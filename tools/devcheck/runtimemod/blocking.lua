--- Runtime test of me-network issue #335: the blocking mode of the ME Pattern Provider (for the chests next to it). Three
--- providers on one network, each next to a chest with two processing patterns (stone -> A, iron plate -> B), and four
--- crafting CPUs:
---   * blocking: a job of 20 A hands over 16 runs (one batch), then waits ("blocking") while the chest holds anything, also
---     for its own pattern; a job of B waits too; emptied, one of them pushes, then the chest blocks again; emptied again, the
---     other one: the inputs of A and B never lie in the chest together;
---   * smart blocking: a job of 20 A hands over both batches (the pattern pushed last may push again), a job of B waits
---     until the chest is emptied, then the provider remembers B;
---   * off: both jobs fill the chest at once (as before);
--- and the settings: the provider's data, its blueprint settings, a blueprint's tag, a settings paste and a clone carry the
--- mode; the provider window's drop-down index of each mode.
--- Loaded by control.lua: require("blocking")(H) returns { setup, tick, running }.

local AC, GUI = "gregtorio-me-autocraft", "gregtorio-me-gui"
local PT = "gregtorio-me-pattern-terminal"
local BX, BY = 300, -375                -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of parking.lua)
local START, TIMEOUT = 150, 300
--- provider x offset, mode, the outputs of its two patterns
local CASES = {
	{ x = 12.5, mode = "blocking", a = "pipe", b = "iron-stick" },
	{ x = 15.5, mode = "smart", a = "copper-cable", b = "iron-gear-wheel" },
	{ x = 18.5, mode = nil, a = "stone-brick", b = "iron-chest" },
}

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "blocking mode"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { stone = 500, ["iron-plate"] = 500 }, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 10.5, BY - 0.5)
		H.cable_row(s, fails, BX + 11, BX + 22, BY - 1)
		for _, x in ipairs({ 12.5, 14.5, 16.5, 18.5 }) do me_place(s, fails, what, "me-256k-crafting-storage", BX + x, BY - 1.5) end
		for _, c in ipairs(CASES) do
			me_place(s, fails, what, "me-pattern-provider", BX + c.x, BY + 0.5)
			me_place(s, fails, what, "iron-chest", BX + c.x, BY + 1.5)
		end
		me_place(s, fails, what, "me-pattern-provider", BX + 12.5, BY + 8.5)        -- (of no network: the settings checks)
		H.me_connect(fails, what, { ctrl, drive, term })
		return fails
	end

	local function st() return storage.blocking335 end

	--- the chest's count of `name`
	local function count(chest, name) return chest.valid and chest.get_inventory(defines.inventory.chest).get_item_count(name) or -1 end

	local function job(id) return id and remote.call(AC, "job", id) or nil end

	local function report()
		local s = st()
		s.done = true
		for _, id in pairs(s.jobs or {}) do pcall(remote.call, AC, "cancel", id) end
		me_report("BLOCKING", "ME Pattern Provider blocking mode", s.problems,
			"blocking holds the second batch and the other pattern, one kind at a time; smart lets the same pattern through, not the other; off fills both; data, blueprint, tag, paste, clone, window index")
	end

	function T.tick()
		local s = st()
		if game.tick < START or (s and s.done) then return end
		local surface = game.surfaces[1]
		local function find(name, x, y) return surface.find_entity(name, { BX + x, BY + y }) end
		if not s then
			s = { problems = {}, phase = 1, jobs = {} }
			storage.blocking335 = s
			local function expect(ok, text) if not ok then s.problems[#s.problems + 1] = text end end
			local ctrl = find("me-network-controller", 7, 0)
			s.ctrl = ctrl
			for i, c in ipairs(CASES) do
				local p, chest = find("me-pattern-provider", c.x, 0.5), find("iron-chest", c.x, 1.5)
				if not (ctrl and p and chest) then expect(false, "entities missing") return report() end
				for _, d in ipairs({ { "stone", c.a }, { "iron-plate", c.b } }) do
					local tmp = game.create_inventory(2)
					tmp.insert{ name = "me-blank-pattern", count = 1 }
					remote.call(PT, "encode_def", tmp, nil, { kind = "processing", inputs = { { key = d[1], amount = 1 } },
						outputs = { { key = d[2], amount = 1 } } })
					local got = remote.call(AC, "insert_pattern", p, (tmp.find_item_stack("me-encoded-pattern")))
					tmp.destroy()
					expect(got ~= nil, "pattern " .. d[2])
				end
				remote.call(AC, "set_blocking", p, c.mode)
				expect(remote.call(AC, "get_blocking", p) == c.mode, "the mode of case " .. i)
				s["p" .. i], s["c" .. i] = p, chest
			end

			--- the settings
			local p1, p2 = s.p1, s.p2
			local lone = find("me-pattern-provider", 12.5, 8.5)
			expect((remote.call(AC, "provider_info", p1) or {}).blocking == "blocking", "the provider's data")
			expect(remote.call(AC, "provider_settings", p2).blocking == "smart", "the blueprint settings")
			remote.call(AC, "built", lone, { fork_me_provider = { priority = 0, patterns = {}, blocking = "smart" } })
			expect(remote.call(AC, "get_blocking", lone) == "smart", "a blueprint's tag")
			remote.call(AC, "paste", p1, lone)
			expect(remote.call(AC, "get_blocking", lone) == "blocking", "a settings paste")
			remote.call(AC, "built", lone, nil, p2)
			expect(remote.call(AC, "get_blocking", lone) == "smart", "a clone")
			remote.call(AC, "set_blocking", lone, "nonsense")
			expect(remote.call(AC, "get_blocking", lone) == nil, "an unknown mode is off")
			local ok, idx = pcall(remote.call, GUI, "blocking_index", "smart")
			expect(ok and idx == 3 and remote.call(GUI, "blocking_index", nil) == 1, "the window's index: " .. tostring(idx))

			--- phase 1: blocking; a job of 20 A (two batches) and one of B
			local why_a, why_b
			s.jobs.a1, why_a = remote.call(AC, "start", ctrl, CASES[1].a, 20)
			s.jobs.b1, why_b = remote.call(AC, "start", ctrl, CASES[1].b, 1)
			expect(s.jobs.a1 and s.jobs.b1, "the jobs of the blocking provider start: " .. tostring(why_a) .. ", " .. tostring(why_b))
			s.phase_tick = game.tick
			return
		end
		local function expect(ok, text) if not ok then s.problems[#s.problems + 1] = text end end
		local tick = game.tick
		local late = tick > s.phase_tick + TIMEOUT
		if s.phase == 1 then
			--- the first hand-over: stone (16 of A) or iron plate (1 of B), never both; then both wait
			local stone, plate = count(s.c1, "stone"), count(s.c1, "iron-plate")
			if stone > 0 and plate > 0 then expect(false, "blocking: both kinds in the chest (" .. stone .. ", " .. plate .. ")") return report() end
			if stone + plate == 0 then
				if late then expect(false, "blocking: nothing pushed") return report() end
				return
			end
			if tick < s.phase_tick + 120 then return end                 -- (time for the other job to be refused a few times)
			local a, b = job(s.jobs.a1), job(s.jobs.b1)
			expect(stone == 0 or stone == 16, "blocking: one batch of A, not " .. stone)
			local waiter = stone > 0 and b or a
			expect(waiter and waiter.wait == "blocking", "blocking: the other job waits for the chest: " .. serpent.line(waiter and waiter.wait))
			if stone > 0 then
				expect(a and a.steps[1].issued == 16, "blocking: the second batch of A is held: " .. serpent.line(a and a.steps[1]))
			end
			s.first = stone > 0 and "stone" or "plate"
			s.c1.get_inventory(defines.inventory.chest).clear()
			s.phase, s.phase_tick = 2, tick
			return
		end
		if s.phase == 2 then
			--- emptied: the next hand-over (the other kind, or A's second batch), again one kind only
			local stone, plate = count(s.c1, "stone"), count(s.c1, "iron-plate")
			if stone > 0 and plate > 0 then expect(false, "blocking: both kinds after emptying (" .. stone .. ", " .. plate .. ")") return report() end
			if stone + plate == 0 then
				if late then expect(false, "blocking: nothing pushed after emptying") return report() end
				return
			end
			s.c1.get_inventory(defines.inventory.chest).clear()
			s.pushes = (s.pushes or 1) + 1
			local a, b = job(s.jobs.a1), job(s.jobs.b1)
			if a and b and a.steps[1].issued == 20 and b.steps[1].issued == 1 then
				expect(s.pushes == 3, "blocking: three hand-overs (16 A, 4 A, 1 B in some order): " .. s.pushes)
				--- phase 3: smart blocking
				remote.call(AC, "cancel", s.jobs.a1)
				remote.call(AC, "cancel", s.jobs.b1)
				s.jobs.a2 = remote.call(AC, "start", s.ctrl, CASES[2].a, 20)
				expect(s.jobs.a2, "the job of A at the smart provider starts")
				s.phase, s.phase_tick = 3, tick
			elseif late then
				expect(false, "blocking: the jobs did not hand everything over: " .. serpent.line({ a and a.steps[1].issued, b and b.steps[1].issued }))
				return report()
			else
				s.phase_tick = tick
			end
			return
		end
		if s.phase == 3 then
			--- smart: both batches of A go in while the chest holds A's stone
			local stone = count(s.c2, "stone")
			if stone < 20 then
				if late then expect(false, "smart: the second batch of A was held: " .. stone .. " stone") return report() end
				return
			end
			expect(stone == 20, "smart: 20 stone, not " .. stone)
			expect(remote.call(AC, "last_pid", s.p2) ~= nil, "smart: the provider remembers the pattern")
			s.jobs.b2 = remote.call(AC, "start", s.ctrl, CASES[2].b, 1)
			s.pid_a = remote.call(AC, "last_pid", s.p2)
			s.phase, s.phase_tick = 4, tick
			return
		end
		if s.phase == 4 then
			--- smart: B waits while A's stone lies there; emptied, B goes in and is remembered
			if not s.emptied then
				if tick < s.phase_tick + 120 then return end
				local b = job(s.jobs.b2)
				expect(count(s.c2, "iron-plate") == 0 and b and b.wait == "blocking", "smart: B waits: " .. serpent.line(b and b.wait))
				s.c2.get_inventory(defines.inventory.chest).clear()
				s.emptied, s.phase_tick = true, tick
				return
			end
			if count(s.c2, "iron-plate") < 1 then
				if late then expect(false, "smart: B was not pushed after emptying") return report() end
				return
			end
			local now = remote.call(AC, "last_pid", s.p2)
			expect(now ~= nil and now ~= s.pid_a, "smart: the provider remembers B now")
			--- phase 5: off
			remote.call(AC, "cancel", s.jobs.a2)
			remote.call(AC, "cancel", s.jobs.b2)
			s.jobs.a3 = remote.call(AC, "start", s.ctrl, CASES[3].a, 20)
			s.jobs.b3 = remote.call(AC, "start", s.ctrl, CASES[3].b, 1)
			s.phase, s.phase_tick = 5, tick
			return
		end
		if s.phase == 5 then
			--- off: the chest takes both
			local stone, plate = count(s.c3, "stone"), count(s.c3, "iron-plate")
			if stone == 20 and plate == 1 then return report() end
			if late then expect(false, "off: the chest holds " .. stone .. " stone, " .. plate .. " iron plates") return report() end
		end
	end

	function T.running(check) check(storage.blocking335 and storage.blocking335.done, "ME Pattern Provider blocking mode") end

	return T
end
