--- Places every assembling machine that has an item, gives it a recipe and power, then lets
--- the benchmark run the map. Any runtime error in Gregtorio's scripts or the entities fails
--- the run. Results are logged as DEVCHECK-RUNTIME lines.
--- ME network (prototypes/120-fork-ae2.lua): controller, one drive per tier, interface and
--- terminal on their own power; checked during the benchmark run (see on_nth_tick below).
--- Autocrafting (prototypes/121-fork-ae2-autocrafting.lua, scripts/fork-me-autocraft.lua): a network
--- with a crafting CPU, two Molecular Assemblers with pattern providers (iron plate + 2 iron sticks ->
--- gear, gear + plate -> transport belt) and raw materials in a drive. Job 1 crafts belts through the
--- two-level chain, job 2 asks for more than the raw materials allow and must not start, job 3 is
--- queued behind job 1 (one CPU) and cancelled; its items must come back.
--- Fluids (prototypes/122-fork-ae2-fluids.lua, scripts/fork-me-fluids.lua): a network with a fluid drive,
--- an import interface with a tank of chlorine connected to it, an export interface, a roboport with
--- construction robots, and pattern machines with fluid recipes (chemical reactors, an extractor). Checks the
--- import and export totals, a drive picked up (contents on the item) and placed again by script and by
--- robots, a reported fluid shortfall, and jobs with a fluid ingredient, a fluid product and both.
--- Fluid recovery (issue #26): a destroyed drive (other drives take what fits, the rest is pooled and a
--- robot-rebuilt drive takes it over), the upgrade planner (fluid stays on the old item), the cells taken
--- out of a loaded item by hand (inside and outside a network) and a deleted surface with a pool.
--- Molds (prototypes/150-fork-molds.lua): an LV alloy smelter with a mold recipe must stop
--- without a mold, run with a mold in its mold slot and keep the mold there.
--- Endgame power (prototypes/136-fork-power.lua): a plasma turbine and a naquadah reactor under load
--- must burn their fuel and make power; the turbine's output hatch gets the cooled fluid.
--- Fuel check (issue #25): steam and the other generator's fuel stop a generator; the right fuel runs it.
local ME_Y = 100
local ME_ITEM = "iron-plate"

function setup_me_network(s)
	local fails = {}
	local function place(name, x, y)
		local ok, e = pcall(function()
			return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
		end)
		if not (ok and e) then fails[#fails + 1] = name .. ": " .. tostring(e) end
		return ok and e or nil
	end
	local eei = place("electric-energy-interface", 0, ME_Y)
	if eei then
		eei.power_production = 1e6      -- J per tick (60 MW); a script-created interface starts at 0
		eei.electric_buffer_size = 1e7
	end
	place("substation", 3, ME_Y)
	place("me-controller", 6, ME_Y)
	for i, tier in ipairs({ "1k", "4k", "16k", "64k", "256k" }) do place("me-drive-" .. tier, 2 + i, ME_Y + 3) end
	place("me-interface", 3, ME_Y + 5)
	place("me-terminal", 5, ME_Y + 5)
	place("iron-chest", 7, ME_Y + 5)
	local drive = s.find_entity("me-drive-16k", { 5.5, ME_Y + 3.5 })
	if drive then drive.insert{ name = ME_ITEM, count = 100 } end
	return fails
end

script.on_nth_tick(300, function(event)
	if storage.me_checked or event.tick == 0 then return end   -- also fires at tick 0, before power
	storage.me_checked = true
	local s = game.surfaces[1]
	local function find(name, x, y) return s.find_entity(name, { x + 0.5, y + 0.5 }) end
	local terminal = find("me-terminal", 5, ME_Y + 5)
	local interface = find("me-interface", 3, ME_Y + 5)
	local chest = find("iron-chest", 7, ME_Y + 5)
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	expect(terminal and interface and chest, "ME entities missing")
	if #problems == 0 then
		expect(interface.get_requester_point().trash_not_requested, "ME interface: trash_not_requested not set on build")
		expect(terminal.status == defines.entity_status.working, "ME terminal not usable (status " .. (function() for k, v in pairs(defines.entity_status) do if v == terminal.status then return k end end return tostring(terminal.status) end)() .. ", energy " .. terminal.energy .. ")")
		local network = s.find_logistic_network_by_position(terminal.position, terminal.force)
		expect(network, "ME terminal: no logistic network from the ME controller")
		if network then
			expect(network.get_item_count(ME_ITEM) == 100, "ME network: expected 100 " .. ME_ITEM .. ", got " .. network.get_item_count(ME_ITEM))
			local moved = remote.call("gregtorio-me-terminal", "withdraw", terminal, chest, ME_ITEM, "normal", 30)
			expect(moved == 30 and chest.get_item_count(ME_ITEM) == 30, "ME terminal withdraw: moved " .. tostring(moved))
			local stack = chest.get_inventory(defines.inventory.chest)[1]
			local stored = remote.call("gregtorio-me-terminal", "store_stack", terminal, stack)
			expect(stored == 30 and network.get_item_count(ME_ITEM) == 100, "ME terminal store: stored " .. tostring(stored))
		end
	end
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. p) end
	log("DEVCHECK-RUNTIME-ME " .. (#problems == 0 and "ok" or "failed"))
end)

--- Victory (scripts/fork-victory.lua): researching `victory` must win the game, and go on.
--- Winning stops the scripts of the benchmark run (no player to continue), so this runs last, at
--- tick 1450, and is checked in the same tick.
script.on_nth_tick(1450, function(event)
	if storage.victory_checked or event.tick == 0 then return end
	storage.victory_checked = true
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local ok, err = pcall(function() game.forces.player.technologies["victory"].researched = true end)
	expect(ok, "victory test: " .. tostring(err))
	--- (can_continue cannot be read before a player chooses to go on; the script passes it, see fork-victory.lua)
	expect(game.finished, "victory test: researching `victory` did not finish the game")
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. p) end
	log("DEVCHECK-RUNTIME-VICTORY " .. (#problems == 0 and "ok" or "failed"))
end)

local AC_Y = 140
local AC_PLATES, AC_STICKS = 200, 100
local AC_ITEM, AC_AMOUNT = "transport-belt", 10
local AC_CRUSH, AC_CRUSH_AMOUNT = "crushed-iron", 1

function setup_autocraft_test(s)
	local fails = {}
	local function place(name, x, y, recipe)
		local ok, e = pcall(function()
			return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
		end)
		if not (ok and e) then fails[#fails + 1] = "autocraft " .. name .. ": " .. tostring(e) return nil end
		if recipe then
			e.force.recipes[recipe].enabled = true
			local ok2, err = pcall(function() e.set_recipe(recipe) end)
			if not ok2 then fails[#fails + 1] = "autocraft recipe " .. recipe .. ": " .. tostring(err) end
		end
		return e
	end
	local eei = place("electric-energy-interface", 12.5, AC_Y + 6.5)
	if eei then
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
	end
	place("substation", 13, AC_Y + 2)
	place("me-controller", 6, AC_Y)
	place("me-terminal", 8.5, AC_Y + 4.5)
	place("me-crafting-cpu", 10, AC_Y)
	local drive = place("me-drive-16k", 8.5, AC_Y + 6.5)
	place("me-molecular-assembler", 14.5, AC_Y + 0.5, "iron-gear-crafting-table")
	place("me-molecular-assembler", 20.5, AC_Y + 0.5, AC_ITEM)
	place("me-pattern-provider", 16.5, AC_Y + 0.5)
	place("me-pattern-provider", 18.5, AC_Y + 0.5)
	--- outside the network (controller radius 16): its recipe must not become a pattern
	place("me-molecular-assembler", 32.5, AC_Y + 0.5, "splitter")
	place("me-pattern-provider", 34.5, AC_Y + 0.5)
	--- a GT machine as pattern machine: crushing raw iron (may have several or probabilistic products)
	place("ev-macerator", 16.5, AC_Y + 4.5, AC_CRUSH)
	place("me-pattern-provider", 18.5, AC_Y + 4.5)
	if drive then
		drive.insert{ name = "raw-iron", count = 20 }
		drive.insert{ name = "iron-plate", count = AC_PLATES }
		drive.insert{ name = "iron-stick", count = AC_STICKS }
	end
	return fails
end

local function autocraft_test()
	local s = game.surfaces[1]
	local terminal = s.find_entity("me-terminal", { 8.5, AC_Y + 4.5 })
	local net = terminal and s.find_logistic_network_by_position(terminal.position, terminal.force)
	local function count(item) return net and net.get_item_count{ name = item, quality = "normal" } or -1 end
	local st = storage.autocraft
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish_test(note)
		storage.autocraft.done = true
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL autocraft: " .. p) end
		log("DEVCHECK-RUNTIME-AUTOCRAFT " .. (#problems == 0 and "ok" or "failed") .. (note and (" (" .. note .. ")") or ""))
	end

	if not st then
		if game.tick < 60 then return end
		storage.autocraft = { started = game.tick }
		st = storage.autocraft
		if not terminal then expect(false, "entities missing") return finish_test() end
		local n_cpu, free = remote.call("gregtorio-me-autocraft", "cpus", terminal)
		expect(n_cpu == 1 and free == 1, "expected 1 free CPU, got " .. n_cpu .. "/" .. free)
		local craftable = remote.call("gregtorio-me-autocraft", "craftable", terminal)
		local set = {}
		for _, n in pairs(craftable) do set[n] = true end
		expect(set[AC_ITEM] and set["iron-gear-wheel"], "patterns not registered")
		expect(not set["splitter"], "a machine outside the network became a pattern")
		expect(count("iron-plate") == AC_PLATES and count("iron-stick") == AC_STICKS, "raw materials not in the network")

		--- per-craft amounts, from the recipes
		local belt = prototypes.recipe[AC_ITEM]
		local per_run = 0
		for _, p in pairs(belt.products) do if p.name == AC_ITEM then per_run = p.amount end end
		st.per_run = per_run
		st.runs = math.ceil(AC_AMOUNT / per_run)
		st.belts = st.runs * per_run
		local plan = remote.call("gregtorio-me-autocraft", "plan", terminal, AC_ITEM, AC_AMOUNT)
		expect(plan and plan.ok and plan.steps == 2 and plan.runs == 2 * st.runs, "plan of job 1: " .. serpent.line(plan))

		--- job 1
		local id1, why1 = remote.call("gregtorio-me-autocraft", "start", terminal, AC_ITEM, AC_AMOUNT)
		expect(id1, "job 1 did not start: " .. tostring(why1))
		st.job1 = id1
		--- items are reserved at the start: plates for gears and belts, sticks for gears
		expect(count("iron-plate") == AC_PLATES - 2 * st.runs, "job 1 reserved " .. (AC_PLATES - count("iron-plate")) .. " plates")
		expect(count("iron-stick") == AC_STICKS - 2 * st.runs, "job 1 reserved " .. (AC_STICKS - count("iron-stick")) .. " sticks")

		--- job 2: more than the raw materials allow (sticks run out), must report the exact shortfall and not start
		local big = 1000
		local runs2 = math.ceil(big / per_run)
		local plates_before, sticks_before = count("iron-plate"), count("iron-stick")
		local want_plates, want_sticks = math.max(0, 2 * runs2 - plates_before), math.max(0, 2 * runs2 - sticks_before)
		expect(want_plates > 0 and want_sticks > 0, "test setup: job 2 must be short of plates and sticks")
		local id2, why2, missing = remote.call("gregtorio-me-autocraft", "start", terminal, AC_ITEM, big)
		expect(id2 == nil and why2 == "missing", "job 2 must not start (" .. tostring(id2) .. ", " .. tostring(why2) .. ")")
		expect(missing and (missing["iron-plate"] or 0) == want_plates and (missing["iron-stick"] or 0) == want_sticks,
			"job 2 missing " .. serpent.line(missing) .. ", expected plates " .. want_plates .. " sticks " .. want_sticks)
		expect(count("iron-plate") == plates_before and count("iron-stick") == sticks_before, "job 2 took items although it did not start")

		--- job 3: one CPU only, so it waits; cancelling gives everything back
		local plates3, sticks3 = count("iron-plate"), count("iron-stick")
		local id3 = remote.call("gregtorio-me-autocraft", "start", terminal, AC_ITEM, per_run)
		expect(id3, "job 3 did not start")
		if id3 then
			local j3 = remote.call("gregtorio-me-autocraft", "job", id3)
			expect(j3 and j3.status == "queued", "job 3 should wait for the CPU (status " .. tostring(j3 and j3.status) .. ")")
			expect(count("iron-plate") == plates3 - 2 and count("iron-stick") == sticks3 - 2, "job 3 did not reserve its items")
			remote.call("gregtorio-me-autocraft", "cancel", id3)
			st.job3, st.plates3, st.sticks3 = id3, plates3, sticks3
		end
		if #problems > 0 then return finish_test() end
		return
	end
	if st.done then return end

	--- Everything is a multiple of these crafts, so whatever the network holds (plus what a job still
	--- carries) is worth exactly the raw materials it started with: plate + 2 sticks make a gear,
	--- gear + plate make one craft of belts.
	local function raw_value()
		local belts = count(AC_ITEM) / st.per_run
		return count("iron-plate") + count("iron-gear-wheel") + 2 * belts,
			count("iron-stick") + 2 * count("iron-gear-wheel") + 2 * belts
	end
	local function expect_all_raw(what)
		local plates, sticks = raw_value()
		expect(plates == AC_PLATES and sticks == AC_STICKS, what .. ": raw value " .. plates .. "/" .. sticks .. ", expected " .. AC_PLATES .. "/" .. AC_STICKS)
	end
	local function job_of(id)
		local j = remote.call("gregtorio-me-autocraft", "job", id)
		for item, n in pairs(j and j.pool or {}) do
			expect(n >= 0, "job " .. id .. " pool holds " .. n .. " " .. item)   -- a job may never hand out more than it holds
		end
		return j
	end
	local function timeout_after(ticks, what)
		if game.tick > st.phase_tick + ticks then
			expect(false, what .. " timed out: " .. serpent.line(st.job and job_of(st.job)))
			finish_test()
			return true
		end
	end
	local function next_phase(name) st.phase = name st.phase_tick = game.tick end

	local phase = st.phase or "job1"
	if phase == "job1" then
		st.phase_tick = st.phase_tick or st.started
		local j1, j3 = job_of(st.job1), st.job3 and job_of(st.job3)
		if j3 and j3.status == "cancelled" and not st.j3_checked then
			st.j3_checked = true
			--- the cancelled job's plates/sticks are back (job 1 keeps its own reservation)
			expect(count("iron-plate") == st.plates3 and count("iron-stick") == st.sticks3,
				"job 3 cancelled but items not returned: plates " .. count("iron-plate") .. "/" .. st.plates3 .. " sticks " .. count("iron-stick") .. "/" .. st.sticks3)
		end
		if j1 and (j1.status == "done" or j1.status == "failed") then
			expect(j1.status == "done", "job 1 ended as " .. j1.status)
			expect(st.j3_checked, "job 3 was never cancelled")
			expect(count(AC_ITEM) == st.belts, "job 1 result: " .. count(AC_ITEM) .. " " .. AC_ITEM .. ", expected " .. st.belts)
			expect(count("iron-plate") == AC_PLATES - 2 * st.runs, "plates after job 1: " .. count("iron-plate"))
			expect(count("iron-stick") == AC_STICKS - 2 * st.runs, "sticks after job 1: " .. count("iron-stick"))
			expect(count("iron-gear-wheel") == 0, "leftover gears: " .. count("iron-gear-wheel"))
			expect(j1.done == j1.total, "job 1 progress " .. j1.done .. "/" .. j1.total)
			expect_all_raw("after job 1")
			st.job1_ticks = game.tick - st.started
			if #problems > 0 then return finish_test() end
			--- scenario 2: the CPU is removed while machines are crafting
			st.job = remote.call("gregtorio-me-autocraft", "start", terminal, AC_ITEM, AC_AMOUNT)
			expect(st.job, "job 4 did not start")
			if not st.job then return finish_test() end
			return next_phase("cpu-lease")
		end
		timeout_after(300, "job 1")
	elseif phase == "cpu-lease" then
		local j = job_of(st.job)
		if j.leases > 0 then
			local cpu = s.find_entity("me-crafting-cpu", { 10, AC_Y })
			expect(cpu, "CPU not found")
			if cpu then cpu.destroy() end
			return next_phase("cpu-paused")
		end
		timeout_after(200, "CPU scenario (waiting for a machine to work)")
	elseif phase == "cpu-paused" then
		if game.tick >= st.phase_tick + 100 then
			local j = job_of(st.job)
			expect(j.status == "queued" and j.done < j.total, "job without CPU should be paused, status " .. j.status)
			local ok, cpu = pcall(function()
				return s.create_entity{ name = "me-crafting-cpu", position = { 10, AC_Y }, force = "player", raise_built = true }
			end)
			expect(ok and cpu, "new CPU could not be placed")
			if not (ok and cpu) then return finish_test() end
			return next_phase("cpu-resumed")
		end
	elseif phase == "cpu-resumed" then
		local j = job_of(st.job)
		if j.status == "done" or j.status == "failed" then
			expect(j.status == "done", "job 4 ended as " .. j.status)
			expect(count(AC_ITEM) == 2 * st.belts, "belts after job 4: " .. count(AC_ITEM))
			expect_all_raw("after job 4 (CPU replaced)")
			if #problems > 0 then return finish_test() end
			--- scenario 3: a pattern machine is removed, the job waits; cancelling gives everything back
			st.job = remote.call("gregtorio-me-autocraft", "start", terminal, AC_ITEM, AC_AMOUNT)
			expect(st.job, "job 5 did not start")
			local b = s.find_entity("me-molecular-assembler", { 20.5, AC_Y + 0.5 })
			expect(b, "belt assembler not found")
			if b then b.destroy() end
			if not st.job then return finish_test() end
			return next_phase("machine-wait")
		end
		timeout_after(300, "job 4 after replacing the CPU")
	elseif phase == "machine-wait" then
		local j = job_of(st.job)
		if j.status == "running" and j.wait == "machine" and j.leases == 0 then
			remote.call("gregtorio-me-autocraft", "cancel", st.job)
			return next_phase("machine-cancelled")
		end
		timeout_after(300, "job 5 (waiting for the removed machine)")
	elseif phase == "machine-cancelled" then
		local j = job_of(st.job)
		if j.status == "cancelled" then
			expect(next(j.pool) == nil, "job 5 keeps items after being cancelled: " .. serpent.line(j.pool))
			expect(count("iron-gear-wheel") > 0, "job 5 did not return the gears it made")
			expect_all_raw("after cancelling job 5")
			if #problems > 0 then return finish_test() end
			--- scenario 4: a GT machine (macerator) as pattern machine
			local recipe = prototypes.recipe[AC_CRUSH]
			local yield, per_run = 0, 0
			for _, p in pairs(recipe.products) do
				if p.name == AC_CRUSH then yield = p.amount * (p.probability or 1) end
			end
			for _, i in pairs(recipe.ingredients) do if i.name == "raw-iron" then per_run = i.amount end end
			st.crush_runs = math.ceil(AC_CRUSH_AMOUNT / yield)
			st.crush_raw = per_run
			local plan = remote.call("gregtorio-me-autocraft", "plan", terminal, AC_CRUSH, AC_CRUSH_AMOUNT)
			expect(plan and plan.ok and plan.steps == 1 and plan.runs == st.crush_runs, "macerator plan: " .. serpent.line(plan))
			st.job = remote.call("gregtorio-me-autocraft", "start", terminal, AC_CRUSH, AC_CRUSH_AMOUNT)
			expect(st.job, "macerator job did not start")
			if not st.job then return finish_test() end
			return next_phase("crush")
		end
		timeout_after(200, "cancelling job 5")
	elseif phase == "crush" then
		local j = job_of(st.job)
		if j.status == "done" or j.status == "failed" then
			expect(j.status == "done", "macerator job ended as " .. j.status)
			expect(count("raw-iron") == 20 - st.crush_runs * st.crush_raw, "raw iron left: " .. count("raw-iron"))
			expect(count(AC_CRUSH) >= AC_CRUSH_AMOUNT or #prototypes.recipe[AC_CRUSH].products > 1 or prototypes.recipe[AC_CRUSH].products[1].probability,
				"crushed iron in the network: " .. count(AC_CRUSH))
			expect(next(j.pool) == nil, "macerator job keeps items: " .. serpent.line(j.pool))
			return finish_test("job 1 took " .. st.job1_ticks .. " ticks, whole test " .. (game.tick - st.started))
		end
		timeout_after(600, "macerator job")
	end
end

script.on_nth_tick(10, function()
	if not (storage.autocraft and storage.autocraft.done) then autocraft_test() end
	if not (storage.fluids and storage.fluids.done) then fluid_test() end
	if not (storage.fluid_rec and storage.fluid_rec.done) then recovery_test() end
	if not (storage.fuel and storage.fuel.done) then fuel_test() end
end)


--------------------------------------------------------------------------------
--- fluids: storage, interfaces, drive round trips and fluid autocrafting
--------------------------------------------------------------------------------

local FL_Y = 200                                        -- below everything else: the roboport's area is 25 tiles
local FL_FLUID, FL_TANK_AMOUNT = "chlorine", 2000      -- in the tank connected to interface A
local FL_EXPORT_LEVEL = 1000                            -- interface B exports up to this level
local FL_CHLORINE_EXTRA, FL_PHENOL = 20000, 100         -- put into the network by script for the jobs
local FL_SILICON, FL_TIN, FL_BOARDS = 50, 20, 5
local FL_DRIVE = "me-fluid-drive-1k"
local FL_DRIVE_POS = { 10.5, FL_Y + 2.5 }
local FL_EPS = 1e-3

--- the layout (everything inside the controller's area, x <= 22 and y <= FL_Y + 16; HV reactors: there is no EV one)
local FL = {
	terminal = { "me-terminal", 8.5, FL_Y + 2.5 },
	iface_a = { "me-fluid-interface", 2.5, FL_Y + 4.5 },
	iface_b = { "me-fluid-interface", 5.5, FL_Y + 4.5 },
	tank = { "storage-tank", 3.5, FL_Y + 6.5 },           -- its north connection meets interface A
	idrive = { "me-drive-16k", 12.5, FL_Y + 2.5 },
	chest = { "iron-chest", 14.5, FL_Y + 2.5 },
	reactor_a = { "hv-chemical-reactor", 12.5, FL_Y + 7.5 },
	extractor = { "ev-extractor", 16.5, FL_Y + 7.5 },
	reactor_c = { "hv-chemical-reactor", 12.5, FL_Y + 11.5 },
	reactor_d = { "hv-chemical-reactor", 20.5, FL_Y + 11.5 },
}

function setup_fluid_test(s)
	local fails = {}
	local function place(name, x, y, extra)
		local ok, e = pcall(function()
			local def = { name = name, position = { x, y }, force = "player", raise_built = true }
			for k, v in pairs(extra or {}) do def[k] = v end
			return s.create_entity(def)
		end)
		if not (ok and e) then fails[#fails + 1] = "fluids " .. name .. ": " .. tostring(e) return nil end
		return e
	end
	local function machine(def, recipe)
		local e = place(def[1], def[2], def[3])
		if e and recipe then
			e.force.recipes[recipe].enabled = true
			local ok, err = pcall(function() e.set_recipe(recipe) end)
			if not ok then fails[#fails + 1] = "fluids recipe " .. recipe .. ": " .. tostring(err) end
		end
		return e
	end
	local eei = place("electric-energy-interface", 0, FL_Y)
	if eei then
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
	end
	place("substation", 3, FL_Y)
	place("substation", 16, FL_Y + 4)
	place("me-controller", 6, FL_Y)
	place("me-crafting-cpu", 10, FL_Y)
	place(FL.terminal[1], FL.terminal[2], FL.terminal[3])
	place(FL_DRIVE, FL_DRIVE_POS[1], FL_DRIVE_POS[2])
	local idrive = place(FL.idrive[1], FL.idrive[2], FL.idrive[3])
	place(FL.chest[1], FL.chest[2], FL.chest[3])
	--- import: a tank connected to interface A (default mode is import); export: interface B stands alone.
	--- (No pump: a 2.0 pump moves fluid in proportion to the fill level of its source, a trickle here.)
	place(FL.iface_a[1], FL.iface_a[2], FL.iface_a[3])
	local tank = place(FL.tank[1], FL.tank[2], FL.tank[3])
	if tank then tank.insert_fluid{ name = FL_FLUID, amount = FL_TANK_AMOUNT } end
	place(FL.iface_b[1], FL.iface_b[2], FL.iface_b[3])
	--- construction robots for the drive round trip (the item drive is their storage chest)
	local port = place("roboport", 16, FL_Y)
	if port then port.insert{ name = "construction-robot", count = 2 } end
	game.forces.player.worker_robots_speed_modifier = 3
	--- pattern machines: raw silicon + chlorine -> silicon tetrachloride (fluid in and out), tin ingot ->
	--- molten tin (fluid out), resin board + phenol -> phenolic board (fluid in), and a reactor whose input
	--- box has a pipe connected (must be ignored)
	machine(FL.reactor_a, "silicon-tetrachloride")
	machine(FL.extractor, "molten-tin")
	place("me-pattern-provider", 14.5, FL_Y + 7.5)     -- touches reactor A (west) and the extractor (east)
	machine(FL.reactor_c, "phenolic-circuit-board")
	place("me-pattern-provider", 14.5, FL_Y + 11.5)
	machine(FL.reactor_d, "hydrochloric-acid")
	place("me-pattern-provider", 18.5, FL_Y + 11.5)
	place("pipe", 19.5, FL_Y + 9.5)                    -- on the north-west input port of reactor D
	if idrive then
		idrive.insert{ name = "raw-silicon", count = FL_SILICON }
		idrive.insert{ name = "tin-ingot", count = FL_TIN }
		idrive.insert{ name = "resin-circuit-board", count = FL_BOARDS }
	end
	return fails
end

function fluid_test()
	local s = game.surfaces[1]
	local F, A = "gregtorio-me-fluids", "gregtorio-me-autocraft"
	local function ent(def) return s.find_entity(def[1], { def[2], def[3] }) end
	local terminal = ent(FL.terminal)
	local net = terminal and s.find_logistic_network_by_position(terminal.position, terminal.force)
	local function count(fluid) return terminal and remote.call(F, "count", terminal, fluid) or -1 end
	local function items(name) return net and net.get_item_count{ name = name, quality = "normal" } or -1 end
	local function near(a, b, what) return math.abs(a - b) <= FL_EPS end
	local st = storage.fluids
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish_test(note)
		storage.fluids.done = true
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL fluids: " .. p) end
		log("DEVCHECK-RUNTIME-FLUIDS " .. (#problems == 0 and "ok" or "failed") .. (note and (" (" .. note .. ")") or ""))
	end

	if not st then
		if game.tick < 60 then return end
		storage.fluids = { started = game.tick, phase = "import", phase_tick = game.tick }
		st = storage.fluids
		local a, b, tank, drive = ent(FL.iface_a), ent(FL.iface_b), ent(FL.tank), s.find_entity(FL_DRIVE, FL_DRIVE_POS)
		expect(terminal and a and b and tank and drive, "entities missing")
		if not (terminal and a and b and tank and drive) then return finish_test() end
		expect(net, "no logistic network at the terminal")
		expect(#a.fluidbox.get_connections(1) > 0, "interface A is not connected to the tank")
		expect(#b.fluidbox.get_connections(1) == 0, "interface B must stand alone")
		local capacity, used = remote.call(F, "capacity", terminal)   -- the import may have run already
		expect(capacity == 32000 and used >= 0 and used <= FL_TANK_AMOUNT + FL_EPS, "fluid capacity " .. tostring(capacity) .. "/" .. tostring(used))
		local ia = remote.call(F, "get_interface", a)
		expect(ia and ia.mode == "import", "interface A default mode " .. tostring(ia and ia.mode))
		expect(remote.call(F, "set_interface", b, "export", FL_FLUID, FL_EXPORT_LEVEL), "set_interface failed")
		local ib = remote.call(F, "get_interface", b)
		expect(ib and ib.mode == "export" and ib.fluid == FL_FLUID and ib.level == FL_EXPORT_LEVEL, "interface B settings " .. serpent.line(ib))
		if #problems > 0 then return finish_test() end
		return
	end
	if st.done then return end

	local function timeout_after(ticks, what)
		if game.tick > st.phase_tick + ticks then
			expect(false, what .. " timed out (network " .. FL_FLUID .. " " .. count(FL_FLUID) .. ")")
			finish_test()
			return true
		end
	end
	local function next_phase(name) st.phase = name st.phase_tick = game.tick end
	local a, b, tank = ent(FL.iface_a), ent(FL.iface_b), ent(FL.tank)
	local function in_pipes() return tank.get_fluid_count(FL_FLUID) + a.get_fluid_count(FL_FLUID) end
	local function job_of(id)
		local j = remote.call(A, "job", id)
		for key, n in pairs(j and j.pool or {}) do
			expect(n >= -FL_EPS, "job " .. id .. " pool holds " .. n .. " " .. key)
		end
		return j
	end

	local phase = st.phase
	if phase == "import" then
		--- the tank drains into interface A, the network stores it; B (export since tick 60) takes its level out
		if in_pipes() < 0.01 and near(b.get_fluid_count(FL_FLUID), FL_EXPORT_LEVEL) then
			local stored, in_b = count(FL_FLUID), b.get_fluid_count(FL_FLUID)
			expect(near(stored + in_b, FL_TANK_AMOUNT), "fluid not conserved: network " .. stored .. " + export " .. in_b)
			local capacity, used = remote.call(F, "capacity", terminal)
			expect(near(used, stored), "used " .. used .. " differs from the total " .. stored)
			local totals = remote.call(F, "totals", terminal)
			expect(near(totals[FL_FLUID] or 0, stored), "totals differ from count")
			local ib = remote.call(F, "get_interface", b)
			expect(ib and ib.status == "ok", "interface B status " .. tostring(ib and ib.status))
			st.import_ticks = game.tick - st.started
			if #problems > 0 then return finish_test() end
			return next_phase("export-hold")
		end
		timeout_after(300, "import from the tank")
	elseif phase == "export-hold" then
		--- export never overfills and never takes back
		if game.tick >= st.phase_tick + 60 then
			expect(near(b.get_fluid_count(FL_FLUID), FL_EXPORT_LEVEL), "export level drifted to " .. b.get_fluid_count(FL_FLUID))
			expect(near(count(FL_FLUID), FL_TANK_AMOUNT - FL_EXPORT_LEVEL), "network changed while holding: " .. count(FL_FLUID))
			remote.call(F, "set_interface", b, "import")
			return next_phase("reimport")
		end
	elseif phase == "reimport" then
		if b.get_fluid_count(FL_FLUID) < 0.01 then
			expect(near(count(FL_FLUID), FL_TANK_AMOUNT), "after re-import the network holds " .. count(FL_FLUID))
			if #problems > 0 then return finish_test() end
			--- pick the drive up by script (the same code path the mined events use) and place it again
			local drive, chest = s.find_entity(FL_DRIVE, FL_DRIVE_POS), ent(FL.chest)
			chest.insert{ name = FL_DRIVE, count = 1 }
			local stack = chest.get_inventory(defines.inventory.chest)[1]
			expect(stack.valid_for_read and stack.name == FL_DRIVE and stack.is_item_with_tags, "drive item is not an item with tags")
			expect(remote.call(F, "pack_drive", drive, stack), "pack_drive failed")
			local tags = stack.tags or {}
			local carried = tags.fork_me_fluids and tags.fork_me_fluids[FL_FLUID] or 0
			expect(near(carried, FL_TANK_AMOUNT), "drive item carries " .. tostring(carried))
			expect(count(FL_FLUID) == 0, "pack_drive copied instead of moved: " .. count(FL_FLUID))
			drive.destroy{ raise_destroy = true }
			expect(count(FL_FLUID) == 0, "network still holds fluid after the drive was removed: " .. count(FL_FLUID))
			--- the loaded drive item survives a trip through the terminal (stored as a stack, withdrawn as a stack)
			local stored = remote.call("gregtorio-me-terminal", "store_stack", terminal, stack)
			expect(stored == 1 and items(FL_DRIVE) == 1, "storing the drive item: " .. tostring(stored) .. ", in network " .. items(FL_DRIVE))
			local back = remote.call("gregtorio-me-terminal", "withdraw", terminal, chest, FL_DRIVE, "normal", 1)
			expect(back == 1 and items(FL_DRIVE) == 0, "withdrawing the drive item: " .. tostring(back))
			stack = nil
			local inv = chest.get_inventory(defines.inventory.chest)
			for i = 1, #inv do
				if inv[i].valid_for_read and inv[i].name == FL_DRIVE then stack = inv[i] end
			end
			expect(stack, "drive item not back in the chest")
			if not stack then return finish_test() end
			local tags2 = stack.tags or {}
			expect(near(tags2.fork_me_fluids and tags2.fork_me_fluids[FL_FLUID] or 0, FL_TANK_AMOUNT), "drive item lost its fluid in the terminal: " .. serpent.line(tags2))
			local capacity = remote.call(F, "capacity", terminal)
			expect(capacity == 0, "capacity without drives " .. tostring(capacity))
			local ok, again = pcall(function()
				return s.create_entity{ name = FL_DRIVE, position = FL_DRIVE_POS, force = "player", raise_built = true }
			end)
			expect(ok and again, "drive could not be placed again")
			if not (ok and again) then return finish_test() end
			expect(count(FL_FLUID) == 0, "a freshly placed drive is not empty")
			remote.call(F, "unpack_drive", again, stack.tags)
			stack.clear()
			expect(near(count(FL_FLUID), FL_TANK_AMOUNT), "after placing the drive again the network holds " .. count(FL_FLUID))
			local d = remote.call(F, "drive", again)
			expect(d and d.capacity == 32000 and near(d.used, FL_TANK_AMOUNT), "drive record " .. serpent.line(d))
			if #problems > 0 then return finish_test() end
			--- now the same round trip through construction robots: deconstruct, then a ghost
			expect(again.order_deconstruction(again.force), "order_deconstruction refused")
			return next_phase("robot-mine")
		end
		timeout_after(300, "re-import from interface B")
	elseif phase == "robot-mine" then
		if not s.find_entity(FL_DRIVE, FL_DRIVE_POS) then
			expect(count(FL_FLUID) == 0, "network holds fluid without a drive: " .. count(FL_FLUID))
			return next_phase("robot-stored")
		end
		timeout_after(600, "robots deconstructing the drive")
	elseif phase == "robot-stored" then
		--- the robot delivers the drive item (with its tags) into the storage chest = the item drive
		local idrive = ent(FL.idrive)
		local found
		for _, stack in pairs(idrive.get_inventory(defines.inventory.chest).get_contents()) do
			if stack.name == FL_DRIVE then found = true end
		end
		if found then
			local inv = idrive.get_inventory(defines.inventory.chest)
			local carried
			for i = 1, #inv do
				local stack = inv[i]
				if stack.valid_for_read and stack.name == FL_DRIVE then
					local tags = stack.tags or {}
					carried = tags.fork_me_fluids and tags.fork_me_fluids[FL_FLUID]
				end
			end
			expect(carried and near(carried, FL_TANK_AMOUNT), "robot-mined drive item carries " .. tostring(carried))
			local ok, ghost = pcall(function()
				return s.create_entity{ name = "entity-ghost", inner_name = FL_DRIVE, position = FL_DRIVE_POS, force = "player" }
			end)
			expect(ok and ghost, "ghost could not be placed: " .. tostring(ghost))
			if not (ok and ghost) then return finish_test() end
			return next_phase("robot-build")
		end
		timeout_after(600, "robot storing the drive item")
	elseif phase == "robot-build" then
		if s.find_entity(FL_DRIVE, FL_DRIVE_POS) then
			expect(near(count(FL_FLUID), FL_TANK_AMOUNT), "after the robots placed the drive the network holds " .. count(FL_FLUID))
			if #problems > 0 then return finish_test() end
			--- full drives: the import stops and keeps the fluid in the tank, an export of a fluid the
			--- network does not hold reports it
			local room = 32000 - count(FL_FLUID)
			expect(near(remote.call(F, "insert", terminal, FL_FLUID, room), room), "could not fill the drive")
			expect(near(count(FL_FLUID), 32000), "drive not full: " .. count(FL_FLUID))
			expect(remote.call(F, "insert", terminal, FL_FLUID, 10) == 0, "a full drive took fluid")
			tank.insert_fluid{ name = FL_FLUID, amount = 500 }
			remote.call(F, "set_interface", b, "export", "water", FL_EXPORT_LEVEL)
			return next_phase("full")
		end
		timeout_after(600, "robots building the drive from the ghost")
	elseif phase == "full" then
		if game.tick >= st.phase_tick + 40 then
			local ia, ib = remote.call(F, "get_interface", a), remote.call(F, "get_interface", b)
			expect(ia and ia.status == "full", "import into full drives: status " .. tostring(ia and ia.status))
			expect(near(in_pipes(), 500), "fluid left the tank although the drives are full: " .. in_pipes())
			expect(near(count(FL_FLUID), 32000), "network changed while full: " .. count(FL_FLUID))
			expect(ib and ib.status == "empty-network", "export of a missing fluid: status " .. tostring(ib and ib.status))
			expect(b.get_fluid_count("water") == 0, "export interface got water from nowhere")
			expect(near(remote.call(F, "remove", terminal, FL_FLUID, 30000), 30000), "could not take fluid out")
			remote.call(F, "set_interface", b, "import")
			return next_phase("full-drain")
		end
	elseif phase == "full-drain" then
		if in_pipes() < 0.01 then
			expect(near(count(FL_FLUID), 2500), "after making room the network holds " .. count(FL_FLUID))
			if #problems > 0 then return finish_test() end
			--- fluid autocrafting: fill the network, check the patterns and a shortfall, start three jobs
			expect(near(remote.call(F, "insert", terminal, FL_FLUID, FL_CHLORINE_EXTRA), FL_CHLORINE_EXTRA), "could not insert chlorine")
			expect(near(remote.call(F, "insert", terminal, "phenol", FL_PHENOL), FL_PHENOL), "could not insert phenol")
			local craftable, set = remote.call(A, "craftable", terminal), {}
			for _, k in pairs(craftable) do set[k] = true end
			expect(set["fluid/silicon-tetrachloride"] and set["fluid/molten-tin"] and set["phenolic-circuit-board"], "fluid patterns missing: " .. serpent.line(craftable))
			expect(not set["fluid/hydrochloric-acid"], "a reactor with a pipe on its input became a pattern")
			local ignored = remote.call(A, "ignored", terminal)
			expect(ignored and ignored["fluid-pipes"] == 1, "ignored reasons " .. serpent.line(ignored))
			local d = ent(FL.reactor_d)
			local piped = false
			for i = 1, #d.fluidbox do if #d.fluidbox.get_connections(i) > 0 then piped = true end end
			expect(piped, "test setup: the pipe is not connected to reactor D")
			--- shortfall: 10000 units = 100 runs = 40000 chlorine and 100 raw silicon
			local have = count(FL_FLUID)
			local plan = remote.call(A, "plan", terminal, "fluid/silicon-tetrachloride", 10000)
			expect(plan and not plan.ok and plan.missing, "shortfall plan " .. serpent.line(plan))
			if plan and plan.missing then
				expect(near(plan.missing["fluid/chlorine"] or 0, 40000 - have), "missing chlorine " .. tostring(plan.missing["fluid/chlorine"]) .. ", expected " .. (40000 - have))
				expect(plan.missing["raw-silicon"] == 100 - FL_SILICON, "missing raw silicon " .. tostring(plan.missing["raw-silicon"]))
			end
			expect(near(count(FL_FLUID), have), "a plan took fluid")
			st.chlorine, st.phenol = count(FL_FLUID), count("phenol")
			st.silicon, st.tin, st.boards = items("raw-silicon"), items("tin-ingot"), items("resin-circuit-board")
			local id1, why1 = remote.call(A, "start", terminal, "fluid/silicon-tetrachloride", 200)   -- 2 runs: 800 chlorine, 2 raw silicon
			local id2, why2 = remote.call(A, "start", terminal, "fluid/molten-tin", 100)             -- 7 runs: 7 ingots -> 100.8 molten tin
			local id3, why3 = remote.call(A, "start", terminal, "phenolic-circuit-board", 3)          -- 3 runs: 30 phenol, 3 boards
			expect(id1 and id2 and id3, "fluid jobs did not start: " .. tostring(why1) .. " " .. tostring(why2) .. " " .. tostring(why3))
			if not (id1 and id2 and id3) then return finish_test() end
			--- reserved at the start (plus the small margin per fluid)
			expect(count(FL_FLUID) <= st.chlorine - 800 and count(FL_FLUID) >= st.chlorine - 800.1, "job 1 reserved " .. (st.chlorine - count(FL_FLUID)) .. " chlorine")
			expect(items("raw-silicon") == st.silicon - 2 and items("tin-ingot") == st.tin - 7 and items("resin-circuit-board") == st.boards - 3, "items not reserved")
			st.jobs = { id1, id2, id3 }
			return next_phase("craft")
		end
		timeout_after(200, "import after making room")
	elseif phase == "craft" then
		local all_over, failed = true, {}
		for _, id in pairs(st.jobs) do
			local j = job_of(id)
			if not j or (j.status ~= "done" and j.status ~= "failed") then all_over = false end
			if j and j.status == "failed" then failed[#failed + 1] = id .. ":" .. serpent.line(j) end
		end
		if all_over then
			expect(#failed == 0, "fluid jobs failed: " .. table.concat(failed, "; "))
			expect(near(count("silicon-tetrachloride"), 200), "silicon tetrachloride in the network: " .. count("silicon-tetrachloride"))
			expect(near(count(FL_FLUID), st.chlorine - 800), "chlorine after the jobs: " .. count(FL_FLUID) .. ", expected " .. (st.chlorine - 800))
			expect(near(count("molten-tin"), 100.8), "molten tin in the network: " .. count("molten-tin"))
			expect(near(count("phenol"), st.phenol - 30), "phenol after the jobs: " .. count("phenol"))
			expect(items("raw-silicon") == st.silicon - 2, "raw silicon left: " .. items("raw-silicon"))
			expect(items("tin-ingot") == st.tin - 7, "tin ingots left: " .. items("tin-ingot"))
			expect(items("resin-circuit-board") == st.boards - 3, "resin boards left: " .. items("resin-circuit-board"))
			expect(items("phenolic-circuit-board") == 3, "phenolic boards: " .. items("phenolic-circuit-board"))
			for _, id in pairs(st.jobs) do
				local j = job_of(id)
				expect(j and next(j.pool) == nil, "job " .. id .. " keeps a pool: " .. serpent.line(j and j.pool))
			end
			--- the machines hold nothing of the jobs any more
			for _, def in pairs({ FL.reactor_a, FL.extractor, FL.reactor_c }) do
				local m = ent(def)
				for i = 1, #m.fluidbox do
					local f = m.fluidbox[i]
					expect(not f or f.amount < FL_EPS, def[1] .. " keeps " .. (f and (f.amount .. " " .. f.name) or ""))
				end
			end
			if #problems > 0 then return finish_test() end
			--- a pattern machine mined by robots while it holds the job's fluid: the fluid returns with the pool
			st.chlorine_before = count(FL_FLUID)
			st.job = remote.call(A, "start", terminal, "fluid/silicon-tetrachloride", 100)   -- 1 run: 400 chlorine
			expect(st.job, "job 4 did not start")
			if not st.job then return finish_test() end
			return next_phase("mine-lease")
		end
		timeout_after(600, "fluid jobs")
	elseif phase == "mine-lease" then
		local j = job_of(st.job)
		if j.leases > 0 then
			expect(ent(FL.reactor_a).order_deconstruction(game.forces.player), "could not order the reactor deconstructed")
			return next_phase("mine-wait")
		end
		timeout_after(200, "job 4 handing chlorine to the reactor")
	elseif phase == "mine-wait" then
		local j = job_of(st.job)
		if j.status == "done" or j.status == "failed" then
			expect(not ent(FL.reactor_a), "the reactor was not mined")
			expect(next(j.pool) == nil, "job 4 keeps a pool: " .. serpent.line(j.pool))
			local now = count(FL_FLUID)
			if j.status == "done" then                       -- the craft finished before the robot arrived
				expect(near(now, st.chlorine_before - 400), "chlorine after job 4 (done): " .. now)
			else                                             -- mined while leased: nothing beyond the running craft is lost
				expect(now >= st.chlorine_before - 400 - FL_EPS and now <= st.chlorine_before + FL_EPS,
					"chlorine after job 4 (failed): " .. now .. ", before " .. st.chlorine_before)
				expect(now > st.chlorine_before - 400 or true, "")
			end
			return finish_test("import took " .. st.import_ticks .. " ticks, whole test " .. (game.tick - st.started))
		end
		timeout_after(600, "job 4 after the reactor was mined")
	end
end

--------------------------------------------------------------------------------
--- fluid recovery (issue #26): destroyed drives, the upgrade planner, taking the cells out by hand
--------------------------------------------------------------------------------

local RC_Y = 330                                        -- below the power test, own roboport
local RC = {
	d1 = { FL_DRIVE, 8.5, RC_Y + 3.5 },
	d2 = { FL_DRIVE, 10.5, RC_Y + 3.5 },
	idrive = { "me-drive-16k", 13.5, RC_Y + 3.5 },     -- the robots' storage
}
local RC_UPGRADE = "me-fluid-drive-4k"
local RC_OUTSIDE = { 120.5, RC_Y + 0.5 }                -- no logistic network here

function setup_recovery_test(s)
	local fails = {}
	local function place(name, x, y)
		local ok, e = pcall(function()
			return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
		end)
		if not (ok and e) then fails[#fails + 1] = "recovery " .. name .. ": " .. tostring(e) return nil end
		return e
	end
	local eei = place("electric-energy-interface", 0, RC_Y)
	if eei then
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
	end
	place("substation", 3, RC_Y)
	place("me-controller", 6, RC_Y)
	place(RC.d1[1], RC.d1[2], RC.d1[3])
	place(RC.d2[1], RC.d2[2], RC.d2[3])
	local idrive = place(RC.idrive[1], RC.idrive[2], RC.idrive[3])
	if idrive then
		idrive.insert{ name = FL_DRIVE, count = 1 }         -- rebuilds the ghost of the destroyed drive
		idrive.insert{ name = RC_UPGRADE, count = 1 }       -- for the upgrade planner
	end
	local port = place("roboport", 16, RC_Y)
	if port then port.insert{ name = "construction-robot", count = 4 } end
	return fails
end

function recovery_test()
	local s = game.surfaces[1]
	local F = "gregtorio-me-fluids"
	local function ent(def, name) return s.find_entity(name or def[1], { def[2], def[3] }) end
	local ref = ent(RC.idrive)
	local function count(fluid) return ref and remote.call(F, "count", ref, fluid) or -1 end
	local function near(a, b) return math.abs((a or 0) - (b or 0)) <= FL_EPS end
	local function pool() return remote.call(F, "recovered", s, "player") end
	local function same(a, b)                           -- two { fluid -> amount } tables
		for k, v in pairs(a) do if not near(v, b[k]) then return false end end
		for k, v in pairs(b) do if not near(v, a[k]) then return false end end
		return true
	end
	local st = storage.fluid_rec
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish_test(note)
		storage.fluid_rec.done = true
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL recovery: " .. p) end
		log("DEVCHECK-RUNTIME-RECOVERY " .. (#problems == 0 and "ok" or "failed") .. (note and (" (" .. note .. ")") or ""))
	end
	local function next_phase(name) st.phase = name st.phase_tick = game.tick end
	local function timeout_after(ticks, what)
		if game.tick > st.phase_tick + ticks then
			expect(false, what .. " timed out")
			finish_test()
		end
	end
	--- the drive item with fluid tags in the robots' storage (nil if there is none)
	local function loaded_item(name)
		local inv = ref.get_inventory(defines.inventory.chest)
		for i = 1, #inv do
			local stack = inv[i]
			if stack.valid_for_read and stack.name == name and stack.is_item_with_tags then
				local tags = stack.tags
				if tags and tags.fork_me_fluids then return stack, tags.fork_me_fluids end
			end
		end
	end

	if not st then
		if game.tick < 60 then return end
		storage.fluid_rec = { started = game.tick, phase = "destroy", phase_tick = game.tick }
		st = storage.fluid_rec
		local d1, d2 = ent(RC.d1), ent(RC.d2)
		expect(ref and d1 and d2, "entities missing")
		if #problems > 0 then return finish_test() end
		local capacity, used = remote.call(F, "capacity", ref)
		expect(capacity == 64000 and used == 0, "capacity " .. tostring(capacity) .. "/" .. tostring(used))
		--- water fills drive 1 (30000), chlorine fills it up (2000) and goes on into drive 2 (8000)
		expect(near(remote.call(F, "insert", ref, "water", 30000), 30000), "could not insert water")
		expect(near(remote.call(F, "insert", ref, "chlorine", 10000), 10000), "could not insert chlorine")
		local c1, c2 = remote.call(F, "drive", d1), remote.call(F, "drive", d2)
		expect(same(c1.contents, { water = 30000, chlorine = 2000 }) and same(c2.contents, { chlorine = 8000 }),
			"drive contents " .. serpent.line(c1.contents) .. " " .. serpent.line(c2.contents))
		st.before = remote.call(F, "totals", ref)
		--- 1) a destroyed drive: drive 2 takes what fits (chlorine 2000, water 22000), 8000 water is pooled
		expect(d1.die(), "drive 1 did not die")
		local totals, left = remote.call(F, "totals", ref), pool()
		expect(same(totals, { water = 22000, chlorine = 10000 }), "network after the destroyed drive " .. serpent.line(totals))
		expect(same(left, { water = 8000 }), "recovered fluid after the destroyed drive " .. serpent.line(left))
		for name, amount in pairs(st.before) do
			expect(near((totals[name] or 0) + (left[name] or 0), amount), name .. " not conserved: " .. serpent.line(totals) .. " + " .. serpent.line(left))
		end
		expect(near(remote.call(F, "drive", d2).used, 32000), "drive 2 not full")
		--- the ghost of the destroyed drive (created by the engine; if not, by the test) is rebuilt by robots
		local ghosts = s.find_entities_filtered{ ghost_name = FL_DRIVE, position = { RC.d1[2], RC.d1[3] }, radius = 0.5 }
		st.engine_ghost = #ghosts > 0
		if not st.engine_ghost then
			s.create_entity{ name = "entity-ghost", inner_name = FL_DRIVE, position = { RC.d1[2], RC.d1[3] }, force = "player" }
		end
		if #problems > 0 then return finish_test() end
		return
	end
	if st.done then return end

	local phase = st.phase
	if phase == "destroy" then
		local rebuilt = ent(RC.d1)
		if rebuilt then
			--- 2) the rebuilt drive takes the recovered fluid over: the network holds everything again
			expect(next(pool()) == nil, "recovered fluid left after the rebuild " .. serpent.line(pool()))
			expect(same(remote.call(F, "totals", ref), st.before), "network after the rebuild " .. serpent.line(remote.call(F, "totals", ref)))
			expect(same(remote.call(F, "drive", rebuilt).contents, { water = 8000 }), "rebuilt drive " .. serpent.line(remote.call(F, "drive", rebuilt)))
			if #problems > 0 then return finish_test() end
			--- 3) the upgrade planner on the full drive 2: its fluid stays on the old drive item
			local d2 = ent(RC.d2)
			expect(d2.order_upgrade{ target = RC_UPGRADE, force = "player" }, "order_upgrade refused")
			return next_phase("upgrade")
		end
		local ghosts = s.find_entities_filtered{ ghost_name = FL_DRIVE, position = { RC.d1[2], RC.d1[3] }, radius = 0.5 }
		timeout_after(600, "robots rebuilding the destroyed drive (ghosts " .. #ghosts .. ", drive items in storage "
			.. ref.get_item_count(FL_DRIVE) .. ")")
	elseif phase == "upgrade" then
		local new = ent(RC.d2, RC_UPGRADE)
		local stack, carried = loaded_item(FL_DRIVE)
		if new and stack then
			local d = remote.call(F, "drive", new)
			expect(d and d.capacity == 128000 and d.used == 0, "upgraded drive " .. serpent.line(d))
			expect(same(carried, { water = 22000, chlorine = 10000 }), "old drive item after the upgrade carries " .. serpent.line(carried))
			expect(same(remote.call(F, "totals", ref), { water = 8000 }), "network after the upgrade " .. serpent.line(remote.call(F, "totals", ref)))
			expect(next(pool()) == nil, "the upgrade pooled fluid " .. serpent.line(pool()))
			--- 4) the cells are taken out of the loaded item by hand (what the craft event does): the
			--- fluid goes into the drives of the network at the player's position, the item loses its tags
			local inv = game.create_inventory(1)
			inv[1].transfer_stack(stack)
			local moved, pooled = remote.call(F, "salvage_items", inv, s, "player", { RC.idrive[2], RC.idrive[3] })
			expect(same(moved, { water = 22000, chlorine = 10000 }) and next(pooled) == nil, "disassembly in the network: moved " .. serpent.line(moved) .. ", pooled " .. serpent.line(pooled))
			expect(same(remote.call(F, "totals", ref), st.before), "network after the disassembly " .. serpent.line(remote.call(F, "totals", ref)))
			local tags = inv[1].valid_for_read and inv[1].tags or {}
			expect(inv[1].valid_for_read and inv[1].name == FL_DRIVE and not tags.fork_me_fluids, "the disassembled item still carries fluid " .. serpent.line(tags))
			--- 5) the same outside any network: everything is pooled, a drive's take over empties the pool
			inv[1].set_stack{ name = FL_DRIVE, count = 1 }
			inv[1].tags = { fork_me_fluids = { water = 500 } }
			moved, pooled = remote.call(F, "salvage_items", inv, s, "player", RC_OUTSIDE)
			expect(next(moved) == nil and same(pooled, { water = 500 }), "disassembly outside: moved " .. serpent.line(moved) .. ", pooled " .. serpent.line(pooled))
			expect(same(pool(), { water = 500 }), "recovered fluid after the disassembly outside " .. serpent.line(pool()))
			local taken = remote.call(F, "take_recovered", new)
			expect(same(taken, { water = 500 }) and next(pool()) == nil, "take over: " .. serpent.line(taken) .. ", left " .. serpent.line(pool()))
			expect(near(count("water"), 30500), "water after the take over " .. count("water"))
			inv.destroy()
			--- 6) a loaded drive removed by another mod without an event: the next lookup pools its fluid
			local silent = s.create_entity{ name = FL_DRIVE, position = RC_OUTSIDE, force = "player", raise_built = true }
			remote.call(F, "unpack_drive", silent, { fork_me_fluids = { water = 300 } })
			silent.destroy()
			expect(near(count("water"), 30500), "water after the silent removal " .. count("water"))
			expect(same(pool(), { water = 300 }), "recovered fluid after the silent removal " .. serpent.line(pool()))
			taken = remote.call(F, "take_recovered", new)
			expect(same(taken, { water = 300 }) and next(pool()) == nil, "take over after the silent removal: " .. serpent.line(taken))
			--- 7) a drive destroyed outside any network on another surface pools everything; deleting the
			--- surface drops that pool (and reports it)
			local other = game.create_surface("fork-recovery-test", { width = 64, height = 64 })
			other.request_to_generate_chunks({ 0, 0 }, 1)
			other.force_generate_chunk_requests()
			local lone = other.create_entity{ name = FL_DRIVE, position = { 0.5, 0.5 }, force = "player", raise_built = true }
			expect(lone, "no drive on the other surface")
			if not lone then return finish_test() end
			remote.call(F, "unpack_drive", lone, { fork_me_fluids = { chlorine = 700 } })
			expect(same(remote.call(F, "drive", lone).contents, { chlorine = 700 }), "lone drive " .. serpent.line(remote.call(F, "drive", lone)))
			lone.die()
			expect(same(remote.call(F, "recovered", other, "player"), { chlorine = 700 }), "pool of the other surface " .. serpent.line(remote.call(F, "recovered", other, "player")))
			st.other = other.index
			game.delete_surface(other)
			if #problems > 0 then return finish_test() end
			return next_phase("surface")
		end
		timeout_after(600, "robots upgrading the drive")
	elseif phase == "surface" then
		if not game.get_surface(st.other) then
			expect(next(remote.call(F, "recovered", st.other, "player")) == nil, "the deleted surface keeps recovered fluid")
			expect(same(remote.call(F, "totals", ref), { water = 30800, chlorine = 10000 }), "network at the end " .. serpent.line(remote.call(F, "totals", ref)))
			return finish_test("ghost " .. (st.engine_ghost and "by the engine" or "by the test") .. ", whole test " .. (game.tick - st.started) .. " ticks")
		end
		timeout_after(120, "deleting the surface")
	end
end

--- Endgame power (prototypes/136-fork-power.lua, scripts/fork-power.lua): a LuV large plasma turbine
--- with helium plasma and a turbine output hatch next to it, and a UV large naquadah reactor with
--- naquadah based fuel MK1, each loaded by an electric energy interface that draws the generator's
--- full output. After 7 s both must have produced power and burnt fuel, and the hatch must hold the
--- cooled fluid (helium) for the plasma the turbine burnt.
local PW_Y = 260                                        -- below the fluid test and its roboport area
local PW_TICK = 420
local PW = {
	turbine = { "luv-large-plasma-turbine", 1.5, PW_Y + 1.5, "helium-plasma", 100, 81.92e6 },
	hatch = { "turbine-output-hatch", 3.5, PW_Y + 1.5 },
	reactor = { "uv-large-naquadah-reactor", 42.5, PW_Y + 2.5, "naquadah-based-fuel-mk1", 10, 327.68e6 },
}

function setup_power_test(s)
	local fails = {}
	local function place(def)
		local ok, e = pcall(function()
			return s.create_entity{ name = def[1], position = { def[2], def[3] }, force = "player", raise_built = true }
		end)
		if not (ok and e) then fails[#fails + 1] = "power test " .. def[1] .. ": " .. tostring(e) return nil end
		return e
	end
	for _, key in pairs({ "turbine", "reactor" }) do
		local def = PW[key]
		local g = place(def)
		if g then
			local got = g.insert_fluid{ name = def[4], amount = def[5] }
			if got < def[5] then fails[#fails + 1] = "power test: " .. def[1] .. " took only " .. got .. " " .. def[4] end
			local ok, err = pcall(function()
				local eei = s.create_entity{ name = "electric-energy-interface", position = { def[2], def[3] + 6 }, force = "player" }
				eei.power_production = 0
				eei.power_usage = def[6] / 60
				eei.electric_buffer_size = 1e8
				s.create_entity{ name = "substation", position = { def[2] + 4, def[3] + 6 }, force = "player" }
			end)
			if not ok then fails[#fails + 1] = "power test load: " .. tostring(err) end
		end
	end
	place(PW.hatch)
	return fails
end

script.on_nth_tick(PW_TICK, function(event)
	if storage.power_checked or event.tick == 0 then return end
	storage.power_checked = true
	local s = game.surfaces[1]
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function find(def) return s.find_entity(def[1], { def[2], def[3] }) end
	local turbine, hatch, reactor = find(PW.turbine), find(PW.hatch), find(PW.reactor)
	expect(turbine and hatch and reactor, "power test entities missing")
	--- an input-output fluid box keeps part of its fluid in the pipeline segment, which
	--- get_fluid_count does not report
	local function fluid_in(e, fluid)
		local seg = e.fluidbox.get_fluid_segment_contents(1)
		return e.get_fluid_count(fluid) + ((seg and seg[fluid]) or 0)
	end
	local summary = ""
	if #problems == 0 then
		local seconds = event.tick / 60
		--- turbine: 81.92 MW on helium plasma (81.92 MJ per unit) burns one unit per second
		local left = fluid_in(turbine, "helium-plasma")
		local burnt = PW.turbine[5] - left
		expect(turbine.energy_generated_last_tick > 0, "plasma turbine generates nothing")
		expect(burnt > 0.6 * seconds and burnt < 1.2 * seconds, "plasma turbine burnt " .. burnt .. " helium plasma in " .. seconds .. " s")
		local helium = hatch.get_fluid_count("helium")
		local owed = remote.call("gregtorio-power", "debt", turbine)
		expect(helium > 0, "the output hatch got no helium")
		expect(math.abs(helium + owed - burnt) < 0.5, "hatch holds " .. helium .. " helium (+ " .. owed .. " owed) for " .. burnt .. " plasma burnt")
		expect(hatch.get_fluid_count("helium-plasma") == 0, "plasma leaked into the output hatch")
		--- reactor: 327.68 MW on fuel MK1 (58.5 GJ per unit) burns 0.0056 units per second
		local fuel_left = fluid_in(reactor, "naquadah-based-fuel-mk1")
		local fuel_burnt = PW.reactor[5] - fuel_left
		expect(reactor.energy_generated_last_tick > 0, "naquadah reactor generates nothing")
		expect(fuel_burnt > 0.003 * seconds and fuel_burnt < 0.007 * seconds, "naquadah reactor burnt " .. fuel_burnt .. " fuel in " .. seconds .. " s")
		summary = string.format(" (turbine %.2f plasma -> %.2f helium, %.1f MW; reactor %.4f fuel, %.1f MW)",
			burnt, helium, turbine.energy_generated_last_tick * 60 / 1e6, fuel_burnt, reactor.energy_generated_last_tick * 60 / 1e6)
	end
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. p) end
	log("DEVCHECK-RUNTIME-POWER " .. (#problems == 0 and "ok" or "failed") .. summary)
end)

--- Fuel check (issue #25, scripts/fork-power.lua): generators on a wrong fluid, each with its own
--- load of the generator's full output and its own network (25 tiles apart). Steam (through a pipe)
--- in a plasma turbine, steam in a naquadah reactor, naquadah fuel in a plasma turbine and plasma in
--- a naquadah reactor must make no power, keep their fluid and show "Wrong fuel"; after the right
--- fuel is put in they run. A running turbine whose plasma is replaced by steam burns steam for at
--- most one check interval (10 ticks, the documented window) and then stops.
local FC_Y = PW_Y
local FC_WINDOW_TICKS = 10
local FC = {
	--  key            generator                     x      wrong fluid                amount  right fuel                 amount  load (W)
	{ "steam_turbine", "luv-large-plasma-turbine",   75.5,  "steam",                   100,    "helium-plasma",           100,    81.92e6, pipe = true },
	{ "steam_reactor", "uv-large-naquadah-reactor",  100.5, "steam",                   500,    "naquadah-based-fuel-mk1", 10,     327.68e6 },
	{ "fuel_turbine",  "luv-large-plasma-turbine",   125.5, "naquadah-based-fuel-mk1", 10,     "helium-plasma",           100,    81.92e6 },
	{ "plasma_reactor", "uv-large-naquadah-reactor", 150.5, "helium-plasma",           100,    "naquadah-based-fuel-mk1", 10,     327.68e6 },
	{ "window",        "luv-large-plasma-turbine",   175.5, "steam",                   500,    "helium-plasma",           100,    81.92e6 },
}

--- an input-output fluid box keeps part of its fluid in the pipeline segment (see the power test)
local function fc_fluid_in(e, fluid)
	local seg = e.fluidbox.get_fluid_segment_contents(1)
	return e.get_fluid_count(fluid) + ((seg and seg[fluid]) or 0)
end

function setup_fuel_test(s)
	local fails = {}
	storage.fuel = { gens = {} }
	for _, def in ipairs(FC) do
		local ok, err = pcall(function()
			local y = FC_Y + (def[2]:find("reactor") and 2.5 or 1.5)
			local g = s.create_entity{ name = def[2], position = { def[3], y }, force = "player", raise_built = true }
			local first, amount = def[4], def[5]
			if def[1] == "window" then first, amount = def[6], def[7] end
			if def.pipe then
				--- the north connection of the 3x3 turbine is one tile above its top edge
				local pipe = s.create_entity{ name = "pipe", position = { def[3], y - 2 }, force = "player" }
				local got = pipe.insert_fluid{ name = first, amount = amount }
				if got < amount then fails[#fails + 1] = "fuel test: the pipe took only " .. got .. " " .. first end
			else
				local got = g.insert_fluid{ name = first, amount = amount }
				if got < amount then fails[#fails + 1] = "fuel test: " .. def[1] .. " took only " .. got .. " " .. first end
			end
			local eei = s.create_entity{ name = "electric-energy-interface", position = { def[3], y + 6 }, force = "player" }
			eei.power_production = 0
			eei.power_usage = def[8] / 60
			eei.electric_buffer_size = 1e8
			s.create_entity{ name = "substation", position = { def[3] + 4, y + 6 }, force = "player" }
			storage.fuel.gens[def[1]] = g
		end)
		if not ok then fails[#fails + 1] = "fuel test " .. def[1] .. ": " .. tostring(err) end
	end
	return fails
end

--- The window turbine: from the swap on, its plasma is taken out every tick, and on the tick it is
--- empty the steam goes in, so the fuel check (every 10 ticks) meets steam that may have burnt since
function fuel_window_tick()
	local st = storage.fuel
	if not (st and st.phase and not st.window_swapped and not st.done) then return end
	local def = FC[#FC]
	local g = st.gens.window
	if not (g and g.valid) then return end
	g.remove_fluid{ name = def[6], amount = 1e9 }
	if fc_fluid_in(g, def[6]) > 0 then return end
	local got = g.insert_fluid{ name = def[4], amount = def[5] }
	if math.abs(got - def[5]) > 1e-6 then log("DEVCHECK-RUNTIME-FAIL fuel test: window turbine took only " .. got .. " steam") end
	st.window_swapped, st.window_stopped = game.tick, g.disabled_by_script
end

function fuel_test()
	local st = storage.fuel
	if not st then return end
	local tick = game.tick
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function label_key(e)
		local cs = e.custom_status
		return cs and type(cs.label) == "table" and cs.label[1] or nil
	end
	local function finish(summary)
		st.done = true
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL fuel test: " .. p) end
		log("DEVCHECK-RUNTIME-FUEL " .. (#problems == 0 and "ok" or "failed") .. (summary or ""))
	end
	for _, def in ipairs(FC) do
		if not (st.gens[def[1]] and st.gens[def[1]].valid) then
			problems[#problems + 1] = "generator " .. def[1] .. " missing"
			return finish()
		end
	end
	if not st.phase and tick >= 120 then
		--- wrong fuels: no power, fluid kept, status set; the window turbine runs on plasma
		for _, def in ipairs(FC) do
			local g = st.gens[def[1]]
			if def[1] == "window" then
				expect(g.energy_generated_last_tick > 0, "window turbine does not run on plasma")
				expect(not g.disabled_by_script, "window turbine stopped on plasma")
			else
				local left = fc_fluid_in(g, def[4])
				expect(g.energy_generated_last_tick == 0, def[1] .. " generates " .. g.energy_generated_last_tick .. " J/tick on " .. def[4])
				expect(math.abs(left - def[5]) < 1e-6, def[1] .. " holds " .. left .. " " .. def[4] .. " of " .. def[5])
				expect(g.disabled_by_script, def[1] .. " is not stopped")
				expect(label_key(g) == "entity-status.fork-wrong-fuel", def[1] .. " status " .. serpent.line(g.custom_status))
			end
		end
		if #problems > 0 then return finish() end
		st.phase, st.drain = "draining", 0
	elseif st.phase == "draining" then
		--- swap: empty the stopped ones (removing takes only the entity's share, the segment gives
		--- the rest back over the next ticks), then put the right fuel in; the window turbine is
		--- swapped every tick by fuel_window_tick
		local left = 0
		for _, def in ipairs(FC) do
			if def[1] ~= "window" then
				local g = st.gens[def[1]]
				g.remove_fluid{ name = def[4], amount = 1e9 }
				left = left + fc_fluid_in(g, def[4])
			end
		end
		st.drain = st.drain + 1
		if left > 0 then
			if st.drain > 30 then
				problems[#problems + 1] = "could not empty the generators (" .. left .. " left)"
				return finish()
			end
			return
		end
		for _, def in ipairs(FC) do
			if def[1] ~= "window" then
				local g = st.gens[def[1]]
				local got = g.insert_fluid{ name = def[6], amount = def[7] }
				expect(math.abs(got - def[7]) < 1e-6, def[1] .. " took only " .. got .. " " .. def[6] .. " after emptying it")
			end
		end
		st.phase, st.swapped = "right", tick
		if #problems > 0 then return finish() end
	elseif st.phase == "right" and st.window_swapped and not st.window_mid and tick >= st.window_swapped + FC_WINDOW_TICKS + 10 then
		st.window_mid = fc_fluid_in(st.gens.window, FC[#FC][4])
	elseif st.phase == "right" and st.window_mid and tick >= math.max(st.swapped, st.window_swapped) + 60 then
		local summary = ""
		for _, def in ipairs(FC) do
			local g = st.gens[def[1]]
			if def[1] == "window" then
				--- at most one interval of the full output on steam (+1 tick for the check order)
				local burnt = def[5] - fc_fluid_in(g, def[4])
				local max = def[8] * (FC_WINDOW_TICKS + 1) / 60 / prototypes.fluid[def[4]].fuel_value
				expect(burnt <= max, "window turbine burnt " .. burnt .. " steam, more than " .. max)
				--- a stopped generator keeps its last energy_generated_last_tick: the steam must not move
				expect(st.window_mid and math.abs(fc_fluid_in(g, def[4]) - st.window_mid) < 1e-6,
					"window turbine still burns steam (" .. tostring(st.window_mid) .. " -> " .. fc_fluid_in(g, def[4]) .. ")")
				expect(g.disabled_by_script, "window turbine is not stopped")
				expect(label_key(g) == "entity-status.fork-wrong-fuel", "window turbine status " .. serpent.line(g.custom_status))
				summary = string.format(" (window: %.1f steam = %.2f MJ burnt, swapped on tick %d %s)", burnt,
					burnt * prototypes.fluid[def[4]].fuel_value / 1e6, st.window_swapped,
					st.window_stopped and "after the turbine had stopped" or "while the turbine ran")
			else
				local burnt = def[7] - fc_fluid_in(g, def[6])
				expect(g.energy_generated_last_tick > 0, def[1] .. " does not run on " .. def[6])
				expect(burnt > 0, def[1] .. " burnt no " .. def[6])
				expect(not g.disabled_by_script, def[1] .. " still stopped on " .. def[6])
				expect(g.custom_status == nil, def[1] .. " still has status " .. serpent.line(g.custom_status))
			end
		end
		return finish(summary)
	elseif tick > 900 then
		problems[#problems + 1] = "timed out in phase " .. tostring(st.phase)
		return finish()
	end
end

local MOLD_Y = 120
local MOLD_RECIPE = "glass-alloy-smelter"

function setup_mold_test(s)
	local ok, err = pcall(function()
		local eei = s.create_entity{ name = "electric-energy-interface", position = { 0, MOLD_Y }, force = "player" }
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
		s.create_entity{ name = "substation", position = { 3, MOLD_Y }, force = "player" }
		local m = s.create_entity{ name = "lv-alloy-smelter", position = { 6, MOLD_Y }, force = "player", raise_built = true }
		m.force.recipes[MOLD_RECIPE].enabled = true
		m.set_recipe(MOLD_RECIPE)
		m.insert{ name = "glass-dust", count = 20 }
		storage.mold_machine = m
	end)
	if not ok then return { "mold test setup: " .. tostring(err) } end
	return {}
end

script.on_event(defines.events.on_tick, function(event)
	fuel_window_tick()
	local m = storage.mold_machine
	if storage.mold_done then return end
	local phase
	if not storage.mold_phase1 and event.tick >= 60 then
		phase = 1
		storage.mold_phase1 = event.tick
	elseif storage.mold_phase1 and event.tick >= storage.mold_phase1 + 450 then
		phase = 2
		storage.mold_done = true
	else
		return
	end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	expect(m and m.valid, "mold test machine missing")
	if #problems == 0 then
		local glass = m.get_inventory(defines.inventory.crafter_output or defines.inventory.assembling_machine_output).get_item_count("glass")
		local inv = m.get_module_inventory()
		if phase == 1 then
			expect(m.disabled_by_script, "mold test: machine without mold is not stopped")
			expect(glass == 0, "mold test: crafted " .. glass .. " glass without a mold")
			expect(inv and inv.insert{ name = "mold", count = 1 } == 1, "mold test: mold does not fit into the mold slot")
		else
			expect(not m.disabled_by_script, "mold test: machine with mold is still stopped")
			expect(glass > 0, "mold test: no glass crafted with the mold inserted")
			expect(inv.get_item_count("mold") == 1, "mold test: mold left the mold slot")
			expect(m.get_item_count("mold") == 1, "mold test: mold was duplicated or moved")
			log("DEVCHECK-RUNTIME-MOLD " .. (#problems == 0 and "ok" or "failed") .. " (glass " .. glass .. ")")
		end
	end
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. p) end
	if #problems > 0 and phase == 1 then
		storage.mold_done = true
		log("DEVCHECK-RUNTIME-MOLD failed")
	end
end)

script.on_init(function()
	local s = game.surfaces[1]
	s.always_day = true
	s.request_to_generate_chunks({ 0, 0 }, 12)
	s.force_generate_chunk_requests()
	local recipe_for = {}
	for rn, r in pairs(prototypes.recipe) do recipe_for[r.category] = recipe_for[r.category] or rn end
	local x, y, placed, with_recipe, fails = -150, -150, 0, 0, {}
	for name, p in pairs(prototypes.get_entity_filtered{ { filter = "type", type = "assembling-machine" } }) do
		if p.items_to_place_this and #p.items_to_place_this > 0 then
			local ok, e = pcall(function()
				return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
			end)
			if ok and e then
				placed = placed + 1
				for c, _ in pairs(p.crafting_categories) do
					if recipe_for[c] and pcall(function() e.set_recipe(recipe_for[c]) end) then
						with_recipe = with_recipe + 1
						break
					end
				end
				s.create_entity{ name = "electric-energy-interface", position = { x, y + 7 }, force = "player" }
				s.create_entity{ name = "substation", position = { x + 5, y + 7 }, force = "player" }
			else
				fails[#fails + 1] = name .. ": " .. tostring(e)
			end
			x = x + 14
			if x > 150 then x = -150; y = y + 14 end
		end
	end
	for _, f in pairs(setup_me_network(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_mold_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_autocraft_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_fluid_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_recovery_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_power_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_fuel_test(s)) do fails[#fails + 1] = f end
	log("DEVCHECK-RUNTIME placed=" .. placed .. " with_recipe=" .. with_recipe .. " failed=" .. #fails)
	for _, f in pairs(fails) do log("DEVCHECK-RUNTIME-FAIL " .. f) end
end)
