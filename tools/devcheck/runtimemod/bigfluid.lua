--- Runtime test of me-network issue #821: a crafting pattern with more of a fluid than the machine's fluid box holds by
--- its prototype. The engine sizes a crafting machine's boxes by the recipe once it is set (an input box holds at least
--- four crafts' worth, an output box at least three), so the prototype's volume says nothing; the pattern check compared
--- it all the same and refused such a pattern until the recipe was set in the machine by hand. One network with water in
--- a fluid drive, iron and copper plates, two Crafting CPUs and two assembling machines 3 (fluid boxes of 1000, switched
--- off without a fluid recipe), each next to its own pattern provider and without a recipe (runtimemod's data-final-fixes
--- recipes, half a second):
--- * A, a crafting pattern: 2500 water + 1 iron plate -> 1 gear (a fluid ingredient above the box);
--- * B, a crafting pattern: 1 copper plate -> 2500 crude oil (a fluid product above the box).
--- Checked: both patterns are accepted while their machines have no recipe; a job of GEARS gears and one of OIL crude oil
--- end; machine A's input box held more than the prototype's volume; the water used and the oil made are exact.
--- Without the recipes (another mod took the vanilla machine, items, fluids or categories): nothing to check.
--- Loaded by control.lua: require("bigfluid")(H) returns { setup, tick, running }.

local NET, AC = "gregtorio-me-network", "gregtorio-me-autocraft"
local BX, BY = 960, -100
local START, TIMEOUT = 150, 900
local IN, OUT = "zz-devcheck-821-in", "zz-devcheck-821-out"
local PER = 2500
local GEARS, RUNS_OUT = 6, 5
local WATER = GEARS * PER + 500

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	local function usable()
		return prototypes.recipe[IN] and prototypes.recipe[OUT] and prototypes.entity["assembling-machine-3"] and true
	end

	function T.setup(s)
		local fails = {}
		local what = "bigfluid"
		if not usable() then return fails end
		local tiles = {}
		for x = BX - 4, BX + 28 do
			for y = BY - 8, BY + 14 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		me_place(s, fails, what, "substation", BX + 10, BY + 9)
		me_place(s, fails, what, "substation", BX + 18, BY + 10)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = GEARS, ["copper-plate"] = RUNS_OUT })
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
			a.force.recipes[IN].enabled = true
			a.force.recipes[OUT].enabled = true
		end
		if pa then give_patterns(pa, { { kind = "crafting", recipe = IN } }, fails) end
		if pb then give_patterns(pb, { { kind = "crafting", recipe = OUT } }, fails) end
		me_connect(fails, what, { ctrl, drive, tank, cpu1, cpu2, pa, pb })
		storage.bigfluid821_scene = { ctrl = ctrl, a = a, b = b, pa = pa, pb = pb }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.bigfluid821
		if tick < START or (st and st.done) then return end
		if not st then
			st = { problems = {}, phase = "start" }
			storage.bigfluid821 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish(note)
			st.done = true
			me_report("BIGFLUID", "fluid above the prototype's box (issue #821)", problems, note or "")
		end
		if not usable() then return finish("nothing to check: no assembling machine 3 with the test's recipes") end
		local sc = storage.bigfluid821_scene
		if not (sc and sc.ctrl and sc.ctrl.valid and sc.a and sc.a.valid and sc.b and sc.b.valid and sc.pa and sc.pa.valid
			and sc.pb and sc.pb.valid) then
			expect(false, "entities missing")
			return finish()
		end
		local function count(name) return remote.call(NET, "count", sc.ctrl, name) end
		local function fluid(name) return remote.call(NET, "fluid_count", sc.ctrl, name) end
		local function job(id) return remote.call(AC, "job", id) or {} end
		local function over(id)
			st.over = st.over or {}
			if st.over[id] then return true end
			local j = job(id)
			if j.status == "done" then st.over[id] = true return true end
			if j.status == "failed" or j.status == "cancelled" or tick > st.at + TIMEOUT then
				expect(false, "job " .. tostring(id) .. " of " .. tostring(j.item) .. ": "
					.. serpent.line({ j.status, j.reason, j.done, j.total, j.wait, j.problem }, { comment = false }))
				finish()
			end
			return false
		end

		if st.phase == "start" then
			local volume = 0
			for _, bx in ipairs(prototypes.entity["assembling-machine-3"].fluidbox_prototypes) do volume = math.max(volume, bx.get_volume()) end
			st.volume = volume
			expect(volume < PER, "the test needs a machine whose boxes hold less than " .. PER .. " by the prototype: " .. volume)
			expect(not sc.a.get_recipe() and not sc.b.get_recipe(), "a machine has a recipe before the first job")
			for _, row in pairs({ { sc.pa, "an ingredient" }, { sc.pb, "a product" } }) do
				local info = remote.call(AC, "provider_info", row[1])
				local sl = info and info.slots[1] or {}
				expect(sl.ok and not sl.reason, "the pattern with " .. PER .. " of a fluid as " .. row[2] .. " is refused at a machine without "
					.. "a recipe: " .. serpent.line({ sl.ok, sl.reason }))
			end
			expect(math.abs(fluid("water") - WATER) < 0.01, "the stock: " .. fluid("water") .. " water")
			local gears, why = remote.call(AC, "start", sc.ctrl, "iron-gear-wheel", GEARS)
			expect(gears ~= nil, "the gear job did not start: " .. tostring(why))
			local oil, why2 = remote.call(AC, "start", sc.ctrl, "fluid/crude-oil", RUNS_OUT * PER)
			expect(oil ~= nil, "the oil job did not start: " .. tostring(why2))
			if not (gears and oil) then return finish() end
			st.gears, st.oil, st.at, st.phase, st.max_in = gears, oil, tick, "run", 0
			return
		end
		if st.phase ~= "run" then return end
		for i = 1, sc.a.fluids_count do
			local f = sc.a.get_fluid(i)
			if f and f.name == "water" then st.max_in = math.max(st.max_in, f.amount) end
		end
		local all = over(st.gears)
		if st.done then return end
		all = over(st.oil) and all
		if st.done or not all then return end
		expect(count("iron-gear-wheel") == GEARS and count("iron-plate") == 0, "after the gear job: " .. count("iron-gear-wheel")
			.. " gears, " .. count("iron-plate") .. " iron plates")
		expect(math.abs(fluid("water") - (WATER - GEARS * PER)) < 0.01, "water after the gear job: " .. fluid("water") .. ", expected "
			.. (WATER - GEARS * PER))
		expect(math.abs(fluid("crude-oil") - RUNS_OUT * PER) < 0.01 and count("copper-plate") == 0, "after the oil job: "
			.. fluid("crude-oil") .. " crude oil, expected " .. RUNS_OUT * PER .. "; " .. count("copper-plate") .. " copper plates")
		expect(st.max_in > st.volume, "machine A's box never held more than the prototype's volume: " .. st.max_in)
		local left = 0
		for _, m in pairs({ sc.a, sc.b }) do for _, n in pairs(m.get_fluid_contents()) do left = left + n end end
		expect(left < 0.01, "fluid left in a machine: " .. left)
		return finish(string.format("patterns with %d of a fluid as ingredient and as product accepted at machines without a recipe "
			.. "(boxes of %d by the prototype); %d gears from %d water (%d in the box at once) and %d crude oil made, every amount exact",
			PER, st.volume, GEARS, GEARS * PER, st.max_in, RUNS_OUT * PER))
	end

	function T.running(check) check(storage.bigfluid821 and storage.bigfluid821.done, "fluid above the prototype's box") end

	return T
end
