--- Runtime test of me-network issue #542: the player's inventory in the ME windows is Factorio 2.1's GUI element
--- `inventory` (the game draws it and moves stacks to and from the hand); what it leaves to the mod comes through
--- on_gui_inventory_action. The harness has no player, so the actions are called as the event handler calls them (remote
--- gregtorio-me-gui inventory_click, an inventory standing for the player's): shift + click stores a stack in the terminal's
--- network (a used science pack is refused and stays), shift + right click half of it, control + click every stack (the
--- terminal's own rule), control + right click half of each, a plain click in remote view the whole stack, any other action
--- nothing; a drive takes a cell by shift + click and every cell of a kind by control + click. The handling flags of the
--- element in and outside remote view. The hand-over buffer of 0.5.10 is gone: the map setting no longer exists, a buffer
--- of an old save goes back into its player's inventory (what does not fit is parked, never spilled, and returned later),
--- and close_all (a mod update) leaves no buffer behind.
--- Loaded by control.lua: require("nativeinv")(H) returns { setup, tick, running }.

local NET, GUI = "gregtorio-me-network", "gregtorio-me-gui"
local BX, BY = 10, -300
local START = 120
local PACK = "zz-devcheck-tool-1"          -- (a tool with durability, data.lua; issue #487)

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "native inventory"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 12.5, BY - 2.5)
		H.me_connect(fails, what, { ctrl, drive, term })
		storage.nativeinv_scene = { term = term, drive = drive }
		return fails
	end

	function T.tick()
		local st = storage.nativeinv
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.nativeinv = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local sc = storage.nativeinv_scene
		local t = sc and sc.term
		if not (t and t.valid) then
			expect(false, "the terminal was not built")
			return me_report("NATIVEINV", "ME windows with the native inventory", problems)
		end
		local g = function(fn, ...) return remote.call(GUI, fn, ...) end
		local function count(name) return remote.call(NET, "count", t, name) end

		--- the map setting of the hand-over buffer is gone
		expect(settings.global["me-network-real-inventory"] == nil, "the setting me-network-real-inventory still exists")

		--- the element's handling flags: the game moves stacks to and from the hand outside remote view, not in it
		local f, r = g("pane_flags", false), g("pane_flags", true)
		expect(f.handle_cursor_transfer and f.handle_cursor_split and f.handle_open_item and f.handle_open_mod_item
			and f.handle_send_stack_to_trash and f.handle_send_stacks_to_trash, "flags outside remote view: " .. serpent.line(f))
		expect(not r.handle_cursor_transfer and not r.handle_cursor_split and r.handle_open_item, "flags in remote view: " .. serpent.line(r))

		--- the actions at the terminal
		local pinv = game.create_inventory(10)
		local function click(slot, mode, e) return g("inventory_click", nil, pinv, slot, mode, e or t) end
		pinv[1].set_stack{ name = "iron-plate", count = 50 }
		local before = count("iron-plate")
		local why = click(1, "shift")
		expect(why == nil and count("iron-plate") == before + 50 and not pinv[1].valid_for_read, "shift + click of 50 plates: "
			.. tostring(why) .. ", network " .. before .. " -> " .. count("iron-plate"))
		pinv[2].set_stack{ name = PACK, count = 3, durability = 0.5 }
		why = click(2, "shift")
		expect(why ~= nil and pinv[2].valid_for_read and pinv[2].count == 3 and count(PACK) == 0, "a used pack refused and kept: "
			.. tostring(why))
		pinv[3].set_stack{ name = "iron-plate", count = 40 }
		before = count("iron-plate")
		why = click(3, "shift-right")
		expect(why == nil and count("iron-plate") == before + 20 and pinv[3].count == 20, "shift + right click: half of 40 plates: "
			.. tostring(why) .. ", " .. (pinv[3].valid_for_read and pinv[3].count or 0) .. " left")
		pinv[4].set_stack{ name = "iron-plate", count = 30 }
		pinv[5].set_stack{ name = "iron-plate", count = 7 }
		before = count("iron-plate")
		why = click(4, "control")
		expect(why == nil and count("iron-plate") == before + 57 and pinv.get_item_count("iron-plate") == 0,
			"control + click: every stack of plates: " .. tostring(why) .. ", " .. pinv.get_item_count("iron-plate") .. " left")
		pinv[3].set_stack{ name = "copper-plate", count = 10 }
		pinv[4].set_stack{ name = "copper-plate", count = 10 }
		pinv[5].set_stack{ name = "copper-plate", count = 9 }
		before = count("copper-plate")
		why = click(4, "control-right")
		expect(why == nil and count("copper-plate") == before + 15 and pinv.get_item_count("copper-plate") == 14,
			"control + right click: half of each stack: " .. tostring(why) .. ", " .. pinv.get_item_count("copper-plate") .. " left")
		before = count("copper-plate")
		why = click(3, "remote")
		expect(why == nil and count("copper-plate") == before + 5 and not pinv[3].valid_for_read, "a click in remote view sends the stack: "
			.. tostring(why))
		before = count("copper-plate")
		why = click(4, "left")
		expect(why == nil and count("copper-plate") == before and pinv[4].count == 5, "another action moves nothing: " .. tostring(why))
		why = click(9, "shift")
		expect(why == nil, "shift + click on an empty slot: " .. tostring(why))
		pinv.clear()

		--- the drive: a cell by shift + click, every cell of a kind by control + click (the drive has no rule of its own)
		local drive = sc.drive
		if drive and drive.valid then
			local cells = function() local n = 0 for _ in pairs(remote.call(NET, "drive", drive)) do n = n + 1 end return n end
			local c0 = cells()
			pinv[1].set_stack{ name = "me-1k-storage-cell", count = 1 }
			why = click(1, "shift", drive)
			expect(why == nil and cells() == c0 + 1 and not pinv[1].valid_for_read, "a cell into the drive: " .. tostring(why))
			pinv[2].set_stack{ name = "me-1k-storage-cell", count = 1 }
			pinv[6].set_stack{ name = "me-1k-storage-cell", count = 1 }
			why = click(2, "control", drive)
			expect(why == nil and cells() == c0 + 3 and pinv.is_empty(), "control + click: both cells into the drive: " .. tostring(why)
				.. ", cells " .. c0 .. " -> " .. cells())
			pinv[1].set_stack{ name = "iron-plate", count = 5 }
			why = click(1, "shift", drive)
			expect(why ~= nil and pinv[1].count == 5, "plates refused by the drive: " .. tostring(why))
			pinv.clear()
		else
			expect(false, "the drive is missing")
		end
		pinv.destroy()

		--- a hand-over buffer of a 0.5.10 save: back into the player's inventory
		local main = game.create_inventory(10)
		g("stand_in", "legacy", { main = main, index = 9101 })
		local buf = game.create_inventory(20)
		buf.insert{ name = "iron-plate", count = 50 }
		buf.insert{ name = PACK, count = 3, durability = 0.5 }
		g("legacy_buffer", 9101, buf)
		local n = g("stand_in_drop_buffer", "legacy")
		expect(n == 2 and main.get_item_count("iron-plate") == 50 and main.get_item_count(PACK) == 3 and not buf.valid
			and not g("has_legacy_buffer", 9101), "a buffer back to its player: " .. tostring(n) .. " stacks, plates "
			.. main.get_item_count("iron-plate") .. ", packs " .. main.get_item_count(PACK))
		--- a full inventory: parked, never spilled, returned when there is room
		local full = game.create_inventory(4)
		for i = 1, #full do full[i].set_stack{ name = "stone", count = 50 } end
		g("stand_in", "legacyfull", { main = full, index = 9102 })
		buf = game.create_inventory(20)
		buf.insert{ name = "copper-plate", count = 20 }
		g("legacy_buffer", 9102, buf)
		local items = game.surfaces[1].count_entities_filtered{ type = "item-entity" }
		g("stand_in_drop_buffer", "legacyfull")
		expect(g("stand_in_parked", "legacyfull") == 20 and game.surfaces[1].count_entities_filtered{ type = "item-entity" } == items,
			"a full inventory: parked " .. g("stand_in_parked", "legacyfull"))
		full.clear()
		local left = g("stand_in_return_parked", "legacyfull")
		expect(left == 0 and full.get_item_count("copper-plate") == 20, "parked items returned: " .. full.get_item_count("copper-plate"))
		--- a mod update (close_all): no buffer stays behind, also of a player who is gone
		buf = game.create_inventory(20)
		g("legacy_buffer", 9200, buf)
		g("close_all")
		expect(not g("has_legacy_buffer") and not buf.valid, "close_all left a buffer")
		g("stand_in_forget", "legacy")
		g("stand_in_forget", "legacyfull")
		main.destroy()
		full.destroy()
		me_report("NATIVEINV", "ME windows with the native inventory", problems, "shift, shift + right, control, control + right "
			.. "and remote view clicks at the terminal and the drive; flags; old buffers handed back, parked and dropped")
	end

	function T.running(check) check(storage.nativeinv and storage.nativeinv.done, "ME windows with the native inventory") end

	return T
end
