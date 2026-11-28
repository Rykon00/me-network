--- Runtime test of me-network issue #815: recipes with more than a stack of an ingredient or of a product. A crafting
--- machine's input slot takes max(stack size, amount x the engine's overload multiplier) from a script and delivers a craft
--- whole, also above a stack; until the issue a pattern with more than a stack of an ingredient was red ("stack") and the
--- hand-overs were sized by floor(stack / amount), which is 0. One network with five pattern providers, each with its
--- target (runtimemod's data-final-fixes recipes, half a second and a second in an assembling machine 3):
--- * A, a crafting pattern: 250 iron plates + 150 copper plates -> 1 gear (ingredients above a stack); its second pattern,
---   2 modular armors -> 1 wooden chest, stays "stack": an item that does not stack (LuaItemPrototype.stackable) never fits twice;
--- * B, a processing pattern that names its recipe: 1 gear -> 250 iron sticks (a product above a stack);
--- * C, a processing pattern that names its recipe: 300 iron sticks -> 1 copper cable (an ingredient above a stack);
--- * D, the crafting pattern of the vanilla nuclear reactor (500 of each of four items), its machine with four speed
---   modules 3;
--- * E, a processing pattern into a chest: 150 copper plates -> 1 iron chest (the chest never had the limit in its
---   pattern check, but its hand-over had: no run was ever handed out).
--- One job of CABLES copper cables runs over C, B and A (5, 6 and 6 runs: several hand-overs each), one of REACTORS nuclear
--- reactors over D, one of two iron chests over E (the test puts the chests into the network when the plates lie in the
--- chest). Checked: no pattern but the armor's is refused; machine A held two crafts' worth of plates at once, more than a
--- stack; the cable job is not stepped more often than every ten ticks on average (no early step for a craft that takes
--- longer than a step); every job ends, every count is exact and nothing is left in a machine. (B also showed that a
--- processing top-up must count the craft in progress: with one run more than its output slot takes the job never ended.)
--- Without the recipes (another mod took the vanilla machine, items or categories): nothing to check; without the vanilla
--- reactor recipe as it is (four item ingredients for an assembling machine 3): that part is left out.
--- Loaded by control.lua: require("overstack")(H) returns { setup, tick, running }.

local NET, AC = "gregtorio-me-network", "gregtorio-me-autocraft"
local BX, BY = 880, -100
local START, TIMEOUT = 150, 1150
local IN, OUT, PROC, ARMOR = "zz-devcheck-815-in", "zz-devcheck-815-out", "zz-devcheck-815-proc", "zz-devcheck-815-armor"
local REACTOR = "nuclear-reactor"
local CABLES, REACTORS = 5, 5
local STICKS, PLATES_IRON, PLATES_COPPER, CHEST_COPPER = 300, 250, 150, 150
local RUNS = CABLES * STICKS / 250                       -- the runs of B and of A

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	local function usable()
		return prototypes.recipe[IN] and prototypes.recipe[OUT] and prototypes.recipe[PROC]
			and prototypes.entity["assembling-machine-3"] and prototypes.entity["steel-chest"] and true
	end

	--- the vanilla reactor recipe's ingredients when an assembling machine 3 makes it from items alone, one of them above a stack
	local function reactor_parts()
		local r, m = prototypes.recipe[REACTOR], prototypes.entity["assembling-machine-3"]
		if not (r and m and prototypes.item[REACTOR]) or script.active_mods["gregtorio-continued"] then return nil end
		local fits = false
		for k, v in pairs(r.categories or {}) do                 -- (a list of names or a set of them)
			if m.crafting_categories[type(k) == "string" and k or v] then fits = true end
		end
		if not fits then return nil end
		local parts, above = {}, false
		for _, i in pairs(r.ingredients) do
			if i.type ~= "item" then return nil end
			parts[i.name] = i.amount
			if i.amount > prototypes.item[i.name].stack_size then above = true end
		end
		return above and parts or nil
	end

	function T.setup(s)
		local fails = {}
		local what = "overstack"
		if not usable() then return fails end
		local tiles = {}
		for x = BX - 4, BX + 44 do
			for y = BY - 8, BY + 14 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		me_place(s, fails, what, "substation", BX + 10, BY + 9)             -- (in wire reach of the source and of the next one)
		me_place(s, fails, what, "substation", BX + 18, BY + 10)
		me_place(s, fails, what, "substation", BX + 34, BY + 10)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local stock = { ["iron-plate"] = RUNS * PLATES_IRON, ["copper-plate"] = RUNS * PLATES_COPPER + 2 * CHEST_COPPER }
		local parts = reactor_parts()
		for name, n in pairs(parts or {}) do stock[name] = (stock[name] or 0) + n * REACTORS end
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 0.5, stock)
		local cpus = { place_cpu(s, fails, what, BX + 11, BY - 4), place_cpu(s, fails, what, BX + 11, BY), place_cpu(s, fails, what, BX + 11, BY + 4) }
		local function pair(dx, target)
			local p = me_place(s, fails, what, "me-pattern-provider", BX + dx + 0.5, BY + 5.5)
			local m = target == "steel-chest" and me_place(s, fails, what, target, BX + dx + 0.5, BY + 6.5)
				or me_place(s, fails, what, target, BX + dx + 0.5, BY + 7.5)
			return p, m
		end
		local pa, a = pair(14, "assembling-machine-3")
		local pb, b = pair(20, "assembling-machine-3")
		local pc, c = pair(26, "assembling-machine-3")
		local pd, d = pair(32, "assembling-machine-3")
		local pe, e = pair(38, "steel-chest")
		if a then
			for _, r in pairs({ IN, OUT, PROC, ARMOR, REACTOR }) do
				if a.force.recipes[r] then a.force.recipes[r].enabled = true end
			end
		end
		if d and prototypes.item["speed-module-3"] then d.get_module_inventory().insert{ name = "speed-module-3", count = 4 } end
		if pa then
			local defs = { { kind = "crafting", recipe = IN } }
			if prototypes.recipe[ARMOR] then defs[2] = { kind = "crafting", recipe = ARMOR } end
			give_patterns(pa, defs, fails)
		end
		if pb then
			give_patterns(pb, { { kind = "processing", inputs = { { key = "iron-gear-wheel", amount = 1 } },
				outputs = { { key = "iron-stick", amount = 250 } }, recipe = OUT } }, fails)
		end
		if pc then
			give_patterns(pc, { { kind = "processing", inputs = { { key = "iron-stick", amount = STICKS } },
				outputs = { { key = "copper-cable", amount = 1 } }, recipe = PROC } }, fails)
		end
		if pd and parts then give_patterns(pd, { { kind = "crafting", recipe = REACTOR } }, fails) end
		if pe then
			give_patterns(pe, { { kind = "processing", inputs = { { key = "copper-plate", amount = CHEST_COPPER } },
				outputs = { { key = "iron-chest", amount = 1 } } } }, fails)
		end
		local members = { ctrl, drive, pa, pb, pc, pd, pe }
		for _, cpu in pairs(cpus) do members[#members + 1] = cpu end
		me_connect(fails, what, members)
		storage.overstack815_scene = { ctrl = ctrl, a = a, b = b, c = c, d = d, e = e, pa = pa, pb = pb, pc = pc, pd = pd, pe = pe,
			parts = parts, stock = stock }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.overstack815
		if tick < START or (st and st.done) then return end
		if not st then
			st = { problems = {}, phase = "start" }
			storage.overstack815 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish(note)
			st.done = true
			me_report("OVERSTACK", "recipes above a stack (issue #815)", problems, note or "")
		end
		if not usable() then return finish("nothing to check: no assembling machine 3 with the test's recipes") end
		local sc = storage.overstack815_scene
		local whole = sc and sc.ctrl and sc.ctrl.valid
		for _, k in pairs({ "a", "b", "c", "d", "e", "pa", "pb", "pc", "pd", "pe" }) do whole = whole and sc[k] and sc[k].valid end
		if not whole then
			expect(false, "entities missing")
			return finish()
		end
		local function count(name) return remote.call(NET, "count", sc.ctrl, name) end
		local function job(id) return remote.call(AC, "job", id) or {} end
		local function over(id)
			st.over = st.over or {}
			if st.over[id] then return true end
			local j = job(id)
			if j.status == "done" then st.over[id] = tick return true end
			if j.status == "failed" or j.status == "cancelled" or tick > st.at + TIMEOUT then
				expect(false, "job " .. tostring(id) .. " of " .. tostring(j.item) .. ": "
					.. serpent.line({ j.status, j.reason, j.done, j.total, j.wait, j.problem, pool = j.pool, steps = j.steps,
					leases = j.leases }, { comment = false }) .. " B " .. serpent.line(sc.b.get_inventory(defines.inventory.crafter_input).get_contents())
					.. serpent.line(sc.b.get_inventory(defines.inventory.crafter_output).get_contents())
					.. " C " .. serpent.line(sc.c.get_inventory(defines.inventory.crafter_input).get_contents())
					.. serpent.line(sc.c.get_inventory(defines.inventory.crafter_output).get_contents())
					.. " network sticks " .. count("iron-stick") .. " cables " .. count("copper-cable"))
				finish()
			end
			return false
		end
		local function slot(provider, i)
			local info = remote.call(AC, "provider_info", provider)
			return info and info.slots[i] or {}
		end

		if st.phase == "start" then
			for _, row in pairs({ { sc.pa, "the crafting pattern with 250 and 150 of an ingredient" },
				{ sc.pb, "the processing pattern with 250 of a product" }, { sc.pc, "the processing pattern with 300 of an ingredient" },
				{ sc.pe, "the processing pattern into a chest" } }) do
				local sl = slot(row[1], 1)
				expect(sl.ok and not sl.reason, row[2] .. " is refused: " .. serpent.line({ sl.ok, sl.reason }))
			end
			if prototypes.recipe[ARMOR] then
				local sl = slot(sc.pa, 2)
				expect(not sl.ok and sl.reason == "stack", "the pattern with two of an item that does not stack: "
					.. serpent.line({ sl.ok, sl.reason }) .. ", refused for \"stack\" expected")
			end
			if sc.parts then
				local sl = slot(sc.pd, 1)
				expect(sl.ok and not sl.reason, "the nuclear reactor's pattern is refused: " .. serpent.line({ sl.ok, sl.reason }))
			end
			local cables, why = remote.call(AC, "start", sc.ctrl, "copper-cable", CABLES)
			expect(cables ~= nil, "the cable job did not start: " .. tostring(why))
			local reactors, chests
			if sc.parts then
				reactors, why = remote.call(AC, "start", sc.ctrl, REACTOR, REACTORS)
				expect(reactors ~= nil, "the reactor job did not start: " .. tostring(why))
			end
			chests, why = remote.call(AC, "start", sc.ctrl, "iron-chest", 2)
			expect(chests ~= nil, "the chest job did not start: " .. tostring(why))
			if not (cables and chests and (reactors or not sc.parts)) then return finish() end
			st.cables, st.reactors, st.chests, st.at, st.phase = cables, reactors, chests, tick, "run"
			st.max_a, st.max_d, st.steps, st.last = 0, 0, 0, nil
			return
		end
		if st.phase ~= "run" then return end

		--- while the jobs run: what lies in the input of A (and D) at once, and how often the cable job is stepped
		local inp = sc.a.get_inventory(defines.inventory.crafter_input)
		st.max_a = math.max(st.max_a, inp.get_item_count("iron-plate"))
		if sc.parts then
			local n = 0
			for _, c in pairs(sc.d.get_inventory(defines.inventory.crafter_input).get_contents()) do n = math.max(n, c.count) end
			st.max_d = math.max(st.max_d, n)
		end
		if not (st.over and st.over[st.cables]) then
			local j = job(st.cables)
			if j.stepped and j.stepped ~= st.last then
				st.last = j.stepped
				st.steps = st.steps + 1
			end
		end
		--- the chest job: its plates lie in the chest, two runs of 150 one after the other; then its chests come by hand
		if not st.chest_fed then
			local chest = sc.e.get_inventory(defines.inventory.chest)
			if chest.get_item_count("copper-plate") >= 2 * CHEST_COPPER then
				st.chest_fed = tick
				chest.remove{ name = "copper-plate", count = 2 * CHEST_COPPER }
				expect(remote.call(NET, "insert", sc.ctrl, "iron-chest", 2) == 2, "the two iron chests did not go into the network")
			end
		end

		local all = over(st.cables)
		if st.done then return end
		all = over(st.chests) and all
		if st.done then return end
		if st.reactors then all = over(st.reactors) and all end
		if st.done or not all then return end

		expect(st.max_a >= 2 * PLATES_IRON, "machine A never held two crafts' worth of iron plates: " .. st.max_a .. " at most, "
			.. 2 * PLATES_IRON .. " expected (a stack is " .. prototypes.item["iron-plate"].stack_size .. ")")
		local span = st.over[st.cables] - st.at
		expect(st.steps > 0 and st.steps <= span / 10, "the cable job was stepped " .. st.steps .. " times in " .. span
			.. " ticks: more than every ten ticks (no craft of it is shorter than a step)")
		expect(count("copper-cable") == CABLES and count("iron-stick") == 0 and count("iron-gear-wheel") == 0
			and count("iron-plate") == 0, "after the cable job: " .. count("copper-cable") .. " cables, " .. count("iron-stick")
			.. " sticks, " .. count("iron-gear-wheel") .. " gears, " .. count("iron-plate") .. " iron plates")
		expect(count("iron-chest") == 2, "after the chest job: " .. count("iron-chest") .. " iron chests")
		local copper = 0
		if sc.parts then
			expect(count(REACTOR) == REACTORS, "after the reactor job: " .. count(REACTOR) .. " reactors, " .. REACTORS .. " expected")
			for name in pairs(sc.parts) do
				local left = count(name)
				if name == "copper-plate" then copper = left
				else expect(left == 0, "after the reactor job: " .. left .. " " .. name .. " left") end
			end
			expect(st.max_d > 500, "the reactor's machine never held more than 500 of an ingredient: " .. st.max_d)
		else
			copper = count("copper-plate")
		end
		expect(copper == 0, "copper plates left in the network: " .. copper)
		for _, k in pairs({ "a", "b", "c", "d" }) do
			expect(sc[k].get_inventory(defines.inventory.crafter_input).is_empty()
				and sc[k].get_inventory(defines.inventory.crafter_output).is_empty(), "something is left in machine " .. k:upper())
		end
		return finish(string.format("a job of %d cables over a crafting pattern with 250 + 150 of its ingredients and two processing "
			.. "patterns with 250 of a product and 300 of an ingredient (%d steps in %d ticks, %d plates in a slot at once); %s; "
			.. "two runs of 150 into a chest; two of an item that does not stack still refused; every count exact",
			CABLES, st.steps, span, st.max_a, sc.parts and (REACTORS .. " nuclear reactors (" .. st.max_d .. " of an ingredient in a "
			.. "slot at once)") or "no vanilla reactor recipe here"))
	end

	function T.running(check) check(storage.overstack815 and storage.overstack815.done, "recipes above a stack") end

	return T
end
