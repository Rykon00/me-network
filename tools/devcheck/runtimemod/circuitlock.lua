--- Runtime test of me-network issue #429: the pattern provider's lock by its circuit connector (AE2-Unofficial's Lock Crafting
--- Card modes, by the connector of #412). A provider in blocking mode (one batch at a time in its chest) with a processing
--- pattern stone -> pipe, a job of 200 pipes, and a constant combinator K (signal A) wired to the provider's connector with the
--- condition A > 0. The chest is emptied by the test where a machine would take the batch:
---   * "high": with K off a batch goes in; K on locks it (the job waits "locked", the window's data says locked); K off again,
---     the next batch goes in;
---   * "low": with K off it is locked; K on, the next batch goes in;
---   * "pulse": one batch goes in, then it is locked; K off and on again (a rise), the next batch goes in;
--- and the settings: the provider's data, its blueprint settings, a blueprint's tag, a settings paste and a clone carry the
--- mode, an unknown mode is off, and the provider gets its connector.
--- Loaded by control.lua: require("circuitlock")(H) returns { setup, tick, running }.

local AC, NET, CONN = "gregtorio-me-autocraft", "gregtorio-me-network", "gregtorio-me-connector"
local PT = "gregtorio-me-pattern-terminal"
local BX, BY = -150, 330              -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, TIMEOUT = 150, 200
local SIG = { type = "virtual", name = "signal-A" }
local HOLD = 50                       -- ticks: the game's circuit update and the connector's check (every 10 ticks) saw K

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "provider circuit lock"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { stone = 500 }, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 10.5, BY - 0.5)
		H.cable_row(s, fails, BX + 11, BX + 18, BY - 1)
		for _, x in ipairs({ 12.5, 14.5 }) do me_place(s, fails, what, "me-256k-crafting-storage", BX + x, BY - 1.5) end
		me_place(s, fails, what, "me-pattern-provider", BX + 13.5, BY + 0.5)
		me_place(s, fails, what, "iron-chest", BX + 13.5, BY + 1.5)
		me_place(s, fails, what, "constant-combinator", BX + 15.5, BY + 1.5)
		me_place(s, fails, what, "me-pattern-provider", BX + 13.5, BY + 8.5)        -- (of no network: the settings checks)
		H.me_connect(fails, what, { ctrl, drive, term })
		return fails
	end

	local function report()
		local s = storage.circuitlock429
		s.done = true
		if s.job then pcall(remote.call, AC, "cancel", s.job) end
		me_report("CIRCUITLOCK", "ME Pattern Provider lock by the circuit condition", s.problems,
			"high, low and pulse lock and release by the condition; data, blueprint, tag, paste, clone, unknown mode off, connector")
	end

	function T.tick()
		local s = storage.circuitlock429
		if game.tick < START or (s and s.done) then return end
		local surface = game.surfaces[1]
		local function find(name, x, y) return surface.find_entity(name, { BX + x, BY + y }) end
		local function expect(ok, text) if not ok then s.problems[#s.problems + 1] = text end end
		local function stone() return s.chest.valid and s.chest.get_inventory(defines.inventory.chest).get_item_count("stone") or -1 end
		local function empty() s.chest.get_inventory(defines.inventory.chest).clear() end
		local function job() return remote.call(AC, "job", s.job) end
		local function info() return remote.call(AC, "provider_info", s.p) or {} end
		local function emit(on) s.k.get_or_create_control_behavior().enabled = on end
		local function next_phase(phase) s.phase, s.phase_tick = phase, game.tick end
		if not s then
			s = { problems = {} }
			storage.circuitlock429 = s
			s.ctrl, s.p, s.chest = find("me-network-controller", 7, 0), find("me-pattern-provider", 13.5, 0.5), find("iron-chest", 13.5, 1.5)
			s.k = find("constant-combinator", 15.5, 1.5)
			local lone = find("me-pattern-provider", 13.5, 8.5)
			if not (s.ctrl and s.p and s.chest and s.k and lone) then expect(false, "entities missing") return report() end
			local tmp = game.create_inventory(2)
			tmp.insert{ name = "me-blank-pattern", count = 1 }
			remote.call(PT, "encode_def", tmp, nil, { kind = "processing", inputs = { { key = "stone", amount = 1 } },
				outputs = { { key = "pipe", amount = 1 } } })
			expect(remote.call(AC, "insert_pattern", s.p, (tmp.find_item_stack("me-encoded-pattern"))) ~= nil, "the pattern")
			tmp.destroy()
			remote.call(AC, "set_blocking", s.p, "blocking")
			remote.call(AC, "set_lock", s.p, "high")

			--- the connector: K's signal A on a red wire, the condition A > 0
			local cn = remote.call(CONN, "connector", s.p)
			expect(cn and cn.valid and cn.position.x == s.p.position.x and cn.position.y == s.p.position.y, "the provider has its connector")
			local cb = s.k.get_or_create_control_behavior()
			if cb.sections_count == 0 then cb.add_section() end
			cb.get_section(1).set_slot(1, { value = { type = SIG.type, name = SIG.name, quality = "normal" }, min = 1 })
			cb.enabled = false
			if cn then
				local w = defines.wire_connector_id.circuit_red
				cn.get_wire_connector(w, true).connect_to(s.k.get_wire_connector(w, true), false)
				local ccb = cn.get_or_create_control_behavior()
				ccb.circuit_enable_disable = true
				ccb.circuit_condition = { first_signal = SIG, comparator = ">", constant = 0 }
				remote.call(CONN, "update", s.p)
			end

			--- the settings
			expect(remote.call(AC, "get_lock", s.p) == "high" and info().lock == "high", "the lock mode is set")
			expect(remote.call(AC, "provider_settings", s.p).lock == "high", "the blueprint settings")
			remote.call(AC, "built", lone, { fork_me_provider = { priority = 0, patterns = {}, lock = "pulse" } })
			expect(remote.call(AC, "get_lock", lone) == "pulse", "a blueprint's tag")
			remote.call(AC, "set_lock", lone, nil)
			remote.call(AC, "paste", s.p, lone)
			expect(remote.call(AC, "get_lock", lone) == "high", "a settings paste")
			remote.call(AC, "set_lock", lone, "low")
			remote.call(AC, "built", lone, nil, s.p)
			expect(remote.call(AC, "get_lock", lone) == "high", "a clone")
			remote.call(AC, "set_lock", lone, "nonsense")
			expect(remote.call(AC, "get_lock", lone) == nil, "an unknown lock is off")

			local why
			s.job, why = remote.call(AC, "start", s.ctrl, "pipe", 200)
			expect(s.job ~= nil, "the job starts: " .. tostring(why))
			if not s.job then return report() end
			next_phase("high-open")
			return
		end
		local tick = game.tick
		local late = tick > s.phase_tick + TIMEOUT
		local function batch_in(msg)
			if stone() > 0 then return true end
			if late then expect(false, msg .. ": " .. serpent.line(job() and job().wait)) report() end
			return false
		end

		--- "high": K off, a batch goes in; K on locks
		if s.phase == "high-open" then
			if not batch_in("high, K off: no hand-over") then return end
			emit(true)
			next_phase("high-arm")
			return
		end
		if s.phase == "high-arm" then
			if tick < s.phase_tick + HOLD then return end
			empty()
			next_phase("high-locked")
			return
		end
		if s.phase == "high-locked" then
			if tick < s.phase_tick + 60 then return end
			local j = job()
			expect(stone() == 0, "high, K on: locked, but " .. stone() .. " stone went in")
			expect(j and j.wait == "locked", "high: the job waits for the lock: " .. serpent.line(j and j.wait))
			expect(info().clocked == true, "high: the window's data says locked: " .. serpent.line(info().clocked))
			emit(false)
			next_phase("high-release")
			return
		end
		if s.phase == "high-release" then
			if not batch_in("high, K off again: nothing went in") then return end
			expect(not info().clocked, "high, K off: not locked any more")
			--- "low": K is off: locked
			remote.call(AC, "set_lock", s.p, "low")
			empty()
			next_phase("low-locked")
			return
		end
		if s.phase == "low-locked" then
			if tick < s.phase_tick + 60 then return end
			expect(stone() == 0, "low, K off: locked, but " .. stone() .. " stone went in")
			expect(info().clocked == true, "low: the window's data says locked")
			emit(true)
			next_phase("low-release")
			return
		end
		if s.phase == "low-release" then
			if not batch_in("low, K on: nothing went in") then return end
			--- "pulse": K is on (no rise): one batch, then locked
			remote.call(AC, "set_lock", s.p, "pulse")
			empty()
			next_phase("pulse-first")
			return
		end
		if s.phase == "pulse-first" then
			if not batch_in("pulse: the first batch did not go in") then return end
			empty()
			next_phase("pulse-locked")
			return
		end
		if s.phase == "pulse-locked" then
			if tick < s.phase_tick + 60 then return end
			expect(stone() == 0, "pulse: locked after a hand-over, but " .. stone() .. " stone went in")
			expect(info().clocked == true, "pulse: the window's data says locked")
			emit(false)
			next_phase("pulse-low")
			return
		end
		if s.phase == "pulse-low" then
			if tick < s.phase_tick + HOLD then return end
			expect(stone() == 0, "pulse: K off is no rise, but " .. stone() .. " stone went in")
			emit(true)
			next_phase("pulse-rise")
			return
		end
		if s.phase == "pulse-rise" then
			if not batch_in("pulse: the rise did not release the lock") then return end
			return report()
		end
	end

	function T.running(check) check(storage.circuitlock429 and storage.circuitlock429.done, "provider circuit lock") end

	return T
end
