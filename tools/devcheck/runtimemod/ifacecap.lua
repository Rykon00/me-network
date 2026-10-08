--- Runtime test of me-network issue #196 (option b): the ME Interface Capacity Card. An ME Interface has 9 config rows and 3 card
--- slots that take only that card (the storage and the Pattern Capacity Card are refused); each card gives 9 more rows (18, 27,
--- 36). A row above the capacity is refused without a card; the rows a card gave are kept (not lost) when it is taken out and work
--- again when a card is put back; a settings paste, a clone, a blueprint's tag and the recipe paste's row count follow the cards;
--- mined, the cards come with the interface.
--- Loaded by control.lua: require("ifacecap")(H) returns { setup, tick, running }.

local NET, IO, GUI = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-gui"
local BX, BY = 10, -460
local START = 150
local CARD = "me-interface-capacity-card"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "interface capacity"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 10.5, BY - 0.5)
		H.cable_row(s, fails, BX + 11, BX + 20, BY - 1)
		for _, x in ipairs({ 11.5, 13.5, 15.5 }) do me_place(s, fails, what, "me-network-interface", BX + x, BY + 0.5) end
		H.me_connect(fails, what, { ctrl, drive, term })
		return fails
	end

	function T.tick()
		local st = storage.ifacecap196
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.ifacecap196 = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[1]
		local function find(x, y) return s.find_entity("me-network-interface", { BX + x, BY + y }) end
		local t = s.find_entity("me-terminal", { BX + 10.5, BY - 0.5 })
		local a, b, c = find(11.5, 0.5), find(13.5, 0.5), find(15.5, 0.5)
		if not (t and a and b and c) then return me_report("IFACECAP", "ME Interface Capacity Card", { "entities missing" }) end
		local function data(e) return remote.call(IO, "get_interface", e) or {} end
		local inv = game.create_inventory(8)
		local hand = inv[1]
		local back = game.create_inventory(20)
		local function count(name) return remote.call(NET, "count", t, name) end
		local function put(e, name, slot)
			hand.set_stack{ name = name, count = 1 }
			local why = remote.call(IO, "interface_card_click", e, slot or 1, hand, back, false)
			if hand.valid_for_read then hand.clear() end
			return why
		end
		local function take(e, slot) return remote.call(IO, "interface_card_click", e, slot, hand, back, true) end
		local function row(e, i) return remote.call(IO, "set_interface_slot", e, i, "iron-plate", "normal", 10 + i) end

		--- no cards (an old save): 9 rows, 3 empty card slots; a tenth row is refused
		local d0 = data(a)
		expect(d0.slots == 9 and d0.card_slots == 3 and not d0.kept, "no cards: " .. serpent.line({ d0.slots, d0.card_slots }))
		local plates = { "iron-plate", "copper-plate", "stone", "coal", "iron-gear-wheel", "copper-cable", "steel-plate", "wood", "iron-stick",
			"stone-brick", "pipe", "electronic-circuit", "iron-chest", "firearm-magazine", "small-electric-pole", "landfill", "sulfur", "plastic-bar" }
		for i = 1, 9 do expect(remote.call(IO, "set_interface_slot", a, i, plates[i], "normal", 5), "row " .. i) end
		expect(remote.call(IO, "set_interface_slot", a, 10, plates[10], "normal", 5) == false, "a tenth row without a card is refused")

		--- the card: only the Interface Capacity Card fits
		expect(put(a, "me-capacity-card") == "not-here", "the storage Capacity Card is refused")
		expect(put(a, "me-pattern-capacity-card") == "not-here", "the Pattern Capacity Card is refused")
		expect(put(a, CARD, 1) == nil and data(a).slots == 18, "one card: " .. data(a).slots)
		expect(remote.call(IO, "set_interface_slot", a, 10, plates[10], "normal", 5) and data(a).config[10], "row 10 with a card")
		expect(put(a, CARD, 2) == nil and put(a, CARD, 3) == nil and data(a).slots == 36, "three cards: " .. data(a).slots)
		local fourth = put(a, CARD)
		expect(fourth == "limit" or fourth == "full", "a fourth card is refused: " .. tostring(fourth))
		expect(remote.call(IO, "set_interface_slot", a, 36, plates[18], "normal", 5) and data(a).config[36], "row 36")
		expect(remote.call(IO, "row_capacity", a) == 36, "the capacity for the recipe paste: " .. tostring(remote.call(IO, "row_capacity", a)))

		--- the rows a card gave are kept when it is taken out, and work again when it is put back
		expect(take(a, 3) == nil and take(a, 2) == nil and data(a).slots == 18, "two cards out: " .. data(a).slots)
		local after = data(a)
		expect(after.kept and after.slots == 18 and after.config[36], "row 36 is kept aside, not shown: " .. serpent.line({ after.kept, after.slots }))
		expect(remote.call(IO, "get_interface_config", a)[36] ~= nil, "the config of the blueprint and the paste still has row 36")
		expect(put(a, CARD, 2) == nil and put(a, CARD, 3) == nil and data(a).config[36] and not data(a).kept,
			"the cards back, row 36 is active again")

		--- a settings paste from an interface with cards onto a bare one: the cards come from the network, and the rows
		remote.call(NET, "insert", t, CARD, 10)
		local before = count(CARD)
		remote.call(IO, "paste", a, b)
		expect(data(b).slots == 36 and count(CARD) == before - 3 and data(b).config[36], "paste: " .. data(b).slots .. " rows, network "
			.. before .. " -> " .. count(CARD))
		--- a clone wants the source's cards too
		remote.call(IO, "built", c, nil, a)
		expect(data(c).slots == 36 and data(c).config[36], "a clone: " .. data(c).slots .. " rows, network " .. count(CARD))

		--- issue #201: a stack of cards in the hand-over buffer (the interface takes three, the rest stays) is not pushed into a card
		--- slot again when the player takes a card out of it; a new stack is tried
		do
			local buf = game.create_inventory(4)
			local slots = remote.call(IO, "interface_inventory", b)
			for i = 1, #slots do slots[i].clear() end
			remote.call(IO, "interface_sync", b, back)
			buf[1].set_stack{ name = CARD, count = 5 }
			local took, seen = remote.call(GUI, "buffer_absorb", buf, "interface", b)
			expect(buf[1].valid_for_read and buf[1].count == 2 and data(b).slots == 36, "buffer: three cards went in, two stay: "
				.. tostring(buf[1].valid_for_read and buf[1].count) .. ", " .. data(b).slots .. " rows")
			expect(remote.call(IO, "interface_card_click", b, 1, hand, back, true) == nil and data(b).slots == 27, "a card out of the slot")
			local _, seen2 = remote.call(GUI, "buffer_absorb", buf, "interface", b, seen)
			expect(buf[1].count == 2 and data(b).slots == 27, "the stack that stayed is not put in again: " .. buf[1].count .. " in the buffer, "
				.. data(b).slots .. " rows")
			buf[2].set_stack{ name = CARD, count = 1 }                       -- a new stack is tried
			remote.call(GUI, "buffer_absorb", buf, "interface", b, seen2)
			expect(not buf[2].valid_for_read and data(b).slots == 36, "a new stack is tried: " .. data(b).slots .. " rows")
			buf.destroy()
		end

		--- mined: the cards come with the interface
		local buffer = game.create_inventory(20)
		remote.call(IO, "removed", a, buffer)
		expect(buffer.get_item_count(CARD) == 3, "mined: " .. buffer.get_item_count(CARD) .. " cards")
		buffer.destroy()

		inv.destroy()
		back.destroy()
		me_report("IFACECAP", "ME Interface Capacity Card", problems,
			"9 rows, 18, 27, 36 with the card, only that card fits, a row above the capacity refused, rows kept when a card is out, paste, clone, mined")
	end

	function T.running(check) check(storage.ifacecap196 and storage.ifacecap196.done, "ME Interface Capacity Card") end

	return T
end
