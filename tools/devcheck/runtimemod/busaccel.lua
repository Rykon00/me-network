--- Runtime test of me-network issue #110, part 2 (docs/AE2.md "Acceleration Card"): the card slots of an ME Import Bus and an ME Export
--- Bus. Up to 4 Acceleration Cards multiply the items per second a bus moves (the map setting "Bus speed") by 1, 8, 32, 64, 96.
--- * The slots take the Acceleration Card only (a fifth card, a Capacity Card and a Fuzzy Card are refused with their reason).
--- * An export bus into an empty chest moves, in one visit, 64, 512, 2048, 4096 items with 0 to 3 cards and more with the fourth
---   (the chest's limit: 4800 plates, 3072 where plates stack to 64); an import bus the same out of a full chest.
--- * A mined bus gives its cards to the buffer, a destroyed one drops them; a paste, a clone and a blueprint's tag make a bus want
---   the cards (it takes them from the network).
--- Loaded by control.lua: require("busaccel")(H) returns { setup, tick, running } like margin.lua.

local NET, IO = "gregtorio-me-network", "gregtorio-me-io"
local BX, BY = 440, 40         -- (land: a spill at a block in a lake lands where there is some)
local START = 100
local CARD = "me-acceleration-card"
local FACTORS = { 1, 8, 32, 64, 96 }
local STEP = 64             -- items one visit may move at the default bus speed: 256 per second, a visit of 15 ticks
local CHEST = 48 * prototypes.item["iron-plate"].stack_size    -- what a steel chest holds of plates (4800; 3072 where plates stack to 64)

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	function T.setup(s)
		local fails = {}
		local what = "bus cards"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 30000, [CARD] = 12 })
		local members = { ctrl, drive }
		local function bus(name, x, chest)
			local b = me_place(s, fails, what, name, BX + x, BY + 0.5, SOUTH)
			me_place(s, fails, what, chest, BX + x, BY + 1.5)
			members[#members + 1] = b
			return b
		end
		bus("me-export-bus", 10.5, "steel-chest")       -- E
		bus("me-import-bus", 12.5, "steel-chest")       -- I
		bus("me-export-bus", 14.5, "steel-chest")       -- E2: the paste
		bus("me-export-bus", 16.5, "steel-chest")       -- E3: the clone
		bus("me-export-bus", 18.5, "steel-chest")       -- E4: the blueprint's tag
		bus("me-export-bus", 20.5, "steel-chest")       -- M: mined
		bus("me-export-bus", 22.5, "steel-chest")       -- D: destroyed
		for x = 9.5, 22.5 do me_place(s, fails, what, "me-cable", BX + x, BY - 0.5) end
		me_connect(fails, what, members)
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.busaccel110
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false }
			storage.busaccel110 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local ctrl = find("me-network-controller", 7, 0)
		local E, I, E2, E3, E4, M, D = find("me-export-bus", 10.5, 0.5), find("me-import-bus", 12.5, 0.5), find("me-export-bus", 14.5, 0.5),
			find("me-export-bus", 16.5, 0.5), find("me-export-bus", 18.5, 0.5), find("me-export-bus", 20.5, 0.5), find("me-export-bus", 22.5, 0.5)
		local CE, CI = find("steel-chest", 10.5, 1.5), find("steel-chest", 12.5, 1.5)
		for _, e in pairs({ ctrl, E, I, E2, E3, E4, M, D, CE, CI }) do
			if not (e and e.valid) then
				problems[#problems + 1] = "the test network was not built"
				st.done = true
				return me_report("BUSACCEL", "ME bus acceleration cards", problems, "no network")
			end
		end
		local function count(name) return remote.call(NET, "count", ctrl, name) end
		local inv = game.create_inventory(4)
		local hand = inv[1]
		local function put(bus, name)
			hand.set_stack{ name = name, count = 1 }
			local why = remote.call(IO, "bus_card_click", bus, 1, hand, inv, false)
			if hand.valid_for_read then hand.clear() end
			return why
		end
		local function info(bus) return remote.call(IO, "bus_info", bus) end
		local function cards_of(bus)
			local n = 0
			for _ in pairs(info(bus).cards) do n = n + 1 end
			return n
		end
		local function take_all(bus)
			for slot = 1, 4 do
				hand.clear()
				remote.call(IO, "bus_card_click", bus, slot, hand, inv, false)
				if hand.valid_for_read then hand.clear() end
			end
		end
		expect(count(CARD) >= 12, "the network has " .. count(CARD) .. " Acceleration Cards, not 12")

		--- the slots and what they take
		expect(info(E).slots == 4 and info(E).accel == 1, "an export bus: " .. serpent.line({ info(E).slots, info(E).accel }))
		expect(put(E, "me-capacity-card") == "not-here" and put(E, "me-fuzzy-card") == "not-here" and put(E, "iron-plate") == "not-here",
			"a card the bus does not take was not refused as not-here")
		for n = 1, 4 do
			expect(put(E, CARD) == nil, "card " .. n .. " was refused")
			local d = info(E)
			expect(d.accel == FACTORS[n + 1] and d.rate == 256 * FACTORS[n + 1], n .. " cards: the factor is " .. tostring(d.accel) .. " (rate " .. tostring(d.rate) .. "), not " .. FACTORS[n + 1])
		end
		expect(put(E, CARD) == "limit", "a fifth card was not refused as limit")
		take_all(E)
		expect(cards_of(E) == 0 and info(E).accel == 1, "the cards taken out: " .. cards_of(E) .. " left, factor " .. info(E).accel)

		--- the export bus: items moved by one visit into the empty chest
		remote.call(IO, "set_bus_filters", E, { "iron-plate" })
		local ce = CE.get_inventory(defines.inventory.chest)
		local moved = {}
		for n = 0, 4 do
			if n > 0 then expect(put(E, CARD) == nil, "export bus: card " .. n .. " was refused") end
			ce.clear()
			moved[n] = remote.call(IO, "step", E)
		end
		for n = 0, 4 do
			local want = math.min(STEP * FACTORS[n + 1], CHEST)
			expect(moved[n] == want, "export bus with " .. n .. " cards moved " .. moved[n] .. " items in a visit, not " .. want)
		end
		expect(moved[3] > moved[2] and moved[2] > moved[1] and moved[1] > moved[0], "the export bus does not move more with every card")
		take_all(E)

		--- the import bus: items taken from a full chest by one visit
		local ci = CI.get_inventory(defines.inventory.chest)
		local got = {}
		for n = 0, 3 do
			if n > 0 then expect(put(I, CARD) == nil, "import bus: card " .. n .. " was refused") end
			ci.clear()
			for slot = 1, 48 do ci[slot].set_stack{ name = "iron-plate", count = CHEST / 48 } end
			local before = count("iron-plate")
			local m = remote.call(IO, "step", I)
			got[n] = { m = m, net = count("iron-plate") - before }
			local want = math.min(STEP * FACTORS[n + 1], CHEST)
			expect(m == want and got[n].net == m, "import bus with " .. n .. " cards moved " .. m .. " (the network +" .. got[n].net .. "), not " .. want)
		end
		take_all(I)

		--- a mined bus gives its cards to the buffer, a destroyed one drops them
		put(M, CARD) put(M, CARD)
		local buffer = game.create_inventory(2)
		remote.call(IO, "removed", M, buffer)
		expect(buffer.get_item_count(CARD) == 2, "a mined bus gave " .. buffer.get_item_count(CARD) .. " cards to the buffer, not 2")
		buffer.destroy()
		expect(put(D, CARD) == nil and cards_of(D) == 1, "the card did not go into the bus that is destroyed next: " .. cards_of(D))
		local function cards_on_ground()
			local n = 0
			for _, e in pairs(s.find_entities_filtered{ name = "item-on-ground", area = { { D.position.x - 8, D.position.y - 8 }, { D.position.x + 8, D.position.y + 8 } } }) do
				if e.stack.valid_for_read and e.stack.name == CARD then n = n + e.stack.count end
			end
			return n
		end
		local ground_before = cards_on_ground()
		remote.call(IO, "removed", D)
		local ground = cards_on_ground()
		expect(ground == ground_before + 1, "a destroyed bus dropped " .. (ground - ground_before) .. " cards, not 1")

		--- a paste, a clone and a blueprint's tag: the bus wants the cards and takes them from the network at its next visit
		put(E, CARD) put(E, CARD)
		remote.call(IO, "paste", E, E2)
		remote.call(IO, "step", E2)
		expect(cards_of(E2) == 2 and info(E2).accel == 32, "the pasted bus has " .. cards_of(E2) .. " cards (factor " .. info(E2).accel .. "), not 2 (32)")
		remote.call(IO, "built", E3, nil, E)
		remote.call(IO, "step", E3)
		expect(cards_of(E3) == 2 and info(E3).accel == 32, "the cloned bus has " .. cards_of(E3) .. " cards (factor " .. info(E3).accel .. "), not 2 (32)")
		remote.call(IO, "built", E4, { fork_me_bus = { filters = { "iron-plate" }, cards = { CARD, CARD, CARD } } }, nil)
		remote.call(IO, "step", E4)
		expect(cards_of(E4) == 3 and info(E4).accel == 64, "the bus built from a blueprint has " .. cards_of(E4) .. " cards (factor " .. info(E4).accel .. "), not 3 (64)")
		--- what a bus has beyond the paste is given back
		remote.call(IO, "paste", E4, E3)
		remote.call(IO, "step", E3)
		expect(cards_of(E3) == 3, "a second paste left the bus with " .. cards_of(E3) .. " cards, not 3")

		--- a mod update (on_configuration_changed) makes the records anew: the cards and the factor stay
		local before = { cards_of(E4), info(E4).accel, cards_of(E3) }
		remote.call(IO, "configuration_changed")
		expect(cards_of(E4) == before[1] and info(E4).accel == before[2] and cards_of(E3) == before[3] and remote.call(IO, "bus_inventory", E4).get_item_count(CARD) == 3,
			"after a mod update the bus has " .. cards_of(E4) .. " cards (factor " .. info(E4).accel .. "), not " .. before[1] .. " (" .. before[2] .. ")")
		expect(remote.call(IO, "step", E4) >= 0 and info(E4).accel == 64, "the bus does not work after the update")

		inv.destroy()
		st.done = true
		me_report("BUSACCEL", "ME bus acceleration cards", problems, "four slots that take only the card, factors " .. table.concat(FACTORS, ", ") .. " (a visit moves "
			.. moved[0] .. ", " .. moved[1] .. ", " .. moved[2] .. ", " .. moved[3] .. ", " .. moved[4] .. " into a chest), the import bus alike, mined into the buffer, destroyed onto the ground, "
			.. "paste, clone and blueprint tag, kept over a mod update")
	end

	function T.running(check) check(storage.busaccel110 and storage.busaccel110.done, "ME bus acceleration cards") end
	return T
end
