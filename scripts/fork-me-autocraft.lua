--------------------------------------------------------------------------------
--- FORK AE2: AUTOCRAFTING (runtime, see prototypes/121-fork-ae2-autocrafting.lua)
---
--- Patterns: a Pattern Provider looks at the machines next to it (assembling machine or furnace,
---   i.e. Molecular Assembler, any GT machine). The recipe such a machine has set is a pattern
---   of the ME network (= logistic network) the provider stands in. Recipes with a fluid
---   ingredient or product are ignored (no fluid storage in the ME network).
--- CPU: a Crafting CPU runs one job at a time; the number of CPUs in the network is the number
---   of parallel jobs. Jobs wait ("queued") until a CPU is free.
--- Planning: recursive over the patterns, storage first, loops recognised, missing raw
---   materials reported before anything is started (M.plan).
--- Job: at start the items taken from storage are removed from the network into the job's own
---   item pool (storage.fork_ae2.jobs[id].pool). Each step the CPU hands batches of ingredients
---   to idle pattern machines (machine.insert), waits until the machine is idle again, moves
---   the products into the pool, and at the end everything left in the pool (result and
---   by-products) is stored in the network. Cancel and failure give the pool back the same way.
--- Work per step: STEP_OPS machine interactions per job, MAX_JOBS_PER_STEP jobs, PROVIDERS_PER_STEP
---   provider rescans, one step every STEP_TICKS ticks (30 and 60 are used by the terminal and
---   the molds, see control.lua).
--- State: storage.fork_ae2 only (entities, item counts, plain data). GUI state lives in the GUI.
--------------------------------------------------------------------------------

local M = {}

local STEP_TICKS = 20
local MAX_JOBS_PER_STEP = 8
local STEP_OPS = 6              -- machine hand-overs / collections per job and step
local MAX_BATCH = 16            -- crafts handed to one machine at once
local PROVIDERS_PER_STEP = 8
local STALL_STEPS = 900         -- steps without progress (5 minutes) until a job fails
local KEEP_FINISHED_TICKS = 5 * 60 * 60
local MAX_FINISHED = 12
local MAX_PLAN_NODES = 3000
local MAX_DEPTH = 40
local MAX_AMOUNT = 100000
local QUALITY = "normal"        -- only normal quality items are planned and crafted

local PROVIDER, CPU = "me-pattern-provider", "me-crafting-cpu"
local NEIGHBORS = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }

--------------------------------------------------------------------------------
--- state
--------------------------------------------------------------------------------

local function state()
	local s = storage.fork_ae2
	if not s then
		s = {
			providers = {},      -- unit_number -> { entity, net, sig, machines = { {entity, unit, recipe} }, ignored }
			plist = {},          -- unit numbers of providers (round robin for rescans)
			pcursor = 1,
			cpus = {},           -- unit_number -> { entity, job = job id | nil }
			jobs = {},           -- id -> job
			active = {},         -- ids of jobs that are not finished
			finished = {},       -- ids of finished jobs (oldest first)
			next_job = 1,
			jcursor = 1,
			busy = {},           -- machine unit_number -> job id
			patterns = {},       -- network id -> { items = { item -> {recipe, ...} }, machines = { recipe -> { entry, ... } }, ignored = n }
			dirty = true,
		}
		storage.fork_ae2 = s
	end
	return s
end

local function shallow_map(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
local function shallow(list) return { table.unpack(list) } end

local function remove_value(list, value)
	for i = #list, 1, -1 do
		if list[i] == value then table.remove(list, i) end
	end
end

local function network_at(surface, position, force)
	if not (surface and force) then return nil end
	return surface.find_logistic_network_by_position(position, force)
end

local function network_of(entity)
	return network_at(entity.surface, entity.position, entity.force)
end

--------------------------------------------------------------------------------
--- machines and patterns
--------------------------------------------------------------------------------

--- the recipe (name) a machine has set, nil when it has none
local function machine_recipe(machine)
	local recipe = machine.get_recipe()
	if recipe then return recipe.name end
	if machine.type == "furnace" then
		local previous = machine.previous_recipe
		return previous and previous.name or nil
	end
	return nil
end

--- Recipes the network cannot craft: anything with a fluid (no fluid storage in the ME network), and
--- recipes that need more of one ingredient than fits into a machine slot
local function unusable(proto)
	for _, i in pairs(proto.ingredients) do
		if i.type == "fluid" then return true end
		if i.amount > prototypes.item[i.name].stack_size then return true end
	end
	for _, p in pairs(proto.products) do if p.type == "fluid" then return true end end
	return false
end

local function input_inventory(machine)
	local d = defines.inventory
	return machine.get_inventory(machine.type == "furnace" and d.furnace_source or d.crafter_input)
end

local function output_inventory(machine)
	local d = defines.inventory
	return machine.get_inventory(machine.type == "furnace" and d.furnace_result or d.crafter_output)
end

local function scan_provider(p)
	local e = p.entity
	local machines, seen, ignored, sig = {}, {}, 0, {}
	local net = network_of(e)
	for _, d in pairs(NEIGHBORS) do
		local found = e.surface.find_entities_filtered{
			position = { e.position.x + d[1], e.position.y + d[2] },
			type = { "assembling-machine", "furnace" },
			force = e.force,
		}
		for _, m in pairs(found) do
			if not seen[m.unit_number] then
				seen[m.unit_number] = true
				local name = machine_recipe(m)
				local proto = name and prototypes.recipe[name]
				local mnet = proto and network_of(m)
				if proto and net and mnet and mnet.network_id == net.network_id then   -- machines outside the network are ignored
					if unusable(proto) then
						ignored = ignored + 1
					else
						machines[#machines + 1] = { entity = m, unit = m.unit_number, recipe = name }
						sig[#sig + 1] = m.unit_number .. ":" .. name
					end
				end
			end
		end
	end
	table.sort(sig)
	sig = (net and net.network_id or "-") .. "|" .. ignored .. "|" .. table.concat(sig, ",")
	p.machines, p.ignored, p.net = machines, ignored, net and net.network_id or nil
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
				net = { items = {}, machines = {}, ignored = 0 }
				patterns[p.net] = net
			end
			net.ignored = net.ignored + p.ignored
			local unique = {}
			for _, m in pairs(p.machines) do
				if m.entity.valid and not unique[m.unit] then
					unique[m.unit] = true
					net.machines[m.recipe] = net.machines[m.recipe] or {}
					table.insert(net.machines[m.recipe], m)
					for _, product in pairs(prototypes.recipe[m.recipe].products) do
						if product.type == "item" then
							local list = net.items[product.name] or {}
							net.items[product.name] = list
							local known = false
							for _, r in pairs(list) do if r == m.recipe then known = true end end
							if not known then list[#list + 1] = m.recipe end
						end
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

local function ensure_patterns(s)
	if s.dirty then rebuild_patterns(s) end
	return s.patterns
end

--- rescan every provider (before starting a job: patterns must be current)
local function refresh_providers(s)
	for _, unit in pairs(shallow(s.plist)) do
		local p = s.providers[unit]
		if p and p.entity.valid then scan_provider(p) else drop_provider(s, unit) end
	end
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

local function stock_of(net)
	local stock = {}
	for _, c in pairs(net.get_contents()) do
		if (c.quality or QUALITY) == QUALITY then stock[c.name] = (stock[c.name] or 0) + c.count end
	end
	return stock
end

--- expected items per craft, and whether that amount is certain
local function product_yield(proto, item)
	local total, exact = 0, true
	for _, p in pairs(proto.products) do
		if p.type == "item" and p.name == item then
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

local function add_missing(ctx, item, count)
	ctx.missing[item] = (ctx.missing[item] or 0) + count
	ctx.missing_n = ctx.missing_n + count
end

local need

--- craft `count` of `item` with one recipe: its ingredients are needed `runs` times
local function apply_recipe(ctx, recipe, item, count, path, depth)
	local proto = prototypes.recipe[recipe]
	local yield, exact = product_yield(proto, item)
	if yield <= 0 then add_missing(ctx, item, count) return end
	local runs = math.ceil(count / yield - 1e-9)
	for _, ing in pairs(proto.ingredients) do
		need(ctx, ing.name, ing.amount * runs, path, depth + 1, false)
	end
	local step = ctx.steps[recipe]
	if not step then
		step = { recipe = recipe, runs = 0 }
		ctx.steps[recipe] = step
		ctx.order[#ctx.order + 1] = recipe          -- ingredients were planned first: dependencies come first
	end
	step.runs = step.runs + runs
	if exact then                                    -- surplus of a certain yield can be used by later demand
		local over = math.floor(runs * yield - count + 1e-9)
		if over > 0 then ctx.surplus[item] = (ctx.surplus[item] or 0) + over end
	end
end

--- `count` of `item` are needed: take from storage, else craft through a pattern
function need(ctx, item, count, path, depth, top)
	ctx.nodes = ctx.nodes + 1
	if ctx.nodes > MAX_PLAN_NODES or depth > MAX_DEPTH then
		ctx.too_complex = true
		add_missing(ctx, item, count)
		return
	end
	if not top then
		local t = math.min(ctx.surplus[item] or 0, count)
		ctx.surplus[item] = (ctx.surplus[item] or 0) - t
		count = count - t
		t = math.min(ctx.stock[item] or 0, count)
		ctx.stock[item] = (ctx.stock[item] or 0) - t
		ctx.reserve[item] = (ctx.reserve[item] or 0) + t
		count = count - t
		if count <= 0 then return end
	end
	local recipes = ctx.patterns.items[item]
	if not recipes then add_missing(ctx, item, count) return end
	if path[item] then
		ctx.loops[item] = true
		add_missing(ctx, item, count)
		return
	end
	path[item] = true
	if #recipes == 1 then
		apply_recipe(ctx, recipes[1], item, count, path, depth)
	else
		--- several patterns: take the first one that needs nothing that is missing
		local start = snapshot(ctx)
		local chosen
		for i, recipe in ipairs(recipes) do
			restore(ctx, snapshot(start))
			apply_recipe(ctx, recipe, item, count, path, depth)
			if ctx.missing_n == start.missing_n then chosen = i break end
		end
		if not chosen then
			restore(ctx, snapshot(start))
			apply_recipe(ctx, recipes[1], item, count, path, depth)
		end
	end
	path[item] = nil
end

--- Plan `amount` of `item` for the network `net`.
--- Returns { ok, missing = {item -> count}, loops = {item -> true}, steps = { {recipe, runs} },
--- reserve = {item -> count taken from storage}, runs, too_complex }
local function make_plan(s, net, item, amount)
	local patterns = ensure_patterns(s)[net.network_id] or { items = {}, machines = {}, ignored = 0 }
	local ctx = {
		patterns = patterns, stock = stock_of(net), surplus = {}, reserve = {}, missing = {}, loops = {},
		steps = {}, order = {}, missing_n = 0, nodes = 0,
	}
	if not patterns.items[item] then
		return { ok = false, missing = { [item] = amount }, loops = {}, steps = {}, reserve = {}, runs = 0, no_pattern = true }
	end
	need(ctx, item, amount, {}, 0, true)
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

--- CPUs of a network: total, free (no job), and how many of them have power
local function cpus_in(s, net)
	local list = {}
	for unit, rec in pairs(s.cpus) do
		if rec.entity.valid then
			local n = network_of(rec.entity)
			if n and n.network_id == net.network_id then list[#list + 1] = rec end
		else
			s.cpus[unit] = nil
		end
	end
	return list
end

--------------------------------------------------------------------------------
--- jobs
--------------------------------------------------------------------------------

local function job_network(job)
	return network_at(game.get_surface(job.surface), job.pos, game.forces[job.force])
end

local function pool_add(job, name, count)
	job.pool[name] = (job.pool[name] or 0) + count
end

--- move everything from the pool into the network; what does not fit stays in the pool
local function flush_pool(job, net)
	for name, count in pairs(shallow_map(job.pool)) do
		local inserted = count > 0 and net.insert{ name = name, count = count, quality = QUALITY } or 0
		if inserted >= count then job.pool[name] = nil else job.pool[name] = count - inserted end
	end
	return next(job.pool) == nil
end

--- everything a machine holds of a lease: products into the pool, optionally unused inputs too
local function collect_output(job, net, machine)
	local out = output_inventory(machine)
	if not out then return end
	for _, c in pairs(out.get_contents()) do
		local removed = out.remove{ name = c.name, count = c.count, quality = c.quality }
		if removed > 0 then
			if (c.quality or QUALITY) == QUALITY then
				pool_add(job, c.name, removed)
			else
				local inserted = net and net.insert{ name = c.name, count = removed, quality = c.quality } or 0
				if inserted < removed then      -- no room: put it back, the machine keeps it
					out.insert{ name = c.name, count = removed - inserted, quality = c.quality }
				end
			end
		end
	end
end

local function take_back_input(job, machine, proto)
	local inp = input_inventory(machine)
	if not inp then return end
	for _, ing in pairs(proto.ingredients) do
		if ing.type == "item" then
			local removed = inp.remove{ name = ing.name, count = inp.get_item_count(ing.name) }
			if removed > 0 then pool_add(job, ing.name, removed) end
		end
	end
end

local function machine_idle(machine, proto)
	if machine.crafting_progress > 0 then return false end
	local inp = input_inventory(machine)
	if not inp then return false end
	for _, ing in pairs(proto.ingredients) do
		if ing.type == "item" and inp.get_item_count(ing.name) > 0 then return false end
	end
	return true
end

local function release_lease(s, job, lease)
	s.busy[lease.unit] = nil
	remove_value(job.leases, lease)
end

local function release_cpu(s, job)
	local rec = job.cpu and s.cpus[job.cpu]
	if rec and rec.job == job.id then rec.job = nil end
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
		if proto and lease.machine.valid then take_back_input(job, lease.machine, proto) end
	end
	if job.status == "queued" then job.status = "running" end
end

local function assign_cpus(s)
	for _, id in pairs(s.active) do
		local job = s.jobs[id]
		if job and job.status == "queued" and not job.closing then
			local net = job_network(job)
			if net then
				for _, rec in pairs(cpus_in(s, net)) do
					if rec.job == nil then
						rec.job = job.id
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
local function start_lease(s, job, step_index, machine, batch)
	local step = job.steps[step_index]
	local proto = prototypes.recipe[step.recipe]
	local inp = input_inventory(machine)
	if not inp then return false end
	local given = {}
	for _, ing in pairs(proto.ingredients) do          -- never hand out more than the pool holds
		if (job.pool[ing.name] or 0) < ing.amount * batch then return false end
	end
	for _, ing in pairs(proto.ingredients) do
		local count = ing.amount * batch
		pool_add(job, ing.name, -count)
		local inserted = inp.insert{ name = ing.name, count = count }
		given[#given + 1] = { ing.name, inserted, count }
		if inserted < count then
			for _, g in pairs(given) do                 -- undo
				if g[2] > 0 then inp.remove{ name = g[1], count = g[2] } end
				pool_add(job, g[1], g[3])
			end
			return false
		end
	end
	step.issued = step.issued + batch
	job.leases[#job.leases + 1] = { machine = machine, unit = machine.unit_number, step = step_index,
		recipe = step.recipe, runs = batch }
	s.busy[machine.unit_number] = job.id
	return true
end

local function find_machine(s, net, recipe, proto)
	local net_patterns = ensure_patterns(s)[net.network_id]
	local list = net_patterns and net_patterns.machines[recipe]
	if not list then return nil end
	for _, m in pairs(list) do
		local e = m.entity
		if e.valid and not s.busy[m.unit] and not e.disabled_by_script
			and machine_recipe(e) == recipe and machine_idle(e, proto) then
			return e
		end
	end
	return nil
end

--- job status text key for the GUI while the job is running
local function set_wait(job, wait)
	job.wait = wait
end

local function job_step(s, job)
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

	local ops, progress = STEP_OPS, false

	--- 1) collect finished machines
	for _, real in pairs(shallow(job.leases)) do
		if ops > 0 then
			local m = real.machine
			if not m.valid then
				release_lease(s, job, real)
				if not job.closing then
					begin_closing(s, job, "failed", { "fork-me-craft.reason-machine-lost" })
				end
			else
				local proto = prototypes.recipe[real.recipe]
				local recipe_changed = machine_recipe(m) ~= real.recipe
				if recipe_changed and not job.closing then
					take_back_input(job, m, proto)
					collect_output(job, net, m)
					release_lease(s, job, real)
					begin_closing(s, job, "failed", { "fork-me-craft.reason-recipe-changed" })
					progress = true
				elseif machine_idle(m, proto) or recipe_changed then
					collect_output(job, net, m)
					job.steps[real.step].done = job.steps[real.step].done + real.runs
					job.done_runs = job.done_runs + real.runs
					release_lease(s, job, real)
					progress = true
				end
				ops = ops - 1
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
		while ops > 0 and step.issued < step.runs do
			local batch = math.min(step.runs - step.issued, MAX_BATCH)
			for _, p in pairs(proto.products) do        -- the products must fit into the output slot
				if p.type == "item" then
					local per = p.amount or p.amount_max
					batch = math.min(batch, math.max(1, math.floor(prototypes.item[p.name].stack_size / per)))
				end
			end
			for _, ing in pairs(proto.ingredients) do   -- only what the pool holds, one stack per ingredient
				local per = ing.amount
				batch = math.min(batch, math.floor((job.pool[ing.name] or 0) / per),
					math.floor(prototypes.item[ing.name].stack_size / per))
			end
			if batch <= 0 then waiting = waiting or "ingredients" break end
			local machine = find_machine(s, net, step.recipe, proto)
			if not machine then waiting = waiting or "machine" break end
			collect_output(job, net, machine)
			if not start_lease(s, job, i, machine, batch) then waiting = waiting or "machine" break end
			ops = ops - 1
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

	--- 5) stalled: nothing arrives and nothing can be started. A shortfall (probabilistic products)
	---    is topped up from network storage; otherwise the job fails after STALL_STEPS.
	if progress then
		job.idle = 0
		set_wait(job, nil)
	else
		set_wait(job, waiting or (#job.leases > 0 and "crafting" or nil))
		if #job.leases == 0 and waiting == "ingredients" then
			for _, step in pairs(job.steps) do
				if step.issued < step.runs then
					for _, ing in pairs(prototypes.recipe[step.recipe].ingredients) do
						local short = ing.amount - (job.pool[ing.name] or 0)
						if short > 0 then
							local got = net.remove_item{ name = ing.name, count = short, quality = QUALITY }
							if got > 0 then pool_add(job, ing.name, got) job.idle = 0 end
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
		for _, id in pairs(ids) do
			local job = s.jobs[id]
			if job and (job.status == "queued" or job.status == "running") then job_step(s, job) end
		end
	end
	maintenance(s)
	prune_finished(s)
end

script.on_nth_tick(STEP_TICKS, on_step)

--------------------------------------------------------------------------------
--- public interface
--------------------------------------------------------------------------------

local function stack_of(item) return prototypes.item[item] end

--- Items the network can craft: { item name, ... }, plus how many pattern machines were ignored
--- because their recipe uses fluids
function M.craftable(net)
	local s = state()
	local p = ensure_patterns(s)[net.network_id]
	if not p then return {}, 0 end
	local names = {}
	for name in pairs(p.items) do
		if stack_of(name) then names[#names + 1] = name end
	end
	table.sort(names)
	return names, p.ignored
end

--- Crafting CPUs of the network: total, free, powered
function M.cpu_summary(net)
	local s = state()
	local total, free, powered = 0, 0, 0
	for _, rec in pairs(cpus_in(s, net)) do
		total = total + 1
		if rec.job == nil then free = free + 1 end
		if cpu_powered(rec.entity) then powered = powered + 1 end
	end
	return total, free, powered
end

--- `fresh` rescans all pattern providers first (user actions); the GUI preview uses the cache
--- that the round robin rescan keeps current.
function M.plan(net, item, amount, fresh)
	local s = state()
	if not (prototypes.item[item] and amount and amount >= 1) then return nil end
	if fresh then refresh_providers(s) end
	return make_plan(s, net, item, math.floor(amount))
end

--- Start a job for `amount` of `item` in the network of `entity` (a network member such as the
--- terminal). Returns the job id, or nil, a reason key and the plan.
function M.start(entity, item, amount)
	local s = state()
	local net = network_of(entity)
	if not net then return nil, "no-network" end
	amount = math.floor(tonumber(amount) or 0)
	if amount < 1 then return nil, "bad-amount" end
	if amount > MAX_AMOUNT then return nil, "too-many" end
	if not prototypes.item[item] then return nil, "no-pattern" end
	local cpus = cpus_in(s, net)
	if #cpus == 0 then return nil, "no-cpu" end
	refresh_providers(s)
	local plan = make_plan(s, net, item, amount)
	if plan.no_pattern then return nil, "no-pattern", plan end
	if not plan.ok then return nil, "missing", plan end

	local pool, taken = {}, {}
	for name, count in pairs(plan.reserve) do
		local removed = net.remove_item{ name = name, count = count, quality = QUALITY }
		if removed > 0 then pool[name] = removed taken[#taken + 1] = name end
		if removed < count then                       -- storage changed under us: undo
			for _, n in pairs(taken) do net.insert{ name = n, count = pool[n], quality = QUALITY } end
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
		id = id, item = item, amount = amount, status = "queued", steps = steps, pool = pool, leases = {},
		total_runs = total, done_runs = 0, idle = 0, tick = game.tick,
		surface = entity.surface.index, force = entity.force.index,
		pos = { x = entity.position.x, y = entity.position.y },
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

--- Jobs of the network (newest first) as plain data for the GUI and tests
function M.jobs(net)
	local s = state()
	local out = {}
	local function add(id)
		local job = s.jobs[id]
		if job then
			local jn = job_network(job)
			if jn and jn.network_id == net.network_id then
				local status = job.status
				if job.closing then status = job.closing == "done" and "delivering" or "cancelling" end
				out[#out + 1] = {
					id = job.id, item = job.item, amount = job.amount, status = status, wait = job.wait,
					reason = job.reason, done = job.done_runs, total = job.total_runs,
					active = job.status == "queued" or job.status == "running",
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
	local job = state().jobs[id]
	if not job then return nil end
	return { id = job.id, item = job.item, amount = job.amount, status = job.status, closing = job.closing,
		wait = job.wait, done = job.done_runs, total = job.total_runs, pool = job.pool,
		leases = #job.leases }
end

--- LocalisedString "12x A, 3x B" for a { item -> count } table (at most `limit` entries)
function M.item_list(counts, limit)
	local names = {}
	for name in pairs(counts) do names[#names + 1] = name end
	table.sort(names)
	local out = { "" }
	for i, name in ipairs(names) do
		if i > (limit or 6) then out[#out + 1] = ", ..." break end
		if i > 1 then out[#out + 1] = ", " end
		local proto = prototypes.item[name]
		out[#out + 1] = counts[name] .. "x "
		out[#out + 1] = proto and proto.localised_name or name
	end
	return out
end

--------------------------------------------------------------------------------
--- events (called from control.lua)
--------------------------------------------------------------------------------

local function register(s, entity)
	if entity.name == PROVIDER then
		local unit = entity.unit_number
		if not s.providers[unit] then
			s.providers[unit] = { entity = entity, machines = {}, ignored = 0 }
			s.plist[#s.plist + 1] = unit
		end
		scan_provider(s.providers[unit])
		s.dirty = true
	elseif entity.name == CPU then
		local unit = entity.unit_number
		s.cpus[unit] = s.cpus[unit] or { entity = entity }
	end
end

function M.on_built(entity)
	if entity and entity.valid and (entity.name == PROVIDER or entity.name == CPU) then
		register(state(), entity)
	end
end

--- Rebuild the registries from the world, drop stale references, and repair the job books.
--- Jobs and their item pools are kept.
function M.on_configuration_changed()
	local s = state()
	s.providers, s.plist, s.pcursor, s.patterns, s.dirty = {}, {}, 1, {}, true
	s.cpus = {}
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = { PROVIDER, CPU } }) do register(s, e) end
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
			for name in pairs(shallow_map(job.pool)) do
				if not prototypes.item[name] then job.pool[name] = nil end
			end
		end
	end
	for _, rec in pairs(s.cpus) do rec.job = nil end
end

--- Other mods and the devcheck runtime test use the same code paths
remote.add_interface("gregtorio-me-autocraft", {
	--- { ok, missing = {item -> count}, runs, steps, loops, reserve } or nil
	plan = function(entity, item, amount)
		local net = network_of(entity)
		local p = net and M.plan(net, item, amount, true)
		if not p then return nil end
		return { ok = p.ok, missing = p.missing, runs = p.runs, steps = #p.steps, loops = p.loops,
			reserve = p.reserve, no_pattern = p.no_pattern }
	end,
	start = function(entity, item, amount)
		local id, why, p = M.start(entity, item, amount)
		return id, why, p and p.missing
	end,
	cancel = function(id) return M.cancel(id) end,
	job = function(id) return M.job(id) end,
	craftable = function(entity)
		local net = network_of(entity)
		if not net then return {} end
		return (M.craftable(net))
	end,
	cpus = function(entity)
		local net = network_of(entity)
		if not net then return 0, 0, 0 end
		return M.cpu_summary(net)
	end,
})

return M
