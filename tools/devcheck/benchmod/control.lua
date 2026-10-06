--- Benchmark scenes of ME Network (tools/devcheck/devcheck.py bench). Never part of the mod.
---
--- config.lua (written by devcheck.py into the copy of this mod it runs) says which scene and size:
---   scene "me": a synthetic base of `size` buses and interfaces on one ME network (the mix below), with storage
---     buses (size / 10), pattern providers with running jobs (size / 25), level maintainers (size / 10), circuit
---     interfaces (size / 50) and drives with 256k cells that are about 70 % full and hold about 2000 item types.
---     Variants (issue #38): `networks` = K builds K such networks of size / K each, one below the other (the
---     latency probes and the item variety only in the first); `idle` leaves every source empty and blocks every
---     sink, sets no recipe on the machines and starts no job, so the network has nothing to move; `noent` destroys
---     every entity of the mod after the build (the engine's share: the same scene without the ME entities).
---   scene "planner": every usable recipe of the game as a processing pattern (deep trees, with Gregtorio its
---     recipes), the raw materials in cells; the planner and a job start are timed on the deepest items.
---   scene "inserters": the same number of chest -> inserter -> chest lines (half fast, half bulk inserters).
---   scene "robots": size / 10 requester chests (each emptied by a bulk inserter) served by logistic robots from
---     passive provider chests.
--- Service quality (issue #38): the scheduler's counters (remote gregtorio-me-io.sched_stats: visits, backlog, the
--- ticks between two visits of a block by what the visit found) are reset at the first probe and reported at the
--- second with the backlog sampled every SAMPLE_TICKS and the state of the scene's machines (working, waiting for
--- ingredients, output full, and crafts made against what their speed allows). `slice` logs the Lua heap of the
--- mod, the counters and the backlogs every so many ticks (the long run). `burst` builds that many ME blocks in one
--- tick after the probes (cables, buses on chests, interfaces, storage buses, connected to the network) and removes
--- them in one tick, then the same number of plain chests, each timed.
--- Timeline (game ticks): the scene is built in on_init; at `warmup` the first probe counts everything (and turns
--- the profiler of an instrumented mod copy on); at `warmup + window` the second probe counts again and reports the
--- throughput and the conservation check; then the latency probes run (scene "me": a storage bus sees a chest change,
--- a level maintainer reacts, its job starts) and DEVCHECK-BENCH-DONE ends the run. Between the probes this mod does
--- nothing, so the scriptUpdate column of --benchmark-verbose is the ME network's own time.
--- Conservation: every item and fluid in the world (cells, chests, interfaces, machines with the ingredients of a
--- craft in progress, inserter hands, job pools, items on the ground, robots, tanks and fluid segments) before and
--- after the window; the difference must equal what the machines crafted (products minus ingredients).
--- Output: DEVCHECK-BENCH-<KEY> <json> lines in the log.

local C = require("config")

local NET, IO, SB, AC, CIRC, TERM = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-storagebus",
	"gregtorio-me-autocraft", "gregtorio-me-circuit", "gregtorio-me-terminal"
local SURFACE = "devcheck-bench"
local X0, Y0 = 8, 8                   -- the first cable row starts here; the spine runs at X0 - 1
local PITCH = 11                      -- rows: 4 tiles north side, the cable, 4 tiles south side, 2 tiles power
local SLOT = 4                        -- slot width: a 3x3 target and one free column
local PROBE_ITEM = "wooden-chest"     -- the storage bus latency probe: no other place holds it
local LATENCY_RECIPES = 5             -- maintainers of the latency probe (own recipes, own stock)
local LATENCY_STOCK = 100
local LATENCY_TIMEOUT = 3600
local PLANNER_SPARE_DRIVES = 16       -- the planner scene's drives for what the network cannot make (issue #50)
local PLAN_SAMPLE = 150               -- the planner scene's plans compared between two versions (issue #50)
local FLUIDS = { "water", "crude-oil", "petroleum-gas", "light-oil", "heavy-oil", "lubricant", "sulfuric-acid" }
--- raw materials: the network holds millions of them (exports, recipes of the patterns)
local RAW = { "iron-plate", "copper-plate", "steel-plate", "stone", "stone-brick", "wood", "coal", "plastic-bar",
	"iron-gear-wheel", "copper-cable", "electronic-circuit", "advanced-circuit", "iron-stick", "pipe", "engine-unit",
	"sulfur", "battery", "electric-engine-unit", "processing-unit", "concrete", "low-density-structure", "solid-fuel",
	"explosives", "rail" }
local PAIR_RECIPES = { "iron-gear-wheel", "copper-cable", "iron-stick", "pipe" }

--- The `pair` recipes an assembling machine 2 can make from one item ingredient: the vanilla four where they are such a
--- recipe, else (Gregtorio renames or replaces them) the first recipes of that shape by name; and the RAW items that
--- exist. With vanilla both lists stay as they are, so the scenes and their random picks are the same.
local function fit_lists()
	local am = prototypes.entity["assembling-machine-2"]
	local function fits(name)
		local r = prototypes.recipe[name]
		if not (r and not r.hidden and am and am.crafting_categories[r.category]) then return false end
		if #r.ingredients ~= 1 or r.ingredients[1].type ~= "item" or #r.products ~= 1 or r.products[1].type ~= "item" then return false end
		local fr = game.forces.player.recipes[name]
		return fr ~= nil and fr.enabled
	end
	local pairs_ok = {}
	for _, name in ipairs(PAIR_RECIPES) do if fits(name) then pairs_ok[#pairs_ok + 1] = name end end
	if #pairs_ok < #PAIR_RECIPES then
		local names = {}
		for name in pairs(prototypes.recipe) do names[#names + 1] = name end
		table.sort(names)
		for _, name in ipairs(names) do
			if #pairs_ok >= #PAIR_RECIPES then break end
			local seen = false
			for _, p in ipairs(pairs_ok) do if p == name then seen = true end end
			if not seen and fits(name) then pairs_ok[#pairs_ok + 1] = name end
		end
	end
	PAIR_RECIPES = pairs_ok
end
do                                    -- (the RAW items that exist, at every load: the profile and the probes use them later)
	local raw = {}
	for _, name in ipairs(RAW) do if prototypes.item[name] then raw[#raw + 1] = name end end
	RAW = raw
end
local BLOCKERS = { "stone", "coal" }  -- idle scene: a sink chest is filled with one of these, so nothing fits in
local PART_GAP = 12                   -- tiles between two networks of the `networks` variant
local SAMPLE_TICKS = 300              -- the backlogs are sampled this often inside the window (one remote call; issue #56:
                                       -- devcheck leaves these ticks out of the timing, keep its BENCH_SAMPLE_TICKS equal)
local STEADY_TICKS = 1200             -- issue #51: the starved arrivals are also counted from this tick of the window on, after
                                      -- the first visits at the sources filled and the sinks emptied at its start
local ALLOC_FROM, ALLOC_TICKS = 300, 300 -- after the window: the Lua memory the mod allocates in 300 ticks, the collector stopped (issue #43)
local BURST_Y = -40                   -- the build burst's cable row (above the scene and the profile's fixtures)
local STATUS = defines.entity_status

local function log_json(key, t) log("DEVCHECK-BENCH-" .. key .. " " .. helpers.table_to_json(t)) end

--------------------------------------------------------------------------------
--- helpers
--------------------------------------------------------------------------------

local seed = 12345
local function rand(n)                -- deterministic, independent of the game's RNG (the high bits: the low bits of
	seed = (seed * 1103515245 + 12345) % 2147483648   -- this generator alternate)
	return math.floor(seed / 65536) % n + 1
end

local fails = {}
local function fail(msg) fails[#fails + 1] = msg end

local function surface() return game.surfaces[SURFACE] end

local function place(name, x, y, dir, extra)
	local def = { name = name, position = { x, y }, force = "player", direction = dir, create_build_effect_smoke = false }
	for k, v in pairs(extra or {}) do def[k] = v end
	local ok, e = pcall(surface().create_entity, def)
	if not (ok and e) then fail("place " .. name .. " at " .. x .. "," .. y .. ": " .. tostring(e)) return nil end
	return e
end

--- tile (tx, ty) -> the position of a 1x1 entity on it; 3x3 entities centered on a tile; 2x2 at a tile corner
local function p1(tx, ty) return tx + 0.5, ty + 0.5 end

local function key_of(name, quality)
	if not quality or quality == "normal" then return name end
	return name .. "@" .. quality
end

local function add(t, k, n) if n ~= 0 then t[k] = (t[k] or 0) + n end end

local function plain(name)
	local p = prototypes.item[name]
	return p ~= nil and p.type == "item" and not p.hidden and p.get_spoil_ticks("normal") == 0
		and not name:find("^parameter") and not name:find("^me%-")
end

local function chest_fill(chest, name, stacks)
	local size = prototypes.item[name].stack_size
	return chest.insert{ name = name, count = size * stacks }
end

--- idle scene: fill every slot of a sink chest with an item the bus or inserter does not deliver
local function block_chest(chest, item)
	local blocker = item == BLOCKERS[1] and BLOCKERS[2] or BLOCKERS[1]
	chest_fill(chest, blocker, #chest.get_inventory(defines.inventory.chest))
end

--- the scheduler's counters of the mod (issue #38; nil with a version that has none, bench --from-ref)
local function sched_stats(reset)
	local io = remote.interfaces[IO]
	if io and io.sched_stats then return remote.call(IO, "sched_stats", reset) end
	return nil
end

local function backlogs()
	local io = remote.interfaces[IO]
	if io and io.backlogs then return remote.call(IO, "backlogs") end
	return nil
end

local function mod_memory_kb(collect)
	local io = remote.interfaces[IO]
	if io and io.lua_memory then return remote.call(IO, "lua_memory", collect) end
	return nil
end

--- every technology researched, except one whose research ends the game (Gregtorio's `victory`: a finished game
--- does not simulate in a headless benchmark, so the run would perform its ticks in no time and measure nothing)
local function research_all(force)
	for name, tech in pairs(force.technologies) do
		if name ~= "victory" and not tech.researched then
			local ok = pcall(function() tech.researched = true end)
			if not ok then fail("research " .. name) end
		end
	end
end

local function power_row(gy, x1, x2)
	--- substations (2x2) every 16 tiles, an energy interface next to each one (no copper wire needed)
	local x = x1
	while x <= x2 do
		place("substation", x, gy + 1)
		local eei = place("electric-energy-interface", x - 2, gy + 1)
		if eei then
			eei.power_production = 1e7
			eei.electric_buffer_size = 1e8
		end
		x = x + 16
	end
end

local function new_surface(w, h)
	local s = game.create_surface(SURFACE, { width = w + 64, height = h + 64, peaceful_mode = true })
	s.generate_with_lab_tiles = true
	s.always_day = true
	for cx = -3, math.ceil((w + 32) / 32) do
		for cy = -3, math.ceil((h + 32) / 32) do s.request_to_generate_chunks({ cx * 32 + 16, cy * 32 + 16 }, 0) end
	end
	s.force_generate_chunk_requests()
	return s
end

--------------------------------------------------------------------------------
--- counting: everything in the world, by key ("name", "name@quality", "fluid/<name>")
--------------------------------------------------------------------------------

local CONTAINERS = { "container", "logistic-container", "infinity-container" }
local CRAFTERS = { "assembling-machine", "furnace" }

local function inv_add(out, inv)
	if not inv then return end
	for _, c in pairs(inv.get_contents()) do add(out, key_of(c.name, c.quality), c.count) end
end

--- the ingredients of a craft in progress are gone from the machine's input already: they count as in the machine
local function in_progress(out, m)
	local r = m.get_recipe()
	if r and m.crafting_progress > 0 then
		for _, ing in pairs(r.ingredients) do
			add(out, ing.type == "fluid" and ("fluid/" .. ing.name) or ing.name, ing.amount)
		end
	end
end

local function count_world()
	local s = surface()
	local out = {}
	for _, e in pairs(s.find_entities_filtered{ type = CONTAINERS }) do inv_add(out, e.get_inventory(defines.inventory.chest)) end
	for _, m in pairs(s.find_entities_filtered{ type = CRAFTERS }) do
		inv_add(out, m.get_inventory(defines.inventory.crafter_input))
		inv_add(out, m.get_inventory(defines.inventory.crafter_output))
		in_progress(out, m)
		local fb = m.fluidbox
		for i = 1, #fb do
			local f = fb[i]
			if f then add(out, "fluid/" .. f.name, f.amount) end
		end
	end
	for _, i in pairs(s.find_entities_filtered{ type = "inserter" }) do
		local h = i.held_stack
		if h and h.valid_for_read then add(out, key_of(h.name, h.quality.name), h.count) end
	end
	for _, g in pairs(s.find_entities_filtered{ name = "item-on-ground" }) do
		add(out, key_of(g.stack.name, g.stack.quality.name), g.stack.count)
	end
	for _, r in pairs(s.find_entities_filtered{ type = "logistic-robot" }) do
		inv_add(out, r.get_inventory(defines.inventory.robot_cargo))
	end
	for _, r in pairs(s.find_entities_filtered{ type = "roboport" }) do
		inv_add(out, r.get_inventory(defines.inventory.roboport_material))
	end
	local segs = {}
	for _, e in pairs(s.find_entities_filtered{ type = { "storage-tank", "pipe", "pipe-to-ground", "pump" } }) do
		local fb = e.fluidbox
		for i = 1, #fb do
			local id = fb.get_fluid_segment_id(i)
			if id then
				if not segs[id] then
					segs[id] = true
					for name, amount in pairs(fb.get_fluid_segment_contents(i) or {}) do add(out, "fluid/" .. name, amount) end
				end
			elseif fb[i] then
				add(out, "fluid/" .. fb[i].name, fb[i].amount)
			end
		end
	end
	local b = storage.b
	for _, d in pairs(b.drives or {}) do
		if d.valid then
			for _, cell in pairs(remote.call(NET, "drive", d)) do
				for key, n in pairs(cell.items) do add(out, key, n) end
			end
		end
	end
	for _, anchor in ipairs(b.anchors or { b.anchor }) do
		if anchor and anchor.valid then
			for _, j in pairs(remote.call(AC, "jobs", anchor)) do
				local job = remote.call(AC, "job", j.id)
				for key, n in pairs(job and job.pool or {}) do add(out, key, n) end
			end
		end
	end
	return out
end

--- crafts finished per machine with its recipe's net products: what crafting added to the world
local function crafted()
	local out = {}
	for _, m in pairs(surface().find_entities_filtered{ type = CRAFTERS }) do
		local r = m.get_recipe()
		if r then out[m.unit_number] = { m.products_finished, r.name } end
	end
	return out
end

local function production(c0, c1)
	local out = {}
	for unit, v1 in pairs(c1) do
		local v0 = c0[unit]
		local n = v1[1] - (v0 and v0[1] or 0)
		if v0 and v0[2] ~= v1[2] then fail("machine " .. unit .. " changed its recipe in the window") end
		if n ~= 0 then
			local r = prototypes.recipe[v1[2]]
			for _, p in pairs(r.products) do add(out, p.type == "fluid" and ("fluid/" .. p.name) or p.name, n * (p.amount or 0)) end
			for _, i in pairs(r.ingredients) do add(out, i.type == "fluid" and ("fluid/" .. i.name) or i.name, -n * i.amount) end
		end
	end
	return out
end

local function conservation(w0, w1, prod)
	local keys, bad = {}, {}
	for k in pairs(w0) do keys[k] = true end
	for k in pairs(w1) do keys[k] = true end
	for k in pairs(prod) do keys[k] = true end
	local checked = 0
	for k in pairs(keys) do
		checked = checked + 1
		local d = (w1[k] or 0) - (w0[k] or 0) - (prod[k] or 0)
		local tol = k:find("^fluid/") and math.max(1, 1e-6 * math.max(w0[k] or 0, w1[k] or 0)) or 0
		if math.abs(d) > tol then bad[#bad + 1] = { key = k, before = w0[k] or 0, after = w1[k] or 0, crafted = prod[k] or 0, diff = d } end
	end
	table.sort(bad, function(a, c) return a.key < c.key end)
	return checked, bad
end

--------------------------------------------------------------------------------
--- the ME scene
--------------------------------------------------------------------------------

local function segment_amount(e)
	local fb = e.fluidbox
	if #fb == 0 then return 0 end
	local n = 0
	for _, a in pairs(fb.get_fluid_segment_contents(1) or {}) do n = n + a end
	return n
end

local function inv_total(e, index)
	local inv = e and e.valid and e.get_inventory(index or defines.inventory.chest)
	return inv and inv.get_item_count() or 0
end

local function hand(i)
	local h = i and i.valid and i.held_stack
	return (h and h.valid_for_read) and h.count or 0
end

--- the recipes of the pattern providers: crafting recipes of the molecular assembler from raw materials only, one
--- item product of a plain item
local function pattern_recipes(force)
	local cats = prototypes.entity["me-molecular-assembler"].crafting_categories
	local raw = {}
	for _, r in pairs(RAW) do raw[r] = true end
	local out = {}
	for name, r in pairs(prototypes.recipe) do
		local ok = cats[r.category] and not r.hidden and force.recipes[name] and force.recipes[name].enabled
			and #r.products == 1 and r.products[1].type == "item" and r.products[1].amount and r.products[1].amount > 0
			and (r.products[1].probability or 1) == 1 and plain(r.products[1].name) and #r.ingredients > 0
			and r.products[1].name ~= PROBE_ITEM and not raw[r.products[1].name]
		if ok then
			for _, i in pairs(r.ingredients) do
				if i.type ~= "item" or not raw[i.name] or i.amount > prototypes.item[i.name].stack_size then ok = false end
			end
		end
		if ok then out[#out + 1] = name end
	end
	table.sort(out)
	return out
end

--- the counts of each slot kind for `size` buses and interfaces. A machine (`pair`) has two buses: the export bus
--- feeds its input, the import bus empties its output. The capacity probes (`cap_*`) work on a warehouse of 800 slots
--- or a tank of 1 000 000 units (test fixtures, data.lua): what one bus can move when its target never runs out.
--- the scene at the maintainer's size (`base`, issues #50 and #51): his network of 2158 members on Gregtorio Continued,
--- 1767 cables and 2 underground cables (here: 1769 cables), 189 interfaces and buses (the mix below scaled to 189),
--- 184 storage buses (70 % on chests, 30 % on tanks), 8 drives (one of them for fluid cells), 7 terminals, the controller;
--- no pattern providers, level maintainers, circuit interfaces or crafting CPUs (his network has none)
local BASE = { cables = 1769, storage_buses = 184, drives = 7, fdrives = 1, terminals = 7 }

local function mix(size)
	local function pct(p) return math.max(1, math.floor(size * p / 100 + 0.5)) end
	local function cap() return math.max(2, math.floor(size / 100 + 0.5)) end
	local m = {
		imp_chest = pct(18), exp_chest = pct(12), pair = math.max(1, math.floor(pct(10) / 2)), imp_tank = pct(8),
		exp_tank = pct(8), cap_imp = cap(), cap_exp = cap(), cap_fimp = cap(), cap_fexp = cap(),
		iface_items = pct(20), iface_fin = pct(10), iface_fout = pct(10),
		sb_chest = math.max(1, math.floor(size / 10 * 0.7 + 0.5)), sb_tank = math.max(1, math.floor(size / 10 * 0.3 + 0.5)),
		provider = math.max(2, math.floor(size / 25 + 0.5)), maint = math.max(2, math.floor(size / 10 + 0.5)),
		circuit = math.max(1, math.floor(size / 50 + 0.5)), drive = math.max(8, math.floor(size / 50 + 0.5)),
		fdrive = math.max(1, math.floor(size / 250 + 0.5)), lat_provider = LATENCY_RECIPES, lat_maint = LATENCY_RECIPES,
		terminal = 0,
	}
	if C.base then
		m.sb_chest = math.floor(BASE.storage_buses * 0.7 + 0.5)
		m.sb_tank = BASE.storage_buses - m.sb_chest
		m.drive, m.fdrive, m.terminal = BASE.drives, BASE.fdrives, BASE.terminals
		m.provider, m.maint, m.circuit, m.lat_provider, m.lat_maint = 0, 0, 0, 0, 0
	end
	return m
end

--- the slot kinds spread evenly over the slots (largest remainder first, so every kind is everywhere)
local ORDER = { "imp_chest", "exp_chest", "pair", "imp_tank", "exp_tank", "cap_imp", "cap_exp", "cap_fimp", "cap_fexp",
	"iface_items", "iface_fin", "iface_fout",
	"sb_chest", "sb_tank", "provider", "maint", "circuit", "drive", "fdrive", "lat_provider", "lat_maint", "terminal" }
local function interleave(m)
	local total = 0
	for _, k in ipairs(ORDER) do total = total + m[k] end
	local out, used = {}, {}
	for _, k in ipairs(ORDER) do used[k] = 0 end
	for i = 1, total do
		local best, bv
		for _, k in ipairs(ORDER) do
			local v = m[k] * i / total - used[k]
			if used[k] < m[k] and (not bv or v > bv) then best, bv = k, v end
		end
		used[best] = used[best] + 1
		out[i] = best
	end
	return out
end

--- cell contents: a list of { key -> count } for 256k item cells (about `fill` of the cells used), every raw material
--- in millions, every other plain item in every quality a few hundred times
local function pack_cells(ncells, fill, reserved, variety_wanted)
	local spec = prototypes.mod_data["fork-me-network"].data.cells["me-256k-storage-cell"]
	local per_byte = spec.per_byte or 8
	local qualities = {}
	for name, q in pairs(prototypes.quality) do if not q.hidden then qualities[#qualities + 1] = name end end
	table.sort(qualities)
	local raw = {}
	for _, r in pairs(RAW) do raw[r] = true end
	local variety = {}
	local names = {}
	for name in pairs(prototypes.item) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		if variety_wanted and plain(name) and not raw[name] and name ~= PROBE_ITEM and not reserved[name] then
			for _, q in ipairs(qualities) do variety[#variety + 1] = key_of(name, q) end
		end
	end
	local cells, cur = {}, nil
	local function new() cur = { items = {}, bytes = 0, types = 0 } cells[#cells + 1] = cur end
	local function put(key, count)        -- as much of `count` as fits; returns the rest
		if not cur or cur.types >= spec.types or spec.bytes - cur.bytes <= spec.per_type then new() end
		local room = (spec.bytes - cur.bytes - spec.per_type) * per_byte
		local n = math.min(count, room)
		cur.items[key] = n
		cur.types = cur.types + 1
		cur.bytes = cur.bytes + spec.per_type + math.ceil(n / per_byte)
		return count - n
	end
	local rnames = {}
	for name in pairs(reserved) do rnames[#rnames + 1] = name end
	table.sort(rnames)
	for _, name in ipairs(rnames) do put(name, reserved[name]) end   -- the latency keys: an exact stock
	for _, key in ipairs(variety) do put(key, 300) end
	local used = #cells
	local budget = math.max(0, math.floor(ncells * fill) - used)
	local per_raw = math.max(1, math.floor(budget / #RAW)) * ((spec.bytes - spec.per_type) * per_byte - 64)
	for _, r in ipairs(RAW) do
		if prototypes.item[r] then
			local left = per_raw
			new()
			while left > 0 and #cells <= math.floor(ncells * fill) do left = put(r, left) end
		end
	end
	local out = {}
	for i = 1, math.min(#cells, ncells) do out[i] = cells[i].items end
	return out, #variety
end

local function fluid_cells(ncells)
	local spec = prototypes.mod_data["fork-me-network"].data.cells["me-256k-fluid-storage-cell"]
	local per_byte = spec.per_byte or 8
	local out = {}
	for i = 1, ncells do
		local items, bytes = {}, 0
		for k = 1, 3 do
			local name = FLUIDS[(i + k) % #FLUIDS + 1]
			if prototypes.fluid[name] and not items["fluid/" .. name] then
				local n = math.floor((spec.bytes * 0.7 / 3 - spec.per_type) * per_byte)
				items["fluid/" .. name] = n
				bytes = bytes + spec.per_type + math.ceil(n / per_byte)
			end
		end
		out[i] = items
	end
	return out
end

local function insert_cell(drive, name, items, slot)
	local inv = game.create_inventory(1)
	inv[1].set_stack{ name = name, count = 1, tags = { fork_me_cell = { items = items, data = {} } } }
	local ok = remote.call(NET, "insert_cell", drive, inv[1], slot)
	if not ok then fail("insert_cell " .. name .. " into drive " .. drive.unit_number) end
	inv.destroy()
end

local function give_pattern(provider, recipe)
	local inv = game.create_inventory(2)
	inv.insert{ name = "me-blank-pattern", count = 1 }
	local where, why = remote.call(TERM, "encode_def", false, inv, false, { kind = "crafting", recipe = recipe })
	local stack = inv.find_item_stack("me-encoded-pattern")
	if not (where and stack and remote.call(AC, "insert_pattern", provider, stack)) then
		fail("pattern " .. recipe .. ": " .. tostring(why))
	end
	inv.destroy()
end

--- an inserter at (tx, ty) that picks from the tile in direction `from` (its direction is the pickup side)
local function inserter(name, tx, ty, from)
	local x, y = p1(tx, ty)
	return place(name, x, y, from)
end

--- the geometry of one network (a part) of `size` buses and interfaces: the mix, the slot kinds in order, the
--- slots per row and side, rows, width and height. Only the first part has the latency probes (and the item
--- variety in its cells); the other parts need fewer drives.
local function part_geometry(size, first)
	local m = mix(size)
	if not first then
		m.lat_provider, m.lat_maint = 0, 0
		m.drive = math.max(2, math.floor(size / 50 + 0.5))
	end
	local kinds = interleave(m)
	local spr = math.max(10, math.ceil(math.sqrt(#kinds) * 0.8))             -- slots per row and side
	local rows = math.ceil(#kinds / (2 * spr))
	return { m = m, kinds = kinds, spr = spr, rows = rows, width = SLOT * spr, height = rows * PITCH }
end

--- the pattern recipes split into the latency probes' and the regular ones
local function split_recipes(force)
	local recipes = pattern_recipes(force)
	if #recipes < LATENCY_RECIPES + 4 then fail("only " .. #recipes .. " pattern recipes") end
	local lat_recipes, reg_recipes = {}, {}
	for i, r in ipairs(recipes) do
		if i <= LATENCY_RECIPES then lat_recipes[#lat_recipes + 1] = r else reg_recipes[#reg_recipes + 1] = r end
	end
	return lat_recipes, reg_recipes
end

--- Place one part (network) with its first cable row at `Y`: power, spine, controller, CPUs and the slots. The ME
--- members go into `members` (registered by the caller in one pass). Returns the part record.
local function place_part(b, geo, Y, index, first, members)
	local m, kinds, spr, rows, width = geo.m, geo.kinds, geo.spr, geo.rows, geo.width
	local idle = C.idle
	local part = { index = index, cpus = {}, slots = {}, y = Y, rows = rows }
	local function member(e) if e then members[#members + 1] = e end return e end
	local ncables = 0
	local function cable(x, y)
		if place("me-cable", x, y) then ncables = ncables + 1 end   -- (cables join through the rebuild, not registered)
	end
	--- power: a row of substations above every cable row's north side and below its south side
	for r = 0, rows do power_row(Y - 6 + r * PITCH, X0 - 4, X0 + width + 2) end
	--- the spine, the controller and the CPUs on the left
	for y = Y, Y + (rows - 1) * PITCH do cable(p1(X0 - 1, y)) end
	part.anchor = member(place("me-network-controller", X0 - 2, Y + 1))
	local lat_recipes, reg_recipes = split_recipes(game.forces.player)
	part.lat_recipes, part.reg_recipes = lat_recipes, reg_recipes
	local jobs = (idle or C.base) and 0 or math.max(1, math.floor(m.provider / 4))
	part.jobs = jobs
	local ncpu
	if C.base then
		ncpu = 0                                                 -- (the maintainer's network has no CPU)
	elseif prototypes.entity["me-256k-crafting-storage"] then
		--- issue #6: one multiblock CPU per job and eight spare in the first part (the quantum CPUs had at least eight
		--- free slots for the level maintainers and the latency probes; the other parts' maintainers are stocked),
		--- each a row of 19 blocks left of the spine (sixteen 256k crafting storages, 4 MiB: the jobs of 5000 items
		--- of the scene need up to about 2 MiB; three co-processors: as fast as a quantum CPU), a free row between
		--- two CPUs; a part too low for its CPUs gets more columns, joined by two cables
		ncpu = jobs + (first and 8 or 1)
		local per_col = math.max(1, math.floor((rows * PITCH - 3) / 2))
		for k = 0, ncpu - 1 do
			local col, row = math.floor(k / per_col), k % per_col
			local y, xb = Y + 3 + 2 * row, X0 - 21 * col
			part.cpus[#part.cpus + 1] = member(place("me-256k-crafting-storage", p1(xb - 2, y)))
			for dx = 3, 17 do member(place("me-256k-crafting-storage", p1(xb - dx, y))) end
			for dx = 18, 20 do member(place("me-crafting-co-processing-unit", p1(xb - dx, y))) end
			if col > 0 then
				place("me-cable", p1(xb, y))
				place("me-cable", p1(xb - 1, y))
			end
		end
	else                                                     -- (bench --from-ref of a version before issue #6)
		ncpu = math.ceil(jobs / 4) + 2
		for k = 0, ncpu - 1 do part.cpus[#part.cpus + 1] = member(place("me-quantum-crafting-cpu", X0 - 2, Y + 3 + 2 * k)) end
		if Y + 3 + 2 * ncpu > Y + (rows - 1) * PITCH then fail("too many CPUs for the spine") end
	end
	part.ncpu = ncpu
	--- the slots
	local n, lat_i, prov_i = 0, 0, 0
	for r = 0, rows - 1 do
		local y0 = Y + r * PITCH
		for x = X0, X0 + width - 1 do cable(p1(x, y0)) end
		for _, s in ipairs({ -1, 1 }) do
			for j = 0, spr - 1 do
				n = n + 1
				local kind = kinds[n]
				if not kind then break end
				b.count[kind] = (b.count[kind] or 0) + 1
				local x = X0 + SLOT * j
				local by = y0 + s                                  -- the tile next to the cable
				local dir = s < 0 and defines.direction.north or defines.direction.south
				local cy = y0 + 3 * s                              -- center tile of a 3x3 target
				local rec = { kind = kind, part = index }
				b.slots[#b.slots + 1] = rec
				part.slots[#part.slots + 1] = #b.slots
				local item = RAW[rand(#RAW)]
				local fluid = FLUIDS[rand(#FLUIDS)]
				if kind == "imp_chest" then
					rec.bus = member(place("me-import-bus", x + 1.5, by + 0.5, dir))
					rec.chest = place("steel-chest", p1(x + 1, y0 + 2 * s))
					rec.item = item
					if rec.chest and not idle then chest_fill(rec.chest, item, 48) end
				elseif kind == "exp_chest" then
					rec.bus = member(place("me-export-bus", x + 1.5, by + 0.5, dir))
					rec.chest = place("steel-chest", p1(x + 1, y0 + 2 * s))
					rec.filters = { item }
					if rec.chest and idle then block_chest(rec.chest, item) end
				elseif kind == "pair" then
					local recipe = PAIR_RECIPES[rand(#PAIR_RECIPES)]
					rec.machine = place("assembling-machine-2", x + 1.5, cy + 0.5)
					if rec.machine and not idle then rec.machine.set_recipe(recipe) end
					rec.recipe = recipe
					rec.exp = member(place("me-export-bus", x + 0.5, by + 0.5, dir))
					rec.imp = member(place("me-import-bus", x + 2.5, by + 0.5, dir))
					rec.filters = { prototypes.recipe[recipe].ingredients[1].name }
				elseif kind == "cap_imp" or kind == "cap_exp" then
					rec.bus = member(place(kind == "cap_imp" and "me-import-bus" or "me-export-bus", x + 1.5, by + 0.5, dir))
					rec.chest = place("zz-bench-warehouse", p1(x + 1, y0 + 2 * s))
					rec.item = item
					rec.filters = { item }
					if rec.chest and idle and kind == "cap_exp" then block_chest(rec.chest, item) end
				elseif kind == "cap_fimp" or kind == "cap_fexp" then
					rec.bus = member(place(kind == "cap_fimp" and "me-import-bus" or "me-export-bus", x + 1.5, by + 0.5, dir))
					rec.tank = place("zz-bench-big-tank", x + 1.5, cy + 0.5)
					rec.fluid = fluid
					rec.filters = { "fluid/" .. fluid }
					if rec.tank and idle and kind == "cap_fexp" then rec.tank.insert_fluid{ name = fluid, amount = 1000000 } end
				elseif kind == "imp_tank" or kind == "exp_tank" then
					rec.bus = member(place(kind == "imp_tank" and "me-import-bus" or "me-export-bus", x + 1.5, by + 0.5, dir))
					rec.tank = place("storage-tank", x + 1.5, cy + 0.5)
					if kind == "imp_tank" then rec.fluid = fluid end
					if rec.tank and ((kind == "imp_tank" and not idle) or (kind == "exp_tank" and idle)) then
						rec.tank.insert_fluid{ name = fluid, amount = 25000 }
					end
					rec.filters = kind == "exp_tank" and { "fluid/" .. fluid } or {}
				elseif kind == "iface_items" then
					local ix = x + 1
					rec.iface = member(place("me-network-interface", p1(ix, by)))
					rec.src = place("steel-chest", p1(ix, y0 + 3 * s))
					rec.src_item = RAW[rand(#RAW)]
					if rec.src and not idle then chest_fill(rec.src, rec.src_item, 48) end
					rec.ins = inserter("fast-inserter", ix, y0 + 2 * s, dir)      -- from the source chest into the interface
					rec.out_item = item
					rec.eins = inserter("fast-inserter", ix + 1, by, defines.direction.west)   -- from the interface east
					if rec.eins then
						rec.eins.use_filters = true
						rec.eins.set_filter(1, item)
					end
					rec.sink = place("steel-chest", p1(ix + 2, by))
					if rec.sink and idle then block_chest(rec.sink, item) end
				elseif kind == "iface_fin" or kind == "iface_fout" then
					--- the interface touches the tank's connection: north slots on the tank's south one, south slots
					--- on its north one
					local ix = s < 0 and x + 2 or x + 1
					local tx = s < 0 and ix - 1 or ix + 1
					rec.tank = place("storage-tank", tx + 0.5, cy + 0.5)
					rec.iface = member(place("me-network-interface", p1(ix, by)))
					rec.side = s < 0 and 1 or 3
					rec.fluid = fluid
					if rec.tank and ((kind == "iface_fin" and not idle) or (kind == "iface_fout" and idle)) then
						rec.tank.insert_fluid{ name = fluid, amount = 25000 }
					end
				elseif kind == "sb_chest" then
					rec.bus = member(place("me-storage-bus", x + 1.5, by + 0.5, dir))
					rec.chest = place("steel-chest", p1(x + 1, y0 + 2 * s))
					if rec.chest then
						for _ = 1, 4 do chest_fill(rec.chest, RAW[rand(#RAW)], 5) end
					end
					local pick = rand(10)
					if pick <= 2 then rec.settings = { priority = -10 }
					elseif pick == 3 then rec.settings = { priority = 10, filters = { RAW[rand(#RAW)], RAW[rand(#RAW)] } } end
				elseif kind == "sb_tank" then
					rec.bus = member(place("me-storage-bus", x + 1.5, by + 0.5, dir))
					rec.tank = place("storage-tank", x + 1.5, cy + 0.5)
					if rec.tank and rand(10) <= 7 then rec.tank.insert_fluid{ name = fluid, amount = 10000 } end
				elseif kind == "provider" or kind == "lat_provider" then
					local recipe
					if kind == "lat_provider" then
						lat_i = lat_i + 1
						recipe = lat_recipes[lat_i]
					else
						prov_i = prov_i + 1
						recipe = reg_recipes[(prov_i - 1) % #reg_recipes + 1]
					end
					rec.provider = member(place("me-pattern-provider", x + 1.5, by + 0.5))
					rec.machine = place("me-molecular-assembler", x + 1.5, cy + 0.5)
					if rec.machine and recipe then rec.machine.set_recipe(recipe) end
					rec.recipe = recipe
				elseif kind == "maint" or kind == "lat_maint" then
					rec.maint = member(place("me-level-maintainer", x + 1.5, by + 0.5))
				elseif kind == "circuit" then
					rec.circuit = member(place("me-circuit-interface", x + 1.5, by + 0.5))
				elseif kind == "drive" or kind == "fdrive" then
					rec.drive = member(place("me-drive", x + 1.5, by + 0.5))
					if rec.drive then b.drives[#b.drives + 1] = rec.drive end
				elseif kind == "terminal" then
					rec.terminal = member(place("me-terminal", p1(x + 1, by)))
				end
			end
		end
	end
	if C.base then
		--- the rest of the 1769 cables: a block of cable columns left of the power, joined to the spine by a row
		local y = Y + 3
		for x = X0 - 9, X0 - 2 do cable(p1(x, y)) end
		local x, height = X0 - 10, math.max(4, rows * PITCH - 8)
		while ncables < BASE.cables do
			for dy = 0, height - 1 do
				if ncables >= BASE.cables then break end
				cable(p1(x, y + dy))
			end
			x = x - 1
		end
	end
	part.cables = ncables
	return part
end

--- the cells, settings, patterns and probes of a placed and registered part
local function configure_part(b, part, first)
	local lat_recipes, reg_recipes = part.lat_recipes, part.reg_recipes
	local reserved = {}
	if first then
		for _, r in ipairs(lat_recipes) do reserved[prototypes.recipe[r].products[1].name] = LATENCY_STOCK end
	else                                              -- no variety: the maintainers' items must still be in stock
		for _, r in ipairs(reg_recipes) do reserved[prototypes.recipe[r].products[1].name] = 300 end
	end
	local idrives, fdrives = {}, {}
	for _, i in ipairs(part.slots) do
		local rec = b.slots[i]
		if rec.kind == "drive" and rec.drive then idrives[#idrives + 1] = rec.drive end
		if rec.kind == "fdrive" and rec.drive then fdrives[#fdrives + 1] = rec.drive end
	end
	local cells, types = pack_cells(#idrives * 10, 0.7, reserved, first)
	for i, items in ipairs(cells) do
		insert_cell(idrives[math.floor((i - 1) / 10) + 1], "me-256k-storage-cell", items, (i - 1) % 10 + 1)
	end
	for i = #cells + 1, #idrives * 10 do
		insert_cell(idrives[math.floor((i - 1) / 10) + 1], "me-256k-storage-cell", {}, (i - 1) % 10 + 1)
	end
	for i, items in ipairs(fluid_cells(#fdrives * 10)) do
		insert_cell(fdrives[math.floor((i - 1) / 10) + 1], "me-256k-fluid-storage-cell", items, (i - 1) % 10 + 1)
	end
	--- a tenth of the drives at a higher priority, some empty cells partitioned (input cells)
	for i, d in ipairs(idrives) do
		if i % 10 == 0 then remote.call(NET, "set_priority", d, 10) end
	end
	--- the settings of every block
	local maint_keys = {}
	for _, r in ipairs(reg_recipes) do maint_keys[#maint_keys + 1] = prototypes.recipe[r].products[1].name end
	local lat_i = 0
	local probes = {}
	for _, i in ipairs(part.slots) do
		local rec = b.slots[i]
		local k = rec.kind
		if (k == "exp_chest" or k == "exp_tank") and rec.bus then remote.call(IO, "set_bus_filters", rec.bus, rec.filters) end
		if (k == "cap_exp" or k == "cap_fexp") and rec.bus then remote.call(IO, "set_bus_filters", rec.bus, rec.filters) end
		if k == "pair" and rec.exp then remote.call(IO, "set_bus_filters", rec.exp, rec.filters) end
		if k == "iface_items" and rec.iface then
			remote.call(IO, "set_interface_config", rec.iface, { { name = rec.out_item, quality = "normal", amount = prototypes.item[rec.out_item].stack_size } }, {})
		end
		if k == "iface_fout" and rec.iface then
			remote.call(IO, "set_interface_config", rec.iface, { { type = "fluid", name = rec.fluid, amount = 5000 } }, { [rec.side] = 1 })
		end
		if k == "sb_chest" and rec.bus then
			if rec.settings then remote.call(SB, "set_settings", rec.bus, rec.settings)
			else probes[#probes + 1] = rec.chest end
		end
		if (k == "provider" or k == "lat_provider") and rec.provider and rec.recipe then give_pattern(rec.provider, rec.recipe) end
		if k == "maint" and rec.maint then
			remote.call(CIRC, "set_maintainer", rec.maint, maint_keys[rand(#maint_keys)], 50, false)
		end
		if k == "lat_maint" and rec.maint then
			lat_i = lat_i + 1
			local key = prototypes.recipe[lat_recipes[lat_i]].products[1].name
			remote.call(CIRC, "set_maintainer", rec.maint, key, LATENCY_STOCK, false)
			b.lat_maint[#b.lat_maint + 1] = { entity = rec.maint, key = key }
		end
		if k == "circuit" and rec.circuit then rec.filtered = rand(2) == 1 end
		if k == "circuit" and rec.circuit and rec.filtered then
			local keys = {}
			for _ = 1, 5 do keys[#keys + 1] = RAW[rand(#RAW)] end
			remote.call(CIRC, "set_circuit_filters", rec.circuit, keys)
		end
	end
	if first then
		--- the storage bus probes: 20 chests spread over all (the buses are visited in unit order)
		local spread = {}
		for i = 1, math.min(20, #probes) do spread[i] = probes[math.floor((i - 1) * #probes / math.min(20, #probes)) + 1] end
		b.sb_probe = spread
	end
	--- jobs on the providers (started at warmup / 2, when the controller has power): a quarter as many as
	--- providers, each for more than the run makes
	for i = 1, part.jobs do
		b.job_keys[#b.job_keys + 1] = { anchor = part.anchor, key = prototypes.recipe[reg_recipes[(i - 1) % #reg_recipes + 1]].products[1].name }
	end
	return types
end

--- `noent`: every entity of the mod goes (the members, the interfaces' side tanks), nothing is registered any more
local function strip_me()
	local n = 0
	for _, e in pairs(surface().find_entities_filtered{}) do
		if e.valid and e.name:find("^me%-") then
			e.destroy()
			n = n + 1
		end
	end
	log("DEVCHECK-BENCH-STRIP " .. n)
end

local function build_me()
	local b = storage.b
	research_all(game.forces.player)
	fit_lists()
	local K = math.max(1, C.networks or 1)
	local geos, total_h, max_w = {}, 0, 0
	for k = 1, K do
		local size = math.floor(C.size / K) + (k <= C.size % K and 1 or 0)
		geos[k] = part_geometry(size, k == 1)
		total_h = total_h + geos[k].height + (k < K and PART_GAP or 0)
		max_w = math.max(max_w, geos[k].width)
	end
	new_surface(max_w + 16, total_h + 16)
	b.slots, b.drives, b.count, b.parts, b.anchors, b.lat_maint, b.sb_probe, b.job_keys = {}, {}, {}, {}, {}, {}, {}, {}
	local members = {}
	local y = Y0
	for k = 1, K do
		local part = place_part(b, geos[k], y, k, k == 1, members)
		b.parts[k] = part
		b.anchors[k] = part.anchor
		y = y + geos[k].height + PART_GAP
	end
	b.anchor = b.parts[1].anchor
	b.cpus = b.parts[1].cpus
	if C.noent then
		--- the engine's share: the ME entities are placed like the rest and destroyed again before the mod ever
		--- registers them (nothing to sweep, no cells to spill); the chests, tanks, machines, inserters and power stay
		log_json("SETUP", { scene = "me", size = C.size, networks = K, idle = false, noent = true, slots = #b.slots,
			counts = b.count, members = #members, entities = #surface().find_entities_filtered{}, fails = fails })
		strip_me()
		return
	end
	--- the graph in one pass (the map scan of on_configuration_changed), then every module registers its blocks
	local prof = game.create_profiler()
	remote.call(NET, "rebuild")
	for _, e in ipairs(members) do script.raise_script_built{ entity = e } end
	prof.stop()
	log({ "", "DEVCHECK-BENCH-BUILD registered ", #members, " members: ", prof })
	local types = 0
	for k = 1, K do types = types + configure_part(b, b.parts[k], k == 1) end
	local net = remote.call(NET, "network", b.anchor)
	local members_all, cells_all, fcells_all, sb_all, fsb_all = 0, 0, 0, 0, 0
	for k = 1, K do
		local nk = remote.call(NET, "network", b.anchors[k])
		if nk then
			members_all, cells_all, fcells_all = members_all + (nk.members or 0), cells_all + (nk.cells or 0), fcells_all + (nk.fluid_cells or 0)
			sb_all, fsb_all = sb_all + (nk.storage_buses or 0), fsb_all + (nk.fluid_storage_buses or 0)
		end
	end
	local rows = 0
	for k = 1, K do rows = rows + geos[k].rows end
	log_json("SETUP", { scene = "me", size = C.size, networks = K, idle = C.idle or false, noent = C.noent or false,
		slots = #b.slots, rows = rows, slots_per_row = 2 * geos[1].spr, counts = b.count, cables = b.parts[1].cables,
		members = members_all, cells = cells_all, fluid_cells = fcells_all,
		storage_buses = sb_all, fluid_storage_buses = fsb_all, item_types = types, recipes = #b.parts[1].reg_recipes,
		jobs = #b.job_keys, cpus = b.parts[1].ncpu, network_ok = net and net.ok or false,
		entities = #surface().find_entities_filtered{}, fails = fails })
end

--- what each slot kind moved between two probes (items or fluid units)
local function slot_state(rec)
	local k = rec.kind
	if k == "imp_chest" or k == "exp_chest" then return { inv_total(rec.chest) } end
	if k == "cap_imp" or k == "cap_exp" then return { inv_total(rec.chest) } end
	if k == "cap_fimp" or k == "cap_fexp" then return { segment_amount(rec.tank) } end
	if k == "pair" and rec.machine and rec.machine.valid then
		local m = rec.machine
		return { inv_total(m, defines.inventory.crafter_input), inv_total(m, defines.inventory.crafter_output),
			m.products_finished, m.crafting_progress > 0 and 1 or 0 }
	end
	if k == "imp_tank" or k == "exp_tank" or k == "iface_fin" or k == "iface_fout" then
		return { rec.tank and rec.tank.valid and segment_amount(rec.tank) or 0 }
	end
	if k == "iface_items" then
		local inv = rec.iface and rec.iface.valid and rec.iface.get_inventory(defines.inventory.chest)
		local row = inv and inv.get_item_count(rec.out_item) or 0
		local all = inv and inv.get_item_count() or 0
		return { inv_total(rec.src), hand(rec.ins), all - row, inv_total(rec.sink), hand(rec.eins), row }
	end
	return nil
end

local function moved(rec, a, c)
	local k = rec.kind
	if k == "imp_chest" or k == "cap_imp" then return { items_in = a[1] - c[1] } end
	if k == "exp_chest" or k == "cap_exp" then return { items_out = c[1] - a[1] } end
	if k == "cap_fimp" then return { fluid_in = a[1] - c[1] } end
	if k == "cap_fexp" then return { fluid_out = c[1] - a[1] } end
	if k == "pair" then
		local r = prototypes.recipe[rec.recipe]
		local started = (c[3] - a[3]) + c[4] - a[4]
		return { items_out = (c[1] - a[1]) + started * r.ingredients[1].amount,
			items_in = (c[3] - a[3]) * r.products[1].amount - (c[2] - a[2]) }
	end
	if k == "imp_tank" or k == "iface_fin" then return { fluid_in = a[1] - c[1] } end
	if k == "exp_tank" or k == "iface_fout" then return { fluid_out = c[1] - a[1] } end
	if k == "iface_items" then
		return { items_in = (a[1] - c[1]) - (c[2] - a[2]) - (c[3] - a[3]), items_out = (c[4] - a[4]) + (c[5] - a[5]) + (c[6] - a[6]) }
	end
	return {}
end

--- sources full, sinks empty at the start of the window (before the count, so the conservation check sees it)
local function refill(b)
	if C.idle then return end
	for _, rec in ipairs(b.slots) do
		local k = rec.kind
		if (k == "imp_chest" or k == "cap_imp") and rec.chest and rec.chest.valid then
			local inv = rec.chest.get_inventory(defines.inventory.chest)
			if rec.item then inv.insert{ name = rec.item, count = prototypes.item[rec.item].stack_size * #inv } end
		elseif (k == "exp_chest" or k == "cap_exp") and rec.chest and rec.chest.valid then
			rec.chest.get_inventory(defines.inventory.chest).clear()
		elseif k == "iface_items" then
			if rec.src and rec.src.valid and rec.src_item then
				local inv = rec.src.get_inventory(defines.inventory.chest)
				inv.insert{ name = rec.src_item, count = prototypes.item[rec.src_item].stack_size * #inv }
			end
			if rec.sink and rec.sink.valid then rec.sink.get_inventory(defines.inventory.chest).clear() end
		elseif (k == "imp_tank" or k == "iface_fin" or k == "cap_fimp") and rec.tank and rec.tank.valid and rec.fluid then
			rec.tank.insert_fluid{ name = rec.fluid, amount = rec.tank.fluidbox.get_capacity(1) }
		elseif (k == "exp_tank" or k == "iface_fout" or k == "cap_fexp") and rec.tank and rec.tank.valid then
			local held = rec.tank.fluidbox[1]
			if held then rec.tank.remove_fluid{ name = held.name, amount = segment_amount(rec.tank) + 1 } end
		end
	end
end

--- the cells: how many, how many can take a new item type, how full in bytes
local function cell_stats(b)
	local spec = prototypes.mod_data["fork-me-network"].data.cells
	local n, open, bytes, total = 0, 0, 0, 0
	for _, d in pairs(b.drives or {}) do
		if d.valid then
			for _, cell in pairs(remote.call(NET, "drive", d)) do
				local sp = spec[cell.name]
				if sp and not sp.kind then
					n = n + 1
					bytes, total = bytes + cell.bytes, total + cell.bytes_total
					if cell.types < cell.types_total and cell.bytes_total - cell.bytes > sp.per_type then open = open + 1 end
				end
			end
		end
	end
	return { cells = n, open = open, bytes_used = total > 0 and bytes / total or 0 }
end

local function probe_me(b)
	local p = { tick = game.tick, world = count_world(), crafted = crafted(), slots = {}, cells = cell_stats(b) }
	for i, rec in ipairs(b.slots) do p.slots[i] = slot_state(rec) end
	return p
end

local function report_me(b, p0, p1)
	local secs = (p1.tick - p0.tick) / 60
	local cat, dry = {}, {}
	local endpoints = { imp_chest = 1, exp_chest = 1, pair = 2, imp_tank = 1, exp_tank = 1, iface_items = 1, iface_fin = 1,
		iface_fout = 1, cap_imp = 1, cap_exp = 1, cap_fimp = 1, cap_fexp = 1 }
	local total = { items_in = 0, items_out = 0, fluid_in = 0, fluid_out = 0 }
	for i, rec in ipairs(b.slots) do
		local a, c = p0.slots[i], p1.slots[i]
		if a and c then
			local mv = moved(rec, a, c)
			local t = cat[rec.kind] or { endpoints = 0 }
			cat[rec.kind] = t
			t.endpoints = t.endpoints + (endpoints[rec.kind] or 1)
			for key, v in pairs(mv) do
				t[key] = (t[key] or 0) + v
				total[key] = total[key] + v
			end
			--- a source that ran out or a sink that filled up in the window: its endpoint moved less than it could
			local k = rec.kind
			if ((k == "imp_chest" or k == "cap_imp" or k == "iface_items") and c[1] < 100)
				or ((k == "imp_tank" or k == "iface_fin" or k == "cap_fimp") and c[1] < 100)
				or (k == "exp_chest" and rec.chest and rec.chest.valid
					and not rec.chest.get_inventory(defines.inventory.chest).can_insert{ name = rec.filters[1] })
				or ((k == "exp_tank" or k == "iface_fout") and c[1] > 24900) then
				dry[k] = (dry[k] or 0) + 1
			end
		end
	end
	local out = { seconds = secs, categories = {}, dry_sources = dry }
	local n_end = 0
	for kind, t in pairs(cat) do
		n_end = n_end + t.endpoints
		local row = { endpoints = t.endpoints }
		for key, v in pairs(t) do
			if key ~= "endpoints" then
				row[key .. "_per_s"] = v / secs
				row[key .. "_per_s_per_endpoint"] = v / secs / t.endpoints
			end
		end
		out.categories[kind] = row
	end
	out.endpoints = n_end
	out.items_per_s = (total.items_in + total.items_out) / secs
	out.fluid_per_s = (total.fluid_in + total.fluid_out) / secs
	out.items_per_s_per_endpoint = out.items_per_s / math.max(1, n_end)
	--- autocrafting: crafts of the providers' machines
	local crafts = 0
	for _, rec in ipairs(b.slots) do
		if (rec.kind == "provider" or rec.kind == "lat_provider") and rec.machine and rec.machine.valid then
			local v0, v1 = p0.crafted[rec.machine.unit_number], p1.crafted[rec.machine.unit_number]
			if v0 and v1 then crafts = crafts + (v1[1] - v0[1]) end
		end
	end
	out.provider_crafts_per_s = crafts / secs
	out.cells_before, out.cells_after = p0.cells, p1.cells
	local checked, bad = conservation(p0.world, p1.world, production(p0.crafted, p1.crafted))
	out.conservation = { keys = checked, problems = #bad, first = { bad[1], bad[2], bad[3], bad[4], bad[5] } }
	return out
end

--- the scene's machines at the second probe: how many work, wait for ingredients or have a full output, and the
--- crafts they made against what their speed allowed in the window (`utilisation`)
local function machine_report(b, p0, p1)
	local secs = (p1.tick - p0.tick) / 60
	local out = {}
	for _, rec in ipairs(b.slots) do
		local m = (rec.kind == "pair" or rec.kind == "provider" or rec.kind == "lat_provider") and rec.machine
		if m and m.valid then
			local group = rec.kind == "pair" and "pair" or "provider"
			local t = out[group] or { n = 0, working = 0, no_ingredients = 0, full_output = 0, other = 0, crafts = 0, possible = 0 }
			out[group] = t
			t.n = t.n + 1
			local st = m.status
			if st == STATUS.working then t.working = t.working + 1
			elseif st == STATUS.item_ingredient_shortage or st == STATUS.no_ingredients or st == STATUS.fluid_ingredient_shortage then
				t.no_ingredients = t.no_ingredients + 1
			elseif st == STATUS.full_output then t.full_output = t.full_output + 1
			else t.other = t.other + 1 end
			local r = m.get_recipe()
			if r then
				local v0, v1 = p0.crafted[m.unit_number], p1.crafted[m.unit_number]
				if v0 and v1 then t.crafts = t.crafts + (v1[1] - v0[1]) end
				t.possible = t.possible + secs * m.crafting_speed / r.energy
			end
		end
	end
	for _, t in pairs(out) do t.utilisation = t.possible > 0 and t.crafts / t.possible or 0 end
	return out
end

--- the service quality of the window: the scheduler's counters since the first probe, the backlogs sampled every
--- SAMPLE_TICKS, the blocks' states now (busy, probing, parked and why: issue #38), the machines, the mod's Lua heap
local function service_report(b, p0, p1)
	local sched = sched_stats(true)
	local steady
	if b.steady0 and sched and sched.io then
		steady = { starved = (sched.io.starved or 0) - b.steady0, ticks = game.tick - b.steady_tick }
	end
	return { sched = sched, io_steady = steady, backlog_samples = b.samples or {}, blocks = backlogs(), machines = machine_report(b, p0, p1),
		memory_kb = mod_memory_kb(), own_memory_kb = collectgarbage("count"), live_kb = mod_memory_kb(true) }
end

--- a slice of the long run: the heap, the counters (not reset) and the backlogs now
local function slice_report(b)
	log_json("SLICE", { tick = game.tick, memory_kb = mod_memory_kb(), own_memory_kb = collectgarbage("count"),
		backlogs = backlogs(), sched = sched_stats(false) })
end

--------------------------------------------------------------------------------
--- reference scenes: inserters, robots
--------------------------------------------------------------------------------

local function build_inserters()
	local b = storage.b
	research_all(game.forces.player)
	local n = C.size
	local per_row = 200
	local rows = math.ceil(n / per_row)
	new_surface(per_row + 16, rows * 5 + 16)
	b.slots = {}
	for r = 0, rows - 1 do
		local y = Y0 + r * 5
		power_row(y + 3, X0, X0 + per_row + 2)
		for j = 0, per_row - 1 do
			local i = r * per_row + j
			if i >= n then break end
			local kind = i % 2 == 0 and "bulk-inserter" or "fast-inserter"
			local rec = { kind = kind }
			rec.src = place("steel-chest", p1(X0 + j, y))
			if rec.src then chest_fill(rec.src, RAW[rand(#RAW)], 48) end
			rec.ins = inserter(kind, X0 + j, y + 1, defines.direction.north)
			rec.sink = place("steel-chest", p1(X0 + j, y + 2))
			b.slots[#b.slots + 1] = rec
		end
	end
	log_json("SETUP", { scene = "inserters", size = n, entities = #surface().find_entities_filtered{}, fails = fails })
end

local function build_robots()
	local b = storage.b
	local force = game.forces.player
	research_all(force)
	local pairs_n = math.max(10, math.floor(C.size / 10))
	local per_row = 100
	local rows = math.ceil(pairs_n / per_row)
	new_surface(per_row * 2 + 32, rows * 40 + 32)
	b.slots = {}
	local robots = 0
	for r = 0, rows - 1 do
		local y = Y0 + r * 40
		power_row(y + 4, X0, X0 + per_row * 2 + 2)
		power_row(y + 20, X0, X0 + per_row * 2 + 2)
		for x = X0 + 10, X0 + per_row * 2, 40 do
			local port = place("roboport", x + 1, y + 13)
			if port then
				port.insert{ name = "logistic-robot", count = 50 }
				robots = robots + 50
			end
		end
		for j = 0, per_row - 1 do
			local i = r * per_row + j
			if i >= pairs_n then break end
			local item = RAW[rand(#RAW)]
			local rec = { kind = "robots" }
			rec.req = place("requester-chest", p1(X0 + 2 * j, y))
			if rec.req then
				local sec = rec.req.get_logistic_sections().add_section()
				sec.set_slot(1, { value = { name = item, quality = "normal" }, min = 1000 })
			end
			rec.ins = inserter("bulk-inserter", X0 + 2 * j, y + 1, defines.direction.north)
			rec.sink = place("steel-chest", p1(X0 + 2 * j, y + 2))
			rec.prov = place("passive-provider-chest", p1(X0 + 2 * j, y + 26))
			if rec.prov then chest_fill(rec.prov, item, 48) end
			b.slots[#b.slots + 1] = rec
		end
	end
	log_json("SETUP", { scene = "robots", size = C.size, pairs = pairs_n, robots = robots,
		entities = #surface().find_entities_filtered{}, fails = fails })
end

local function probe_native(b)
	local p = { tick = game.tick, world = count_world(), slots = {} }
	for i, rec in ipairs(b.slots) do
		if rec.kind == "robots" then
			p.slots[i] = { inv_total(rec.req) + inv_total(rec.sink) + hand(rec.ins) }
		else
			p.slots[i] = { inv_total(rec.sink) + hand(rec.ins) }
		end
	end
	return p
end

local function report_native(b, p0, p1)
	local secs = (p1.tick - p0.tick) / 60
	local by = {}
	for i, rec in ipairs(b.slots) do
		local t = by[rec.kind] or { n = 0, items = 0 }
		by[rec.kind] = t
		t.n = t.n + 1
		t.items = t.items + (p1.slots[i][1] - p0.slots[i][1])
	end
	local out = { seconds = secs, categories = {} }
	local total, n = 0, 0
	for kind, t in pairs(by) do
		out.categories[kind] = { endpoints = t.n, items_per_s = t.items / secs, items_per_s_per_endpoint = t.items / secs / t.n }
		total, n = total + t.items, n + t.n
	end
	out.items_per_s = total / secs
	out.items_per_s_per_endpoint = total / secs / math.max(1, n)
	out.endpoints = n
	local checked, bad = conservation(p0.world, p1.world, {})
	out.conservation = { keys = checked, problems = #bad, first = { bad[1], bad[2], bad[3], bad[4], bad[5] } }
	return out
end

--------------------------------------------------------------------------------
--- planner scene: every usable recipe as a processing pattern, the planner timed on the deepest items
--------------------------------------------------------------------------------

local function res_key(e) return e.type == "fluid" and ("fluid/" .. e.name) or e.name end

--- The recipes the planner gets as processing patterns: enabled, not hidden, no recycling, at most 9 inputs and 6
--- outputs, whole products without a chance. Each gets the depth of its main product: raw keys (nothing makes them)
--- are 0, a product is one more than its deepest input; a recipe that is not on a shortest path of its main product
--- (loops, roundabout ways) is left out, so the trees are deep but finite.
local function planner_recipes(force)
	local R = {}
	for name, r in pairs(prototypes.recipe) do
		local fr = force.recipes[name]
		if fr and fr.enabled and not r.hidden and r.category ~= "recycling" and not name:find("%-recycling$")
			and #r.ingredients > 0 and #r.ingredients <= 9 and #r.products > 0 and #r.products <= 6 then
			local ok, ins, outs, inset = true, {}, {}, {}
			--- (items with own data, the cells and patterns, are never stored by name: no pattern names them)
			local function tagged(e) return e.type == "item" and prototypes.item[e.name] and prototypes.item[e.name].type == "item-with-tags" end
			for _, i in pairs(r.ingredients) do
				if tagged(i) then ok = false end
				ins[#ins + 1] = { key = res_key(i), amount = i.amount }
				inset[res_key(i)] = true
			end
			for _, pr in pairs(r.products) do
				local amt = pr.amount or ((pr.amount_min or 0) + (pr.amount_max or 0)) / 2
				if (pr.probability or 1) < 1 or amt <= 0 or (pr.type == "item" and amt ~= math.floor(amt)) or inset[res_key(pr)] or tagged(pr) then ok = false end
				outs[#outs + 1] = { key = res_key(pr), amount = amt }
			end
			if ok then
				local main = r.main_product and res_key(r.main_product) or outs[1].key
				R[#R + 1] = { name = name, inputs = ins, outputs = outs, main = main }
			end
		end
	end
	table.sort(R, function(a, c) return a.name < c.name end)
	--- depths
	local produced, depth = {}, {}
	for _, r in ipairs(R) do for _, o in ipairs(r.outputs) do produced[o.key] = true end end
	for _, r in ipairs(R) do for _, i in ipairs(r.inputs) do if not produced[i.key] then depth[i.key] = 0 end end end
	for _ = 1, 2 do                                  -- the second pass: keys only loops make (water) count as raw
		local changed = true
		while changed do
			changed = false
			for _, r in ipairs(R) do
				local d, ok = 0, true
				for _, i in ipairs(r.inputs) do
					local di = depth[i.key]
					if not di then ok = false break end
					if di > d then d = di end
				end
				if ok then
					for _, o in ipairs(r.outputs) do
						if not depth[o.key] or depth[o.key] > d + 1 then
							depth[o.key] = d + 1
							changed = true
						end
					end
				end
			end
		end
		for _, r in ipairs(R) do for _, i in ipairs(r.inputs) do if not depth[i.key] then depth[i.key] = 0 end end end
	end
	local kept, max_depth, items = {}, 0, {}
	for _, r in ipairs(R) do
		local d = 0
		for _, i in ipairs(r.inputs) do if depth[i.key] > d then d = depth[i.key] end end
		if depth[r.main] == d + 1 then
			kept[#kept + 1] = r
			items[r.main] = depth[r.main]
			if d + 1 > max_depth then max_depth = d + 1 end
		end
	end
	local raw = {}
	for _, r in ipairs(kept) do for _, i in ipairs(r.inputs) do if depth[i.key] == 0 then raw[i.key] = true end end end
	return kept, items, raw, max_depth, #R
end

--- cells holding `amount` of every key in `keys` (items; fluids into fluid cells)
local function stock_cells(keys, amount, fluid)
	local spec = prototypes.mod_data["fork-me-network"].data.cells[fluid and "me-256k-fluid-storage-cell" or "me-256k-storage-cell"]
	local per_byte = spec.per_byte or 8
	local cells, cur = {}, nil
	for _, key in ipairs(keys) do
		local need = spec.per_type + math.ceil(amount / per_byte)
		if not cur or cur.types >= spec.types or cur.bytes + need > spec.bytes then
			cur = { items = {}, bytes = 0, types = 0 }
			cells[#cells + 1] = cur
		end
		cur.items[key] = amount
		cur.types, cur.bytes = cur.types + 1, cur.bytes + need
	end
	local out = {}
	for i, c in ipairs(cells) do out[i] = c.items end
	return out
end

--- The machine prototype that makes recipe `name` as a crafting pattern: an assembling machine with the recipe's
--- category, no other fixed recipe and enough fluid boxes (inputs and outputs, none of both kinds), the first by
--- name. nil for a recipe without fluids: a processing pattern next to a chest does for it.
local machine_cache = {}
local function machine_for(name)
	local proto = prototypes.recipe[name]
	local fin, fout = 0, 0
	for _, i in pairs(proto.ingredients) do if i.type == "fluid" then fin = fin + 1 end end
	for _, pr in pairs(proto.products) do if pr.type == "fluid" then fout = fout + 1 end end
	if fin + fout == 0 then return nil end
	local key = proto.category .. ":" .. fin .. ":" .. fout
	if machine_cache[key] ~= nil then return machine_cache[key] or nil end
	local names = {}
	for ename, m in pairs(prototypes.entity) do
		if m.type == "assembling-machine" and not m.hidden and m.crafting_categories[proto.category]
			and (not m.fixed_recipe or m.fixed_recipe == "" or m.fixed_recipe == name) then
			names[#names + 1] = ename
		end
	end
	table.sort(names)
	local found = false
	for _, ename in ipairs(names) do
		local m = prototypes.entity[ename]
		local ins, outs, bad = 0, 0, false
		for _, fb in ipairs(m.fluidbox_prototypes or {}) do
			if fb.production_type == "input" then ins = ins + 1
			elseif fb.production_type == "output" then outs = outs + 1
			elseif fb.production_type == "input-output" then bad = true end
		end
		if not bad and ins >= fin and outs >= fout then
			found = ename
			break
		end
	end
	machine_cache[key] = found
	return found or nil
end

local function footprint(ename)
	local box = prototypes.entity[ename].collision_box
	return math.ceil(box.right_bottom.x - box.left_top.x - 0.01), math.ceil(box.right_bottom.y - box.left_top.y - 0.01)
end

local function build_planner()
	local b = storage.b
	local force = game.forces.player
	research_all(force)
	local recipes, items, raw, max_depth, usable = planner_recipes(force)
	local raw_items, raw_fluids = {}, {}
	for key in pairs(raw) do
		if key:find("^fluid/") then raw_fluids[#raw_fluids + 1] = key else raw_items[#raw_items + 1] = key end
	end
	table.sort(raw_items)
	table.sort(raw_fluids)
	--- the deepest items as targets (a key the planner can make from the patterns)
	local deep = {}
	for key, d in pairs(items) do
		if not key:find("^fluid/") and prototypes.item[key] then deep[#deep + 1] = { key = key, depth = d } end
	end
	table.sort(deep, function(a, c) if a.depth ~= c.depth then return a.depth > c.depth end return a.key < c.key end)
	b.targets = {}
	for i = 1, math.min(C.planner_targets or 5, #deep) do b.targets[i] = deep[i] end
	--- recipes without fluids: processing patterns at a chest; with fluids: crafting patterns at a machine of the
	--- recipe's category (grouped by machine); without a machine: left out
	local chest_recipes, by_machine, machine_names, no_machine = {}, {}, {}, {}
	for _, r in ipairs(recipes) do
		local m = machine_for(r.name)
		local fluids = false
		for _, i in ipairs(r.inputs) do if i.key:find("^fluid/") then fluids = true end end
		for _, o in ipairs(r.outputs) do if o.key:find("^fluid/") then fluids = true end end
		if not fluids then chest_recipes[#chest_recipes + 1] = r
		elseif m then
			if not by_machine[m] then
				by_machine[m] = {}
				machine_names[#machine_names + 1] = m
			end
			by_machine[m][#by_machine[m] + 1] = r
		else
			no_machine[#no_machine + 1] = r.name
		end
	end
	table.sort(machine_names)
	--- the layout: rows of providers along cable rows; chest rows (3 tiles per provider, 4 per row) first, then a
	--- row per machine kind (the machine north of its provider, touching it; w + 1 tiles per provider, h + 3 per row)
	local per_row = 100
	local plan = {}                                      -- { kind = "chest" | ename, recipes, providers, pitch, slot }
	local nprov = math.ceil(#chest_recipes / 9)
	for k = 1, math.ceil(nprov / per_row) do
		local first = (k - 1) * per_row * 9 + 1
		local list = {}
		for i = first, math.min(#chest_recipes, first + per_row * 9 - 1) do list[#list + 1] = chest_recipes[i] end
		plan[#plan + 1] = { kind = "chest", recipes = list, pitch = 4, slot = 3, w = 1, h = 1 }
	end
	for _, m in ipairs(machine_names) do
		local w, h = footprint(m)
		local list = by_machine[m]
		local n = math.ceil(#list / 9)
		for k = 1, math.ceil(n / per_row) do
			local first = (k - 1) * per_row * 9 + 1
			local part = {}
			for i = first, math.min(#list, first + per_row * 9 - 1) do part[#part + 1] = list[i] end
			plan[#plan + 1] = { kind = m, recipes = part, pitch = h + 3, slot = w + 1, w = w, h = h }
		end
	end
	local icells = stock_cells(raw_items, 1000000, false)
	local fcells = stock_cells(raw_fluids, 1000000, true)
	local idrives, fdrives = math.max(1, math.ceil(#icells / 10)), math.max(1, math.ceil(#fcells / 10))
	--- issue #50: spare drives for what the patterns name and the network cannot make (the products of patterns it cannot
	--- use as placed, of recipes with a chance): stocked after the patterns are in, so the deep plans complete
	local spare = PLANNER_SPARE_DRIVES
	local width = 0
	for _, row in ipairs(plan) do width = math.max(width, math.ceil(#row.recipes / 9) * row.slot) end
	width = width + 4 + 2 * (idrives + fdrives + spare)
	local height = 0
	for _, row in ipairs(plan) do height = height + row.pitch end
	new_surface(width + 16, math.max(height, 12) + 40)
	local members = {}
	local function member(e) if e then members[#members + 1] = e end return e end
	--- power: substations every 16 tiles above every cable row's north side
	local y = Y0
	for _, row in ipairs(plan) do
		power_row(y - row.h - 3, X0 - 4, X0 + width + 2)
		y = y + row.pitch
	end
	power_row(y + 2, X0 - 4, X0 + width + 2)
	for yy = Y0, math.max(y, Y0 + 6) do place("me-cable", p1(X0 - 1, yy)) end   -- the spine (down to the CPU rows)
	b.anchor = member(place("me-network-controller", X0 - 2, Y0 + 1))
	b.terminal = member(place("me-terminal", p1(X0 - 1, Y0 - 1)))   -- (the crafting tab's preview, issue #50)
	b.anchors = { b.anchor }
	b.cpus, b.slots = {}, {}
	for k = 0, 1 do
		local cy = Y0 + 3 + 2 * k
		b.cpus[#b.cpus + 1] = member(place("me-256k-crafting-storage", p1(X0 - 2, cy)))
		for dx = 3, 17 do member(place("me-256k-crafting-storage", p1(X0 - dx, cy))) end
		for dx = 18, 20 do member(place("me-crafting-co-processing-unit", p1(X0 - dx, cy))) end
	end
	b.providers, b.drives = {}, {}
	local machines = {}
	y = Y0
	for ri, row in ipairs(plan) do
		for x = X0, X0 + width - 1 do place("me-cable", p1(x, y)) end
		if ri == 1 then
			for i = 1, idrives + fdrives + spare do b.drives[#b.drives + 1] = member(place("me-drive", p1(X0 + 2 * i - 2, y + 1))) end
		end
		local x = X0 + 2 * (idrives + fdrives + spare) + 4
		row.providers = {}
		for i = 1, #row.recipes, 9 do
			local prov = member(place("me-pattern-provider", p1(x, y - 1)))
			if row.kind == "chest" then
				place("steel-chest", p1(x + 1, y - 1))                       -- the processing target next to the provider
			else
				--- the machine north of the provider, its bottom row of tiles touching the provider's tile
				local m = place(row.kind, x + 0.5, y - 1 - row.h / 2)
				if m then machines[row.kind] = (machines[row.kind] or 0) + 1 end
			end
			if prov then
				b.providers[#b.providers + 1] = prov
				row.providers[#row.providers + 1] = prov
			end
			x = x + row.slot
		end
		y = y + row.pitch
	end
	local prof = game.create_profiler()
	remote.call(NET, "rebuild")
	for _, e in ipairs(members) do script.raise_script_built{ entity = e } end
	prof.stop()
	log({ "", "DEVCHECK-BENCH-BUILD registered ", #members, " members: ", prof })
	for i, cell in ipairs(icells) do insert_cell(b.drives[math.floor((i - 1) / 10) + 1], "me-256k-storage-cell", cell, (i - 1) % 10 + 1) end
	for i, cell in ipairs(fcells) do insert_cell(b.drives[idrives + math.floor((i - 1) / 10) + 1], "me-256k-fluid-storage-cell", cell, (i - 1) % 10 + 1) end
	--- the patterns, 9 per provider
	local inv = game.create_inventory(2)
	local encoded, bad, processing, crafting = 0, 0, 0, 0
	for _, row in ipairs(plan) do
		for i, r in ipairs(row.recipes) do
			local prov = row.providers[math.floor((i - 1) / 9) + 1]
			if prov then
				inv.clear()
				inv.insert{ name = "me-blank-pattern", count = 1 }
				local def
				if row.kind == "chest" then
					def = { kind = "processing", inputs = r.inputs, outputs = r.outputs, recipe = r.name }
					processing = processing + 1
				else
					def = { kind = "crafting", recipe = r.name }
					crafting = crafting + 1
				end
				local where, why = remote.call(TERM, "encode_def", false, inv, false, def)
				local stack = inv.find_item_stack("me-encoded-pattern")
				if where and stack and remote.call(AC, "insert_pattern", prov, stack) then encoded = encoded + 1
				else
					bad = bad + 1
					if bad <= 5 then fail("pattern " .. r.name .. ": " .. tostring(why)) end
				end
			end
		end
	end
	inv.destroy()
	--- (what the network cannot make is stocked at the first probe, when the network has power: planner_stock)
	b.plan_recipes, b.plan_raw, b.plan_drive0 = recipes, raw, idrives + fdrives
	table.sort(no_machine)
	log_json("SETUP", { scene = "planner", size = C.size, recipes = #recipes, usable_recipes = usable, encoded = encoded,
		processing = processing, crafting = crafting, no_machine = #no_machine, no_machine_first = { no_machine[1], no_machine[2], no_machine[3], no_machine[4], no_machine[5] },
		machines = machines, rejected = bad, items = table_size(items), raw_items = #raw_items, raw_fluids = #raw_fluids,
		max_depth = max_depth, depths = depths, providers = #b.providers, targets = b.targets,
		entities = #surface().find_entities_filtered{}, fails = fails })
end

--- issue #50: at the first probe (the network has power, the providers are scanned): every key a pattern needs that the
--- network can neither make nor holds goes into the spare drives, and the targets become the items with the longest
--- chain of patterns the network can use over its stock
local function planner_stock(b)
	local recipes, raw, idrives, fdrives = b.plan_recipes, b.plan_raw, b.plan_drive0, 0
	--- what the patterns need and the network cannot make: into the spare drives (items first, then fluids)
	local can = {}
	if recipes[1] then remote.call(AC, "plan", b.anchor, recipes[1].main, 1) end   -- (a fresh plan scans every provider)
	for _, key in ipairs(remote.call(AC, "craftable", b.anchor) or {}) do can[key] = true end
	--- a key is made when a pattern the network can use has it as its main product (a byproduct of another pattern does
	--- not count: the planner would walk that pattern's inputs, often in a loop)
	local makers = {}
	for _, r in ipairs(recipes) do
		if can[r.main] then
			makers[r.main] = makers[r.main] or {}
			table.insert(makers[r.main], r)
		end
	end
	local extra_items, extra_fluids, seen = {}, {}, {}
	for _, r in ipairs(recipes) do
		for _, i in ipairs(r.inputs) do
			local key = i.key
			if not raw[key] and not makers[key] and not seen[key] then
				seen[key] = true
				if key:find("^fluid/") then extra_fluids[#extra_fluids + 1] = key else extra_items[#extra_items + 1] = key end
			end
		end
	end
	table.sort(extra_items)
	table.sort(extra_fluids)
	local xi, xf = stock_cells(extra_items, 100000, false), stock_cells(extra_fluids, 100000, true)
	local slot = 0
	local function put_cell(name, cell)
		local d = b.drives[idrives + fdrives + math.floor(slot / 10) + 1]
		if d then insert_cell(d, name, cell, slot % 10 + 1) else fail("planner: no spare drive for a cell") end
		slot = slot + 1
	end
	for _, cell in ipairs(xi) do put_cell("me-256k-storage-cell", cell) end
	for _, cell in ipairs(xf) do put_cell("me-256k-fluid-storage-cell", cell) end
	--- the targets: the items with the longest chain of patterns the network can use over its stock (a stocked key is 0, a
	--- made key one more than the deepest input of its cheapest usable recipe), so their plans walk deep and complete
	local stocked = {}
	for key in pairs(raw) do stocked[key] = true end
	for key in pairs(seen) do stocked[key] = true end
	local chain, busy = {}, {}
	local function depth_of(key)
		if stocked[key] then return 0 end
		if chain[key] then return chain[key] end
		if busy[key] or not makers[key] then return math.huge end
		busy[key] = true
		local best = math.huge
		for _, r in ipairs(makers[key]) do
			local d = 0
			for _, i in ipairs(r.inputs) do d = math.max(d, depth_of(i.key)) end
			if d + 1 < best then best = d + 1 end
		end
		busy[key] = nil
		chain[key] = best
		return best
	end
	local deep = {}
	for key in pairs(makers) do
		local d = depth_of(key)
		if d < math.huge and not key:find("^fluid/") and prototypes.item[key] then deep[#deep + 1] = { key = key, depth = d } end
	end
	table.sort(deep, function(a, c) if a.depth ~= c.depth then return a.depth > c.depth end return a.key < c.key end)
	b.targets = {}
	for i = 1, math.min(C.planner_targets or 5, #deep) do b.targets[i] = deep[i] end
	--- the keys whose plans are compared between versions (bench --compare-plans): every item of the chain, at most PLAN_SAMPLE
	--- of them spread over the depths
	b.plan_sample = {}
	local step = math.max(1, math.floor(#deep / PLAN_SAMPLE))
	for i = 1, #deep, step do b.plan_sample[#b.plan_sample + 1] = deep[i].key end
	b.plan_recipes, b.plan_stocked = nil, seen
	for key in pairs(raw) do b.plan_stocked[key] = true end
	log_json("PLANSTOCK", { extra_items = #extra_items, extra_fluids = #extra_fluids,
		extra_first = { extra_items[1], extra_items[2], extra_fluids[1], extra_fluids[2] }, targets = b.targets, cells = #xi + #xf })
end

--- the planner on every target: five plans of 1 and of 100 timed (the providers scanned first, as the terminal
--- does), then one job of 10 started; the patterns the network cannot use, by reason
--- Issue #50: a plan as the crafting tab's preview makes it (the terminal's craft_preview: no provider rescan). The first call
--- for a key and amount (nothing kept: a fresh plan) and the mean of five more (a refresh while nothing changed). Logged as
--- DEVCHECK-BENCH-<tag> (the fresh one, with the plan) and DEVCHECK-BENCH-<tag>-KEPT.
local function time_preview(b, tag, t, amount, extra)
	local p = game.create_profiler()
	local pre = remote.call(TERM, "craft_preview", b.terminal, t.key, amount)
	p.stop()
	local q = game.create_profiler()
	for _ = 1, 5 do remote.call(TERM, "craft_preview", b.terminal, t.key, amount) end
	q.stop()
	q.divide(5)
	local status = pre.reason == "missing" and "missing" or (pre.reason == "no-pattern" and "no-pattern" or "ok")
	local missing, names = 0, {}
	for k in pairs(pre.missing or {}) do
		missing = missing + 1
		if #names < 4 then names[#names + 1] = k end
	end
	log({ "", "DEVCHECK-BENCH-" .. tag .. " ", t.key, " depth ", t.depth, " amount ", amount, " steps ", pre.steps or -1,
		" runs ", pre.runs or -1, " missing ", missing, " ", status, " ", p, " ", extra or table.concat(names, ",") })
	log({ "", "DEVCHECK-BENCH-" .. tag .. "-KEPT ", t.key, " amount ", amount, " ", q })
end

local function planner_probe(b)
	local started = {}
	for _, t in ipairs(b.targets) do
		for _, amount in ipairs({ 1, 100 }) do
			time_preview(b, "PLAN", t, amount)
			local p = remote.call(AC, "plan", b.anchor, t.key, amount, true)
			log("DEVCHECK-BENCH-PLAN-NODES " .. t.key .. " " .. amount .. " " .. tostring(p and p.nodes) .. " " .. tostring(p and p.too_complex))
		end
		--- issue #50: the same target failing: the first item the plan of 1 takes from storage that the network cannot make
		--- (raw or stocked) is withdrawn for the plans
		local ok_plan = remote.call(AC, "plan", b.anchor, t.key, 1)
		local keys = {}
		for k in pairs(ok_plan and ok_plan.reserve or {}) do
			if not k:find("^fluid/") and (b.plan_stocked or {})[k] then keys[#keys + 1] = k end
		end
		table.sort(keys)
		local gone, got
		for i = 1, math.min(#keys, 12) do               -- (the first whose absence makes the plan fail: some are byproducts too)
			local k = keys[i]
			local n = remote.call(NET, "extract", b.anchor, k, remote.call(NET, "count", b.anchor, k))
			local test = remote.call(AC, "plan", b.anchor, t.key, 1, true)
			if test and not test.ok then gone, got = k, n break end
			if n > 0 then remote.call(NET, "insert", b.anchor, k, n) end
		end
		if gone then
			for _, amount in ipairs({ 1, 100 }) do time_preview(b, "PLAN-FAIL", t, amount, "without " .. gone) end
			if got > 0 then remote.call(NET, "insert", b.anchor, gone, got) end
		end
		local p = game.create_profiler()
		local id, why = remote.call(AC, "start", b.anchor, t.key, 10)
		p.stop()
		log({ "", "DEVCHECK-BENCH-PLAN-START ", t.key, " ", id and "ok" or tostring(why), " ", p })
		--- (cancelled at once: the scene times the start; a running GregTech job holds fluid in machines the count misses)
		if id then remote.call(AC, "cancel", id) end
	end
	b.jobs = started
	log_json("JOBS", { started = #started, failed = {} })
	--- the plans of the sample, for bench --compare-plans: what the network would do (fresh plans, never a kept one)
	for _, key in ipairs(b.plan_sample or {}) do
		for _, amount in ipairs({ 1, 37 }) do
			local p = remote.call(AC, "plan", b.anchor, key, amount, true)
			local d = p and { ok = p.ok, missing = p.missing, reserve = p.reserve, pids = p.pids, runs = p.runs, steps = p.steps,
				loops = p.loops, bytes = p.bytes, no_pattern = p.no_pattern } or "nil"
			log("DEVCHECK-BENCH-PLANDIGEST " .. key .. " " .. amount .. " " .. serpent.line(d, { comment = false, sortkeys = true, numformat = "%.10g" }))
		end
	end
	--- issue #50, lever 6: what the scan finds at each provider (pattern id, ok, reason, machines per slot), for --compare-plans
	for i, prov in ipairs(b.providers or {}) do
		local info = prov.valid and remote.call(AC, "provider_info", prov)
		local d = {}
		for slot, sl in pairs(info and info.slots or {}) do d[slot] = { id = sl.id, ok = sl.ok, reason = sl.reason, machines = sl.machines } end
		log("DEVCHECK-BENCH-PLANDIGEST provider-" .. i .. " 0 " .. serpent.line(d, { comment = false, sortkeys = true }))
	end
	log_json("PLANNER", { ignored = remote.call(AC, "ignored", b.anchor) })
end

local function report_planner(b, p0, p1)
	local out = { seconds = (p1.tick - p0.tick) / 60, categories = {}, endpoints = 0, items_per_s = 0, items_per_s_per_endpoint = 0 }
	local jobs = {}
	for _, id in ipairs(b.jobs or {}) do
		local j = remote.call(AC, "job", id)
		if j then jobs[#jobs + 1] = { id = id, status = j.status, done = j.done, leases = j.leases } end
	end
	out.jobs = jobs
	local checked, bad = conservation(p0.world, p1.world, production(p0.crafted, p1.crafted))
	out.conservation = { keys = checked, problems = #bad, first = { bad[1], bad[2], bad[3], bad[4], bad[5] } }
	return out
end

--------------------------------------------------------------------------------
--- latency probes (scene "me", after the window): a storage bus sees a chest change, a maintainer reacts, its job
--- starts
--------------------------------------------------------------------------------

local function latency_start(b)
	local L = { start = game.tick, sb = {}, maint = {} }
	for _, chest in ipairs(b.sb_probe) do
		if chest.valid and chest.insert{ name = PROBE_ITEM, count = 1 } == 1 then L.sb[#L.sb + 1] = false end
	end
	for _, m in ipairs(b.lat_maint) do
		if m.entity.valid then
			local got = remote.call(NET, "extract", b.anchor, m.key, 10)
			L.maint[#L.maint + 1] = { entity = m.entity, key = m.key, extracted = got }
		end
	end
	b.L = L
end

local function median(list)
	if #list == 0 then return nil end
	table.sort(list)
	return list[math.floor((#list + 1) / 2)]
end

local function latency_tick(b)
	local L = b.L
	local t = game.tick - L.start
	local seen = remote.call(NET, "count", b.anchor, PROBE_ITEM)
	for i = 1, math.min(seen, #L.sb) do if not L.sb[i] then L.sb[i] = t end end
	local open = seen < #L.sb
	for _, m in ipairs(L.maint) do
		if not m.react then
			local info = remote.call(CIRC, "get_maintainer", m.entity)
			if info and info.job then m.react, m.job = t, info.job end
		end
		if m.react and not m.start then
			local j = remote.call(AC, "job", m.job)
			if not j or j.leases > 0 or j.done > 0 or j.status == "done" then m.start = t end
		end
		if not m.start then open = true end
	end
	if open and t < LATENCY_TIMEOUT then return false end
	local sb, react, start = {}, {}, {}
	for _, v in ipairs(L.sb) do sb[#sb + 1] = v or LATENCY_TIMEOUT end
	for _, m in ipairs(L.maint) do
		react[#react + 1] = m.react or LATENCY_TIMEOUT
		start[#start + 1] = (m.start and m.react) and (m.start - m.react) or LATENCY_TIMEOUT
	end
	local function stats(list)
		local mx = 0
		for _, v in ipairs(list) do mx = math.max(mx, v) end
		return { n = #list, median_s = (median(list) or 0) / 60, max_s = mx / 60, timeouts = (function()
			local k = 0 for _, v in ipairs(list) do if v >= LATENCY_TIMEOUT then k = k + 1 end end return k end)() }
	end
	log_json("LATENCY", { storage_bus = stats(sb), maintainer = stats(react), job_start = stats(start) })
	return true
end

--------------------------------------------------------------------------------
--- profile (an instrumented copy of the mod, devcheck.py bench --profile): the sections of the mod are timed by the
--- copy; this mod times single engine calls on the scene's entities
--------------------------------------------------------------------------------

local function time_it(name, n, f, out)
	local p = game.create_profiler()
	for i = 1, n do f(i) end
	p.stop()
	p.divide(n)
	log({ "", "DEVCHECK-BENCH-ENGINE ", name, " ", n, " ", p })
	out[#out + 1] = name
end

local function engine_profile(b)
	local s = surface()
	local out = {}
	local sb_chest, sb_tank, imp_chest, tank_bus
	for _, rec in ipairs(b.slots) do
		if rec.kind == "sb_chest" and not sb_chest then sb_chest = rec.chest end
		if rec.kind == "sb_tank" and not sb_tank and rec.tank and rec.tank.valid then
			sb_tank = rec.tank
			if segment_amount(sb_tank) <= 0 then sb_tank.insert_fluid{ name = "water", amount = 5000 } end
		end
		if rec.kind == "imp_chest" and not imp_chest and rec.chest and rec.chest.valid and rec.chest.get_item_count() > 0 then imp_chest = rec.chest end
		if rec.kind == "imp_tank" and not tank_bus then tank_bus = rec.bus end
	end
	if sb_chest then
		local inv = sb_chest.get_inventory(defines.inventory.chest)
		time_it("chest48.get_inventory", 2000, function() return sb_chest.get_inventory(defines.inventory.chest) end, out)
		time_it("chest48.get_contents", 2000, function() return inv.get_contents() end, out)
		time_it("inv.get_item_count{name}", 2000, function() return inv.get_item_count{ name = "iron-plate", quality = "normal" } end, out)
		time_it("inv.get_insertable_count{name}", 2000, function() return inv.get_insertable_count{ name = "iron-plate", quality = "normal" } end, out)
		time_it("inv.insert+remove 10", 1000, function()
			local k = inv.insert{ name = "iron-plate", count = 10 }
			if k > 0 then inv.remove{ name = "iron-plate", count = k } end
		end, out)
		time_it("inv[i] read + valid_for_read", 2000, function(i) local st = inv[(i % 48) + 1] return st.valid_for_read end, out)
		time_it("find_entities_filtered{position}", 2000, function() return s.find_entities_filtered{ position = sb_chest.position } end, out)
		time_it("entity.valid + direction", 2000, function() return sb_chest.valid and sb_chest.direction end, out)
	end
	if imp_chest then
		local inv = imp_chest.get_inventory(defines.inventory.chest)
		time_it("stack: prototype+spoil+item+health+tags (M.storable)", 2000, function(i)
			local st = inv[(i % 48) + 1]
			if st.valid_for_read then
				local proto = st.prototype
				local _ = proto.get_spoil_ticks(st.quality) > 0 or st.item or st.health < 1 or st.is_item_with_tags
			end
		end, out)
	end
	if sb_tank then
		local fb = sb_tank.fluidbox
		time_it("fluidbox[1] read", 2000, function() return fb[1] end, out)
		time_it("get_fluid_segment_id", 2000, function() return fb.get_fluid_segment_id(1) end, out)
		time_it("get_fluid_segment_contents", 2000, function() return fb.get_fluid_segment_contents(1) end, out)
		time_it("fluidbox.get_capacity", 2000, function() return fb.get_capacity(1) end, out)
		local f = fb[1] and fb[1].name or "water"
		time_it("insert_fluid+remove_fluid 100", 1000, function()
			local k = sb_tank.insert_fluid{ name = f, amount = 100 }
			if k > 0 then sb_tank.remove_fluid{ name = f, amount = k } end
		end, out)
	end
	--- a long fluid segment: a tank and 200 pipes (above the scene)
	local lx, ly = X0, -20
	s.request_to_generate_chunks({ lx + 100, ly }, 4)
	s.force_generate_chunk_requests()
	local tank = place("storage-tank", lx + 1.5, ly + 1.5)
	for i = 0, 199 do place("pipe", p1(lx + 3 + i, ly + 2)) end
	if tank then
		tank.insert_fluid{ name = "water", amount = 20000 }
		local fb = tank.fluidbox
		time_it("long segment: get_fluid_segment_contents", 2000, function() return fb.get_fluid_segment_contents(1) end, out)
		time_it("long segment: insert_fluid+remove_fluid 100", 1000, function()
			local k = tank.insert_fluid{ name = "water", amount = 100 }
			if k > 0 then tank.remove_fluid{ name = "water", amount = k } end
		end, out)
	end
	--- a big chest: 800 slots, 300 of them used
	local wh = place("zz-bench-warehouse", lx + 0.5, ly - 3.5)
	if wh then
		for i = 1, 30 do wh.insert{ name = RAW[(i - 1) % #RAW + 1], count = 1000 } end
		local inv = wh.get_inventory(defines.inventory.chest)
		time_it("chest800.get_contents", 1000, function() return inv.get_contents() end, out)
		time_it("chest800.get_item_count{name}", 2000, function() return inv.get_item_count{ name = "iron-plate", quality = "normal" } end, out)
		time_it("chest800.get_insertable_count{name}", 2000, function() return inv.get_insertable_count{ name = "iron-plate", quality = "normal" } end, out)
	end
	--- a circuit interface's section with 1000 signals
	local cc = place("constant-combinator", lx + 4.5, ly - 3.5)
	if cc then
		local sec = cc.get_or_create_control_behavior().add_section()
		local filters = {}
		local i = 0
		for name in pairs(prototypes.item) do
			i = i + 1
			if i > 1000 then break end
			filters[#filters + 1] = { value = { type = "item", name = name, quality = "normal", comparator = "=" }, min = i }
		end
		time_it("section.filters = " .. #filters .. " signals", 50, function() sec.filters = filters end, out)
		--- more signals: items in every quality
		local big = {}
		for _, q in ipairs({ "normal", "uncommon", "rare", "epic", "legendary" }) do
			for name in pairs(prototypes.item) do
				big[#big + 1] = { value = { type = "item", name = name, quality = q, comparator = "=" }, min = #big + 1 }
			end
		end
		for _, n in ipairs({ 100, 400, 700, 1000 }) do
			local part = {}
			for i = 1, math.min(n, #big) do part[i] = big[i] end
			time_it("section.filters = " .. #part .. " signals (qualities)", 20, function() sec.filters = part end, out)
		end
	end
	--- the storage API itself, inside the instrumented copy
	if remote.interfaces["zz-me-bench-profile"] and remote.interfaces["zz-me-bench-profile"].storage then
		local chest
		for _, rec in ipairs(b.slots) do
			if rec.kind == "exp_chest" and rec.chest and rec.chest.valid then chest = rec.chest break end
		end
		if chest then
			chest.get_inventory(defines.inventory.chest).clear()
			remote.call("zz-me-bench-profile", "storage", b.anchor, chest, "iron-plate", "water")
		end
	end
	--- one update of a circuit interface without and with a filter (a whole write, through the remote)
	for _, filtered in ipairs({ false, true }) do
		for _, rec in ipairs(b.slots) do
			if rec.kind == "circuit" and rec.circuit and rec.circuit.valid and rec.filtered == filtered then
				time_it("circuit interface update (" .. (filtered and "5 filters" or "no filter") .. ", remote)", 10,
					function() remote.call(CIRC, "update_circuit", rec.circuit) end, out)
				break
			end
		end
	end
	--- the remote call used by the latency probes, for scale
	time_it("remote.call count (empty work)", 2000, function() return remote.call(NET, "count", b.anchor, "iron-plate") end, out)
	--- issue #38: what the windows compute at a refresh (the GUI itself needs a player: not measured headless). A
	--- terminal on the spine (left of it, between the controller and the first CPU row).
	local term = s.create_entity{ name = "me-terminal", position = { X0 - 1.5, Y0 + 2.5 }, force = "player", raise_built = true }
	if term and term.valid then
		local job_key = b.job_keys and b.job_keys[1] and b.job_keys[1].key or "iron-gear-wheel"
		--- issue #50, lever 8: the first refresh (no last list), a refresh while nothing changed, and one after one amount
		--- changed (an iron plate in or out before each call; the insert's own 10 us are in it). Every line holds the remote's copy of
		--- the list it returns (a window calls the function without one): about what "nothing changed" costs with the kept lists.
		time_it("window: terminal entries (all, by count)", 20, function() return remote.call(TERM, "entries", term, "", "count", "all", true) end, out)
		time_it("window: terminal entries (items, by name)", 20, function() return remote.call(TERM, "entries", term, "", "name", "items", true) end, out)
		time_it("window: terminal entries (search 'iron')", 20, function() return remote.call(TERM, "entries", term, "iron", "count", "all", true) end, out)
		remote.call(TERM, "entries", term, "", "count", "all")
		time_it("window: terminal entries (all, by count), nothing changed", 20, function() return remote.call(TERM, "entries", term, "", "count", "all") end, out)
		time_it("window: terminal entries (all, by count), one amount changed", 20, function(i)
			if i % 2 == 1 then remote.call(NET, "insert", b.anchor, "iron-plate", 1) else remote.call(NET, "extract", b.anchor, "iron-plate", 1) end
			return remote.call(TERM, "entries", term, "", "count", "all")
		end, out)
		time_it("window: terminal craft preview (100)", 20, function() return remote.call(TERM, "craft_preview", term, job_key, 100) end, out)
		time_it("window: terminal jobs", 20, function() return remote.call(TERM, "jobs", term) end, out)
		time_it("window: terminal cells", 20, function() return remote.call(TERM, "cells", term) end, out)
	end
	local one = {}
	for _, rec in ipairs(b.slots) do
		local k = rec.kind
		if not one[k] then one[k] = rec end
	end
	if one.iface_items and one.iface_items.iface and one.iface_items.iface.valid then
		local e = one.iface_items.iface
		time_it("window: interface data (get_interface)", 100, function() return remote.call(IO, "get_interface", e) end, out)
	end
	if one.imp_chest and one.imp_chest.bus and one.imp_chest.bus.valid then
		local e = one.imp_chest.bus
		time_it("window: bus data (bus_info)", 100, function() return remote.call(IO, "bus_info", e) end, out)
	end
	if one.sb_chest and one.sb_chest.bus and one.sb_chest.bus.valid then
		local e = one.sb_chest.bus
		time_it("window: storage bus data (info)", 100, function() return remote.call(SB, "info", e) end, out)
	end
	if one.drive and one.drive.drive and one.drive.drive.valid then
		local e = one.drive.drive
		time_it("window: drive data (drive)", 100, function() return remote.call(NET, "drive", e) end, out)
	end
	if one.maint and one.maint.maint and one.maint.maint.valid then
		local e = one.maint.maint
		time_it("window: maintainer data (get_maintainer)", 100, function() return remote.call(CIRC, "get_maintainer", e) end, out)
	end
	if one.circuit and one.circuit.circuit and one.circuit.circuit.valid then
		local e = one.circuit.circuit
		time_it("window: circuit interface data (get_circuit)", 100, function() return remote.call(CIRC, "get_circuit", e) end, out)
	end
	if one.provider and one.provider.provider and one.provider.provider.valid then
		local e = one.provider.provider
		time_it("window: provider data (provider_info)", 100, function() return remote.call(AC, "provider_info", e) end, out)
	end
	if b.cpus and b.cpus[1] and b.cpus[1].valid and prototypes.entity["me-256k-crafting-storage"] then
		local e = b.cpus[1]
		time_it("window: crafting CPU data (group_info)", 100, function() return remote.call(AC, "group_info", e) end, out)
	end
	if b.anchor and b.anchor.valid then
		time_it("window: controller data (network)", 100, function() return remote.call(NET, "network", b.anchor) end, out)
	end
	--- what building and removing one block costs in this network (the graph recompute of a member)
	if tank_bus and tank_bus.valid then
		local x, y = X0 - 0.5, Y0 - 0.5                       -- above the spine's first cable
		local p = game.create_profiler()
		local e = surface().create_entity{ name = "me-import-bus", position = { x, y }, force = "player", raise_built = true,
			direction = defines.direction.north }
		p.stop()
		log({ "", "DEVCHECK-BENCH-ENGINE build one import bus (raise_built) 1 ", p })
		if e then
			p.reset()
			e.destroy{ raise_destroy = true }
			p.stop()
			log({ "", "DEVCHECK-BENCH-ENGINE remove one import bus (raise_destroy) 1 ", p })
		end
	end
	local p = game.create_profiler()
	remote.call(NET, "rebuild")
	p.stop()
	log({ "", "DEVCHECK-BENCH-ENGINE graph rebuild (on_configuration_changed) 1 ", p })
end

--------------------------------------------------------------------------------
--- build burst (issue #38): `C.burst` ME blocks built in one tick and removed in one tick, connected to the
--- network (a cable column from the spine's top up to a cable row; import and storage buses on chests north of the
--- row, interfaces south of it), then the same number of plain chests, each timed. The devcheck reads the ticks'
--- script time from the verbose log as well.
--------------------------------------------------------------------------------

local function burst_layout(n)
	local col = Y0 - 1 - (BURST_Y + 1) + 1                -- cables from (X0 - 1, Y0 - 1) up to (X0 - 1, BURST_Y + 1)
	local row = math.max(1, math.floor((n - col) / 3))     -- cable row, a bus per tile north, an interface per tile south
	return col, row
end

local function burst_build(b, n)
	local s = surface()
	local col, row = burst_layout(n)
	local made = {}
	for y = Y0 - 1, BURST_Y + 1, -1 do made[#made + 1] = s.create_entity{ name = "me-cable", position = { p1(X0 - 1, y) }, force = "player", raise_built = true } end
	for i = 0, row - 1 do made[#made + 1] = s.create_entity{ name = "me-cable", position = { p1(X0 - 1 + i, BURST_Y) }, force = "player", raise_built = true } end
	for i = 0, row - 1 do
		local name = i % 2 == 0 and "me-import-bus" or "me-storage-bus"
		made[#made + 1] = s.create_entity{ name = name, position = { p1(X0 - 1 + i, BURST_Y - 1) }, force = "player", direction = defines.direction.north, raise_built = true }
	end
	for i = 0, row - 1 do made[#made + 1] = s.create_entity{ name = "me-network-interface", position = { p1(X0 - 1 + i, BURST_Y + 1) }, force = "player", raise_built = true } end
	local out, kinds = {}, {}
	for _, e in ipairs(made) do
		if e and e.valid then
			out[#out + 1] = e
			kinds[e.name] = (kinds[e.name] or 0) + 1
		end
	end
	log("DEVCHECK-BENCH-BURST-KINDS " .. serpent.line(kinds) .. " of " .. #made .. " placed")
	return out
end

--- the wakes the scheduler has counted so far (the io queue): what a burst of builds or removals wakes
local function io_wakes()
	local st = sched_stats(false)
	return st and st.io and st.io.wakes or 0
end

local function burst_remove(list)
	local n = 0
	for _, e in ipairs(list) do
		if e.valid then
			e.destroy{ raise_destroy = true }
			n = n + 1
		end
	end
	return n
end

local function on_burst_tick()
	local b = storage.b
	local t = game.tick - b.burst_t0
	local n = C.burst
	local s = surface()
	if t == 1 then
		local col, row = burst_layout(n)
		s.request_to_generate_chunks({ X0 + row / 2, BURST_Y }, math.ceil(row / 64) + 2)
		s.force_generate_chunk_requests()
		b.burst_chests = {}
		for i = 0, row - 1 do                                -- the targets of the buses, plain entities, no event
			local c = place("steel-chest", p1(X0 - 1 + i, BURST_Y - 2))
			if c then
				chest_fill(c, RAW[i % #RAW + 1], 2)
				b.burst_chests[#b.burst_chests + 1] = c
			end
		end
	elseif t == 10 then
		local w0 = io_wakes()
		local p = game.create_profiler()
		b.burst_made = burst_build(b, n)
		p.stop()
		log({ "", "DEVCHECK-BENCH-BURST build ", #b.burst_made, " ", game.tick, " ", p })
		log("DEVCHECK-BENCH-BURST-WAKES build " .. (io_wakes() - w0))
	elseif t == 70 then
		local w0 = io_wakes()
		local prof = C.profile and remote.interfaces["zz-me-bench-profile"]
		if prof then remote.call("zz-me-bench-profile", "enable", false, C.exclusive) end    -- (profile run: the functions of the removal alone)
		local p = game.create_profiler()
		local k = burst_remove(b.burst_made)
		p.stop()
		if prof then
			log("DEVCHECK-BENCH-PROF-BURST remove")
			remote.call("zz-me-bench-profile", "report")
		end
		log({ "", "DEVCHECK-BENCH-BURST remove ", k, " ", game.tick, " ", p })
		log("DEVCHECK-BENCH-BURST-WAKES remove " .. (io_wakes() - w0))
		b.burst_made = nil
	elseif t == 130 then
		local p = game.create_profiler()
		local made = {}
		local col, row = burst_layout(n)
		local k = 0
		for y = 0, math.ceil(n / row) do
			for i = 0, row - 1 do
				if k < n then
					k = k + 1
					made[#made + 1] = s.create_entity{ name = "steel-chest", position = { p1(X0 - 1 + i, BURST_Y - 4 - y) }, force = "player", raise_built = true }
				end
			end
		end
		p.stop()
		b.burst_made = made
		log({ "", "DEVCHECK-BENCH-BURST plain-build ", #made, " ", game.tick, " ", p })
	elseif t == 190 then
		local p = game.create_profiler()
		local k = burst_remove(b.burst_made)
		p.stop()
		log({ "", "DEVCHECK-BENCH-BURST plain-remove ", k, " ", game.tick, " ", p })
		b.burst_made = nil
	elseif t >= 200 then
		b.phase = "done"
		script.on_event(defines.events.on_tick, nil)
		log("DEVCHECK-BENCH-DONE")
	end
end

local function finish(b)
	if C.burst and C.burst > 0 and C.scene == "me" and not C.noent then
		b.phase = "burst"
		b.burst_t0 = game.tick
		script.on_event(defines.events.on_tick, on_burst_tick)
	else
		b.phase = "done"
		script.on_event(defines.events.on_tick, nil)
		log("DEVCHECK-BENCH-DONE")
	end
end

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

local function on_latency_tick()
	local b = storage.b
	if latency_tick(b) then finish(b) end
end

script.on_init(function()
	storage.b = { phase = "warmup" }
	if C.scene == "me" then build_me()
	elseif C.scene == "planner" then build_planner()
	elseif C.scene == "inserters" then build_inserters()
	else build_robots() end
end)

script.on_load(function()
	if storage.b and storage.b.phase == "latency" then script.on_event(defines.events.on_tick, on_latency_tick)
	elseif storage.b and storage.b.phase == "burst" then script.on_event(defines.events.on_tick, on_burst_tick) end
end)



--- the probes: at `warmup` and at `warmup + window` (the window is a multiple of the warm-up)
local function start_jobs(b)
	b.jobs = {}
	local bad = {}
	for _, j in ipairs(b.job_keys or {}) do
		local id, why = remote.call(AC, "start", j.anchor, j.key, 5000)
		if id then b.jobs[#b.jobs + 1] = id else bad[#bad + 1] = j.key .. ": " .. tostring(why) end
	end
	--- a look at the first fluid import interface (its sides)
	for _, rec in ipairs(b.slots) do
		if rec.kind == "iface_fin" and rec.iface and rec.iface.valid then
			local info = remote.call(IO, "get_interface", rec.iface)
			log("DEVCHECK-BENCH-IFACE " .. serpent.line(info.fluids) .. " tank " .. segment_amount(rec.tank))
			break
		end
	end
	log_json("JOBS", { started = #b.jobs, failed = bad })
end

local function probe(b)
	if C.scene == "me" then return probe_me(b) end
	if C.scene == "planner" then return { tick = game.tick, world = count_world(), crafted = crafted(), slots = {} } end
	return probe_native(b)
end

--- warmup / 2: the jobs start; then the probes at `warmup` and at `warmup + window` (a multiple of the warm-up);
--- in between the backlogs are sampled every SAMPLE_TICKS and a SLICE logged every `slice` ticks
script.on_nth_tick(math.min(C.warmup / 2, SAMPLE_TICKS), function(event)
	local b = storage.b
	local tick = event.tick
	if tick == C.warmup / 2 and C.scene == "me" and not C.noent then
		start_jobs(b)
	elseif tick == C.warmup then
		if C.scene == "me" then refill(b) end
		if C.scene == "planner" then planner_stock(b) end           -- (before the count: the stock is part of the world)
		b.p0 = probe(b)
		if C.scene == "planner" then planner_probe(b) end
		sched_stats(true)                                     -- the counters start with the window
		b.samples = {}
		if C.profile and remote.interfaces["zz-me-bench-profile"] then remote.call("zz-me-bench-profile", "enable", C.alloc, C.exclusive) end
		log("DEVCHECK-BENCH-PROBE0 " .. game.tick)
	elseif tick == C.warmup + C.window then
		if C.profile and remote.interfaces["zz-me-bench-profile"] then remote.call("zz-me-bench-profile", "report") end
		local p1 = probe(b)
		log("DEVCHECK-BENCH-PROBE1 " .. game.tick)
		if C.scene == "me" then log_json("THROUGHPUT", report_me(b, b.p0, p1))
		elseif C.scene == "planner" then log_json("THROUGHPUT", report_planner(b, b.p0, p1))
		else log_json("THROUGHPUT", report_native(b, b.p0, p1)) end
		if C.scene == "me" or C.scene == "planner" then log_json("SERVICE", service_report(b, b.p0, p1)) end
		b.p0 = nil
		if C.profile and C.scene == "me" and not C.noent then engine_profile(b) end
		if C.scene == "me" and C.latency and not C.profile and not C.noent then
			latency_start(b)
			b.phase = "latency"
			script.on_event(defines.events.on_tick, on_latency_tick)
		else
			finish(b)
		end
	elseif C.scene == "me" and C.latency and not C.profile and tick == C.warmup + C.window + ALLOC_FROM then
		--- issue #115: the mod's own meter (what each of its tick handlers allocates) where it has one; Factorio collects between
		--- ticks even with the collector stopped, so the heap's growth (versions before it) is no measure at a small size
		local io = remote.interfaces[IO]
		if io and io.alloc_meter then
			remote.call(IO, "alloc_meter", true)
			b.alloc0, b.meter = 0, true
		else
			b.alloc0 = mod_memory_kb("stop")                  -- the collector stops: the heap grows by what the ticks allocate
		end
	elseif b.alloc0 and tick == C.warmup + C.window + ALLOC_FROM + ALLOC_TICKS then
		if b.meter then
			local kb = remote.call(IO, "alloc_meter", false)
			if kb then log_json("ALLOC", { kb_per_tick = kb / ALLOC_TICKS, ticks = ALLOC_TICKS, method = "meter" }) end
		else
			local kb = mod_memory_kb("restart")
			if kb then log_json("ALLOC", { heap_kb_per_tick = (kb - b.alloc0) / ALLOC_TICKS, ticks = ALLOC_TICKS, method = "heap" }) end
		end
		mod_memory_kb(true)                                   -- the garbage of the 300 ticks is collected now, not in the ticks that follow
		b.alloc0, b.meter = nil, nil
	elseif tick > C.warmup and tick < C.warmup + C.window then
		if tick == C.warmup + STEADY_TICKS and C.window > 2 * STEADY_TICKS then
			local st = sched_stats(false)
			b.steady0, b.steady_tick = st and st.io and st.io.starved or 0, tick
		end
		if tick % SAMPLE_TICKS == 0 and b.samples then
			local bl = backlogs()
			if bl then
				bl.tick = tick
				b.samples[#b.samples + 1] = bl
			end
		end
		if C.slice and (tick - C.warmup) % C.slice == 0 then slice_report(b) end
	end
end)
