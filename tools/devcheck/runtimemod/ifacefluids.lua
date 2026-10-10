--- Runtime test of me-network issue #311: the ME Interface window shows the fluids its sides hold.
--- A network (controller, a drive with four 16k fluid cells partitioned for water, 20000 water) and an interface:
---   * north: tied to a fluid row of 1000 water, so the network fills its tank;
---   * east: imports (the default), two pipes at it hold 3000 steam at 500 °C that the network has no room for, so the
---     steam stays in the tank and the pipes (one fluid segment: the pipes hold some of it);
---   * south and west: import, nothing connected, empty.
--- Once the north tank is full: the window's entries are the two sides (water with its fill, steam with its temperature
--- and what its pipes hold too), the empty sides give none. The fluid section, built into a stand-in frame (the harness
--- has no player), shows them; a second refresh does not build it anew; a new amount is set in place; when the tanks
--- are emptied it is built anew with the "no side holds fluid" line. All in one tick (the stand-in frame is not saved).
--- Loaded by control.lua: require("ifacefluids")(H) returns { setup, tick, running }.

local NET, IO, GUI = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-gui"
local BX, BY = -660, -420
local START, LAST = 200, 1500
local NORTH, EAST = 1, 2
local WATER, STEAM, DEG = 1000, 3000, 500

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "interface fluids"
		local tiles = {}                                         -- (land under the scene)
		for x = BX - 4, BX + 18 do
			for y = BY - 6, BY + 12 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k", true)
		local iface = me_place(s, fails, what, "me-network-interface", BX + 10.5, BY + 3.5)
		H.me_connect(fails, what, { ctrl, drive, iface })
		if drive then
			for slot = 1, 4 do remote.call(NET, "set_partition", drive, slot, { "fluid/water" }) end
		end
		local pipes = {}
		local tank = iface and (remote.call(IO, "interface_tanks", iface) or {})[EAST]
		local conn = tank and tank.fluidbox.get_pipe_connections(1)[1]
		if conn then
			local p = conn.target_position
			local dx, dy = p.x - tank.position.x, p.y - tank.position.y      -- (away from the interface)
			dx, dy = dx ~= 0 and dx / math.abs(dx) or 0, dy ~= 0 and dy / math.abs(dy) or 0
			pipes[1] = me_place(s, fails, what, "pipe", p.x, p.y)
			pipes[2] = me_place(s, fails, what, "pipe", p.x + dx, p.y + dy)
		else
			fails[#fails + 1] = what .. ": the interface's east tank has no pipe connection"
		end
		storage.ifacefluids311_scene = { iface = iface, pipes = pipes }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.ifacefluids311
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false }
			storage.ifacefluids311 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		local function finish(note)
			st.done = true
			me_report("IFACEFLUIDS", "ME interface window fluids (issue #311)", problems, note)
		end
		local sc = storage.ifacefluids311_scene or {}
		local iface, pipes = sc.iface, sc.pipes or {}
		if not (iface and iface.valid and pipes[1] and pipes[1].valid and pipes[2] and pipes[2].valid) then
			problems[#problems + 1] = "the scene is missing"
			return finish()
		end
		local tanks = remote.call(IO, "interface_tanks", iface) or {}
		if not st.started then
			st.started = tick
			remote.call(NET, "insert_fluid", iface, "water", 20000)
			expect(remote.call(IO, "set_interface_key", iface, 1, "fluid/water", WATER), "a fluid row of water")
			for side = 1, 4 do                    -- (a new fluid row takes the side with pipes: east imports here)
				remote.call(IO, "set_interface_side", iface, side, side == NORTH and 1 or "import")
			end
			local n = pipes[2].insert_fluid{ name = "steam", amount = STEAM, temperature = DEG }
			expect(n >= STEAM - 1e-6, "steam into the pipes at the east side: " .. n)
			return
		end
		local north = tanks[NORTH] and tanks[NORTH].fluidbox[1]
		if not (north and north.amount >= WATER - 0.5) and tick < LAST then return end
		expect(north and north.amount >= WATER - 0.5, "the network did not fill the north side: " .. serpent.line(north))

		--- the entries of the window's data
		local d = remote.call(IO, "get_interface", iface)
		local south = d and d.fluids[3] or {}
		expect(south.name == nil and south.segment == 0, "the empty south side " .. serpent.line(south))
		local es = remote.call(GUI, "interface_fluid_entries", iface) or {}
		local w, sm = es[1] or {}, es[2] or {}
		expect(#es == 2, "two sides hold fluid, entries: " .. serpent.line(es))
		expect(w.side == NORTH and w.key == "fluid/water" and math.abs(w.amount - WATER) < 1
			and math.abs(w.fill - WATER / d.volume) < 0.01 and w.segment == nil, "the water entry " .. serpent.line(w))
		expect(sm.side == EAST and sm.key == "fluid/steam@" .. DEG and sm.amount > 0 and sm.segment
			and sm.segment >= STEAM - 1 and sm.segment > sm.amount + 1, "the steam entry (its pipes hold some) " .. serpent.line(sm))

		--- the fluid section of the window
		remote.call(GUI, "stand_in_forget", "if311")
		local v = remote.call(GUI, "interface_fluid_view", "if311", iface)
		local r1, r2 = v.rows[1] or {}, v.rows[2] or {}
		expect(v.rebuilt and #v.rows == 2 and not v.none, "the section's first build " .. serpent.line(v))
		expect(r1.sprite == "fluid/water" and r1.number == WATER and r1.elem_tooltip and r1.elem_tooltip.type == "fluid"
			and r1.elem_tooltip.name == "water" and math.abs((r1.value or 0) - WATER / d.volume) < 0.01
			and type(r1.caption) == "table" and r1.caption[2] and r1.caption[2][1] == "fork-me-gui.interface-fluid-fill"
			and r1.caption[4] == "", "the water row " .. serpent.line(r1))
		expect(r2.sprite == "fluid/steam" and type(r2.caption) == "table" and r2.caption[2]
			and type(r2.caption[2][2]) == "table" and r2.caption[2][2][1] == "fork-me-gui.fluid-at-temperature"
			and r2.caption[2][2][3] == tostring(DEG) and type(r2.caption[4]) == "table"
			and r2.caption[4][1] == "fork-me-gui.interface-fluid-pipes", "the steam row (temperature, pipes) " .. serpent.line(r2))
		v = remote.call(GUI, "interface_fluid_view", "if311", iface)
		expect(not v.rebuilt and #v.rows == 2, "a refresh without a change built the section anew")
		tanks[NORTH].remove_fluid{ name = "water", amount = 400 }
		v = remote.call(GUI, "interface_fluid_view", "if311", iface)
		r1 = v.rows[1] or {}
		expect(not v.rebuilt and r1.number == WATER - 400 and math.abs((r1.value or 0) - (WATER - 400) / d.volume) < 0.01,
			"a new amount is set in place " .. serpent.line(v))
		for _, e in pairs({ tanks[NORTH], tanks[EAST], pipes[1], pipes[2] }) do e.clear_fluid_inside() end
		v = remote.call(GUI, "interface_fluid_view", "if311", iface)
		expect(v.rebuilt and #v.rows == 0 and type(v.none) == "table" and v.none[1] == "fork-me-gui.interface-fluids-none",
			"the section once the tanks are empty " .. serpent.line(v))
		expect(#(remote.call(GUI, "interface_fluid_entries", iface) or { 0 }) == 0, "entries once the tanks are empty")
		remote.call(GUI, "stand_in_forget", "if311")
		return finish("north " .. WATER .. " water, east " .. string.format("%.0f", sm.amount or 0) .. " steam at " .. DEG
			.. " °C in its tank, " .. string.format("%.0f", sm.segment or 0) .. " with its pipes; built once, amounts in place, emptied")
	end

	function T.running(check) check(storage.ifacefluids311 and storage.ifacefluids311.done, "ME interface window fluids (issue #311)") end
	return T
end
