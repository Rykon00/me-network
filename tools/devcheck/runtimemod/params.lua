--- Runtime test of me-network issue #781: parametrised blueprints. The game replaces items, fluids and numbers only in the
--- fields of a blueprint entity it knows itself, so the ME blocks' filters and thresholds are mirrored into such a field when a
--- blueprint is made (scripts/fork-me-mirror.lua) and read back when the block or its ghost is built. The dialog that asks for
--- the values is the client's (checked there once, issue #781); here its work is done by hand on the blueprint: every
--- "iron-plate" outside the tags becomes "iron-gear-wheel" and every count of 100 becomes 250, as the game replaces a
--- parameter and a number. A row of blocks of no network (the settings need none): an export bus E (iron plate, copper plate,
--- water), an import bus I (water of one temperature), a storage bus S (iron plate), a level emitter L (iron plate, 100, low), an
--- emitter H with a threshold above 32 bits, an advanced emitter A (rows 1 and 3) and a circuit interface C:
---   * the blueprint has the mirror: E's filters as display panel records, L's row as an inactive section 2, A's rows as
---     sections 2 and 4, C's filters as slots of an inactive section 2; H has none; the tags are as before;
---   * built as ghosts after the replacement: each ghost's tags have the replaced item and amount, and its mirror is gone;
---   * revived: the blocks have the replaced filters, resources and thresholds, what was not replaced is kept (copper, the
---     fluid with its temperature, the modes, the row that was not touched), and no block has a record or a second section;
---   * built without the ghost step (revived at once): the same;
---   * the blueprint without the replacement gives the settings back as they were; a blueprint without the mirror (made by
---     an older version) is built from its tags.
--- Loaded by control.lua: require("params")(H) returns { setup, tick, running }.

local IO, SB, EM, CI, MIRROR, AC = "gregtorio-me-io", "gregtorio-me-storagebus", "gregtorio-me-emitter", "gregtorio-me-circuit",
	"gregtorio-me-mirror", "gregtorio-me-autocraft"
local BX, BY = -250, 290              -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 140
local FROM, TO = "iron-plate", "iron-gear-wheel"
local BIG = 5000000000

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}
	local function line(t) return serpent.line(t) end
	local NAMES = { "me-export-bus", "me-import-bus", "me-storage-bus", "me-level-emitter", "me-level-emitter",
		"me-advanced-level-emitter", "me-circuit-interface" }

	function T.setup(s)
		local fails = {}
		for i, name in ipairs(NAMES) do me_place(s, fails, "parametrised blueprints", name, BX + 2 * i + 0.5, BY + 0.5) end
		return fails
	end

	--- what the game's dialog does to a blueprint entity: the parameter's item and number replaced everywhere but in the tags
	local function replace(v, key)
		if type(v) ~= "table" then return v end
		for k, x in pairs(v) do
			if k ~= "tags" then
				if type(x) == "table" then replace(x, k)
				elseif k == "name" and x == FROM and key ~= nil then v[k] = TO
				elseif (k == "count" or k == "constant") and x == 100 then v[k] = 250 end
			end
		end
		return v
	end

	local function same(list, want)
		if type(list) ~= "table" or #list ~= #want then return false end
		for i, v in ipairs(want) do if list[i] ~= v then return false end end
		return true
	end

	function T.tick()
		local st = storage.params781
		if (st and st.done) or game.tick < START then return end
		st = { problems = {} }
		storage.params781 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local s = game.surfaces[1]
		local function at(i, dy) return s.find_entity(NAMES[i], { BX + 2 * i + 0.5, BY + 0.5 + (dy or 0) }) end
		local E, I, S, L, Hh, A, C = at(1), at(2), at(3), at(4), at(5), at(6), at(7)
		local function finish()
			st.done = true
			me_report("PARAMS", "Parametrised blueprints", problems, "the mirror in the blueprint (records, inactive sections); "
				.. "replaced item and number reach the ghosts' tags and the built blocks; what was not replaced is kept; no mirror "
				.. "left on a block; a blueprint without the mirror builds from its tags")
		end
		if not (E and I and S and L and Hh and A and C) then expect(false, "entities missing") return finish() end

		remote.call(IO, "set_bus_filters", E, { FROM, "copper-plate", "fluid/water" })
		remote.call(IO, "set_bus_filters", I, { "fluid/water@165" })
		local warm = (remote.call(IO, "get_bus", I) or {}).filters or {}
		remote.call(SB, "set_settings", S, { filters = { FROM }, priority = 3 })
		remote.call(EM, "set", L, { key = FROM, amount = 100, mode = "low" })
		remote.call(EM, "set", Hh, { key = FROM, amount = BIG })
		remote.call(EM, "set", A, { row = 1, key = "copper-plate", amount = 100, active = true })
		remote.call(EM, "set", A, { row = 3, key = "fluid/water", amount = 500, active = true, inverted = true })
		remote.call(CI, "set_circuit_filters", C, { FROM, "fluid/water" })

		--- the blueprint as a player makes it: the tags, then the mirror
		local area = { { BX + 2, BY }, { BX + 2 * #NAMES + 1, BY + 1 } }
		local inv = game.create_inventory(3)
		local function blueprint(slot)
			local bp = inv[slot]
			bp.set_stack{ name = "blueprint" }
			local mapping = bp.create_blueprint{ surface = s, force = "player", area = area } or {}
			remote.call(AC, "tag_blueprint", bp, mapping)
			return bp
		end
		local bp = blueprint(1)
		local plain = bp.get_blueprint_entities() or {}
		expect(remote.call(MIRROR, "mirror_blueprint", bp) == true, "the blueprint got mirrors")
		local ents = bp.get_blueprint_entities() or {}
		expect(#ents == #NAMES, "the blueprint keeps its " .. #NAMES .. " entities: " .. #ents)
		local by, emitters = {}, {}
		for _, be in pairs(ents) do
			if be.name == "me-level-emitter" then emitters[#emitters + 1] = be else by[be.name] = be end
		end
		table.sort(emitters, function(a, b) return a.position.x < b.position.x end)
		local function sections(be)
			local list = ((be and be.control_behavior or {}).sections or {}).sections or {}
			local out = {}
			for _, sec in pairs(list) do out[sec.index or 1] = sec end
			return out
		end
		do
			local recs = ((by["me-export-bus"] or {}).control_behavior or {}).parameters or {}
			expect(#recs == 3 and recs[1].icon and recs[1].icon.name == FROM and recs[2].icon.name == "copper-plate"
				and recs[3].icon.type == "fluid" and recs[3].icon.name == "water", "the export bus's filters as records: " .. line(recs))
			expect(same(((by["me-export-bus"] or {}).tags or {}).fork_me_bus and by["me-export-bus"].tags.fork_me_bus.filters,
				{ FROM, "copper-plate", "fluid/water" }), "the export bus's tag is as before")
			local l = sections(emitters[1])[2]
			local f = l and l.filters and l.filters[1]
			expect(l and l.active == false and f and f.name == FROM and f.count == 100, "the emitter's row as an inactive section 2: " .. line(l))
			expect(sections(emitters[2])[2] == nil, "a threshold above 32 bits is not mirrored: " .. line(sections(emitters[2])))
			local a = sections(by["me-advanced-level-emitter"])
			expect(a[2] and a[2].filters[1].name == "copper-plate" and a[2].filters[1].count == 100
				and (a[3] == nil or a[3].filters == nil or #a[3].filters == 0) and a[4] and a[4].filters[1].name == "water" and a[4].filters[1].count == 500 and a[4].active == false,
				"the advanced emitter's rows 1 and 3 as sections 2 and 4: " .. line(a))
			local c = sections(by["me-circuit-interface"])[2]
			expect(c and c.active == false and #(c.filters or {}) == 2 and c.filters[1].name == FROM and c.filters[2].name == "water",
				"the circuit interface's filters as an inactive section 2: " .. line(c))
		end

		--- the game's replacement, then built: as ghosts first (dy 6), at once (dy 12)
		local replaced = bp.get_blueprint_entities()
		for _, be in pairs(replaced) do replace(be) end
		local bp2 = inv[2]
		bp2.set_stack{ name = "blueprint" }
		bp2.set_blueprint_entities(replaced)

		local function check(dy, what)
			local e, i, sb, l, h, a, c = at(1, dy), at(2, dy), at(3, dy), at(4, dy), at(5, dy), at(6, dy), at(7, dy)
			if not (e and i and sb and l and h and a and c) then expect(false, what .. ": blocks missing") return end
			local f = (remote.call(IO, "get_bus", e) or {}).filters
			expect(same(f, { TO, "copper-plate", "fluid/water" }), what .. ": the export bus's filters: " .. line(f))
			f = (remote.call(IO, "get_bus", i) or {}).filters
			expect(same(f, warm), what .. ": the import bus keeps its fluid filter with the temperature: " .. line(f) .. " / " .. line(warm))
			local ss = remote.call(SB, "get_settings", sb) or {}
			expect(same(ss.filters, { TO }) and ss.priority == 3, what .. ": the storage bus's filter and priority: " .. line({ ss.filters, ss.priority }))
			local g = remote.call(EM, "get", l) or {}
			expect(g.key == TO and g.amount == 250 and g.mode == "low", what .. ": the emitter's resource, threshold and mode: "
				.. line({ g.key, g.amount, g.mode }))
			g = remote.call(EM, "get", h) or {}
			expect(g.key == FROM and g.amount == BIG, what .. ": the emitter above 32 bits keeps its tag: " .. line({ g.key, g.amount }))
			g = (remote.call(EM, "get", a) or {}).rows or {}
			expect(g[1] and g[1].key == "copper-plate" and g[1].amount == 250 and g[1].active and g[3] and g[3].key == "fluid/water"
				and g[3].amount == 500 and g[3].inverted and g[2] == nil, what .. ": the advanced emitter's rows: " .. line(g))
			f = (remote.call(CI, "get_circuit", c) or {}).filters
			expect(same(f, { TO, "fluid/water" }), what .. ": the circuit interface's filters: " .. line(f))
			local left = {}
			for _, x in pairs({ e, i, sb }) do
				local n = 0
				for _, r in pairs(x.get_or_create_control_behavior().records) do if r.icon then n = n + 1 end end
				left[#left + 1] = n
			end
			for _, x in pairs({ l, h, a }) do left[#left + 1] = x.get_or_create_control_behavior().sections_count end
			expect(same(left, { 0, 0, 0, 1, 1, 1 }), what .. ": no mirror left on a block (records, sections): " .. line(left))
		end

		--- ghosts with the build event: their tags are resolved, their mirror gone
		bp2.build_blueprint{ surface = s, force = "player", position = { BX + #NAMES + 1.5, BY + 6.5 }, raise_built = true }
		local ghosts = s.find_entities_filtered{ type = "entity-ghost", area = { { BX + 2, BY + 6 }, { BX + 2 * #NAMES + 1, BY + 7 } } }
		expect(#ghosts == #NAMES, "ghosts of the replaced blueprint: " .. #ghosts)
		for _, g in pairs(ghosts) do
			local tags = g.tags or {}
			if g.ghost_name == "me-export-bus" then
				expect(same((tags.fork_me_bus or {}).filters, { TO, "copper-plate", "fluid/water" }), "the bus ghost's tags are resolved: "
					.. line(tags.fork_me_bus))
				local cb, n = g.get_control_behavior(), 0
				for _, r in pairs(cb and cb.records or {}) do if r.icon then n = n + 1 end end
				expect(n == 0, "the bus ghost's mirror is gone: " .. n .. " records with an icon")
			elseif g.ghost_name == "me-level-emitter" and (tags.fork_me_emitter or {}).amount ~= BIG then
				expect(tags.fork_me_emitter.key == TO and tags.fork_me_emitter.amount == 250, "the emitter ghost's tags are resolved: "
					.. line(tags.fork_me_emitter))
			end
			g.revive{ raise_revive = true }
		end
		check(6, "ghosts first")

		--- revived without a ghost event (a robot that builds a ghost no script saw)
		for _, g in pairs(bp2.build_blueprint{ surface = s, force = "player", position = { BX + #NAMES + 1.5, BY + 12.5 } } or {}) do
			if g.valid then g.revive{ raise_revive = true } end
		end
		check(12, "built at once")

		--- nothing replaced: the settings as they were
		for _, g in pairs(bp.build_blueprint{ surface = s, force = "player", position = { BX + #NAMES + 1.5, BY + 18.5 } } or {}) do
			if g.valid then g.revive{ raise_revive = true } end
		end
		do
			local e, l, a = at(1, 18), at(4, 18), at(6, 18)
			local f = e and (remote.call(IO, "get_bus", e) or {}).filters
			expect(same(f, { FROM, "copper-plate", "fluid/water" }), "nothing replaced: the export bus's filters: " .. line(f))
			local g = l and remote.call(EM, "get", l) or {}
			expect(g.key == FROM and g.amount == 100 and g.mode == "low", "nothing replaced: the emitter: " .. line({ g.key, g.amount, g.mode }))
			g = a and (remote.call(EM, "get", a) or {}).rows or {}
			expect(g[1] and g[1].amount == 100 and g[3] and g[3].amount == 500, "nothing replaced: the advanced emitter: " .. line(g))
		end

		--- a blueprint without the mirror (an older version's): built from its tags
		local bp3 = inv[3]
		bp3.set_stack{ name = "blueprint" }
		bp3.set_blueprint_entities(plain)
		for _, g in pairs(bp3.build_blueprint{ surface = s, force = "player", position = { BX + #NAMES + 1.5, BY + 24.5 } } or {}) do
			if g.valid then g.revive{ raise_revive = true } end
		end
		do
			local e, l, c = at(1, 24), at(4, 24), at(7, 24)
			local f = e and (remote.call(IO, "get_bus", e) or {}).filters
			expect(same(f, { FROM, "copper-plate", "fluid/water" }), "no mirror: the export bus from its tag: " .. line(f))
			local g = l and remote.call(EM, "get", l) or {}
			expect(g.key == FROM and g.amount == 100, "no mirror: the emitter from its tag: " .. line({ g.key, g.amount }))
			f = c and (remote.call(CI, "get_circuit", c) or {}).filters
			expect(same(f, { FROM, "fluid/water" }), "no mirror: the circuit interface from its tag: " .. line(f))
		end
		inv.destroy()
		return finish()
	end

	function T.running(check) check(storage.params781 and storage.params781.done, "Parametrised blueprints") end

	return T
end
