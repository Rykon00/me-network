--- Runtime test of me-network issue #386: the ME IO Port (scripts/fork-me-ioport.lua).
--- Network A (four 16k item cells and a fluid cell, 1000 iron plates) with four ports, network B (one 1k cell filled to
--- the brim) with one:
--- * P1, empty: a cell with 500 gears and 300 copper plates goes into A; the cell, empty, ends in the output slot.
--- * P2, fill: a cell partitioned for copper plates takes A's copper plates (the 300 of P1 and 200 more) and nothing else;
---   it ends in the output slot when the network has no more of them.
--- * P3, empty: a fluid cell with 5000 water goes into A's fluid cell.
--- * P4 on B, empty: a cell with 100 iron plates finds no room (B's cell is full): the port is parked ("net-full"), nothing
---   moves; a second cell put into B's drive wakes it and the plates go in.
--- * A speed card in P1's card slots: the factor of the buses (8).
--- * A void cell is refused by the input slot.
--- The ports' schedules are in the save and load check of control.lua (schedule_digest). Loaded by control.lua like lab.lua.

local NET, IOP = "gregtorio-me-network", "gregtorio-me-ioport"
local BX, BY = 140, 330                  -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, CHECK1, CHECK2 = 100, 700, 1000
local PORTS = { { 12.5, -0.5 }, { 13.5, -0.5 }, { 14.5, -0.5 }, { 15.5, -0.5 } }   -- P1 .. P4 (P4 is B's)

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "io port"
		power(s, fails, what, BX, BY)
		local ca = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local da = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 1000, ["copper-plate"] = 200 })
		local members = { ca, da }
		for i = 1, 3 do members[#members + 1] = me_place(s, fails, what, "me-io-port", BX + PORTS[i][1], BY + PORTS[i][2]) end
		H.me_connect(fails, what, members)
		--- network B, 10 tiles further down (power of its own: the first substation does not reach it)
		power(s, fails, what, BX, BY + 12)
		local cb = me_place(s, fails, what, "me-network-controller", BX + 7, BY + 10)
		local db = me_place(s, fails, what, "me-drive", BX + 8.5, BY + 9.5)
		local p4 = me_place(s, fails, what, "me-io-port", BX + PORTS[4][1], BY + 10 + PORTS[4][2])
		H.me_connect(fails, what, { cb, db, p4 })
		--- a spare drive (no network) where the test's cells are filled
		me_place(s, fails, what, "me-drive", BX + 20.5, BY + 20.5)
		return fails
	end

	function T.tick()
		local tick = game.tick
		local s = game.surfaces[1]
		local st = storage.ioport386
		local function port(i) return s.find_entity("me-io-port", { BX + PORTS[i][1], BY + PORTS[i][2] + (i == 4 and 10 or 0) }) end
		local ca = s.find_entity("me-network-controller", { BX + 7, BY })
		local cb = s.find_entity("me-network-controller", { BX + 7, BY + 10 })
		local db = s.find_entity("me-drive", { BX + 8.5, BY + 9.5 })
		local da = s.find_entity("me-drive", { BX + 8.5, BY - 0.5 })
		local spare = s.find_entity("me-drive", { BX + 20.5, BY + 20.5 })
		if tick == START then
			st = { problems = {}, done = false }
			storage.ioport386 = st
			local problems = st.problems
			local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
			if not (port(1) and port(2) and port(3) and port(4) and ca and cb and da and db and spare) then
				st.done = true
				return me_report("IOPORT", "ME IO Port", { "the test networks were not built" })
			end
			local inv = game.create_inventory(4)
			--- a cell of `name` holding `items` ({ key -> amount }; "fluid/<name>" for fluid), from the spare drive
			local function cell(name, items)
				inv[1].set_stack{ name = name, count = 1 }
				remote.call(NET, "insert_cell", spare, inv[1], 1)
				for key, n in pairs(items) do
					if key:find("^fluid/") then remote.call(NET, "store_fluid_in_drive", spare, key:sub(7), n)
					else remote.call(NET, "store_in_drive", spare, key, n) end
				end
				local out = game.create_inventory(1)
				remote.call(NET, "take_cell", spare, 1, out)
				inv[1].transfer_stack(out[1])
				out.destroy()
				return inv[1]
			end
			local function put(i, stack)
				local why = remote.call(IOP, "cell_click", port(i), 1, stack, inv, false)
				expect(why == nil and not stack.valid_for_read, "port " .. i .. ": the cell did not go in: " .. tostring(why))
			end
			--- network B's cell to the brim (a kind per type, then items until it refuses)
			local full = game.create_inventory(1)
			full[1].set_stack{ name = "me-1k-storage-cell", count = 1 }
			remote.call(NET, "insert_cell", db, full[1], 1)
			full.destroy()
			remote.call(NET, "store_in_drive", db, "stone", 100000)
			st.b_stone = remote.call(NET, "count", cb, "stone")
			put(1, cell("me-1k-storage-cell", { ["iron-gear-wheel"] = 500, ["copper-plate"] = 300 }))
			remote.call(IOP, "set_mode", port(2), "fill")
			inv[1].set_stack{ name = "me-1k-storage-cell", count = 1,
				tags = { fork_me_cell = { items = {}, partition = { ["copper-plate"] = true } } } }
			put(2, inv[1])
			--- the fluid: A needs a fluid cell
			local fc = game.create_inventory(1)
			fc[1].set_stack{ name = "me-16k-fluid-storage-cell", count = 1 }
			remote.call(NET, "insert_cell", da, fc[1], 5)
			fc.destroy()
			put(3, cell("me-1k-fluid-storage-cell", { ["fluid/water"] = 5000 }))
			put(4, cell("me-1k-storage-cell", { ["iron-plate"] = 100 }))
			--- a void cell is refused; a speed card gives the buses' factor
			if prototypes.item["me-void-storage-cell"] then
				inv[2].set_stack{ name = "me-void-storage-cell", count = 1 }
				local why = remote.call(IOP, "cell_click", port(1), 1, inv[2], inv, false)
				expect(why == "io-port-void" and inv[2].valid_for_read, "a void cell into the input slot: " .. tostring(why))
				inv[2].clear()
			end
			local cards = game.create_inventory(1)
			cards[1].set_stack{ name = "me-acceleration-card", count = 1 }
			local why = remote.call(IOP, "card_click", port(1), 1, cards[1], inv, false)
			local info = remote.call(IOP, "info", port(1)) or {}
			expect(why == nil and info.accel == 8, "a speed card in the port: " .. serpent.line({ why, info.accel }))
			cards.destroy()
			st.inv = inv
			return
		end
		if not st or st.done then return end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function count(c, key) return remote.call(NET, "count", c, key) end
		local function slot_cell(i, slot)
			local cells = remote.call(IOP, "cells", port(i))
			local stc = cells and cells[slot]
			if not (stc and stc.valid_for_read) then return nil end
			local t = stc.is_item_with_tags and stc.tags and stc.tags.fork_me_cell
			return t and t.items or {}
		end
		local function line(t) return serpent.line(t) end
		if tick == CHECK1 then
			--- P1: emptied into A, the empty cell in the output slot
			expect(count(ca, "iron-gear-wheel") == 500 and slot_cell(1, 1) == nil and slot_cell(1, 2) and next(slot_cell(1, 2)) == nil,
				"P1 emptied: A has " .. count(ca, "iron-gear-wheel") .. " gears; input " .. line(slot_cell(1, 1)) .. ", output " .. line(slot_cell(1, 2)))
			--- P2: the copper plates (200 + P1's 300) and nothing else
			local c2 = slot_cell(2, 2) or {}
			expect(c2["copper-plate"] == 500 and table_size(c2) == 1 and count(ca, "copper-plate") == 0 and count(ca, "iron-plate") == 1000,
				"P2 filled with copper only: " .. line(c2) .. "; A has " .. count(ca, "copper-plate") .. " copper, " .. count(ca, "iron-plate") .. " iron")
			expect((remote.call(IOP, "info", port(2)) or {}).status == "done", "P2 status " .. line(remote.call(IOP, "info", port(2))))
			--- P3: the water
			expect(math.abs(count(ca, "fluid/water") - 5000) < 1 and slot_cell(3, 2) and next(slot_cell(3, 2)) == nil,
				"P3 emptied its water: A has " .. count(ca, "fluid/water") .. ", output " .. line(slot_cell(3, 2)))
			--- P4: B is full: parked, nothing moved
			local i4 = remote.call(IOP, "info", port(4)) or {}
			expect(i4.parked == "net-full" and (slot_cell(4, 1) or {})["iron-plate"] == 100 and count(cb, "iron-plate") == 0,
				"P4 on a full network: " .. line({ i4.parked, i4.status, slot_cell(4, 1), count(cb, "iron-plate") }))
			--- room appears: a second cell in B's drive
			local more = game.create_inventory(1)
			more[1].set_stack{ name = "me-4k-storage-cell", count = 1 }
			remote.call(NET, "insert_cell", db, more[1], 2)
			more.destroy()
			return
		end
		if tick == CHECK2 then
			st.done = true
			expect(count(cb, "iron-plate") == 100 and slot_cell(4, 1) == nil and slot_cell(4, 2) and next(slot_cell(4, 2)) == nil,
				"P4 after room appeared: B has " .. count(cb, "iron-plate") .. " plates; input " .. line(slot_cell(4, 1)) .. ", output " .. line(slot_cell(4, 2)))
			expect(count(cb, "stone") == st.b_stone, "B's stone changed: " .. count(cb, "stone") .. " of " .. st.b_stone)
			if st.inv and st.inv.valid then st.inv.destroy() end
			st.inv = nil
			me_report("IOPORT", "ME IO Port", problems, "a cell emptied into the network, a partitioned cell filled, a fluid cell emptied, "
				.. "a full network parks the port until a cell gives room, a void cell refused, a speed card's factor")
		end
	end

	function T.running(check) check(storage.ioport386 and storage.ioport386.done, "ME IO Port") end
	return T
end
