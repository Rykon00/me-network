--- Runtime test of me-network issue #545: the ME windows play the game's machine window sounds (Factorio 2.1.13), only for
--- the player who opens or closes one. The harness has no player, so the window functions run on a stand-in (remote
--- gregtorio-me-gui stand_in with `gui`: a stand-in of player.gui.screen, the sounds recorded as play_sound gets them):
--- opening plays utility/machine_gui_open, the same window built again (a rebuild) plays nothing, another window opened
--- from it plays only the open sound, closing plays utility/machine_gui_close, a close without a window or the internal
--- close of a mod update plays nothing. The window it builds has the inventory element of issue #542 bound to the
--- stand-in's inventory.
--- Loaded by control.lua: require("windowsound")(H) returns { setup, tick, running }.

local GUI = "gregtorio-me-gui"
local START = 130
local OPEN, CLOSE = "utility/machine_gui_open", "utility/machine_gui_close"

return function(H)
	local me_report = H.me_report
	local T = {}

	function T.tick()
		local st = storage.windowsound
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.windowsound = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local g = function(fn, ...) return remote.call(GUI, fn, ...) end
		local main = game.create_inventory(20)
		g("stand_in", "sound", { main = main, index = 9301, gui = true })
		local function sounds() return g("stand_in_sounds", "sound") end
		local function line(t) return serpent.line(t) end

		local view = g("stand_in_open_window", "sound", "terminal", 101)
		local s = sounds()
		expect(#s == 1 and s[1] == OPEN, "opening a window: " .. line(s))
		expect(view and view.open and view.opened, "the window is open and the opened GUI: " .. line(view))
		expect(view and view.inventory_bound and view.cursor_transfer == true and view.slots_per_row == 10,
			"the pane's inventory element (issue #542): " .. line(view))
		g("stand_in_open_window", "sound", "terminal", 101)
		s = sounds()
		expect(#s == 1, "the same window built again plays nothing: " .. line(s))
		g("stand_in_open_window", "sound", "drive", 102)
		s = sounds()
		expect(#s == 2 and s[2] == OPEN, "a window opened from another plays only the open sound: " .. line(s))
		g("stand_in_close_window", "sound", true)
		s = sounds()
		expect(#s == 3 and s[3] == CLOSE, "closing plays the close sound: " .. line(s))
		g("stand_in_close_window", "sound", true)
		s = sounds()
		expect(#s == 3, "a close without a window plays nothing: " .. line(s))
		g("stand_in_open_window", "sound", "drive", 102)
		g("stand_in_close_window", "sound", false)
		s = sounds()
		expect(#s == 4 and s[4] == OPEN, "a close without sound (a mod update) plays nothing: " .. line(s))
		g("stand_in_forget", "sound")
		main.destroy()
		me_report("WINSOUND", "ME window sounds", problems, "open, rebuild, open from another window, close, close without a "
			.. "window, silent close; the pane's inventory element")
	end

	function T.running(check) check(storage.windowsound and storage.windowsound.done, "ME window sounds") end

	return T
end
