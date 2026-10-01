--------------------------------------------------------------------------------
--- FORK AE2: AUTOCRAFTING (runtime, see prototypes/121-fork-ae2-autocrafting.lua)
---
--- Patterns: a Pattern Provider looks at the machines next to it (assembling machine or furnace,
---   i.e. Molecular Assembler, any GT machine). The recipe such a machine has set is a pattern
---   of the ME network the provider is connected to (scripts/fork-me-network.lua). Recipes with fluids work when
---   the machine's fluid boxes are not connected to pipes (the network fills and drains them);
---   machines the network cannot use are counted per reason (see machine_problem).
--- Furnaces have no recipe setting: the provider holds a recipe choice (its GUI, opened with the
---   "open" key; copied by settings paste, blueprints and cloning) that applies to every furnace
---   next to it that can make it. Without a choice the furnace's last smelted recipe is used, a
---   furnace with neither is counted as ignored ("no-recipe"). While a furnace holds or smelts
---   something, the recipe it actually runs counts (it picks it from the input item).
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

local PROVIDER, CPU = "me-pattern-provider", "me-crafting-cpu"
local NEIGHBORS = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }

--- CPU tiers: entity name -> { jobs, speed } (prototypes/121-fork-ae2-autocrafting.lua)
local function cpu_specs()
	local md = prototypes.mod_data["fork-me-autocraft"]
	return md and md.data.cpus or { [CPU] = { jobs = 1, speed = 1 } }
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
			providers = {},      -- unit_number -> { entity, net, sig, recipe (furnace choice), machines = { {entity, unit, recipe, fluid, chosen} }, ignored }
			plist = {},          -- unit numbers of providers (round robin for rescans)
			pcursor = 1,
			cpus = {},           -- unit_number -> { entity, jobs = { [job id] = true } } (older saves: job = id)
			jobs = {},           -- id -> job
			active = {},         -- ids of jobs that are not finished
			finished = {},       -- ids of finished jobs (oldest first)
			next_job = 1,
			jcursor = 1,
			busy = {},           -- machine unit_number -> job id
			patterns = {},       -- network id -> { items = { key -> {recipe, ...} }, machines = { recipe -> { entry, ... } }, ignored = { total, [reason] } }
			dirty = true,
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

--------------------------------------------------------------------------------
--- machines and patterns
--------------------------------------------------------------------------------

local function input_inventory(machine)
	local d = defines.inventory
	return machine.get_inventory(machine.type == "furnace" and d.furnace_source or d.crafter_input)
end

local function output_inventory(machine)
	local d = defines.inventory
	return machine.get_inventory(machine.type == "furnace" and d.furnace_result or d.crafter_output)
end

--- The recipe (name) a machine stands for, nil when it has none. `chosen` is the recipe the pattern
--- provider holds for a furnace (see furnace_choice): it counts while the furnace is empty; a furnace
--- that holds or smelts something runs the recipe it picked from its input.
local function machine_recipe(machine, chosen)
	local recipe = machine.get_recipe()
	if chosen and machine.type == "furnace" then
		local inp = input_inventory(machine)
		if recipe and (machine.crafting_progress > 0 or (inp and not inp.is_empty())) then return recipe.name end
		return chosen
	end
	if recipe then return recipe.name end
	if machine.type == "furnace" then
		local previous = machine.previous_recipe
		local name = previous and previous.name
		if name ~= nil and type(name) ~= "string" then name = name.name end   -- a recipe prototype when read
		return name
	end
	return nil
end

local function has_fluid(proto)
	for _, i in pairs(proto.ingredients) do if i.type == "fluid" then return true end end
	for _, p in pairs(proto.products) do if p.type == "fluid" then return true end end
	return false
end

local function connected(fb, index)
	return #fb.get_connections(index) > 0
end

--- The fluid boxes a machine uses for its recipe: which box takes which fluid ingredient and which
--- boxes hold the fluid products. Returns the map, or nil and the reason why the machine cannot
--- be a pattern: "fluid-box" (no usable box, box too small, furnace, two-way box),
--- "fluid-temperature" (the recipe wants a temperature the stored fluid does not have),
--- "fluid-pipes" (a used box is connected to a pipe: the network could not keep the fluid apart).
local function fluid_map(machine, proto)
	if not has_fluid(proto) then return { inputs = {}, outputs = {} } end
	if machine.type ~= "assembling-machine" then return nil, "fluid-box" end
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
	for _, ing in pairs(proto.ingredients) do
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
	for _, p in pairs(proto.products) do
		if p.type == "fluid" then
			n_out = n_out + 1
			max_out = math.max(max_out, p.amount or p.amount_max or 0)
		end
	end
	if n_out > #out_boxes then return nil, "fluid-box" end
	for _, i in pairs(out_boxes) do
		if connected(fb, i) then return nil, "fluid-pipes" end
		local capacity = fb.get_capacity(i)
		if n_out > 0 and capacity < max_out then return nil, "fluid-box" end
		outputs[#outputs + 1] = { index = i, capacity = capacity }
	end
	return { inputs = inputs, outputs = outputs, max_out = max_out }
end

--- nil and the fluid map when the network can use the machine, else the reason:
--- "stack" (more of an item than fits into a machine slot) or one of the fluid reasons above
local function machine_problem(machine, proto)
	for _, i in pairs(proto.ingredients) do
		if i.type == "item" and i.amount > prototypes.item[i.name].stack_size then return "stack" end
	end
	local map, reason = fluid_map(machine, proto)
	if not map then return reason end
	return nil, map
end

--- Recipes a furnace can be a pattern for: its crafting categories, researched by its force, not
--- hidden, items only (a furnace has no fluid boxes the network could fill).
local function furnace_can_make(machine, proto)
	if not (proto and machine.prototype.crafting_categories[proto.category]) then return false end
	if proto.hidden or has_fluid(proto) then return false end
	local r = machine.force.recipes[proto.name]
	return r ~= nil and r.enabled
end

--- the provider's recipe choice if the furnace can make it, else nil
local function furnace_choice(machine, choice)
	if not (choice and machine.type == "furnace") then return nil end
	if furnace_can_make(machine, prototypes.recipe[choice]) then return choice end
	return nil
end

local function scan_provider(p)
	local e = p.entity
	local machines, seen, ignored, sig = {}, {}, { total = 0 }, {}
	local net = N.network_of(e)                  -- patterns are kept while the network is off, jobs wait
	for _, d in pairs(NEIGHBORS) do
		local found = e.surface.find_entities_filtered{
			position = { e.position.x + d[1], e.position.y + d[2] },
			type = { "assembling-machine", "furnace" },
			force = e.force,
		}
		for _, m in pairs(found) do
			if not seen[m.unit_number] then
				seen[m.unit_number] = true
				local chosen = furnace_choice(m, p.recipe)
				local name = machine_recipe(m, chosen)
				local proto = name and prototypes.recipe[name]
				local inside = net ~= nil                  -- a provider outside any network makes no pattern
				if inside and not proto then                -- a furnace without a choice that never smelted
					ignored.total = ignored.total + 1
					ignored["no-recipe"] = (ignored["no-recipe"] or 0) + 1
					sig[#sig + 1] = m.unit_number .. "::no-recipe"
				elseif inside then
					local reason, map = machine_problem(m, proto)
					if reason then
						ignored.total = ignored.total + 1
						ignored[reason] = (ignored[reason] or 0) + 1
						sig[#sig + 1] = m.unit_number .. ":" .. name .. ":" .. reason
					else
						machines[#machines + 1] = { entity = m, unit = m.unit_number, recipe = name, fluid = map, chosen = chosen }
						sig[#sig + 1] = m.unit_number .. ":" .. name .. (chosen and ":chosen" or "")
					end
				end
			end
		end
	end
	table.sort(sig)
	sig = (net and net.id or "-") .. "|" .. table.concat(sig, ",")
	p.machines, p.ignored, p.net = machines, ignored, net and net.id or nil
	if p.sig ~= sig then
		p.sig = sig
		state().dirty = true
	end
end

local function drop_provider(s, unit)
	s.providers[unit] = nil
	remove_value(s.plist, unit)
	s.dirty = true
end

local function rebuild_patterns(s)
	local patterns = {}
	for _, unit in pairs(s.plist) do
		local p = s.providers[unit]
		if p and p.net and p.entity.valid then
			local net = patterns[p.net]
			if not net then
				net = { items = {}, machines = {}, ignored = { total = 0 } }
				patterns[p.net] = net
			end
			local ign = p.ignored
			if type(ign) == "number" then ign = { total = ign, ["fluid-box"] = ign } end   -- providers scanned by an older version
			for reason, n in pairs(ign or {}) do net.ignored[reason] = (net.ignored[reason] or 0) + n end
			local unique = {}
			for _, m in pairs(p.machines) do
				if m.entity.valid and not unique[m.unit] then
					unique[m.unit] = true
					net.machines[m.recipe] = net.machines[m.recipe] or {}
					table.insert(net.machines[m.recipe], m)
					for _, product in pairs(prototypes.recipe[m.recipe].products) do
						local key = key_of(product)
						local list = net.items[key] or {}
						net.items[key] = list
						local known = false
						for _, r in pairs(list) do if r == m.recipe then known = true end end
						if not known then list[#list + 1] = m.recipe end
					end
				end
			end
		end
	end
	for _, net in pairs(patterns) do
		for _, list in pairs(net.items) do table.sort(list) end
	end
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
		refresh_providers(s)
	end
	if s.dirty then rebuild_patterns(s) end
	return s.patterns
end
N.change_hooks[#N.change_hooks + 1] = function()
	local s = storage.fork_ae2
	if s then s.graph_dirty = true end
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

--- items with own data (item-with-tags: a fluid drive item carries its fluid) are never taken from
--- storage: moving them by name and count would strip the data
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

--- expected units per craft, and whether that amount is certain
local function product_yield(proto, key)
	local total, exact = 0, true
	for _, p in pairs(proto.products) do
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
	for k, v in pairs(ctx.steps) do steps[k] = { recipe = v.recipe, runs = v.runs } end
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

--- craft `count` of `key` with one recipe: its ingredients are needed `runs` times
local function apply_recipe(ctx, recipe, key, count, path, depth)
	local proto = prototypes.recipe[recipe]
	local yield, exact = product_yield(proto, key)
	if yield <= 0 then add_missing(ctx, key, count) return end
	local runs = math.ceil(count / yield - 1e-9)
	for _, ing in pairs(proto.ingredients) do
		need(ctx, key_of(ing), ing.amount * runs, path, depth + 1, false)
	end
	local step = ctx.steps[recipe]
	if not step then
		step = { recipe = recipe, runs = 0 }
		ctx.steps[recipe] = step
		ctx.order[#ctx.order + 1] = recipe          -- ingredients were planned first: dependencies come first
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
	local recipes = ctx.patterns.items[key]
	if not recipes then add_missing(ctx, key, count) return end
	if path[key] then
		ctx.loops[key] = true
		add_missing(ctx, key, count)
		return
	end
	path[key] = true
	if #recipes == 1 then
		apply_recipe(ctx, recipes[1], key, count, path, depth)
	else
		--- several patterns: take the first one that needs nothing that is missing
		local start = snapshot(ctx)
		local chosen
		for i, recipe in ipairs(recipes) do
			restore(ctx, snapshot(start))
			apply_recipe(ctx, recipe, key, count, path, depth)
			if ctx.missing_n == start.missing_n then chosen = i break end
		end
		if not chosen then
			restore(ctx, snapshot(start))
			apply_recipe(ctx, recipes[1], key, count, path, depth)
		end
	end
	path[key] = nil
end

--- Plan `amount` of `key` for the network `net`.
--- Returns { ok, missing = {key -> count}, loops = {key -> true}, steps = { {recipe, runs} },
--- reserve = {key -> count taken from storage}, runs, too_complex }
local function make_plan(s, net, key, amount)
	local patterns = ensure_patterns(s)[net.id] or { items = {}, machines = {}, ignored = { total = 0 } }
	local ctx = {
		patterns = patterns, stock = stock_of(net), surplus = {}, reserve = {}, missing = {}, loops = {},
		steps = {}, order = {}, missing_n = 0, nodes = 0,
	}
	if not patterns.items[key] then
		return { ok = false, missing = { [key] = amount }, loops = {}, steps = {}, reserve = {}, runs = 0, no_pattern = true }
	end
	need(ctx, key, amount, {}, 0, true)
	local steps, runs = {}, 0
	for _, recipe in ipairs(ctx.order) do
		local step = ctx.steps[recipe]
		steps[#steps + 1] = { recipe = recipe, runs = step.runs }
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

--- move everything from the pool into the network; what does not fit stays in the pool
local function flush_pool(job, net)
	for key, count in pairs(shallow_map(job.pool)) do
		local inserted = 0
		if count > 0 then
			if is_fluid(key) then
				inserted = fluids.insert(net, fluid_name(key), count)
			else
				inserted = N.insert(net, key, QUALITY, count)
			end
		end
		if inserted >= count - FLUID_EPS then job.pool[key] = nil else job.pool[key] = count - inserted end
	end
	return next(job.pool) == nil
end

--- everything a machine holds of a lease: products into the pool (items and fluid output boxes)
local function collect_output(job, net, machine, map)
	local out = output_inventory(machine)
	if out then
		for _, c in pairs(out.get_contents()) do
			local removed = out.remove{ name = c.name, count = c.count, quality = c.quality }
			if removed > 0 then
				if (c.quality or QUALITY) == QUALITY then
					pool_add(job, c.name, removed)
				else
					local inserted = net and N.insert(net, c.name, c.quality, removed) or 0
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
				pool_add(job, FLUID_PREFIX .. f.name, f.amount)
				fb[o.index] = nil
			end
		end
	end
end

--- unused inputs back into the pool (items and fluid input boxes)
local function take_back_input(job, machine, proto, map)
	local inp = input_inventory(machine)
	if inp then
		for _, ing in pairs(proto.ingredients) do
			if ing.type == "item" then
				local held = inp.get_item_count(ing.name)
				local removed = held > 0 and inp.remove{ name = ing.name, count = held } or 0
				if removed > 0 then pool_add(job, ing.name, removed) end
			end
		end
	end
	if map and #map.inputs > 0 then
		local fb = machine.fluidbox
		for _, i in pairs(map.inputs) do
			local f = i.index <= #fb and fb[i.index] or nil
			if f and f.amount > 0 then
				pool_add(job, FLUID_PREFIX .. f.name, f.amount)
				fb[i.index] = nil
			end
		end
	end
end

--- nothing in progress and nothing left to craft with (fluid remainders below one craft count as empty)
local function machine_idle(machine, proto, map)
	if machine.crafting_progress > 0 then return false end
	local inp = input_inventory(machine)
	if not inp then return false end
	for _, ing in pairs(proto.ingredients) do
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
end

--- Cancel or fail: stop handing out work, take unused inputs back, keep waiting for machines that
--- are still crafting so their products can be collected, then give the pool back to the network.
local function begin_closing(s, job, final_status, reason)
	if job.closing or job.status == "done" or job.status == "failed" or job.status == "cancelled" then return end
	job.closing = final_status
	job.reason = reason
	job.closing_steps = 0
	for _, lease in pairs(job.leases) do
		local proto = prototypes.recipe[lease.recipe]
		if proto and lease.machine.valid then take_back_input(job, lease.machine, proto, lease.fluid) end
	end
	if job.status == "queued" then job.status = "running" end
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

--- one lease per machine: hand `batch` crafts of ingredients to it
local function start_lease(s, job, step_index, machine, batch, map, chosen)
	local step = job.steps[step_index]
	local proto = prototypes.recipe[step.recipe]
	local inp = input_inventory(machine)
	if not inp then return false end
	for _, ing in pairs(proto.ingredients) do          -- never hand out more than the pool holds
		local per = ing.type == "fluid" and fixed_up(ing.amount) or ing.amount
		if (job.pool[key_of(ing)] or 0) + FLUID_EPS < per * batch then return false end
	end
	local given = {}
	local function undo()
		for _, g in pairs(given) do
			if g.fluid then
				machine.fluidbox[g.index] = nil
			elseif g.got > 0 then
				inp.remove{ name = g.name, count = g.got }
			end
			pool_add(job, g.key, g.got)
		end
	end
	for _, ing in pairs(proto.ingredients) do
		if ing.type == "item" then
			local count = ing.amount * batch
			local inserted = inp.insert{ name = ing.name, count = count }
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
	job.leases[#job.leases + 1] = { machine = machine, unit = machine.unit_number, step = step_index,
		recipe = step.recipe, runs = batch, fluid = map, chosen = chosen, finished0 = machine.products_finished }
	s.busy[machine.unit_number] = job.id
	return true
end

--- an idle pattern machine for the recipe, its fluid map and the furnace choice it was found with
local function find_machine(s, net, recipe, proto)
	local net_patterns = ensure_patterns(s)[net.id]
	local list = net_patterns and net_patterns.machines[recipe]
	if not list then return nil end
	for _, m in pairs(list) do
		local e = m.entity
		if e.valid and not s.busy[m.unit] and not e.disabled_by_script
			and machine_recipe(e, m.chosen) == recipe and machine_idle(e, proto, m.fluid) then
			local ok = true
			if m.fluid and (#m.fluid.inputs > 0 or #m.fluid.outputs > 0) then   -- a pipe connected since the scan
				local fb = e.fluidbox
				for _, i in pairs(m.fluid.inputs) do if connected(fb, i.index) then ok = false end end
				for _, o in pairs(m.fluid.outputs) do if connected(fb, o.index) then ok = false end end
			end
			if ok then return e, m.fluid or { inputs = {}, outputs = {} }, m.chosen end
		end
	end
	return nil
end

--- crafts per hand-over that fit into the machine's fluid boxes
local function fluid_batch_limit(map, proto, batch)
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
				local proto = prototypes.recipe[real.recipe]
				local recipe_changed = machine_recipe(m, real.chosen) ~= real.recipe
				if recipe_changed and not job.closing then
					take_back_input(job, m, proto, real.fluid)
					collect_output(job, net, m, real.fluid)
					release_lease(s, job, real)
					--- a furnace picks its recipe from the input item: another recipe with the same input won
					local why = m.type == "furnace" and "reason-furnace-other-recipe" or "reason-recipe-changed"
					begin_closing(s, job, "failed", { "fork-me-craft." .. why })
					progress = true
				elseif machine_idle(m, proto, real.fluid) or recipe_changed then
					collect_output(job, net, m, real.fluid)
					take_back_input(job, m, proto, real.fluid)
					local runs = real.runs
					if real.finished0 and not recipe_changed then     -- fewer crafts than handed over: hand the rest out again
						local crafted = m.products_finished - real.finished0
						if crafted >= 0 and crafted < runs then
							job.steps[real.step].issued = job.steps[real.step].issued - (runs - crafted)
							runs = crafted
						end
					end
					job.steps[real.step].done = job.steps[real.step].done + runs
					job.done_runs = job.done_runs + runs
					release_lease(s, job, real)
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
	for i, step in ipairs(job.steps) do
		local proto = prototypes.recipe[step.recipe]
		while work.ops > 0 and step.issued < step.runs do
			local batch = math.min(step.runs - step.issued, MAX_BATCH)
			for _, p in pairs(proto.products) do        -- the products must fit into the output slot
				if p.type == "item" then
					local per = p.amount or p.amount_max
					batch = math.min(batch, math.max(1, math.floor(prototypes.item[p.name].stack_size / per)))
				end
			end
			for _, ing in pairs(proto.ingredients) do   -- only what the pool holds, one stack per item ingredient
				local per = ing.type == "fluid" and fixed_up(ing.amount) or ing.amount
				batch = math.min(batch, math.floor((job.pool[key_of(ing)] or 0) / per + 1e-9))
				if ing.type == "item" then
					batch = math.min(batch, math.floor(prototypes.item[ing.name].stack_size / per))
				end
			end
			if batch <= 0 then waiting = waiting or "ingredients" break end
			local machine, map, chosen = find_machine(s, net, step.recipe, proto)
			if not machine then waiting = waiting or "machine" break end
			batch = fluid_batch_limit(map, proto, batch)
			if batch <= 0 then waiting = waiting or "machine" break end
			collect_output(job, net, machine, map)
			if not start_lease(s, job, i, machine, batch, map, chosen) then waiting = waiting or "machine" break end
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
		if flush_pool(job, net) then finish(s, job, "done") end
		return
	end

	--- 5) stalled: nothing arrives and nothing can be started. A shortfall (probabilistic products,
	---    fluid rounding) is topped up from network storage; otherwise the job fails after STALL_STEPS.
	if progress then
		job.idle = 0
		set_wait(job, nil)
	else
		set_wait(job, waiting or (#job.leases > 0 and "crafting" or nil))
		if #job.leases == 0 and waiting == "ingredients" then
			for _, step in pairs(job.steps) do
				if step.issued < step.runs then
					for _, ing in pairs(prototypes.recipe[step.recipe].ingredients) do
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
--- public interface
--------------------------------------------------------------------------------

--- Resources the network can craft: { key, ... } (items by name, fluids as "fluid/<name>"), and the
--- table of pattern machines the network cannot use: { total = n, [reason] = n }
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
			if is_fluid(k) then fluids.insert(net, fluid_name(k), pool[k]) else N.insert(net, k, QUALITY, pool[k]) end
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
		steps[#steps + 1] = { recipe = st.recipe, runs = st.runs, issued = 0, done = 0 }
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
	return { id = job.id, item = job.item, amount = job.amount, status = job.status, closing = job.closing,
		wait = job.wait, done = job.done_runs, total = job.total_runs, pool = job.pool,
		leases = #job.leases, owner = job.owner, cpu = job.cpu, ops = job_ops(s, job),
		cpu_name = rec and rec.entity.valid and rec.entity.name or nil }
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
--- recipe choice of a pattern provider (for the furnaces next to it)
--------------------------------------------------------------------------------

local TAG = "fork_ae2_recipe"                -- blueprint tag of a provider's choice

local function register(s, entity)
	if entity.name == PROVIDER then
		local unit = entity.unit_number
		if not s.providers[unit] then
			s.providers[unit] = { entity = entity, machines = {}, ignored = { total = 0 } }
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

--- the furnaces next to a provider (in the order of NEIGHBORS, each once)
local function furnaces_next_to(entity)
	local out, seen = {}, {}
	for _, d in pairs(NEIGHBORS) do
		for _, m in pairs(entity.surface.find_entities_filtered{
			position = { entity.position.x + d[1], entity.position.y + d[2] }, type = "furnace", force = entity.force,
		}) do
			if not seen[m.unit_number] then
				seen[m.unit_number] = true
				out[#out + 1] = m
			end
		end
	end
	return out
end

--- The recipe choice of a provider, nil when it has none
function M.get_recipe(entity)
	local p = provider_record(entity)
	return p and p.recipe
end

--- Set (recipe name) or clear (nil) the recipe choice of a provider; the patterns are updated at
--- once. The GUI, settings paste, blueprints and the devcheck test use this. Returns true when set.
function M.set_recipe(entity, name)
	local p = provider_record(entity)
	if not p then return false end
	if name ~= nil and not prototypes.recipe[name] then return false end
	p.recipe = name
	scan_provider(p)
	return true
end

--- Recipes the player can choose for a provider: every recipe one of the furnaces next to it can make
--- (see furnace_can_make), sorted by order. `shared[name]` is true when another of these recipes
--- has the same input item: the furnace picks the recipe from its input, so it may run the other one.
function M.recipe_options(entity)
	local names, seen, protos = {}, {}, {}
	for _, m in pairs(furnaces_next_to(entity)) do
		local filters = {}
		for category in pairs(m.prototype.crafting_categories) do
			filters[#filters + 1] = { filter = "category", category = category }
		end
		if #filters > 0 then
			for name, proto in pairs(prototypes.get_recipe_filtered(filters)) do
				if not seen[name] and furnace_can_make(m, proto) then
					seen[name] = true
					names[#names + 1] = name
					protos[name] = proto
				end
			end
		end
	end
	table.sort(names, function(a, b)
		local pa, pb = protos[a], protos[b]
		if pa.group.order ~= pb.group.order then return pa.group.order < pb.group.order end
		if pa.subgroup.order ~= pb.subgroup.order then return pa.subgroup.order < pb.subgroup.order end
		if pa.order ~= pb.order then return pa.order < pb.order end
		return a < b
	end)
	local by_input, shared = {}, {}
	for _, name in pairs(names) do
		for _, ing in pairs(protos[name].ingredients) do
			local other = by_input[ing.name]
			if other then shared[other], shared[name] = true, true else by_input[ing.name] = name end
		end
	end
	return names, shared
end

--- The pattern provider window's data: the machines next to it (name, recipe or the reason they are no
--- pattern), the recipe choice for furnaces and its options.
function M.provider_info(entity)
	local p = provider_record(entity)
	if not p then return nil end
	scan_provider(p)
	local machines = {}
	for _, m in pairs(p.machines or {}) do
		if m.entity.valid then
			machines[#machines + 1] = { name = m.entity.name, unit = m.unit, recipe = m.recipe, chosen = m.chosen ~= nil }
		end
	end
	table.sort(machines, function(a, b) return a.unit < b.unit end)
	local options, shared = M.recipe_options(entity)
	local ignored = {}
	for reason, n in pairs(p.ignored or {}) do if reason ~= "total" then ignored[reason] = n end end
	return { machines = machines, ignored = ignored, choice = p.recipe, furnaces = #furnaces_next_to(entity),
		options = options, shared = shared, network = p.net ~= nil }
end

--- the pattern provider window's recipe button: choose it, or clear the choice when it is chosen already
function M.toggle_recipe(entity, name)
	if name == nil or name == M.get_recipe(entity) then return M.set_recipe(entity, nil) end
	return M.set_recipe(entity, name)
end

--- The CPU window's data: its tier (job slots, speed), power, and the jobs it runs or that wait in its network
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

--- copy the choice with the provider's settings (shift right click, shift left click)
function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (src and src.valid and dst and dst.valid and src.name == PROVIDER and dst.name == PROVIDER) then return end
	M.set_recipe(dst, M.get_recipe(src))
end

--- A blueprint with providers carries their choice as entity tag; the fluid interfaces (fluids module)
--- and the blueprint hooks (level maintainers, circuit interfaces) tag theirs. `bp` is the blueprint
--- (item stack or record), `mapping` blueprint entity index -> source entity.
function M.tag_blueprint(bp, mapping)
	if not (bp and bp.valid and mapping) then return end
	for index, entity in pairs(mapping) do
		if entity.valid and entity.name == PROVIDER then
			local choice = M.get_recipe(entity)
			if choice then bp.set_blueprint_entity_tag(index, TAG, choice) end
		end
	end
	fluids.tag_blueprint(bp, mapping)
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

--- `tags`: the blueprint tags of a built ghost; `source`: the original of a cloned entity
function M.on_built(entity, tags, source)
	if not (entity and entity.valid and (entity.name == PROVIDER or cpu_spec(entity.name))) then return end
	register(state(), entity)
	if entity.name ~= PROVIDER then return end
	local choice = type(tags) == "table" and tags[TAG] or nil
	if not choice and source and source.valid and source.name == PROVIDER then choice = M.get_recipe(source) end
	if type(choice) == "string" then M.set_recipe(entity, choice) end
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
			local proto = prototypes.recipe[lease.recipe]
			collect_output(job, job_network(job), entity, lease.fluid)
			if proto then take_back_input(job, entity, proto, lease.fluid) end
			return
		end
	end
end
fluids.mined_hooks[#fluids.mined_hooks + 1] = M.on_mined

--- Rebuild the registries from the world, drop stale references, and repair the job books.
--- Jobs and their pools are kept.
function M.on_configuration_changed()
	local s = state()
	local choices = {}                           -- recipe choices survive the rebuild (dropped if the recipe is gone)
	for unit, p in pairs(s.providers) do
		if p.recipe and prototypes.recipe[p.recipe] then choices[unit] = p.recipe end
	end
	s.providers, s.plist, s.pcursor, s.patterns, s.dirty = {}, {}, 1, {}, true
	s.cpus = {}
	local names = cpu_names()
	names[#names + 1] = PROVIDER
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = names }) do
			register(s, e)
			local p = s.providers[e.unit_number]
			if p and choices[e.unit_number] then
				p.recipe = choices[e.unit_number]
				scan_provider(p)
			end
		end
	end
	s.busy = {}
	for _, id in pairs(shallow(s.active)) do
		local job = s.jobs[id]
		if not job then
			remove_value(s.active, id)
		else
			job.cpu = nil
			if job.status == "running" and not job.closing then job.status = "queued" end
			for _, lease in pairs(shallow(job.leases)) do
				if lease.machine.valid and prototypes.recipe[lease.recipe] then
					s.busy[lease.unit] = job.id
					if lease.fluid == nil then lease.fluid = { inputs = {}, outputs = {} } end   -- leases from before fluid support
				else
					remove_value(job.leases, lease)
					if not job.closing then begin_closing(s, job, "failed", { "fork-me-craft.reason-machine-lost" }) end
				end
			end
			for _, step in pairs(job.steps) do
				if not prototypes.recipe[step.recipe] then
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
	--- { ok, missing = {key -> count}, runs, steps, loops, reserve } or nil
	plan = function(entity, key, amount)
		local net = network_of(entity)
		local p = net and M.plan(net, key, amount, true)
		if not p then return nil end
		return { ok = p.ok, missing = p.missing, runs = p.runs, steps = #p.steps, loops = p.loops,
			reserve = p.reserve, no_pattern = p.no_pattern }
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
	--- { total = n, [reason] = n } of the pattern machines the network cannot use
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
	--- recipe choice of a pattern provider for the furnaces next to it (the GUI's code path)
	get_recipe = function(provider) return M.get_recipe(provider) end,
	set_recipe = function(provider, name) return M.set_recipe(provider, name) end,
	recipe_options = function(provider) return M.recipe_options(provider) end,
	--- the pattern provider window's recipe button (choose, or clear when chosen), the CPU window's data (R3)
	toggle_recipe = function(provider, name) return M.toggle_recipe(provider, name) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	tag_blueprint = function(bp, mapping) M.tag_blueprint(bp, mapping) end,
})

return M
