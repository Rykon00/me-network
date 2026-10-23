--- Runtime test of me-network issue #420 (the performance levers): a controller with a drive, a cable row, five import buses,
--- three storage buses on chests, an ME Interface and an ME Circuit Interface:
---   * the controller's draw that joins and removals keep equals the walk over every member;
---   * a node is its own tile box (no box table, no position);
---   * the network's cell list after a storage bus left: each cell once, as many as it has; the storage bus lists are right;
---   * the graph rebuild takes the kept graph over (the same network) and rebuilds from the map when a cable came without an
---     event (it joins);
---   * the interface's side tanks: none alone; a pipe built beside it gets one, connected; the pipe gone, the next look removes
---     it; a pipe built without an event gets one at the next look; a side tied to a fluid row has one; four tanks of an older
---     save are cut to those needed;
---   * the circuit interface: its section is the network's contents after each change; one amount changed writes one slot,
---     many the whole section, a change that leaves the amounts as they were writes nothing.
--- Loaded by control.lua: require("perf420")(H) returns { setup, tick, running }.

local NET, IO, CI, SB = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-circuit", "gregtorio-me-storagebus"
local BX, BY = -150, 290              -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 140
local WAIT = 130                      -- ticks for a circuit interface's visit after a change (CIRCUIT_INTERVAL 60, twice)
local SIDE = "me-network-interface-side"
local ITEMS = { "iron-plate", "copper-plate", "steel-plate", "coal", "stone", "wood", "iron-ore", "copper-ore", "stone-brick",
	"iron-gear-wheel", "copper-cable", "electronic-circuit", "pipe", "iron-stick", "small-electric-pole", "transport-belt",
	"inserter", "burner-inserter", "stone-furnace", "wooden-chest", "iron-chest", "plastic-bar", "sulfur", "battery" }

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local function line(t) return serpent.line(t) end

	function T.setup(s)
		local fails = {}
		local what = "issue #420"
		power(s, fails, what, BX, BY - 4)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY - 3)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 3.5, {}, "4k")
		local members = { ctrl, drive }
		for x = 9.5, 20.5 do members[#members + 1] = me_place(s, fails, what, "me-cable", BX + x, BY - 3.5) end
		members[#members + 1] = me_place(s, fails, what, "me-circuit-interface", BX + 9.5, BY - 2.5)
		members[#members + 1] = me_place(s, fails, what, "me-network-interface", BX + 14.5, BY - 2.5)
		for x = 16.5, 18.5 do
			local c = s.create_entity{ name = "wooden-chest", position = { BX + x, BY - 5.5 }, force = "player" }
			if c then c.insert{ name = "iron-plate", count = 10 } end
			members[#members + 1] = me_place(s, fails, what, "me-storage-bus", BX + x, BY - 4.5, { direction = defines.direction.north })
		end
		H.me_connect(fails, what, members)
		return fails
	end

	--- the circuit interface's section against the network's contents: problems (empty: the same)
	local function section_problems(ci, ctrl)
		local want = {}
		for key, n in pairs(remote.call(NET, "contents", ctrl) or {}) do
			if n >= 1 and not key:find("@") then want[key] = math.floor(n) end
		end
		local got = {}
		local cb = ci.get_control_behavior()
		local section = cb and cb.get_section(1)
		for _, f in pairs(section and section.filters or {}) do
			if f.value and f.value.name then got[f.value.name] = f.min end
		end
		local out = {}
		for k, n in pairs(want) do if got[k] ~= n then out[#out + 1] = k .. " " .. tostring(got[k]) .. " for " .. n end end
		for k, n in pairs(got) do if want[k] == nil then out[#out + 1] = k .. " " .. n .. " not in the network" end end
		table.sort(out)
		return out
	end

	--- the side tanks on the interface's tile: { [direction] = tank }, and their number
	local function tanks_at(s, i)
		local out, n = {}, 0
		for _, t in pairs(s.find_entities_filtered{ name = SIDE, position = i.position }) do
			out[t.direction] = t
			n = n + 1
		end
		return out, n
	end

	function T.tick()
		local st = storage.perf420
		if (st and st.done) or game.tick < START then return end
		local s = game.surfaces[1]
		if not st then
			st = { problems = {}, phase = "start" }
			storage.perf420 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("PERF420", "Performance levers (issue #420)", problems, "power kept, folded nodes, cell list, storage bus "
				.. "lists, kept graph and rebuild, side tanks where needed, circuit interface writes")
		end
		local ctrl = s.find_entity("me-network-controller", { BX + 7, BY - 3 })
		local ci = s.find_entity("me-circuit-interface", { BX + 9.5, BY - 2.5 })
		local iface = s.find_entity("me-network-interface", { BX + 14.5, BY - 2.5 })
		if not (ctrl and ci and iface) then expect(false, "entities missing") return finish() end
		if st.phase ~= "start" and game.tick < st.tick + WAIT then return end

		if st.phase == "start" then
			--- the controller's draw
			local function power_same(when)
				local p = remote.call(NET, "power_recount", ctrl)
				expect(p and not p.dirty and p.kept == p.walked and line(p.kept_by) == line(p.walked_by),
					"the controller's draw " .. when .. ": " .. line(p))
			end
			power_same("at the start")
			local buses = {}
			for x = 10.5, 14.5 do
				buses[#buses + 1] = s.create_entity{ name = "me-import-bus", position = { BX + x, BY - 4.5 }, force = "player",
					direction = defines.direction.north, raise_built = true }
			end
			power_same("after five buses were built")
			for k = 1, 2 do buses[k].destroy{ raise_destroy = true } end
			power_same("after two buses were removed")
			--- a folded node
			local cable = s.find_entity("me-cable", { BX + 12.5, BY - 3.5 })
			local f = remote.call(NET, "node_fold", cable)
			expect(f and f[1] == BX + 12 and f[2] == BY - 4 and f[3] == BX + 13 and f[4] == BY - 3 and not f.box and not f.position,
				"the cable's node: " .. line(f))
			--- the cell list after a storage bus left
			for x = 16.5, 18.5 do remote.call(SB, "visit", s.find_entity("me-storage-bus", { BX + x, BY - 4.5 })) end
			local before = remote.call(NET, "cell_ids", ctrl)
			s.find_entity("me-storage-bus", { BX + 17.5, BY - 4.5 }).destroy{ raise_destroy = true }
			local after = remote.call(NET, "cell_ids", ctrl)
			local seen, dup = {}, nil
			for _, cid in ipairs(after.ids) do
				if seen[cid] then dup = cid end
				seen[cid] = true
			end
			expect(not dup and #after.ids == after.cells and after.cells == before.cells - 1,
				"the cell list after a storage bus left: " .. line({ before = before, after = after, dup = dup }))
			local lok, lwhy = remote.call(SB, "lists_ok")
			expect(lok, "the storage bus lists: " .. tostring(lwhy))
			local hok = { remote.call(NET, "check_holder_lists") }
			expect(hok[2] == 0, "the holder lists: " .. line(hok))
			--- the graph rebuild
			local id = remote.call(NET, "network", ctrl).id
			local c2 = s.create_entity{ name = "me-cable", position = { BX + 21.5, BY - 3.5 }, force = "player" }   -- (no event)
			expect(remote.call(NET, "rebuild") == true, "the rebuild did not take the kept graph over")
			expect(remote.call(NET, "network", ctrl).id == id, "the kept graph changed the network's id")
			expect(remote.call(NET, "same_network", ctrl, c2), "the cable built without an event did not join at the rebuild")
			local ok, why = remote.call(NET, "sweep_list_ok")
			expect(ok, "the sweep list after the rebuild: " .. tostring(why))
			power_same("after the rebuild")
			--- the side tanks
			local _, n = tanks_at(s, iface)
			expect(n == 0, "an interface with nothing beside it has " .. n .. " side tanks")
			local south = { BX + 14.5, BY - 1.5 }
			local pipe = s.create_entity{ name = "pipe", position = south, force = "player", raise_built = true }
			local t = tanks_at(s, iface)[defines.direction.south]
			expect(t and #t.fluidbox.get_connections(1) > 0, "the pipe built south of it got no connected side tank")
			pipe.destroy{ raise_destroy = true }
			expect(remote.call(IO, "refit_tanks", iface) == true and not tanks_at(s, iface)[defines.direction.south],
				"the side tank of the removed pipe stayed")
			s.create_entity{ name = "pipe", position = south, force = "player" }                                     -- (no event)
			_, n = tanks_at(s, iface)
			expect(n == 0, "a pipe built without an event made a tank at once")
			remote.call(IO, "refit_tanks", iface)
			t = tanks_at(s, iface)[defines.direction.south]
			expect(t and #t.fluidbox.get_connections(1) > 0, "the look at the sides gave the pipe built without an event no tank")
			remote.call(IO, "set_interface_config", iface, { { type = "fluid", name = "water", amount = 100 } }, { [2] = 1 })
			remote.call(IO, "step", iface)
			expect(tanks_at(s, iface)[defines.direction.east] ~= nil, "the side tied to a fluid row has no tank")
			remote.call(IO, "interface_tanks", iface)                         -- (four tanks, as an older save had)
			_, n = tanks_at(s, iface)
			expect(n == 4, "interface_tanks made " .. n .. " tanks")
			remote.call(IO, "refit_tanks", iface)
			local left
			left, n = tanks_at(s, iface)
			expect(n == 2 and left[defines.direction.south] and left[defines.direction.east],
				"the four tanks of an older save were cut to " .. n)
			--- the circuit interface: contents to write
			for k, name in ipairs(ITEMS) do remote.call(NET, "insert", ctrl, name, k * 3) end
			st.phase, st.tick = "circuit1", game.tick
			return
		end

		if st.phase ~= "start" then remote.call(CI, "update", ci) end     -- (its scheduled visit may come later)

		if st.phase == "circuit1" then
			local p = section_problems(ci, ctrl)
			expect(#p == 0, "the section after the first contents: " .. line(p))
			remote.call(CI, "last_write", ci, true)
			remote.call(NET, "insert", ctrl, "coal", 5)                       -- (one amount)
			st.phase, st.tick = "circuit2", game.tick
			return
		end

		if st.phase == "circuit2" then
			local p = section_problems(ci, ctrl)
			expect(#p == 0, "the section after one amount changed: " .. line(p))
			local w = remote.call(CI, "last_write", ci, true)
			expect(w == 1, "one amount changed wrote " .. tostring(w) .. " (want 1 slot)")
			for k = 1, 12 do remote.call(NET, "insert", ctrl, ITEMS[k], 1) end   -- (many amounts)
			st.phase, st.tick = "circuit3", game.tick
			return
		end

		if st.phase == "circuit3" then
			local p = section_problems(ci, ctrl)
			expect(#p == 0, "the section after many amounts changed: " .. line(p))
			local w = remote.call(CI, "last_write", ci, true)
			expect(w == "section", "many amounts changed wrote " .. tostring(w) .. " (want the section)")
			remote.call(NET, "insert", ctrl, "coal", 7)                       -- (the same amounts again)
			remote.call(NET, "extract", ctrl, "coal", 7)
			st.phase, st.tick = "circuit4", game.tick
			return
		end

		if st.phase == "circuit4" then
			local p = section_problems(ci, ctrl)
			expect(#p == 0, "the section after a change that left the amounts: " .. line(p))
			local w = remote.call(CI, "last_write", ci, true)
			expect(w == nil, "a change that left the amounts wrote " .. tostring(w))
			return finish()
		end
	end

	function T.running(check) check(storage.perf420 and storage.perf420.done, "Performance levers (issue #420)") end

	return T
end
