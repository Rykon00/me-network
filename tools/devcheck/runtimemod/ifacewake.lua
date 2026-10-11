--- Runtime test of me-network issue #313: an ME Interface's import side that holds fluid is visited again, whatever woke it.
--- Two networks, each a controller, a drive with four 16k fluid cells and an interface with no pipe at any side (its sides
--- import; with nothing connected and nothing in its tanks it stops looking at them, `rec.sidle`).
---   * A: at START water appears in its south side's tank without any event (as when a machine's fluid box connects when
---     its recipe is set, or a pump is rotated): the window says it waits ("waiting", not "imports"), and the network
---     holds the water within two idle limits.
---   * B: its cells are partitioned for steam only, so the water that appears in its tank has no room ("full"); at ROOM
---     the partition is cleared (no event wakes the interface for that): the water is imported within two idle limits.
--- The scene runs through the save and load of the save-and-load run (its schedule must be the unbroken run's).
--- Loaded by control.lua: require("ifacewake")(H) returns { setup, tick, running }.

local NET, IO = "gregtorio-me-network", "gregtorio-me-io"
local BX, BY = -620, -420
local START, ROOM, LAST = 300, 560, 1400
local SOUTH = 3
local AMOUNT = 1000

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	local function scene(s, fails, what, x, y, partition)
		power(s, fails, what, x, y)
		local ctrl = me_place(s, fails, what, "me-network-controller", x + 7, y)
		local drive = H.me_drive(s, fails, what, x + 8.5, y - 0.5, {}, "16k", true)
		local iface = me_place(s, fails, what, "me-network-interface", x + 10.5, y + 3.5)
		H.me_connect(fails, what, { ctrl, drive, iface })
		if drive and partition then
			for slot = 1, 4 do remote.call(NET, "set_partition", drive, slot, partition) end
		end
		return drive, iface
	end

	function T.setup(s)
		local fails = {}
		local what = "interface wake"
		local tiles = {}                                         -- (land under the scenes)
		for x = BX - 4, BX + 16 do
			for y = BY - 6, BY + 26 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		local _, a = scene(s, fails, what, BX, BY)
		local db, b = scene(s, fails, what, BX, BY + 16, { "fluid/steam" })
		storage.ifacewake313_scene = { a = a, b = b, db = db }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.ifacewake313
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false }
			storage.ifacewake313 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		local function finish(note)
			st.done = true
			me_report("IFACEWAKE", "ME interface wake (issue #313)", problems, note)
		end
		local sc = storage.ifacewake313_scene or {}
		local a, b = sc.a, sc.b
		if not (a and a.valid and b and b.valid) then
			problems[#problems + 1] = "the scene is missing"
			return finish()
		end
		local function tank(e) return (remote.call(IO, "interface_tanks", e) or {})[SOUTH] end
		local function water(e) return remote.call(NET, "fluid_count", e, "water") end
		local function side(e) return (remote.call(IO, "get_interface", e) or { fluids = {} }).fluids[SOUTH] or {} end
		if not st.filled then
			--- water in both tanks, no event; the window of A says it waits for a visit
			st.filled, st.a0, st.b0 = tick, water(a), water(b)
			for _, e in pairs({ a, b }) do
				local t = tank(e)
				local n = t and t.insert_fluid{ name = "water", amount = AMOUNT } or 0
				expect(n >= AMOUNT - 1e-6, "water into the south tank of an interface: " .. n)
			end
			local sa = side(a)
			expect(sa.status == "waiting", "the window of an interface whose import side holds fluid unvisited says "
				.. tostring(sa.status) .. " (waiting expected)")
			return
		end
		if not st.a_at and water(a) >= st.a0 + AMOUNT - 1e-3 then st.a_at = tick end
		if tick >= ROOM and not st.room then
			st.room = tick
			expect(water(b) <= st.b0 + 1e-3, "network B took water although its cells take steam only")
			expect(side(b).status == "full", "the side of interface B before the room: " .. tostring(side(b).status))
			for slot = 1, 4 do remote.call(NET, "set_partition", sc.db, slot, {}) end
		end
		if st.room and not st.b_at and water(b) >= st.b0 + AMOUNT - 1e-3 then st.b_at = tick end
		if (st.a_at and st.b_at) or tick >= LAST then
			local limit = remote.interfaces[IO].idle_limit and remote.call(IO, "idle_limit") or 300
			expect(st.a_at and st.a_at - st.filled <= 2 * limit + 10, "interface A: the water in its import side "
				.. (st.a_at and ("was imported " .. (st.a_at - st.filled) .. " ticks later") or "was never imported")
				.. " (idle limit " .. limit .. ")")
			expect(st.b_at and st.b_at - st.room <= 2 * limit + 10, "interface B: after the room appeared, its water "
				.. (st.b_at and ("was imported " .. (st.b_at - st.room) .. " ticks later") or "was never imported")
				.. " (idle limit " .. limit .. ")")
			local t = tank(a)
			local f = t and t.fluidbox[1]
			expect(not f or f.amount <= 1e-6, "interface A's tank still holds " .. tostring(f and f.amount))
			return finish("water that appeared in an unconnected interface's tank imported " .. tostring(st.a_at and st.a_at - st.filled)
				.. " ticks later; water a full network had no room for imported " .. tostring(st.b_at and st.b_at - st.room)
				.. " ticks after a partition gave room (no wake for either)")
		end
	end

	function T.running(check) check(storage.ifacewake313 and storage.ifacewake313.done, "ME interface wake (issue #313)") end
	return T
end
