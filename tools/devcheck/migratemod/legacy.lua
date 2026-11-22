--------------------------------------------------------------------------------
--- devcheck migrate, me-network issue #777: the old drive items of a save of 0.5.x (me-drive-<tier>, me-fluid-drive-<tier>:
--- one item per tier with four cells built in, a fluid drive's fluid in its tags) become ME Drives with their cells when
--- the working copy loads the save, and nothing else changes. Built by the old version (one that has the old items), south
--- of the helper's other blocks:
---   * a network (controller, terminal, a drive D of four 16k cells with 1000 iron plates and 300 copper plates, a drive of
---     four 1k fluid cells with 5000 water): what a network holds must be the same afterwards;
---   * old items stored IN THE NETWORK (in D's cells): 3 x 1k, 1 x 256k, and a 4k fluid drive with 2000 water and 500 crude oil;
---   * a chest behind an ME Storage Bus with 1 x 1k (the network counts the chest);
---   * chest A: 2 x 1k, a 1k fluid drive with 40000 water (more than four cells hold), 1 x 64k;
---   * chest B: a 16k cell that lies outside a drive and holds 2 x 1k, a 1k fluid drive with 3000 water, and 50 iron plates;
---   * 1 x 4k on the ground, 1 x 16k on a belt, 1 x 1k in an inserter's hand.
--- After the load: no old item is left anywhere; every old item is one ME Drive and four cells of its tier (the 256k one
--- also its Acceleration Card when the game has that item) at the place it was, every unit of fluid is in fluid cells, the
--- network holds what it held plus the replacements, counted once; the cell of chest B put into drive D adds its
--- replacements (it is read then); a second conversion finds nothing. Logs DEVCHECK-MIGRATE-LEGACY.
--- (`all --with-gregtorio`: the save is made without Gregtorio Continued, which needs a newer me-network than the old one,
--- and loaded with it: the mod is added to the save as a player of the issue adds nothing but updates both.)
--------------------------------------------------------------------------------

local NET = "gregtorio-me-network"
local X, Y = 0, 60                          -- (south of the other blocks of the helper, outside its fluid area)
local AREA = { { X - 8, Y - 8 }, { X + 62, Y + 14 } }
local EPS = 0.5

local M = {}

local function L(key, msg) log("DEVCHECK-MIGRATE-" .. key .. " " .. msg) end

local function place(s, fails, name, x, y, extra)
	local def = { name = name, position = { X + x, Y + y }, force = "player", raise_built = true }
	for k, v in pairs(extra or {}) do def[k] = v end
	local ok, e = pcall(s.create_entity, def)
	if not (ok and e) then fails[#fails + 1] = "place " .. name .. " at " .. x .. "," .. y .. ": " .. tostring(e) return nil end
	return e
end

--- does a save of this version hold the old drive items unconverted? Only 0.5.x: 0.6.0 converted them itself, 0.7.0 had no
--- such items, and since 0.7.1 the items exist again only so that an old save's can be converted (a map started there
--- holds none and is marked as converted, so old items put into it would stay: `migrate --from-ref v0.7.2` failed on that)
function M.has_old_items()
	local major, minor = (script.active_mods["me-network"] or ""):match("^(%d+)%.(%d+)")
	if not (major and tonumber(major) == 0 and tonumber(minor) < 6) then return false end
	return prototypes.item["me-drive-1k"] ~= nil and prototypes.item["me-fluid-drive-1k"] ~= nil
end

--- the old save. Returns the problems and what was built.
function M.setup(s)
	local fails = {}
	for _, e in pairs(s.find_entities_filtered{ area = AREA }) do
		if e.valid and e.type ~= "character" then e.destroy() end
	end
	local tiles = {}
	for x = AREA[1][1], AREA[2][1] do
		for y = AREA[1][2], AREA[2][2] do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
	end
	s.set_tiles(tiles)
	local eei = place(s, fails, "electric-energy-interface", 2, -4)
	if eei then eei.power_production = 1e7 eei.electric_buffer_size = 1e8 end
	place(s, fails, "substation", 5, -4)
	local ctrl = place(s, fails, "me-network-controller", 9, 0)
	if ctrl then ctrl.energy = 1e9 end
	for x = 8, 16 do place(s, fails, "me-cable", x + 0.5, 1.5) end
	local tmp = game.create_inventory(1)
	local hand = tmp[1]
	local function drive(x, y, cell, n)
		local d = place(s, fails, "me-drive", x, y)
		for slot = 1, n do
			hand.set_stack{ name = cell, count = 1 }
			if d then remote.call(NET, "insert_cell", d, hand, slot) end
		end
		return d
	end
	local di = drive(10.5, 0.5, "me-16k-storage-cell", 4)
	local df = drive(11.5, 0.5, "me-1k-fluid-storage-cell", 4)
	local t = place(s, fails, "me-terminal", 12.5, 0.5)
	if di then
		remote.call(NET, "store_in_drive", di, "iron-plate", 1000)
		remote.call(NET, "store_in_drive", di, "copper-plate", 300)
		--- the old items in the network
		if remote.call(NET, "store_in_drive", di, "me-drive-1k", 3) ~= 3 or remote.call(NET, "store_in_drive", di, "me-drive-256k", 1) ~= 1 then
			fails[#fails + 1] = "old drive items not stored in the drive"
		end
	end
	if df then remote.call(NET, "store_fluid_in_drive", df, "water", 5000) end
	if t then
		hand.set_stack{ name = "me-fluid-drive-4k", count = 1 }
		hand.tags = { fork_me_fluids = { water = 2000, ["crude-oil"] = 500 } }
		if remote.call(NET, "insert_stack", t, hand) ~= 1 then fails[#fails + 1] = "the old fluid drive item not stored in the network" end
		hand.clear()
	end
	--- a chest behind a storage bus
	place(s, fails, "me-storage-bus", 14.5, 2.5, { direction = defines.direction.south })
	local cc = place(s, fails, "iron-chest", 14.5, 3.5)
	if cc then cc.insert{ name = "me-drive-1k", count = 1 } end
	--- chest A
	local ca = place(s, fails, "steel-chest", 20.5, 6.5)
	if ca then
		local inv = ca.get_inventory(defines.inventory.chest)
		inv[1].set_stack{ name = "me-drive-1k", count = 2 }
		inv[2].set_stack{ name = "me-fluid-drive-1k", count = 1 }
		inv[2].tags = { fork_me_fluids = { water = 40000 } }
		inv[3].set_stack{ name = "me-drive-64k", count = 1 }
	end
	--- chest B: a cell taken out of a drive, with old items in it
	local cb = place(s, fails, "steel-chest", 24.5, 6.5)
	local temp = drive(16.5, 6.5, "me-16k-storage-cell", 1)
	if temp and cb then
		remote.call(NET, "store_in_drive", temp, "me-drive-1k", 2)
		remote.call(NET, "store_in_drive", temp, "iron-plate", 50)
		local inv = cb.get_inventory(defines.inventory.chest)
		remote.call(NET, "take_cell", temp, 1, inv)
		temp.destroy({ raise_destroy = true })
		local cell = inv[1]
		local tags = cell.valid_for_read and cell.is_item_with_tags and cell.tags
		local stored = tags and tags.fork_me_cell
		if not (stored and stored.items and stored.items["me-drive-1k"] == 2 and stored.items["iron-plate"] == 50) then
			fails[#fails + 1] = "the loose cell with old items: " .. serpent.line(tags)
		else
			--- an old fluid drive item with its tags, as a key with data (the key's text behind # only has to be its own)
			local key = "me-fluid-drive-1k@normal#" .. helpers.table_to_json({ tags = { fork_me_fluids = { water = 3000 } } })
			stored.items[key] = 1
			stored.data = stored.data or {}
			stored.data[key] = { tags = { fork_me_fluids = { water = 3000 } } }
			cell.tags = tags
		end
	end
	--- on the ground, on a belt, in an inserter's hand
	s.create_entity{ name = "item-on-ground", position = { X + 30.5, Y + 6.5 }, stack = { name = "me-drive-4k", count = 1 } }
	local belt = place(s, fails, "transport-belt", 40.5, 6.5)
	if belt and not belt.get_transport_line(1).insert_at_back({ name = "me-drive-16k", count = 1 }) then
		fails[#fails + 1] = "the old item not put on the belt"
	end
	local ins = place(s, fails, "inserter", 50.5, 6.5)
	if ins then
		ins.held_stack.set_stack{ name = "me-drive-1k", count = 1 }
		if not ins.held_stack.valid_for_read then fails[#fails + 1] = "the old item not put into the inserter's hand" end
	end
	tmp.destroy()
	return fails, "a network with old drive items in its cells and behind a storage bus, two chests (one with a loose cell that "
		.. "holds old items), an old item on the ground, on a belt and in an inserter's hand"
end

--- { item name -> count } of the keys of `contents` ({ key -> count }), and the fluid in the tags of the fluid cells among them
local function by_name(contents)
	local out, fluid = {}, {}
	for key, n in pairs(contents) do
		local name = key:match("^[^@#]*")
		out[name] = (out[name] or 0) + n
		local json = key:match("#(.*)$")
		local data = json and helpers.json_to_table(json)
		local stored = data and data.tags and data.tags.fork_me_cell
		for fkey, amount in pairs(stored and stored.items or {}) do
			if fkey:sub(1, 6) == "fluid/" then fluid[fkey:sub(7)] = (fluid[fkey:sub(7)] or 0) + amount * n end
		end
	end
	return out, fluid
end

--- the same of the stacks of an inventory
local function inventory_names(inv)
	local out, fluid = {}, {}
	for i = 1, #inv do
		local st = inv[i]
		if st.valid_for_read then
			out[st.name] = (out[st.name] or 0) + st.count
			local stored = st.is_item_with_tags and st.tags.fork_me_cell
			for fkey, amount in pairs(stored and stored.items or {}) do
				if fkey:sub(1, 6) == "fluid/" then fluid[fkey:sub(7)] = (fluid[fkey:sub(7)] or 0) + amount * st.count end
			end
		end
	end
	return out, fluid
end

--- the same of the items on the ground around a place
local function ground_names(s, x, y)
	local out = {}
	for _, g in pairs(s.find_entities_filtered{ type = "item-entity", position = { X + x, Y + y }, radius = 4 }) do
		out[g.stack.name] = (out[g.stack.name] or 0) + g.stack.count
	end
	return out
end

local function old_in(names)
	local found = {}
	for name, n in pairs(names) do
		if name:find("^me%-drive%-") or name:find("^me%-fluid%-drive%-") then found[#found + 1] = name .. " " .. n end
	end
	table.sort(found)
	return #found > 0 and table.concat(found, ", ") or nil
end

--- after the load
function M.check()
	local s = game.surfaces[1]
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function at(name, x, y) return s.find_entity(name, { X + x, Y + y }) end
	--- (what the game has: another mod may have removed a vanilla item or fluid, and the extra card is Gregtorio's)
	local function item(name, n) return prototypes.item[name] and n or 0 end
	local function fluid(name, n) return prototypes.fluid[name] and n or 0 end
	local card = item("acceleration-card", 1)
	local t, di = at("me-terminal", 12.5, 0.5), at("me-drive", 10.5, 0.5)
	local function network()
		local names, fl = by_name(t and remote.call(NET, "contents", t) or {})
		return names, fl, t and remote.call(NET, "fluid_contents", t) or {}
	end
	local function get(tbl, name) return tbl[name] or 0 end
	local function near(a, b) return math.abs(a - b) < EPS end
	expect(remote.call("gregtorio-me-legacy-drives", "done") == true, "the save is not marked as converted")

	--- the network: what it held, and the replacements of 3 x 1k, 1 x 256k, the 4k fluid drive (and 1 x 1k behind the storage bus)
	local names, fl, fluids = network()
	expect(old_in(names) == nil, "the network still holds old items: " .. tostring(old_in(names)))
	expect(get(names, "iron-plate") == item("iron-plate", 1000) and get(names, "copper-plate") == item("copper-plate", 300)
		and near(get(fluids, "water"), fluid("water", 5000)),
		"what the network held: iron plates " .. get(names, "iron-plate") .. ", copper plates " .. get(names, "copper-plate")
		.. ", water " .. get(fluids, "water"))
	expect(get(names, "me-drive") == 6 and get(names, "me-1k-storage-cell") == 16 and get(names, "me-256k-storage-cell") == 4
		and get(names, "me-4k-fluid-storage-cell") == 4 and get(names, "acceleration-card") == card,
		"the replacements in the network (6 drives, 16 1k cells, 4 256k cells, 4 4k fluid cells, " .. card .. " card): "
		.. get(names, "me-drive") .. ", " .. get(names, "me-1k-storage-cell") .. ", " .. get(names, "me-256k-storage-cell") .. ", "
		.. get(names, "me-4k-fluid-storage-cell") .. ", " .. get(names, "acceleration-card"))
	expect(near(get(fl, "water"), fluid("water", 2000)) and near(get(fl, "crude-oil"), fluid("crude-oil", 500)),
		"the fluid of the old 4k fluid drive in its cells: water " .. get(fl, "water") .. ", crude oil " .. get(fl, "crude-oil"))
	local cc = at("iron-chest", 14.5, 3.5)
	local cn = cc and inventory_names(cc.get_inventory(defines.inventory.chest)) or {}
	expect(get(cn, "me-drive") == 1 and get(cn, "me-1k-storage-cell") == 4 and old_in(cn) == nil,
		"the chest behind the storage bus: " .. serpent.line(cn))

	--- chest A: 2 x 1k, the 1k fluid drive with 40000 water, 1 x 64k
	local ca = at("steel-chest", 20.5, 6.5)
	local ai = ca and ca.get_inventory(defines.inventory.chest)
	local an, af = {}, {}
	if ai then an, af = inventory_names(ai) end
	expect(ai and ai[1].valid_for_read and ai[1].name == "me-drive" and ai[1].count == 2, "chest A: the drives are not in the old item's slot")
	expect(old_in(an) == nil and get(an, "me-drive") == 4 and get(an, "me-1k-storage-cell") == 8 and get(an, "me-64k-storage-cell") == 4
		and get(an, "me-1k-fluid-storage-cell") >= 4 and near(get(af, "water"), fluid("water", 40000)),
		"chest A (4 drives, 8 1k cells, 4 64k cells, the fluid cells with 40000 water): " .. serpent.line(an) .. " water " .. get(af, "water"))
	expect(next(ground_names(s, 20.5, 6.5)) == nil, "chest A spilled items: " .. serpent.line(ground_names(s, 20.5, 6.5)))

	--- the ground, the belt, the inserter
	local gn = ground_names(s, 30.5, 6.5)
	expect(old_in(gn) == nil and get(gn, "me-drive") == 1 and get(gn, "me-4k-storage-cell") == 4, "the old item on the ground: " .. serpent.line(gn))
	local belt = at("transport-belt", 40.5, 6.5)
	local on_belt = 0
	for i = 1, belt and belt.get_max_transport_line_index() or 0 do on_belt = on_belt + belt.get_transport_line(i).get_item_count() end
	local bn = ground_names(s, 40.5, 6.5)
	expect(belt and on_belt == 0 and old_in(bn) == nil and get(bn, "me-drive") == 1 and get(bn, "me-16k-storage-cell") == 4,
		"the old item on the belt: " .. on_belt .. " on the belt, around it " .. serpent.line(bn))
	local ins = at("inserter", 50.5, 6.5)
	local held = ins and ins.held_stack
	local hn = ground_names(s, 50.5, 6.5)
	local in_hand = held and held.valid_for_read and held.name == "me-drive" and held.count or 0
	expect(old_in(hn) == nil and in_hand + get(hn, "me-drive") == 1 and get(hn, "me-1k-storage-cell") == 4,
		"the old item in the inserter's hand: hand " .. serpent.line(held and held.valid_for_read and held.name) .. ", around it "
		.. serpent.line(hn))

	--- nothing old on the ground anywhere
	local stray = {}
	for _, g in pairs(s.find_entities_filtered{ type = "item-entity" }) do stray[g.stack.name] = (stray[g.stack.name] or 0) + g.stack.count end
	expect(old_in(stray) == nil, "old items on the ground: " .. tostring(old_in(stray)))

	--- a second conversion finds nothing and changes nothing
	expect(remote.call("gregtorio-me-legacy-drives", "convert") == 0, "a second conversion found old items")
	local again = network()
	expect(serpent.line(again) == serpent.line(names), "the network after a second conversion: " .. serpent.line(again))

	--- chest B: the loose cell is read when it goes into drive D: its 2 x 1k, its 1k fluid drive with 3000 water and its plates
	local cb = at("steel-chest", 24.5, 6.5)
	local cell = cb and cb.get_inventory(defines.inventory.chest)[1]
	expect(cell and cell.valid_for_read and cell.name == "me-16k-storage-cell", "chest B: the loose cell is gone")
	if cell and cell.valid_for_read and di then
		expect(remote.call(NET, "insert_cell", di, cell, 5) == 5, "the loose cell did not go into the drive")
		local n2, f2, fluids2 = network()
		expect(old_in(n2) == nil, "the network holds old items of the loose cell: " .. tostring(old_in(n2)))
		expect(get(n2, "me-drive") == 9 and get(n2, "me-1k-storage-cell") == 24 and get(n2, "me-1k-fluid-storage-cell") == 4
			and get(n2, "iron-plate") == item("iron-plate", 1050) and near(get(f2, "water"), fluid("water", 2000 + 3000))
			and near(get(fluids2, "water"), fluid("water", 5000)) and get(n2, "me-256k-storage-cell") == 4
			and get(n2, "acceleration-card") == card,
			"the network with the loose cell (9 drives, 24 1k cells, 4 1k fluid cells, 1050 iron plates, 5000 water in fluid cell "
			.. "items): " .. get(n2, "me-drive") .. ", " .. get(n2, "me-1k-storage-cell") .. ", " .. get(n2, "me-1k-fluid-storage-cell")
			.. ", " .. get(n2, "iron-plate") .. ", " .. get(f2, "water"))
		--- a drive comes out of the network as an ME Drive
		local out = game.create_inventory(1)
		local key = "me-drive"
		expect(remote.call(NET, "extract_to", t, out, key, 1) == 1 and out[1].valid_for_read and out[1].name == "me-drive",
			"an ME Drive taken out of the network: " .. serpent.line(out[1].valid_for_read and out[1].name))
		out.destroy()
	end
	for _, p in pairs(problems) do L("FAIL", p) end
	L("LEGACY", (#problems == 0 and "ok" or "failed") .. " (the old drive items of the save are ME Drives with their cells: in the "
		.. "network's cells, behind a storage bus, in a chest, on the ground, on a belt, in an inserter's hand and in a loose cell; "
		.. "their fluid is in fluid cells; what the network held is unchanged; nothing twice, nothing lost"
		.. (card == 1 and "; the 256k drive's Acceleration Card is back" or "") .. ")")
	return #problems == 0
end

return M
