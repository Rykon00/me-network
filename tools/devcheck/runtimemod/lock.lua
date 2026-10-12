--- Runtime test of me-network issue #346: the pattern provider's lock until the result is back (for the chests next to it). A
--- provider with the lock and blocking off, next to a chest with a processing pattern stone -> pipe, and two crafting CPUs:
---   * a job of 20 pipes hands over 16 runs (one batch); the chest has room, but the rest waits ("locked") while the provider
---     waits for 16 pipes;
---   * 10 pipes come into the network (they are the job's outputs: it takes them, and the lock counts them): 6 still to come,
---     the chest gets nothing; 6 more: the lock is released, the last 4 runs go in, and the provider waits for 4;
---   * Unlock releases it at once; the job ends when those 4 come back;
--- and the settings: the provider's data, its blueprint settings, a blueprint's tag, a settings paste and a clone carry the
--- lock, switching it off releases a lock in effect, the window's line of a locked provider.
--- Loaded by control.lua: require("lock")(H) returns { setup, tick, running }.

local AC, NET, GUI = "gregtorio-me-autocraft", "gregtorio-me-network", "gregtorio-me-gui"
local PT = "gregtorio-me-pattern-terminal"
local BX, BY = 340, -375                -- (inside the cleared test area, clear of parking.lua and blocking.lua)
local START, TIMEOUT = 150, 300

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "provider lock"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { stone = 500 }, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 10.5, BY - 0.5)
		H.cable_row(s, fails, BX + 11, BX + 18, BY - 1)
		for _, x in ipairs({ 12.5, 14.5 }) do me_place(s, fails, what, "me-256k-crafting-storage", BX + x, BY - 1.5) end
		me_place(s, fails, what, "me-pattern-provider", BX + 13.5, BY + 0.5)
		me_place(s, fails, what, "iron-chest", BX + 13.5, BY + 1.5)
		me_place(s, fails, what, "me-pattern-provider", BX + 13.5, BY + 8.5)        -- (of no network: the settings checks)
		H.me_connect(fails, what, { ctrl, drive, term })
		return fails
	end

	local function report()
		local s = storage.lock346
		s.done = true
		if s.job then pcall(remote.call, AC, "cancel", s.job) end
		me_report("LOCK", "ME Pattern Provider lock until the result is back", s.problems,
			"one batch, then locked with room in the chest; counted down by arrivals; released, the rest goes in; Unlock; data, blueprint, tag, paste, clone, off releases, window line")
	end

	function T.tick()
		local s = storage.lock346
		if game.tick < START or (s and s.done) then return end
		local surface = game.surfaces[1]
		local function find(name, x, y) return surface.find_entity(name, { BX + x, BY + y }) end
		local function expect(ok, text) if not ok then s.problems[#s.problems + 1] = text end end
		local function stone() return s.chest.valid and s.chest.get_inventory(defines.inventory.chest).get_item_count("stone") or -1 end
		local function locked() return remote.call(AC, "locked", s.p) end
		local function job() return remote.call(AC, "job", s.job) end
		if not s then
			s = { problems = {} }
			storage.lock346 = s
			s.ctrl, s.p, s.chest = find("me-network-controller", 7, 0), find("me-pattern-provider", 13.5, 0.5), find("iron-chest", 13.5, 1.5)
			local lone = find("me-pattern-provider", 13.5, 8.5)
			if not (s.ctrl and s.p and s.chest and lone) then expect(false, "entities missing") return report() end
			local tmp = game.create_inventory(2)
			tmp.insert{ name = "me-blank-pattern", count = 1 }
			remote.call(PT, "encode_def", tmp, nil, { kind = "processing", inputs = { { key = "stone", amount = 1 } },
				outputs = { { key = "pipe", amount = 1 } } })
			expect(remote.call(AC, "insert_pattern", s.p, (tmp.find_item_stack("me-encoded-pattern"))) ~= nil, "the pattern")
			tmp.destroy()
			remote.call(AC, "set_lock", s.p, "result")

			--- the settings
			expect(remote.call(AC, "get_lock", s.p) == "result" and (remote.call(AC, "provider_info", s.p) or {}).lock == "result", "the lock is set")
			expect(remote.call(AC, "provider_settings", s.p).lock == "result", "the blueprint settings")
			remote.call(AC, "built", lone, { fork_me_provider = { priority = 0, patterns = {}, lock = "result" } })
			expect(remote.call(AC, "get_lock", lone) == "result", "a blueprint's tag")
			remote.call(AC, "set_lock", lone, nil)
			remote.call(AC, "paste", s.p, lone)
			expect(remote.call(AC, "get_lock", lone) == "result", "a settings paste")
			remote.call(AC, "set_lock", lone, nil)
			remote.call(AC, "built", lone, nil, s.p)
			expect(remote.call(AC, "get_lock", lone) == "result", "a clone")
			remote.call(AC, "set_lock", lone, "nonsense")
			expect(remote.call(AC, "get_lock", lone) == nil, "an unknown lock is off")
			local text = remote.call(GUI, "locked_text", { pipe = 16 })
			expect(type(text) == "table" and text[1] == "fork-me-gui.provider-locked" and text[2] == "16 [item=pipe]",
				"the window's line: " .. serpent.line(text))

			local why
			s.job, why = remote.call(AC, "start", s.ctrl, "pipe", 20)
			expect(s.job ~= nil, "the job starts: " .. tostring(why))
			if not s.job then return report() end
			s.phase, s.phase_tick = 1, game.tick
			return
		end
		local tick = game.tick
		local late = tick > s.phase_tick + TIMEOUT
		if s.phase == 1 then
			--- one batch, then locked although the chest has room
			if stone() < 16 then
				if late then expect(false, "no hand-over: " .. stone()) return report() end
				return
			end
			if tick < s.phase_tick + 120 then return end
			local j = job()
			expect(stone() == 16, "locked: only one batch in the chest, not " .. stone())
			expect(j and j.wait == "locked", "the job waits for the lock: " .. serpent.line(j and j.wait))
			expect(serpent.line(locked()) == serpent.line({ pipe = 16 }), "it waits for 16 pipes: " .. serpent.line(locked()))
			remote.call(NET, "insert", s.ctrl, "pipe", 10)
			expect(serpent.line(locked()) == serpent.line({ pipe = 6 }), "10 came: 6 to come: " .. serpent.line(locked()))
			s.phase, s.phase_tick = 2, tick
			return
		end
		if s.phase == 2 then
			if tick < s.phase_tick + 60 then return end
			expect(stone() == 16, "still locked after 10 of 16: " .. stone())
			remote.call(NET, "insert", s.ctrl, "pipe", 6)
			expect(locked() == nil, "released: " .. serpent.line(locked()))
			s.phase, s.phase_tick = 3, tick
			return
		end
		if s.phase == 3 then
			--- the rest goes in, locked again for 4
			if stone() < 20 then
				if late then expect(false, "after the release nothing went in: " .. stone()) return report() end
				return
			end
			expect(serpent.line(locked()) == serpent.line({ pipe = 4 }), "locked again for 4: " .. serpent.line(locked()))
			expect(remote.call(AC, "locked_units") ~= nil, "the provider is listed as locked")
			remote.call(AC, "unlock", s.p)
			expect(locked() == nil and remote.call(AC, "locked_units") == nil, "Unlock releases it")
			--- a lock in effect is released by switching the lock off
			remote.call(AC, "set_lock", s.p, nil)
			remote.call(AC, "set_lock", s.p, "result")
			remote.call(NET, "insert", s.ctrl, "pipe", 4)                   -- (the job's last outputs: it ends)
			s.phase, s.phase_tick = 4, tick
			return
		end
		if s.phase == 4 then
			local j = job()
			if j and j.status ~= "done" then
				if late then expect(false, "the job did not end: " .. serpent.line(j and { j.status, j.wait, j.done, j.total })) return report() end
				return
			end
			expect(locked() == nil, "no lock left: " .. serpent.line(locked()))
			s.job = nil
			return report()
		end
	end

	function T.running(check) check(storage.lock346 and storage.lock346.done, "ME Pattern Provider lock") end

	return T
end
