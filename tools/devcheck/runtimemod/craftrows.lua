--- Runtime test of me-network issue #751: the rows of the ME Terminal's Crafting tab grid (the craftable items). It had 4
--- rows on every screen; it has up to 8 now, by the player's screen (remote gregtorio-me-terminal craft_rows, the height in
--- GUI pixels = screen height over UI scale):
--- * 1080p at 100 % and at 125 %: 8 rows; 1440p: 8 (never more);
--- * 720 GUI pixels (1280 x 720 at 100 %, 1080p at 150 %): 6 rows;
--- * a very small screen (600 pixels, 1080p at 200 %): the 4 rows it had, never fewer.
--- And the window itself: an ME Terminal opened for a stand-in player with a 1080p screen has the grid's scroll pane at
--- 8 * 40 + 8 pixels, with a 720p screen at 6 * 40 + 8; the storage tab's grid keeps its 9 rows.
--- Loaded by control.lua: require("craftrows")(H) returns { setup, tick, running }.

local GUI, TERM = "gregtorio-me-gui", "gregtorio-me-terminal"
local START = 160

return function(H)
	local me_report = H.me_report
	local T = {}

	function T.tick()
		local st = storage.craftrows751
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.craftrows751 = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note) me_report("CRAFTROWS", "rows of the craftable grid (issue #751)", problems, note) end
		if not remote.interfaces[TERM].craft_rows then return finish("nothing to check: a version before #751") end
		local function rows(height, scale) return remote.call(TERM, "craft_rows", height, scale) end
		local cases = { { 1080, 1, 8 }, { 1080, 1.25, 8 }, { 1440, 1, 8 }, { 720, 1, 6 }, { 1080, 1.5, 6 }, { 600, 1, 4 }, { 1080, 2, 4 } }
		local got = {}
		for _, c in ipairs(cases) do
			local r = rows(c[1], c[2])
			got[#got + 1] = c[1] .. "@" .. c[2] .. "=" .. tostring(r)
			expect(r == c[3], "a screen of " .. c[1] .. " pixels at scale " .. c[2] .. ": " .. tostring(r) .. " rows, expected " .. c[3])
		end

		--- the window: a terminal of the test map opened for a stand-in with a screen
		local term
		for _, s in pairs(game.surfaces) do
			term = s.find_entities_filtered{ name = "me-terminal", limit = 1 }[1]
			if term then break end
		end
		if term then
			local g = function(fn, ...) return remote.call(GUI, fn, ...) end
			local inv = game.create_inventory(10)
			for _, c in ipairs({ { "hd", 1080, 8 }, { "small", 720, 6 } }) do
				local name = "craftrows-" .. c[1]
				g("stand_in", name, { main = inv, index = c[2] == 1080 and 9421 or 9422, gui = true, screen = { height = c[2], scale = 1 } })
				local ok, err = pcall(g, "stand_in_open_entity", name, term)
				expect(ok, "the terminal's window for a stand-in: " .. tostring(err))
				if ok then
					local h = g("stand_in_scroll_height", name, "fork_me_craft_grid")
					expect(h == c[3] * 40 + 8, "the craftable grid on a " .. c[2] .. " pixel screen: " .. tostring(h) .. " pixels, expected "
						.. (c[3] * 40 + 8))
					local sh = g("stand_in_scroll_height", name, "fork_me_grid")
					expect(sh == 9 * 40 + 8, "the storage grid keeps 9 rows: " .. tostring(sh))
					g("stand_in_close_window", name, false)
				end
				g("stand_in_forget", name)
			end
			inv.destroy()
		else
			expect(false, "no ME Terminal on the test map")
		end
		finish(table.concat(got, ", "))
	end

	function T.running(check) check(storage.craftrows751 and storage.craftrows751.done, "rows of the craftable grid") end

	return T
end
