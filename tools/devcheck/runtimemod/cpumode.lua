--- Runtime test of me-network issue #350: the choice of the crafting CPU and the CPU modes (AE2-Unofficial's
--- CraftingAllow). Two Crafting CPUs A and B (one 256k crafting storage each, not touching) and a processing pattern
--- stone -> pipe in a provider with a chest; each step starts a job, notes its CPU (or why it did not start), cancels it
--- and waits until both CPUs are free again:
---   * every request: a player's job takes A (the first);
---   * A automation only: a player's job takes B; both automation only: a player's job does not start ("cpu-not-allowed",
---     the terminal's preview says so), a job of automation (an owner) takes A;
---   * A players only: a job of automation takes B, a player's A;
---   * the CPU chosen in the terminal: a job asked for B takes B though A fits; a chosen CPU that is none ("cpu-gone");
---     automation asking for a players-only CPU ("cpu-not-allowed");
---   * the window data carries the mode, an unknown mode is every request.
--- Loaded by control.lua: require("cpumode")(H) returns { setup, tick, running }.

local AC, PT, TERM = "gregtorio-me-autocraft", "gregtorio-me-pattern-terminal", "gregtorio-me-terminal"
local BX, BY = -200, -380               -- (inside the cleared test area, TEST_RADIUS of control.lua)
local START, TIMEOUT = 160, 600
local MAINT = 123456                    -- (any unit number stands for a request of automation)

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "CPU choice and modes"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { stone = 500 }, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 10.5, BY - 0.5)
		H.cable_row(s, fails, BX + 11, BX + 18, BY - 1)
		for _, x in ipairs({ 12.5, 15.5 }) do me_place(s, fails, what, "me-256k-crafting-storage", BX + x, BY - 1.5) end
		me_place(s, fails, what, "me-pattern-provider", BX + 13.5, BY + 0.5)
		me_place(s, fails, what, "iron-chest", BX + 13.5, BY + 1.5)
		H.me_connect(fails, what, { ctrl, drive, term })
		return fails
	end

	local function report()
		local s = storage.cpumode350
		s.done = true
		me_report("CPUMODE", "ME crafting CPU choice and modes", s.problems,
			"automation only skips players, players only skips automation, a chosen CPU, cpu-not-allowed, cpu-gone, window data")
	end

	--- the steps: { modes of A and B before it, owner, want ("A"/"B"/number), the CPU expected ("A"/"B") or the reason }
	local STEPS = {
		{ nil, nil, nil, nil, "A", "every request: a player's job" },
		{ "automation", nil, nil, nil, "B", "A automation only: a player's job" },
		{ "automation", "automation", nil, nil, "cpu-not-allowed", "both automation only: a player's job" },
		{ "automation", "automation", MAINT, nil, "A", "both automation only: a job of automation" },
		{ "player", "all", MAINT, nil, "B", "A players only: a job of automation" },
		{ "player", "all", nil, nil, "A", "A players only: a player's job" },
		{ "all", "all", nil, "B", "B", "the chosen CPU B though A fits" },
		{ "all", "all", nil, 999999, "cpu-gone", "a chosen CPU that is none" },
		{ "player", "all", MAINT, "A", "cpu-not-allowed", "automation asking for a players-only CPU" },
	}

	function T.tick()
		local s = storage.cpumode350
		if game.tick < START or (s and s.done) then return end
		local surface = game.surfaces[1]
		local function find(name, x, y) return surface.find_entity(name, { BX + x, BY + y }) end
		if not s then
			s = { problems = {}, step = 1 }
			storage.cpumode350 = s
			s.term, s.p = find("me-terminal", 10.5, -0.5), find("me-pattern-provider", 13.5, 0.5)
			s.a, s.b = find("me-256k-crafting-storage", 12.5, -1.5), find("me-256k-crafting-storage", 15.5, -1.5)
			if not (s.term and s.p and s.a and s.b) then s.problems[1] = "entities missing" return report() end
			local tmp = game.create_inventory(2)
			tmp.insert{ name = "me-blank-pattern", count = 1 }
			remote.call(PT, "encode_def", tmp, nil, { kind = "processing", inputs = { { key = "stone", amount = 1 } },
				outputs = { { key = "pipe", amount = 1 } } })
			if remote.call(AC, "insert_pattern", s.p, (tmp.find_item_stack("me-encoded-pattern"))) == nil then
				s.problems[#s.problems + 1] = "the pattern"
			end
			tmp.destroy()
			local ga, gb = remote.call(AC, "group_info", s.a), remote.call(AC, "group_info", s.b)
			if not (ga and gb and ga.status == "ok" and gb.status == "ok" and ga.id ~= gb.id) then
				s.problems[#s.problems + 1] = "two CPUs: " .. serpent.line({ ga and ga.status, gb and gb.status })
				return report()
			end
			s.ids = { A = ga.id, B = gb.id }
			s.since = game.tick
			return
		end
		local function expect(ok, text) if not ok then s.problems[#s.problems + 1] = text end end
		--- wait until both CPUs are free (a cancelled job gives its CPU back when it has closed)
		local ga, gb = remote.call(AC, "group_info", s.a), remote.call(AC, "group_info", s.b)
		if (ga and ga.job) or (gb and gb.job) then
			if game.tick > s.since + TIMEOUT then expect(false, "a cancelled job kept its CPU") return report() end
			return
		end
		local step = STEPS[s.step]
		if not step then
			expect(ga.mode == nil and gb.mode == nil or ga.mode == "player", "the window data: " .. serpent.line({ ga.mode, gb.mode }))
			remote.call(AC, "set_cpu_mode", s.a, "nonsense")
			expect(remote.call(AC, "group_info", s.a).mode == nil, "an unknown mode is every request")
			return report()
		end
		remote.call(AC, "set_cpu_mode", s.a, step[1])
		remote.call(AC, "set_cpu_mode", s.b, step[2])
		if step[1] == "automation" then
			expect(remote.call(AC, "group_info", s.a).mode == "automation", "the window data has the mode")
		end
		local want = type(step[4]) == "string" and s.ids[step[4]] or step[4]
		local id, why = remote.call(AC, "start", s.term, "pipe", 4, step[3], want)
		local got = why
		if id then
			local j = remote.call(AC, "job", id)
			got = j and (j.group == s.ids.A and "A" or j.group == s.ids.B and "B" or tostring(j.group))
			remote.call(AC, "cancel", id)
		end
		expect(got == step[5], step[6] .. ": " .. tostring(got) .. ", not " .. step[5])
		if step[5] == "cpu-not-allowed" and not step[3] then
			local pv = remote.call(TERM, "craft_preview", s.term, "pipe", 4)
			expect(pv and not pv.ok and pv.reason == "cpu-not-allowed", "the preview: " .. serpent.line(pv and pv.reason))
		end
		s.step, s.since = s.step + 1, game.tick
	end

	function T.running(check) check(storage.cpumode350 and storage.cpumode350.done, "ME crafting CPU choice and modes") end

	return T
end
