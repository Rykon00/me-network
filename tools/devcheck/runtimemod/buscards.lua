--- Runtime test of me-network issue #413: the Capacity, Fuzzy and Inverter Card on the ME Import Bus and ME Export Bus. A network
--- with iron and copper plates, stone and the cards; export buses on chests A and D, import buses on chests B and C:
---   * a filter beyond the 9 of a bus without a card is kept but does nothing; two Capacity Cards give 27 filters and it
---     exports; one card taken out leaves 18 and the filter kept but idle again;
---   * with quality: the export bus with the filter "iron-plate" exports normal plates only, with a Fuzzy Card the uncommon
---     ones too; the import bus with the filter "copper-plate@uncommon" leaves normal copper plates, with a Fuzzy Card it takes
---     them;
---   * the import bus with an Inverter Card and the filter "stone" takes the wood and leaves the stone; the export bus refuses
---     the Inverter Card;
---   * a settings paste and a blueprint tag carry the 27 filters and the cards (taken from the network).
--- Loaded by control.lua: require("buscards")(H) returns { setup, tick, running }.

local NET, IO = "gregtorio-me-network", "gregtorio-me-io"
local BX, BY = -150, -30              -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 150
local CAP, FUZZY, INV = "me-capacity-card", "me-fuzzy-card", "me-inverter-card"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH = { direction = defines.direction.south }
	local XS = { 10.5, 12.5, 14.5, 16.5 }    -- export E, import I, export E2, import I2

	function T.setup(s)
		local fails = {}
		local what = "bus cards"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 200, ["copper-plate"] = 200, stone = 50,
			[CAP] = 6, [FUZZY] = 4, [INV] = 2 })
		local members = { ctrl, drive }
		for i, x in ipairs(XS) do
			local name = (i % 2 == 0) and "me-import-bus" or "me-export-bus"
			members[#members + 1] = me_place(s, fails, what, name, BX + x, BY + 0.5, SOUTH)
			me_place(s, fails, what, "iron-chest", BX + x, BY + 1.5)
		end
		for x = 9.5, 16.5 do me_place(s, fails, what, "me-cable", BX + x, BY - 0.5) end
		H.me_connect(fails, what, members)
		return fails
	end

	function T.tick()
		local st = storage.buscards413
		if (st and st.done) or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.buscards413 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local function report()
			me_report("BUSCARDS", "Capacity, Fuzzy and Inverter Card on the import and export bus", problems, "27 filters with two "
				.. "Capacity Cards, kept filters idle; fuzzy export and import; inverter import, refused on the export bus; paste "
				.. "and blueprint tag")
		end
		local ctrl = find("me-network-controller", 7, 0)
		local E, I, E2, I2 = find("me-export-bus", XS[1], 0.5), find("me-import-bus", XS[2], 0.5), find("me-export-bus", XS[3], 0.5),
			find("me-import-bus", XS[4], 0.5)
		local A, B, D, C = find("iron-chest", XS[1], 1.5), find("iron-chest", XS[2], 1.5), find("iron-chest", XS[3], 1.5),
			find("iron-chest", XS[4], 1.5)
		if not (ctrl and E and I and E2 and I2 and A and B and C and D) then expect(false, "entities missing") return report() end
		local inv = game.create_inventory(2)
		local function put(bus, card)
			inv[1].set_stack{ name = card, count = 1 }
			local why = remote.call(IO, "bus_card_click", bus, 1, inv[1], inv, false)
			local ok = why == nil and not inv[1].valid_for_read
			inv[1].clear()
			return ok, why
		end
		local function info(bus) return remote.call(IO, "bus_info", bus) or {} end
		local a, b, c = A.get_inventory(defines.inventory.chest), B.get_inventory(defines.inventory.chest),
			C.get_inventory(defines.inventory.chest)
		local function step(bus, n) for _ = 1, n or 1 do remote.call(IO, "step", bus) end end

		--- 18 filters of items the network does not hold, then iron plates as the 19th
		local used = { ["iron-plate"] = true, ["copper-plate"] = true, stone = true, wood = true, [CAP] = true, [FUZZY] = true, [INV] = true }
		local names = {}
		for name, p in pairs(prototypes.item) do
			if p.type == "item" and not used[name] and not p.hidden and not p.parameter then names[#names + 1] = name end
		end
		table.sort(names)
		local list = {}
		for i = 1, 18 do list[i] = names[i] end
		list[19] = "iron-plate"

		--- Capacity Cards
		remote.call(IO, "set_bus_filters", E, list)
		local d = info(E)
		expect(#(d.filters or {}) == 19 and d.max == 9 and d.kept == true, "without a card: 19 filters kept, 9 apply, kept shown: "
			.. #(d.filters or {}) .. ", " .. tostring(d.max) .. ", " .. tostring(d.kept))
		step(E, 3)
		expect(a.get_item_count("iron-plate") == 0, "a kept filter beyond the 9 exports nothing: " .. a.get_item_count("iron-plate"))
		expect(put(E, CAP) and put(E, CAP), "two Capacity Cards go into the export bus")
		local ok3, why3 = put(E, CAP)
		expect(not ok3 and why3 == "limit", "a third Capacity Card is refused (limit): " .. tostring(why3))
		d = info(E)
		expect(d.max == 27 and not d.kept, "two Capacity Cards: 27 filters apply, none kept aside: " .. tostring(d.max) .. ", "
			.. tostring(d.kept))
		step(E, 3)
		expect(a.get_item_count("iron-plate") > 0, "the 19th filter exports with the cards: " .. a.get_item_count("iron-plate"))
		inv[1].clear()
		remote.call(IO, "bus_card_click", E, 1, inv[1], inv, false)                      -- a card into the hand
		expect(inv[1].valid_for_read and inv[1].name == CAP, "a Capacity Card is taken out")
		inv[1].clear()
		d = info(E)
		expect(d.max == 18 and d.kept == true and #(d.filters or {}) == 19, "one card: 18 filters apply, the 19th is kept: "
			.. tostring(d.max) .. ", " .. tostring(d.kept) .. ", " .. #(d.filters or {}))
		a.clear()
		step(E, 3)
		expect(a.is_empty(), "the kept filter is idle again: " .. a.get_item_count("iron-plate"))
		expect(put(E, CAP), "the Capacity Card goes back in")

		--- Fuzzy Card (needs quality)
		local Q = script.feature_flags.quality and prototypes.quality.uncommon and "uncommon" or nil
		if Q then
			remote.call(NET, "insert", ctrl, "iron-plate", 20, Q)
			remote.call(IO, "set_bus_filters", E, { "iron-plate" })
			a.clear()
			step(E, 4)
			local up = a.get_item_count({ name = "iron-plate", quality = Q })
			expect(a.get_item_count("iron-plate") > 0 and up == 0, "without a Fuzzy Card the export bus exports normal plates only: "
				.. a.get_item_count("iron-plate") .. " normal, " .. up .. " uncommon")
			expect(put(E, FUZZY), "the Fuzzy Card goes into the export bus")
			expect(info(E).fuzzy == true, "the window data says fuzzy")
			a.clear()
			step(E, 6)
			up = a.get_item_count({ name = "iron-plate", quality = Q })
			expect(up > 0, "with a Fuzzy Card the export bus exports the uncommon plates too: " .. up)
			b.insert{ name = "copper-plate", count = 30 }
			remote.call(IO, "set_bus_filters", I, { "copper-plate@" .. Q })
			step(I, 3)
			expect(b.get_item_count("copper-plate") == 30, "without a Fuzzy Card the filter copper-plate@" .. Q .. " leaves normal "
				.. "plates: " .. b.get_item_count("copper-plate"))
			expect(put(I, FUZZY), "the Fuzzy Card goes into the import bus")
			step(I, 3)
			expect(b.get_item_count("copper-plate") == 0, "with a Fuzzy Card the import bus takes them: "
				.. b.get_item_count("copper-plate") .. " left")
		end

		--- Inverter Card
		c.insert{ name = "stone", count = 30 }
		c.insert{ name = "wood", count = 30 }
		remote.call(IO, "set_bus_filters", I2, { "stone" })
		expect(put(I2, INV), "the Inverter Card goes into the import bus")
		expect(info(I2).inverted == true, "the window data says blacklist")
		step(I2, 4)
		expect(c.get_item_count("wood") == 0 and c.get_item_count("stone") == 30, "with an Inverter Card the import bus takes "
			.. "everything but stone: wood " .. c.get_item_count("wood") .. ", stone " .. c.get_item_count("stone") .. " left")
		local ok, why = put(E2, INV)
		expect(not ok and why == "not-here", "the export bus refuses the Inverter Card: " .. tostring(why))

		--- copying
		remote.call(IO, "set_bus_filters", E, list)
		remote.call(IO, "paste", E, E2)
		d = info(E2)
		expect(#(d.filters or {}) == 19 and d.max == 27 and d.fuzzy == (Q ~= nil),
			"a settings paste carries the filters and the cards (from the network): " .. #(d.filters or {}) .. ", "
			.. tostring(d.max) .. ", fuzzy " .. tostring(d.fuzzy))
		local all = {}
		for i = 1, 27 do all[i] = names[i] end
		remote.call(IO, "built", E2, { fork_me_bus = { filters = all, cards = { CAP, CAP } } })
		d = info(E2)
		expect(#(d.filters or {}) == 27 and d.max == 27, "a blueprint tag carries 27 filters and the cards: "
			.. #(d.filters or {}) .. ", " .. tostring(d.max))
		inv.destroy()
		return report()
	end

	function T.running(check) check(storage.buscards413 and storage.buscards413.done, "Capacity, Fuzzy and Inverter Card on the buses") end

	return T
end
