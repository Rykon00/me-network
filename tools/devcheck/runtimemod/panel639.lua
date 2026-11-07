--- Runtime test of me-network issue #639: the logistic network condition of the ME blocks and the circuit and logistic network
--- panel right of their windows. A network with iron plates; a roboport R and a storage chest SC (50 iron plates) make a logistic
--- network around it; export bus E1 (no wire), export bus E2 (wired to a constant combinator K with signal A), a level maintainer
--- M, and a bus E3 on its own:
---   * E1 connected to the logistic network with "iron plate > 100": off (the chest A behind it gets nothing); 100 more plates
---     into SC: on, A gets plates (the check queue follows the network's contents, no tick handler);
---   * E2 with both conditions ("A > 0" on its wire, "iron plate > 10" in the network): on while both hold; K off: off;
---   * the maintainer's logistic condition (its lamp's own): disabled while it does not hold, its levels follow;
---   * a blueprint copy, a settings paste and a clone of E1 keep the logistic part; a tag made before #639 (no logistic part)
---     still applies and clears it;
---   * the panel (a stand-in player's window): E1's window shows the logistic section only, E2's both, M's the logistic one;
---     the "Connect" check box switches E1's connection through its handler; the roboport removed: E1, still connected, is off
---     (as a vanilla inserter outside every network) and its panel says so; E3 (no wire, not connected) has no panel then.
---   * Issue #651, the status lines name the condition that switches a block off: with a storage bus S (a chest behind it) and a
---     pattern provider P (lock "while the condition does not hold"), both connected with "iron plate > 100": E1, S, M and P say
---     their logistic condition does not hold; with 150 plates E2 (its circuit condition off) says circuit, also when its
---     logistic condition fails as well (the circuit one is named first), and P in lock mode "while it holds" says the logistic
---     one holds; the roboport removed: E1, S, M and P (back in the first mode) say no logistic network covers them.
---   * Task-Ingame #658: an ME Interface I (connected with "iron plate > 100") says its logistic condition does not hold, and is
---     off once the roboport is gone (issue #664: its line then names the missing network); E2 with its circuit condition holding and its logistic one failing names the
---     logistic condition (its panel: the circuit condition holds, the logistic one not); the combinator on again with 150
---     plates: E2 says "Working."; the line names the missing logistic network at most 300 ticks after the roboport went.
---   * Issue #664, an interface with nothing to do (I, no rows) switched while it works: the roboport built again, I is on and
---     says "Working."; wired to K with "A > 0" it stays so, K off: it says its circuit condition does not hold, K on: "Working.".
--- Loaded by control.lua: require("panel639")(H) returns { setup, tick, running }.

local IO, CONN, C, GUI = "gregtorio-me-io", "gregtorio-me-connector", "gregtorio-me-circuit", "gregtorio-me-gui"
local BX, BY = -70, 150               -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 150
local IRON = { type = "item", name = "iron-plate" }
local SIG = { type = "virtual", name = "signal-A" }

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	function T.setup(s)
		local fails = {}
		local what = "logistic condition"
		H.power(s, fails, what, BX, BY)
		me_place(s, fails, what, "substation", BX - 3, BY + 10)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 400 })
		local members = { ctrl, drive }
		for x = 9.5, 18.5 do members[#members + 1] = me_place(s, fails, what, "me-cable", BX + x, BY - 0.5) end
		members[#members + 1] = me_place(s, fails, what, "me-export-bus", BX + 10.5, BY + 0.5, SOUTH)
		members[#members + 1] = me_place(s, fails, what, "me-export-bus", BX + 12.5, BY + 0.5, SOUTH)
		members[#members + 1] = me_place(s, fails, what, "me-level-maintainer", BX + 19.5, BY - 0.5)
		me_place(s, fails, what, "iron-chest", BX + 10.5, BY + 1.5)
		me_place(s, fails, what, "iron-chest", BX + 12.5, BY + 1.5)
		me_place(s, fails, what, "constant-combinator", BX + 12.5, BY + 3.5)
		me_place(s, fails, what, "me-export-bus", BX + 24.5, BY + 0.5, SOUTH)                -- E3, on its own
		--- issue #651: S (a chest behind it) and P
		members[#members + 1] = me_place(s, fails, what, "me-storage-bus", BX + 14.5, BY + 0.5, SOUTH)
		me_place(s, fails, what, "iron-chest", BX + 14.5, BY + 1.5)
		members[#members + 1] = me_place(s, fails, what, "me-pattern-provider", BX + 16.5, BY + 0.5)
		members[#members + 1] = me_place(s, fails, what, "me-network-interface", BX + 18.5, BY + 0.5)    -- (Task-Ingame #658)
		local port = me_place(s, fails, what, "roboport", BX + 3, BY + 10)
		local sc = me_place(s, fails, what, "storage-chest", BX + 7.5, BY + 10.5)
		if sc then sc.insert{ name = "iron-plate", count = 50 } end
		H.me_connect(fails, what, members)
		if port and not s.find_logistic_network_by_position({ BX + 10.5, BY + 0.5 }, "player") then
			fails[#fails + 1] = what .. ": the roboport makes no logistic network at the buses"
		end
		return fails
	end

	function T.tick()
		local st = storage.panel639
		if (st and st.done) or game.tick < START then return end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		if not st then
			st = { problems = {}, phase = "start" }
			storage.panel639 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function line(t) return serpent.line(t) end
		local function finish()
			st.done = true
			me_report("PANEL639", "Logistic condition and the circuit and logistic network panel", problems, "a bus switched by the "
				.. "logistic network's contents, both conditions, the maintainer's, blueprint/paste/clone/old tag, the panel's sections"
				.. (st.seen and ("; the missing network named after " .. st.seen .. " ticks") or ""))
		end
		local E1, E2, E3 = find("me-export-bus", 10.5, 0.5), find("me-export-bus", 12.5, 0.5), find("me-export-bus", 24.5, 0.5)
		local M = find("me-level-maintainer", 19.5, -0.5)
		local A, B = find("iron-chest", 10.5, 1.5), find("iron-chest", 12.5, 1.5)
		local K, SC = find("constant-combinator", 12.5, 3.5), find("storage-chest", 7.5, 10.5)
		local S, P = find("me-storage-bus", 14.5, 0.5), find("me-pattern-provider", 16.5, 0.5)   -- (issue #651)
		local I = find("me-network-interface", 18.5, 0.5)                                        -- (Task-Ingame #658)
		if not (E1 and E2 and E3 and M and A and B and K and SC and S and P and I) then expect(false, "entities missing") return finish() end
		local function off(e) return remote.call(CONN, "is_off", e) end
		local function logistic(e) return remote.call(CONN, "logistic", e) end
		local function side(e, act, state)
			--- (the stand-in is a table of the mod, not saved: made again for each look, also after the save and load)
			if not (st.inv and st.inv.valid) then st.inv = game.create_inventory(10) end
			remote.call(GUI, "stand_in", "panel639", { main = st.inv, index = 9639, gui = true })
			remote.call(GUI, "stand_in_open_entity", "panel639", e)
			return remote.call(GUI, "stand_in_side", "panel639", act, state) or {}
		end
		local function same(a, b)
			return a and b and a[1] == b[1] and line(a[2]) == line(b[2])
		end
		--- issue #651: the status line of `e`'s window (its element `element`) must be locale key `key`
		local STATUS = { ["me-export-bus"] = "fork_me_bus_status", ["me-storage-bus"] = "fork_me_sbus_status",
			["me-level-maintainer"] = "fork_me_maint_status", ["me-pattern-provider"] = "fork_me_prov_locked",
			["me-network-interface"] = "fork_me_if_status" }
		local function caption(e)
			if not (st.inv and st.inv.valid) then st.inv = game.create_inventory(10) end
			remote.call(GUI, "stand_in", "panel639", { main = st.inv, index = 9639, gui = true })
			remote.call(GUI, "stand_in_open_entity", "panel639", e)
			return remote.call(GUI, "stand_in_caption", "panel639", STATUS[e.name])
		end
		local function status(e, key, what)
			local c = caption(e)
			expect(type(c) == "table" and c[1] == key, what .. ": the status line is " .. line(c) .. ", not " .. key)
		end
		local wait = game.tick - (st.tick or 0)

		if st.phase == "start" then
			for _, e in pairs({ E1, E2, E3 }) do remote.call(IO, "set_bus_filters", e, { "iron-plate" }) end
			local cb = K.get_or_create_control_behavior()
			if cb.sections_count == 0 then cb.add_section() end
			cb.get_section(1).set_slot(1, { value = { type = SIG.type, name = SIG.name, quality = "normal" }, min = 1 })
			local w = defines.wire_connector_id.circuit_red
			E2.get_wire_connector(w, true).connect_to(K.get_wire_connector(w, true), false)
			expect(remote.call(CONN, "set_logistic", E1, true, { first_signal = IRON, comparator = ">", constant = 100 }), "E1 set")
			remote.call(CONN, "set_condition", E2, true, { first_signal = SIG, comparator = ">", constant = 0 })
			remote.call(CONN, "set_logistic", E2, true, { first_signal = IRON, comparator = ">", constant = 10 })
			remote.call(C, "set_maintainer", M, "iron-gear-wheel", 10, false)
			expect(remote.call(C, "set_logistic", M, true, { first_signal = IRON, comparator = ">", constant = 100 }), "M set")
			expect(off(E1), "E1 is off at once: 50 plates in the network, its condition asks for more than 100")
			--- issue #651: S and P with the same logistic condition, P locked while it does not hold
			for _, e in pairs({ S, P, I }) do
				expect(remote.call(CONN, "set_logistic", e, true, { first_signal = IRON, comparator = ">", constant = 100 }), e.name .. " set")
			end
			expect(remote.call("gregtorio-me-autocraft", "set_lock", P, "low"), "P's lock mode")
			--- the panels
			local p = side(E1)
			expect(p.visible and p.logistic and not p.circuit and p.states.fork_me_lcond_on == true,
				"E1's panel: the logistic section only, connected: " .. line({ p.visible, p.circuit, p.logistic, p.states }))
			p = side(E2)
			expect(p.visible and p.logistic and p.circuit and p.names.fork_me_bus_pulse and p.states.fork_me_cond_on == true,
				"E2's panel: both sections, the pulse mode in the circuit one: " .. line({ p.visible, p.circuit, p.logistic, p.states }))
			p = side(M)
			expect(p.visible and p.logistic and not p.circuit and p.states.fork_me_lcond_on == true,
				"M's panel: the logistic section, connected: " .. line({ p.visible, p.circuit, p.logistic, p.states }))
			p = side(E3)
			expect(p.visible and p.logistic and not p.circuit and p.states.fork_me_lcond_on == false,
				"E3's panel: in the network's area, not connected: " .. line({ p.visible, p.circuit, p.logistic, p.states }))
			--- the check box through its handler: E3 connected and back
			p = side(E3, "lcond_on", true)
			expect(logistic(E3)[1] == true and p.states.fork_me_lcond_on == true, "Connect on E3's panel: " .. line(logistic(E3)))
			p = side(E3, "lcond_on", false)
			expect(logistic(E3)[1] == false, "Connect off on E3's panel: " .. line(logistic(E3)))
			st.phase, st.tick = "arm", game.tick
			return
		end

		if st.phase == "arm" then
			if wait < 40 then return end
			expect(off(E1) and A.get_item_count("iron-plate") == 0, "E1 stays off: " .. A.get_item_count("iron-plate") .. " plates in A")
			local lv = remote.call(CONN, "levels", E2)
			expect(not off(E2) and B.get_item_count("iron-plate") > 0 and lv[1] == true and lv[2] == true,
				"E2 works while both hold: " .. B.get_item_count("iron-plate") .. " plates, levels " .. line(lv))
			local ml = remote.call(C, "levels", M)
			local m = remote.call(C, "get_maintainer", M)
			expect(ml[2] == false and m.status == "disabled", "M is disabled by its logistic condition: " .. line({ ml, m.status }))
			--- issue #651: the logistic condition is named
			status(E1, "fork-me-net.bus-logistic-off", "E1 (its logistic condition does not hold)")
			status(S, "fork-me-net.storage-bus-logistic-off", "S (its logistic condition does not hold)")
			status(M, "fork-me-circuit.maintainer-logistic-off", "M (its logistic condition does not hold)")
			status(P, "fork-me-gui.provider-locked-low-logistic", "P (its logistic condition does not hold)")
			--- Task-Ingame #658: the interface; E2 with its circuit condition holding and its logistic one failing
			status(I, "fork-me-net.bus-logistic-off", "I (its logistic condition does not hold)")
			remote.call(CONN, "set_logistic", E2, true, { first_signal = IRON, comparator = ">", constant = 1000 })
			st.phase, st.tick = "e2logistic", game.tick
			return
		end

		if st.phase == "e2logistic" then
			if wait < 40 then return end           -- (the status line follows the bus's next visit)
			status(E2, "fork-me-net.bus-logistic-off", "E2 (its circuit condition holds, its logistic one not)")
			local p2 = side(E2)
			local cs, ls = p2.captions and p2.captions.fork_me_cond_state, p2.captions and p2.captions.fork_me_lcond_state
			expect(type(cs) == "table" and cs[1] == "fork-me-gui.circuit-condition-holds" and type(ls) == "table"
				and ls[1] == "fork-me-gui.circuit-condition-not", "E2's panel (circuit holds, logistic not): " .. line({ cs, ls }))
			remote.call(CONN, "set_logistic", E2, true, { first_signal = IRON, comparator = ">", constant = 10 })
			SC.insert{ name = "iron-plate", count = 100 }
			K.get_or_create_control_behavior().enabled = false
			st.phase, st.tick = "flip", game.tick
			return
		end

		if st.phase == "flip" then
			if wait < 40 then return end
			expect(not off(E1) and A.get_item_count("iron-plate") > 0,
				"E1 is on with 150 plates in the network: " .. A.get_item_count("iron-plate") .. " plates in A")
			local lv = remote.call(CONN, "levels", E2)
			expect(off(E2) and lv[1] == false and lv[2] == true, "E2 is off while its circuit condition does not hold: " .. line(lv))
			local ml = remote.call(C, "levels", M)
			expect(ml[2] == true, "M's logistic condition holds with 150 plates: " .. line(ml))
			--- issue #651: the circuit condition is named, also when both fail (a fixed order); P locked while it holds
			status(E2, "fork-me-net.bus-circuit-off", "E2 (its circuit condition does not hold, the logistic one holds)")
			remote.call(CONN, "set_logistic", E2, true, { first_signal = IRON, comparator = ">", constant = 1000 })
			status(E2, "fork-me-net.bus-circuit-off", "E2 (neither holds: the circuit condition first)")
			remote.call(CONN, "set_logistic", E2, true, { first_signal = IRON, comparator = ">", constant = 10 })
			remote.call("gregtorio-me-autocraft", "set_lock", P, "high")
			remote.call(CONN, "update", P)
			status(P, "fork-me-gui.provider-locked-high-logistic", "P in lock mode high (its logistic condition holds)")
			remote.call("gregtorio-me-autocraft", "set_lock", P, "low")
			--- blueprint, settings paste, clone, an old tag
			local want = logistic(E1)
			local copy, why, tags = H.blueprint_copy(E1, 0, 6)
			expect(copy and same(logistic(copy), want) and tags and tags.fork_me_condition and tags.fork_me_condition.lc == true,
				"a blueprint copy of E1 keeps its logistic part: " .. tostring(why) .. " " .. line({ copy and logistic(copy), tags }))
			if copy and copy.valid then copy.destroy{ raise_destroy = true } end
			remote.call(CONN, "paste", E1, E3)
			expect(same(logistic(E3), want), "a settings paste E1 -> E3: " .. line(logistic(E3)))
			local clone = E1.clone{ position = { BX + 26.5, BY + 0.5 } }
			expect(clone and same(logistic(clone), want), "a clone of E1: " .. line(clone and logistic(clone)))
			if clone and clone.valid then clone.destroy{ raise_destroy = true } end
			remote.call(CONN, "apply_tag", E3, { fork_me_condition = { cc = true, cond = { first_signal = SIG, comparator = "=", constant = 4 } } })
			local c3 = remote.call(CONN, "condition", E3)
			expect(c3[1] == true and c3[2] and c3[2].constant == 4 and logistic(E3)[1] == false,
				"a tag of 0.5.11 (no logistic part) applies: " .. line({ c3, logistic(E3) }))
			--- Task-Ingame #658: the combinator on again (150 plates in the network): E2 works
			K.get_or_create_control_behavior().enabled = true
			st.phase, st.tick = "back", game.tick
			return
		end

		if st.phase == "back" then
			if wait < 40 then return end
			expect(not off(E2), "E2 with both conditions holding again is off: " .. line(remote.call(CONN, "levels", E2)))
			status(E2, "fork-me-net.bus-ok", "E2 (both conditions hold)")
			--- the logistic network goes
			local port = s.find_entities_filtered{ name = "roboport", position = { BX + 3, BY + 10 } }[1]
			if port then port.destroy{ raise_destroy = true } end
			st.phase, st.tick = "gone", game.tick
			return
		end

		if st.phase == "gone" then
			--- Task-Ingame #658: when E1's line first names the missing network (the harness calls this every 10 ticks)
			if not st.seen then
				local c = caption(E1)
				if type(c) == "table" and c[1] == "fork-me-net.bus-no-logistic-network" then st.seen = wait end
			end
			if wait < 320 then return end           -- (the checks' lookup is at most 300 ticks old)
			expect(st.seen and st.seen <= 300, "E1's line names the missing logistic network " .. tostring(st.seen)
				.. " ticks after the roboport went (at most 300)")
			expect(off(I), "I, connected outside every network, is not off: " .. line(remote.call(CONN, "levels", I)))
			--- issue #664: the interface had been working and has nothing to do (no rows): its line follows the switch-off
			status(I, "fork-me-net.bus-no-logistic-network", "I (no logistic network, switched off while it was working)")
			expect(off(E1) and remote.call(CONN, "levels", E1)[2] == false, "E1, connected outside every network, is off: "
				.. line(remote.call(CONN, "levels", E1)))
			local p = side(E1)
			expect(p.visible and p.logistic and type(p.captions.fork_me_side_lnet) == "table"
				and p.captions.fork_me_side_lnet[1] == "gui-control-behavior.no-network-in-range",
				"E1's panel stays (it is connected) and says there is no network: " .. line(p.captions))
			p = side(E3)
			expect(not p.visible, "E3 (no wire, not connected, no network) has no panel: " .. line({ p.visible, p.names }))
			local m = remote.call(C, "get_maintainer", M)
			expect(m.status == "disabled", "M, connected outside every network, is disabled: " .. tostring(m.status))
			--- issue #651: no logistic network is named
			status(E1, "fork-me-net.bus-no-logistic-network", "E1 (no logistic network)")
			status(S, "fork-me-net.storage-bus-no-logistic-network", "S (no logistic network)")
			status(M, "fork-me-circuit.maintainer-no-logistic-network", "M (no logistic network)")
			status(P, "fork-me-gui.provider-locked-low-no-logistic-network", "P (no logistic network)")
			--- issue #664: the logistic network comes back (150 plates, "iron plate > 100" holds): I is switched on again
			local fails = {}
			me_place(s, fails, "logistic condition", "roboport", BX + 3, BY + 10)
			for _, f in pairs(fails) do expect(false, f) end
			st.phase, st.tick = "regain", game.tick
			return
		end

		--- issue #664: the switch on and off of an interface with nothing to do, by its logistic and its circuit condition
		if st.phase == "regain" then
			if wait < 320 then return end           -- (the checks' lookup is at most 300 ticks old)
			expect(not off(I), "I with its logistic network back is off: " .. line(remote.call(CONN, "levels", I)))
			status(I, "fork-me-net.bus-ok", "I (switched on again by its logistic condition)")
			--- its circuit condition: wired to K (signal A) with "A > 0", which holds
			local w = defines.wire_connector_id.circuit_red
			I.get_wire_connector(w, true).connect_to(K.get_wire_connector(w, true), false)
			remote.call(CONN, "set_condition", I, true, { first_signal = SIG, comparator = ">", constant = 0 })
			st.phase, st.tick = "iwired", game.tick
			return
		end

		if st.phase == "iwired" then
			if wait < 40 then return end
			expect(not off(I), "I with its circuit condition holding is off: " .. line(remote.call(CONN, "levels", I)))
			status(I, "fork-me-net.bus-ok", "I (both conditions hold)")
			K.get_or_create_control_behavior().enabled = false
			st.phase, st.tick = "icircuitoff", game.tick
			return
		end

		if st.phase == "icircuitoff" then
			if wait < 40 then return end
			expect(off(I), "I with its circuit condition failing is not off: " .. line(remote.call(CONN, "levels", I)))
			status(I, "fork-me-net.bus-circuit-off", "I (switched off by its circuit condition while it had nothing to do)")
			K.get_or_create_control_behavior().enabled = true
			st.phase, st.tick = "icircuiton", game.tick
			return
		end

		if st.phase == "icircuiton" then
			if wait < 40 then return end
			expect(not off(I), "I with its circuit condition holding again is off: " .. line(remote.call(CONN, "levels", I)))
			status(I, "fork-me-net.bus-ok", "I (switched on again by its circuit condition)")
			remote.call(GUI, "stand_in_close_window", "panel639")
			remote.call(GUI, "stand_in_forget", "panel639")
			if st.inv and st.inv.valid then st.inv.destroy() end
			st.inv = nil
			finish()
		end
	end

	function T.running(check) check(storage.panel639 and storage.panel639.done, "logistic condition and the network panel (#639)") end

	return T
end
