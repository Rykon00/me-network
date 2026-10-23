--- Runtime test of me-network issue #443: the ME Advanced Level Emitter (AE2-Unofficial's PartAdvancedLevelEmitter: six rows
--- joined by OR or AND). A network with 100 iron plates, 50 copper plates and 1000 water, an advanced emitter A and a level
--- emitter L next to it (both visited by the emitters' step and budget):
---   * no row: off; one active row "iron >= 50": on; its threshold 150: off; inverted (iron < 150): on;
---   * OR of "iron >= 150" and "copper >= 20": on; AND of the same: off; AND with iron's row at 80: on; a row made inactive no
---     longer counts (AND of the copper row alone); a fluid row (water >= 900) counts like an item row;
---   * the step changes the output without a visit of the test: 60 iron plates taken out (40 left) switch the AND off within
---     the step's interval; the window's data has each row's level;
---   * the output signal is the chosen one (signal-B); a network that does not work: off;
---   * the settings: blueprint tag, settings paste and clone keep the rows, the logic and the signal; a paste from a level
---     emitter onto it changes nothing.
--- Loaded by control.lua: require("advemitter")(H) returns { setup, tick, running }.

local NET, EM = "gregtorio-me-network", "gregtorio-me-emitter"
local BX, BY = -150, 370              -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, TIMEOUT = 170, 120
local ADV = "me-advanced-level-emitter"
local SIG = { type = "virtual", name = "signal-B" }

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "advanced level emitter"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 100, ["copper-plate"] = 50 }, "16k")
		local fdrive = H.me_drive(s, fails, what, BX + 8.5, BY + 0.5, {}, "1k", true)
		H.cable_row(s, fails, BX + 9, BX + 14, BY - 1)
		me_place(s, fails, what, ADV, BX + 12.5, BY - 1.5)
		me_place(s, fails, what, "me-level-emitter", BX + 13.5, BY - 1.5)
		me_place(s, fails, what, ADV, BX + 12.5, BY + 6.5)                          -- (of no network: the settings checks)
		H.me_connect(fails, what, { ctrl, drive, fdrive })
		return fails
	end

	local function report()
		local st = storage.advemitter443
		st.done = true
		me_report("ADVEMITTER", "ME Advanced Level Emitter", st.problems,
			"rows on, off, inverted, inactive; OR and AND; a fluid row; the step without a visit; signal; no network; blueprint, paste, clone")
	end

	function T.tick()
		local st = storage.advemitter443
		if game.tick < START or (st and st.done) then return end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local function expect(ok, text) if not ok then st.problems[#st.problems + 1] = text end end
		local function set(e, t) return remote.call(EM, "set", e, t) end
		local function get(e) return remote.call(EM, "get", e) or {} end
		local function visit(e) remote.call(EM, "visit", e) end
		--- the signal the combinator gives: its first section's first filter, or nil
		local function out(e)
			local cb = e.get_control_behavior()
			local sec = cb and cb.sections_count > 0 and cb.get_section(1)
			local f = sec and sec.filters and sec.filters[1]
			return f and f.value and f.value.name or nil
		end
		if not st then
			st = { problems = {} }
			storage.advemitter443 = st
			st.ctrl, st.a, st.l, st.lone = find("me-network-controller", 7, 0), find(ADV, 12.5, -1.5), find("me-level-emitter", 13.5, -1.5),
				find(ADV, 12.5, 6.5)
			if not (st.ctrl and st.a and st.l and st.lone) then expect(false, "entities missing") return report() end
			local a = st.a
			remote.call(NET, "insert_fluid", st.ctrl, "water", 1000)
			visit(a)
			expect(get(a).on == false and out(a) == nil, "no row: off")
			expect(set(a, { row = 1, key = "iron-plate", amount = 50 }), "a row is set")
			expect(get(a).on == true and out(a) == "signal-check", "iron >= 50: on: " .. serpent.line({ get(a).on, out(a) }))
			expect(get(a).rows[1].active == true and get(a).rows[1].level == 100, "a row with a resource is active, its level read: "
				.. serpent.line(get(a).rows[1]))
			set(a, { row = 1, amount = 150 })
			expect(get(a).on == false, "iron >= 150: off")
			set(a, { row = 1, inverted = true })
			expect(get(a).on == true, "inverted: iron < 150: on")
			set(a, { row = 1, inverted = false })
			set(a, { row = 2, key = "copper-plate", amount = 20 })
			expect(get(a).logic == "or" and get(a).on == true, "OR (the default) of iron >= 150 and copper >= 20: on")
			set(a, { logic = "and" })
			expect(get(a).on == false, "AND of the same: off")
			set(a, { row = 1, amount = 80 })
			expect(get(a).on == true, "AND with iron >= 80: on")
			set(a, { row = 1, active = false, amount = 1000 })
			expect(get(a).on == true, "an inactive row does not count (AND of copper alone): on")
			set(a, { row = 1, active = true, amount = 80 })
			set(a, { row = 4, key = "fluid/water", amount = 900 })
			expect(get(a).on == true and get(a).rows[4].level == 1000, "a fluid row: water >= 900: on: " .. serpent.line(get(a).rows[4]))
			set(a, { row = 4, amount = 1100 })
			expect(get(a).on == false, "water >= 1100: off")
			set(a, { row = 4, key = false })
			expect(get(a).on == true and get(a).rows[4].key == nil, "a cleared row does not count")
			set(a, { signal = SIG })
			expect(out(a) == "signal-B", "the chosen signal: " .. tostring(out(a)))
			--- the settings
			remote.call(EM, "built", st.lone, { fork_me_emitter = { rows = { { key = "copper-plate", amount = 7, active = true, inverted = true } },
				logic = "and", signal = SIG } })
			local d = get(st.lone)
			expect(d.logic == "and" and d.rows[1] and d.rows[1].key == "copper-plate" and d.rows[1].amount == 7 and d.rows[1].inverted == true
				and d.signal.name == "signal-B", "a blueprint's tag: " .. serpent.line(d))
			set(st.lone, { rows = {}, logic = "or", signal = false })
			remote.call(EM, "paste", a, st.lone)
			d = get(st.lone)
			expect(d.logic == "and" and d.rows[1].amount == 80 and d.rows[2].key == "copper-plate" and d.signal.name == "signal-B",
				"a settings paste: " .. serpent.line(d))
			set(st.lone, { rows = {}, logic = "or" })
			remote.call(EM, "built", st.lone, nil, a)
			d = get(st.lone)
			expect(d.logic == "and" and d.rows[2] and d.rows[2].key == "copper-plate", "a clone: " .. serpent.line(d))
			set(st.l, { key = "iron-plate", amount = 1 })
			remote.call(EM, "paste", st.l, st.lone)
			expect(get(st.lone).logic == "and" and get(st.lone).rows[2], "a level emitter's paste changes nothing")
			--- the step: 60 plates out (40 left), the AND of iron >= 80 goes off without a visit of the test
			expect(get(a).on == true, "on before the step check")
			remote.call(NET, "extract", st.ctrl, "iron-plate", 60)
			st.phase, st.tick = "step", game.tick
			return
		end
		if st.phase == "step" then
			if get(st.a).on then
				if game.tick > st.tick + TIMEOUT then expect(false, "the step did not switch the emitter off") return report() end
				return
			end
			expect(get(st.a).rows[1].level == 40, "the step read iron's level: " .. serpent.line(get(st.a).rows[1]))
			--- no working network: off
			st.ctrl.destroy{ raise_destroy = true }
			visit(st.a)
			expect(get(st.a).on == false and out(st.a) == nil, "no network: off")
			return report()
		end
	end

	function T.running(check) check(storage.advemitter443 and storage.advemitter443.done, "advanced level emitter") end

	return T
end
