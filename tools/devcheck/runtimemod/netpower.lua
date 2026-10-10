--- Runtime test of me-network issue #128 (docs/AE2.md "Building a network"): the ME Terminal and the ME Level Maintainer take their
--- power from the network, not from a pole.
--- One network at a power source with a substation; the terminal and the level maintainer sit 24 tiles away at the end of a cable
--- row, far outside every pole's supply area (their lamps have a void energy source: no electric network of their own).
--- * they join: the controller's draw rises by exactly 8 kW (terminal) and 30 kW (level maintainer) (issue #145: the legacy
---   Crafting CPU of this check is gone)
--- * they work with no pole: the terminal has no problem, its screen is lit (a sprite render object of the mod's, under the
---   character: layer lower-object, and its light), the maintainer is stocked
--- * the controller's power is cut (at tick 300, so that the dark network is still dark after the save and load of the
---   save-and-load run at tick 500): the terminal says "no-power", its screen goes dark and its light off, the maintainer says
---   "no-power" and is parked for it
--- * the power comes back (tick 600): the screen is lit again, the maintainer is woken and checks again within the slow step's second
--- * a terminal that is mined or destroyed takes its screen along (no render object left), a cloned one gets its own
--- * issue #254: the level maintainer's picture is a screen of the same kind (no light): lit in the working network, dark
---   without power and lit again with it, dark for one with no cable to a network, dark while its circuit condition is
---   false and lit again when the condition is switched off
--- Loaded by control.lua: require("netpower")(H) returns { setup, tick, running } like lab.lua.

local NET, TERM, CIRC, IO = "gregtorio-me-network", "gregtorio-me-terminal", "gregtorio-me-circuit", "gregtorio-me-io"
local BX, BY = -300, -200
local START, CUT, DARK_CHECK, BACK, END = 90, 300, 580, 600, 1100
local TERMINAL_X, MAINTAINER_X = 26, 27            -- tiles right of BX, on the cable row's row (BY - 1)

return function(H)
	local me_place, me_report, power, cable_row = H.me_place, H.me_report, H.power, H.cable_row
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "network power"
		local eei = power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 6, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 100 })
		cable_row(s, fails, BX + 7, BX + 7, BY - 1)             -- (the drive's tile is BX + 8)
		cable_row(s, fails, BX + 9, BX + 25, BY - 1)
		if not (eei and ctrl and drive) then fails[#fails + 1] = what .. ": the network was not built" end
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.netpower128
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false, phase = "join" }
			storage.netpower128 = st
		end
		if st.done then return end
		local s = game.surfaces[1]
		local problems = st.problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		local function finish(note)
			st.done = true
			me_report("NETPOWER", "ME terminal and level maintainer power", problems, note)
		end
		local ctrl = s.find_entity("me-network-controller", { BX + 6, BY })
		local eei = s.find_entity("electric-energy-interface", { BX, BY })
		if not (ctrl and ctrl.valid and eei and eei.valid) then
			problems[#problems + 1] = "the test network is missing"
			return finish()
		end
		local function info() return remote.call(NET, "network", ctrl) end
		local terminal = st.terminal and st.terminal.valid and st.terminal
		local maintainer = st.maintainer and st.maintainer.valid and st.maintainer
		local function maint() return maintainer and remote.call(CIRC, "get_maintainer", maintainer) end

		if st.phase == "join" then
			local n0 = info()
			expect(n0 and n0.ok and n0.power == 124000, "the network before: " .. serpent.line(n0))
			local function place(name, x, extra)
				local def = { name = name, position = { BX + x + 0.5, BY - 0.5 }, force = "player", raise_built = true }
				for k, v in pairs(extra or {}) do def[k] = v end
				return s.create_entity(def)
			end
			st.terminal = place("me-terminal", TERMINAL_X)
			local n1 = info()
			expect(n1 and n1.power == n0.power + 8000, "the controller draws " .. tostring(n1 and n1.power) .. " W with a terminal, "
				.. (n0.power + 8000) .. " expected (terminal 8 kW)")
			st.maintainer = place("me-level-maintainer", MAINTAINER_X)
			local n2 = info()
			expect(n2 and n2.power == n0.power + 38000, "the controller draws " .. tostring(n2 and n2.power) .. " W with a level maintainer too, "
				.. (n0.power + 38000) .. " expected (maintainer 30 kW)")
			--- issue #149: the breakdown by kind adds up to the total, biggest first, with the controller's base as a row
			local rows = n2 and n2.power_rows or {}
			local sum, want, sorted = 0, { controller = 120000, maintainer = 30000, terminal = 8000, drive = 4000 }, true
			for i, row in ipairs(rows) do
				sum = sum + row.w
				if i > 1 and rows[i - 1].w < row.w then sorted = false end
				expect(want[row.key] == row.w and row.per * row.n == row.w, "power row " .. serpent.line(row))
				want[row.key] = nil
			end
			expect(sum == n2.power and sorted and next(want) == nil and #rows == 4, "power breakdown " .. serpent.line(rows) .. " for "
				.. tostring(n2.power) .. " W")
			local text = remote.call("gregtorio-me-gui", "controller_power_text", ctrl)
			expect(type(text) == "table" and text[1] == "" and #text >= 3, "the power text " .. serpent.line(text))
			--- no pole reaches them
			for _, e in pairs({ st.terminal, st.maintainer }) do
				local poles = s.find_entities_filtered{ type = "electric-pole", position = e.position, radius = 14 }
				expect(#poles == 0, e.name .. " has an electric pole within 14 tiles")
			end
			remote.call(CIRC, "set_maintainer", st.maintainer, "iron-plate", 10, false)
			st.phase = "work"
			return
		end
		if not (terminal and maintainer) then
			problems[#problems + 1] = "the terminal or the level maintainer is gone in phase " .. st.phase
			return finish()
		end
		local function screen() return remote.call(NET, "screen", terminal) end
		local function mscreen() return remote.call(NET, "screen", maintainer) end
		--- issue #254: the maintainer's screen shows `on`
		local function maintainer_lit(on, when)
			local sc = mscreen()
			expect(sc and sc.on == on and sc.light == nil and sc.layer == "lower-object"
				and sc.sprite == (on and "me-level-maintainer-screen-on" or "me-level-maintainer-screen-off"),
				"the level maintainer's picture " .. when .. ": " .. serpent.line(sc) .. " (" .. (on and "lit" or "dark") .. " expected)")
		end
		local function problem() return remote.call(TERM, "problem", terminal) end

		if st.phase == "work" then
			if tick < START + 40 then return end
			local sc = screen()
			expect(problem() == nil, "the terminal without a pole has the problem " .. tostring(problem()))
			expect(sc and sc.on and sc.light and sc.sprite == "me-terminal-screen-on" and sc.layer == "lower-object",
				"the screen of a terminal in a working network: " .. serpent.line(sc))
			local m = maint()
			expect(m and m.status == "stocked", "the level maintainer without a pole: " .. serpent.line(m))
			maintainer_lit(true, "in a working network")
			--- a level maintainer with no cable to a network is dark, and takes its picture along when it is destroyed
			local lone = s.create_entity{ name = "me-level-maintainer", position = { BX + 30.5, BY + 3.5 }, force = "player",
				raise_built = true }
			local ls = lone and remote.call(NET, "screen", lone)
			expect(ls and ls.on == false and ls.sprite == "me-level-maintainer-screen-off",
				"a level maintainer outside every network: " .. serpent.line(ls))
			if lone then lone.destroy{ raise_destroy = true } end
			for _, id in pairs(ls and ls.ids or {}) do
				local o = rendering.get_object_by_id(id)
				expect(not (o and o.valid), "a destroyed level maintainer left the render object " .. id)
			end
			local sch = remote.call(CIRC, "schedule", maintainer)
			expect(sch and sch.parked == "stocked", "the level maintainer is not parked as stocked: " .. serpent.line(sch))
			--- a second terminal, cloned: it gets a screen of its own; mined, a screen goes with it
			local two = s.create_entity{ name = "me-terminal", position = { BX + 20.5, BY + 3.5 }, force = "player", raise_built = true }
			local three = two and two.clone{ position = { BX + 23.5, BY + 3.5 } }
			local s3 = three and remote.call(NET, "screen", three)
			local s2 = two and remote.call(NET, "screen", two)
			expect(s3 ~= nil and s2 ~= nil and s3.ids[1] ~= s2.ids[1], "a cloned terminal has no screen of its own: " .. serpent.line(s3))
			if two then two.destroy{ raise_destroy = true } end
			if three then three.destroy{ raise_destroy = true } end
			for _, sc3 in pairs({ s2 or { ids = {} }, s3 or { ids = {} } }) do
				for _, id in pairs(sc3.ids) do
					local o = rendering.get_object_by_id(id)
					expect(not (o and o.valid), "a destroyed terminal left the render object " .. id)
				end
			end
			st.phase = "cut"
		elseif st.phase == "cut" then
			if tick < CUT then return end
			eei.power_production, eei.energy, ctrl.energy = 0, 0, 0
			st.cut_at, st.phase = tick, "dark"
		elseif st.phase == "dark" then
			local n = info()
			if n and n.status == "no-power" then
				remote.call(NET, "slow_step")
				local sc = screen()
				expect(problem() == "no-power", "the terminal of a network without power: " .. tostring(problem()))
				expect(sc and not sc.on and not sc.light and sc.sprite == "me-terminal-screen-off",
					"the screen of a network without power: " .. serpent.line(sc))
				expect(maint() and maint().status == "no-power", "the maintainer's status without power: " .. serpent.line(maint()))
				maintainer_lit(false, "in a network without power")
				--- (a woken maintainer finds it and parks for the power)
				remote.call(CIRC, "set_maintainer", maintainer, nil, 20, nil)
				st.dark_at, st.phase = tick, "parked"
			elseif tick - st.cut_at > 300 then
				problems[#problems + 1] = "the network kept its power 300 ticks after the source was cut: " .. serpent.line(n)
				eei.power_production = 1e6
				return finish()
			end
		elseif st.phase == "parked" then
			local sch = remote.call(CIRC, "schedule", maintainer)
			if sch and sch.parked == "no-power" then
				st.phase = "dark2"
			elseif tick - st.dark_at > 90 then
				problems[#problems + 1] = "the level maintainer was not parked for the power within 90 ticks: " .. serpent.line(sch)
				eei.power_production = 1e6
				return finish()
			end
		elseif st.phase == "dark2" then
			--- (after the save and load of the save-and-load run: the screen, still dark, is the same render object)
			if tick < DARK_CHECK then return end
			local sc = screen()
			expect(sc and not sc.on and not sc.light and sc.sprite == "me-terminal-screen-off", "the screen after a while without power: " .. serpent.line(sc))
			expect(problem() == "no-power", "the terminal after a while without power: " .. tostring(problem()))
			local sch = remote.call(CIRC, "schedule", maintainer)
			expect(sch and sch.parked == "no-power", "the maintainer after a while without power: " .. serpent.line(sch))
			maintainer_lit(false, "after a while without power")
			st.phase = "back"
		elseif st.phase == "back" then
			if tick < BACK then return end
			eei.power_production = 1e6
			st.back_at, st.phase = tick, "lit"
		elseif st.phase == "lit" then
			local sch = remote.call(CIRC, "schedule", maintainer)
			local sc = screen()
			if sc and sc.on and sch and sch.parked ~= "no-power" then
				expect(sc.light and sc.sprite == "me-terminal-screen-on", "the screen is lit again but: " .. serpent.line(sc))
				expect(problem() == nil, "the terminal with the power back: " .. tostring(problem()))
				expect(maint() and maint().status == "stocked", "the maintainer with the power back: " .. serpent.line(maint()))
				expect(tick - st.back_at <= 150, "the power came back, the screen was lit " .. (tick - st.back_at) .. " ticks later")
				local n = info()
				expect(n and n.power == 162000, "the controller's draw at the end: " .. serpent.line(n))
				st.lit_after = tick - st.back_at
				maintainer_lit(true, "with the power back")
				--- issue #254: a condition that is false makes it dark, switched off lit again (a condition counts only on a
				--- circuit network: a constant combinator with no signal on a red wire, iron plates > 0)
				local cc = s.create_entity{ name = "constant-combinator", position = { BX + MAINTAINER_X + 0.5, BY + 1.5 },
					force = "player" }
				local RED = defines.wire_connector_id.circuit_red
				expect(cc and maintainer.get_wire_connector(RED, true).connect_to(cc.get_wire_connector(RED, true), false),
					"the level maintainer could not be wired to a constant combinator")
				st.combinator = cc
				remote.call(CIRC, "set_condition", maintainer, true, { type = "item", name = "iron-plate" }, ">", 0)
				st.cond_at, st.phase = tick, "condition"
			elseif tick - st.back_at > 300 then
				problems[#problems + 1] = "the power came back but the screen stayed dark or the maintainer parked: " .. serpent.line(sc) .. " " .. serpent.line(sch)
				return finish()
			end
		elseif st.phase == "condition" then
			if tick < st.cond_at + 5 then return end
			remote.call(NET, "slow_step")
			maintainer_lit(false, "with a false circuit condition")
			remote.call(CIRC, "set_condition", maintainer, false)
			st.cond_at, st.phase = tick, "condition-off"
		elseif st.phase == "condition-off" then
			if tick < st.cond_at + 5 then return end
			remote.call(NET, "slow_step")
			maintainer_lit(true, "with the circuit condition switched off")
			if st.combinator and st.combinator.valid then st.combinator.destroy() end
			return finish("a terminal and a level maintainer 24 tiles from a pole: +8 kW and +30 kW, dark and parked "
				.. "without power, lit and woken " .. st.lit_after .. " ticks after it came back, screens made, cloned and "
				.. "removed; the maintainer dark outside a network and with a false condition (issue #254)")
		end
	end

	function T.running(check) check(storage.netpower128 and storage.netpower128.done, "ME terminal and level maintainer power") end
	return T
end
