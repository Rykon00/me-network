--- Runtime test of me-network issue #754: the pipette key (Q) for fluids, and the two gaps it had for items.
--- The game's pipette puts an item shown in a window into the cursor (the stack, or a ghost of it), and a config slot takes
--- an item from the cursor (issue #677). A fluid cannot be in the cursor, so the mod keeps a **held fluid** per player: Q
--- over a fluid slot of an ME window holds it, the next click on a slot that takes fluids sets it. The harness has no
--- player and no key, so a stand-in player (remote gregtorio-me-gui stand_in) and the handlers' own functions:
--- * a slot the windows draw for a fluid raises hover events and names its fluid (tag fork_me_fluid); an item slot does not;
--- * Q while a fluid slot is hovered holds that fluid (with its temperature, when the slot has one), says so, and shows it
---   in the open window's title bar; Q while nothing is hovered lets it go;
--- * a slot that takes fluids gets the held fluid as its choice, a slot of items only gets none (the picker opens);
--- * an item in the cursor comes first and lets the held fluid go;
--- * a **ghost** in the cursor (an item picked with Q that the player does not carry) is a choice like the item, with its
---   quality where the slot takes one;
--- * real slots through their click handlers: an ME Export Bus's filter takes the held fluid and a ghost's item; the
---   ME Pattern Terminal's rows (they always opened the picker) take the held fluid, the cursor's item and a ghost;
--- * the fluid stays held when a window closes (picked in the terminal, set in a bus); Q after its slot is gone lets it go;
--- * and the click of a scale button of issue #753 (its handler had no test): x2 doubles the rows.
--- Loaded by control.lua: require("heldfluid")(H) returns { setup, tick, running }.

local GUI, PT = "gregtorio-me-gui", "gregtorio-me-pattern-terminal"
local START = 180
local WHO, INDEX = "heldfluid754", 9754

return function(H)
	local me_report = H.me_report
	local T = {}

	function T.tick()
		local st = storage.heldfluid754
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.heldfluid754 = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note) me_report("HELDFLUID", "the pipette key for fluids (issue #754)", problems, note) end
		local g = function(fn, ...) return remote.call(GUI, fn, ...) end
		if not remote.interfaces[GUI].stand_in_pipette then return finish("nothing to check: a version before #754") end
		local function line(t) return serpent.line(t, { comment = false }) end

		--- the slots
		local fluid_slot, item_slot = g("slot_view", "fluid/water"), g("slot_view", "iron-plate")
		expect(fluid_slot.raise_hover_events == true and fluid_slot.tags.fork_me_fluid == "fluid/water", "a fluid slot: " .. line(fluid_slot))
		expect(not item_slot.raise_hover_events and item_slot.tags.fork_me_fluid == nil, "an item slot: " .. line(item_slot))
		local acting = g("slot_view", "fluid/water", { fork_me_act = "x", index = 3 })
		expect(acting.tags.fork_me_act == "x" and acting.tags.index == 3 and acting.tags.fork_me_fluid == "fluid/water",
			"a fluid slot with an action keeps its tags: " .. line(acting.tags))
		local config = g("slot_view", "fluid/water", { fork_me_act = "y" }, true)
		expect(config.raise_hover_events == true and config.tags.fork_me_fluid == "fluid/water", "a config slot of a fluid: " .. line(config))

		local inv = game.create_inventory(10)
		local hold = game.create_inventory(1)
		local cursor = hold[1]
		local function stand_in(ghost) g("stand_in", WHO, { main = inv, index = INDEX, gui = true, cursor = cursor, ghost = ghost }) end
		stand_in()
		local both, items = { kinds = { item = true, fluid = true } }, { kinds = { item = true } }
		local function choice(spec) return g("stand_in_cursor_choice", WHO, spec) end

		--- hold and let go
		expect(g("stand_in_held", WHO) == nil and choice(both) == nil, "nothing held at first")
		g("held_hover", INDEX, "fluid/water")
		expect(g("stand_in_pipette", WHO) == "fluid/water" and g("stand_in_held", WHO) == "fluid/water", "Q over a water slot holds water: "
			.. tostring(g("stand_in_held", WHO)))
		local texts = g("stand_in_texts", WHO)
		expect(#texts == 1 and texts[1][1] == "fork-me-gui.held-fluid", "it says what is held: " .. line(texts))
		local c = choice(both)
		expect(c and c.kind == "fluid" and c.name == "water" and c.temperature == nil and c.cursor == true, "a slot of items and fluids: " .. line(c))
		expect(choice(items) == nil, "a slot of items only gets no choice from a held fluid")
		expect(choice({ kinds = { fluid = true } }) ~= nil, "a slot of fluids only takes it")
		g("held_hover", INDEX, nil)
		expect(g("stand_in_pipette", WHO) == nil and g("stand_in_held", WHO) == nil, "Q over nothing lets it go")
		g("held_hover", INDEX, "fluid/steam@165")
		g("stand_in_pipette", WHO)
		c = choice(both)
		expect(c and c.kind == "fluid" and c.name == "steam" and c.temperature == 165, "a fluid of one temperature: " .. line(c))

		--- an item in the cursor comes first
		cursor.set_stack{ name = "iron-plate", count = 5 }
		c = choice(both)
		expect(c and c.kind == "item" and c.name == "iron-plate" and g("stand_in_held", WHO) == nil, "an item in the cursor comes first and "
			.. "lets the fluid go: " .. line(c) .. ", held " .. tostring(g("stand_in_held", WHO)))
		cursor.clear()

		--- a ghost in the cursor
		local quality = script.feature_flags.quality and prototypes.quality["uncommon"] and "uncommon" or "normal"
		stand_in({ name = "iron-gear-wheel", quality = quality })
		c = choice(both)
		expect(c and c.kind == "item" and c.name == "iron-gear-wheel" and c.quality == quality, "a ghost in the cursor: " .. line(c))
		c = choice({ kinds = { item = true }, quality = false })
		expect(c and c.name == "iron-gear-wheel" and c.quality == nil, "a ghost for a slot without a quality: " .. line(c))
		expect(choice({ kinds = { fluid = true } }) == nil, "a ghost for a slot of fluids only: none")

		--- real slots: an export bus's filter
		local sc = storage.cursorslot677_scene or {}
		local bus = sc.export
		local function open(e, what)
			local ok, err = pcall(g, "stand_in_open_entity", WHO, e)
			expect(ok and err ~= nil, what .. ": the window did not open: " .. tostring(err))
			return ok and err ~= nil
		end
		local function click(act, field, value, what, button)
			expect(g("stand_in_slot_click", WHO, act, field, value, button), what .. ": no slot " .. act .. " " .. tostring(field) .. "=" .. tostring(value))
		end
		if bus and bus.valid then
			stand_in()
			if open(bus, "export bus") then
				g("held_hover", INDEX, "fluid/water")
				g("stand_in_pipette", WHO)
				g("held_hover", INDEX, nil)
				expect(g("stand_in_held_shown", WHO) == true, "the window's title bar shows the held fluid")
				click("bus_filter", "index", 2, "export bus filter 2")
				local d = g("bus_data", bus)
				expect(d and d.filters and d.filters[2] == "fluid/water", "the filter takes the held fluid: " .. line(d and d.filters))
				expect(g("stand_in_held", WHO) == "fluid/water", "the fluid stays held after a click")
				--- (picked in one window, set in another: closing a window keeps it; Q over nothing lets it go)
				g("stand_in_close_window", WHO, true)
				expect(g("stand_in_held", WHO) == "fluid/water", "the fluid stays held when the window closes")
				expect(g("stand_in_pipette", WHO) == nil and g("stand_in_held", WHO) == nil, "Q after the slot is gone lets it go")
			end
			stand_in({ name = "iron-gear-wheel", quality = "normal" })
			if open(bus, "export bus with a ghost") then
				click("bus_filter", "index", 3, "export bus filter 3")
				local d = g("bus_data", bus)
				expect(d and d.filters and d.filters[3] == "iron-gear-wheel", "the filter takes a ghost's item: " .. line(d and d.filters))
				click("bus_filter", "index", 2, "export bus filter 2", "right")
				click("bus_filter", "index", 3, "export bus filter 3", "right")
				g("stand_in_close_window", WHO, false)
			end
		else
			expect(false, "no export bus of the cursor slot test")
		end

		--- the pattern terminal's rows, and a scale button's click
		local term
		for _, s in pairs(game.surfaces) do
			term = s.find_entities_filtered{ name = "me-pattern-terminal", limit = 1 }[1]
			if term then break end
		end
		if term then
			local function editor() return remote.call(PT, "player_editor", INDEX) end
			local ed = remote.call(PT, "new_editor")
			ed.mode = "processing"
			remote.call(PT, "set_player_editor", INDEX, ed)
			stand_in()
			if open(term, "pattern terminal") then
				g("held_hover", INDEX, "fluid/water")
				g("stand_in_pipette", WHO)
				click("pat_row", "index", 1, "input row 1")
				local e = editor()
				expect(e and e.inputs[1] and e.inputs[1].key == "fluid/water", "a pattern row takes the held fluid: " .. line(e and e.inputs))
				cursor.set_stack{ name = "iron-plate", count = 3 }
				click("pat_row", "index", 2, "input row 2")
				e = editor()
				expect(e and e.inputs[2] and e.inputs[2].key == "iron-plate" and cursor.valid_for_read and cursor.count == 3,
					"a pattern row takes the cursor's item, the cursor stays: " .. line(e and e.inputs))
				cursor.clear()
				g("stand_in_close_window", WHO, false)
			end
			stand_in({ name = "iron-gear-wheel", quality = "normal" })
			if open(term, "pattern terminal with a ghost") then
				click("pat_row", "index", 3, "input row 3")
				local e = editor()
				expect(e and e.inputs[3] and e.inputs[3].key == "iron-gear-wheel", "a pattern row takes a ghost's item: " .. line(e and e.inputs))
				--- issue #753: the x2 button through its click handler
				local before = e and e.inputs[2] and e.inputs[2].amount or 0
				click("pat_scale", "factor", 2, "the x2 button")
				e = editor()
				expect(before > 0 and e and e.inputs[2] and e.inputs[2].amount == 2 * before, "a click on x2 doubles a row (issue #753): "
					.. tostring(before) .. " -> " .. tostring(e and e.inputs[2] and e.inputs[2].amount))
				g("stand_in_close_window", WHO, false)
			end
			remote.call(PT, "set_player_editor", INDEX, nil)
		else
			expect(false, "no ME Pattern Terminal on the test map")
		end

		g("stand_in_forget", WHO)
		inv.destroy()
		hold.destroy()
		finish("fluid slots hover, Q holds and lets go, the choice by kind of slot, item first, a ghost, the export bus filter, "
			.. "the pattern rows, the x2 click")
	end

	function T.running(check) check(storage.heldfluid754 and storage.heldfluid754.done, "the pipette key for fluids") end

	return T
end
