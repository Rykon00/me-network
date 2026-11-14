--- Runtime test of me-network issue #674: a turned blueprint over ME blocks whose direction does not show (the drive and the
--- others of scripts/fork-me-cableturn.lua). Everything goes through the real LuaItemStack.build_blueprint in normal mode: a
--- blueprint of the block and a wooden chest eight tiles beside it on free ground, so a paste the game takes makes the chest's ghost and a refused one
--- makes nothing. On a surface of its own ("me-turnblocks-test", concrete):
--- * every block with an item that this mod makes is placed north and pasted over turned east. The game's answer sorts them: a
---   refused block must be in the module's list (remote `agnostic`), or one that uses its direction (REAL below, the test's
---   own table), so a new block has to be classified;
--- * the blocks of the list: refused before the turn; remote `align` with R turns them east, the same unit number, and the
---   paste is taken;
--- * the blocks of REAL: `align` leaves them north and the paste stays refused;
--- * a network (controller, drive with 4 cells, terminal, a line of cable, a marked drive and a marked cable): the drive
---   turned and pasted over keeps its unit number, the cells, what the terminal sees, its priority and the network; the graph
---   version is the same; a crafting CPU keeps its picture through the turn and, one tick later, through the paste (which
---   writes the blueprint's stored variation over it: scripts/fork-me-cableshape.lua puts the picture back);
--- * a ghost of a block is turned and the paste is taken; a ghost of a bus is not turned;
--- * a block marked for deconstruction is not turned, stays marked and out of the network, and a paste over it is taken;
--- * `normalise` stores a turned drive as north;
--- * a pattern provider (a display panel with a circuit connector) keeps its red wire through the turn and the paste.
--- Loaded by control.lua: require("turnblocks")(H) returns { setup, tick, running }.

local CT = "gregtorio-me-cableturn"
local CS = "gregtorio-me-cableshape"
local NET = "gregtorio-me-network"
local SURFACE = "me-turnblocks-test"
local START = 160
local D = defines.direction
local R = "fork-me-cable-rotate"
local PLATES = 100

--- the blocks that do use their direction, or that stay refused on purpose: why, for the failure text
local REAL = {
	["me-import-bus"] = "faces a target", ["me-export-bus"] = "faces a target", ["me-storage-bus"] = "faces a target",
	["me-item-p2p-tunnel"] = "faces a target", ["me-fluid-p2p-tunnel"] = "faces a target",
	["me-underground-cable"] = "open side",
	["me-level-emitter"] = "wire connection points", ["me-advanced-level-emitter"] = "wire connection points",
	["me-circuit-interface"] = "wire connection points",
}

return function(H)
	local me_report, me_drive, me_place, cable_row = H.me_report, H.me_drive, H.me_place, H.cable_row
	local T = {}

	local function surface()
		local s = game.surfaces[SURFACE]
		if s then return s end
		s = game.create_surface(SURFACE, { width = 512, height = 512, default_enable_all_autoplace_controls = false,
			autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
				decorative = { treat_missing_as_default = false, settings = {} } } })
		s.always_day = true
		s.request_to_generate_chunks({ 0, 0 }, 8)
		s.force_generate_chunk_requests()
		local tiles = {}
		for x = -240, 239 do for y = -240, 239 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
		s.set_tiles(tiles)
		return s
	end

	local X, Y = 40, 200

	function T.setup()
		local s = surface()
		local st = { fails = {} }
		storage.turnblocks674 = st
		local fails, what = st.fails, "turnblocks"
		H.power(s, fails, what, X + 7, Y + 6)
		me_place(s, fails, what, "me-network-controller", X + 7, Y)
		st.drive = me_drive(s, fails, what, X + 8.5, Y - 0.5, { ["iron-plate"] = PLATES })
		st.term = me_place(s, fails, what, "me-terminal", X + 9.5, Y - 0.5)
		cable_row(s, fails, X + 10, X + 14, Y - 1)
		st.marked = me_place(s, fails, what, "me-drive", X + 15.5, Y - 0.5)
		st.mcable = s.find_entity("me-cable", { X + 14.5, Y - 0.5 })
		st.unit1 = me_place(s, fails, what, "me-crafting-unit", X + 7.5, Y + 1.5)
		st.unit2 = me_place(s, fails, what, "me-1k-crafting-storage", X + 8.5, Y + 1.5)
		return {}
	end

	--- a blueprint of `name` at (0.5, 0.5) and a wooden chest 8 tiles north (turned east: 8 tiles east), in a script inventory
	local function blueprint(name)
		local inv = game.create_inventory(1)
		inv.insert{ name = "blueprint" }
		inv[1].set_blueprint_entities({
			{ entity_number = 1, name = name, position = { 0.5, 0.5 } },
			{ entity_number = 2, name = "wooden-chest", position = { 0.5, -7.5 } } })
		return inv, inv[1]
	end

	function T.tick()
		local st = storage.turnblocks674
		if not st or st.done or game.tick < START then return end
		local s = game.surfaces[SURFACE]
		if st.check then                                   -- (the tick after the paste: the picture is back)
			if game.tick < st.check then return end
			local problems = st.problems
			local e = st.unit2
			if not (e and e.valid and e.graphics_variation == st.var2) then
				problems[#problems + 1] = "the crafting block's picture after the paste: " .. tostring(e and e.valid and e.graphics_variation)
					.. ", wanted " .. tostring(st.var2)
			end
			st.done = true
			me_report("TURNBLOCKS", "Turned blueprints over ME blocks whose direction does not show (issue #674)", problems, st.note)
			return
		end
		local problems = {}
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			st.problems, st.note, st.check = problems, note, game.tick + 2
		end
		for _, f in ipairs(st.fails) do expect(false, f) end
		if not s then expect(false, "no test surface") return finish() end
		if not remote.interfaces[CT] then expect(false, "no remote interface " .. CT) return finish() end

		local names = remote.call(CT, "agnostic")
		local agnostic = {}
		for _, n in ipairs(names) do agnostic[n] = true end

		--- a free spot; `step` tiles apart, so that no blueprint touches another test's
		local cx, cy = -230, -230
		local function spot()
			local x, y = cx, cy
			cx = cx + 24
			if cx > 220 then cx, cy = -230, cy + 24 end
			return x, y
		end
		--- where the blueprint of `name` lands against its paste position, turned east: measured on free ground
		local offsets = {}
		local function offset(name)
			local o = offsets[name]
			if o then return o end
			local x, y = spot()
			local inv, bp = blueprint(name)
			local at = { x = x + 0.5, y = y + 0.5 }
			for _, g in pairs(bp.build_blueprint{ surface = s, force = "player", position = at, direction = D.east } or {}) do
				if g.ghost_name == name then o = { g.position.x - at.x, g.position.y - at.y } end
				g.destroy()
			end
			inv.destroy()
			offsets[name] = o
			return o
		end
		--- the turned paste of `name` over what stands at `e.position`: how many ghosts it made, and the ghost of the block
		local function paste(name, e)
			local o = offset(name)
			if not o then return 0 end
			local inv, bp = blueprint(name)
			local made = bp.build_blueprint{ surface = s, force = "player", position = { e.position.x - o[1], e.position.y - o[2] },
				direction = D.east } or {}
			inv.destroy()
			local count, ghost = #made, nil
			for _, g in pairs(made) do
				if g.ghost_name == name then ghost = g else g.destroy() end
			end
			return count, ghost
		end
		local function stand(name, direction)
			local p = prototypes.entity[name]
			local x, y = spot()
			local dx = (p.tile_width or 1) % 2 == 1 and 0.5 or 0
			local dy = (p.tile_height or 1) % 2 == 1 and 0.5 or 0
			return s.create_entity{ name = name, position = { x + dx, y + dy }, force = "player", direction = direction or D.north }
		end
		local function align(e, keys) remote.call(CT, "align", s, e.position, keys) end

		--- every block of this mod that an item places: what the game says, and what the module does
		local all = {}
		for name, p in pairs(prototypes.entity) do
			local h = prototypes.get_history(p.type, name)
			--- (issue #711: not a block a player cannot build on this ground at all, the ME Space Molecular Assembler: the game
			--- refuses every paste of it here, turned or not)
			if h and h.created == "me-network" and p.items_to_place_this and #p.items_to_place_this > 0 and not name:find("%-legacy$")
					and not p.collision_mask.layers.ground_tile then
				all[#all + 1] = name
			end
		end
		table.sort(all)
		local refused, turned = 0, 0
		for _, name in ipairs(all) do
			local e = stand(name)
			if not e then
				expect(false, name .. ": not placed")
			else
				local unit = e.unit_number
				local hinv, hbp = blueprint(name)
				local holds = remote.call(CT, "holds", hbp)
				hinv.destroy()
				expect(holds == (agnostic[name] == true), name .. ": a blueprint with it counts as held: " .. tostring(holds))
				local count = paste(name, e)
				local is_refused = count == 0
				if is_refused then
					refused = refused + 1
					expect(agnostic[name] or REAL[name], name .. ": the game refuses a turned paste, and the block is classified neither "
						.. "as direction-agnostic nor as using its direction")
				end
				if agnostic[name] then
					expect(is_refused, name .. ": is in the list, but a turned paste was taken before the turn")
					align(e, { R })
					expect(e.direction == D.east and e.unit_number == unit, name .. ": after R the direction is " .. tostring(e.direction)
						.. ", wanted east (the same unit number)")
					local after = paste(name, e)
					expect(after == 1, name .. ": the turned paste after R made " .. after .. " ghosts, wanted the chest's")
					if after == 1 then turned = turned + 1 end
				elseif REAL[name] then
					align(e, { R })
					expect(e.direction == D.north, name .. ": was turned (" .. REAL[name] .. ")")
					local after = paste(name, e)
					expect(after == 0, name .. ": a turned paste made " .. after .. " ghosts, it should stay refused (" .. REAL[name] .. ")")
				end
				e.destroy()
			end
		end
		for _, n in ipairs(names) do
			local found = false
			for _, a in ipairs(all) do if a == n then found = true end end
			expect(found, n .. " is in the list but is no block of this mod")
		end

		--- the network: controller, drive with cells, terminal, cable line, a drive and a cable to mark; a CPU of two blocks
		local drive, term, marked, mcable, unit1, unit2 = st.drive, st.term, st.marked, st.mcable, st.unit1, st.unit2
		if drive and term and marked and mcable and unit1 and unit2 then
			remote.call(NET, "set_priority", drive, 7)
			local function info()
				local cells, held = 0, 0
				for _, c in pairs(remote.call(NET, "drive", drive) or {}) do
					cells = cells + 1
					held = held + ((c.items or {})["iron-plate"] or 0)
				end
				return cells .. " cells, " .. held .. " iron, " .. remote.call(NET, "count", term, "iron-plate") .. " seen, priority "
					.. tostring(remote.call(NET, "get_priority", drive))
			end
			local want = "4 cells, " .. PLATES .. " iron, " .. PLATES .. " seen, priority 7"
			expect(info() == want, "the network before the turn: " .. info())
			local unit = drive.unit_number
			local nets = remote.call(NET, "same_network", term, drive)
			expect(nets, "the drive is not in the terminal's network before the turn")
			local var1, var2 = unit1.graphics_variation, unit2.graphics_variation
			st.var2 = var2
			expect(var2 ~= 1, "the crafting block's picture is the default one: the scene tests nothing")

			marked.order_deconstruction("player")
			mcable.order_deconstruction("player")
			expect(remote.call(NET, "network", marked) == nil, "the marked drive is still in a network")

			local version = remote.call(NET, "version")     -- (after the marks, which are changes of the network)
			align(drive, { R })

			expect(drive.direction == D.east and drive.unit_number == unit, "the drive after R: direction " .. tostring(drive.direction))
			expect(remote.call(NET, "version") == version, "the turn changed the network's version: a rebuild or a storage change")
			expect(info() == want, "the network after the turn: " .. info())
			expect(remote.call(NET, "same_network", term, drive), "the turn took the drive out of the terminal's network")
			expect(unit1.graphics_variation == var1 and unit2.graphics_variation == var2, "the turn changed a crafting block's picture")
			expect(unit1.direction == D.east and unit2.direction == D.east, "the CPU's blocks were not turned")
			--- marks: not turned, still marked, still out
			expect(marked.direction == D.north, "the marked drive was turned")
			expect(mcable.direction == D.north, "the marked cable was turned")
			expect(marked.to_be_deconstructed() and mcable.to_be_deconstructed(), "a mark was lost")
			expect(remote.call(NET, "network", marked) == nil, "the marked drive is back in a network")
			expect(remote.call(NET, "network", mcable) == nil, "the marked cable is back in a network")

			local count = paste("me-drive", drive)
			expect(count == 1, "the turned paste over the drive made " .. count .. " ghosts, wanted the chest's")
			expect(drive.valid and drive.unit_number == unit and info() == want, "the drive after the paste: " .. (drive.valid and info() or "gone"))
			local count2, ghost = paste("me-drive", marked)
			expect(count2 == 2 and ghost ~= nil, "the turned paste over the marked drive made " .. count2 .. " ghosts, wanted the block's and the chest's")
			if ghost and ghost.valid then ghost.destroy() end
			expect(marked.valid and marked.to_be_deconstructed() and remote.call(NET, "network", marked) == nil,
				"the paste over the marked drive brought it back")
			--- as on_pre_build for a player's paste (the picture is read before the paste, written back on the next tick)
			local o = offset("me-1k-crafting-storage")
			local pinv, pbp = blueprint("me-1k-crafting-storage")
			local at = { x = unit2.position.x - o[1], y = unit2.position.y - o[2] }
			remote.call(CS, "note_paste", pbp, s, "player", at, D.east, false, false)
			local made = pbp.build_blueprint{ surface = s, force = "player", position = at, direction = D.east } or {}
			pinv.destroy()
			for _, g in pairs(made) do g.destroy() end
			expect(#made == 1, "the turned paste over the CPU block made " .. #made .. " ghosts, wanted the chest's")
			expect(unit2.graphics_variation ~= var2, "the paste did not write over the CPU block's picture: the scene tests nothing")

			--- a blueprint of the turned drive is stored north
			local inv = game.create_inventory(1)
			inv.insert{ name = "blueprint" }
			inv[1].create_blueprint{ surface = s, force = "player", area = { { X + 8.2, Y - 0.8 }, { X + 8.8, Y - 0.2 } } }
			local d0 = (inv[1].get_blueprint_entities() or {})[1]
			remote.call(CT, "normalise", inv[1])
			local d1 = (inv[1].get_blueprint_entities() or {})[1]
			expect(d0 and d0.direction == D.east and d1 and (d1.direction or 0) == 0, "a blueprint of the turned drive: "
				.. tostring(d0 and d0.direction) .. " before, " .. tostring(d1 and d1.direction) .. " after, wanted east and north")
			inv.destroy()
		else
			expect(false, "the network was not placed")
		end

		--- ghosts
		local g = s.create_entity{ name = "entity-ghost", inner_name = "me-drive", position = { 80.5, 200.5 }, force = "player", direction = D.north }
		local refused_ghost = paste("me-drive", g)
		expect(refused_ghost == 0, "a turned paste over a ghost made " .. refused_ghost .. " ghosts before the turn: the scene tests nothing")
		align(g, { R })
		expect(g.direction == D.east, "the ghost of the drive was not turned")
		local onto_ghost = paste("me-drive", g)
		expect(onto_ghost == 1, "the turned paste over the ghost made " .. onto_ghost .. " ghosts, wanted the chest's")
		local bg = s.create_entity{ name = "entity-ghost", inner_name = "me-import-bus", position = { 96.5, 200.5 }, force = "player", direction = D.north }
		align(bg, { R })
		expect(bg.direction == D.north, "the ghost of an import bus was turned")

		--- a pattern provider keeps its wire
		local pa = stand("me-pattern-provider")
		local pb = s.create_entity{ name = "me-pattern-provider", position = { pa.position.x + 2, pa.position.y }, force = "player" }
		local ca = pa.get_wire_connector(defines.wire_connector_id.circuit_red, true)
		local cb = pb.get_wire_connector(defines.wire_connector_id.circuit_red, true)
		expect(ca.connect_to(cb, false), "the two pattern providers could not be wired")
		align(pa, { R })
		expect(pa.direction == D.east, "the wired pattern provider was not turned")
		expect(ca.valid and ca.connection_count == 1, "the turn cut the pattern provider's wire")
		local onto = paste("me-pattern-provider", pa)
		expect(onto == 1, "the turned paste over the wired pattern provider made " .. onto .. " ghosts, wanted the chest's")
		expect(ca.valid and ca.connection_count == 1, "the paste cut the pattern provider's wire")

		return finish(#all .. " blocks, " .. refused .. " refused turned, " .. turned .. " of the list taken after R, the drive's network, marks, ghosts (tick " .. game.tick .. ")")
	end

	function T.running(check) check(storage.turnblocks674 and storage.turnblocks674.done, "Turned blueprints over ME blocks (issue #674)") end

	return T
end
