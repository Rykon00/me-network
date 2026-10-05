--- Runtime test of me-network issue #86 (docs/AE2.md "ME Import Bus / ME Export Bus"): an ME Export Bus feeds a lab.
--- * Lab A: an export bus with two science packs as filters. The lab's input takes one stack of each: the bus tops each
---   up to a stack (200 packs), the network keeps the rest; packs taken out of the lab (it used them) are topped up again.
--- * Lab C: a bus whose filters hold a pack the lab does not use, a plate and a pack the lab uses: the lab refuses what it
---   cannot take (nothing moves, nothing is lost, the network keeps it) and the pack it uses is still topped up. The pack the
---   lab does not use is found in the game's prototypes (a lab's `lab_inputs`); a game with none skips the case.
--- * Lab I: an ME Import Bus facing a lab has nothing to take from it ("no target").
--- Loaded by control.lua: require("lab")(H) returns { setup, tick, running } like margin.lua.

local NET, IO = "gregtorio-me-network", "gregtorio-me-io"
local BX, BY = 440, 100
local START, CHECK1, CHECK2 = 100, 400, 1000
local AUTOMATION, LOGISTIC = "automation-science-pack", "logistic-science-pack"

--- an item of type tool (a science pack) that the vanilla lab does not use, or nil (the game's twelve packs are all lab inputs,
--- so there is none without a mod that adds one)
local function unused_pack()
	local lab = prototypes.entity["lab"]
	local used = {}
	local ok, inputs = pcall(function() return lab.lab_inputs end)
	if not (ok and inputs) then return nil end
	for _, name in pairs(inputs) do used[name] = true end
	local best
	for name, p in pairs(prototypes.item) do
		if p.type == "tool" and not used[name] and (not best or name < best) then best = name end
	end
	return best
end

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	function T.setup(s)
		local fails = {}
		local what = "lab"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local items = { [AUTOMATION] = 800, [LOGISTIC] = 50, ["iron-plate"] = 100 }
		local other = unused_pack()
		if other then items[other] = 40 end
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 0.5, items)
		local bus_a = me_place(s, fails, what, "me-export-bus", BX + 10.5, BY + 0.5, SOUTH)
		local lab_a = me_place(s, fails, what, "lab", BX + 10.5, BY + 2.5)
		local bus_c = me_place(s, fails, what, "me-export-bus", BX + 14.5, BY + 0.5, SOUTH)
		local lab_c = me_place(s, fails, what, "lab", BX + 14.5, BY + 2.5)
		local bus_i = me_place(s, fails, what, "me-import-bus", BX + 18.5, BY + 0.5, SOUTH)
		local lab_i = me_place(s, fails, what, "lab", BX + 18.5, BY + 2.5)
		for x = 9.5, 18.5 do
			if x ~= 10.5 and x ~= 14.5 and x ~= 18.5 then me_place(s, fails, what, "me-cable", BX + x, BY - 0.5) end
		end
		me_connect(fails, what, { ctrl, drive, bus_a, bus_c, bus_i })
		storage.lab86_scene = { other = other or false }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local sc = storage.lab86_scene
		local st = storage.lab86
		if not st then
			if tick < START or not sc then return end
			st = { problems = {}, done = false }
			storage.lab86 = st
			local s = game.surfaces[1]
			local function find(name, x) return s.find_entity(name, { BX + x, BY + (name == "lab" and 2.5 or 0.5) }) end
			st.bus_a, st.lab_a = find("me-export-bus", 10.5), find("lab", 10.5)
			st.bus_c, st.lab_c = find("me-export-bus", 14.5), find("lab", 14.5)
			st.bus_i, st.lab_i = find("me-import-bus", 18.5), find("lab", 18.5)
			st.ctrl = s.find_entity("me-network-controller", { BX + 7, BY })
			if st.bus_a then remote.call(IO, "set_bus_filters", st.bus_a, { AUTOMATION, LOGISTIC }) end
			if st.bus_c then
				local f = { "iron-plate", AUTOMATION }
				if sc.other then table.insert(f, 1, sc.other) end
				remote.call(IO, "set_bus_filters", st.bus_c, f)
			end
			if st.bus_i then remote.call(IO, "set_bus_filters", st.bus_i, { AUTOMATION }) end
		end
		if st.done or tick < CHECK1 then return end
		local problems = st.problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		local ok = true
		for _, e in pairs({ st.bus_a, st.lab_a, st.bus_c, st.lab_c, st.bus_i, st.lab_i, st.ctrl }) do ok = ok and e and e.valid end
		if not ok then
			problems[#problems + 1] = "the test network was not built"
			st.done = true
			return me_report("LAB", "ME Export Bus into a lab", problems, "no network")
		end
		local function count(name) return remote.call(NET, "count", st.ctrl, name) end
		local function held(lab, name) return lab.get_inventory(defines.inventory.lab_input).get_item_count(name) end
		local stack = prototypes.item[AUTOMATION].stack_size
		if not st.phase1 then
			--- the first top-up: a stack of each pack the lab takes; the network keeps the rest
			st.phase1 = true
			local inv = st.lab_a.get_inventory(defines.inventory.lab_input)
			expect(inv ~= nil and #inv >= 1, "the lab has no lab_input inventory")
			expect(held(st.lab_a, AUTOMATION) == stack, "lab A holds " .. held(st.lab_a, AUTOMATION) .. " automation packs, not a stack of " .. stack)
			expect(held(st.lab_a, LOGISTIC) == 50, "lab A holds " .. held(st.lab_a, LOGISTIC) .. " logistic packs, not the 50 the network had")
			expect(count(AUTOMATION) == 800 - 2 * stack, "the network has " .. count(AUTOMATION) .. " automation packs left, not " .. (800 - 2 * stack) .. " (labs A and C took a stack each)")
			expect(count(LOGISTIC) == 0, "the network has " .. count(LOGISTIC) .. " logistic packs left")
			--- lab C: what it cannot take stays in the network, what it can is topped up
			expect(held(st.lab_c, AUTOMATION) == stack, "lab C holds " .. held(st.lab_c, AUTOMATION) .. " automation packs")
			expect(held(st.lab_c, "iron-plate") == 0, "lab C took iron plates")
			expect(count("iron-plate") == 100, "the network lost iron plates to lab C: " .. count("iron-plate"))
			if sc.other then
				expect(held(st.lab_c, sc.other) == 0, "lab C took " .. sc.other .. ", a pack the lab does not use")
				expect(count(sc.other) == 40, "the network has " .. count(sc.other) .. " " .. sc.other .. ", not 40")
				expect(not st.lab_c.get_inventory(defines.inventory.lab_input).can_insert{ name = sc.other },
					"the lab's input takes " .. sc.other .. ": the premise of the case is wrong")
			end
			--- the import bus has nothing to take from a lab
			local bus = remote.call(IO, "get_bus", st.bus_i)
			expect(bus and bus.status == "no-target", "the import bus facing a lab has the status " .. tostring(bus and bus.status))
			expect(held(st.lab_i, AUTOMATION) == 0, "the import bus put packs into a lab")
			--- the labs use packs: the buses top them up again
			st.lab_a.get_inventory(defines.inventory.lab_input).remove{ name = AUTOMATION, count = 150 }
			st.lab_a.get_inventory(defines.inventory.lab_input).remove{ name = LOGISTIC, count = 20 }
			st.used_at = tick
			return
		end
		if tick < CHECK2 then return end
		expect(held(st.lab_a, AUTOMATION) == stack, "after the lab used 150 packs it holds " .. held(st.lab_a, AUTOMATION) .. ", not a stack again")
		expect(held(st.lab_a, LOGISTIC) == 30, "lab A holds " .. held(st.lab_a, LOGISTIC) .. " logistic packs, the 30 it had left (the network has none)")
		--- nothing was lost or made: what the labs hold and the network has is what the drive got
		local total = count(AUTOMATION) + held(st.lab_a, AUTOMATION) + held(st.lab_c, AUTOMATION) + held(st.lab_i, AUTOMATION) + 150
		expect(total == 800, "automation packs: the network " .. count(AUTOMATION) .. " + lab A " .. held(st.lab_a, AUTOMATION) .. " + lab C "
			.. held(st.lab_c, AUTOMATION) .. " + the 150 the lab used = " .. total .. ", not 800")
		st.done = true
		me_report("LAB", "ME Export Bus into a lab", problems, "a stack of each pack topped up, a refused pack and a plate stay in the network, "
			.. "packs used are topped up again, an import bus facing a lab has no target" .. (sc.other and "" or " (no tool the lab refuses in this game: that case skipped)"))
	end

	function T.running(check) check(storage.lab86 and storage.lab86.done, "ME Export Bus into a lab") end
	return T
end
