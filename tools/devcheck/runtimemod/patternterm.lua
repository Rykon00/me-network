--- Runtime test of me-network issue #130 (docs/AE2.md "ME Pattern Terminal"): the block that encodes patterns (it was the
--- Patterns tab of the ME Terminal).
--- One network (a drive with 5 blank patterns), the pattern terminal 8 tiles outside every pole's supply:
--- * it joins the network (the controller draws 8 kW more, the same network as the controller), has no pole, can be stood on,
---   its screen is the lit picture (graphics variation 2)
--- * a crafting pattern and a processing pattern encoded through it give the pattern that was asked for (kind, recipe, rows, id)
--- * the blank comes from the blank slot; with the slot empty one comes from the network (one fewer there); with none in either
---   nothing is encoded ("no-blank"); a blank in the player's inventory is never used; an encoded pattern lying in the output slot is
---   encoded again in place without a blank (the blank count does not change); shift + click on Encode puts the pattern straight into
---   the inventory (and keeps it in the slot when the inventory is full)
--- * the slots: a blank pattern goes in, another item is refused ("not-a-blank"), only an encoded pattern goes into the output slot
---   ("not-encoded"), the empty blank slot fetches a stack from the network, shift + click on the player's inventory sends blanks and
---   patterns to their slots, a taken pattern is the same item
--- * load pattern reads the hand's pattern, else the output slot's; clear pattern turns the hand's pattern, else the output slot's, into
---   a blank (the output slot's goes into the blank slot)
--- * a clone has empty slots; mining returns what the slots hold into the mined buffer; destroying spills it where the block stood
--- * without power the window says why ("no-power": encode and fetching refuse) and the screen is the dark picture (variation 1),
---   with the power back it is lit again
--- * the ME Terminal has four tabs, none of them the patterns
--- Loaded by control.lua: require("patternterm")(H) returns { setup, tick, running } like lab.lua.

local NET, TERM, PT, AC = "gregtorio-me-network", "gregtorio-me-terminal", "gregtorio-me-pattern-terminal", "gregtorio-me-autocraft"
local BX, BY = -250, 100
local START, END = 90, 700
local BLANK, ENCODED = "me-blank-pattern", "me-encoded-pattern"
local RECIPE = "iron-gear-crafting-table"          -- (vanilla: a stand-in, data.lua)
local PT_X = 14                                      -- tile right of BX: outside the substation's supply

return function(H)
	local me_place, me_report, power, cable_row = H.me_place, H.me_report, H.power, H.cable_row
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "pattern terminal"
		local eei = power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 6, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 0.5, { [BLANK] = 5, ["iron-plate"] = 50, ["iron-stick"] = 50 })
		cable_row(s, fails, BX + 7, BX + 7, BY - 1)
		cable_row(s, fails, BX + 9, BX + 20, BY - 1)
		local term = me_place(s, fails, what, "me-terminal", BX + 18.5, BY - 2.5)
		if not (eei and ctrl and drive and term) then fails[#fails + 1] = what .. ": the network was not built" end
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.patternterm130
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false, phase = "join" }
			storage.patternterm130 = st
		end
		if st.done then return end
		local s = game.surfaces[1]
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			st.done = true
			me_report("PATTERNTERM", "ME Pattern Terminal", problems, note)
		end
		local ctrl = s.find_entity("me-network-controller", { BX + 6, BY })
		local eei = s.find_entity("electric-energy-interface", { BX, BY })
		local term = s.find_entity("me-terminal", { BX + 18.5, BY - 2.5 })
		if not (ctrl and ctrl.valid and eei and eei.valid and term and term.valid) then
			problems[#problems + 1] = "the test network is missing"
			return finish()
		end
		local function count(name) return remote.call(NET, "count", ctrl, name) end
		local function net() return remote.call(NET, "network", ctrl) end
		local pt = st.pt and st.pt.valid and st.pt
		local force = ctrl.force
		local hand, inv = st.hand, st.inv

		if st.phase == "join" then
			local n0 = net()
			st.pt = s.create_entity{ name = "me-pattern-terminal", position = { BX + PT_X + 0.5, BY - 0.5 }, force = "player", raise_built = true }
			pt = st.pt
			if not pt then
				expect(false, "the pattern terminal was not built")
				return finish()
			end
			st.hand, st.inv = game.create_inventory(1), game.create_inventory(8)
			hand, inv = st.hand, st.inv
			local n1 = net()
			expect(remote.call(NET, "same_network", ctrl, pt), "the pattern terminal is not in the controller's network")
			expect(n1 and n0 and n1.power == n0.power + 8000, "the controller draws " .. tostring(n1 and n1.power) .. " W, "
				.. tostring(n0 and n0.power + 8000) .. " expected (pattern terminal 8 kW)")
			expect(#s.find_entities_filtered{ type = "electric-pole", position = pt.position, radius = 10 } == 0, "an electric pole within 10 tiles of the pattern terminal")
			expect(s.can_place_entity{ name = "character", position = pt.position }, "a character cannot stand on the pattern terminal")
			expect(remote.call(PT, "problem", pt) == nil, "the pattern terminal has the problem " .. tostring(remote.call(PT, "problem", pt)))
			local sc = remote.call(NET, "screen", pt)
			expect(sc and sc.on and sc.variation == 2, "the screen of a pattern terminal in a working network: " .. serpent.line(sc))
			expect(remote.call(NET, "kind", "me-pattern-terminal") == "pattern-terminal", "the kind of the block")
			st.phase = "encode"
			return
		end
		if not pt then
			expect(false, "the pattern terminal is gone in phase " .. st.phase)
			return finish()
		end
		local slots = remote.call(PT, "inventory", pt)

		if st.phase == "encode" then
			--- the pattern as a plain editor would describe it
			force.recipes[RECIPE].enabled = true
			local ed = remote.call(PT, "new_editor")
			local ok, why
			ok, why, ed = remote.call(PT, "set_editor_recipe", force, ed, RECIPE)
			expect(ok and ed.recipe == RECIPE, "set_editor_recipe " .. tostring(why))
			local own, in_net = remote.call(PT, "blanks", pt)
			expect(own == 0 and in_net == 5, "blanks " .. own .. "/" .. in_net)
			--- a blank in the player's inventory is not used: with no blank in the slot the network's one is
			inv[1].set_stack{ name = BLANK, count = 3 }
			local where = remote.call(PT, "encode", pt, force, ed)
			expect(where == "output" and count(BLANK) == 4 and inv[1].count == 3, "encoding from the network: " .. tostring(where) .. ", network " .. count(BLANK)
				.. ", inventory " .. inv[1].count)
			local info = slots[2].valid_for_read and remote.call(PT, "pattern_info", slots[2])
			expect(info and info.valid and info.kind == "crafting" and info.recipe == RECIPE and info.id == "c/" .. RECIPE, "crafting pattern " .. serpent.line(info))
			--- a second Encode overwrites the pattern in the output slot without a blank (another recipe: the editor changes)
			local old_number = slots[2].item_number
			ed.mode = "processing"
			ok, why, ed = remote.call(PT, "set_editor_recipe", force, ed, RECIPE)
			where = remote.call(PT, "encode", pt, force, ed)
			info = slots[2].valid_for_read and remote.call(PT, "pattern_info", slots[2])
			expect(where == "output" and count(BLANK) == 4 and info and info.kind == "processing" and info.inputs[1] and info.outputs[1],
				"encoding again in place: " .. tostring(where) .. ", network " .. count(BLANK) .. " " .. serpent.line(info))
			expect(slots[2].item_number ~= old_number, "the pattern in the output slot was not written again")
			st.processing_id = info and info.id
			--- the blank slot is used before the network: a blank in it, the output slot emptied
			slots[2].clear()
			slots[1].set_stack{ name = BLANK, count = 2 }
			where = remote.call(PT, "encode", pt, force, ed)
			expect(where == "output" and slots[1].count == 1 and count(BLANK) == 4, "encoding from the slot: " .. tostring(where) .. ", slot " .. slots[1].count
				.. ", network " .. count(BLANK))
			info = remote.call(PT, "pattern_info", slots[2])
			expect(info and info.id == st.processing_id, "the same pattern from the slot's blank: " .. serpent.line(info))
			--- shift + click on Encode: straight into the inventory (the output slot stays empty); a full inventory keeps it in the slot
			slots[2].clear()
			where = remote.call(PT, "encode", pt, force, ed, inv)
			expect(where == "inventory" and not slots[2].valid_for_read and inv.get_item_count(ENCODED) == 1 and not slots[1].valid_for_read,
				"encoding into the inventory: " .. tostring(where))
			inv.clear()
			for i = 1, #inv do inv[i].set_stack{ name = "iron-plate", count = 100 } end
			slots[1].set_stack{ name = BLANK, count = 1 }
			where = remote.call(PT, "encode", pt, force, ed, inv)
			expect(where == "output" and slots[2].valid_for_read, "encoding with a full inventory: " .. tostring(where))
			inv.clear()
			slots[2].clear()
			--- with no blank in the slot and none in the network: nothing is encoded
			remote.call(NET, "extract", ctrl, BLANK, count(BLANK))
			where, why = remote.call(PT, "encode", pt, force, ed)
			expect(where == nil and why == "no-blank" and not slots[2].valid_for_read, "no blank anywhere: " .. tostring(where) .. " " .. tostring(why))
			--- an invalid pattern (a processing pattern without rows) is refused before a blank is taken
			remote.call(NET, "insert", ctrl, BLANK, 5)
			local empty = remote.call(PT, "new_editor")
			empty.mode = "processing"
			where, why = remote.call(PT, "encode", pt, force, empty)
			expect(where == nil and why == "invalid" and count(BLANK) == 5, "an empty processing pattern: " .. tostring(where) .. " " .. tostring(why) .. ", network " .. count(BLANK))
			st.phase = "slots"
			return
		end

		if st.phase == "slots" then
			inv.clear()
			slots.clear()
			local R = function(...) return remote.call(PT, ...) end
			--- the blank slot takes blank patterns only
			hand[1].set_stack{ name = "iron-plate", count = 1 }
			expect(R("click", pt, 1, hand[1], inv, false) == "not-a-blank" and hand[1].valid_for_read and not slots[1].valid_for_read, "an iron plate into the blank slot")
			hand[1].set_stack{ name = BLANK, count = 10 }
			expect(R("click", pt, 1, hand[1], inv, false) == nil and slots[1].count == 10 and not hand[1].valid_for_read, "ten blanks into the slot")
			hand[1].set_stack{ name = BLANK, count = 60 }
			expect(R("click", pt, 1, hand[1], inv, false) == nil and slots[1].count == 64 and hand[1].count == 6, "a stack merges up to 64: " .. slots[1].count .. ", hand " .. tostring(hand[1].count))
			expect(R("click", pt, 1, hand[1], inv, false) == "slot-full", "a full blank slot")
			--- taking them out: into the hand (the hand is not empty here: refused by transfer), shift into the inventory
			hand[1].clear()
			expect(R("click", pt, 1, hand[1], inv, true) == nil and not slots[1].valid_for_read and inv.get_item_count(BLANK) == 64, "shift + click takes the blanks into the inventory")
			inv.clear()
			--- an empty slot with an empty hand fetches a stack from the network (5 there)
			local before = count(BLANK)
			expect(R("click", pt, 1, hand[1], inv, false) == nil and slots[1].valid_for_read and slots[1].count == before and count(BLANK) == 0,
				"fetching blank patterns from the network: slot " .. tostring(slots[1].count) .. ", network " .. count(BLANK))
			expect(R("click", pt, 1, hand[1], inv, false) == nil and hand[1].valid_for_read and hand[1].count == before, "the blanks into the hand")
			expect(not slots[1].valid_for_read, "the blank slot after the blanks were taken")
			hand[1].clear()
			local fetched = R("click", pt, 1, hand[1], inv, false)
			expect(fetched == "no-blank", "fetching from an empty network: " .. tostring(fetched))
			hand[1].clear()
			remote.call(NET, "insert", ctrl, BLANK, before)
			--- the output slot takes encoded patterns only
			hand[1].set_stack{ name = BLANK, count = 1 }
			expect(R("click", pt, 2, hand[1], inv, false) == "not-encoded" and not slots[2].valid_for_read, "a blank into the output slot")
			hand[1].clear()
			local def = { kind = "processing", inputs = { { key = "iron-plate", amount = 2 } }, outputs = { { key = "iron-gear-wheel", amount = 1 } } }
			local tmp = game.create_inventory(2)
			tmp.insert{ name = BLANK, count = 1 }
			remote.call(PT, "encode_def", tmp, nil, def)
			expect(tmp[2].valid_for_read, "encode_def")
			hand[1].transfer_stack(tmp[2])
			expect(R("click", pt, 2, hand[1], inv, false) == nil and slots[2].valid_for_read and not hand[1].valid_for_read, "an encoded pattern into the output slot")
			--- a second one swaps
			local second = game.create_inventory(2)
			second.insert{ name = BLANK, count = 1 }
			remote.call(PT, "encode_def", second, nil, { kind = "crafting", recipe = RECIPE })
			hand[1].transfer_stack(second[2])
			expect(R("click", pt, 2, hand[1], inv, false) == nil and hand[1].valid_for_read and R("pattern_info", hand[1]).kind == "processing"
				and R("pattern_info", slots[2]).kind == "crafting", "swapping the pattern in the output slot")
			second.destroy()
			tmp.destroy()
			--- load: the hand's pattern first
			local ed = R("new_editor")
			local ok, where
			ok, where, ed = R("load_pattern", pt, hand[1], ed)
			expect(ok == true and where == "hand" and ed.mode == "processing" and ed.inputs[1].key == "iron-plate" and ed.outputs[1].key == "iron-gear-wheel",
				"load from the hand " .. serpent.line(ed) .. " " .. tostring(where))
			hand[1].clear()
			ed = R("new_editor")
			ok, where, ed = R("load_pattern", pt, hand[1], ed)
			expect(ok == true and where == "output" and ed.mode == "crafting" and ed.recipe == RECIPE, "load from the output slot " .. serpent.line(ed))
			--- clear: the hand's pattern becomes a blank in the hand; with an empty hand the output slot's goes into the blank slot
			local def2 = { kind = "crafting", recipe = RECIPE }
			tmp = game.create_inventory(2)
			tmp.insert{ name = BLANK, count = 1 }
			remote.call(PT, "encode_def", tmp, nil, def2)
			hand[1].transfer_stack(tmp[2])
			tmp.destroy()
			expect(R("clear", pt, hand[1], inv) == true and hand[1].name == BLANK and hand[1].count == 1 and slots[2].valid_for_read, "clear in hand")
			hand[1].clear()
			slots[1].clear()
			ok, where = R("clear", pt, hand[1], inv)
			expect(ok == true and where == "output" and not slots[2].valid_for_read and slots[1].valid_for_read and slots[1].name == BLANK and slots[1].count == 1,
				"clear in the output slot: " .. tostring(where))
			ok, where = R("clear", pt, hand[1], inv)
			expect(not ok and where == "no-pattern-in-hand", "clear with no pattern: " .. tostring(where))
			--- shift + click in the inventory pane
			inv.clear()
			inv[1].set_stack{ name = BLANK, count = 5 }
			inv[2].set_stack{ name = "iron-plate", count = 1 }
			tmp = game.create_inventory(2)
			tmp.insert{ name = BLANK, count = 1 }
			remote.call(PT, "encode_def", tmp, nil, def2)
			inv[3].transfer_stack(tmp[2])
			tmp.destroy()
			expect(R("shift_in", pt, inv[1], inv) == nil and slots[1].count == 6 and not inv[1].valid_for_read, "shift + click on blanks")
			expect(R("shift_in", pt, inv[2], inv) == "not-a-pattern-slot" and inv[2].valid_for_read, "shift + click on a plate")
			expect(R("shift_in", pt, inv[3], inv) == nil and slots[2].valid_for_read and not inv[3].valid_for_read, "shift + click on a pattern")
			inv[3].set_stack{ name = ENCODED, count = 1 }
			expect(R("shift_in", pt, inv[3], inv) == "output-full" and inv[3].valid_for_read, "a pattern into a full output slot")
			inv.clear()
			st.phase = "clone"
			return
		end

		if st.phase == "clone" then
			--- what lies in the slots stays (the window is not needed); a clone and a blueprint do not copy it
			local before_blank = slots[1].count
			local clone = pt.clone{ position = { pt.position.x + 3, pt.position.y } }
			local cslots = clone and remote.call(PT, "inventory", clone)
			expect(cslots and not cslots[1].valid_for_read and not cslots[2].valid_for_read and slots[1].count == before_blank,
				"a clone has empty slots and the source keeps its own")
			if clone then clone.destroy{ raise_destroy = true } end
			--- mined: both slots into the buffer
			local buffer = game.create_inventory(4)
			local records = remote.call(PT, "record_count")
			local blanks_in_slot, patterns_in_slot = slots[1].count, slots[2].valid_for_read and 1 or 0
			remote.call(PT, "on_removed", pt, buffer)
			expect(buffer.get_item_count(BLANK) == blanks_in_slot and buffer.get_item_count(ENCODED) == patterns_in_slot and patterns_in_slot == 1,
				"mined: " .. serpent.line(buffer.get_contents()) .. ", the slots held " .. blanks_in_slot .. " blanks and " .. patterns_in_slot .. " pattern")
			buffer.destroy()
			--- destroyed: spilled where it stood (a fresh terminal with both slots filled)
			local dead = s.create_entity{ name = "me-pattern-terminal", position = { BX + PT_X + 6.5, BY - 0.5 }, force = "player", raise_built = true }
			local dslots = dead and remote.call(PT, "inventory", dead)
			if dslots then
				dslots[1].set_stack{ name = BLANK, count = 7 }
				local tmp = game.create_inventory(2)
				tmp.insert{ name = BLANK, count = 1 }
				remote.call(PT, "encode_def", tmp, nil, { kind = "crafting", recipe = RECIPE })
				dslots[2].transfer_stack(tmp[2])
				tmp.destroy()
				local pos = dead.position
				dead.die()
				local blanks, patterns = 0, 0
				for _, e in pairs(s.find_entities_filtered{ name = "item-on-ground", position = pos, radius = 4 }) do
					if e.stack.valid_for_read and e.stack.name == BLANK then blanks = blanks + e.stack.count end
					if e.stack.valid_for_read and e.stack.name == ENCODED then patterns = patterns + e.stack.count end
				end
				expect(blanks == 7 and patterns == 1, "destroyed: " .. blanks .. " blanks and " .. patterns .. " patterns on the ground")
			else
				expect(false, "the second pattern terminal was not built")
			end
			expect(remote.call(PT, "record_count") == records - 1, "the record of a mined and of a destroyed pattern terminal stayed: " .. remote.call(PT, "record_count")
				.. " against " .. records .. " before (the mined one's went, the second one's came and went)")
			--- a new one for the power cut
			st.pt.destroy{ raise_destroy = true }
			local again = s.create_entity{ name = "me-pattern-terminal", position = { BX + PT_X + 0.5, BY - 0.5 }, force = "player", raise_built = true }
			expect(again and remote.call(NET, "same_network", ctrl, again), "the pattern terminal built again is not in the network")
			st.pt = again
			st.phase = "cut"
			st.cut_tick = math.max(tick, 150) + 1
			return
		end

		if st.phase == "cut" then
			if tick < st.cut_tick then return end
			eei.power_production, eei.energy, ctrl.energy = 0, 0, 0
			st.t, st.phase = tick, "dark"
			return
		end
		if st.phase == "dark" then
			local n = net()
			if n and n.status == "no-power" then
				remote.call(NET, "slow_step")
				local sc = remote.call(NET, "screen", pt)
				expect(sc and not sc.on and sc.variation == 1, "the screen of a pattern terminal without power: " .. serpent.line(sc))
				expect(remote.call(PT, "problem", pt) == "no-power", "problem without power: " .. tostring(remote.call(PT, "problem", pt)))
				local ed = remote.call(PT, "new_editor")
				local ok, why
				ok, why, ed = remote.call(PT, "set_editor_recipe", force, ed, RECIPE)
				local where, ewhy = remote.call(PT, "encode", pt, force, ed)
				expect(where == nil and ewhy == "no-power", "encoding without power: " .. tostring(where) .. " " .. tostring(ewhy))
				hand[1].clear()
				slots[1].clear()
				local cs = remote.call(PT, "click", pt, 1, hand[1], inv, false)
				expect(cs == "no-power", "fetching blanks without power: " .. tostring(cs))
				eei.power_production = 1e6
				st.t, st.phase = tick, "lit"
			elseif tick - st.t > 300 then
				problems[#problems + 1] = "the network kept its power 300 ticks after the source was cut: " .. serpent.line(n)
				eei.power_production = 1e6
				return finish()
			end
			return
		end
		if st.phase == "lit" then
			local sc = remote.call(NET, "screen", pt)
			if sc and sc.on and sc.variation == 2 then
				expect(remote.call(PT, "problem", pt) == nil, "problem with the power back: " .. tostring(remote.call(PT, "problem", pt)))
				st.phase = "tabs"
			elseif tick - st.t > 300 then
				problems[#problems + 1] = "the screen stayed dark after the power came back: " .. serpent.line(sc)
				return finish()
			end
			return
		end
		if st.phase == "tabs" then
			local tabs = remote.call(TERM, "tabs")
			local names = table.concat(tabs, ",")
			expect(#tabs == 4 and names == "storage,crafting,jobs,cells", "the ME Terminal's tabs: " .. names)
			st.hand.destroy()
			st.inv.destroy()
			return finish("the block joins the network (+8 kW, no pole, walkable, a lit screen); a crafting and a processing pattern; blank from the slot, "
				.. "else the network, never the inventory; encoded again in place without a blank; shift into the inventory; the slots' clicks and shift + click; "
				.. "load and clear from the hand or the output slot; a clone empty, mined into the buffer, destroyed spilled; dark and refusing without power; "
				.. "the ME Terminal has four tabs")
		end
	end

	function T.running(check) check(storage.patternterm130 and storage.patternterm130.done, "ME Pattern Terminal") end
	return T
end
