--- Runtime test of me-network issue #156: the ME Pattern Capacity Card. A provider has 9 pattern slots and 3 card slots that
--- take only that card (the storage Capacity Card is refused); each card gives 9 more slots (18, 27, 36), a 10th pattern
--- without a card is refused; a card cannot be taken out while a pattern sits in a slot it gives; a provider that loses
--- a card another way (settings paste of one with fewer) puts those patterns on the ground, never loses them; mined, the
--- patterns and the cards come with it; a blueprint's tag and a clone want the cards from the network; a provider that never
--- had a card has 9 slots (an old save).
--- Loaded by control.lua: require("patterncap")(H) returns { setup, tick, running }.

local NET, AC, PT = "gregtorio-me-network", "gregtorio-me-autocraft", "gregtorio-me-pattern-terminal"
local BX, BY = 10, -420
local START = 150
local CARD = "me-pattern-capacity-card"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "pattern capacity"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 10.5, BY - 0.5)
		H.cable_row(s, fails, BX + 11, BX + 20, BY - 1)
		for _, x in ipairs({ 11.5, 13.5, 15.5 }) do me_place(s, fails, what, "me-pattern-provider", BX + x, BY + 0.5) end
		H.me_connect(fails, what, { ctrl, drive, term })
		return fails
	end

	function T.tick()
		local st = storage.patterncap156
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.patterncap156 = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local t = find("me-terminal", 10.5, -0.5)
		local a, b, c = find("me-pattern-provider", 11.5, 0.5), find("me-pattern-provider", 13.5, 0.5), find("me-pattern-provider", 15.5, 0.5)
		if not (t and a and b and c) then return me_report("PATTERNCAP", "ME Pattern Capacity Card", { "entities missing" }) end
		local function pinfo(e) return remote.call(AC, "provider_info", e) or {} end
		local inv = game.create_inventory(8)
		local hand = inv[1]
		local back = game.create_inventory(20)
		local function count(name) return remote.call(NET, "count", t, name) end
		local function ground() return #s.find_entities_filtered{ name = "item-on-ground", position = { BX + 13, BY }, radius = 30 } end
		--- a card from the hand into the next free card slot
		local function put(e, name, slot)
			hand.set_stack{ name = name, count = 1 }
			local why = remote.call(AC, "provider_card_click", e, slot or 1, hand, back, false)
			if hand.valid_for_read then hand.clear() end
			return why
		end
		--- a card out of slot `slot` into `back`
		local function take(e, slot) return remote.call(AC, "provider_card_click", e, slot, hand, back, true) end
		--- an encoded pattern (a different one each time), put into provider `e`
		local n = 0
		local function pattern(e, slot)
			n = n + 1
			local tmp = game.create_inventory(2)
			tmp.insert{ name = "me-blank-pattern", count = 1 }
			remote.call(PT, "encode_def", tmp, nil, { kind = "processing", inputs = { { key = "stone", amount = n } },
				outputs = { { key = "pipe", amount = 1 } } })
			local stack = tmp.find_item_stack("me-encoded-pattern")
			local got, why = remote.call(AC, "insert_pattern", e, stack, slot)
			tmp.destroy()
			return got, why
		end

		--- a provider without cards (an old save): 9 slots, 3 empty card slots
		local i0 = pinfo(a)
		expect(i0.slot_count == 9 and i0.card_slots == 3 and i0.filled == 0, "no cards: " .. serpent.line({ i0.slot_count, i0.card_slots, i0.filled }))
		for i = 1, 9 do expect(pattern(a) == i, "pattern " .. i) end
		local got, why = pattern(a)
		expect(got == nil and why == "provider-full", "a 10th pattern: " .. serpent.line({ got, why }))
		expect(pinfo(a).filled == 9, "nine filled")

		--- the card: only the Pattern Capacity Card fits
		expect(put(a, "me-capacity-card") == "not-here", "the storage Capacity Card is refused: " .. tostring(put(a, "me-capacity-card")))
		expect(put(a, CARD, 1) == nil and pinfo(a).slot_count == 18, "one card: " .. pinfo(a).slot_count)
		expect(pattern(a) == 10, "the 10th pattern goes in")
		expect(put(a, CARD, 2) == nil and put(a, CARD, 3) == nil and pinfo(a).slot_count == 36, "three cards: " .. pinfo(a).slot_count)
		expect(put(a, CARD) == "limit" or put(a, CARD) == "full", "a fourth card is refused: " .. tostring(put(a, CARD)))
		for i = 11, 36 do expect(pattern(a) == i, "pattern " .. i) end
		got, why = pattern(a)
		expect(got == nil and why == "provider-full" and pinfo(a).filled == 36, "full at 36: " .. serpent.line({ got, why }))

		--- a card cannot be taken out while a pattern sits in a slot it gives; the patterns of the scan are all there
		expect(take(a, 3) == "patterns-above", "the click is refused: " .. tostring(take(a, 3)))
		expect(pinfo(a).slot_count == 36 and remote.call(AC, "provider_inventory", a)[3].valid_for_read, "the card stayed")
		--- take the patterns of slots 28..36 out, then the card goes
		for slot = 28, 36 do
			expect(remote.call(AC, "take_pattern", a, slot, back), "take pattern " .. slot)
		end
		expect(take(a, 3) == nil and pinfo(a).slot_count == 27 and back.get_item_count(CARD) == 1, "the card went out: " .. pinfo(a).slot_count)
		expect(pinfo(a).filled == 27, "27 patterns stay: " .. pinfo(a).filled)

		--- a paste from a provider with fewer cards: the patterns above the new size are put on the ground, not lost
		local before_ground, before_patterns = ground(), pinfo(a).filled
		remote.call(AC, "paste", b, a)                       -- b has no cards: a wants none
		local ia = pinfo(a)
		expect(ia.slot_count == 9, "after the paste: " .. ia.slot_count .. " slots")
		expect(ia.filled == 9 and ground() - before_ground >= before_patterns - 9 - 1,
			"the patterns above went to the ground: " .. ia.filled .. " left, ground " .. before_ground .. " -> " .. ground())

		--- a blueprint's tag and a clone want the cards from the network (never from nothing)
		remote.call(NET, "insert", t, CARD, 5)
		local before = count(CARD)
		remote.call(AC, "built", b, { fork_me_provider = { priority = 0, patterns = {}, cards = { CARD, CARD } } })
		local ib = pinfo(b)
		expect(ib.slot_count == 27 and count(CARD) == before - 2, "a tag with two cards: " .. ib.slot_count .. " slots, network " .. before .. " -> " .. count(CARD))
		remote.call(AC, "built", c, nil, b)
		expect(pinfo(c).slot_count == 27, "a clone: " .. pinfo(c).slot_count .. " slots, network " .. count(CARD))

		--- the settings of a provider carry its cards
		local settings = remote.call(AC, "provider_settings", b)
		expect(type(settings.cards) == "table" and #settings.cards == 2, "the blueprint settings hold the cards: " .. serpent.line(settings.cards))

		--- mined: patterns and cards come with the provider (into the buffer)
		pattern(b, 20)
		local buffer = game.create_inventory(60)
		remote.call(AC, "on_removed", b, buffer)
		expect(buffer.get_item_count(CARD) == 2 and buffer.get_item_count("me-encoded-pattern") >= 1,
			"mined: " .. buffer.get_item_count(CARD) .. " cards, " .. buffer.get_item_count("me-encoded-pattern") .. " patterns")
		buffer.destroy()

		inv.destroy()
		back.destroy()
		me_report("PATTERNCAP", "ME Pattern Capacity Card", problems,
			"9 slots, 18, 27, 36 with the card, only that card fits, a card stays while a pattern is in its slots, a paste puts patterns on the ground, tag, clone, mined")
	end

	function T.running(check) check(storage.patterncap156 and storage.patterncap156.done, "ME Pattern Capacity Card") end

	return T
end
