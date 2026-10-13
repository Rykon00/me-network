--- Runtime test of me-network issue #355: the ME Toggle Bus, the ME Inverted Toggle Bus and the ME Level Emitter.
--- Network A (controller, a drive with plates and sticks, a terminal, a 1k crafting storage, two level emitters) and part B (a
--- drive with copper plates, a pattern provider with an assembler for gears; no controller) are joined only through a toggle
--- bus T, wired to a constant combinator K (signal A):
---   * T without a condition is open: A sees no copper; K's signal with T's condition "A > 0" joins it: A sees the copper;
---   * a gear job (its machine on B's side) starts and T opens at once: A sees no copper, the job waits; T joins again: the job
---     ends, nothing is lost (plates and sticks against gears);
---   * an inverted toggle bus I joins network C's drive without a wire and opens with the condition;
---   * the level emitter E gives the green check while A holds at least 1000 plates and not with "below"; by stored energy;
---     an item of B's side gives nothing while T is open; a second emitter takes E's settings by paste and by tags.
--- Loaded by control.lua: require("togglebus")(H) returns { setup, tick, running }.

local NET, AC = "gregtorio-me-network", "gregtorio-me-autocraft"
local TG, EM = "gregtorio-me-toggle", "gregtorio-me-emitter"
local BX, BY = -150, -150             -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, TIMEOUT = 120, 1200
local GEAR, GEAR_RECIPE = "iron-gear-wheel", "iron-gear-crafting-table"
local PLATES, STICKS, COPPER, GEARS = 2000, 4000, 50, 30
local SIG = { type = "virtual", name = "signal-A" }

return function(H)
	local me_place, cable_row, power, me_report = H.me_place, H.cable_row, H.power, H.me_report
	local T = {}
	local function at(dx, dy) return { BX + dx + 0.5, BY + dy + 0.5 } end      -- the centre of tile (BX+dx, BY+dy)
	local function line(t) return serpent.line(t) end

	function T.setup(s)
		local fails = {}
		local what = "toggle buses"
		power(s, fails, what, BX, BY)
		power(s, fails, what, BX + 22, BY - 8)                                    -- the assembler on B's side
		me_place(s, fails, what, "me-network-controller", BX + 7, BY)             -- tiles 6..7, -1..0
		H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = PLATES, ["iron-stick"] = STICKS })
		me_place(s, fails, what, "me-terminal", BX + 9.5, BY - 0.5)
		cable_row(s, fails, BX + 10, BX + 12, BY - 1)
		me_place(s, fails, what, "me-1k-crafting-storage", BX + 11.5, BY + 0.5)
		me_place(s, fails, what, "me-level-emitter", BX + 12.5, BY - 1.5)
		me_place(s, fails, what, "me-level-emitter", BX + 10.5, BY - 1.5)
		me_place(s, fails, what, "me-toggle-bus", BX + 13.5, BY - 0.5)           -- tile 13, -1
		me_place(s, fails, what, "constant-combinator", BX + 13.5, BY + 1.5)
		cable_row(s, fails, BX + 14, BX + 20, BY - 1)
		H.me_drive(s, fails, what, BX + 19.5, BY - 1.5, { ["copper-plate"] = COPPER })
		me_place(s, fails, what, "me-pattern-provider", BX + 16.5, BY - 1.5)
		local m = me_place(s, fails, what, "me-molecular-assembler", BX + 16.5, BY - 2.5)
		if m then
			m.force.recipes[GEAR_RECIPE].enabled = true
			m.set_recipe(GEAR_RECIPE)
		end
		local p = s.find_entity("me-pattern-provider", at(16, -2))
		if p then give_patterns(p, { { kind = "crafting", recipe = GEAR_RECIPE } }, fails) end
		--- network C: a controller, a cable, the inverted toggle bus, a cable, a drive with copper
		power(s, fails, what, BX, BY + 12)
		me_place(s, fails, what, "me-network-controller", BX + 7, BY + 10)       -- tiles 6..7, 9..10
		cable_row(s, fails, BX + 8, BX + 9, BY + 9)
		me_place(s, fails, what, "me-inverted-toggle-bus", BX + 10.5, BY + 9.5)
		cable_row(s, fails, BX + 11, BX + 11, BY + 9)
		H.me_drive(s, fails, what, BX + 12.5, BY + 9.5, { ["copper-plate"] = 10 })
		me_place(s, fails, what, "constant-combinator", BX + 10.5, BY + 11.5)
		return fails
	end

	local function wire(a, b)
		local w = defines.wire_connector_id.circuit_red
		return a.get_wire_connector(w, true).connect_to(b.get_wire_connector(w, true), false)
	end

	local function emitting(e)
		local cb = e.get_control_behavior()
		local sec = cb and cb.get_section(1)
		local f = sec and sec.filters or {}
		return #f == 1 and f[1].value and f[1].value.name == "signal-check" and f[1].min == 1
	end

	function T.tick()
		local st = storage.togglebus355
		if (st and st.done) or game.tick < START then return end
		local s = game.surfaces[1]
		local function find(name, dx, dy) return s.find_entity(name, at(dx, dy)) end
		if not st then
			st = { problems = {}, phase = "start" }
			storage.togglebus355 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("TOGGLE", "ME Toggle Bus and Level Emitter", problems, "open without a condition, joined by the "
				.. "condition, a job waits across a split and ends after the join, nothing lost, the inverted bus, the level "
				.. "emitter by amount, mode, energy and an open toggle bus, paste and tags")
		end
		local t, tb = find("me-terminal", 9, -1), find("me-toggle-bus", 13, -1)
		local k, e1, e2 = find("constant-combinator", 13, 1), find("me-level-emitter", 12, -2), find("me-level-emitter", 10, -2)
		local cc, ib, kc = find("me-network-controller", 6, 9), find("me-inverted-toggle-bus", 10, 9), find("constant-combinator", 10, 11)
		if not (t and tb and k and e1 and e2 and cc and ib and kc) then expect(false, "entities missing") return finish() end
		local function count(name) return remote.call(NET, "count", t, name) end
		local function joined(b) return (remote.call(TG, "get", b) or {}).joined end
		local function job(id) return remote.call(AC, "job", id) or {} end
		local function conserved(what)
			local gears = count(GEAR)
			expect(count("iron-plate") + gears == PLATES and count("iron-stick") + 2 * gears == STICKS,
				what .. ": plates " .. count("iron-plate") .. ", sticks " .. count("iron-stick") .. ", gears " .. gears)
		end
		local function signal(comb, on)
			local cb = comb.get_or_create_control_behavior()
			if cb.sections_count == 0 then cb.add_section() end
			cb.get_section(1).set_slot(1, { value = { type = SIG.type, name = SIG.name, quality = "normal" }, min = 1 })
			cb.enabled = on
		end
		local function condition(b)
			local cb = b.get_or_create_control_behavior()
			cb.circuit_enable_disable = true
			cb.circuit_condition = { first_signal = SIG, comparator = ">", constant = 0 }
		end

		if st.phase == "start" then
			expect(joined(tb) == false and count("copper-plate") == 0, "T without a condition is open: " .. line({ joined(tb), count("copper-plate") }))
			expect(joined(ib) == true and remote.call(NET, "count", cc, "copper-plate") == 10, "I without a wire joins: "
				.. line({ joined(ib), remote.call(NET, "count", cc, "copper-plate") }))
			expect(remote.call(NET, "count", t, "iron-plate") == PLATES, "A holds its plates")
			--- the level emitter: plates at or above 1000, below, by energy, an item behind the open T
			remote.call(EM, "set", e1, { key = "iron-plate", amount = 1000, mode = "high" })
			expect(emitting(e1) and (remote.call(EM, "get", e1) or {}).level == PLATES, "E emits at 2000 >= 1000: " .. line(remote.call(EM, "get", e1)))
			remote.call(EM, "set", e1, { mode = "low" })
			expect(not emitting(e1), "E with below does not emit at 2000")
			remote.call(EM, "set", e1, { energy = true, amount = 1, mode = "high" })
			expect(emitting(e1), "E by stored energy (at least 1 J): " .. line(remote.call(EM, "get", e1)))
			remote.call(EM, "set", e1, { energy = false, key = "copper-plate", amount = 1 })
			expect(not emitting(e1), "E for copper behind the open T does not emit")
			--- paste and tags carry the settings
			remote.call(EM, "paste", e1, e2)
			local g2 = remote.call(EM, "get", e2) or {}
			expect(g2.key == "copper-plate" and g2.amount == 1 and g2.mode == "high", "paste: " .. line(g2))
			remote.call(EM, "built", e2, { fork_me_emitter = { key = "iron-plate", amount = 5, mode = "low", signal = { type = "virtual", name = "signal-B" } } })
			g2 = remote.call(EM, "get", e2) or {}
			expect(g2.key == "iron-plate" and g2.amount == 5 and g2.mode == "low" and g2.signal.name == "signal-B", "tags: " .. line(g2))
			--- T gets its condition and K's signal; I gets K's signal and its condition (it opens)
			wire(tb, k)
			signal(k, true)
			condition(tb)
			wire(ib, kc)
			signal(kc, true)
			condition(ib)
			st.phase, st.tick = "join", game.tick
			return
		end

		if st.phase == "join" then
			if not (joined(tb) and joined(ib) == false) then
				if game.tick > st.tick + 120 then expect(false, "T did not join or I did not open: " .. line({ joined(tb), joined(ib) })) return finish() end
				return
			end
			expect(count("copper-plate") == COPPER, "joined, A sees B's copper: " .. count("copper-plate"))
			expect(remote.call(NET, "count", cc, "copper-plate") == 0, "I open, C sees no copper")
			remote.call(EM, "visit", e1)
			expect(emitting(e1), "E for copper emits once T joined")
			local id, why = remote.call(AC, "start", t, GEAR, GEARS)
			expect(id ~= nil, "the gear job did not start: " .. tostring(why))
			if not id then return finish() end
			signal(k, false)                                                  -- T opens at once
			st.job, st.phase, st.tick = id, "split", game.tick
			return
		end

		if st.phase == "split" then
			if joined(tb) then
				if game.tick > st.tick + 120 then expect(false, "T did not open") return finish() end
				return
			end
			if not st.opened then
				st.opened = game.tick
				expect(count("copper-plate") == 0, "open again, A sees no copper: " .. count("copper-plate"))
				remote.call(EM, "visit", e1)
				expect(not emitting(e1), "E for copper stops once T opened")
			end
			if game.tick < st.opened + 180 then return end
			local j = job(st.job)
			expect(j.status ~= "failed" and j.status ~= "cancelled", "the job across the split: " .. line({ j.status }))
			expect(count(GEAR) < GEARS, "the job ended without its machine: " .. count(GEAR))
			signal(k, true)                                                   -- T joins again
			st.phase, st.tick = "rejoin", game.tick
			return
		end

		if st.phase == "rejoin" then
			local j = job(st.job)
			if j.status ~= "done" then
				if j.status == "failed" or j.status == "cancelled" or game.tick > st.tick + TIMEOUT then
					expect(false, "the job after the join: " .. line({ j.status, joined(tb), count(GEAR) }))
					return finish()
				end
				return
			end
			expect(joined(tb), "T joined again")
			expect(count(GEAR) == GEARS, "gears after the join: " .. count(GEAR))
			conserved("after the job")
			return finish()
		end
	end

	function T.running(check) check(storage.togglebus355 and storage.togglebus355.done, "ME Toggle Bus and Level Emitter") end

	return T
end
