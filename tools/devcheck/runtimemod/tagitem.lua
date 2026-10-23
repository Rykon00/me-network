--- Runtime test of me-network issue #479: items of the type item-with-tags (Quality Turrets Reworked makes every turret one)
--- through storage buses, and an import bus that meets a stack the network cannot take. The item is
--- `zz-devcheck-tagged-wall` of data.lua (it places a copy of the stone wall, so a stack of it can be damaged).
--- * Network A has a storage bus on a chest and no cell. Untagged items of the type go through the import bus into the
---   chest, are counted by the terminal and taken out by an export bus; the ones put into the chest by hand are seen. A
---   damaged stack (issue #84) and a stack with tags in that chest are neither counted nor taken. A stack with tags (no label)
---   and one with a label in the import bus's chest stay there: no storage of this network can ever take the first, the
---   second is refused (`cannot-store-label`). The bus does not park for them as "net-full": iron plates put into the same
---   chest afterwards are in the network within LIMIT ticks. An ME IO Port of A empties a cell of B that holds the item with
---   tags: no storage of A can take it, so the port waits for room ("net-full") and the cell keeps it.
--- * Network B has cells and a storage bus of a higher priority: the untagged items go into the bus's chest, the one with
---   tags into a cell, never into the chest. An ME Interface of B with a row of 1 of the item holds one with tags and 2
---   untagged ones: its surplus is the 2 untagged ones (into the chest too); the one with tags stays in it with its tags (on
---   main the whole-stack removal of the surplus did not look at tags).
--- * Network C: its storage bus's chest has no free slot and one stack of iron plates that is not full. Copper plates in the
---   import bus's chest have no room; iron plates put there afterwards are taken within LIMIT ticks.
--- On main the storage buses show and move none of the item and the import buses of A and C park as "net-full" (woken only
--- by room for their key, at the latest by the fallback visit 3600 ticks later). Loaded by control.lua: require("tagitem")(H)
--- returns { setup, tick, running } like margin.lua.

local NET, IO, SBUS, IOP = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-storagebus", "gregtorio-me-ioport"
local BX, BY = 380, 190                   -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, CHECK1, CHECK2, DEADLINE, CHECK3 = 100, 400, 700, 1150, 1300
local LIMIT = 400                         -- ticks: the idle limit of the import buses (300 by default) and a margin
local ITEM = "zz-devcheck-tagged-wall"
local PLATES = 20

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local NORTH = { direction = defines.direction.north }
	local SOUTH = { direction = defines.direction.south }

	function T.setup(s)
		local fails = {}
		local what = "tagitem"
		local sc = {}
		--- network A: a storage bus only
		power(s, fails, what, BX, BY)
		sc.ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		sc.term = me_place(s, fails, what, "me-terminal", BX + 8.5, BY - 0.5)
		sc.sbus = me_place(s, fails, what, "me-storage-bus", BX + 10.5, BY - 0.5, NORTH)
		sc.schest = me_place(s, fails, what, "steel-chest", BX + 10.5, BY - 1.5)
		sc.ibus = me_place(s, fails, what, "me-import-bus", BX + 12.5, BY + 0.5, SOUTH)
		sc.ichest = me_place(s, fails, what, "iron-chest", BX + 12.5, BY + 1.5)
		sc.ebus = me_place(s, fails, what, "me-export-bus", BX + 14.5, BY + 0.5, SOUTH)
		sc.echest = me_place(s, fails, what, "iron-chest", BX + 14.5, BY + 1.5)
		sc.port = me_place(s, fails, what, "me-io-port", BX + 16.5, BY - 0.5)
		me_connect(fails, what, { sc.ctrl, sc.term, sc.sbus, sc.ibus, sc.ebus, sc.port })
		--- network B: cells and a storage bus before them
		power(s, fails, what, BX, BY + 12)
		sc.ctrl_b = me_place(s, fails, what, "me-network-controller", BX + 7, BY + 12)
		sc.drive_b = me_drive(s, fails, what, BX + 8.5, BY + 11.5, {}, "1k")
		sc.sbus_b = me_place(s, fails, what, "me-storage-bus", BX + 10.5, BY + 11.5, NORTH)
		sc.schest_b = me_place(s, fails, what, "steel-chest", BX + 10.5, BY + 10.5)
		sc.ibus_b = me_place(s, fails, what, "me-import-bus", BX + 12.5, BY + 12.5, SOUTH)
		sc.ichest_b = me_place(s, fails, what, "iron-chest", BX + 12.5, BY + 13.5)
		sc.iface_b = me_place(s, fails, what, "me-network-interface", BX + 16.5, BY + 11.5)
		me_connect(fails, what, { sc.ctrl_b, sc.drive_b, sc.sbus_b, sc.ibus_b, sc.iface_b })
		--- network C: a storage bus whose chest has room for iron plates only
		power(s, fails, what, BX, BY + 24)
		sc.ctrl_c = me_place(s, fails, what, "me-network-controller", BX + 7, BY + 24)
		sc.sbus_c = me_place(s, fails, what, "me-storage-bus", BX + 10.5, BY + 23.5, NORTH)
		sc.schest_c = me_place(s, fails, what, "wooden-chest", BX + 10.5, BY + 22.5)
		sc.ibus_c = me_place(s, fails, what, "me-import-bus", BX + 12.5, BY + 24.5, SOUTH)
		sc.ichest_c = me_place(s, fails, what, "iron-chest", BX + 12.5, BY + 25.5)
		me_connect(fails, what, { sc.ctrl_c, sc.sbus_c, sc.ibus_c })
		storage.tagitem479_scene = sc
		return fails
	end

	local function inv_of(e) return e.get_inventory(defines.inventory.chest) end
	--- the items of the item in an inventory, by what their stacks carry
	local function census(inv)
		local c = { whole = 0, damaged = 0, tagged = 0, labelled = 0 }
		for i = 1, #inv do
			local st = inv[i]
			if st.valid_for_read and st.name == ITEM then
				if st.label then c.labelled = c.labelled + st.count
				elseif next(st.tags) then c.tagged = c.tagged + st.count
				elseif st.health < 1 then c.damaged = c.damaged + st.count
				else c.whole = c.whole + st.count end
			end
		end
		return c
	end
	local function kills(inv)
		for i = 1, #inv do
			local st = inv[i]
			if st.valid_for_read and st.name == ITEM and not st.label and next(st.tags) then return st.tags.kills, st.count end
		end
		return nil
	end

	function T.tick()
		local tick = game.tick
		local sc = storage.tagitem479_scene
		local st = storage.tagitem479
		if not st then
			if tick < START or not sc then return end
			st = { problems = {}, done = false }
			storage.tagitem479 = st
			local ok = true
			for _, e in pairs(sc) do ok = ok and e and e.valid end
			if not ok then
				st.problems[#st.problems + 1] = "the test networks were not built"
				st.done = true
				return me_report("TAGITEM", "ME items with tags through storage buses", st.problems, "no network")
			end
			for _, bus in pairs({ sc.ibus, sc.ibus_b, sc.ibus_c }) do remote.call(IO, "set_bus_filters", bus, {}) end   -- everything
			remote.call(SBUS, "set_settings", sc.sbus_b, { priority = 10 })
			--- A: a stack with tags and a damaged stack lie in the storage bus's chest; 5 untagged ones come through the import bus
			local chest = inv_of(sc.schest)
			chest[1].set_stack{ name = ITEM, count = 1 }
			chest[1].tags = { kills = 3 }
			chest[2].set_stack{ name = ITEM, count = 2, health = 0.5 }
			inv_of(sc.ichest).insert{ name = ITEM, count = 5 }
			--- B: 3 untagged ones and one with tags
			local ib = inv_of(sc.ichest_b)
			ib[1].set_stack{ name = ITEM, count = 3 }
			ib[2].set_stack{ name = ITEM, count = 1 }
			ib[2].tags = { kills = 2 }
			--- B: the interface's row wants 1; it holds one with tags and 2 untagged ones
			local fi = inv_of(sc.iface_b)
			fi[1].set_stack{ name = ITEM, count = 1 }
			fi[1].tags = { kills = 5 }
			fi[2].set_stack{ name = ITEM, count = 2 }
			remote.call(IO, "set_interface_slot", sc.iface_b, 1, ITEM, "normal", 1)
			--- C: the storage bus's chest full but for room for iron plates; copper plates in the import bus's chest
			local cc = inv_of(sc.schest_c)
			for i = 1, #cc - 1 do cc[i].set_stack{ name = "stone", count = prototypes.item["stone"].stack_size } end
			cc[#cc].set_stack{ name = "iron-plate", count = 10 }
			inv_of(sc.ichest_c).insert{ name = "copper-plate", count = 5 }
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		for _, e in pairs(sc) do
			if not (e and e.valid) then
				problems[#problems + 1] = "an entity of the test networks is gone"
				st.done = true
				return me_report("TAGITEM", "ME items with tags through storage buses", problems, "")
			end
		end
		local function count(e, name) return remote.call(NET, "count", e, name) end
		--- the items with tags of the item in a network
		local function tagged_in(e)
			local n = 0
			for key, c in pairs(remote.call(NET, "contents", e)) do      -- (key -> count)
				if key:find(ITEM .. "@normal#", 1, true) == 1 then n = n + c end
			end
			return n
		end
		local function sched(bus) return remote.call(IO, "schedule", bus) or {} end
		if tick < CHECK1 then return end
		if not st.c1 then
			st.c1 = true
			local a, ia = census(inv_of(sc.schest)), census(inv_of(sc.ichest))
			expect(ia.whole == 0, "network A: " .. ia.whole .. " untagged items were not imported into the storage bus's chest")
			expect(a.whole == 5, "network A: the storage bus's chest holds " .. a.whole .. " untagged items, not 5")
			expect(count(sc.term, ITEM) == 5, "network A: the terminal counts " .. count(sc.term, ITEM) .. " of the item, not 5 (the damaged and the tagged stack are no part of it)")
			local k, n = kills(inv_of(sc.schest))
			expect(k == 3 and n == 1 and a.tagged == 1 and a.damaged == 2,
				"network A: the tagged stack (" .. tostring(k) .. ", " .. tostring(n) .. ") or the damaged one (" .. a.damaged .. ") in the storage bus's chest changed")
			local b, ib = census(inv_of(sc.schest_b)), census(inv_of(sc.ichest_b))
			expect(ib.whole == 0 and ib.tagged == 0, "network B: the import bus left " .. serpent.line(ib))
			expect(b.whole == 5, "network B: the storage bus's chest holds " .. b.whole .. " untagged items, not 5 (3 imported, 2 of the interface's surplus; it comes before the cells)")
			expect(b.tagged == 0, "network B: the item with tags went into the storage bus's chest")
			local tagged = tagged_in(sc.ctrl_b)
			expect(tagged == 1, "network B: the cells hold " .. tagged .. " items with tags, not 1")
			local fi = census(inv_of(sc.iface_b))
			expect(fi.tagged == 1 and fi.whole == 0 and kills(inv_of(sc.iface_b)) == 5,
				"network B: the interface's surplus was not its 2 untagged ones (it holds " .. serpent.line(fi) .. ")")
			--- the cell of B with the item with tags into A's IO Port
			local cinv = game.create_inventory(1)
			local found = false
			for slot = 1, 4 do
				remote.call(NET, "take_cell", sc.drive_b, slot, cinv)
				if cinv[1].valid_for_read then
					if tagged_in(sc.ctrl_b) == 0 then found = true break end
					remote.call(NET, "insert_cell", sc.drive_b, cinv[1], slot)
				end
			end
			expect(found, "network B: no cell of its drive held the item with tags")
			if found then
				local why = remote.call(IOP, "cell_click", sc.port, 1, cinv[1], cinv, false)
				expect(why == nil, "the cell did not go into the IO Port: " .. tostring(why))
			end
			cinv.destroy()
			--- A: 4 put into the chest by hand; a stack with tags and one with a label into the import bus's chest
			inv_of(sc.schest).insert{ name = ITEM, count = 4 }
			local ic = inv_of(sc.ichest)
			ic[1].set_stack{ name = ITEM, count = 1 }
			ic[1].tags = { kills = 7 }
			ic[2].set_stack{ name = ITEM, count = 1 }
			ic[2].label = "veteran"
			--- the label is refused as such
			local tmp = game.create_inventory(1)
			tmp[1].set_stack{ name = ITEM, count = 1 }
			tmp[1].label = "veteran"
			local n2, why = remote.call(NET, "insert_stack", sc.ctrl_b, tmp[1])
			expect(n2 == nil and why == "cannot-store-label", "an item with a label was not refused as cannot-store-label: " .. tostring(n2) .. ", " .. tostring(why))
			tmp.destroy()
			return
		end
		if tick < CHECK2 then return end
		if not st.put then
			expect(count(sc.term, ITEM) == 9, "network A: the terminal counts " .. count(sc.term, ITEM) .. " of the item, not 9 (4 were put into the chest by hand)")
			local ia = census(inv_of(sc.ichest))
			expect(ia.tagged == 1 and ia.labelled == 1, "network A: the stacks with tags and with a label left the import bus's chest: " .. serpent.line(ia))
			expect(census(inv_of(sc.schest)).tagged == 1, "network A: an item with tags went into the storage bus's chest")
			local a, c = sched(sc.ibus), sched(sc.ibus_c)
			expect(a.block ~= "net-full" and a.parked == nil, "network A: the import bus is parked for stacks no storage can take: " .. serpent.line(a))
			expect(c.parked == nil, "network C: the import bus is parked for the copper plates: " .. serpent.line(c))
			expect(inv_of(sc.ichest_c).get_item_count("copper-plate") == 5, "network C: copper plates went in without room")
			local p = remote.call(IOP, "schedule", sc.port) or {}
			local cell = remote.call(IOP, "cells", sc.port)[1]
			expect(p.parked == "net-full" and cell.valid_for_read and tagged_in(sc.ctrl) == 0,
				"network A: the IO Port with a cell it cannot empty does not wait for room with the cell in its input slot: " .. serpent.line(p))
			inv_of(sc.ichest).insert{ name = "iron-plate", count = PLATES }
			inv_of(sc.ichest_c).insert{ name = "iron-plate", count = PLATES }
			st.put = tick
			return
		end
		if not st.lat_a and count(sc.ctrl, "iron-plate") >= PLATES then st.lat_a = tick - st.put end
		if not st.lat_c and count(sc.ctrl_c, "iron-plate") >= 10 + PLATES then st.lat_c = tick - st.put end
		if not st.exporting and ((st.lat_a and st.lat_c) or tick >= DEADLINE) then
			expect(st.lat_a ~= nil and st.lat_a <= LIMIT, "network A: the iron plates that came after the stacks it cannot take were taken after "
				.. tostring(st.lat_a) .. " ticks, not within " .. LIMIT .. ": " .. serpent.line(sched(sc.ibus)))
			expect(st.lat_c ~= nil and st.lat_c <= LIMIT, "network C: the iron plates that came after the copper plates without room were taken after "
				.. tostring(st.lat_c) .. " ticks, not within " .. LIMIT .. ": " .. serpent.line(sched(sc.ibus_c)))
			--- the export bus takes every untagged one out of A's storage bus chest
			remote.call(IO, "set_bus_filters", sc.ebus, { ITEM })
			st.exporting = tick
			return
		end
		if not st.exporting or tick < CHECK3 then return end
		local a, e = census(inv_of(sc.schest)), census(inv_of(sc.echest))
		expect(e.whole == 9 and e.tagged == 0 and e.damaged == 0, "network A: the export bus moved " .. serpent.line(e) .. ", not the 9 untagged items")
		expect(a.whole == 0 and a.tagged == 1 and a.damaged == 2, "network A: the storage bus's chest holds " .. serpent.line(a) .. " after the export")
		expect(kills(inv_of(sc.schest)) == 3, "network A: the tagged stack lost its tags")
		expect(count(sc.term, ITEM) == 0, "network A: the terminal still counts " .. count(sc.term, ITEM) .. " of the item")
		st.done = true
		me_report("TAGITEM", "ME items with tags through storage buses", problems, "untagged ones through a storage bus (import, count, export, by hand), tagged ones only into cells, iron plates after an untakeable stack in "
			.. tostring(st.lat_a) .. " and after a key without room in " .. tostring(st.lat_c) .. " ticks")
	end

	function T.running(check) check(storage.tagitem479 and storage.tagitem479.done, "ME items with tags through storage buses") end
	return T
end
