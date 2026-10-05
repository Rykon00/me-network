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
		--- issue #37: the workbench's partition without a cell: set by hand (items and fluids), shown as the items and
		--- then the fluids, onto the next cell without a partition (the keys of its kind), not onto one that has one
		local k = info(wb)
		expect(#k.config == 0 and k.config_items == 0 and k.limits and k.limits.items >= 63 and k.limits.fluids >= 1,
			"an empty workbench's partition " .. line(k))
		remote.call(WB, "set_partition_slot", wb, 1, "coal")
		remote.call(WB, "set_partition_slot", wb, 2, "fluid/steam")
		remote.call(WB, "set_partition_slot", wb, 3, "wood")
		remote.call(WB, "set_partition_slot", wb, 4, "coal")                 -- (a key it has: once)
		remote.call(WB, "set_partition_slot", wb, 4, "no-such-item")         -- (an unknown key: dropped)
		k = info(wb)
		expect(line(k.config) == line({ "coal", "wood", "fluid/steam" }) and k.config_items == 2,
			"a partition set without a cell " .. line(k.config) .. " " .. tostring(k.config_items))
		expect(remote.call(WB, "from_contents", wb) == false and #info(wb).config == 3, "from contents without a cell")
		remote.call(WB, "set_partition_slot", wb, 2, nil)                    -- (wood out)
		remote.call(WB, "set_partition_slot", wb, 1, "stone")                -- (coal becomes stone)
		expect(line(info(wb).config) == line({ "stone", "fluid/steam" }), "a slot removed and one replaced " .. line(info(wb).config))
		--- a cell with a partition of its own keeps it; the fluid set by hand stays next to it; without the copy mode
		--- all of it is forgotten when the cell leaves
		remote.call(WB, "set_partition_slot", wb, 1, "coal")
		hand.clear()
		hand.transfer_stack(gear_cell[1])
		remote.call(WB, "cell_click", wb, hand, inv, false)
		expect(line(info(wb).cell.partition) == line({ "stone" }) and line(info(wb).config) == line({ "stone", "fluid/steam" }),
			"a cell with a partition in a workbench with one " .. line(info(wb).cell.partition) .. " " .. line(info(wb).config))
		take_cell(wb)
		gear_cell[1].transfer_stack(hand)
		expect(#info(wb).config == 0, "the partition after that cell left (no copy mode) " .. line(info(wb).config))
		--- a cell without a partition takes the keys of its kind, also without the copy mode
		remote.call(WB, "set_partition_slot", wb, 1, "coal")
		remote.call(WB, "set_partition_slot", wb, 2, "fluid/steam")
		put_cell(wb, "me-4k-storage-cell")
		expect(line(info(wb).cell.partition) == line({ "coal" }) and line(info(wb).config) == line({ "coal", "fluid/steam" }),
			"an item cell takes the items set without a cell " .. line(info(wb).cell.partition) .. " " .. line(info(wb).config))
		--- an item cell takes no fluid into its partition (and its tags hold none)
		remote.call(WB, "set_partition_slot", wb, 2, "fluid/water")
		expect(line(info(wb).cell.partition) == line({ "coal" }), "a fluid set on an item cell " .. line(info(wb).cell.partition))
		--- the cell's partition changed and cleared: the fluid kept for a fluid cell is not touched
		remote.call(WB, "set_partition_slot", wb, 2, "wood")
		expect(line(info(wb).config) == line({ "coal", "wood", "fluid/steam" }), "the cell's change in the workbench's partition " .. line(info(wb).config))
		remote.call(WB, "clear", wb)
		expect(#info(wb).cell.partition == 0 and line(info(wb).config) == line({ "fluid/steam" }), "clear with a cell " .. line(info(wb).config))
		remote.call(WB, "set_partition_slot", wb, 1, "coal")
		local t37 = take_cell(wb)
		expect(t37 and t37.fork_me_cell and t37.fork_me_cell.partition and t37.fork_me_cell.partition["coal"] and #info(wb).config == 0,
			"the cell left with the partition, the workbench forgot it " .. line(t37) .. " " .. line(info(wb).config))
		hand.clear()
		--- with the copy mode a fluid cell takes the fluids and the items stay for an item cell; Clear without a cell
		remote.call(WB, "set_keep", wb, true)
		remote.call(WB, "set_partition_slot", wb, 1, "coal")
		remote.call(WB, "set_partition_slot", wb, 2, "fluid/steam")
		put_cell(wb, "me-1k-fluid-storage-cell")
		expect(line(info(wb).cell.partition) == line({ "fluid/steam" }), "a fluid cell takes the fluids " .. line(info(wb).cell.partition))
		--- a fluid cell takes no item into its partition
		remote.call(WB, "set_partition_slot", wb, 2, "iron-plate")
		expect(line(info(wb).cell.partition) == line({ "fluid/steam" }), "an item set on a fluid cell " .. line(info(wb).cell.partition))
		local tf = take_cell(wb)
		local pf = tf and tf.fork_me_cell and tf.fork_me_cell.partition or {}
		expect(pf["fluid/steam"] and not pf["coal"] and table_size(pf) == 1, "the fluid cell's tags " .. line(pf))
		hand.clear()
		expect(line(info(wb).config) == line({ "coal", "fluid/steam" }), "the copy mode keeps both kinds " .. line(info(wb).config))
		expect(remote.call(WB, "clear", wb) == true and #info(wb).config == 0, "clear without a cell " .. line(info(wb).config))
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
			.. "copy mode, the partition without a cell, inverter/fuzzy/equal/void cells in a drive, mined/destroyed/vanished")
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

	--- issue #69: what the partition buttons of a workbench without a cell offer and take: the free slot is a chooser of
	--- the kind the switch says (item with quality, fluid), the filled ones of their own kind; only an item with quality
	--- or a fluid is taken (a virtual signal, an item or fluid given as a signal, an entity, a recipe: refused, nothing
	--- changes); a slot is changed, emptied, a key chosen twice stays once; a full kind leaves its free slot disabled
	local function pick_test()
		local st = storage.wb69
		if (st and st.done) or game.tick < 110 then return end
		st = { problems = {}, done = true }
		storage.wb69 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local w = game.surfaces[1].create_entity{ name = "me-cell-workbench", position = { WX + 24.5, WY + 4.5 }, force = "player", raise_built = true }
		if not w then return me_report("WBPICK69", "ME Cell Workbench partition buttons", { "no workbench" }) end
		local function info() return remote.call(WB, "info", w) or {} end
		local function slots(kind) return remote.call(GUI, "workbench_slots", w, kind) or {} end
		local function choose(index, elem_type, value) return remote.call(GUI, "workbench_choose", w, index, elem_type, value) end
		local function item(name, q) return { name = name, quality = q or "normal" } end
		local function last(t) return t[#t] end

		--- empty: one free slot, a chooser of the kind asked for; never a signal chooser
		for kind, elem_type in pairs({ item = "item-with-quality", fluid = "fluid" }) do
			local sl = slots(kind)
			expect(#sl == 1 and sl[1].free and sl[1].index == 1 and sl[1].elem_type == elem_type and sl[1].enabled and not sl[1].key,
				"the free slot of an empty workbench (" .. kind .. ") " .. line(sl))
		end
		--- refused, and nothing changes
		local refused = {
			{ "signal", { type = "virtual", name = "signal-A" } }, { "signal", { type = "virtual", name = "signal-everything" } },
			{ "signal", { type = "item", name = "iron-plate", quality = "normal" } }, { "signal", { type = "fluid", name = "water" } },
			{ "signal", { type = "entity", name = "iron-chest" } }, { "entity", "iron-chest" }, { "recipe", "iron-gear-wheel" },
			{ "item", "iron-plate" }, { "item-with-quality", item("no-such-item") }, { "fluid", "no-such-fluid" },
			{ "item-with-quality", { type = "virtual", name = "signal-A" } },
		}
		for _, r in ipairs(refused) do
			expect(choose(1, r[1], r[2]) == false, "refused: " .. r[1] .. " " .. line(r[2]))
		end
		expect(#info().config == 0, "a refused choice changed the partition " .. line(info().config))
		--- an item with its quality, a fluid, an item of another quality
		expect(choose(1, "item-with-quality", item("iron-plate")) == true and choose(2, "fluid", "water") == true
			and choose(3, "item-with-quality", item("copper-plate")) == true, "items and a fluid chosen")
		local q = prototypes.quality["uncommon"] and "uncommon"
		if q then expect(choose(4, "item-with-quality", item("iron-plate", q)) == true, "an item with quality chosen") end
		local want = q and { "copper-plate", "iron-plate", "iron-plate@" .. q, "fluid/water" } or { "copper-plate", "iron-plate", "fluid/water" }
		local k = info()
		expect(line(k.config) == line(want) and k.config_items == #want - 1, "the kept partition: items, then fluids " .. line(k.config))
		--- the buttons: a filled one of its own kind, then the free one at the end, of the kind asked for
		for _, kind in ipairs({ "item", "fluid" }) do
			local sl = slots(kind)
			local ok = #sl == #want + 1
			for i, key in ipairs(want) do
				ok = ok and sl[i] and sl[i].key == key and not sl[i].free and sl[i].enabled
					and sl[i].elem_type == (key:find("^fluid/") and "fluid" or "item-with-quality")
			end
			local f = last(sl)
			ok = ok and f.free and f.index == #want + 1 and not f.key and f.enabled
				and f.elem_type == (kind == "fluid" and "fluid" or "item-with-quality")
			expect(ok, "the buttons with the free " .. kind .. " slot " .. line(sl))
		end
		--- a slot changed, a key chosen twice (once), a slot emptied
		expect(choose(1, "item-with-quality", item("stone")) == true, "a slot changed")
		expect(line(info().config):find("copper-plate", 1, true) == nil and line(info().config):find("stone", 1, true) ~= nil,
			"the slot after the change " .. line(info().config))
		local n = #info().config
		choose(#info().config + 1, "item-with-quality", item("iron-plate"))      -- (iron-plate is in the list already)
		expect(#info().config == n, "a key chosen twice " .. line(info().config))
		local gone = info().config[1]
		choose(1, "item-with-quality", nil)
		expect(#info().config == n - 1 and info().config[1] ~= gone and not remote.call(WB, "info", w).config[n], "a slot emptied " .. line(info().config))
		expect(#slots("item") == #info().config + 1, "no stale button after the choices " .. line(slots("item")))
		--- a full kind: its free slot is not enabled, the other kind's is
		remote.call(WB, "clear", w)
		local lim = info().limits
		for name in pairs(prototypes.item) do
			if info().config_items >= lim.items then break end
			choose(#info().config + 1, "item-with-quality", item(name))
		end
		k = info()
		expect(k.config_items == lim.items, "items filled up to the limit: " .. k.config_items .. "/" .. lim.items)
		expect(not last(slots("item")).enabled and last(slots("fluid")).enabled, "the free slot of a full kind " .. line(last(slots("item"))))
		choose(1, "item-with-quality", nil)
		expect(last(slots("item")).enabled, "a slot of a full kind emptied: the free one is enabled again")
		choose(#info().config + 1, "item-with-quality", item("iron-plate", q or "normal"))
		for name in pairs(prototypes.fluid) do
			if #info().config - info().config_items >= lim.fluids then break end
			choose(#info().config + 1, "fluid", name)
		end
		k = info()
		expect(#k.config - k.config_items == lim.fluids and not last(slots("fluid")).enabled, "the free slot of full fluids")
		remote.call(WB, "clear", w)
		w.destroy()
		me_report("WBPICK69", "ME Cell Workbench partition buttons", problems, "the free slot per kind, refused signals, entities, "
			.. "recipes and unknown values, items with quality and fluids, a slot changed and emptied, a key twice, full kinds")
	end

	--- Issue #64: the tooltip of a cell (its custom_description, written with the stack by N.cell_stack). The cells are made
	--- through the workbench's remote interface, as a player makes them; the test compares structure and keys, never a
	--- rendered text: one concatenation ("" first) of the lines, split at the "\n" strings, each a { locale key, params }
	--- (the windows' keys for the modes) with the icon lists as plain strings
	local function tip_test()
		local st = storage.wbtip64
		if (st and st.done) or game.tick < 120 then return end
		st = { problems = {}, done = true }
		storage.wbtip64 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local w = game.surfaces[1].create_entity{ name = "me-cell-workbench", position = { WX + 26.5, WY + 4.5 }, force = "player", raise_built = true }
		if not w then return me_report("WBTIP64", "ME cell tooltip", { "no workbench" }) end
		local inv = game.create_inventory(2)
		local hand = inv[1]
		local function put_cell(def)
			def = type(def) == "string" and { name = def, count = 1 } or def
			hand.set_stack(def)
			return remote.call(WB, "cell_click", w, hand, inv, false)
		end
		local function card(name)
			hand.set_stack{ name = name, count = 1 }
			local why = remote.call(WB, "card_click", w, 1, hand, inv, false)
			if hand.valid_for_read then hand.clear() end
			return why
		end
		local function key(index, k) remote.call(WB, "set_partition_slot", w, index, k) end
		--- the cell leaves the workbench into the hand: its lines (the description split at "\n"), nil without a description
		local function lines()
			hand.clear()
			remote.call(WB, "cell_click", w, hand, inv, false)
			if not hand.valid_for_read then return nil, "no cell came out" end
			local d = hand.custom_description
			if d == nil or d == "" then return nil end
			if type(d) ~= "table" or d[1] ~= "" then return nil, "not a concatenation " .. line(d) end
			local out = {}
			for i = 2, #d do
				if d[i] ~= "\n" then out[#out + 1] = d[i] end
			end
			return out, #d
		end
		--- (the game gives a number parameter of a localised string back as a string: the wanted lines are compared as text)
		local function texts(t)
			if type(t) ~= "table" then return type(t) == "number" and tostring(t) or t end
			local out = {}
			for i, v in ipairs(t) do out[i] = texts(v) end
			return out
		end
		local function is(l, want, what)
			local got = l and line(l) or "nil"
			expect(got == line(texts(want)), what .. ": " .. got .. " (wanted " .. line(texts(want)) .. ")")
		end
		local ICON = { void = "[item=" .. CARD.void .. "]", fuzzy = "[item=" .. CARD.fuzzy .. "]", inverter = "[item=" .. CARD.inverter .. "]",
			equal = "[item=" .. CARD.equal .. "]" }
		local cells = prototypes.mod_data["fork-me-network"].data.cells
		local size_1k, size_fluid = cells["me-1k-storage-cell"], cells["me-1k-fluid-storage-cell"]

		--- a fresh cell has no description (the prototype's), also one that lost its partition and cards again
		expect(put_cell("me-1k-storage-cell") == nil, "an item cell in the workbench")
		local l, why = lines()
		expect(l == nil and why == nil, "a fresh cell has no description " .. line(why))
		put_cell("me-1k-storage-cell")
		key(1, "iron-plate")
		card(CARD.fuzzy)
		remote.call(WB, "clear", w)
		hand.clear()
		remote.call(WB, "card_click", w, 1, hand, inv, false)             -- the card back out
		hand.clear()
		l, why = lines()
		expect(l == nil and why == nil, "a cell cleared of partition and cards is fresh again " .. line(l))

		--- a whitelist of two items (the empty cell says its size first)
		put_cell("me-1k-storage-cell")
		key(1, "iron-plate")
		key(2, "copper-plate")
		l = lines()
		is(l, { { "fork-me-net.cell-tip-empty", size_1k.bytes, size_1k.types }, { "fork-me-net.cell-tip-partition", "[item=copper-plate] [item=iron-plate]" },
			{ "fork-me-gui.cell-mode-whitelist" } }, "a whitelist of two items")

		--- the same with an Inverter Card: a blacklist, then the card
		put_cell("me-1k-storage-cell")
		key(1, "iron-plate")
		key(2, "copper-plate")
		expect(card(CARD.inverter) == nil, "an Inverter Card")
		l = lines()
		is(l, { { "fork-me-net.cell-tip-empty", size_1k.bytes, size_1k.types }, { "fork-me-net.cell-tip-partition", "[item=copper-plate] [item=iron-plate]" },
			{ "fork-me-gui.cell-mode-blacklist" }, { "fork-me-net.cell-tip-cards", ICON.inverter } }, "a blacklist")

		--- a key with quality (not for normal), next to one without
		local q = prototypes.quality["uncommon"] and "uncommon"
		if q then
			put_cell("me-1k-storage-cell")
			key(1, "iron-plate@" .. q)
			key(2, "copper-plate")
			l = lines()
			is(l, { { "fork-me-net.cell-tip-empty", size_1k.bytes, size_1k.types },
				{ "fork-me-net.cell-tip-partition", "[item=copper-plate] [item=iron-plate,quality=" .. q .. "]" }, { "fork-me-gui.cell-mode-whitelist" } },
				"a quality key")
		end

		--- a fluid cell: fluids, the fluid size line
		put_cell("me-1k-fluid-storage-cell")
		key(1, "fluid/water")
		l = lines()
		is(l, { { "fork-me-net.cell-tip-empty-fluid", size_fluid.bytes, size_fluid.types }, { "fork-me-net.cell-tip-partition", "[fluid=water]" },
			{ "fork-me-gui.cell-mode-whitelist" } }, "a fluid cell")

		--- more keys than fit: twelve icons, then "+N more" (the keys are sorted: the first twelve show)
		local names = {}
		for name in pairs(prototypes.item) do
			if not name:find("[^%l%-]") and not name:find("storage%-cell") then names[#names + 1] = name end
		end
		table.sort(names)
		local want = {}
		for i = 1, 14 do want[i] = names[i] end
		put_cell("me-1k-storage-cell")
		for i, name in ipairs(want) do key(i, name) end
		local icons = {}
		for i = 1, 12 do icons[i] = "[item=" .. want[i] .. "]" end
		l = lines()
		is(l, { { "fork-me-net.cell-tip-empty", size_1k.bytes, size_1k.types }, { "fork-me-net.cell-tip-partition-more", table.concat(icons, " "), 2 },
			{ "fork-me-gui.cell-mode-whitelist" } }, "more keys than fit")
		--- exactly twelve: no "more"
		put_cell("me-1k-storage-cell")
		for i = 1, 12 do key(i, want[i]) end
		l = lines()
		is(l and l[2], { "fork-me-net.cell-tip-partition", table.concat(icons, " ") }, "twelve keys fit")

		--- every card on an item cell: the card icons in the order they went in, then what each does
		put_cell("me-1k-storage-cell")
		key(1, "iron-plate")
		for _, name in ipairs({ CARD.inverter, CARD.fuzzy, CARD.equal, CARD.void }) do expect(card(name) == nil, "card " .. name) end
		local d
		l, d = lines()
		expect(l and #l == 7 and type(d) == "number" and d <= 21, "every card: a concatenation of at most 20 parts " .. line(l) .. " " .. line(d))
		if l and #l == 7 then
			is(l[2], { "fork-me-net.cell-tip-partition", "[item=iron-plate]" }, "every card: partition")
			is(l[3], { "fork-me-gui.cell-mode-blacklist" }, "every card: blacklist")
			is(l[4], { "fork-me-net.cell-tip-cards", table.concat({ ICON.inverter, ICON.fuzzy, ICON.equal, ICON.void }, " ") }, "every card: cards")
			is(l[5], { "fork-me-gui.cell-mode-fuzzy" }, "every card: fuzzy")
			expect(l[6][1] == "fork-me-gui.cell-mode-equal" and type(l[6][2]) == "string", "every card: equal distribution " .. line(l[6]))
			is(l[7], { "fork-me-gui.cell-mode-void" }, "every card: overflow destruction (the red line)")
		end
		--- the windows' mode line says the same sentences (one source)
		local caption = remote.call(GUI, "cell_mode_caption", { inverted = true, fuzzy = true, equal = 1234, void = true })
		expect(caption and line(caption):find("cell-mode-blacklist", 1, true) and line(caption):find("cell-mode-fuzzy", 1, true)
			and line(caption):find("cell-mode-equal", 1, true) and line(caption):find("cell-mode-void", 1, true), "the window's mode line " .. line(caption))

		--- a fluid cell with the cards it takes (no Fuzzy Card)
		put_cell("me-1k-fluid-storage-cell")
		key(1, "fluid/water")
		expect(card(CARD.fuzzy) == "not-here", "a Fuzzy Card on a fluid cell")
		expect(card(CARD.void) == nil and card(CARD.equal) == nil, "a fluid cell's cards")
		l = lines()
		expect(l and #l == 6 and line(l):find("cell-mode-whitelist", 1, true) and not line(l):find("cell-mode-fuzzy", 1, true), "a fluid cell with cards " .. line(l))

		--- an empty cell that is not partitioned, with a card: its size, the card, what it does
		put_cell("me-1k-storage-cell")
		expect(card(CARD.fuzzy) == nil, "a Fuzzy Card")
		l = lines()
		is(l, { { "fork-me-net.cell-tip-empty", size_1k.bytes, size_1k.types }, { "fork-me-net.cell-tip-cards", ICON.fuzzy }, { "fork-me-gui.cell-mode-fuzzy" } },
			"an empty cell with a card")

		--- a cell that holds items and is partitioned (a cell with contents in its tags into the workbench; a change
		--- writes the description): what it holds as before, the partition, the mode; with a card too
		local function held()
			return { name = "me-1k-storage-cell", count = 1, tags = { fork_me_cell = { items = { ["iron-plate"] = 100, ["copper-plate"] = 30 }, data = {} } } }
		end
		put_cell(held())
		key(1, "iron-plate")
		l = lines()
		expect(l and #l == 3 and l[1][1] == "fork-me-net.cell-holds" and l[1][2] == "130" and l[1][3] == "2" and l[1][4] == "100 [item=iron-plate], 30 [item=copper-plate]",
			"a partitioned cell that holds items: contents " .. line(l and l[1]))
		if l and #l == 3 then
			is(l[2], { "fork-me-net.cell-tip-partition", "[item=iron-plate]" }, "holds: partition")
			is(l[3], { "fork-me-gui.cell-mode-whitelist" }, "holds: whitelist")
		end
		put_cell(held())
		key(1, "iron-plate")
		card(CARD.inverter)
		l = lines()
		expect(l and #l == 4 and l[1][1] == "fork-me-net.cell-holds", "a cell that holds items, blacklisted " .. line(l))
		--- a cell that holds items and has no partition or card has the contents line alone
		put_cell(held())
		key(1, "iron-plate")
		remote.call(WB, "clear", w)
		l = lines()
		expect(l and #l == 1 and l[1][1] == "fork-me-net.cell-holds", "a cell with contents only " .. line(l))

		--- a cell that leaves a drive (the other writer of the stack) says the same
		local spare = game.create_inventory(1)
		local drive = game.surfaces[1].create_entity{ name = "me-drive", position = { WX + 28.5, WY + 4.5 }, force = "player", raise_built = true }
		local out
		if drive then
			hand.set_stack{ name = "me-1k-storage-cell", count = 1, tags = { fork_me_cell = { items = { ["iron-plate"] = 8 }, data = {},
				partition = { ["iron-plate"] = true }, cards = { CARD.fuzzy } } } }
			expect(remote.call(NET, "insert_cell", drive, hand, 1) == 1, "a cell into a drive")
			remote.call(NET, "take_cell", drive, 1, spare)
			out = spare[1].valid_for_read and spare[1].custom_description
			drive.destroy()
		end
		local text = line(out)
		expect(type(out) == "table" and text:find("fork-me-net.cell-holds", 1, true) and text:find("cell-tip-partition", 1, true)
			and text:find("cell-mode-whitelist", 1, true) and text:find("cell-tip-cards", 1, true) and text:find("cell-mode-fuzzy", 1, true),
			"a cell taken out of a drive " .. text)
		spare.destroy()
		inv.destroy()
		w.destroy()
		me_report("WBTIP64", "ME cell tooltip", problems, "a fresh cell, a whitelist, a blacklist, a quality key, a fluid cell, more keys than fit, "
			.. "every card, a cell with contents, an empty cell with a card, a cell out of a drive")
	end

	--- Issue #75: what a slot of an ME window gives a stack. The window's buttons need a player, so the functions behind
	--- them are called: G.stack_tooltip (the tooltip next to the item's own, `elem_tooltip`) and G.stack_ident (the piece
	--- of the slot's signature that makes the slot notice a stack written anew). A cell and a pattern give their own
	--- description (then the slot's own hint), a plain item and a cell without a description give the hint alone.
	local function slot_tip_test()
		local st = storage.wbslot75
		if (st and st.done) or game.tick < 130 then return end
		st = { problems = {}, done = true }
		storage.wbslot75 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local w = game.surfaces[1].create_entity{ name = "me-cell-workbench", position = { WX + 30.5, WY + 4.5 }, force = "player", raise_built = true }
		if not w then return me_report("WBSLOTTIP75", "ME window slot tooltips", { "no workbench" }) end
		local inv = game.create_inventory(3)
		local hand = inv[1]
		local function tip(stack, base) return remote.call(GUI, "stack_tooltip", stack, base) end
		local function ident(stack) return remote.call(GUI, "stack_ident", stack) end
		local hint = { "fork-me-gui.workbench-cell-tooltip" }

		--- a plain item: the hint alone (nothing without one), no signature piece
		hand.set_stack{ name = "iron-plate", count = 5 }
		expect(line(tip(hand, hint)) == line(hint) and tip(hand, nil) == nil and ident(hand) == "", "a plain item: " .. line(tip(hand, hint)) .. " / " .. line(ident(hand)))
		--- an empty slot: the hint alone
		expect(line(tip(inv[2], hint)) == line(hint) and tip(inv[2], nil) == nil, "an empty slot")

		--- a fresh cell (an item with tags, no description): the hint alone, but a signature piece
		hand.set_stack{ name = "me-1k-storage-cell", count = 1 }
		expect(line(tip(hand, hint)) == line(hint) and tip(hand, nil) == nil, "a fresh cell: " .. line(tip(hand, nil)))
		expect(ident(hand):find("^#%d+$") ~= nil, "a fresh cell's signature piece " .. line(ident(hand)))

		--- a cell made in the workbench: its description (the tooltip the game's inventory shows), then the hint
		expect(remote.call(WB, "cell_click", w, hand, inv, false) == nil, "the cell into the workbench")
		remote.call(WB, "set_partition_slot", w, 1, "iron-plate")
		local bench_inv = remote.call(WB, "inventory", w)
		local slot = bench_inv[1]
		local before = ident(slot)
		local desc = slot.custom_description
		expect(type(desc) == "table", "the cell in the workbench has no description " .. line(desc))
		expect(line(tip(slot, nil)) == line(desc), "a cell: its description alone " .. line(tip(slot, nil)))
		local both = tip(slot, hint)
		expect(type(both) == "table" and both[1] == "" and line(both[2]) == line(desc) and both[3] == "\n" and line(both[4]) == line(hint),
			"a cell with a hint: the description, a line break, the hint " .. line(both))
		--- the cell stays in the slot and its partition changes: the description is written anew and the signature piece changes
		remote.call(WB, "set_partition_slot", w, 2, "copper-plate")
		local after = ident(bench_inv[1])
		expect(before ~= after and after:find("^#%d+$") ~= nil, "the signature piece after a change: " .. line(before) .. " -> " .. line(after))
		expect(line(tip(bench_inv[1], nil)) ~= line(desc), "the tooltip after a change " .. line(tip(bench_inv[1], nil)))
		--- a card: a plain item
		hand.set_stack{ name = "me-fuzzy-card", count = 1 }
		expect(line(tip(hand, hint)) == line(hint) and ident(hand) == "", "a card is a plain item")

		--- an encoded pattern: its description (what it makes) shows in the slot
		local pdesc = { "fork-me-pattern.description", "x" }
		hand.set_stack{ name = "me-encoded-pattern", count = 1, tags = { fork_me_pattern = { kind = "crafting" } }, custom_description = pdesc }
		expect(line(tip(hand, nil)) == line(pdesc) and ident(hand):find("^#%d+$") ~= nil, "an encoded pattern: " .. line(tip(hand, nil)))
		remote.call(WB, "clear", w)
		inv.destroy()
		w.destroy()
		me_report("WBSLOTTIP75", "ME window slot tooltips", problems, "a plain item, an empty slot, a fresh cell, a cell with its description and a hint, "
			.. "the signature piece after a change in the workbench, an encoded pattern")
	end

	--- Issue #79: the terminal's storage tab (and every grid made by G.slot) shows a stored cell's or pattern's
	--- description. The key of an item with tags kept in the network carries it in its json; G.key_description reads it
	--- (the buttons need a player: the function behind them is called). A cell and a pattern are stored through
	--- the network's insert_stack and the key the network made for them is looked up in its contents.
	local function key_tip_test()
		local st = storage.wbkey79
		if (st and st.done) or game.tick < 140 then return end
		st = { problems = {}, done = true }
		storage.wbkey79 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local s = game.surfaces[1]
		local t = s.find_entity("me-terminal", { WX + 10.5, WY - 0.5 })
		local w = s.create_entity{ name = "me-cell-workbench", position = { WX + 32.5, WY + 4.5 }, force = "player", raise_built = true }
		if not (t and w) then return me_report("WBKEY79", "ME stored item descriptions", { "terminal or workbench missing" }) end
		local inv = game.create_inventory(2)
		local hand = inv[1]
		local function desc_of(key) return remote.call(GUI, "key_description", key) end
		--- the key the network made for the stack in the hand (the one new key with `#` of that item), the stack stored
		local function store(name)
			local before = remote.call(NET, "contents", t)
			local n, why = remote.call(NET, "insert_stack", t, hand)
			if not n then return nil, "not stored: " .. tostring(why) end
			for key in pairs(remote.call(NET, "contents", t)) do
				if not before[key] and key:find(name .. "@normal#", 1, true) == 1 then return key end
			end
			return nil, "no new key"
		end

		--- a cell made in the workbench, stored: its key gives the description the stack had
		hand.set_stack{ name = "me-1k-storage-cell", count = 1 }
		remote.call(WB, "cell_click", w, hand, inv, false)
		remote.call(WB, "set_partition_slot", w, 1, "iron-plate")
		remote.call(WB, "set_partition_slot", w, 2, "copper-plate")
		hand.clear()
		remote.call(WB, "cell_click", w, hand, inv, false)
		local want = hand.valid_for_read and hand.custom_description
		expect(type(want) == "table", "the cell made in the workbench has no description " .. line(want))
		local key, why = store("me-1k-storage-cell")
		expect(key ~= nil, "a stored cell: " .. tostring(why))
		expect(key and line(desc_of(key)) == line(want), "a stored cell's description: " .. line(key and desc_of(key)) .. " (wanted " .. line(want) .. ")")
		expect(key and line(desc_of(key)):find("cell-tip-partition", 1, true) ~= nil, "a stored cell says its partition")

		--- an encoded pattern
		local pdesc = { "fork-me-pattern.description", "x" }
		hand.set_stack{ name = "me-encoded-pattern", count = 1, tags = { fork_me_pattern = { kind = "crafting" } }, custom_description = pdesc }
		local pkey, pwhy = store("me-encoded-pattern")
		expect(pkey ~= nil, "a stored pattern: " .. tostring(pwhy))
		expect(pkey and line(desc_of(pkey)) == line(pdesc), "a stored pattern's description: " .. line(pkey and desc_of(pkey)))

		--- no description: a plain key, one with quality, a fluid, a fresh cell (stored as a plain item: no tags), a key with a
		--- broken json, and one whose json has no description
		expect(desc_of("iron-plate") == nil and desc_of("iron-plate@uncommon") == nil and desc_of("fluid/water") == nil, "plain keys have no description")
		expect(desc_of("me-1k-storage-cell@normal#{broken") == nil, "a broken json")
		expect(desc_of("me-1k-storage-cell@normal#" .. helpers.table_to_json({ tags = { a = 1 } })) == nil, "a json without a description")
		--- a cell written anew is another key (a changed description can never be shown for the old key)
		hand.set_stack{ name = "me-1k-storage-cell", count = 1 }
		remote.call(WB, "cell_click", w, hand, inv, false)
		remote.call(WB, "set_partition_slot", w, 1, "stone")
		hand.clear()
		remote.call(WB, "cell_click", w, hand, inv, false)
		local key2 = store("me-1k-storage-cell")
		expect(key2 ~= nil and key2 ~= key and line(desc_of(key2)) ~= line(desc_of(key)), "a cell with another partition is another key")

		inv.destroy()
		remote.call(WB, "clear", w)
		w.destroy()
		me_report("WBKEY79", "ME stored item descriptions", problems, "a stored cell and a stored pattern give the description of their stack, "
			.. "plain keys, a broken json and one without a description give none, another partition is another key")
	end

	function T.tick()
		workbench_test()
		slots_test()
		pane_test()
		pick_test()
		tip_test()
		slot_tip_test()
		key_tip_test()
	end
	function T.running(check)
		check(storage.wb17 and storage.wb17.done, "ME Cell Workbench")
		check(storage.wb28 and storage.wb28.done, "ME Cell Workbench slots")
		check(storage.wbpane28 and storage.wbpane28.done, "ME window pane (workbench)")
		check(storage.wb69 and storage.wb69.done, "ME Cell Workbench partition buttons")
		check(storage.wbtip64 and storage.wbtip64.done, "ME cell tooltip")
		check(storage.wbslot75 and storage.wbslot75.done, "ME window slot tooltips")
		check(storage.wbkey79 and storage.wbkey79.done, "ME stored item descriptions")
	end
	return T
end
