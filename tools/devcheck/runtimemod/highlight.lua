--- Runtime test of me-network issue #699: the network drawn while a player hovers a member (scripts/fork-me-highlight.lua,
--- remote "gregtorio-me-highlight"; a test draws for a key of its own, visible to everyone, as no player hovers headless).
--- On a surface of its own ("me-highlight-test", concrete):
--- * A, a small network: an underground pair (-5 west, -1 east) with a cable west of it (-6), a line (0..4, 0) from the
---   pair's east end to an ME Drive (5, 0), a branch down from (2, 0) to (2, 2), and a line (6..90, 0) east of the drive. Shown
---   from the cable (0, 0): the lines are exact (from the edge of a block or an underground end, from a middle a little
---   before it where a cable has no neighbour, to the edge of the area at x = 64.5 where the line goes on), the two pictures
---   of the underground ends, one dashed line between them, nothing more. The same shown again is kept (false); shown from the
---   drive after a cable (3, 1) is built it is drawn again and has the new piece; cleared, nothing is left.
--- * B, a lone cable: the pipe's single piece.
--- * C, a grid of 30 x 30 cables (900, more than a tick's steps): it spreads over ticks (still busy after the start, done some
---   ticks later), every cable's middle lies on a drawn line, every drawn line runs over cables only, 60 lines; a cable built
---   while it spreads (30, 30) starts it again and it ends with that cable on its row's line.
--- * at the end every entity is removed and nothing is left drawn or spreading (`counts`).
--- Loaded by control.lua: require("highlight")(H) returns { setup, tick, running }.

local HL = "gregtorio-me-highlight"
local SURFACE = "me-highlight-test"
local START = 150
local CABLE, UG, DRIVE = "me-cable", "me-underground-cable", "me-drive"
local D = defines.direction
local OVER = 4 / 64                  -- (the module's WIDTH / 64)

local function surface()
	local s = game.surfaces[SURFACE]
	if s then return s end
	s = game.create_surface(SURFACE, { width = 256, height = 128, default_enable_all_autoplace_controls = false,
		autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
			decorative = { treat_missing_as_default = false, settings = {} } } })
	s.always_day = true
	s.request_to_generate_chunks({ 0, 0 }, 3)
	s.force_generate_chunk_requests()
	local tiles = {}
	for x = -20, 100 do for y = -10, 50 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
	s.set_tiles(tiles)
	return s
end

local function near(a, b) return math.abs(a - b) < 1e-6 end
local function fmt(o)
	if o[1] == "line" then
		return string.format("line %.4f,%.4f-%.4f,%.4f%s", o[2], o[3], o[4], o[5], o[6] and " dashed" or "")
	end
	return string.format("%s %.4f,%.4f", tostring(o[1]), o[2] or 0, o[3] or 0)
end

return function(H)
	local me_report = H.me_report
	local T = {}

	function T.setup()
		surface()
		storage.highlight699 = { problems = {}, step = 0 }
		return {}
	end

	function T.tick()
		local st = storage.highlight699
		if not st or st.done or game.tick < START then return end
		if st.wait and game.tick < st.wait then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[SURFACE]
		local function finish(note)
			st.done = true
			me_report("HIGHLIGHT", "the network highlighted on hover (issue #699)", problems, note)
		end
		if not s then expect(false, "no test surface") return finish() end
		if not remote.interfaces[HL] then return finish("nothing to check: a version before #699") end
		local function put(name, x, y, dir)
			local e = s.create_entity{ name = name, position = { x + 0.5, y + 0.5 }, force = "player", direction = dir, raise_built = true }
			expect(e ~= nil, "could not build " .. name .. " at " .. x .. "," .. y)
			return e
		end
		local function at(name, x, y) return s.find_entities_filtered{ name = name, position = { x + 0.5, y + 0.5 }, limit = 1 }[1] end
		local function objects(key)
			local r = remote.call(HL, "objects", key)
			return r and r.list or {}, r and r.done
		end
		--- `want` (strings of fmt) and the drawn objects are the same set
		local function same(what, key, want)
			local got = {}
			for _, o in pairs(objects(key)) do got[#got + 1] = fmt(o) end
			table.sort(got)
			local w = {}
			for i, v in ipairs(want) do w[i] = v end
			table.sort(w)
			local a, b = table.concat(got, "; "), table.concat(w, "; ")
			expect(a == b, what .. ": drawn " .. a .. "; wanted " .. b)
		end
		local step = st.step
		st.step = step + 1
		st.wait = game.tick + 1

		if step == 0 then
			--- A and B
			put(CABLE, -6, 0)
			put(UG, -5, 0, D.west)
			put(UG, -1, 0, D.east)
			for x = 0, 4 do put(CABLE, x, 0) end
			put(CABLE, 2, 1)
			put(CABLE, 2, 2)
			local drive = put(DRIVE, 5, 0)
			expect(drive and drive.prototype.tile_width == 1 and drive.prototype.tile_height == 1, "the ME Drive is no 1x1 block")
			for x = 6, 90 do put(CABLE, x, 0) end
			put(CABLE, 10, 8)
			expect(remote.call(HL, "show", "a", at(CABLE, 0, 0)) == true, "A: the highlight did not start")
			local _, done = objects("a")
			expect(done == true, "A: not done in its first steps")
			same("A", "a", {
				string.format("line %.4f,0.5000-%.4f,0.5000", -6 + 0.5 - OVER, -5),        -- (to the underground end)
				"line 0.0000,0.5000-5.0000,0.5000",                                       -- (from the end to the drive)
				string.format("line 2.5000,%.4f-2.5000,%.4f", 0.5 - OVER, 2.5 + OVER),    -- (the branch)
				"line 6.0000,0.5000-65.0000,0.5000",                                      -- (from the drive to the area's edge)
				"line -4.0000,0.5000--1.0000,0.5000 dashed",                              -- (the pair)
				"fork-me-underground-visualization-west -4.5000,0.5000",
				"fork-me-underground-visualization-east -0.5000,0.5000",
			})
			expect(remote.call(HL, "show", "a", at(CABLE, 1, 0)) == false, "A: hovering the next cable drew again")
			put(CABLE, 3, 1)
			expect(remote.call(HL, "show", "a", at(DRIVE, 5, 0)) == true, "A: not drawn again after the graph changed")
			local has = false
			for _, o in pairs(objects("a")) do
				if o[1] == "line" and near(o[2], 3.5) and near(o[4], 3.5) then has = true end
			end
			expect(has, "A: the new cable (3, 1) is not drawn")
			remote.call(HL, "clear", "a")
			expect(remote.call(HL, "objects", "a") == nil, "A: something is left after clear")
			expect(remote.call(HL, "show", "b", at(CABLE, 10, 8)) == true, "B: the highlight did not start")
			same("B", "b", { "fork-me-cable-visualization-single 10.5000,8.5000" })
			remote.call(HL, "clear", "b")
			--- C: the grid
			for x = 0, 29 do for y = 15, 44 do put(CABLE, x, y) end end
			remote.call(HL, "show", "c", at(CABLE, 15, 30))
			local _, cdone = objects("c")
			expect(cdone == false, "C: the grid was drawn in its first steps (it should spread)")
		elseif step == 1 then
			--- C, while it spreads: a cable built next to the grid starts it again
			local _, cdone = objects("c")
			expect(cdone == false, "C: the grid was done after one tick")
			put(CABLE, 30, 30)
			st.t0 = game.tick
		elseif step == 2 then
			local _, cdone = objects("c")
			if not cdone then
				if game.tick - st.t0 > 120 then expect(false, "C: still spreading after 120 ticks") else st.step = 2 end
				return
			end
			st.ticks = game.tick - st.t0
			local list = objects("c")
			--- every drawn line over cables only, every cable's middle on a line
			local covered, lines = {}, 0
			for _, o in pairs(list) do
				if o[1] == "line" then
					lines = lines + 1
					if near(o[3], o[5]) then
						local y = math.floor(o[3])
						for x = math.floor(o[2] + 0.5), math.floor(o[4] - 0.5 + 1e-9) do
							covered[x .. "," .. y] = true
							expect(at(CABLE, x, y) ~= nil, "C: a line over (" .. x .. ", " .. y .. ") without a cable")
						end
					else
						local x = math.floor(o[2])
						for y = math.floor(o[3] + 0.5), math.floor(o[5] - 0.5 + 1e-9) do
							covered[x .. "," .. y] = true
							expect(at(CABLE, x, y) ~= nil, "C: a line over (" .. x .. ", " .. y .. ") without a cable")
						end
					end
				else
					expect(false, "C: a picture in the grid: " .. fmt(o))
				end
			end
			local missing = 0
			for x = 0, 29 do for y = 15, 44 do if not covered[x .. "," .. y] then missing = missing + 1 end end end
			expect(missing == 0, "C: " .. missing .. " cables of the grid on no line")
			expect(covered["30,30"] == true, "C: the cable built while it spread is not drawn")
			expect(lines == 60, "C: " .. lines .. " lines, wanted 60 (30 rows, one of them to the new cable, 30 columns)")
			remote.call(HL, "clear", "c")
			for _, e in pairs(s.find_entities_filtered{ area = { { -40, -20 }, { 120, 60 } }, name = { CABLE, UG, DRIVE } }) do
				e.destroy{ raise_destroy = true }
			end
		elseif step == 3 then
			local c = remote.call(HL, "counts")
			expect(c.highlights == 0 and c.busy == 0, "left after the end: " .. serpent.line(c))
			finish("the grid spread in " .. tostring(st.ticks) .. " ticks")
		end
	end

	function T.running(check) check(storage.highlight699 and storage.highlight699.done, "the network highlight (issue #699)") end

	return T
end
