--- Runtime test of me-network issue #677: a key slot clicked with an item in the cursor takes that item (AE2's ghost slots),
--- the cursor stays as it is. Through a stand-in player with a GUI and a cursor stack (the windows' own handlers):
--- * the ME Interface: an empty row gets the item with the amount the picker gives a new row, a row that held something keeps
---   its amount, an item that has a row moves to the clicked row (as set_interface_key does);
--- * the ME Import Bus, ME Export Bus and ME Storage Bus filters, the ME Level Maintainer's target, the ME Circuit Interface's
---   filter, the ME Level Emitter's and the ME Storage Monitor's key take the item (with its quality where the slot takes one);
--- * the window of a ghost of an ME Interface (issue #659) the same;
--- * a blueprint, a deconstruction planner or an empty hand gives no choice (the picker opens), nor does a slot of fluids only;
---   the circuit interface's filter takes no quality.
--- Loaded by control.lua like sortprefs.lua.

local IO, GUI, EM, MON, GW = "gregtorio-me-io", "gregtorio-me-gui", "gregtorio-me-emitter", "gregtorio-me-monitor", "gregtorio-me-ghostwin"
local BX, BY = 220, -240                 -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local CHECK = 140
local WHO = "cursorslot677"

local BLOCKS = {
	{ "interface", "me-network-interface" },
	{ "import", "me-import-bus" },
	{ "export", "me-export-bus" },
	{ "sbus", "me-storage-bus" },
	{ "maint", "me-level-maintainer" },
	{ "circ", "me-circuit-interface" },
	{ "emitter", "me-level-emitter" },
	{ "monitor", "me-storage-monitor" },
	{ "interface2", "me-network-interface" },
}

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "config slots from the cursor"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local list, scene = { ctrl }, { ctrl = ctrl }
		for i, b in ipairs(BLOCKS) do
			local e = me_place(s, fails, what, b[2], BX + 8.5 + 2 * i, BY + 0.5)
			scene[b[1]] = e
			list[#list + 1] = e
		end
		H.me_connect(fails, what, list)
		storage.cursorslot677_scene = scene
		return fails
	end

	function T.tick()
		if game.tick ~= CHECK then return end
		local st = { problems = {}, done = true }
		storage.cursorslot677 = st
		local problems = st.problems
		local sc = storage.cursorslot677_scene or {}
		for _, b in ipairs(BLOCKS) do
			if not (sc[b[1]] and sc[b[1]].valid) then
				return me_report("CURSORSLOT", "ME config slots from the cursor", { "the test blocks were not built" })
			end
		end
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function line(t) return serpent.line(t, { comment = false }) end
		local quality = script.feature_flags.quality and prototypes.quality["uncommon"] and "uncommon" or nil
		local inv = game.create_inventory(10)
		local hold = game.create_inventory(1)
		local cursor = hold[1]
		remote.call(GUI, "stand_in", WHO, { main = inv, index = 9677, gui = true, cursor = cursor })
		local function hand(name, q) cursor.set_stack{ name = name, count = 7, quality = q or "normal" } end
		local function hand_kept(name, q, what)
			expect(cursor.valid_for_read and cursor.name == name and cursor.count == 7 and cursor.quality.name == (q or "normal"),
				what .. ": the cursor changed")
		end
		local function open(e, what)
			local ok, err = pcall(remote.call, GUI, "stand_in_open_entity", WHO, e)
			expect(ok and err ~= nil, what .. ": the window did not open: " .. tostring(err))
			return ok and err ~= nil
		end
		local function click(act, field, value, what, button)
			local ok = remote.call(GUI, "stand_in_slot_click", WHO, act, field, value, button)
			expect(ok, what .. ": no slot " .. act .. " " .. tostring(field) .. "=" .. tostring(value))
		end
		local function close() remote.call(GUI, "stand_in_close_window", WHO, false) end
		local function key(name, q) return (q and q ~= "normal") and (name .. "@" .. q) or name end

		--- the ME Interface
		local e = sc.interface
		remote.call(IO, "set_interface_key", e, 1, "copper-plate", 77)
		remote.call(IO, "set_interface_key", e, 2, "stone", 33)
		if open(e, "interface") then
			hand("iron-plate", quality)
			click("if_item", "index", 1, "interface row 1")
			hand_kept("iron-plate", quality, "interface row 1")
			local c = remote.call(IO, "get_interface_config", e)
			expect(c[1] and c[1].name == "iron-plate" and (c[1].quality or "normal") == (quality or "normal") and c[1].amount == 77,
				"a filled row clicked with iron plates keeps its amount 77: " .. line(c[1]))
			hand("iron-gear-wheel")
			click("if_item", "index", 4, "interface row 4")
			c = remote.call(IO, "get_interface_config", e)
			--- (the amount the picker gives a new row: the same choice through the picker's path on the second interface)
			remote.call(GUI, "set_interface_choice", sc.interface2, 4, { kind = "item", name = "iron-gear-wheel", quality = "normal" })
			local picked = remote.call(IO, "get_interface_config", sc.interface2)[4]
			expect(c[4] and c[4].name == "iron-gear-wheel" and picked and c[4].amount == picked.amount,
				"a new row gets the picker's amount: " .. line(c[4]) .. " vs " .. line(picked))
			hand("stone")
			click("if_item", "index", 3, "interface row 3")
			c = remote.call(IO, "get_interface_config", e)
			expect(c[3] and c[3].name == "stone" and not (c[2] and c[2].name == "stone"),
				"stone moves from row 2 to row 3: " .. line(c))
			hand("blueprint")
			click("if_item", "index", 5, "interface row 5 with a blueprint")
			c = remote.call(IO, "get_interface_config", e)
			expect(c[5] == nil, "a blueprint in the cursor set row 5: " .. line(c[5]))
			hand("stone")
			click("if_item", "index", 1, "interface row 1 right click", "right")
			c = remote.call(IO, "get_interface_config", e)
			expect(c[1] == nil and c[3] and c[3].name == "stone", "right click with an item in the cursor clears the row: " .. line(c))
			close()
		end

		--- the buses' filters
		for _, b in ipairs({ { "import", "bus_filter" }, { "export", "bus_filter" }, { "sbus", "sbus_filter" } }) do
			local bus = sc[b[1]]
			if open(bus, b[1]) then
				hand("copper-plate", quality)
				click(b[2], "index", 1, b[1] .. " filter 1")
				hand_kept("copper-plate", quality, b[1])
				local d = b[1] == "sbus" and remote.call(GUI, "storage_bus_data", bus) or remote.call(GUI, "bus_data", bus)
				expect(d and d.filters and d.filters[1] == key("copper-plate", quality), b[1] .. " filter: " .. line(d and d.filters))
				close()
			end
		end

		--- the level maintainer's target, the circuit interface's filter (no quality)
		if open(sc.maint, "maintainer") then
			hand("iron-gear-wheel", quality)
			click("maint_target", "row", 1, "maintainer row 1")
			local d = remote.call(GUI, "maintainer_data", sc.maint)
			local r = d and d.rows and d.rows[1]
			expect(r and r.key == key("iron-gear-wheel", quality), "maintainer target: " .. line(r))
			close()
		end
		if open(sc.circ, "circuit interface") then
			hand("iron-gear-wheel", quality)
			click("circ_filter", "index", 1, "circuit interface filter 1")
			local d = remote.call(GUI, "circuit_data", sc.circ)
			expect(d and d.filters and d.filters[1] == "iron-gear-wheel", "circuit interface filter (plain name): " .. line(d and d.filters))
			close()
		end

		--- the level emitter and the storage monitor
		if open(sc.emitter, "emitter") then
			hand("stone", quality)
			click("em_key", nil, nil, "emitter")
			local d = remote.call(EM, "get", sc.emitter)
			expect(d and d.key == key("stone", quality), "emitter key: " .. line(d and d.key))
			close()
		end
		if open(sc.monitor, "monitor") then
			hand("stone", quality)
			click("mon_key", nil, nil, "monitor")
			local d = remote.call(MON, "get", sc.monitor)
			expect(d and d.key == key("stone", quality), "monitor key: " .. line(d and d.key))
			close()
		end

		--- what gives no choice: the picker opens
		hand("deconstruction-planner")
		expect(remote.call(GUI, "stand_in_cursor_choice", WHO, { kinds = { item = true } }) == nil, "a deconstruction planner gave a choice")
		hand("blueprint")
		expect(remote.call(GUI, "stand_in_cursor_choice", WHO, { kinds = { item = true } }) == nil, "a blueprint gave a choice")
		hand("iron-plate")
		expect(remote.call(GUI, "stand_in_cursor_choice", WHO, { kinds = { fluid = true } }) == nil, "a fluid slot took an item")
		local plain = remote.call(GUI, "stand_in_cursor_choice", WHO, { kinds = { item = true }, quality = false })
		expect(plain and plain.name == "iron-plate" and plain.quality == nil, "a slot without quality: " .. line(plain))
		cursor.clear()
		expect(remote.call(GUI, "stand_in_cursor_choice", WHO, { kinds = { item = true } }) == nil, "an empty hand gave a choice")

		--- issue #659: the window of a ghost of an ME Interface
		local s = game.surfaces[1]
		local ghost = s.create_entity{ name = "entity-ghost", inner_name = "me-network-interface", position = { BX + 30.5, BY + 4.5 }, force = "player" }
		local staged = ghost and remote.call(GW, "stage", ghost, 9677)
		if staged and open(staged, "ghost interface") then
			hand("copper-plate")
			click("if_item", "index", 2, "ghost interface row 2")
			local c = remote.call(IO, "get_interface_config", staged)
			expect(c and c[2] and c[2].name == "copper-plate", "the ghost's window took the item: " .. line(c))
			close()
			remote.call(GW, "unstage", 9677, inv)
		else
			expect(false, "the ghost of an interface was not staged")
		end
		if ghost and ghost.valid then ghost.destroy() end
		remote.call(GUI, "stand_in_forget", WHO)
		inv.destroy()
		hold.destroy()
		me_report("CURSORSLOT", "ME config slots from the cursor (issue #677)", problems, "interface rows (amount kept, picker's amount, "
			.. "moved key, right click), bus, storage bus, maintainer, circuit interface, emitter and monitor keys"
			.. (quality and " with quality" or "") .. ", tools and empty hand to the picker, a ghost's window")
	end

	function T.running(check) check(storage.cursorslot677 and storage.cursorslot677.done, "ME config slots from the cursor") end
	return T
end
