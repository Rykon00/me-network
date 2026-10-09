--- Runtime test of me-network issue #193: the Sticky Card (AE2-Unofficial's). A storage bus on a chest (priority 0) and a cell in
--- a drive of priority -5, each with a Sticky Card, get an item they hold before a drive of priority 10; an item they do not hold
--- goes by priority as before; a full sticky storage stops the insert (AE2: the rest is not stored elsewhere); without the card
--- the priority decides again.
--- Loaded by control.lua: require("sticky")(H) returns { setup, tick, running }.

local NET, SB = "gregtorio-me-network", "gregtorio-me-storagebus"
local BX, BY = 100, -420
local START = 170
local SOUTH = { direction = defines.direction.south }
local CARD = "me-sticky-card"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "sticky card"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local high = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k")          -- priority 10: the plain storage
		local term = me_place(s, fails, what, "me-terminal", BX + 10.5, BY - 0.5)
		H.cable_row(s, fails, BX + 11, BX + 20, BY - 1)
		me_place(s, fails, what, "me-storage-bus", BX + 12.5, BY + 0.5, SOUTH)
		me_place(s, fails, what, "iron-chest", BX + 12.5, BY + 1.5)
		me_place(s, fails, what, "me-drive", BX + 14.5, BY + 0.5)                       -- priority -5: the sticky cell
		H.me_connect(fails, what, { ctrl, high, term })
		return fails
	end

	function T.tick()
		local st = storage.sticky193
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.sticky193 = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local t, high = find("me-terminal", 10.5, -0.5), find("me-drive", 8.5, -0.5)
		local bus, chest, low = find("me-storage-bus", 12.5, 0.5), find("iron-chest", 12.5, 1.5), find("me-drive", 14.5, 0.5)
		if not (t and high and bus and chest and low) then return me_report("STICKY", "ME Sticky Card", { "entities missing" }) end
		local function count_in_drive(drive, key)
			local n = 0
			for _, c in pairs(remote.call(NET, "drive", drive)) do n = n + (c.items[key] or 0) end
			return n
		end
		remote.call(NET, "set_priority", high, 10)
		remote.call(NET, "set_priority", low, -5)
		remote.call(SB, "set_settings", bus, { priority = 0 })
		--- the chest holds iron, the sticky cell holds stone
		chest.insert{ name = "iron-plate", count = 10 }
		remote.call(SB, "visit", bus)
		local inv = game.create_inventory(4)
		inv[1].set_stack{ name = "me-1k-storage-cell", count = 1, tags = { fork_me_cell = { items = { stone = 10 }, data = {}, cards = { CARD } } } }
		expect(remote.call(NET, "insert_cell", low, inv[1], 1) == 1, "the sticky cell into the low drive")
		--- without the card on the bus: iron goes by priority into the high drive
		local before = count_in_drive(high, "iron-plate")
		remote.call(NET, "insert", t, "iron-plate", 5)
		expect(count_in_drive(high, "iron-plate") == before + 5 and chest.get_item_count("iron-plate") == 10,
			"no card: iron by priority, chest " .. chest.get_item_count("iron-plate"))
		--- the card on the bus: iron goes into the chest first
		inv[2].set_stack{ name = CARD, count = 1 }
		expect(remote.call(SB, "card_click", bus, 1, inv[2], inv, false) == nil, "the card into the bus")
		remote.call(NET, "insert", t, "iron-plate", 7)
		expect(chest.get_item_count("iron-plate") == 17, "sticky bus: iron into the chest, chest " .. chest.get_item_count("iron-plate"))
		--- copper: no sticky storage holds it, the priority decides
		local cu = count_in_drive(high, "copper-plate")
		remote.call(NET, "insert", t, "copper-plate", 4)
		expect(count_in_drive(high, "copper-plate") == cu + 4 and chest.get_item_count("copper-plate") == 0, "copper by priority")
		--- stone: the sticky cell of priority -5 gets it before the high drive
		remote.call(NET, "insert", t, "stone", 6)
		expect(count_in_drive(low, "stone") == 16 and count_in_drive(high, "stone") == 0,
			"the sticky cell takes stone: low " .. count_in_drive(low, "stone") .. ", high " .. count_in_drive(high, "stone"))
		--- the chest full of iron: the insert stops there (AE2), nothing goes to the high drive
		local room = 0
		for _ = 1, 64 do room = room + chest.insert{ name = "iron-plate", count = 100000 } if room == 0 then break end end
		remote.call(SB, "visit", bus)
		local h0 = count_in_drive(high, "iron-plate")
		local got = remote.call(NET, "insert", t, "iron-plate", 20)
		expect(got == 0 and count_in_drive(high, "iron-plate") == h0, "a full sticky bus stops the insert: " .. tostring(got))
		--- the card out again: the priority decides
		inv[2].clear()
		expect(remote.call(SB, "card_click", bus, 1, inv[2], inv, false) == nil and inv[2].valid_for_read, "the card out of the bus")
		got = remote.call(NET, "insert", t, "iron-plate", 20)
		expect(got == 20 and count_in_drive(high, "iron-plate") == h0 + 20, "without the card iron goes to the high drive: " .. tostring(got))
		inv.destroy()
		me_report("STICKY", "ME Sticky Card", problems, "bus and cell before the priority for what they hold, other items by priority, full stops, card out")
	end

	function T.running(check) check(storage.sticky193 and storage.sticky193.done, "ME Sticky Card") end

	return T
end
