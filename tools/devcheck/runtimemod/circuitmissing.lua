--- Runtime test of me-network issue #809: the ME Circuit Interface's mode "Missing for crafting". A network with iron
--- sticks and no iron plates, a CPU, a provider with a molecular assembler and the gear pattern (1 iron plate and 2 sticks),
--- a level maintainer that keeps 10 gears (its start lacks 10 iron plates) and four circuit interfaces: A (the mode set
--- through its window's switch), B (the contents, as before), C (the mode with a filter), D (the target of the pastes):
---   * A sends 10 iron plates and nothing else, its window says "1 missing"; B sends the network's contents and no plates;
---     C sends nothing while its filter is another item and the plates once it names them; an update of an unchanged list
---     writes nothing;
---   * 4 plates into the network: A sends 6;
---   * a blueprint of A carries the mode in its tag and its copy has it, a blueprint of B has no mode in its tag; a settings
---     paste copies the mode both ways; a tag without a mode means the contents; a clone keeps the mode;
---   * a note of a missing fluid (30.5 water): one fluid signal, rounded up; a filter on plates keeps it out;
---   * the other 6 plates: the signal goes away, the window says nothing is missing; the switch back: the contents again.
--- The test spans the save at tick 500 (its state is in storage; the stand-in player lives within one tick).
--- Loaded by control.lua: require("circuitmissing")(H) returns { setup, tick, running }.

local NET, C38, GUI = "gregtorio-me-network", "gregtorio-me-circuit", "gregtorio-me-gui"
local BX, BY = -250, -60              -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 130
local GEAR, GEAR_RECIPE = "iron-gear-wheel", "iron-gear-crafting-table"   -- (1 iron plate and 2 sticks: the stand-in or Gregtorio's)
local CI = "me-circuit-interface"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local function line(t) return serpent.line(t) end

	function T.setup(s)
		local fails = {}
		local what = "circuit interface, missing for crafting"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-stick"] = 100 })
		local cpu = me_place(s, fails, what, "me-16k-crafting-storage", BX + 12.5, BY + 0.5)
		local p = me_place(s, fails, what, "me-pattern-provider", BX + 16.5, BY - 1.5)
		local m = me_place(s, fails, what, "me-molecular-assembler", BX + 16.5, BY - 2.5)
		if m then
			m.force.recipes[GEAR_RECIPE].enabled = true
			m.get_module_inventory().insert{ name = "me-acceleration-card", count = 5 }
		end
		local maint = me_place(s, fails, what, "me-level-maintainer", BX + 19.5, BY + 0.5)
		local members = { ctrl, drive, cpu, p, maint }
		for i = 0, 3 do members[#members + 1] = me_place(s, fails, what, CI, BX + 10.5 + 2 * i, BY + 2.5) end   -- A, B, C, D
		H.me_connect(fails, what, members)
		if p then give_patterns(p, { { kind = "crafting", recipe = GEAR_RECIPE } }, fails) end
		if maint then remote.call(C38, "set_maintainer", maint, GEAR, 10, false, 1, 0) end
		return fails
	end

	--- what a circuit interface sends: { ["item/<name>"] or ["fluid/<name>"] = amount } of its section
	local function out(e)
		local cb = e.get_control_behavior()
		local sec = cb and cb.sections_count > 0 and cb.get_section(1)
		local t = {}
		for _, f in pairs(sec and sec.filters or {}) do
			if f.value then t[(f.value.type or "item") .. "/" .. f.value.name] = f.min end
		end
		return t
	end

	--- the window of `e` opened for a stand-in player: the mode switch set to `state` (nil: left alone); returns the switch's
	--- state and the status line's caption
	local function window(e, state)
		local inv = game.create_inventory(1)
		remote.call(GUI, "stand_in", "missing809", { main = inv, index = 9809, gui = true })
		remote.call(GUI, "stand_in_open_entity", "missing809", e)
		local sw = remote.call(GUI, "stand_in_switch", "missing809", "circ_mode", state)
		local caption = remote.call(GUI, "stand_in_caption", "missing809", "fork_me_circ_status")
		remote.call(GUI, "stand_in_close_window", "missing809")
		remote.call(GUI, "stand_in_forget", "missing809")
		inv.destroy()
		return sw, caption
	end

	function T.tick()
		local st = storage.missing809
		if (st and st.done) or game.tick < START then return end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		if not st then
			st = { problems = {}, phase = "start", tick = game.tick }
			storage.missing809 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("CIRCUITMISSING", "ME Circuit Interface: missing for crafting", problems, "the window's switch; the need of a "
				.. "failed maintainer start as a signal, less as the material arrives and gone when it is there; the contents mode "
				.. "untouched; filters; nothing written for an unchanged list; blueprint tag, settings paste, a tag without a mode, "
				.. "clone; a fluid rounded up")
		end
		local function next_phase(name) st.phase, st.tick = name, game.tick end
		local ctrl = find("me-network-controller", 7, 0)
		local A, B, C, D = find(CI, 10.5, 2.5), find(CI, 12.5, 2.5), find(CI, 14.5, 2.5), find(CI, 16.5, 2.5)
		if not (ctrl and A and B and C and D) then
			expect(false, "entities missing")
			return finish()
		end
		local function mode(e) return (remote.call(C38, "get_circuit", e) or {}).mode end
		--- how long a phase waits for an interface (control.lua's circuit test: two rounds of the queue and an interval)
		local q = remote.call(C38, "queues")
		local limit = math.max(200, 2 * math.ceil(q.cq * 60 / math.max(q.rate, 1)) + q.interval)
		local a = out(A)
		local function late(extra, what)
			if game.tick <= st.tick + limit + (extra or 0) then return false end
			expect(false, what .. ": A sends " .. line(a) .. ", maintainer " .. line(remote.call(C38, "get_maintainer",
				find("me-level-maintainer", 19.5, 0.5)) or {}))
			finish()
			return true
		end

		if st.phase == "start" then
			expect(mode(A) == "contents", "a new interface's mode: " .. tostring(mode(A)))
			local before = window(A)
			local sw = window(A, "right")
			expect(before == "left" and sw == "right" and mode(A) == "missing", "the window's switch: " .. tostring(before) .. " -> "
				.. tostring(sw) .. ", mode " .. tostring(mode(A)))
			expect(remote.call(C38, "set_circuit_mode", C, "missing") and mode(C) == "missing", "set_circuit_mode on C")
			remote.call(C38, "set_circuit_filters", C, { "copper-plate" })
			return next_phase("lack")
		elseif st.phase == "lack" then
			--- (the maintainer's first start may come late: its network gets its power first; a failed start is tried every 300 ticks)
			if a["item/iron-plate"] ~= 10 then late(700, "the plates the maintainer's start lacks are not sent") return end
			local ga = remote.call(C38, "get_circuit", A)
			expect(table_size(a) == 1 and ga.signals == 1, "A sends more than the plates: " .. line(a) .. ", signals " .. tostring(ga.signals))
			local b = out(B)
			expect(mode(B) == "contents" and b["item/iron-stick"] == 100 and b["item/iron-plate"] == nil,
				"B (contents) sends " .. line(b) .. " in the mode " .. tostring(mode(B)))
			expect(table_size(out(C)) == 0, "C with a filter on copper sends " .. line(out(C)))
			remote.call(C38, "set_circuit_filters", C, { "iron-plate" })
			expect(out(C)["item/iron-plate"] == 10 and table_size(out(C)) == 1, "C with a filter on plates sends " .. line(out(C)))
			local _, caption = window(A)
			expect(type(caption) == "table" and caption[1] == "fork-me-circuit.circuit-missing" and tonumber(caption[2]) == 1,
				"A's status line: " .. line(caption))
			remote.call(C38, "last_write", A, true)
			remote.call(C38, "update", A)
			local w = remote.call(C38, "last_write", A)
			expect(w == nil, "an update of an unchanged list wrote " .. tostring(w))
			expect(remote.call(NET, "insert", ctrl, "iron-plate", 4) == 4, "4 plates into the network")
			return next_phase("partial")
		elseif st.phase == "partial" then
			if a["item/iron-plate"] ~= 6 then late(0, "4 of 10 plates there, 6 expected") return end
			--- blueprint: the tag carries the mode (and only then), the copy has it
			local copy, why, tags = H.blueprint_copy(A, 0, 4)
			local t = tags and tags.fork_me_circuit
			expect(copy and t and t.mode == "missing" and mode(copy) == "missing", "a blueprint of A: " .. tostring(why) .. ", tag "
				.. line(t) .. ", the copy's mode " .. tostring(copy and mode(copy)))
			if copy and copy.valid then copy.destroy{ raise_destroy = true } end
			copy, why, tags = H.blueprint_copy(B, 0, 4)
			t = tags and tags.fork_me_circuit
			expect(copy and t and t.mode == nil and mode(copy) == "contents", "a blueprint of B: " .. tostring(why) .. ", tag "
				.. line(t) .. ", the copy's mode " .. tostring(copy and mode(copy)))
			if copy and copy.valid then copy.destroy{ raise_destroy = true } end
			--- settings paste, both ways
			remote.call(C38, "paste", A, D)
			expect(mode(D) == "missing" and out(D)["item/iron-plate"] == 6 and table_size(out(D)) == 1, "a paste of A onto D: mode "
				.. tostring(mode(D)) .. ", sends " .. line(out(D)))
			remote.call(C38, "paste", B, D)
			expect(mode(D) == "contents" and out(D)["item/iron-stick"] == 100, "a paste of B onto D: mode " .. tostring(mode(D))
				.. ", sends " .. line(out(D)))
			--- a tag with the mode, and one of before (no mode: the contents)
			remote.call(C38, "built", D, { fork_me_circuit = { filters = {}, mode = "missing" } })
			expect(mode(D) == "missing", "a tag with the mode: " .. tostring(mode(D)))
			remote.call(C38, "built", D, { fork_me_circuit = { filters = { "iron-stick" } } })
			expect(mode(D) == "contents" and out(D)["item/iron-stick"] == 100 and table_size(out(D)) == 1,
				"a tag without a mode: " .. tostring(mode(D)) .. ", sends " .. line(out(D)))
			local clone = A.clone{ position = { BX + 14.5, BY + 6.5 } }
			expect(clone and mode(clone) == "missing", "a clone of A: " .. tostring(clone and mode(clone)))
			if clone and clone.valid then clone.destroy{ raise_destroy = true } end
			--- a fluid that a start lacked (a note as a Crafting Card or a maintainer makes it)
			remote.call(C38, "note_missing", A, "test809", { ["fluid/water"] = 30.5 }, game.tick + 3600)
			return next_phase("fluid")
		elseif st.phase == "fluid" then
			if a["fluid/water"] ~= 31 then late(0, "30.5 water noted, a signal of 31 expected") return end
			expect(a["item/iron-plate"] == 6 and table_size(a) == 2, "A with the fluid sends " .. line(a))
			local c = out(C)
			expect(c["item/iron-plate"] == 6 and table_size(c) == 1, "C (a filter on plates) with the fluid sends " .. line(c))
			remote.call(C38, "note_missing", A, "test809", nil)
			expect(remote.call(NET, "insert", ctrl, "iron-plate", 6) == 6, "6 plates into the network")
			return next_phase("gone")
		elseif st.phase == "gone" then
			--- (A and C each write at their own visit of the queue: both are waited for)
			if next(a) ~= nil or next(out(C)) ~= nil then
				late(0, "all plates there and the fluid's note gone, yet signals (C sends " .. line(out(C)) .. ")")
				return
			end
			local sw, caption = window(A)
			expect(sw == "right" and type(caption) == "table" and caption[1] == "fork-me-circuit.circuit-missing-none",
				"A's window with nothing missing: " .. tostring(sw) .. ", " .. line(caption))
			sw = window(A, "left")
			a = out(A)
			expect(sw == "left" and mode(A) == "contents" and (a["item/iron-stick"] or 0) > 0, "the switch back: " .. tostring(sw)
				.. ", mode " .. tostring(mode(A)) .. ", sends " .. line(a))
			return finish()
		end
	end

	function T.running(check) check(storage.missing809 and storage.missing809.done, "ME Circuit Interface: missing for crafting") end

	return T
end
