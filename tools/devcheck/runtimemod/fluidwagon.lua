--- Runtime test of me-network issue #417: a fluid wagon on the ME Storage Bus. A straight track of rails, a fluid wagon on it with
--- 1000 water, a storage bus north of the track facing the wagon, a controller with a fluid drive:
---   * the network sees the wagon's water, puts water into it and takes it out (the wagon's own amounts follow);
---   * the network puts no other fluid into a wagon that holds water;
---   * the wagon goes (destroyed): the network sees nothing; another wagon with 300 water there: the network sees its water;
---   * the bus's window data says it faces a fluid wagon.
--- Loaded by control.lua: require("fluidwagon")(H) returns { setup, tick, running }.

local NET, FL, SB = "gregtorio-me-network", "gregtorio-me-fluids", "gregtorio-me-storagebus"
local BX, BY = -150, 210              -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 130
local WAGON_X = 12                    -- the wagon's centre (x); the bus faces the tile at x = 12.5

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local function line(t) return serpent.line(t) end

	local function wagon(s, amount)
		local w = s.create_entity{ name = "fluid-wagon", position = { BX + WAGON_X, BY + 2 }, force = "player",
			direction = defines.direction.east }
		if w and amount then w.insert_fluid{ name = "water", amount = amount } end
		return w
	end

	function T.setup(s)
		local fails = {}
		local what = "fluid wagon"
		power(s, fails, what, BX, BY - 4)
		for x = 0, 24, 2 do
			local ok, r = pcall(s.create_entity, { name = "straight-rail", position = { BX + x + 1, BY + 2 + 1 }, force = "player",
				direction = defines.direction.east })
			if not (ok and r) then fails[#fails + 1] = what .. ": a rail at " .. x .. ": " .. tostring(r) end
		end
		if not wagon(s, 1000) then fails[#fails + 1] = what .. ": no fluid wagon on the rails" end
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY - 3)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 3.5, {}, "1k", true)
		local members = { ctrl, drive }
		for x = 9.5, 12.5 do members[#members + 1] = me_place(s, fails, what, "me-cable", BX + x, BY - 3.5) end
		for y = -2.5, 0.5 do members[#members + 1] = me_place(s, fails, what, "me-cable", BX + 12.5, BY + y) end
		members[#members + 1] = me_place(s, fails, what, "me-storage-bus", BX + 12.5, BY + 1.5, { direction = defines.direction.south })   -- (faces the wagon at y 2.5)
		H.me_connect(fails, what, members)
		return fails
	end

	function T.tick()
		local st = storage.fluidwagon417
		if (st and st.done) or game.tick < START then return end
		local s = game.surfaces[1]
		if not st then
			st = { problems = {}, phase = "start" }
			storage.fluidwagon417 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("FLUIDWAGON", "Fluid wagon on the ME Storage Bus", problems, "the wagon's water seen, put in and taken out, no "
				.. "other fluid; the wagon gone and another one there; the window data")
		end
		local ctrl, bus = s.find_entity("me-network-controller", { BX + 7, BY - 3 }), s.find_entity("me-storage-bus", { BX + 12.5, BY + 1.5 })
		local w = s.find_entities_filtered{ type = "fluid-wagon", area = { { BX, BY }, { BX + 25, BY + 5 } } }[1]
		if not (ctrl and bus) then expect(false, "entities missing") return finish() end
		local function water() return remote.call(FL, "count", ctrl, "water", "any") end
		local function in_wagon(e) local f = e and e.valid and e.get_fluid(1) return f and f.name == "water" and f.amount or 0 end

		if st.phase == "start" then
			if not w then expect(false, "no wagon") return finish() end
			remote.call(SB, "visit", bus)
			expect(math.abs(water() - 1000) < 0.01, "the network sees the wagon's water: " .. water())
			local info = remote.call(SB, "info", bus) or {}
			expect(info.target == "fluid-wagon", "the window data's target: " .. line(info.target))
			local put = remote.call(FL, "insert", ctrl, "water", 500)
			expect(math.abs(put - 500) < 0.01 and math.abs(in_wagon(w) - 1500) < 0.01, "500 water into the wagon: " .. line({ put, in_wagon(w) }))
			local got = remote.call(FL, "remove", ctrl, "water", 700)
			expect(math.abs(got - 700) < 0.01 and math.abs(in_wagon(w) - 800) < 0.01, "700 water out of the wagon: " .. line({ got, in_wagon(w) }))
			remote.call(FL, "insert", ctrl, "crude-oil", 100)                  -- (into the drive's fluid cell, not the wagon)
			local f = w.get_fluid(1)
			expect(f and f.name == "water" and math.abs(f.amount - 800) < 0.01, "crude oil went into a wagon of water: " .. line(f))
			--- the wagon goes, another one comes
			w.destroy{ raise_destroy = true }
			expect(water() < 0.01, "the network still sees the water of a wagon that is gone: " .. water())
			local w2 = wagon(s, 300)
			expect(w2 ~= nil, "the second wagon")
			st.phase, st.tick = "back", game.tick
			return
		end

		if st.phase == "back" then
			remote.call(SB, "visit", bus)
			expect(math.abs(water() - 300) < 0.01, "the network sees the second wagon's water: " .. water())
			return finish()
		end
	end

	function T.running(check) check(storage.fluidwagon417 and storage.fluidwagon417.done, "Fluid wagon on the ME Storage Bus") end

	return T
end
