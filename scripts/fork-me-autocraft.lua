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
--- CPU (issue #6, docs/ME-REWORK.md "Crafting CPUs as multiblocks"): a group of touching crafting blocks (1x1) that
---   is a solid rectangle with at least one crafting storage is a Crafting CPU. It runs one job, which must fit its
---   bytes (plan.bytes, AE2's rule); its co-processors make it hand more work to the machines per step (speed). The
---   groups are kept up to date on build and removal (add_block / remove_block), never scanned. The single-entity CPUs
---   of issue #38 (mod-data "fork-me-autocraft", cpus) are legacy blocks: several jobs, their speed, no byte limit.
---   A job whose CPU changes or goes pauses ("queued") with everything it holds and takes the next CPU that fits.
--- Planning: recursive over the patterns, storage first, loops recognised, missing raw
---   materials reported before anything is started (M.plan). Items and fluids are both
---   "resources", keyed by the item name or "fluid/<name>" (fluid storage: fork-me-fluids.lua).
--- Job: at start the resources taken from storage are removed from the network into the job's own
---   pool (storage.fork_ae2.jobs[id].pool). Each step the CPU hands batches of ingredients
---   to idle pattern machines (machine.insert, fluid boxes set by index), waits until the machine
---   is idle again, moves the products into the pool, and at the end everything left in the pool
---   (result and by-products) is stored in the network. Cancel and failure give the pool back
---   the same way.
--- Work (issue #5: spread over the ticks, M.on_tick from control.lua): each tick the setting "crafting jobs per
---   tick" jobs are stepped, round robin, each at most once per STEP_TICKS ticks; a step makes STEP_OPS machine
---   interactions times the speed of the job's CPU tier per STEP_TICKS since the job's last step (up to
---   MAX_CATCH_UP steps' worth, so a job that waits for its turn catches up). One provider is rescanned every
---   PROVIDER_SCAN_TICKS ticks, CPUs are assigned every STEP_TICKS ticks, and the tick hooks run every tick (level
---   maintainers and circuit interfaces, scripts/fork-me-circuit.lua, on their own queues).
--- State: storage.fork_ae2 only (entities, counts, plain data). GUI state lives in the GUI.
--------------------------------------------------------------------------------

local fluids = require("scripts.fork-me-fluids")
local N = require("scripts.fork-me-network")
local P = require("scripts.fork-me-patterns")
local Sched = require("scripts.fork-me-schedule")

local M = {}

--- functions(s, tick) run every tick (fork-me-circuit.lua); registered at load time, nothing is stored
M.step_hooks = {}
--- functions(bp, mapping) run when a blueprint is set up, after the providers are tagged
M.blueprint_hooks = {}

local STEP_TICKS = 20           -- a job is stepped at most this often
local STEP_OPS = 6              -- machine hand-overs / collections per job and step (base CPU)
local MAX_CATCH_UP = 3          -- steps' worth of operations a late job may make at once
local MAX_BATCH = 16            -- crafts handed to one machine at once
local PROVIDER_SCAN_TICKS = 2   -- one provider rescan this often (8 per 20 ticks before issue #5)
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

--- issue #6: the crafting blocks (name -> { bytes, coprocessors, monitor, power }) and the byte rule's numbers
local blocks_cache, fluid_per_byte, max_coprocessors
local function block_specs()
	if not blocks_cache then
		local md = prototypes.mod_data["fork-me-autocraft"]
		local d = md and md.data or {}
		blocks_cache = d.blocks or {}
		fluid_per_byte = d.fluid_units_per_byte or 10
		max_coprocessors = d.max_coprocessors or 16
	end
	return blocks_cache
end

local function block_spec(name)
	return block_specs()[name]
end

local function cpu_names()
	local names = {}
	for name in pairs(cpu_specs()) do names[#names + 1] = name end
	for name in pairs(block_specs()) do names[#names + 1] = name end
	table.sort(names)
	return names
end

--------------------------------------------------------------------------------
--- resource keys: item name, or the storage key of a fluid ("fluid/<name>", "fluid/<name>@<degrees>": issue #159)
--------------------------------------------------------------------------------

local FLUID_PREFIX = "fluid/"

--- Issue #159: a fluid ingredient without a temperature takes the fluid at any temperature in its range (none: every
--- temperature); its key is the default one when the default is in the range, else the range's end next to it. A
--- fluid ingredient with a temperature, and every fluid product, is the key of that temperature (none: the default).
local function key_of(ing)
	if ing.type == "fluid" then
		local t = ing.temperature
		if t == nil and (ing.minimum_temperature or ing.maximum_temperature) then
			local d = N.fluid_range(ing.name) or 15
			if ing.minimum_temperature and d < ing.minimum_temperature then t = ing.minimum_temperature
			elseif ing.maximum_temperature and d > ing.maximum_temperature then t = ing.maximum_temperature end
		end
		return N.fluid_key(ing.name, t)
	end
	return ing.name
end

--- Issue #159: may a fluid ingredient take other temperatures than its key's? true and the range (nil: open) for a fluid
--- ingredient without an exact temperature; nil for items, exact temperatures and products
local function ing_flex(ing)
	if ing.type ~= "fluid" or ing.temperature ~= nil then return nil end
	return true, ing.minimum_temperature, ing.maximum_temperature
end

--- does the storage key `key` of fluid `name` fit a flexible input (lo, hi)?
local function flex_fits(key, name, lo, hi)
	if not (N.is_fluid_key(key) and N.fluid_name(key) == name) then return false end
	local t = N.fluid_temperature(key)
	return (not lo or t >= lo - 1e-6) and (not hi or t <= hi + 1e-6)
end

--- can a fluid ingredient be had at all? (its range must meet the fluid's [default, max]: the engine clamps temperatures)
local function fluid_reachable(ing)
	local d, m = N.fluid_range(ing.name)
	if not d then return false end
	local lo, hi = ing.minimum_temperature, ing.maximum_temperature
	if ing.temperature then lo, hi = ing.temperature, ing.temperature end
	return math.max(lo or d, d) <= math.min(hi or m, m) + 1e-6
end

local function is_fluid(key)
	return key:sub(1, #FLUID_PREFIX) == FLUID_PREFIX
end

local function fluid_name(key)
	return N.fluid_name(key)
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

local function store_fluid(net, key, amount)
	N.no_arrival = true
	local n = fluids.insert_key(net, key, amount)
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

--- Issue #115: a machine's input and output inventory once per load (`get_inventory` makes a new object at every call; a
--- job step asks for them at every lease); weak keys, an object that turned invalid is made anew, nothing saved
local machine_invs = setmetatable({}, { __mode = "k" })
local function invs_of(machine)
	local c = machine_invs[machine]
	if not c then
		c = {}
		machine_invs[machine] = c
	end
	return c
end

local function input_inventory(machine)
	local c = invs_of(machine)
	local inv = c.inp
	if inv and inv.valid then return inv end
	local d = defines.inventory
	if machine.type == "container" or machine.type == "logistic-container" then inv = machine.get_inventory(d.chest)
	else inv = machine.get_inventory(machine.type == "furnace" and d.furnace_source or d.crafter_input) end
	c.inp = inv
	return inv
end

local function output_inventory(machine)
	local d = defines.inventory
	if machine.type == "container" or machine.type == "logistic-container" then return nil end
	local c = invs_of(machine)
	local inv = c.out
	if inv and inv.valid then return inv end
	inv = machine.get_inventory(machine.type == "furnace" and d.furnace_result or d.crafter_output)
	c.out = inv
	return inv
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

--- an item's stack size, nil when there is no such item (per load, issue #59 lever 3: a prototype read makes a new object)
local stack_size_cache = {}
local function stack_size_of(name)
	local n = stack_size_cache[name]
	if n == nil then
		local proto = prototypes.item[name]
		n = proto and proto.stack_size or false
		stack_size_cache[name] = n
	end
	return n or nil
end

--- The fluid boxes a machine uses for `ingredients` and `products`: which box takes which fluid ingredient and
--- which boxes hold the fluid products. Returns the map, or nil and the reason why the machine cannot be used:
--- "fluid-box" (no usable box, box too small, furnace, two-way box), "fluid-temperature" (a box wants a
--- temperature no fluid can have: issue #159, the network keeps every temperature), "fluid-pipes" (a used box is connected to a pipe: the network
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
			if not fluid_reachable(ing) then return nil, "fluid-temperature" end
			local capacity = fb.get_capacity(index)
			if capacity < fixed_up(ing.amount) then return nil, "fluid-box" end
			if connected(fb, index) then return nil, "fluid-pipes" end
			--- issue #159: `flex` (with `lo`, `hi`): any temperature of the fluid in that range may go in
			local flex, lo, hi = ing_flex(ing)
			inputs[#inputs + 1] = { key = key_of(ing), name = ing.name, amount = fixed_up(ing.amount), index = index, capacity = capacity,
				flex = flex, lo = lo, hi = hi }
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
--- then the entity has none and pipes are checked only after the switch. nil when it fits, else the reason. `machine` is a
--- scan's view of the machine (machine_view).
local function fluid_boxes_fit(machine, ingredients, products)
	if not has_fluid(ingredients, products) then return nil end
	if machine.type ~= "assembling-machine" then return "fluid-box" end
	local fb = machine.fluidbox
	local boxes = machine.facts.boxes
	local live = #fb == #boxes                     -- the entity's boxes are the prototype's, by index
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
	for _, e in pairs(ingredients) do if e.type == "fluid" then need_in = math.max(need_in, fixed_up(e.amount)) end end
	for _, e in pairs(products) do if e.type == "fluid" then need_out = math.max(need_out, e.amount or e.amount_max or 0) end end
	for _, e in pairs(ingredients) do
		if e.type == "fluid" and not fluid_reachable(e) then return "fluid-temperature" end
	end
	return fit(ins, ingredients, need_in) or fit(outs, products, need_out)
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

--- The ingredients and products of a pattern, made once per pattern definition (issue #43): a crafting pattern reads them
--- from the recipe prototype, which makes a new table of tables at every access (7 µs and garbage); nothing that uses them
--- changes them. Per load and weak: nothing is saved. The scan (issue #50, lever 6), the job steps and the planner use them.
local ing_cache = setmetatable({}, { __mode = "k" })
local prod_cache = setmetatable({}, { __mode = "k" })
local function def_ingredients(def)
	local l = ing_cache[def]
	if not l then
		l = P.ingredients(def)
		ing_cache[def] = l
	end
	return l
end
local function def_products(def)
	local l = prod_cache[def]
	if not l then
		l = P.products(def)
		prod_cache[def] = l
	end
	return l
end

--- Issue #50, lever 6: what target_for reads of a pattern alone, once per pattern definition (weak, per load; prototypes
--- do not change while the game runs): its recipe's category (crafting), stack_problem, the number of item ingredients and
--- whether an ingredient is a fluid.
local facts_cache = setmetatable({}, { __mode = "k" })
local function def_facts(def)
	local f = facts_cache[def]
	if not f then
		local ingredients = def_ingredients(def)
		local items, fluid_in = 0, false
		for _, i in pairs(ingredients) do
			if i.type == "item" then items = items + 1 elseif i.type == "fluid" then fluid_in = true end
		end
		--- issue #158: a processing pattern that names the recipe it was encoded from (P.normalize keeps only an existing
		--- one) switches an assembling machine to it, as a crafting pattern does: its category too
		local recipe = def.recipe and prototypes.recipe[def.recipe]
		f = { stack = stack_problem(ingredients), items = items, fluid_in = fluid_in,
			category = recipe and recipe.category or nil, switch = def.kind == "processing" and recipe ~= nil or nil }
		facts_cache[def] = f
	end
	return f
end

--- per machine prototype name (per load): its crafting categories and fixed recipe (entity.prototype makes a new object
--- and crafting_categories a new table at every access)
local machine_cache = {}
local function machine_facts(entity)
	local name = entity.name
	local m = machine_cache[name]
	if not m then
		local proto = entity.prototype
		m = { categories = proto.crafting_categories or {}, fixed = proto.fixed_recipe, boxes = proto.fluidbox_prototypes }
		machine_cache[name] = m
	end
	return m
end

--- Issue #50, lever 6: a scan's view of a machine next to a provider. The scan asks the same machine about each pattern slot
--- of the provider and nothing changes during a scan, so the view reads each value once and is dropped with the scan: the
--- type and unit number, and when first asked (__index) the set recipe's name (false: none), the input slots (false: no
--- input inventory), the force's recipes, the prototype's facts, and `fluidbox`, which stands in for the entity's in
--- fluid_map and fluid_boxes_fit (the same calls, each read once per index).
local function fluidbox_view(fb)
	local n = #fb
	local NONE = {}                                    -- (a read that gave nil)
	local function memo(read)
		local got = {}
		return function(i)
			local x = got[i]
			if x == nil then
				x = read(i)
				if x == nil then x = NONE end
				got[i] = x
			end
			if x == NONE then return nil end
			return x
		end
	end
	return setmetatable({
		get_prototype = memo(function(i) return fb.get_prototype(i) end),
		get_filter = memo(function(i) return fb.get_filter(i) end),
		get_capacity = memo(function(i) return fb.get_capacity(i) end),
		get_connections = memo(function(i) return fb.get_connections(i) end),
	}, { __len = function() return n end })
end

local VIEW = {
	__index = function(v, k)
		local e = rawget(v, "entity")
		local x
		if k == "recipe" then
			local r = e.get_recipe()
			x = r and r.name or false
		elseif k == "input_slots" then
			local inp = input_inventory(e)
			x = inp and #inp or false
		elseif k == "recipes" then x = e.force.recipes
		elseif k == "facts" then x = machine_facts(e)
		elseif k == "fluidbox" then x = fluidbox_view(e.fluidbox)
		else return nil end
		rawset(v, k, x)
		return x
	end,
}
local function machine_view(entity)
	return setmetatable({ entity = entity, type = entity.type, unit = entity.unit_number }, VIEW)
end

--- Can an assembling machine (view `v`) be switched to the recipe of pattern `def`? nil when it can, else the reason
--- ("category", "fixed-recipe", "not-researched", "stack", the fluid reasons). `outputs_optional`: a processing pattern
--- (its outputs may come back elsewhere).
local function switch_problem(v, def, facts, outputs_optional)
	local machine = v.facts
	if not machine.categories[facts.category] then return "category" end
	local fixed = machine.fixed
	if fixed and fixed ~= "" and fixed ~= def.recipe then return "fixed-recipe" end
	local r = v.recipes[def.recipe]
	if not (r and r.enabled) then return "not-researched" end
	if facts.stack then return facts.stack end
	local ingredients, products = def_ingredients(def), def_products(def)
	if v.recipe == def.recipe then
		local _, reason = fluid_map(v, ingredients, products, outputs_optional)
		return reason
	end
	return fluid_boxes_fit(v, ingredients, outputs_optional and {} or products)
end

--- Can the machine of view `v` (next to a provider) do pattern `def`? Returns a target entry { entity, unit, mode } or nil
--- and the reason: crafting patterns need an assembling machine that can make the recipe ("category",
--- "not-researched", "fixed-recipe", "stack", the fluid reasons; a furnace: "furnace"), processing patterns a
--- machine ("no-recipe": an assembling machine without a recipe; "stack", fluid reasons) or a chest (items only).
--- Issue #158: a processing pattern that names its recipe takes an assembling machine as a crafting pattern does (any
--- recipe set or none: the job step switches an idle one, `recipe` in the entry); a furnace keeps choosing by its input.
--- Chests are no target of crafting patterns (nil, nil: not counted).
local function target_for(v, def)
	local etype = v.type
	local facts = def_facts(def)
	if facts.switch and etype == "assembling-machine" then
		local why = switch_problem(v, def, facts, true)
		if why then return nil, why end
		return { entity = v.entity, unit = v.unit, mode = "push", recipe = def.recipe }
	end
	if def.kind == "crafting" then
		if etype == "furnace" then return nil, "furnace" end
		if etype ~= "assembling-machine" then return nil, nil end
		local machine = v.facts
		if not machine.categories[facts.category] then return nil, "category" end
		local fixed = machine.fixed
		if fixed and fixed ~= "" and fixed ~= def.recipe then return nil, "fixed-recipe" end
		local r = v.recipes[def.recipe]
		if not (r and r.enabled) then return nil, "not-researched" end
		if facts.stack then return nil, facts.stack end
		local ingredients, products = def_ingredients(def), def_products(def)
		if v.recipe == def.recipe then
			local _, reason = fluid_map(v, ingredients, products)
			if reason then return nil, reason end
		else
			local why = fluid_boxes_fit(v, ingredients, products)
			if why then return nil, why end
		end
		return { entity = v.entity, unit = v.unit, mode = "craft" }
	end
	if etype == "container" or etype == "logistic-container" then
		if facts.fluid_in then return nil, "fluid-box" end
		return { entity = v.entity, unit = v.unit, mode = "chest" }
	end
	if etype == "assembling-machine" and not v.recipe then return nil, "no-recipe" end
	if facts.stack then return nil, facts.stack end
	local slots = v.input_slots
	if slots and facts.items > slots then return nil, "stack" end  -- more input items than input slots (a furnace)
	local _, reason = fluid_map(v, def_ingredients(def), def_products(def), true)
	if reason then return nil, reason end
	return { entity = v.entity, unit = v.unit, mode = "push" }
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
		patterns = {},       -- [slot] = { id, def, targets = { {entity, unit, mode} }, why = first reason of a machine that cannot } (scan)
		status = {},         -- [slot] = { ok, reason, machines } (scan)
		net = nil,           -- network id of the last scan
		scanned_priority = nil }   -- priority of the last scan (before issue #50: `sig`, a signature string of the scan)
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

--- Issue #50, lever 6: the clean pattern of a slot (P.normalize) or the reason it has none, and the pattern's id, once per
--- slot content (weak, per load). A slot's pattern is replaced, never changed in place, and normalize reads only the
--- prototypes and the aliases of the replaced items, which do not change while the game runs. The scan hands out the same
--- definition every time, so the caches per definition (target_for, the planner, the job steps) keep it as well.
local norm_cache = setmetatable({}, { __mode = "k" })
local function normalized(raw)
	if type(raw) ~= "table" then return P.normalize(raw) end
	local c = norm_cache[raw]
	if not c then
		local def, why = P.normalize(raw)
		c = { def = def, why = why, id = def and P.id_of(def) }
		norm_cache[raw] = c
	end
	return c.def, c.why, c.id
end

--- whether a scanned slot is what the last scan found: the same pattern id, the same first reason of a machine that cannot
--- (`why`, kept even when another machine can) and the same machines in the same order
local function same_scan(old, id, why, targets)
	if not (old and old.id == id and old.why == why) then return false end
	local was = old.targets
	if not was or #was ~= #targets then return false end
	for i, t in ipairs(targets) do
		if was[i].unit ~= t.unit then return false end
	end
	return true
end

--- Scan a provider: the pattern in each slot, the machines next to it that can do it. The network's patterns are made
--- again (dirty) when the scan found something else than the last one: the network, the priority, a slot's pattern, its
--- reason or its machines. Issue #50, lever 6: compared with the last scan's records instead of a signature string
--- (p.sig, dropped); what the comparison sees is what the signature held.
local function scan_provider(p)
	local e = p.entity
	local net = N.network_of(e)                  -- patterns are kept while the network is off, jobs wait
	if p.pending then fill_pending(p, N.active_of(e)) end
	local net_id, priority = net and net.id or nil, p.priority or 0
	local old_patterns, old_status = p.patterns or {}, p.status or {}
	local same = p.net == net_id and p.scanned_priority == priority
	local patterns, status = {}, {}
	local around = {}
	if net then
		for i, m in ipairs(neighbors_of(e)) do around[i] = machine_view(m) end
	end
	for slot = 1, SLOTS do
		local raw = p.slots[slot]
		if raw then
			local def, why, id = normalized(raw)
			if not def then
				status[slot] = { ok = false, reason = why }
				if same then
					local was = old_status[slot]
					same = old_patterns[slot] == nil and was ~= nil and was.reason == why
				end
			elseif not net then
				status[slot] = { ok = false, reason = "no-network" }
				if same then
					local was = old_status[slot]
					same = old_patterns[slot] == nil and was ~= nil and was.reason == "no-network"
				end
			else
				local targets, reason = {}, nil
				for _, v in ipairs(around) do
					local t, r = target_for(v, def)
					if t then targets[#targets + 1] = t else reason = reason or r end
				end
				patterns[slot] = { id = id, def = def, targets = targets, why = reason }
				local ok = #targets > 0
				status[slot] = { ok = ok, reason = not ok and (reason or "no-machine") or nil, machines = #targets }
				same = same and same_scan(old_patterns[slot], id, reason, targets)
			end
		elseif same then
			same = old_status[slot] == nil
		end
	end
	p.patterns, p.status, p.net = patterns, status, net_id
	p.scanned_priority, p.sig = priority, nil
	if not same then state().dirty = true end
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
				net = { items = {}, defs = {}, targets = {}, ignored = { total = 0 }, seen = {}, prov = {} }
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
					net.prov[id] = net.prov[id] or {}
					if net.prov[id][#net.prov[id]] ~= p.unit then net.prov[id][#net.prov[id] + 1] = p.unit end
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

--- bounded slice of the round robin rescan: `count` providers
local function maintenance(s, count)
	local n = #s.plist
	if n == 0 then return end
	for _ = 1, math.min(count, n) do
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

--- What the plan finds of `key` in storage (issue #50: read when the plan first asks, not the whole stock per plan): the
--- plain items (not with data, no quality) and the fluids of a usable network, as stock_of of 0.3.0 had them.
local storable = {}                               -- key -> true when the plan may take it from storage (per load)
local function base_count(net, key)
	local ok = storable[key]
	if ok == nil then
		ok = is_fluid(key) or (not key:find("[@#]") and plain_item(key))
		storable[key] = ok
	end
	return ok and net.items[key] or 0
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

--- Issue #50: what a plan node reads of a pattern, made once per pattern definition (weak, per load): the yield of a key
--- (product_yield) and the ingredients as { key, amount } in the order of def_ingredients
local yield_cache = setmetatable({}, { __mode = "k" })
local inputs_cache = setmetatable({}, { __mode = "k" })
local function def_yield(def, key)
	local per = yield_cache[def]
	if not per then
		per = {}
		yield_cache[def] = per
	end
	local y = per[key]
	if not y then
		local total, exact = product_yield(def_products(def), key)
		y = { total, exact }
		per[key] = y
	end
	return y[1], y[2]
end
local function def_inputs(def)
	local l = inputs_cache[def]
	if not l then
		l = {}
		for _, ing in pairs(def_ingredients(def)) do
			--- issue #159: a fluid ingredient without a temperature also takes the other temperatures in its range
			local flex, lo, hi = ing_flex(ing)
			l[#l + 1] = { key_of(ing), ing.amount, flex and { ing.name, lo, hi } or nil }
		end
		inputs_cache[def] = l
	end
	return l
end

local function copy_map(t)
	local c = {}
	for k, v in pairs(t) do c[k] = v end
	return c
end

--- Issue #50: the alternatives of a key are tried on the same tables, undone to where they started, instead of on a copy of
--- the whole state each (the stock of a GregTech network is thousands of keys, copied twice per alternative). While an
--- alternative is tried (`ctx.alt` > 0) every write is journaled as (table, key, value before); `undo` writes them back in
--- the reverse order. The state after an undo is the state the copy of 0.3.0 held.
local function jset(ctx, t, k, v)
	if ctx.alt > 0 then
		local log, n = ctx.log, ctx.logn
		log[n + 1], log[n + 2], log[n + 3] = t, k, t[k]
		ctx.logn = n + 3
	end
	t[k] = v
end

local function undo(ctx, mark)
	local log = ctx.log
	for i = ctx.logn - 2, mark + 1, -3 do
		log[i][log[i + 1]] = log[i + 2]
		log[i], log[i + 1], log[i + 2] = nil, nil, nil
	end
	ctx.logn = mark
end

local function add_missing(ctx, key, count)
	jset(ctx, ctx.missing, key, (ctx.missing[key] or 0) + count)
	jset(ctx, ctx, "missing_n", ctx.missing_n + count)
end

local need

--- make `count` of `key` with one pattern: its ingredients are needed `runs` times
local function apply_pattern(ctx, pid, key, count, path, depth)
	local def = ctx.patterns.defs[pid]
	local yield, exact = def_yield(def, key)
	if yield <= 0 then add_missing(ctx, key, count) return end
	local runs = math.ceil(count / yield - 1e-9)
	local inputs = def_inputs(def)
	for i = 1, #inputs do
		local ing = inputs[i]
		need(ctx, ing[1], ing[2] * runs, path, depth + 1, false, ing[3])
	end
	local step = ctx.steps[pid]
	if not step then
		step = { pid = pid, runs = 0 }
		jset(ctx, ctx.steps, pid, step)
		jset(ctx, ctx.order, #ctx.order + 1, pid)    -- ingredients were planned first: dependencies come first
	end
	jset(ctx, step, "runs", step.runs + runs)
	if exact then                                    -- surplus of a certain yield can be used by later demand
		local over = runs * yield - count
		if not is_fluid(key) then over = math.floor(over + 1e-9) end
		if over > 1e-9 then jset(ctx, ctx.surplus, key, (ctx.surplus[key] or 0) + over) end
	end
end

--- Issue #159: take up to `count` of another storage key `key` from the stock (as need does for its own key); returns
--- what is still needed
local function take_stock(ctx, key, count)
	local stock = ctx.stock
	local have = stock[key]
	if have == nil then
		have = base_count(ctx.net, key)
		stock[key] = have
		ctx.base[key] = have
	end
	jset(ctx, ctx.demand, key, (ctx.demand[key] or 0) + count)
	if have <= 0 then return count end
	local t = have < count and have or count
	jset(ctx, stock, key, have - t)
	jset(ctx, ctx.reserve, key, (ctx.reserve[key] or 0) + t)
	return count - t
end

--- `count` of `key` are needed: take from storage, else craft through a pattern. `flex` (issue #159): { fluid name, lo,
--- hi } of a fluid ingredient without a temperature: after its own key the network's other temperatures of the fluid
--- in that range are taken (the default first, then from the coldest), before anything is crafted.
function need(ctx, key, count, path, depth, top, flex)
	ctx.nodes = ctx.nodes + 1
	if ctx.nodes > MAX_PLAN_NODES or depth > MAX_DEPTH then
		ctx.too_complex = true
		add_missing(ctx, key, count)
		return
	end
	if not top then
		--- the surplus of earlier steps first, then the stock (jset written out, the hot path of a plan; the
		--- first read of a key takes its stock from the network and keeps what was read in `ctx.base`)
		local logging = ctx.alt > 0
		local log, n = ctx.log, ctx.logn
		local surplus = ctx.surplus
		local sur = surplus[key]
		if sur and sur > 0 then
			local t = sur < count and sur or count
			if logging then
				log[n + 1], log[n + 2], log[n + 3] = surplus, key, sur
				n = n + 3
			end
			surplus[key] = sur - t
			count = count - t
		end
		if count <= 1e-9 then
			ctx.logn = n
			return
		end
		local stock = ctx.stock
		local have = stock[key]
		if have == nil then
			have = ctx.usable and base_count(ctx.net, key) or 0
			stock[key] = have
			ctx.base[key] = have
		end
		local demand = ctx.demand
		demand[key] = (demand[key] or 0) + count             -- (all asked of the stock, every alternative: kept plans)
		if have > 0 then
			local t = have < count and have or count
			local reserve = ctx.reserve
			local r = reserve[key]
			if logging then
				log[n + 1], log[n + 2], log[n + 3] = stock, key, have
				log[n + 4], log[n + 5], log[n + 6] = reserve, key, r
				n = n + 6
			end
			stock[key] = have - t
			reserve[key] = (r or 0) + t
			count = count - t
		end
		ctx.logn = n
		if count <= 1e-9 then return end
		if flex and ctx.usable then
			local list = N.fluid_keys(ctx.net, flex[1])
			--- (a kept plan is made anew when the fluid gets a temperature it did not have: kept_valid)
			if not ctx.fkeys[flex[1]] then ctx.fkeys[flex[1]] = #list end
			for _, k in ipairs(list) do
				if k ~= key and flex_fits(k, flex[1], flex[2], flex[3]) then
					count = take_stock(ctx, k, count)
					if count <= 1e-9 then return end
				end
			end
		end
	end
	local pids = ctx.patterns.items[key]
	if not pids then add_missing(ctx, key, count) return end
	if path[key] then
		jset(ctx, ctx.loops, key, true)
		add_missing(ctx, key, count)
		return
	end
	path[key] = true
	if #pids == 1 then
		apply_pattern(ctx, pids[1], key, count, path, depth)
	else
		--- several patterns (in pattern order: provider priority, provider, slot): the first one that needs
		--- nothing that is missing; each tried from the state before the first (undone)
		local mark, missing0 = ctx.logn, ctx.missing_n
		ctx.alt = ctx.alt + 1
		local chosen
		for i, pid in ipairs(pids) do
			undo(ctx, mark)
			apply_pattern(ctx, pid, key, count, path, depth)
			if ctx.missing_n == missing0 then chosen = i break end
		end
		if not chosen then
			undo(ctx, mark)
			apply_pattern(ctx, pids[1], key, count, path, depth)
		end
		ctx.alt = ctx.alt - 1
	end
	path[key] = nil
end

local NO_PATTERNS = { items = {}, defs = {}, targets = {}, ignored = { total = 0 } }

--- issue #6: crafting storage bytes of `amount` of `key`: 1 per item, 1 per fluid_units_per_byte fluid units (rounded up)
local function key_bytes(key, amount)
	if is_fluid(key) then
		block_specs()
		return math.ceil(amount / fluid_per_byte - 1e-9)
	end
	return math.ceil(amount - 1e-9)
end

--- The bytes a job needs (AE2's rule per plan step, docs/ME-REWORK.md "The bytes a job needs"): the amount ordered,
--- per step its runs and the ingredients of all its runs, 8 per step and per resource taken from storage (`reserved`:
--- their number; unknown for a job of an older save, counted as 0). `steps`: { def, runs }.
local function plan_bytes(key, amount, steps, reserved)
	local bytes = key_bytes(key, amount) + 8 * (#steps + (reserved or 0))
	for _, st in ipairs(steps) do
		bytes = bytes + st.runs
		for _, ing in pairs(def_ingredients(st.def)) do
			bytes = bytes + key_bytes(key_of(ing), ing.amount * st.runs)
		end
	end
	return bytes
end

--- Issue #50: kept plans. A plan is a pure function of the network's patterns (the table `ensure_patterns` builds anew at
--- every change: its identity says whether they changed) and of the stock it read. A kept plan holds what each key read from
--- storage was (`base`) and how much was asked of it in all (`demand`, every alternative tried counted): it is the plan the
--- network would make now when the patterns are the same table and every key it read holds the same amount, or held and
--- holds at least all that was asked of it (then every take was whole, before and now). Anything else (a stock below what
--- was asked, a pattern added or removed, a provider or machine built or removed, the network joined, split or without
--- power) makes a new plan. Kept per network id, key and amount, outside `storage`: a peer that has none makes the same
--- plan fresh, so every peer acts alike. The crafting CPUs are not part of a plan (the preview reads them every time).
local KEEP_PER_NETWORK = 16
local kept_plans = {}                              -- network id -> { [key .. "|" .. amount] = { patterns, base, demand, plan } }
local kept_stats = { hits = 0, misses = 0 }

local function kept_valid(entry, net, patterns)
	if entry.patterns ~= patterns then return false end
	local usable = N.usable(net) and true or false
	local demand = entry.demand
	for key, was in pairs(entry.base) do
		local now = usable and base_count(net, key) or 0
		if now ~= was then
			local d = demand[key] or 0
			if was < d or now < d then return false end
		end
	end
	--- issue #159: a fluid ingredient of every temperature looked at the network's temperatures of its fluid; one that is
	--- new since then (the list only grows) was never read
	for name, n in pairs(entry.fkeys or {}) do
		if #N.fluid_keys(net, name) ~= n then return false end
	end
	return true
end

--- a copy of a plan's tables a caller may change (M.start sets `biggest`, a maintainer keeps `missing`)
local function plan_copy(p)
	local c = copy_map(p)
	c.missing, c.loops, c.reserve = copy_map(p.missing), copy_map(p.loops), copy_map(p.reserve)
	c.steps = { table.unpack(p.steps) }
	return c
end

--- Plan `amount` of `key` for the network `net`.
--- Returns { ok, missing = {key -> count}, loops = {key -> true}, steps = { {pid, def, runs} },
--- reserve = {key -> count taken from storage}, runs, too_complex }. `fresh_only`: never a kept plan (tests).
local function make_plan(s, net, key, amount, fresh_only)
	local patterns = ensure_patterns(s)[net.id] or NO_PATTERNS
	if not patterns.items[key] then
		return { ok = false, missing = { [key] = amount }, loops = {}, steps = {}, reserve = {}, runs = 0, no_pattern = true }
	end
	local per = kept_plans[net.id]
	local id = key .. "|" .. amount
	local entry = per and per[id]
	if entry and not fresh_only and kept_valid(entry, net, patterns) then
		kept_stats.hits = kept_stats.hits + 1
		return plan_copy(entry.plan)
	end
	kept_stats.misses = kept_stats.misses + 1
	local ctx = {
		patterns = patterns, net = net, usable = N.usable(net) and true or false, stock = {}, base = {}, demand = {},
		surplus = {}, reserve = {}, missing = {}, loops = {}, steps = {}, order = {}, missing_n = 0, nodes = 0,
		alt = 0, log = {}, logn = 0, fkeys = {},
	}
	need(ctx, key, amount, {}, 0, true)
	local steps, runs = {}, 0
	for _, pid in ipairs(ctx.order) do
		local step = ctx.steps[pid]
		steps[#steps + 1] = { pid = pid, def = patterns.defs[pid], runs = step.runs }
		runs = runs + step.runs
	end
	local reserve, reserved = {}, 0
	for k, v in pairs(ctx.reserve) do if v > 0 then reserve[k] = v reserved = reserved + 1 end end
	local plan = { ok = ctx.missing_n == 0, missing = ctx.missing, loops = ctx.loops, steps = steps,
		reserve = reserve, runs = runs, too_complex = ctx.too_complex, bytes = plan_bytes(key, amount, steps, reserved),
		nodes = ctx.nodes }
	if not fresh_only then
		if not per or table_size(per) >= KEEP_PER_NETWORK then
			per = {}
			kept_plans[net.id] = per
		end
		per[id] = { patterns = patterns, base = ctx.base, demand = ctx.demand, fkeys = ctx.fkeys, plan = plan }
		return plan_copy(plan)
	end
	return plan
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
--- multiblock CPUs (issue #6): groups of touching crafting blocks, kept up to date on build and removal like the
--- network graph (no scan while nothing changes). All blocks are 1x1 and cannot overlap, so a group is a solid
--- rectangle exactly when its block count fills its bounding box.
---   s.cblocks[unit] = { entity, x, y, surface, group }    every crafting block, by its tile
---   s.cgrid["surface:x:y"] = unit                         the tile index: neighbours are four lookups
---   s.groups[id] = { id, blocks = { unit = true }, n, x1, y1, x2, y2, bytes, coprocessors, monitors = { unit = true },
---                    status, job, anchor, surface }       status "ok", "not-rectangle" or "no-storage"
--------------------------------------------------------------------------------

--- functions(group) run when a group's blocks, status or job changed (the crafting monitors)
M.group_hooks = {}

local SIDES = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }

local function cstate(s)
	if not s.groups then s.cblocks, s.cgrid, s.groups, s.next_group = {}, {}, {}, 1 end
	return s
end

local function grid_key(surface, x, y) return surface .. ":" .. x .. ":" .. y end

--- the units of the crafting blocks on the four tiles next to block `b` (in `group` only, when given)
local function block_neighbours(s, b, group)
	local out = {}
	for _, d in ipairs(SIDES) do
		local u = s.cgrid[grid_key(b.surface, b.x + d[1], b.y + d[2])]
		local o = u and s.cblocks[u]
		if o and (not group or o.group == group) then out[#out + 1] = u end
	end
	return out
end

--- the group's sums and box from its blocks (after a removal)
local function recount_group(s, g)
	g.n, g.bytes, g.coprocessors, g.monitors, g.anchor = 0, 0, 0, {}, nil
	g.x1, g.y1, g.x2, g.y2 = nil, nil, nil, nil
	local units = {}
	for unit in pairs(g.blocks) do units[#units + 1] = unit end
	table.sort(units)
	for _, unit in ipairs(units) do
		local b = s.cblocks[unit]
		local spec = b.entity.valid and block_spec(b.entity.name) or { bytes = 0, coprocessors = 0 }
		g.n = g.n + 1
		g.bytes = g.bytes + spec.bytes
		g.coprocessors = g.coprocessors + spec.coprocessors
		if spec.monitor then g.monitors[unit] = true end
		if not g.anchor and b.entity.valid then g.anchor = b.entity end
		g.x1, g.y1 = math.min(g.x1 or b.x, b.x), math.min(g.y1 or b.y, b.y)
		g.x2, g.y2 = math.max(g.x2 or b.x, b.x), math.max(g.y2 or b.y, b.y)
	end
end

local function add_to_group(g, unit, b)
	local spec = block_spec(b.entity.name)
	g.blocks[unit] = true
	b.group = g.id
	g.n = g.n + 1
	g.bytes = g.bytes + spec.bytes
	g.coprocessors = g.coprocessors + spec.coprocessors
	if spec.monitor then g.monitors[unit] = true end
	if not (g.anchor and g.anchor.valid) then g.anchor = b.entity end
	g.x1, g.y1 = math.min(g.x1 or b.x, b.x), math.min(g.y1 or b.y, b.y)
	g.x2, g.y2 = math.max(g.x2 or b.x, b.x), math.max(g.y2 or b.y, b.y)
end

local function new_group(s, surface)
	local id = s.next_group
	s.next_group = id + 1
	local g = { id = id, blocks = {}, n = 0, bytes = 0, coprocessors = 0, monitors = {}, surface = surface }
	s.groups[id] = g
	return g
end

--- the bytes a job needs (jobs of older saves: from their steps)
local function job_bytes(job)
	if not job.bytes then job.bytes = plan_bytes(job.item, job.amount, job.steps) end
	return job.bytes
end

--- a job whose CPU group changed or went: it pauses with everything it holds and takes the next CPU that fits
--- (a closing job needs no CPU and simply goes on)
local function pause_group_job(s, g)
	local job = g.job and s.jobs[g.job]
	g.job = nil
	if not (job and job.group == g.id) then return end
	job.group = nil
	if job.status == "running" and not job.closing then
		job.status = "queued"
		job.wait = nil
	end
end

local function group_changed(g)
	for _, hook in pairs(M.group_hooks) do hook(g) end
end

--- status, pictures (dark: no CPU, lit: a CPU) and the job of a group whose blocks changed
local function settle_group(s, g)
	local was = g.status
	local rect = g.n == (g.x2 - g.x1 + 1) * (g.y2 - g.y1 + 1)
	g.status = not rect and "not-rectangle" or g.bytes <= 0 and "no-storage" or "ok"
	if g.status ~= was then
		local variation = g.status == "ok" and 2 or 1
		for unit in pairs(g.blocks) do
			local e = s.cblocks[unit].entity
			if e.valid then e.graphics_variation = variation end
		end
	end
	local job = g.job and s.jobs[g.job]
	if job and not (g.status == "ok" and g.bytes >= job_bytes(job)) then pause_group_job(s, g) end
	group_changed(g)
end

--- a crafting block was built (or cloned): it joins the groups next to it (merged into the largest)
local function add_block(s, entity)
	cstate(s)
	local unit = entity.unit_number
	if s.cblocks[unit] then return end
	local b = { entity = entity, x = math.floor(entity.position.x), y = math.floor(entity.position.y), surface = entity.surface.index }
	s.cblocks[unit] = b
	s.cgrid[grid_key(b.surface, b.x, b.y)] = unit
	local ids, seen = {}, {}
	for _, u in ipairs(block_neighbours(s, b)) do
		local id = s.cblocks[u].group
		if not seen[id] then seen[id] = true ids[#ids + 1] = id end
	end
	table.sort(ids, function(a, c)
		if s.groups[a].n ~= s.groups[c].n then return s.groups[a].n > s.groups[c].n end
		return a < c
	end)
	local g = ids[1] and s.groups[ids[1]] or new_group(s, b.surface)
	--- merged groups: the job with the lowest id stays (if it still fits), the others pause
	local jobs = {}
	if g.job then jobs[#jobs + 1] = g.job end
	for i = 2, #ids do
		local other = s.groups[ids[i]]
		if other.job then jobs[#jobs + 1] = other.job end
		pause_group_job(s, other)
		for u in pairs(other.blocks) do add_to_group(g, u, s.cblocks[u]) end
		s.groups[other.id] = nil
		group_changed(other)
	end
	table.sort(jobs)
	if jobs[1] and jobs[1] ~= g.job then
		pause_group_job(s, g)
		local job = s.jobs[jobs[1]]
		if job and job.status == "queued" and not job.closing then
			g.job, job.group, job.status = job.id, g.id, "running"
		end
	end
	add_to_group(g, unit, b)
	entity.graphics_variation = g.status == "ok" and 2 or 1      -- (settle_group sets every block when the status changes)
	settle_group(s, g)
end

--- a crafting block was removed (mined, destroyed, or vanished without an event): it leaves its group, which may split
local function remove_block(s, unit)
	local b = s.cblocks and s.cblocks[unit]
	if not b then return end
	s.cblocks[unit] = nil
	local k = grid_key(b.surface, b.x, b.y)
	if s.cgrid[k] == unit then s.cgrid[k] = nil end
	local g = s.groups[b.group]
	if not g then return end
	g.blocks[unit] = nil
	if s.monitors and s.monitors[unit] then
		for _, obj in pairs(s.monitors[unit]) do if type(obj) ~= "number" and obj.valid then obj.destroy() end end
		s.monitors[unit] = nil
	end
	if next(g.blocks) == nil then
		pause_group_job(s, g)
		s.groups[g.id] = nil
		g.n = 0
		group_changed(g)
		return
	end
	local starts = block_neighbours(s, b, g.id)
	local parts
	if #starts <= 1 then
		parts = { g.blocks }
	else
		--- one breadth first search over the group's blocks finds its parts
		parts = {}
		local seen = {}
		table.sort(starts)
		for _, start in ipairs(starts) do
			if not seen[start] then
				local part, queue, i = {}, { start }, 1
				seen[start] = true
				while queue[i] do
					local u = queue[i]
					i = i + 1
					part[u] = true
					for _, v in ipairs(block_neighbours(s, s.cblocks[u], g.id)) do
						if not seen[v] then seen[v] = true queue[#queue + 1] = v end
					end
				end
				parts[#parts + 1] = part
			end
		end
	end
	if #parts > 1 then
		local function size(p) local n = 0 for _ in pairs(p) do n = n + 1 end return n end
		local sizes = {}
		for i, p in ipairs(parts) do sizes[i] = { p = p, n = size(p), first = i } end
		table.sort(sizes, function(a, c) if a.n ~= c.n then return a.n > c.n end return a.first < c.first end)
		g.blocks = sizes[1].p                              -- the largest part keeps the group (and its job, if it fits)
		for i = 2, #sizes do
			local part = new_group(s, g.surface)
			part.blocks = sizes[i].p
			for u in pairs(part.blocks) do s.cblocks[u].group = part.id end
			recount_group(s, part)
			settle_group(s, part)
		end
	end
	recount_group(s, g)
	settle_group(s, g)
end

--- the working network of a group (that of its blocks), nil when it has none or it does not work
local function group_network(g)
	if not (g.anchor and g.anchor.valid) then return nil end
	return N.active_of(g.anchor)
end

--- the network of a group, working or not
local function group_network_any(g)
	return g.anchor and g.anchor.valid and N.network_of(g.anchor) or nil
end

--- speed of a group: 1 + its co-processors (at most max_coprocessors count)
local function group_speed(g)
	block_specs()
	return 1 + math.min(g.coprocessors, max_coprocessors)
end

--- the multiblock CPUs of a network (groups that are CPUs), smallest storage first, then the fastest, then the oldest
local function groups_in(s, net)
	local list = {}
	for _, g in pairs(cstate(s).groups) do
		if g.status == "ok" then
			local n = group_network_any(g)
			if n and n.id == net.id then list[#list + 1] = g end
		end
	end
	table.sort(list, function(a, b)
		if a.bytes ~= b.bytes then return a.bytes < b.bytes end
		if a.coprocessors ~= b.coprocessors then return a.coprocessors > b.coprocessors end
		return a.id < b.id
	end)
	return list
end

--- The CPU a job of `bytes` gets now in `net`: a free multiblock CPU that is big enough, else a legacy CPU with a free
--- slot. Returns the group or the legacy record (and its kind), or nil and why: "no-cpu" (none at all),
--- "cpu-too-small" (no CPU of the network is big enough; also the biggest one's bytes), "no-free-cpu".
local function pick_cpu(s, net, bytes)
	local biggest, any = 0, false
	for _, g in ipairs(groups_in(s, net)) do
		any = true
		if g.bytes > biggest then biggest = g.bytes end
		if g.bytes >= bytes and not g.job and group_network(g) then return g, "group" end
	end
	local legacy = cpus_in(s, net)
	for _, rec in ipairs(legacy) do
		if cpu_powered(rec.entity) and cpu_load(rec) < cpu_slots(rec) then return rec, "legacy" end
	end
	if not any and #legacy == 0 then return nil, "no-cpu" end
	if #legacy == 0 and biggest < bytes then return nil, "cpu-too-small", biggest end
	return nil, "no-free-cpu", biggest
end

--- The CPUs of a network for the plan preview (issue #6), in the order a job takes them: { kind = "group" or "legacy",
--- id (group id or unit number), name (legacy: entity name), bytes (nil: no limit), coprocessors, speed, width,
--- height, free, fits } (`bytes`: the job's; fits = big enough, free = can take a job now)
function M.cpu_list(net, bytes)
	local s = state()
	local out = {}
	for _, g in ipairs(groups_in(s, net)) do
		out[#out + 1] = { kind = "group", id = g.id, bytes = g.bytes, coprocessors = g.coprocessors, speed = group_speed(g),
			width = g.x2 - g.x1 + 1, height = g.y2 - g.y1 + 1, free = not g.job and group_network(g) ~= nil,
			fits = g.bytes >= (bytes or 0) }
	end
	for _, rec in ipairs(cpus_in(s, net)) do
		local spec = cpu_spec(rec.entity.name)
		out[#out + 1] = { kind = "legacy", id = rec.entity.unit_number, name = rec.entity.name, speed = spec and spec.speed or 1,
			free = cpu_powered(rec.entity) and cpu_load(rec) < cpu_slots(rec), fits = true }
	end
	return out
end

local function give_group(g, job)
	g.job, job.group, job.cpu, job.status = job.id, g.id, nil, "running"
	if g.anchor and g.anchor.valid then job.pos = { x = g.anchor.position.x, y = g.anchor.position.y } end
	group_changed(g)
end

--------------------------------------------------------------------------------
--- jobs
--------------------------------------------------------------------------------

--- the working network of a job: that of its CPU, else of the entity it was started at, else of the ME member at
--- its position (jobs of older saves)
local function job_network(job)
	local s = state()
	local g = job.group and s.groups and s.groups[job.group]
	if g and group_network_any(g) then return group_network(g) end
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

--- the ingredients and products of a job step (its pattern; a crafting pattern reads its recipe): def_ingredients above
local function step_ingredients(step) return def_ingredients(step.def) end
local function step_products(step) return def_products(step.def) end

--- runs of a processing step whose outputs are all back (received)
local function processing_done(step)
	local done
	for _, r in ipairs(step.def.outputs) do
		local n = math.floor(((step.received[r.key] or 0) + FLUID_EPS) / r.amount)
		done = done and math.min(done, n) or n
	end
	return math.min(done or 0, step.issued)
end

local monitor_progress                                  -- (the crafting monitors, below: they follow the job's progress, issue #140)

--- the job's total of finished runs (crafting steps count crafts, processing steps the outputs that came back)
local function update_done(job)
	local total = 0
	for _, step in ipairs(job.steps) do
		if step.kind == "processing" then step.done = processing_done(step) end
		total = total + step.done
	end
	job.done_runs = total
	monitor_progress(job)
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

--- Issue #159: the pool keys a fluid input may take (its own key first, then the others of its fluid in its range, in
--- key order) and what they hold together. `name`, `flex`, `lo`, `hi` as in a fluid map input.
local function pool_keys(job, key, name, flex, lo, hi)
	local out = { key }
	local total = job.pool[key] or 0
	if flex then
		local others
		for k, n in pairs(job.pool) do
			if k ~= key and n > 0 and flex_fits(k, name, lo, hi) then
				others = others or {}
				others[#others + 1] = k
			end
		end
		if others then
			table.sort(others)
			for _, k in ipairs(others) do
				out[#out + 1] = k
				total = total + job.pool[k]
			end
		end
	end
	return out, total
end

--- what the pool holds for an ingredient (a fluid without a temperature: every temperature in its range)
local function ing_pool(job, ing)
	if ing.type ~= "fluid" then return job.pool[ing.name] or 0 end
	local key = key_of(ing)
	local total = job.pool[key] or 0
	local flex, lo, hi = ing_flex(ing)
	if flex then
		for k, n in pairs(job.pool) do
			if k ~= key and n > 0 and flex_fits(k, ing.name, lo, hi) then total = total + n end
		end
	end
	return total
end

--- move everything from the pool into the network; what does not fit stays in the pool
local function flush_pool(job, net)
	for key, count in pairs(shallow_map(job.pool)) do
		local inserted = 0
		if count > 0 then
			if is_fluid(key) then
				inserted = store_fluid(net, key, count)
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
		for _, c in pairs(N.bound(out).get_contents()) do
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
				got(N.fluid_key(f.name, f.temperature), f.amount)   -- (issue #159: at its temperature)
				fb[o.index] = nil
			end
		end
	end
end

local QI = {}                                         -- (an item spec for the engine, reused: issue #115)

--- unused inputs back into the pool (items and fluid input boxes); returns { key -> amount taken back }
local function take_back_input(job, machine, ingredients, map)
	local back = {}
	local inp = input_inventory(machine)
	if inp then
		for _, ing in pairs(ingredients) do
			if ing.type == "item" and not back[ing.name] then
				QI.name, QI.quality, QI.count = ing.name, QUALITY, nil
				local held = N.bound(inp).get_item_count(QI)
				QI.count = held
				local removed = held > 0 and N.bound(inp).remove(QI) or 0
				if removed > 0 then pool_add(job, ing.name, removed) back[ing.name] = removed end
			end
		end
	end
	if map and #map.inputs > 0 then
		local fb = machine.fluidbox
		for _, i in pairs(map.inputs) do
			local f = i.index <= #fb and fb[i.index] or nil
			if f and f.amount > 0 then
				pool_add(job, N.fluid_key(f.name, f.temperature), f.amount)   -- (issue #159: at its temperature)
				back[i.key] = (back[i.key] or 0) + f.amount                   -- (counted for the input's key)
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
		if ing.type == "item" and N.bound(inp).get_item_count(ing.name) > 0 then return false end
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
	local g = job.group and s.groups and s.groups[job.group]
	job.group = nil
	if g and g.job == job.id then
		g.job = nil
		group_changed(g)
	end
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
	if job.owner and N.wakers.maint then N.wakers.maint(job.owner) end     -- its level maintainer checks again
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

--- Queued jobs (paused: their CPU changed or went; or queued in an older save) take a free CPU of their network: a
--- multiblock CPU with enough bytes (the smallest first), else a legacy CPU with a free slot (the fastest first).
local function assign_cpus(s)
	for _, id in pairs(s.active) do
		local job = s.jobs[id]
		if job and job.status == "queued" and not job.closing then
			local net = job_network(job)
			if net then
				local bytes = job_bytes(job)
				local given = false
				for _, g in ipairs(groups_in(s, net)) do
					if not g.job and g.bytes >= bytes then
						give_group(g, job)
						given = true
						break
					end
				end
				if not given then
					for _, rec in ipairs(cpus_in(s, net)) do
						if cpu_load(rec) < cpu_slots(rec) then
							cpu_jobs(rec)[job.id] = true
							job.cpu = rec.entity.unit_number
							job.pos = { x = rec.entity.position.x, y = rec.entity.position.y }
							job.status = "running"
							given = true
							break
						end
					end
				end
				job.wait = not given and "cpu-bytes" or nil
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
		if ing_pool(job, ing) + FLUID_EPS < per * batch then return false end
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
			pool_add(job, N.fluid_key(leftover.name, leftover.temperature), leftover.amount)
			fb[i.index] = nil
		end
		local need_amount = i.amount * batch
		--- issue #159: from the input's own key first, then the other temperatures it takes; the box gets their mean
		--- temperature (all in the recipe's range)
		local keys, have = pool_keys(job, i.key, i.name, i.flex, i.lo, i.hi)
		local give = math.min(i.capacity, need_amount + math.max(0, math.min(FLUID_MARGIN, have - need_amount)))
		local parts, left, heat = {}, give, 0
		for _, k in ipairs(keys) do
			local n = math.min(left, job.pool[k] or 0)
			if n > 0 then
				parts[#parts + 1] = { k, n }
				heat = heat + n * N.fluid_temperature(k)
				left = left - n
			end
			if left <= 0 then break end
		end
		local amount = give - math.max(0, left)
		fb[i.index] = amount > 0 and { name = i.name, amount = amount, temperature = heat / amount } or nil
		local now = fb[i.index]
		local got = (now and now.name == i.name) and now.amount or 0
		local rest = got
		for _, part in ipairs(parts) do
			local n = math.min(rest, part[2])
			if n > 0 then
				pool_add(job, part[1], -n)
				given[#given + 1] = { key = part[1], lkey = i.key, fluid = true, index = i.index, got = n }
				rest = rest - n
			end
		end
		if got + FLUID_EPS < need_amount then undo() return false end
	end
	step.issued = step.issued + batch
	local lease = { machine = machine, unit = machine.unit_number, step = step_index, pid = step.pid, kind = step.kind,
		recipe = step.recipe, runs = batch, fluid = map }
	if step.kind == "crafting" then
		lease.finished0 = machine.products_finished
	else
		lease.given = {}
		for _, g in pairs(given) do
			local k = g.lkey or g.key                          -- (a fluid counts for its input's key: issue #159)
			lease.given[k] = (lease.given[k] or 0) + g.got
		end
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
	if not prototypes.recipe[step.recipe] then return nil end
	--- issue #59, lever 3: the step's ingredient and product lists (a read of the recipe prototype makes new tables every
	--- time), the busy test before the engine's, and the second pass only over the machines the first one found free with
	--- another recipe (in their order: nothing the first pass does changes them)
	local ingredients, products = step_ingredients(step), step_products(step)
	local busy, others = s.busy, nil
	for _, t in pairs(targets) do
		local e = t.entity
		if t.mode == "craft" and not busy[t.unit] and e.valid and not e.disabled_by_script and not rejected(job, t.unit, step.pid) then
			local current = N.bound(e).get_recipe()
			if current ~= nil and current.name == step.recipe then
				local map, why = fluid_map(e, ingredients, products)
				if not map then reject(job, t.unit, step.pid) job.problem = why
				elseif machine_idle(e, ingredients, map) then return e, map end
			else
				others = others or {}
				others[#others + 1] = t
			end
		end
	end
	if not others then return nil end
	for _, t in ipairs(others) do
		local e = t.entity
		if e.crafting_progress == 0 and switch_recipe(net, e, step.recipe) then
			local map, why = fluid_map(e, ingredients, products)
			if map then return e, map end
			reject(job, t.unit, step.pid)
			job.problem = why
		end
	end
	return nil
end

--- A target for a processing step: an idle machine ("push") or a chest ("chest"). Returns the entity, its mode and
--- the fluid map. Issue #158: a target with a `recipe` (a processing pattern that names its recipe, at an assembling
--- machine) is used when it has that recipe and is idle; else, after the other targets, an idle one is switched to it
--- (switch_recipe: what is left in it goes into the network first), as find_crafter does for crafting steps.
local function find_pusher(s, net, job, step, targets)
	local ingredients, products = step_ingredients(step), step_products(step)
	local others
	for _, t in pairs(targets) do
		local e = t.entity
		if e.valid and not s.busy[t.unit] and not rejected(job, t.unit, step.pid) then
			if t.mode == "chest" then
				return e, "chest", EMPTY_MAP
			elseif t.mode == "push" and not e.disabled_by_script then
				local current = t.recipe and N.bound(e).get_recipe()
				if t.recipe and not (current ~= nil and current.name == t.recipe) then
					others = others or {}
					others[#others + 1] = t
				else
					local map, why = fluid_map(e, ingredients, products, true)
					if not map then reject(job, t.unit, step.pid) job.problem = why
					elseif machine_idle(e, ingredients, map) then return e, "push", map end
				end
			end
		end
	end
	if not (others and net) then return nil end
	for _, t in ipairs(others) do
		local e = t.entity
		if e.crafting_progress == 0 and switch_recipe(net, e, t.recipe) then
			local map, why = fluid_map(e, ingredients, products, true)
			if map then return e, "push", map end
			reject(job, t.unit, step.pid)
			job.problem = why
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
	local g = job.group and s.groups and s.groups[job.group]
	if g then return STEP_OPS * group_speed(g) end
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

--- the job's position (its CPU's), a new table only when it moved (issue #59, lever 3)
local function set_pos(job, entity)
	local p, old = entity.position, job.pos
	if not (old and old.x == p.x and old.y == p.y) then job.pos = { x = p.x, y = p.y } end
end

--- `work.ops`: machine interactions left for this job in this step (counted down)
local function job_step(s, job, work)
	if job.status == "queued" and not job.closing then return end
	local net = job_network(job)
	if not net then set_wait(job, "no-network") return end
	local cpu_rec = job.cpu and s.cpus[job.cpu]
	local group = job.group and s.groups and s.groups[job.group]
	if group and not job.closing then
		if not (group.job == job.id and group.status == "ok") then     -- (settle_group pauses it; never seen)
			release_cpu(s, job)
			job.status = "queued"
			set_wait(job, nil)
			return
		end
		if group.anchor and group.anchor.valid then set_pos(job, group.anchor) end
	elseif not job.closing then
		if not (cpu_rec and cpu_rec.entity.valid) then       -- CPU removed: pause until another one is free
			release_cpu(s, job)
			job.status = "queued"
			set_wait(job, nil)
			return
		end
		set_pos(job, cpu_rec.entity)
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
				local current = N.bound(m).get_recipe()
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
				batch = math.min(batch, math.floor(ing_pool(job, ing) / per + 1e-9))
				if ing.type == "item" then
					local size = stack_size_of(ing.name)
					batch = math.min(batch, size and math.floor(size / per) or 0)
				end
			end
			if batch <= 0 then waiting = waiting or "ingredients" break end
			local machine, mode, map
			if step.kind == "crafting" then
				machine, map = find_crafter(s, net, job, step, targets)
				mode = "craft"
			else
				machine, mode, map = find_pusher(s, net, job, step, targets)
			end
			if not machine then waiting = waiting or "machine" break end
			if mode ~= "chest" then
				for _, p in pairs(products) do        -- the products must fit into the output slot
					if p.type == "item" then
						local per = p.amount or p.amount_max
						local size = stack_size_of(p.name)
						if size and per > 0 then batch = math.min(batch, math.max(1, math.floor(size / per))) end
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
							local short = fixed_up(ing.amount) - ing_pool(job, ing)
							if short > 0 then
								--- its own key first, then (issue #159) the other temperatures it takes
								local want = short + FLUID_MARGIN
								local flex, lo, hi = ing_flex(ing)
								local got = fluids.remove_key(net, key, want)
								if got > 0 then pool_add(job, key, got) job.idle = 0 end
								if flex and got < want then
									for _, k in ipairs(N.fluid_keys(net, ing.name)) do
										if k ~= key and flex_fits(k, ing.name, lo, hi) then
											local n = fluids.remove_key(net, k, want - got)
											if n > 0 then pool_add(job, k, n) job.idle = 0 got = got + n end
											if got >= want then break end
										end
									end
								end
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

--- the jobs of this tick: round robin from s.jcursor, each at most once per STEP_TICKS, at most `budget` of them;
--- a step gets its CPU's operations for every STEP_TICKS since the job's last step (MAX_CATCH_UP at most)
local function step_jobs(s, tick, budget)
	local n = #s.active
	if n == 0 then return end
	local done = 0
	for _ = 1, n do
		if done >= budget or #s.active == 0 then break end
		if s.jcursor > #s.active then s.jcursor = 1 end
		local id = s.active[s.jcursor]
		s.jcursor = s.jcursor + 1
		local job = s.jobs[id]
		if job and (job.status == "queued" or job.status == "running") then
			local since = tick - (job.stepped or (tick - STEP_TICKS))
			if since >= STEP_TICKS then
				if job.stepped then Sched.sample("jobs", since, 1) end
				job.stepped = tick
				done = done + 1
				local scale = math.min(math.floor(since / STEP_TICKS), MAX_CATCH_UP)
				job_step(s, job, { ops = job_ops(s, job) * scale })
			end
		end
	end
end

--- every tick (control.lua): CPUs and pruning every STEP_TICKS, the due jobs, a provider rescan every
--- PROVIDER_SCAN_TICKS, then the tick hooks (maintainers and circuit interfaces)
function M.on_tick(tick)
	local s = storage.fork_ae2
	if not s then return end
	if tick % STEP_TICKS == 0 then
		if #s.active > 0 then assign_cpus(s) end
		prune_finished(s)
	end
	--- issue #38: the steps per tick follow the running jobs (each stepped every STEP_TICKS), between the settings
	if #s.active > 0 then step_jobs(s, tick, Sched.load_budget(#s.active, STEP_TICKS, Sched.setting("jobs"), Sched.setting("jobs_max"))) end
	if tick % PROVIDER_SCAN_TICKS == 0 then maintenance(s, 1) end
	for _, hook in pairs(M.step_hooks) do hook(s, tick) end
end

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
		local _, deg = N.split_fluid_key(key)
		return { key = key, name = fluid_name(key), fluid = true, sprite = "fluid/" .. fluid_name(key), localised_name = fluids.key_name(key),
			temperature = deg }
	end
	return { key = key, name = key, fluid = false, sprite = "item/" .. key, localised_name = proto.localised_name }
end

--- Crafting CPUs of the network: CPUs, free job slots, powered CPUs, job slots (a multiblock CPU and a base CPU have
--- one; a multiblock CPU is powered when its network works)
function M.cpu_summary(net)
	local s = state()
	local total, free, powered, slots = 0, 0, 0, 0
	for _, g in ipairs(groups_in(s, net)) do
		total, slots = total + 1, slots + 1
		if not g.job then free = free + 1 end
		if group_network(g) then powered = powered + 1 end
	end
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
	for _, g in ipairs(groups_in(s, net)) do
		if not g.job and group_network(g) then return true end
	end
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
function M.plan(net, key, amount, fresh, fresh_only)
	local s = state()
	if not (proto_of(key) and amount and amount >= 1) then return nil end
	if fresh then refresh_providers(s) end
	return make_plan(s, net, key, math.floor(amount), fresh_only)
end

--- issue #50: { hits, misses } of the kept plans since the load (tests, the benchmark)
function M.kept_plan_stats() return { hits = kept_stats.hits, misses = kept_stats.misses } end

--- Issue #5: before a job starts, the providers of its plan's patterns are scanned (not every provider of the map:
--- 200 of them cost 18 ms); true when a pattern changed (then the plan is made again).
local function rescan_plan(s, net, plan)
	local pats = s.patterns[net.id]
	if not (pats and pats.prov) then return false end
	local units, seen = {}, {}
	for _, st in ipairs(plan.steps or {}) do
		for _, unit in ipairs(pats.prov[st.pid] or {}) do
			if not seen[unit] then
				seen[unit] = true
				units[#units + 1] = unit
			end
		end
	end
	table.sort(units)
	local dirty = s.dirty
	for _, unit in ipairs(units) do
		local p = s.providers[unit]
		if p and p.entity.valid then scan_provider(p) else drop_provider(s, unit) end
	end
	return s.dirty and not dirty
end

--- the job step of a planned step
local function job_step_of(st)
	local step = { pid = st.pid, def = st.def, kind = st.def.kind, recipe = st.def.recipe, runs = st.runs, issued = 0, done = 0 }
	if step.kind == "processing" then step.received = {} end
	return step
end

--- Start a job for `amount` of `key` in the network of `entity` (a network member such as the
--- terminal). `owner`: unit number of the level maintainer that asked for it (nil for a player).
--- Returns the job id, or nil, a reason key and the plan. Issue #6: the job needs a CPU now (a free multiblock CPU
--- with plan.bytes, or a free slot of a legacy CPU): else "cpu-too-small" (plan.biggest: the biggest CPU's bytes) or
--- "no-free-cpu".
function M.start(entity, key, amount, owner)
	local s = state()
	local net = network_of(entity)
	if not net then return nil, "no-network" end
	amount = math.floor(tonumber(amount) or 0)
	if amount < 1 then return nil, "bad-amount" end
	if amount > (is_fluid(key) and MAX_FLUID_AMOUNT or MAX_AMOUNT) then return nil, "too-many" end
	if not proto_of(key) then return nil, "no-pattern" end
	if #cpus_in(s, net) == 0 and #groups_in(s, net) == 0 then return nil, "no-cpu" end
	local plan = make_plan(s, net, key, amount)
	if rescan_plan(s, net, plan) then plan = make_plan(s, net, key, amount) end
	if plan.no_pattern then return nil, "no-pattern", plan end
	if not plan.ok then return nil, "missing", plan end
	local cpu, kind, biggest = pick_cpu(s, net, plan.bytes)
	if not cpu then
		plan.biggest = biggest
		return nil, kind, plan
	end

	local pool, taken = {}, {}
	local function undo()
		for _, k in pairs(taken) do
			if is_fluid(k) then store_fluid(net, k, pool[k]) else store_item(net, k, QUALITY, pool[k]) end
		end
	end
	for k, count in pairs(plan.reserve) do
		local removed
		if is_fluid(k) then
			removed = fluids.remove_key(net, k, count + FLUID_MARGIN)   -- a little extra covers fixed point rounding
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
		pos = { x = entity.position.x, y = entity.position.y }, owner = owner, anchor = entity, bytes = plan.bytes,
	}
	s.active[#s.active + 1] = id
	local job = s.jobs[id]
	if kind == "group" then
		give_group(cpu, job)
	else
		cpu_jobs(cpu)[id] = true
		job.cpu, job.status = cpu.entity.unit_number, "running"
		job.pos = { x = cpu.entity.position.x, y = cpu.entity.position.y }
	end
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
					bytes = job_bytes(job), group = job.group,
				}
			end
		end
	end
	for _, id in pairs(s.active) do add(id) end
	for _, id in pairs(s.finished) do add(id) end
	table.sort(out, function(a, b) return a.id > b.id end)
	return out
end

--- The crafting CPUs of a network and how many of them have a job (the in-game diagnostic, issue #38)
function M.cpu_report(net)
	local s = state()
	local cpus, busy = 0, 0
	for _, g in ipairs(groups_in(s, net)) do
		cpus = cpus + 1
		if g.job then busy = busy + 1 end
	end
	return { cpus = cpus, busy = busy }
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
		leases = #job.leases, owner = job.owner, cpu = job.cpu, ops = job_ops(s, job), group = job.group, bytes = job_bytes(job),
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
			out[#out + 1] = { "", sep .. fluids.format(counts[key]) .. " ", proto and fluids.key_name(key) or fluid_name(key) }
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
	elseif block_spec(entity.name) then
		add_block(s, entity)
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
	if not (entity and entity.valid and (entity.name == PROVIDER or cpu_spec(entity.name) or block_spec(entity.name))) then return end
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
	if entity and entity.valid and block_spec(entity.name) then          -- a crafting block leaves its CPU (issue #6)
		local s = storage.fork_ae2
		if s then remove_block(s, entity.unit_number) end
		return
	end
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

--- The crafting monitors (issue #6): each monitor of a CPU that runs a job shows the job's item or fluid and the amount it
--- still has to make (two render objects, kept in s.monitors[unit]; issue #140: the amount counts down as the job's steps
--- finish runs, before it showed the amount asked for); redrawn when its CPU's blocks, status or job change, the text set
--- when the job's finished runs change.
local function amount_text(n)
	if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
	if n >= 1e4 then return string.format("%.0fk", n / 1e3) end
	return tostring(math.floor(n))
end

local function clear_monitor(s, unit)
	local r = s.monitors and s.monitors[unit]
	if not r then return end
	for _, obj in pairs(r) do
		if type(obj) ~= "number" and obj.valid then obj.destroy() end
	end
	s.monitors[unit] = nil
end

--- Issue #140: what a job still has to make of its item or fluid, for the crafting monitors: the amount asked for less what its
--- steps have made so far (every finished run of a step makes what its pattern's outputs say of the item), never below 0
local function remaining_of(job)
	local made = 0
	for _, step in ipairs(job.steps) do
		if step.done > 0 then made = made + step.done * P.output_of(step.def, job.item) end
	end
	local left = job.amount - made
	if not is_fluid(job.item) then left = math.ceil(left - 1e-9) end
	return left > 0 and left or 0
end

--- the monitors of the job's CPU count down as the job makes its item (called whenever the job's finished runs change)
function monitor_progress(job)
	local s = storage.fork_ae2
	local g = job.group and s and s.groups and s.groups[job.group]
	if not (g and next(g.monitors)) then return end
	local left
	for unit in pairs(g.monitors) do
		local shown = s.monitors and s.monitors[unit]
		if shown and shown.job == job.id and shown.text.valid then
			left = left or remaining_of(job)
			if shown.left ~= left then
				shown.left = left
				shown.text.text = amount_text(left)
			end
		end
	end
end

local function draw_monitors(g)
	local s = storage.fork_ae2
	if not (s and s.cblocks) then return end
	s.monitors = s.monitors or {}
	local live = s.groups[g.id] == g and g.n > 0
	local job = live and g.status == "ok" and g.job and s.jobs[g.job]
	local sprite = job and (is_fluid(job.item) and ("fluid/" .. fluid_name(job.item)) or ("item/" .. job.item))
	if sprite and not helpers.is_valid_sprite_path(sprite) then sprite = nil end
	for unit in pairs(g.monitors) do
		local b = s.cblocks[unit]
		local e = b and b.entity
		local shown = s.monitors[unit]
		if not (live and job and sprite and e and e.valid) then
			clear_monitor(s, unit)
		elseif not (shown and shown.job == job.id) then
			clear_monitor(s, unit)
			s.monitors[unit] = {
				icon = rendering.draw_sprite{ sprite = sprite, target = { entity = e, offset = { 0, -0.1 } }, surface = e.surface,
					x_scale = 0.55, y_scale = 0.55, render_layer = "higher-object-under" },
				text = rendering.draw_text{ text = amount_text(remaining_of(job)), target = { entity = e, offset = { 0, 0.12 } },
					surface = e.surface, color = { 0.6, 0.95, 1 }, scale = 0.6, alignment = "center", render_layer = "higher-object-under" },
				job = job.id, left = remaining_of(job),
			}
		end
	end
end
M.group_hooks[#M.group_hooks + 1] = draw_monitors

--- a crafting block that vanished without an event (found by the network's sweep)
N.vanish_hooks[#N.vanish_hooks + 1] = function(unit)
	local s = storage.fork_ae2
	if s then remove_block(s, unit) end
end

--- The window data of a crafting block (issue #6): its group's size, status, bytes, co-processors, speed, monitors,
--- network and job. nil for anything else.
function M.group_info(entity)
	if not (entity and entity.valid and block_spec(entity.name)) then return nil end
	local s = cstate(state())
	if not s.cblocks[entity.unit_number] then add_block(s, entity) end
	local g = s.groups[s.cblocks[entity.unit_number].group]
	local monitors = 0
	for _ in pairs(g.monitors) do monitors = monitors + 1 end
	local job = g.job and M.job(g.job)
	return { id = g.id, status = g.status, blocks = g.n, width = g.x2 - g.x1 + 1, height = g.y2 - g.y1 + 1,
		bytes = g.bytes, used = job and job.bytes or 0, coprocessors = g.coprocessors, speed = group_speed(g),
		monitors = monitors, network = group_network_any(g) ~= nil, working = group_network(g) ~= nil, job = job }
end
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
	s.cblocks, s.cgrid, s.groups = {}, {}, {}             -- issue #6: the groups are built again from the blocks
	s.next_group = s.next_group or 1
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
	for _, rec in pairs(s.cpus) do rec.job, rec.jobs = nil, {} end
	for _, id in pairs(shallow(s.active)) do
		local job = s.jobs[id]
		if not job then
			remove_value(s.active, id)
		else
			if legacy then migrate_job(s, job) end
			--- issue #6: a job stays on its legacy CPU (while it is one, with a slot); every other job is queued and
			--- takes the next CPU that fits (multiblock groups are built again, they lose their jobs)
			local rec = job.cpu and s.cpus[job.cpu]
			job.cpu, job.group = nil, nil
			if job.status == "running" and not job.closing then
				if rec and rec.entity.valid and cpu_load(rec) < cpu_slots(rec) then
					cpu_jobs(rec)[job.id] = true
					job.cpu = rec.entity.unit_number
				else
					job.status = "queued"
				end
			end
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
end

--- Other mods and the devcheck runtime test use the same code paths. Resource keys are item names
--- or "fluid/<fluid name>".
remote.add_interface("gregtorio-me-autocraft", {
	--- { ok, missing = {key -> count}, runs, steps, loops, reserve, pids, bytes } or nil
	plan = function(entity, key, amount, fresh_only)
		local net = network_of(entity)
		local p = net and M.plan(net, key, amount, true, fresh_only)
		if not p then return nil end
		local pids, runs_of = {}, {}
		for i, st in ipairs(p.steps) do pids[i], runs_of[i] = st.pid, st.runs end
		return { ok = p.ok, missing = p.missing, runs = p.runs, steps = #p.steps, loops = p.loops,
			reserve = p.reserve, no_pattern = p.no_pattern, pids = pids, step_runs = runs_of, bytes = p.bytes,
			too_complex = p.too_complex, nodes = p.nodes }
	end,
	--- issue #50, lever 6 (tests): the machines of each pattern of the network of `entity` as its patterns are now (made
	--- anew only when a scan found a change): { [pattern id] = { unit numbers } }
	pattern_targets = function(entity)
		local net = network_of(entity)
		local p = net and ensure_patterns(state())[net.id]
		local out = {}
		for id, list in pairs(p and p.targets or {}) do
			local units = {}
			for _, t in ipairs(list) do units[#units + 1] = t.unit end
			out[id] = units
		end
		return out
	end,
	--- issue #50: the kept plans' { hits, misses } since the load
	kept_plan_stats = function() return M.kept_plan_stats() end,
	start = function(entity, key, amount)
		local id, why, p = M.start(entity, key, amount)
		return id, why, p and p.missing, p and p.bytes, p and p.biggest
	end,
	cancel = function(id) return M.cancel(id) end,
	--- issue #6: the CPU (group) of a crafting block: { id, status, blocks, width, height, bytes, used, coprocessors,
	--- speed, monitors, network, working, job }
	group_info = function(block) return M.group_info(block) end,
	--- the CPUs of the network of `entity` for a job of `bytes` (the plan preview)
	cpu_list = function(entity, bytes)
		local net = N.network_of(entity)
		return net and M.cpu_list(net, bytes) or {}
	end,
	--- the render objects of a crafting monitor: { icon = sprite path, text } or nil
	monitor = function(block)
		local s = storage.fork_ae2
		local r = block and block.valid and s and s.monitors and s.monitors[block.unit_number]
		if not (r and r.icon.valid and r.text.valid) then return nil end
		return { sprite = r.icon.sprite, text = r.text.text, job = r.job }
	end,
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
