--- Runtime test of ME Network with Space Exploration (tools/devcheck/devcheck.py se): loaded with Space Exploration and its
--- dependencies only, on a new map. Every part reports a DEVCHECK-SE-<KEY> line ("ok ..." or "failed ..."), every problem a
--- DEVCHECK-SE-FAIL line; DEVCHECK-SE-DONE at the end.
---   PLACE    every block of the mod can be built on Space Exploration's space platform scaffold, space platform plating
---            and spaceship floor (LuaSurface.can_place_entity as a player builds it), and on Nauvis.
---   BUILD    a network on spaceship floor in Nauvis Orbit: controller (powered by an electric energy interface), a drive with
---            item cells and a fluid cell, a pattern provider with an encoded pattern and a priority, an export bus with a
---            filter and a card, a storage bus on a chest, an interface with a row, an IO port with a cell, a cell workbench
---            with a cell, a pattern terminal, an access point, a level maintainer, a pair of P2P tunnels, a crafting unit
---            and storage, and a quantum bridge whose partner stands in a second network on Nauvis.
---   LAUNCH   the ship is moved to a surface of its own the way Space Exploration's SpaceshipClone.clone moves one:
---            LuaSurface.clone_brush over its tiles, then every original destroyed with raise_destroy. (Its launch itself
---            starts from a button of its window and from nothing a script can call: the real flight is in the in-game
---            checklist.) Nothing lies on the ground where it stood, and the network holds what it held.
---   TRAVEL   the network works on the ship's surface for two seconds: powered, the interface filled from the drive, the
---            quantum bridge linked to Nauvis again.
---   LAND     the ship is moved onto Nauvis the same way, next to the partner network: everything as before the launch.
---   COPY     a clone whose source stays is still a copy: an empty drive with the source's priority, the source keeps its cells.
---   PAD      storage buses read a cargo rocket landing pad and a delivery cannon chest of Space Exploration.
---   JOB      issue #704: a crafting job that runs over both moves. The level maintainer keeps 32 iron sticks, a second
---            pattern provider next to an assembling machine 2 crafts them (16 crafts in one hand-over, about 640 ticks),
---            the Crafting CPU is in the mode "automation". After each move the job is the same job, running on the CPU
---            at the new place, the maintainer's row and the job's owner name each other, the machine's lease went along
---            (no "machine-lost"), the mode stayed; at the end the job is done and the 32 sticks are in the network.
---   LOGISTICS issue #707: a logistic network on the ship that flies along. A roboport with 10 logistic robots, an ME
---            Logistic Interface (Automatic mode) with an offer row (40 gears, of which a vanilla requester chest wants 20) and
---            a request row (keep 20 stone bricks, which a vanilla passive provider holds), an ME Logistic Storage Bus that
---            shows a vanilla storage chest (120 plastic bars). The robots are at work during both moves. After each move:
---            the interface and the bus are in the roboport's logistic network of the new place (`rec.lid`, the bus's
---            claim), the rows are the same, the interface has exactly its three hidden chests and none stands alone, the
---            automatic mode keeps no stock of a logistic network that is gone, and every gear, brick and plastic bar is
---            there exactly once (cells, chests, hidden chests, robots' cargo, the ground). At the end the requester has its
---            20 gears and the network its 20 bricks. Robot attrition: between the moves a robot that carries an item is
---            crashed the way the mod Robot Attrition (a dependency of Space Exploration) crashes one (its bot_crash: the
---            cargo into a "logistic-robot-dropped-cargo" container marked for deconstruction, the robot dies; the mod itself
---            only strikes logistic networks with more than 50 robots in the air and never on a spaceship). The item is still
---            counted once, a construction robot brings it back and the deliveries end all the same.
---   SPACEASM issue #711: the ME Space Molecular Assembler. It can be built on space platform scaffold and plating, not
---            on spaceship floor and not on Nauvis (PLACE knows it); Space Exploration made no "-grounded" or "-spaced" twin
---            of it; it has the ME Molecular Assembler's categories and "space-crafting", its speed, five Acceleration Card
---            slots and no power connection. On scaffold on a surface of its own a network (controller, drive, a 1k
---            crafting storage, a pattern provider, the assembler next to it) crafts a recipe of the category "space-crafting"
---            that no ME Molecular Assembler can craft (the first one with item ingredients only), started as a job; the
---            assembler is a member of the network that carries it (the provider is cabled only through it).
---   ZONES    issue #713: what a surface is called. Nauvis Orbit and Nauvis by their zone names from Space Exploration's
---            remote interface, asked once per surface while the answer is kept (a second question in the same tick makes
---            no call); a surface that is no zone by its own name; the map marker of a message with the zone's name after
---            it; the quantum bridge's window data names the partner's zone.
---   FRAGMENTS issue #710: core fragment processing. An ME Storage Bus on Space Exploration's fragment processing machine
---            (the machine of the recipe category "core-fragment-processing", its pulveriser) makes the machine's output
---            slots network storage to take from: the network counts what lies there, an extraction takes it out of the
---            machine, and what the network stores never goes into the machine. A storage bus on an assembling machine 2
---            (no fragment processing) faces no item storage, as before.
---   CHANCE   issue #710, part c: a product that comes by chance. A second pulveriser next to an ME Pattern Provider with a
---            crafting pattern of the helper's recipe zz-me-se-chance (2 stone into an iron stick and, at 50 %, an iron gear
---            wheel). Five jobs of 6 gears each, one after the other: every job ends "done" with at least the 6 gears it was
---            asked for in the network (the plan runs the recipe 12 times; when chance gave fewer than 6 the job adds runs
---            and takes their stone from the network), the sticks of every run are in the network, and at least one of the
---            five jobs needed more runs than its plan (else the test shows nothing: another seed, other amounts).
---   SURFACE  Space Exploration's question before it deletes a zone's surface is answered with "no" while ME blocks stand
---            on it; a surface with a network that is deleted leaves no member, drive or network in the mod's storage.
---
--- Issue #706, `devcheck.py launch` (the startup setting zz-me-se-real-launch of settings.lua): none of the steps above runs
--- by the tick. The harness drives a headless server through RCON instead: the remote interface "me-se-launch" below builds
--- the same network inside a real spaceship of Space Exploration (spaceship floor, walls around it, a rocket engine in the
--- back wall, a booster tank with liquid rocket fuel, the console; power from charged accumulators, because Space
--- Exploration counts an electric energy interface as a generator far too heavy for a ship), the harness waits for Space
--- Exploration's integrity check and calls its own Spaceship.launch and Spaceship.land_at_position in its Lua state
--- (`/silent-command __space-exploration__ ...`), and the interface compares what the network holds after each move.

local NET, IO, SB, AC, PT = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-storagebus", "gregtorio-me-autocraft",
	"gregtorio-me-pattern-terminal"
local QB, P2P, PORT, BENCH, MOVE = "gregtorio-me-qbridge", "gregtorio-me-p2p", "gregtorio-me-ioport", "gregtorio-me-workbench",
	"me-network-space-exploration"
local SE = "space-exploration"

local fails = {}
local function fail(what) fails[#fails + 1] = what log("DEVCHECK-SE-FAIL " .. what) end
local function report(key, problems, text)
	for _, p in ipairs(problems) do fail(key .. ": " .. p) end
	local line = (#problems == 0 and "ok" or "failed") .. " (" .. text .. ")"
	log("DEVCHECK-SE-" .. key .. " " .. line)
	return line .. (#problems > 0 and (" PROBLEMS: " .. table.concat(problems, " ;; ")) or "")
end

local SHIP = { x1 = -8, y1 = -6, x2 = 21, y2 = 5 }      -- the ship's tiles in Nauvis Orbit (inclusive; x 10..20: the logistic network of issue #707)
local REAL = { x1 = -8, y1 = -6, x2 = 21, y2 = 11 }     -- issue #706: the real ship (walls on its border, console, tank and engine below the network)
local LIF, LIF_NAME = "gregtorio-me-logistic-interface", "me-logistic-interface"
local LIF_CHESTS = { LIF_NAME .. "-provider", LIF_NAME .. "-requester", LIF_NAME .. "-storage" }
local GOODS = { ["iron-gear-wheel"] = 100, ["stone-brick"] = 200, ["plastic-bar"] = 120 }   -- issue #707: what must stay exactly once
local REAL_LAUNCH = settings.startup["zz-me-se-real-launch"] and settings.startup["zz-me-se-real-launch"].value
local FLIGHT = "me-se-flight"                           -- the surface it flies on
local LAND = { dx = 60, dy = 40 }                       -- where it lands on Nauvis, relative to its tiles

local function tiles(surface, name, x1, y1, x2, y2)
	surface.request_to_generate_chunks({ (x1 + x2) / 2, (y1 + y2) / 2 }, 3)
	surface.force_generate_chunk_requests()
	local list = {}
	for x = x1, x2 do for y = y1, y2 do list[#list + 1] = { name = name, position = { x, y } } end end
	surface.set_tiles(list)
end

local function place(s, problems, name, x, y, extra)
	local def = { name = name, position = { x, y }, force = "player", raise_built = true }
	for k, v in pairs(extra or {}) do def[k] = v end
	local ok, e = pcall(s.create_entity, def)
	if not (ok and e) then problems[#problems + 1] = "could not place " .. name .. ": " .. tostring(e) return nil end
	return e
end

local function orbit()
	local zone = remote.call(SE, "get_zone_from_name", { zone_name = "Nauvis Orbit" })
	return zone and remote.call(SE, "zone_get_make_surface", { zone_index = zone.index }), zone
end

--------------------------------------------------------------------------------
--- PLACE
--------------------------------------------------------------------------------

local function place_test()
	local problems = {}
	local s = orbit()
	if not s then report("PLACE", { "no surface of Nauvis Orbit" }, "") return end
	local floors = { { "se-space-platform-scaffold", 40 }, { "se-space-platform-plating", 60 }, { "se-spaceship-floor", 80 } }
	for _, f in ipairs(floors) do
		if not prototypes.tile[f[1]] then problems[#problems + 1] = "no tile " .. f[1] else tiles(s, f[1], f[2], -4, f[2] + 8, 4) end
	end
	local names, n = {}, 0
	for name, item in pairs(prototypes.item) do
		local e = item.place_result
		if e and (e.name:sub(1, 3) == "me-" or item.name == "fluix-cable") and not item.hidden then names[#names + 1] = e.name end
	end
	table.sort(names)
	local nauvis = game.surfaces.nauvis
	--- (issue #711: the ME Space Molecular Assembler stands on the platforms only, not on a ship and not on a planet)
	local SPACE_ONLY = { ["me-space-molecular-assembler"] = { ["se-spaceship-floor"] = false } }
	for _, name in ipairs(names) do
		n = n + 1
		local rule = SPACE_ONLY[name]
		for _, f in ipairs(floors) do
			local want = not (rule and rule[f[1]] == false)
			if prototypes.tile[f[1]] and s.can_place_entity{ name = name, position = { f[2] + 4.5, 0.5 }, force = "player",
					build_check_type = defines.build_check_type.manual } ~= want then
				problems[#problems + 1] = name .. (want and " cannot" or " can") .. " be built on " .. f[1]
			end
		end
		local pos = nauvis.find_non_colliding_position(name, { 200, 200 }, 40, 1)
		if (pos ~= nil) ~= (rule == nil) then problems[#problems + 1] = name .. (rule and " can" or " cannot") .. " be built on Nauvis" end
	end
	report("PLACE", problems, n .. " blocks on scaffold, plating, spaceship floor and Nauvis")
end

--------------------------------------------------------------------------------
--- SPACEASM (issue #711)
--------------------------------------------------------------------------------

local SPACE_ASM = "me-space-molecular-assembler"

--- the first recipe (by name) of the category "space-crafting" with item ingredients and products only that the ME Molecular
--- Assembler cannot craft
local function space_recipe()
	local plain = {}
	for c in pairs(prototypes.entity["me-molecular-assembler"].crafting_categories) do plain[c] = true end
	local names = {}
	for name, r in pairs(prototypes.recipe) do
		local space, other = false, false
		for k, v in pairs(r.categories or {}) do                 -- (a list of names, or names as keys)
			local c = type(k) == "string" and k or v
			if c == "space-crafting" then space = true end
			if plain[c] then other = true end
		end
		local items = #r.products > 0
		for _, x in pairs(r.ingredients) do if x.type ~= "item" then items = false end end
		for _, x in pairs(r.products) do
			if x.type ~= "item" or (x.probability or x.independent_probability or 1) < 1 or not x.amount then items = false end
		end
		if space and not other and items and not r.hidden then names[#names + 1] = name end
	end
	table.sort(names)
	return names[1], #names
end

local function space_asm_build()
	local problems = {}
	local proto = prototypes.entity[SPACE_ASM]
	if not proto then report("SPACEASM", { "no entity " .. SPACE_ASM }, "") return end
	--- (a surface of its own: the ship's orbit must be free of ME blocks after the launch)
	local s = game.create_surface("me-se-platform", { width = 128, height = 128 })
	local X, Y = 0, 0
	tiles(s, "se-space-platform-scaffold", X - 2, Y - 4, X + 12, Y + 4)
	local function at(name, x, y) return place(s, problems, name, x, y) end
	local eei = at("electric-energy-interface", X, Y - 2)
	if eei then eei.power_production = 5e6 eei.electric_buffer_size = 5e7 eei.energy = 5e7 end
	at("substation", X + 3, Y - 2)
	local a = {}
	storage.space_asm = a
	a.ctrl = at("me-network-controller", X + 1, Y + 1)        -- (tiles X..X+1, Y..Y+1)
	a.drive = at("me-drive", X + 2.5, Y + 0.5)
	a.cpu = at("me-1k-crafting-storage", X + 3.5, Y + 0.5)
	a.asm = at(SPACE_ASM, X + 4.5, Y + 0.5)                   -- (the provider is in the network through the assembler alone)
	a.provider = at("me-pattern-provider", X + 5.5, Y + 0.5)
	local recipe, n = space_recipe()
	a.recipe, a.recipes = recipe, n
	if not recipe then problems[#problems + 1] = "no recipe of the category space-crafting with item ingredients only" end
	if recipe and a.drive and a.provider then
		local r = prototypes.recipe[recipe]
		game.forces.player.recipes[recipe].enabled = true
		local inv = game.create_inventory(1)
		inv[1].set_stack{ name = "me-16k-storage-cell", count = 1 }
		if not remote.call(NET, "insert_cell", a.drive, inv[1], 1) then problems[#problems + 1] = "no cell in the drive" end
		inv.destroy()
		for _, ing in pairs(r.ingredients) do remote.call(NET, "store_in_drive", a.drive, ing.name, ing.amount * 3) end
		local pinv = game.create_inventory(2)
		pinv.insert{ name = "me-blank-pattern", count = 1 }
		local where, why = remote.call(PT, "encode_def", pinv, nil, { kind = "crafting", recipe = recipe })
		local stack = pinv.find_item_stack("me-encoded-pattern")
		if not (where and stack and remote.call(AC, "insert_pattern", a.provider, stack)) then
			problems[#problems + 1] = "no pattern of " .. recipe .. " in the provider: " .. tostring(why)
		end
		pinv.destroy()
		a.product = r.products[1].name
		a.amount = r.products[1].amount * 2
	end
	--- the prototype: the ME Molecular Assembler's categories and space-crafting, its speed, five card slots, no twin
	local base = prototypes.entity["me-molecular-assembler"]
	for c in pairs(base.crafting_categories) do
		if not proto.crafting_categories[c] then problems[#problems + 1] = "it lacks the ME Molecular Assembler's category " .. c end
	end
	if not proto.crafting_categories["space-crafting"] then problems[#problems + 1] = "it lacks the category space-crafting" end
	for c in pairs(proto.crafting_categories) do
		if not base.crafting_categories[c] and c ~= "space-crafting" then problems[#problems + 1] = "a category of its own: " .. c end
	end
	if proto.get_crafting_speed() ~= base.get_crafting_speed() then problems[#problems + 1] = "its crafting speed is " .. proto.get_crafting_speed() end
	if proto.module_inventory_size ~= base.module_inventory_size then problems[#problems + 1] = "its card slots: " .. tostring(proto.module_inventory_size) end
	if proto.electric_energy_source_prototype then problems[#problems + 1] = "it has a power connection" end
	for _, suffix in ipairs({ "-grounded", "-spaced" }) do
		if prototypes.entity[SPACE_ASM .. suffix] then problems[#problems + 1] = "Space Exploration made the twin " .. SPACE_ASM .. suffix end
		if base and prototypes.entity["me-molecular-assembler" .. suffix] then problems[#problems + 1] = "Space Exploration made the twin me-molecular-assembler" .. suffix end
	end
	a.problems = problems
end

local function space_asm_start()
	local a = storage.space_asm
	if not (a and a.recipe and a.ctrl and a.ctrl.valid) then return end
	if not remote.call(NET, "same_network", a.ctrl, a.provider) then a.problems[#a.problems + 1] = "the provider behind the assembler is not in the network" end
	local net = remote.call(NET, "network", a.ctrl)
	if not (net and net.status == "ok") then a.problems[#a.problems + 1] = "the network on the scaffold does not work: " .. tostring(net and net.status) end
	local id, why = remote.call(AC, "start", a.ctrl, a.product, a.amount)
	a.job = id
	if not id then a.problems[#a.problems + 1] = "the job of " .. a.amount .. " " .. a.product .. " did not start: " .. tostring(why) end
end

local function space_asm_done()
	local a = storage.space_asm
	if not a then return end
	local problems = a.problems or {}
	if a.job then
		local job = remote.call(AC, "job", a.job)
		local got = remote.call(NET, "count", a.ctrl, a.product)
		if not (job and job.status == "done" and got == a.amount) then
			problems[#problems + 1] = "the job of " .. a.amount .. " " .. a.product .. " is " .. tostring(job and job.status) .. " (" .. serpent.line(job and job.reason)
				.. "), the network holds " .. tostring(got)
		end
	end
	report("SPACEASM", problems, "the ME Space Molecular Assembler on scaffold in orbit crafted " .. tostring(a.amount) .. " " .. tostring(a.product)
		.. " (recipe " .. tostring(a.recipe) .. ", one of " .. tostring(a.recipes) .. " space-crafting recipes with item ingredients only)")
end

--------------------------------------------------------------------------------
--- FRAGMENTS (issue #710)
--------------------------------------------------------------------------------

--- the machine of core fragment processing (by its recipe category)
local function fragment_machine()
	local names = {}
	for name, p in pairs(prototypes.get_entity_filtered{ { filter = "crafting-machine" } }) do
		if p.crafting_categories and p.crafting_categories["core-fragment-processing"] and not p.hidden then names[#names + 1] = name end
	end
	table.sort(names)
	return names[1]
end

local function fragments_build()
	local problems = {}
	local f = { problems = problems }
	storage.fragments = f
	local name = fragment_machine()
	f.machine_name = name
	if not name then problems[#problems + 1] = "no machine of the category core-fragment-processing" return end
	local s = game.create_surface("me-se-fragments", { width = 128, height = 128 })
	tiles(s, "refined-concrete", -16, -16, 30, 16)
	for _, e in pairs(s.find_entities_filtered{ area = { { -16, -16 }, { 31, 17 } } }) do
		if e.valid and e.type ~= "character" then e.destroy() end
	end
	local function at(n, x, y, extra) return place(s, problems, n, x, y, extra) end
	local eei = at("electric-energy-interface", -4, -4)
	if eei then eei.power_production = 5e6 eei.electric_buffer_size = 5e7 eei.energy = 5e7 end
	at("substation", -1, -4)
	f.ctrl = at("me-network-controller", 1, 1)                -- (tiles 0..1, 0..1)
	f.drive = at("me-drive", 2.5, 0.5)
	f.bus = at("me-storage-bus", 3.5, 0.5, { direction = defines.direction.east })
	local p = prototypes.entity[name]
	local w, h = p.tile_width, p.tile_height
	--- the machine east of the bus (its left column at x = 4), without the build event (Space Exploration's own handlers)
	f.machine = at(name, 4 + w / 2, h % 2 == 1 and 0.5 or 1, { raise_built = false })
	--- the control: a storage bus on a machine that does no fragment processing
	f.bus2 = at("me-storage-bus", 2.5, 1.5, { direction = defines.direction.south })
	f.plain = at("assembling-machine-2", 2.5, 3.5, { raise_built = false })
	if f.drive then
		local inv = game.create_inventory(1)
		inv[1].set_stack{ name = "me-16k-storage-cell", count = 1 }
		if not remote.call(NET, "insert_cell", f.drive, inv[1], 1) then problems[#problems + 1] = "no cell in the drive" end
		inv.destroy()
	end
	if f.machine then
		--- a fragment recipe (the first by name with stone and another item among its products): the output slots are the
		--- recipe's, and what a craft would leave there is put there
		local recipes = {}
		for rname, r in pairs(prototypes.recipe) do
			local fragment = false
			for k, v in pairs(r.categories or {}) do
				if (type(k) == "string" and k or v) == "core-fragment-processing" then fragment = true end
			end
			local stone, other = false, nil
			for _, x in pairs(r.products) do
				if x.type == "item" and x.name == "stone" then stone = true
				elseif x.type == "item" and (not other or x.name < other) then other = x.name end
			end
			if fragment and stone and other then recipes[#recipes + 1] = { rname, other } end
		end
		table.sort(recipes, function(x, y) return x[1] < y[1] end)
		local pick = recipes[1]
		if not pick then problems[#problems + 1] = "no core fragment recipe with stone and another item"
		else
			f.recipe, f.other = pick[1], pick[2]
			game.forces.player.recipes[f.recipe].enabled = true
			f.machine.set_recipe(f.recipe)
			local out = f.machine.get_inventory(defines.inventory.crafter_output)
			local a, c = out.insert{ name = "stone", count = 30 }, out.insert{ name = f.other, count = 12 }
			if a ~= 30 or c ~= 12 then problems[#problems + 1] = "the machine's output took " .. a .. " stone and " .. c .. " " .. f.other .. " of 30 and 12" end
		end
	end
	if f.plain then f.plain.get_inventory(defines.inventory.crafter_output).insert{ name = "stone", count = 5 } end
	--- CHANCE (part c): a network of its own (the stone of the first one is in a machine's output), a CPU, a provider with
	--- the pattern of the chance recipe, a second pulveriser next to it
	local c = { jobs = {}, problems = {} }
	storage.chance = c
	local eei2 = at("electric-energy-interface", -4, -12)
	if eei2 then eei2.power_production = 5e6 eei2.electric_buffer_size = 5e7 eei2.energy = 5e7 end
	at("substation", -1, -12)
	c.ctrl = at("me-network-controller", 1, -8)               -- (tiles 0..1, -9..-8)
	c.drive = at("me-drive", 2.5, -8.5)
	c.cpu = at("me-1k-crafting-storage", 2.5, -9.5)
	c.provider = at("me-pattern-provider", 3.5, -8.5)
	c.machine = at(name, 4 + w / 2, (h % 2 == 1 and 0.5 or 1) - 9, { raise_built = false })
	if c.drive and c.provider and prototypes.recipe["zz-me-se-chance"] then
		local inv = game.create_inventory(1)
		inv[1].set_stack{ name = "me-16k-storage-cell", count = 1 }
		remote.call(NET, "insert_cell", c.drive, inv[1], 1)
		inv.destroy()
		remote.call(NET, "store_in_drive", c.drive, "stone", 2000)
		local pinv = game.create_inventory(2)
		pinv.insert{ name = "me-blank-pattern", count = 1 }
		local where, why = remote.call(PT, "encode_def", pinv, nil, { kind = "crafting", recipe = "zz-me-se-chance" })
		local stack = pinv.find_item_stack("me-encoded-pattern")
		if not (where and stack and remote.call(AC, "insert_pattern", c.provider, stack)) then
			c.problems[#c.problems + 1] = "no pattern of the chance recipe in the provider: " .. tostring(why)
		end
		pinv.destroy()
	else
		c.problems[#c.problems + 1] = "the chance network was not built (or no recipe zz-me-se-chance)"
	end
end

--- CHANCE: one job after the other (called every 30 ticks)
local CHANCE_JOBS, CHANCE_AMOUNT = 5, 6
local function chance_tick()
	local c = storage.chance
	if not (c and c.ctrl and c.ctrl.valid) or c.finished then return end
	local function gears() return remote.call(NET, "count", c.ctrl, "iron-gear-wheel") end
	local cur = c.jobs[#c.jobs]
	if cur then
		local job = remote.call(AC, "job", cur.id)
		if job and (job.status == "running" or job.status == "queued") then return end
		cur.status, cur.topups, cur.runs, cur.got = job and job.status, job and job.topups, job and job.total, gears() - cur.before
		if #c.jobs >= CHANCE_JOBS then c.finished = true return end
	end
	local before = gears()
	local id, why = remote.call(AC, "start", c.ctrl, "iron-gear-wheel", CHANCE_AMOUNT)
	if not id then
		c.problems[#c.problems + 1] = "job " .. (#c.jobs + 1) .. " did not start: " .. tostring(why)
		c.finished = true
		return
	end
	c.jobs[#c.jobs + 1] = { id = id, before = before }
end

local function chance_done()
	local c = storage.chance
	if not c then return end
	local problems = c.problems
	local topups, text = 0, {}
	if #c.jobs < CHANCE_JOBS or not c.finished then
		local cur = c.jobs[#c.jobs]
		local job = cur and remote.call(AC, "job", cur.id)
		problems[#problems + 1] = #c.jobs .. " of " .. CHANCE_JOBS .. " jobs ran to their end; the last one: " .. serpent.line(job and { status = job.status,
			wait = job.wait, done = job.done, total = job.total, leases = job.leases, topups = job.topups, reason = job.reason, pool = job.pool })
			.. ", the machine: " .. tostring(c.machine and c.machine.valid and c.machine.status) .. " recipe " .. tostring(c.machine and c.machine.valid and c.machine.get_recipe() and c.machine.get_recipe().name)
	end
	for i, j in ipairs(c.jobs) do
		if j.status then
			if j.status ~= "done" then problems[#problems + 1] = "job " .. i .. " ended " .. tostring(j.status) end
			if (j.got or 0) < CHANCE_AMOUNT then problems[#problems + 1] = "job " .. i .. " made " .. tostring(j.got) .. " of " .. CHANCE_AMOUNT .. " gears" end
			topups = topups + (j.topups or 0)
			text[#text + 1] = tostring(j.got) .. " gears in " .. tostring(j.runs) .. " runs"
		end
	end
	if topups == 0 and #problems == 0 then problems[#problems + 1] = "no job needed more runs than its plan: the test shows nothing (another seed)" end
	local runs = 0
	for _, j in ipairs(c.jobs) do runs = runs + (j.runs or 0) end
	local sticks = c.ctrl and c.ctrl.valid and remote.call(NET, "count", c.ctrl, "iron-stick") or -1
	if c.finished and sticks ~= runs then problems[#problems + 1] = "the network holds " .. sticks .. " iron sticks after " .. runs .. " runs" end
	report("CHANCE", problems, CHANCE_JOBS .. " jobs of " .. CHANCE_AMOUNT .. " gears at 50 % a run (planned 12 runs each): "
		.. table.concat(text, ", ") .. "; " .. topups .. " top-ups")
end

local function fragments_check()
	local f = storage.fragments
	if not f then return end
	local problems = f.problems
	if f.machine and f.ctrl and f.bus then
		local function count(n) return remote.call(NET, "count", f.ctrl, n) end
		local out = f.machine.get_inventory(defines.inventory.crafter_output)
		local info = remote.call(SB, "info", f.bus) or {}
		if info.status ~= "ok" or info.side ~= "item" then problems[#problems + 1] = "the bus on the machine: status " .. tostring(info.status) .. ", side " .. tostring(info.side) end
		if count("stone") ~= 30 or count(f.other or "stone") ~= (f.other and 12 or 30) then
			problems[#problems + 1] = "the network counts " .. count("stone") .. " stone and " .. count(f.other or "stone") .. " " .. tostring(f.other)
				.. ", the machine's output holds 30 and 12"
		end
		local got = remote.call(NET, "extract", f.ctrl, "stone", 10)
		if got ~= 10 or out.get_item_count("stone") ~= 20 then
			problems[#problems + 1] = "an extraction of 10 stone took " .. tostring(got) .. ", the machine's output holds " .. out.get_item_count("stone")
		end
		local put = remote.call(NET, "insert", f.ctrl, "stone", 50)
		if out.get_item_count("stone") ~= 20 then problems[#problems + 1] = "stone stored in the network went into the machine's output: " .. out.get_item_count("stone") end
		if count("stone") ~= 70 then problems[#problems + 1] = "after 50 stone stored (" .. tostring(put) .. ") the network counts " .. count("stone") .. ", not 70" end
		local info2 = remote.call(SB, "info", f.bus2) or {}
		if info2.side == "item" and info2.status == "ok" then problems[#problems + 1] = "a storage bus on an assembling machine 2 has an item storage" end
		if count("stone") ~= 70 then problems[#problems + 1] = "the assembling machine's output is counted: " .. count("stone") end
	end
	report("FRAGMENTS", problems, "a storage bus on " .. tostring(f.machine_name) .. " (recipe " .. tostring(f.recipe) .. "): its output slots, with stone and "
		.. tostring(f.other) .. ", are network storage to take from")
end

--------------------------------------------------------------------------------
--- BUILD
--------------------------------------------------------------------------------

local function cell(name)
	local inv = game.create_inventory(1)
	inv[1].set_stack{ name = name, count = 1 }
	return inv
end

local function build(real)
	local problems = {}
	local s = orbit()
	local t = { }
	storage.t = t
	local S = real and REAL or SHIP
	tiles(s, "se-spaceship-floor", S.x1, S.y1, S.x2, S.y2)
	local function at(name, x, y, extra) return place(s, problems, name, x, y, extra) end
	if real then
		for _, y in ipairs({ -4, -2, 0, 2, 4 }) do
			local acc = at("accumulator", -6, y)
			if acc then acc.energy = acc.electric_buffer_size end
		end
	else
		local eei = at("electric-energy-interface", -6, -4)
		if eei then eei.power_production = 5e6 eei.electric_buffer_size = 5e7 eei.energy = 5e7 end
	end
	at("substation", -3, -4)
	t.ctrl = at("me-network-controller", 0, -4)
	t.drive = at("me-drive", 2.5, -3.5)
	t.provider = at("me-pattern-provider", 3.5, -3.5)
	t.iface = at("me-network-interface", 4.5, -3.5)
	t.port = at("me-io-port", 5.5, -3.5)
	t.bench = at("me-cell-workbench", 6.5, -3.5)
	t.pterm = at("me-pattern-terminal", 7.5, -3.5)
	t.ap = at("me-wireless-access-point", 8.5, -3.5)
	t.maint = at("me-level-maintainer", 2.5, -1.5)
	t.chest = at("steel-chest", 4.5, -0.5)
	t.sbus = at("me-storage-bus", 4.5, -1.5, { direction = defines.direction.south })
	t.xchest = at("steel-chest", 6.5, -0.5)
	t.xbus = at("me-export-bus", 6.5, -1.5, { direction = defines.direction.south })
	t.tunnel_in = at("me-item-p2p-tunnel", 8.5, -1.5)
	t.tunnel_out = at("me-item-p2p-tunnel", 8.5, 1.5)
	t.cpu = at("me-1k-crafting-storage", 2.5, 1.5)
	t.cpu2 = at("me-crafting-unit", 3.5, 1.5)
	t.bridge = at("me-quantum-bridge", 0.5, 2.5)
	t.machine = at("assembling-machine-2", 4.5, 3.5)
	if t.machine then t.machine.set_recipe("iron-gear-wheel") end
	t.provider2 = at("me-pattern-provider", 2.5, 3.5)             -- (issue #704: next to the machine, the job's provider)
	--- issue #707: a logistic network on the ship
	at("substation", 10, -4)
	if real then
		for _, x in ipairs({ 17, 19 }) do
			local acc = at("accumulator", x, 3)
			if acc then acc.energy = acc.electric_buffer_size end
		end
	end
	t.robo = at("roboport", 13, -3)
	if t.robo then
		t.robo.energy = t.robo.electric_buffer_size           -- (an empty roboport draws megawatts: the real ship runs on accumulators)
		t.robo.insert{ name = "logistic-robot", count = 10 }
		t.robo.insert{ name = "construction-robot", count = 2 }
	end
	t.lif = at(LIF_NAME, 16.5, -3.5)
	t.lsbus = at("me-logistic-storage-bus", 16.5, -1.5)
	t.req = at("requester-chest", 18.5, -3.5)
	t.store = at("storage-chest", 18.5, -1.5)
	t.prov = at("passive-provider-chest", 18.5, 0.5)
	local members = {}
	for _, k in ipairs({ "ctrl", "drive", "provider", "iface", "port", "pterm", "ap", "maint", "sbus", "xbus", "tunnel_in",
			"tunnel_out", "cpu", "cpu2", "bridge", "provider2", "lif", "lsbus" }) do
		if t[k] then members[#members + 1] = t[k] end
	end
	local _, unreached = remote.call(NET, "connect", members, 16)
	for _, e in pairs(unreached or {}) do problems[#problems + 1] = "no cable path to " .. e.name end
	--- the drive: three item cells and a fluid cell
	if t.drive then
		for slot, name in ipairs({ "me-16k-storage-cell", "me-16k-storage-cell", "me-4k-storage-cell", "me-16k-fluid-storage-cell" }) do
			local inv = cell(name)
			if not remote.call(NET, "insert_cell", t.drive, inv[1], slot) then problems[#problems + 1] = "no cell in slot " .. slot end
			inv.destroy()
		end
		remote.call(NET, "store_in_drive", t.drive, "iron-plate", 1000)
		remote.call(NET, "store_in_drive", t.drive, "copper-plate", 300)
		remote.call(NET, "store_in_drive", t.drive, "me-capacity-card", 4)
		remote.call(NET, "store_fluid_in_drive", t.drive, "water", 5000)
	end
	--- the provider: an encoded pattern, a priority
	if t.provider then
		local inv = game.create_inventory(2)
		inv.insert{ name = "me-blank-pattern", count = 1 }
		local where, why = remote.call(PT, "encode_def", inv, nil, { kind = "crafting", recipe = "iron-gear-wheel" })
		local stack = inv.find_item_stack("me-encoded-pattern")
		if not (where and stack and remote.call(AC, "insert_pattern", t.provider, stack)) then
			problems[#problems + 1] = "no pattern in the provider: " .. tostring(why)
		end
		inv.destroy()
		remote.call(AC, "set_priority", t.provider, 3)
	end
	if t.iface then remote.call(IO, "set_interface_slot", t.iface, 1, "iron-plate", "normal", 50) end
	if t.xbus then
		remote.call(IO, "set_bus_filters", t.xbus, { "stone" })       -- (nothing of it in the network: the bus only keeps its setting)
		local inv = cell("me-capacity-card")
		local why = remote.call(IO, "bus_shift_in", t.xbus, inv[1])
		if inv[1].valid_for_read then problems[#problems + 1] = "the export bus did not take its card: " .. tostring(why) end
		inv.destroy()
	end
	if t.chest then t.chest.insert{ name = "steel-plate", count = 200 } end
	if t.port then
		local inv = cell("me-1k-storage-cell")
		remote.call(PORT, "shift_in", t.port, inv[1])
		if inv[1].valid_for_read then problems[#problems + 1] = "the IO port did not take its cell" end
		inv.destroy()
	end
	if t.bench then
		local inv = cell("me-1k-storage-cell")
		remote.call(BENCH, "shift_in", t.bench, inv[1], nil)
		if inv[1].valid_for_read then problems[#problems + 1] = "the workbench did not take its cell" end
		inv.destroy()
	end
	--- issue #704: the job that runs over the moves: the maintainer keeps 32 iron sticks, crafted by the second provider's
	--- machine; the CPU takes requests of automation only (its mode must survive the moves)
	if t.provider2 then
		--- (iron sticks are behind a technology with AAI Industry; a wooden chest needs wood, which the network lacks: the
		--- maintainer's first row notes what its start lacked, "m<unit>:wooden-chest")
		for _, recipe in ipairs({ "iron-stick", "wooden-chest" }) do
			game.forces.player.recipes[recipe].enabled = true
			local inv = game.create_inventory(2)
			inv.insert{ name = "me-blank-pattern", count = 1 }
			local where, why = remote.call(PT, "encode_def", inv, nil, { kind = "crafting", recipe = recipe })
			local stack = inv.find_item_stack("me-encoded-pattern")
			if not (where and stack and remote.call(AC, "insert_pattern", t.provider2, stack)) then
				problems[#problems + 1] = "no pattern " .. recipe .. " in the second provider: " .. tostring(why)
			end
			inv.destroy()
		end
	end
	if t.drive then remote.call(NET, "store_in_drive", t.drive, "iron-gear-wheel", GOODS["iron-gear-wheel"]) end
	if t.store then t.store.insert{ name = "plastic-bar", count = GOODS["plastic-bar"] } end
	if t.prov then t.prov.insert{ name = "stone-brick", count = GOODS["stone-brick"] } end
	if t.req then
		local point = t.req.get_logistic_point(defines.logistic_member_index.logistic_container)
		local section = point.get_section(1) or point.add_section()
		section.set_slot(1, { value = { name = "iron-gear-wheel", quality = "normal", comparator = "=" }, min = 20 })
	end
	if t.lif then
		remote.call(LIF, "set_row", t.lif, "offer", 1, "iron-gear-wheel", 40)
		remote.call(LIF, "set_row", t.lif, "request", 1, "stone-brick", 20)
	end
	if t.cpu then remote.call(AC, "set_cpu_mode", t.cpu, "automation") end
	if t.maint then
		remote.call("gregtorio-me-circuit", "set_maintainer", t.maint, "wooden-chest", 1)
		remote.call("gregtorio-me-circuit", "set_maintainer", t.maint, "iron-stick", 32, nil, 2)
	end
	if t.tunnel_in and t.tunnel_out then
		remote.call(P2P, "set", t.tunnel_in, 11, false)
		remote.call(P2P, "set", t.tunnel_out, 11, true)
	end
	--- the partner network on Nauvis, where the ship will land next to it
	local n = game.surfaces.nauvis
	local nx, ny = LAND.dx + 30, LAND.dy
	tiles(n, "refined-concrete", nx - 10, ny - 8, nx + 10, ny + 8)
	for _, e in pairs(n.find_entities_filtered{ area = { { nx - 10, ny - 8 }, { nx + 11, ny + 9 } } }) do
		if e.valid and e.type ~= "character" then e.destroy() end
	end
	local function on_nauvis(name, x, y, extra) return place(n, problems, name, nx + x, ny + y, extra) end
	local e2 = on_nauvis("electric-energy-interface", -6, -4)
	if e2 then e2.power_production = 5e6 e2.electric_buffer_size = 5e7 e2.energy = 5e7 end
	on_nauvis("substation", -3, -4)
	--- (no controller: a network has one, the ship's, through the bridge)
	t.n_bridge = on_nauvis("me-quantum-bridge", 0.5, 2.5)
	t.n_iface = on_nauvis("me-network-interface", 5.5, 2.5)
	for x = 1.5, 4.5 do pcall(n.create_entity, { name = "me-cable", position = { nx + x, ny + 2.5 }, force = "player", raise_built = true }) end
	if t.n_bridge and t.n_iface then
		if not remote.call(NET, "same_network", t.n_bridge, t.n_iface) then problems[#problems + 1] = "Nauvis: the interface is not cabled to the bridge" end
		remote.call(IO, "set_interface_slot", t.n_iface, 1, "copper-plate", "normal", 20)
	end
	if t.bridge and t.n_bridge then
		remote.call(QB, "set_frequency", t.bridge, 9)
		remote.call(QB, "set_frequency", t.n_bridge, 9)
	end
	if real then
		--- the ship around the network: an engine in the back wall, walls on the rest of the border, a booster tank with
		--- fuel, and the console last (its build starts Space Exploration's integrity check)
		at("se-spaceship-rocket-engine", 1.5, 10)                   -- (tiles 0..2 x 8..11)
		for x = S.x1, S.x2 do
			for y = S.y1, S.y2 do
				local border = x == S.x1 or x == S.x2 or y == S.y1 or y == S.y2
				if border and not (y == S.y2 and x >= 0 and x <= 2) then at("se-spaceship-wall", x + 0.5, y + 0.5) end
			end
		end
		local tank = at("se-spaceship-rocket-booster-tank", 5.5, 7.5)
		if tank then tank.insert_fluid{ name = "se-liquid-rocket-fuel", amount = 100000 } end
		t.console = at("se-spaceship-console", -4, 8)
	end
	return report("BUILD", problems, #members .. " blocks on spaceship floor in " .. s.name .. ", a partner network on Nauvis"
		.. (real and ", inside a real spaceship" or ""))
end

--------------------------------------------------------------------------------
--- what the network holds and how its blocks are set: compared before and after a move
--------------------------------------------------------------------------------

local function inv_names(inv)
	local out = {}
	if not inv then return "none" end
	for i = 1, #inv do out[#out + 1] = inv[i].valid_for_read and (inv[i].name .. "x" .. inv[i].count) or "-" end
	return table.concat(out, ",")
end

local function snapshot()
	local t = storage.t
	local out = {}
	local function put(k, v) out[#out + 1] = k .. "=" .. tostring(v) end
	local net = remote.call(NET, "network", t.ctrl)
	put("status", net and net.status)
	put("cells", net and net.cells)
	put("drives", net and net.drives)
	for _, name in ipairs({ "iron-plate", "copper-plate", "steel-plate", "me-capacity-card" }) do
		put(name, remote.call(NET, "count", t.ctrl, name))
	end
	put("water", remote.call(NET, "fluid_count", t.ctrl, "water"))
	local info = remote.call(AC, "provider_info", t.provider)
	local slot = info and info.slots and info.slots[1]
	put("pattern", slot and (tostring(slot.kind) .. ":" .. tostring(slot.recipe)) or "none")
	put("provider priority", remote.call(AC, "get_priority", t.provider))
	local bus = remote.call(IO, "get_bus", t.xbus)
	put("export filters", bus and table.concat(bus.filters, ",") or "none")
	put("export cards", inv_names(remote.call(IO, "bus_inventory", t.xbus)))
	put("interface", serpent.line(remote.call(IO, "get_interface_config", t.iface)))
	put("storage bus", serpent.line((remote.call(SB, "get_settings", t.sbus) or {}).mode))
	put("port cells", inv_names(remote.call(PORT, "cells", t.port)))
	local wb = remote.call(BENCH, "info", t.bench)
	put("workbench", wb and tostring(wb.cell and (wb.cell.name or true) or wb.name or "empty") or "none")
	local mt = remote.call("gregtorio-me-circuit", "get_maintainer", t.maint)
	put("maintainer", mt and (tostring(mt.key) .. ":" .. tostring(mt.amount)) or "none")
	local pi, po = remote.call(P2P, "info", t.tunnel_in), remote.call(P2P, "info", t.tunnel_out)
	put("tunnels", tostring(pi and pi.freq) .. "/" .. tostring(pi and pi.output) .. " " .. tostring(po and po.freq) .. "/" .. tostring(po and po.output))
	local qi = remote.call(QB, "info", t.bridge)
	put("bridge frequency", qi and (qi.freq or qi.frequency))
	local g = remote.call(AC, "group_info", t.cpu)
	put("cpu", g and (tostring(g.n or g.blocks) .. " blocks, " .. tostring(g.bytes) .. " bytes") or "none")
	return out
end

local function compare(before, after, skip)
	local problems = {}
	for i, row in ipairs(before) do
		local key = row:match("^[^=]+")
		if not (skip and skip[key]) and after[i] ~= row then problems[#problems + 1] = "was " .. row .. ", now " .. tostring(after[i]) end
	end
	return problems
end

--------------------------------------------------------------------------------
--- the move, as Space Exploration's scripts/spaceship-clone.lua makes it
--------------------------------------------------------------------------------

local KEYS = { "ctrl", "drive", "provider", "iface", "port", "bench", "pterm", "ap", "maint", "chest", "sbus", "xchest", "xbus",
	"tunnel_in", "tunnel_out", "cpu", "cpu2", "bridge", "machine", "provider2", "robo", "lif", "lsbus", "req", "store", "prov" }

--------------------------------------------------------------------------------
--- issue #707: the logistic network on the ship
--------------------------------------------------------------------------------

--- how many of `name` exist on the ship's surface outside the ME network's cells: in chests (the hidden ones of the
--- logistic interface too), in the robots, in the roboport and on the ground
local function physical(surface, name)
	local n = 0
	for _, e in pairs(surface.find_entities_filtered{ type = { "container", "logistic-container", "roboport" } }) do
		if e.force.name == "player" then n = n + e.get_item_count(name) end
	end
	for _, e in pairs(surface.find_entities_filtered{ type = { "logistic-robot", "construction-robot" } }) do
		local inv = e.get_inventory(defines.inventory.robot_cargo)
		if inv then n = n + inv.get_item_count(name) end
	end
	for _, e in pairs(surface.find_entities_filtered{ type = "item-entity" }) do
		if e.stack.name == name then n = n + e.stack.count end
	end
	return n
end

--- Robot Attrition's bot_crash (its control.lua) on a logistic robot of the ship that carries something: "crashed <item>",
--- or "none" while no robot carries anything
local function crash_robot()
	local t = storage.t
	local ln = t.robo and t.robo.valid and t.robo.logistic_network
	for _, bot in pairs(ln and ln.logistic_robots or {}) do
		local inventory = bot.get_inventory(defines.inventory.robot_cargo)
		if not inventory.is_empty() then
			local name = inventory[1].name
			local drop = bot.surface.create_entity{ name = "logistic-robot-dropped-cargo",
				position = { x = bot.position.x, y = bot.position.y + 1 }, force = bot.force }
			drop.get_inventory(defines.inventory.chest)[1].transfer_stack(inventory[1])
			drop.order_deconstruction(bot.force)
			bot.force = "neutral"
			bot.die()
			storage.crashed = name
			return "crashed " .. name
		end
	end
	return "none"
end

--- `done`: the deliveries must have ended too. Returns false while they have not (and `done` is not asked)
local function logistics(problems, done)
	local t = storage.t
	for _, k in ipairs({ "robo", "lif", "lsbus", "req", "store", "prov" }) do
		if not (t[k] and t[k].valid) then problems[#problems + 1] = "logistics: " .. k .. " is not there" return end
	end
	local s = t.lif.surface
	local ln = t.robo.logistic_network
	local lid = ln and ln.network_id
	if not lid then problems[#problems + 1] = "logistics: the roboport has no logistic network" return end
	local info = remote.call(LIF, "info", t.lif) or {}
	if info.lid ~= lid then problems[#problems + 1] = "logistics: the interface is in logistic network " .. tostring(info.lid) .. ", the roboport's is " .. lid end
	local o, r = info.offer and info.offer[1], info.request and info.request[1]
	if not (o and o.key == "iron-gear-wheel" and o.amount == 40 and r and r.key == "stone-brick" and r.amount == 20) then
		problems[#problems + 1] = "logistics: the interface's rows: " .. serpent.line({ o, r })
	end
	if info.status ~= "ok" then
		local net = remote.call(NET, "network", t.ctrl)
		problems[#problems + 1] = "logistics: the interface's status is " .. tostring(info.status) .. " (the network: " .. tostring(net and net.status)
			.. ", same network as the controller: " .. tostring(remote.call(NET, "same_network", t.ctrl, t.lif)) .. ")"
	end
	local bus = remote.call(SB, "info", t.lsbus) or {}
	if bus.status and bus.status ~= "ok" then problems[#problems + 1] = "logistics: the logistic storage bus's status is " .. tostring(bus.status) end
	--- the hidden chests: three on the interface's tile, none anywhere else on the surface
	local p = t.lif.position
	local here = s.count_entities_filtered{ name = LIF_CHESTS, area = { { p.x - 0.4, p.y - 0.4 }, { p.x + 0.4, p.y + 0.4 } } }
	local all = s.count_entities_filtered{ name = LIF_CHESTS }
	if here ~= 3 or all ~= 3 then problems[#problems + 1] = "logistics: " .. here .. " hidden chests on the interface's tile, " .. all .. " on the surface (3 and 3)" end
	--- the automatic mode's books name logistic networks that exist
	local demand = remote.call(LIF, "demand") or {}
	for id in pairs(demand.auto or {}) do
		if id ~= lid then problems[#problems + 1] = "logistics: the automatic mode keeps a stock for logistic network " .. id .. " (the ship's is " .. lid .. ")" end
	end
	for id in pairs(demand.points or {}) do
		if id ~= lid then problems[#problems + 1] = "logistics: a point list of logistic network " .. id .. " (the ship's is " .. lid .. ")" end
	end
	--- everything exactly once: the cells (the network's count less what the bus shows of the storage chests) and the rest
	local shown = bus.status == "ok" or bus.status == nil
	for name, want in pairs(GOODS) do
		local count = remote.call(NET, "count", t.ctrl, name)
		local in_storage = 0
		for _, c in pairs(s.find_entities_filtered{ name = "storage-chest" }) do in_storage = in_storage + c.get_item_count(name) end
		local cells = count - (shown and in_storage or 0)
		local total = cells + physical(s, name)
		if total ~= want then
			problems[#problems + 1] = "logistics: " .. total .. " " .. name .. " exist (" .. cells .. " in cells, " .. physical(s, name)
				.. " in chests, robots and on the ground; the network counts " .. count .. "), there were " .. want
		end
	end
	if remote.call(NET, "count", t.ctrl, "plastic-bar") ~= t.store.get_item_count("plastic-bar") then
		problems[#problems + 1] = "logistics: the network counts " .. remote.call(NET, "count", t.ctrl, "plastic-bar") .. " plastic bars through the logistic storage bus, the storage chest holds "
			.. t.store.get_item_count("plastic-bar")
	end
	local gears, bricks = t.req.get_item_count("iron-gear-wheel"), remote.call(NET, "count", t.ctrl, "stone-brick")
	local finished = gears == 20 and bricks == 20
	if done then
		if not storage.crashed then problems[#problems + 1] = "logistics: no robot was crashed (none carried an item between the moves)" end
		local left = s.count_entities_filtered{ name = "logistic-robot-dropped-cargo" }
		if left > 0 then problems[#problems + 1] = "logistics: " .. left .. " dropped cargo of the crashed robot was not collected" end
	end
	if done and not finished then
		local where = {}
		for _, e in pairs(s.find_entities_filtered{ type = { "container", "logistic-container", "logistic-robot", "construction-robot" } }) do
			local inv = e.get_inventory(e.type:find("robot") and defines.inventory.robot_cargo or defines.inventory.chest)
			local n = inv and inv.get_item_count("stone-brick") or 0
			if n > 0 then where[#where + 1] = e.name .. " " .. n end
		end
		problems[#problems + 1] = "logistics: the requester chest holds " .. gears .. " of 20 gears, the network " .. bricks .. " of 20 stone bricks ("
			.. table.concat(where, ", ") .. "; request row " .. serpent.line(info.request and info.request[1]) .. ", robots available "
			.. ln.available_logistic_robots .. " of " .. ln.all_logistic_robots .. ")"
	end
	return finished
end

--------------------------------------------------------------------------------
--- issue #704: the job that runs over the moves
--------------------------------------------------------------------------------

--- the maintainer's row of the iron sticks (its second row)
local function stick_row(mt)
	for _, row in ipairs(mt and mt.rows or {}) do
		if row.key == "iron-stick" then return row end
	end
	return {}
end

--- the notes of what failed starts lacked name blocks that stand: the maintainer here, with its note of the wooden chest
local function notes_follow(problems)
	local t = storage.t
	local notes = remote.call(AC, "missing_notes")
	local want = "m" .. t.maint.unit_number .. ":wooden-chest"
	if notes[want] ~= t.maint.unit_number then problems[#problems + 1] = "no note " .. want .. " of what the wooden chest lacked: " .. serpent.line(notes) end
	for key, unit in pairs(notes) do
		if key ~= want then problems[#problems + 1] = "a note of a block that is gone: " .. key .. " (unit " .. tostring(unit) .. ")" end
	end
end

--- before the first move: the maintainer's job runs on the CPU with work in the machine; its id is kept
local function job_kept(problems)
	local t = storage.t
	local mt = remote.call("gregtorio-me-circuit", "get_maintainer", t.maint)
	notes_follow(problems)
	local id = stick_row(mt).job
	local job = id and remote.call(AC, "job", id)
	local g = remote.call(AC, "group_info", t.cpu)
	storage.job_id, storage.job_done = id, job and job.done or 0
	if not job then problems[#problems + 1] = "the level maintainer started no job before the launch: " .. serpent.line(mt) return end
	if not (job.status == "running" and job.leases > 0 and job.group == (g and g.id)) then
		problems[#problems + 1] = "the job does not run on the CPU with work in a machine before the launch: status " .. tostring(job.status)
			.. ", leases " .. tostring(job.leases) .. ", group " .. tostring(job.group) .. " of " .. tostring(g and g.id)
	end
	if not (g and g.mode == "automation") then problems[#problems + 1] = "the CPU's mode before the launch: " .. tostring(g and g.mode) end
end

--- a while after a move: the same job runs on the CPU at the new place, linked to the maintainer there
local function job_carried(problems)
	local t = storage.t
	local id = storage.job_id
	if not id then return end
	local job = remote.call(AC, "job", id)
	local mt = remote.call("gregtorio-me-circuit", "get_maintainer", t.maint)
	local g = remote.call(AC, "group_info", t.cpu)
	if not job then problems[#problems + 1] = "job " .. id .. " is gone" return end
	if job.status == "done" then return end                 -- (it ended in the meantime: job_done checks the result)
	if job.status ~= "running" or job.closing then
		problems[#problems + 1] = "job " .. id .. " does not run after the move: " .. tostring(job.status) .. " closing " .. tostring(job.closing)
			.. " wait " .. tostring(job.wait) .. " reason " .. serpent.line(job.reason)
	end
	if job.group ~= (g and g.id) then problems[#problems + 1] = "job " .. id .. " is on group " .. tostring(job.group) .. ", the CPU here is group " .. tostring(g and g.id) end
	if job.owner ~= t.maint.unit_number then problems[#problems + 1] = "the job's owner is " .. tostring(job.owner) .. ", the maintainer here is " .. t.maint.unit_number end
	if stick_row(mt).job ~= id then
		problems[#problems + 1] = "the maintainer's row names job " .. tostring(stick_row(mt).job) .. ", not " .. id
	end
	notes_follow(problems)
	if job.leases < 1 and job.done < job.total then problems[#problems + 1] = "the job has no work in a machine after the move" end
	if job.done < storage.job_done then problems[#problems + 1] = "the job's finished runs went back from " .. storage.job_done .. " to " .. job.done end
	storage.job_done = job.done
	if not (g and g.mode == "automation") then problems[#problems + 1] = "the CPU's mode after the move: " .. tostring(g and g.mode) end
	local jobs = remote.call(AC, "jobs", t.ctrl) or {}
	local active = 0
	for _, j in pairs(jobs) do if j.active then active = active + 1 end end
	if active ~= 1 then problems[#problems + 1] = active .. " active jobs in the network, expected the one job" end
end

--- the end: "done", "running" or a problem text
local function job_done()
	local t = storage.t
	local id = storage.job_id
	local job = id and remote.call(AC, "job", id)
	if not job then return "job " .. tostring(id) .. " is gone" end
	if job.status == "running" or job.status == "queued" then return "running" end
	if job.status ~= "done" then return "the job ended " .. tostring(job.status) .. ": " .. serpent.line(job.reason) end
	local sticks = remote.call(NET, "count", t.ctrl, "iron-stick")
	if sticks ~= 32 then return "the job is done, the network holds " .. tostring(sticks) .. " iron sticks, not 32" end
	if t.machine.get_item_count("iron-stick") + t.machine.get_item_count("iron-plate") > 0 then return "the job is done, items are left in its machine" end
	return "done"
end

--- the ship's tiles x1..y2 of `from` go to `to` at the offset dx, dy. Returns what lies on the ground at the old place.
local function fly(from, to, x1, y1, x2, y2, dx, dy)
	local t = storage.t
	tiles(to, "se-spaceship-floor", x1 + dx, y1 + dy, x2 + dx, y2 + dy)
	local positions = {}
	for x = x1, x2 do for y = y1, y2 do positions[#positions + 1] = { x = x, y = y } end end
	local where = {}
	for _, k in ipairs(KEYS) do
		if t[k] and t[k].valid then where[k] = { t[k].name, t[k].position } end
	end
	from.clone_brush{ source_offset = { 0, 0 }, destination_offset = { dx, dy }, destination_surface = to, clone_tiles = false,
		clone_entities = true, clone_decoratives = false, clear_destination_entities = false,
		clear_destination_decoratives = false, expand_map = true, source_positions = positions }
	for _, p in ipairs(positions) do
		for _, e in pairs(from.find_entities_filtered{ area = { { p.x, p.y }, { p.x + 1, p.y + 1 } } }) do
			if e.valid and e.type ~= "character" then e.destroy({ raise_destroy = true }) end
		end
	end
	tiles(from, from.name == "nauvis" and "refined-concrete" or "se-space", x1, y1, x2, y2)
	for k, w in pairs(where) do
		t[k] = to.find_entity(w[1], { w[2].x + dx, w[2].y + dy })
	end
	local spilled = from.find_entities_filtered{ type = "item-entity", area = { { x1 - 3, y1 - 3 }, { x2 + 4, y2 + 4 } } }
	for _, e in pairs(spilled) do log("DEVCHECK-SE-SPILLED " .. e.stack.name .. " x" .. e.stack.count .. " on " .. from.name) end
	return #spilled
end

local function moved_ok(problems, spilled, from)
	local t = storage.t
	if spilled > 0 then problems[#problems + 1] = spilled .. " item stacks lie on the ground where the ship stood" end
	for _, k in ipairs(KEYS) do
		if not (t[k] and t[k].valid) then problems[#problems + 1] = k .. " did not arrive" end
	end
	if from and from.valid then                              -- (a landed ship's own surface is deleted by Space Exploration)
		local hook = remote.call(MOVE, "space_exploration_delete_surface", { surface_index = from.index })
		if not (hook and hook.allow_delete) then problems[#problems + 1] = "members are still recorded on " .. from.name end
	end
	local ok, why = remote.call(NET, "sweep_list_ok")
	if not ok then problems[#problems + 1] = "the graph's sweep list: " .. tostring(why) end
	if remote.call(MOVE, "stale") > 0 then problems[#problems + 1] = remote.call(MOVE, "stale") .. " members without an entity" end
end

--------------------------------------------------------------------------------
--- the run
--------------------------------------------------------------------------------

local STEPS = {}

STEPS[10] = function()
	place_test()
	build()
	space_asm_build()
	fragments_build()
end

STEPS[150] = function()
	space_asm_start()
	fragments_check()
end

local function zones_check()
	local t = storage.t
	local problems = {}
	local PLACE = "me-network-place"
	local orbit_surface, nauvis = t.ctrl.surface, game.surfaces.nauvis
	local calls = remote.call(PLACE, "calls")
	local a = remote.call(PLACE, "name", orbit_surface.index)
	local b = remote.call(PLACE, "name", nauvis.index)
	if a ~= "Nauvis Orbit" then problems[#problems + 1] = "the orbit is called " .. serpent.line(a) end
	if b ~= "Nauvis" then problems[#problems + 1] = "Nauvis is called " .. serpent.line(b) end
	local after = remote.call(PLACE, "calls")
	remote.call(PLACE, "name", orbit_surface.index)
	remote.call(PLACE, "name", nauvis.index)
	if remote.call(PLACE, "calls") ~= after then problems[#problems + 1] = "a second question in the same tick asked Space Exploration again" end
	if after - calls > 2 then problems[#problems + 1] = (after - calls) .. " calls for two surfaces" end
	local plain = game.surfaces["me-se-platform"] or game.create_surface("me-se-plain", { width = 32, height = 32 })
	local c = remote.call(PLACE, "name", plain.index)
	if c ~= plain.name then problems[#problems + 1] = "a surface without a zone is called " .. serpent.line(c) .. ", not " .. plain.name end
	local gps = remote.call(PLACE, "gps", nauvis.index, 12.7, -3.2)
	if not (type(gps) == "table" and gps[2] == "[gps=12,-4,nauvis]" and gps[4] == "Nauvis") then problems[#problems + 1] = "the map marker: " .. serpent.line(gps) end
	local info = remote.call(QB, "info", t.bridge)
	if not (info and info.partner and info.partner.place == "Nauvis" and info.partner.surface == "nauvis") then
		problems[#problems + 1] = "the bridge's partner: " .. serpent.line(info and info.partner)
	end
	report("ZONES", problems, "Nauvis Orbit and Nauvis by their zone names (" .. (after - calls) .. " calls, kept), a surface without a zone by its own, "
		.. "the map marker and the bridge's partner with the zone")
end

STEPS[200] = function()
	local t = storage.t
	zones_check()
	storage.before = snapshot()
	local problems = {}
	local net = remote.call(NET, "network", t.ctrl)
	if not (net and net.status == "ok") then problems[#problems + 1] = "the network in orbit does not work: " .. tostring(net and net.status) end
	if not remote.call(NET, "same_network", t.bridge, t.n_bridge) then problems[#problems + 1] = "the quantum bridge orbit - Nauvis is not linked" end
	if t.iface.get_item_count("iron-plate") ~= 50 then problems[#problems + 1] = "the interface in orbit holds " .. t.iface.get_item_count("iron-plate") .. " iron plates, not 50" end
	local hook = remote.call(MOVE, "space_exploration_delete_surface", { surface_index = t.ctrl.surface.index })
	if not hook or hook.allow_delete ~= false then problems[#problems + 1] = "the surface with the network may be deleted" end
	job_kept(problems)
	if logistics(problems) then problems[#problems + 1] = "logistics: the robots' deliveries ended before the launch (nothing in flight during the move)" end
	report("ORBIT", problems, "the network works in " .. t.ctrl.surface.name .. " on power of that surface, bridged to Nauvis: " .. table.concat(storage.before, "; "))
	--- the launch
	problems = {}
	local from = t.ctrl.surface
	local flight = game.create_surface(FLIGHT, { width = 128, height = 128 })
	local old_ctrl = t.ctrl.unit_number
	local spilled = fly(from, flight, SHIP.x1, SHIP.y1, SHIP.x2, SHIP.y2, 0, 0)
	moved_ok(problems, spilled, from)
	if t.ctrl and t.ctrl.valid then
		for _, p in ipairs(compare(storage.before, snapshot(), { status = true })) do problems[#problems + 1] = p end
		if remote.call(MOVE, "resolve", old_ctrl) ~= t.ctrl.unit_number then problems[#problems + 1] = "the controller's old unit number does not lead to the new one" end
	end
	report("LAUNCH", problems, "moved to " .. FLIGHT .. " by clone_brush and raise_destroy, " .. spilled .. " stacks spilled")
end

STEPS[330] = function()
	local t = storage.t
	local problems = {}
	for _, p in ipairs(compare(storage.before, snapshot())) do problems[#problems + 1] = p end
	if not remote.call(NET, "same_network", t.bridge, t.n_bridge) then problems[#problems + 1] = "the quantum bridge ship - Nauvis is not linked" end
	if t.iface.get_item_count("iron-plate") ~= 50 then problems[#problems + 1] = "the interface holds " .. t.iface.get_item_count("iron-plate") .. " iron plates, not 50" end
	job_carried(problems)
	logistics(problems)
	crash_robot()                                            -- (issue #707: robot attrition, before the landing)
	report("TRAVEL", problems, "the network works on the ship's surface, bridged to Nauvis; the crafting job runs on")
	problems = {}
	local from = t.ctrl.surface
	local spilled = fly(from, game.surfaces.nauvis, SHIP.x1, SHIP.y1, SHIP.x2, SHIP.y2, LAND.dx, LAND.dy)
	moved_ok(problems, spilled, from)
	if t.ctrl and t.ctrl.valid then
		for _, p in ipairs(compare(storage.before, snapshot(), { status = true })) do problems[#problems + 1] = p end
	end
	report("LAND", problems, "moved onto Nauvis, " .. spilled .. " stacks spilled")
end

STEPS[460] = function()
	local t = storage.t
	local problems = {}
	for _, p in ipairs(compare(storage.before, snapshot())) do problems[#problems + 1] = p end
	if not remote.call(NET, "same_network", t.bridge, t.n_bridge) then problems[#problems + 1] = "the quantum bridge is not linked after the landing" end
	if t.iface.get_item_count("iron-plate") ~= 50 then problems[#problems + 1] = "the interface holds " .. t.iface.get_item_count("iron-plate") .. " iron plates, not 50" end
	if t.n_iface.get_item_count("copper-plate") ~= 20 then
		problems[#problems + 1] = "the interface of the partner network holds " .. t.n_iface.get_item_count("copper-plate") .. " copper plates through the bridge, not 20"
	end
	job_carried(problems)
	logistics(problems)
	report("LANDED", problems, "the network works on Nauvis as before the launch; the crafting job runs on")
	--- COPY: a clone whose source stays
	problems = {}
	local n = game.surfaces.nauvis
	local p = t.drive.position
	local copy = t.drive.clone{ position = { p.x, p.y + 12 }, surface = n }
	storage.copy = copy
	local net = remote.call(NET, "network", t.ctrl)
	if not copy then problems[#problems + 1] = "the drive was not cloned"
	else
		local cells
		for _, row in ipairs(storage.before) do cells = cells or row:match("^cells=(%d+)") end
		if not (net and tostring(net.cells) == cells) then
			problems[#problems + 1] = "the source lost cells to its clone: " .. tostring(net and net.cells) .. " of " .. tostring(cells)
		end
		local cnet = remote.call(NET, "network", copy)
		if cnet and (cnet.cells or 0) > 0 and cnet.id ~= (net and net.id) then problems[#problems + 1] = "the clone has cells" end
	end
	report("COPY", problems, "a cloned drive whose source stays is empty")
	--- PAD: Space Exploration's containers
	problems = {}
	local base = { x = LAND.dx - 80, y = LAND.dy }             -- (clear of the landed ship)
	tiles(n, "refined-concrete", base.x - 12, base.y - 14, base.x + 40, base.y + 12)
	for _, e in pairs(n.find_entities_filtered{ area = { { base.x - 12, base.y - 14 }, { base.x + 41, base.y + 13 } } }) do
		if e.valid and e.type ~= "character" then e.destroy() end
	end
	local pads = {}
	for i, name in ipairs({ "cargo-landing-pad", "se-delivery-cannon-chest", "se-rocket-launch-pad" }) do
		if prototypes.entity[name] then
			local x = base.x + (i - 1) * 14
			--- (without raise_built: Space Exploration's scripts refuse a pad of a force without players, and a headless run has
			--- none; the buses work with the container itself)
			local pad = place(n, problems, name, x, base.y, { raise_built = false })
			if pad then
				local box = pad.bounding_box
				local bus = place(n, problems, "me-storage-bus", math.floor(pad.position.x) + 0.5, math.floor(box.left_top.y) - 0.5,
					{ direction = defines.direction.south })
				local ctrl = place(n, problems, "me-network-controller", math.floor(pad.position.x) + 4, math.floor(box.left_top.y) - 3)
				local eei = place(n, problems, "electric-energy-interface", math.floor(pad.position.x) + 8, math.floor(box.left_top.y) - 3)
				place(n, problems, "substation", math.floor(pad.position.x) + 6, math.floor(box.left_top.y) - 6)
				if eei then eei.power_production = 5e6 eei.electric_buffer_size = 5e7 eei.energy = 5e7 end
				if bus and ctrl then remote.call(NET, "connect", { ctrl, bus }, 16) end
				local got = pad.insert{ name = "iron-plate", count = 77 }
				pads[#pads + 1] = { name = name, ctrl = ctrl, bus = bus, got = got }
			end
		else
			problems[#problems + 1] = "no entity " .. name
		end
	end
	storage.pads = pads
	for _, p2 in ipairs(problems) do fail("PAD: " .. p2) end
end

STEPS[700] = function()
	local problems = {}
	for _, pad in ipairs(storage.pads or {}) do
		local n = pad.ctrl and pad.ctrl.valid and remote.call(NET, "count", pad.ctrl, "iron-plate")
		if n ~= pad.got or pad.got == 0 then
			problems[#problems + 1] = "the storage bus on " .. pad.name .. " shows " .. tostring(n) .. " of " .. tostring(pad.got) .. " iron plates"
		elseif remote.call(NET, "extract", pad.ctrl, "iron-plate", 7) ~= 7 then
			problems[#problems + 1] = "the network cannot take from " .. pad.name
		end
	end
	report("PAD", problems, #(storage.pads or {}) .. " containers of Space Exploration read and emptied through a storage bus")
	--- SURFACE: a surface with a network is deleted
	problems = {}
	local s = game.create_surface("me-se-gone", { width = 64, height = 64 })
	tiles(s, "se-space-platform-scaffold", -8, -8, 8, 8)
	local ctrl = place(s, problems, "me-network-controller", 0, 0)
	local drive = place(s, problems, "me-drive", 2.5, 0.5)
	if ctrl and drive then
		remote.call(NET, "connect", { ctrl, drive }, 8)
		local inv = cell("me-1k-storage-cell")
		remote.call(NET, "insert_cell", drive, inv[1], 1)
		inv.destroy()
	end
	storage.gone_before = remote.call(MOVE, "counts")
	game.delete_surface(s)
	for _, p2 in ipairs(problems) do fail("SURFACE: " .. p2) end
end

for tick = 180, 1950, 30 do STEPS[tick] = STEPS[tick] or chance_tick end

STEPS[2000] = function()
	space_asm_done()
	chance_done()
	local got = job_done()
	report("JOB", got == "done" and {} or { got }, "the job started before the launch ran over both moves and made its 32 iron sticks")
	local problems = {}
	logistics(problems, true)
	report("LOGISTICS", problems, "the logistic interface and the logistic storage bus in the ship's logistic network over both moves: "
		.. "nothing lost or doubled, the requester chest has its 20 gears, the network its 20 stone bricks")
	log("DEVCHECK-SE-DONE " .. #fails .. " problems")
end

STEPS[720] = function()
	local problems = {}
	local now, before = remote.call(MOVE, "counts"), storage.gone_before or {}
	if game.surfaces["me-se-gone"] then problems[#problems + 1] = "the surface was not deleted" end
	if remote.call(MOVE, "stale") > 0 then problems[#problems + 1] = remote.call(MOVE, "stale") .. " members without an entity" end
	for _, k in ipairs({ "nodes", "nets", "drives" }) do
		local want = (before[k] or 0) - (k == "nodes" and (before.nodes_gone or 0) or 1)
		if k ~= "nodes" and now[k] ~= want then problems[#problems + 1] = k .. ": " .. tostring(now[k]) .. " after the deletion, expected " .. want end
	end
	if (now.nodes or 0) >= (before.nodes or 0) then problems[#problems + 1] = "members: " .. tostring(now.nodes) .. " after the deletion, " .. tostring(before.nodes) .. " before" end
	local ok, why = remote.call(NET, "sweep_list_ok")
	if not ok then problems[#problems + 1] = "the graph's sweep list: " .. tostring(why) end
	report("SURFACE", problems, "a deleted surface leaves no member, drive or network (" .. serpent.line(now) .. ")")
end

if not REAL_LAUNCH then
	script.on_event(defines.events.on_tick, function(event)
		local step = STEPS[event.tick]
		if step then step() end
	end)
end

--------------------------------------------------------------------------------
--- issue #706: the real launch, driven by the harness through RCON (devcheck.py launch)
--------------------------------------------------------------------------------

--- where every block of KEYS stands now (name, position, surface), to find its clone after Space Exploration moved the ship
local function remember()
	local t, where = storage.t, {}
	for _, k in ipairs(KEYS) do
		if t[k] and t[k].valid then where[k] = { t[k].name, t[k].position, t[k].surface.index } end
	end
	storage.where = where
end

--- the real ship runs on accumulators (an electric energy interface is too heavy for Space Exploration's integrity check):
--- they are filled again at every step of the harness, the test is not about the ship's power plant
local function charge()
	local t = storage.t
	if not (t and t.ctrl and t.ctrl.valid) then return end
	for _, acc in pairs(t.ctrl.surface.find_entities_filtered{ name = "accumulator" }) do acc.energy = acc.electric_buffer_size end
end

if REAL_LAUNCH then
	remote.add_interface("me-se-launch", {
		--- the network inside a real spaceship in Nauvis Orbit; the spaceship technologies researched (the integrity limit of the ship)
		build = function()
			--- (only the technologies of the ship's integrity: with every technology the robots of issue #707 would carry and
			--- fly so much more that their deliveries ended before the launch)
			for name, tech in pairs(game.forces.player.technologies) do
				if name:find("spaceship", 1, true) then tech.researched = true end
			end
			local line = build(true)
			remember()
			return "Space Exploration " .. tostring(script.active_mods[SE]) .. ": " .. line
		end,
		--- before the launch: the network works; what it holds is kept for the comparisons
		keep = function()
			local t = storage.t
			charge()
			storage.before = snapshot()
			local problems = {}
			local net = remote.call(NET, "network", t.ctrl)
			if not (net and net.status == "ok") then problems[#problems + 1] = "the network in orbit does not work: " .. tostring(net and net.status) end
			if not remote.call(NET, "same_network", t.bridge, t.n_bridge) then problems[#problems + 1] = "the quantum bridge orbit - Nauvis is not linked" end
			if t.iface.get_item_count("iron-plate") ~= 50 then problems[#problems + 1] = "the interface in orbit holds " .. t.iface.get_item_count("iron-plate") .. " iron plates, not 50" end
			storage.old_ctrl = t.ctrl.unit_number
			job_kept(problems)
			if logistics(problems) then problems[#problems + 1] = "logistics: the robots' deliveries ended before the launch (nothing in flight during the move)" end
			remember()
			return report("ORBIT", problems, "the network works in " .. t.ctrl.surface.name .. ", bridged to Nauvis: " .. table.concat(storage.before, "; "))
		end,
		--- after Space Exploration moved the ship to `surface` by dx, dy: every block is found there, nothing lies where it
		--- stood, the network holds what it held (its status may still be settling: `works` checks it later)
		moved = function(key, surface, dx, dy)
			local t, problems = storage.t, {}
			local to = game.get_surface(surface)
			if not to then return report(key, { "no surface " .. tostring(surface) }, "") end
			local from
			for k, w in pairs(storage.where or {}) do
				from = from or game.get_surface(w[3])
				t[k] = to.find_entity(w[1], { w[2].x + dx, w[2].y + dy })
			end
			local spilled = 0
			if from and from.valid then
				local list = from.find_entities_filtered{ type = "item-entity", area = { { REAL.x1 - 3, REAL.y1 - 3 }, { REAL.x2 + 4, REAL.y2 + 4 } } }
				for _, e in pairs(list) do log("DEVCHECK-SE-SPILLED " .. e.stack.name .. " x" .. e.stack.count .. " on " .. from.name) end
				spilled = #list
			end
			moved_ok(problems, spilled, from)
			charge()
			if t.ctrl and t.ctrl.valid then
				for _, p in ipairs(compare(storage.before, snapshot(), { status = true })) do problems[#problems + 1] = p end
				if remote.call(MOVE, "resolve", storage.old_ctrl) ~= t.ctrl.unit_number then
					problems[#problems + 1] = "the controller's first unit number does not lead to the one it has now"
				end
			end
			remember()
			return report(key, problems, "moved to " .. to.name .. " by Space Exploration, " .. spilled .. " stacks spilled")
		end,
		--- a while after a move: everything as before the launch, the bridge linked, the interfaces filled
		works = function(key)
			local t, problems = storage.t, {}
			charge()
			for _, p in ipairs(compare(storage.before, snapshot())) do problems[#problems + 1] = p end
			if not remote.call(NET, "same_network", t.bridge, t.n_bridge) then problems[#problems + 1] = "the quantum bridge to Nauvis is not linked" end
			if t.iface.get_item_count("iron-plate") ~= 50 then problems[#problems + 1] = "the interface holds " .. t.iface.get_item_count("iron-plate") .. " iron plates, not 50" end
			if t.n_iface.get_item_count("copper-plate") ~= 20 then
				problems[#problems + 1] = "the interface of the partner network holds " .. t.n_iface.get_item_count("copper-plate") .. " copper plates through the bridge, not 20"
			end
			job_carried(problems)
			logistics(problems)
			--- issue #713: in flight the ship's surface is no zone: it is called by the display name Space Exploration gave it
			--- (the ship's name), not "spaceship-1"
			local place = remote.call("me-network-place", "name", t.ctrl.surface.index)
			if key == "TRAVEL" and (place == nil or place == t.ctrl.surface.name) then
				problems[#problems + 1] = "the ship's surface is called " .. serpent.line(place)
			end
			return report(key, problems, "the network works on " .. t.ctrl.surface.name .. " (shown as " .. serpent.line(place)
				.. ") as before the launch; the crafting job runs on")
		end,
		--- issue #707: robot attrition, "crashed <item>" or "none" (no robot carries anything now)
		crash = function() return crash_robot() end,
		--- issue #707: "done" when the deliveries ended with everything in place, "running", or what is wrong
		logistics = function()
			local problems = {}
			charge()
			local finished = logistics(problems)
			if #problems > 0 then return table.concat(problems, " ;; ") end
			if not finished then return "running" end
			problems = {}
			logistics(problems, true)                            -- (the crashed robot's cargo collected)
			return #problems == 0 and "done" or (problems[1]:find("not collected", 1, true) and "running" or table.concat(problems, " ;; "))
		end,
		--- issue #704: "done" when the job started before the launch made its sticks, "running", or what went wrong
		job = function() charge() return job_done() end,
		failures = function() return #fails end,
	})
end
