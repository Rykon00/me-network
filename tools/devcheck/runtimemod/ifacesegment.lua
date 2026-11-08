--- Runtime test of me-network issue #626: a fluid row counts what the side's whole fluid segment holds (its tank and the
--- pipes behind it), and a side that holds more gives the surplus back to the network.
--- Two networks, each a controller, a drive with four 16k fluid cells partitioned for water, 20000 water, and an interface
--- whose east side is tied to a row of AMOUNT water, with PIPES pipes in a line behind it (no consumer; the segment holds
--- far more than the row) and its other sides off.
---   * Both: once settled, the segment (the tank's and the pipes' shares summed) holds AMOUNT and the network lost exactly
---     that (before, the side was filled until its tank alone held the amount: the pipes took more than twice the row).
---   * A: the row is lowered to AMOUNT / 2: the segment holds AMOUNT / 2 and the network got the other half back.
---   * B: a save the old code over-filled: EXTRA water appears in its last pipe without an event while B's cells take
---     steam only (no room): the side says "full" and keeps it. At ROOM the partition is cleared (no wake for that): the
---     surplus goes back within two idle limits (a side holding a surplus is never put to sleep), the segment holds
---     AMOUNT again and the network holds what it had plus EXTRA (nothing lost, nothing duplicated).
--- The scene runs through the save and load of the save-and-load run.
--- Loaded by control.lua: require("ifacesegment")(H) returns { setup, tick, running }.

local NET, IO = "gregtorio-me-network", "gregtorio-me-io"
local BX, BY = -760, -380
local START, LAST = 200, 1450
local EAST = 2
local AMOUNT, PIPES, EXTRA, WATER = 3000, 60, 4000, 20000
local TOL = 1                                                -- (segment counts are rounded)
local SETTLE = 120                                           -- ticks a state must hold (a first visit is not a settled side)

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	--- a network with an interface and PIPES pipes in a line from its east side; returns { iface, drive, pipes }
	local function scene(s, fails, what, x, y)
		power(s, fails, what, x, y)
		local ctrl = me_place(s, fails, what, "me-network-controller", x + 7, y)
		local drive = H.me_drive(s, fails, what, x + 8.5, y - 0.5, {}, "16k", true)
		local iface = me_place(s, fails, what, "me-network-interface", x + 10.5, y + 3.5)
		H.me_connect(fails, what, { ctrl, drive, iface })
		if drive then
			for slot = 1, 4 do remote.call(NET, "set_partition", drive, slot, { "fluid/water" }) end
		end
		local pipes = {}
		local tank = iface and (remote.call(IO, "interface_tanks", iface) or {})[EAST]
		local conn = tank and tank.get_fluid_box_pipe_connections(1)[1]
		if conn then
			local p = conn.target_position
			local dx, dy = p.x - tank.position.x, p.y - tank.position.y      -- (away from the interface)
			dx, dy = dx ~= 0 and dx / math.abs(dx) or 0, dy ~= 0 and dy / math.abs(dy) or 0
			for i = 1, PIPES do pipes[i] = me_place(s, fails, what, "pipe", p.x + (i - 1) * dx, p.y + (i - 1) * dy) end
		else
			fails[#fails + 1] = what .. ": the interface's east tank has no pipe connection"
		end
		return { iface = iface, drive = drive, pipes = pipes }
	end

	function T.setup(s)
		local fails = {}
		local what = "interface segment"
		local tiles = {}                                         -- (land under the scenes)
		for x = BX - 4, BX + 16 + PIPES do
			for y = BY - 6, BY + 26 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		storage.ifacesegment626_scene = { a = scene(s, fails, what, BX, BY), b = scene(s, fails, what, BX, BY + 16) }
		return fails
	end

	--- what the side's segment holds: the tank's and the pipes' shares summed (not the engine's rounded segment count)
	local function segment(sc)
		local t = (remote.call(IO, "interface_tanks", sc.iface) or {})[EAST]
		local f = t and t.get_fluid(1)
		local n = f and f.amount or 0
		for _, p in ipairs(sc.pipes) do
			local pf = p.get_fluid(1)
			n = n + (pf and pf.amount or 0)
		end
		return n
	end
	local function water(sc) return remote.call(NET, "fluid_count", sc.iface, "water") end
	local function side(sc) return (remote.call(IO, "get_interface", sc.iface) or { fluids = {} }).fluids[EAST] or {} end
	local function near(a, b) return math.abs(a - b) <= TOL end
	local function f0(n) return string.format("%.1f", n) end

	function T.tick()
		local tick = game.tick
		local st = storage.ifacesegment626
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false }
			storage.ifacesegment626 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		local function finish(note)
			st.done = true
			me_report("IFACESEGMENT", "ME interface fluid row over its segment (issue #626)", problems, note)
		end
		local sc = storage.ifacesegment626_scene or {}
		local a, b = sc.a or {}, sc.b or {}
		local ok = true
		for _, x in pairs({ a, b }) do
			if not (x.iface and x.iface.valid and x.drive and x.drive.valid and #x.pipes == PIPES) then ok = false end
			for _, p in ipairs(x.pipes or {}) do if not p.valid then ok = false end end
		end
		if not ok then
			problems[#problems + 1] = "the scene is missing"
			return finish()
		end
		if not st.started then
			st.started = tick
			for _, x in pairs({ a, b }) do
				remote.call(NET, "insert_fluid", x.iface, "water", WATER)
				expect(remote.call(IO, "set_interface_key", x.iface, 1, "fluid/water", AMOUNT), "a fluid row of water")
				for d = 1, 4 do remote.call(IO, "set_interface_side", x.iface, d, d == EAST and 1 or "off") end
			end
			st.a0, st.b0 = water(a), water(b)
			expect(near(st.a0, WATER) and near(st.b0, WATER), "the networks hold the water: " .. f0(st.a0) .. ", " .. f0(st.b0))
			return
		end
		local late = tick >= LAST
		--- has `ok` held for SETTLE ticks? (st[key]: the first tick of the streak)
		local function steady(key, ok)
			if not ok then st[key] = nil return false end
			st[key] = st[key] or tick
			return tick - st[key] >= SETTLE
		end

		--- 1. both sides settle at the row's amount over the whole segment
		if not st.filled then
			local sa, sb = segment(a), segment(b)
			if not steady("fill_at", near(sa, AMOUNT) and near(sb, AMOUNT) and near(st.a0 - water(a), AMOUNT)
				and near(st.b0 - water(b), AMOUNT)) and not late then return end
			st.filled = tick
			for name, x in pairs({ A = a, B = b }) do
				local seg, lost = segment(x), (name == "A" and st.a0 or st.b0) - water(x)
				expect(near(seg, AMOUNT), name .. ": the segment holds " .. f0(seg) .. " (" .. AMOUNT .. " expected)")
				expect(near(lost, AMOUNT), name .. ": the network lost " .. f0(lost) .. " (" .. AMOUNT .. " expected)")
				expect(math.abs(seg - lost) < 1e-3, name .. ": the segment holds " .. f0(seg) .. ", the network lost " .. f0(lost))
			end
			st.fill_note = "filled to " .. f0(segment(a)) .. " (network -" .. f0(st.a0 - water(a)) .. ")"
			--- 2. A's row lowered; B over-filled (as by the old code) while its network has no room for water
			expect(remote.call(IO, "set_interface_key", a.iface, 1, "fluid/water", AMOUNT / 2), "A's row lowered")
			for slot = 1, 4 do remote.call(NET, "set_partition", b.drive, slot, { "fluid/steam" }) end
			local n = b.pipes[PIPES].insert_fluid{ name = "water", amount = EXTRA }
			expect(math.abs(n - EXTRA) < 1e-3, "B: the water into its last pipe: " .. f0(n))
			st.b1 = water(b)
			return
		end

		--- A: the half comes back
		if not st.lowered then
			if steady("lower_at", near(segment(a), AMOUNT / 2) and near(st.a0 - water(a), AMOUNT / 2)) or late then
				st.lowered = tick
				local seg, lost = segment(a), st.a0 - water(a)
				expect(near(seg, AMOUNT / 2), "A after the lowered row: the segment holds " .. f0(seg) .. " (" .. AMOUNT / 2 .. " expected)")
				expect(math.abs(seg - lost) < 1e-3, "A after the lowered row: the segment holds " .. f0(seg)
					.. ", the network lost " .. f0(lost) .. " (nothing lost or duplicated)")
				st.lower_note = "lowered to " .. f0(seg) .. " in " .. ((st.lower_at or tick) - st.filled) .. " ticks"
			end
		end

		--- B: "full" while there is no room, then room without a wake
		if not st.room then
			if side(b).status ~= "full" and not late then return end
			st.room = tick
			expect(side(b).status == "full", "B with a surplus and no room: the side says " .. tostring(side(b).status))
			expect(near(water(b), st.b1) and near(segment(b), AMOUNT + EXTRA), "B kept the surplus while there was no room: network "
				.. f0(water(b)) .. " (" .. f0(st.b1) .. "), segment " .. f0(segment(b)))
			for slot = 1, 4 do remote.call(NET, "set_partition", b.drive, slot, { "fluid/water" }) end
			return
		end
		if not st.back then
			if steady("back_at", near(segment(b), AMOUNT) and near(water(b), st.b1 + EXTRA)) or late then
				st.back = st.back_at or tick
			end
		end
		if not (st.lowered and st.back) then return end

		local limit = remote.interfaces[IO].idle_limit and remote.call(IO, "idle_limit") or 300
		local seg, net = segment(b), water(b)
		expect(near(seg, AMOUNT), "B after the room: the segment holds " .. f0(seg) .. " (" .. AMOUNT .. " expected)")
		expect(math.abs(net - (st.b1 + EXTRA)) < 1e-3 and math.abs((st.b0 - net) - (seg - EXTRA)) < 1e-3,
			"B after the room: the network holds " .. f0(net) .. " (" .. f0(st.b1 + EXTRA) .. " expected), the segment " .. f0(seg))
		expect(st.back - st.room <= 2 * limit + 10, "B: the surplus went back " .. (st.back - st.room)
			.. " ticks after the room appeared (idle limit " .. limit .. ")")
		return finish(st.fill_note .. " over " .. PIPES .. " pipes; " .. tostring(st.lower_note) .. "; a surplus of " .. EXTRA
			.. " kept while the network had no room and returned " .. (st.back - st.room) .. " ticks after it had")
	end

	function T.running(check) check(storage.ifacesegment626 and storage.ifacesegment626.done, "ME interface fluid row over its segment (issue #626)") end
	return T
end
