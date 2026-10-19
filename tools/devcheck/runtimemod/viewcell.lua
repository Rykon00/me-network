--- Runtime test of me-network issue #440: View Cells. A network with iron and copper plates, stone and water, an ME Terminal and
--- an ME Cell Workbench:
---   * a view cell in the workbench: it takes items and fluids (iron plate, water), its data says it is a view cell; taken out it
---     carries its list; an ME Drive refuses it (it is no storage cell); its description says what it is;
---   * the terminal's list without view cells: all four; with that cell in its first slot: iron plate and water; a second cell with
---     an Inverter Card naming iron plate: water only (a blacklist cell excludes, OR over the whitelists); the first taken out:
---     everything but iron plate; a cell in hand that is no view cell is refused;
---   * the terminal destroyed: its view cell is spilled where it stood.
--- Loaded by control.lua: require("viewcell")(H) returns { setup, tick, running }.

local NET, TERM, WB, VCR = "gregtorio-me-network", "gregtorio-me-terminal", "gregtorio-me-workbench", "gregtorio-me-viewcells"
local BX, BY = -100, 330              -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 175
local VIEW = "me-view-cell"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "view cells"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 10, ["copper-plate"] = 10, stone = 5 }, "16k")
		local fdrive = H.me_drive(s, fails, what, BX + 8.5, BY + 0.5, {}, "1k", true)
		local term = me_place(s, fails, what, "me-terminal", BX + 10.5, BY - 0.5)
		me_place(s, fails, what, "me-cell-workbench", BX + 14.5, BY + 4.5)
		H.me_connect(fails, what, { ctrl, drive, fdrive, term })
		return fails
	end

	function T.tick()
		local st = storage.viewcell440
		if game.tick < START or (st and st.done) then return end
		st = { problems = {} }
		storage.viewcell440 = st
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local function expect(ok, msg) if not ok then st.problems[#st.problems + 1] = msg end end
		local function report()
			st.done = true
			me_report("VIEWCELL", "View Cells", st.problems, "workbench (items and fluids), refused by a drive, the terminal's list "
				.. "by one cell, a blacklist cell and OR, a wrong item refused, spilled with the terminal")
		end
		local ctrl, drive, t, wb = find("me-network-controller", 7, 0), find("me-drive", 8.5, -0.5), find("me-terminal", 10.5, -0.5),
			find("me-cell-workbench", 14.5, 4.5)
		if not (ctrl and drive and t and wb) then expect(false, "entities missing") return report() end
		remote.call(NET, "insert_fluid", ctrl, "water", 100)
		local inv = game.create_inventory(10)
		local hand = inv[1]
		local function keys(views)
			local out = {}
			for _, e in ipairs(remote.call(TERM, "entries", t, "", "name", "all", true, 0, views) or {}) do out[#out + 1] = e.key end
			table.sort(out)
			return table.concat(out, ",")
		end
		local ALL = "copper-plate,fluid/water,iron-plate,stone"
		expect(keys(false) == ALL and keys(true) == ALL, "without view cells everything: " .. keys(true))

		--- the workbench
		hand.set_stack{ name = VIEW, count = 1 }
		expect(remote.call(WB, "cell_click", wb, hand, inv, false) == nil and not hand.valid_for_read, "the view cell goes into the workbench")
		expect(remote.call(WB, "set_partition_slot", wb, 1, "iron-plate"), "an item in its list")
		expect(remote.call(WB, "set_partition_slot", wb, 2, "fluid/water"), "a fluid in its list")
		local d = (remote.call(WB, "info", wb) or {}).cell or {}
		expect(d.view == true and serpent.line(d.partition) == serpent.line({ "fluid/water", "iron-plate" }),
			"the workbench's data: " .. serpent.line({ d.view, d.partition }))
		remote.call(WB, "cell_click", wb, hand, inv, false)
		local tags = hand.valid_for_read and hand.is_item_with_tags and hand.tags or {}
		local cell = tags.fork_me_cell or {}
		expect(hand.valid_for_read and hand.name == VIEW and cell.partition and cell.partition["iron-plate"] and cell.partition["fluid/water"],
			"taken out with its list: " .. serpent.line(tags))
		local desc = hand.valid_for_read and hand.custom_description
		expect(type(desc) == "table" and serpent.line(desc):find("view%-cell%-tip") ~= nil, "its description: " .. serpent.line(desc))

		--- an ME Drive refuses it
		pcall(remote.call, NET, "insert_cell", drive, hand, 5)
		expect(hand.valid_for_read and hand.name == VIEW, "an ME Drive took the view cell")

		--- the terminal
		expect(remote.call(VCR, "click", t, 1, hand, inv, false) == nil and not hand.valid_for_read, "the view cell goes into slot 1")
		expect(keys(false) == ALL, "the plain list stays everything: " .. keys(false))
		expect(keys(true) == "fluid/water,iron-plate", "one view cell: " .. keys(true))
		hand.set_stack{ name = VIEW, count = 1, tags = { fork_me_cell = { partition = { ["iron-plate"] = true }, cards = { "me-inverter-card" } } } }
		expect(remote.call(VCR, "click", t, 2, hand, inv, false) == nil, "a blacklist view cell goes into slot 2")
		expect(keys(true) == "fluid/water", "a whitelist and a blacklist: " .. keys(true))
		expect(remote.call(VCR, "click", t, 1, hand, inv, false) == nil and hand.valid_for_read and hand.name == VIEW, "slot 1 taken out")
		expect(keys(true) == "copper-plate,fluid/water,stone", "the blacklist alone: " .. keys(true))
		hand.set_stack{ name = "iron-plate", count = 1 }
		expect(remote.call(VCR, "click", t, 1, hand, inv, false) == "not-here", "an iron plate is refused")
		inv.destroy()

		--- the terminal destroyed: its view cell is spilled
		t.destroy{ raise_destroy = true }
		local n = 0
		for _, e in pairs(s.find_entities_filtered{ name = "item-on-ground", area = { { BX + 6, BY - 6 }, { BX + 16, BY + 6 } } }) do
			if e.stack.valid_for_read and e.stack.name == VIEW then n = n + 1 end
		end
		expect(n == 1, "the destroyed terminal's view cell on the ground: " .. n)
		return report()
	end

	function T.running(check) check(storage.viewcell440 and storage.viewcell440.done, "View Cells") end

	return T
end
