--- Runtime test of me-network issue #747: a blueprint book in the cursor. The cursor handler of issue #673
--- (scripts/fork-me-cableturn.lua `held`) asks scripts/fork-me-pasteover.lua `resolve` for the blueprint a book stands
--- for; a book whose active index points past its inventory (an empty book: no slots, active index 1) stopped the game
--- with "Index out of inventory bounds". The harness has no player, so the test hands item stacks of a script inventory
--- to both functions (remotes gregtorio-me-pasteover `resolves` and gregtorio-me-cableturn `held_stack`, which is `held`
--- for an item in the cursor):
--- * an empty book: not a blueprint, no error;
--- * a book with one blueprint of an ME Drive: the blueprint, held; a copy of the book (set_stack, as Ctrl+C of the stack
---   or a clone): the same;
--- * that book after its blueprint was taken out (the active blueprint removed): not a blueprint, no error;
--- * a book whose active slot is empty while another slot has the blueprint: not a blueprint;
--- * a book with a blueprint that is not set up: not a blueprint;
--- * a book in a book, the inner one with the blueprint: the blueprint, held; the inner one empty: not a blueprint;
--- * a plain item and an empty slot: not a blueprint.
--- A book of the blueprint library (a LuaRecord) cannot be made without a player; its branch reads `contents[i]`, a Lua
--- table, where an index past the end is nil.
--- Loaded by control.lua: require("bookcursor")(H) returns { setup, tick, running }.

local PO, CT = "gregtorio-me-pasteover", "gregtorio-me-cableturn"
local START = 135
local MAIN = defines.inventory.item_main

return function(H)
	local me_report = H.me_report
	local T = {}

	function T.tick()
		local st = storage.bookcursor747
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.bookcursor747 = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			me_report("BOOKCURSOR", "a blueprint book in the cursor (issue #747)", problems, note)
		end
		local po, ct = remote.interfaces[PO], remote.interfaces[CT]
		if not (po and po.resolves and ct and ct.held_stack) then return finish("nothing to check: a version before #747") end

		local inv = game.create_inventory(8)
		local facts = {}
		--- both functions on `stack`: `want` is whether it stands for a set-up blueprint (and one with an ME block is held)
		local function case(label, stack, want)
			local ok, got = pcall(remote.call, PO, "resolves", stack)
			expect(ok, label .. ": resolve stopped with " .. tostring(got))
			if ok then expect(got == want, label .. ": resolve gives " .. tostring(got) .. ", expected " .. tostring(want)) end
			local ok2, held = pcall(remote.call, CT, "held_stack", stack)
			expect(ok2, label .. ": held stopped with " .. tostring(held))
			if ok2 then expect(held == want, label .. ": held gives " .. tostring(held) .. ", expected " .. tostring(want)) end
		end
		local function drive_blueprint(stack)
			stack.set_stack{ name = "blueprint" }
			stack.set_blueprint_entities{ { entity_number = 1, name = "me-drive", position = { 0, 0 } } }
		end

		inv[1].set_stack{ name = "blueprint-book" }
		local book = inv[1]
		local binv = book.get_inventory(MAIN)
		facts[#facts + 1] = "an empty book has " .. #binv .. " slots and active index " .. tostring(book.active_index)
		case("an empty book", book, false)

		binv.insert{ name = "blueprint" }
		expect(#binv >= 1, "the book took no blueprint")
		if #binv >= 1 then
			case("a book with a blueprint that is not set up", book, false)
			drive_blueprint(binv[1])
			case("a book with one blueprint", book, true)
			inv[2].set_stack(book)
			case("a copy of the book", inv[2], true)

			binv.clear()
			facts[#facts + 1] = "after its blueprint was removed: " .. #binv .. " slots, active index " .. tostring(book.active_index)
			case("a book whose blueprint was removed", book, false)
			case("the copy made before, still with its blueprint", inv[2], true)
		end

		--- two blueprints, the second active, then the second removed
		inv[3].set_stack{ name = "blueprint-book" }
		local b3 = inv[3]
		local i3 = b3.get_inventory(MAIN)
		i3.insert{ name = "blueprint" }
		i3.insert{ name = "blueprint" }
		if #i3 >= 2 then
			drive_blueprint(i3[1])
			drive_blueprint(i3[2])
			local ok = pcall(function() b3.active_index = 2 end)
			case("a book with the second blueprint active", b3, true)
			i3[2].clear()
			facts[#facts + 1] = "second of two active (set " .. tostring(ok) .. ") and removed: " .. #i3 .. " slots, active index "
				.. tostring(b3.active_index)
			local i = b3.active_index
			local filled = i and i >= 1 and i <= #i3 and i3[i].valid_for_read or false
			case("a book whose active blueprint was removed", b3, filled)
		else
			expect(false, "a book took only " .. #i3 .. " of two blueprints")
		end

		--- a book in a book
		inv[4].set_stack{ name = "blueprint-book" }
		local outer = inv[4]
		local oinv = outer.get_inventory(MAIN)
		oinv.insert{ name = "blueprint-book" }
		if #oinv >= 1 then
			case("a book with an empty book", outer, false)
			local iinv = oinv[1].get_inventory(MAIN)
			iinv.insert{ name = "blueprint" }
			if #iinv >= 1 then
				drive_blueprint(iinv[1])
				case("a book in a book with a blueprint", outer, true)
				iinv.clear()
				case("a book in a book whose blueprint was removed", outer, false)
			else
				expect(false, "the inner book took no blueprint")
			end
		else
			expect(false, "the outer book took no book")
		end

		inv[5].set_stack{ name = "iron-plate", count = 5 }
		case("a plain item", inv[5], false)
		case("an empty slot", inv[6], false)

		inv.destroy()
		finish(table.concat(facts, "; "))
	end

	function T.running(check) check(storage.bookcursor747 and storage.bookcursor747.done, "blueprint book in the cursor") end

	return T
end
