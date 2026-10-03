--- Benchmark scenes of ME Network (tools/devcheck/devcheck.py bench). Never part of the mod.
---
--- config.lua (written by devcheck.py into the copy of this mod it runs) says which scene and size:
---   scene "me": a synthetic base of `size` buses and interfaces on one ME network (the mix below), with storage
---     buses (size / 10), pattern providers with running jobs (size / 25), level maintainers (size / 10), circuit
---     interfaces (size / 50) and drives with 256k cells that are about 70 % full and hold about 2000 item types.
---   scene "inserters": the same number of chest -> inserter -> chest lines (half fast, half bulk inserters).
---   scene "robots": size / 10 requester chests (each emptied by a bulk inserter) served by logistic robots from
---     passive provider chests.
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
local FLUIDS = { "water", "crude-oil", "petroleum-gas", "light-oil", "heavy-oil", "lubricant", "sulfuric-acid" }
--- raw materials: the network holds millions of them (exports, recipes of the patterns)
local RAW = { "iron-plate", "copper-plate", "steel-plate", "stone", "stone-brick", "wood", "coal", "plastic-bar",
	"iron-gear-wheel", "copper-cable", "electronic-circuit", "advanced-circuit", "iron-stick", "pipe", "engine-unit",
	"sulfur", "battery", "electric-engine-unit", "processing-unit", "concrete", "low-density-structure", "solid-fuel",
	"explosives", "rail" }
local PAIR_RECIPES = { "iron-gear-wheel", "copper-cable", "iron-stick", "pipe" }

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
	for cx = -1, math.ceil((w + 32) / 32) do
		for cy = -1, math.ceil((h + 32) / 32) do s.request_to_generate_chunks({ cx * 32 + 16, cy * 32 + 16 }, 0) end
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
	if b.anchor and b.anchor.valid then
		for _, j in pairs(remote.call(AC, "jobs", b.anchor)) do
			local job = remote.call(AC, "job", j.id)
			for key, n in pairs(job and job.pool or {}) do add(out, key, n) end
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
	}
	return m
end

--- the slot kinds spread evenly over the slots (largest remainder first, so every kind is everywhere)
local ORDER = { "imp_chest", "exp_chest", "pair", "imp_tank", "exp_tank", "cap_imp", "cap_exp", "cap_fimp", "cap_fexp",
	"iface_items", "iface_fin", "iface_fout",
	"sb_chest", "sb_tank", "provider", "maint", "circuit", "drive", "fdrive", "lat_provider", "lat_maint" }
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
local function pack_cells(ncells, fill, reserved)
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
		if plain(name) and not raw[name] and name ~= PROBE_ITEM and not reserved[name] then
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

local function build_me()
	local b = storage.b
	local force = game.forces.player
	force.research_all_technologies()
	local m = mix(C.size)
	local kinds = interleave(m)
	local spr = math.max(10, math.ceil(math.sqrt(#kinds) * 0.8))             -- slots per row and side
	local rows = math.ceil(#kinds / (2 * spr))
	local width, height = SLOT * spr, rows * PITCH
	new_surface(width + 16, height + 16)
	--- power: a row of substations above every cable row's north side and below its south side
	for r = 0, rows do power_row(Y0 - 6 + r * PITCH, X0 - 4, X0 + width + 2) end
	--- the spine, the controller and the CPUs on the left
	for y = Y0, Y0 + (rows - 1) * PITCH do place("me-cable", p1(X0 - 1, y)) end
	local members = {}
	local function member(e) if e then members[#members + 1] = e end return e end
	b.anchor = member(place("me-network-controller", X0 - 2, Y0 + 1))
	local recipes = pattern_recipes(force)
	if #recipes < LATENCY_RECIPES + 4 then fail("only " .. #recipes .. " pattern recipes") end
	local lat_recipes, reg_recipes = {}, {}
	for i, r in ipairs(recipes) do
		if i <= LATENCY_RECIPES then lat_recipes[#lat_recipes + 1] = r else reg_recipes[#reg_recipes + 1] = r end
	end
	local jobs = math.max(1, math.floor(m.provider / 4))
	b.cpus = {}
	local ncpu
	if prototypes.entity["me-256k-crafting-storage"] then
		--- issue #6: one multiblock CPU per job (and two spare), each a row of four blocks left of the spine (a 256k
		--- crafting storage and three co-processors: as fast as a quantum CPU), a free row between two CPUs
		ncpu = jobs + 2
		for k = 0, ncpu - 1 do
			local y = Y0 + 3 + 2 * k
			b.cpus[#b.cpus + 1] = member(place("me-256k-crafting-storage", p1(X0 - 2, y)))
			for dx = 3, 5 do member(place("me-crafting-co-processing-unit", p1(X0 - dx, y))) end
		end
	else                                                     -- (bench --from-ref of a version before issue #6)
		ncpu = math.ceil(jobs / 4) + 2
		for k = 0, ncpu - 1 do b.cpus[#b.cpus + 1] = member(place("me-quantum-crafting-cpu", X0 - 2, Y0 + 3 + 2 * k)) end
	end
	if Y0 + 3 + 2 * ncpu > Y0 + (rows - 1) * PITCH then fail("too many CPUs for the spine") end
	--- the slots
	b.slots, b.drives, b.count = {}, {}, {}
	local n, lat_i, prov_i = 0, 0, 0
	for r = 0, rows - 1 do
		local y0 = Y0 + r * PITCH
		for x = X0, X0 + width - 1 do place("me-cable", p1(x, y0)) end
		for _, s in ipairs({ -1, 1 }) do
			for j = 0, spr - 1 do
				n = n + 1
				local kind = kinds[n]
				if not kind then break end
				b.count[kind] = (b.count[kind] or 0) + 1
				local x = X0 + SLOT * j
				local by = y0 + s                                  -- the tile next to the cable
				local dir = s < 0 and defines.direction.north or defines.direction.south
				local back = s < 0 and defines.direction.south or defines.direction.north
				local cy = y0 + 3 * s                              -- center tile of a 3x3 target
				local rec = { kind = kind }
				b.slots[#b.slots + 1] = rec
				local item = RAW[rand(#RAW)]
				local fluid = FLUIDS[rand(#FLUIDS)]
				if kind == "imp_chest" then
					rec.bus = member(place("me-import-bus", x + 1.5, by + 0.5, dir))
					rec.chest = place("steel-chest", p1(x + 1, y0 + 2 * s))
					rec.item = item
					if rec.chest then chest_fill(rec.chest, item, 48) end
				elseif kind == "exp_chest" then
					rec.bus = member(place("me-export-bus", x + 1.5, by + 0.5, dir))
					rec.chest = place("steel-chest", p1(x + 1, y0 + 2 * s))
					rec.filters = { item }
				elseif kind == "pair" then
					local recipe = PAIR_RECIPES[rand(#PAIR_RECIPES)]
					rec.machine = place("assembling-machine-2", x + 1.5, cy + 0.5)
					if rec.machine then rec.machine.set_recipe(recipe) end
					rec.recipe = recipe
					rec.exp = member(place("me-export-bus", x + 0.5, by + 0.5, dir))
					rec.imp = member(place("me-import-bus", x + 2.5, by + 0.5, dir))
					rec.filters = { prototypes.recipe[recipe].ingredients[1].name }
				elseif kind == "cap_imp" or kind == "cap_exp" then
					rec.bus = member(place(kind == "cap_imp" and "me-import-bus" or "me-export-bus", x + 1.5, by + 0.5, dir))
					rec.chest = place("zz-bench-warehouse", p1(x + 1, y0 + 2 * s))
					rec.item = item
					rec.filters = { item }
				elseif kind == "cap_fimp" or kind == "cap_fexp" then
					rec.bus = member(place(kind == "cap_fimp" and "me-import-bus" or "me-export-bus", x + 1.5, by + 0.5, dir))
					rec.tank = place("zz-bench-big-tank", x + 1.5, cy + 0.5)
					rec.fluid = fluid
					rec.filters = { "fluid/" .. fluid }
				elseif kind == "imp_tank" or kind == "exp_tank" then
					rec.bus = member(place(kind == "imp_tank" and "me-import-bus" or "me-export-bus", x + 1.5, by + 0.5, dir))
					rec.tank = place("storage-tank", x + 1.5, cy + 0.5)
					if kind == "imp_tank" then rec.fluid = fluid end
					if kind == "imp_tank" and rec.tank then rec.tank.insert_fluid{ name = fluid, amount = 25000 } end
					rec.filters = kind == "exp_tank" and { "fluid/" .. fluid } or {}
				elseif kind == "iface_items" then
					local ix = x + 1
					rec.iface = member(place("me-network-interface", p1(ix, by)))
					rec.src = place("steel-chest", p1(ix, y0 + 3 * s))
					rec.src_item = RAW[rand(#RAW)]
					if rec.src then chest_fill(rec.src, rec.src_item, 48) end
					rec.ins = inserter("fast-inserter", ix, y0 + 2 * s, dir)      -- from the source chest into the interface
					rec.out_item = item
					rec.eins = inserter("fast-inserter", ix + 1, by, defines.direction.west)   -- from the interface east
					if rec.eins then
						rec.eins.use_filters = true
						rec.eins.set_filter(1, item)
					end
					rec.sink = place("steel-chest", p1(ix + 2, by))
				elseif kind == "iface_fin" or kind == "iface_fout" then
					--- the interface touches the tank's connection: north slots on the tank's south one, south slots
					--- on its north one
					local ix = s < 0 and x + 2 or x + 1
					local tx = s < 0 and ix - 1 or ix + 1
					rec.tank = place("storage-tank", tx + 0.5, cy + 0.5)
					rec.iface = member(place("me-network-interface", p1(ix, by)))
					rec.side = s < 0 and 1 or 3
					rec.fluid = fluid
					if kind == "iface_fin" and rec.tank then rec.tank.insert_fluid{ name = fluid, amount = 25000 } end
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
				end
			end
		end
	end
	--- the graph in one pass (the map scan of on_configuration_changed), then every module registers its blocks
	local prof = game.create_profiler()
	remote.call(NET, "rebuild")
	for _, e in ipairs(members) do script.raise_script_built{ entity = e } end
	prof.stop()
	log({ "", "DEVCHECK-BENCH-BUILD registered ", #members, " members: ", prof })
	--- cells: item drives about 70 % full, fluid drives
	local reserved = {}
	for _, r in ipairs(lat_recipes) do reserved[prototypes.recipe[r].products[1].name] = LATENCY_STOCK end
	local idrives, fdrives = {}, {}
	for _, rec in ipairs(b.slots) do
		if rec.kind == "drive" and rec.drive then idrives[#idrives + 1] = rec.drive end
		if rec.kind == "fdrive" and rec.drive then fdrives[#fdrives + 1] = rec.drive end
	end
	local cells, types = pack_cells(#idrives * 10, 0.7, reserved)
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
	lat_i = 0
	b.lat_maint, b.sb_probe = {}, {}
	for _, rec in ipairs(b.slots) do
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
			else b.sb_probe[#b.sb_probe + 1] = rec.chest end
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
	--- the storage bus probes: 20 chests spread over all (the buses are visited in unit order)
	local spread = {}
	for i = 1, math.min(20, #b.sb_probe) do spread[i] = b.sb_probe[math.floor((i - 1) * #b.sb_probe / math.min(20, #b.sb_probe)) + 1] end
	b.sb_probe = spread
	--- jobs on the providers (started at warmup / 2, when the controller has power): a quarter as many as
	--- providers, each for more than the run makes
	b.job_keys = {}
	for i = 1, jobs do
		b.job_keys[i] = prototypes.recipe[reg_recipes[(i - 1) % #reg_recipes + 1]].products[1].name
	end
	local net = remote.call(NET, "network", b.anchor)
	log_json("SETUP", { scene = "me", size = C.size, slots = #kinds, rows = rows, slots_per_row = 2 * spr, counts = b.count,
		members = net and net.members or 0, cells = net and net.cells or 0, fluid_cells = net and net.fluid_cells or 0,
		storage_buses = net and net.storage_buses or 0, fluid_storage_buses = net and net.fluid_storage_buses or 0,
		item_types = types, recipes = #reg_recipes, jobs = jobs, cpus = ncpu, network_ok = net and net.ok or false,
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

--------------------------------------------------------------------------------
--- reference scenes: inserters, robots
--------------------------------------------------------------------------------

local function build_inserters()
	local b = storage.b
	game.forces.player.research_all_technologies()
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
	force.research_all_technologies()
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
--- events
--------------------------------------------------------------------------------

local function on_latency_tick()
	local b = storage.b
	if latency_tick(b) then
		b.phase = "done"
		script.on_event(defines.events.on_tick, nil)
		log("DEVCHECK-BENCH-DONE")
	end
end

script.on_init(function()
	storage.b = { phase = "warmup" }
	if C.scene == "me" then build_me()
	elseif C.scene == "inserters" then build_inserters()
	else build_robots() end
end)

script.on_load(function()
	if storage.b and storage.b.phase == "latency" then script.on_event(defines.events.on_tick, on_latency_tick) end
end)

--- the probes: at `warmup` and at `warmup + window` (the window is a multiple of the warm-up)
local function start_jobs(b)
	b.jobs = {}
	local bad = {}
	for _, key in ipairs(b.job_keys or {}) do
		local id, why = remote.call(AC, "start", b.anchor, key, 5000)
		if id then b.jobs[#b.jobs + 1] = id else bad[#bad + 1] = key .. ": " .. tostring(why) end
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

--- warmup / 2: the jobs start; then the probes at `warmup` and at `warmup + window` (a multiple of the warm-up)
script.on_nth_tick(C.warmup / 2, function(event)
	local b = storage.b
	if event.tick == C.warmup / 2 and C.scene == "me" then
		start_jobs(b)
	elseif event.tick == C.warmup then
		if C.scene == "me" then refill(b) end
		b.p0 = C.scene == "me" and probe_me(b) or probe_native(b)
		if C.profile and remote.interfaces["zz-me-bench-profile"] then remote.call("zz-me-bench-profile", "enable") end
		log("DEVCHECK-BENCH-PROBE0 " .. game.tick)
	elseif event.tick == C.warmup + C.window then
		if C.profile and remote.interfaces["zz-me-bench-profile"] then remote.call("zz-me-bench-profile", "report") end
		local p1 = C.scene == "me" and probe_me(b) or probe_native(b)
		log("DEVCHECK-BENCH-PROBE1 " .. game.tick)
		log_json("THROUGHPUT", C.scene == "me" and report_me(b, b.p0, p1) or report_native(b, b.p0, p1))
		b.p0 = nil
		if C.profile and C.scene == "me" then engine_profile(b) end
		if C.scene == "me" and C.latency and not C.profile then
			latency_start(b)
			b.phase = "latency"
			script.on_event(defines.events.on_tick, on_latency_tick)
		else
			b.phase = "done"
			log("DEVCHECK-BENCH-DONE")
		end
	end
end)
