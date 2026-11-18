--- Runtime test of me-network issue #780: the filters of the ME Export and Import Bus from the circuit (vanilla's "Set
--- filters" of an inserter). A network with iron plates, copper plates, iron sticks and gears; an export bus E on chest A (its
--- own filter: copper plate) wired red to a constant combinator K and green to a second one K2; an import bus I on chest B
--- (stone and wood) wired to K3; an export bus EA on an assembling machine that puts its recipe's ingredients on the wire; a
--- bus E3 on its own:
---   * the mode switched on in E's panel (a stand-in player's click on the check box): K's item and fluid signals with a
---     positive value are the filters, whatever their value (a negative one, a virtual one are none); A gets iron plates and
---     neither the copper of E's own filter nor gears; the panel names the filters;
---   * a signal's value changes: the check finds the same filters and makes no list; the signals change: the filters follow;
---   * red and green are added: a signal that K2 cancels on the green wire is no filter;
---   * more signals than filters: the first in the game's signal order apply, the same a vanilla inserter with "Set filters"
---     takes from that wire, and the window says how many have no slot;
---   * the wire removed: E's own filter works again (copper plates); the wire back and the mode off: its own filter, too;
---   * a blueprint copy, a settings paste and a clone keep the mode and the bus's own filters;
---   * the import bus: with the mode it takes what K3 names (the stone, not the wood) and nothing while K3 sends nothing;
---   * the assembling machine: EA exports the ingredients of its recipe and nothing else.
--- Loaded by control.lua: require("circuitflt")(H) returns { setup, tick, running }.

local NET, IO, CONN, GUI = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-connector", "gregtorio-me-gui"
local BX, BY = -250, 250              -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 130
local RECIPE = "iron-gear-crafting-table"     -- (1 iron plate + 2 iron sticks; with Gregtorio its own, else data.lua's stand-in)
local RED, GREEN = defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH = { direction = defines.direction.south }
	local function line(t) return serpent.line(t) end

	--- an assembling machine that crafts RECIPE and takes a wire (vanilla's assembling machine 2 first)
	local function machine_name()
		local recipe = prototypes.recipe[RECIPE]
		if not recipe then return nil end
		local names = { "assembling-machine-2", "assembling-machine-1", "assembling-machine-3" }
		for name, p in pairs(prototypes.get_entity_filtered{ { filter = "type", type = "assembling-machine" } }) do
			if not p.hidden and name:sub(1, 3) ~= "me-" then names[#names + 1] = name end
		end
		for _, name in ipairs(names) do
			local p = prototypes.entity[name]
			local makes = false
			for _, cat in pairs(recipe.categories) do if p and p.crafting_categories[cat] then makes = true end end
			if p and p.type == "assembling-machine" and makes and not p.fixed_recipe
				and p.tile_width == 3 and p.tile_height == 3 then return name end
		end
		return nil
	end

	function T.setup(s)
		local fails = {}
		local what = "filters from the circuit"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5,
			{ ["iron-plate"] = 400, ["copper-plate"] = 400, ["iron-stick"] = 200, ["iron-gear-wheel"] = 100 })
		local members = { ctrl, drive }
		for x = 9.5, 21.5 do me_place(s, fails, what, "me-cable", BX + x, BY - 0.5) end
		members[#members + 1] = me_place(s, fails, what, "me-export-bus", BX + 10.5, BY + 0.5, SOUTH)       -- E
		me_place(s, fails, what, "iron-chest", BX + 10.5, BY + 1.5)                                          -- A
		me_place(s, fails, what, "constant-combinator", BX + 10.5, BY + 3.5)                                 -- K
		me_place(s, fails, what, "constant-combinator", BX + 11.5, BY + 3.5)                                 -- K2
		members[#members + 1] = me_place(s, fails, what, "me-import-bus", BX + 13.5, BY + 0.5, SOUTH)       -- I
		me_place(s, fails, what, "iron-chest", BX + 13.5, BY + 1.5)                                          -- B
		me_place(s, fails, what, "constant-combinator", BX + 13.5, BY + 3.5)                                 -- K3
		members[#members + 1] = me_place(s, fails, what, "me-export-bus", BX + 16.5, BY + 0.5, SOUTH)       -- EA
		local mname = machine_name()
		if mname then
			local m = s.create_entity{ name = mname, position = { BX + 16.5, BY + 2.5 }, force = "player", raise_built = true }
			if not m then fails[#fails + 1] = what .. ": could not place " .. mname end
		end
		members[#members + 1] = me_place(s, fails, what, "me-export-bus", BX + 20.5, BY + 0.5, SOUTH)       -- E3
		H.me_connect(fails, what, members)
		return fails
	end

	--- the signals of constant combinator `k`: a list of { type, name, count, quality }
	local function emit(k, list)
		local cb = k.get_or_create_control_behavior()
		if cb.sections_count == 0 then cb.add_section() end
		local sec = cb.get_section(1)
		for i = 1, 30 do sec.clear_slot(i) end
		for i, v in ipairs(list) do
			sec.set_slot(i, { value = { type = v[1], name = v[2], quality = v[4] or "normal" }, min = v[3] })
		end
	end

	--- `n` plain items of this game, in an order that is not the game's
	local function some_items(n, skip)
		local names = {}
		for name, p in pairs(prototypes.item) do
			if p.type == "item" and not p.hidden and not p.parameter and not skip[name] then names[#names + 1] = name end
		end
		table.sort(names, function(a, b) return a > b end)
		local out = {}
		local step = math.max(1, math.floor(#names / n))
		for i = 1, n do out[i] = names[1 + (i - 1) * step] end
		return out
	end

	function T.tick()
		local st = storage.circuitflt780
		if (st and st.done) or game.tick < START then return end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		if not st then
			st = { problems = {}, phase = "start" }
			storage.circuitflt780 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("CIRCUITFLT", "Filters of the export and import bus from the circuit", problems, "the panel's check box; "
				.. "positive item and fluid signals are the filters, values play no part; red and green added; more signals than "
				.. "filters as a vanilla inserter; no wire or mode off: the own filters; blueprint, paste, clone; the import bus; an "
				.. "assembling machine's ingredients")
		end
		local function next_phase(name) st.phase, st.tick = name, game.tick end
		local ctrl = find("me-network-controller", 7, 0)
		local E, I, EA, E3 = find("me-export-bus", 10.5, 0.5), find("me-import-bus", 13.5, 0.5), find("me-export-bus", 16.5, 0.5),
			find("me-export-bus", 20.5, 0.5)
		local A, B = find("iron-chest", 10.5, 1.5), find("iron-chest", 13.5, 1.5)
		local K, K2, K3 = find("constant-combinator", 10.5, 3.5), find("constant-combinator", 11.5, 3.5),
			find("constant-combinator", 13.5, 3.5)
		if not (ctrl and E and I and EA and E3 and A and B and K and K2 and K3) then expect(false, "entities missing") return finish() end
		local a, b = A.get_inventory(defines.inventory.chest), B.get_inventory(defines.inventory.chest)
		local function bus(e) return remote.call(IO, "bus_info", e) or {} end
		local function mode(e) return remote.call(CONN, "filter_mode", e) or {} end
		local function wire(x, y, id) x.get_wire_connector(id, true).connect_to(y.get_wire_connector(id, true), false) end
		local function same(list, want)
			if #(list or {}) ~= #want then return false end
			for i, v in ipairs(want) do if list[i] ~= v then return false end end
			return true
		end

		if st.phase == "start" then
			emit(K, { { "item", "iron-plate", 5 }, { "item", "iron-gear-wheel", -3 }, { "virtual", "signal-A", 1 },
				{ "fluid", "water", 10 } })
			emit(K2, {})
			emit(K3, {})
			wire(E, K, RED)
			wire(E, K2, GREEN)
			wire(I, K3, RED)
			remote.call(IO, "set_bus_filters", E, { "copper-plate" })
			b.insert{ name = "stone", count = 30 }
			b.insert{ name = "wood", count = 20 }
			remote.call(IO, "set_bus_circuit", I, true)             -- (before its first visit: without filters it takes everything)
			return next_phase("own")
		end

		--- E works with its own filter first; then the mode through the panel's check box
		if st.phase == "own" then
			if game.tick < st.tick + 40 then return end
			expect(a.get_item_count("copper-plate") > 0, "the export bus moves its own filter's copper plates before the mode")
			a.clear()
			st.inv = game.create_inventory(10)
			remote.call(GUI, "stand_in", "circuitflt780", { main = st.inv, index = 9780, gui = true })
			remote.call(GUI, "stand_in_open_entity", "circuitflt780", E)
			local side = remote.call(GUI, "stand_in_side", "circuitflt780", "bus_circuit", true) or {}
			expect(side.states and side.states.fork_me_bus_circuit == true, "the panel's check box switches the mode on: " .. line(side))
			local cap = side.captions and side.captions.fork_me_bus_circuit_filters
			expect(type(cap) == "table" and cap[1] == "fork-me-gui.bus-circuit-filters" and tostring(cap[2]):find("iron-plate", 1, true)
				and tostring(cap[2]):find("fluid=water", 1, true), "the panel names the filters: " .. line(cap))
			remote.call(GUI, "stand_in_close_window", "circuitflt780")
			remote.call(GUI, "stand_in_forget", "circuitflt780")
			st.inv.destroy()
			st.inv = nil
			local d = bus(E)
			expect(d.circuit == true and same(d.cfilters, { "iron-plate", "fluid/water" }), "the wires' filters (items, then fluids; the "
				.. "negative and the virtual signal are none): " .. line(d.cfilters))
			expect(same(d.filters, { "copper-plate" }), "the bus keeps its own filter: " .. line(d.filters))
			return next_phase("on")
		end

		if st.phase == "on" then
			if game.tick < st.tick + 40 then return end
			expect(a.get_item_count("iron-plate") > 0, "the export bus moves the iron plates the wire names")
			expect(a.get_item_count("copper-plate") == 0 and a.get_item_count("iron-gear-wheel") == 0,
				"it moves nothing else: copper " .. a.get_item_count("copper-plate") .. ", gears " .. a.get_item_count("iron-gear-wheel"))
			--- the import bus: K3 sends nothing, so it took nothing
			expect(b.get_item_count("stone") == 30 and b.get_item_count("wood") == 20, "the import bus takes nothing while its wire "
				.. "names nothing: stone " .. b.get_item_count("stone") .. ", wood " .. b.get_item_count("wood"))
			emit(K3, { { "item", "stone", 1 } })
			--- a value changes: the same filters, no new list
			st.gen = mode(E).gen
			emit(K, { { "item", "iron-plate", 500 }, { "item", "iron-gear-wheel", -3 }, { "virtual", "signal-A", 7 },
				{ "fluid", "water", 1 } })
			return next_phase("value")
		end

		if st.phase == "value" then
			if game.tick < st.tick + 40 then return end
			expect(mode(E).gen == st.gen, "a changed value makes no new filter list: " .. tostring(st.gen) .. " -> " .. tostring(mode(E).gen))
			expect(b.get_item_count("stone") == 0 and b.get_item_count("wood") == 20, "the import bus takes the stone its wire names "
				.. "and leaves the wood: stone " .. b.get_item_count("stone") .. ", wood " .. b.get_item_count("wood"))
			--- the signals change
			a.clear()
			emit(K, { { "item", "iron-gear-wheel", 1 }, { "item", "iron-plate", 5 } })
			emit(K2, { { "item", "iron-plate", -5 } })               -- (green cancels the plates of red)
			return next_phase("changed")
		end

		if st.phase == "changed" then
			if game.tick < st.tick + 40 then return end
			expect(same(bus(E).cfilters, { "iron-gear-wheel" }), "the filters follow the signals, red and green added: " .. line(bus(E).cfilters))
			expect(a.get_item_count("iron-gear-wheel") > 0 and a.get_item_count("iron-plate") == 0, "gears and no plates: "
				.. a.get_item_count("iron-gear-wheel") .. ", " .. a.get_item_count("iron-plate"))
			--- more signals than filters; a vanilla inserter on the same wire
			emit(K2, {})
			local names = some_items(12, {})
			local list = {}
			for i, name in ipairs(names) do list[i] = { "item", name, 13 - i } end
			emit(K, list)
			for _, name in ipairs({ "fast-inserter", "inserter" }) do
				if not st.ins and prototypes.entity[name] and prototypes.entity[name].filter_count > 0 then
					local ins = s.create_entity{ name = name, position = { BX + 10.5, BY + 5.5 }, force = "player" }
					if ins then
						ins.use_filters = true
						ins.get_or_create_control_behavior().circuit_set_filters = true
						wire(ins, K, RED)
						st.ins = ins
					end
				end
			end
			st.count = #names
			return next_phase("many")
		end

		if st.phase == "many" then
			if game.tick < st.tick + 40 then return end
			local d = bus(E)
			expect(#(d.cfilters or {}) == st.count and d.max == 9 and d.cmore == st.count - 9, "more signals than filters: "
				.. line({ #(d.cfilters or {}), d.max, d.cmore }))
			local got = remote.call(IO, "get_bus_applied", E) or {}
			expect(#got == 9 and same(got, { table.unpack(d.cfilters or {}, 1, 9) }), "the first nine apply: " .. line(got))
			if st.ins and st.ins.valid then
				local n = math.min(st.ins.filter_slot_count, #(d.cfilters or {}))
				local theirs, ours = {}, {}
				for i = 1, n do
					local f = st.ins.get_filter(i)
					theirs[i], ours[i] = f and f.name or "-", d.cfilters[i]
				end
				expect(n > 0 and same(ours, theirs), "the order of a vanilla inserter's filters from the same wire: ours "
					.. line(ours) .. ", the inserter's " .. line(theirs))
				st.ins.destroy()
			end
			st.ins = nil
			--- the wire removed: its own filter
			a.clear()
			E.get_wire_connector(RED, true).disconnect_all()
			E.get_wire_connector(GREEN, true).disconnect_all()
			return next_phase("unwired")
		end

		if st.phase == "unwired" then
			if game.tick < st.tick + 40 then return end
			local d = bus(E)
			expect(d.circuit == true and d.cfilters == nil and mode(E).wired == false, "without a wire the mode stays and names no filters: "
				.. line({ d.circuit, d.cfilters, mode(E) }))
			expect(a.get_item_count("copper-plate") > 0, "without a wire the bus's own filter works: copper "
				.. a.get_item_count("copper-plate"))
			--- blueprint, settings paste, clone (the mode on, the own filter)
			local copy, why, tags = H.blueprint_copy(E, 14, 0)
			local t = tags and tags.fork_me_bus
			expect(t and t.circuit == true and same(t.filters, { "copper-plate" }), "the blueprint's tag: " .. line(t))
			local c = copy and bus(copy) or {}
			expect(copy and c.circuit == true and same(c.filters, { "copper-plate" }), "a blueprint copy keeps the mode: "
				.. tostring(why) .. " " .. line({ c.circuit, c.filters }))
			if copy and copy.valid then copy.destroy{ raise_destroy = true } end
			remote.call(IO, "paste", E, E3)
			c = bus(E3)
			expect(c.circuit == true and same(c.filters, { "copper-plate" }), "a settings paste keeps the mode: " .. line({ c.circuit, c.filters }))
			local clone = E.clone{ position = { BX + 26.5, BY + 0.5 } }
			c = clone and bus(clone) or {}
			expect(clone and c.circuit == true and same(c.filters, { "copper-plate" }), "a clone keeps the mode: " .. line({ c.circuit, c.filters }))
			if clone and clone.valid then clone.destroy{ raise_destroy = true } end
			remote.call(IO, "set_bus_circuit", E3, false)
			remote.call(IO, "paste", E3, E)                          -- (a paste from a bus without the mode switches it off)
			expect(bus(E).circuit ~= true and mode(E).on == false, "a paste from a bus without the mode switches it off")
			--- the wire back, the mode on and off again: the own filter either way
			wire(E, K, RED)
			remote.call(IO, "set_bus_circuit", E, true)
			return next_phase("rewired")
		end

		--- (a wire a script made is a circuit network at the next tick: the check sees it then)
		if st.phase == "rewired" then
			if game.tick < st.tick + 30 then return end
			expect(#(bus(E).cfilters or {}) == st.count, "the mode on and the wire back: the wire's filters again: "
				.. #(bus(E).cfilters or {}))
			remote.call(IO, "set_bus_circuit", E, false)
			expect(bus(E).circuit ~= true and bus(E).cfilters == nil and same(remote.call(IO, "get_bus_applied", E) or {}, { "copper-plate" }),
				"the mode off: the own filter applies: " .. line(remote.call(IO, "get_bus_applied", E)))
			--- the assembling machine: its recipe's ingredients on EA's wire
			local M = s.find_entities_filtered{ type = "assembling-machine", position = { BX + 16.5, BY + 2.5 } }[1]
			if M then
				M.set_recipe(RECIPE)
				M.get_or_create_control_behavior().circuit_read_ingredients = true
				wire(EA, M, RED)
				remote.call(IO, "set_bus_circuit", EA, true)
				st.machine = true
			else
				expect(script.active_mods["gregtorio-continued"] ~= nil, "no assembling machine for " .. RECIPE)
			end
			return next_phase("machine")
		end

		if st.phase == "machine" then
			if game.tick < st.tick + 60 then return end
			if st.machine then
				local M = s.find_entities_filtered{ type = "assembling-machine", position = { BX + 16.5, BY + 2.5 } }[1]
				local got = bus(EA).cfilters or {}
				local want = {}
				for _, ing in pairs(prototypes.recipe[RECIPE].ingredients) do
					want[ing.type == "fluid" and ("fluid/" .. ing.name) or ing.name] = true
				end
				local ok = #got > 0
				for _, key in ipairs(got) do if not want[key] then ok = false end end
				for key in pairs(want) do
					local hit = false
					for _, k in ipairs(got) do if k == key then hit = true end end
					if not hit then ok = false end
				end
				expect(ok, "the machine's ingredients are the filters: " .. line(got))
				local inv = M and M.get_inventory(defines.inventory.crafter_input)
				local made = M and (M.products_finished > 0 or M.is_crafting())
				expect(inv and (inv.get_item_count("iron-plate") > 0 or made), "the bus feeds the machine its ingredients: "
					.. line(inv and inv.get_contents()))
				expect(inv and inv.get_item_count("copper-plate") == 0, "and nothing else")
			end
			return finish()
		end
	end

	function T.running(check)
		check(storage.circuitflt780 and storage.circuitflt780.done, "Filters of the export and import bus from the circuit")
	end

	return T
end
