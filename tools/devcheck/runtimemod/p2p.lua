--- Runtime test of me-network issue #629: ME P2P tunnels, a pattern provider serving the machines their outputs face.
--- One network: a controller, an item drive (iron plates), a fluid drive (water), a CPU, a provider with three crafting
--- patterns (zz-devcheck-p2p-a: an iron plate, -b: water, -c: both; data.lua) and two input tunnels facing it, an item one
--- (west) and a fluid one (north). Three machines (zz-devcheck-p2p-machine, no recipe set) far from it, each with output
--- tunnels on its north side: M1 an item and a fluid output, M2 an item output, M3 a fluid output.
---   * Binding: the item frequency by the ME Memory Card's path (select the input, alt-select M2's output) and settings paste
---     (onto M1's), the fluid frequency by the window's path (a number, input and output). Each tunnel's window says its role.
---   * The scan: pattern a reaches M1 and M2 (M3 only through a fluid tunnel: "tunnel-items"), b M1 and M3, c M1 alone.
---   * Jobs: a's spread over M1 and M2, b's over M1 and M3, c's on M1; the products arrive.
---   * A frequency changed (M1's item output on another): a reaches M2 alone; back.
---   * An output removed while a job runs on its machine: the job ends done, nothing lost (the network lost exactly the
---     plates of the products it got, the machine is empty), the provider no longer reaches that machine.
---   * Kept: a blueprint copy of an output (frequency and role), of the input (the copy waits: "taken"), a clone.
---   * Issue #650, the reason of a mixed recipe: a second provider in the network, its item input tunnel bound first (to two
---     machines of the scene's category, M4 and M5), its fluid input to a stand-in chemical plant (M6, zz-devcheck-p2p-chem).
---     The pattern zz-devcheck-p2p-mixed (an iron plate and water, the chemical plant's only) reaches none of them; the reason
---     is M6's, the one machine that could craft it: "tunnel-items", not the assemblers' "tunnel-fluids".
---   * Task-Ingame #656: at the end an item output of that provider's item frequency is bound onto M6 as well: the pattern is
---     ok (one machine) and a job of it runs on M6 (the iron plates through the item tunnel, the water through the fluid one).
--- The scene runs through the save and load of the save-and-load run.
--- Loaded by control.lua: require("p2p")(H) returns { setup, tick, running }.

local NET, AC, P2P, MC, GUI = "gregtorio-me-network", "gregtorio-me-autocraft", "gregtorio-me-p2p", "gregtorio-me-memorycard",
	"gregtorio-me-gui"
local BX, BY = -880, -300
local START, LAST = 160, 1420
local PLATES, WATER = 400, 20000
local N_A, N_B, N_C, N_RM = 34, 4, 2, 24                 -- (a: more than two hand-overs of 16, so both machines get work)
local FLUID_FREQ, OTHER_FREQ = 7000, 7001
local MIX_ITEM_FREQ, MIX_FLUID_FREQ = 7010, 7011          -- (issue #650)
local N_MIX = 3                                           -- (Task-Ingame #656)
local MACHINE = "zz-devcheck-p2p-machine"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "p2p tunnels"
		for x = BX - 6, BX + 40, 32 do                            -- (the chunks under the scene and its copies exist)
			for y = BY - 6, BY + 40, 32 do s.request_to_generate_chunks({ x, y }, 0) end
		end
		s.force_generate_chunk_requests()
		local tiles = {}
		for x = BX - 6, BX + 40 do
			for y = BY - 6, BY + 40 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = PLATES }, "16k")
		local fdrive = H.me_drive(s, fails, what, BX + 9.5, BY - 0.5, {}, "16k", true)
		local cpu = place_cpu(s, fails, what, BX + 12, BY)
		local south, east = { direction = defines.direction.south }, { direction = defines.direction.east }
		local sc = { ctrl = ctrl, fdrive = fdrive }
		sc.provider = me_place(s, fails, what, "me-pattern-provider", BX + 0.5, BY + 10.5)
		sc.in_item = me_place(s, fails, what, "me-item-p2p-tunnel", BX - 0.5, BY + 10.5, east)      -- (faces the provider)
		sc.in_fluid = me_place(s, fails, what, "me-fluid-p2p-tunnel", BX + 0.5, BY + 9.5, south)
		sc.m, sc.out = {}, {}
		for i = 1, 3 do
			local cx = BX + 16.5 + 5 * i                                            -- (3x3: tiles cx - 1.5 .. cx + 1.5)
			sc.m[i] = me_place(s, fails, what, MACHINE, cx, BY + 10.5)
		end
		local o = sc.out
		o.item1 = me_place(s, fails, what, "me-item-p2p-tunnel", BX + 20.5, BY + 8.5, south)
		o.fluid1 = me_place(s, fails, what, "me-fluid-p2p-tunnel", BX + 21.5, BY + 8.5, south)
		o.item2 = me_place(s, fails, what, "me-item-p2p-tunnel", BX + 26.5, BY + 8.5, south)
		o.fluid3 = me_place(s, fails, what, "me-fluid-p2p-tunnel", BX + 31.5, BY + 8.5, south)
		--- issue #650: the second provider, its item input (bound first) to M4 and M5, its fluid input to M6 (a chemical plant)
		local MY = BY + 18
		sc.mix = me_place(s, fails, what, "me-pattern-provider", BX + 0.5, MY + 0.5)
		sc.mix_item = me_place(s, fails, what, "me-item-p2p-tunnel", BX - 0.5, MY + 0.5, east)
		sc.mix_fluid = me_place(s, fails, what, "me-fluid-p2p-tunnel", BX + 0.5, MY - 0.5, south)
		sc.mm = {}
		for i = 1, 3 do
			sc.mm[i] = me_place(s, fails, what, i < 3 and MACHINE or "zz-devcheck-p2p-chem", BX + 21.5 + 5 * i, MY + 0.5)
		end
		sc.mo = { me_place(s, fails, what, "me-item-p2p-tunnel", BX + 26.5, MY - 1.5, south),
			me_place(s, fails, what, "me-item-p2p-tunnel", BX + 31.5, MY - 1.5, south),
			me_place(s, fails, what, "me-fluid-p2p-tunnel", BX + 36.5, MY - 1.5, south),
			me_place(s, fails, what, "me-item-p2p-tunnel", BX + 35.5, MY - 1.5, south) }    -- (Task-Ingame #656: unbound until the end)
		H.me_connect(fails, what, { ctrl, drive, fdrive, cpu, sc.provider, sc.in_item, sc.in_fluid, o.item1, o.fluid1, o.item2, o.fluid3,
			sc.mix, sc.mix_item, sc.mix_fluid, sc.mo[1], sc.mo[2], sc.mo[3], sc.mo[4] })
		storage.p2p629_scene = sc
		return fails
	end

	local function info(e) return e and e.valid and remote.call(P2P, "info", e) or {} end
	local function slot(sc, i) return ((remote.call(AC, "provider_info", sc.provider) or {}).slots or {})[i] or {} end
	local function count(sc, name) return remote.call(NET, "count", sc.ctrl, name) end
	local function machine_has(m, recipe)
		local r = m.valid and m.get_recipe()
		return r and r.name == recipe
	end

	function T.tick()
		local tick = game.tick
		local st = storage.p2p629
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false, phase = 0 }
			storage.p2p629 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			st.done = true
			me_report("P2P", "ME P2P tunnels with a pattern provider (issue #629)", problems, note)
		end
		local sc = storage.p2p629_scene
		local ok = sc and sc.ctrl and sc.ctrl.valid and sc.provider and sc.provider.valid and sc.in_item and sc.in_item.valid
			and sc.in_fluid and sc.in_fluid.valid
		for name, e in pairs(sc and sc.out or {}) do ok = ok and (e.valid or (name == "item2" and st.removed_unit ~= nil)) end
		for i = 1, 3 do ok = ok and sc.m[i] and sc.m[i].valid end
		if not ok then
			expect(false, "the scene is missing")
			return finish()
		end
		local o = sc.out
		local late = tick >= LAST

		if st.phase == 0 then
			--- the water, the patterns, the frequencies
			local w = remote.call(NET, "insert_fluid", sc.ctrl, "water", WATER)
			expect(math.abs(w - WATER) < 1e-6, "the network took " .. tostring(w) .. " water")
			local n = give_patterns(sc.provider, { { kind = "crafting", recipe = "zz-devcheck-p2p-a" },
				{ kind = "crafting", recipe = "zz-devcheck-p2p-b" }, { kind = "crafting", recipe = "zz-devcheck-p2p-c" } }, problems)
			expect(n == 3, "the provider took " .. n .. " patterns")
			local inv = game.create_inventory(1)
			inv[1].set_stack{ name = "me-memory-card" }
			local copied = remote.call(MC, "copy", inv[1], { sc.in_item }, nil)
			expect(copied == sc.in_item.unit_number, "the card copied the item input: " .. tostring(copied))
			local pasted = remote.call(MC, "paste", inv[1], { o.item2, sc.in_item }, nil)
			expect(pasted == 2, "the card pasted onto " .. tostring(pasted) .. " tunnels")
			inv.destroy()
			local fi = info(sc.in_item)
			expect(fi.freq and fi.freq > 0 and fi.output == false, "the item input: " .. serpent.line(fi))
			expect(remote.call(P2P, "paste", sc.in_item, o.item1), "settings paste onto M1's item output")
			expect(not remote.call(P2P, "paste", sc.in_item, o.fluid1), "settings paste between the kinds is refused")
			expect(remote.call(P2P, "set", sc.in_fluid, FLUID_FREQ, false), "the fluid input's frequency")
			expect(remote.call(P2P, "set", o.fluid1, FLUID_FREQ, true) and remote.call(P2P, "set", o.fluid3, FLUID_FREQ, true),
				"the fluid outputs' frequency")
			st.fi = fi.freq
			--- issue #650: the item input of the second provider first, then its fluid input
			local mixed = sc.mix and sc.mix.valid and sc.mix_item and sc.mix_item.valid and sc.mix_fluid and sc.mix_fluid.valid
			expect(mixed, "the scene of the mixed recipe is missing")
			if mixed then
				expect(give_patterns(sc.mix, { { kind = "crafting", recipe = "zz-devcheck-p2p-mixed" } }, problems) == 1,
					"the second provider took the mixed pattern")
				expect(remote.call(P2P, "set", sc.mix_item, MIX_ITEM_FREQ, false) and remote.call(P2P, "set", sc.mo[1], MIX_ITEM_FREQ, true)
					and remote.call(P2P, "set", sc.mo[2], MIX_ITEM_FREQ, true), "the second provider's item frequency")
				expect(remote.call(P2P, "set", sc.mix_fluid, MIX_FLUID_FREQ, false) and remote.call(P2P, "set", sc.mo[3], MIX_FLUID_FREQ, true),
					"the second provider's fluid frequency")
			end
			st.phase, st.at = 1, tick
			return
		end

		if st.phase == 1 then
			if tick < st.at + 5 then return end
			for name, e in pairs({ item1 = o.item1, item2 = o.item2 }) do
				local d = info(e)
				expect(d.freq == st.fi and d.output == true and d.status == "output", name .. ": " .. serpent.line(d))
			end
			local d = info(sc.in_item)
			expect(d.status == "input" and d.outputs == 2 and d.bound == 2, "the item input: " .. serpent.line(d))
			d = info(sc.in_fluid)
			expect(d.status == "input" and d.outputs == 2, "the fluid input: " .. serpent.line(d))
			local v = remote.call(GUI, "p2p_view", sc.in_item)
			expect(v.ok and v.role == "left" and v.text == tostring(st.fi) and type(v.status) == "table"
				and v.status[1] == "fork-me-gui.p2p-status-input", "the input's window: " .. serpent.line(v))
			v = remote.call(GUI, "p2p_view", o.fluid3)
			expect(v.ok and v.role == "right" and v.text == tostring(FLUID_FREQ) and v.status[1] == "fork-me-gui.p2p-status-output",
				"an output's window: " .. serpent.line(v))
			local reach = remote.call(P2P, "targets", sc.provider)
			expect(#reach == 4, "the provider reaches " .. #reach .. " machines through tunnels (4: M1 twice, M2, M3)")
			local a, b, c = slot(sc, 1), slot(sc, 2), slot(sc, 3)
			expect(a.ok and a.machines == 2, "pattern a (items): " .. serpent.line(a))
			expect(b.ok and b.machines == 2, "pattern b (water): " .. serpent.line(b))
			expect(c.ok and c.machines == 1, "pattern c (both): " .. serpent.line(c))
			--- issue #650: the reason names the tunnel that the chemical plant lacks
			if sc.mix and sc.mix.valid then
				local reach2 = remote.call(P2P, "targets", sc.mix)
				expect(#reach2 == 3, "the second provider reaches " .. #reach2 .. " machines through tunnels (3: M4, M5, M6)")
				local mx = ((remote.call(AC, "provider_info", sc.mix) or {}).slots or {})[1] or {}
				expect(not mx.ok and mx.reason == "tunnel-items", "the mixed pattern: " .. serpent.line(mx)
					.. " (expected tunnel-items: the chemical plant, the only machine of its category, has no item tunnel)")
			end
			st.a0 = count(sc, "zz-devcheck-p2p-a")
			local id, why = remote.call(AC, "start", sc.ctrl, "zz-devcheck-p2p-a", N_A)
			expect(id ~= nil, "the job of a: " .. tostring(why))
			if not id then return finish() end
			st.job, st.phase, st.at = id, 2, tick
			return
		end

		local function job_done(next_phase, what)
			local j = remote.call(AC, "job", st.job)
			if j and j.status ~= "done" and j.status ~= "failed" and j.status ~= "cancelled" and not late then return false end
			expect(j == nil or j.status == "done", what .. ": " .. serpent.line(j and { j.status, j.wait, j.reason }))
			st.phase, st.at = next_phase, tick
			return true
		end

		if st.phase == 2 then
			if not job_done(3, "the job of a") then return end
			expect(count(sc, "zz-devcheck-p2p-a") == st.a0 + N_A, "a: " .. count(sc, "zz-devcheck-p2p-a") - st.a0 .. " of " .. N_A)
			local m1, m2 = sc.m[1].products_finished, sc.m[2].products_finished
			expect(m1 > 0 and m2 > 0 and m1 + m2 == N_A, "a was spread over M1 and M2: " .. m1 .. " + " .. m2)
			expect(sc.m[3].products_finished == 0, "M3 (fluid tunnel only) made " .. sc.m[3].products_finished .. " of a")
			st.made = { m1, m2, 0 }
			st.b0 = count(sc, "zz-devcheck-p2p-b")
			local id, why = remote.call(AC, "start", sc.ctrl, "zz-devcheck-p2p-b", N_B)
			expect(id ~= nil, "the job of b: " .. tostring(why))
			if not id then return finish() end
			st.job = id
			return
		end

		if st.phase == 3 then
			if not job_done(4, "the job of b") then return end
			expect(count(sc, "zz-devcheck-p2p-b") == st.b0 + N_B, "b: " .. count(sc, "zz-devcheck-p2p-b") - st.b0 .. " of " .. N_B)
			local m1 = sc.m[1].products_finished - st.made[1]
			local m3 = sc.m[3].products_finished
			expect(m1 + m3 == N_B and sc.m[2].products_finished == st.made[2], "b on M1 and M3: " .. m1 .. " + " .. m3
				.. ", M2 " .. sc.m[2].products_finished - st.made[2])
			st.made = { sc.m[1].products_finished, sc.m[2].products_finished, m3 }
			st.c0 = count(sc, "zz-devcheck-p2p-c")
			local id, why = remote.call(AC, "start", sc.ctrl, "zz-devcheck-p2p-c", N_C)
			expect(id ~= nil, "the job of c: " .. tostring(why))
			if not id then return finish() end
			st.job = id
			return
		end

		if st.phase == 4 then
			if not job_done(5, "the job of c") then return end
			expect(count(sc, "zz-devcheck-p2p-c") == st.c0 + N_C, "c: " .. count(sc, "zz-devcheck-p2p-c") - st.c0 .. " of " .. N_C)
			expect(sc.m[1].products_finished - st.made[1] == N_C, "c on M1: " .. sc.m[1].products_finished - st.made[1])
			--- a frequency changed: M1's item output on another one; a reaches M2 alone
			expect(remote.call(P2P, "set", o.item1, OTHER_FREQ, true), "M1's item output on another frequency")
			return
		end

		if st.phase == 5 then
			if tick < st.at + 3 then return end
			if not st.moved then
				st.moved = true
				local a = slot(sc, 1)
				expect(a.ok and a.machines == 1, "pattern a after the frequency change: " .. serpent.line(a))
				expect(info(o.item1).status == "no-input", "M1's item output: " .. serpent.line(info(o.item1)))
				expect(remote.call(P2P, "bind_output", o.item1, st.fi), "M1's item output back")
				st.at = tick
				return
			end
			local a = slot(sc, 1)
			expect(a.ok and a.machines == 2, "pattern a back: " .. serpent.line(a))
			--- an output removed while a job runs on its machine
			st.plates, st.a1 = count(sc, "iron-plate"), count(sc, "zz-devcheck-p2p-a")
			local id, why = remote.call(AC, "start", sc.ctrl, "zz-devcheck-p2p-a", N_RM)
			expect(id ~= nil, "the job of a (removal): " .. tostring(why))
			if not id then return finish() end
			st.job, st.phase, st.at = id, 6, tick
			return
		end

		if st.phase == 6 then
			local m2 = sc.m[2]
			local busy = machine_has(m2, "zz-devcheck-p2p-a") and (m2.is_crafting() or m2.get_item_count("iron-plate") > 0)
			if not busy and not late and tick < st.at + 300 then return end
			expect(busy, "M2 never got work of the removal job")
			st.removed_unit = m2.unit_number
			o.item2.destroy{ raise_destroy = true }
			st.phase, st.at = 7, tick
			return
		end

		if st.phase == 7 then
			if not job_done(8, "the job of a with M2's output removed") then return end
			local got = count(sc, "zz-devcheck-p2p-a") - st.a1
			local used = st.plates - count(sc, "iron-plate")
			expect(got == N_RM, "a after the removal: " .. got .. " of " .. N_RM)
			expect(used == got, "nothing lost: the network gave " .. used .. " plates for " .. got .. " products")
			local m2 = sc.m[2]
			expect(m2.get_item_count() == 0 and not m2.is_crafting(), "M2 is empty: " .. m2.get_item_count() .. " items")
			for _, unit in ipairs(remote.call(P2P, "targets", sc.provider)) do
				expect(unit ~= st.removed_unit, "the provider still reaches M2")
			end
			local a = slot(sc, 1)
			expect(a.ok and a.machines == 1, "pattern a after the removal: " .. serpent.line(a))
			--- kept: blueprint copies of an output and of the input, a clone
			local copy, why, tags = H.blueprint_copy(o.fluid3, 0, 25)                -- (below the cables' area)
			local t = tags and tags.fork_me_p2p
			expect(type(t) == "table" and t.freq == FLUID_FREQ and t.output == true, "the output's blueprint tag: " .. serpent.line(tags))
			local d = info(copy)
			expect(copy and d.freq == FLUID_FREQ and d.output == true, "the output's copy: " .. tostring(why) .. " " .. serpent.line(d))
			if copy then copy.destroy{ raise_destroy = true } end
			copy, why = H.blueprint_copy(sc.in_fluid, 0, 25)
			d = info(copy)
			expect(copy and d.freq == FLUID_FREQ and d.output == false and d.status == "taken",
				"the input's copy waits: " .. tostring(why) .. " " .. serpent.line(d))
			if copy then copy.destroy{ raise_destroy = true } end
			expect(info(sc.in_fluid).status == "input", "the fluid input still holds its frequency: " .. serpent.line(info(sc.in_fluid)))
			local clone = o.fluid1.clone{ position = { o.fluid1.position.x, o.fluid1.position.y + 26 } }
			d = info(clone)
			expect(clone and d.freq == FLUID_FREQ and d.output == true, "the clone: " .. serpent.line(d))
			if clone then clone.destroy{ raise_destroy = true } end
			--- Task-Ingame #656: an item output of the second provider's item frequency onto the chemical plant M6 as well
			local mo4 = sc.mo[4]
			expect(mo4 and mo4.valid and remote.call(P2P, "set", mo4, MIX_ITEM_FREQ, true), "M6's item output on the second provider's frequency")
			st.phase, st.at = 8, tick
			return
		end

		if st.phase == 8 then
			if tick < st.at + 5 then return end
			local mx = ((remote.call(AC, "provider_info", sc.mix) or {}).slots or {})[1] or {}
			expect(mx.ok and mx.machines == 1, "the mixed pattern with M6's item tunnel: " .. serpent.line(mx))
			st.x0 = count(sc, "zz-devcheck-p2p-mixed")
			local id, why = remote.call(AC, "start", sc.ctrl, "zz-devcheck-p2p-mixed", N_MIX)
			expect(id ~= nil, "the job of the mixed recipe: " .. tostring(why))
			if not id then return finish() end
			st.job, st.phase, st.at = id, 9, tick
			return
		end

		if st.phase == 9 then
			if not job_done(10, "the job of the mixed recipe") then return end
			local got = count(sc, "zz-devcheck-p2p-mixed") - st.x0
			local m6 = sc.mm[3]
			expect(got == N_MIX and m6.valid and m6.products_finished == N_MIX, "the mixed recipe: " .. got .. " of " .. N_MIX
				.. ", M6 made " .. tostring(m6.valid and m6.products_finished))
			return finish(N_A .. " + " .. N_B .. " + " .. N_C .. " + " .. N_RM .. " + " .. N_MIX .. " crafts through tunnels (tick " .. tick .. ")")
		end
	end

	function T.running(check)
		if storage.p2p629_scene and not (storage.p2p629 and storage.p2p629.done) then check("P2P") end
	end

	return T
end
