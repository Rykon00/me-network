--- Runtime test of me-network issue #150 (an experiment): the hand-over buffer of the ME Terminal opened next to the
--- game's inventory window. The harness has no player, so the buffer's functions are called as the events call them
--- (remote gregtorio-me-gui buffer_absorb / buffer_return): plates put into the buffer arrive in the network, a used
--- science pack (refused as damaged) stays in the buffer, and what is left goes back to the player (an inventory stands in
--- for the player's) when the window closes; the map setting exists and is on by default (issue #168: every ME window).
--- A drive's buffer takes a storage cell into a free slot (its window's shift), as every window's buffer does what its
--- shift + click did.
--- Loaded by control.lua: require("buffer150")(H) returns { setup, tick, running }.

local NET, GUI = "gregtorio-me-network", "gregtorio-me-gui"
local BX, BY = 10, -300
local START = 120
local PACK = "automation-science-pack"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "terminal buffer"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 12.5, BY - 2.5)
		H.me_connect(fails, what, { ctrl, drive, term })
		storage.buffer150_scene = { term = term, drive = drive }
		return fails
	end

	function T.tick()
		local st = storage.buffer150
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.buffer150 = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local sc = storage.buffer150_scene
		local t = sc and sc.term
		if not (t and t.valid) then
			expect(false, "the terminal was not built")
			return me_report("BUFFER", "ME terminal buffer", problems)
		end
		local setting = settings.global["me-network-real-inventory"]
		expect(setting and setting.value == true, "the setting (issue #168: on by default): " .. serpent.line(setting and setting.value))
		local slots = remote.call(GUI, "buffer_slots")
		local inv = game.create_inventory(slots)
		inv.insert{ name = "iron-plate", count = 50 }
		inv.insert{ name = PACK, count = 3, durability = 0.5 }
		local before = remote.call(NET, "count", t, "iron-plate")
		local n = remote.call(GUI, "buffer_absorb", inv, "terminal", t)
		expect(n == 1 and remote.call(NET, "count", t, "iron-plate") == before + 50 and inv.get_item_count("iron-plate") == 0,
			"plates from the buffer: " .. tostring(n) .. " stacks, network " .. remote.call(NET, "count", t, "iron-plate"))
		expect(inv.get_item_count(PACK) == 3 and remote.call(NET, "count", t, PACK) == 0, "the used packs stayed in the buffer: "
			.. inv.get_item_count(PACK))
		local player = game.create_inventory(10)
		remote.call(GUI, "buffer_return", inv, player, t)
		expect(inv.is_empty() and player.get_item_count(PACK) == 3, "what was left went back: buffer " .. tostring(inv.is_empty())
			.. ", player " .. player.get_item_count(PACK))
		--- issue #168: the drive window's buffer puts a storage cell into a free slot (the drive's shift)
		local drive = sc.drive
		if drive and drive.valid then
			local cells = function() local n = 0 for _ in pairs(remote.call(NET, "drive", drive)) do n = n + 1 end return n end
			local before_cells = cells()
			inv.insert{ name = "me-1k-storage-cell", count = 1 }
			local m = remote.call(GUI, "buffer_absorb", inv, "drive", drive)
			expect(m == 1 and cells() == before_cells + 1 and inv.is_empty(), "a cell from the drive window's buffer: " .. tostring(m)
				.. ", cells " .. before_cells .. " -> " .. cells())
		else
			expect(false, "the drive is missing")
		end
		inv.destroy()
		player.destroy()
		me_report("BUFFER", "ME terminal buffer", problems, "stored from the buffer, a refused stack kept and returned, a cell into a drive")
	end

	function T.running(check) check(storage.buffer150 and storage.buffer150.done, "ME terminal buffer") end

	return T
end
