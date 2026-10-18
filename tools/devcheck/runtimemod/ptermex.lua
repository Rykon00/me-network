--- Runtime test of me-network issue #416: the ME Pattern Terminal Ex (AE2-Unofficial's PartPatternTerminalEx). A network with 24
--- kinds of items and blank patterns, a Pattern Terminal Ex, a 256k CPU and a pattern provider with a chest:
---   * the Ex's editor takes 32 inputs and 8 outputs (a 33rd input and a 9th output are refused); a pattern of 20 inputs and 2
---     outputs is encoded and reads back with its 20 inputs; switched to 8 inputs and 32 outputs, one of 3 inputs and 10 outputs;
---   * the Ex loads no crafting pattern; the plain terminal's editor still takes 9 and 6;
---   * a processing pattern of 12 inputs on the provider: a job of it pushes all 12 into the chest.
--- Loaded by control.lua: require("ptermex")(H) returns { setup, tick, running }.

local NET, AC, PT = "gregtorio-me-network", "gregtorio-me-autocraft", "gregtorio-me-pattern-terminal"
local BX, BY = -150, 170              -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, TIMEOUT = 150, 900
local OUT = "wooden-chest"

return function(H)
	local me_place, cable_row, power, me_report = H.me_place, H.cable_row, H.power, H.me_report
	local T = {}
	local function line(t) return serpent.line(t) end

	--- 24 plain items of the game (sorted names; not the mod's, not the output), the inputs of the patterns
	local function input_items()
		local out = {}
		for name, p in pairs(prototypes.item) do
			if p.type == "item" and not p.hidden and not p.parameter and p.stack_size >= 50 and name:sub(1, 3) ~= "me-"
				and name ~= OUT and not p.place_result and p.get_spoil_ticks() <= 0 then out[#out + 1] = name end   -- (no spoiling items: refused)
		end
		table.sort(out)
		local list = {}
		for i = 1, 24 do list[i] = out[i] end
		return list
	end

	function T.setup(s)
		local fails = {}
		local what = "pattern terminal ex"
		power(s, fails, what, BX, BY)
		local items = { ["me-blank-pattern"] = 10 }
		for _, name in ipairs(input_items()) do items[name] = 20 end
		me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, items)
		cable_row(s, fails, BX + 9, BX + 16, BY - 1)
		me_place(s, fails, what, "me-pattern-terminal-ex", BX + 10.5, BY - 1.5)
		me_place(s, fails, what, "me-256k-crafting-storage", BX + 12.5, BY - 1.5)
		me_place(s, fails, what, "me-pattern-provider", BX + 14.5, BY + 0.5)
		me_place(s, fails, what, "iron-chest", BX + 14.5, BY + 1.5)
		return fails
	end

	function T.tick()
		local st = storage.ptermex416
		if (st and st.done) or game.tick < START then return end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		if not st then
			st = { problems = {}, phase = "start" }
			storage.ptermex416 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			if st.job then pcall(remote.call, AC, "cancel", st.job) end
			me_report("PTERMEX", "ME Pattern Terminal Ex", problems, "32 inputs and 8 outputs or 8 and 32, the limits, encoded "
				.. "patterns of 20 inputs and of 10 outputs, no crafting pattern, the plain terminal's 9 and 6; a job of 12 inputs into a chest")
		end
		local ctrl, X, p, chest = find("me-network-controller", 7, 0), find("me-pattern-terminal-ex", 10.5, -1.5),
			find("me-pattern-provider", 14.5, 0.5), find("iron-chest", 14.5, 1.5)
		if not (ctrl and X and p and chest) then expect(false, "entities missing") return finish() end
		local items = input_items()

		if st.phase == "start" then
			local force = X.force
			local ok
			local ed = remote.call(PT, "new_editor_ex")
			expect(ed and ed.mode == "processing" and ed.ex == "inputs", "the Ex's editor: " .. line(ed))
			for i = 1, 20 do ok, ed = remote.call(PT, "set_editor_row", ed, "inputs", i, items[i], 1) end
			ok, ed = remote.call(PT, "set_editor_row", ed, "inputs", 32, items[21], 1)
			expect(ok, "the 32nd input row")
			ok = remote.call(PT, "set_editor_row", ed, "inputs", 33, items[22], 1)
			expect(not ok, "a 33rd input row was taken")
			ok, ed = remote.call(PT, "set_editor_row", ed, "inputs", 32, false)
			for i = 1, 2 do ok, ed = remote.call(PT, "set_editor_row", ed, "outputs", i, i == 1 and OUT or items[24], 1) end
			ok = remote.call(PT, "set_editor_row", ed, "outputs", 9, items[23], 1)
			expect(not ok, "a 9th output row was taken in the 32-input layout")
			local where, why = remote.call(PT, "encode", X, force, ed, nil)
			expect(where == "output", "encoding 20 inputs: " .. tostring(where) .. " " .. tostring(why))
			local slots = remote.call(PT, "inventory", X)
			local info = slots and slots[2].valid_for_read and remote.call(PT, "pattern_info", slots[2]) or {}
			expect(#(info.inputs or {}) == 20 and #(info.outputs or {}) == 2, "the encoded pattern has 20 inputs and 2 outputs: "
				.. #(info.inputs or {}) .. ", " .. #(info.outputs or {}))
			--- 8 inputs and 32 outputs
			local ed2 = remote.call(PT, "new_editor_ex")
			ed2.ex = "outputs"
			for i = 1, 3 do ok, ed2 = remote.call(PT, "set_editor_row", ed2, "inputs", i, items[i], 1) end
			ok = remote.call(PT, "set_editor_row", ed2, "inputs", 9, items[9], 1)
			expect(not ok, "a 9th input row was taken in the 32-output layout")
			for i = 1, 10 do ok, ed2 = remote.call(PT, "set_editor_row", ed2, "outputs", i, items[10 + i], 1) end
			where, why = remote.call(PT, "encode", X, force, ed2, nil)
			info = slots and slots[2].valid_for_read and remote.call(PT, "pattern_info", slots[2]) or {}
			expect(where == "output" and #(info.inputs or {}) == 3 and #(info.outputs or {}) == 10, "encoding 10 outputs: "
				.. line({ where, why, #(info.inputs or {}), #(info.outputs or {}) }))
			--- no crafting pattern; the plain terminal's editor keeps 9 and 6
			local tmp = game.create_inventory(2)
			tmp.insert{ name = "me-blank-pattern", count = 1 }
			remote.call(PT, "encode_def", tmp, nil, { kind = "crafting", recipe = "iron-chest" })
			local craft = tmp.find_item_stack("me-encoded-pattern")
			local lok, lwhy = remote.call(PT, "load_pattern", X, craft, remote.call(PT, "new_editor_ex"))
			expect(not lok and lwhy == "ex-processing-only", "the Ex loaded a crafting pattern: " .. line({ lok, lwhy }))
			tmp.destroy()
			local plain = remote.call(PT, "new_editor")
			plain.mode = "processing"
			expect(remote.call(PT, "set_editor_row", plain, "inputs", 9, items[1], 1) == true
				and remote.call(PT, "set_editor_row", plain, "inputs", 10, items[2], 1) == false
				and remote.call(PT, "set_editor_row", plain, "outputs", 7, items[3], 1) == false, "the plain terminal's 9 and 6")
			--- a processing pattern of 12 inputs on the provider, a job of it
			local inputs = {}
			for i = 1, 12 do inputs[i] = { key = items[i], amount = 1 } end
			local n = give_patterns(p, { { kind = "processing", inputs = inputs, outputs = { { key = OUT, amount = 1 } } } }, problems)
			expect(n == 1, "the 12-input pattern on the provider")
			local id, jwhy = remote.call(AC, "start", ctrl, OUT, 1)
			expect(id ~= nil, "the job of the 12-input pattern: " .. tostring(jwhy))
			if not id then return finish() end
			st.job, st.phase, st.tick = id, "push", game.tick
			return
		end

		if st.phase == "push" then
			local inv = chest.get_inventory(defines.inventory.chest)
			local have = 0
			for i = 1, 12 do if inv.get_item_count(items[i]) == 1 then have = have + 1 end end
			if have < 12 then
				if game.tick > st.tick + TIMEOUT then
					expect(false, "the chest got " .. have .. " of the 12 inputs: " .. line(remote.call(AC, "job", st.job)))
					return finish()
				end
				return
			end
			return finish()
		end
	end

	function T.running(check) check(storage.ptermex416 and storage.ptermex416.done, "ME Pattern Terminal Ex") end

	return T
end
