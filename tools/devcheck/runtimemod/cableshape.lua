--- Runtime test of me-network issue #670: the shape of ME Cable (graphics_variation = 1 + N + 2E + 4S + 8W) when blueprints
--- are pasted next to and onto cable, and the shape of cable ghosts. On a surface of its own ("me-cableshape-test",
--- concrete), every scene in a free row of it:
--- * A: a corner (three cables, stored 7, 9, 2) pasted next to a built line: the ghosts show their arms to the line (8, 10,
---   2), the line keeps its built shape (11) until the ghosts are built, then the line's two cables are T pieces (15);
--- * B: the same corner pasted onto the line (two of its cables on line cables: the game gives them the blueprint's 7 and 9
---   and raises no event): after the paste (the next tick) the line is 11 again, after the build (1,1) is 15 and (2,1) 11;
--- * B2: a paste that brings no new cable (two cables stored 3 and 9 onto the middle of a line): the line is 11 again;
--- * C: a ghost line as a shift-drag makes it (ghosts without a stored shape, raise_built): 3 11 11 9; a blueprint of four
---   cables all stored with variation = 1 pasted: 3 11 11 9;
--- * D: ghosts that go: one cancelled (deconstruction order), one destroyed without an event (as undo removes it), one built
---   (revive with raise_revive, as robots build): their ghost neighbours follow; an ME Interface ghost and a built ME block
---   next to a cable ghost (arm), the block mined (no arm), an underground cable ghost facing away (no arm) and facing it (arm);
--- * at the end every entity is removed and the module keeps nothing (`counts`).
--- A new ghost takes its shape on the next tick (the module's queue), what goes and what a member changes at once; every
--- step waits two ticks (on_object_destroyed comes at the end of the tick or the next one).
--- The paste is what on_pre_build does for a player (remote `note_paste`, then build_blueprint with raise_built as a paste
--- raises on_built_entity per ghost). Everything ends before the save at tick 500.
--- Loaded by control.lua: require("cableshape")(H) returns { setup, tick, running }.

local CS = "gregtorio-me-cableshape"
local SURFACE = "me-cableshape-test"
local START = 140
local CABLE, UG = "me-cable", "me-underground-cable"
local D = defines.direction

local function surface()
	local s = game.surfaces[SURFACE]
	if s then return s end
	s = game.create_surface(SURFACE, { width = 128, height = 128, default_enable_all_autoplace_controls = false,
		autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
			decorative = { treat_missing_as_default = false, settings = {} } } })
	s.always_day = true
	s.request_to_generate_chunks({ 0, 0 }, 2)
	s.force_generate_chunk_requests()
	local tiles = {}
	for x = -40, 39 do for y = -40, 39 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
	s.set_tiles(tiles)
	return s
end

--- a blueprint in a script inventory of `list` ({ name, x, y, variation, direction }, positions in the blueprint's frame)
local function blueprint(list)
	local inv = game.create_inventory(1)
	inv.insert{ name = "blueprint" }
	local bp = inv[1]
	local ents = {}
	for i, c in ipairs(list) do
		ents[i] = { entity_number = i, name = c[1], position = { c[2], c[3] }, variation = c[4], direction = c[5] }
	end
	bp.set_blueprint_entities(ents)
	return inv, bp
end

return function(H)
	local me_report = H.me_report
	local T = {}

	function T.setup()
		surface()
		storage.cableshape670 = { problems = {}, step = 0 }
		return {}
	end

	function T.tick()
		local st = storage.cableshape670
		if not st or st.done or game.tick < START then return end
		if st.wait and game.tick < st.wait then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[SURFACE]
		local function finish(note)
			st.done = true
			me_report("CABLESHAPE", "ME Cable shapes from blueprints and of ghosts (issue #670)", problems, note)
		end
		if not s then expect(false, "no test surface") return finish() end
		local has = remote.interfaces[CS] ~= nil         -- (without it the scenes still run: a version before #670)
		--- the entity (or ghost) of `name` at tile (x, y) of row `oy`
		local function at(x, y, ghost, name)
			local p = { x + 0.5, y + 0.5 }
			if ghost then
				for _, g in pairs(s.find_entities_filtered{ name = "entity-ghost", position = p }) do
					if g.ghost_name == (name or CABLE) then return g end
				end
				return nil
			end
			return s.find_entities_filtered{ name = name or CABLE, position = p, limit = 1 }[1]
		end
		local function var(x, y, ghost)
			local e = at(x, y, ghost)
			return e and e.graphics_variation or "-"
		end
		--- the shapes of tiles {x, y, ghost} in one line
		local function shapes(list)
			local out = {}
			for i, t in ipairs(list) do out[i] = tostring(var(t[1], t[2], t[3])) end
			return table.concat(out, " ")
		end
		local function check(what, list, want)
			local got = shapes(list)
			expect(got == want, what .. ": " .. got .. ", wanted " .. want)
		end
		local function cable(x, y, name, dir)
			return s.create_entity{ name = name or CABLE, position = { x + 0.5, y + 0.5 }, force = "player", direction = dir, raise_built = true }
		end
		local function ghost(x, y, name, dir)
			return s.create_entity{ name = "entity-ghost", inner_name = name or CABLE, position = { x + 0.5, y + 0.5 }, force = "player",
				direction = dir, raise_built = true }
		end
		--- paste `list` with its middle at `pos` as a player's paste: on_pre_build first, then the build
		local function paste(list, pos)
			local inv, bp = blueprint(list)
			if has then remote.call(CS, "note_paste", bp, s, "player", pos, D.north, false, false) end
			local made = bp.build_blueprint{ surface = s, force = "player", position = pos, raise_built = true } or {}
			inv.destroy()
			return made
		end
		local function revive(list)
			for _, g in pairs(list) do if g.valid and g.name == "entity-ghost" then g.revive{ raise_revive = true } end end
		end
		local function line(y, x1, x2) for x = x1, x2 do cable(x, y) end end
		--- the corner: (0,0) east and south (7), (1,0) west (9), (0,1) north (2); its middle (1, 1) lands on a tile corner
		local CORNER = { { CABLE, 0.5, 0.5, 7 }, { CABLE, 1.5, 0.5, 9 }, { CABLE, 0.5, 1.5, 2 } }
		local step = st.step
		st.step = step + 1
		st.wait = game.tick + 2                            -- (on_object_destroyed comes at the end of this tick or the next)

		--- A: a line y = -20 (x 0..4) and a corner pasted south of it at (1..2, -19) (ghosts take their shape the next tick)
		if step == 0 then
			line(-20, 0, 4)
			check("A: the built line", { { 0, -20 }, { 1, -20 }, { 2, -20 }, { 3, -20 }, { 4, -20 } }, "3 11 11 11 9")
			st.a = paste(CORNER, { 2, -18 })
		elseif step == 1 then
			check("A: the corner ghosts next to the line", { { 1, -19, true }, { 2, -19, true }, { 1, -18, true } }, "8 10 2")
			check("A: the line a tick after the paste", { { 1, -20 }, { 2, -20 } }, "11 11")
			revive(st.a)
			st.a = nil
			check("A: built", { { 1, -20 }, { 2, -20 }, { 1, -19 }, { 2, -19 }, { 1, -18 } }, "15 15 8 10 2")

		--- B: a line y = -10 and the corner onto it at (1..2, -10)
		elseif step == 2 then
			line(-10, 0, 4)
			st.b = paste(CORNER, { 2, -9 })
			expect(#st.b == 1, "B: the paste made " .. #st.b .. " ghosts, wanted 1")
		elseif step == 3 then
			check("B: the ghost on the line", { { 1, -9, true } }, "2")
			check("B: the line a tick after the paste", { { 0, -10 }, { 1, -10 }, { 2, -10 }, { 3, -10 } }, "3 11 11 11")
			revive(st.b)
			st.b = nil
		elseif step == 4 then
			check("B: built", { { 1, -10 }, { 2, -10 }, { 1, -9 } }, "15 11 2")
			--- B2: two cables stored 3 and 9 onto the middle of the line y = -5: no new cable
			line(-5, 0, 4)
			local made = paste({ { CABLE, 0.5, 0.5, 3 }, { CABLE, 1.5, 0.5, 9 } }, { 2, -4.5 })
			expect(#made == 0, "B2: the paste made " .. #made .. " ghosts, wanted none")
			st.b2 = shapes({ { 1, -5 }, { 2, -5 } })
			--- C: a ghost line as a shift-drag makes it (y = 0), and a blueprint of four cables stored 1 (y = 5)
			for x = 0, 3 do ghost(x, 0) end
			paste({ { CABLE, 0.5, 0.5, 1 }, { CABLE, 1.5, 0.5, 1 }, { CABLE, 2.5, 0.5, 1 }, { CABLE, 3.5, 0.5, 1 } }, { 2, 5.5 })
		elseif step == 5 then
			expect(st.b2 == "3 9", "B2: the game did not overwrite the shapes (" .. tostring(st.b2) .. "): the scene tests nothing")
			check("B2: the line a tick after a paste without new cable", { { 0, -5 }, { 1, -5 }, { 2, -5 }, { 3, -5 }, { 4, -5 } },
				"3 11 11 11 9")
			check("C: shift-drag ghosts", { { 0, 0, true }, { 1, 0, true }, { 2, 0, true }, { 3, 0, true } }, "3 11 11 9")
			check("C: a blueprint stored with dots", { { 0, 5, true }, { 1, 5, true }, { 2, 5, true }, { 3, 5, true } }, "3 11 11 9")

		--- D: ghosts that go (the ghost lines of C)
			local g = at(1, 0, true)
			expect(g and g.order_deconstruction("player"), "D: the ghost (1,0) took no deconstruction order")
			local h = at(2, 5, true)
			if h then h.destroy() else expect(false, "D: no ghost (2,5)") end
		elseif step == 6 then
			check("D: a ghost cancelled", { { 0, 0, true }, { 1, 0, true }, { 2, 0, true }, { 3, 0, true } }, "1 - 3 9")
			check("D: a ghost destroyed without an event", { { 0, 5, true }, { 1, 5, true }, { 2, 5, true }, { 3, 5, true } }, "3 9 - 1")
			local g = at(2, 0, true)
			if g then g.revive{ raise_revive = true } else expect(false, "D: no ghost (2,0)") end
			--- an ME Interface ghost east of the cable ghost (3,5); underground cable ghost west of (0,0) facing away (west)
			st.iface = ghost(4, 5, "me-network-interface")
			st.ug = ghost(-1, 0, UG, D.west)
			--- a built ME block south of the ghost (0,5): an arm at once (the member joins the graph)
			st.block = cable(0, 6)
			check("D: a cable built next to a ghost", { { 0, 5, true } }, "7")
		elseif step == 7 then
			check("D: a ghost built", { { 2, 0 }, { 3, 0, true } }, "1 9")
			check("D: next to an interface ghost", { { 3, 5, true } }, "3")
			check("D: an underground ghost facing away", { { 0, 0, true } }, "1")
			if st.ug and st.ug.valid then st.ug.destroy() end
			st.ug = ghost(-1, 0, UG, D.east)
			if st.iface and st.iface.valid then st.iface.order_deconstruction("player") end
			if st.block and st.block.valid then st.block.destroy{ raise_destroy = true } end
			check("D: the built cable mined", { { 0, 5, true } }, "3")
		elseif step == 8 then
			check("D: an underground ghost facing the cable", { { 0, 0, true } }, "9")
			check("D: the interface ghost cancelled", { { 3, 5, true } }, "1")
			st.step = 11

		--- the end: everything goes, nothing is kept
		elseif step == 11 then
			for _, e in pairs(s.find_entities_filtered{ area = { { -40, -40 }, { 40, 40 } } }) do
				if e.valid and (e.name == "entity-ghost" or e.name == CABLE or e.name == UG) then
					e.destroy{ raise_destroy = true }
				end
			end
		elseif step == 12 then
			expect(has, "no remote interface " .. CS)
			local c = has and remote.call(CS, "counts", s) or { ghosts = 0, pastes = 0 }
			expect(c.ghosts == 0 and c.pastes == 0 and not c.surfaces and (c.tiles or 0) == 0 and (c.queued or 0) == 0, "left in the module's state: " .. serpent.line(c))
			local left = #s.find_entities_filtered{ area = { { -40, -40 }, { 40, 40 } }, name = { CABLE, UG, "entity-ghost" } }
			expect(left == 0, left .. " entities left")
			return finish("corner next to and onto a line, a paste without cable, shift-drag and dot blueprints, ghosts that go (tick "
				.. game.tick .. ")")
		end
	end

	function T.running(check) check(storage.cableshape670 and storage.cableshape670.done, "ME Cable shapes (issue #670)") end

	return T
end
