--------------------------------------------------------------------------------
--- FORK AE2: ME NETWORK CORE (issue #68, step R1; design: docs/ME-REWORK.md, prototypes/120-fork-ae2.lua)
---   * Graph: ME blocks ("nodes": cables, controller, drives, terminals, interfaces, buses, pattern
---     providers, CPUs, level maintainers, circuit interfaces, fluid drives, fluid interfaces) connect when
---     their tile boxes share an edge. A network is a connected component. It works with exactly one
---     powered ME Controller; two controllers are a conflict. The graph is kept incrementally from the
---     build and removal events (no map scans except on_init / on_configuration_changed); members removed
---     without an event are found by a bounded sweep (slow_step, every 60 ticks from the terminal module).
---   * Storage: items live virtually in the storage cells in the ME Drives (AE2 bytes and types). Per
---     network the totals, bytes, types and an index item -> cells are kept, so count is a lookup and
---     insert / extract only touch the cells that hold the item. A cell taken out of a drive carries its
---     contents in its tags (fork_me_cell); putting it into a drive reads them back.
---   * ME Drive: 10 cell slots, a script GUI (the open key) and a light per slot (rendering).
--- Keys: "name" (normal quality), "name@quality", and for items with tags "name@quality#<json of the tags>".
--- State: storage.fork_me_net (nodes, nets, drives). GUI state lives in the GUI elements (tags).
--------------------------------------------------------------------------------

local M = {}

--- functions(net) called when a network's members changed (autocrafting drops its pattern cache)
M.change_hooks = {}

local SWEEP_PER_STEP = 200          -- members checked for validity per slow step
local LEDS_PER_STEP_N = 50          -- drives whose lights are redrawn per slow step
local BASE_POWER = 120000           -- W: controller
local MEMBER_POWER = 4000           -- W: per member without its own power connection
local DRIVE_FRAME = "fork_me_drive"
local CELL_TAG = "fork_me_cell"
local OFF = 16                      -- pixels from the drive's left/top edge to its center
--- bay rectangles of the drive sprite (tools/gen_ae2_sprites.py: DRIVE_BAY_X, DRIVE_BAY_Y)
local BAY_X, BAY_Y = { 5, 17 }, { 4, 9, 14, 19, 24 }
local LED_GREEN, LED_ORANGE, LED_RED = { 0.3, 0.85, 0.4 }, { 1, 0.6, 0.1 }, { 0.95, 0.2, 0.15 }

--------------------------------------------------------------------------------
--- prototype data
--------------------------------------------------------------------------------

local function mod_data()
	local md = prototypes.mod_data["fork-me-network"]
	return md and md.data or { cells = {}, legacy_drives = {}, drive_slots = 10, names = {}, legacy = {} }
end

local names_cache
--- entity name -> kind; kinds with their own power connection draw nothing from the controller
local function kinds()
	if names_cache then return names_cache end
	local n = mod_data().names
	local k = {}
	if n.cable then
		k[n.cable] = "cable"
		k[n.controller] = "controller"
		k[n.drive] = "drive"
		k[n.interface] = "interface"
		k[n.import_bus] = "import-bus"
		k[n.export_bus] = "export-bus"
		k[n.terminal] = "terminal"
	end
	k["me-pattern-provider"] = "provider"
	k["me-level-maintainer"] = "maintainer"
	k["me-circuit-interface"] = "circuit"
	k["me-fluid-interface"] = "fluid-interface"
	local ac = prototypes.mod_data["fork-me-autocraft"]
	for name in pairs(ac and ac.data.cpus or {}) do k[name] = "cpu" end
	local fl = prototypes.mod_data["fork-me-fluids"]
	for name in pairs(fl and fl.data.drives or {}) do k[name] = "fluid-drive" end
	for name in pairs(k) do
		if not prototypes.entity[name] then k[name] = nil end
	end
	names_cache = k
	return k
end

local POWERED_SELF = { cable = true, controller = true, terminal = true, cpu = true, maintainer = true }

function M.node_names()
	local out = {}
	for name in pairs(kinds()) do out[#out + 1] = name end
	table.sort(out)
	return out
end

function M.kind_of(name) return kinds()[name] end

local function cell_spec(name) return mod_data().cells[name] end
M.cell_spec = cell_spec

local function drive_slots() return mod_data().drive_slots or 10 end

--------------------------------------------------------------------------------
--- state
--------------------------------------------------------------------------------

local function state()
	local s = storage.fork_me_net
	if not s then
		s = {
			nodes = {},       -- unit -> { entity, kind, net, adj = { unit -> true }, box, surface, force, position }
			nets = {},        -- id -> network (see new_net)
			next_net = 1,
			version = 0,      -- counts graph changes
			drives = {},      -- unit -> { entity, slots = { [i] = cell }, surface, force, position, leds, dirty }
			dirty = {},       -- drive unit -> true: lights to redraw
			sweep = 1,
		}
		storage.fork_me_net = s
	end
	return s
end
M.state = state

local function new_net(s, surface, force)
	local id = s.next_net
	s.next_net = id + 1
	local net = { id = id, nodes = {}, n = 0, surface = surface, force = force, controllers = {}, drives = {},
		status = "no-controller", items = {}, index = {}, cells = {}, cell_list = {},
		bytes = 0, bytes_total = 0, types = 0, types_total = 0, power = 0 }
	s.nets[id] = net
	return net
end

--------------------------------------------------------------------------------
--- keys
--------------------------------------------------------------------------------

local function quality_name(q)
	if q == nil then return "normal" end
	if type(q) == "string" then return q end
	return q.name
end

local function key_of(name, quality, data_json)
	local q = quality_name(quality)
	local key = q == "normal" and name or (name .. "@" .. q)
	if data_json then key = (q == "normal" and (name .. "@normal") or key) .. "#" .. data_json end
	return key
end
M.key_of = key_of

--- name, quality, json of the tags (nil for plain items)
local function parse_key(key)
	local base, json = key:match("^([^#]*)#(.*)$")
	base = base or key
	local name, q = base:match("^([^@]*)@(.*)$")
	if not name then name, q = base, "normal" end
	return name, q, json
end
M.parse_key = parse_key

--------------------------------------------------------------------------------
--- graph
--------------------------------------------------------------------------------

local function tile_box(entity)
	local p, pos = entity.prototype, entity.position
	local w, h = p.tile_width or 1, p.tile_height or 1
	local d = entity.direction
	if (d == defines.direction.east or d == defines.direction.west) and w ~= h then w, h = h, w end
	return { math.floor(pos.x - w / 2 + 0.5), math.floor(pos.y - h / 2 + 0.5),
		math.floor(pos.x + w / 2 + 0.5), math.floor(pos.y + h / 2 + 0.5) }
end

--- boxes share an edge of positive length
local function adjacent(a, b)
	if a[3] == b[1] or b[3] == a[1] then
		return math.min(a[4], b[4]) - math.max(a[2], b[2]) > 0
	elseif a[4] == b[2] or b[4] == a[2] then
		return math.min(a[3], b[3]) - math.max(a[1], b[1]) > 0
	end
	return false
end
M.adjacent = adjacent

--- cable picture: 1 + N + 2E + 4S + 8W
local function update_cable(s, node)
	if node.kind ~= "cable" or not node.entity.valid then return end
	local b, mask = node.box, 0
	for unit in pairs(node.adj) do
		local o = s.nodes[unit]
		if o then
			local ob = o.box
			if ob[4] == b[2] then mask = mask + 1
			elseif ob[1] == b[3] then mask = mask + 2
			elseif ob[2] == b[4] then mask = mask + 4
			elseif ob[3] == b[1] then mask = mask + 8 end
		end
	end
	node.entity.graphics_variation = mask + 1
end

local recompute

--- every member of the networks `ids` is visited once; split components get new ids (the largest keeps it)
local function components(s, net, starts)
	local seen, comps = {}, {}
	for _, start in ipairs(starts) do
		if not seen[start] and s.nodes[start] then
			local comp, queue, i = {}, { start }, 1
			seen[start] = true
			while queue[i] do
				local u = queue[i]
				i = i + 1
				comp[#comp + 1] = u
				for v in pairs(s.nodes[u].adj) do
					if not seen[v] and s.nodes[v] then
						seen[v] = true
						queue[#queue + 1] = v
					end
				end
			end
			comps[#comps + 1] = comp
		end
	end
	return comps
end

local function changed(s, net)
	s.version = s.version + 1
	recompute(s, net)
	for _, hook in pairs(M.change_hooks) do hook(net) end
end

--- Register a built member. Returns its node.
local function add_node(s, entity, kind)
	local unit = entity.unit_number
	local node = s.nodes[unit]
	if node then return node end
	node = { entity = entity, kind = kind, adj = {}, box = tile_box(entity), surface = entity.surface.index,
		force = entity.force.name, position = { x = entity.position.x, y = entity.position.y } }
	s.nodes[unit] = node
	local b = node.box
	local found = entity.surface.find_entities_filtered{
		area = { { b[1] - 0.5, b[2] - 0.5 }, { b[3] + 0.5, b[4] + 0.5 } }, name = M.node_names(), force = entity.force }
	local nets, order = {}, {}
	for _, e in pairs(found) do
		local other = e.valid and e.unit_number ~= unit and s.nodes[e.unit_number]
		if other and other.entity == e and adjacent(b, other.box) then
			node.adj[e.unit_number] = true
			other.adj[unit] = true
			if not nets[other.net] then
				nets[other.net] = true
				order[#order + 1] = other.net
			end
		end
	end
	local net
	if #order == 0 then
		net = new_net(s, node.surface, node.force)
	else
		table.sort(order, function(a, c)
			if s.nets[a].n ~= s.nets[c].n then return s.nets[a].n > s.nets[c].n end
			return a < c
		end)
		net = s.nets[order[1]]
		for i = 2, #order do                       -- merge the others into the largest
			local other = s.nets[order[i]]
			for u in pairs(other.nodes) do
				net.nodes[u] = true
				net.n = net.n + 1
				s.nodes[u].net = net.id
			end
			s.nets[other.id] = nil
		end
	end
	net.nodes[unit] = true
	net.n = net.n + 1
	node.net = net.id
	update_cable(s, node)
	for u in pairs(node.adj) do update_cable(s, s.nodes[u]) end
	if kind == "cable" and #order == 1 then
		s.version = s.version + 1                  -- only the member count changed (and the power)
		net.power_dirty = true
	else
		changed(s, net)
	end
	return node
end

--- Unregister a member (the entity may already be invalid). The drive's cells are handled by the caller.
local function remove_node(s, unit)
	local node = s.nodes[unit]
	if not node then return end
	s.nodes[unit] = nil
	local net = s.nets[node.net]
	local neighbours = {}
	for u in pairs(node.adj) do
		local o = s.nodes[u]
		if o then
			o.adj[unit] = nil
			neighbours[#neighbours + 1] = u
		end
	end
	table.sort(neighbours)
	for _, u in ipairs(neighbours) do update_cable(s, s.nodes[u]) end
	if not net then return end
	net.nodes[unit] = nil
	net.n = net.n - 1
	if net.n <= 0 then
		s.nets[net.id] = nil
		s.version = s.version + 1
		return
	end
	local comps = components(s, net, neighbours)
	if #comps <= 1 then
		if node.kind == "cable" then
			s.version = s.version + 1
			net.power_dirty = true
		else
			changed(s, net)
		end
		return
	end
	table.sort(comps, function(a, b)
		if #a ~= #b then return #a > #b end
		return a[1] < b[1]
	end)
	--- the largest part keeps the network (and its id); every other part becomes a new network
	for i = 2, #comps do
		local part = new_net(s, net.surface, net.force)
		for _, u in ipairs(comps[i]) do
			net.nodes[u] = nil
			net.n = net.n - 1
			part.nodes[u] = true
			part.n = part.n + 1
			s.nodes[u].net = part.id
		end
		changed(s, part)
	end
	changed(s, net)
end

--------------------------------------------------------------------------------
--- cells and network storage
--------------------------------------------------------------------------------

local function type_bytes(spec, count)
	return spec.per_type + math.ceil(count / 8)
end

--- items of `key` the cell can still take
local function cell_room(cell, spec, key)
	local free = spec.bytes - cell.bytes
	local have = cell.items[key]
	if have then
		return (math.ceil(have / 8) * 8 - have) + math.max(0, free) * 8
	end
	if cell.types >= spec.types then return 0 end
	free = free - spec.per_type
	if free <= 0 then return 0 end
	return free * 8
end

--- change the count of `key` in a cell by `delta`; returns the change of bytes and types
local function cell_add(cell, spec, key, delta)
	local have = cell.items[key] or 0
	local now = have + delta
	local before = have > 0 and type_bytes(spec, have) or 0
	local after = now > 0 and type_bytes(spec, now) or 0
	local dtypes = (now > 0 and 1 or 0) - (have > 0 and 1 or 0)
	cell.items[key] = now > 0 and now or nil
	if now <= 0 and cell.data then cell.data[key] = nil end
	cell.bytes = cell.bytes + after - before
	cell.types = cell.types + dtypes
	return after - before, dtypes
end

local function new_cell(name)
	return { name = name, items = {}, data = {}, bytes = 0, types = 0 }
end

--- the cell's contents as a fresh record (from the tags of a cell item); unknown items are dropped
local function cell_from_tags(name, tags)
	local cell = new_cell(name)
	local spec = cell_spec(name)
	local stored = type(tags) == "table" and tags[CELL_TAG] or nil
	if type(stored) ~= "table" or not spec then return cell end
	local keys = {}
	for key, count in pairs(stored.items or {}) do
		if type(key) == "string" and type(count) == "number" and count > 0 then keys[#keys + 1] = key end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local item = parse_key(key)
		if prototypes.item[item] then
			cell_add(cell, spec, key, math.floor(stored.items[key]))
			local d = stored.data and stored.data[key]
			if type(d) == "table" then cell.data[key] = d end
		end
	end
	return cell
end

local function cell_total(cell)
	local n = 0
	for _, c in pairs(cell.items) do n = n + c end
	return n
end

--- the item stack definition of a cell (tags and a description when it holds something)
local function cell_stack(cell)
	if next(cell.items) == nil then return { name = cell.name, count = 1 } end
	local items, data = {}, {}
	local keys = {}
	for key, count in pairs(cell.items) do
		items[key] = count
		keys[#keys + 1] = key
		if cell.data and cell.data[key] then data[key] = cell.data[key] end
	end
	table.sort(keys, function(a, b)
		if items[a] ~= items[b] then return items[a] > items[b] end
		return a < b
	end)
	local list = {}
	for i = 1, math.min(5, #keys) do
		local name = parse_key(keys[i])
		list[#list + 1] = items[keys[i]] .. " [item=" .. name .. "]"
	end
	local spec = cell_spec(cell.name)
	return {
		name = cell.name, count = 1,
		tags = { [CELL_TAG] = { items = items, data = data } },
		custom_description = { "fork-me-net.cell-holds", cell_total(cell), cell.types, table.concat(list, ", "),
			cell.bytes, spec and spec.bytes or 0, #keys > 5 and ", ..." or "" },
	}
end
M.cell_stack = cell_stack

--- the fill state of a cell: "room", "high" (above 75 % of the bytes), "full" (bytes or types)
local function cell_state(cell)
	local spec = cell_spec(cell.name)
	if not spec then return "full" end
	if cell.types >= spec.types or spec.bytes - cell.bytes < 1 or (cell.types == 0 and spec.bytes - cell.bytes <= spec.per_type) then return "full" end
	if cell.bytes > spec.bytes * 0.75 then return "high" end
	return "room"
end

--- add (sign 1) or remove (sign -1) the cell's contents to or from the network's totals and index
local function net_cell(net, cid, cell, sign)
	local spec = cell_spec(cell.name)
	if not spec then return end
	if sign > 0 then
		net.cells[cid] = cell
		net.cell_list[#net.cell_list + 1] = cid
	else
		net.cells[cid] = nil
		for i = #net.cell_list, 1, -1 do
			if net.cell_list[i] == cid then table.remove(net.cell_list, i) end
		end
	end
	net.bytes = net.bytes + sign * cell.bytes
	net.bytes_total = net.bytes_total + sign * spec.bytes
	net.types = net.types + sign * cell.types
	net.types_total = net.types_total + sign * spec.types
	for key, count in pairs(cell.items) do
		local now = (net.items[key] or 0) + sign * count
		net.items[key] = now > 0 and now or nil
		local idx = net.index[key]
		if sign > 0 then
			if not idx then idx = {} net.index[key] = idx end
			idx[cid] = true
		elseif idx then
			idx[cid] = nil
			if next(idx) == nil then net.index[key] = nil end
		end
	end
end

local function drive_cells(net, s, f)
	local units = {}
	for unit in pairs(net.drives) do units[#units + 1] = unit end
	table.sort(units)
	for _, unit in ipairs(units) do
		local d = s.drives[unit]
		if d then
			for slot = 1, drive_slots() do
				local cell = d.slots[slot]
				if cell then f(unit .. ":" .. slot, cell) end
			end
		end
	end
end

--- set the controller's power use: base + per member without its own power
local function update_power(s, net)
	net.power_dirty = nil
	local members = 0
	for unit in pairs(net.nodes) do
		local node = s.nodes[unit]
		if node and not POWERED_SELF[node.kind] then members = members + 1 end
	end
	net.power = BASE_POWER + MEMBER_POWER * members
	for unit in pairs(net.controllers) do
		local node = s.nodes[unit]
		if node and node.entity.valid then node.entity.power_usage = net.power / 60 end
	end
end

--- controllers, status, drives, storage totals and power of a network, from its members
function recompute(s, net)
	net.controllers, net.drives = {}, {}
	local nc = 0
	for unit in pairs(net.nodes) do
		local node = s.nodes[unit]
		if node then
			if node.kind == "controller" then net.controllers[unit] = true nc = nc + 1 end
			if node.kind == "drive" then net.drives[unit] = true end
		end
	end
	net.status = nc == 0 and "no-controller" or nc > 1 and "conflict" or "ok"
	for unit in pairs(net.controllers) do
		local e = s.nodes[unit].entity
		if e.valid then
			e.custom_status = net.status == "conflict"
				and { diode = defines.entity_status_diode.red, label = { "fork-me-net.status-conflict" } } or nil
		end
	end
	net.items, net.index, net.cells, net.cell_list = {}, {}, {}, {}
	net.bytes, net.bytes_total, net.types, net.types_total = 0, 0, 0, 0
	drive_cells(net, s, function(cid, cell) net_cell(net, cid, cell, 1) end)
	net.usable_tick = nil
	update_power(s, net)
end

--- true when the network works; else false and the reason ("no-controller", "conflict", "no-power")
function M.usable(net)
	if not net then return false, "no-network" end
	if net.status ~= "ok" then return false, net.status end
	if net.usable_tick == game.tick then return net.usable, net.why end
	local s = state()
	if net.power_dirty then update_power(s, net) end
	local ok, why = false, "no-controller"
	for unit in pairs(net.controllers) do
		local node = s.nodes[unit]
		local e = node and node.entity
		if e and e.valid then
			--- an energy interface without any pole reports no "no power" status: its buffer stays empty
			if e.status == defines.entity_status.no_power or e.energy <= 0 then why = "no-power" else ok, why = true, nil end
		end
	end
	net.usable, net.why, net.usable_tick = ok, why, game.tick
	return ok, why
end

--- the network an entity is a member of (working or not), nil if it is no member
function M.network_of(entity)
	if not (entity and entity.valid and entity.unit_number) then return nil end
	local s = storage.fork_me_net
	local node = s and s.nodes[entity.unit_number]
	return node and s.nets[node.net] or nil
end

--- the network of the entity if it works
function M.active_of(entity)
	local net = M.network_of(entity)
	if net and M.usable(net) then return net end
	return nil
end

--- the nearest member within `radius` of a position whose network works (`any`: working or not), and that
--- network; nil if there is none
function M.member_near(surface, position, force, radius, any)
	if not (surface and position) then return nil end
	local pos = { x = position.x or position[1], y = position.y or position[2] }
	local found = surface.find_entities_filtered{ position = pos, radius = radius or 1.5, name = M.node_names(), force = force }
	local best, bnet, bd
	for _, e in pairs(found) do
		local net = any and M.network_of(e) or M.active_of(e)
		if net then
			local dx, dy = e.position.x - pos.x, e.position.y - pos.y
			local d = dx * dx + dy * dy
			if not bd or d < bd or (d == bd and e.unit_number < best.unit_number) then best, bnet, bd = e, net, d end
		end
	end
	return best, bnet
end

--- the working network of the nearest member within `radius` of a position (nil if none)
function M.network_near(surface, position, force, radius, any)
	local _, net = M.member_near(surface, position, force, radius, any)
	return net
end

function M.get(id) local s = storage.fork_me_net return s and s.nets[id] or nil end

--- graph version (changes whenever a member is added or removed)
function M.version() local s = storage.fork_me_net return s and s.version or 0 end

local function mark_drive(s, unit) s.dirty[unit] = true end

--- items of `key` the network can take
local function room_for(net, key)
	local n = 0
	for cid in pairs(net.index[key] or {}) do
		local cell = net.cells[cid]
		n = n + cell_room(cell, cell_spec(cell.name), key)
	end
	for _, cid in ipairs(net.cell_list) do
		local cell = net.cells[cid]
		if not cell.items[key] then n = n + cell_room(cell, cell_spec(cell.name), key) end
	end
	return n
end

--- Store up to `count` of `key` (data: { tags, description } of an item with tags). Returns the amount stored.
local function insert_key(net, key, count, data)
	if count <= 0 then return 0 end
	local s = state()
	local left = count
	local function put(cid)
		local cell = net.cells[cid]
		local spec = cell_spec(cell.name)
		local n = math.min(left, cell_room(cell, spec, key))
		if n <= 0 then return end
		local db, dt = cell_add(cell, spec, key, n)
		if data and not cell.data[key] then cell.data[key] = data end
		net.bytes, net.types = net.bytes + db, net.types + dt
		net.items[key] = (net.items[key] or 0) + n
		local idx = net.index[key]
		if not idx then idx = {} net.index[key] = idx end
		idx[cid] = true
		left = left - n
		mark_drive(s, tonumber(cid:match("^(%d+):")))
	end
	local held = {}
	for cid in pairs(net.index[key] or {}) do held[#held + 1] = cid end
	table.sort(held)
	for _, cid in ipairs(held) do
		if left <= 0 then break end
		put(cid)
	end
	for _, cid in ipairs(net.cell_list) do
		if left <= 0 then break end
		if not net.cells[cid].items[key] then put(cid) end
	end
	return count - left
end

local function extract_key(net, key, count)
	if count <= 0 or not net.items[key] then return 0 end
	local s = state()
	local left = count
	local held = {}
	for cid in pairs(net.index[key] or {}) do held[#held + 1] = cid end
	table.sort(held)
	for _, cid in ipairs(held) do
		if left <= 0 then break end
		local cell = net.cells[cid]
		local n = math.min(left, cell.items[key] or 0)
		if n > 0 then
			local db, dt = cell_add(cell, cell_spec(cell.name), key, -n)
			net.bytes, net.types = net.bytes + db, net.types + dt
			left = left - n
			if not cell.items[key] then net.index[key][cid] = nil end
			mark_drive(s, tonumber(cid:match("^(%d+):")))
		end
	end
	local now = (net.items[key] or 0) - (count - left)
	net.items[key] = now > 0 and now or nil
	if net.index[key] and next(net.index[key]) == nil then net.index[key] = nil end
	return count - left
end

--- data ({ tags, description }) of an item-with-tags key in the network
local function data_of(net, key)
	for cid in pairs(net.index[key] or {}) do
		local d = net.cells[cid].data
		if d and d[key] then return d[key] end
	end
	return nil
end

--- the public API: plain items by name and quality; nothing happens when the network does not work
function M.insert(net, name, quality, count)
	if not (M.usable(net) and prototypes.item[name]) then return 0 end
	return insert_key(net, key_of(name, quality), math.floor(count))
end

function M.extract(net, name, quality, count)
	if not M.usable(net) then return 0 end
	return extract_key(net, key_of(name, quality), math.floor(count))
end

function M.count(net, name, quality)
	if not M.usable(net) then return 0 end
	return net.items[key_of(name, quality)] or 0
end

function M.extract_key(net, key, count)
	if not M.usable(net) then return 0 end
	return extract_key(net, key, math.floor(count))
end

function M.count_key(net, key)
	if not M.usable(net) then return 0 end
	return net.items[key] or 0
end

function M.can_insert(net, name, quality, count)
	if not M.usable(net) then return 0 end
	return math.min(math.floor(count), room_for(net, key_of(name, quality)))
end

--- { { key, name, quality, count, data } }, unsorted
function M.contents(net)
	local out = {}
	if not M.usable(net) then return out end
	for key, count in pairs(net.items) do
		local name, q, json = parse_key(key)
		out[#out + 1] = { key = key, name = name, quality = q, count = count, special = json ~= nil }
	end
	return out
end

--- totals of plain normal quality items { name -> count } (autocrafting stock)
function M.plain_counts(net)
	local out = {}
	if not M.usable(net) then return out end
	for key, count in pairs(net.items) do
		if not key:find("[@#]") then out[key] = count end
	end
	return out
end

function M.stats(net)
	local ok, why = M.usable(net)
	local drives, cells = 0, #net.cell_list
	for _ in pairs(net.drives) do drives = drives + 1 end
	return { ok = ok, status = ok and "ok" or why, bytes = net.bytes, bytes_total = net.bytes_total,
		types = net.types, types_total = net.types_total, drives = drives, cells = cells, power = net.power,
		members = net.n, id = net.id }
end

--- Why a stack cannot go into the network (a locale key suffix), or nil and its key and data
function M.storable(stack)
	if not (stack and stack.valid_for_read) then return "empty" end
	local proto = stack.prototype
	if proto.get_spoil_ticks(stack.quality) > 0 then return "cannot-store-spoil" end
	if stack.item and not stack.is_item_with_tags then return "cannot-store" end    -- inventories, blueprints, armor
	if stack.health < 1 then return "cannot-store-damaged" end
	if proto.type == "tool" and stack.durability < proto.get_durability(stack.quality) then return "cannot-store-damaged" end
	if proto.type == "ammo" and stack.ammo < proto.magazine_size then return "cannot-store-damaged" end
	if stack.is_item_with_tags then
		local tags = stack.tags
		local desc = stack.custom_description
		if (tags and next(tags)) or (desc and desc ~= "") then
			local data = { tags = tags or {}, description = desc }
			return nil, key_of(stack.name, stack.quality, helpers.table_to_json(data)), data
		end
	end
	return nil, key_of(stack.name, stack.quality), nil
end

--- Store (part of) a LuaItemStack; the stack shrinks by what was stored. Returns the count, or nil and a reason.
function M.insert_stack(net, stack)
	local ok, why = M.usable(net)
	if not ok then return nil, why end
	local problem, key, data = M.storable(stack)
	if problem then return nil, problem end
	local n = insert_key(net, key, stack.count, data)
	if n <= 0 then return nil, "no-storage" end
	if n >= stack.count then stack.clear() else stack.count = stack.count - n end
	return n
end

--- Store up to `max` items of a LuaItemStack (the stack shrinks). Returns the count, or nil and a reason.
function M.insert_partial(net, stack, max)
	local ok, why = M.usable(net)
	if not ok then return nil, why end
	local problem, key, data = M.storable(stack)
	if problem then return nil, problem end
	local n = insert_key(net, key, math.min(stack.count, math.floor(max)), data)
	if n <= 0 then return nil, "no-storage" end
	if n >= stack.count then stack.clear() else stack.count = stack.count - n end
	return n
end

--- the stack definition for `count` of `key` (with the tags of an item with tags)
local function stack_def(net, key, count)
	local name, q = parse_key(key)
	local def = { name = name, quality = q, count = count }
	local data = data_of(net, key)
	if data then
		def.tags = data.tags
		if data.description then def.custom_description = data.description end
	end
	return def
end

--- Move up to `count` of `key` into `target` (LuaPlayer, LuaEntity, LuaInventory: anything with insert, or an
--- empty LuaItemStack). Returns the amount moved.
function M.extract_to(net, target, key, count)
	if not M.usable(net) then return 0 end
	count = math.min(math.floor(count), net.items[key] or 0)
	if count <= 0 or not prototypes.item[(parse_key(key))] then return 0 end
	local def = stack_def(net, key, count)
	local moved
	if target.object_name == "LuaItemStack" then
		if target.valid_for_read then return 0 end
		local size = prototypes.item[def.name].stack_size
		def.count = math.min(def.count, size)
		if not target.set_stack(def) then return 0 end
		moved = target.count
	else
		moved = target.insert(def)
	end
	if moved <= 0 then return 0 end
	local got = extract_key(net, key, moved)
	if got < moved then                       -- cannot happen (count was checked), but never duplicate
		if target.object_name == "LuaItemStack" then target.count = math.max(0, got) if got == 0 then target.clear() end
		else target.remove_item{ name = def.name, quality = def.quality, count = moved - got } end
	end
	return got
end

--------------------------------------------------------------------------------
--- drives
--------------------------------------------------------------------------------

local function drive_record(s, entity)
	local unit = entity.unit_number
	local d = s.drives[unit]
	if not d then
		d = { entity = entity, slots = {}, surface = entity.surface.index, force = entity.force.name,
			position = { x = entity.position.x, y = entity.position.y }, leds = {} }
		s.drives[unit] = d
	end
	return d
end

local function drive_net(s, unit)
	local node = s.nodes[unit]
	return node and s.nets[node.net] or nil
end

--- put a cell record into a free slot of a drive (and into its network's totals)
local function place_cell(s, d, slot, cell)
	d.slots[slot] = cell
	local unit = d.entity.unit_number
	local net = drive_net(s, unit)
	if net then net_cell(net, unit .. ":" .. slot, cell, 1) end
	mark_drive(s, unit)
end

local function remove_cell(s, d, slot)
	local cell = d.slots[slot]
	if not cell then return nil end
	local unit = d.entity.valid and d.entity.unit_number or d.unit
	local net = unit and drive_net(s, unit)
	if net and net.cells[unit .. ":" .. slot] then net_cell(net, unit .. ":" .. slot, cell, -1) end
	d.slots[slot] = nil
	if unit then mark_drive(s, unit) end
	return cell
end

--- Put the cell in `stack` into `slot` (the first free one when nil). Returns the slot, or nil and a reason.
function M.insert_cell(drive, stack, slot)
	local s = state()
	if not (drive and drive.valid and M.kind_of(drive.name) == "drive") then return nil, "no-drive" end
	if not (stack and stack.valid_for_read and cell_spec(stack.name)) then return nil, "not-a-cell" end
	local d = drive_record(s, drive)
	if slot == nil then
		for i = 1, drive_slots() do
			if not d.slots[i] then slot = i break end
		end
		if not slot then return nil, "drive-full" end
	end
	if d.slots[slot] then return nil, "slot-taken" end
	local cell = cell_from_tags(stack.name, stack.is_item_with_tags and stack.tags or nil)
	if stack.count > 1 then stack.count = stack.count - 1 else stack.clear() end
	place_cell(s, d, slot, cell)
	return slot
end

--- Take the cell out of `slot` into `target` (an empty LuaItemStack, or a LuaInventory / LuaPlayer).
--- Its contents go into its tags. Returns true when it was moved.
function M.take_cell(drive, slot, target)
	local s = state()
	local d = drive and drive.valid and s.drives[drive.unit_number]
	local cell = d and d.slots[slot]
	if not cell then return false end
	local def = cell_stack(cell)
	if target.object_name == "LuaItemStack" then
		if target.valid_for_read or not target.set_stack(def) then return false end
	elseif target.insert(def) < 1 then
		return false
	end
	remove_cell(s, d, slot)
	return true
end

--- Store (part of) a LuaItemStack in the cells of one drive, whether or not its network works (the migration
--- fills each new drive with the contents of the old one). The stack shrinks. Returns the count, or nil and a
--- reason.
function M.store_in_drive(drive, stack)
	local s = state()
	local d = drive and drive.valid and s.drives[drive.unit_number]
	if not d then return nil, "no-drive" end
	local problem, key, data = M.storable(stack)
	if problem then return nil, problem end
	local unit = drive.unit_number
	local net = drive_net(s, unit)
	local left = stack.count
	for slot = 1, drive_slots() do
		if left <= 0 then break end
		local cell = d.slots[slot]
		if cell then
			local spec = cell_spec(cell.name)
			local n = math.min(left, cell_room(cell, spec, key))
			if n > 0 then
				local db, dt = cell_add(cell, spec, key, n)
				if data and not cell.data[key] then cell.data[key] = data end
				local cid = unit .. ":" .. slot
				if net and net.cells[cid] then
					net.bytes, net.types = net.bytes + db, net.types + dt
					net.items[key] = (net.items[key] or 0) + n
					net.index[key] = net.index[key] or {}
					net.index[key][cid] = true
				end
				left = left - n
			end
		end
	end
	local n = stack.count - left
	if n <= 0 then return nil, "no-storage" end
	mark_drive(s, unit)
	if left <= 0 then stack.clear() else stack.count = left end
	return n
end

--- plain data of a drive's slots for GUIs and tests: { [slot] = { name, items, bytes, bytes_total, types, state } }
function M.drive_info(drive)
	local s = storage.fork_me_net
	local d = s and drive and drive.valid and s.drives[drive.unit_number]
	local out = {}
	if not d then return out end
	for slot = 1, drive_slots() do
		local cell = d.slots[slot]
		if cell then
			local spec = cell_spec(cell.name) or { bytes = 0, types = 0 }
			local items = {}
			for k, v in pairs(cell.items) do items[k] = v end
			out[slot] = { name = cell.name, items = items, bytes = cell.bytes, bytes_total = spec.bytes,
				types = cell.types, types_total = spec.types, state = cell_state(cell) }
		end
	end
	return out
end

--- the cells of a drive record as stack definitions, and the drive record emptied (mined, destroyed)
local function unload_drive(s, d)
	local out = {}
	for slot = 1, drive_slots() do
		local cell = remove_cell(s, d, slot)
		if cell then out[#out + 1] = cell_stack(cell) end
	end
	return out
end

local function spill(surface, position, def)
	local inv = game.create_inventory(1)
	inv[1].set_stack(def)
	surface.spill_item_stack{ position = position, stack = inv[1], allow_belts = false }
	inv.destroy()
end

local function clear_leds(d)
	for _, obj in pairs(d.leds or {}) do
		if obj.valid then obj.destroy() end
	end
	d.leds = {}
end

--- redraw the lights of a drive: one rectangle per cell, colored by its fill state
local function draw_leds(s, d)
	clear_leds(d)
	local e = d.entity
	if not e.valid then return end
	for slot = 1, drive_slots() do
		local cell = d.slots[slot]
		if cell then
			local col, row = (slot - 1) % 2, math.floor((slot - 1) / 2)
			local x0, y0 = BAY_X[col + 1], BAY_Y[row + 1]
			local st = cell_state(cell)
			d.leds[slot] = rendering.draw_rectangle{
				color = st == "full" and LED_RED or st == "high" and LED_ORANGE or LED_GREEN,
				filled = true, surface = e.surface,
				left_top = { entity = e, offset = { (x0 + 1 - OFF) / 32, (y0 + 1 - OFF) / 32 } },
				right_bottom = { entity = e, offset = { (x0 + 9 - OFF) / 32, (y0 + 3 - OFF) / 32 } },
			}
		end
	end
end

--------------------------------------------------------------------------------
--- drive GUI (screen frame, the open key on a drive)
--------------------------------------------------------------------------------

local function find(root, name)
	local queue, i = { root }, 1
	while queue[i] do
		for _, child in pairs(queue[i].children) do
			if child.name == name then return child end
			queue[#queue + 1] = child
		end
		i = i + 1
	end
end

local function drive_gui_refresh(player)
	local frame = player.gui.screen[DRIVE_FRAME]
	if not frame then return end
	local s = state()
	local d = s.drives[frame.tags.unit]
	if not (d and d.entity.valid) then frame.destroy() return end
	local net = drive_net(s, frame.tags.unit)
	local ok, why = M.usable(net)
	find(frame, "fork_me_drive_status").caption = ok and { "fork-me-net.drive-online" } or { "fork-me-net.status-" .. (why or "no-network") }
	local grid = find(frame, "fork_me_drive_grid")
	grid.clear()
	for slot = 1, drive_slots() do
		local cell = d.slots[slot]
		local spec = cell and cell_spec(cell.name)
		local b = grid.add{ type = "sprite-button", style = "slot_button", tags = { fork_me_drive_slot = slot },
			sprite = cell and ("item/" .. cell.name) or nil,
			tooltip = cell and { "fork-me-net.drive-slot", cell_total(cell), cell.types, spec.types, cell.bytes, spec.bytes }
				or { "fork-me-net.drive-slot-empty" } }
		b.style.size = 40
		local flow = grid.add{ type = "flow", direction = "vertical" }
		local bar = flow.add{ type = "progressbar", value = cell and spec and math.min(1, cell.bytes / spec.bytes) or 0 }
		bar.style.width = 110
		flow.add{ type = "label", caption = cell and { "fork-me-net.drive-slot-short", cell.bytes, spec.bytes, cell.types, spec.types } or "" }
	end
end

local function drive_gui_open(player, entity)
	local frame = player.gui.screen[DRIVE_FRAME]
	if frame then frame.destroy() end
	frame = player.gui.screen.add{ type = "frame", name = DRIVE_FRAME, direction = "vertical", caption = entity.localised_name,
		tags = { unit = entity.unit_number } }
	frame.auto_center = true
	local help = frame.add{ type = "label", caption = { "fork-me-net.drive-help" } }
	help.style.single_line = false
	help.style.maximal_width = 330
	frame.add{ type = "label", name = "fork_me_drive_status" }
	frame.add{ type = "table", name = "fork_me_drive_grid", column_count = 4 }
	player.opened = frame
	drive_gui_refresh(player)
end

--- a click on a slot: with a cell in the cursor it goes into the slot (a cell there is swapped into the cursor);
--- with an empty cursor the cell goes into the cursor (shift: into the inventory). Returns a reason on failure.
function M.drive_click(cursor, inventory, drive, slot, shift)
	local s = state()
	if not (drive and drive.valid and M.kind_of(drive.name) == "drive") then return "no-drive" end
	local d = drive_record(s, drive)
	if cursor and cursor.valid_for_read then
		if not cell_spec(cursor.name) then return "not-a-cell" end
		if d.slots[slot] then                        -- swap: the cell in the slot goes into the cursor
			local held = game.create_inventory(1)
			held[1].transfer_stack(cursor)
			M.take_cell(drive, slot, cursor)
			M.insert_cell(drive, held[1], slot)
			if held[1].valid_for_read then cursor.transfer_stack(held[1]) end   -- not a cell after all: back
			held.destroy()
			return nil
		end
		local _, why = M.insert_cell(drive, cursor, slot)
		return why
	end
	if not d.slots[slot] then return nil end
	if shift then
		if not (inventory and M.take_cell(drive, slot, inventory)) then return "inventory-full" end
	elseif cursor then
		if not M.take_cell(drive, slot, cursor) then return "inventory-full" end
	end
	return nil
end

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

--- legacy ghosts (old drives, controller, interface) become ghosts of the new entities
local function swap_legacy_ghost(entity)
	local md = mod_data()
	local name = entity.ghost_name
	local target
	if md.legacy_drives[name] then target = md.names.drive
	elseif name == md.legacy.controller and entity.ghost_type == "roboport" then target = md.names.controller
	elseif name == md.legacy.interface and entity.ghost_type == "logistic-container" then target = md.names.interface end
	if not target then return end
	local surface, pos, force = entity.surface, entity.position, entity.force
	entity.destroy()
	surface.create_entity{ name = "entity-ghost", inner_name = target, position = pos, force = force }
end

--- the old drive item a build consumed (placing it gives an ME Drive with its four empty cells)
local function legacy_item(event)
	local md = mod_data()
	local stack = event and event.stack
	if stack and stack.valid and stack.valid_for_read and md.legacy_drives[stack.name] then return stack.name, nil end
	local consumed = event and event.consumed_items
	if consumed and consumed.valid then
		for i = 1, #consumed do
			local st = consumed[i]
			if st.valid_for_read and md.legacy_drives[st.name] then return st.name, event.player_index end
		end
	end
	return nil
end

--- `event`: the build event (for the item that was placed); `source`: the original of a clone
function M.on_built(entity, event)
	if not (entity and entity.valid) then return end
	if entity.name == "entity-ghost" then swap_legacy_ghost(entity) return end
	local kind = kinds()[entity.name]
	if not kind then return end
	local s = state()
	if kind == "drive" then
		local d = drive_record(s, entity)
		local old = legacy_item(event)
		if old then
			local info = mod_data().legacy_drives[old]
			for i = 1, info.cells do d.slots[i] = new_cell(info.cell) end
			if info.extra then
				local player = event.player_index and game.get_player(event.player_index)
				local got = player and player.insert(info.extra) or 0
				if got < info.extra.count then spill(entity.surface, entity.position, { name = info.extra.name, count = info.extra.count - got }) end
			end
		end
	end
	add_node(s, entity, kind)
	if kind == "drive" then mark_drive(s, entity.unit_number) end
end

--- A member is mined (its cells go into `buffer`), destroyed (`died`: its cells are spilled) or removed by a
--- script. Call before the entity is gone.
function M.on_removed(entity, buffer)
	if not (entity and entity.valid and entity.unit_number) then return end
	local s = storage.fork_me_net
	if not (s and s.nodes[entity.unit_number]) then return end
	local d = s.drives[entity.unit_number]
	if d then
		for _, def in ipairs(unload_drive(s, d)) do
			local got = buffer and buffer.valid and buffer.insert(def) or 0
			if got < 1 then spill(entity.surface, entity.position, def) end
		end
		clear_leds(d)
		s.drives[entity.unit_number] = nil
		s.dirty[entity.unit_number] = nil
	end
	remove_node(s, entity.unit_number)
end

--- a member whose entity vanished without an event: spill its cells at the stored position, unregister it
local function vanish(s, unit)
	local node = s.nodes[unit]
	local d = s.drives[unit]
	if d then
		local surface = game.get_surface(d.surface)
		d.unit = unit
		local defs = unload_drive(s, d)
		if surface then
			for _, def in ipairs(defs) do spill(surface, d.position, def) end
			local force = game.forces[d.force]
			if #defs > 0 and force then
				force.print({ "fork-me-net.drive-vanished", #defs, string.format("[gps=%d,%d,%s]", math.floor(d.position.x), math.floor(d.position.y), surface.name) })
			end
		end
		clear_leds(d)
		s.drives[unit] = nil
		s.dirty[unit] = nil
	end
	if node then remove_node(s, unit) end
end

--- every 60 ticks (from the terminal module): the lights of changed drives, the sweep, open drive GUIs
function M.slow_step()
	local s = storage.fork_me_net
	if not s then return end
	local n = 0
	for unit in pairs(s.dirty) do
		if n >= LEDS_PER_STEP_N then break end
		s.dirty[unit] = nil
		local d = s.drives[unit]
		if d then draw_leds(s, d) end
		n = n + 1
	end
	--- sweep: members removed without an event
	local units = {}
	local count = 0
	for unit, node in pairs(s.nodes) do
		count = count + 1
		if count >= s.sweep and #units < SWEEP_PER_STEP then units[#units + 1] = unit end
	end
	s.sweep = (#units < SWEEP_PER_STEP) and 1 or (s.sweep + SWEEP_PER_STEP)
	for _, unit in ipairs(units) do
		local node = s.nodes[unit]
		if node and not node.entity.valid then vanish(s, unit) end
	end
	for _, player in pairs(game.connected_players) do
		local frame = player.gui.screen[DRIVE_FRAME]
		if frame then
			local d = s.drives[frame.tags.unit]
			if not (d and d.entity.valid and player.can_reach_entity(d.entity)) then frame.destroy()
			else drive_gui_refresh(player) end
		end
	end
end

--- the open key on a selected entity: a drive (with a cell in the cursor: the cell goes into the first free slot)
function M.on_open_input(player, entity)
	if not (entity and entity.valid and kinds()[entity.name] == "drive") then return false end
	if not player.can_reach_entity(entity) then return true end
	local cursor = player.cursor_stack
	if cursor and cursor.valid_for_read and cell_spec(cursor.name) then
		local _, why = M.insert_cell(entity, cursor)
		if why then player.create_local_flying_text{ text = { "fork-me-net.error-" .. why }, create_at_cursor = true } end
		return true
	end
	drive_gui_open(player, entity)
	return true
end

function M.on_gui_click(event)
	local el = event.element
	local slot = el and el.valid and el.tags and el.tags.fork_me_drive_slot
	if not slot then return false end
	local player = game.get_player(event.player_index)
	local frame = player.gui.screen[DRIVE_FRAME]
	local d = frame and state().drives[frame.tags.unit]
	if not (d and d.entity.valid and player.can_reach_entity(d.entity)) then
		if frame then frame.destroy() end
		return true
	end
	local why = M.drive_click(player.cursor_stack, player.get_main_inventory(), d.entity, slot, event.shift)
	if why then player.create_local_flying_text{ text = { "fork-me-net.error-" .. why }, create_at_cursor = true } end
	drive_gui_refresh(player)
	return true
end

function M.on_gui_closed(event)
	local el = event.element
	if not (el and el.valid and el.name == DRIVE_FRAME) then return false end
	el.destroy()
	return true
end

--------------------------------------------------------------------------------
--- rebuild (on_init, on_configuration_changed): the only map scan
--------------------------------------------------------------------------------

function M.rebuild()
	names_cache = nil
	local s = state()
	local old_drives = s.drives
	s.nodes, s.nets, s.version = {}, {}, s.version + 1
	s.drives, s.dirty, s.sweep = {}, {}, 1
	local names = M.node_names()
	local all = {}
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = names }) do all[#all + 1] = e end
	end
	table.sort(all, function(a, b) return a.unit_number < b.unit_number end)
	--- drives keep their cells (by unit number); cells of drives that are gone are spilled where they stood
	for unit, d in pairs(old_drives) do
		if d.entity.valid and kinds()[d.entity.name] == "drive" then
			s.drives[unit] = d
			d.leds = d.leds or {}
			clear_leds(d)
			for slot in pairs(d.slots) do
				if slot > drive_slots() or not cell_spec(d.slots[slot].name) then d.slots[slot] = nil end
			end
			s.dirty[unit] = true
		else
			local surface = game.get_surface(d.surface)
			if surface then
				for slot = 1, drive_slots() do
					local cell = d.slots[slot]
					if cell then spill(surface, d.position, cell_stack(cell)) end
				end
			end
		end
	end
	--- nodes without links first, then the links, then the components
	for _, e in ipairs(all) do
		local unit = e.unit_number
		s.nodes[unit] = { entity = e, kind = kinds()[e.name], adj = {}, box = tile_box(e), surface = e.surface.index,
			force = e.force.name, position = { x = e.position.x, y = e.position.y } }
		if kinds()[e.name] == "drive" then drive_record(s, e) s.dirty[unit] = true end
	end
	for _, e in ipairs(all) do
		local node = s.nodes[e.unit_number]
		local b = node.box
		for _, o in pairs(e.surface.find_entities_filtered{
			area = { { b[1] - 0.5, b[2] - 0.5 }, { b[3] + 0.5, b[4] + 0.5 } }, name = names, force = e.force }) do
			local other = o.unit_number ~= e.unit_number and s.nodes[o.unit_number]
			if other and adjacent(b, other.box) then node.adj[o.unit_number] = true end
		end
	end
	local seen = {}
	for _, e in ipairs(all) do
		local unit = e.unit_number
		if not seen[unit] then
			local node = s.nodes[unit]
			local net = new_net(s, node.surface, node.force)
			local queue, i = { unit }, 1
			seen[unit] = true
			while queue[i] do
				local u = queue[i]
				i = i + 1
				net.nodes[u] = true
				net.n = net.n + 1
				s.nodes[u].net = net.id
				for v in pairs(s.nodes[u].adj) do
					if not seen[v] then seen[v] = true queue[#queue + 1] = v end
				end
			end
			recompute(s, net)
		end
	end
	for _, node in pairs(s.nodes) do update_cable(s, node) end
	for _, player in pairs(game.players) do
		local frame = player.gui.screen[DRIVE_FRAME]
		if frame then frame.destroy() end
	end
	for _, hook in pairs(M.change_hooks) do hook(nil) end
end

--------------------------------------------------------------------------------
--- cable router (migration and tests): connect members with cables over free tiles
--------------------------------------------------------------------------------

--- Lays cables so that every entity of `members` is in the network of members[1] (a controller): one breadth
--- first search per member from the cables and controllers already connected, over tiles where an ME Cable can
--- be placed and that touch no member of another network with a controller, within the members' bounding box
--- plus `margin` tiles. Returns the number of cables placed and the list of members no path reached.
function M.connect(members, margin)
	local s = state()
	local root = members[1]
	if not (root and root.valid) then return 0, members end
	local surface, force = root.surface, root.force
	local cable = mod_data().names.cable
	margin = margin or 16
	local l, t, r, b = math.huge, math.huge, -math.huge, -math.huge
	for _, e in pairs(members) do
		if e.valid then
			local bx = tile_box(e)
			l, t, r, b = math.min(l, bx[1]), math.min(t, bx[2]), math.max(r, bx[3]), math.max(b, bx[4])
		end
	end
	l, t, r, b = l - margin, t - margin, r + margin, b + margin
	local free = {}                                   -- "x,y" -> true / false (cached can_place)
	local function is_free(x, y)
		local k = x .. "," .. y
		local v = free[k]
		if v == nil then
			v = surface.can_place_entity{ name = cable, position = { x + 0.5, y + 0.5 }, force = force }
			free[k] = v
		end
		return v
	end
	--- members of other networks in the area: a cable next to one would join that network (two controllers)
	local tiles = {}                                  -- "x,y" -> node of the area
	local surface_index = surface.index
	for _, node in pairs(s.nodes) do
		local bx = node.box
		if node.surface == surface_index and bx[3] > l - 1 and bx[1] < r + 1 and bx[4] > t - 1 and bx[2] < b + 1 then
			for x = bx[1], bx[3] - 1 do
				for y = bx[2], bx[4] - 1 do tiles[x .. "," .. y] = node end
			end
		end
	end
	local wanted = {}                                 -- unit -> true for the members to connect
	for _, e in pairs(members) do if e.valid then wanted[e.unit_number] = true end end
	local placed, unreached = 0, {}
	local function net_of(e) local n = M.network_of(e) return n and n.id end
	local function foreign(x, y, root_net)
		for _, dxy in ipairs({ { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }) do
			local node = tiles[(x + dxy[1]) .. "," .. (y + dxy[2])]
			if node and node.net ~= root_net and not (node.entity.valid and wanted[node.entity.unit_number]) then
				local o = s.nets[node.net]
				--- a network without a controller (cables, members of the group) may join; one with a controller not
				if not o or next(o.controllers) then return true end
			end
		end
		return false
	end
	for _ = 1, #members do
		local root_net = net_of(root)
		local targets, target_tiles = {}, {}
		for _, e in pairs(members) do
			if e.valid and net_of(e) ~= root_net and not unreached[e.unit_number] then
				targets[#targets + 1] = e
				local bx = tile_box(e)
				for x = bx[1], bx[3] - 1 do
					target_tiles[x .. "," .. (bx[2] - 1)] = e
					target_tiles[x .. "," .. bx[4]] = e
				end
				for y = bx[2], bx[4] - 1 do
					target_tiles[(bx[1] - 1) .. "," .. y] = e
					target_tiles[bx[3] .. "," .. y] = e
				end
			end
		end
		if #targets == 0 then break end
		--- sources: the free tiles next to the root network's cables and controller (members stay leaves: removing
		--- one never cuts another off)
		local parent, queue, qi = {}, {}, 1
		local units = {}
		for unit in pairs(s.nets[root_net].nodes) do
			local kind = s.nodes[unit].kind
			if kind == "cable" or kind == "controller" then units[#units + 1] = unit end
		end
		table.sort(units)
		for _, unit in ipairs(units) do
			local bx = s.nodes[unit].box
			local edge = {}
			for x = bx[1], bx[3] - 1 do edge[#edge + 1] = { x, bx[2] - 1 } edge[#edge + 1] = { x, bx[4] } end
			for y = bx[2], bx[4] - 1 do edge[#edge + 1] = { bx[1] - 1, y } edge[#edge + 1] = { bx[3], y } end
			for _, p in ipairs(edge) do
				local k = p[1] .. "," .. p[2]
				if parent[k] == nil and p[1] >= l and p[1] < r and p[2] >= t and p[2] < b and is_free(p[1], p[2])
					and not foreign(p[1], p[2], root_net) then
					parent[k] = false
					queue[#queue + 1] = p
				end
			end
		end
		local hit
		while queue[qi] do
			local p = queue[qi]
			qi = qi + 1
			local k = p[1] .. "," .. p[2]
			if target_tiles[k] then hit = p break end
			for _, dxy in ipairs({ { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }) do
				local x, y = p[1] + dxy[1], p[2] + dxy[2]
				local nk = x .. "," .. y
				if parent[nk] == nil and x >= l and x < r and y >= t and y < b and is_free(x, y) and not foreign(x, y, root_net) then
					parent[nk] = k
					queue[#queue + 1] = { x, y }
				end
			end
		end
		if not hit then
			for _, e in ipairs(targets) do unreached[e.unit_number] = e end
			break
		end
		local k = hit[1] .. "," .. hit[2]
		while k do
			local x, y = k:match("^(-?%d+),(-?%d+)$")
			local e = surface.create_entity{ name = cable, position = { tonumber(x) + 0.5, tonumber(y) + 0.5 }, force = force }
			if e then
				placed = placed + 1
				free[k] = false
				M.on_built(e)
				tiles[k] = s.nodes[e.unit_number]
			end
			k = parent[k] or nil
		end
	end
	local out = {}
	for _, e in pairs(unreached) do out[#out + 1] = e end
	return placed, out
end

--------------------------------------------------------------------------------
--- remote interface (tests and other mods use the same functions as the GUIs)
--------------------------------------------------------------------------------

local function info(net)
	if not net then return nil end
	local st = M.stats(net)
	local controllers = 0
	for _ in pairs(net.controllers) do controllers = controllers + 1 end
	st.controllers = controllers
	st.graph_status = net.status
	return st
end

remote.add_interface("gregtorio-me-network", {
	--- { ok, status, id, members, controllers, drives, cells, bytes, bytes_total, types, types_total, power } or nil
	network = function(entity) return info(M.network_of(entity)) end,
	same_network = function(a, b)
		local na, nb = M.network_of(a), M.network_of(b)
		return na ~= nil and na == nb
	end,
	insert = function(entity, name, count, quality) return M.insert(M.network_of(entity), name, quality, count) end,
	extract = function(entity, name, count, quality) return M.extract(M.network_of(entity), name, quality, count) end,
	count = function(entity, name, quality) return M.count(M.network_of(entity), name, quality) end,
	can_insert = function(entity, name, count, quality) return M.can_insert(M.network_of(entity), name, quality, count) end,
	--- { key -> count }
	contents = function(entity)
		local out = {}
		for _, c in pairs(M.contents(M.network_of(entity))) do out[c.key] = c.count end
		return out
	end,
	insert_stack = function(entity, stack) return M.insert_stack(M.network_of(entity), stack) end,
	--- `count` of `name` straight into the cells of one drive (also without power; the migration's function)
	store_in_drive = function(drive, name, count, quality)
		local inv = game.create_inventory(1)
		local size = prototypes.item[name].stack_size
		local n, left = 0, count
		while left > 0 do
			local want = math.min(left, size)
			inv[1].set_stack{ name = name, count = want, quality = quality or "normal" }
			local got = M.store_in_drive(drive, inv[1]) or 0
			n, left = n + got, left - got
			if got < want then break end
		end
		inv.destroy()
		return n
	end,
	--- what a build event does for `entity` placed from `stack` (an old drive item gives its cells)
	built = function(entity, stack) M.on_built(entity, { stack = stack }) end,
	extract_to = function(entity, target, key, count) return M.extract_to(M.network_of(entity), target, key, count) end,
	insert_cell = function(drive, stack, slot) return M.insert_cell(drive, stack, slot) end,
	take_cell = function(drive, slot, target) return M.take_cell(drive, slot, target) end,
	drive = function(drive) return M.drive_info(drive) end,
	--- a click on a slot of the drive window, for a cursor stack and a main inventory
	drive_click = function(cursor, inventory, drive, slot, shift) return M.drive_click(cursor, inventory, drive, slot, shift) end,
	--- cables from members[1]'s network to every other member; returns cables placed, unreached members
	connect = function(members, margin) return M.connect(members, margin) end,
	--- what the sweep does with members removed without an event (now, for the whole map)
	sweep = function()
		local s = state()
		local units = {}
		for unit, node in pairs(s.nodes) do if not node.entity.valid then units[#units + 1] = unit end end
		table.sort(units)
		for _, unit in ipairs(units) do vanish(s, unit) end
		return #units
	end,
	version = function() return M.version() end,
	cable_variation = function(cable) return cable.graphics_variation end,
})

return M
