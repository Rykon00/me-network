--- Runtime test of me-network issue #51 (docs/PERFORMANCE.md "Pull request 10"): a visit counts as starved only when the other
--- side had really run out, and a busy block never waits longer than the margin of a short busy list.
--- * An export bus fills water from the network into an empty storage tank at its speed. Its target never runs dry, so no
---   visit may count as starved (before #51 every visit after the second did: an insert the bus's speed ended was taken for
---   a target that took all it could hold, which also halved the bus's interval at every visit).
--- * An export bus fills iron plates into an empty steel chest at its speed (a block that moved all it was allowed to, whose
---   target uses nothing: its headroom says 600 ticks). Its interval must stay within the margin cap of the busy list
---   (remote `margin_cap`), which in the test map lies below 600 ticks. The cap is the number of busy units of the whole
---   map, so it moves while the other tests run: each interval is held against the cap of the tick its visit set it. The
---   visit runs in the mod's on_tick and this check after it, so a unit that leaves the busy list later in that tick makes
---   the cap read here one tick shorter than the one the visit used (issue #146: 16 against 15 once the map had a few
---   buses less): one tick of slack (MARGIN 1/16 at the floor of 16: a unit is a tick).
--- Loaded by control.lua: require("margin")(H) returns { setup, tick, running }.

local NET, IO = "gregtorio-me-network", "gregtorio-me-io"
local BX, BY = 370, -250
local START, CHECK = 200, 700
local WATER = 100000

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	function T.setup(s)
		local fails = {}
		local what = "margin"
		local eei = me_place(s, fails, what, "electric-energy-interface", BX + 12.5, BY + 6.5)
		if eei then
			eei.power_production = 1e6
			eei.electric_buffer_size = 1e7
		end
		me_place(s, fails, what, "substation", BX + 13, BY + 2)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 6, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 2.5, { ["iron-plate"] = 20000 })
		local fdrive = me_drive(s, fails, what, BX + 10.5, BY - 2.5, {}, "64k", true)
		local fbus = me_place(s, fails, what, "me-export-bus", BX + 1.5, BY + 0.5, SOUTH)
		local tank = me_place(s, fails, what, "storage-tank", BX + 1.5, BY + 2.5)
		local ibus = me_place(s, fails, what, "me-export-bus", BX + 4.5, BY + 0.5, SOUTH)
		local chest = me_place(s, fails, what, "steel-chest", BX + 4.5, BY + 1.5)
		me_connect(fails, what, { ctrl, drive, fdrive, fbus, ibus })
		if fdrive then
			local got = remote.call(NET, "store_fluid_in_drive", fdrive, "water", WATER)
			if (got or 0) < WATER then fails[#fails + 1] = what .. ": only " .. tostring(got) .. " water went into the fluid drive" end
		end
		storage.margin51_scene = { ctrl = ctrl, fbus = fbus, tank = tank, ibus = ibus, chest = chest }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local sc = storage.margin51_scene
		local st = storage.margin51
		if not st then
			if tick < START or not sc then return end
			st = { problems = {}, done = false, fvisits = 0, starved = 0, ivisits = 0, ivs = {} }
			storage.margin51 = st
			if sc.fbus and sc.fbus.valid then remote.call(IO, "set_bus_filters", sc.fbus, { "fluid/water" }) end
			if sc.ibus and sc.ibus.valid then remote.call(IO, "set_bus_filters", sc.ibus, { "iron-plate" }) end
		end
		if st.done then return end
		local problems = st.problems
		if not (sc.fbus and sc.fbus.valid and sc.ibus and sc.ibus.valid and sc.tank and sc.tank.valid and sc.chest and sc.chest.valid) then
			problems[#problems + 1] = "the test network was not built"
			st.done = true
			me_report("MARGIN", "ME margin of a short busy list", problems, "no network")
			return
		end
		--- the fluid bus: every visit while the tank has room (a visit is a new `last`)
		local f = remote.call(IO, "schedule", sc.fbus)
		local held = sc.tank.fluidbox[1]
		local room = sc.tank.fluidbox.get_capacity(1) - (held and held.amount or 0)
		if f and f.last and f.last ~= st.flast then
			st.flast = f.last
			if room > 5000 then
				st.fvisits = st.fvisits + 1
				if f.starve then st.starved = st.starved + 1 end
			end
		end
		--- the item bus into the chest: its intervals after the first visits, each with the cap of its visit's tick
		local i = remote.call(IO, "schedule", sc.ibus)
		if i and i.last and i.last ~= st.ilast then
			st.ilast = i.last
			st.ivisits = st.ivisits + 1
			if st.ivisits > 2 and i.interval then
				st.ivs[#st.ivs + 1] = i.interval
				st.caps = st.caps or {}
				st.caps[#st.ivs] = i.last == tick and remote.call(IO, "margin_cap") or nil
			end
		end
		if tick < CHECK then return end
		local cap = remote.call(IO, "margin_cap")
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		expect(st.fvisits >= 3, "the water export bus was visited " .. st.fvisits .. " times while its tank had room")
		expect(st.starved == 0, st.starved .. " of " .. st.fvisits .. " visits of the water export bus counted as starved, its tank never ran dry")
		expect(cap and cap < 600, "the margin cap of the test map is " .. tostring(cap) .. " ticks: not below the 600 of the headroom, the case tests nothing")
		local caps = st.caps or {}
		if st.ivisits >= 2 and i and i.interval and i.last ~= tick then   -- (the interval it is waiting now: set at an earlier tick)
			st.ivs[#st.ivs + 1] = i.interval
		end
		local worst, over = 0, nil
		for k, iv in ipairs(st.ivs) do
			if iv > worst then worst = iv end
			local c = caps[k] or cap
			if c and iv > c + 1 and not over then over = iv .. " ticks against the cap " .. c .. " of its visit" end
		end
		expect(#st.ivs >= 1, "the item export bus had " .. st.ivisits .. " visits, too few to see its interval")
		expect(cap and not over, "the item export bus waited " .. tostring(over or worst) .. ", longer than the margin cap")
		expect(sc.chest.get_item_count("iron-plate") > 0, "the item export bus moved nothing into its chest")
		st.done = true
		me_report("MARGIN", "ME margin of a short busy list", problems, "water export bus: " .. st.fvisits .. " visits, " .. st.starved .. " starved; item export bus: "
			.. #st.ivs .. " intervals, at most " .. worst .. " ticks (margin cap " .. tostring(cap) .. ")")
	end

	function T.running(check) check(storage.margin51 and storage.margin51.done, "ME margin of a short busy list") end
	return T
end
