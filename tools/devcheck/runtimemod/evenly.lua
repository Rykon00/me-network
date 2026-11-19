--- Runtime test of the map setting "Buses take evenly from the stacks" (me-network-bus-take-evenly, N.remove_even): an ME
--- Storage Bus and an ME Import Bus take an item out of a chest from all its stacks at once, an equal share from each,
--- instead of from the first slot (top left) on: the next few stacks from a cursor, an equal share each.
--- * Storage bus, plain items: four stacks of iron in scattered slots, the network takes 40: every stack gives 10. Two more:
---   two stacks give one each; two more: the other two (the one item more goes round).
--- * Eight stacks: a removal takes a few of them (the window), the next the ones behind: after two removals of 20 each
---   stack gave 5.
--- * Storage bus, whole stacks (transport belts can be damaged: N.remove_whole's walk): two stacks give a share each.
--- * Import bus: three stacks of copper, one visit (64 items) leaves them within one item of each other, none empty.
--- * The setting off: the game's removal by count again (the stacks do not go down together).
--- Loaded by control.lua: require("evenly")(H) returns { setup, tick, running }.

local NET, IO, SB = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-storagebus"
local SETTING = "me-network-bus-take-evenly"
local BX, BY = 600, -600
local START = 150
local SOUTH = { direction = defines.direction.south }
local IRON_SLOTS = { 1, 4, 9, 20 }
local BELT_SLOTS = { 2, 6 }
local COPPER_SLOTS = { 1, 10, 30 }

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "buses take evenly"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k")
		H.cable_row(s, fails, BX + 9, BX + 16, BY - 1)
		me_place(s, fails, what, "me-storage-bus", BX + 10.5, BY + 0.5, SOUTH)
		me_place(s, fails, what, "steel-chest", BX + 10.5, BY + 1.5)
		me_place(s, fails, what, "me-storage-bus", BX + 12.5, BY + 0.5, SOUTH)
		me_place(s, fails, what, "steel-chest", BX + 12.5, BY + 1.5)
		me_place(s, fails, what, "me-import-bus", BX + 14.5, BY + 0.5, SOUTH)
		me_place(s, fails, what, "steel-chest", BX + 14.5, BY + 1.5)
		H.me_connect(fails, what, { ctrl, drive })
		return fails
	end

	function T.tick()
		local st = storage.evenly
		if game.tick < START or (st and (st.done or game.tick < st.next)) then return end
		if not st then
			st = { problems = {}, phase = 1, next = game.tick + 5 }
			storage.evenly = st
			st.was = settings.global[SETTING].value
			remote.call(SB, "set_take_evenly", true)
			return
		end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local ctrl = find("me-network-controller", 7, 0)
		local b1, b2, ib = find("me-storage-bus", 10.5, 0.5), find("me-storage-bus", 12.5, 0.5), find("me-import-bus", 14.5, 0.5)
		local c1, c2, ci = find("steel-chest", 10.5, 1.5), find("steel-chest", 12.5, 1.5), find("steel-chest", 14.5, 1.5)
		if not (ctrl and b1 and b2 and ib and c1 and c2 and ci) then
			st.done = true
			return me_report("EVENLY", "buses take evenly", { "entities missing" })
		end
		local inv1, inv2, invi = c1.get_inventory(defines.inventory.chest), c2.get_inventory(defines.inventory.chest),
			ci.get_inventory(defines.inventory.chest)
		local function counts(inv, slots)
			local out = {}
			for i, slot in ipairs(slots) do out[i] = inv[slot].valid_for_read and inv[slot].count or 0 end
			return out
		end
		local function line(t) return table.concat(t, "/") end
		local function fill(inv, slots, name, n)
			inv.clear()
			for _, slot in ipairs(slots) do inv[slot].set_stack{ name = name, count = n } end
		end
		local function extract(name, n) return remote.call(NET, "extract", ctrl, name, n) end

		if st.phase == 2 then
			--- the setting off: the game's removal by count
			fill(inv1, IRON_SLOTS, "iron-plate", 50)
			remote.call(SB, "visit", b1)
			extract("iron-plate", 40)
			local co = counts(inv1, IRON_SLOTS)
			expect(line(co) ~= "40/40/40/40" and co[1] + co[2] + co[3] + co[4] == 160, "setting off: the stacks went down together (" .. line(co) .. ")")
			remote.call(SB, "set_take_evenly", st.was)
			st.done = true
			return me_report("EVENLY", "buses take evenly", problems,
				"storage bus (plain and whole stacks) and import bus take from the stacks in turns, an equal share each, the remainder goes round; off: by count")
		end

		--- storage bus, plain items
		remote.call(SB, "set_settings", b1, { filters = { "iron-plate" }, priority = 10 })
		fill(inv1, IRON_SLOTS, "iron-plate", 50)
		remote.call(SB, "visit", b1)
		local got = extract("iron-plate", 40)
		local c = counts(inv1, IRON_SLOTS)
		expect(got == 40 and line(c) == "40/40/40/40", "storage bus: took " .. got .. ", the stacks are " .. line(c) .. ", not 40/40/40/40")
		extract("iron-plate", 2)
		local c2a = counts(inv1, IRON_SLOTS)
		local low = 0
		for _, n in ipairs(c2a) do if n == 39 then low = low + 1 end end
		expect(low == 2 and c2a[1] + c2a[2] + c2a[3] + c2a[4] == 158, "two more: two stacks give one each, not " .. line(c2a))
		extract("iron-plate", 2)
		local c2b = counts(inv1, IRON_SLOTS)
		expect(line(c2b) == "39/39/39/39", "two more again: the other two stacks give, not " .. line(c2b))

		--- a fuller chest: the stacks take turns, a few at a time (N.remove_even's window), two removals reach all eight
		local EIGHT = { 1, 3, 5, 7, 11, 13, 17, 19 }
		fill(inv1, EIGHT, "iron-plate", 50)
		remote.call(SB, "visit", b1)
		extract("iron-plate", 20)
		extract("iron-plate", 20)
		local c8 = counts(inv1, EIGHT)
		expect(line(c8) == "45/45/45/45/45/45/45/45", "eight stacks, two removals of 20: " .. line(c8) .. ", not 45 each")

		--- storage bus, whole stacks
		remote.call(SB, "set_settings", b2, { filters = { "transport-belt" }, priority = 10 })
		fill(inv2, BELT_SLOTS, "transport-belt", 50)
		remote.call(SB, "visit", b2)
		local gb = extract("transport-belt", 20)
		local cb = counts(inv2, BELT_SLOTS)
		expect(gb == 20 and line(cb) == "40/40", "whole stacks: took " .. gb .. ", the stacks are " .. line(cb) .. ", not 40/40")

		--- import bus: one visit
		remote.call(IO, "set_bus_filters", ib, { "copper-plate" })
		fill(invi, COPPER_SLOTS, "copper-plate", 50)
		local m = remote.call(IO, "step", ib)
		local ccu = counts(invi, COPPER_SLOTS)
		local lo, hi = math.huge, 0
		for _, n in ipairs(ccu) do
			if n < lo then lo = n end
			if n > hi then hi = n end
		end
		expect(m > 0 and m < 150 and lo > 0 and hi - lo <= 1 and lo + hi > 0,
			"import bus: moved " .. tostring(m) .. ", the stacks are " .. line(ccu) .. " (want them within one of each other)")

		remote.call(SB, "set_take_evenly", false)
		st.phase, st.next = 2, game.tick + 5
	end

	function T.running(check) check(storage.evenly and storage.evenly.done, "buses take evenly") end

	return T
end
