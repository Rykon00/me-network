--- Runtime test of the parked blocks of me-network issue #38 (docs/ME-REWORK.md "Levers 1 and 2"): a block blocked on
--- the network's side is parked and costs nothing until the network wakes it, so every park reason has to end through
--- its wake, and a missed wake must show. One small network per case; each case parks a block, makes the thing it waits
--- for happen in one way, and expects the block to work within a time far shorter than the slow fallback visit (3600
--- ticks), so a missed wake fails its case. Cases: the key arrives through a storage bus whose chest is filled without
--- an event, through a cell put into a drive and through a crafting job's output; room appears because another block
--- exports, a cell is added to a drive, a drive is built and a storage bus gets a chest; the network appears (a cable
--- joins an island, an island with a drive joins, a controller is placed) and splits and joins again; the filter of the
--- block changes; the target is replaced or changes its recipe; a level maintainer is woken by its key being taken and
--- by its settings. Two last cases lose their wakes on purpose (`drop_waits`) and expect the slow fallback visit to
--- find the work and count it as a missed wake. Loaded by control.lua: require("parking")(H) returns
--- { setup, tick, running } like cpus.lua.

local NET, IO, CIRC, AC = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-circuit", "gregtorio-me-autocraft"
local COPPER = "copper-plate"
local X0, Y1, Y2, Y3, STEP = 40, -345, -318, -291, 30   -- the cases lie in three rows of nine, STEP tiles apart
local START, FALLBACK_START, FALLBACK = 150, 900, 90
local GEAR, GEAR_RECIPE = "iron-gear-wheel", "iron-gear-crafting-table"

return function(H)
	local me_place, cable_row, power, me_report = H.me_place, H.cable_row, H.power, H.me_report
	local T = {}
	local function line(t) return serpent.line(t) end
	local SOUTH, NORTH = { direction = defines.direction.south }, { direction = defines.direction.north }

	local function sch(e) return e and e.valid and remote.call(IO, "schedule", e) or nil end
	local function parked(e) local r = sch(e) return r and r.parked end
	local function msch(e) return e and e.valid and remote.call(CIRC, "schedule", e) or nil end

	--- a network at (bx, by): power, controller, a drive with `items` (tier: of its cells), and the members the case adds
	local function net(s, fails, what, bx, by, items, tier, members)
		local eei = me_place(s, fails, what, "electric-energy-interface", bx + 12.5, by + 6.5)
		if eei then
			eei.power_production = 1e6
			eei.electric_buffer_size = 1e7
		end
		me_place(s, fails, what, "substation", bx + 13, by + 2)
		local ctrl = me_place(s, fails, what, "me-network-controller", bx + 6, by)
		local drive = me_drive(s, fails, what, bx + 8.5, by + 4.5, items or {}, tier)
		local all = { ctrl, drive }
		for _, m in ipairs(members or {}) do all[#all + 1] = m end
		return ctrl, drive, all
	end

	local function chest(s, fails, what, x, y, item, count)
		local c = me_place(s, fails, what, "iron-chest", x, y)
		if c and item then c.insert{ name = item, count = count } end
		return c
	end

	--- fill a network with items until it takes nothing new (a full network: no room for a key it does not hold)
	local function fill(ctrl)
		for _, name in ipairs({ "iron-plate", "stone", "coal", "wood", "iron-ore", "copper-ore", "iron-gear-wheel" }) do
			if prototypes.item[name] then remote.call(NET, "insert", ctrl, name, 1e7) end
		end
		return remote.call(NET, "can_insert", ctrl, COPPER, 1) == 0
	end

	--- a step that waits for `fn(c, x)` to be true (timeout in ticks), and a step that does something
	local function wait(what, timeout, fn) return { what = what, timeout = timeout, fn = fn } end
	local function act(what, fn) return { what = what, timeout = 20, fn = function(c, x) fn(c, x) return true end } end

	local cases = {}
	local function case(name, slot, setup, steps, late)
		cases[#cases + 1] = { name = name, slot = slot, setup = setup, steps = steps, late = late }
	end
	local function base(slot) return X0 + STEP * ((slot - 1) % 9), (slot <= 9) and Y1 or ((slot <= 18) and Y2 or Y3) end

	--------------------------------------------------------------------------------------------------------------------
	--- the key arrives
	--------------------------------------------------------------------------------------------------------------------

	local function export_net(s, fails, what, bx, by, items, tier, filters, extra)
		local e = me_place(s, fails, what, "me-export-bus", bx + 2.5, by + 0.5, NORTH)
		chest(s, fails, what, bx + 2.5, by - 0.5)
		local members = { e }
		for _, m in ipairs(extra and extra(s, fails, what, bx, by) or {}) do members[#members + 1] = m end
		local ctrl, drive, all = net(s, fails, what, bx, by, items, tier, members)
		me_connect(fails, what, all)
		if e and filters then remote.call(IO, "set_bus_filters", e, filters) end
		return e, ctrl, drive
	end
	local function find_e(x) return x.find("me-export-bus", 2.5, 0.5) end
	local function chest_e(x) return x.find("iron-chest", 2.5, -0.5) end
	local function got_copper(x) return chest_e(x).get_item_count(COPPER) > 0 end
	local function is_parked(reason, timeout)
		return wait("the export bus is parked for " .. reason, timeout or 200, function(c, x) return parked(find_e(x)) == reason end)
	end
	local function exports(timeout, why)
		return wait("the export bus moves copper (" .. why .. ")", timeout, function(c, x) return got_copper(x) end)
	end

	case("key arrives through a storage bus", 1, function(s, fails, bx, by)
		export_net(s, fails, "key through a storage bus", bx, by, {}, nil, { COPPER }, function()
			local sb = me_place(s, fails, "key through a storage bus", "me-storage-bus", bx + 4.5, by + 0.5, NORTH)
			chest(s, fails, "key through a storage bus", bx + 4.5, by - 0.5)
			return { sb }
		end)
	end, {
		is_parked("no-key"),
		act("copper goes into the chest of the storage bus without an event", function(c, x)
			x.find("iron-chest", 4.5, -0.5).insert{ name = COPPER, count = 100 }
		end),
		exports(400, "found by the storage bus read, no event"),
	})

	case("key arrives through a cell", 2, function(s, fails, bx, by)
		export_net(s, fails, "key through a cell", bx, by, {}, nil, { COPPER })
		me_drive(s, fails, "key through a cell", bx + 20.5, by + 4.5, { [COPPER] = 100 })   -- on its own: not in the network
	end, {
		is_parked("no-key"),
		act("a cell with copper goes from the lone drive into the network's drive", function(c, x)
			local src = x.find("me-drive", 20.5, 4.5)
			local dst = x.find("me-drive", 8.5, 4.5)
			local inv = game.create_inventory(1)
			for slot, cell in pairs(remote.call(NET, "drive", src)) do
				if (cell.items[COPPER] or 0) > 0 and inv[1] and not inv[1].valid_for_read then
					remote.call(NET, "take_cell", src, slot, inv[1])
					remote.call(NET, "insert_cell", dst, inv[1], 6)
				end
			end
			inv.destroy()
		end),
		exports(100, "a cell with copper in a drive"),
	})

	case("key arrives through a crafting job", 3, function(s, fails, bx, by)
		local what = "key through a job"
		power(s, fails, what, bx, by)
		me_place(s, fails, what, "me-network-controller", bx + 7, by)
		me_drive(s, fails, what, bx + 8.5, by - 0.5, { ["iron-plate"] = 400, ["iron-stick"] = 800 })
		me_place(s, fails, what, "me-terminal", bx + 9.5, by - 0.5)
		cable_row(s, fails, bx + 10, bx + 22, by - 1)
		local provider = me_place(s, fails, what, "me-pattern-provider", bx + 11.5, by - 1.5)        -- (inside the substation's supply: the assembler is one tile now)
		local m = me_place(s, fails, what, "me-molecular-assembler", bx + 11.5, by - 2.5)
		if m then
			m.force.recipes[GEAR_RECIPE].enabled = true
			m.set_recipe(GEAR_RECIPE)
		end
		me_place(s, fails, what, "me-1k-crafting-storage", bx + 16.5, by + 0.5)
		local e = me_place(s, fails, what, "me-export-bus", bx + 20.5, by + 0.5, SOUTH)
		chest(s, fails, what, bx + 20.5, by + 1.5)
		if provider then give_patterns(provider, { { kind = "crafting", recipe = GEAR_RECIPE } }, fails) end
		if e then remote.call(IO, "set_bus_filters", e, { GEAR }) end
	end, {
		wait("the export bus is parked for its gears", 250, function(c, x) return parked(x.find("me-export-bus", 20.5, 0.5)) == "no-key" end),
		act("a job for gears starts", function(c, x)
			local id, why = remote.call(AC, "start", x.find("me-terminal", 9.5, -0.5), GEAR, 5)
			c.job = id
			if not id then c.problem = "the job did not start: " .. tostring(why) end
		end),
		wait("the export bus moves the gears of the job", 700, function(c, x)
			return c.problem or x.find("iron-chest", 20.5, 1.5).get_item_count(GEAR) > 0
		end),
	})

	--------------------------------------------------------------------------------------------------------------------
	--- room appears: a full network (four 1k cells), an import bus parked for it
	--------------------------------------------------------------------------------------------------------------------

	local function room_case(name, slot, trigger)
		case(name, slot, function(s, fails, bx, by)
			local what = name
			local i = me_place(s, fails, what, "me-import-bus", bx + 2.5, by + 0.5, NORTH)
			chest(s, fails, what, bx + 2.5, by - 0.5)
			local e = me_place(s, fails, what, "me-export-bus", bx + 4.5, by + 0.5, NORTH)
			chest(s, fails, what, bx + 4.5, by - 0.5)
			local ctrl, drive, all = net(s, fails, what, bx, by, {}, "1k", { i, e })
			me_connect(fails, what, all)
		end, {
			act("the network is filled, copper is put in front of the import bus, its filter wakes it", function(c, x)
				if not fill(x.find("me-network-controller", 6, 0)) then c.problem = "the network still has room for copper" end
				x.find("iron-chest", 2.5, -0.5).insert{ name = COPPER, count = 50 }
				remote.call(IO, "set_bus_filters", x.find("me-import-bus", 2.5, 0.5), { COPPER })
			end),
			wait("the import bus is parked: the network is full", 100, function(c, x)
				return c.problem or parked(x.find("me-import-bus", 2.5, 0.5)) == "net-full"
			end),
			act("room appears: " .. trigger.what, trigger.fn),
			wait("the import bus takes the copper", 250, function(c, x)
				return c.problem or x.find("iron-chest", 2.5, -0.5).get_item_count(COPPER) == 0
			end),
		})
	end
	room_case("room appears: another block exports", 4, { what = "an export bus takes iron plates out", fn = function(c, x)
		remote.call(IO, "set_bus_filters", x.find("me-export-bus", 4.5, 0.5), { "iron-plate" })
	end })
	room_case("room appears: some of a key is taken", 20, { what = "an eighth of the iron plates is taken, no type vanishes from a cell", fn = function(c, x)
		local ctrl = x.find("me-network-controller", 6, 0)
		remote.call(NET, "extract", ctrl, "iron-plate", math.floor(remote.call(NET, "count", ctrl, "iron-plate") / 8))
	end })
	room_case("room appears: a cell is added to a drive", 5, { what = "a cell goes into a free slot of the drive", fn = function(c, x)
		local inv = game.create_inventory(1)
		inv[1].set_stack{ name = "me-16k-storage-cell", count = 1 }
		remote.call(NET, "insert_cell", x.find("me-drive", 8.5, 4.5), inv[1], 6)
		inv.destroy()
	end })
	room_case("room appears: a drive is built", 6, { what = "a drive with cells is built next to the first", fn = function(c, x)
		local fails = {}
		me_drive(x.s, fails, "a new drive", c.bx + 9.5, c.by + 4.5, {})
		c.problem = fails[1]
	end })
	room_case("room appears: a storage bus gets a chest", 7, { what = "a storage bus with a chest is built", fn = function(c, x)
		local fails = {}
		chest(x.s, fails, "a new chest", c.bx + 8.5, c.by + 6.5)
		me_place(x.s, fails, "a new storage bus", "me-storage-bus", c.bx + 8.5, c.by + 5.5, SOUTH)
		c.problem = fails[1]
	end })

	--------------------------------------------------------------------------------------------------------------------
	--- the network appears, splits and joins again
	--------------------------------------------------------------------------------------------------------------------

	local function wait_chest(dx, dy, item, timeout, why)
		return wait(why, timeout, function(c, x) return x.find("iron-chest", dx, dy).get_item_count(item) > 0 end)
	end
	local function wait_empty(dx, dy, item, timeout, why)
		return wait(why, timeout, function(c, x) return x.find("iron-chest", dx, dy).get_item_count(item) == 0 end)
	end

	case("network appears: a cable joins a bus", 8, function(s, fails, bx, by)
		local what = "a cable joins a bus"
		local _, _, all = net(s, fails, what, bx, by, {})
		cable_row(s, fails, bx + 7, bx + 16, by - 1)
		me_connect(fails, what, all)
		me_place(s, fails, what, "me-import-bus", bx + 18.5, by - 0.5, NORTH)
		chest(s, fails, what, bx + 18.5, by - 1.5, COPPER, 50)
	end, {
		wait("the import bus of the island is parked: no network", 200, function(c, x) return parked(x.find("me-import-bus", 18.5, -0.5)) == "no-network" end),
		act("a cable closes the gap", function(c, x) me_place(x.s, {}, "gap", "me-cable", c.bx + 17.5, c.by - 0.5) end),
		wait_empty(18.5, -1.5, COPPER, 150, "the import bus takes the copper"),
	})

	case("network appears: an island with a drive joins", 9, function(s, fails, bx, by)
		local what = "an island joins"
		local _, _, all = net(s, fails, what, bx, by, {})
		cable_row(s, fails, bx + 7, bx + 16, by - 1)
		me_connect(fails, what, all)
		cable_row(s, fails, bx + 18, bx + 20, by - 1)
		me_drive(s, fails, what, bx + 21.5, by - 0.5, { [COPPER] = 100 })
		local e = me_place(s, fails, what, "me-export-bus", bx + 19.5, by + 0.5, SOUTH)
		chest(s, fails, what, bx + 19.5, by + 1.5)
		if e then remote.call(IO, "set_bus_filters", e, { COPPER }) end
	end, {
		wait("the export bus of the island is parked: no network", 200, function(c, x) return parked(x.find("me-export-bus", 19.5, 0.5)) == "no-network" end),
		act("a cable joins the island to the network", function(c, x) me_place(x.s, {}, "gap", "me-cable", c.bx + 17.5, c.by - 0.5) end),
		wait_chest(19.5, 1.5, COPPER, 150, "the export bus moves the copper of the island's drive"),
	})

	case("network appears: a controller is placed", 10, function(s, fails, bx, by)
		local what = "a controller is placed"
		cable_row(s, fails, bx + 18, bx + 20, by - 1)
		me_drive(s, fails, what, bx + 18.5, by + 0.5, {})
		me_place(s, fails, what, "me-import-bus", bx + 19.5, by + 0.5, SOUTH)
		chest(s, fails, what, bx + 19.5, by + 1.5, COPPER, 50)
		power(s, fails, what, bx + 26, by + 3)
	end, {
		wait("the import bus is parked: no network", 200, function(c, x) return parked(x.find("me-import-bus", 19.5, 0.5)) == "no-network" end),
		act("a controller is placed next to the island", function(c, x) me_place(x.s, {}, "controller", "me-network-controller", c.bx + 22, c.by) end),
		wait_empty(19.5, 1.5, COPPER, 250, "the import bus takes the copper"),
	})

	case("network splits and joins again", 11, function(s, fails, bx, by)
		local what = "split and join"
		local _, _, all = net(s, fails, what, bx, by, {})
		cable_row(s, fails, bx + 7, bx + 13, by - 1)
		me_connect(fails, what, all)
		local e = me_place(s, fails, what, "me-export-bus", bx + 13.5, by + 0.5, SOUTH)
		chest(s, fails, what, bx + 13.5, by + 1.5)
		if e then remote.call(IO, "set_bus_filters", e, { COPPER }) end
	end, {
		wait("the export bus is parked: no copper", 200, function(c, x) return parked(x.find("me-export-bus", 13.5, 0.5)) == "no-key" end),
		act("the cable at the bridge is removed: the network splits", function(c, x)
			x.find("me-cable", 11.5, -0.5).destroy{ raise_destroy = true }
		end),
		wait("the export bus is parked: no network", 100, function(c, x) return parked(x.find("me-export-bus", 13.5, 0.5)) == "no-network" end),
		act("the cable is built again: the networks join", function(c, x) me_place(x.s, {}, "bridge", "me-cable", c.bx + 11.5, c.by - 0.5) end),
		wait("the export bus is parked: no copper again", 100, function(c, x) return parked(x.find("me-export-bus", 13.5, 0.5)) == "no-key" end),
		act("copper comes into the network", function(c, x) remote.call(NET, "insert", x.find("me-network-controller", 6, 0), COPPER, 50) end),
		wait_chest(13.5, 1.5, COPPER, 100, "the export bus moves the copper"),
	})

	--- a change of the graph wakes what it can affect, not every block that waits: a cable joins two small networks
	--- while a bus waits for a key on the same network and another one waits for a network elsewhere; neither is woken
	case("a change of the graph wakes nothing unrelated", 21, function(s, fails, bx, by)
		local what = "an unrelated change"
		local e = me_place(s, fails, what, "me-export-bus", bx + 2.5, by + 0.5, NORTH)
		chest(s, fails, what, bx + 2.5, by - 0.5)
		local ctrl, drive, all = net(s, fails, what, bx, by, {}, nil, { e })
		cable_row(s, fails, bx + 7, bx + 10, by - 1)
		me_connect(fails, what, all)
		if e then remote.call(IO, "set_bus_filters", e, { COPPER }) end
		cable_row(s, fails, bx + 12, bx + 13, by - 1)                               -- a small network of its own
		me_place(s, fails, what, "me-import-bus", bx + 20.5, by - 0.5, NORTH)       -- a bus with no network at all
		chest(s, fails, what, bx + 20.5, by - 1.5, COPPER, 10)
	end, {
		wait("the export bus waits for copper", 200, function(c, x) return parked(find_e(x)) == "no-key" end),
		wait("the lone import bus waits for a network", 200, function(c, x) return parked(x.find("me-import-bus", 20.5, -0.5)) == "no-network" end),
		act("the due ticks are noted and a cable joins the small network to the big one", function(c, x)
			c.due_e, c.due_i = sch(find_e(x)).due, sch(x.find("me-import-bus", 20.5, -0.5)).due
			me_place(x.s, {}, "cable", "me-cable", c.bx + 11.5, c.by - 0.5)
		end),
		wait("some ticks pass", 100, function(c, x) return game.tick - c.t0 >= 40 end),
		act("neither bus was woken", function(c, x)
			local re, ri = sch(find_e(x)), sch(x.find("me-import-bus", 20.5, -0.5))
			if re.parked ~= "no-key" or re.due ~= c.due_e then c.problem = "the export bus was woken by an unrelated change: " .. line(re) end
			if ri.parked ~= "no-network" or ri.due ~= c.due_i then c.problem = "the lone bus was woken by an unrelated change: " .. line(ri) end
		end),
	})

	--------------------------------------------------------------------------------------------------------------------
	--- settings, the target
	--------------------------------------------------------------------------------------------------------------------

	case("settings: a filter is set", 12, function(s, fails, bx, by)
		export_net(s, fails, "a filter is set", bx, by, { [COPPER] = 100 }, nil, nil)
	end, {
		is_parked("unset"),
		act("a filter is set", function(c, x) remote.call(IO, "set_bus_filters", find_e(x), { COPPER }) end),
		exports(100, "its filter was set"),
	})

	case("settings: the filter changes", 13, function(s, fails, bx, by)
		export_net(s, fails, "the filter changes", bx, by, { stone = 100 }, nil, { COPPER })
	end, {
		is_parked("no-key"),
		act("the filter changes to an item the network has", function(c, x) remote.call(IO, "set_bus_filters", find_e(x), { "stone" }) end),
		wait("the export bus moves stone", 100, function(c, x) return chest_e(x).get_item_count("stone") > 0 end),
	})

	case("target: replaced", 14, function(s, fails, bx, by)
		local e = export_net(s, fails, "the target is replaced", bx, by, { [COPPER] = 100 }, nil, { COPPER })
		local c = s.find_entity("iron-chest", { bx + 2.5, by - 0.5 })
		if c then
			c.get_inventory(defines.inventory.chest).insert{ name = "wood", count = 100 * #c.get_inventory(defines.inventory.chest) }
		end
	end, {
		wait("the export bus has a full target", 200, function(c, x) local r = sch(find_e(x)) return r and r.block == "full" end),
		act("the chest is removed and an empty one built", function(c, x)
			chest_e(x).destroy{ raise_destroy = true }
			me_place(x.s, {}, "new chest", "iron-chest", c.bx + 2.5, c.by - 0.5)
		end),
		exports(100, "the target was replaced"),
	})

	--- two recipes the machine accepts: one that uses copper plates and one that does not (the same in every game that
	--- has the mod: candidates sorted by name, the first the machine really takes)
	local function two_recipes(m)
		local names, cats = {}, m.prototype.crafting_categories
		for name, r in pairs(prototypes.recipe) do
			if cats[r.category] and not r.hidden and #r.ingredients >= 1 and #r.ingredients <= 2 then names[#names + 1] = name end
		end
		table.sort(names)
		local with, without
		for _, name in ipairs(names) do
			local uses, plain = false, true
			for _, i in pairs(prototypes.recipe[name].ingredients) do
				if i.type ~= "item" then plain = false end
				if i.name == COPPER then uses = true end
			end
			if plain and ((uses and not with) or (not uses and not without)) then
				m.force.recipes[name].enabled = true
				pcall(m.set_recipe, name)
				if m.get_recipe() then
					if uses then with = name else without = name end
				end
			end
			if with and without then break end
		end
		return with, without
	end

	case("target: changes its recipe", 15, function(s, fails, bx, by)
		local what = "the target changes its recipe"
		local e = me_place(s, fails, what, "me-export-bus", bx + 2.5, by + 0.5, NORTH)
		local m = me_place(s, fails, what, "me-molecular-assembler", bx + 2.5, by - 0.5)
		local with, without
		if m then with, without = two_recipes(m) end
		storage.parking_recipes = { with = with, without = without }
		if m and with and without then
			m.set_recipe(without)
		else
			fails[#fails + 1] = "no pair of recipes for the target: " .. tostring(with) .. " " .. tostring(without)
		end
		local _, _, all = net(s, fails, what, bx, by, { [COPPER] = 100 }, nil, { e })
		me_connect(fails, what, all)
		if e then remote.call(IO, "set_bus_filters", e, { COPPER }) end
	end, {
		wait("the export bus is blocked: the machine takes no copper", 250, function(c, x) local r = sch(find_e(x)) return r and r.block == "full" end),
		act("the machine gets a recipe that uses copper", function(c, x) x.find("me-molecular-assembler", 2.5, -0.5).set_recipe(storage.parking_recipes.with) end),
		wait("the export bus puts copper into the machine", 450, function(c, x) return x.find("me-molecular-assembler", 2.5, -0.5).get_item_count(COPPER) > 0 end),
	})

	--------------------------------------------------------------------------------------------------------------------
	--- level maintainers
	--------------------------------------------------------------------------------------------------------------------

	local function maintainer_net(s, fails, what, bx, by, key)
		local m = me_place(s, fails, what, "me-level-maintainer", bx + 11.5, by + 1.5)
		local ctrl, drive, all = net(s, fails, what, bx, by, { ["iron-plate"] = 100 }, nil, { m })
		me_connect(fails, what, all)
		if m and key then remote.call(CIRC, "set_maintainer", m, key, 10, false) end
	end
	local function find_m(x) return x.find("me-level-maintainer", 11.5, 1.5) end

	case("maintainer: its key is taken", 16, function(s, fails, bx, by)
		maintainer_net(s, fails, "a maintainer", bx, by, "iron-plate")
	end, {
		wait("the maintainer is parked: stocked", 200, function(c, x) local r = msch(find_m(x)) return r and r.parked == "stocked" end),
		act("the key is taken out of the network", function(c, x) remote.call(NET, "extract", x.find("me-network-controller", 6, 0), "iron-plate", 95) end),
		wait("the maintainer is woken and checks", 60, function(c, x)
			local r = msch(find_m(x))
			return r and not r.parked and r.status ~= "stocked"
		end),
	})

	case("maintainer: its settings change", 17, function(s, fails, bx, by)
		maintainer_net(s, fails, "a maintainer", bx, by, nil)
	end, {
		wait("the maintainer is parked: no target", 200, function(c, x) local r = msch(find_m(x)) return r and r.parked == "no-target" end),
		act("a key is set", function(c, x) remote.call(CIRC, "set_maintainer", find_m(x), "iron-plate", 10, false) end),
		wait("the maintainer is woken and parked: stocked", 60, function(c, x) local r = msch(find_m(x)) return r and r.parked == "stocked" end),
	})

	--------------------------------------------------------------------------------------------------------------------
	--- the slow fallback finds a wake that was lost on purpose (late: after the others, with a short fallback)
	--------------------------------------------------------------------------------------------------------------------

	case("fallback: a block", 18, function(s, fails, bx, by)
		export_net(s, fails, "fallback", bx, by, {}, nil, { COPPER })
	end, {
		is_parked("no-key"),
		act("the fallback becomes short and the block parks again with it", function(c, x)
			remote.call(IO, "set_park_fallback", FALLBACK)
			remote.call(IO, "set_bus_filters", find_e(x), { COPPER })
		end),
		is_parked("no-key", 60),
		act("all waits are lost, then copper comes in: no wake", function(c, x)
			local ctrl = x.find("me-network-controller", 6, 0)
			remote.call(NET, "drop_waits", ctrl)
			remote.call(NET, "insert", ctrl, COPPER, 50)
		end),
		exports(400, "the fallback visit found it"),
	}, true)

	case("fallback: a maintainer", 19, function(s, fails, bx, by)
		maintainer_net(s, fails, "fallback", bx, by, "iron-plate")
	end, {
		wait("the maintainer is parked: stocked", 200, function(c, x) local r = msch(find_m(x)) return r and r.parked == "stocked" end),
		act("the fallback becomes short and the maintainer parks again with it", function(c, x)
			remote.call(IO, "set_park_fallback", FALLBACK)
			remote.call(CIRC, "set_maintainer", find_m(x), nil, nil, nil)
		end),
		wait("the maintainer is parked again", 60, function(c, x) local r = msch(find_m(x)) return r and r.parked == "stocked" end),
		act("all waits are lost, then the key is taken: no wake", function(c, x)
			local ctrl = x.find("me-network-controller", 6, 0)
			remote.call(NET, "drop_waits", ctrl)
			remote.call(NET, "extract", ctrl, "iron-plate", 95)
		end),
		wait("the fallback visit finds it", 400, function(c, x)
			local r = msch(find_m(x))
			return r and not r.parked and r.status ~= "stocked"
		end),
	}, true)

	--------------------------------------------------------------------------------------------------------------------

	function T.setup(s)
		local fails = {}
		for _, k in ipairs(cases) do
			local bx, by = base(k.slot)
			local sub = {}
			local ok, err = pcall(k.setup, s, sub, bx, by)
			if not ok then sub[#sub + 1] = tostring(err) end
			for _, f in ipairs(sub) do fails[#fails + 1] = k.name .. ": " .. f end
		end
		return fails
	end

	local function finish(st, note)
		st.done = true
		remote.call(IO, "set_park_fallback", 3600)
		local stats = remote.call(IO, "sched_stats", false) or {}
		local missed_io = (stats.io and stats.io.missed) or 0
		local missed_m = (stats.maintainer and stats.maintainer.missed) or 0
		local problems = st.problems
		if st.missed0 and (st.missed0.io ~= 0 or st.missed0.maintainer ~= 0) then
			problems[#problems + 1] = "wakes were missed before the fallback cases: " .. line(st.missed0)
		end
		if missed_io < 1 then problems[#problems + 1] = "the fallback visit of a parked bus that found work was not counted as a missed wake" end
		if missed_m < 1 then problems[#problems + 1] = "the fallback visit of a parked maintainer that found work was not counted as a missed wake" end
		me_report("PARKING", "ME parked blocks", problems, #cases .. " cases, each park reason ended through its wake; the fallback found "
			.. missed_io .. " lost wakes of buses and " .. missed_m .. " of maintainers" .. (note or ""))
	end

	function T.tick()
		local tick = game.tick
		if tick < START then return end
		local st = storage.parking
		if not st then
			st = { cases = {}, problems = {} }
			for _, k in ipairs(cases) do
				local bx, by = base(k.slot)
				st.cases[k.name] = { i = 1, t0 = tick, bx = bx, by = by, done = false }
			end
			storage.parking = st
		end
		if st.done then return end
		local s = game.surfaces[1]
		local natural_open = false
		for _, k in ipairs(cases) do
			if not k.late and not st.cases[k.name].done then natural_open = true end
		end
		if not st.missed0 and (not natural_open or tick >= FALLBACK_START) then
			local stats = remote.call(IO, "sched_stats", false) or {}
			st.missed0 = { io = (stats.io and stats.io.missed) or 0, maintainer = (stats.maintainer and stats.maintainer.missed) or 0 }
		end
		local open = false
		for _, k in ipairs(cases) do
			local c = st.cases[k.name]
			if not c.done and (not k.late or st.missed0) then
				local step = k.steps[c.i]
				local x = { s = s, find = function(name, dx, dy) return s.find_entity(name, { c.bx + dx, c.by + dy }) end }
				local ok, res = pcall(step.fn, c, x)
				if not ok then
					st.problems[#st.problems + 1] = k.name .. ": step " .. c.i .. " (" .. step.what .. ") failed: " .. tostring(res)
					c.done = true
				elseif c.problem then
					st.problems[#st.problems + 1] = k.name .. ": " .. c.problem
					c.done = true
				elseif res then
					c.i, c.t0 = c.i + 1, tick
					if c.i > #k.steps then c.done = true end
				elseif tick - c.t0 > step.timeout then
					local e = x.find("me-export-bus", 2.5, 0.5)
					st.problems[#st.problems + 1] = k.name .. ": " .. step.what .. " (step " .. c.i .. ") did not happen within " .. step.timeout
						.. " ticks " .. line(sch(e) or msch(x.find("me-level-maintainer", 11.5, 1.5)) or {})
						.. (c.job and (" job " .. line(remote.call(AC, "job", c.job))) or "")
					c.done = true
				end
			end
			if not c.done then open = true end
		end
		if not open then finish(st) end
	end

	function T.running(check) check(storage.parking and storage.parking.done, "ME parked blocks") end
	return T
end
