--------------------------------------------------------------------------------
--- devcheck migrate, me-network issue #628: the buses and the pattern provider of an old save (simple entities, each with
--- its hidden circuit connector of issue #412 where it had one) become the wired blocks (display panels that take wires
--- themselves); the ME Interface keeps its prototype and gets its wires from its connector. Built by an old version with the
--- connector (0.5.x with issue #412; an older one builds the blocks without connectors):
---   * storage bus S on a chest (iron, stone, wood; priority 3), its connector wired to a constant combinator K (A = 1, iron
---     plate 7), no condition: the network's only storage;
---   * import bus I on a chest of copper plates, its connector wired to K with the condition A > 0 (holds);
---   * export bus E1 on a chest (filter iron plate), its connector wired to K with A > 5 (does not hold: off);
---   * export bus E2 on a chest (filter iron plate), no connector;
---   * ME Interface F, its rows from the circuit on its connector (K's 7 iron plates);
---   * pattern provider P with a processing pattern stone -> pipe, priority 4, blocking mode, a chest next to it, and a job of
---     pipes running on a crafting storage; provider P2 with the lock "low" and its connector's condition A > 0;
---   * an old blueprint (a bus, its connector with a wire to a constant combinator and the condition A > 0) in a chest, and its
---     ghosts built on the map.
--- After the load: no old block, connector or ghost of one is left; every block is the wired one with its settings, its wires
--- and its condition, the buses work as before (S's storage counted, I imported, E1 still off, E2 exported), F keeps 7
--- plates (its own contents are not on its wire), the job still runs and hands stone into P's chest, P2 keeps its lock; the
--- old ghost is a ghost of the wired bus with the wire and the condition in its tags; the old blueprint builds a wired bus
--- with its wire and condition. Logs DEVCHECK-MIGRATE-WIRED.
--------------------------------------------------------------------------------

local NET, IO, SB, AC, CONN = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-storagebus", "gregtorio-me-autocraft",
	"gregtorio-me-connector"
local PT = "gregtorio-me-pattern-terminal"
local X, Y = 100, 0                         -- (east of the other blocks of the helper)
local AREA = { { X - 2, Y - 8 }, { X + 52, Y + 12 } }
local SIG = { type = "virtual", name = "signal-A" }
local RED = defines.wire_connector_id.circuit_red
local OLD_NAMES = { "me-import-bus-legacy", "me-export-bus-legacy", "me-storage-bus-legacy", "me-pattern-provider-legacy",
	"me-circuit-connector" }

local M = {}

local function L(key, msg) log("DEVCHECK-MIGRATE-" .. key .. " " .. msg) end

local function place(s, fails, name, x, y, extra)
	local def = { name = name, position = { X + x, Y + y }, force = "player", raise_built = true }
	for k, v in pairs(extra or {}) do def[k] = v end
	local ok, e = pcall(s.create_entity, def)
	if not (ok and e) then fails[#fails + 1] = "place " .. name .. " at " .. x .. "," .. y .. ": " .. tostring(e) return nil end
	return e
end

--- the old version's connector of `e`, wired to `k` with the condition `cond` (nil: none); false when it has no connectors
local function connector(e, k, cond)
	local iface = remote.interfaces[CONN]
	if not (iface and iface.connector) then return false end
	local c = remote.call(CONN, "connector", e)
	if not c then return nil end
	c.get_wire_connector(RED, true).connect_to(k.get_wire_connector(RED, true), false)
	if cond then
		local cb = c.get_or_create_control_behavior()
		cb.circuit_enable_disable = true
		cb.circuit_condition = cond
	end
	remote.call(CONN, "update", e)
	return c
end

local function emit(k, slots)
	local cb = k.get_or_create_control_behavior()
	if cb.sections_count == 0 then cb.add_section() end
	for i, v in ipairs(slots) do
		cb.get_section(1).set_slot(i, { value = { type = v[1], name = v[2], quality = "normal" }, min = v[3] })
	end
end

function M.setup(s)
	local fails = {}
	s.request_to_generate_chunks({ X + 25, Y }, 3)
	s.force_generate_chunk_requests()
	for _, e in pairs(s.find_entities_filtered{ area = AREA }) do
		if e.valid and e.type ~= "character" then e.destroy() end
	end
	local tiles = {}
	for x = AREA[1][1], AREA[2][1] do
		for y = AREA[1][2], AREA[2][2] do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
	end
	s.set_tiles(tiles)
	local eei = place(s, fails, "electric-energy-interface", 0, -5)
	if eei then eei.power_production = 1e7 eei.electric_buffer_size = 1e8 end
	for _, x in ipairs({ 3, 20, 37 }) do place(s, fails, "substation", x, -5) end
	local ctrl = place(s, fails, "me-network-controller", 5, 0)
	if ctrl then ctrl.energy = 1e7 end
	for x = 4, 22 do place(s, fails, "me-cable", x + 0.5, 1.5) end
	local south = { direction = defines.direction.south }
	local k = place(s, fails, "constant-combinator", 10.5, 6.5)
	if k then emit(k, { { SIG.type, SIG.name, 1 }, { "item", "iron-plate", 7 } }) end
	--- the storage: a storage bus on a chest
	local S = place(s, fails, "me-storage-bus", 6.5, 2.5, south)
	local cs = place(s, fails, "steel-chest", 6.5, 3.5)
	if cs then
		cs.insert{ name = "iron-plate", count = 100 }
		cs.insert{ name = "stone", count = 100 }
		cs.insert{ name = "wood", count = 40 }
	end
	if S then remote.call(SB, "set_settings", S, { priority = 3, filters = {} }) end
	local I = place(s, fails, "me-import-bus", 8.5, 2.5, south)
	local ci = place(s, fails, "iron-chest", 8.5, 3.5)
	if ci then ci.insert{ name = "copper-plate", count = 50 } end
	local E1 = place(s, fails, "me-export-bus", 10.5, 2.5, south)
	place(s, fails, "iron-chest", 10.5, 3.5)
	local E2 = place(s, fails, "me-export-bus", 12.5, 2.5, south)
	place(s, fails, "iron-chest", 12.5, 3.5)
	for _, e in pairs({ E1, E2 }) do remote.call(IO, "set_bus_filters", e, { "iron-plate" }) end
	local F = place(s, fails, "me-network-interface", 14.5, 2.5)
	if F then remote.call(IO, "set_interface_circuit", F, true) end
	local P = place(s, fails, "me-pattern-provider", 16.5, 2.5)
	place(s, fails, "iron-chest", 16.5, 3.5)
	local P2 = place(s, fails, "me-pattern-provider", 18.5, 2.5)
	place(s, fails, "me-1k-crafting-storage", 20.5, 2.5)
	if P then
		local inv = game.create_inventory(2)
		inv.insert{ name = "me-blank-pattern", count = 1 }
		remote.call(PT, "encode_def", inv, nil, { kind = "processing", inputs = { { key = "stone", amount = 1 } },
			outputs = { { key = "pipe", amount = 1 } } })
		local stack = inv.find_item_stack("me-encoded-pattern")
		if not (stack and remote.call(AC, "insert_pattern", P, stack)) then fails[#fails + 1] = "the provider's pattern" end
		inv.destroy()
		remote.call(AC, "set_priority", P, 4)
		remote.call(AC, "set_blocking", P, "blocking")
	end
	if P2 then remote.call(AC, "set_lock", P2, "low") end
	local conns = 0
	if k and S and I and E1 and F and P2 then
		local made = {
			connector(S, k, nil), connector(I, k, { first_signal = SIG, comparator = ">", constant = 0 }),
			connector(E1, k, { first_signal = SIG, comparator = ">", constant = 5 }), connector(F, k, nil),
			connector(P2, k, { first_signal = SIG, comparator = ">", constant = 0 }) }
		for _, c in pairs(made) do if c then conns = conns + 1 end end
	end
	--- the old blueprint: a bus, its connector wired to a constant combinator, the condition
	local bp_chest = place(s, fails, "iron-chest", 30.5, -2.5)
	local B = place(s, fails, "me-import-bus", 30.5, 2.5, south)
	local k2 = place(s, fails, "constant-combinator", 30.5, 5.5)
	local bconn = B and k2 and connector(B, k2, { first_signal = SIG, comparator = ">", constant = 0 })
	local blueprint = false
	if bp_chest and bconn then
		bp_chest.insert{ name = "blueprint" }
		local bp = bp_chest.get_inventory(defines.inventory.chest)[1]
		bp.create_blueprint{ surface = s, force = "player", area = { { X + 29.6, Y + 1.6 }, { X + 31.4, Y + 6.4 } } }
		local n = 0
		for _, be in pairs(bp.get_blueprint_entities() or {}) do if be.name == "me-circuit-connector" then n = n + 1 end end
		blueprint = n == 1
		if not blueprint then fails[#fails + 1] = "the old blueprint holds " .. n .. " connectors" end
		for _, e in pairs({ B, k2, bconn }) do if e.valid then e.destroy() end end
		--- its ghosts on the map (no event: the old version does not revive the connector's ghost)
		bp.build_blueprint{ surface = s, force = "player", position = { X + 36, Y + 4 } }
	end
	local job, why
	if P and ctrl then job, why = remote.call(AC, "start", ctrl, "pipe", 20) end
	if not job then fails[#fails + 1] = "the job: " .. tostring(why) end
	storage.wired = { conns = conns, blueprint = blueprint, job = job }
	return fails, string.format("%d connectors, %s, job %s", conns, blueprint and "an old blueprint and its ghosts" or "no blueprint",
		tostring(job))
end

--- after the load (a phase: `st.wired.phase`)
function M.check(st)
	local w = storage.wired
	if not w then return true end
	local s = game.surfaces[1]
	local function at(name, x, y) return s.find_entity(name, { X + x, Y + y }) end
	local problems = w.problems or {}
	w.problems = problems
	local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
	local function wires(e) return e and e.get_wire_connector(RED, true).connection_count or -1 end
	local function cond(e) return e and remote.call(CONN, "condition", e) or {} end
	local ctrl = at("me-network-controller", 5, 0)
	local S, I, E1, E2 = at("me-storage-bus", 6.5, 2.5), at("me-import-bus", 8.5, 2.5), at("me-export-bus", 10.5, 2.5),
		at("me-export-bus", 12.5, 2.5)
	local F, P, P2 = at("me-network-interface", 14.5, 2.5), at("me-pattern-provider", 16.5, 2.5), at("me-pattern-provider", 18.5, 2.5)
	local k = at("constant-combinator", 10.5, 6.5)
	if not w.phase then
		local left = s.find_entities_filtered{ area = AREA, name = OLD_NAMES }
		local lghosts = s.find_entities_filtered{ area = AREA, ghost_name = OLD_NAMES }
		expect(#left == 0 and #lghosts == 0, "old blocks or connectors left: " .. #left .. ", ghosts " .. #lghosts)
		for _, e in pairs({ S, I, E1, E2, P, P2 }) do
			expect(e and e.type == "display-panel", "a wired block: " .. serpent.line(e and { e.name, e.type }))
		end
		expect(F and F.type == "container", "the interface is still a container")
		expect(I and I.direction == defines.direction.south and S and S.direction == defines.direction.south, "the directions")
		if not (ctrl and S and I and E1 and E2 and F and P and P2 and k) then
			expect(false, "blocks missing")
			w.phase = "done"
			return M.report(w)
		end
		for _, e in pairs({ S, I, E1, E2, F, P, P2 }) do
			expect(remote.call(NET, "same_network", ctrl, e), e.name .. " at " .. e.position.x .. " is in the network")
		end
		local conns = w.conns > 0
		if conns then
			for _, e in pairs({ S, I, E1, F, P2 }) do expect(wires(e) == 1, e.name .. " at " .. e.position.x .. ": wires " .. wires(e)) end
			expect(wires(E2) == 0 and wires(P) == 0, "the blocks without a connector have no wire")
			local ci, c1, cp = cond(I), cond(E1), cond(P2)
			expect(ci[1] == true and ci[2] and ci[2].comparator == ">" and ci[2].constant == 0, "I's condition: " .. serpent.line(ci))
			expect(c1[1] == true and c1[2] and c1[2].constant == 5, "E1's condition: " .. serpent.line(c1))
			expect(cp[1] == true and cp[2] and cp[2].first_signal and cp[2].first_signal.name == SIG.name, "P2's condition: " .. serpent.line(cp))
			expect(cond(S)[1] == false, "S has no condition")
			local cb = F.get_control_behavior()
			expect(cb and cb.read_contents == false, "the interface's contents are off its wire")
		end
		expect(remote.call(SB, "get_settings", S).priority == 3, "S's priority: " .. serpent.line(remote.call(SB, "get_settings", S)))
		expect(remote.call(AC, "get_priority", P) == 4 and remote.call(AC, "get_blocking", P) == "blocking", "P's priority and blocking")
		expect(remote.call(AC, "get_lock", P2) == "low", "P2's lock: " .. tostring(remote.call(AC, "get_lock", P2)))
		expect(table_size((remote.call(AC, "provider_info", P) or {}).patterns or {}) >= 1
			or ((remote.call(AC, "provider_info", P) or {}).filled or 0) >= 1, "P's pattern")
		local bus = remote.call(IO, "get_bus", E2)
		expect(bus and bus.filters and bus.filters[1] == "iron-plate", "E2's filter: " .. serpent.line(bus and bus.filters))
		if w.blueprint then
			--- the old ghosts: a ghost of the wired bus with the wire and the condition
			local g = s.find_entities_filtered{ area = AREA, ghost_name = "me-import-bus" }
			local tag = g[1] and g[1].tags and g[1].tags.fork_me_condition
			expect(#g == 1 and tag and tag.cc == true and wires(g[1]) == 1, "the old ghost: " .. #g .. " " .. serpent.line(tag)
				.. " wires " .. wires(g[1]))
			--- the old blueprint built now
			local chest = at("iron-chest", 30.5, -2.5)
			local bp = chest and chest.get_inventory(defines.inventory.chest)[1]
			expect(bp and bp.valid_for_read and bp.is_blueprint, "the old blueprint is in its chest")
			if bp and bp.valid_for_read then
				local names = {}
				for _, be in pairs(bp.get_blueprint_entities() or {}) do names[#names + 1] = be.name end
				w.bp_names = table.concat(names, ",")
				bp.build_blueprint{ surface = s, force = "player", position = { X + 44, Y + 4 }, raise_built = true }
			end
			--- (the build event replaced an old block's ghost: the ghosts are those on the place now)
			for _, gh in pairs(s.find_entities_filtered{ area = { { X + 42, Y }, { X + 47, Y + 8 } }, type = "entity-ghost" }) do
				if gh.valid then gh.revive{ raise_revive = true } end
			end
			local B = s.find_entities_filtered{ area = { { X + 43, Y }, { X + 46, Y + 8 } }, name = "me-import-bus" }[1]
			local cb = cond(B)
			expect(B and B.type == "display-panel" and wires(B) == 1 and cb[1] == true, "the old blueprint (" .. tostring(w.bp_names) .. ") built: "
				.. serpent.line(B and { B.type, wires(B), cb }))
			expect(#s.find_entities_filtered{ area = AREA, name = OLD_NAMES } == 0, "the old blueprint left an old block or connector")
		end
		w.copper, w.phase, w.tick = remote.call(NET, "count", ctrl, "copper-plate"), "work", game.tick
		return false
	end
	if w.phase == "work" then
		if game.tick < w.tick + 100 then return false end
		local function chest(x) local c = at("iron-chest", x, 3.5) return c and c.get_inventory(defines.inventory.chest) end
		expect(chest(8.5).get_item_count("copper-plate") == 0, "I imported: " .. chest(8.5).get_item_count("copper-plate") .. " left")
		expect(remote.call(NET, "count", ctrl, "copper-plate") == 50, "the copper plates are in the network")
		expect(remote.call(NET, "count", ctrl, "wood") == 40, "S's wood is counted: " .. remote.call(NET, "count", ctrl, "wood"))
		if w.conns > 0 then
			expect(remote.call(CONN, "is_off", E1) and chest(10.5).get_item_count("iron-plate") == 0, "E1 is off by its condition: "
				.. chest(10.5).get_item_count("iron-plate"))
			local have = F.get_inventory(defines.inventory.chest).get_item_count("iron-plate")
			expect(have == 7, "F keeps the 7 plates of its rows from the circuit: " .. have)
		end
		expect(chest(12.5).get_item_count("iron-plate") > 0, "E2 exported")
		local job = w.job and remote.call(AC, "job", w.job)
		expect(job and job.status ~= "failed", "the job still runs: " .. serpent.line(job and { job.status, job.wait }))
		expect(chest(16.5).get_item_count("stone") > 0, "the job hands stone into P's chest")
		w.phase = "done"
		return M.report(w)
	end
	return true
end

function M.report(w)
	for _, p in pairs(w.problems) do L("FAIL", "wired: " .. p) end
	L("WIRED", (#w.problems == 0 and "ok" or "failed") .. " (" .. (w.conns > 0 and w.conns .. " old connectors" or "no connectors")
		.. (w.blueprint and ", an old blueprint and its ghosts" or "") .. ": the wired blocks with their settings, wires, conditions"
		.. " and the running job)")
	return true
end

return M
