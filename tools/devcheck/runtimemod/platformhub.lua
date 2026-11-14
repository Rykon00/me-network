--- Runtime test of me-network issue #749: the ME windows on a Space Age space platform. A player there is in the remote
--- controller with their character in the hub (measured in a graphical client: controller remote, get_main_inventory()
--- nil, player.hub the hub, the character on the platform at the hub), and a rocket takes nobody with items: the
--- character's inventory is empty and what the platform has lies in the hub. The window's pane showed that empty
--- character inventory, so no cell could be put into an ME Drive. The pane is the hub's inventory there now.
--- A real platform (create_space_platform, its starter pack) with an ME Controller, an ME Drive and an ME Cell Workbench
--- on it; the harness has no player, so a stand-in (remote gregtorio-me-gui stand_in, `surface`: what the player looks at):
--- * in remote view of the platform: the inventory of the windows is the hub's, the hand holds nothing; the drive's window
---   has the pane titled "Platform hub" with the hub's help line, bound to the hub's inventory, the hand left to the mod;
--- * in remote view of a planet: the character's inventory and the remote view lines, as before (issues #176, #177);
--- * a storage cell in the hub: a plain click on it in the pane (the remote view's click) puts it into the drive; a click
---   on the filled drive slot takes it back into the hub; with a full hub it stays in the drive ("inventory-full");
--- * the workbench's cell slot and its window's pane the same way.
--- Without Space Age: nothing to check.
--- Loaded by control.lua: require("platformhub")(H) returns { setup, tick, running }.

local NET, GUI, WB = "gregtorio-me-network", "gregtorio-me-gui", "gregtorio-me-workbench"
local START, WAIT = 150, 60
local CELL = "me-16k-storage-cell"

return function(H)
	local me_report, me_place = H.me_report, H.me_place
	local T = {}

	function T.tick()
		local st = storage.platformhub749
		if st and st.done or game.tick < START then return end
		local function finish(problems, note)
			st.done = true
			me_report("PLATFORMHUB", "ME windows on a space platform (issue #749)", problems, note)
		end
		if not st then
			st = { problems = {} }
			storage.platformhub749 = st
			local force = game.forces.player
			if not (script.active_mods["space-age"] and prototypes.item["space-platform-starter-pack"]) then
				return finish(st.problems, "nothing to check: no space platforms without Space Age")
			end
			if not remote.interfaces[GUI].stand_in_hub then return finish({ "no stand_in_hub: a version before #749" }) end
			local ok, platform = pcall(force.create_space_platform, { name = "me-hub-test", planet = "nauvis",
				starter_pack = "space-platform-starter-pack" })
			if not (ok and platform) then return finish({ "no space platform: " .. tostring(platform) }) end
			platform.apply_starter_pack()
			st.platform = platform
			st.check = game.tick + WAIT
			return
		end
		if game.tick < st.check then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local platform = st.platform
		local hub = platform.valid and platform.hub
		if not (hub and hub.valid) then return finish({ "the platform has no hub" }) end
		local s = platform.surface
		local tiles = {}
		for x = -10, 14 do for y = 8, 16 do tiles[#tiles + 1] = { name = "space-platform-foundation", position = { x, y } } end end
		for x = -2, 2 do for y = 0, 8 do tiles[#tiles + 1] = { name = "space-platform-foundation", position = { x, y } } end end
		s.set_tiles(tiles)
		local fails = {}
		local eei = me_place(s, fails, "platform", "electric-energy-interface", -6, 12)
		if eei then eei.power_production = 1e6 eei.electric_buffer_size = 1e7 eei.energy = 1e7 end
		me_place(s, fails, "platform", "substation", -3, 12)
		local ctrl = me_place(s, fails, "platform", "me-network-controller", 1, 12)
		local drive = me_place(s, fails, "platform", "me-drive", 2.5, 11.5)
		local bench = me_place(s, fails, "platform", "me-cell-workbench", 6.5, 11.5)
		for _, f in ipairs(fails) do problems[#problems + 1] = f end
		if not (ctrl and drive and bench) then return finish(problems) end

		local g = function(fn, ...) return remote.call(GUI, fn, ...) end
		local hub_inv = hub.get_inventory(defines.inventory.hub_main)
		hub_inv.clear()
		local char = game.create_inventory(10)                   -- the character's inventory: empty, as after a rocket ride
		g("stand_in", "on-platform", { remote = true, character = char, index = 9411, surface = s, gui = true })
		g("stand_in", "on-planet", { remote = true, character = char, index = 9412, gui = true })

		expect(g("stand_in_inventory", "on-platform") == hub_inv, "remote view of the platform: the hub's inventory")
		expect(g("stand_in_hub", "on-platform") == hub_inv and g("stand_in_hub", "on-planet") == nil, "the hub of the platform in view")
		expect(g("stand_in_inventory", "on-planet") == char, "remote view of a planet: the character's inventory")
		local c, inv, remote_view = g("stand_in_hand", "on-platform")
		expect(c == nil and inv == hub_inv and remote_view == true, "the hand on a platform: no cursor, the hub's inventory, remote")

		local view = g("stand_in_open_window", "on-platform", "drive", drive.unit_number)
		expect(view and view.pane_title == "fork-me-gui.platform-hub" and view.pane_help == "fork-me-gui.hub-help"
			and view.inventory_bound and view.cursor_transfer == false, "the drive's window on the platform: " .. serpent.line(view))
		g("stand_in_close_window", "on-platform", false)
		view = g("stand_in_open_window", "on-planet", "drive", drive.unit_number)
		expect(view and view.pane_title == "fork-me-gui.character" and view.pane_help == "fork-me-gui.remote-help",
			"the drive's window in remote view of a planet: " .. serpent.line(view))
		g("stand_in_close_window", "on-planet", false)

		--- a cell from the hub into the drive by a click in the pane, and back by a click on the drive's slot
		local function cells() local n = 0 for _ in pairs(remote.call(NET, "drive", drive)) do n = n + 1 end return n end
		hub_inv.insert{ name = "iron-plate", count = 10 }
		hub_inv.insert{ name = CELL, count = 1 }
		local slot
		for i = 1, #hub_inv do if hub_inv[i].valid_for_read and hub_inv[i].name == CELL then slot = i end end
		expect(slot ~= nil, "the hub took no cell")
		if slot then
			local why = g("inventory_click", nil, hub_inv, slot, "remote", drive)
			expect(why == nil and cells() == 1 and hub_inv.get_item_count(CELL) == 0, "a click on the cell in the pane: " .. tostring(why)
				.. ", cells in the drive " .. cells() .. ", in the hub " .. hub_inv.get_item_count(CELL))
			local dslot = next(remote.call(NET, "drive", drive))
			local out
			why, out = remote.call(NET, "drive_click", c, inv, drive, dslot, remote_view)
			expect(why == nil and out == "out" and cells() == 0 and hub_inv.get_item_count(CELL) == 1, "the cell back into the hub: "
				.. tostring(why) .. "/" .. tostring(out) .. ", in the hub " .. hub_inv.get_item_count(CELL))
			expect(char.is_empty(), "nothing went to the character")
			--- a full hub: the cell stays in the drive
			for i = 1, #hub_inv do if hub_inv[i].valid_for_read and hub_inv[i].name == CELL then slot = i end end
			g("inventory_click", nil, hub_inv, slot, "remote", drive)
			local plates = prototypes.item["iron-plate"].stack_size
			hub_inv.insert{ name = "iron-plate", count = plates * #hub_inv }
			dslot = next(remote.call(NET, "drive", drive))
			why = remote.call(NET, "drive_click", c, inv, drive, dslot, remote_view)
			expect(why == "inventory-full" and cells() == 1, "a full hub: " .. tostring(why) .. ", cells in the drive " .. cells())
			hub_inv.clear()
		end

		--- the workbench: its pane on the platform, a cell from the hub into its slot and back
		view = g("stand_in_open_window", "on-platform", "workbench", bench.unit_number)
		expect(view and view.pane_title == "fork-me-gui.platform-hub" and view.inventory_bound, "the workbench's window: " .. serpent.line(view))
		g("stand_in_close_window", "on-platform", false)
		hub_inv.insert{ name = CELL, count = 1 }
		local why = g("inventory_click", nil, hub_inv, 1, "remote", bench)
		local info = remote.call(WB, "info", bench)
		expect(why == nil and info and info.cell ~= nil and hub_inv.get_item_count(CELL) == 0, "a cell from the hub into the workbench: "
			.. tostring(why))
		local out
		why, out = g("block_click", bench, 1, c, inv, remote_view)
		expect(why == nil and out == "out" and hub_inv.get_item_count(CELL) == 1, "the workbench's cell back into the hub: " .. tostring(why))

		g("stand_in_forget", "on-platform")
		g("stand_in_forget", "on-planet")
		char.destroy()
		for _, e in pairs({ drive, bench, ctrl, eei }) do if e and e.valid then e.destroy{ raise_destroy = true } end end
		finish(problems, "the hub's inventory in the pane, a cell from the hub into the drive and the workbench and back, a full hub; "
			.. "the hub has " .. #hub_inv .. " slots")
	end

	function T.running(check) check(storage.platformhub749 and storage.platformhub749.done, "ME windows on a space platform") end

	return T
end
