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
--- Molds (prototypes/150-fork-molds.lua): an LV alloy smelter with a mold recipe must stop
--- without a mold, run with a mold in its mold slot and keep the mold there.
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
--- tick 850, and is checked in the same tick.
script.on_nth_tick(850, function(event)
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

script.on_nth_tick(10, function() if not (storage.autocraft and storage.autocraft.done) then autocraft_test() end end)

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
	log("DEVCHECK-RUNTIME placed=" .. placed .. " with_recipe=" .. with_recipe .. " failed=" .. #fails)
	for _, f in pairs(fails) do log("DEVCHECK-RUNTIME-FAIL " .. f) end
end)
