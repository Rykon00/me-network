--- Runtime test of me-network issue #17, part 3 (docs/ME-REWORK.md "The ME Cell Workbench"): the ME Cell Workbench
--- (its cell slot, partition buttons, card slots, From contents, Clear, the copy mode; mined, destroyed and vanished
--- with a cell) and the cards on item and fluid cells in a drive (inverter, fuzzy, equal distribution, overflow
--- destruction). Loaded by control.lua: require("workbench")(H) returns { setup, tick, running } like cards.lua.

local NET, GUI = "gregtorio-me-network", "gregtorio-me-gui"
local WB = "gregtorio-me-workbench"
local WX, WY = 200, -300
local CARD = {
	void = "me-overflow-destruction-card", fuzzy = "me-fuzzy-card", inverter = "me-inverter-card",
	equal = "me-equal-distribution-card", capacity = "me-capacity-card",
}

return function(H)
	local me_place, cable_row, power, me_report = H.me_place, H.cable_row, H.power, H.me_report
	local T = {}
	local function line(t) return serpent.line(t) end

	function T.setup(s)
		local fails = {}
		local what = "workbench"
		power(s, fails, what, WX, WY)
		me_place(s, fails, what, "me-network-controller", WX + 7, WY)
		me_place(s, fails, what, "me-drive", WX + 8.5, WY - 0.5)          -- DT: the cell under test, priority 10
		me_place(s, fails, what, "me-drive", WX + 9.5, WY - 0.5)          -- DB: the backstop, an item and a fluid cell
		me_place(s, fails, what, "me-terminal", WX + 10.5, WY - 0.5)
		me_place(s, fails, what, "me-cell-workbench", WX + 14.5, WY + 4.5)   -- no cable: it needs no network
		me_place(s, fails, what, "me-cell-workbench", WX + 16.5, WY + 4.5)   -- mined
		me_place(s, fails, what, "me-cell-workbench", WX + 18.5, WY + 4.5)   -- destroyed
		me_place(s, fails, what, "me-cell-workbench", WX + 20.5, WY + 4.5)   -- vanished
		return fails
	end

	local function workbench_test()
		local st = storage.wb17
		if (st and st.done) or game.tick < 90 then return end
		st = { problems = {}, done = true }
		storage.wb17 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { WX + x, WY + y }) end
		local dt, db, t = find("me-drive", 8.5, -0.5), find("me-drive", 9.5, -0.5), find("me-terminal", 10.5, -0.5)
		local wb, wm, wd, wv = find("me-cell-workbench", 14.5, 4.5), find("me-cell-workbench", 16.5, 4.5),
			find("me-cell-workbench", 18.5, 4.5), find("me-cell-workbench", 20.5, 4.5)
		if not (dt and db and t and wb and wm and wd and wv) then
			return me_report("WORKBENCH", "ME Cell Workbench", { "entities missing" })
		end
		local inv = game.create_inventory(10)
		local hand = inv[1]
		local function info(w) return remote.call(WB, "info", w) or {} end
		local function count(name, q) return remote.call(NET, "count", t, name, q) end
		local function card(w, name, slot)
			hand.set_stack{ name = name, count = 1 }
			local why = remote.call(WB, "card_click", w, slot or 1, hand, inv, false)
			if hand.valid_for_read then hand.clear() end
			return why
		end
		local function put_cell(w, name)
			hand.set_stack{ name = name, count = 1 }
			return remote.call(WB, "cell_click", w, hand, inv, false)
		end
		--- the cell of workbench `w` into the hand (and the hand's tags)
		local function take_cell(w)
			hand.clear()
			remote.call(WB, "cell_click", w, hand, inv, false)
			return hand.valid_for_read and hand.is_item_with_tags and hand.tags or nil
		end
		local function in_cell(drive, slot, key)
			local c = remote.call(NET, "drive", drive)[slot]
			return c and (c.items[key] or 0) or -1
		end
		--- the cell in the hand into slot 1 of DT (the drive under test), its old cell out first
		local function into_dt()
			local old = remote.call(NET, "drive", dt)[1]
			if old then
				local spare = game.create_inventory(1)
				remote.call(NET, "take_cell", dt, 1, spare)
				spare.destroy()
			end
			return remote.call(NET, "insert_cell", dt, hand, 1)
		end

		--- the backstop: an item and a fluid cell at priority 0; DT at priority 10
		local cells = game.create_inventory(2)
		cells[1].set_stack{ name = "me-16k-storage-cell", count = 1 }
		cells[2].set_stack{ name = "me-16k-fluid-storage-cell", count = 1 }
		remote.call(NET, "insert_cell", db, cells[1], 1)
		remote.call(NET, "insert_cell", db, cells[2], 2)
		cells.destroy()
		remote.call(NET, "set_priority", dt, 10)

		--- an empty workbench; a cell in; partition buttons; cards and their limits
		local i0 = info(wb)
		expect(i0.cell == nil and i0.keep == false, "empty workbench " .. line(i0))
		expect(put_cell(wb, "me-1k-storage-cell") == nil and info(wb).cell and info(wb).cell.slots == 4, "item cell in the workbench")
		remote.call(WB, "set_partition_slot", wb, 1, "iron-plate")
		remote.call(WB, "set_partition_slot", wb, 2, "copper-plate")
		expect(line(info(wb).cell.partition) == line({ "copper-plate", "iron-plate" }), "partition " .. line(info(wb).cell.partition))
		expect(card(wb, CARD.inverter) == nil and info(wb).cell.inverted, "inverter card on an item cell")
		expect(card(wb, CARD.inverter) == "limit", "a second inverter card")
		expect(card(wb, CARD.capacity) == "not-here", "a capacity card on a cell")
		expect(card(wb, CARD.fuzzy) == nil and card(wb, CARD.equal) == nil and card(wb, CARD.void) == nil, "fuzzy, equal, void cards")
		expect(card(wb, CARD.fuzzy) == "limit" or card(wb, CARD.fuzzy) == "full", "a fifth card")
		--- a card taken out by hand
		hand.clear()
		remote.call(WB, "card_click", wb, 4, hand, inv, false)
		expect(hand.valid_for_read and hand.name == CARD.void and not info(wb).cell.void, "card taken out: " .. line(hand.valid_for_read and hand.name))
		hand.clear()
		--- the cell taken out carries its partition and cards in its tags
		local tags = take_cell(wb)
		local ct = tags and tags.fork_me_cell
		expect(ct and ct.partition and ct.partition["copper-plate"] and ct.partition["iron-plate"] and #ct.cards == 3, "cell tags " .. line(ct))
		expect(info(wb).cell == nil and #info(wb).config == 0, "workbench after the cell left (no copy mode) " .. line(info(wb)))
		--- From contents and Clear (a cell with items, from a drive)
		local store = game.create_inventory(4)
		store[1].set_stack{ name = "me-1k-storage-cell", count = 1 }
		remote.call(NET, "insert_cell", dt, store[1], 2)                 -- (DT is empty yet: the gears go into this cell)
		remote.call(NET, "store_in_drive", dt, "iron-gear-wheel", 5)
		remote.call(NET, "take_cell", dt, 2, store)
		local full = store.find_item_stack("me-1k-storage-cell")
		hand.clear()
		hand.transfer_stack(full)
		remote.call(WB, "cell_click", wb, hand, inv, false)
		remote.call(WB, "from_contents", wb)
		expect(line(info(wb).cell.partition) == line({ "iron-gear-wheel" }) and info(wb).cell.items["iron-gear-wheel"] == 5,
			"from contents " .. line(info(wb).cell))
		remote.call(WB, "clear", wb)
		expect(#info(wb).cell.partition == 0 and info(wb).cell.items["iron-gear-wheel"] == 5, "clear keeps the items " .. line(info(wb).cell))
		--- the copy mode: the partition stays and goes onto the next cell whose partition is empty
		remote.call(WB, "set_partition_slot", wb, 1, "stone")
		remote.call(WB, "set_keep", wb, true)
		take_cell(wb)
		local gear_cell = game.create_inventory(1)
		gear_cell[1].transfer_stack(hand)
		expect(line(info(wb).config) == line({ "stone" }), "copy mode keeps " .. line(info(wb).config))
		put_cell(wb, "me-4k-storage-cell")
		expect(line(info(wb).cell.partition) == line({ "stone" }), "the kept partition on the next cell " .. line(info(wb).cell.partition))
		take_cell(wb)
		hand.clear()
		remote.call(WB, "set_keep", wb, false)
		--- a fluid cell: 3 slots, no fuzzy card, fluid keys
		put_cell(wb, "me-1k-fluid-storage-cell")
		expect(info(wb).cell.slots == 3 and info(wb).cell.fluid, "fluid cell " .. line(info(wb).cell))
		expect(card(wb, CARD.fuzzy) == "not-here", "a fuzzy card on a fluid cell")
		remote.call(WB, "set_partition_slot", wb, 1, "fluid/water")
		expect(card(wb, CARD.inverter) == nil, "inverter on a fluid cell")
		take_cell(wb)
		--- the inverted fluid cell in DT: water goes to the backstop, steam into it
		into_dt()
		remote.call(NET, "insert_fluid", t, "water", 100)
		remote.call(NET, "insert_fluid", t, "steam", 100)
		expect(in_cell(dt, 1, "fluid/water") == 0 and in_cell(db, 2, "fluid/water") == 100 and in_cell(dt, 1, "fluid/steam") == 100,
			"inverted fluid cell: water " .. in_cell(dt, 1, "fluid/water") .. ", steam " .. in_cell(dt, 1, "fluid/steam"))

		--- the inverted item cell (tags of the first cell): iron and copper refused, the rest taken; not preferred
		hand.set_stack{ name = "me-1k-storage-cell", count = 1, tags = tags }
		into_dt()
		local d1 = remote.call(NET, "drive", dt)[1]
		expect(d1 and #d1.cards == 3 and line(d1.partition) == line({ "copper-plate", "iron-plate" }), "the cell in the drive " .. line(d1))
		remote.call(NET, "insert", t, "iron-plate", 10)
		remote.call(NET, "insert", t, "wood", 10)
		expect(in_cell(dt, 1, "iron-plate") == 0 and in_cell(dt, 1, "wood") == 10, "inverted item cell: iron "
			.. in_cell(dt, 1, "iron-plate") .. ", wood " .. in_cell(dt, 1, "wood"))
		local q = prototypes.quality["uncommon"] and "uncommon"
		if q then
			remote.call(NET, "insert", t, "iron-plate", 4, q)
			expect(in_cell(dt, 1, "iron-plate@" .. q) == 0, "inverted and fuzzy: uncommon iron in the cell")
		end
		--- the cell window shows the cards and the configured list
		local cd = remote.call(GUI, "cell_data", dt, 1)
		expect(cd and #cd.cards == 3 and cd.inverted and line(cd.partition) == line({ "copper-plate", "iron-plate" }), "cell window data " .. line(cd and cd.cards))

		--- fuzzy whitelist on a fresh cell: every quality of copper
		hand.clear()
		put_cell(wb, "me-1k-storage-cell")
		remote.call(WB, "set_partition_slot", wb, 1, "copper-plate")
		card(wb, CARD.fuzzy)
		take_cell(wb)
		into_dt()
		remote.call(NET, "insert", t, "copper-plate", 6)
		if q then remote.call(NET, "insert", t, "copper-plate", 7, q) end
		expect(in_cell(dt, 1, "copper-plate") == 6 and (not q or in_cell(dt, 1, "copper-plate@" .. q) == 7),
			"fuzzy cell: copper " .. in_cell(dt, 1, "copper-plate") .. (q and (", uncommon " .. in_cell(dt, 1, "copper-plate@" .. q)) or ""))
		remote.call(NET, "insert", t, "stone", 3)
		expect(in_cell(dt, 1, "stone") == 0, "fuzzy whitelist took stone")

		--- equal distribution without a partition: AE2's share of a 1k cell, ceil((1024 - 8 x 63) x 8 / 63) = 67
		hand.clear()
		put_cell(wb, "me-1k-storage-cell")
		card(wb, CARD.equal)
		take_cell(wb)
		into_dt()
		remote.call(NET, "insert", t, "stone-brick", 100)
		expect(in_cell(dt, 1, "stone-brick") == 67 and count("stone-brick") == 100, "equal distribution: "
			.. in_cell(dt, 1, "stone-brick") .. " in the cell, " .. count("stone-brick") .. " in the network")
		--- with a whitelist of two: ceil((1024 - 16) x 8 / 2) = 4032
		hand.clear()
		put_cell(wb, "me-1k-storage-cell")
		remote.call(WB, "set_partition_slot", wb, 1, "coal")
		remote.call(WB, "set_partition_slot", wb, 2, "wood")
		card(wb, CARD.equal)
		take_cell(wb)
		into_dt()
		remote.call(NET, "insert", t, "coal", 5000)
		expect(in_cell(dt, 1, "coal") == 4032, "equal distribution of two: " .. in_cell(dt, 1, "coal"))

		--- overflow destruction on a partitioned cell: full, then the rest destroyed and counted
		hand.clear()
		put_cell(wb, "me-1k-storage-cell")
		remote.call(WB, "set_partition_slot", wb, 1, "iron-ore")
		card(wb, CARD.void)
		take_cell(wb)
		into_dt()
		local v0 = remote.call(NET, "voided")["iron-ore"] or 0
		local cap = (1024 - 8) * 8
		local got = remote.call(NET, "insert", t, "iron-ore", cap + 500)
		local v = (remote.call(NET, "voided")["iron-ore"] or 0) - v0
		expect(got == cap + 500 and in_cell(dt, 1, "iron-ore") == cap and v == 500 and count("iron-ore") == cap,
			"void cell: inserted " .. got .. ", cell " .. in_cell(dt, 1, "iron-ore") .. ", voided " .. v)
		remote.call(NET, "insert", t, "copper-ore", 10)
		expect(in_cell(dt, 1, "copper-ore") == 0 and (remote.call(NET, "voided")["copper-ore"] or 0) == 0, "void cell destroyed an unpartitioned key")
		expect(remote.call(NET, "can_insert", t, "iron-ore", 99999) == 99999, "can_insert at a voiding cell")

		--- mined, destroyed and vanished workbenches with a cell: never lost
		local function cell_with(w)
			put_cell(w, "me-4k-storage-cell")
			remote.call(WB, "set_partition_slot", w, 1, "wood")
			card(w, CARD.inverter)
		end
		cell_with(wm)
		local buffer = game.create_inventory(2)
		remote.call(WB, "removed", wm, buffer)
		wm.destroy()
		local mined = buffer.find_item_stack("me-4k-storage-cell")
		expect(mined and mined.tags.fork_me_cell and #mined.tags.fork_me_cell.cards == 1, "mined workbench: cell in the buffer")
		buffer.destroy()
		cell_with(wd)
		wd.die()
		cell_with(wv)
		wv.destroy()
		for _ = 1, 10 do remote.call(WB, "sweep") end
		local ground = 0
		for _, e in pairs(s.find_entities_filtered{ name = "item-on-ground", area = { { WX + 16, WY + 2 }, { WX + 24, WY + 8 } } }) do
			if e.stack.valid_for_read and e.stack.name == "me-4k-storage-cell" and e.stack.tags.fork_me_cell then ground = ground + 1 end
		end
		expect(ground == 2, "destroyed and vanished workbenches spilled " .. ground .. " cells")
		expect(remote.call(GUI, "has_window", wb), "the workbench has no window")
		inv.destroy()
		store.destroy()
		gear_cell.destroy()
		me_report("WORKBENCH", "ME Cell Workbench", problems, "slots, partition, cards and limits, tags, from contents, clear, "
			.. "copy mode, inverter/fuzzy/equal/void cells in a drive, mined/destroyed/vanished")
	end

	--- issue #28: the workbench's script inventory (slot 1 the cell, slots 2 to 5 its cards) changed the way a player
	--- changes it; `back` stands for the player's inventory, `hands` for the place a cell is taken to
	local function slots_test()
		local st = storage.wb28
		if (st and st.done) or game.tick < 100 then return end
		st = { problems = {}, done = true }
		storage.wb28 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local s = game.surfaces[1]
		local w = s.create_entity{ name = "me-cell-workbench", position = { WX + 22.5, WY + 4.5 }, force = "player", raise_built = true }
		local inv = w and remote.call(WB, "inventory", w)
		if not inv then return me_report("WBSLOTS", "ME Cell Workbench slots", { "no workbench or no inventory" }) end
		local back = game.create_inventory(20)
		local hands = game.create_inventory(5)
		local function sync(places) return remote.call(WB, "sync", w, back, places or {}) end
		local function info() return remote.call(WB, "info", w) or {} end
		local function tag_cards(stack)
			local t = stack.valid_for_read and stack.is_item_with_tags and stack.tags.fork_me_cell
			return t and t.cards or {}
		end
		local function cards_in(i)
			local n = 0
			for _, name in pairs(CARD) do n = n + i.get_item_count(name) end
			return n
		end
		--- every card: items in the slots, back and hands, and the ones in the tags of the cells there
		local function all_cards()
			local n = cards_in(inv) + cards_in(back) + cards_in(hands)
			for _, i in pairs({ inv, back, hands }) do
				for k = 1, #i do if i[k].valid_for_read and i[k].is_item_with_tags then n = n + #tag_cards(i[k]) end end
			end
			return n
		end
		expect(#inv == 5 and inv.is_empty(), "a new workbench: " .. #inv .. " slots")
		--- a cell with two cards in its tags arrives: the cards become the card slots' items, its tags lose them
		inv[1].set_stack{ name = "me-1k-storage-cell", count = 1,
			tags = { fork_me_cell = { items = {}, partition = { wood = true }, cards = { CARD.inverter, CARD.fuzzy } } } }
		local total = all_cards()
		expect(sync() == true, "the cell's arrival reports no change")
		expect(#tag_cards(inv[1]) == 0 and cards_in(inv) == 2 and info().cell and #info().cell.cards == 2 and info().cell.inverted
			and line(info().cell.partition) == line({ "wood" }), "arrived: tags " .. line(tag_cards(inv[1])) .. ", slots " .. cards_in(inv)
			.. ", info " .. line(info().cell and info().cell.cards))
		--- a third card is taken, a second inverter card and an iron plate go back
		inv[4].set_stack{ name = CARD.void, count = 1 }
		inv[5].set_stack{ name = CARD.inverter, count = 1 }
		total = total + 2
		sync()
		inv[5].set_stack{ name = "iron-plate", count = 3 }
		sync()
		expect(cards_in(inv) == 3 and back.get_item_count(CARD.inverter) == 1 and back.get_item_count("iron-plate") == 3 and info().cell.void,
			"cards: " .. cards_in(inv) .. " in the slots, inverter back " .. back.get_item_count(CARD.inverter))
		--- the cell taken to the player's hands (the engine keeps its item_number): found, the cards go into its tags
		hands[1].transfer_stack(inv[1])
		sync({ hands })
		expect(#tag_cards(hands[1]) == 3 and cards_in(inv) == 0 and info().cell == nil, "the cell left: tags " .. line(tag_cards(hands[1]))
			.. ", slots " .. cards_in(inv))
		expect(all_cards() == total, "cards after the cell left: " .. all_cards() .. "/" .. total)
		--- a card without a cell goes back
		inv[3].set_stack{ name = CARD.equal, count = 1 }
		total = total + 1
		sync()
		expect(not inv[3].valid_for_read and back.get_item_count(CARD.equal) == 1, "a card without a cell stayed")
		--- the cell put into a card slot: moved to slot 1, its cards back in the slots
		inv[4].transfer_stack(hands[1])
		sync()
		expect(inv[1].valid_for_read and inv[1].name == "me-1k-storage-cell" and cards_in(inv) == 3 and #tag_cards(inv[1]) == 0,
			"a cell in slot 4: slot 1 " .. line(inv[1].valid_for_read and inv[1].name) .. ", slots " .. cards_in(inv))
		--- a cell that leaves to a place nobody looks at: its cards go back to the player as items (never two copies)
		hands[2].transfer_stack(inv[1])
		sync({})
		expect(#tag_cards(hands[2]) == 0 and cards_in(inv) == 0 and all_cards() == total, "an unfound cell: tags "
			.. line(tag_cards(hands[2])) .. ", slots " .. cards_in(inv) .. ", all " .. all_cards() .. "/" .. total)
		--- a fluid cell takes 3 cards and no fuzzy card: the fuzzy card goes back, the card in slot 5 moves up
		inv[1].set_stack{ name = "me-1k-fluid-storage-cell", count = 1 }
		sync()
		for slot, name in pairs({ [2] = CARD.inverter, [3] = CARD.fuzzy, [5] = CARD.void }) do
			back.remove{ name = name, count = 1 }
			inv[slot].set_stack{ name = name, count = 1 }
		end
		sync()
		expect(not inv[5].valid_for_read and cards_in(inv) == 2 and info().cell and info().cell.slots == 3
			and back.get_item_count(CARD.fuzzy) == 1 and #info().cell.cards == 2,
			"a fluid cell with the item cell's cards: " .. line(info().cell and info().cell.cards) .. ", fuzzy back " .. back.get_item_count(CARD.fuzzy))
		--- the old click takes the cell with its cards
		local hand = game.create_inventory(1)
		remote.call(WB, "cell_click", w, hand[1], back, false)
		expect(hand[1].valid_for_read and #tag_cards(hand[1]) == 2 and cards_in(inv) == 0, "the click took the cell: tags "
			.. line(tag_cards(hand[1])))
		--- mined with a card no sync has seen yet: it goes into the cell's tags, the cell into the buffer
		remote.call(WB, "cell_click", w, hand[1], back, false)
		back.remove{ name = CARD.equal, count = 1 }
		inv[4].set_stack{ name = CARD.equal, count = 1 }
		local buffer = game.create_inventory(5)
		remote.call(WB, "removed", w, buffer)
		w.destroy()
		local cell = buffer.find_item_stack("me-1k-fluid-storage-cell")
		expect(cell and #tag_cards(cell) == 3 and cards_in(buffer) == 0, "mined: " .. line(cell and tag_cards(cell)))
		local n = cards_in(back) + cards_in(hands) + (cell and #tag_cards(cell) or 0)
		for k = 1, #hands do if hands[k].valid_for_read and hands[k].is_item_with_tags then n = n + #tag_cards(hands[k]) end end
		expect(n == total, "cards after mining: " .. n .. "/" .. total)
		hand.destroy()
		buffer.destroy()
		hands.destroy()
		back.destroy()
		me_report("WBSLOTS", "ME Cell Workbench slots", problems, "tag cards to the slots and back, limits, a wrong item, the cell "
			.. "found in the hand, a card without a cell, a cell in a card slot, an unfound cell, a fluid cell, mined with an unseen card")
	end

	--- issue #28: the workbench window's inventory pane and slots, clicked through the GUI module's functions (a script
	--- inventory stands for the player's main inventory, a slot of another one for the cursor)
	local function pane_test()
		local st = storage.wbpane28
		if (st and st.done) or game.tick < 110 then return end
		st = { problems = {}, done = true }
		storage.wbpane28 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local s = game.surfaces[1]
		local w = s.create_entity{ name = "me-cell-workbench", position = { WX + 24.5, WY + 4.5 }, force = "player", raise_built = true }
		local winv = w and remote.call(WB, "inventory", w)
		if not winv then return me_report("WBPANE", "ME window pane (workbench)", { "no workbench or no inventory" }) end
		local pinv = game.create_inventory(20)
		local hold = game.create_inventory(1)
		local cursor = hold[1]
		local function click(slot, mode) return remote.call(GUI, "inventory_click", cursor, pinv, slot, mode, w) end
		local function bclick(slot, shift) return remote.call(GUI, "block_click", w, slot, cursor, pinv, shift) end
		local function tag_cards(stack)
			local t = stack.valid_for_read and stack.is_item_with_tags and stack.tags.fork_me_cell
			return t and t.cards or {}
		end
		local function cards_in(i)
			local c = 0
			for _, name in pairs(CARD) do c = c + i.get_item_count(name) end
			return c
		end
		local function all_cards()
			local c = cards_in(winv) + cards_in(pinv) + cards_in(hold)
			for _, i in pairs({ winv, pinv, hold }) do
				for k = 1, #i do if i[k].valid_for_read and i[k].is_item_with_tags then c = c + #tag_cards(i[k]) end end
			end
			return c
		end
		pinv[1].set_stack{ name = "me-1k-storage-cell", count = 1,
			tags = { fork_me_cell = { items = {}, partition = { wood = true }, cards = { CARD.inverter } } } }
		pinv[2].set_stack{ name = "iron-plate", count = 10 }
		pinv[3].set_stack{ name = CARD.fuzzy, count = 1 }
		pinv[4].set_stack{ name = "me-4k-storage-cell", count = 1 }
		local total = all_cards()
		--- shift + click: a wrong item, a card without a cell, then the cell (its tag card becomes a card slot's item)
		local why = remote.call(GUI, "inventory_click", cursor, pinv, 2, "shift", w)
		expect(why == "not-here" and pinv[2].count == 10, "shift + click of iron plates: " .. tostring(why))
		why = click(3, "shift")
		expect(why == "no-cell" and pinv[3].valid_for_read, "shift + click of a card without a cell: " .. tostring(why))
		expect(click(1, "shift") == nil and winv[1].valid_for_read and winv[1].name == "me-1k-storage-cell" and #tag_cards(winv[1]) == 0
			and winv.get_item_count(CARD.inverter) == 1 and not pinv[1].valid_for_read, "shift + click of the cell")
		why = click(4, "shift")
		expect(why == "occupied" and pinv[4].valid_for_read, "shift + click of a second cell: " .. tostring(why))
		expect(click(3, "shift") == nil and winv.get_item_count(CARD.fuzzy) == 1 and not pinv[3].valid_for_read, "shift + click of a card")
		--- block slot clicks with a wrong item in the cursor: refused, nothing moves
		cursor.set_stack{ name = "iron-plate", count = 3 }
		why = bclick(4, false)
		expect(why == "not-here" and cursor.count == 3 and not winv[4].valid_for_read, "iron plates on a card slot: " .. tostring(why))
		why = bclick(1, false)
		expect(why == "not-a-cell" and cursor.count == 3 and winv[1].name == "me-1k-storage-cell", "iron plates on the cell slot: " .. tostring(why))
		pinv[10].transfer_stack(cursor)
		--- the cell into the cursor: its cards go with it into its tags
		expect(bclick(1, false) == nil and cursor.valid_for_read and #tag_cards(cursor) == 2 and cards_in(winv) == 0,
			"the cell taken into the cursor: tags " .. serpent.line(tag_cards(cursor)))
		--- a card clicked on a card slot without a cell is refused
		local cell = game.create_inventory(1)
		cell[1].transfer_stack(cursor)
		cursor.set_stack{ name = CARD.void, count = 1 }
		total = total + 1
		why = bclick(2, false)
		expect(why == "no-cell" and cursor.valid_for_read and cursor.name == CARD.void, "a card without a cell: " .. tostring(why))
		pinv[11].transfer_stack(cursor)
		--- the cell back from the cursor, then swapped with the second cell: the first comes back with its cards
		cursor.transfer_stack(cell[1])
		bclick(1, false)
		expect(cards_in(winv) == 2 and not cursor.valid_for_read, "the cell clicked back: " .. cards_in(winv) .. " cards in the slots")
		cursor.transfer_stack(pinv[4])
		bclick(1, false)
		expect(cursor.valid_for_read and cursor.name == "me-1k-storage-cell" and #tag_cards(cursor) == 2 and winv[1].name == "me-4k-storage-cell"
			and cards_in(winv) == 0, "swap: the cursor holds " .. tostring(cursor.valid_for_read and cursor.name) .. " with "
			.. serpent.line(tag_cards(cursor)))
		pinv[4].transfer_stack(cursor)
		--- shift + click on the cell slot: the cell into the inventory
		expect(bclick(1, true) == nil and not winv[1].valid_for_read and pinv.get_item_count("me-4k-storage-cell") == 1,
			"the cell shift-clicked into the inventory")
		expect(all_cards() == total, "cards made or lost by the clicks: " .. all_cards() .. "/" .. total)
		cell.destroy()
		hold.destroy()
		pinv.destroy()
		me_report("WBPANE", "ME window pane (workbench)", problems, "shift + click of a wrong item, a card without a cell, the cell, "
			.. "a second cell, a card; block slot clicks with a wrong item, the cell into the cursor and back, a swap, shift")
	end

	function T.tick()
		workbench_test()
		slots_test()
		pane_test()
	end
	function T.running(check)
		check(storage.wb17 and storage.wb17.done, "ME Cell Workbench")
		check(storage.wb28 and storage.wb28.done, "ME Cell Workbench slots")
		check(storage.wbpane28 and storage.wbpane28.done, "ME window pane (workbench)")
	end
	return T
end
