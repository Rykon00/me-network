--- Runtime test of me-network issue #752: machines are fed while they work (the top-up of issue #557 for crafting patterns
--- with a fluid and for processing patterns). One network with water and iron plates, two Crafting CPUs and two
--- assembling machines 3, each next to its own pattern provider, with recipes of a tenth of a second (runtimemod's
--- data-final-fixes): machine A a crafting pattern with a fluid (10 water -> 1 iron plate), machine B a processing pattern
--- that names its recipe (1 iron plate -> 1 iron stick). A machine works off a hand-over in about a second; before, A ran
--- dry between two steps of its job (its fluid box holds a few crafts' worth) and B was filled only when it was empty.
--- * two jobs at once, JOB sticks from the plates in stock (B) and JOB plates from water (A): over WINDOW ticks each
---   machine makes at least 90 % of what its speed allows, and each job topped its machine up (`fed` of the job);
--- * both end with the numbers to the item: JOB sticks, the plates of the stock less what the sticks took plus the JOB
---   plates made, 10 water per plate gone, nothing left in a machine;
--- * a provider with a lock mode ("result": locked until the result is back) is not topped up: a third job of sticks on
---   B's provider with that lock ends with its sticks and `fed` 0.
--- Without the recipes (another mod took the vanilla machine or categories): nothing to check.
--- Loaded by control.lua: require("feeding")(H) returns { setup, tick, running }.

local NET, AC = "gregtorio-me-network", "gregtorio-me-autocraft"
local BX, BY = 760, -100
local START, TIMEOUT = 170, 1150
local PLATE_RECIPE, STICK_RECIPE = "zz-devcheck-feed-plate", "zz-devcheck-feed-stick"
local JOB, LOCKED_JOB, WINDOW, WARM = 80, 32, 220, 40
local STOCK, WATER = JOB + LOCKED_JOB, 2000

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	local function usable()
		return prototypes.recipe[PLATE_RECIPE] and prototypes.recipe[STICK_RECIPE] and prototypes.entity["assembling-machine-3"] and true
	end

	function T.setup(s)
		local fails = {}
		local what = "feeding"
		if not usable() then return fails end
		local tiles = {}
		for x = BX - 4, BX + 28 do
			for y = BY - 4, BY + 14 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		me_place(s, fails, what, "substation", BX + 18, BY + 8)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = STOCK })
		local tank = me_drive(s, fails, what, BX + 8.5, BY + 3.5, {}, "64k", true)
		if tank then
			local got = remote.call(NET, "store_fluid_in_drive", tank, "water", WATER)
			if got ~= WATER then fails[#fails + 1] = what .. ": only " .. tostring(got) .. " water went into the drive" end
		end
		local cpu1 = place_cpu(s, fails, what, BX + 11, BY)
		local cpu2 = place_cpu(s, fails, what, BX + 11, BY + 4)
		local pa = me_place(s, fails, what, "me-pattern-provider", BX + 14.5, BY + 5.5)
		local a = me_place(s, fails, what, "assembling-machine-3", BX + 14.5, BY + 7.5)
		local pb = me_place(s, fails, what, "me-pattern-provider", BX + 22.5, BY + 5.5)
		local b = me_place(s, fails, what, "assembling-machine-3", BX + 22.5, BY + 7.5)
		if a then
			a.force.recipes[PLATE_RECIPE].enabled = true
			a.force.recipes[STICK_RECIPE].enabled = true
		end
		if pa then give_patterns(pa, { { kind = "crafting", recipe = PLATE_RECIPE } }, fails) end
		if pb then
			give_patterns(pb, { { kind = "processing", inputs = { { key = "iron-plate", amount = 1 } },
				outputs = { { key = "iron-stick", amount = 1 } }, recipe = STICK_RECIPE } }, fails)
		end
		me_connect(fails, what, { ctrl, drive, tank, cpu1, cpu2, pa, pb })
		storage.feeding752_scene = { ctrl = ctrl, a = a, b = b, pa = pa, pb = pb }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.feeding752
		if tick < START or (st and st.done) then return end
		if not st then
			st = { problems = {}, phase = "start" }
			storage.feeding752 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish(note)
			st.done = true
			me_report("FEEDING", "machines fed while they work (issue #752)", problems, note or "")
		end
		if not usable() then return finish("nothing to check: no assembling machine 3 with the test's recipes") end
		local sc = storage.feeding752_scene
		if not (sc and sc.ctrl and sc.ctrl.valid and sc.a and sc.a.valid and sc.b and sc.b.valid and sc.pb and sc.pb.valid) then
			expect(false, "entities missing")
			return finish()
		end
		local function count(name) return remote.call(NET, "count", sc.ctrl, name) end
		local function water() return remote.call(NET, "fluid_count", sc.ctrl, "water") end
		local function job(id) return remote.call(AC, "job", id) or {} end
		local function per_tick(m, recipe) return m.crafting_speed / (prototypes.recipe[recipe].energy * 60) end
		--- (a finished job is kept for a while only: its end is noted when it is seen)
		local function over(id)
			st.over = st.over or {}
			if st.over[id] then return true end
			local j = job(id)
			if j.status == "done" then st.over[id] = true return true end
			if j.status == "failed" or j.status == "cancelled" or tick > st.at + TIMEOUT then
				expect(false, "job " .. tostring(id) .. ": " .. serpent.line({ j.status, j.reason, j.done, j.total, j.wait }))
				finish()
			end
			return false
		end

		if st.phase == "start" then
			expect(count("iron-plate") == STOCK and math.abs(water() - WATER) < 0.01, "the stock: " .. count("iron-plate") .. " plates, "
				.. water() .. " water")
			--- the sticks first: their job takes the plates of the stock, so the plate job plans its plates from water
			local sticks, why = remote.call(AC, "start", sc.ctrl, "iron-stick", JOB)
			expect(sticks ~= nil, "the stick job did not start: " .. tostring(why))
			expect(count("iron-plate") == STOCK - JOB, "the stick job took its plates: " .. count("iron-plate") .. " left")
			local plates, why2 = remote.call(AC, "start", sc.ctrl, "iron-plate", JOB)
			expect(plates ~= nil, "the plate job did not start: " .. tostring(why2))
			if not (sticks and plates) then return finish() end
			st.sticks, st.plates, st.at, st.phase = sticks, plates, tick, "warm"
		elseif st.phase == "warm" then
			if tick < st.at + WARM then return end
			st.a0, st.b0, st.t0, st.phase = sc.a.products_finished, sc.b.products_finished, tick, "window"
		elseif st.phase == "window" then
			if tick < st.t0 + WINDOW then return end
			local ticks = tick - st.t0
			local sa = (sc.a.products_finished - st.a0) / (ticks * per_tick(sc.a, PLATE_RECIPE))
			local sb = (sc.b.products_finished - st.b0) / (ticks * per_tick(sc.b, STICK_RECIPE))
			st.sa, st.sb = sa, sb
			expect(sa >= 0.9, string.format("the machine of the crafting pattern with a fluid made %.0f %% of what its speed allows in %d "
				.. "ticks, at least 90 %% expected", sa * 100, ticks))
			expect(sb >= 0.9, string.format("the machine of the processing pattern made %.0f %% of what its speed allows in %d ticks, at "
				.. "least 90 %% expected", sb * 100, ticks))
			local jp, js = job(st.plates), job(st.sticks)
			st.fed_plates, st.fed_sticks = jp.fed or 0, js.fed or 0
			expect((jp.fed or 0) > 0, "the plate job topped its machine up " .. tostring(jp.fed) .. " times")
			expect((js.fed or 0) > 0, "the stick job topped its machine up " .. tostring(js.fed) .. " times")
			st.phase = "done"
		elseif st.phase == "done" then
			if not (over(st.sticks) and over(st.plates)) then return end
			if st.done then return end
			local plates, sticks, w = count("iron-plate"), count("iron-stick"), water()
			expect(sticks == JOB and plates == STOCK - JOB + JOB, "after the two jobs: " .. sticks .. " sticks, " .. plates .. " plates")
			expect(math.abs(w - (WATER - 10 * JOB)) < 0.01, "water after the plate job: " .. w .. ", expected " .. (WATER - 10 * JOB))
			expect(sc.a.get_inventory(defines.inventory.crafter_input).is_empty() and sc.a.get_inventory(defines.inventory.crafter_output).is_empty()
				and sc.b.get_inventory(defines.inventory.crafter_input).is_empty() and sc.b.get_inventory(defines.inventory.crafter_output).is_empty(),
				"something is left in a machine")
			local fluid = sc.a.get_fluid_contents()
			expect((fluid.water or 0) < 0.01, "water left in the machine: " .. tostring(fluid.water))
			--- a provider with a lock mode is not topped up
			expect(remote.call(AC, "set_lock", sc.pb, "result"), "the lock was not set")
			local locked, why = remote.call(AC, "start", sc.ctrl, "iron-stick", LOCKED_JOB)
			expect(locked ~= nil, "the job on the locked provider did not start: " .. tostring(why))
			if not locked then return finish() end
			st.locked, st.at, st.phase = locked, tick, "locked"
		elseif st.phase == "locked" then
			if not over(st.locked) then return end
			if st.done then return end
			local j = job(st.locked)
			expect((j.fed or 0) == 0, "the job on a provider with a lock was topped up " .. tostring(j.fed) .. " times")
			expect(count("iron-stick") == JOB + LOCKED_JOB and count("iron-plate") == JOB, "after the third job: " .. count("iron-stick")
				.. " sticks, " .. count("iron-plate") .. " plates")
			remote.call(AC, "set_lock", sc.pb, nil)
			return finish(string.format("fluid crafting busy %.0f %% (%d top-ups), processing busy %.0f %% (%d top-ups) of %d ticks; "
				.. "every count exact; no top-up on a locked provider", st.sa * 100, st.fed_plates, st.sb * 100, st.fed_sticks, WINDOW))
		end
	end

	function T.running(check) check(storage.feeding752 and storage.feeding752.done, "machines fed while they work") end

	return T
end
