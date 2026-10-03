--- Runtime tests of me-network issue #17 (docs/ME-REWORK.md "Upgrade cards, storage bus settings, the Cell Workbench
--- and priorities"): the upgrade cards on the ME Storage Bus, its new settings, the cards never created or lost, the
--- priorities of drives, storage buses, interfaces and pattern providers. Loaded by control.lua with its helpers:
--- require("cards")(H) returns { setup = function(s) -> fails, tick = function() } (tick every 10 ticks).

local NET, IO, TERM, AC = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-terminal", "gregtorio-me-autocraft"
local SB, GUI, RP = "gregtorio-me-storagebus", "gregtorio-me-gui", "gregtorio-me-recipe-paste"
local CX, CY = 200, -200            -- the cards test (its own network)
local PX, PY = 200, -250            -- the priorities test (its own network)
local SOUTH = { direction = defines.direction.south }
local CARD = {
	capacity = "me-capacity-card", void = "me-overflow-destruction-card", fuzzy = "me-fuzzy-card",
	inverter = "me-inverter-card", equal = "me-equal-distribution-card", basic = "me-basic-card",
}

return function(H)
	local me_place, cable_row, power, me_report = H.me_place, H.cable_row, H.power, H.me_report
	local T = {}

	local function line(t) return serpent.line(t) end

	--- plain items for the filter test: 30 names of simple items that do not spoil (sorted, the same in every run)
	local function plain_items(n)
		local out = {}
		for name, p in pairs(prototypes.item) do
			if p.type == "item" and not p.hidden and not p.place_result and not p.place_as_tile_result and p.stack_size > 1
				and p.get_spoil_ticks() == 0 and not name:find("^me%-") then
				out[#out + 1] = name
			end
		end
		table.sort(out)
		local picked = {}
		for i = 1, math.min(n, #out) do picked[i] = out[i] end
		return picked
	end

	function T.setup(s)
		local fails = {}
		local what = "cards"
		--- the cards test: buses on chests (B1..B5, B7), a bus on a tank (B6), a bus facing nothing (B8)
		power(s, fails, what, CX, CY)
		me_place(s, fails, what, "me-network-controller", CX + 7, CY)
		H.me_drive(s, fails, what, CX + 8.5, CY - 0.5, {}, "1k")
		H.me_drive(s, fails, what, CX + 9.5, CY - 0.5, {}, "1k", true)
		me_place(s, fails, what, "me-terminal", CX + 10.5, CY - 0.5)
		cable_row(s, fails, CX + 11, CX + 32, CY - 1)
		for _, x in pairs({ 11.5, 13.5, 15.5, 17.5, 24.5 }) do
			me_place(s, fails, what, "me-storage-bus", CX + x, CY + 0.5, SOUTH)
			me_place(s, fails, what, "iron-chest", CX + x, CY + 1.5)
		end
		me_place(s, fails, what, "me-storage-bus", CX + 19.5, CY + 0.5, SOUTH)          -- B5: a wooden chest
		me_place(s, fails, what, "wooden-chest", CX + 19.5, CY + 1.5)
		me_place(s, fails, what, "me-storage-bus", CX + 21.5, CY + 0.5, SOUTH)          -- B6: a tank
		me_place(s, fails, what, "storage-tank", CX + 21.5, CY + 2.5)
		me_place(s, fails, what, "me-storage-bus", CX + 26.5, CY + 0.5, SOUTH)          -- B8: facing nothing
		--- the priorities test: drives, storage buses BB (blacklist), BW (whitelist), BL (low), two interfaces,
		--- two providers with chests
		what = "priorities"
		power(s, fails, what, PX, PY)
		me_place(s, fails, what, "me-network-controller", PX + 7, PY)
		H.me_drive(s, fails, what, PX + 8.5, PY - 0.5, {}, "1k")
		H.me_drive(s, fails, what, PX + 9.5, PY - 0.5, {}, "1k", true)
		me_place(s, fails, what, "me-terminal", PX + 10.5, PY - 0.5)
		cable_row(s, fails, PX + 11, PX + 32, PY - 1)
		for _, x in pairs({ 11.5, 13.5, 15.5 }) do
			me_place(s, fails, what, "me-storage-bus", PX + x, PY + 0.5, SOUTH)
			me_place(s, fails, what, "iron-chest", PX + x, PY + 1.5)
		end
		me_place(s, fails, what, "me-network-interface", PX + 18.5, PY + 0.5)            -- I_lo (built first)
		me_place(s, fails, what, "me-network-interface", PX + 20.5, PY + 0.5)            -- I_hi
		me_place(s, fails, what, "me-pattern-provider", PX + 23.5, PY + 0.5)             -- P_hi
		me_place(s, fails, what, "iron-chest", PX + 24.5, PY + 0.5)
		me_place(s, fails, what, "me-pattern-provider", PX + 27.5, PY + 0.5)             -- P_lo
		me_place(s, fails, what, "iron-chest", PX + 28.5, PY + 0.5)
		return fails
	end

	--------------------------------------------------------------------------------
	--- the cards and the storage bus
	--------------------------------------------------------------------------------

	local function cards_test()
		local st = storage.cards17
		if (st and st.done) or game.tick < 90 then return end
		st = { problems = {} }
		storage.cards17 = st
		st.done = true
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { CX + x, CY + y }) end
		local t = find("me-terminal", 10.5, -0.5)
		local b1, b2, b3, b4, b7 = find("me-storage-bus", 11.5, 0.5), find("me-storage-bus", 13.5, 0.5),
			find("me-storage-bus", 15.5, 0.5), find("me-storage-bus", 17.5, 0.5), find("me-storage-bus", 24.5, 0.5)
		local b5, b6, b8 = find("me-storage-bus", 19.5, 0.5), find("me-storage-bus", 21.5, 0.5), find("me-storage-bus", 26.5, 0.5)
		local c1, c2, c3, c4, c7 = find("iron-chest", 11.5, 1.5), find("iron-chest", 13.5, 1.5), find("iron-chest", 15.5, 1.5),
			find("iron-chest", 17.5, 1.5), find("iron-chest", 24.5, 1.5)
		local c5, tank = find("wooden-chest", 19.5, 1.5), find("storage-tank", 21.5, 2.5)
		if not (t and b1 and b2 and b3 and b4 and b5 and b6 and b7 and b8 and c1 and c2 and c3 and c4 and c5 and c7 and tank) then
			return me_report("CARDS", "ME upgrade cards", { "entities missing" })
		end
		local inv = game.create_inventory(8)
		local hand = inv[1]
		local function count(name, q) return remote.call(NET, "count", t, name, q) end
		local function info(b) return remote.call(SB, "info", b) or {} end
		local function visit(b) remote.call(SB, "visit", b) end
		--- a card into card slot `slot` of bus `b` from the hand
		local function put(b, name, slot)
			hand.set_stack{ name = name, count = 1 }
			local why = remote.call(SB, "card_click", b, slot or 1, hand, inv, false)
			if hand.valid_for_read then hand.clear() end
			return why
		end
		local function cards_of(b)
			local out = {}
			for _, name in pairs(info(b).cards or {}) do out[#out + 1] = name end
			table.sort(out)
			return table.concat(out, ",")
		end

		--- defaults of a bus that never saw a card (old saves): 18 filters, no extra settings
		local g0 = remote.call(SB, "get_settings", b7)
		local i0 = info(b7)
		expect(g0 and g0.extract == nil and g0.cards == nil and i0.max == 18 and i0.slots == 5 and i0.extract == true
			and not i0.void and not i0.inverted and not i0.fuzzy, "defaults " .. line(g0) .. " " .. line(i0))

		--- Capacity Card: 18 filters, 27 with one card; a card of another kind or above its limit is refused
		local items = plain_items(30)
		remote.call(SB, "set_settings", b1, { filters = items, priority = 5 })
		expect(info(b1).max == 18 and #info(b1).filters == 30, "30 filters kept, 18 apply: " .. line(info(b1).max))
		local i20 = items[20]
		remote.call(NET, "insert", t, i20, 1)
		expect(c1.get_item_count(i20) == 0, "filter 20 applied without a Capacity Card")
		expect(put(b1, CARD.capacity) == nil and info(b1).max == 27, "capacity card: " .. line(info(b1).max))
		remote.call(NET, "insert", t, i20, 1)
		expect(c1.get_item_count(i20) == 1, "filter 20 with a Capacity Card: " .. c1.get_item_count(i20))
		for slot = 2, 5 do put(b1, CARD.capacity, slot) end
		expect(info(b1).max == 63, "five capacity cards: " .. line(info(b1).max))
		local why = put(b1, CARD.fuzzy)
		expect(why == "full", "a sixth card: " .. tostring(why))
		remote.call(SB, "card_click", b1, 5, hand, inv, false)       -- take one capacity card out
		expect(hand.valid_for_read and hand.name == CARD.capacity and info(b1).max == 54, "card taken: " .. line(info(b1).max))
		hand.clear()
		why = put(b1, CARD.equal)
		expect(why == "not-here", "an equal distribution card on a bus: " .. tostring(why))
		why = put(b1, CARD.capacity)
		expect(why == nil, "capacity card again: " .. tostring(why))
		why = put(b1, CARD.capacity)
		expect(why == "full" or why == "limit", "a sixth capacity card: " .. tostring(why))
		remote.call(SB, "set_settings", b1, { filters = {}, priority = 0, mode = "read" })   -- out of the way

		--- Inverter Card: a blacklist; the network does not see the listed items unless "filter on extract" is off
		remote.call(SB, "set_settings", b2, { filters = { "iron-plate" }, priority = 5 })
		expect(put(b2, CARD.inverter) == nil and info(b2).inverted, "inverter card")
		why = put(b2, CARD.inverter)
		expect(why == "limit", "a second inverter card: " .. tostring(why))
		remote.call(NET, "insert", t, "iron-plate", 10)
		remote.call(NET, "insert", t, "copper-plate", 10)
		expect(c2.get_item_count("iron-plate") == 0 and c2.get_item_count("copper-plate") == 10,
			"blacklist insert: iron " .. c2.get_item_count("iron-plate") .. ", copper " .. c2.get_item_count("copper-plate"))
		c2.insert{ name = "iron-plate", count = 7 }
		visit(b2)
		expect(count("iron-plate") == 10, "a blacklisted item in the chest is shown: " .. count("iron-plate"))
		remote.call(SB, "set_settings", b2, { extract = false })
		expect(count("iron-plate") == 17 and info(b2).extract == false, "filter only what goes in: iron " .. count("iron-plate"))
		expect(remote.call(NET, "extract", t, "iron-plate", 17) == 17 and c2.get_item_count("iron-plate") == 0,
			"the network takes the blacklisted item: " .. c2.get_item_count("iron-plate"))
		remote.call(NET, "insert", t, "iron-plate", 3)
		expect(c2.get_item_count("iron-plate") == 0, "filter only what goes in: iron went into the chest")
		remote.call(SB, "set_settings", b2, { extract = true })
		--- a whitelist with "filter only what goes in": the chest's other items are seen and taken too
		remote.call(SB, "set_settings", b3, { filters = { "copper-cable" }, extract = false })
		c3.insert{ name = "stone", count = 4 }
		visit(b3)
		expect(count("stone") == 4, "whitelist, filter only what goes in: stone " .. count("stone"))
		remote.call(SB, "set_settings", b3, { extract = true })
		expect(count("stone") == 0, "whitelist, filter on extract: stone " .. count("stone"))
		remote.call(SB, "set_settings", b2, { mode = "read" })           -- the blacklist bus takes nothing more

		--- Fuzzy Card: a filter matches every quality
		local q = prototypes.quality["uncommon"] and "uncommon"
		remote.call(SB, "set_settings", b4, { filters = { "copper-plate" }, priority = 6 })
		if q then
			remote.call(NET, "insert", t, "copper-plate", 5, q)
			expect(c4.get_item_count{ name = "copper-plate", quality = q } == 0, "another quality without a fuzzy card")
			expect(put(b4, CARD.fuzzy) == nil and info(b4).fuzzy, "fuzzy card")
			remote.call(NET, "insert", t, "copper-plate", 5, q)
			expect(c4.get_item_count{ name = "copper-plate", quality = q } == 5, "fuzzy: uncommon copper into the chest "
				.. c4.get_item_count{ name = "copper-plate", quality = q })
			c4.insert{ name = "copper-plate", count = 2, quality = "rare" }
			visit(b4)
			expect(count("copper-plate", "rare") == 2, "fuzzy: rare copper shown " .. count("copper-plate", "rare"))
		else
			expect(put(b4, CARD.fuzzy) == nil, "fuzzy card")
			st.note_q = "no quality mod: fuzzy checked without another quality"
		end
		remote.call(NET, "insert", t, "copper-plate", 3)
		expect(c4.get_item_count("copper-plate") == 3, "fuzzy: normal copper " .. c4.get_item_count("copper-plate"))
		remote.call(SB, "set_settings", b4, { mode = "read" })

		--- Overflow Destruction Card: what does not fit is destroyed (filtered keys only), counted
		local voided0 = remote.call(NET, "voided")["stone"] or 0
		remote.call(SB, "set_settings", b5, { filters = { "stone" }, priority = 10 })
		expect(put(b5, CARD.void) == nil and info(b5).void, "void card")
		local room = 16 * prototypes.item["stone"].stack_size
		expect(remote.call(NET, "can_insert", t, "stone", 1000000) == 1000000, "can_insert at a voiding bus")
		local got = remote.call(NET, "insert", t, "stone", room + 100)
		local voided = (remote.call(NET, "voided")["stone"] or 0) - voided0
		expect(got == room + 100 and c5.get_item_count("stone") == room and voided == 100 and info(b5).voided == 100,
			"void: inserted " .. got .. ", chest " .. c5.get_item_count("stone") .. ", voided " .. voided .. "/" .. info(b5).voided)
		expect(count("stone") == room, "void: the network holds " .. count("stone"))
		remote.call(NET, "insert", t, "coal", 10)
		expect(c5.get_item_count("coal") == 0 and count("coal") == 10 and (remote.call(NET, "voided")["coal"] or 0) == 0,
			"void: an unfiltered key was destroyed or stored in the chest")
		local wd = remote.call(GUI, "storage_bus_data", b5)
		expect(wd and wd.void and wd.voided == 100, "window data of the voiding bus " .. line(wd and wd.voided))
		--- on a tank: the segment's room, then destroyed
		remote.call(SB, "set_settings", b6, { filters = { "fluid/water" }, priority = 10 })
		put(b6, CARD.void)
		visit(b6)
		local cap = tank.fluidbox.get_capacity(1)
		local wv0 = remote.call(NET, "voided")["fluid/water"] or 0
		local gw = remote.call(NET, "insert_fluid", t, "water", cap + 500)
		local wv = (remote.call(NET, "voided")["fluid/water"] or 0) - wv0
		expect(math.abs(gw - (cap + 500)) < 1e-3 and math.abs(tank.get_fluid_count("water") - cap) < 1 and math.abs(wv - 500) < 1,
			"void on a tank: inserted " .. gw .. ", tank " .. tank.get_fluid_count("water") .. ", voided " .. wv)
		--- a voiding bus facing nothing destroys nothing
		remote.call(SB, "set_settings", b8, { filters = { "wood" }, priority = 10 })
		put(b8, CARD.void)
		remote.call(NET, "insert", t, "wood", 5)
		expect(count("wood") == 5 and (remote.call(NET, "voided")["wood"] or 0) == 0, "void without a target: wood " .. count("wood"))
		remote.call(SB, "set_settings", b5, { mode = "read" })
		remote.call(SB, "set_settings", b6, { mode = "read" })

		--- From contents and Clear
		c7.insert{ name = "iron-gear-wheel", count = 3 }
		c7.insert{ name = "iron-stick", count = 2 }
		remote.call(SB, "from_contents", b7)
		expect(line(remote.call(SB, "get_settings", b7).filters) == line({ "iron-gear-wheel", "iron-stick" }),
			"from contents " .. line(remote.call(SB, "get_settings", b7).filters))
		remote.call(SB, "clear", b7)
		expect(#remote.call(SB, "get_settings", b7).filters == 0, "clear")

		--- the cards are never created or lost: the cards of the world counted before and after
		local function world_cards()
			local n = 0
			for _, name in pairs(CARD) do n = n + count(name) + inv.get_item_count(name) end
			for _, b in pairs(s.find_entities_filtered{ name = "me-storage-bus", area = { { CX, CY - 5 }, { CX + 40, CY + 20 } } }) do
				for _, name in pairs(info(b).cards or {}) do if name then n = n + 1 end end
			end
			for _, e in pairs(s.find_entities_filtered{ name = "item-on-ground", area = { { CX, CY - 5 }, { CX + 40, CY + 20 } } }) do
				if e.stack.valid_for_read and e.stack.name:find("card$") then n = n + e.stack.count end
			end
			return n
		end
		local before = world_cards()
		--- a bus with cards mined: the cards into the buffer
		local bm = s.create_entity{ name = "me-storage-bus", position = { CX + 30.5, CY + 6.5 }, force = "player", raise_built = true }
		put(bm, CARD.inverter)
		put(bm, CARD.capacity, 2)
		before = before + 2                                               -- (two cards made by this test's hand)
		local buffer = game.create_inventory(4)
		remote.call(SB, "removed", bm, buffer)
		bm.destroy()
		remote.call(NET, "sweep")
		expect(buffer.get_item_count(CARD.inverter) == 1 and buffer.get_item_count(CARD.capacity) == 1, "mined: cards in the buffer "
			.. line(buffer.get_contents()))
		for _, it in pairs(buffer.get_contents()) do inv.insert{ name = it.name, count = it.count } end
		buffer.destroy()
		--- destroyed: spilled; vanished without an event: spilled at the sweep
		local bd = s.create_entity{ name = "me-storage-bus", position = { CX + 32.5, CY + 6.5 }, force = "player", raise_built = true }
		inv.remove{ name = CARD.inverter, count = 1 }
		put(bd, CARD.inverter)
		bd.die()
		local bv = s.create_entity{ name = "me-storage-bus", position = { CX + 34.5, CY + 6.5 }, force = "player", raise_built = true }
		inv.remove{ name = CARD.capacity, count = 1 }
		put(bv, CARD.capacity)
		bv.destroy()
		remote.call(NET, "sweep")
		local ground = 0
		for _, e in pairs(s.find_entities_filtered{ name = "item-on-ground", area = { { CX + 28, CY + 3 }, { CX + 38, CY + 10 } } }) do
			if e.stack.valid_for_read and e.stack.name:find("card$") then ground = ground + e.stack.count end
		end
		expect(ground == 2, "destroyed and vanished buses spilled " .. ground .. " cards")
		expect(world_cards() == before, "cards after mining and destroying: " .. world_cards() .. "/" .. before)

		--- blueprint, ghost, paste, clone: the cards are wanted, never copied (the buses between B1 ... B4, on the cable row)
		local bs = s.create_entity{ name = "me-storage-bus", position = { CX + 12.5, CY + 0.5 }, force = "player", raise_built = true }
		inv.insert{ name = CARD.inverter, count = 1 }
		inv.insert{ name = CARD.fuzzy, count = 1 }
		before = before + 2
		put(bs, CARD.inverter)
		put(bs, CARD.fuzzy, 2)
		remote.call(SB, "set_settings", bs, { filters = { "wood" }, extract = false })
		inv.remove{ name = CARD.inverter, count = 1 }
		inv.remove{ name = CARD.fuzzy, count = 1 }
		local want = { mode = "readwrite", priority = 0, filters = { "wood" }, extract = false, cards = { CARD.inverter, CARD.fuzzy } }
		expect(line(remote.call(SB, "get_settings", bs)) == line(want), "settings with cards " .. line(remote.call(SB, "get_settings", bs)))
		local bpi = game.create_inventory(1)
		bpi.insert{ name = "blueprint" }
		local mapping = bpi[1].create_blueprint{ surface = s, force = "player", area = { { CX + 12.2, CY + 0.2 }, { CX + 12.8, CY + 0.8 } } }
		remote.call(SB, "tag_blueprint", bpi[1], mapping)
		local tag
		for index, e in pairs(mapping or {}) do
			if e.name == "me-storage-bus" then tag = bpi[1].get_blueprint_entity_tag(index, "fork_me_storage_bus") end
		end
		bpi.destroy()
		expect(tag and line(tag.cards) == line(want.cards) and tag.extract == false, "blueprint tag " .. line(tag))
		local ghost = s.create_entity{ name = "entity-ghost", inner_name = "me-storage-bus", position = { CX + 14.5, CY + 0.5 },
			force = "player", tags = { fork_me_storage_bus = tag } }
		local _, revived = ghost.revive{ raise_revive = true }
		expect(revived and cards_of(revived) == "" and #(info(revived).want or {}) == 2, "a revived ghost has no cards, wants 2: "
			.. (revived and (cards_of(revived) .. " " .. line(info(revived).want)) or "not revived"))
		expect(world_cards() == before, "cards after the blueprint: " .. world_cards() .. "/" .. before)
		--- the network gets one of them: the bus takes it at its visit
		remote.call(NET, "insert", t, CARD.fuzzy, 1)
		before = before + 1
		if revived then
			visit(revived)
			expect(cards_of(revived) == CARD.fuzzy and count(CARD.fuzzy) == 0 and #(info(revived).want or {}) == 1,
				"the revived bus took its fuzzy card from the network: " .. cards_of(revived) .. " " .. line(info(revived).want))
		end
		--- settings paste onto a bus with a capacity card: the capacity card goes (into the network: no player), the
		--- wanted ones come from the network
		local bp2 = s.create_entity{ name = "me-storage-bus", position = { CX + 16.5, CY + 0.5 }, force = "player", raise_built = true }
		before = before + 1                                               -- (the capacity card made by put)
		put(bp2, CARD.capacity)
		remote.call(NET, "insert", t, CARD.inverter, 1)
		before = before + 1
		remote.call(SB, "paste", bs, bp2)
		expect(cards_of(bp2) == CARD.inverter and count(CARD.capacity) == 1 and count(CARD.inverter) == 0
			and #(info(bp2).want or {}) == 1 and remote.call(SB, "get_settings", bp2).extract == false,
			"paste: cards " .. cards_of(bp2) .. ", network capacity " .. count(CARD.capacity) .. " " .. line(info(bp2).want))
		--- a clone wants the source's cards; the source keeps its own
		local clone = bs.clone{ position = { CX + 18.5, CY + 0.5 } }
		expect(clone and cards_of(clone) == "" and cards_of(bs) == CARD.fuzzy .. "," .. CARD.inverter,
			"clone: " .. (clone and cards_of(clone) or "none") .. " / source " .. cards_of(bs))
		expect(world_cards() == before, "cards after paste and clone: " .. world_cards() .. "/" .. before)
		--- a hand click ends the waiting
		if revived then
			remote.call(SB, "card_click", revived, 1, hand, inv, true)
			expect(info(revived).want == nil and inv.get_item_count(CARD.fuzzy) == 1, "a card taken by hand ends the waiting")
		end
		expect(world_cards() == before, "cards at the end: " .. world_cards() .. "/" .. before)

		--- the recipe paste of #12 changes only the filters
		local machine = s.create_entity{ name = "me-molecular-assembler", position = { CX + 22.5, CY + 12.5 }, force = "player" }
		local recipe = machine and machine.force.recipes["iron-gear-crafting-table"]       -- (vanilla: a stand-in, data.lua)
		if recipe then
			recipe.enabled = true
			machine.set_recipe("iron-gear-crafting-table")
			remote.call(SB, "set_settings", bs, { priority = 4, mode = "write" })
			remote.call(RP, "paste", machine, bs)
			local g = remote.call(SB, "get_settings", bs)
			expect(g.extract == false and g.priority == 4 and g.mode == "write" and line(g.cards) == line(want.cards)
				and g.filters[1] ~= "wood", "recipe paste kept " .. line(g))
		else
			expect(false, "no assembling machine for the recipe paste")
		end
		inv.destroy()
		me_report("CARDS", "ME upgrade cards", problems, "capacity, inverter, fuzzy, overflow destruction, filter on extract, "
			.. "from contents, mined/destroyed/vanished/blueprint/paste/clone counted" .. (st.note_q and ("; " .. st.note_q) or ""))
	end

	--------------------------------------------------------------------------------
	--- priorities: storage order, interfaces, pattern fall-back
	--------------------------------------------------------------------------------

	local function priorities_test()
		local st = storage.prio17
		if (st and st.done) or game.tick < 90 then return end
		st = { problems = {}, done = true }
		storage.prio17 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { PX + x, PY + y }) end
		local t, drive = find("me-terminal", 10.5, -0.5), find("me-drive", 8.5, -0.5)
		local bb, bw, bl = find("me-storage-bus", 11.5, 0.5), find("me-storage-bus", 13.5, 0.5), find("me-storage-bus", 15.5, 0.5)
		local cb, cw, cl = find("iron-chest", 11.5, 1.5), find("iron-chest", 13.5, 1.5), find("iron-chest", 15.5, 1.5)
		local ilo, ihi = find("me-network-interface", 18.5, 0.5), find("me-network-interface", 20.5, 0.5)
		local phi, plo = find("me-pattern-provider", 23.5, 0.5), find("me-pattern-provider", 27.5, 0.5)
		if not (t and drive and bb and bw and bl and cb and cw and cl and ilo and ihi and phi and plo) then
			return me_report("PRIORITIES", "ME priorities", { "entities missing" })
		end
		local inv = game.create_inventory(4)
		local function count(name) return remote.call(NET, "count", t, name) end
		local function in_cells(name)
			local n = 0
			for _, c in pairs(remote.call(NET, "drive", drive)) do n = n + (c.items[name] or 0) end
			return n
		end
		local function visit(b) remote.call(SB, "visit", b) end

		--- storage order: a blacklist is not preferred (AE2), a whitelist is; a holder is preferred at its priority
		remote.call(SB, "set_settings", bb, { filters = { "iron-plate" }, priority = 5 })
		inv[1].set_stack{ name = CARD.inverter, count = 1 }
		remote.call(SB, "card_click", bb, 1, inv[1], inv, false)
		remote.call(SB, "set_settings", bw, { filters = { "copper-plate" }, priority = 5 })
		remote.call(SB, "set_settings", bl, { priority = -5 })
		remote.call(NET, "insert", t, "copper-plate", 10)
		expect(cw.get_item_count("copper-plate") == 10 and cb.get_item_count("copper-plate") == 0,
			"copper: whitelist " .. cw.get_item_count("copper-plate") .. ", blacklist (built first) " .. cb.get_item_count("copper-plate"))
		remote.call(NET, "insert", t, "wood", 10)
		expect(cb.get_item_count("wood") == 10, "wood into the blacklist bus at priority 5: " .. cb.get_item_count("wood"))
		remote.call(NET, "insert", t, "iron-plate", 10)
		expect(cb.get_item_count("iron-plate") == 0 and in_cells("iron-plate") == 10 and cl.get_item_count("iron-plate") == 0,
			"iron: refused by the blacklist, into the cells (priority 0) before the bus at -5: cells " .. in_cells("iron-plate"))
		--- a partitioned cell at priority 0 against the blacklist bus at 5: the higher priority first
		remote.call(NET, "set_partition", drive, 1, { "coal" })
		remote.call(NET, "insert", t, "coal", 4)
		expect(cb.get_item_count("coal") == 4, "coal: the blacklist bus at 5 before the partitioned cell at 0: " .. cb.get_item_count("coal"))
		remote.call(SB, "set_settings", bb, { mode = "read" })
		remote.call(NET, "insert", t, "coal", 4)
		expect(in_cells("coal") == 4, "coal: the partitioned cell once the bus is read only: " .. in_cells("coal"))
		--- a bus that holds an item gets it before an empty cell of its priority
		cl.insert{ name = "stone", count = 3 }
		remote.call(SB, "set_settings", bl, { priority = 0 })
		visit(bl)
		remote.call(NET, "insert", t, "stone", 5)
		expect(cl.get_item_count("stone") == 8 and in_cells("stone") == 0, "stone: the holder first: bus " .. cl.get_item_count("stone")
			.. ", cells " .. in_cells("stone"))
		--- taking out: the lowest priority first
		remote.call(SB, "set_settings", bl, { priority = -5 })
		cl.insert{ name = "iron-plate", count = 4 }
		visit(bl)
		expect(remote.call(NET, "extract", t, "iron-plate", 6) == 6 and cl.get_item_count("iron-plate") == 0 and in_cells("iron-plate") == 8,
			"iron taken from the bus at -5 first: bus " .. cl.get_item_count("iron-plate") .. ", cells " .. in_cells("iron-plate"))

		--- interfaces: no priority on the map's interfaces yet registers nothing; then the higher priority is filled first
		local GEAR = "iron-gear-wheel"
		remote.call(IO, "set_interface_key", ilo, 1, GEAR, 50)
		remote.call(IO, "set_interface_key", ihi, 1, GEAR, 50)
		remote.call(IO, "set_interface_key", ilo, 2, "fluid/water", 1000)
		remote.call(IO, "set_interface_key", ihi, 2, "fluid/water", 1000)
		local any_prio = false
		for _, e in pairs(s.find_entities_filtered{ name = "me-network-interface" }) do
			if (remote.call(IO, "get_interface_priority", e) or 0) ~= 0 then any_prio = true end
		end
		remote.call(IO, "step", ilo)
		remote.call(IO, "step", ihi)
		if not any_prio then
			expect(next(remote.call(IO, "get_interface", ilo).short) == nil, "a shortfall registered without priorities")
		end
		remote.call(IO, "set_interface_priority", ihi, 10)
		expect(remote.call(IO, "get_interface_priority", ihi) == 10 and remote.call(IO, "get_interface_priority", ilo) == 0, "interface priorities")
		remote.call(IO, "step", ilo)
		remote.call(IO, "step", ihi)
		local function gears(i) return i.get_item_count(GEAR) end
		local function side_water(i)
			local sides = remote.call(IO, "get_interface_sides", i)
			local tanks = remote.call(IO, "interface_tanks", i)
			for d, v in pairs(sides) do if v == 2 then return tanks[d].get_fluid_count("water") end end
			return -1
		end
		local short = remote.call(IO, "get_interface", ilo).short
		expect(short[GEAR] == 50 and short["fluid/water"] == 1000, "shortfall of the low interface " .. line(short))
		remote.call(NET, "insert", t, GEAR, 30)
		remote.call(NET, "insert_fluid", t, "water", 600)
		remote.call(IO, "step", ilo)
		remote.call(IO, "step", ihi)
		expect(gears(ilo) == 0 and gears(ihi) == 30, "30 gears for two interfaces: low " .. gears(ilo) .. ", high " .. gears(ihi))
		expect(math.abs(side_water(ilo)) < 1e-3 and math.abs(side_water(ihi) - 600) < 1e-3,
			"600 water: low " .. side_water(ilo) .. ", high " .. side_water(ihi))
		remote.call(NET, "insert", t, GEAR, 40)
		remote.call(NET, "insert_fluid", t, "water", 1400)
		remote.call(IO, "step", ilo)
		remote.call(IO, "step", ihi)
		expect(gears(ilo) == 20 and gears(ihi) == 50 and count(GEAR) == 0, "70 gears: low " .. gears(ilo) .. ", high " .. gears(ihi))
		expect(math.abs(side_water(ilo) - 1000) < 1e-3 and math.abs(side_water(ihi) - 1000) < 1e-3,
			"2000 water: low " .. side_water(ilo) .. ", high " .. side_water(ihi))
		--- priority in blueprints, settings paste and clones
		local bpi = game.create_inventory(1)
		bpi.insert{ name = "blueprint" }
		local mapping = bpi[1].create_blueprint{ surface = s, force = "player", area = { { PX + 20, PY }, { PX + 21, PY + 1 } } }
		remote.call(IO, "tag_blueprint", bpi[1], mapping)
		local tag
		for index, e in pairs(mapping or {}) do
			if e.name == "me-network-interface" then tag = bpi[1].get_blueprint_entity_tag(index, "fork_me_interface") end
		end
		bpi.destroy()
		expect(tag and tag.priority == 10, "interface blueprint tag " .. line(tag and tag.priority))
		local built = s.create_entity{ name = "me-network-interface", position = { PX + 20.5, PY + 8.5 }, force = "player" }
		remote.call(IO, "built", built, { fork_me_interface = tag })
		expect(remote.call(IO, "get_interface_priority", built) == 10, "interface from a blueprint: priority " .. line(remote.call(IO, "get_interface_priority", built)))
		local pasted = s.create_entity{ name = "me-network-interface", position = { PX + 22.5, PY + 8.5 }, force = "player", raise_built = true }
		remote.call(IO, "paste", ihi, pasted)
		expect(remote.call(IO, "get_interface_priority", pasted) == 10, "pasted interface priority")
		local clone = ihi.clone{ position = { PX + 24.5, PY + 8.5 } }
		expect(clone and remote.call(IO, "get_interface_priority", clone) == 10, "cloned interface priority")
		for _, e in pairs({ built, pasted, clone }) do if e and e.valid then e.destroy{ raise_destroy = true } end end
		expect(remote.call(GUI, "interface_data", ihi).priority == 10, "interface window data: priority")

		--- pattern fall-back (AE2): the higher priority provider's pattern lacks an ingredient, the next one is used
		local function processing(input, n, output)
			local ed = remote.call(TERM, "new_editor")
			ed.mode = "processing"
			local _
			_, ed = remote.call(TERM, "set_editor_row", ed, "inputs", 1, input, n)
			_, ed = remote.call(TERM, "set_editor_row", ed, "outputs", 1, output, 1)
			inv.clear()
			inv.insert{ name = "me-blank-pattern", count = 1 }
			remote.call(TERM, "encode", false, inv, t, t.force, ed)
			return inv.find_item_stack("me-encoded-pattern")
		end
		local p1 = processing("stone-brick", 1, "pipe")
		expect(p1 and remote.call(AC, "insert_pattern", phi, p1) == 1, "pattern of the high provider")
		local p2 = processing("stone", 2, "pipe")
		expect(p2 and remote.call(AC, "insert_pattern", plo, p2) == 1, "pattern of the low provider")
		remote.call(AC, "set_priority", phi, 10)
		local plan = remote.call(AC, "plan", t, "pipe", 1)
		expect(plan and plan.ok and plan.reserve and plan.reserve["stone"] == 2 and not plan.reserve["stone-brick"],
			"fall-back to the low provider: " .. line(plan and { plan.ok, plan.reserve, plan.missing }))
		remote.call(NET, "insert", t, "stone-brick", 5)
		plan = remote.call(AC, "plan", t, "pipe", 1)
		expect(plan and plan.ok and plan.reserve and plan.reserve["stone-brick"] == 1 and not plan.reserve["stone"],
			"the high provider once its ingredient is there: " .. line(plan and { plan.ok, plan.reserve }))
		remote.call(NET, "extract", t, "stone-brick", 5)
		remote.call(NET, "extract", t, "stone", 1000)
		plan = remote.call(AC, "plan", t, "pipe", 1)
		expect(plan and not plan.ok and plan.missing and plan.missing["stone-brick"] == 1,
			"nothing there: the first pattern's shortfall is reported: " .. line(plan and plan.missing))
		inv.destroy()
		me_report("PRIORITIES", "ME priorities", problems, "storage order with whitelist, blacklist, holder, partition; "
			.. "two interfaces on a short item and a short fluid; interface priority copied; pattern fall-back")
	end

	--------------------------------------------------------------------------------
	--- issue #28: the card slots are the bus's script inventory (the window shows it beside the player's inventory);
	--- what a player puts in is checked by the sync (here with a LuaInventory standing for the player's inventory)
	--------------------------------------------------------------------------------

	local function slots_test()
		local st = storage.slots28
		if (st and st.done) or game.tick < 100 then return end
		st = { problems = {}, done = true }
		storage.slots28 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local s = game.surfaces[1]
		local b = s.create_entity{ name = "me-storage-bus", position = { CX + 36.5, CY + 6.5 }, force = "player", raise_built = true }
		local inv = b and remote.call(SB, "inventory", b)
		if not inv then return me_report("CARDSLOTS", "ME storage bus card slots", { "no bus or no inventory" }) end
		local back = game.create_inventory(20)                   -- the player's inventory
		local function info() return remote.call(SB, "info", b) or {} end
		local function sync() return remote.call(SB, "sync", b, back) end
		local function cards_in(i)
			local n = 0
			for _, name in pairs(CARD) do n = n + i.get_item_count(name) end
			return n
		end
		expect(#inv == 5 and inv.is_empty() and info().max == 18, "a new bus: " .. #inv .. " slots, max " .. line(info().max))
		--- a card put in is taken
		inv[1].set_stack{ name = CARD.capacity, count = 1 }
		expect(sync() == true and info().cards[1] == CARD.capacity and info().max == 27, "a capacity card in slot 1: " .. line(info().cards)
			.. " max " .. line(info().max))
		expect(sync() == false, "a second sync without a change reports a change")
		--- a wrong item goes back
		inv[2].set_stack{ name = "iron-plate", count = 10 }
		sync()
		expect(not inv[2].valid_for_read and back.get_item_count("iron-plate") == 10, "iron plates in a card slot: "
			.. back.get_item_count("iron-plate") .. " back")
		--- three inverter cards in one slot: one stays (AE2's limit), two go back
		inv[3].set_stack{ name = CARD.inverter, count = 3 }
		sync()
		expect(inv[3].valid_for_read and inv[3].count == 1 and back.get_item_count(CARD.inverter) == 2 and info().inverted,
			"three inverter cards: " .. (inv[3].valid_for_read and inv[3].count or 0) .. " kept, " .. back.get_item_count(CARD.inverter) .. " back")
		--- four capacity cards in one slot: spread over the empty slots, the one beyond the slots goes back
		inv[4].set_stack{ name = CARD.capacity, count = 4 }
		sync()
		local caps = 0
		for i = 1, 5 do if inv[i].valid_for_read and inv[i].name == CARD.capacity then caps = caps + inv[i].count end end
		expect(caps == 4 and back.get_item_count(CARD.capacity) == 1 and info().max == 18 + 4 * 9,
			"four capacity cards spread: " .. caps .. " in the slots, " .. back.get_item_count(CARD.capacity) .. " back, max " .. line(info().max))
		--- a full bus refuses: the inventory takes nothing more, the old click says why
		local hand = game.create_inventory(1)
		hand[1].set_stack{ name = CARD.fuzzy, count = 1 }
		expect(inv.insert{ name = CARD.fuzzy, count = 1 } == 0 and remote.call(SB, "card_click", b, 1, hand[1], back, false) == "full",
			"a full bus took a fuzzy card")
		--- a card the bus does not take (Equal Distribution) goes back
		back.insert(inv[5])
		inv[5].clear()
		sync()
		inv[5].set_stack{ name = CARD.equal, count = 1 }
		sync()
		expect(not inv[5].valid_for_read and back.get_item_count(CARD.equal) == 1, "an equal distribution card in a bus")
		--- a card taken out by the player: the filters follow
		back.insert(inv[1])
		inv[1].clear()
		sync()
		expect(info().max == 18 + 2 * 9 and info().cards[1] == nil, "a capacity card taken out: max " .. line(info().max))
		--- the cards that were in their slot come first: a new inverter card in slot 1 goes back, the old one in slot 3 stays
		back.remove{ name = CARD.inverter, count = 1 }
		inv[1].set_stack{ name = CARD.inverter, count = 1 }
		sync()
		expect(not inv[1].valid_for_read and inv[3].valid_for_read and inv[3].name == CARD.inverter, "the old inverter card was replaced")
		--- the settings name the slots' cards, also of a stack moved to another slot of the inventory
		inv[1].transfer_stack(inv[3])
		sync()
		local g = remote.call(SB, "get_settings", b)
		expect(g and g.cards and #g.cards == 3 and info().cards[1] == CARD.inverter and info().inverted, "settings after a move: " .. line(g and g.cards))
		--- mined with an item that no sync has seen yet: everything into the buffer, no card made or lost
		local before = cards_in(inv) + cards_in(back)
		inv[3].set_stack{ name = "copper-plate", count = 5 }
		local buffer = game.create_inventory(10)
		remote.call(SB, "removed", b, buffer)
		b.destroy()
		remote.call(NET, "sweep")
		expect(cards_in(buffer) == 3 and buffer.get_item_count("copper-plate") == 5 and cards_in(buffer) + cards_in(back) == before,
			"mined: " .. line(buffer.get_contents()))
		expect(not inv.valid, "the inventory of a removed bus is not destroyed")
		hand.destroy()
		buffer.destroy()
		back.destroy()
		me_report("CARDSLOTS", "ME storage bus card slots", problems, "a card taken, a wrong item back, the limit, a stack spread, "
			.. "a full bus, equal distribution refused, taken out, old cards first, mined with an unseen item")
	end

	--------------------------------------------------------------------------------
	--- issue #28: the window's inventory pane and card slots, clicked through the GUI module's functions with a script
	--- inventory standing for the player's main inventory and a slot of another one for the cursor
	--------------------------------------------------------------------------------

	local function pane_test()
		local st = storage.pane28
		if (st and st.done) or game.tick < 110 then return end
		st = { problems = {}, done = true }
		storage.pane28 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local s = game.surfaces[1]
		local b = s.create_entity{ name = "me-storage-bus", position = { CX + 38.5, CY + 6.5 }, force = "player", raise_built = true }
		local binv = b and remote.call(SB, "inventory", b)
		if not binv then return me_report("PANE", "ME window pane (storage bus)", { "no bus or no inventory" }) end
		local pinv = game.create_inventory(20)                 -- the player's main inventory
		local hold = game.create_inventory(1)
		local cursor = hold[1]
		local function click(slot, mode) return remote.call(GUI, "inventory_click", cursor, pinv, slot, mode, b) end
		local function bclick(slot, shift) return remote.call(GUI, "block_click", b, slot, cursor, pinv, shift) end
		local function info() return remote.call(SB, "info", b) or {} end
		local function n(i, name) return i.get_item_count(name) end
		local function all_cards()
			local c = 0
			for _, name in pairs(CARD) do c = c + n(binv, name) + n(pinv, name) + n(hold, name) end
			return c
		end
		pinv[1].set_stack{ name = CARD.capacity, count = 3 }
		pinv[2].set_stack{ name = "iron-plate", count = 10 }
		pinv[3].set_stack{ name = CARD.inverter, count = 2 }
		local total = all_cards()
		--- shift + click: a card into the first slot that takes it (a stack: one per empty slot)
		expect(click(1, "shift") == nil and n(binv, CARD.capacity) == 3 and not pinv[1].valid_for_read and info().max == 18 + 3 * 9,
			"shift + click of three capacity cards: " .. n(binv, CARD.capacity) .. " in the bus")
		--- a wrong item is refused and stays
		local why = click(2, "shift")
		expect(why == "not-here" and n(pinv, "iron-plate") == 10 and n(binv, "iron-plate") == 0, "shift + click of iron plates: " .. tostring(why))
		--- the kind's limit: one inverter card goes in, the other stays, a second try is refused
		click(3, "shift")
		why = click(3, "shift")
		expect(n(binv, CARD.inverter) == 1 and pinv[3].valid_for_read and pinv[3].count == 1 and why == "limit",
			"shift + click of two inverter cards: " .. n(binv, CARD.inverter) .. " in, " .. tostring(why))
		--- a click on a block slot with a wrong item in the cursor: refused, nothing moves
		cursor.set_stack{ name = "iron-plate", count = 5 }
		why = bclick(5, false)
		expect(why == "not-here" and cursor.valid_for_read and cursor.count == 5 and not binv[5].valid_for_read,
			"iron plates on a card slot: " .. tostring(why))
		pinv[10].transfer_stack(cursor)
		--- with a card in the cursor: one card goes in, the rest stays in the cursor
		cursor.set_stack{ name = CARD.fuzzy, count = 2 }
		total = total + 2
		expect(bclick(5, false) == nil and binv[5].valid_for_read and binv[5].name == CARD.fuzzy and cursor.count == 1 and info().fuzzy,
			"a fuzzy card clicked into slot 5: cursor " .. (cursor.valid_for_read and cursor.count or 0))
		--- a full bus refuses, the card stays in the cursor
		cursor.set_stack{ name = CARD.void, count = 1 }          -- (replaces the fuzzy card left in the cursor: the same total)
		why = bclick(1, false)
		expect(why == "full" and cursor.valid_for_read and cursor.name == CARD.void, "a full bus took a card: " .. tostring(why))
		pinv[11].transfer_stack(cursor)
		--- an empty cursor takes the card; shift + click takes it into the inventory
		expect(bclick(1, false) == nil and cursor.valid_for_read and cursor.name == CARD.capacity and info().max == 18 + 2 * 9,
			"a card taken into the cursor: max " .. line(info().max))
		pinv[12].transfer_stack(cursor)
		expect(bclick(2, true) == nil and not binv[2].valid_for_read and n(pinv, CARD.capacity) == 2,
			"a card shift-clicked into the inventory: " .. n(pinv, CARD.capacity))
		expect(all_cards() == total, "cards made or lost by the clicks: " .. all_cards() .. "/" .. total)
		--- the pane's own clicks: half a stack, one item put down, merge, pick up, put down, swap
		pinv[5].set_stack{ name = "stone", count = 10 }
		expect(click(5, "right") == nil and cursor.valid_for_read and cursor.count == 5 and pinv[5].count == 5, "half a stack: cursor "
			.. (cursor.valid_for_read and cursor.count or 0))
		click(6, "right")
		expect(pinv[6].valid_for_read and pinv[6].count == 1 and cursor.count == 4, "right click with a stack in the cursor puts one down")
		click(5, "left")
		expect(not cursor.valid_for_read and pinv[5].count == 9, "left click merges: " .. pinv[5].count)
		local _, picked = click(5, "left")
		expect(picked == "picked" and cursor.valid_for_read and cursor.count == 9 and not pinv[5].valid_for_read, "left click picks the stack up")
		click(7, "left")
		expect(not cursor.valid_for_read and pinv[7].valid_for_read and pinv[7].count == 9, "left click puts the stack down")
		cursor.set_stack{ name = "wood", count = 3 }
		click(2, "left")
		expect(cursor.valid_for_read and cursor.name == "iron-plate" and pinv[2].name == "wood", "left click swaps")
		cursor.clear()
		hold.destroy()
		pinv.destroy()
		me_report("PANE", "ME window pane (storage bus)", problems, "shift + click of cards, a wrong item and the limit refused, "
			.. "block slot clicks with a wrong item, a card, a full bus, an empty cursor, shift; half a stack, put one, merge, "
			.. "pick, put, swap; no card made or lost")
	end

	function T.tick()
		cards_test()
		priorities_test()
		slots_test()
		pane_test()
	end

	--- for tests_running() of control.lua
	function T.running(check)
		check(storage.cards17 and storage.cards17.done, "ME upgrade cards")
		check(storage.prio17 and storage.prio17.done, "ME priorities")
		check(storage.slots28 and storage.slots28.done, "ME storage bus card slots")
		check(storage.pane28 and storage.pane28.done, "ME window pane (storage bus)")
	end

	return T
end
