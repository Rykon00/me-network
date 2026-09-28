--- Places every assembling machine that has an item, gives it a recipe and power, then lets
--- the benchmark run the map. Any runtime error in Gregtorio's scripts or the entities fails
--- the run. Results are logged as DEVCHECK-RUNTIME lines.
--- ME network (prototypes/120-fork-ae2.lua): controller, one drive per tier, interface and
--- terminal on their own power; checked during the benchmark run (see on_nth_tick below).
--- Molds (prototypes/130-fork-molds.lua): an LV alloy smelter with a mold recipe must stop
--- without a mold, run with a mold in its mold slot and keep the mold there.
local ME_Y = 100
local ME_ITEM = "iron-plate"

function setup_me_network(s)
	local fails = {}
	local function place(name, x, y)
		local ok, e = pcall(function()
			return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
		end)
		if not (ok and e) then fails[#fails + 1] = name .. ": " .. tostring(e) end
		return ok and e or nil
	end
	local eei = place("electric-energy-interface", 0, ME_Y)
	if eei then
		eei.power_production = 1e6      -- J per tick (60 MW); a script-created interface starts at 0
		eei.electric_buffer_size = 1e7
	end
	place("substation", 3, ME_Y)
	place("me-controller", 6, ME_Y)
	for i, tier in ipairs({ "1k", "4k", "16k", "64k", "256k" }) do place("me-drive-" .. tier, 2 + i, ME_Y + 3) end
	place("me-interface", 3, ME_Y + 5)
	place("me-terminal", 5, ME_Y + 5)
	place("iron-chest", 7, ME_Y + 5)
	local drive = s.find_entity("me-drive-16k", { 5.5, ME_Y + 3.5 })
	if drive then drive.insert{ name = ME_ITEM, count = 100 } end
	return fails
end

script.on_nth_tick(300, function(event)
	if storage.me_checked or event.tick == 0 then return end   -- also fires at tick 0, before power
	storage.me_checked = true
	local s = game.surfaces[1]
	local function find(name, x, y) return s.find_entity(name, { x + 0.5, y + 0.5 }) end
	local terminal = find("me-terminal", 5, ME_Y + 5)
	local interface = find("me-interface", 3, ME_Y + 5)
	local chest = find("iron-chest", 7, ME_Y + 5)
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	expect(terminal and interface and chest, "ME entities missing")
	if #problems == 0 then
		expect(interface.get_requester_point().trash_not_requested, "ME interface: trash_not_requested not set on build")
		expect(terminal.status == defines.entity_status.working, "ME terminal not usable (status " .. (function() for k, v in pairs(defines.entity_status) do if v == terminal.status then return k end end return tostring(terminal.status) end)() .. ", energy " .. terminal.energy .. ")")
		local network = s.find_logistic_network_by_position(terminal.position, terminal.force)
		expect(network, "ME terminal: no logistic network from the ME controller")
		if network then
			expect(network.get_item_count(ME_ITEM) == 100, "ME network: expected 100 " .. ME_ITEM .. ", got " .. network.get_item_count(ME_ITEM))
			local moved = remote.call("gregtorio-me-terminal", "withdraw", terminal, chest, ME_ITEM, "normal", 30)
			expect(moved == 30 and chest.get_item_count(ME_ITEM) == 30, "ME terminal withdraw: moved " .. tostring(moved))
			local stack = chest.get_inventory(defines.inventory.chest)[1]
			local stored = remote.call("gregtorio-me-terminal", "store_stack", terminal, stack)
			expect(stored == 30 and network.get_item_count(ME_ITEM) == 100, "ME terminal store: stored " .. tostring(stored))
		end
	end
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. p) end
	log("DEVCHECK-RUNTIME-ME " .. (#problems == 0 and "ok" or "failed"))
end)

local MOLD_Y = 120
local MOLD_RECIPE = "glass-alloy-smelter"

function setup_mold_test(s)
	local ok, err = pcall(function()
		local eei = s.create_entity{ name = "electric-energy-interface", position = { 0, MOLD_Y }, force = "player" }
		eei.power_production = 1e6
		eei.electric_buffer_size = 1e7
		s.create_entity{ name = "substation", position = { 3, MOLD_Y }, force = "player" }
		local m = s.create_entity{ name = "lv-alloy-smelter", position = { 6, MOLD_Y }, force = "player", raise_built = true }
		m.force.recipes[MOLD_RECIPE].enabled = true
		m.set_recipe(MOLD_RECIPE)
		m.insert{ name = "glass-dust", count = 20 }
		storage.mold_machine = m
	end)
	if not ok then return { "mold test setup: " .. tostring(err) } end
	return {}
end

script.on_event(defines.events.on_tick, function(event)
	local m = storage.mold_machine
	if storage.mold_done then return end
	local phase
	if not storage.mold_phase1 and event.tick >= 60 then
		phase = 1
		storage.mold_phase1 = event.tick
	elseif storage.mold_phase1 and event.tick >= storage.mold_phase1 + 450 then
		phase = 2
		storage.mold_done = true
	else
		return
	end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	expect(m and m.valid, "mold test machine missing")
	if #problems == 0 then
		local glass = m.get_inventory(defines.inventory.crafter_output or defines.inventory.assembling_machine_output).get_item_count("glass")
		local inv = m.get_module_inventory()
		if phase == 1 then
			expect(m.disabled_by_script, "mold test: machine without mold is not stopped")
			expect(glass == 0, "mold test: crafted " .. glass .. " glass without a mold")
			expect(inv and inv.insert{ name = "mold", count = 1 } == 1, "mold test: mold does not fit into the mold slot")
		else
			expect(not m.disabled_by_script, "mold test: machine with mold is still stopped")
			expect(glass > 0, "mold test: no glass crafted with the mold inserted")
			expect(inv.get_item_count("mold") == 1, "mold test: mold left the mold slot")
			expect(m.get_item_count("mold") == 1, "mold test: mold was duplicated or moved")
			log("DEVCHECK-RUNTIME-MOLD " .. (#problems == 0 and "ok" or "failed") .. " (glass " .. glass .. ")")
		end
	end
	for _, p in pairs(problems) do log("DEVCHECK-RUNTIME-FAIL " .. p) end
	if #problems > 0 and phase == 1 then
		storage.mold_done = true
		log("DEVCHECK-RUNTIME-MOLD failed")
	end
end)

script.on_init(function()
	local s = game.surfaces[1]
	s.always_day = true
	s.request_to_generate_chunks({ 0, 0 }, 12)
	s.force_generate_chunk_requests()
	local recipe_for = {}
	for rn, r in pairs(prototypes.recipe) do recipe_for[r.category] = recipe_for[r.category] or rn end
	local x, y, placed, with_recipe, fails = -150, -150, 0, 0, {}
	for name, p in pairs(prototypes.get_entity_filtered{ { filter = "type", type = "assembling-machine" } }) do
		if p.items_to_place_this and #p.items_to_place_this > 0 then
			local ok, e = pcall(function()
				return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
			end)
			if ok and e then
				placed = placed + 1
				for c, _ in pairs(p.crafting_categories) do
					if recipe_for[c] and pcall(function() e.set_recipe(recipe_for[c]) end) then
						with_recipe = with_recipe + 1
						break
					end
				end
				s.create_entity{ name = "electric-energy-interface", position = { x, y + 7 }, force = "player" }
				s.create_entity{ name = "substation", position = { x + 5, y + 7 }, force = "player" }
			else
				fails[#fails + 1] = name .. ": " .. tostring(e)
			end
			x = x + 14
			if x > 150 then x = -150; y = y + 14 end
		end
	end
	for _, f in pairs(setup_me_network(s)) do fails[#fails + 1] = f end
	for _, f in pairs(setup_mold_test(s)) do fails[#fails + 1] = f end
	log("DEVCHECK-RUNTIME placed=" .. placed .. " with_recipe=" .. with_recipe .. " failed=" .. #fails)
	for _, f in pairs(fails) do log("DEVCHECK-RUNTIME-FAIL " .. f) end
end)
