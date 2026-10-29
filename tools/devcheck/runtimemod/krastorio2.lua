--- Runtime test of me-network issue #595: Krastorio 2's warehouses, strongboxes, big tanks, labs, matter machines and steel
--- pipes as targets of the ME blocks (scripts/fork-me-targets.lua: they are containers, logistic containers, storage tanks, a
--- lab and assembling machines, so nothing of the mod names them). On a surface of its own ("me-k2-test", concrete). Without
--- Krastorio 2 the test reports itself skipped.
--- * Items: an import bus empties a warehouse, an export bus fills a strongbox, a storage bus shows a requester warehouse's
---   contents as network storage and stores into it; every Krastorio 2 warehouse and strongbox has a type the buses take.
--- * Fluids: an export bus fills water into a big storage tank, a storage bus shows the crude oil of a huge storage tank.
--- * Research: an export bus fills Krastorio 2's advanced lab with science packs and its research server with the ingredients
---   of one of its recipes.
--- * Matter: matter (kr-matter) in fluid cells; an export bus fills it into a matter associator set to a recipe that takes
---   matter, an import bus takes the matter a matter plant made (its output box) back into the network, at its temperature.
--- * Steel pipes: Krastorio 2's steel pipe and steel pipe to ground connect to an ME Interface's side as a vanilla pipe does
---   (Krastorio 2's data-final-fixes gives every fluid box but a pipe's its steel pipe category).
--- Loaded by control.lua like lab.lua.

local NET, IO, SB, FL = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-storagebus", "gregtorio-me-fluids"
local SURFACE = "me-k2-test"
local START, CHECK = 120, 900
local MATTER = "kr-matter"

local function active() return prototypes.entity["kr-warehouse"] ~= nil end

local function surface()
	local s = game.surfaces[SURFACE]
	if s then return s end
	s = game.create_surface(SURFACE, { width = 256, height = 128, default_enable_all_autoplace_controls = false,
		autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
			decorative = { treat_missing_as_default = false, settings = {} } } })
	s.always_day = true
	s.request_to_generate_chunks({ 0, 0 }, 3)
	s.force_generate_chunk_requests()
	local tiles = {}
	for tx = -96, 95 do for ty = -48, 47 do tiles[#tiles + 1] = { name = "refined-concrete", position = { tx, ty } } end end
	s.set_tiles(tiles)
	return s
end

--- the first recipe of `category` whose ingredients and results pass `ok(recipe)`
local function recipe_of(category, ok)
	local names = {}
	for name, r in pairs(prototypes.recipe) do
		for k, v in pairs(r.categories or {}) do          -- (Factorio 2.1: a list of categories)
			if k == category or v == category then names[#names + 1] = name break end
		end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		if ok(prototypes.recipe[name]) then return name end
	end
end
local function has_fluid(list, name)
	for _, x in pairs(list) do if x.type == "fluid" and x.name == name then return true end end
	return false
end
local function items_only(list)
	for _, x in pairs(list) do if x.type ~= "item" then return false end end
	return #list > 0
end

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	--- a bus on tile (bx, by) facing south and `target` with its top left tile at (bx, by + 1)
	local function bus_on(s, fails, what, bus, target, bx, by, extra)
		local b = me_place(s, fails, what, bus, bx + 0.5, by + 0.5, SOUTH)
		local p = prototypes.entity[target]
		local w, h = p.tile_width, p.tile_height
		local t = me_place(s, fails, what, target, bx + w / 2, by + 1 + h / 2, extra)
		return b, t
	end

	function T.setup(_)
		if not active() then return {} end
		local fails, what = {}, "krastorio2"
		local s = surface()
		power(s, fails, what, -62, -30)
		local ctrl = me_place(s, fails, what, "me-network-controller", -54, -30)
		local drive = me_drive(s, fails, what, -52.5, -30.5, { ["copper-plate"] = 500, ["automation-science-pack"] = 400,
			["logistic-science-pack"] = 400, ["iron-gear-wheel"] = 400, ["electronic-circuit"] = 400, ["iron-plate"] = 400 })
		local fdrive = me_drive(s, fails, what, -51.5, -30.5, {}, "64k", true)
		if fdrive then
			for name, amount in pairs({ water = 50000, [MATTER] = 20000 }) do
				local got = remote.call(NET, "store_fluid_in_drive", fdrive, name, amount)
				if (got or 0) < amount then fails[#fails + 1] = what .. ": only " .. tostring(got) .. " " .. name .. " in the fluid drive" end
			end
		end
		local members = { ctrl, drive, fdrive }
		local sc = {}
		--- the buses in a row at y = -12, each target below its bus, 3 tiles between two targets
		local x = -66
		local function add(key, bus, target)
			local b, t = bus_on(s, fails, what, bus, target, x, -12)
			x = x + prototypes.entity[target].tile_width + 3
			members[#members + 1] = b
			sc[key], sc[key .. "_t"] = b, t
		end
		add("wh", "me-import-bus", "kr-warehouse")
		add("sb", "me-export-bus", "kr-strongbox")
		add("rq", "me-storage-bus", "kr-requester-warehouse")
		add("big", "me-export-bus", "kr-big-storage-tank")
		add("huge", "me-storage-bus", "kr-huge-storage-tank")
		add("lab", "me-export-bus", "kr-advanced-lab")
		add("server", "me-export-bus", "kr-research-server")
		add("assoc", "me-export-bus", "kr-matter-associator")
		add("plant", "me-import-bus", "kr-matter-plant")
		--- the steel pipes: an interface with a steel pipe east, a steel pipe to ground south (its pipe end facing the
		--- interface) and a vanilla pipe west
		local ix = x + 2
		local iface = me_place(s, fails, what, "me-network-interface", ix + 0.5, -11.5)
		members[#members + 1] = iface
		sc.iface = iface
		sc.steel = me_place(s, fails, what, "kr-steel-pipe", ix + 1.5, -11.5)
		sc.steel_ug = me_place(s, fails, what, "kr-steel-pipe-to-ground", ix + 0.5, -10.5, { direction = defines.direction.north })
		sc.pipe = me_place(s, fails, what, "pipe", ix - 0.5, -11.5)
		me_connect(fails, what, members)
		--- the targets' contents
		if sc.wh_t then sc.wh_t.insert{ name = "iron-plate", count = 300 } end
		if sc.rq_t then sc.rq_t.insert{ name = "stone", count = 77 } end
		if sc.huge_t then sc.huge_t.insert_fluid{ name = "crude-oil", amount = 5000 } end
		--- the research server and the matter machines: a recipe each
		sc.server_recipe = recipe_of("kr-research-data", function(r) return items_only(r.ingredients) end)
			or recipe_of("kr-t2-tech-cards", function(r) return items_only(r.ingredients) end)
		sc.assoc_recipe = recipe_of("kr-matter-deconversion", function(r) return has_fluid(r.ingredients, MATTER) end)
		sc.plant_recipe = recipe_of("kr-matter-conversion", function(r) return has_fluid(r.products, MATTER) end)
		for _, k in ipairs({ "server", "assoc", "plant" }) do
			local m, r = sc[k .. "_t"], sc[k .. "_recipe"]
			if m and r then
				m.force.recipes[r].enabled = true
				m.set_recipe(r)
			elseif m then
				fails[#fails + 1] = what .. ": no recipe for " .. m.name
			end
		end
		storage.krastorio2_595 = { scene = sc }
		return fails
	end

	local function report(st, note)
		st.done = true
		me_report("KRASTORIO2", "Krastorio 2 targets (issue #595)", st.problems or {}, note)
	end

	function T.tick()
		local tick = game.tick
		local st = storage.krastorio2_595
		if not active() then
			if tick >= START and not (st and st.done) then
				storage.krastorio2_595 = { done = true }
				me_report("KRASTORIO2", "Krastorio 2 targets (issue #595)", {}, "skipped: no Krastorio 2")
			end
			return
		end
		if not st or st.done or tick < START then return end
		local sc = st.scene
		local problems = st.problems or {}
		st.problems = problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		if not st.started then
			st.started = true
			for _, k in ipairs({ "wh", "sb", "rq", "big", "huge", "lab", "server", "assoc", "plant", "wh_t", "sb_t", "rq_t", "big_t",
					"huge_t", "lab_t", "server_t", "assoc_t", "plant_t", "iface", "steel", "steel_ug", "pipe" }) do
				if not (sc[k] and sc[k].valid) then expect(false, k .. " was not built") end
			end
			if #problems > 0 then return report(st, "the scene was not built") end
			remote.call(IO, "set_bus_filters", sc.wh, { "iron-plate" })
			remote.call(IO, "set_bus_filters", sc.sb, { "copper-plate" })
			remote.call(IO, "set_bus_filters", sc.big, { "fluid/water" })
			remote.call(IO, "set_bus_filters", sc.lab, { "automation-science-pack", "logistic-science-pack" })
			local server = {}
			for _, i in pairs(prototypes.recipe[sc.server_recipe].ingredients) do server[#server + 1] = i.name end
			remote.call(IO, "set_bus_filters", sc.server, server)
			st.server_items = server
			remote.call(IO, "set_bus_filters", sc.assoc, { "fluid/" .. MATTER })
			remote.call(IO, "set_bus_filters", sc.plant, { "fluid/" .. MATTER })
			--- what the matter plant "made": its output box filled by hand
			local out
			for i = 1, sc.plant_t.fluids_count do        -- (the boxes the recipe uses: the index is the entity's, not the prototype's)
				local b = sc.plant_t.get_fluid_box_prototype(i)     -- (Factorio 2.1: a list of the box's prototypes)
				for _, x in pairs(b and b.object_name and { b } or b or {}) do
					if x.production_type == "output" then out = out or i end
				end
			end
			st.matter_temp = prototypes.fluid[MATTER].default_temperature
			if out then sc.plant_t.set_fluid(out, { name = MATTER, amount = 500, temperature = st.matter_temp }) end
			expect(out ~= nil, "the matter plant (" .. tostring(sc.plant_recipe) .. ") has no output box")
			st.matter_before = remote.call(FL, "count", sc.wh, MATTER, "any")
			--- every warehouse and strongbox of Krastorio 2 has a type the buses work with
			for name, p in pairs(prototypes.entity) do
				if name:find("^kr%-.*warehouse$") or name:find("^kr%-.*strongbox$") then
					expect(p.type == "container" or p.type == "logistic-container", name .. " is a " .. p.type)
				end
			end
			return
		end
		if tick < CHECK then return end
		local function n(name) return remote.call(NET, "count", sc.wh, name) end
		local function f(name) return remote.call(FL, "count", sc.wh, name, "any") end
		--- items
		expect(sc.wh_t.get_item_count("iron-plate") == 0 and n("iron-plate") == 700,
			"import bus on a warehouse: " .. sc.wh_t.get_item_count("iron-plate") .. " left in it, the network " .. n("iron-plate") .. " (700)")
		expect(sc.sb_t.get_item_count("copper-plate") + n("copper-plate") == 500 and sc.sb_t.get_item_count("copper-plate") > 0,
			"export bus into a strongbox: " .. sc.sb_t.get_item_count("copper-plate") .. ", the network " .. n("copper-plate"))
		expect(n("stone") == 77, "storage bus on a requester warehouse: the network shows " .. n("stone") .. " stone (77)")
		local stored = remote.call(NET, "insert", sc.wh, "stone", 23)
		remote.call(SB, "visit", sc.rq)
		expect(stored == 23 and sc.rq_t.get_item_count("stone") == 100, "the network stored " .. tostring(stored)
			.. " stone, the requester warehouse holds " .. sc.rq_t.get_item_count("stone") .. " (100)")
		--- fluids
		local water = sc.big_t.get_fluid_count("water")
		expect(water > 0 and math.abs(water + f("water") - 50000) < 0.01, "export bus into a big storage tank: " .. water .. ", the network " .. f("water"))
		expect(math.abs(f("crude-oil") - 5000) < 0.01, "storage bus on a huge storage tank: the network shows " .. f("crude-oil") .. " crude oil (5000)")
		--- research
		local lab = sc.lab_t.get_inventory(defines.inventory.lab_input)
		expect(lab and lab.get_item_count("automation-science-pack") > 0 and lab.get_item_count("logistic-science-pack") > 0,
			"export bus into the advanced lab: " .. (lab and lab.get_item_count("automation-science-pack") or -1) .. " automation, "
			.. (lab and lab.get_item_count("logistic-science-pack") or -1) .. " logistic packs")
		local into = sc.server_t.get_inventory(defines.inventory.crafter_input)
		local got = 0
		for _, i in ipairs(st.server_items) do got = got + (into and into.get_item_count(i) or 0) end
		expect(got > 0 or (n(st.server_items[1]) < 400 and #st.server_items > 0),
			"export bus into the research server (" .. sc.server_recipe .. "): nothing of " .. table.concat(st.server_items, ", "))
		--- matter
		local in_assoc = sc.assoc_t.get_fluid_count(MATTER)
		expect(in_assoc > 0, "export bus into a matter associator (" .. tostring(sc.assoc_recipe) .. "): no matter arrived")
		local back = remote.call(NET, "fluid_count", sc.wh, MATTER, st.matter_temp)
		expect(sc.plant_t.get_fluid_count(MATTER) < 1 and back > 20000 - in_assoc,
			"import bus on a matter plant: " .. sc.plant_t.get_fluid_count(MATTER) .. " left in it, the network " .. back
			.. " at " .. tostring(st.matter_temp) .. " degrees")
		--- steel pipes
		local function joined(e)                     -- (Factorio 2.1: a list of { entity, index })
			for _, o in pairs(e.get_fluid_box_neighbours(1) or {}) do
				if o.entity and o.entity.valid and o.entity.name == "me-network-interface-side" then return true end
			end
			return false
		end
		expect(joined(sc.pipe), "a vanilla pipe beside the ME Interface is not connected to its side")
		expect(joined(sc.steel), "a steel pipe beside the ME Interface is not connected to its side")
		expect(joined(sc.steel_ug), "a steel pipe to ground beside the ME Interface is not connected to its side")
		report(st, "warehouse, strongbox, requester warehouse, big and huge tank, advanced lab, research server ("
			.. tostring(sc.server_recipe) .. "), matter associator (" .. tostring(sc.assoc_recipe) .. ") and plant, steel pipes")
	end

	function T.running(check) check(storage.krastorio2_595 and storage.krastorio2_595.done, "Krastorio 2 targets (issue #595)") end
	return T
end
