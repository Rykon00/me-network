--------------------------------------------------------------------------------
--- FORK AE2: AUTOCRAFTING (runtime, see prototypes/autocrafting.lua)
---
--- Patterns (issue #80, docs/AE2.md "Patterns", docs/ME-REWORK.md "Encoded patterns"): an ME Pattern Provider
---   holds up to 9 encoded patterns (scripts/fork-me-patterns.lua) in its slots; each one is a pattern of the ME
---   network the provider is connected to (scripts/fork-me-network.lua). The machines on the four tiles around
---   the provider do the work:
---   * a crafting pattern names a recipe: an assembling machine next to the provider that can make it is set to
---     that recipe for the hand-over (set_recipe; one machine serves many patterns, one at a time). A machine is
---     only switched when it is idle; what is left in it goes into the network first.
---   * a processing pattern has free inputs and outputs: the inputs are pushed into a machine next to the
---     provider (furnace, assembling machine with its own recipe) or into a chest next to it (the start of a
---     line). Outputs are taken from the machine's output, and outputs that come back into the network through
---     an import bus, an interface or the terminal are taken by the job that waits for them (arrivals, see
---     N.on_arrival), as in AE2.
---   Recipes with fluids work when the machine's fluid boxes are not connected to pipes (the network fills and
---   drains them). Patterns the network cannot use are counted per reason (see pattern_problem).
---   Several patterns for one output: by provider priority (higher first), then the provider built first, then the
---   slot; the planner takes the first one that needs nothing missing.
--- CPU: a Crafting CPU runs one job at a time, the bigger tiers (issue #38, mod-data
---   "fork-me-autocraft") several, and hand more work to the machines per step (speed). The job
---   slots of all CPUs in the network are the number of parallel jobs. Jobs wait ("queued") until a
---   slot is free.
--- Planning: recursive over the patterns, storage first, loops recognised, missing raw
---   materials reported before anything is started (M.plan). Items and fluids are both
---   "resources", keyed by the item name or "fluid/<name>" (fluid storage: fork-me-fluids.lua).
--- Job: at start the resources taken from storage are removed from the network into the job's own
---   pool (storage.fork_ae2.jobs[id].pool). Each step the CPU hands batches of ingredients
---   to idle pattern machines (machine.insert, fluid boxes set by index), waits until the machine
---   is idle again, moves the products into the pool, and at the end everything left in the pool
---   (result and by-products) is stored in the network. Cancel and failure give the pool back
---   the same way.
--- Work per step: STEP_OPS machine interactions per job (times the speed of its CPU tier), at most
---   MAX_OPS_PER_STEP in all, MAX_JOBS_PER_STEP jobs, PROVIDERS_PER_STEP provider rescans, and the
---   step hooks (level maintainers and circuit interfaces, scripts/fork-me-circuit.lua), one step
---   every STEP_TICKS ticks (15, 30 and 60 are used by the fluid storage, the molds and the terminal,
---   see control.lua).
--- State: storage.fork_ae2 only (entities, counts, plain data). GUI state lives in the GUI.
--------------------------------------------------------------------------------

local fluids = require("scripts.fork-me-fluids")
local N = require("scripts.fork-me-network")
local P = require("scripts.fork-me-patterns")

local M = {}

--- functions run at the end of every step (fork-me-circuit.lua); registered at load time, nothing is stored
M.step_hooks = {}
--- functions(bp, mapping) run when a blueprint is set up, after the providers are tagged
M.blueprint_hooks = {}

local STEP_TICKS = 20
local MAX_JOBS_PER_STEP = 8
local STEP_OPS = 6              -- machine hand-overs / collections per job and step (base CPU)
local MAX_OPS_PER_STEP = 96     -- all jobs together (4 quantum CPU jobs at full speed)
local MAX_BATCH = 16            -- crafts handed to one machine at once
local PROVIDERS_PER_STEP = 8
local STALL_STEPS = 900         -- steps without progress (5 minutes) until a job fails
local KEEP_FINISHED_TICKS = 5 * 60 * 60
local MAX_FINISHED = 12
local MAX_PLAN_NODES = 3000
local MAX_DEPTH = 40
local MAX_AMOUNT = 100000       -- items per job
local MAX_FLUID_AMOUNT = 10000000 -- fluid units per job
M.MAX_AMOUNT, M.MAX_FLUID_AMOUNT = MAX_AMOUNT, MAX_FLUID_AMOUNT
local QUALITY = "normal"        -- only normal quality items are planned and crafted
local FLUID_MARGIN = 0.01       -- extra fluid reserved per job and fluid (fixed point rounding)
local FLUID_EPS = 1e-6
local FIXED = 16777216          -- fluid amounts are fixed point with 24 fractional bits
local SLOTS = 9                 -- pattern slots of a provider (AE2)
local PATTERN_VERSION = 1       -- storage.fork_ae2.pattern_version: providers hold encoded patterns (issue #80)
M.SLOTS = SLOTS

local PROVIDER, CPU = "me-pattern-provider", "me-crafting-cpu"
local NEIGHBORS = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }
local TARGET_TYPES = { "assembling-machine", "furnace", "container", "logistic-container" }
local BP_TAG = "fork_me_provider"            -- blueprint tag: { priority, patterns = { ["slot"] = pattern } }
local OLD_TAG = "fork_ae2_recipe"            -- blueprint tag of 0.4.1 and older: the furnace recipe choice

--- CPU tiers: entity name -> { jobs, speed } (prototypes/autocrafting.lua)
local cpu_specs_cache                -- prototype data, read once per load (reading mod-data copies the table)
local function cpu_specs()
	if not cpu_specs_cache then
		local md = prototypes.mod_data["fork-me-autocraft"]
		cpu_specs_cache = md and md.data.cpus or { [CPU] = { jobs = 1, speed = 1 } }
	end
	return cpu_specs_cache
end

local function cpu_spec(name)
	return cpu_specs()[name]
end

local function cpu_names()
	local names = {}
	for name in pairs(cpu_specs()) do names[#names + 1] = name end
	table.sort(names)
	return names
end

--------------------------------------------------------------------------------
--- resource keys: item name, or "fluid/<name>" for fluids
--------------------------------------------------------------------------------

local FLUID_PREFIX = "fluid/"

local function key_of(ing)
	if ing.type == "fluid" then return FLUID_PREFIX .. ing.name end
	return ing.name
end

local function is_fluid(key)
	return key:sub(1, #FLUID_PREFIX) == FLUID_PREFIX
end

local function fluid_name(key)
	return key:sub(#FLUID_PREFIX + 1)
end

--- the prototype behind a key (LuaItemPrototype or LuaFluidPrototype), nil if none
local function proto_of(key)
	if is_fluid(key) then return prototypes.fluid[fluid_name(key)] end
	return prototypes.item[key]
end

M.key_of, M.is_fluid, M.fluid_name = key_of, is_fluid, fluid_name

--- the smallest fixed point amount that is not below `amount` (what a machine consumes per craft)
local function fixed_up(amount)
	return math.ceil(amount * FIXED) / FIXED
end

--------------------------------------------------------------------------------
--- state
--------------------------------------------------------------------------------

local function state()
	local s = storage.fork_ae2
	if not s then
		s = {
			providers = {},      -- unit_number -> provider record (see new_provider)
			plist = {},          -- unit numbers of providers (round robin for rescans)
			pcursor = 1,
			cpus = {},           -- unit_number -> { entity, jobs = { [job id] = true } } (older saves: job = id)
			jobs = {},           -- id -> job
			active = {},         -- ids of jobs that are not finished
			finished = {},       -- ids of finished jobs (oldest first)
			next_job = 1,
			jcursor = 1,
			busy = {},           -- machine unit_number -> job id
			patterns = {},       -- network id -> { items, defs, targets, ignored } (see rebuild_patterns)
			dirty = true,
			pattern_version = PATTERN_VERSION,
		}
		storage.fork_ae2 = s
	end
	return s
end

--- the level maintainers and circuit interfaces keep their records in the same table (fork-me-circuit.lua)
M.state = state

local function shallow_map(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
local function shallow(list) return { table.unpack(list) } end

local function remove_value(list, value)
	for i = #list, 1, -1 do
		if list[i] == value then table.remove(list, i) end
	end
end

--- the working ME network of an entity (nil when it is no member or the network is off)
local function network_of(entity)
	return N.active_of(entity)
end

--- store into the network without offering it to waiting jobs (a job's own pool, a machine emptied)
local function store_item(net, name, quality, count)
	N.no_arrival = true
	local n = N.insert(net, name, quality, count)
	N.no_arrival = false
	return n
end

local function store_fluid(net, name, amount)
	N.no_arrival = true
	local n = fluids.insert(net, name, amount)
	N.no_arrival = false
	return n
end

local function spill(entity, def)
	local inv = game.create_inventory(1)
	inv[1].set_stack(def)
	entity.surface.spill_item_stack{ position = entity.position, stack = inv[1], allow_belts = false }
	inv.destroy()
end

--------------------------------------------------------------------------------
--- machines
--------------------------------------------------------------------------------

local function input_inventory(machine)
	local d = defines.inventory
	if machine.type == "container" or machine.type == "logistic-container" then return machine.get_inventory(d.chest) end
	return machine.get_inventory(machine.type == "furnace" and d.furnace_source or d.crafter_input)
end

local function output_inventory(machine)
	local d = defines.inventory
	if machine.type == "container" or machine.type == "logistic-container" then return nil end
	return machine.get_inventory(machine.type == "furnace" and d.furnace_result or d.crafter_output)
end

local function is_machine(entity)
	return entity.type == "assembling-machine" or entity.type == "furnace"
end

local function has_fluid(ingredients, products)
	for _, i in pairs(ingredients) do if i.type == "fluid" then return true end end
	for _, p in pairs(products or {}) do if p.type == "fluid" then return true end end
	return false
end

local function connected(fb, index)
	return #fb.get_connections(index) > 0
end

local EMPTY_MAP = { inputs = {}, outputs = {} }

--- The fluid boxes a machine uses for `ingredients` and `products`: which box takes which fluid ingredient and
--- which boxes hold the fluid products. Returns the map, or nil and the reason why the machine cannot be used:
--- "fluid-box" (no usable box, box too small, furnace, two-way box), "fluid-temperature" (a box wants a
--- temperature the stored fluid does not have), "fluid-pipes" (a used box is connected to a pipe: the network
--- could not keep the fluid apart). The box filters are those of the recipe the machine has set: call it after
--- set_recipe. `outputs_optional`: a processing pattern does not need output boxes (its outputs may come back
--- elsewhere).
local function fluid_map(machine, ingredients, products, outputs_optional)
	local fluid_in, fluid_out = has_fluid(ingredients), has_fluid({}, products)
	if not fluid_in and not fluid_out then return EMPTY_MAP end
	if machine.type ~= "assembling-machine" then
		if fluid_in or not outputs_optional then return nil, "fluid-box" end
		return EMPTY_MAP                               -- a processing output that comes back elsewhere
	end
	local fb = machine.fluidbox
	local in_boxes, out_boxes = {}, {}
	for i = 1, #fb do
		local p = fb.get_prototype(i)
		if p and p.production_type == nil and p[1] then p = p[1] end   -- merged prototypes: the first one
		local kind = p and p.production_type
		if kind == "input" then
			in_boxes[#in_boxes + 1] = i
		elseif kind == "output" then
			out_boxes[#out_boxes + 1] = i
		elseif kind == "input-output" then
			return nil, "fluid-box"
		end
	end
	local inputs, used = {}, {}
	for _, ing in pairs(ingredients) do
		if ing.type == "fluid" then
			local index
			for _, i in pairs(in_boxes) do            -- the box the recipe assigned to this fluid
				if not used[i] then
					local f = fb.get_filter(i)
					if f and f.name == ing.name then index = i break end
				end
			end
			if not index then
				for _, i in pairs(in_boxes) do        -- no filter: the boxes are used in recipe order
					if not used[i] and not fb.get_filter(i) then index = i break end
				end
			end
			if not index then return nil, "fluid-box" end
			used[index] = true
			local f = fb.get_filter(index)
			local t = prototypes.fluid[ing.name].default_temperature
			if f and ((f.minimum_temperature and t < f.minimum_temperature) or (f.maximum_temperature and t > f.maximum_temperature)) then
				return nil, "fluid-temperature"
			end
			local capacity = fb.get_capacity(index)
			if capacity < fixed_up(ing.amount) then return nil, "fluid-box" end
			if connected(fb, index) then return nil, "fluid-pipes" end
			inputs[#inputs + 1] = { key = FLUID_PREFIX .. ing.name, name = ing.name, amount = fixed_up(ing.amount), index = index, capacity = capacity }
		end
	end
	local outputs, n_out, max_out = {}, 0, 0
	for _, p in pairs(products) do
		if p.type == "fluid" then
			n_out = n_out + 1
			max_out = math.max(max_out, p.amount or p.amount_max or 0)
		end
	end
	if n_out > #out_boxes and not outputs_optional then return nil, "fluid-box" end
	for _, i in pairs(out_boxes) do
		if connected(fb, i) then
			if not outputs_optional then return nil, "fluid-pipes" end
		else
			local capacity = fb.get_capacity(i)
			if n_out > 0 and capacity < max_out and not outputs_optional then return nil, "fluid-box" end
			outputs[#outputs + 1] = { index = i, capacity = capacity }
		end
	end
	return { inputs = inputs, outputs = outputs, max_out = outputs_optional and 0 or max_out }
end

--- What a crafting pattern needs from a machine whose recipe is not set yet: enough unconnected fluid boxes
--- of the right kind and size (the exact map is made after set_recipe). The boxes are read from the machine's
--- prototype: a machine without a fluid recipe may have its boxes switched off (fluid_boxes_off_when_no_fluid_recipe),
--- then the entity has none and pipes are checked only after the switch. nil when it fits, else the reason.
local function fluid_boxes_fit(machine, proto)
	if not has_fluid(proto.ingredients, proto.products) then return nil end
	if machine.type ~= "assembling-machine" then return "fluid-box" end
	local fb = machine.fluidbox
	local boxes = machine.prototype.fluidbox_prototypes
	local live = #fb == #boxes                      -- the entity's boxes are the prototype's, by index
	local ins, outs = {}, {}
	for i, p in ipairs(boxes) do
		local kind = p.production_type
		if kind == "input" then ins[#ins + 1] = i
		elseif kind == "output" then outs[#outs + 1] = i
		elseif kind == "input-output" then return "fluid-box" end
	end
	local function fit(list, entries, need)
		local n = 0
		for _, e in pairs(entries) do if e.type == "fluid" then n = n + 1 end end
		if n == 0 then return nil end
		local free, pipes = 0, false
		for _, i in pairs(list) do
			if live and connected(fb, i) then pipes = true
			elseif (live and fb.get_capacity(i) or boxes[i].volume) >= need then free = free + 1 end
		end
		if free >= n then return nil end
		return pipes and "fluid-pipes" or "fluid-box"
	end
	local need_in, need_out = 0, 0
	for _, e in pairs(proto.ingredients) do if e.type == "fluid" then need_in = math.max(need_in, fixed_up(e.amount)) end end
	for _, e in pairs(proto.products) do if e.type == "fluid" then need_out = math.max(need_out, e.amount or e.amount_max or 0) end end
	for _, e in pairs(proto.ingredients) do
		if e.type == "fluid" then
			local t = prototypes.fluid[e.name].default_temperature
			if (e.minimum_temperature and t < e.minimum_temperature) or (e.maximum_temperature and t > e.maximum_temperature) then
				return "fluid-temperature"
			end
		end
	end
	return fit(ins, proto.ingredients, need_in) or fit(outs, proto.products, need_out)
end

--- "stack" when an item ingredient does not fit into one machine slot
local function stack_problem(ingredients)
	for _, i in pairs(ingredients) do
		if i.type == "item" then
			local proto = prototypes.item[i.name]
			if not proto or i.amount > proto.stack_size then return "stack" end
		end
	end
	return nil
end

--- Can `entity` (next to a provider) do pattern `def`? Returns a target entry { entity, unit, mode } or nil and
--- the reason: crafting patterns need an assembling machine that can make the recipe ("category",
--- "not-researched", "fixed-recipe", "stack", the fluid reasons; a furnace: "furnace"), processing patterns a
--- machine ("no-recipe": an assembling machine without a recipe; "stack", fluid reasons) or a chest (items only).
--- Chests are no target of crafting patterns (nil, nil: not counted).
local function target_for(entity, def)
	if def.kind == "crafting" then
		if entity.type == "furnace" then return nil, "furnace" end
		if entity.type ~= "assembling-machine" then return nil, nil end
		local proto = prototypes.recipe[def.recipe]
		if not entity.prototype.crafting_categories[proto.category] then return nil, "category" end
		local fixed = entity.prototype.fixed_recipe
		if fixed and fixed ~= "" and fixed ~= def.recipe then return nil, "fixed-recipe" end
		local r = entity.force.recipes[def.recipe]
		if not (r and r.enabled) then return nil, "not-researched" end
		local why = stack_problem(proto.ingredients)
		if why then return nil, why end
		local current = entity.get_recipe()
		if current and current.name == def.recipe then
			local _, reason = fluid_map(entity, proto.ingredients, proto.products)
			if reason then return nil, reason end
		else
			why = fluid_boxes_fit(entity, proto)
			if why then return nil, why end
		end
		return { entity = entity, unit = entity.unit_number, mode = "craft" }
	end
	local ingredients, products = P.ingredients(def), P.products(def)
	if entity.type == "container" or entity.type == "logistic-container" then
		for _, i in pairs(ingredients) do if i.type == "fluid" then return nil, "fluid-box" end end
		return { entity = entity, unit = entity.unit_number, mode = "chest" }
	end
	if entity.type == "assembling-machine" and not entity.get_recipe() then return nil, "no-recipe" end
	local why = stack_problem(ingredients)
	if why then return nil, why end
	local items = 0
	for _, i in pairs(ingredients) do if i.type == "item" then items = items + 1 end end
	local inp = input_inventory(entity)
	if inp and items > #inp then return nil, "stack" end         -- more input items than input slots (a furnace)
	local _, reason = fluid_map(entity, ingredients, products, true)
	if reason then return nil, reason end
	return { entity = entity, unit = entity.unit_number, mode = "push" }
end

--------------------------------------------------------------------------------
--- providers: pattern slots, scan, patterns of the networks
--------------------------------------------------------------------------------

--- The machines and chests on the four tiles around a provider (each once, in the order of NEIGHBORS)
local function neighbors_of(entity)
	local out, seen = {}, {}
	for _, d in pairs(NEIGHBORS) do
		for _, m in pairs(entity.surface.find_entities_filtered{
			position = { entity.position.x + d[1], entity.position.y + d[2] }, type = TARGET_TYPES, force = entity.force,
		}) do
			if not seen[m.unit_number] then
				seen[m.unit_number] = true
				out[#out + 1] = m
			end
		end
	end
	return out
end

local function new_provider(entity)
	return { entity = entity, unit = entity.unit_number, surface = entity.surface.index,
		position = { x = entity.position.x, y = entity.position.y }, force = entity.force.name,
		slots = {},          -- [slot] = pattern as stored in the item (raw: kept exactly, validated by the scan)
		pending = nil,       -- [slot] = pattern from a blueprint, encoded from a blank pattern of the network
		priority = 0,
		patterns = {},       -- [slot] = { id, def, targets = { {entity, unit, mode} } } (scan)
		status = {},         -- [slot] = { ok, reason, machines } (scan)
		net = nil, sig = nil }
end

--- blueprint patterns waiting for a blank pattern: encoded from the network's blanks (never out of nothing)
local function fill_pending(p, net)
	if not (p.pending and net and N.usable(net)) then return false end
	local changed = false
	for slot, def in pairs(p.pending) do
		if p.slots[slot] then
			p.pending[slot] = nil                      -- a pattern was put into the slot by hand
		elseif N.extract(net, P.BLANK, "normal", 1) == 1 then
			p.slots[slot] = def
			p.pending[slot] = nil
			changed = true
		end
	end
	if next(p.pending) == nil then p.pending = nil end
	return changed
end

local function scan_provider(p)
	local e = p.entity
	local net = N.network_of(e)                  -- patterns are kept while the network is off, jobs wait
	if p.pending then fill_pending(p, N.active_of(e)) end
	local patterns, status, sig = {}, {}, { net and net.id or "-", p.priority or 0 }
	local around = net and neighbors_of(e) or {}
	for slot = 1, SLOTS do
		local raw = p.slots[slot]
		if raw then
			local def, why = P.normalize(raw)
			if not def then
				status[slot] = { ok = false, reason = why }
				sig[#sig + 1] = slot .. ":" .. why
			elseif not net then
				status[slot] = { ok = false, reason = "no-network" }
				sig[#sig + 1] = slot .. ":-"
			else
				local id = P.id_of(def)
				local targets, reason = {}, nil
				for _, m in pairs(around) do
					local t, r = target_for(m, def)
					if t then targets[#targets + 1] = t else reason = reason or r end
				end
				patterns[slot] = { id = id, def = def, targets = targets }
				local ok = #targets > 0
				status[slot] = { ok = ok, reason = not ok and (reason or "no-machine") or nil, machines = #targets }
				local units = {}
				for _, t in ipairs(targets) do units[#units + 1] = t.unit end
				sig[#sig + 1] = slot .. ":" .. id .. ":" .. table.concat(units, "/") .. ":" .. tostring(reason)
			end
		end
	end
	sig = table.concat(sig, "|")
	p.patterns, p.status, p.net = patterns, status, net and net.id or nil
	if p.sig ~= sig then
		p.sig = sig
		state().dirty = true
	end
end

--- a provider whose entity is gone without an event: its patterns are dropped on the ground where it stood
local function vanish_provider(s, p)
	local surface = game.get_surface(p.surface or 0)
	local n = 0
	for slot = 1, SLOTS do
		local raw = p.slots and p.slots[slot]
		if raw and surface then
			local def = P.normalize(raw)
			local inv = game.create_inventory(1)
			inv[1].set_stack(def and P.stack_def(def) or { name = P.ENCODED, count = 1, tags = { [P.TAG] = raw } })
			surface.spill_item_stack{ position = p.position, stack = inv[1], allow_belts = false }
			inv.destroy()
			n = n + 1
		end
	end
	if n > 0 and surface then
		local force = game.forces[p.force or "player"]
		if force then
			force.print({ "fork-me-pattern.provider-vanished", n,
				string.format("[gps=%d,%d,%s]", math.floor(p.position.x), math.floor(p.position.y), surface.name) })
		end
	end
	p.slots = {}
end

local function drop_provider(s, unit)
	local p = s.providers[unit]
	if p and not (p.entity and p.entity.valid) then vanish_provider(s, p) end
	s.providers[unit] = nil
	remove_value(s.plist, unit)
	s.dirty = true
end

--- providers in the order of their patterns: priority descending, then the one built first
local function provider_order(s)
	local list = {}
	for _, unit in pairs(s.plist) do
		local p = s.providers[unit]
		if p then list[#list + 1] = p end
	end
	table.sort(list, function(a, b)
		local pa, pb = a.priority or 0, b.priority or 0
		if pa ~= pb then return pa > pb end
		return a.unit < b.unit
	end)
	return list
end

--- The patterns of each network: items[key] = { pattern id, ... } (preferred first), defs[id] = pattern,
--- targets[id] = { target entries } (each machine once), ignored = { total, [reason] } (pattern slots the network
--- cannot use).
local function rebuild_patterns(s)
	local patterns = {}
	for _, p in ipairs(provider_order(s)) do
		if p.net and p.entity.valid then
			local net = patterns[p.net]
			if not net then
				net = { items = {}, defs = {}, targets = {}, ignored = { total = 0 }, seen = {} }
				patterns[p.net] = net
			end
			for slot = 1, SLOTS do
				local st = p.status[slot]
				local pat = p.patterns[slot]
				if st and not st.ok then
					net.ignored.total = net.ignored.total + 1
					net.ignored[st.reason] = (net.ignored[st.reason] or 0) + 1
				elseif pat then
					local id = pat.id
					if not net.defs[id] then
						net.defs[id] = pat.def
						net.targets[id] = {}
						net.seen[id] = {}
						for _, product in pairs(P.products(pat.def)) do
							local key = key_of(product)
							local list = net.items[key] or {}
							net.items[key] = list
							local known = false
							for _, r in pairs(list) do if r == id then known = true end end
							if not known then list[#list + 1] = id end
						end
					end
					for _, t in ipairs(pat.targets) do
						if t.entity.valid and not net.seen[id][t.unit] then
							net.seen[id][t.unit] = true
							table.insert(net.targets[id], t)
						end
					end
				end
			end
		end
	end
	for _, net in pairs(patterns) do net.seen = nil end
	s.patterns = patterns
	s.dirty = false
end

--- rescan every provider (before starting a job: patterns must be current)
local function refresh_providers(s)
	for _, unit in pairs(shallow(s.plist)) do
		local p = s.providers[unit]
		if p and p.entity.valid then scan_provider(p) else drop_provider(s, unit) end
	end
end

--- the patterns of every network; a change of the ME graph (networks joined or split) rescans the providers
local function ensure_patterns(s)
	if s.graph_dirty then
		s.graph_dirty = nil
		s.await = nil
		refresh_providers(s)
	end
	if s.dirty then rebuild_patterns(s) end
	return s.patterns
end
N.change_hooks[#N.change_hooks + 1] = function()
	local s = storage.fork_ae2
	if s then s.graph_dirty, s.await = true, nil end
end

--- bounded slice of the round robin rescan
local function maintenance(s)
	local n = #s.plist
	if n == 0 then return end
	for _ = 1, math.min(PROVIDERS_PER_STEP, n) do
		if s.pcursor > #s.plist then s.pcursor = 1 end
		local unit = s.plist[s.pcursor]
		local p = s.providers[unit]
		if p and p.entity.valid then
			scan_provider(p)
			s.pcursor = s.pcursor + 1
		else
			drop_provider(s, unit)
		end
		if #s.plist == 0 then return end
	end
end

--------------------------------------------------------------------------------
--- planning
--------------------------------------------------------------------------------

--- items with own data (item-with-tags: a cell, an encoded pattern) are never taken from storage: moving them by
--- name and count would strip the data
local function plain_item(name)
	local proto = prototypes.item[name]
	return proto ~= nil and proto.type ~= "item-with-tags"
end

local function stock_of(net)
	local stock = {}
	for name, count in pairs(N.plain_counts(net)) do
		if plain_item(name) then stock[name] = count end
	end
	for name, amount in pairs(fluids.totals(net)) do
		stock[FLUID_PREFIX .. name] = amount
	end
	return stock
end

--- expected units of `key` per run of a pattern (its products), and whether that amount is certain
local function product_yield(products, key)
	local total, exact = 0, true
	for _, p in pairs(products) do
		if key_of(p) == key then
			local amount = p.amount or ((p.amount_min + p.amount_max) / 2)
			local probability = p.probability or 1
			total = total + amount * probability
			if p.amount == nil or probability ~= 1 then exact = false end
		end
	end
	return total, exact
end

local function copy_map(t)
	local c = {}
	for k, v in pairs(t) do c[k] = v end
	return c
end

local function snapshot(ctx)
	local steps = {}
	for k, v in pairs(ctx.steps) do steps[k] = { pid = v.pid, runs = v.runs } end
	return {
		stock = copy_map(ctx.stock), surplus = copy_map(ctx.surplus), reserve = copy_map(ctx.reserve),
		missing = copy_map(ctx.missing), loops = copy_map(ctx.loops), steps = steps,
		order = { table.unpack(ctx.order) }, missing_n = ctx.missing_n,
	}
end

local function restore(ctx, snap)
	for k, v in pairs(snap) do ctx[k] = v end
end

local function add_missing(ctx, key, count)
	ctx.missing[key] = (ctx.missing[key] or 0) + count
	ctx.missing_n = ctx.missing_n + count
end

local need

--- make `count` of `key` with one pattern: its ingredients are needed `runs` times
local function apply_pattern(ctx, pid, key, count, path, depth)
	local def = ctx.patterns.defs[pid]
	local yield, exact = product_yield(P.products(def), key)
	if yield <= 0 then add_missing(ctx, key, count) return end
	local runs = math.ceil(count / yield - 1e-9)
	for _, ing in pairs(P.ingredients(def)) do
		need(ctx, key_of(ing), ing.amount * runs, path, depth + 1, false)
	end
	local step = ctx.steps[pid]
	if not step then
		step = { pid = pid, runs = 0 }
		ctx.steps[pid] = step
		ctx.order[#ctx.order + 1] = pid              -- ingredients were planned first: dependencies come first
	end
	step.runs = step.runs + runs
	if exact then                                    -- surplus of a certain yield can be used by later demand
		local over = runs * yield - count
		if not is_fluid(key) then over = math.floor(over + 1e-9) end
		if over > 1e-9 then ctx.surplus[key] = (ctx.surplus[key] or 0) + over end
	end
end

--- `count` of `key` are needed: take from storage, else craft through a pattern
function need(ctx, key, count, path, depth, top)
	ctx.nodes = ctx.nodes + 1
	if ctx.nodes > MAX_PLAN_NODES or depth > MAX_DEPTH then
		ctx.too_complex = true
		add_missing(ctx, key, count)
		return
	end
	if not top then
		local t = math.min(ctx.surplus[key] or 0, count)
		ctx.surplus[key] = (ctx.surplus[key] or 0) - t
		count = count - t
		t = math.min(ctx.stock[key] or 0, count)
		ctx.stock[key] = (ctx.stock[key] or 0) - t
		ctx.reserve[key] = (ctx.reserve[key] or 0) + t
		count = count - t
		if count <= 1e-9 then return end
	end
	local pids = ctx.patterns.items[key]
	if not pids then add_missing(ctx, key, count) return end
	if path[key] then
		ctx.loops[key] = true
		add_missing(ctx, key, count)
		return
	end
	path[key] = true
	if #pids == 1 then
		apply_pattern(ctx, pids[1], key, count, path, depth)
	else
		--- several patterns (in pattern order: provider priority, provider, slot): the first one that needs
		--- nothing that is missing
		local start = snapshot(ctx)
		local chosen
		for i, pid in ipairs(pids) do
			restore(ctx, snapshot(start))
			apply_pattern(ctx, pid, key, count, path, depth)
			if ctx.missing_n == start.missing_n then chosen = i break end
		end
		if not chosen then
			restore(ctx, snapshot(start))
			apply_pattern(ctx, pids[1], key, count, path, depth)
		end
	end
	path[key] = nil
end

local NO_PATTERNS = { items = {}, defs = {}, targets = {}, ignored = { total = 0 } }

--- Plan `amount` of `key` for the network `net`.
--- Returns { ok, missing = {key -> count}, loops = {key -> true}, steps = { {pid, def, runs} },
--- reserve = {key -> count taken from storage}, runs, too_complex }
local function make_plan(s, net, key, amount)
	local patterns = ensure_patterns(s)[net.id] or NO_PATTERNS
	local ctx = {
		patterns = patterns, stock = stock_of(net), surplus = {}, reserve = {}, missing = {}, loops = {},
		steps = {}, order = {}, missing_n = 0, nodes = 0,
	}
	if not patterns.items[key] then
		return { ok = false, missing = { [key] = amount }, loops = {}, steps = {}, reserve = {}, runs = 0, no_pattern = true }
	end
	need(ctx, key, amount, {}, 0, true)
	local steps, runs = {}, 0
	for _, pid in ipairs(ctx.order) do
		local step = ctx.steps[pid]
		steps[#steps + 1] = { pid = pid, def = patterns.defs[pid], runs = step.runs }
		runs = runs + step.runs
	end
	local reserve = {}
	for k, v in pairs(ctx.reserve) do if v > 0 then reserve[k] = v end end
	return { ok = ctx.missing_n == 0, missing = ctx.missing, loops = ctx.loops, steps = steps,
		reserve = reserve, runs = runs, too_complex = ctx.too_complex }
end

--------------------------------------------------------------------------------
--- CPUs
--------------------------------------------------------------------------------

local function cpu_powered(cpu)
	return cpu.status ~= defines.entity_status.no_power
end

--- the jobs a CPU runs ({ [id] = true }); a record from before the CPU tiers held one `job`
local function cpu_jobs(rec)
	if not rec.jobs then
		rec.jobs = {}
		if rec.job then rec.jobs[rec.job] = true end
		rec.job = nil
	end
	return rec.jobs
end

local function cpu_load(rec)
	local n = 0
	for _ in pairs(cpu_jobs(rec)) do n = n + 1 end
	return n
end

--- job slots of a CPU record (1 for an entity that is no longer a known tier)
local function cpu_slots(rec)
	local spec = rec.entity.valid and cpu_spec(rec.entity.name)
	return spec and spec.jobs or 1
end

--- CPUs of a network, fastest first (a queued job takes the fastest free one)
local function cpus_in(s, net)
	local list = {}
	for unit, rec in pairs(s.cpus) do
		if rec.entity.valid then
			local n = N.network_of(rec.entity)
			if n and n.id == net.id then list[#list + 1] = rec end
		else
			s.cpus[unit] = nil
		end
	end
	table.sort(list, function(a, b)
		local sa, sb = cpu_spec(a.entity.name), cpu_spec(b.entity.name)
		local va, vb = sa and sa.speed or 1, sb and sb.speed or 1
		if va ~= vb then return va > vb end
		return a.entity.unit_number < b.entity.unit_number
	end)
	return list
end

--------------------------------------------------------------------------------
--- jobs
--------------------------------------------------------------------------------

--- the working network of a job: that of its CPU, else of the entity it was started at, else of the ME member at
--- its position (jobs of older saves)
local function job_network(job)
	local s = state()
	local rec = job.cpu and s.cpus[job.cpu]
	if rec and rec.entity.valid and N.network_of(rec.entity) then return N.active_of(rec.entity) end
	if job.anchor and job.anchor.valid and N.network_of(job.anchor) then return N.active_of(job.anchor) end
	local surface = game.get_surface(job.surface)
	if not (surface and job.pos) then return nil end
	for _, e in pairs(surface.find_entities_filtered{ position = job.pos, name = N.node_names() }) do
		if N.network_of(e) then
			job.anchor = e
			return N.active_of(e)
		end
	end
	return nil
end

local function pool_add(job, key, count)
	local now = (job.pool[key] or 0) + count
	if now > -FLUID_EPS and now < FLUID_EPS then now = 0 end     -- fixed point remainders of fluids
	job.pool[key] = now
end

--- the ingredients and products of a job step (its pattern; a crafting pattern reads its recipe)
local function step_ingredients(step) return P.ingredients(step.def) end
local function step_products(step) return P.products(step.def) end

--- runs of a processing step whose outputs are all back (received)
local function processing_done(step)
	local done
	for _, r in ipairs(step.def.outputs) do
		local n = math.floor(((step.received[r.key] or 0) + FLUID_EPS) / r.amount)
		done = done and math.min(done, n) or n
	end
	return math.min(done or 0, step.issued)
end

--- the job's total of finished runs (crafting steps count crafts, processing steps the outputs that came back)
local function update_done(job)
	local total = 0
	for _, step in ipairs(job.steps) do
		if step.kind == "processing" then step.done = processing_done(step) end
		total = total + step.done
	end
	job.done_runs = total
end

--- Outputs of processing steps that came back (from the machine or as arrivals): credited to the steps that wait
--- for `key` (`first`: this step first), at most what their issued runs make. Returns the amount credited.
local function credit(job, key, amount, first)
	local left = amount
	local function give(step)
		if step.kind ~= "processing" or left <= 0 then return end
		local per = P.output_of(step.def, key)
		if per <= 0 then return end
		local open = step.issued * per - (step.received[key] or 0)
		if not is_fluid(key) then open = math.floor(open + 1e-9) end
		local n = math.min(left, open)
		if n > 0 then
			step.received[key] = (step.received[key] or 0) + n
			left = left - n
		end
	end
	if first then give(job.steps[first]) end
	for i, step in ipairs(job.steps) do
		if i ~= first then give(step) end
	end
	if amount - left > 0 then update_done(job) end
	return amount - left
end

--- move everything from the pool into the network; what does not fit stays in the pool
local function flush_pool(job, net)
	for key, count in pairs(shallow_map(job.pool)) do
		local inserted = 0
		if count > 0 then
			if is_fluid(key) then
				inserted = store_fluid(net, fluid_name(key), count)
			else
				inserted = store_item(net, key, QUALITY, count)
			end
		end
		if inserted >= count - FLUID_EPS then job.pool[key] = nil else job.pool[key] = count - inserted end
	end
	return next(job.pool) == nil
end

--- Everything a machine holds of a lease: products into the pool (items and fluid output boxes). For a
--- processing lease (`step` given) the outputs of its pattern are credited to the step.
local function collect_output(job, net, machine, map, step)
	local function got(key, n)
		pool_add(job, key, n)
		if step then credit(job, key, n, step) end
	end
	local out = output_inventory(machine)
	if out then
		for _, c in pairs(out.get_contents()) do
			local removed = out.remove{ name = c.name, count = c.count, quality = c.quality }
			if removed > 0 then
				if (c.quality or QUALITY) == QUALITY then
					got(c.name, removed)
				else
					local inserted = net and store_item(net, c.name, c.quality, removed) or 0
					if inserted < removed then      -- no room: put it back, the machine keeps it
						out.insert{ name = c.name, count = removed - inserted, quality = c.quality }
					end
				end
			end
		end
	end
	if map and #map.outputs > 0 then
		local fb = machine.fluidbox
		for _, o in pairs(map.outputs) do
			local f = o.index <= #fb and fb[o.index] or nil     -- a changed recipe may have fewer boxes
			if f and f.amount > 0 then
				got(FLUID_PREFIX .. f.name, f.amount)
				fb[o.index] = nil
			end
		end
	end
end

--- unused inputs back into the pool (items and fluid input boxes); returns { key -> amount taken back }
local function take_back_input(job, machine, ingredients, map)
	local back = {}
	local inp = input_inventory(machine)
	if inp then
		for _, ing in pairs(ingredients) do
			if ing.type == "item" and not back[ing.name] then
				local held = inp.get_item_count{ name = ing.name, quality = QUALITY }
				local removed = held > 0 and inp.remove{ name = ing.name, count = held, quality = QUALITY } or 0
				if removed > 0 then pool_add(job, ing.name, removed) back[ing.name] = removed end
			end
		end
	end
	if map and #map.inputs > 0 then
		local fb = machine.fluidbox
		for _, i in pairs(map.inputs) do
			local f = i.index <= #fb and fb[i.index] or nil
			if f and f.amount > 0 then
				local key = FLUID_PREFIX .. f.name
				pool_add(job, key, f.amount)
				back[key] = (back[key] or 0) + f.amount
				fb[i.index] = nil
			end
		end
	end
	return back
end

--- nothing in progress and nothing left to craft with (fluid remainders below one craft count as empty)
local function machine_idle(machine, ingredients, map)
	if machine.crafting_progress > 0 then return false end
	local inp = input_inventory(machine)
	if not inp then return false end
	for _, ing in pairs(ingredients) do
		if ing.type == "item" and inp.get_item_count(ing.name) > 0 then return false end
	end
	if map and #map.inputs > 0 then
		local fb = machine.fluidbox
		for _, i in pairs(map.inputs) do
			local f = i.index <= #fb and fb[i.index] or nil
			if f and f.amount >= i.amount then return false end
		end
	end
	return true
end

local function release_lease(s, job, lease)
	s.busy[lease.unit] = nil
	remove_value(job.leases, lease)
end

local function release_cpu(s, job)
	local rec = job.cpu and s.cpus[job.cpu]
	if rec then cpu_jobs(rec)[job.id] = nil end
	job.cpu = nil
end

--- The job is over one way or the other; keep it visible for a while
local function finish(s, job, status, reason)
	job.status = status
	job.reason = reason or job.reason
	job.closing = nil
	job.tick_end = game.tick
	release_cpu(s, job)
	remove_value(s.active, job.id)
	s.finished[#s.finished + 1] = job.id
	s.await = nil
end

--- Cancel or fail: stop handing out work, take unused inputs back, keep waiting for machines that
--- are still crafting so their products can be collected, then give the pool back to the network.
--- (What a processing job pushed into a chest is in the line: it cannot be taken back; outputs that come back
--- later go into storage.)
local function begin_closing(s, job, final_status, reason)
	if job.closing or job.status == "done" or job.status == "failed" or job.status == "cancelled" then return end
	job.closing = final_status
	job.reason = reason
	job.closing_steps = 0
	for _, lease in pairs(job.leases) do
		local step = job.steps[lease.step]
		if step and lease.machine.valid then take_back_input(job, lease.machine, step_ingredients(step), lease.fluid) end
	end
	if job.status == "queued" then job.status = "running" end
	s.await = nil
end

local function assign_cpus(s)
	for _, id in pairs(s.active) do
		local job = s.jobs[id]
		if job and job.status == "queued" and not job.closing then
			local net = job_network(job)
			if net then
				for _, rec in ipairs(cpus_in(s, net)) do
					if cpu_load(rec) < cpu_slots(rec) then
						cpu_jobs(rec)[job.id] = true
						job.cpu = rec.entity.unit_number
						job.pos = { x = rec.entity.position.x, y = rec.entity.position.y }
						job.status = "running"
						break
					end
				end
			end
		end
	end
end

--- One lease per machine: hand `batch` runs of ingredients to it. A crafting lease counts crafts
--- (products_finished), a processing lease remembers what it gave (to see what the machine used).
local function start_lease(s, job, step_index, machine, batch, map)
	local step = job.steps[step_index]
	local ingredients = step_ingredients(step)
	local inp = input_inventory(machine)
	if not inp then return false end
	for _, ing in pairs(ingredients) do               -- never hand out more than the pool holds
		local per = ing.type == "fluid" and fixed_up(ing.amount) or ing.amount
		if (job.pool[key_of(ing)] or 0) + FLUID_EPS < per * batch then return false end
	end
	local given = {}
	local function undo()
		for _, g in pairs(given) do
			if g.fluid then
				machine.fluidbox[g.index] = nil
			elseif g.got > 0 then
				inp.remove{ name = g.name, count = g.got, quality = QUALITY }
			end
			pool_add(job, g.key, g.got)
		end
	end
	for _, ing in pairs(ingredients) do
		if ing.type == "item" then
			local count = ing.amount * batch
			local inserted = inp.insert{ name = ing.name, count = count, quality = QUALITY }
			pool_add(job, ing.name, -inserted)
			given[#given + 1] = { key = ing.name, name = ing.name, got = inserted }
			if inserted < count then undo() return false end
		end
	end
	local fb = machine.fluidbox
	for _, i in pairs(map.inputs) do
		local leftover = fb[i.index]                        -- less than one craft: back into the pool first
		if leftover and leftover.amount > 0 then
			pool_add(job, FLUID_PREFIX .. leftover.name, leftover.amount)
			fb[i.index] = nil
		end
		local need_amount = i.amount * batch
		local give = math.min(i.capacity, need_amount + math.max(0, math.min(FLUID_MARGIN, (job.pool[i.key] or 0) - need_amount)))
		fb[i.index] = { name = i.name, amount = give }
		local now = fb[i.index]
		local got = (now and now.name == i.name) and now.amount or 0
		pool_add(job, i.key, -got)
		given[#given + 1] = { key = i.key, fluid = true, index = i.index, got = got }
		if got + FLUID_EPS < need_amount then undo() return false end
	end
	step.issued = step.issued + batch
	local lease = { machine = machine, unit = machine.unit_number, step = step_index, pid = step.pid, kind = step.kind,
		recipe = step.recipe, runs = batch, fluid = map }
	if step.kind == "crafting" then
		lease.finished0 = machine.products_finished
	else
		lease.given = {}
		for _, g in pairs(given) do lease.given[g.key] = (lease.given[g.key] or 0) + g.got end
		s.await = nil
	end
	job.leases[#job.leases + 1] = lease
	s.busy[machine.unit_number] = job.id
	return true
end

--- A processing pattern into a chest (the start of a line): every input of `batch` runs must fit; nothing is
--- taken back later, the outputs come back into the network.
local function push_chest(s, job, step_index, chest, batch)
	local step = job.steps[step_index]
	local inv = input_inventory(chest)
	if not inv then return false end
	local put = {}
	local function undo()
		for name, n in pairs(put) do
			inv.remove{ name = name, count = n, quality = QUALITY }
			pool_add(job, name, n)
		end
	end
	for _, ing in pairs(step_ingredients(step)) do
		if ing.type ~= "item" then undo() return false end
		local count = ing.amount * batch
		if (job.pool[ing.name] or 0) < count then undo() return false end
		local n = inv.insert{ name = ing.name, count = count, quality = QUALITY }
		if n > 0 then
			pool_add(job, ing.name, -n)
			put[ing.name] = (put[ing.name] or 0) + n
		end
		if n < count then undo() return false end
	end
	step.issued = step.issued + batch
	s.await = nil
	return true
end

--- the machine was given work of another job or pattern that failed there: not used again by this job for it
local function rejected(job, unit, pid)
	return job.rejected ~= nil and job.rejected[unit .. "|" .. pid] == true
end

local function reject(job, unit, pid)
	job.rejected = job.rejected or {}
	job.rejected[unit .. "|" .. pid] = true
end

--- Switch an idle machine to `recipe` (crafting patterns). What is left in it goes into the network first (items
--- of its input and output, its fluid boxes); when the network cannot take it all, the machine is not switched
--- (it is tried again later). Returns true when the machine has the recipe now.
local function switch_recipe(net, machine, recipe)
	if machine.crafting_progress > 0 then return false end
	local inp, out = input_inventory(machine), output_inventory(machine)
	local items = {}
	for _, inv in pairs({ inp, out }) do
		if inv then
			for _, c in pairs(inv.get_contents()) do items[#items + 1] = { inv = inv, name = c.name, quality = c.quality or QUALITY, count = c.count } end
		end
	end
	local fb = machine.fluidbox
	local held = {}
	for i = 1, #fb do
		local f = fb[i]
		if f and f.amount > 0 then held[#held + 1] = { index = i, name = f.name, amount = f.amount } end
	end
	N.no_arrival = true
	local fits = true
	for _, it in pairs(items) do
		if N.can_insert(net, it.name, it.quality, it.count) < it.count then fits = false end
	end
	for _, f in pairs(held) do
		if N.can_insert_fluid(net, f.name, f.amount) < f.amount - FLUID_EPS then fits = false end
	end
	if not fits then N.no_arrival = false return false end
	for _, it in pairs(items) do
		local removed = it.inv.remove{ name = it.name, quality = it.quality, count = it.count }
		local stored = removed > 0 and N.insert(net, it.name, it.quality, removed) or 0
		if stored < removed then spill(machine, { name = it.name, quality = it.quality, count = removed - stored }) end
	end
	for _, f in pairs(held) do
		N.insert_fluid(net, f.name, f.amount)
		fb[f.index] = nil
	end
	local ok, returned = pcall(machine.set_recipe, recipe)
	for _, it in pairs(ok and returned or {}) do              -- nothing should be left: never lose it anyway
		local stored = N.insert(net, it.name, it.quality or QUALITY, it.count)
		if stored < it.count then spill(machine, { name = it.name, quality = it.quality, count = it.count - stored }) end
	end
	N.no_arrival = false
	local now = machine.get_recipe()
	return ok and now ~= nil and now.name == recipe
end

--- A machine for a crafting step: one that has the recipe and is idle, else an idle one that is switched to it.
--- Returns the machine and its fluid map, or nil.
local function find_crafter(s, net, job, step, targets)
	local proto = prototypes.recipe[step.recipe]
	if not proto then return nil end
	for pass = 1, 2 do
		for _, t in pairs(targets) do
			local e = t.entity
			if t.mode == "craft" and e.valid and not s.busy[t.unit] and not e.disabled_by_script and not rejected(job, t.unit, step.pid) then
				local current = e.get_recipe()
				local has = current ~= nil and current.name == step.recipe
				if pass == 1 and has then
					local map, why = fluid_map(e, proto.ingredients, proto.products)
					if not map then reject(job, t.unit, step.pid) job.problem = why
					elseif machine_idle(e, proto.ingredients, map) then return e, map end
				elseif pass == 2 and not has and e.crafting_progress == 0 then
					if switch_recipe(net, e, step.recipe) then
						local map, why = fluid_map(e, proto.ingredients, proto.products)
						if map then return e, map end
						reject(job, t.unit, step.pid)
						job.problem = why
					end
				end
			end
		end
	end
	return nil
end

--- A target for a processing step: an idle machine ("push") or a chest ("chest"). Returns the entity, its mode and
--- the fluid map.
local function find_pusher(s, job, step, targets)
	local ingredients, products = step_ingredients(step), step_products(step)
	for _, t in pairs(targets) do
		local e = t.entity
		if e.valid and not s.busy[t.unit] and not rejected(job, t.unit, step.pid) then
			if t.mode == "chest" then
				return e, "chest", EMPTY_MAP
			elseif t.mode == "push" and not e.disabled_by_script then
				local map, why = fluid_map(e, ingredients, products, true)
				if not map then reject(job, t.unit, step.pid) job.problem = why
				elseif machine_idle(e, ingredients, map) then return e, "push", map end
			end
		end
	end
	return nil
end

--- crafts per hand-over that fit into the machine's fluid boxes
local function fluid_batch_limit(map, batch)
	for _, i in pairs(map.inputs) do
		batch = math.min(batch, math.floor(i.capacity / i.amount + 1e-9))
	end
	if map.max_out and map.max_out > 0 then
		for _, o in pairs(map.outputs) do
			batch = math.min(batch, math.floor(o.capacity / map.max_out + 1e-9))
		end
	end
	return batch
end

--- job status text key for the GUI while the job is running
local function set_wait(job, wait)
	job.wait = wait
end

--- machine interactions a job may use in this step: STEP_OPS times the speed of its CPU tier
local function job_ops(s, job)
	local rec = job.cpu and s.cpus[job.cpu]
	local spec = rec and rec.entity.valid and cpu_spec(rec.entity.name)
	return STEP_OPS * (spec and spec.speed or 1)
end

--- A lease whose machine is idle again: products into the pool, unused inputs back. A crafting lease counts the
--- crafts the machine made (fewer than handed over: the rest is handed out again); a processing lease counts the
--- runs whose inputs the machine used (none: the machine does not take this pattern, it is not used again).
local function close_lease(s, job, net, lease)
	local m = lease.machine
	local step = job.steps[lease.step]
	if lease.kind == "crafting" then
		collect_output(job, net, m, lease.fluid)
		take_back_input(job, m, step_ingredients(step), lease.fluid)
		local runs = lease.runs
		if lease.finished0 then
			local crafted = m.products_finished - lease.finished0
			if crafted >= 0 and crafted < runs then
				step.issued = step.issued - (runs - crafted)
				runs = crafted
			end
		end
		step.done = step.done + runs
		update_done(job)
	else
		collect_output(job, net, m, lease.fluid, lease.step)
		local back = take_back_input(job, m, step_ingredients(step), lease.fluid)
		local used = lease.runs
		for _, ing in pairs(step_ingredients(step)) do
			local key = key_of(ing)
			local per = ing.type == "fluid" and fixed_up(ing.amount) or ing.amount
			local given = lease.given and lease.given[key] or per * lease.runs
			used = math.min(used, math.floor((given - (back[key] or 0)) / per + 1e-6))
		end
		used = math.max(0, used)
		if used < lease.runs then step.issued = step.issued - (lease.runs - used) end
		if used == 0 then reject(job, lease.unit, lease.pid) end
		update_done(job)
	end
	release_lease(s, job, lease)
end

--- `work.ops`: machine interactions left for this job in this step (counted down)
local function job_step(s, job, work)
	if job.status == "queued" and not job.closing then return end
	local net = job_network(job)
	if not net then set_wait(job, "no-network") return end
	local cpu_rec = job.cpu and s.cpus[job.cpu]
	if not job.closing then
		if not (cpu_rec and cpu_rec.entity.valid) then       -- CPU removed: pause until another one is free
			release_cpu(s, job)
			job.status = "queued"
			set_wait(job, nil)
			return
		end
		job.pos = { x = cpu_rec.entity.position.x, y = cpu_rec.entity.position.y }
		if not cpu_powered(cpu_rec.entity) then set_wait(job, "no-power") return end
	end

	local progress = false

	--- 1) collect finished machines
	for _, real in pairs(shallow(job.leases)) do
		if work.ops > 0 then
			local m = real.machine
			if not m.valid then
				release_lease(s, job, real)
				if not job.closing then
					begin_closing(s, job, "failed", { "fork-me-craft.reason-machine-lost" })
				end
			else
				local step = job.steps[real.step]
				local current = m.get_recipe()
				local recipe_changed = real.kind == "crafting" and not (current and current.name == real.recipe)
				if recipe_changed and not job.closing then
					take_back_input(job, m, step_ingredients(step), real.fluid)
					collect_output(job, net, m, real.fluid)
					release_lease(s, job, real)
					begin_closing(s, job, "failed", { "fork-me-craft.reason-recipe-changed" })
					progress = true
				elseif recipe_changed or machine_idle(m, step_ingredients(step), real.fluid) then
					close_lease(s, job, net, real)
					progress = true
				end
				work.ops = work.ops - 1
			end
		end
	end

	--- 2) closing: give everything back
	if job.closing then
		job.closing_steps = job.closing_steps + 1
		local empty = flush_pool(job, net)
		if #job.leases > 0 and job.closing_steps > STALL_STEPS then
			for _, lease in pairs(shallow(job.leases)) do          -- machine never finished: leave the rest in it
				release_lease(s, job, lease)
			end
		end
		if #job.leases == 0 and empty then
			finish(s, job, job.closing, job.reason)
		else
			set_wait(job, "delivering")
		end
		return
	end

	--- 3) hand out work in plan order
	local waiting
	local targets_of = (ensure_patterns(s)[net.id] or NO_PATTERNS).targets
	for i, step in ipairs(job.steps) do
		local ingredients, products = step_ingredients(step), step_products(step)
		local targets = targets_of[step.pid] or {}
		while work.ops > 0 and step.issued < step.runs do
			local batch = math.min(step.runs - step.issued, MAX_BATCH)
			for _, ing in pairs(ingredients) do   -- only what the pool holds, one stack per item ingredient
				local per = ing.type == "fluid" and fixed_up(ing.amount) or ing.amount
				batch = math.min(batch, math.floor((job.pool[key_of(ing)] or 0) / per + 1e-9))
				if ing.type == "item" then
					local proto = prototypes.item[ing.name]
					batch = math.min(batch, proto and math.floor(proto.stack_size / per) or 0)
				end
			end
			if batch <= 0 then waiting = waiting or "ingredients" break end
			local machine, mode, map
			if step.kind == "crafting" then
				machine, map = find_crafter(s, net, job, step, targets)
				mode = "craft"
			else
				machine, mode, map = find_pusher(s, job, step, targets)
			end
			if not machine then waiting = waiting or "machine" break end
			if mode ~= "chest" then
				for _, p in pairs(products) do        -- the products must fit into the output slot
					if p.type == "item" then
						local per = p.amount or p.amount_max
						local proto = prototypes.item[p.name]
						if proto and per > 0 then batch = math.min(batch, math.max(1, math.floor(proto.stack_size / per))) end
					end
				end
				batch = fluid_batch_limit(map, batch)
				if batch <= 0 then waiting = waiting or "machine" break end
			end
			local ok
			if mode == "chest" then                        -- a full chest (the line is backed up): one run, else wait
				ok = push_chest(s, job, i, machine, batch) or (batch > 1 and push_chest(s, job, i, machine, 1))
			else
				collect_output(job, net, machine, map)
				ok = start_lease(s, job, i, machine, batch, map)
				if not ok and step.kind == "processing" then reject(job, machine.unit_number, step.pid) end
			end
			if not ok then waiting = waiting or "machine" break end
			work.ops = work.ops - 1
			progress = true
		end
		if step.issued < step.runs and not waiting then waiting = "machine" end
	end

	--- 4) done?
	if job.done_runs >= job.total_runs and #job.leases == 0 then
		job.closing = "done"
		job.closing_steps = 0
		set_wait(job, nil)
		s.await = nil
		if flush_pool(job, net) then finish(s, job, "done") end
		return
	end

	--- 5) stalled: nothing arrives and nothing can be started. A shortfall (probabilistic products,
	---    fluid rounding) is topped up from network storage; otherwise the job fails after STALL_STEPS.
	if not waiting and #job.leases == 0 then
		for _, step in ipairs(job.steps) do
			if step.kind == "processing" and step.done < step.issued then waiting = "outputs" break end
		end
	end
	if progress then
		job.idle = 0
		set_wait(job, nil)
	else
		set_wait(job, waiting or (#job.leases > 0 and "crafting" or nil))
		if #job.leases == 0 and waiting == "ingredients" then
			for _, step in pairs(job.steps) do
				if step.issued < step.runs then
					for _, ing in pairs(step_ingredients(step)) do
						local key = key_of(ing)
						if ing.type == "fluid" then
							local short = fixed_up(ing.amount) - (job.pool[key] or 0)
							if short > 0 then
								local got = fluids.remove(net, ing.name, short + FLUID_MARGIN)
								if got > 0 then pool_add(job, key, got) job.idle = 0 end
							end
						else
							local short = ing.amount - (job.pool[key] or 0)
							if short > 0 then
								local got = N.extract(net, ing.name, QUALITY, short)
								if got > 0 then pool_add(job, key, got) job.idle = 0 end
							end
						end
					end
					break
				end
			end
		end
		job.idle = job.idle + 1
		if job.idle > STALL_STEPS then
			begin_closing(s, job, "failed", { "fork-me-craft.reason-stalled", job.wait and { "fork-me-craft.wait-" .. job.wait } or "" })
		end
	end
end

local function prune_finished(s)
	while #s.finished > 0 do
		local job = s.jobs[s.finished[1]]
		if not job or #s.finished > MAX_FINISHED or game.tick - (job.tick_end or 0) > KEEP_FINISHED_TICKS then
			if job then s.jobs[job.id] = nil end
			table.remove(s.finished, 1)
		else
			break
		end
	end
end

local function on_step(event)
	local s = storage.fork_ae2
	if not s then return end
	if #s.active > 0 then
		assign_cpus(s)
		local n = #s.active
		local count = math.min(MAX_JOBS_PER_STEP, n)
		local ids = {}
		for i = 0, count - 1 do ids[#ids + 1] = s.active[(s.jcursor - 1 + i) % n + 1] end
		s.jcursor = (s.jcursor - 1 + count) % n + 1
		local budget = MAX_OPS_PER_STEP
		for _, id in pairs(ids) do
			local job = s.jobs[id]
			if job and (job.status == "queued" or job.status == "running") then
				local work = { ops = math.min(job_ops(s, job), budget) }
				local given = work.ops
				job_step(s, job, work)
				budget = math.max(0, budget - (given - work.ops))
			end
		end
	end
	maintenance(s)
	prune_finished(s)
	for _, hook in pairs(M.step_hooks) do hook(s) end
end

script.on_nth_tick(STEP_TICKS, on_step)

--------------------------------------------------------------------------------
--- arrivals: outputs of processing patterns that come back into the network (N.on_arrival)
--------------------------------------------------------------------------------

--- net id -> key -> { job ids } of running jobs with processing steps that wait for outputs (rebuilt when a job
--- hands out processing work, closes or ends, or the graph changes: s.await = nil)
local function await_index(s)
	if s.await then return s.await end
	local idx = {}
	for _, id in ipairs(s.active) do
		local job = s.jobs[id]
		if job and not job.closing and job.status == "running" then
			local net
			for _, step in ipairs(job.steps) do
				if step.kind == "processing" and step.issued > 0 then
					net = net or job_network(job)
					if net then
						local keys = idx[net.id] or {}
						idx[net.id] = keys
						for _, r in ipairs(step.def.outputs) do
							local ids = keys[r.key] or {}
							keys[r.key] = ids
							if ids[#ids] ~= id then ids[#ids + 1] = id end
						end
					end
				end
			end
		end
	end
	s.await = idx
	return idx
end

--- what the jobs of `net` still wait for of `key`
local function awaiting(net, key)
	local s = storage.fork_ae2
	if not s then return 0 end
	local keys = await_index(s)[net.id]
	local ids = keys and keys[key]
	if not ids then return 0 end
	local n = 0
	for _, id in ipairs(ids) do
		local job = s.jobs[id]
		for _, step in ipairs(job and job.steps or {}) do
			if step.kind == "processing" then
				local per = P.output_of(step.def, key)
				if per > 0 then n = n + math.max(0, step.issued * per - (step.received[key] or 0)) end
			end
		end
	end
	return n
end

local function on_arrival(net, key, count)
	local s = storage.fork_ae2
	if not s then return 0 end
	local keys = await_index(s)[net.id]
	local ids = keys and keys[key]
	if not ids then return 0 end
	local left = count
	for _, id in ipairs(ids) do
		local job = s.jobs[id]
		if job and not job.closing and job.status == "running" then
			local got = credit(job, key, left)
			if got > 0 then
				pool_add(job, key, got)
				job.idle = 0
				left = left - got
			end
		end
		if left <= FLUID_EPS then break end
	end
	return count - left
end
N.on_arrival = on_arrival
N.awaiting = awaiting

--------------------------------------------------------------------------------
--- public interface
--------------------------------------------------------------------------------

--- Resources the network can craft: { key, ... } (items by name, fluids as "fluid/<name>"), and the
--- table of patterns the network cannot use: { total = n, [reason] = n }
function M.craftable(net)
	local s = state()
	local p = ensure_patterns(s)[net.id]
	if not p then return {}, { total = 0 } end
	local keys = {}
	for key in pairs(p.items) do
		if proto_of(key) then keys[#keys + 1] = key end
	end
	table.sort(keys)
	return keys, p.ignored
end

--- Sprite path, localised name and kind of a resource key (nil when the prototype is gone)
function M.describe(key)
	local proto = proto_of(key)
	if not proto then return nil end
	if is_fluid(key) then
		return { key = key, name = fluid_name(key), fluid = true, sprite = "fluid/" .. fluid_name(key), localised_name = proto.localised_name }
	end
	return { key = key, name = key, fluid = false, sprite = "item/" .. key, localised_name = proto.localised_name }
end

--- Crafting CPUs of the network: CPUs, free job slots, powered CPUs, job slots (a base CPU has one)
function M.cpu_summary(net)
	local s = state()
	local total, free, powered, slots = 0, 0, 0, 0
	for _, rec in pairs(cpus_in(s, net)) do
		total = total + 1
		local n = cpu_slots(rec)
		slots = slots + n
		free = free + math.max(0, n - cpu_load(rec))
		if cpu_powered(rec.entity) then powered = powered + 1 end
	end
	return total, free, powered, slots
end

--- true when a powered CPU of the network has a free job slot (a new job would run at once)
function M.free_slot(net)
	local s = state()
	for _, rec in pairs(cpus_in(s, net)) do
		if cpu_powered(rec.entity) and cpu_load(rec) < cpu_slots(rec) then return true end
	end
	return false
end

--- the id of an active job of the network that crafts `key`, nil if there is none
function M.active_job_for(net, key)
	local s = state()
	for _, id in pairs(s.active) do
		local job = s.jobs[id]
		if job and job.item == key and not job.closing then
			local jn = job_network(job)
			if jn and jn.id == net.id then return id end
		end
	end
	return nil
end

--- `fresh` rescans all pattern providers first (user actions); the GUI preview uses the cache
--- that the round robin rescan keeps current.
function M.plan(net, key, amount, fresh)
	local s = state()
	if not (proto_of(key) and amount and amount >= 1) then return nil end
	if fresh then refresh_providers(s) end
	return make_plan(s, net, key, math.floor(amount))
end

--- the job step of a planned step
local function job_step_of(st)
	local step = { pid = st.pid, def = st.def, kind = st.def.kind, recipe = st.def.recipe, runs = st.runs, issued = 0, done = 0 }
	if step.kind == "processing" then step.received = {} end
	return step
end

--- Start a job for `amount` of `key` in the network of `entity` (a network member such as the
--- terminal). `owner`: unit number of the level maintainer that asked for it (nil for a player).
--- Returns the job id, or nil, a reason key and the plan.
function M.start(entity, key, amount, owner)
	local s = state()
	local net = network_of(entity)
	if not net then return nil, "no-network" end
	amount = math.floor(tonumber(amount) or 0)
	if amount < 1 then return nil, "bad-amount" end
	if amount > (is_fluid(key) and MAX_FLUID_AMOUNT or MAX_AMOUNT) then return nil, "too-many" end
	if not proto_of(key) then return nil, "no-pattern" end
	local cpus = cpus_in(s, net)
	if #cpus == 0 then return nil, "no-cpu" end
	refresh_providers(s)
	local plan = make_plan(s, net, key, amount)
	if plan.no_pattern then return nil, "no-pattern", plan end
	if not plan.ok then return nil, "missing", plan end

	local pool, taken = {}, {}
	local function undo()
		for _, k in pairs(taken) do
			if is_fluid(k) then store_fluid(net, fluid_name(k), pool[k]) else store_item(net, k, QUALITY, pool[k]) end
		end
	end
	for k, count in pairs(plan.reserve) do
		local removed
		if is_fluid(k) then
			removed = fluids.remove(net, fluid_name(k), count + FLUID_MARGIN)   -- a little extra covers fixed point rounding
		else
			removed = N.extract(net, k, QUALITY, count)
		end
		if removed > 0 then pool[k] = removed taken[#taken + 1] = k end
		if removed + FLUID_EPS < count then                     -- storage changed under us: undo
			undo()
			return nil, "stock-changed", plan
		end
	end
	local steps, total = {}, 0
	for _, st in pairs(plan.steps) do
		steps[#steps + 1] = job_step_of(st)
		total = total + st.runs
	end
	local id = s.next_job
	s.next_job = id + 1
	s.jobs[id] = {
		id = id, item = key, amount = amount, status = "queued", steps = steps, pool = pool, leases = {},
		total_runs = total, done_runs = 0, idle = 0, tick = game.tick,
		surface = entity.surface.index, force = entity.force.index,
		pos = { x = entity.position.x, y = entity.position.y }, owner = owner, anchor = entity,
	}
	s.active[#s.active + 1] = id
	assign_cpus(s)
	return id, nil, plan
end

function M.cancel(id)
	local s = state()
	local job = s.jobs[id]
	if not job then return false end
	if job.status == "queued" and not job.closing then
		--- never ran: nothing is in a machine, give the pool back at the next step
		job.closing = "cancelled"
		job.reason = { "fork-me-craft.reason-cancelled" }
		job.closing_steps = 0
		job.status = "running"
		s.await = nil
		return true
	end
	begin_closing(s, job, "cancelled", { "fork-me-craft.reason-cancelled" })
	return true
end

--- Jobs of the network (newest first) as plain data for the GUI and tests; `item` is the resource key
function M.jobs(net)
	local s = state()
	local out = {}
	local function add(id)
		local job = s.jobs[id]
		if job then
			local jn = job_network(job)
			if jn and jn.id == net.id then
				local status = job.status
				if job.closing then status = job.closing == "done" and "delivering" or "cancelling" end
				out[#out + 1] = {
					id = job.id, item = job.item, amount = job.amount, status = status, wait = job.wait,
					reason = job.reason, done = job.done_runs, total = job.total_runs,
					active = job.status == "queued" or job.status == "running", owner = job.owner,
				}
			end
		end
	end
	for _, id in pairs(s.active) do add(id) end
	for _, id in pairs(s.finished) do add(id) end
	table.sort(out, function(a, b) return a.id > b.id end)
	return out
end

function M.job(id)
	local s = state()
	local job = s.jobs[id]
	if not job then return nil end
	local rec = job.cpu and s.cpus[job.cpu]
	local steps = {}
	for i, st in ipairs(job.steps) do
		steps[i] = { pid = st.pid, kind = st.kind, recipe = st.recipe, runs = st.runs, issued = st.issued, done = st.done,
			received = st.received }
	end
	return { id = job.id, item = job.item, amount = job.amount, status = job.status, closing = job.closing,
		wait = job.wait, done = job.done_runs, total = job.total_runs, pool = job.pool,
		leases = #job.leases, owner = job.owner, cpu = job.cpu, ops = job_ops(s, job),
		cpu_name = rec and rec.entity.valid and rec.entity.name or nil, steps = steps, reason = job.reason, problem = job.problem }
end

--- LocalisedString "12x A, 3x B, 100 C (fluid)" for a { key -> count } table (at most `limit` entries)
function M.item_list(counts, limit)
	local keys = {}
	for key in pairs(counts) do keys[#keys + 1] = key end
	table.sort(keys)
	local out = { "" }
	for i, key in ipairs(keys) do
		if i > (limit or 6) then out[#out + 1] = ", ..." break end
		local proto = proto_of(key)
		local sep = i > 1 and ", " or ""
		if is_fluid(key) then                            -- one nested string per entry: at most limit + 1 parameters
			out[#out + 1] = { "", sep .. fluids.format(counts[key]) .. " ", proto and proto.localised_name or fluid_name(key) }
		else
			out[#out + 1] = { "", sep .. counts[key] .. "x ", proto and proto.localised_name or key }
		end
	end
	return out
end

--- LocalisedString with the reasons of the ignored table, "" when nothing is ignored
function M.ignored_list(ignored)
	local out = { "" }
	local reasons = {}
	for reason, n in pairs(ignored or {}) do
		if reason ~= "total" and n > 0 then reasons[#reasons + 1] = reason end
	end
	table.sort(reasons)
	for i, reason in ipairs(reasons) do
		if i > 1 then out[#out + 1] = ", " end
		out[#out + 1] = { "fork-me-craft.ignored-" .. reason, ignored[reason] }
	end
	return out
end

--------------------------------------------------------------------------------
--- the pattern provider: slots, window data, settings, blueprints, removal
--------------------------------------------------------------------------------

local function register(s, entity)
	if entity.name == PROVIDER then
		local unit = entity.unit_number
		if not s.providers[unit] then
			s.providers[unit] = new_provider(entity)
			s.plist[#s.plist + 1] = unit
		end
		scan_provider(s.providers[unit])
		s.dirty = true
	elseif cpu_spec(entity.name) then
		local unit = entity.unit_number
		s.cpus[unit] = s.cpus[unit] or { entity = entity, jobs = {} }
	end
end

--- the provider's record (registered on demand), nil for anything else
local function provider_record(entity)
	if not (entity and entity.valid and entity.name == PROVIDER) then return nil end
	local s = state()
	if not s.providers[entity.unit_number] then register(s, entity) end
	return s.providers[entity.unit_number]
end

--- the item stack definition of the pattern in a slot (a broken one keeps its raw tags)
local function slot_stack(raw)
	local def = P.normalize(raw)
	if def then return P.stack_def(def) end
	return { name = P.ENCODED, count = 1, tags = { [P.TAG] = raw } }
end

local function changed(p)
	scan_provider(p)
	state().dirty = true
end

--- Put the encoded pattern in `stack` into `slot` of a provider (the first free one when nil). The stack is
--- emptied. Returns the slot, or nil and a reason ("no-provider", "not-a-pattern", "provider-full",
--- "pattern-slot-taken").
function M.insert_pattern(provider, stack, slot)
	local p = provider_record(provider)
	if not p then return nil, "no-provider" end
	if not P.is_encoded(stack) then return nil, "not-a-pattern" end
	if slot == nil then
		for i = 1, SLOTS do
			if not p.slots[i] then slot = i break end
		end
		if not slot then return nil, "provider-full" end
	end
	if slot < 1 or slot > SLOTS then return nil, "pattern-slot-taken" end
	if p.slots[slot] then return nil, "pattern-slot-taken" end
	p.slots[slot] = P.read(stack) or {}
	if p.pending then p.pending[slot] = nil end
	stack.clear()
	changed(p)
	return slot
end

--- Take the pattern out of `slot` into `target` (an empty LuaItemStack, or anything with insert: LuaInventory,
--- LuaPlayer). Returns true when it was moved.
function M.take_pattern(provider, slot, target)
	local p = provider_record(provider)
	local raw = p and p.slots[slot]
	if not raw then return false end
	local def = slot_stack(raw)
	if target.object_name == "LuaItemStack" then
		if target.valid_for_read or not target.set_stack(def) then return false end
	elseif target.insert(def) < 1 then
		return false
	end
	p.slots[slot] = nil
	changed(p)
	return true
end

--- A click on a pattern slot of the provider window: with an encoded pattern in the cursor it goes into the slot
--- (a pattern there is swapped into the cursor); with an empty cursor the pattern goes into the cursor (shift:
--- into the inventory); an empty slot waiting for a blueprint pattern forgets it. Returns a reason on failure.
function M.provider_click(cursor, inventory, provider, slot, shift)
	local p = provider_record(provider)
	if not p then return "no-provider" end
	if cursor and cursor.valid_for_read then
		if not P.is_encoded(cursor) then return "not-a-pattern" end
		if p.slots[slot] then                         -- swap: the pattern in the slot goes into the cursor
			local held = game.create_inventory(1)
			held[1].transfer_stack(cursor)
			M.take_pattern(provider, slot, cursor)
			M.insert_pattern(provider, held[1], slot)
			if held[1].valid_for_read then cursor.transfer_stack(held[1]) end
			held.destroy()
			return nil
		end
		local _, why = M.insert_pattern(provider, cursor, slot)
		return why
	end
	if not p.slots[slot] then
		if p.pending and p.pending[slot] then
			p.pending[slot] = nil
			if next(p.pending) == nil then p.pending = nil end
		end
		return nil
	end
	if shift then
		if not (inventory and M.take_pattern(provider, slot, inventory)) then return "inventory-full" end
	elseif cursor then
		if not M.take_pattern(provider, slot, cursor) then return "inventory-full" end
	end
	return nil
end

--- the open key on a provider with an encoded pattern in the cursor: into the first free slot (true when it did
--- something; else the provider window opens)
function M.quick_insert(player, entity)
	if not (entity and entity.valid and entity.name == PROVIDER) then return false end
	local cursor = player.cursor_stack
	if not P.is_encoded(cursor) then return false end
	if not player.can_reach_entity(entity) then return true end
	local _, why = M.insert_pattern(entity, cursor)
	if why then player.create_local_flying_text{ text = { "fork-me-net.error-" .. why }, create_at_cursor = true } end
	return true
end

function M.get_priority(entity)
	local p = provider_record(entity)
	return p and p.priority or 0
end

function M.set_priority(entity, priority)
	local p = provider_record(entity)
	if not p then return false end
	p.priority = math.max(-1000, math.min(1000, math.floor(tonumber(priority) or 0)))
	changed(p)
	return true
end

--- The pattern provider window's data: the slots (pattern, kind, recipe, inputs, outputs, status), the patterns
--- waiting for a blank (blueprint), the machines and chests next to it, the priority.
function M.provider_info(entity)
	local p = provider_record(entity)
	if not p then return nil end
	scan_provider(p)
	local slots = {}
	for slot = 1, SLOTS do
		local raw = p.slots[slot]
		local st = p.status[slot]
		if raw then
			local def = P.normalize(raw)
			slots[slot] = { kind = raw.kind, recipe = raw.recipe, inputs = def and def.inputs or raw.inputs,
				outputs = def and def.outputs or raw.outputs, id = def and P.id_of(def) or nil,
				ok = st and st.ok or false, reason = st and st.reason or nil, machines = st and st.machines or 0 }
		elseif p.pending and p.pending[slot] then
			local def = p.pending[slot]
			slots[slot] = { pending = true, kind = def.kind, recipe = def.recipe, inputs = def.inputs, outputs = def.outputs }
		end
	end
	local machines = {}
	local s = state()
	for _, m in ipairs(neighbors_of(entity)) do
		local r = is_machine(m) and m.get_recipe() or nil
		machines[#machines + 1] = { name = m.name, unit = m.unit_number, type = m.type, recipe = r and r.name or nil,
			busy = s.busy[m.unit_number] }
	end
	return { slots = slots, slot_count = SLOTS, machines = machines, priority = p.priority or 0, network = p.net ~= nil }
end

--- the CPU window's data: its tier (job slots, speed), power, and the jobs it runs or that wait in its network
function M.cpu_info(entity)
	local s = state()
	if not (entity and entity.valid and cpu_spec(entity.name)) then return nil end
	register(s, entity)
	local rec = s.cpus[entity.unit_number]
	local spec = cpu_spec(entity.name)
	local jobs = {}
	for id in pairs(cpu_jobs(rec)) do
		local j = M.job(id)
		if j then jobs[#jobs + 1] = j end
	end
	table.sort(jobs, function(a, b) return a.id < b.id end)
	local waiting = {}
	local net = network_of(entity)
	if net then
		for _, j in ipairs(M.jobs(net)) do
			if j.status == "queued" then waiting[#waiting + 1] = j end
		end
	end
	return { slots = spec.jobs, speed = spec.speed, powered = cpu_powered(entity), network = net ~= nil,
		jobs = jobs, waiting = waiting }
end

--- settings paste (shift right click, shift left click): the priority. Patterns are items: they are not copied.
function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (src and src.valid and dst and dst.valid and src.name == PROVIDER and dst.name == PROVIDER) then return end
	M.set_priority(dst, M.get_priority(src))
end

--- The blueprint settings of a provider: { priority, patterns = { ["slot"] = pattern } } (its patterns and those
--- still waiting for a blank). A provider built from it encodes them from blank patterns of its network.
function M.provider_settings(entity)
	local p = provider_record(entity)
	if not p then return nil end
	local patterns = {}
	for slot = 1, SLOTS do
		local def = p.slots[slot] and P.normalize(p.slots[slot]) or (p.pending and p.pending[slot])
		if def then patterns[tostring(slot)] = def end
	end
	return { priority = p.priority or 0, patterns = patterns }
end

--- Apply blueprint settings to a provider: the priority, and the patterns as "pending" (each costs a blank
--- pattern of the network when it is encoded). Old blueprint tags (`fork_ae2_recipe`, 0.4.1 and older: the furnace
--- recipe choice) give a processing pattern of that recipe.
function M.apply_settings(entity, settings, old_recipe)
	local p = provider_record(entity)
	if not p then return false end
	if type(settings) == "table" then
		p.priority = math.max(-1000, math.min(1000, math.floor(tonumber(settings.priority) or 0)))
		for key, raw in pairs(type(settings.patterns) == "table" and settings.patterns or {}) do
			local slot = tonumber(key)
			local def = P.normalize(raw)
			if def and slot and slot >= 1 and slot <= SLOTS and not p.slots[slot] then
				p.pending = p.pending or {}
				p.pending[slot] = def
			end
		end
	end
	if type(old_recipe) == "string" and prototypes.recipe[old_recipe] then
		local inputs, outputs = P.recipe_rows(old_recipe)
		local def = P.processing(inputs, outputs, old_recipe)
		if def then
			for slot = 1, SLOTS do
				if not p.slots[slot] and not (p.pending and p.pending[slot]) then
					p.pending = p.pending or {}
					p.pending[slot] = def
					break
				end
			end
		end
	end
	changed(p)
	return true
end

--- A blueprint with providers carries their settings as entity tag; the fluid interfaces (fluids module)
--- and the blueprint hooks (level maintainers, circuit interfaces, drives, buses) tag theirs. `bp` is the blueprint
--- (item stack or record), `mapping` blueprint entity index -> source entity.
function M.tag_blueprint(bp, mapping)
	if not (bp and bp.valid and mapping) then return end
	for index, entity in pairs(mapping) do
		if entity.valid and entity.name == PROVIDER then
			local settings = M.provider_settings(entity)
			if settings and (settings.priority ~= 0 or next(settings.patterns)) then
				bp.set_blueprint_entity_tag(index, BP_TAG, settings)
			end
		end
	end
	for _, hook in pairs(M.blueprint_hooks) do hook(bp, mapping) end
end

local function blueprint_usable(bp)
	if not (bp and bp.valid) then return false end
	if bp.object_name == "LuaRecord" then return true end
	return bp.valid_for_read and bp.is_blueprint
end

function M.on_player_setup_blueprint(event)
	local player = game.get_player(event.player_index)
	local bp = event.record or event.stack
	if not blueprint_usable(bp) and player then bp = player.blueprint_to_setup end
	if not blueprint_usable(bp) and player then bp = player.cursor_stack end
	if not blueprint_usable(bp) then return end
	--- the mapping can be stale when another mod changed the blueprint: never break blueprinting
	pcall(function() M.tag_blueprint(bp, event.mapping.get()) end)
end

--- `tags`: the blueprint tags of a built ghost; `source`: the original of a cloned entity (its priority is copied,
--- its patterns are items and stay with it)
function M.on_built(entity, tags, source)
	if not (entity and entity.valid and (entity.name == PROVIDER or cpu_spec(entity.name))) then return end
	register(state(), entity)
	if entity.name ~= PROVIDER then return end
	if type(tags) == "table" and (tags[BP_TAG] or tags[OLD_TAG]) then
		M.apply_settings(entity, tags[BP_TAG], tags[OLD_TAG])
	elseif source and source.valid and source.name == PROVIDER then
		M.set_priority(entity, M.get_priority(source))
	end
end

--- A provider is mined (its patterns go into `buffer`), destroyed or removed by a script (`buffer` nil: they are
--- dropped on the ground). Patterns waiting for a blank are forgotten (they were never items).
function M.on_removed(entity, buffer)
	if not (entity and entity.valid and entity.name == PROVIDER) then return end
	local s = storage.fork_ae2
	local p = s and s.providers[entity.unit_number]
	if not p then return end
	for slot = 1, SLOTS do
		local raw = p.slots[slot]
		if raw then
			local def = slot_stack(raw)
			local got = buffer and buffer.valid and buffer.insert(def) or 0
			if got < 1 then spill(entity, def) end
			p.slots[slot] = nil
		end
	end
	s.providers[entity.unit_number] = nil
	remove_value(s.plist, entity.unit_number)
	s.dirty = true
end

--- A pattern machine mined while a job uses it: the fluid in its boxes would vanish with the
--- entity (items are collected by the game), so it goes back into the job's pool first. The job
--- then fails at its next step ("a pattern machine was removed") and returns the pool.
function M.on_mined(entity)
	local s = storage.fork_ae2
	if not (s and entity and entity.valid and entity.unit_number) then return end
	local id = s.busy[entity.unit_number]
	local job = id and s.jobs[id]
	if not job then return end
	for _, lease in pairs(job.leases) do
		if lease.unit == entity.unit_number then
			local step = job.steps[lease.step]
			collect_output(job, job_network(job), entity, lease.fluid)
			if step then take_back_input(job, entity, step_ingredients(step), lease.fluid) end
			return
		end
	end
end
fluids.mined_hooks[#fluids.mined_hooks + 1] = M.on_mined

--------------------------------------------------------------------------------
--- migration (issue #80): providers of 0.4.1 and older read the recipe of the machines next to them (furnaces:
--- a recipe chosen in the provider). Each gets encoded patterns for what it provided, so running setups, level
--- maintainers and saved jobs keep working. Logged as FORK-ME-MIGRATE lines.
--------------------------------------------------------------------------------

--- the recipe an old provider stood for with a furnace: the choice when the furnace can make it, else the recipe
--- it runs, else the one it smelted last (0.4.1 rules; research is not asked: a processing pattern does not need
--- it, and the update resets the technology effects before this runs)
local function old_furnace_recipe(m, choice)
	local proto = choice and prototypes.recipe[choice]
	if proto and m.prototype.crafting_categories[proto.category] and not proto.hidden
		and not has_fluid(proto.ingredients, proto.products) then
		return choice
	end
	local recipe = m.get_recipe()
	if recipe then return recipe.name end
	local previous = m.previous_recipe
	local name = previous and previous.name
	if name ~= nil and type(name) ~= "string" then name = name.name end
	return name
end

--- encoded patterns for what an old provider provided: a crafting pattern per assembling machine recipe, a
--- processing pattern per furnace recipe (each once). Returns the list.
local function old_patterns(entity, choice)
	local out, seen = {}, {}
	for _, m in ipairs(neighbors_of(entity)) do
		local def
		if m.type == "assembling-machine" then
			local r = m.get_recipe()
			if r then def = P.normalize{ kind = "crafting", recipe = r.name } end
		elseif m.type == "furnace" then
			local name = old_furnace_recipe(m, choice)
			if name and prototypes.recipe[name] then
				local inputs, outputs = P.recipe_rows(name)
				def = P.processing(inputs, outputs, name)
			end
		end
		if def then
			local id = P.id_of(def)
			if not seen[id] then
				seen[id] = true
				out[#out + 1] = def
			end
		end
	end
	return out
end

local function migrate_providers(s, choices)
	local n, total = 0, 0
	for _, unit in ipairs(s.plist) do
		local p = s.providers[unit]
		if p and p.entity.valid then
			local list = old_patterns(p.entity, choices[unit])
			local names = {}
			for i, def in ipairs(list) do
				if i <= SLOTS then
					p.slots[i] = def
					names[#names + 1] = def.kind .. " " .. (def.recipe or P.id_of(def))
				else
					names[#names + 1] = "dropped " .. P.id_of(def)
				end
			end
			if #list > 0 then
				n = n + 1
				total = total + math.min(#list, SLOTS)
				log("FORK-ME-MIGRATE: patterns: provider " .. unit .. " at " .. p.entity.position.x .. "," .. p.entity.position.y
					.. " on " .. p.entity.surface.name .. ": " .. table.concat(names, ", "))
			end
			scan_provider(p)
		end
	end
	log("FORK-ME-MIGRATE: patterns: " .. total .. " encoded patterns in " .. n .. " of " .. #s.plist .. " pattern providers")
end

--- job steps and leases of older saves name a recipe: they get the pattern that makes it now (the crafting
--- pattern of the recipe, or the processing pattern migrated from a furnace recipe)
local function migrate_job(s, job)
	local net = job_network(job)
	local defs = net and (s.patterns[net.id] or NO_PATTERNS).defs or {}
	for _, step in ipairs(job.steps) do
		if not step.pid and step.recipe then
			local pid, def = "c/" .. step.recipe, nil
			def = defs[pid]
			if not def then
				for id, d in pairs(defs) do
					if d.kind == "processing" and d.recipe == step.recipe then pid, def = id, d break end
				end
			end
			def = def or P.normalize{ kind = "crafting", recipe = step.recipe }
			if def then
				step.pid, step.def, step.kind = P.id_of(def), def, def.kind
				if step.kind == "processing" then
					step.received = {}
					for _, r in ipairs(def.outputs) do step.received[r.key] = step.done * r.amount end
				end
			end
		end
	end
	for _, lease in pairs(job.leases) do
		local step = job.steps[lease.step]
		if step and step.def and not lease.kind then
			lease.pid, lease.kind = step.pid, step.kind
			lease.chosen = nil
			if lease.kind == "processing" then
				lease.given = {}
				for _, ing in pairs(P.ingredients(step.def)) do
					lease.given[key_of(ing)] = (ing.type == "fluid" and fixed_up(ing.amount) or ing.amount) * lease.runs
				end
				lease.finished0 = nil
			end
		end
	end
end

--- Rebuild the registries from the world, drop stale references, and repair the job books.
--- Jobs and their pools are kept; provider slots, blueprint patterns and priorities are kept by unit number.
function M.on_configuration_changed()
	local s = state()
	local legacy = s.pattern_version ~= PATTERN_VERSION
	local kept, choices = {}, {}
	for unit, p in pairs(s.providers) do
		if legacy then
			if p.recipe and prototypes.recipe[p.recipe] then choices[unit] = p.recipe end
		else
			kept[unit] = p
		end
	end
	s.providers, s.plist, s.pcursor, s.patterns, s.dirty, s.await = {}, {}, 1, {}, true, nil
	s.cpus = {}
	local names = cpu_names()
	names[#names + 1] = PROVIDER
	local all = {}
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = names }) do all[#all + 1] = e end
	end
	table.sort(all, function(a, b) return a.unit_number < b.unit_number end)
	for _, e in ipairs(all) do
		if e.name == PROVIDER and kept[e.unit_number] then
			local k = kept[e.unit_number]
			s.providers[e.unit_number] = new_provider(e)
			s.plist[#s.plist + 1] = e.unit_number
			local p = s.providers[e.unit_number]
			p.slots, p.pending, p.priority = k.slots or {}, k.pending, k.priority or 0
			kept[e.unit_number] = nil
		end
		register(s, e)
	end
	--- providers whose entity is gone without an event: their patterns are dropped where they stood
	for _, k in pairs(kept) do
		if k.slots and next(k.slots) then vanish_provider(s, k) end
	end
	if legacy then
		migrate_providers(s, choices)
		s.pattern_version = PATTERN_VERSION
	end
	refresh_providers(s)
	ensure_patterns(s)
	s.busy = {}
	for _, id in pairs(shallow(s.active)) do
		local job = s.jobs[id]
		if not job then
			remove_value(s.active, id)
		else
			if legacy then migrate_job(s, job) end
			job.cpu = nil
			if job.status == "running" and not job.closing then job.status = "queued" end
			for _, lease in pairs(shallow(job.leases)) do
				local step = job.steps[lease.step]
				if lease.machine.valid and step and step.def then
					s.busy[lease.unit] = job.id
					if lease.fluid == nil then lease.fluid = { inputs = {}, outputs = {} } end   -- leases from before fluid support
				else
					remove_value(job.leases, lease)
					if not job.closing then begin_closing(s, job, "failed", { "fork-me-craft.reason-machine-lost" }) end
				end
			end
			for _, step in pairs(job.steps) do
				if not (step.def and P.normalize(step.def)) then
					begin_closing(s, job, "failed", { "fork-me-craft.reason-recipe-gone" })
					break
				end
			end
			for key in pairs(shallow_map(job.pool)) do
				if not proto_of(key) then job.pool[key] = nil end
			end
		end
	end
	for _, rec in pairs(s.cpus) do rec.job, rec.jobs = nil, {} end
end

--- Other mods and the devcheck runtime test use the same code paths. Resource keys are item names
--- or "fluid/<fluid name>".
remote.add_interface("gregtorio-me-autocraft", {
	--- { ok, missing = {key -> count}, runs, steps, loops, reserve, pids } or nil
	plan = function(entity, key, amount)
		local net = network_of(entity)
		local p = net and M.plan(net, key, amount, true)
		if not p then return nil end
		local pids = {}
		for i, st in ipairs(p.steps) do pids[i] = st.pid end
		return { ok = p.ok, missing = p.missing, runs = p.runs, steps = #p.steps, loops = p.loops,
			reserve = p.reserve, no_pattern = p.no_pattern, pids = pids }
	end,
	start = function(entity, key, amount)
		local id, why, p = M.start(entity, key, amount)
		return id, why, p and p.missing
	end,
	cancel = function(id) return M.cancel(id) end,
	job = function(id) return M.job(id) end,
	craftable = function(entity)
		local net = network_of(entity)
		if not net then return {} end
		return (M.craftable(net))
	end,
	--- { total = n, [reason] = n } of the patterns the network cannot use
	ignored = function(entity)
		local net = network_of(entity)
		if not net then return { total = 0 } end
		local _, ignored = M.craftable(net)
		return ignored
	end,
	--- CPUs, free job slots, powered CPUs, job slots
	cpus = function(entity)
		local net = network_of(entity)
		if not net then return 0, 0, 0, 0 end
		return M.cpu_summary(net)
	end,
	--- the jobs of the network (newest first): { id, item, amount, status, wait, done, total, active, owner }
	jobs = function(entity)
		local net = network_of(entity)
		return net and M.jobs(net) or {}
	end,
	--- the pattern provider (issue #80): slots, the window's slot click, priority, blueprint settings
	provider_info = function(provider) return M.provider_info(provider) end,
	insert_pattern = function(provider, stack, slot) return M.insert_pattern(provider, stack, slot) end,
	take_pattern = function(provider, slot, target) return M.take_pattern(provider, slot, target) end,
	provider_click = function(cursor, inventory, provider, slot, shift) return M.provider_click(cursor, inventory, provider, slot, shift) end,
	get_priority = function(provider) return M.get_priority(provider) end,
	set_priority = function(provider, priority) return M.set_priority(provider, priority) end,
	provider_settings = function(provider) return M.provider_settings(provider) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	tag_blueprint = function(bp, mapping) M.tag_blueprint(bp, mapping) end,
	--- the provider removal of the build events (mined: `buffer`, destroyed: nil)
	on_removed = function(provider, buffer) M.on_removed(provider, buffer) end,
	--- what the jobs of the network of `entity` still wait for of `key` (processing outputs)
	awaiting = function(entity, key)
		local net = network_of(entity)
		return net and awaiting(net, key) or 0
	end,
})

return M
