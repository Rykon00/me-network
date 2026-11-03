--- Runtime test of me-network issue #412: the circuit condition of the ME Import, Export and Storage Bus and the ME Interface;
--- since issue #628 on the blocks' own wires (until 0.5.11 a hidden lamp at each block's position, the connector).
--- A network with iron plates; an export bus on chest A (filter iron-plate), an import bus on chest B (stone), a storage bus on
--- chest C (wood), an ME Interface; a constant combinator K (signal A, iron plate 7) wired to every block:
---   * an old connector (a lamp of 0.5.11 with a wire to K and the condition) built at the export bus hands its wire and its
---     condition to the bus and goes; an old connector without a block is removed; the other blocks are wired themselves;
---   * the buses' condition "A > 0" while K is off: the buses are off (parked), A gets nothing, B keeps its stone, the
---     network does not see C's wood; K on: they are on again, A gets plates, the stone comes in, the wood is seen;
---   * pulse mode of the export bus: one visit per rise of the condition, nothing in between;
---   * the interface's rows from the circuit: it keeps the 7 plates K's signal asks for (its own contents are not on its
---     wire: they would make 14);
---   * a removed bus takes its condition's record with it.
--- Loaded by control.lua: require("circuitbus")(H) returns { setup, tick, running }.

local NET, IO, CONN = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-connector"
local BX, BY = -150, 50               -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 200
local SIG = { type = "virtual", name = "signal-A" }
local CONNECTOR = "me-circuit-connector"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH = { direction = defines.direction.south }
	local XS = { 10.5, 12.5, 14.5, 16.5 }    -- export E, import I, storage S, interface F
	local function line(t) return serpent.line(t) end

	function T.setup(s)
		local fails = {}
		local what = "circuit condition"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 200 })
		local members = { ctrl, drive }
		local names = { "me-export-bus", "me-import-bus", "me-storage-bus", "me-network-interface" }
		for i, x in ipairs(XS) do
			members[#members + 1] = me_place(s, fails, what, names[i], BX + x, BY + 0.5, i < 4 and SOUTH or nil)
			if i < 4 then me_place(s, fails, what, "iron-chest", BX + x, BY + 1.5) end
		end
		for x = 9.5, 16.5 do me_place(s, fails, what, "me-cable", BX + x, BY - 0.5) end
		me_place(s, fails, what, "constant-combinator", BX + 13.5, BY + 3.5)
		me_place(s, fails, what, "me-export-bus", BX + 18.5, BY + 0.5, SOUTH)            -- (removed in the test)
		members[#members + 1] = s.find_entity("me-export-bus", { BX + 18.5, BY + 0.5 })
		me_place(s, fails, what, "me-cable", BX + 17.5, BY - 0.5)
		me_place(s, fails, what, "me-cable", BX + 18.5, BY - 0.5)
		H.me_connect(fails, what, members)
		--- a connector alone (no block, no block's ghost at its place) is removed when it is built
		local lone = s.create_entity{ name = CONNECTOR, position = { BX + 20.5, BY + 3.5 }, force = "player" }
		if lone then remote.call(CONN, "on_built", lone) end
		if lone and lone.valid then fails[#fails + 1] = what .. ": a connector without a block stayed" end
		return fails
	end

	function T.tick()
		local st = storage.circuitbus412
		if (st and st.done) or game.tick < START then return end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		if not st then
			st = { problems = {}, phase = "start" }
			storage.circuitbus412 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("CIRCUITBUS", "Circuit condition of the buses and the interface", problems, "an old connector hands "
				.. "over, a lone one removed; the condition switches the three buses off and on; pulse mode; the interface's rows from the "
				.. "circuit; a removed bus takes its record")
		end
		local ctrl = find("me-network-controller", 7, 0)
		local E, I, S, F = find("me-export-bus", XS[1], 0.5), find("me-import-bus", XS[2], 0.5), find("me-storage-bus", XS[3], 0.5),
			find("me-network-interface", XS[4], 0.5)
		local A, B, C = find("iron-chest", XS[1], 1.5), find("iron-chest", XS[2], 1.5), find("iron-chest", XS[3], 1.5)
		local K = find("constant-combinator", 13.5, 3.5)
		if not (ctrl and E and I and S and F and A and B and C and K) then expect(false, "entities missing") return finish() end
		local a, b, c = A.get_inventory(defines.inventory.chest), B.get_inventory(defines.inventory.chest),
			C.get_inventory(defines.inventory.chest)
		local function count(name) return remote.call(NET, "count", ctrl, name) end
		local function off(e) return remote.call(CONN, "is_off", e) end
		local function emit(on)
			local cb = K.get_or_create_control_behavior()
			cb.enabled = on
		end

		if st.phase == "start" then
			local cb = K.get_or_create_control_behavior()
			if cb.sections_count == 0 then cb.add_section() end
			cb.get_section(1).set_slot(1, { value = { type = SIG.type, name = SIG.name, quality = "normal" }, min = 1 })
			cb.get_section(1).set_slot(2, { value = { type = "item", name = "iron-plate", quality = "normal" }, min = 7 })
			cb.enabled = false
			local w = defines.wire_connector_id.circuit_red
			--- the export bus: an old connector with the wire and the condition hands them over
			local old = s.create_entity{ name = CONNECTOR, position = E.position, force = "player" }
			if old then
				old.get_wire_connector(w, true).connect_to(K.get_wire_connector(w, true), false)
				local ccb = old.get_or_create_control_behavior()
				ccb.circuit_enable_disable = true
				ccb.circuit_condition = { first_signal = SIG, comparator = ">", constant = 0 }
				remote.call(CONN, "on_built", old)
			end
			expect(old and not old.valid, "the old connector at the export bus is removed")
			expect(E.get_wire_connector(w, true).connection_count == 1, "the export bus has the old connector's wire")
			local got = remote.call(CONN, "condition", E)
			expect(got[1] == true and got[2] and got[2].comparator == ">" and got[2].first_signal and got[2].first_signal.name == SIG.name,
				"the export bus has the old connector's condition: " .. line(got))
			for _, e in pairs({ I, S, F }) do
				e.get_wire_connector(w, true).connect_to(K.get_wire_connector(w, true), false)
				if e ~= F then remote.call(CONN, "set_condition", e, true, { first_signal = SIG, comparator = ">", constant = 0 }) end
				remote.call(CONN, "update", e)
			end
			st.phase, st.tick = "arm", game.tick
			return
		end

		--- (the game evaluates a new condition at its next circuit update: the work comes after the checks saw it)
		if st.phase == "arm" then
			if game.tick < st.tick + 30 then return end
			remote.call(IO, "set_bus_filters", E, { "iron-plate" })
			b.insert{ name = "stone", count = 30 }
			c.insert{ name = "wood", count = 40 }
			remote.call(IO, "set_interface_circuit", F, true)
			st.phase, st.tick = "off", game.tick
			return
		end

		if st.phase == "off" then
			if game.tick < st.tick + 40 then return end
			expect(off(E) and off(I) and off(S), "K off: the three buses are off: " .. line({ off(E), off(I), off(S) }))
			expect(a.get_item_count("iron-plate") == 0, "the export bus moved plates while off: " .. a.get_item_count("iron-plate"))
			expect(b.get_item_count("stone") == 30, "the import bus took stone while off: " .. b.get_item_count("stone"))
			expect(count("wood") == 0, "the network sees the wood of an off storage bus: " .. count("wood"))
			expect(not off(F), "the interface has no condition: it is on")
			emit(true)
			st.phase, st.tick = "on", game.tick
			return
		end

		if st.phase == "on" then
			if game.tick < st.tick + 60 then return end
			expect(not off(E) and not off(I) and not off(S), "K on: the buses are on: " .. line({ off(E), off(I), off(S) }))
			expect(a.get_item_count("iron-plate") > 0, "the export bus moves plates again")
			expect(b.get_item_count("stone") == 0, "the import bus took the stone: " .. b.get_item_count("stone") .. " left")
			expect(count("wood") == 40, "the network sees the wood again: " .. count("wood"))
			local have = F.get_inventory(defines.inventory.chest).get_item_count("iron-plate")
			expect(have == 7, "the interface keeps the 7 plates of its rows from the circuit: " .. have
				.. " " .. line((remote.call(IO, "get_interface", F) or {}).circuit_rows))
			--- pulse mode
			remote.call(IO, "set_bus_pulse", E, true)
			emit(false)
			st.phase, st.tick = "pulse-low", game.tick
			return
		end

		if st.phase == "pulse-low" then
			if game.tick < st.tick + 30 then return end
			a.clear()
			remote.call(NET, "insert", ctrl, "iron-plate", 200)            -- (the bus had moved the network's plates into A)
			emit(true)
			st.phase, st.tick = "pulse-high", game.tick
			return
		end

		if st.phase == "pulse-high" then
			if game.tick < st.tick + 30 then return end
			st.first = a.get_item_count("iron-plate")
			expect(st.first > 0, "a rise of the condition gives the export bus a visit: " .. st.first)
			st.phase, st.tick = "pulse-hold", game.tick
			return
		end

		if st.phase == "pulse-hold" then
			if game.tick < st.tick + 90 then return end
			expect(a.get_item_count("iron-plate") == st.first, "no visit while the condition stays true: " .. st.first .. " -> "
				.. a.get_item_count("iron-plate"))
			--- a removed bus takes its condition's record with it
			local R = find("me-export-bus", 18.5, 0.5)
			if R then remote.call(CONN, "set_condition", R, true, { first_signal = SIG, comparator = ">", constant = 0 }) end
			local before = remote.call(CONN, "stats").hosts
			if R then R.destroy{ raise_destroy = true } end
			local after = remote.call(CONN, "stats").hosts
			expect(R and after == before - 1, "the record of a removed bus is gone: " .. before .. " -> " .. after)
			return finish()
		end
	end

	function T.running(check) check(storage.circuitbus412 and storage.circuitbus412.done, "Circuit condition of the buses and the interface") end

	return T
end
