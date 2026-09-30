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
--- Furnace patterns (issue #27): in its own network, a fresh iron furnace next to a pattern provider
--- with a chosen recipe is a pattern at once and smelts a job into storage; a furnace without choice
--- and without a smelted recipe is counted as ignored ("no-recipe"). Settings paste, blueprint tags and
--- a revived ghost carry the choice.
--- Fluids (prototypes/122-fork-ae2-fluids.lua, scripts/fork-me-fluids.lua): a network with a fluid drive,
--- an import interface with a tank of chlorine connected to it, an export interface, a roboport with
--- construction robots, and pattern machines with fluid recipes (chemical reactors, an extractor). Checks the
--- import and export totals, a drive picked up (contents on the item) and placed again by script and by
--- robots, a reported fluid shortfall, and jobs with a fluid ingredient, a fluid product and both.
--- Fluid recovery (issue #26): a destroyed drive (other drives take what fits, the rest is pooled and a
--- robot-rebuilt drive takes it over), the cells taken out of a loaded item by hand (inside and outside a
--- network) and a deleted surface with a pool. Issue #43: the upgrade planner (robots) moves a loaded
--- drive's fluid into the new drive and the old item carries none; existing drives pull recovered fluid in
--- once an export interface has made room; a robot downgrade into a too small drive puts the rest into
--- the network, then into the recovered fluid; a hand fast replace (the engine's event order, called
--- through the remote interface: no player in a headless run) moves the fluid into the new drive.
--- Molds (prototypes/150-fork-molds.lua): an LV alloy smelter with a mold recipe must stop
--- without a mold, run with a mold in its mold slot and keep the mold there.
--- Endgame power (prototypes/136-fork-power.lua): a plasma turbine and a naquadah reactor under load
--- must burn their fuel and make power; the turbine's output hatch gets the cooled fluid.
--- Fuel check (issue #25): steam and the other generator's fuel stop a generator; the right fuel runs it.
--- Turbine tiers (issue #34): the UHV to UXV plasma turbines under an overload give exactly four amps of
--- their tier and return the cooled fluid of the plasma they burnt.
--- Recipes of issue #35: grades 7 and 8, FPIC/APIC wafers and chips, complex SMDs and the recipes that
--- use them are crafted once each (setup_recipe_test).
local ME_Y = 100
local ME_ITEM = "iron-plate"

--- State of a robot job at `pos` for a timeout message: ghosts and blocking entities there, the tile,
--- the chunk, and every construction network covering it (robots with position, energy and order).
function robot_report(s, pos, name)
	local force = game.forces.player
	local out = {}
	local function add(x) out[#out + 1] = x end
	local area = { { pos[1] - 1.5, pos[2] - 1.5 }, { pos[1] + 1.5, pos[2] + 1.5 } }
	add("ghosts " .. #s.find_entities_filtered{ ghost_name = name, position = pos, radius = 0.5 })
	local blocking = {}
	for _, e in pairs(s.find_entities_filtered{ area = area }) do
		if e.name ~= name and e.type ~= "entity-ghost" then blocking[#blocking + 1] = e.name .. "@" .. e.position.x .. "," .. e.position.y end
	end
	add("near: " .. table.concat(blocking, " "))
	add("tile " .. s.get_tile(pos[1], pos[2]).name)
	local chunk = { math.floor(pos[1] / 32), math.floor(pos[2] / 32) }
	add("chunk generated " .. tostring(s.is_chunk_generated(chunk)) .. " charted " .. tostring(force.is_chunk_charted(s, chunk)))
	for _, n in pairs(s.find_logistic_networks_by_construction_area(pos, force)) do
		local robots = {}
		for _, r in pairs(n.construction_robots) do
			robots[#robots + 1] = string.format("(%.1f,%.1f e=%.0f orders=%d)", r.position.x, r.position.y, r.energy, #r.robot_order_queue)
		end
		local ports = {}
		for _, c in pairs(n.cells) do ports[#ports + 1] = c.owner.name .. " e=" .. string.format("%.0f", c.owner.energy) end
		add("network " .. n.network_id .. ": robots " .. n.available_construction_robots .. "/" .. n.all_construction_robots
			.. " " .. table.concat(robots, " ") .. " cells " .. table.concat(ports, ", "))
	end
	return table.concat(out, "; ")
end

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
--- Winning stops the scripts of the benchmark run (no player to continue), so this runs last: as soon
--- as every other test has reported, at the latest at tick VICTORY_DEADLINE (a test still running
--- then is reported as unfinished). Checked from the 10-tick handler below.
local VICTORY_DEADLINE = 1450
local function tests_running()
	local running = {}
	local function check(done, name) if not done then running[#running + 1] = name end end
	check(storage.me_checked, "ME network")
	check(storage.mold_done, "mold")
	check(storage.autocraft and storage.autocraft.done, "autocrafting")
	check(storage.furnace and storage.furnace.done, "furnace patterns")
	check(storage.fluids and storage.fluids.done, "fluids")
	check(storage.fluid_rec and storage.fluid_rec.done, "fluid recovery")
	check(storage.power_checked, "power")
	check(storage.fuel and storage.fuel.done, "fuel check")
	check(storage.cooled and storage.cooled.done, "cooled fluid")
	check(storage.tiers and storage.tiers.done, "turbine tiers")
	check(storage.recipe_test and storage.recipe_test.done, "recipes of issue #35")
	return running
end

function victory_test()
	if storage.victory_checked then return end
	local running = tests_running()
	if #running > 0 and game.tick < VICTORY_DEADLINE then return end
	storage.victory_checked = true
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	expect(#running == 0, "tests still running at tick " .. game.tick .. ": " .. table.concat(running, ", "))
	local ok, err = pcall(function() game.forces.player.technologies["victory"].researched = true end)
	expect(ok, "victory test: " .. tostring(err))
	--- (can_continue cannot be read before a player chooses to go on; the script passes it, see fork-victory.lua)
	expect(game.finished, "victory test: researching `victory` did not finish the game")
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. p) end
	log("DEVCHECK-RUNTIME-VICTORY " .. (#problems == 0 and "ok" or "failed") .. " (tick " .. game.tick .. ")")
end

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

--------------------------------------------------------------------------------
--- furnace patterns (issue #27): the recipe choice of a pattern provider
--------------------------------------------------------------------------------

local FU_X, FU_Y = -116, -220                          -- own network, above the machine grid
local FU_RECIPE, FU_ITEM, FU_INPUT, FU_AMOUNT = "iron-dust-smelter", "iron-ingot", "iron-dust", 2
local FU_PROVIDER_A = { FU_X + 16.5, FU_Y + 10.5 }     -- touches furnace A (west)
local FU_PROVIDER_B = { FU_X + 7.5, FU_Y + 10.5 }      -- touches furnace B (west)
local FU_GHOST = { FU_X + 20.5, FU_Y + 4.5 }

function setup_furnace_test(s)
	local fails = {}
	local function place(name, x, y)
		local ok, e = pcall(function()
			return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
		end)
		if not (ok and e) then fails[#fails + 1] = "furnace test " .. name .. ": " .. tostring(e) return nil end
		return e
	end
	local eei = place("electric-energy-interface", FU_X + 12.5, FU_Y + 6.5)
	if eei then
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
	end
	place("substation", FU_X + 13, FU_Y + 2)
	place("me-controller", FU_X + 6, FU_Y)
	place("me-terminal", FU_X + 8.5, FU_Y + 4.5)
	place("me-crafting-cpu", FU_X + 10, FU_Y)
	local drive = place("me-drive-16k", FU_X + 8.5, FU_Y + 6.5)
	for _, pos in pairs({ { FU_X + 15, FU_Y + 11 }, { FU_X + 6, FU_Y + 11 } }) do
		local f = place("iron-furnace", pos[1], pos[2])
		if f then f.get_inventory(defines.inventory.fuel).insert{ name = "coal", count = 20 } end
	end
	place("me-pattern-provider", FU_PROVIDER_A[1], FU_PROVIDER_A[2])
	place("me-pattern-provider", FU_PROVIDER_B[1], FU_PROVIDER_B[2])
	if drive then drive.insert{ name = FU_INPUT, count = 10 } end
	return fails
end

function furnace_test()
	local s = game.surfaces[1]
	local A = "gregtorio-me-autocraft"
	local terminal = s.find_entity("me-terminal", { FU_X + 8.5, FU_Y + 4.5 })
	local net = terminal and s.find_logistic_network_by_position(terminal.position, terminal.force)
	local pa = s.find_entity("me-pattern-provider", FU_PROVIDER_A)
	local pb = s.find_entity("me-pattern-provider", FU_PROVIDER_B)
	local furnace_a = s.find_entity("iron-furnace", { FU_X + 15, FU_Y + 11 })
	local function count(item) return net and net.get_item_count{ name = item, quality = "normal" } or -1 end
	local st = storage.furnace
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish_test(note)
		storage.furnace.done = true
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL furnace patterns: " .. p) end
		log("DEVCHECK-RUNTIME-FURNACE " .. (#problems == 0 and "ok" or "failed") .. (note and (" (" .. note .. ")") or ""))
	end
	local function craftable()
		local set = {}
		for _, k in pairs(remote.call(A, "craftable", terminal)) do set[k] = true end
		return set
	end

	if not st then
		if game.tick < 60 then return end
		storage.furnace = { started = game.tick }
		st = storage.furnace
		if not (terminal and net and pa and pb and furnace_a) then expect(false, "entities missing") return finish_test() end
		--- fresh furnaces: no recipe, no previous recipe; both are counted as ignored
		expect(furnace_a.previous_recipe == nil and furnace_a.get_recipe() == nil, "furnace A is not fresh")
		local ignored = remote.call(A, "ignored", terminal)
		expect(ignored["no-recipe"] == 2 and ignored.total == 2, "fresh furnaces ignored: " .. serpent.line(ignored))
		expect(not craftable()[FU_ITEM], "a fresh furnace became a pattern")
		--- the GUI's options: researched recipes of the furnace's categories only
		local options = remote.call(A, "recipe_options", pa)
		local listed = {}
		for _, n in pairs(options) do listed[n] = true end
		expect(not listed[FU_RECIPE], "the options list a recipe that is not researched")
		terminal.force.recipes[FU_RECIPE].enabled = true
		options = remote.call(A, "recipe_options", pa)
		listed = {}
		for _, n in pairs(options) do
			listed[n] = true
			local r = terminal.force.recipes[n]
			expect(r.enabled and prototypes.recipe[n].category == "smelting", "option " .. n .. " is not a researched smelting recipe")
		end
		expect(listed[FU_RECIPE], "the options miss " .. FU_RECIPE .. ": " .. serpent.line(options))
		--- choose the recipe (the GUI's code path): a pattern right away
		expect(remote.call(A, "set_recipe", pa, FU_RECIPE), "set_recipe failed")
		expect(remote.call(A, "get_recipe", pa) == FU_RECIPE, "choice not stored")
		expect(craftable()[FU_ITEM], "the furnace with a chosen recipe is no pattern")
		ignored = remote.call(A, "ignored", terminal)
		expect(ignored["no-recipe"] == 1 and ignored.total == 1, "ignored after the choice: " .. serpent.line(ignored))
		local per_run = 0
		for _, i in pairs(prototypes.recipe[FU_RECIPE].ingredients) do if i.name == FU_INPUT then per_run = i.amount end end
		local yield = 0
		for _, p in pairs(prototypes.recipe[FU_RECIPE].products) do if p.name == FU_ITEM then yield = p.amount end end
		st.runs = math.ceil(FU_AMOUNT / yield)
		st.input = st.runs * per_run
		st.output = st.runs * yield
		local plan = remote.call(A, "plan", terminal, FU_ITEM, FU_AMOUNT)
		expect(plan and plan.ok and plan.steps == 1 and plan.runs == st.runs, "furnace plan: " .. serpent.line(plan))
		st.job = remote.call(A, "start", terminal, FU_ITEM, FU_AMOUNT)
		expect(st.job, "furnace job did not start")
		if #problems > 0 then return finish_test() end
		return
	end
	if st.done then return end

	local j = remote.call(A, "job", st.job)
	if j and (j.status == "done" or j.status == "failed" or j.status == "cancelled") then
		expect(j.status == "done", "furnace job ended as " .. j.status .. " " .. serpent.line(j))
		expect(count(FU_ITEM) == st.output, "ingots in storage: " .. count(FU_ITEM) .. ", expected " .. st.output)
		expect(count(FU_INPUT) == 10 - st.input, "dust left: " .. count(FU_INPUT) .. ", expected " .. (10 - st.input))
		expect(next(j.pool) == nil, "furnace job keeps items: " .. serpent.line(j.pool))
		expect(furnace_a.get_inventory(defines.inventory.furnace_source).is_empty()
			and furnace_a.get_inventory(defines.inventory.furnace_result).is_empty(), "furnace A is not empty after the job")
		--- settings paste: provider B takes the choice, furnace B becomes a pattern too
		remote.call(A, "paste", pa, pb)
		expect(remote.call(A, "get_recipe", pb) == FU_RECIPE, "paste did not copy the choice")
		local ignored = remote.call(A, "ignored", terminal)
		expect((ignored.total or 0) == 0, "ignored after the paste: " .. serpent.line(ignored))
		--- without a choice the recipe furnace A smelted last (previous_recipe) keeps it a pattern
		remote.call(A, "set_recipe", pa, nil)
		ignored = remote.call(A, "ignored", terminal)
		expect((ignored.total or 0) == 0, "furnace A without choice lost its last smelted recipe: " .. serpent.line(ignored))
		remote.call(A, "set_recipe", pa, FU_RECIPE)
		--- blueprint: the provider's choice becomes an entity tag
		local inv = game.create_inventory(1)
		inv.insert{ name = "blueprint" }
		local bp = inv[1]
		local mapping = bp.create_blueprint{ surface = s, force = "player",
			area = { { FU_PROVIDER_A[1] - 0.4, FU_PROVIDER_A[2] - 0.4 }, { FU_PROVIDER_A[1] + 0.4, FU_PROVIDER_A[2] + 0.4 } } }
		remote.call(A, "tag_blueprint", bp, mapping)
		local tagged = false
		for index, e in pairs(mapping or {}) do
			if e.name == "me-pattern-provider" then tagged = bp.get_blueprint_entity_tag(index, "fork_ae2_recipe") == FU_RECIPE end
		end
		expect(tagged, "the blueprint does not carry the choice")
		inv.destroy()
		--- a ghost with the tag is revived: the new provider has the choice
		local ghost = s.create_entity{ name = "entity-ghost", inner_name = "me-pattern-provider", position = FU_GHOST,
			force = "player", tags = { fork_ae2_recipe = FU_RECIPE } }
		local _, revived = ghost.revive{ raise_revive = true }
		expect(revived and remote.call(A, "get_recipe", revived) == FU_RECIPE, "a revived ghost lost the choice")
		return finish_test("job took " .. (game.tick - st.started) .. " ticks")
	end
	if game.tick > st.started + 1200 then
		local status
		for name, v in pairs(defines.entity_status) do if furnace_a.status == v then status = name end end
		expect(false, "furnace job timed out: " .. serpent.line(j) .. ", furnace " .. tostring(status) .. " progress "
			.. furnace_a.crafting_progress .. " recipe energy " .. prototypes.recipe[FU_RECIPE].energy)
		finish_test()
	end
end

script.on_nth_tick(10, function()
	if not (storage.autocraft and storage.autocraft.done) then autocraft_test() end
	if not (storage.furnace and storage.furnace.done) then furnace_test() end
	if not (storage.fluids and storage.fluids.done) then fluid_test() end
	if not (storage.fluid_rec and storage.fluid_rec.done) then recovery_test() end
	if not (storage.fuel and storage.fuel.done) then fuel_test() end
	if not (storage.cooled and storage.cooled.done) then cooled_test() end
	if not (storage.tiers and storage.tiers.done) then tier_test() end
	if not (storage.recipe_test and storage.recipe_test.done) then recipe_test() end
	victory_test()
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
			expect(false, what .. " timed out at tick " .. game.tick .. " (network " .. FL_FLUID .. " " .. count(FL_FLUID) .. ")")
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
		timeout_after(600, "robots deconstructing the drive (" .. robot_report(s, FL_DRIVE_POS, FL_DRIVE) .. ")")
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
		timeout_after(600, "robot storing the drive item (" .. robot_report(s, FL_DRIVE_POS, FL_DRIVE) .. ")")
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
		timeout_after(600, "robots building the drive from the ghost (" .. robot_report(s, FL_DRIVE_POS, FL_DRIVE) .. ")")
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
local RC_IFACE = { 8.5, RC_Y + 6.5 }                    -- export interface of the pull-in test

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
			expect(false, what .. " timed out at tick " .. game.tick)
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
			--- 3) the upgrade planner on the full drive 2 (robots): its fluid goes into the new drive
			local d2 = ent(RC.d2)
			st.events = {}
			expect(d2.order_upgrade{ target = RC_UPGRADE, force = "player" }, "order_upgrade refused")
			return next_phase("upgrade")
		end
		local ghosts = s.find_entities_filtered{ ghost_name = FL_DRIVE, position = { RC.d1[2], RC.d1[3] }, radius = 0.5 }
		timeout_after(600, "robots rebuilding the destroyed drive (ghosts " .. #ghosts .. ", drive items in storage "
			.. ref.get_item_count(FL_DRIVE) .. "; " .. robot_report(s, { RC.d1[2], RC.d1[3] }, FL_DRIVE) .. ")")
	elseif phase == "upgrade" then
		local new = ent(RC.d2, RC_UPGRADE)
		--- done when the new drive stands and the robot has brought the old drive item back
		if new and ref.get_item_count(FL_DRIVE) >= 1 then
			local d = remote.call(F, "drive", new)
			expect(d and d.capacity == 128000 and same(d.contents, { water = 22000, chlorine = 10000 }), "upgraded drive " .. serpent.line(d))
			expect(loaded_item(FL_DRIVE) == nil, "the old drive item carries fluid after the upgrade " .. serpent.line(select(2, loaded_item(FL_DRIVE))))
			expect(same(remote.call(F, "totals", ref), st.before), "network after the upgrade " .. serpent.line(remote.call(F, "totals", ref)))
			expect(next(pool()) == nil, "the upgrade pooled fluid " .. serpent.line(pool()))
			expect(next(remote.call(F, "replacing")) == nil, "fluid still held for a replacement " .. serpent.line(remote.call(F, "replacing")))
			log("DEVCHECK-RUNTIME-UPGRADE-EVENTS upgrade " .. table.concat(st.events, " "))
			local expected = { water = 30000, chlorine = 10000 }
			--- 4) the cells are taken out of a loaded item by hand (what the craft event does): the fluid
			--- goes into the drives of the network at the player's position, the item loses its tags
			local inv = game.create_inventory(1)
			inv[1].set_stack{ name = FL_DRIVE, count = 1 }
			inv[1].tags = { fork_me_fluids = { water = 1000, chlorine = 500 } }
			local moved, pooled = remote.call(F, "salvage_items", inv, s, "player", { RC.idrive[2], RC.idrive[3] })
			expect(same(moved, { water = 1000, chlorine = 500 }) and next(pooled) == nil, "disassembly in the network: moved " .. serpent.line(moved) .. ", pooled " .. serpent.line(pooled))
			expected = { water = 31000, chlorine = 10500 }
			expect(same(remote.call(F, "totals", ref), expected), "network after the disassembly " .. serpent.line(remote.call(F, "totals", ref)))
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
			expect(near(count("water"), 31500), "water after the take over " .. count("water"))
			inv.destroy()
			--- 6) a loaded drive removed by another mod without an event: the next lookup pools its fluid
			local silent = s.create_entity{ name = FL_DRIVE, position = RC_OUTSIDE, force = "player", raise_built = true }
			remote.call(F, "unpack_drive", silent, { fork_me_fluids = { water = 300 } })
			silent.destroy()
			expect(near(count("water"), 31500), "water after the silent removal " .. count("water"))
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
		timeout_after(600, "robots upgrading the drive (" .. robot_report(s, { RC.d2[2], RC.d2[3] }, RC_UPGRADE) .. ")")
	elseif phase == "surface" then
		if not game.get_surface(st.other) then
			expect(next(remote.call(F, "recovered", st.other, "player")) == nil, "the deleted surface keeps recovered fluid")
			expect(same(remote.call(F, "totals", ref), { water = 31800, chlorine = 10500 }), "network after the deleted surface " .. serpent.line(remote.call(F, "totals", ref)))
			--- 8) existing drives pull recovered fluid in: the network is filled up, 3000 chlorine of a
			--- disassembly find no room and are pooled; an export interface then takes 5000 water out
			local capacity, used = remote.call(F, "capacity", ref)
			expect(near(remote.call(F, "insert", ref, "water", capacity - used), capacity - used), "could not fill the network")
			local inv = game.create_inventory(1)
			inv[1].set_stack{ name = FL_DRIVE, count = 1 }
			inv[1].tags = { fork_me_fluids = { chlorine = 3000 } }
			local moved, pooled = remote.call(F, "salvage_items", inv, s, "player", { RC.idrive[2], RC.idrive[3] })
			inv.destroy()
			expect(next(moved) == nil and same(pooled, { chlorine = 3000 }), "disassembly into a full network: moved " .. serpent.line(moved) .. ", pooled " .. serpent.line(pooled))
			local iface = s.create_entity{ name = "me-fluid-interface", position = RC_IFACE, force = "player", raise_built = true }
			expect(iface and remote.call(F, "set_interface", iface, "export", "water", 5000), "no export interface")
			if #problems > 0 then return finish_test() end
			st.all = { water = 31800 + capacity - used, chlorine = 13500 }   -- drives + interface + pool from here on
			return next_phase("pullin")
		end
		timeout_after(120, "deleting the surface")
	elseif phase == "pullin" then
		local iface = s.find_entity("me-fluid-interface", RC_IFACE)
		local function all()
			local out = remote.call(F, "totals", ref)
			for name, amount in pairs(pool()) do out[name] = (out[name] or 0) + amount end
			local held = iface and iface.get_fluid_count("water") or 0
			if held > 0 then out.water = (out.water or 0) + held end
			return out
		end
		expect(same(all(), st.all), "fluid not conserved while exporting and pulling in: " .. serpent.line(all()) .. ", expected " .. serpent.line(st.all))
		if #problems > 0 then return finish_test() end
		if next(pool()) == nil and iface and near(iface.get_fluid_count("water"), 5000) then
			local capacity, used = remote.call(F, "capacity", ref)
			expect(near(capacity - used, 2000), "room after the pull-in " .. (capacity - used))
			st.pullin_ticks = game.tick - st.phase_tick
			--- 9) the upgrade planner downgrades the full 4k drive (128000) to a 1k (32000): the new drive
			--- takes 32000, the network's 2000 of room the next, the rest is recovered fluid
			local big = ent(RC.d2, RC_UPGRADE)
			st.big_used = remote.call(F, "drive", big).used
			st.room = capacity - used
			st.events = {}
			expect(big.order_upgrade{ target = FL_DRIVE, force = "player" }, "order_upgrade (downgrade) refused")
			return next_phase("downgrade")
		end
		timeout_after(300, "pulling the recovered chlorine in (pool " .. serpent.line(pool()) .. ", interface "
			.. (iface and iface.get_fluid_count("water") or -1) .. ")")
	elseif phase == "downgrade" then
		local small = ent(RC.d2, FL_DRIVE)
		local iface = s.find_entity("me-fluid-interface", RC_IFACE)
		if small and ref.get_item_count(RC_UPGRADE) >= 1 then
			local d = remote.call(F, "drive", small)
			expect(d and near(d.used, 32000), "downgraded drive " .. serpent.line(d))
			expect(loaded_item(RC_UPGRADE) == nil, "the old 4k drive item carries fluid after the downgrade")
			local rest = 0
			for _, amount in pairs(pool()) do rest = rest + amount end
			expect(near(rest, st.big_used - 32000 - st.room), "recovered after the downgrade " .. rest .. ", expected " .. (st.big_used - 32000 - st.room))
			local capacity, used = remote.call(F, "capacity", ref)
			expect(near(capacity, used), "the network is not full after the downgrade " .. used .. "/" .. capacity)
			expect(next(remote.call(F, "replacing")) == nil, "fluid still held for a replacement " .. serpent.line(remote.call(F, "replacing")))
			log("DEVCHECK-RUNTIME-UPGRADE-EVENTS downgrade " .. table.concat(st.events, " "))
			--- 10) a hand fast replace of the rebuilt 1k drive by a 4k drive, in the engine's event order:
			--- on_pre_build of the player at that spot, on_player_mined_entity (buffer: the old item), the
			--- old entity is gone, on_built_entity of the new drive. The new drive takes the old drive's fluid
			--- and then the recovered fluid of its network.
			local d1 = ent(RC.d1)
			local old = remote.call(F, "drive", d1).contents
			local buffer = game.create_inventory(1)
			buffer.insert{ name = FL_DRIVE, count = 1 }
			remote.call(F, "pre_build", 1, s, { x = RC.d1[2], y = RC.d1[3] })
			remote.call(F, "player_mined", d1, buffer, 1)
			expect(same(remote.call(F, "replacing"), old), "held for the fast replace " .. serpent.line(remote.call(F, "replacing")) .. ", drive held " .. serpent.line(old))
			local tags = buffer[1].valid_for_read and buffer[1].tags or {}
			expect(buffer[1].valid_for_read and not tags.fork_me_fluids, "the replaced drive item carries fluid " .. serpent.line(tags))
			buffer.destroy()
			d1.destroy()
			local hand = s.create_entity{ name = RC_UPGRADE, position = { RC.d1[2], RC.d1[3] }, force = "player" }
			remote.call(F, "unpack_drive", hand, nil)
			local h = remote.call(F, "drive", hand)
			for name, amount in pairs(old) do
				expect(h.contents[name] and h.contents[name] >= amount - FL_EPS, "the fast replaced drive lost " .. name .. ": " .. serpent.line(h.contents))
			end
			expect(next(pool()) == nil, "recovered fluid left after the fast replace " .. serpent.line(pool()))
			expect(next(remote.call(F, "replacing")) == nil, "fluid still held after the fast replace")
			local out = remote.call(F, "totals", ref)
			out.water = (out.water or 0) + (iface and iface.get_fluid_count("water") or 0)
			expect(same(out, st.all), "fluid not conserved at the end: " .. serpent.line(out) .. ", expected " .. serpent.line(st.all))
			return finish_test("ghost " .. (st.engine_ghost and "by the engine" or "by the test") .. ", pull-in " .. st.pullin_ticks
				.. " ticks, whole test " .. (game.tick - st.started) .. " ticks")
		end
		timeout_after(600, "robots downgrading the drive (" .. robot_report(s, { RC.d2[2], RC.d2[3] }, FL_DRIVE) .. ")")
	end
end

--- the engine's event order of a robot upgrade, logged for docs/AE2.md ("Upgrades")
local function note_upgrade_event(what)
	return function(event)
		local st = storage.fluid_rec
		local e = event.entity
		if not (st and st.events and e and e.valid and e.name:find("^me%-fluid%-drive")) then return end
		local marked = (what ~= "built") and tostring(e.to_be_upgraded()) or "-"
		st.events[#st.events + 1] = string.format("%s:%s@%d(unit %d, marked %s)", what, e.name, game.tick, e.unit_number, marked)
	end
end
script.on_event(defines.events.on_robot_pre_mined, note_upgrade_event("pre_mined"))
script.on_event(defines.events.on_robot_mined_entity, note_upgrade_event("mined"))
script.on_event(defines.events.on_robot_built_entity, note_upgrade_event("built"))

--- Endgame power (prototypes/136-fork-power.lua, scripts/fork-power.lua): a LuV large plasma turbine
--- with helium plasma and a turbine output hatch next to it, and a UV large naquadah reactor with
--- naquadah based fuel MK1, each loaded by an electric energy interface that draws the generator's
--- full output. After 7 s both must have produced power and burnt fuel, and the hatch must hold the
--- cooled fluid (helium) for the plasma the turbine burnt (see the cooled fluid test below).
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
		local owed = remote.call("gregtorio-power", "debt", turbine) + remote.call("gregtorio-power", "energy", turbine) / PW.turbine[6]
		expect(helium > 0, "the output hatch got no helium")
		expect(math.abs(helium + owed - burnt) <= cooled_tolerance(burnt), "hatch holds " .. helium .. " helium (+ " .. owed .. " owed) for " .. burnt .. " plasma burnt")
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
	--- issue #34: the new tiers take the same fuel check (1000 plasma: 7.8 s of the UXV turbine)
	{ "steam_uxv",     "uxv-large-plasma-turbine",   200.5, "steam",                   100,    "helium-plasma",           1000,   10485.76e6 },
	{ "fuel_uev",      "uev-large-plasma-turbine",   225.5, "naquadah-based-fuel-mk1", 10,     "helium-plasma",           100,    1310.72e6 },
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
			eei.electric_buffer_size = math.max(1e8, 2 * def[8] / 60)
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

--- Cooled fluid (issue #28, scripts/fork-power.lua): the cooled fluid in a turbine's output hatch
--- must match the plasma it burnt, one unit per unit, within COOLED_TOL (relative) + COOLED_ABS
--- units, whatever the load. Every LuV plasma turbine has its own load (an electric energy interface
--- that draws exactly the given share of 81.92 MW per tick, no buffer), set every tick:
---   full, partial (40 %), burst (full for 5 ticks out of 23, idle in between): a known amount of
---     helium plasma burnt to the last drop, then the hatch must hold exactly that much helium;
---   idle: no load; only the first fill of the load's buffer is burnt, and returned;
---   full_hatch: the hatch starts with 3999 of its 4000 helium, so the rest stays owed; once it is
---     emptied it must get all of it;
---   pair_a, pair_b: two turbines side by side on helium and nitrogen plasma, one hatch each: each
---     hatch gets only its own cooled fluid, in the right amount.
--- A running turbine is compared as hatch + owed + the energy of the current step / fuel value.
local CO_Y = 370
local COOLED_TOL, COOLED_ABS = 1e-3, 1e-3
local CO_DEADLINE = 1300
local CO_POWER = 81.92e6
local CO = {
	--  key           x      plasma            amount  load(tick)                                       hatch x offset
	{ "full",       200.5, "helium-plasma",   4,     function() return 1 end,                         2 },
	{ "partial",    225.5, "helium-plasma",   2,     function() return 0.4 end,                       2 },
	{ "burst",      250.5, "helium-plasma",   1.5,   function(t) return t % 23 < 5 and 1 or 0 end,    2 },
	{ "idle",       275.5, "helium-plasma",   10,    function() return 0 end,                         2 },
	{ "full_hatch", 300.5, "helium-plasma",   100,   function() return 1 end,                         2 },
	{ "pair_a",     330.5, "helium-plasma",   100,   function() return 1 end,                         -2 },
	{ "pair_b",     333.5, "nitrogen-plasma", 100,   function() return 1 end,                         2 },
}
local CO_PREFILL = 3999

function cooled_tolerance(burnt) return COOLED_ABS + COOLED_TOL * burnt end

function setup_cooled_test(s)
	local fails = {}
	storage.cooled = { t = {} }
	for i, def in ipairs(CO) do
		local ok, err = pcall(function()
			local g = s.create_entity{ name = "luv-large-plasma-turbine", position = { def[2], CO_Y }, force = "player", raise_built = true }
			local got = g.insert_fluid{ name = def[3], amount = def[4] }
			if math.abs(got - def[4]) > 1e-6 then fails[#fails + 1] = "cooled test: " .. def[1] .. " took only " .. got .. " " .. def[3] end
			local eei = s.create_entity{ name = "electric-energy-interface", position = { def[2], CO_Y + 6 }, force = "player" }
			eei.power_production = 0
			eei.power_usage = 0
			eei.electric_buffer_size = CO_POWER / 60
			s.create_entity{ name = "substation", position = { def[2] + (def[6] > 0 and 4 or -4), CO_Y + 6 }, force = "player" }
			local h = s.create_entity{ name = "turbine-output-hatch", position = { def[2] + def[6], CO_Y }, force = "player", raise_built = true }
			storage.cooled.t[def[1]] = { g = g, eei = eei, h = h, i = i, removed = 0 }
		end)
		if not ok then fails[#fails + 1] = "cooled test " .. def[1] .. ": " .. tostring(err) end
	end
	local fh = storage.cooled.t.full_hatch
	if fh then
		local got = fh.h.insert_fluid{ name = "helium", amount = CO_PREFILL }
		if math.abs(got - CO_PREFILL) > 1e-6 then fails[#fails + 1] = "cooled test: the full hatch took only " .. got .. " helium" end
	end
	return fails
end

--- Every tick: the load of each turbine
function cooled_load_tick(tick)
	local st = storage.cooled
	if not st or st.done then return end
	for _, c in pairs(st.t) do
		if c.eei.valid then c.eei.power_usage = CO_POWER / 60 * CO[c.i][5](tick) end
	end
end

function cooled_test()
	local st = storage.cooled
	if not st then return end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish(summary)
		st.done = true
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL cooled fluid test: " .. p) end
		log("DEVCHECK-RUNTIME-COOLED " .. (#problems == 0 and "ok" or "failed") .. (summary or ""))
	end
	for _, def in ipairs(CO) do
		local c = st.t[def[1]]
		if not (c and c.g.valid and c.h.valid and c.eei.valid) then
			problems[#problems + 1] = def[1] .. " missing"
			return finish()
		end
	end
	local P = "gregtorio-power"
	--- the plasma a turbine burnt (entity and segment) and the cooled fluid it returned: in the hatch
	--- (and taken out of it by the test), owed, and the energy of the current step
	local function account(c)
		local def = CO[c.i]
		local fuel = prototypes.fluid[def[3]].fuel_value
		local out = def[3] == "helium-plasma" and "helium" or "nitrogen"
		local seg = c.g.fluidbox.get_fluid_segment_contents(1)
		local burnt = def[4] - c.g.get_fluid_count(def[3]) - ((seg and seg[def[3]]) or 0)
		local prefill = def[1] == "full_hatch" and CO_PREFILL or 0
		local hatch = c.h.get_fluid_count(out) + c.removed - prefill
		local owed = remote.call(P, "debt", c.g, out)
		local pending = remote.call(P, "energy", c.g) / fuel
		return burnt, hatch, owed, pending, out
	end
	local function matches(key, c)
		local burnt, hatch, owed, pending, out = account(c)
		local ok = math.abs(hatch + owed + pending - burnt) <= cooled_tolerance(burnt)
		st.worst = math.max(st.worst or 0, math.abs(hatch + owed + pending - burnt) / burnt)
		expect(ok, string.format("%s: %.6f plasma burnt, hatch got %.6f %s, %.6f owed, %.6f pending", key, burnt, hatch, out, owed, pending))
		return burnt, hatch + owed + pending - burnt
	end
	local tick = game.tick
	st.dry = st.dry or {}
	--- the known amounts: burnt to the last drop, stopped for "no fuel", nothing owed or pending
	for _, key in pairs({ "full", "partial", "burst" }) do
		local c = st.t[key]
		if not st.dry[key] then
			local burnt, hatch, owed, pending = account(c)
			local amount = CO[c.i][4]
			if burnt >= amount - 1e-9 and owed < 1e-4 and pending == 0 and c.g.disabled_by_script then
				st.dry[key] = { tick = tick, hatch = hatch }
				st.worst = math.max(st.worst or 0, math.abs(hatch - amount) / amount)
				expect(math.abs(hatch - amount) <= cooled_tolerance(amount),
					string.format("%s: %.6f plasma burnt, the hatch got %.6f", key, amount, hatch))
			end
		end
	end
	--- the full hatch: full, the rest owed; then emptied, and it must get everything
	local fh = st.t.full_hatch
	if not st.hatch_phase then
		local burnt, _, owed = account(fh)
		if burnt >= 3 then
			expect(math.abs(fh.h.get_fluid_count("helium") - 4000) < 1e-3, "full hatch holds " .. fh.h.get_fluid_count("helium") .. " of 4000")
			expect(owed > 1.5, "full hatch: only " .. owed .. " helium owed for " .. burnt .. " plasma burnt")
			matches("full_hatch (full)", fh)
			st.hatch_owed = owed
			fh.removed = fh.removed + fh.h.remove_fluid{ name = "helium", amount = 4000 }
			st.hatch_phase = tick
		end
	elseif st.hatch_phase ~= true and tick >= st.hatch_phase + 60 then
		matches("full_hatch (emptied)", fh)
		local _, _, owed = account(fh)
		expect(owed < 0.2, "full hatch: still " .. owed .. " helium owed after it was emptied")
		st.hatch_phase = true
	end
	--- the pair: own fluid only, right amounts
	if not st.pair_checked and account(st.t.pair_a) >= 3 then
		matches("pair_a", st.t.pair_a)
		matches("pair_b", st.t.pair_b)
		expect(st.t.pair_a.h.get_fluid_count("nitrogen") == 0, "pair_a's hatch got nitrogen")
		expect(st.t.pair_b.h.get_fluid_count("helium") == 0, "pair_b's hatch got helium")
		expect(account(st.t.pair_b) > 1, "pair_b burnt only " .. account(st.t.pair_b) .. " nitrogen plasma")
		st.pair_checked = true
	end
	if #problems > 0 then return finish() end
	if st.dry.full and st.dry.partial and st.dry.burst and st.hatch_phase == true and st.pair_checked then
		--- idle: only the first fill of its load's buffer (one tick of output each) is burnt
		local idle_burnt = matches("idle", st.t.idle)
		expect(idle_burnt < 3 / 60 + 1e-6, "idle turbine burnt " .. idle_burnt .. " plasma")
		return finish(string.format(" (4/2/1.5 plasma -> %.6f/%.6f/%.6f helium at full/40%%/burst load, worst error %.1e, full hatch owed %.2f)",
			st.dry.full.hatch, st.dry.partial.hatch, st.dry.burst.hatch, st.worst or 0, st.hatch_owed))
	end
	if tick > CO_DEADLINE then
		local left = {}
		for _, key in pairs({ "full", "partial", "burst" }) do
			if not st.dry[key] then
				local burnt, hatch, owed, pending = account(st.t[key])
				left[key] = { burnt = burnt, hatch = hatch, owed = owed, pending = pending, stopped = st.t[key].g.disabled_by_script }
			end
		end
		expect(false, "timed out: dry " .. serpent.line(st.dry) .. " (not yet: " .. serpent.line(left) .. ")" .. ", full hatch " .. tostring(st.hatch_phase) .. ", pair " .. tostring(st.pair_checked))
		return finish()
	end
end

--- Turbine tiers (issue #34, prototypes/136-fork-power.lua): one UHV to UXV large plasma turbine each
--- and a second UXV one on neon plasma, with an output hatch and a load of twice its output (an electric
--- energy interface in its own network). While it runs, every turbine must generate exactly four amps
--- of its tier per tick (the cap, not the load; fluid_usage_per_tick must let the weakest plasma, neon,
--- reach it too); once its plasma (one to one and a half seconds of full output) is burnt to the last
--- drop, its hatch must hold exactly that much cooled fluid (tolerance of the cooled fluid test).
--- The runtime code is the one of the LuV turbines: the new turbines are only listed in the mod data.
local TT_Y = -260                                       -- above the machine grid, below the recipe test
local TT_CHECK_TICK = 20
local TT_DEADLINE = 600
local TT = {
	--  turbine                     x      plasma            amount  cooled fluid    cap (W)
	{ "uhv-large-plasma-turbine", 100.5, "helium-plasma",   8,      "helium",       655.36e6 },
	{ "uev-large-plasma-turbine", 125.5, "helium-plasma",   16,     "helium",       1310.72e6 },
	{ "uiv-large-plasma-turbine", 150.5, "nitrogen-plasma", 30,     "nitrogen",     2621.44e6 },
	{ "umv-large-plasma-turbine", 175.5, "iron-plasma",     30,     "molten-iron",  5242.88e6 },
	{ "uxv-large-plasma-turbine", 200.5, "helium-plasma",   128,    "helium",       10485.76e6 },
	--- the weakest plasma (20.48 MJ): the UXV turbine needs 8.53 of its 9 units per tick for the cap
	{ "uxv-large-plasma-turbine", 225.5, "neon-plasma",     512,    "neon",         10485.76e6 },
}

function setup_tier_test(s)
	local fails = {}
	storage.tiers = { t = {}, dry = {} }
	for i, def in ipairs(TT) do
		local ok, err = pcall(function()
			local g = s.create_entity{ name = def[1], position = { def[2], TT_Y }, force = "player", raise_built = true }
			local got = g.insert_fluid{ name = def[3], amount = def[4] }
			if math.abs(got - def[4]) > 1e-6 then fails[#fails + 1] = "tier test: " .. def[1] .. " took only " .. got .. " " .. def[3] end
			local eei = s.create_entity{ name = "electric-energy-interface", position = { def[2], TT_Y + 6 }, force = "player" }
			eei.power_production = 0
			eei.power_usage = 2 * def[6] / 60
			eei.electric_buffer_size = 4 * def[6] / 60
			s.create_entity{ name = "substation", position = { def[2] + 4, TT_Y + 6 }, force = "player" }
			local h = s.create_entity{ name = "turbine-output-hatch", position = { def[2] + 2, TT_Y }, force = "player", raise_built = true }
			storage.tiers.t[i] = { g = g, h = h }
		end)
		if not ok then fails[#fails + 1] = "tier test " .. def[1] .. ": " .. tostring(err) end
	end
	return fails
end

function tier_test()
	local st = storage.tiers
	if not st then return end
	local tick = game.tick
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function finish(summary)
		st.done = true
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL turbine tier test: " .. p) end
		log("DEVCHECK-RUNTIME-TIERS " .. (#problems == 0 and "ok" or "failed") .. (summary or ""))
	end
	for i, def in ipairs(TT) do
		local c = st.t[i]
		if not (c and c.g.valid and c.h.valid) then
			problems[#problems + 1] = def[1] .. " missing"
			return finish()
		end
	end
	--- the cap: four amps of the tier per tick under twice that load, as the prototype says
	if not st.capped and tick >= TT_CHECK_TICK then
		for i, def in ipairs(TT) do
			local g = st.t[i].g
			local per_tick = def[6] / 60
			local max = g.prototype.get_max_power_output()
			expect(math.abs(max - per_tick) <= 1e-6 * per_tick, def[1] .. ": max_power_output " .. max * 60 .. " W, expected " .. def[6])
			expect(not g.disabled_by_script, def[1] .. " is stopped on " .. def[3] .. " (" .. serpent.line(g.custom_status) .. ")")
			expect(math.abs(g.energy_generated_last_tick - per_tick) <= 1e-6 * per_tick,
				string.format("%s generates %.6g W under a load of %.6g W, expected the cap %.6g W", def[1],
					g.energy_generated_last_tick * 60, 2 * def[6], def[6]))
		end
		st.capped = true
		if #problems > 0 then return finish() end
	end
	--- the cooled fluid: burnt to the last drop (stopped for "no fuel", nothing owed or pending)
	for i, def in ipairs(TT) do
		local c = st.t[i]
		if not st.dry[i] then
			local seg = c.g.fluidbox.get_fluid_segment_contents(1)
			local burnt = def[4] - c.g.get_fluid_count(def[3]) - ((seg and seg[def[3]]) or 0)
			local owed = remote.call("gregtorio-power", "debt", c.g, def[5])
			local pending = remote.call("gregtorio-power", "energy", c.g)
			if burnt >= def[4] - 1e-9 and owed < 1e-4 and pending == 0 and c.g.disabled_by_script then
				local hatch = c.h.get_fluid_count(def[5])
				st.dry[i] = { tick = tick, hatch = hatch }
				st.worst = math.max(st.worst or 0, math.abs(hatch - def[4]) / def[4])
				expect(math.abs(hatch - def[4]) <= cooled_tolerance(def[4]),
					string.format("%s: %.6f %s burnt, the hatch got %.6f %s", def[1], def[4], def[3], hatch, def[5]))
				expect(c.h.get_fluid_count(def[3]) == 0, def[1] .. ": plasma leaked into the output hatch")
			end
		end
	end
	if #problems > 0 then return finish() end
	if st.capped and table_size(st.dry) == #TT then
		local parts = {}
		for i, def in ipairs(TT) do
			parts[#parts + 1] = string.format("%s %.6g MW: %g -> %.6f", def[1]:sub(1, 3), def[6] / 1e6, def[4], st.dry[i].hatch)
		end
		return finish(string.format(" (%s; worst error %.1e)", table.concat(parts, ", "), st.worst or 0))
	end
	if tick > TT_DEADLINE then
		expect(false, "timed out: capped " .. tostring(st.capped) .. ", dry " .. serpent.line(st.dry))
		return finish()
	end
end

--- New recipes of issue #35 (prototypes/129-fork-water-purification.lua): grades 7 and 8 in the water
--- purification plant, the FPIC and APIC wafers and chips, the complex SMDs, the quark creation catalyst
--- and recipes that take the new parts; the same for issues #39 and #36. Each machine gets one craft's ingredients (placed above the
--- machine grid, powered like it); once it crafts, its progress is set close to the end (the grades take
--- 25 and 30 s, a mainframe 12 minutes), and the main product must come out.
local RT_Y = -300
local RT_DEADLINE = 900
local RT = {
	{ "water-purification-plant", "grade-7-water" },
	{ "water-purification-plant", "grade-8-water" },
	{ "uhv-laser-engraver", "fpic-wafer" },
	{ "uev-laser-engraver", "apic-wafer" },
	{ "uhv-assembling-machine", "femto-power-ic" },
	{ "uev-assembling-machine", "atto-power-ic" },
	{ "uv-assembling-machine", "complex-smd-transistor" },
	{ "uv-assembling-machine", "complex-smd-resistor" },
	{ "uv-assembling-machine", "complex-smd-capacitor" },
	{ "uv-assembling-machine", "complex-smd-diode" },
	{ "uv-assembling-machine", "complex-smd-inductor" },
	{ "zpm-assembly-line", "quark-creation-catalyst" },
	{ "zpm-assembly-line", "uev-energy-hatch" },
	{ "zpm-assembly-line", "uiv-energy-hatch" },
	{ "zpm-assembly-line", "fusion-reactor-mk4-controller" },
	{ "luv-circuit-assembly-line", "wetware-processor-mainframe" },
	-- issues #39 and #36 (prototypes/137-fork-endgame-materials.lua): the drafts made real, the new
	-- materials and recipes that take them
	{ "iv-circuit-assembler", "lapotronic-energy-orb-cluster" },
	{ "ev-assembling-machine", "wrapped-plutonium-ingot" },
	{ "hv-implosion-compressor", "high-density-plutonium-nugget" },
	{ "luv-mixer", "plutonium-based-liquid-fuel" },
	{ "hv-mixer", "super-coolant" },
	{ "hv-canning-machine", "1080k-super-coolant-cell" },
	{ "zpm-electric-blast-furnace", "hot-fluxed-electrum-ingot" },
	{ "zpm-alloy-blast-smelter", "molten-fluxed-electrum" },
	{ "uv-electric-blast-furnace", "hot-bedrockium-ingot" },
	{ "uhv-electric-blast-furnace", "hot-quantium-ingot" },
	{ "iv-extractor", "molten-quantium" },
	{ "uhv-mixer", "naquadah-based-fuel-mk2" },
	{ "water-purification-plant", "grade-5-water" },
	{ "zpm-assembly-line", "uxv-energy-hatch" },
}

local function rt_product(recipe)
	local r = prototypes.recipe[recipe]
	for _, p in pairs(r.products) do
		if p.name == (r.main_product and r.main_product.name or p.name) then return p end
	end
end

function setup_recipe_test(s)
	local fails = {}
	storage.recipe_test = { m = {}, ok = {} }
	local x = -150
	for i, def in pairs(RT) do
		local ok, err = pcall(function()
			local e = s.create_entity{ name = def[1], position = { x, RT_Y }, force = "player", raise_built = true }
			s.create_entity{ name = "electric-energy-interface", position = { x, RT_Y + 7 }, force = "player" }
			s.create_entity{ name = "substation", position = { x + 5, RT_Y + 7 }, force = "player" }
			e.force.recipes[def[2]].enabled = true
			e.set_recipe(def[2])
			for _, ing in pairs(prototypes.recipe[def[2]].ingredients) do
				if ing.type == "item" then
					local n = e.insert{ name = ing.name, count = ing.amount }
					assert(n == ing.amount, "only " .. n .. " of " .. ing.amount .. " " .. ing.name .. " fit")
				else
					local n = e.insert_fluid{ name = ing.name, amount = ing.amount }
					assert(math.abs(n - ing.amount) < 1e-6, "only " .. n .. " of " .. ing.amount .. " " .. ing.name .. " fit")
				end
			end
			storage.recipe_test.m[i] = e
		end)
		if not ok then fails[#fails + 1] = "recipe test " .. def[2] .. " in " .. def[1] .. ": " .. tostring(err) end
		x = x + 18
	end
	return fails
end

function recipe_test()
	local st = storage.recipe_test
	if not st or st.done then return end
	local pending = {}
	for i, def in pairs(RT) do
		local e = st.m[i]
		if e and e.valid and not st.ok[i] then
			local p = rt_product(def[2])
			local made = p.type == "fluid" and e.get_fluid_count(p.name) or
				e.get_inventory(defines.inventory.crafter_output).get_item_count(p.name)
			if made >= (p.amount or p.amount_min or 1) - 1e-6 then
				st.ok[i] = true
			else
				if e.crafting_progress > 0 and e.crafting_progress < 0.999 then e.crafting_progress = 0.999 end
				local status
				for name, v in pairs(defines.entity_status) do if e.status == v then status = name end end
				pending[#pending + 1] = def[2] .. " (" .. tostring(status) .. ", progress " .. e.crafting_progress .. ", made " .. made .. ")"
			end
		end
	end
	local n = 0
	for _ in pairs(st.ok) do n = n + 1 end
	if #pending == 0 or game.tick > RT_DEADLINE then
		st.done = true
		local problems = {}
		if n < #RT then problems[#problems + 1] = "recipe test: " .. (#RT - n) .. " of " .. #RT .. " recipes made nothing: " .. table.concat(pending, ", ") end
		for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. p) end
		log("DEVCHECK-RUNTIME-RECIPES " .. (#problems == 0 and "ok" or "failed") .. " (" .. n .. " of " .. #RT .. " recipes crafted by tick " .. game.tick .. ")")
	end
end

local MOLD_Y = 120
local MOLD_RECIPE = "glass-alloy-smelter"
local MOLD_DEADLINE = 900                               -- ticks for the first glass with the mold in (361 needed)

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
	cooled_load_tick(event.tick)
	local m = storage.mold_machine
	if storage.mold_done then return end
	local function glass_made()
		return m and m.valid and m.get_inventory(defines.inventory.crafter_output or defines.inventory.assembling_machine_output).get_item_count("glass") or 0
	end
	--- phase 2 as soon as the first glass is out, at the latest MOLD_DEADLINE ticks after the mold went in
	local phase
	if not storage.mold_phase1 and event.tick >= 60 then
		phase = 1
		storage.mold_phase1 = event.tick
	elseif storage.mold_phase1 and (glass_made() > 0 or event.tick >= storage.mold_phase1 + MOLD_DEADLINE) then
		phase = 2
		storage.mold_done = true
	else
		return
	end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	expect(m and m.valid, "mold test machine missing")
	if #problems == 0 then
		local glass = glass_made()
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
			log("DEVCHECK-RUNTIME-MOLD " .. (#problems == 0 and "ok" or "failed") .. " (glass " .. glass .. " after " .. (event.tick - storage.mold_phase1) .. " ticks)")
		end
	end
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. p) end
	if #problems > 0 and phase == 1 then
		storage.mold_done = true
		log("DEVCHECK-RUNTIME-MOLD failed")
	end
end)

--- The terrain comes from the map seed: trees, rocks, cliffs, water and enemies can be anywhere. The
--- tests place their entities by script, which ignores all that, but construction robots do not build
--- a ghost over a tree or on water, so a robot rebuild timed out on some seeds (issue #47). The whole
--- generated test area is cleared first (ore patches stay, they block nothing).
local TEST_RADIUS = 12                                     -- chunks around { 0, 0 }; every test lies inside
local function clear_test_area(s)
	local r = TEST_RADIUS * 32
	local area = { { -r, -r }, { r + 32, r + 32 } }
	local removed, water = 0, {}
	for _, e in pairs(s.find_entities_filtered{ area = area, force = { "neutral", "enemy" } }) do
		if e.valid and e.type ~= "resource" then
			e.destroy()
			removed = removed + 1
		end
	end
	for _, t in pairs(s.find_tiles_filtered{ area = area, collision_mask = "water_tile" }) do
		water[#water + 1] = { name = "landfill", position = t.position }
	end
	s.set_tiles(water)
	s.destroy_decoratives{ area = area }
	s.peaceful_mode = true
	game.map_settings.enemy_expansion.enabled = false
	return removed, #water
end

script.on_init(function()
	local s = game.surfaces[1]
	s.always_day = true
	s.request_to_generate_chunks({ 0, 0 }, TEST_RADIUS)
	s.force_generate_chunk_requests()
	local removed, water = clear_test_area(s)
	log("DEVCHECK-RUNTIME-SEED " .. s.map_gen_settings.seed .. " (test area cleared: " .. removed .. " entities, " .. water .. " water tiles)")
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
	for _, f in pairs(setup_furnace_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_fluid_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_recovery_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_power_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_fuel_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_cooled_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_tier_test(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_recipe_test(s)) do fails[#fails + 1] = f end
	log("DEVCHECK-RUNTIME placed=" .. placed .. " with_recipe=" .. with_recipe .. " failed=" .. #fails)
	for _, f in pairs(fails) do log("DEVCHECK-RUNTIME-FAIL " .. f) end
end)
