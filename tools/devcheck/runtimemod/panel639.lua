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
---   * the panel (a stand-in player's window): E1's window shows the logistic section only, E2's both; M's window sits beside
---     the game's lamp window (anchored in player.gui.relative, the lamp stays opened) and has no panel of ours;
---     the "Connect" check box switches E1's connection through its handler; the roboport removed: E1, still connected, is off
---     (as a vanilla inserter outside every network) and its panel says so; E3 (no wire, not connected) has no panel then.
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
				.. "logistic network's contents, both conditions, the maintainer's, blueprint/paste/clone/old tag, the panel's sections")
		end
		local E1, E2, E3 = find("me-export-bus", 10.5, 0.5), find("me-export-bus", 12.5, 0.5), find("me-export-bus", 24.5, 0.5)
		local M = find("me-level-maintainer", 19.5, -0.5)
		local A, B = find("iron-chest", 10.5, 1.5), find("iron-chest", 12.5, 1.5)
		local K, SC = find("constant-combinator", 12.5, 3.5), find("storage-chest", 7.5, 10.5)
		if not (E1 and E2 and E3 and M and A and B and K and SC) then expect(false, "entities missing") return finish() end
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
			--- the panels
			local p = side(E1)
			expect(p.visible and p.logistic and not p.circuit and p.states.fork_me_lcond_on == true,
				"E1's panel: the logistic section only, connected: " .. line({ p.visible, p.circuit, p.logistic, p.states }))
			p = side(E2)
			expect(p.visible and p.logistic and p.circuit and p.names.fork_me_bus_pulse and p.states.fork_me_cond_on == true,
				"E2's panel: both sections, the pulse mode in the circuit one: " .. line({ p.visible, p.circuit, p.logistic, p.states }))
			--- the maintainer: its ME window beside the game's lamp window (which has the game's own panel), none of ours
			p = side(M)
			local anchor = p.anchor or {}
			expect(p.relative and p.opened_entity and not p.visible and anchor.gui == defines.relative_gui_type.lamp_gui
				and anchor.position == defines.relative_gui_position.left and anchor.names and anchor.names[1] == "me-level-maintainer",
				"M's window beside the game's lamp window: " .. line({ p.relative, p.opened_entity, p.visible, anchor }))
			local mview = remote.call(GUI, "stand_in_act", "panel639", nil, nil, "fork_me_maint_rows")
			expect(mview and #mview.labels > 0, "M's window has its rows (with the circuit column): " .. line(mview))
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
			--- the logistic network goes
			local port = s.find_entities_filtered{ name = "roboport", position = { BX + 3, BY + 10 } }[1]
			if port then port.destroy{ raise_destroy = true } end
			st.phase, st.tick = "gone", game.tick
			return
		end

		if st.phase == "gone" then
			if wait < 320 then return end           -- (the checks' lookup is at most 300 ticks old)
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
