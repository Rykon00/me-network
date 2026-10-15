--- Runtime test of me-network issue #394: a storage cell item keeps its quality wherever the mod writes its stack.
--- An uncommon 1k cell (a game without the quality mod skips the test with a note):
--- * in the ME Cell Workbench: a partition and a card change it, it is taken out by a click: still uncommon;
--- * into a drive, items stored, taken out (take_cell): uncommon, with its items;
--- * into a drive again and the drive mined (its cells into the buffer): uncommon;
--- * through an ME IO Port (emptied into a network): uncommon in the output slot.
--- Loaded by control.lua like lab.lua.

local NET, WB, IOP = "gregtorio-me-network", "gregtorio-me-workbench", "gregtorio-me-ioport"
local BX, BY = 100, 360                  -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, CHECK = 100, 400
local CELL = "me-1k-storage-cell"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "cell quality"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {})
		local port = me_place(s, fails, what, "me-io-port", BX + 10.5, BY - 0.5)
		H.me_connect(fails, what, { ctrl, drive, port })
		me_place(s, fails, what, "me-cell-workbench", BX + 14.5, BY + 3.5)
		me_place(s, fails, what, "me-drive", BX + 16.5, BY + 3.5)                    -- (no network: filled and mined)
		return fails
	end

	function T.tick()
		local tick = game.tick
		if tick ~= START and tick ~= CHECK then return end
		local s = game.surfaces[1]
		local q = prototypes.quality["uncommon"] and "uncommon" or nil
		local st = storage.cellquality394
		if tick == START then
			st = { problems = {}, done = false }
			storage.cellquality394 = st
			if not q then
				st.done = true
				return me_report("CELLQUALITY", "ME cell item quality", {}, "no quality mod: skipped")
			end
		end
		if not st or st.done then return end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local wb = s.find_entity("me-cell-workbench", { BX + 14.5, BY + 3.5 })
		local loose = s.find_entity("me-drive", { BX + 16.5, BY + 3.5 })
		local port = s.find_entity("me-io-port", { BX + 10.5, BY - 0.5 })
		local ctrl = s.find_entity("me-network-controller", { BX + 7, BY })
		if not (wb and port and ctrl and (loose or tick ~= START)) then          -- (the loose drive is mined at START)
			st.done = true
			return me_report("CELLQUALITY", "ME cell item quality", { "the test blocks were not built" })
		end
		local function quality_of(stack) return stack and stack.valid_for_read and stack.quality.name or "(none)" end
		if tick == START then
			local inv = game.create_inventory(8)
			local hand = inv[1]
			--- the workbench: a partition, a card, then taken out by a click
			hand.set_stack{ name = CELL, count = 1, quality = q }
			remote.call(WB, "cell_click", wb, hand, inv, false)
			remote.call(WB, "set_partition_slot", wb, 1, "iron-plate")
			inv[2].set_stack{ name = "me-inverter-card", count = 1 }
			remote.call(WB, "card_click", wb, 1, inv[2], inv, false)
			local inside = remote.call(WB, "inventory", wb)[1]
			expect(quality_of(inside) == q, "in the workbench after a partition and a card: " .. quality_of(inside))
			hand.clear()
			remote.call(WB, "cell_click", wb, hand, inv, false)
			expect(quality_of(hand) == q and hand.is_item_with_tags and hand.tags.fork_me_cell, "taken out of the workbench: " .. quality_of(hand))
			--- a drive: in, items stored, out
			remote.call(NET, "insert_cell", loose, hand, 1)
			remote.call(NET, "store_in_drive", loose, "copper-plate", 40)
			local out = game.create_inventory(1)
			remote.call(NET, "take_cell", loose, 1, out)
			local t = out[1].valid_for_read and out[1].is_item_with_tags and out[1].tags.fork_me_cell
			expect(quality_of(out[1]) == q and t and t.items and t.items["copper-plate"] == 40,
				"taken out of a drive: " .. quality_of(out[1]) .. " " .. serpent.line(t and t.items))
			--- the drive mined with the cell in it
			remote.call(NET, "insert_cell", loose, out[1], 1)
			local buffer = game.create_inventory(8)
			remote.call(NET, "removed", loose, buffer)                 -- (what mining it does: its cells into the buffer)
			loose.destroy()
			local mined = buffer.find_item_stack{ name = CELL, quality = q }       -- (a plain name finds normal quality only)
			expect(quality_of(mined) == q, "the cell of a mined drive: " .. quality_of(mined))
			--- the IO port empties it into the network
			if mined then
				hand.clear()
				hand.transfer_stack(mined)
				local why = remote.call(IOP, "cell_click", port, 1, hand, inv, false)
				expect(why == nil, "into the IO port: " .. tostring(why))
			end
			buffer.destroy()
			out.destroy()
			st.inv = inv
			return
		end
		st.done = true
		local cells = remote.call(IOP, "cells", port)
		local done = cells and cells[2]
		expect(quality_of(done) == q and remote.call(NET, "count", ctrl, "copper-plate") == 40,
			"the IO port's output: " .. quality_of(done) .. ", the network has " .. remote.call(NET, "count", ctrl, "copper-plate") .. " copper plates")
		if st.inv and st.inv.valid then st.inv.destroy() end
		st.inv = nil
		me_report("CELLQUALITY", "ME cell item quality", problems, "an " .. q .. " cell stays " .. q .. " through the workbench (partition, card, "
			.. "taken out), a drive (in, items, out), a mined drive and an IO port")
	end

	function T.running(check) check(storage.cellquality394 and storage.cellquality394.done, "ME cell item quality") end
	return T
end
