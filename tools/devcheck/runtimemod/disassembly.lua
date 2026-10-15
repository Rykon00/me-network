--- Runtime test of me-network issue #387: an empty storage cell taken apart in the ME Cell Workbench (AE2's disassembly).
--- * An empty 1k item cell gives the item ingredients of its recipe (the housing and the component; with Gregtorio its GT
---   recipe's), in the cell's quality, and the cell is gone; crafting the parts again gives the cell back (the parts are the
---   recipe's, so nothing is gained).
--- * Its cards stay in the workbench's card slots; its partition goes with it (no copy mode).
--- * A cell holding one item and a fluid cell holding water are refused ("not-empty") and stay; a void cell is refused
---   ("void"); an empty fluid cell is taken apart.
--- No network: the workbench needs none, the drive fills cells without power. Loaded by control.lua like lab.lua.

local NET, WB = "gregtorio-me-network", "gregtorio-me-workbench"
local BX, BY = 60, 340                   -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 80

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	function T.setup(s)
		local fails = {}
		me_place(s, fails, "disassembly", "me-drive", BX + 0.5, BY + 0.5)
		me_place(s, fails, "disassembly", "me-cell-workbench", BX + 3.5, BY + 0.5)
		return fails
	end

	function T.tick()
		if game.tick ~= START then return end
		local s = game.surfaces[1]
		local problems = {}
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function line(t) return serpent.line(t) end
		local drive = s.find_entity("me-drive", { BX + 0.5, BY + 0.5 })
		local wb = s.find_entity("me-cell-workbench", { BX + 3.5, BY + 0.5 })
		storage.disassembly387 = { done = true }
		if not (drive and wb) then return me_report("DISASSEMBLY", "ME cell disassembly", { "entities missing" }) end
		local back = game.create_inventory(20)
		local hold = game.create_inventory(4)
		local hand = hold[1]
		local function info() return remote.call(WB, "info", wb) or {} end
		local function put(stack)
			hand.clear()
			hand.transfer_stack(stack)
			return remote.call(WB, "cell_click", wb, hand, back, false)
		end
		--- a cell of `name` (quality `q`) holding `what` (an item or "fluid/<name>") from the drive, or an empty one
		local function cell(name, q, what, amount)
			local tmp = hold[2]
			tmp.set_stack{ name = name, count = 1, quality = q or "normal" }
			if not what then return tmp end
			remote.call(NET, "insert_cell", drive, tmp, 1)
			if what:find("^fluid/") then remote.call(NET, "store_fluid_in_drive", drive, what:sub(7), amount)
			else remote.call(NET, "store_in_drive", drive, what, amount) end
			local out = game.create_inventory(1)
			remote.call(NET, "take_cell", drive, 1, out)
			tmp.transfer_stack(out[1])
			out.destroy()
			return tmp
		end
		local function recipe_parts(name)
			local out = {}
			for _, ing in pairs(prototypes.recipe[name].ingredients) do
				if ing.type == "item" then out[ing.name] = (out[ing.name] or 0) + ing.amount end
			end
			return out
		end
		local function got(q)
			local out = {}
			for _, c in pairs(back.get_contents()) do
				if (c.quality or "normal") == (q or "normal") then out[c.name] = (out[c.name] or 0) + c.count end
			end
			return out
		end

		--- an empty item cell (uncommon, straight from the hand): its recipe's items in its quality, the cell gone
		local q = prototypes.quality["uncommon"] and "uncommon" or "normal"
		local want = recipe_parts("me-1k-storage-cell")
		expect(put(cell("me-1k-storage-cell", q)) == nil and info().cell, "the empty cell in the workbench")
		local i = info()
		expect(i.cell and i.cell.disassemble == true and #(i.cell.parts or {}) > 0, "the window offers the disassembly " .. line(i.cell))
		local ok, why = remote.call(WB, "disassemble", wb, back)
		expect(ok == true, "an empty cell was refused: " .. tostring(why))
		expect(line(got(q)) == line(want), "the parts of the empty " .. q .. " cell: " .. line(back.get_contents()) .. ", its recipe: " .. line(want))
		expect(want["basic-storage-housing"] == 1 and want["me-1k-storage-component"] == 1, "the 1k cell's recipe has a housing and a 1k component: " .. line(want))
		expect(info().cell == nil and remote.call(WB, "inventory", wb)[1].valid_for_read == false, "the cell is gone")
		back.clear()
		--- one with a card and a partition: the card stays in its slot, the partition goes with the cell (no copy mode)
		expect(put(cell("me-1k-storage-cell")) == nil, "the second empty cell in the workbench")
		remote.call(WB, "set_partition_slot", wb, 1, "iron-plate")
		local cards = game.create_inventory(1)
		cards[1].set_stack{ name = "me-inverter-card", count = 1 }
		remote.call(WB, "card_click", wb, 1, cards[1], back, false)
		cards.destroy()
		ok, why = remote.call(WB, "disassemble", wb, back)
		expect(ok == true and line(got()) == line(want), "the cell with a card and a partition: " .. line({ ok, why, got() }))
		local slots = remote.call(WB, "inventory", wb)
		expect(slots[2].valid_for_read and slots[2].name == "me-inverter-card", "the card stays in the card slot")
		expect(#(info().config or {}) == 0, "the partition went with the cell (no copy mode): " .. line(info().config))
		slots[2].clear()
		back.clear()

		--- a cell holding one item, a fluid cell holding water: refused, and they stay
		expect(put(cell("me-1k-storage-cell", nil, "iron-plate", 1)) == nil, "the full cell in the workbench")
		ok, why = remote.call(WB, "disassemble", wb, back)
		expect(ok == false and why == "not-empty" and info().cell and info().cell.disassemble == "not-empty",
			"a cell with one item: " .. line({ ok, why, info().cell and info().cell.disassemble }))
		expect(back.is_empty(), "a refused cell gave parts")
		hand.clear()
		remote.call(WB, "cell_click", wb, hand, back, false)                 -- (taken out again)
		hand.clear()
		expect(put(cell("me-1k-fluid-storage-cell", nil, "fluid/water", 100)) == nil, "the fluid cell in the workbench")
		ok, why = remote.call(WB, "disassemble", wb, back)
		expect(ok == false and why == "not-empty", "a fluid cell with water: " .. line({ ok, why }))
		hand.clear()
		remote.call(WB, "cell_click", wb, hand, back, false)
		hand.clear()
		--- an empty fluid cell: its recipe's items
		expect(put(cell("me-1k-fluid-storage-cell")) == nil, "the empty fluid cell in the workbench")
		ok, why = remote.call(WB, "disassemble", wb, back)
		local wantf = recipe_parts("me-1k-fluid-storage-cell")
		expect(ok == true and line(got()) == line(wantf), "the empty fluid cell: " .. line({ ok, why, got() }) .. ", its recipe: " .. line(wantf))
		back.clear()
		--- a void cell has no component
		if prototypes.item["me-void-storage-cell"] then
			expect(put(cell("me-void-storage-cell")) == nil, "the void cell in the workbench")
			ok, why = remote.call(WB, "disassemble", wb, back)
			expect(ok == false and why == "void" and back.is_empty(), "a void cell: " .. line({ ok, why }))
		end
		back.destroy()
		hold.destroy()
		me_report("DISASSEMBLY", "ME cell disassembly", problems, "an empty " .. q .. " item cell into its recipe's items in its quality, its card"
			.. " kept, the partition gone; a cell with an item and one with water refused; an empty fluid cell; a void cell refused")
	end

	function T.running(check) check(storage.disassembly387 and storage.disassembly387.done, "ME cell disassembly") end
	return T
end
