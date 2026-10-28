--------------------------------------------------------------------------------
--- FORK AE2: ME NETWORK CORE (issue #68, step R1; design: docs/ME-REWORK.md, prototypes/network.lua)
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
---   * ME Drive: 10 cell slots, a window (scripts/fork-me-windows.lua) and a light per slot (rendering).
---   * Partitions and priorities (R3, docs/AE2.md): a cell can be restricted to some keys (cell.partition,
---     kept in its tags), a drive has a priority (-1000 ... 1000). Insertion: drives of higher priority first;
---     within one priority the cells partitioned for the key, then the cells that hold it, then any cell
---     with room; a partitioned cell never takes other keys. Extraction: the reverse (lower priority first,
---     unpartitioned cells before partitioned ones). Priority and partitions are kept in blueprints
---     (tag fork_me_drive), settings paste and clones.
--- Keys: "name" (normal quality), "name@quality", and for items with tags "name@quality#<json of the tags>".
--- State: storage.fork_me_net (nodes, nets, drives).
--------------------------------------------------------------------------------

local G = require("scripts.fork-me-gui")        -- (a leaf: only its number format is used, for the cards' tooltip lines)

local M = {}
M.GF = require("scripts.fork-me-groupfilter")    -- issue #354: the Group Filter Card's text (a field: no main-chunk local)

--- functions(net) called when a network's members changed (autocrafting drops its pattern cache)
M.change_hooks = {}

--- Arrivals (issue #80): function(net, key, count) -> amount claimed, set by autocrafting. Every item or fluid that
--- comes into a network through the public insert functions (import bus, interface, terminal, fluid interface ...)
--- is offered to it first: a crafting job waiting for the outputs of a processing pattern takes them into its pool
--- (AE2 behaviour). What it claims counts as stored for the caller. `M.no_arrival` is set while autocrafting stores
--- its own pools (a job never takes back what a job stores). Plain normal quality keys only.
M.on_arrival = nil
M.no_arrival = false

local SWEEP_PER_STEP = 200          -- members checked for validity per slow step
local LEDS_PER_STEP_N = 50          -- drives whose lights are redrawn per slow step
local BASE_POWER = 120000           -- W: controller
local MEMBER_POWER = 4000           -- W: per member without its own power connection
local CELL_TAG = "fork_me_cell"
local DRIVE_TAG = "fork_me_drive"   -- blueprint tag of a drive: { priority, partitions = { ["slot"] = { keys } } }
--- issue #267: a cell's light is a hidden entity on the drive's (or chest's) position whose picture variation is its bay and
--- state (data-final-fixes.lua: (bay - 1) * 4 + LIGHT_STATE; issue #229: "off" is the dark light of a chest without
--- power); a graphics mod's cell (issue #264) the same, (bay - 1) * 2 + 1 for an item cell, + 2 for a fluid cell
local LIGHT_STATE = { room = 1, high = 2, full = 3, off = 4 }

--------------------------------------------------------------------------------
--- prototype data
--------------------------------------------------------------------------------

--- Reading `.data` of a mod-data prototype copies the whole table into Lua on every access, and the cell checks of
--- can_insert ask for a cell's spec once per cell. Prototype data cannot change while a game runs, so it is read once
--- per load into an upvalue (never into `storage`; every peer reads the same data, so this stays deterministic).
--- The table is shared: callers must not change it.
local md_cache
local function mod_data()
	if not md_cache then
		local md = prototypes.mod_data["fork-me-network"]
		md_cache = md and md.data or { cells = {}, legacy_drives = {}, drive_slots = 10, names = {} }
	end
	return md_cache
end

local names_cache, names_list
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
		if n.pattern_terminal then k[n.pattern_terminal] = "pattern-terminal" end      -- issue #130
		if n.pattern_terminal_ex then k[n.pattern_terminal_ex] = "pattern-terminal" end   -- issue #416: the Ex, the same kind
		if n.interface_terminal then k[n.interface_terminal] = "interface-terminal" end   -- issue #336
		for _, m in pairs({ "storage", "conversion", "throughput" }) do                     -- issue #353: the monitors
			if n[m .. "_monitor"] then k[n[m .. "_monitor"]] = m .. "-monitor" end
		end
		if n.toggle_bus then k[n.toggle_bus] = "toggle" end                             -- issue #355
		if n.inverted_toggle_bus then k[n.inverted_toggle_bus] = "toggle" end
		if n.level_emitter then k[n.level_emitter] = "level-emitter" end
		if n.advanced_level_emitter then k[n.advanced_level_emitter] = "level-emitter" end   -- issue #443: the same kind
		if n.underground then k[n.underground] = "underground" end
		if n.storage_bus then k[n.storage_bus] = "storage-bus" end
		if n.logistic_storage_bus then k[n.logistic_storage_bus] = "storage-bus" end   -- issue #506: a storage bus on a logistic network
		if n.access_point then k[n.access_point] = "access-point" end   -- issue #205
		if n.charger then k[n.charger] = "charger" end                -- issue #208
		if n.chest then k[n.chest] = "chest" end                      -- issue #229
		if n.io_port then k[n.io_port] = "io-port" end                -- issue #386
		if n.logistic_interface then k[n.logistic_interface] = "logistic-interface" end   -- issue #531
		if n.quantum_bridge then k[n.quantum_bridge] = "quantum-bridge" end   -- issue #385
		if n.wireless_link then k[n.wireless_link] = "wireless-link" end      -- issue #384
		if n.creative_energy then k[n.creative_energy] = "creative-energy" end   -- issue #442
	end
	k["me-pattern-provider"] = "provider"
	--- issue #560: the ME Molecular Assembler carries the network like a cable (AE2), and draws its power through the controller
	--- (M.assembler_power); another mod's (ME_NETWORK.make_molecular_assembler) has the same name
	k["me-molecular-assembler"] = "assembler"
	k["me-level-maintainer"] = "maintainer"
	k["me-circuit-interface"] = "circuit"
	k["me-fluid-interface"] = "fluid-interface"
	local ac = prototypes.mod_data["fork-me-autocraft"]
	--- issue #6: the blocks of the multiblock crafting CPUs (scripts/fork-me-autocraft.lua finds the CPUs among them)
	for name in pairs(ac and ac.data.blocks or {}) do k[name] = "crafting" end
	k["me-fluid-import-bus"] = "fluid-import-bus"
	k["me-fluid-export-bus"] = "fluid-export-bus"
	k["me-fluid-storage-bus"] = "fluid-storage-bus"
	for name in pairs(k) do
		if not prototypes.entity[name] then k[name] = nil end
	end
	names_cache = k
	return k
end

--- kinds with a power connection of their own (or none at all: the cable): the controller draws nothing for them. Issue #128:
--- the terminal and the level maintainer are not among them any more; issue #145: the legacy CPUs are gone
local POWERED_SELF = { cable = true, underground = true, controller = true, ["creative-energy"] = true,   -- (issue #442)
	["quantum-bridge"] = true, ["wireless-link"] = true }   -- (issues #385, #384: they draw from the power grid themselves)

--- Issue #128: the power (W) a kind draws through the controller where it is not the default (mod-data "fork-me-network",
--- member_power: terminal, level maintainer, pattern and interface terminal), read once per load like the rest of the mod-data
local kind_power_cache
local function kind_power(kind)
	if not kind_power_cache then kind_power_cache = mod_data().member_power or {} end
	return kind_power_cache[kind] or MEMBER_POWER
end

--- Issue #205: kinds whose power depends on their state (the access point's boosters, the charger while it charges): kind ->
--- function(entity) returning W. A change of that state calls M.power_changed(entity).
M.power_hooks = {}

--- issue #6: the power (W) of a crafting block drawn through the controller (mod-data "fork-me-autocraft", blocks)
local block_power_cache
local function member_power(node)
	if node.kind == "assembler" then return M.assembler_power(node) end   -- (issue #560: its draw is kept in its node)
	local hook = M.power_hooks[node.kind]
	if hook then return node.entity.valid and hook(node.entity) or MEMBER_POWER end
	if node.kind ~= "crafting" then return kind_power(node.kind) end
	if not block_power_cache then
		local ac = prototypes.mod_data["fork-me-autocraft"]
		block_power_cache = {}
		for name, b in pairs(ac and ac.data.blocks or {}) do block_power_cache[name] = b.power end
	end
	return node.entity.valid and block_power_cache[node.entity.name] or MEMBER_POWER
end

--- the entity names of all members, sorted (cached: the filter of every find_entities_filtered of the graph)
function M.node_names()
	if names_list then return names_list end
	local out = {}
	for name in pairs(kinds()) do out[#out + 1] = name end
	table.sort(out)
	names_list = out
	return out
end

function M.kind_of(name) return kinds()[name] end

local function cell_spec(name) return mod_data().cells[name] end
M.cell_spec = cell_spec
--- every storage cell's spec by item name (issue #37: the most kinds a cell of each kind takes)
function M.cell_specs() return mod_data().cells end

--- issue #17: the card slots and limits of the blocks (prototypes/cards.lua, AE2's numbers) and what a card item does
--- ("capacity", "void", "fuzzy", "inverter", "equal"; nil: no card)
function M.card_rules() return mod_data().cards end
function M.card_kind(name) return name and mod_data().cards.kinds[name] or nil end

local function drive_slots() return mod_data().drive_slots or 10 end

--- issue #229: the kinds that hold storage cells, the ME Drive (drive_slots) and the ME Chest (one): both keep a drive record
--- (s.drives) whose cells are network storage at its priority, cell id "<unit>:<slot>"
local CELL_KINDS = { drive = true, chest = true }
M.CELL_KINDS = CELL_KINDS
local function slots_of(entity) return kinds()[entity.name] == "chest" and 1 or drive_slots() end
M.slots_of = slots_of

--------------------------------------------------------------------------------
--- state
--------------------------------------------------------------------------------

--- the render layer of the screens of terminals and level maintainers (issue #258, see "screens")
local SCREEN_LAYER = "lower-object-above-shadow"

local function state()
	local s = storage.fork_me_net
	if not s then
		s = {
			nodes = {},       -- unit -> { x1, y1, x2, y2 (its tile box), entity, kind, net, adj = { unit -> true }, surface, force }
			nets = {},        -- id -> network (see new_net)
			next_net = 1,
			version = 0,      -- counts graph changes
			drives = {},      -- unit -> { entity, slots = { [i] = cell }, surface, force, position, leds, dirty }
			dirty = {},       -- drive unit -> true: lights to redraw
			sweep = 1,
			nlist = {},       -- the units of the members, in the order they joined (a member that leaves is replaced by the last): the sweep
			                  -- walks it (issue #43); each node keeps its place in `li`. Saves before it get it at their first sweep.
			ext = {},         -- unit -> external cell of a member (storage bus, scripts/fork-me-storagebus.lua)
			--- the screens of terminals and level maintainers (see "screens"), made when they join (issue #254: a new map has
			--- them from the start, so a big scene is not drawn at once at its first slow step)
			screens = {}, screen_list = {}, maintainer_screens = true, screen_layer = SCREEN_LAYER,
			light_parts = true,   -- issue #267: the drives' lights are entities (a save from before redraws them once)
		}
		storage.fork_me_net = s
	end
	if not s.ext then s.ext = {} end          -- saves before the storage bus
	if not s.asm then                         -- issue #560: the units of the ME Molecular Assemblers (M.assembler_step)
		s.asm = {}
		for unit, node in pairs(s.nodes) do if node.kind == "assembler" then s.asm[unit] = true end end
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
--- Issue #420: a node is its own tile box (fields 1 to 4: left, top, right, bottom, the node's array part), not a table of
--- its own, and keeps no position (nothing read it): two tables less per member (about 250 bytes; at 20 000 endpoints and
--- their 80 000 members some 20 MB of the heap). The nodes of older saves are made anew by M.rebuild (they have no
--- s.graph_sig).
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

--- side of `ob` that `b` touches: 1 N, 2 E, 4 S, 8 W (0: none)
local function side_of(b, ob)
	if ob[4] == b[2] then return 1
	elseif ob[1] == b[3] then return 2
	elseif ob[2] == b[4] then return 4
	elseif ob[3] == b[1] then return 8 end
	return 0
end

--- Underground cable: like the vanilla underground pipe, above ground it connects only on the side its direction
--- points to, under ground on the opposite side to its partner (see engine_partner). (Before 0.5.11 it was the other way
--- round; M.migrate_underground_direction turns the ends of older saves.)
local DIR_BIT = { [defines.direction.north] = 1, [defines.direction.east] = 2, [defines.direction.south] = 4, [defines.direction.west] = 8 }
local DIR_VEC = { [defines.direction.north] = { 0, -1 }, [defines.direction.east] = { 1, 0 },
	[defines.direction.south] = { 0, 1 }, [defines.direction.west] = { -1, 0 } }

--- may `a` and `b` (adjacent boxes) connect above ground?
local function connects(a, b)
	if a.kind == "underground" and side_of(a, b) ~= DIR_BIT[a.dir] then return false end
	if b.kind == "underground" and side_of(b, a) ~= DIR_BIT[b.dir] then return false end
	return true
end

--- render objects of an older version (a dashed line between paired ends): destroyed when the graph is rebuilt
local function clear_link(node)
	local id = node and node.link
	if not id then return end
	local obj = type(id) == "number" and rendering.get_object_by_id(id)
	if obj and obj.valid then obj.destroy() end
	node.link = nil
end

--- The underground cable is a pipe-to-ground with its own connection category (prototypes/network.lua), so the
--- engine pairs the ends exactly like underground pipes and shows the pairing on hover and while placing. The graph
--- follows the engine: the partner is the end the underground pipe connection reaches (behind the direction).
local function engine_partner(entity, dir)
	local v = DIR_VEC[dir]
	if not (v and entity.fluids_count > 0) then return nil end
	for _, other in pairs(entity.get_fluid_box_neighbours(1)) do       -- (issue #487: records { entity, index } since 2.1)
		local o = other.entity
		if o and o.valid and o ~= entity and o.name == entity.name then
			local dx, dy = o.position.x - entity.position.x, o.position.y - entity.position.y
			if dx * v[1] + dy * v[2] < 0 then return o end
		end
	end
	return nil
end

--- the node of the engine's partner (nil if it is no member yet)
local function find_partner(s, node)
	local pe = engine_partner(node.entity, node.dir)
	local o = pe and s.nodes[pe.unit_number]
	if o and o.entity == pe then return o end
	return nil
end

--- pair two underground nodes (graph edge)
local function link_pair(a, b)
	local au, bu = a.entity.unit_number, b.entity.unit_number
	a.partner, b.partner = bu, au
	a.adj[bu] = true
	b.adj[au] = true
end

--- cable picture: 1 + N + 2E + 4S + 8W
local function update_cable(s, node)
	if node.kind ~= "cable" or not node.entity.valid then return end
	local b, mask = node, 0
	for unit in pairs(node.adj) do
		local o = s.nodes[unit]
		if o then
			local ob = o
			if ob[4] == b[2] then mask = mask + 1
			elseif ob[1] == b[3] then mask = mask + 2
			elseif ob[2] == b[4] then mask = mask + 4
			elseif ob[3] == b[1] then mask = mask + 8 end
		end
	end
	node.entity.graphics_variation = mask + 1
end

local recompute
local net_cell
--- issue #229: the ME Chest (its section below the drives)
local CH = {}
local take_waits, fire_all_waits
local screen_made, screen_gone, has_screen

--- The parts a removal left (issue #38, lever 5). `starts`: the neighbours of the removed member, in order; `total`: the
--- members the network has left. A search runs from each of them, one member at a time, in turns; two searches that meet
--- are one group; a search that runs dry has found a whole part. The search still running when every other one has run
--- dry is the rest of the network and is not walked to its end (its size is `total` less the parts found), so the cost is
--- the size of the smaller parts, not of the network (the search of the whole network that every removed cable made
--- cost 1.8 ms at 20 000 members, 364 times in a burst). The largest part keeps the network and its id (a tie: the one
--- with the smaller first neighbour), as before: only when a part that ran dry is larger than the rest is the rest
--- walked to its end, which then costs less than that part did.
--- Returns the parts that do not keep the network, each a list of units, the larger first (empty: no split).
local function split_parts(s, starts, total)
	local nodes = s.nodes
	local owner = {}                                  -- unit -> the search that found it (root() gives its group)
	local up = {}                                     -- search -> the search it was merged into
	local searches = {}
	local function root(i)
		while up[i] ~= i do
			up[i] = up[up[i]]
			i = up[i]
		end
		return i
	end
	for i, start in ipairs(starts) do
		searches[i] = { queue = { start }, head = 1, list = { start }, dry = false, first = i }
		up[i] = i
		owner[start] = i
	end
	local live = #starts                              -- groups that have not run dry
	local groups = #starts                            -- groups, dry or not
	--- one member of group `i` is searched
	local function step(i)
		local g = searches[i]
		local u = g.queue[g.head]
		g.head = g.head + 1
		for v in pairs(nodes[u].adj) do
			if nodes[v] then
				local o = owner[v]
				if o == nil then
					owner[v] = i
					g.queue[#g.queue + 1] = v
					g.list[#g.list + 1] = v
				else
					local r = root(o)
					if r ~= i then                    -- the two searches met: one group
						local other = searches[r]
						for k = other.head, #other.queue do g.queue[#g.queue + 1] = other.queue[k] end
						for k = 1, #other.list do g.list[#g.list + 1] = other.list[k] end
						if other.first < g.first then g.first = other.first end
						if not other.dry then live = live - 1 end
						groups = groups - 1
						up[r] = i
						searches[r] = nil
					end
				end
			end
		end
		if g.head > #g.queue then
			g.dry = true
			live = live - 1
		end
	end
	while live > 1 do
		for i = 1, #starts do
			if up[i] == i and not searches[i].dry then
				step(i)
				if live <= 1 then break end
			end
		end
	end
	if groups <= 1 then return {} end
	--- the groups that are left, the one still searching (if any) with the size that is left of the network
	local list, found, rest = {}, 0, nil
	for i = 1, #starts do
		if up[i] == i then
			local g = searches[i]
			if g.dry then
				list[#list + 1] = { i = i, size = #g.list, first = g.first, dry = true }
				found = found + #g.list
			else
				rest = { i = i, size = 0, first = g.first, dry = false }
				list[#list + 1] = rest
			end
		end
	end
	if rest then rest.size = total - found end
	table.sort(list, function(a, b)
		if a.size ~= b.size then return a.size > b.size end
		return a.first < b.first
	end)
	local out = {}
	for k = 2, #list do
		local e = list[k]
		if not e.dry then                              -- the rest is not the largest: walk it to its end (it is smaller than the part that keeps the network)
			while not searches[e.i].dry do step(e.i) end
		end
		out[#out + 1] = searches[e.i].list
	end
	return out
end

--- Issue #442: the kinds whose joining or leaving changes a network's status and power: the controller and the Creative Energy
--- Cell (recompute counts them)
M.STATUS_KINDS = { controller = true, ["creative-energy"] = true }
M.NONE = {}                                           -- (an empty table to walk; never written)

local function changed(s, net)
	s.version = s.version + 1
	recompute(s, net)
	for _, hook in pairs(M.change_hooks) do hook(net) end
	if net.wait_use then M.usable(net) end          -- (issue #38: blocks parked for want of a working network wake now, if it works)
end

local remove_node_graph

--- Register a built member. Returns its node.
local function add_node(s, entity, kind)
	local unit = entity.unit_number
	local node = s.nodes[unit]
	if node then return node end
	if kind == "underground" then
		--- the engine pairs a new end with the nearest one facing it; that end's old partner loses it
		local pe = engine_partner(entity, entity.direction)
		local pn = pe and s.nodes[pe.unit_number]
		local old = pn and pn.partner and pn.partner ~= unit and s.nodes[pn.partner]
		if old then
			pn.partner, old.partner = nil, nil
			remove_node_graph(s, old.entity.unit_number)
			if old.entity.valid then add_node(s, old.entity, old.kind) end
		end
	end
	local tb = tile_box(entity)
	node = { tb[1], tb[2], tb[3], tb[4], entity = entity, kind = kind, adj = {}, surface = entity.surface.index,
		force = entity.force.name }
	if kind == "underground" then node.dir = entity.direction end
	s.nodes[unit] = node
	if kind == "assembler" then s.asm[unit] = true end      -- (issue #560)
	local nl = s.nlist
	if nl then
		nl[#nl + 1] = unit
		node.li = #nl
	end
	local b = node
	local found = entity.surface.find_entities_filtered{
		area = { { b[1] - 0.5, b[2] - 0.5 }, { b[3] + 0.5, b[4] + 0.5 } }, name = M.node_names(), force = entity.force }
	local nets, order = {}, {}
	for _, e in pairs(found) do
		local other = e.valid and e.unit_number ~= unit and s.nodes[e.unit_number]
		if other and other.entity == e and adjacent(b, other) and connects(node, other) then
			node.adj[e.unit_number] = true
			other.adj[unit] = true
			if not nets[other.net] then
				nets[other.net] = true
				order[#order + 1] = other.net
			end
		end
	end
	if kind == "underground" then
		local partner = find_partner(s, node)
		if partner and not partner.partner then
			link_pair(node, partner)
			if not nets[partner.net] then
				nets[partner.net] = true
				order[#order + 1] = partner.net
			end
		end
	end
	--- issue #385: a linked ME Quantum Bridge has its partner (any distance, any surface) as a neighbour
	local qu = s.qlink and s.qlink[unit]
	local qn = qu and s.nodes[qu]
	if qn and qn.entity.valid then
		node.adj[qu] = true
		qn.adj[unit] = true
		if not nets[qn.net] then
			nets[qn.net] = true
			order[#order + 1] = qn.net
		end
	end
	--- issue #559: an ME Wireless Link has the links of its group it is linked to as neighbours (M.set_wlinks)
	for wu in pairs(s.wlinks and s.wlinks[unit] or M.NONE) do
		local wn = s.nodes[wu]
		if wn and wn.entity.valid then
			node.adj[wu] = true
			wn.adj[unit] = true
			if not nets[wn.net] then
				nets[wn.net] = true
				order[#order + 1] = wn.net
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
			take_waits(net, other)                 -- (issue #38: its parked endpoints keep their wake)
			s.nets[other.id] = nil
		end
	end
	net.nodes[unit] = true
	net.n = net.n + 1
	node.net = net.id
	if has_screen(kind) then screen_made(s, unit, entity, kind) end
	update_cable(s, node)
	for u in pairs(node.adj) do update_cable(s, s.nodes[u]) end
	if #order == 1 and not M.STATUS_KINDS[kind] then                  -- (issue #442: the creative energy cell too)
		--- issue #5: a member that joins one network changes no totals of it, except a drive (its cells) and a storage
		--- bus already registered (its external cell): no recompute, no rescan of every provider
		s.version = s.version + 1
		M.power_add(s, net, node, 1)                         -- (issue #420: not the walk over every member)
		if CELL_KINDS[kind] then
			net.drives[unit] = true
			local d = s.drives[unit]
			for slot = 1, drive_slots() do
				local cell = d and d.slots[slot]
				local cid = unit .. ":" .. slot
				if cell and not net.cells[cid] then net_cell(net, cid, cell, 1) end
			end
		end
		local cell = s.ext and s.ext[unit]
		if cell and not net.cells[unit .. ":ext"] then net_cell(net, unit .. ":ext", cell, 1) end
	else
		changed(s, net)
	end
	return node
end

--- the cells of a drive or a storage bus leave the index and the totals of `net` (the member was removed or went with a part
--- that split off); the cells themselves stay with their drive or bus
local function release_cells(net, unit)
	net.drives[unit] = nil
	for slot = 1, drive_slots() do
		local cid = unit .. ":" .. slot
		if net.cells[cid] then net_cell(net, cid, net.cells[cid], -1) end
	end
	if net.cells[unit .. ":ext"] then net_cell(net, unit .. ":ext", net.cells[unit .. ":ext"], -1) end
end

--- Unregister a member from the graph (the entity may already be invalid).
function remove_node_graph(s, unit)
	local node = s.nodes[unit]
	if not node then return end
	s.nodes[unit] = nil
	if has_screen(node.kind) then screen_gone(s, unit) end
	local nl, li = s.nlist, node.li
	if nl and li and nl[li] == unit then                -- the last member takes its place in the sweep list
		local last = #nl
		local moved = nl[last]
		nl[li] = moved
		nl[last] = nil
		local mn = s.nodes[moved]
		if mn then mn.li = li end
	end
	local net = s.nets[node.net]
	if net and net.wunits then net.wunits[unit] = nil end
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
	--- a member with one neighbour (a bus, an interface, a drive at the end of a cable) cannot split the network
	local parts = #neighbours <= 1 and {} or split_parts(s, neighbours, net.n)
	if #parts == 0 then
		if M.STATUS_KINDS[node.kind] then                   -- (issue #442: the creative energy cell too)
			changed(s, net)
		else
			--- issue #5: no recompute; whatever storage the member still had in the network leaves it
			s.version = s.version + 1
			M.power_add(s, net, node, -1)                    -- (issue #420: not the walk over every member)
			release_cells(net, unit)
		end
		return
	end
	--- the rest keeps the network (and its id, the largest part); every other part becomes a new network
	local moved
	--- (light: no controller leaves; the drives and storage buses that leave, the member removed among them, take their cells out
	--- of the rest's index one by one instead of the rest being computed again)
	local light = not M.STATUS_KINDS[node.kind]
	local leaving = { unit }
	for i = 1, #parts do
		local part = new_net(s, net.surface, net.force)
		for _, u in ipairs(parts[i]) do
			net.nodes[u] = nil
			net.n = net.n - 1
			part.nodes[u] = true
			part.n = part.n + 1
			local pnode = s.nodes[u]
			pnode.net = part.id
			if M.STATUS_KINDS[pnode.kind] then light = false end
			if CELL_KINDS[pnode.kind] or (s.ext and s.ext[u]) then leaving[#leaving + 1] = u end
			local kind = net.wunits and net.wunits[u]
			if kind then                               -- (issue #38: a waiting endpoint that moved registers again on its new network)
				net.wunits[u] = nil
				moved = moved or {}
				moved[#moved + 1] = { u, kind }
			end
		end
		changed(s, part)
	end
	if light then
		--- issue #5 / #43: no controller went with the parts: no recompute of the rest (it rebuilt every cell's index: 35 to 50 ms
		--- at 20 000 members), the cells of what left are taken out, and the rest is told what a change of the members means
		for _, u in ipairs(leaving) do release_cells(net, u) end
		s.version = s.version + 1
		net.power_dirty = true
		net.usable_tick = nil
		for _, hook in pairs(M.change_hooks) do hook(net) end
		if net.wait_use then M.usable(net) end
	else
		changed(s, net)
	end
	if moved then
		table.sort(moved, function(a, b) return a[1] < b[1] end)
		for _, m in ipairs(moved) do
			local f = M.wakers[m[2]]
			if f then f(m[1]) end
		end
	end
end

--- Unregister a member (the entity may already be invalid). The drive's cells are handled by the caller. The
--- partner of an underground cable is registered again, so it can pair with another one in reach.
local function remove_node(s, unit)
	local node = s.nodes[unit]
	local pu = node and node.partner
	clear_link(node)
	local qu = s.qlink and s.qlink[unit]                 -- (issue #385: a removed quantum bridge's link is gone)
	if qu then
		s.qlink[unit] = nil
		if s.qlink[qu] == unit then s.qlink[qu] = nil end
	end
	M.drop_wlinks(s, unit)                               -- (issue #559: so are a removed wireless link's)
	if pu and s.nodes[pu] then
		s.nodes[pu].partner = nil
		s.nodes[pu].link = nil
	end
	remove_node_graph(s, unit)
	local p = pu and s.nodes[pu]
	if p and p.entity.valid then
		remove_node_graph(s, pu)
		add_node(s, p.entity, p.kind)
		--- the removed end still exists during the removal event; the engine may pair the partner with an end
		--- further away once it is gone: checked in the next slow step
		s.ug_dirty = s.ug_dirty or {}
		s.ug_dirty[pu] = true
	end
end

--- Issue: dragging the underground cable (0.5.11). Its prototype took the vanilla underground pipe's connections (the
--- cable side on its direction, the underground side opposite), so the game's own underground drag places the pairs at
--- the full reach. Every underground cable (and ghost) of a save from before is turned around once, which keeps its
--- connections, and its node's direction follows (a kept graph is taken over as it is). Blueprints keep their old
--- directions. Runs before the graph is built (on_init after the hand-over, on_configuration_changed before the rebuild).
--- `only` (tests): { surface, area } turns the ends there, whatever the flag says.
function M.migrate_underground_direction(only)
	if not only then
		if storage.fork_me_ug_vanilla then return end
		storage.fork_me_ug_vanilla = true
	end
	local name = mod_data().names.underground
	local s = storage.fork_me_net
	local turned = 0
	for _, surface in pairs(only and { only.surface } or game.surfaces) do
		local area = only and only.area
		for _, e in pairs(surface.find_entities_filtered{ name = name, area = area }) do
			e.direction = (e.direction + 8) % 16
			local node = s and s.nodes and s.nodes[e.unit_number]
			if node and node.kind == "underground" then node.dir = e.direction end
			turned = turned + 1
		end
		for _, g in pairs(surface.find_entities_filtered{ ghost_name = name, area = area }) do
			g.direction = (g.direction + 8) % 16
			turned = turned + 1
		end
	end
	if turned > 0 then log("ME-UNDERGROUND-DIRECTION: turned " .. turned .. " underground cables around") end
	return turned
end

--- A rotated underground cable changes its connections: register it again (its old partner too).
function M.on_rotated(entity)
	local s = storage.fork_me_net
	local node = s and entity and entity.valid and entity.unit_number and s.nodes[entity.unit_number]
	if not (node and node.kind == "underground" and node.dir ~= entity.direction) then return end
	remove_node(s, entity.unit_number)
	add_node(s, entity, "underground")
end

--------------------------------------------------------------------------------
--- cells and network storage
--------------------------------------------------------------------------------

local FLUID_PREFIX = "fluid/"       -- keys of fluids: "fluid/<name>" (the resource keys of autocrafting)
local ZERO = 1e-6                   -- fluid amounts are fixed point: below this an amount counts as nothing

local FLUID_FIRST = FLUID_PREFIX:byte(1)
local function is_fluid_key(key) return key:byte(1) == FLUID_FIRST and key:sub(1, #FLUID_PREFIX) == FLUID_PREFIX end   -- (no substring for the usual item)
local function fluid_cell(spec) return spec.kind == "fluid" end
M.is_fluid_key = is_fluid_key
M.FLUID_PREFIX = FLUID_PREFIX

--- Issue #159: fluids keep their temperature. The storage key of a fluid at its default temperature is "fluid/<name>"
--- (the key of every save before), at any other temperature "fluid/<name>@<degrees>": the temperature clamped to the
--- fluid's [default_temperature, max_temperature] as the engine does, rounded to whole degrees (249.6 and 250.2 are
--- one type). A filter key may also name the default temperature ("fluid/<name>@<default>": that temperature only); a
--- filter without a temperature takes every temperature of the fluid (fluid_matches, listed). Everything here is
--- derived from the prototypes and kept per load, never in `storage`.
local fluid_parts = {}               -- key -> { name, degrees or false }
local function split_fluid_key(key)
	local p = fluid_parts[key]
	if p == nil then
		local body = key:sub(#FLUID_PREFIX + 1)
		local name, deg = body:match("^(.+)@(%-?%d+)$")
		if name and prototypes.fluid[name] then p = { name, tonumber(deg) } else p = { body, false } end
		fluid_parts[key] = p
	end
	return p[1], p[2] or nil
end
M.split_fluid_key = split_fluid_key

--- { default temperature, max temperature, default in whole degrees } of a fluid, nil for no fluid
local fluid_temps = {}
local function temps_of(name)
	local t = fluid_temps[name]
	if t == nil then
		local p = prototypes.fluid[name]
		if p then
			local d = p.default_temperature
			t = { d, math.max(d, p.max_temperature or d), math.floor(d + 0.5) }
		else
			t = false
		end
		fluid_temps[name] = t
	end
	return t or nil
end

--- the default and the max temperature of a fluid (nil for no fluid; per load)
--- Issue #487: the chance that a craft makes product `p` (a recipe prototype's product). Since Factorio 2.1 a product has
--- `independent_probability` and `shared_probability` { min, max } (one roll per craft for all products; the product is made
--- when it falls between them); a product kept from a 2.0 save has `probability`
function M.chance(p)
	local sp = p.shared_probability
	return (p.independent_probability or p.probability or 1) * (sp and (sp.max - sp.min) or 1)
end

--- Issue #487: does a machine with the crafting categories `machine_cats` (a set) make a recipe of the categories `cats` (a
--- list: Factorio 2.1's LuaRecipePrototype::categories; a recipe may have several)?
function M.makes(machine_cats, cats)
	for _, c in pairs(cats or {}) do
		if machine_cats[c] then return true end
	end
	return false
end

function M.fluid_range(name)
	local t = temps_of(name)
	if not t then return nil end
	return t[1], t[2]
end

--- a temperature as whole degrees within the fluid's range (nil without the fluid or a temperature)
local function clamp_degrees(name, temperature)
	local t = temperature and temps_of(name)
	if not t then return nil end
	if temperature < t[1] then temperature = t[1] elseif temperature > t[2] then temperature = t[2] end
	return math.floor(temperature + 0.5)
end

local fluid_key_cache = {}           -- name -> { [degrees] = key, [""] = default key }
--- the storage key of `name` at `temperature` (nil: the default temperature)
local function fluid_key(name, temperature)
	local c = fluid_key_cache[name]
	if not c then
		c = { [""] = FLUID_PREFIX .. name }
		fluid_key_cache[name] = c
	end
	local d = clamp_degrees(name, temperature)
	if d == nil or d == fluid_temps[name][3] then return c[""] end
	local key = c[d]
	if not key then
		key = FLUID_PREFIX .. name .. "@" .. d
		c[d] = key
	end
	return key
end
M.fluid_key = fluid_key

--- the filter key of `name` at `temperature`: without one every temperature, with one only that one (also the default)
local filter_key_cache = {}          -- name -> { [degrees] = filter key } (the key without a temperature: fluid_key_cache)
function M.fluid_filter_key(name, temperature)
	local d = clamp_degrees(name, temperature)
	if d == nil then return fluid_key(name) end
	local c = filter_key_cache[name]
	if not c then
		c = {}
		filter_key_cache[name] = c
	end
	local key = c[d]
	if not key then
		key = FLUID_PREFIX .. name .. "@" .. d
		c[d] = key
	end
	return key
end

--- a fluid filter key checked against the prototypes and written as fluid_filter_key writes it; nil for no fluid
function M.clean_fluid_filter(key)
	if type(key) ~= "string" or not is_fluid_key(key) then return nil end
	local name, deg = split_fluid_key(key)
	if not prototypes.fluid[name] then return nil end
	return M.fluid_filter_key(name, deg)
end

--- the fluid name of a fluid key (storage or filter key), nil for no fluid key
function M.fluid_name(key)
	if not is_fluid_key(key) then return nil end
	return (split_fluid_key(key))
end

--- the temperature the fluid of a storage key has: its degrees, or the fluid's default temperature
function M.fluid_temperature(key)
	local name, deg = split_fluid_key(key)
	if deg then return deg end
	local t = temps_of(name)
	return t and t[1] or 15
end

--- the storage key a filter key names exactly (a filter without a temperature: the default key)
function M.fluid_storage_key(key)
	local name, deg = split_fluid_key(key)
	return fluid_key(name, deg)
end

--- does the fluid filter `filter` take the storage key `key`? (another fluid: no; no temperature: every temperature)
local function fluid_matches(filter, key)
	if filter == key then return true end
	local fname, fdeg = split_fluid_key(filter)
	local kname = split_fluid_key(key)
	if fname ~= kname then return false end
	if not fdeg then return true end
	return fluid_key(fname, fdeg) == key
end
M.fluid_matches = fluid_matches

--- The other filter key that takes a storage key (`listed`, the partition lookups): for "fluid/<name>@<degrees>" the
--- filter of every temperature "fluid/<name>", for the default key "fluid/<name>@<default>"; false for items
local alt_keys = {}
local function alt_key(key)
	local a = alt_keys[key]
	if a == nil then
		a = false
		if is_fluid_key(key) then
			local name, deg = split_fluid_key(key)
			local t = temps_of(name)
			if deg then a = FLUID_PREFIX .. name
			elseif t then a = FLUID_PREFIX .. name .. "@" .. t[3] end
		end
		alt_keys[key] = a
	end
	return a
end

local function type_bytes(spec, count)
	return spec.per_type + math.ceil(count / (spec.per_byte or 8) - ZERO)
end

--- the item name of an item key (nil for a fluid key), remembered per key
local key_names = {}
local function name_of_key(key)
	local n = key_names[key]
	if n == nil then
		n = not is_fluid_key(key) and (parse_key(key)) or false
		key_names[key] = n
	end
	return n or nil
end

--- is `key` in a filter list? `set`: exact keys; `fnames`: the item names of the list with a Fuzzy Card (issue #17:
--- any quality)
local function listed(set, fnames, key)
	if set[key] then return true end
	local alt = alt_key(key)                      -- issue #159: a fluid filter of every temperature, or of the default
	if alt and set[alt] then return true end
	if fnames then
		local n = name_of_key(key)
		return n ~= nil and fnames[n] == true
	end
	return false
end

--- is the storage key `key` in the filter set `set` ({ key -> true }; issue #159: a fluid filter of every temperature)?
function M.listed(set, key) return listed(set, nil, key) end

--- Does the filter of a cell (a drive cell or a storage bus) let `key` in? `partition` is a whitelist (R3), `deny` a
--- blacklist (issue #17, an Inverter Card), `fnames` makes either match every quality (a Fuzzy Card).
local function accepts(cell, key)
	local gf = cell.gf                                        -- issue #354: a Group Filter Card's text replaces the list
	if gf then
		if cell.ginv then return not M.GF.match(gf, key) end
		return M.GF.match(gf, key)
	end
	local p = cell.partition
	if p and next(p) then return listed(p, cell.fnames, key) end
	local d = cell.deny
	if d then return not listed(d, cell.fnames, key) end
	return true
end
M.accepts = accepts

--- items (fluid units) of `key` the cell can still take; item cells take items, fluid cells fluids
local function cell_room(cell, spec, key)
	if fluid_cell(spec) ~= is_fluid_key(key) or spec.creative then return 0 end   -- (issue #441: a creative cell only voids)
	local p = cell.partition                                  -- partitioned (R3); a fuzzy list or a blacklist (#17)
	if cell.gf then                                           -- a group filter (issue #354)
		if not accepts(cell, key) then return 0 end
	elseif p then
		if next(p) and not listed(p, cell.fnames, key) then return 0 end
	elseif cell.deny and not accepts(cell, key) then
		return 0
	end
	local per = spec.per_byte or 8
	local free = spec.bytes - cell.bytes
	local have = cell.items[key]
	local room
	if have then
		room = math.max(0, math.ceil(have / per - ZERO) * per - have) + math.max(0, free) * per
	else
		if cell.types >= spec.types then return 0 end
		free = free - spec.per_type
		if free <= 0 then return 0 end
		room = free * per
	end
	--- issue #17, an Equal Distribution Card: no key holds more than AE2's share of the cell (cell.eq)
	if cell.eq then room = math.min(room, math.max(0, cell.eq - (have or 0))) end
	return room
end

--- change the count of `key` in a cell by `delta`; returns the change of bytes and types
local function cell_add(cell, spec, key, delta)
	local have = cell.items[key] or 0
	local now = have + delta
	if now < ZERO then now = 0 end
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

--- Issue #115: is there an item of this name (of this key's name)? Per load: `prototypes.item[name]` makes a new object at
--- every call. The key cache is bounded (keys of items with tags are many).
local item_known, key_known, key_known_n = {}, {}, 0
local function item_exists(name)
	local v = item_known[name]
	if v == nil then
		v = prototypes.item[name] ~= nil
		item_known[name] = v
	end
	return v
end
local function key_item_exists(key)
	local v = key_known[key]
	if v == nil then
		if key_known_n >= 4096 then key_known, key_known_n = {}, 0 end
		v = item_exists((parse_key(key)))
		key_known[key], key_known_n = v, key_known_n + 1
	end
	return v
end
M.item_exists = item_exists
M.key_item_exists = key_item_exists

--- Issue #3: items that were replaced by another one (the old fluid blocks -> the unified blocks; mod-data
--- "fork-me-fluids", unified.items). Keys of such items are read as the key of the new item wherever stored keys
--- come back (cell tags, partitions, patterns, level maintainers, circuit filters).
--- Issue #503: items another mod removed or renamed (ME_NETWORK.replace_item, mod-data "fork-me-network", replaced_items)
--- are read as their replacement only while the old item no longer exists: a mod's JSON migration may rename an item it
--- keeps (Gregtorio's small lamp), and what the network stores of it keeps its name. A chain (a -> b in one update, b -> c
--- in a later one) is followed to its first item that exists.
local alias_map                       -- { unified = { old -> new }, replaced = { old -> new } } (a table: the main chunk's locals are few)
function M.alias(name)
	if not alias_map then
		local md = prototypes.mod_data["fork-me-fluids"]
		alias_map = { unified = md and md.data.unified and md.data.unified.items or {}, replaced = mod_data().replaced_items or {} }
	end
	local new = alias_map.unified[name]
	local replaced = alias_map.replaced
	if new or not replaced[name] or item_exists(name) then return new end
	new = replaced[name]
	for _ = 1, 8 do
		if item_exists(new) or not replaced[new] then break end
		new = replaced[new]
	end
	return new
end

--- the key of the replacing item for a key of a replaced one (items with tags keep their key; issue #503: unless their item
--- is gone, then they keep their quality and tags under the replacing item)
local function alias_key(key)
	if type(key) ~= "string" or is_fluid_key(key) then return key end
	local tagged = key:find("#", 1, true)
	if tagged and key_item_exists(key) then return key end
	local name, q, json = parse_key(key)
	local new = M.alias(name)
	return new and key_of(new, q, json) or key
end
M.alias_key = alias_key

--- the cell's contents as a fresh record (from the tags of a cell item); unknown items are dropped
local function cell_from_tags(name, tags)
	local cell = new_cell(name)
	local spec = cell_spec(name) or M.view_spec(name)        -- (issue #440: a view cell's list and cards, no contents)
	local stored = type(tags) == "table" and tags[CELL_TAG] or nil
	if type(stored) ~= "table" or not spec then
		if spec and spec.void then M.apply_cell_cards(cell) end   -- (issue #354: a new void cell)
		return cell
	end
	local keys = {}
	local counts, data = {}, {}
	for key, count in pairs(stored.items or {}) do
		if type(key) == "string" and type(count) == "number" and count > 0 then
			local k = alias_key(key)                      -- a replaced item counts as its replacement (issue #3)
			if not counts[k] then keys[#keys + 1] = k end
			counts[k] = (counts[k] or 0) + count
			if stored.data and stored.data[key] then data[k] = stored.data[key] end
		end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		if is_fluid_key(key) then
			if fluid_cell(spec) and prototypes.fluid[(split_fluid_key(key))] then cell_add(cell, spec, key, counts[key]) end
		elseif not fluid_cell(spec) and not spec.creative and prototypes.item[(parse_key(key))] then   -- (#441: below)
			cell_add(cell, spec, key, math.floor(counts[key]))
			local d = data[key]
			if type(d) == "table" then cell.data[key] = d end
		end
	end
	cell.partition = M.clean_partition(spec, stored.partition)
	cell.gtext = M.GF.clean(stored.gtext)                       -- issue #354: the Group Filter Card's text
	cell.cards = M.clean_cards(spec, stored.cards)              -- issue #17: the cell's upgrade cards
	if cell.cards or spec.void then M.apply_cell_cards(cell) end      -- (issue #354: a void cell's `void` comes from its spec)
	--- issue #441: a creative cell holds M.CREATIVE of every key its partition lists (no bytes: nothing is written into it)
	if spec.creative then
		for key in pairs(cell.partition or {}) do cell.items[key] = M.CREATIVE end
	end
	return cell
end
M.cell_from_tags = cell_from_tags

--- the cell record of a cell item stack (its contents, partition and cards from the tags). Issue #394: the item's quality
--- goes with it (`cell.quality`, nil for normal; a drive's record keeps it), so the stack written back keeps it. It changes
--- nothing in the cell: bytes, types and cards are the same in every quality.
--- Issue #440: the spec of a view cell (mod-data `view_cells`: { view = true, types }), nil for anything else. Kept apart from
--- `cells` (cell_spec): a view cell is partitioned like a cell but stores nothing, so no drive or chest takes it.
function M.view_spec(name)
	local v = mod_data().view_cells
	return v and v[name] or nil
end

function M.cell_from_stack(stack)
	local cell = cell_from_tags(stack.name, stack.is_item_with_tags and stack.tags or nil)
	local q = stack.quality.name
	if q ~= "normal" then cell.quality = q end
	return cell
end

--- A partition ({ key -> true } or a list of keys) checked against the cell's kind and the prototypes; nil
--- when empty. At most the cell's number of types.
function M.clean_partition(spec, partition)
	if type(partition) ~= "table" or not spec then return nil end
	local keys = {}
	for k, v in pairs(partition) do
		local key = type(k) == "string" and v == true and k or (type(v) == "string" and v or nil)
		if key then keys[#keys + 1] = is_fluid_key(key) and M.clean_fluid_filter(key) or alias_key(key) end
	end
	table.sort(keys)
	local out, n = {}, 0
	for _, key in ipairs(keys) do
		local ok
		if is_fluid_key(key) then ok = (fluid_cell(spec) or spec.view) and prototypes.fluid[(split_fluid_key(key))] ~= nil   -- (#440)
		else ok = not fluid_cell(spec) and not key:find("#") and prototypes.item[(parse_key(key))] ~= nil end
		if ok and not out[key] and n < spec.types then
			out[key] = true
			n = n + 1
		end
	end
	return n > 0 and out or nil
end

--- Issue #17: a list of card names checked against the cell: cards of the kinds its slots take (item cell: fuzzy,
--- inverter, equal distribution, overflow destruction; fluid cell: no fuzzy), at most each kind's limit and the slots.
--- nil when none.
function M.clean_cards(spec, list)
	if type(list) ~= "table" or not spec or spec.creative then return nil end      -- (issue #441: a creative cell takes none)
	local r = M.card_rules()
	r = spec.view and r.view_cell or spec.kind == "fluid" and r.fluid_cell or r.item_cell   -- (issue #440: a view cell)
	local out, n = {}, {}
	for _, name in ipairs(list) do
		local kind = type(name) == "string" and prototypes.item[name] and M.card_kind(name)
		local limit = kind and r.limits[kind]
		if limit and (n[kind] or 0) < limit and #out < r.slots then
			n[kind] = (n[kind] or 0) + 1
			out[#out + 1] = name
		end
	end
	return #out > 0 and out or nil
end

--- does the cell have a card of `kind`?
function M.has_card(cell, kind)
	for _, name in ipairs(cell.cards or {}) do if M.card_kind(name) == kind then return true end end
	return false
end

--- Bumped whenever the cards or the list of a cell change (M.apply_cell_cards): the cursors of the holder lists
--- (first_holder) start again, since a cell may take a key it refused (or the reverse).
local room_gen = 0

--- AE2's share of one key in a cell with an Equal Distribution Card (BasicCellInventory: the bytes left after the
--- type costs, divided by the types: the whitelist's size without a fuzzy card, else the cell's type limit)
local function equal_share(cell, spec)
	local n = spec.types
	if cell.partition and not cell.fnames then n = math.min(n, math.max(1, table_size(cell.partition))) end
	local total = (spec.bytes - spec.per_type * n) * (spec.per_byte or 8)
	return math.max(0, math.ceil(total / n))
end

--- The fields the storage engine reads, from a cell's partition and cards: the configured list is `partition` (a
--- whitelist) or, with an Inverter Card, `deny`; `fnames` (Fuzzy Card), `void` (Overflow Destruction Card), `eq` (Equal
--- Distribution Card: the share of one key). A cell without cards keeps exactly the fields of 0.3.0.
function M.apply_cell_cards(cell)
	room_gen = room_gen + 1
	local spec = cell_spec(cell.name) or M.view_spec(cell.name)   -- (issue #440)
	if not spec then return end
	local keys = cell.partition or cell.deny or cell.gkeys
	local kinds = {}
	for _, name in ipairs(cell.cards or {}) do
		local k = M.card_kind(name)
		if k then kinds[k] = true end
	end
	--- issue #354: with a Group Filter Card its text (cell.gtext) is the filter and the list waits in `gkeys` (AE2-U's
	--- CellInventoryHandler: the ore filter replaces the partition; an empty text lets everything in)
	cell.gf, cell.ginv, cell.gkeys = nil, nil, nil
	if kinds.gfilter then
		cell.partition, cell.deny, cell.gkeys = nil, nil, keys
		cell.gf, cell.ginv = cell.gtext, cell.gtext and kinds.inverter or nil
	elseif kinds.inverter then cell.partition, cell.deny = nil, keys else cell.partition, cell.deny = keys, nil end
	local names
	if kinds.fuzzy and keys and not kinds.gfilter then
		for key in pairs(keys) do
			local n = name_of_key(key)
			if n then
				names = names or {}
				names[n] = true
			end
		end
	end
	cell.fnames = names
	cell.void = kinds.void or spec.void or nil          -- issue #354: a void cell voids without a card
	cell.creative = spec.creative or nil               -- issue #441
	cell.sticky = kinds.sticky or nil                  -- issue #193
	cell.eq = nil
	if kinds.equal then cell.eq = equal_share(cell, spec) end
	if cell.cards and #cell.cards == 0 then cell.cards = nil end
end

--- the configured list of a cell (its whitelist, or its blacklist with an Inverter Card), sorted
function M.cell_keys(cell)
	local out = {}
	for key in pairs(cell.partition or cell.deny or cell.gkeys or {}) do out[#out + 1] = key end
	table.sort(out)
	return out
end

--- set the configured list of a cell (cleaned; the cards decide whether it is a whitelist or a blacklist)
function M.set_cell_keys(cell, keys)
	cell.partition = M.clean_partition(cell_spec(cell.name) or M.view_spec(cell.name), keys or {})   -- (issue #440)
	cell.deny, cell.gkeys = nil, nil
	M.apply_cell_cards(cell)
end

--- "1234" or "12.3"
local function amount_text(n)
	if n == math.floor(n) then return string.format("%d", n) end
	return string.format("%.1f", n)
end
M.amount_text = amount_text

local function cell_total(cell)
	local n = 0
	for _, c in pairs(cell.items) do n = n + c end
	return n
end

--- the icons of the partition shown in a cell's tooltip: as many as fit in a line or two (issue #64)
local TIP_KEYS = 12

--- the rich text icon of a key: [item=name], [item=name,quality=q] (not for normal) or [fluid=name]
local function key_icon(key)
	if is_fluid_key(key) then
		local name, deg = split_fluid_key(key)
		return "[fluid=" .. name .. "]" .. (deg and (deg .. "°C") or "")
	end
	local name, q = parse_key(key)
	if q ~= "normal" then return "[item=" .. name .. ",quality=" .. q .. "]" end
	return "[item=" .. name .. "]"
end

--- Issue #147 (the maintainer's comment): the icon of a key with its name behind it, [item=iron-plate] Iron plate; an item
--- of another quality names the quality, a fluid of a temperature the degrees. A LocalisedString.
local function key_label(key)
	local fluid = is_fluid_key(key)
	local name, q, deg
	if fluid then name, deg = split_fluid_key(key) else name, q = parse_key(key) end
	local proto = (fluid and prototypes.fluid or prototypes.item)[name]
	local label = { "", key_icon(key), " ", proto and proto.localised_name or name }
	if q and q ~= "normal" then label[#label + 1] = { "", " (", { "quality-name." .. q }, ")" } end
	if deg then label[#label + 1] = " (" .. deg .. "°C)" end
	return label
end

--- the labels of `keys` (at most `n`) one per line, as one LocalisedString, each line after a newline
local function key_lines(keys, n, amounts)
	local out = { "" }
	for i = 1, math.min(n, #keys) do
		local key = keys[i]
		out[#out + 1] = "\n"
		if amounts then
			out[#out + 1] = (is_fluid_key(key) and amount_text(amounts[key]) or tostring(amounts[key])) .. " "
		end
		out[#out + 1] = key_label(key)
	end
	return out
end

--- What a cell's cards make of its partition, as the modes the windows and the item tooltip name (`kind`: "inverted",
--- "fuzzy", "equal", "void"; `c`: the fields of drive_info or cell_flags): one localised sentence, or nil. The
--- window joins them into one line (cell_mode_caption), the tooltip puts them on lines of their own.
function M.cell_mode_text(kind, c)
	if kind == "inverted" then return c.inverted and not c.gfilter and { "fork-me-gui.cell-mode-blacklist" } or nil end   -- (#354: the text's line says it)
	if kind == "fuzzy" then return c.fuzzy and { "fork-me-gui.cell-mode-fuzzy" } or nil end
	if kind == "equal" then return c.equal and { "fork-me-gui.cell-mode-equal", G.fmt(c.equal) } or nil end
	if kind == "void" then return c.void and { "fork-me-gui.cell-mode-void" .. (c.voidcell and "cell" or "") } or nil end
	if kind == "sticky" then return c.sticky and { "fork-me-gui.cell-mode-sticky" } or nil end
	if kind == "gfilter" then                                  -- issue #354
		if not c.gfilter then return nil end
		return c.gtext and { "fork-me-gui.cell-mode-gfilter" .. (c.inverted and "-blacklist" or ""), c.gtext }
			or { "fork-me-gui.cell-mode-gfilter-empty" }
	end
end

--- the same fields as drive_info's for a cell record (drive_info keeps its own copy: it is the hot one)
local function cell_flags(cell)
	return { inverted = cell.deny ~= nil or M.has_card(cell, "inverter"), fuzzy = cell.fnames ~= nil or M.has_card(cell, "fuzzy"),
		equal = cell.eq, void = cell.void == true, sticky = cell.sticky == true,
		voidcell = cell_spec(cell.name) and cell_spec(cell.name).void or nil, gfilter = M.has_card(cell, "gfilter"), gtext = cell.gtext }
end

--- Issue #64: the tooltip of a cell that is not a fresh one, the same lines in the same order for every cell, so two
--- cells compare at a glance (a line that does not apply is left out):
---   1. what it holds, as before; an empty cell says its size instead
---   2. the partition as icons (at most TIP_KEYS, then "+N more")
---   3. whitelist or blacklist, in the words of the windows
---   4. the cards as icons, then what they do (fuzzy, equal distribution, overflow destruction), in the words of the windows;
---      a void cell without cards gets its warning here (issue #376)
--- One concatenation of at most 13 parts (a localised string takes 20), the icon lists plain strings. Cells written
--- by an earlier version keep their old description until they pass through a drive or the workbench; its keys stay.
local function cell_description(cell, spec, plist, cards, keys, list)
	local fluid = spec and fluid_cell(spec)
	local desc = { "" }
	local function line(text)
		if #desc > 1 then desc[#desc + 1] = "\n" end
		desc[#desc + 1] = text
	end
	if spec and spec.view then
		line({ "fork-me-net.view-cell-tip" })                    -- (issue #440: a view cell holds nothing)
	elseif spec and spec.creative then
		line({ "fork-me-net.creative-cell-tip" })                -- (issue #441: what it lists, without end)
	elseif #keys == 0 then
		line({ fluid and "fork-me-net.cell-tip-empty-fluid" or "fork-me-net.cell-tip-empty", spec and spec.bytes or 0, spec and spec.types or 0 })
	else
		line({ fluid and "fork-me-net.fluid-cell-holds" or "fork-me-net.cell-holds",
			amount_text(cell_total(cell)), cell.types, table.concat(list, ", "),
			cell.bytes, spec and spec.bytes or 0, #keys > 5 and ", ..." or "" })
	end
	local flags = cell_flags(cell)
	if plist then
		local sorted, icons = M.cell_keys(cell), {}
		for i = 1, math.min(TIP_KEYS, #sorted) do icons[i] = key_icon(sorted[i]) end
		if #sorted > TIP_KEYS then
			line({ "fork-me-net.cell-tip-partition-more", table.concat(icons, " "), #sorted - TIP_KEYS })
		else
			line({ "fork-me-net.cell-tip-partition", table.concat(icons, " ") })
		end
	end
	if flags.inverted and not flags.gfilter then line(M.cell_mode_text("inverted", flags))
	elseif plist and not flags.gfilter then line({ "fork-me-gui.cell-mode-whitelist" }) end
	if cards then
		local icons = {}
		for i, name in ipairs(cards) do icons[i] = "[item=" .. name .. "]" end
		line({ "fork-me-net.cell-tip-cards", table.concat(icons, " ") })
		for _, kind in ipairs({ "fuzzy", "equal", "void", "sticky", "gfilter" }) do
			local text = M.cell_mode_text(kind, flags)
			if text then line(text) end
		end
	elseif flags.void then
		line(M.cell_mode_text("void", flags))   -- issue #376: a void cell is void without a card
	end
	return desc
end

--- the item stack definition of a cell (tags and a description when it holds something, is partitioned or has cards; issue
--- #394: in the quality of the cell item it was made from, `cell.quality`, nil for normal)
local function cell_stack(cell)
	local plist = cell.partition or cell.deny or cell.gkeys   -- issue #17: a blacklist is kept as the partition
	local cards = cell.cards and #cell.cards > 0 and { table.unpack(cell.cards) } or nil
	if next(cell.items) == nil and not plist and not cards and not cell.gtext then
		return { name = cell.name, count = 1, quality = cell.quality }
	end
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
		local key = keys[i]
		if is_fluid_key(key) then
			list[#list + 1] = amount_text(items[key]) .. " " .. key_icon(key)
		else
			list[#list + 1] = items[key] .. " [item=" .. parse_key(key) .. "]"
		end
	end
	return {
		name = cell.name, count = 1, quality = cell.quality,
		tags = { [CELL_TAG] = { items = items, data = data, partition = plist, cards = cards, gtext = cell.gtext } },
		custom_description = cell_description(cell, cell_spec(cell.name) or M.view_spec(cell.name), plist, cards, keys, list),
	}
end
M.cell_stack = cell_stack

--- Issue #147: the tooltip of a cell inside a drive (the drive window and the ME Terminal's Cells tab), read from the
--- cell record (no copies), one line each:
---   1. the cell's name, item or fluid cell, its bytes
---   2. the fill (bytes and types used of total)
---   3. the partition as icons, as the item tooltip (issue #64): at most TIP_KEYS, then "+N more"
---   4. whitelist or blacklist, the cards as icons and what they do, in the words of the item tooltip and the windows
---   5. the first TIP_HOLDS kinds it holds with their amounts (fluids as the fluid cell's tooltip), then "+N more"
--- Lines that do not apply are left out. The sentences of 4 are one nested concatenation, so the outer one stays far
--- below the engine's 20 parameters (the drive window adds its click hints after it).
local TIP_HOLDS = 5
local TIP_NAMES = 6                       -- (partition entries with their names, one per line: fewer than the icons of the item tooltip)

local function drive_cell(drive, slot)
	local s = storage.fork_me_net
	local d = s and drive and drive.valid and s.drives[drive.unit_number]
	return d and d.slots[slot]
end

function M.drive_cell_tooltip(drive, slot)
	local cell = drive_cell(drive, slot)
	if not cell then return nil end
	local spec = cell_spec(cell.name) or { bytes = 0, types = 0 }
	local fluid = fluid_cell(spec)
	local proto = prototypes.item[cell.name]
	local lines = {
		{ fluid and "fork-me-gui.cell-tip-head-fluid" or "fork-me-gui.cell-tip-head", proto and proto.localised_name or cell.name,
			G.fmt(spec.bytes) },
		{ "fork-me-gui.cell-fill", G.fmt(cell.bytes), G.fmt(spec.bytes), cell.types, spec.types },
	}
	local plist = cell.partition or cell.deny or cell.gkeys
	local flags = cell_flags(cell)
	if plist then
		local sorted = M.cell_keys(cell)
		lines[#lines + 1] = #sorted > TIP_NAMES and { "fork-me-gui.cell-tip-partition-list-more", key_lines(sorted, TIP_NAMES), #sorted - TIP_NAMES }
			or { "fork-me-gui.cell-tip-partition-list", key_lines(sorted, TIP_NAMES) }
	end
	local mode = { "" }
	local function add(text)
		if #mode > 1 then mode[#mode + 1] = "\n" end
		mode[#mode + 1] = text
	end
	if flags.inverted and not flags.gfilter then add(M.cell_mode_text("inverted", flags))
	elseif plist and not flags.gfilter then add({ "fork-me-gui.cell-mode-whitelist" }) end
	if cell.cards and #cell.cards > 0 then
		local icons = {}
		for i, name in ipairs(cell.cards) do icons[i] = "[item=" .. name .. "]" end
		add({ "fork-me-net.cell-tip-cards", table.concat(icons, " ") })
		for _, kind in ipairs({ "fuzzy", "equal", "void", "sticky", "gfilter" }) do
			local text = M.cell_mode_text(kind, flags)
			if text then add(text) end
		end
	elseif flags.void then
		add(M.cell_mode_text("void", flags))   -- issue #376: a void cell is void without a card
	end
	if #mode > 1 then lines[#lines + 1] = mode end
	local keys = {}
	for key in pairs(cell.items) do keys[#keys + 1] = key end
	if #keys > 0 then
		table.sort(keys, function(a, b)
			if cell.items[a] ~= cell.items[b] then return cell.items[a] > cell.items[b] end
			return a < b
		end)
		local list = key_lines(keys, TIP_HOLDS, cell.items)
		lines[#lines + 1] = #keys > TIP_HOLDS and { "fork-me-gui.cell-tip-holds-more", list, #keys - TIP_HOLDS }
			or { "fork-me-gui.cell-tip-holds", list }
	end
	local tip = { "" }
	for i, l in ipairs(lines) do
		if i > 1 then tip[#tip + 1] = "\n" end
		tip[#tip + 1] = l
	end
	return tip
end

--- what the tooltip above shows changes when this does (the cell lists rebuild their buttons on a new signature)
function M.drive_cell_sig(drive, slot)
	local cell = drive_cell(drive, slot)
	if not cell then return "-" end
	local parts = { cell.name, cell.bytes, cell.types, tostring(cell.deny ~= nil), tostring(cell.eq), tostring(cell.void),
		tostring(cell.fnames ~= nil), table.concat(cell.cards or {}, "|"), table.concat(M.cell_keys(cell), "|") }
	for key, count in pairs(cell.items) do parts[#parts + 1] = key .. "=" .. count end
	return table.concat(parts, ":")
end

--- the fill state of a cell: "room", "high" (above 75 % of the bytes, or no new type but bytes left), "full" (no bytes left,
--- or empty without room for a type). Issue #468: a cell that takes no new type but more of what it holds is orange, as
--- AE2-Unofficial's status 3 (appeng/me/storage/CellInventory.java, getStatusForCell), not red: a one-type Singularity cell
--- was red as soon as it held anything.
local function cell_state(cell)
	local spec = cell_spec(cell.name)
	if not spec then return "full" end
	if spec.void then return "room" end                 -- (issue #354: a void cell is never full)
	local left = spec.bytes - cell.bytes
	local new_type = cell.types < spec.types and left - spec.per_type > 0   -- (as open_cell below)
	if left < 1 or (cell.types == 0 and not new_type) then return "full" end
	if not new_type or cell.bytes > spec.bytes * 0.75 then return "high" end
	return "room"
end

--------------------------------------------------------------------------------
--- issue #5: the index of a key, with what depends on it
--------------------------------------------------------------------------------

local HOLDER_CURSORS = { "hfs", "hfr", "hrr" }

--- Derived lookups per network (the insertion order by priority group and kind, the sorted holders of a key, the
--- extraction order of a key). They are a pure function of the network's state, so they are kept outside `storage`
--- (no save size; after a load they are built again and give the same results on every peer). `cache[net]` is valid
--- while net.order is the table it was built from (ordered() makes a new one whenever the order changes) and the
--- holders of a key are dropped whenever the key's index changes (idx_add, idx_del).
local cache = setmetatable({}, { __mode = "k" })

--- "<unit>:<slot>" -> the drive's unit number (false for an external cell), remembered per cell id
local cid_units = {}
local function cid_unit(cid)
	local u = cid_units[cid]
	if u == nil then
		u = tonumber(cid:match("^(%d+):%d+$")) or false
		cid_units[cid] = u
	end
	return u
end

--- Endpoints waiting for a key (issue #5): net.wait_in[key] = { [unit] = kind } wake when the network gets more of
--- the key, net.wait_out[key] when it loses some (one wake per registration). In storage, because they decide when
--- an endpoint is visited. M.wakers[kind](unit) is set by the module of that kind at load time.
M.wakers = {}
--- Issue #441: the amount of each listed key a creative cell holds (the totals, the terminal, the planner): 2^50, far below the
--- 2^53 of exact integers, so the totals stay exact with it
M.CREATIVE = 2 ^ 50
--- Issue #426: M.deliverers[waker](unit, key, count) hands the products of a job that block `unit` asked for (its Crafting
--- Card) to that block (AE2's ICraftingRequester.injectCraftedItems) and returns what the block took; the rest is stored. Set
--- by the module of that waker at load time.
M.deliverers = {}

--- does `unit` still belong to `net`? (a unit that moved to another network registers there at its next visit)
local function stays(nodes, net, unit)
	local node = nodes[unit]
	return not node or node.net == net.id
end

local function fire(net, waits, key)
	local w = waits[key]
	if not w then return end
	waits[key] = nil
	local units = {}
	for unit in pairs(w) do units[#units + 1] = unit end
	table.sort(units)
	local nodes = state().nodes
	for _, unit in ipairs(units) do
		local f = M.wakers[w[unit]]
		if f and stays(nodes, net, unit) then f(unit) end
	end
end

--- endpoints waiting for the amount of `key` to fall below their threshold (net.wait_below[key] = { [unit] =
--- { kind, amount } }): the ones whose threshold it is below now wake
local function fire_below(net, key)
	local w = net.wait_below[key]
	local have = net.items[key] or 0
	local units = {}
	for unit, v in pairs(w) do
		if have < v[2] then units[#units + 1] = unit end
	end
	if #units == 0 then return end
	table.sort(units)
	local nodes = state().nodes
	for _, unit in ipairs(units) do
		local kind = w[unit][1]
		w[unit] = nil
		local f = M.wakers[kind]
		if f and stays(nodes, net, unit) then f(unit) end
	end
	if next(w) == nil then net.wait_below[key] = nil end
end

--- the network's amount of `key` went up (`up`) or down: the version of its contents and the waiting endpoints
local function moved_key(net, key, up)
	net.cver = (net.cver or 0) + 1
	local waits = up and net.wait_in or net.wait_out
	if waits then
		if waits[key] then fire(net, waits, key) end
		--- issue #159: a wait for a fluid at every temperature ("fluid/<name>") wakes when any temperature of it arrives
		local alt = up and alt_key(key)
		if alt and waits[alt] then fire(net, waits, alt) end
	end
	if not up and net.wait_below and net.wait_below[key] then fire_below(net, key) end
end

--- Issue #38: endpoints parked on the network's side wake without polling. `net.wait_use[unit] = kind` wakes when
--- the network is usable again (power back, a controller), `net.wait_room[unit] = kind` when room for a new key
--- may have appeared (a cell joined the network, a cell lost a key). In storage, like the key waits; one wake per
--- registration.
local function fire_units(net, field)
	local w = net[field]
	if not w then return end
	net[field] = nil
	local units = {}
	for unit in pairs(w) do units[#units + 1] = unit end
	table.sort(units)
	local nodes = state().nodes
	for _, unit in ipairs(units) do
		local f = M.wakers[w[unit]]
		if f and stays(nodes, net, unit) then f(unit) end
	end
end

--- the waiting units of a network and their kinds (a split wakes the ones that moved to a part, a fire skips the ones that left)
local function note_waiter(net, kind, unit)
	local wu = net.wunits
	if not wu then
		wu = {}
		net.wunits = wu
	end
	wu[unit] = kind
end

function M.wait_usable(net, kind, unit)
	note_waiter(net, kind, unit)
	local w = net.wait_use
	if not w then
		w = {}
		net.wait_use = w
	end
	w[unit] = kind
end

function M.wait_room(net, kind, unit)
	note_waiter(net, kind, unit)
	local w = net.wait_room
	if not w then
		w = {}
		net.wait_room = w
	end
	w[unit] = kind
end

--- the waiters of `other` (merged into `net`) continue on `net`
function take_waits(net, other)
	if not (other.wait_in or other.wait_out or other.wait_below or other.wait_use or other.wait_room) then return end   -- (the usual)
	if other.wunits then
		local wu = net.wunits
		if not wu then
			wu = {}
			net.wunits = wu
		end
		for unit, kind in pairs(other.wunits) do wu[unit] = kind end
	end
	for _, field in ipairs({ "wait_in", "wait_out" }) do
		local src = other[field]
		if src then
			local dst = net[field]
			if not dst then
				dst = {}
				net[field] = dst
			end
			for key, w in pairs(src) do
				local d = dst[key]
				if not d then
					d = {}
					dst[key] = d
				end
				for unit, kind in pairs(w) do d[unit] = kind end
			end
		end
	end
	if other.wait_below then
		local dst = net.wait_below
		if not dst then
			dst = {}
			net.wait_below = dst
		end
		for key, w in pairs(other.wait_below) do
			local d = dst[key]
			if not d then
				d = {}
				dst[key] = d
			end
			for unit, v in pairs(w) do d[unit] = v end
		end
	end
	for _, field in ipairs({ "wait_use", "wait_room" }) do
		local src = other[field]
		if src then
			local dst = net[field]
			if not dst then
				dst = {}
				net[field] = dst
			end
			for unit, kind in pairs(src) do dst[unit] = kind end
		end
	end
end

--- every waiter of `net` wakes once (the network is split or rebuilt: the endpoints register again where they are)
function fire_all_waits(net)
	if not (net.wait_in or net.wait_out or net.wait_below or net.wait_use or net.wait_room) then return end
	local kinds = {}
	for _, field in ipairs({ "wait_in", "wait_out" }) do
		local waits = net[field]
		if waits then
			for _, w in pairs(waits) do
				for unit, kind in pairs(w) do kinds[unit] = kind end
			end
			net[field] = nil
		end
	end
	if net.wait_below then
		for _, w in pairs(net.wait_below) do
			for unit, v in pairs(w) do kinds[unit] = v[1] end
		end
		net.wait_below = nil
	end
	for _, field in ipairs({ "wait_use", "wait_room" }) do
		local w = net[field]
		if w then
			for unit, kind in pairs(w) do kinds[unit] = kind end
			net[field] = nil
		end
	end
	local units = {}
	for unit in pairs(kinds) do units[#units + 1] = unit end
	table.sort(units)
	for _, unit in ipairs(units) do
		local f = M.wakers[kinds[unit]]
		if f then f(unit) end
	end
end

--- `unit` (an endpoint of `kind`) wakes when the network gets more of `key` (`up`) or loses some
function M.wait_for(net, key, kind, unit, up)
	note_waiter(net, kind, unit)
	local field = up and "wait_in" or "wait_out"
	local waits = net[field]
	if not waits then
		waits = {}
		net[field] = waits
	end
	local w = waits[key]
	if not w then
		w = {}
		waits[key] = w
	end
	w[unit] = kind
end

--- `unit` (an endpoint of `kind`) wakes when the network's amount of `key` falls below `amount`
function M.wait_below(net, key, kind, unit, amount)
	note_waiter(net, kind, unit)
	local waits = net.wait_below
	if not waits then
		waits = {}
		net.wait_below = waits
	end
	local w = waits[key]
	if not w then
		w = {}
		waits[key] = w
	end
	w[unit] = { kind, amount }
end

--- a cell started (`added`) or stopped holding `key`: the sorted lists of its holders follow (issue #59; defined with the
--- lookups below)
local holders_changed

--- Issue #159: the storage keys of each fluid a network has held (fluid name -> keys: the default key first, then by
--- temperature), made from the index when first asked and kept up to date by idx_add; a key whose amount went to 0
--- stays listed (the callers read net.items). Per load, weak: nothing is saved.
local fluid_sets = setmetatable({}, { __mode = "k" })
local EMPTY_KEYS = {}
local function by_degrees(a, b)
	local _, da = split_fluid_key(a)
	local _, db = split_fluid_key(b)
	if (da == nil) ~= (db == nil) then return da == nil end
	if da ~= db then return da < db end
	return a < b
end
local function note_fluid(fs, key)
	local name = split_fluid_key(key)
	local l = fs[name]
	if not l then
		l = {}
		fs[name] = l
	end
	for i = 1, #l do if l[i] == key then return end end
	l[#l + 1] = key
	table.sort(l, by_degrees)
end

--- the storage keys of fluid `name` the network holds or held (shared: callers must not change it), default first,
--- then from the coldest to the hottest
function M.fluid_keys(net, name)
	local fs = fluid_sets[net]
	if not fs then
		fs = {}
		local keys = {}
		for key in pairs(net.index) do if is_fluid_key(key) then keys[#keys + 1] = key end end
		table.sort(keys)
		for _, key in ipairs(keys) do note_fluid(fs, key) end
		fluid_sets[net] = fs
	end
	return fs[name] or EMPTY_KEYS
end

local function idx_add(net, key, cid)
	local idx = net.index[key]
	if not idx then
		idx = {}
		net.index[key] = idx
		net.kgen = (net.kgen or 0) + 1                   -- (issue #363: a key new in the network)
		if is_fluid_key(key) then
			local fs = fluid_sets[net]
			if fs then note_fluid(fs, key) end
		end
	end
	if not idx[cid] then
		idx[cid] = true
		holders_changed(net, key, cid, true)
	end
end

local function idx_del(net, key, cid)
	local idx = net.index[key]
	if idx and idx[cid] then
		idx[cid] = nil
		if next(idx) == nil then net.index[key] = nil end
		holders_changed(net, key, cid, false)
	end
end

--- add (sign 1) or remove (sign -1) the cell's contents to or from the network's totals and index
function net_cell(net, cid, cell, sign)
	local spec = not cell.ext and cell_spec(cell.name)
	if not (spec or cell.ext) then return end
	net.order_dirty = true
	if sign > 0 then
		net.cells[cid] = cell
		net.cell_list[#net.cell_list + 1] = cid
	else
		--- issue #420: the list keeps the cell's entry until its next use (M.cell_ids): the cells that leave in one burst are
		--- taken out in one pass, not one walk over the network's cells each (158 storage buses at 20 000: 79 ms)
		net.cells[cid] = nil
		net.cell_gone = true
	end
	if spec then                                      -- an external cell (storage bus) has no bytes or types
		local p = fluid_cell(spec) and "f" or ""      -- item cells count in bytes/types, fluid cells in fbytes/ftypes
		net[p .. "bytes"] = net[p .. "bytes"] + sign * cell.bytes
		net[p .. "bytes_total"] = net[p .. "bytes_total"] + sign * spec.bytes
		net[p .. "types"] = net[p .. "types"] + sign * cell.types
		net[p .. "types_total"] = net[p .. "types_total"] + sign * spec.types
	end
	if sign > 0 and net.wait_room then fire_units(net, "wait_room") end
	local waits = sign > 0 and net.wait_in or net.wait_out
	local woken
	for key, count in pairs(cell.items) do
		local now = (net.items[key] or 0) + sign * count
		net.items[key] = now > ZERO and now or nil
		if sign > 0 then idx_add(net, key, cid) else idx_del(net, key, cid) end
		if waits and waits[key] then
			woken = woken or {}
			woken[#woken + 1] = key
		end
		local alt = sign > 0 and waits and alt_key(key)            -- issue #159 (moved_key)
		if alt and waits[alt] then
			woken = woken or {}
			woken[#woken + 1] = alt
		end
	end
	net.cver = (net.cver or 0) + 1
	if woken then
		table.sort(woken)
		for _, key in ipairs(woken) do fire(net, waits, key) end
	end
	if sign < 0 and net.wait_below then
		local keys = {}
		for key in pairs(cell.items) do if net.wait_below[key] then keys[#keys + 1] = key end end
		table.sort(keys)
		for _, key in ipairs(keys) do if net.wait_below[key] then fire_below(net, key) end end
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

--- set the controller's power use: base + per member without its own power (a crafting block: its own number)
local function update_power(s, net)
	net.power_dirty = nil
	local members = 0
	--- issue #149: where the power goes, by kind (a crafting block: by its entity name): { n = blocks, w = watts, entity = true
	--- for a crafting block }; the controller's base is a row of its own, so the rows add up to net.power exactly
	local by = { controller = { n = 1, w = BASE_POWER } }
	for unit in pairs(net.nodes) do
		local node = s.nodes[unit]
		if node and not POWERED_SELF[node.kind] then
			local w = member_power(node)
			members = members + w
			local crafting = node.kind == "crafting" and node.entity.valid
			local key = crafting and node.entity.name or node.kind
			local row = by[key]
			if not row then
				row = { n = 0, w = 0, entity = crafting or nil }
				by[key] = row
			end
			row.n, row.w = row.n + 1, row.w + w
		end
	end
	net.power_by = by
	net.power = BASE_POWER + members
	for unit in pairs(net.controllers) do
		local node = s.nodes[unit]
		if node and node.entity.valid then M.set_draw(node.entity, net.power) end
	end
end

--- Issue #556: a controller draws `watts` (its network's power), and its buffer holds BUFFER_TICKS of that draw, at least the
--- prototype's 100 kJ: with a fixed buffer a draw of more than 100 kJ per tick (6 MW) emptied it every tick and the network
--- reported "no-power" on any grid. The prototype's input flow limit is far above any network. (A field: the main chunk is at
--- Lua's limit of 200 locals.)
M.BUFFER_TICKS = 30
M.MIN_BUFFER = 100000
function M.set_draw(entity, watts)
	entity.power_usage = watts / 60
	local buffer = math.max(M.MIN_BUFFER, watts / 60 * M.BUFFER_TICKS)
	if entity.electric_buffer_size ~= buffer then entity.electric_buffer_size = buffer end
end

--- Issue #560: the ME Molecular Assembler is a member without a power connection (a void energy source, prototypes/api.lua): the
--- controller draws its prototype's energy usage (with its Acceleration Cards' consumption) while it crafts and a thirtieth of
--- it otherwise (the game's drain of a machine), AE2's and the game's way. Its node keeps the draw counted for it (`w`), so a
--- change is added to the controller's draw as it is (no walk over the members) and a member that leaves takes out what it
--- added. M.assembler_step (once a second, from the slow step) reads each assembler's status: the draw follows within a
--- second, and an assembler whose network does not work is switched off with a status saying why (`off`), and on again (`on`:
--- switched on since its node was made). The usage per name is derived, read once per load.
M.ASM_IDLE = 30
M.asm_usage = {}
function M.asm_watts(entity, crafting)
	local name = entity.name
	local w = M.asm_usage[name]
	if not w then
		w = prototypes.entity[name].energy_usage * 60
		M.asm_usage[name] = w
	end
	--- (whole watts: the sums of the draws do not depend on their order)
	if not crafting then return math.floor(w / M.ASM_IDLE + 0.5) end
	return math.floor(w * math.max(0.2, 1 + entity.consumption_bonus) + 0.5)      -- (the game's floor: -80 %)
end

function M.assembler_power(node)
	if not node.w then node.w = node.entity.valid and M.asm_watts(node.entity, false) or 0 end
	return node.w
end

--- the draw of assembler `node` (in network `net`) becomes `w`
function M.asm_draw(s, net, node, w)
	local d = w - M.assembler_power(node)
	node.w = w
	local row = net and not net.power_dirty and net.power_by and net.power_by.assembler
	if not row then
		if net then net.power_dirty = true end
		return
	end
	row.w = row.w + d
	net.power = net.power + d
	for unit in pairs(net.controllers) do
		local c = s.nodes[unit]
		if c and c.entity.valid then M.set_draw(c.entity, net.power) end
	end
end

function M.assembler_step(s)
	local working = defines.entity_status.working
	for unit in pairs(s.asm) do
		local node = s.nodes[unit]
		if not (node and node.kind == "assembler") then
			s.asm[unit] = nil
		elseif node.entity.valid then
			local e = node.entity
			local net = s.nets[node.net]
			local ok, why = M.usable(net)
			local w
			if ok then
				if not node.on then
					e.disabled_by_script = false
					e.custom_status = nil
					node.on, node.off = true, nil
				end
				w = M.asm_watts(e, e.status == working)
			else
				if node.off ~= why then
					e.disabled_by_script = true
					e.custom_status = { diode = defines.entity_status_diode.red, label = { "fork-me-net.status-" .. why } }
					node.on, node.off = nil, why
				end
				w = M.asm_watts(e, false)
			end
			if w ~= node.w then M.asm_draw(s, net, node, w) end
		end
	end
end

--- Issue #420: a member that joined (`sign` 1) or left (-1) a network without a split changes its controller's draw by its
--- own power, as update_power would count it, instead of the walk over every member at the network's next use (a burst of
--- 1000 built blocks with 158 storage buses, each looking at its network at once, walked 20 000 members 158 times: 7.6 s). A
--- kind whose power depends on its state (M.power_hooks) or a crafting block (counted by its entity name, which a removed
--- block no longer has) makes the walk instead, as does a network whose breakdown is not up to date. (A field: no main-chunk
--- local, the chunk is at Lua's limit of 200.)
function M.power_add(s, net, node, sign)
	if POWERED_SELF[node.kind] then return end
	if net.power_dirty or not net.power_by or M.power_hooks[node.kind] or node.kind == "crafting" then
		net.power_dirty = true
		return
	end
	local w = member_power(node)
	local row = net.power_by[node.kind]
	if sign > 0 then
		if not row then
			row = { n = 0, w = 0 }
			net.power_by[node.kind] = row
		end
		row.n, row.w = row.n + 1, row.w + w
	else
		if not (row and row.n > 0) then
			net.power_dirty = true
			return
		end
		row.n, row.w = row.n - 1, row.w - w
		if row.n == 0 then net.power_by[node.kind] = nil end
	end
	net.power = net.power + sign * w
	for unit in pairs(net.controllers) do
		local c = s.nodes[unit]
		if c and c.entity.valid then M.set_draw(c.entity, net.power) end
	end
end

--- controllers, status, drives, storage totals and power of a network, from its members
function recompute(s, net)
	net.controllers, net.drives = {}, {}
	local nc = 0
	net.creative = nil                                    -- (issue #442: a Creative Energy Cell among the members)
	for unit in pairs(net.nodes) do
		local node = s.nodes[unit]
		if node then
			if node.kind == "controller" then net.controllers[unit] = true nc = nc + 1 end
			if node.kind == "creative-energy" then net.creative = true end
			if CELL_KINDS[node.kind] then net.drives[unit] = true end
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
	net.items, net.index, net.cells, net.cell_list, net.order_dirty, net.cell_gone = {}, {}, {}, {}, true, nil
	fluid_sets[net] = nil
	net.bytes, net.bytes_total, net.types, net.types_total = 0, 0, 0, 0
	net.fbytes, net.fbytes_total, net.ftypes, net.ftypes_total = 0, 0, 0, 0
	drive_cells(net, s, function(cid, cell) net_cell(net, cid, cell, 1) end)
	local ext = {}
	for unit in pairs(net.nodes) do if s.ext and s.ext[unit] then ext[#ext + 1] = unit end end
	table.sort(ext)
	for _, unit in ipairs(ext) do net_cell(net, unit .. ":ext", s.ext[unit], 1) end
	net.usable_tick = nil
	update_power(s, net)
end

--- true when the network works; else false and the reason ("no-controller", "conflict", "no-power")
function M.usable(net)
	if not net then return false, "no-network" end
	if net.chest then return CH.usable(net) end              -- (issue #229: the view of an ME Chest)
	if net.status ~= "ok" then return false, net.status end
	if net.power_dirty then update_power(state(), net) end    -- (before the cache: a member that joined this tick counts at once)
	if net.usable_tick == game.tick then return net.usable, net.why end
	local s = state()
	local ok, why = false, "no-controller"
	--- issue #442: a network with a Creative Energy Cell never lacks power (AE2-Unofficial: its energy grid's creative flag)
	if net.creative then ok, why = true, nil end
	for unit in pairs(net.creative and M.NONE or net.controllers) do
		local node = s.nodes[unit]
		local e = node and node.entity
		if e and e.valid then
			--- an energy interface without any pole reports no "no power" status: its buffer stays empty. Issue #556: nor does one
			--- on a grid that delivers less than its draw; the engine refills the buffer after the draw, so it holds what the grid
			--- gave in the last tick: less than one tick's draw is no power
			if e.status == defines.entity_status.no_power or e.energy <= 0 or e.energy < e.power_usage then
				why = "no-power"
			else
				ok, why = true, nil
			end
		end
	end
	net.usable, net.why, net.usable_tick = ok, why, game.tick
	if ok and net.wait_use then fire_units(net, "wait_use") end
	return ok, why
end

--------------------------------------------------------------------------------
--- screens of the ME Terminals (issue #128): the terminal's lamp has no picture of its own (prototypes/network.lua); its
--- screen is a sprite render object that follows the entity (it goes with it when the entity is removed or destroyed), lit
--- while the terminal's network works and dark when it does not, with a light that goes with it. `s.screens[unit] = { spr,
--- light (render object ids), on }` is in `storage` (render objects are saved with the map). Nothing runs for it on its own:
--- the slow step (once a second, with the look at the network's power it makes anyway) sets every screen to its network's
--- state, and a terminal that joins a network is set at once. Setting a screen that is right already costs one comparison.
--- The ME Pattern Terminal (issue #130) is an entity with two pictures (graphics variation 1 dark, 2 lit, like the crafting
--- blocks): its record is `{ variation = true, on }` and it is set the same way; so is the ME Interface Terminal (issue #336).
--- The ME Level Maintainer (issue #254) is a lamp with a void energy source too, so the game drew it lit all the time: its
--- whole picture is a screen of the same kind without a light (`{ spr, on }`), lit while its network works and its circuit
--- condition lets it run, dark otherwise.
--------------------------------------------------------------------------------

local SCREEN_LIGHT = { intensity = 0.4, scale = 0.7, color = { 0.7, 0.55, 1 } }
--- SCREEN_LAYER (issue #258, defined at the top): one layer above the dark picture that the game draws as the entity's
--- `stateless_visualisation` (in `lower-object`, also on its ghost), below the character
--- kind -> { lit sprite, dark sprite, light }
local SCREENS = {
	terminal = { "me-terminal-screen-on", "me-terminal-screen-off", SCREEN_LIGHT },
	maintainer = { "me-level-maintainer-screen-on", "me-level-maintainer-screen-off" },
}
--- (a screen that is a graphics variation, 1 dark and 2 lit: the ME Pattern Terminal, the ME Interface Terminal of issue #336 and
--- the monitors of issue #353; no local for it: the main chunk is at Lua's limit of 200)
M.VARIATION_SCREENS = { ["pattern-terminal"] = true, ["interface-terminal"] = true, ["storage-monitor"] = true,
	["conversion-monitor"] = true, ["throughput-monitor"] = true }
function has_screen(kind) return SCREENS[kind] ~= nil or M.VARIATION_SCREENS[kind] == true end
--- issue #254: the benchmark's scenes have a level maintainer per ten buses (2000 at 20 000), so the slow step must not
--- look at every screen every second, and must not sort them (#43: about 7 µs an element). `s.screen_list` holds the
--- units of `s.screens` in the order they came (a screen that goes is replaced by the last one, each record keeps its
--- place in `li`), like `s.nlist`. The slow step sets them all only when something they show may have changed: the graph
--- (`s.version`, kept as `s.screen_version`) or the state of a network (`net.screen_on`, what its screens were last set
--- to); otherwise only the level maintainers with a circuit condition switched on (`s.screen_cond`, noted when one joins
--- and when its window or a paste sets the condition, the only ways a maintainer gets one: the lamp's window is replaced).
--- Derived per load: each condition maintainer's control behaviour (#115: one kept object instead of a new one per read).
local maintainer_cbs = {}

--- the screen list of a save from before issue #254: made once, sorted
local function screen_list(s)
	local sl = s.screen_list
	if sl then return sl end
	sl = {}
	for unit in pairs(s.screens) do sl[#sl + 1] = unit end
	table.sort(sl)
	for i, unit in ipairs(sl) do s.screens[unit].li = i end
	s.screen_list = sl
	return sl
end

--- the place in the screen list of a new record of `unit` (or the place its old record had)
local function screen_place(s, sc, unit)
	if sc and sc.li then return sc.li end
	local sl = screen_list(s)
	if sc and sc.li then return sc.li end              -- (a save from before: the list was just made, with this record)
	sl[#sl + 1] = unit
	return #sl
end

--- sets the screen of terminal or level maintainer `unit` to `on`, drawing it first if it is missing (a save from
--- before, a clone). A screen that shows `on` already costs one comparison.
local function set_screen(s, unit, entity, on, kind)
	local list = s.screens
	local sc = list[unit]
	if M.VARIATION_SCREENS[kind] or (sc and sc.variation) then
		if not (sc and sc.on == on and entity.graphics_variation == (on and 2 or 1)) then
			entity.graphics_variation = on and 2 or 1
			list[unit] = { variation = true, on = on, li = screen_place(s, sc, unit) }
		end
		return
	end
	if sc and sc.on == on then return end
	if not entity.valid then return end
	local def = SCREENS[kind]
	local spr = sc and sc.spr and rendering.get_object_by_id(sc.spr)
	local light = sc and sc.light and rendering.get_object_by_id(sc.light)
	if not (spr and spr.valid and (not def[3] or (light and light.valid))) then
		if spr and spr.valid then spr.destroy() end
		if light and light.valid then light.destroy() end
		local surface = entity.surface
		spr = rendering.draw_sprite{ sprite = on and def[1] or def[2], target = entity, surface = surface,
			render_layer = SCREEN_LAYER }
		local l = def[3]
		light = l and rendering.draw_light{ sprite = "utility/light_medium", target = entity, surface = surface,
			scale = l.scale, intensity = l.intensity, color = l.color, visible = on }
		list[unit] = { spr = spr.id, light = light and light.id or nil, on = on, li = screen_place(s, sc, unit) }
		return
	end
	sc.on = on
	spr.sprite = on and def[1] or def[2]
	if light then light.visible = on end
end

--- a level maintainer's lamp with a circuit condition switched on: its control behaviour, else nil
local function condition_of(unit, entity)
	local cb = maintainer_cbs[unit]
	if not (cb and cb.valid) then
		cb = entity.valid and entity.get_control_behavior() or nil
		maintainer_cbs[unit] = cb
	end
	if cb and (cb.circuit_enable_disable or cb.connect_to_logistic_network) then return cb end
	return nil
end

--- notes whether level maintainer `unit` has a condition switched on (it joined, or its condition was set)
local function note_condition(s, unit, entity)
	maintainer_cbs[unit] = nil
	s.screen_cond = s.screen_cond or {}
	s.screen_cond[unit] = condition_of(unit, entity) and true or nil
end

--- the state a screen shows now: its network works, and a level maintainer's circuit condition lets it run (the lamp's
--- condition, as fork-me-circuit.lua reads it; it counts only on a circuit network)
local function screen_state(s, unit, node)
	local net = s.nets[node.net]
	if not (net ~= nil and M.usable(net)) then return false end
	if s.screen_cond and s.screen_cond[unit] then
		local cb = condition_of(unit, node.entity)
		if cb and cb.disabled then return false end
	end
	return true
end

function screen_made(s, unit, entity, kind)
	if not s.screens then return end                       -- (the first slow step makes them all)
	local node = s.nodes[unit]
	kind = kind or (node and node.kind)
	if kind == "maintainer" then note_condition(s, unit, entity) end
	set_screen(s, unit, entity, node and node.net and screen_state(s, unit, node) or false, kind)
end

function screen_gone(s, unit)
	local sc = s.screens and s.screens[unit]
	if not sc then return end
	s.screens[unit] = nil
	if s.screen_cond then s.screen_cond[unit] = nil end
	maintainer_cbs[unit] = nil
	local sl, li = s.screen_list, sc.li
	if sl and li and sl[li] == unit then                -- the last screen takes its place in the list
		local last = #sl
		local moved = sl[last]
		sl[li] = moved
		sl[last] = nil
		local msc = s.screens[moved]
		if msc then msc.li = li end
	end
end

--- the screens to their state: all of them when the graph or a network's state changed since the last time, else the
--- level maintainers with a condition; the first time on a save from before also one pass over the members to make the
--- screens (and once for the level maintainers of a save from before issue #254, `s.maintainer_screens`)
local function refresh_screens(s)
	if not s.screens or not s.maintainer_screens then
		s.screens = s.screens or {}
		s.maintainer_screens = true
		screen_list(s)
		local units = {}
		for unit, node in pairs(s.nodes) do
			if has_screen(node.kind) and node.entity.valid and not s.screens[unit] then units[#units + 1] = unit end
		end
		table.sort(units)
		for _, unit in ipairs(units) do
			local node = s.nodes[unit]
			if node.kind == "maintainer" then note_condition(s, unit, node.entity) end
			set_screen(s, unit, node.entity, false, node.kind)
		end
		s.screen_version = nil
	end
	if s.screen_layer ~= SCREEN_LAYER then
		--- issue #258: the screens of a save from before go one layer up, above the dark picture the game draws now
		for _, unit in ipairs(screen_list(s)) do
			local sc = s.screens[unit]
			local spr = sc and sc.spr and rendering.get_object_by_id(sc.spr)
			if spr and spr.valid then spr.render_layer = SCREEN_LAYER end
		end
		s.screen_layer = SCREEN_LAYER
	end
	local nodes, screens, nets = s.nodes, s.screens, s.nets
	local ids = {}
	for id in pairs(nets) do ids[#ids + 1] = id end
	table.sort(ids)
	local all = s.screen_version ~= s.version
	if not all then
		for _, id in ipairs(ids) do
			local net = nets[id]
			if net.screen_on ~= (M.usable(net) and true or false) then all = true break end
		end
	end
	if all then
		local sl = screen_list(s)
		local i = 1
		while i <= #sl do
			local unit = sl[i]
			local node = nodes[unit]
			if node then
				set_screen(s, unit, node.entity, screen_state(s, unit, node), node.kind)
				i = i + 1
			else
				screen_gone(s, unit)                           -- (the last one took its place: look at it next)
				if sl[i] == unit then                         -- (a place without its record)
					local last = #sl
					sl[i], sl[last] = sl[last], nil
					local msc = i < last and screens[sl[i]]
					if msc then msc.li = i end
				end
			end
		end
		for _, id in ipairs(ids) do nets[id].screen_on = M.usable(nets[id]) and true or false end
		s.screen_version = s.version
	elseif s.screen_cond and next(s.screen_cond) then
		local units = {}
		for unit in pairs(s.screen_cond) do units[#units + 1] = unit end
		table.sort(units)
		for _, unit in ipairs(units) do
			local node = nodes[unit]
			if node and screens[unit] then
				set_screen(s, unit, node.entity, screen_state(s, unit, node), node.kind)
			else
				s.screen_cond[unit] = nil
			end
		end
	end
	return ids
end

--- (tests) the state a screen shows: nil without a screen, else { on, sprite, light, layer, ids } (a lamp terminal; a level
--- maintainer without `light`) or { on, variation } (a pattern terminal)
function M.screen_of(entity)
	local s = storage.fork_me_net
	local sc = s and s.screens and entity and entity.valid and s.screens[entity.unit_number]
	if sc and sc.variation then return { on = sc.on, variation = entity.graphics_variation } end
	local spr = sc and rendering.get_object_by_id(sc.spr)
	local light = sc and sc.light and rendering.get_object_by_id(sc.light)
	if not (spr and spr.valid) or (sc.light and not (light and light.valid)) then return nil end
	return { on = sc.on, sprite = spr.sprite, light = light and light.visible or nil, layer = spr.render_layer,
		ids = { sc.spr, sc.light } }
end

--- issue #254: sets the screen of a level maintainer now: its circuit condition was set in its window or pasted, the only
--- ways it gets one (the lamp's own window is replaced); a change through the circuit network shows within the slow
--- step's second
function M.update_screen(entity)
	local s = storage.fork_me_net
	local unit = entity and entity.valid and entity.unit_number
	local node = s and s.screens and unit and s.nodes[unit]
	if not (node and has_screen(node.kind)) then return end
	if node.kind == "maintainer" then note_condition(s, unit, entity) end
	set_screen(s, unit, entity, screen_state(s, unit, node), node.kind)
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

--- Issue #115: an engine object's methods, made once per object and load. `obj.method` makes a new bound method object at
--- every read (88 bytes of garbage, most of the time of a cheap call: 0.28 µs against 0.04 µs for a kept one), so the hot
--- paths call the methods of the objects they keep (a record's entity, T.inventory) through this. Methods only:
--- a property read here would be kept as it was. Weak keys: an object no longer kept leaves (the table it keys refers to it,
--- an ephemeron). Nothing is saved.
local bound_cache = setmetatable({}, { __mode = "k" })
local BOUND_MT = {
	__index = function(b, name)
		local f = rawget(b, 1)[name]
		rawset(b, name, f)
		return f
	end,
}
function M.bound(obj)
	local b = bound_cache[obj]
	if not b then
		b = setmetatable({ obj }, BOUND_MT)
		bound_cache[obj] = b
	end
	return b
end

--- Issue #115: the same by the member's unit number, for a caller that knows the entity is valid (a visit): no engine
--- reads (`valid` and `unit_number` of the entity, 43 calls per tick at 20 000)
function M.network_of_unit(unit)
	local s = storage.fork_me_net
	local node = s and s.nodes[unit]
	return node and s.nets[node.net] or nil
end
function M.active_of_unit(unit)
	local net = M.network_of_unit(unit)
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

--------------------------------------------------------------------------------
--- external cells: storage that is not a storage cell (the storage bus, scripts/fork-me-storagebus.lua, and its
--- fluid side, scripts/fork-me-fluid-storagebus.lua: fluid keys, fractional amounts). An
--- external cell is a record { ext = <kind>, handler = <handler name, if not the kind's>, items = { key -> count },
--- data = {}, partition, priority, hidden } kept in s.ext[unit] of its member; its cell id is "<unit>:ext". `items` is a snapshot of what the
--- storage held at the last look (none while `hidden`: write only); the totals and the index of the network
--- include it like any cell. `full[key]` (issue #5): the storage took less of the key than it was offered, so
--- inserts pass it by until its next read (ext_sync) or until something is taken from it; a full chest is not
--- asked again by every insert. The handler (M.ext_handlers[name], registered at load time) works on the real
--- storage: room(cell, key), insert(cell, key, count), count(cell, key) and extract(cell, key, count). The
--- engine asks `count` before it takes, so the network never hands out what is no longer there. Issue #67: a handler may
--- have `emptied(cell, key)`, called when an extraction took the last of `key` out of the storage (the storage bus looks
--- again soon: something may refill it).
--------------------------------------------------------------------------------

M.ext_handlers = {}

local ext_cids = {}                                  -- unit -> its cell id (per load; issue #59: a number's string costs 1 µs)
local function ext_cid(unit)
	local cid = ext_cids[unit]
	if not cid then
		cid = unit .. ":ext"
		ext_cids[unit] = cid
	end
	return cid
end

--- items of `key` a cell can take now
local function room_in(cell, key)
	if cell.ext then
		if cell.full and cell.full[key] then return 0 end
		return M.ext_handlers[cell.handler or cell.ext].room(cell, key)
	end
	return cell_room(cell, cell_spec(cell.name), key)
end

--- set an external cell's snapshot of `key` to `n`, the network's totals and index with it; true when it changed
local function ext_set(net, cid, cell, key, n)
	local old = cell.items[key] or 0
	if n < ZERO then n = 0 end
	if n == old then return false end
	cell.items[key] = n > 0 and n or nil
	if not (net and net.cells[cid] == cell) then return true end
	local now = (net.items[key] or 0) + n - old
	net.items[key] = now > ZERO and now or nil
	if n > 0 then idx_add(net, key, cid) else idx_del(net, key, cid) end
	moved_key(net, key, n > old)
	return true
end

function M.ext_get(unit)
	local s = storage.fork_me_net
	return s and s.ext and s.ext[unit] or nil
end

--- register the external cell of a member (its network takes it into its totals)
function M.ext_attach(entity, cell)
	local s = state()
	local unit = entity.unit_number
	if s.ext[unit] then M.ext_detach(unit) end
	cell.items = cell.items or {}
	cell.data = cell.data or {}
	s.ext[unit] = cell
	local net = M.network_of(entity)
	if net then net_cell(net, ext_cid(unit), cell, 1) end
end

function M.ext_detach(unit)
	local s = storage.fork_me_net
	local cell = s and s.ext and s.ext[unit]
	if not cell then return end
	local h = M.ext_handlers[cell.ext]
	if h and h.detached then h.detached(cell) end     -- issue #17: a card still in it is spilled, never lost
	local node = s.nodes[unit]
	local net = node and s.nets[node.net]
	if net and net.cells[ext_cid(unit)] == cell then net_cell(net, ext_cid(unit), cell, -1) end
	s.ext[unit] = nil
end

--- the snapshot of an external cell is now `contents` ({ key -> count }): only the differences are applied; returns
--- true when the snapshot changed
function M.ext_sync(unit, contents)
	local s = storage.fork_me_net
	local cell = s and s.ext and s.ext[unit]
	if not cell then return false end
	local node = s.nodes[unit]
	local net = node and s.nets[node.net]
	local cid = ext_cid(unit)
	if cell.hidden then contents = {} end
	cell.full = nil                                    -- read again: room is asked again (issue #5)
	local changed = false
	for key in pairs(cell.items) do
		if not contents[key] and ext_set(net, cid, cell, key, 0) then changed = true end
	end
	--- issue #509: a key whose count is the snapshot's is not passed to ext_set (most keys of a large storage at a visit: the
	--- logistic storage bus reads hundreds); the same test as ext_set's (an amount below ZERO is none)
	local items = cell.items
	for key, n in pairs(contents) do
		local old = items[key]
		if old ~= n and not (old == nil and n < ZERO) and ext_set(net, cid, cell, key, n) then changed = true end
	end
	return changed
end

--- the priority or partition of an external cell changed: its network sorts its cells again
function M.ext_touch(unit)
	local s = storage.fork_me_net
	local node = s and s.nodes[unit]
	local net = node and s.nets[node.net]
	if net then net.order_dirty = true end
end

local EMPTY = {}

--- the priority of a cell: of the drive it is in ("<unit>:<slot>"), or of the external cell
local function cell_priority(s, net, cid)
	local cell = net.cells[cid]
	if cell and cell.ext then return cell.priority or 0 end
	local d = s.drives[cid_unit(cid)]
	return d and d.priority or 0
end

--- The network's cells in insertion order (R3): higher drive priority first, then drive and slot order (cells before
--- storage buses of the same priority). Cached
--- until a cell or a priority changes (net.order_dirty). Also says whether the plain order of R1 is enough (one
--- priority, no partition).
local function ordered(s, net)
	if net.order and not net.order_dirty then return net.order, net.uniform end
	local list = {}
	local prios, parts = {}, false
	for i, cid in ipairs(M.cell_ids(net)) do
		local p = cell_priority(s, net, cid)
		prios[p] = true
		local cell = net.cells[cid]
		if cell.partition or cell.ext or cell.cards then parts = true end   -- an external cell or cards: never uniform
		list[i] = { cid = cid, p = p, i = i, ext = net.cells[cid].ext and 1 or 0 }
	end
	--- within one priority the cells before the external storage (storage buses): the network's own storage first
	table.sort(list, function(a, b)
		if a.p ~= b.p then return a.p > b.p end
		if a.ext ~= b.ext then return a.ext < b.ext end
		return a.i < b.i
	end)
	local order = {}
	for i, c in ipairs(list) do order[i] = { cid = c.cid, p = c.p } end
	local n = 0
	for _ in pairs(prios) do n = n + 1 end
	net.order, net.uniform, net.order_dirty = order, (n <= 1 and not parts), nil
	return order, net.uniform
end
M.ordered = ordered

--- Issue #420: the network's cell ids in the order they joined (net.cell_list), the entries of the cells that left since its
--- last use taken out (net.cell_gone): a cell that left and joined again keeps its last entry, as when every removal took
--- its entry out at once. (A field: no main-chunk local.)
function M.cell_ids(net)
	if not net.cell_gone then return net.cell_list end
	local list, cells = net.cell_list, net.cells
	local seen, keep = {}, {}
	for i = #list, 1, -1 do
		local cid = list[i]
		if cells[cid] and not seen[cid] then
			seen[cid] = true
			keep[#keep + 1] = cid
		end
	end
	local out = {}
	for i = #keep, 1, -1 do out[#out + 1] = keep[i] end
	net.cell_list, net.cell_gone = out, nil
	return out
end

--- can the cell take a key it does not hold yet? (types and bytes; its kind and partition are the caller's)
local function open_cell(cell, spec)
	if spec.void then return true end                   -- (issue #354: a void cell takes every new type)
	return cell.types < spec.types and spec.bytes - cell.bytes - spec.per_type > 0
end

--- Issue #17: does the cell destroy what it cannot store of `key` (an Overflow Destruction Card)? AE2's rules
--- (BasicCellInventory.insert, MEInventoryHandler.insert): a cell voids what passes its filter, one without a
--- partition only while it can take a new type or already holds the key; a storage bus voids what its filter and mode
--- let in while it works on a target (its handler's `voids`). Items with tags (`data`) are never destroyed.
local function voids(cell, key, data)
	if not cell.void or data then return false end
	if cell.ext then
		local h = M.ext_handlers[cell.handler or cell.ext]
		return h.voids ~= nil and h.voids(cell, key) == true
	end
	local spec = cell_spec(cell.name)
	if not spec or fluid_cell(spec) ~= is_fluid_key(key) or not accepts(cell, key) then return false end
	if spec.creative then return cell.partition ~= nil end   -- issue #441: only what it lists (without a list: nothing)
	if spec.void then return true end                   -- issue #354: a void cell voids whatever its filter lets in
	if cell.partition or cell.deny or cell.gf then return true end
	return cell.items[key] ~= nil or open_cell(cell, spec)
end

--- The lookups of a network (issue #5), built from the insertion order: its priority groups in order, each with
--- the cells partitioned for a key (`parts[key]`; issue #17: a fuzzy whitelist by item name in `fparts[name]`, `fuzzy`
--- says that there is one), the unpartitioned cells (and blacklists) by kind (`cells.item`, `cells.fluid`) with
--- the position of the first one that may still take a new key (`first`; cells fill in order, an extraction moves it
--- back), the unpartitioned storage buses that take inserts by the kind they face (`ext`); `at[cid]` = { g, rank,
--- kind, pos }. The holders of a key sorted by cell id (`hs`, the uniform order of R1) or by rank (`hr`) and the
--- extraction order of a key (`xs`) are made when asked and dropped when the key's index changes.
local function lookups(s, net)
	local order = ordered(s, net)
	local c = cache[net]
	if c and c.order == order then return c end
	c = { order = order, groups = {}, at = {}, hs = {}, hr = {}, xs = {}, hfs = {}, hfr = {}, hrr = {},
		read = { hs = {}, hr = {}, xs = {} } }       -- (issue #59: a list read since its last change)
	cache[net] = c
	local g
	for rank, o in ipairs(order) do
		if not (g and g.p == o.p) then
			g = { p = o.p, parts = {}, fparts = {}, cells = { item = {}, fluid = {} }, ext = { item = {}, fluid = {} },
				first = { item = 1, fluid = 1 } }
			c.groups[#c.groups + 1] = g
		end
		local cid = o.cid
		local cell = net.cells[cid]
		local at = { g = g, rank = rank }
		c.at[cid] = at
		if cell.sticky and not (cell.ext and cell.mode == "read") then   -- issue #193: the sticky storage, in insertion order
			c.sticky = c.sticky or {}
			c.sticky[#c.sticky + 1] = cid
		end
		if cell.partition then
			--- issue #17: a fuzzy whitelist is found by the item name (any quality), its fluid keys as they are
			local fnames = cell.fnames
			for key in pairs(cell.partition) do
				if not (fnames and name_of_key(key)) then
					local l = g.parts[key]
					if not l then
						l = {}
						g.parts[key] = l
					end
					l[#l + 1] = cid
				end
			end
			for name in pairs(fnames or EMPTY) do
				local l = g.fparts[name]
				if not l then
					l = {}
					g.fparts[name] = l
					c.fuzzy = true
				end
				l[#l + 1] = cid
			end
		elseif cell.ext then
			if cell.mode ~= "read" then                -- read only: it never takes anything
				local list = (cell.side == "fluid" or cell.ext == "fluid-storage-bus") and g.ext.fluid or g.ext.item
				list[#list + 1] = cid
			end
		else
			local kind = fluid_cell(cell_spec(cell.name)) and "fluid" or "item"
			local list = g.cells[kind]
			list[#list + 1] = cid
			at.kind, at.pos = kind, #list
		end
	end
	return c
end

--- the holders of `key`, sorted by cell id (by_rank false) or by their rank in the insertion order
--- the comparators of the sorted lists are module-level (a closure per rebuild made garbage): the ranks of the
--- network being sorted, and for the extraction order the priority, kind and partition of each cell, are in these
--- tables while a sort runs
local sort_at
local XO_P, XO_E, XO_X = {}, {}, {}
local function by_rank(a, b) return sort_at[a].rank < sort_at[b].rank end
local function by_extraction(a, b)
	local pa, pb = XO_P[a], XO_P[b]
	if pa ~= pb then return pa < pb end
	local ea, eb = XO_E[a], XO_E[b]
	if ea ~= eb then return ea < eb end
	local xa, xb = XO_X[a], XO_X[b]
	if xa ~= xb then return xa < xb end
	return a < b
end

local function holders(net, c, key, rank)
	local field = rank and "hr" or "hs"
	c.read[field][key] = true
	local l = c[field][key]
	if l then return l end
	l = {}
	local n = 0
	for cid in pairs(net.index[key] or EMPTY) do
		n = n + 1
		l[n] = cid
	end
	if rank then
		sort_at = c.at
		table.sort(l, by_rank)
		sort_at = nil
	else
		table.sort(l)
	end
	c[field][key] = l
	return l
end

--- Issue #59: a cell that starts or stops holding a key used to drop the key's three sorted lists (by cell id `hs`, by rank
--- `hr`, the extraction order `xs`), which the next insert or extraction sorted anew: at 20 000 a list of about 220 cells
--- sorted 900 times a minute for the extractions alone. Now a list that was made gets the cell put in at its place (or
--- taken out) in a copy: an insert or extraction that walks the old list while a cell starts or stops holding the key
--- walks it to its end unchanged, as when the list was dropped. A list is sorted by a strict total order whose values
--- only change with the network's order (a cell, a priority or a partition: net.order_dirty, new lookups), so the copy is
--- the list a sort would make. The holder cursors of the list move to the copy (an entry put in before a cursor is looked
--- at again). While the lookups are about to be made anew, or for a cell they do not know, the lists are dropped as before;
--- so is a list that nobody read since its last change (a burst of builds changes a list many times before it is used:
--- one sort at the next use costs less than a copy per change).
local function by_cid(_, a, b) return a < b end
local function by_rank_of(c, a, b) return c.at[a].rank < c.at[b].rank end
local cmp_net                                     -- the network of the list being changed (by_extraction_of)
local function by_extraction_of(_, a, b)
	local net, s = cmp_net, state()
	local pa, pb = cell_priority(s, net, a), cell_priority(s, net, b)
	if pa ~= pb then return pa < pb end
	local ca, cb = net.cells[a], net.cells[b]
	local ea, eb = ca.ext and 0 or 1, cb.ext and 0 or 1
	if ea ~= eb then return ea < eb end
	local xa, xb = ca.partition and 1 or 0, cb.partition and 1 or 0
	if xa ~= xb then return xa < xb end
	return a < b
end
local HOLDER_LISTS = {
	{ "hs", by_cid, { "hfs" } },
	{ "hr", by_rank_of, { "hfr", "hrr" } },
	{ "xs", by_extraction_of, {} },
}

--- the first position in the sorted list `l` whose entry does not come before `cid`
local function lower_bound(c, l, cid, less)
	local lo, hi = 1, #l
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		if less(c, l[mid], cid) then lo = mid + 1 else hi = mid - 1 end
	end
	return lo
end

holders_changed = function(net, key, cid, added)
	local c = cache[net]
	if not c then return end
	if net.order_dirty or c.order ~= net.order or not c.at[cid] or not net.cells[cid] then
		c.hs[key], c.hr[key], c.xs[key] = nil, nil, nil
		return
	end
	cmp_net = net
	for _, spec in ipairs(HOLDER_LISTS) do
		local field, less, cursors = spec[1], spec[2], spec[3]
		local l = c[field][key]
		if l and not c.read[field][key] then
			c[field][key] = nil                             -- (not read since its last change: sorted at the next use)
		elseif l then
			c.read[field][key] = nil
			local pos = lower_bound(c, l, cid, less)
			local copy, n = {}, #l
			if added then
				for i = 1, pos - 1 do copy[i] = l[i] end
				copy[pos] = cid
				for i = pos, n do copy[i + 1] = l[i] end
			elseif l[pos] == cid then
				for i = 1, pos - 1 do copy[i] = l[i] end
				for i = pos + 1, n do copy[i - 1] = l[i] end
			else
				copy = nil                                  -- (not in the list: made from the index again)
			end
			c[field][key] = copy
			for _, cf in ipairs(cursors) do
				local e = c[cf][key]
				if e and e.list == l then
					if not copy then e.list, e.i = nil, 1
					else
						e.list = copy
						if added and pos < e.i then e.i = pos
						elseif not added and pos < e.i then e.i = e.i - 1 end
					end
				end
			end
		end
	end
	cmp_net = nil
end

--- Issue #59 (tests): every kept holder list of every network against the list sorted anew from the index, and every holder
--- cursor on a kept list against its rule (the entries before it are internal cells that cannot take the key, or partitioned
--- ones for the walks that skip them). Returns the number of lists, the number that differ and the first problem.
function M.check_holder_lists()
	local s = storage.fork_me_net
	local lists, bad, first = 0, 0, nil
	local SKIPS = { hfs = true, hfr = true, hrr = false }
	for _, net in pairs(s and s.nets or {}) do
		local c = cache[net]
		if c and c.order == net.order and not net.order_dirty then
			cmp_net = net
			for _, spec in ipairs(HOLDER_LISTS) do
				local field, less, cursors = spec[1], spec[2], spec[3]
				for key, l in pairs(c[field]) do
					lists = lists + 1
					local fresh = {}
					for cid in pairs(net.index[key] or EMPTY) do fresh[#fresh + 1] = cid end
					table.sort(fresh, function(a, b) return less(c, a, b) end)
					local same = #fresh == #l
					for i = 1, #l do if l[i] ~= fresh[i] then same = false end end
					if not same then
						bad = bad + 1
						first = first or (field .. " " .. key .. ": " .. table.concat(l, ",") .. " against " .. table.concat(fresh, ","))
					end
					for _, cf in ipairs(cursors) do
						local e = c[cf][key]
						if e and e.list == l and e.gen == room_gen then
							for i = 1, math.min(e.i - 1, #l) do
								local cell = net.cells[l[i]]
								local skip = cell and not cell.ext and not cell.void
									and ((SKIPS[cf] and cell.partition) or cell_room(cell, cell_spec(cell.name), key) <= 0)
								if not skip then
									bad = bad + 1
									first = first or (cf .. " " .. key .. ": entry " .. i .. " (" .. tostring(l[i]) .. ") before the cursor " .. e.i)
									break
								end
							end
						end
					end
				end
			end
			cmp_net = nil
		end
	end
	return lists, bad, first
end

--- The first holder of `key` in the list `l` (`field`: the cursors of the sorted list "hfs" or of the ranked list "hfr")
--- that may still take some of it. An insert used to walk every cell that holds the key, the full ones first (28 of them
--- per insert in the 20 000 scene, 55 % of the interface and bus time); the full internal cells at the front are
--- skipped for good here, until an extraction frees room in one of them (reopen). An external cell (a storage bus,
--- whose room is the chest's) and a cell that destroys overflow are never skipped. `skips_partition`: the walk that
--- uses the cursor ignores partitioned cells (the insert's ranked walk), so they are skipped whatever their room (the
--- room count of room_for needs them). The cursor belongs to the list it was made for and to the generation of the
--- cards; it is reused for the next list of the key, so it makes no garbage.
local function first_holder(net, c, key, l, field, skips_partition)
	local fh = c[field]
	local e = fh[key]
	if not e then
		e = { list = l, i = 1, gen = room_gen }
		fh[key] = e
	elseif e.list ~= l or e.gen ~= room_gen then
		e.list, e.i, e.gen = l, 1, room_gen
	end
	local i, n = e.i, #l
	local cells = net.cells
	while i <= n do
		local cell = cells[l[i]]
		if cell.ext or cell.void then break end
		if not (skips_partition and cell.partition) and cell_room(cell, cell_spec(cell.name), key) > 0 then break end
		i = i + 1
	end
	e.i = i
	return i
end

--- the position of the cell `cid` in the holder list `l` of a cursor field (the list is sorted by cell id for "hfs", by
--- rank for the others), 0 when it is not in it
local function holder_pos(c, field, l, cid)
	local lo, hi = 1, #l
	if field == "hfs" then
		while lo <= hi do
			local mid = math.floor((lo + hi) / 2)
			local v = l[mid]
			if v == cid then return mid end
			if v < cid then lo = mid + 1 else hi = mid - 1 end
		end
		return 0
	end
	local at = c.at[cid]
	if not at then return 0 end
	local rank = at.rank
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		local v = l[mid]
		if v == cid then return mid end
		if c.at[v].rank < rank then lo = mid + 1 else hi = mid - 1 end
	end
	return 0
end

--- an extraction freed bytes or a type of a cell: it may take new keys again, and the keys it holds again. `had_room`
--- (issue #115): the cell had free bytes before and no Equal Distribution Card, so it could take more of every key it holds
--- (a held key's room is at least a byte's items then): no cursor of those keys stands behind it, and the walk over its keys
--- (up to 63, three cursors each) is not needed
local function reopen(net, cid, had_room)
	local c = cache[net]
	if not c then return end
	local cell = net.cells[cid]
	if cell and not had_room then
		for key in pairs(cell.items) do
			for _, field in ipairs(HOLDER_CURSORS) do
				local e = c[field][key]
				if e and e.i > 1 then
					local pos = holder_pos(c, field, e.list, cid)
					if pos > 0 and pos < e.i then e.i = pos end
				end
			end
		end
	end
	local at = c.order == net.order and not net.order_dirty and c.at[cid]
	if at and at.kind and at.pos < at.g.first[at.kind] then at.g.first[at.kind] = at.pos end
end

--- Items of `key` the network can take; with `want` it stops counting once it has found that much. A cell that
--- destroys what it cannot store (issue #17) takes everything.
local function room_for(net, key, want)
	local n = 0
	local c = lookups(state(), net)
	local hl = holders(net, c, key, true)                       -- in insertion order: cells before storage buses
	for i = first_holder(net, c, key, hl, "hrr", false), #hl do
		local cell = net.cells[hl[i]]
		if cell.void and voids(cell, key) then return want or math.huge end
		n = n + room_in(cell, key)
		if want and n >= want then return n end
	end
	local kind = is_fluid_key(key) and "fluid" or "item"
	local fname = c.fuzzy and name_of_key(key)
	local alt = alt_key(key)                                     -- issue #159: the other fluid filter that takes the key
	for _, g in ipairs(c.groups) do
		for _, cid in ipairs(g.parts[key] or EMPTY) do
			local cell = net.cells[cid]
			if not cell.items[key] then
				if cell.void and voids(cell, key) then return want or math.huge end
				n = n + room_in(cell, key)
				if want and n >= want then return n end
			end
		end
		for _, cid in ipairs(alt and g.parts[alt] or EMPTY) do
			local cell = net.cells[cid]
			if not cell.items[key] then
				if cell.void and voids(cell, key) then return want or math.huge end
				n = n + room_in(cell, key)
				if want and n >= want then return n end
			end
		end
		for _, cid in ipairs(fname and g.fparts[fname] or EMPTY) do    -- a fuzzy whitelist (issue #17)
			local cell = net.cells[cid]
			if not cell.items[key] then
				if cell.void and voids(cell, key) then return want or math.huge end
				n = n + room_in(cell, key)
				if want and n >= want then return n end
			end
		end
		local list = g.cells[kind]
		local i = g.first[kind]
		while list[i] do                                         -- closed cells at the front: no room for a new key
			local cell = net.cells[list[i]]
			if open_cell(cell, cell_spec(cell.name)) then break end
			i = i + 1
		end
		g.first[kind] = i
		for k = i, #list do
			local cell = net.cells[list[k]]
			if not cell.items[key] then
				if cell.void and voids(cell, key) then return want or math.huge end
				n = n + cell_room(cell, cell_spec(cell.name), key)
				if want and n >= want then return n end
			end
		end
		for _, cid in ipairs(g.ext[kind]) do
			local cell = net.cells[cid]
			if not cell.items[key] then
				if cell.void and voids(cell, key) then return want or math.huge end
				n = n + room_in(cell, key)
				if want and n >= want then return n end
			end
		end
	end
	return n
end

--- the insertion in progress (insert_key; module-level instead of closures, so an insert makes no garbage); `void`:
--- what cells with an Overflow Destruction Card destroyed of it (issue #17)
local ins = { net = nil, key = nil, left = 0, data = nil, s = nil, void = 0, skip = nil }

--- Issue #17: the rest of the insert is destroyed by `cell`. Counted on the cell (its window) and per key for the map
--- (storage.fork_me_net.voided: the conservation checks of the tests add it).
local function void_rest(cell)
	local n, key, s = ins.left, ins.key, ins.s
	cell.voided = (cell.voided or 0) + n
	s.voided = s.voided or {}
	s.voided[key] = (s.voided[key] or 0) + n
	ins.void = ins.void + n
	ins.left = 0
end

--- into one cell; true when nothing is left
local function put(cid)
	local net, key = ins.net, ins.key
	local cell = net.cells[cid]
	if cell.ext then                               -- external cell: into the real storage, then the snapshot
		if ins.data then return false end          -- items with tags only go into cells
		if ins.skip and ins.skip(cell) then return false end   -- (issue #531: a storage the caller leaves out)
		if cell.full and cell.full[key] then return false end
		local want = is_fluid_key(key) and ins.left or math.floor(ins.left)
		local n = M.ext_handlers[cell.handler or cell.ext].insert(cell, key, want)
		local void = n < want and cell.void and voids(cell, key)
		if n < want and not void then              -- no more room for the key: not asked again until its next read
			cell.full = cell.full or {}
			cell.full[key] = true
		end
		if n > 0 then
			if not cell.hidden then
				cell.items[key] = (cell.items[key] or 0) + n
				net.items[key] = (net.items[key] or 0) + n
				idx_add(net, key, cid)
			end
			ins.left = ins.left - n
			if ins.left < ZERO then ins.left = 0 end
		end
		if void and ins.left > 0 then void_rest(cell) end
		return ins.left <= 0
	end
	local spec = cell_spec(cell.name)
	local n = math.min(ins.left, cell_room(cell, spec, key))
	if n > 0 then
		local db, dt = cell_add(cell, spec, key, n)
		if ins.data and not cell.data[key] then cell.data[key] = ins.data end
		local p = fluid_cell(spec) and "f" or ""
		net[p .. "bytes"], net[p .. "types"] = net[p .. "bytes"] + db, net[p .. "types"] + dt
		net.items[key] = (net.items[key] or 0) + n
		idx_add(net, key, cid)
		ins.left = ins.left - n
		if ins.left < ZERO then ins.left = 0 end
		mark_drive(ins.s, cid_unit(cid))
	end
	if cell.void and ins.left > 0 and voids(cell, key, ins.data) then void_rest(cell) end
	return ins.left <= 0
end

--- pass 3 of group `g`: the unpartitioned cells of `kind` without the key, from the first that may take a new key
--- (closed cells at the front are skipped for good, until an extraction opens one); true when nothing is left
local function put_open(net, g, kind, key)
	local list = g.cells[kind]
	local i = g.first[kind]
	while list[i] do
		local cell = net.cells[list[i]]
		if open_cell(cell, cell_spec(cell.name)) then break end
		i = i + 1
	end
	g.first[kind] = i
	for k = i, #list do
		local cid = list[k]
		if not net.cells[cid].items[key] and put(cid) then return true end
	end
	return false
end

--- Store up to `count` of `key`. Order (R3, docs/ME-REWORK.md "Partitions and priorities"): drives of higher
--- priority first; within one priority the cells partitioned for the key first, then the cells that hold it,
--- then any cell with room (a partitioned cell only takes its keys). Issue #5: the passes use the lookups of the
--- network instead of walking every cell.
--- Issue #531: `skip(cell)`, when given, leaves out each external cell it returns true for (the ME Logistic Interface's
--- pull-in never goes into an ME Logistic Storage Bus of its own logistic network).
local function insert_key(net, key, count, data, skip)
	if count <= 0 then return 0 end
	if net.chest then return CH.store(net, key, count, data) end   -- (issue #229: into the ME Chest's cell only)
	local s = state()
	ins.net, ins.key, ins.left, ins.data, ins.s, ins.void, ins.skip = net, key, count, data, s, 0, skip
	local c = lookups(s, net)
	local kind = is_fluid_key(key) and "fluid" or "item"
	if net.uniform then                                -- one priority, no partition: the cells that hold it first
		local hl = holders(net, c, key, false)
		for i = first_holder(net, c, key, hl, "hfs", true), #hl do
			if put(hl[i]) then break end
		end
		if ins.left > 0 and c.groups[1] then put_open(net, c.groups[1], kind, key) end
	else
		local hr = holders(net, c, key, true)
		local h = first_holder(net, c, key, hr, "hfr", true)
		local fname = c.fuzzy and name_of_key(key)
		--- Issue #193, AE2-Unofficial's sticky pass (NetworkInventoryHandler.injectItems; written anew): before the priorities, the
		--- storage with a Sticky Card that holds the key or is partitioned for it gets it; when there is such a storage the insert
		--- ends there (what it cannot take is not stored elsewhere, as in AE2). A network without a sticky storage skips this.
		local groups = c.groups
		if c.sticky then
			local found = false
			local index = net.index[key]
			for _, cid in ipairs(c.sticky) do
				if ins.left <= 0 then break end
				local cell = net.cells[cid]
				local p = cell.partition
				local listed = p and (p[key] or (cell.fnames and fname and cell.fnames[fname]))
				local holds = not p and index and index[cid] and not (cell.deny and cell.deny[key])
				if listed or holds then
					found = true
					local full = cell.full
					if not (full and full[key]) then put(cid) end
				end
			end
			if found then groups = EMPTY end
		end
		for _, g in ipairs(groups) do
			if ins.left <= 0 then break end
			--- 1: partitioned for the key. Issue #115: a storage bus marked full for the key (until its next read) refuses it at
			--- once in put; at 20 000 ten of eleven calls per insert were such, so the test is made here without the call
			local cells = net.cells
			for _, cid in ipairs(g.parts[key] or EMPTY) do
				local full = cells[cid].full
				if not (full and full[key]) and put(cid) then break end
			end
			local alt = ins.left > 0 and alt_key(key)                    -- 1: the other fluid filter of the key (issue #159)
			if alt then
				for _, cid in ipairs(g.parts[alt] or EMPTY) do
					local full = cells[cid].full
					if not (full and full[key]) and put(cid) then break end
				end
			end
			if fname and ins.left > 0 then                                -- 1: a fuzzy whitelist (issue #17)
				for _, cid in ipairs(g.fparts[fname] or EMPTY) do
					local full = cells[cid].full
					if not (full and full[key]) and put(cid) then break end
				end
			end
			while hr[h] and c.at[hr[h]].g == g do                         -- 2: the cells that hold it
				local cid = hr[h]
				h = h + 1
				if ins.left <= 0 then break end                           -- (nothing left: the rest of the walk does nothing)
				if not net.cells[cid].partition then put(cid) end
			end
			if ins.left > 0 and not put_open(net, g, kind, key) then     -- 3: any cell, then storage buses
				for _, cid in ipairs(g.ext[kind]) do
					if not net.cells[cid].items[key] and put(cid) then break end
				end
			end
		end
	end
	local left = ins.left
	ins.net, ins.data, ins.skip = nil, nil, nil
	if left + ins.void < count then moved_key(net, key, true) end   -- something was stored (not only destroyed)
	return count - left
end

--- Issue #479: can no storage of the network ever take `key`, whatever room it had? `data`: the key is an item with data (tags,
--- a description, a health), which only cells take (put). A storage may take the key by its kind, filter and mode: a cell of the
--- key's kind (item or fluid) whose partition, blacklist or group filter lets it in (a creative cell only what it lists), a
--- storage bus that is not read only, whose filter lets it in and whose handler can hold such a key (its `takes`, when it has
--- one). Room, the sticky pass and the ME Chest (its own cell) are not looked at: false there. The answer is kept per key in the
--- network's lookups, which are made again when a storage, a priority, a partition or a mode changes (never saved).
function M.never_stores(net, key, data)
	if net.chest or not M.usable(net) then return false end
	local c = lookups(state(), net)
	local never = c.never
	if not never then
		never = {}
		c.never = never
	end
	local v = never[key]
	if v ~= nil then return v end
	v = true
	local fluid = is_fluid_key(key)
	local cells = net.cells
	for _, o in ipairs(c.order) do
		local cell = cells[o.cid]
		if cell then
			if cell.ext then
				if not data and cell.mode ~= "read" and accepts(cell, key) then
					local h = M.ext_handlers[cell.handler or cell.ext]
					if not (h and h.takes) or h.takes(cell, key) then v = false break end
				end
			else
				local spec = cell_spec(cell.name)
				if spec and fluid_cell(spec) == fluid and accepts(cell, key) and not (spec.creative and not cell.partition) then
					v = false
					break
				end
			end
		end
	end
	never[key] = v
	return v
end

--- the extraction order of `key`: lower priority first, storage buses before cells of the same priority,
--- unpartitioned before partitioned, then by cell id
local function extract_order(s, net, c, key)
	c.read.xs[key] = true
	local l = c.xs[key]
	if l then return l end
	l = {}
	local n = 0
	for cid in pairs(net.index[key] or EMPTY) do
		local cell = net.cells[cid]
		n = n + 1
		l[n] = cid
		XO_P[cid], XO_E[cid], XO_X[cid] = cell_priority(s, net, cid), cell.ext and 0 or 1, cell.partition and 1 or 0
	end
	table.sort(l, by_extraction)
	for i = 1, n do
		local cid = l[i]
		XO_P[cid], XO_E[cid], XO_X[cid] = nil, nil, nil
	end
	c.xs[key] = l
	return l
end

--- (`skip(cell)`, issue #537: an external cell it returns true for is left out, as insert_key's)
local function extract_key(net, key, count, skip)
	if count <= 0 or not net.items[key] then return 0 end
	if net.chest then return CH.take(net, key, count) end          -- (issue #229: out of the ME Chest's cell only)
	local s = state()
	local left = count
	--- extraction is the reverse of insertion: lower drive priority first, storage buses before cells of the same
	--- priority, unpartitioned before partitioned
	local c = lookups(s, net)
	local kept = 0                                     -- (issue #441: what creative cells gave; their counts stay)
	for _, cid in ipairs(extract_order(s, net, c, key)) do
		if left <= 0 then break end
		local cell = net.cells[cid]
		if skip and cell.ext and skip(cell) then
		elseif cell.creative then                      -- issue #441: a creative cell gives the rest without end
			kept = kept + left
			left = 0
		elseif cell.ext then                           -- external cell: the real storage first (staleness)
			local handler = M.ext_handlers[cell.handler or cell.ext]
			local real = handler.count(cell, key)
			if real ~= (cell.items[key] or 0) then ext_set(net, cid, cell, key, real) end
			local n = math.min(left, real)
			local got = n > 0 and handler.extract(cell, key, n) or 0
			if got > 0 then
				cell.full = nil
				cell.items[key] = real - got > ZERO and (real - got) or nil   -- net.items: below, with the others
				if not cell.items[key] then idx_del(net, key, cid) end
				left = left - got
				if left < ZERO then left = 0 end
				if not cell.items[key] and handler.emptied then handler.emptied(cell, key) end
			end
		else
			local n = math.min(left, cell.items[key] or 0)
			if n > 0 then
				local spec = cell_spec(cell.name)
				local had_room = not cell.eq and spec.bytes - cell.bytes > 0
				local db, dt = cell_add(cell, spec, key, -n)
				local p = fluid_cell(spec) and "f" or ""
				net[p .. "bytes"], net[p .. "types"] = net[p .. "bytes"] + db, net[p .. "types"] + dt
				left = left - n
				if left < ZERO then left = 0 end
				if not cell.items[key] then idx_del(net, key, cid) end
				if (db < 0 or dt < 0) and not cell.partition then reopen(net, cid, had_room) end
				if dt < 0 and net.wait_room then fire_units(net, "wait_room") end
				mark_drive(s, cid_unit(cid))
			end
		end
	end
	local now = (net.items[key] or 0) - (count - left) + kept
	net.items[key] = now > ZERO and now or nil
	if net.index[key] and next(net.index[key]) == nil then net.index[key] = nil end
	if left < count then
		if net.wait_room then net.room_pending = true end           -- (room may have appeared: the slow step wakes them)
		moved_key(net, key, false)
	end
	return count - left
end

--- data of a key with data in the network: an item with tags' { tags, description }, a damaged item's { health, description }
--- (the damage text) or, issue #481, a damaged item with tags' { tags, description, health }
local function data_of(net, key)
	if net.chest then return CH.data(net, key) end
	for cid in pairs(net.index[key] or {}) do
		local d = net.cells[cid].data
		if d and d[key] then return d[key] end
	end
	return nil
end

--- the amount of `key` a job waiting for it takes (see M.on_arrival)
local function arrive(net, key, count)
	if M.no_arrival or not M.on_arrival or count <= 0 then return 0 end
	return M.on_arrival(net, key, count) or 0
end

--- what jobs still wait for of `key` (room for an arrival beyond the cells' room)
local function awaited(net, key)
	if M.no_arrival or not M.awaiting then return 0 end
	return M.awaiting(net, key) or 0
end

--- the public API: plain items by name and quality; nothing happens when the network does not work (`skip`: insert_key's)
function M.insert(net, name, quality, count, skip)
	if not (M.usable(net) and item_exists(name)) then return 0 end
	local key = key_of(name, quality)
	count = math.floor(count)
	local claimed = arrive(net, key, count)
	return claimed + insert_key(net, key, count - claimed, nil, skip)
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

--- issue #537: the count of `key` without the external cells `skip(cell)` returns true for (their snapshot)
function M.count_key_skip(net, key, skip)
	local n = M.count_key(net, key)
	if n <= 0 then return 0 end
	for cid in pairs(net.index and net.index[key] or {}) do
		local cell = net.cells[cid]
		if cell and cell.ext and skip(cell) then n = n - (cell.items[key] or 0) end
	end
	return n > 0 and n or 0
end

function M.can_insert(net, name, quality, count)
	if not M.usable(net) then return 0 end
	local key = key_of(name, quality)
	count = math.floor(count)
	return math.min(count, room_for(net, key, count) + awaited(net, key))
end

--- the items: { { key, name, quality, count, data } }, unsorted (fluids: fluid_contents)
function M.contents(net)
	local out = {}
	if not M.usable(net) then return out end
	for key, count in pairs(net.items) do
		if not is_fluid_key(key) then
			local name, q, json = parse_key(key)
			out[#out + 1] = { key = key, name = name, quality = q, count = count, special = json ~= nil }
		end
	end
	return out
end

--- totals of plain normal quality items { name -> count } (autocrafting stock)
function M.plain_counts(net)
	local out = {}
	if not M.usable(net) then return out end
	for key, count in pairs(net.items) do
		if not (key:find("[@#]") or is_fluid_key(key)) then out[key] = count end
	end
	return out
end

--- The fluid API: amounts may be fractional. Issue #159: a fluid is stored per temperature (fluid_key); `temperature`
--- nil is the fluid's default temperature (the calls of before keep working), a number its key (whole degrees).
function M.insert_fluid(net, name, amount, temperature)
	if not (M.usable(net) and prototypes.fluid[name] and amount and amount > 0) then return 0 end
	local key = fluid_key(name, temperature)
	local claimed = arrive(net, key, amount)
	if claimed >= amount then return amount end
	return claimed + insert_key(net, key, amount - claimed)
end

function M.extract_fluid(net, name, amount, temperature)
	if not (M.usable(net) and amount and amount > 0) then return 0 end
	return extract_key(net, fluid_key(name, temperature), amount)
end

function M.fluid_count(net, name, temperature)
	if not M.usable(net) then return 0 end
	return net.items[fluid_key(name, temperature)] or 0
end

function M.can_insert_fluid(net, name, amount, temperature)
	if not M.usable(net) then return 0 end
	local key = fluid_key(name, temperature)
	return math.min(amount, room_for(net, key, amount) + awaited(net, key))
end

--- the same by storage key ("fluid/<name>" or "fluid/<name>@<degrees>")
function M.insert_fluid_key(net, key, amount)
	if not (M.usable(net) and amount and amount > 0 and is_fluid_key(key) and prototypes.fluid[(split_fluid_key(key))]) then return 0 end
	local claimed = arrive(net, key, amount)
	if claimed >= amount then return amount end
	return claimed + insert_key(net, key, amount - claimed)
end

function M.extract_fluid_key(net, key, amount)
	if not (M.usable(net) and amount and amount > 0) then return 0 end
	return extract_key(net, key, amount)
end

function M.can_insert_fluid_key(net, key, amount)
	if not M.usable(net) then return 0 end
	return math.min(amount, room_for(net, key, amount) + awaited(net, key))
end

--- Issue #386 (the ME IO Port, scripts/fork-me-ioport.lua): a cell record that lies in no drive (`cell`, from
--- M.cell_from_stack) and the network. Up to `count` of `key` from the cell into the network (with its data, as a stored
--- item of a cell keeps it); returns what went, which the cell no longer holds.
function M.cell_to_network(net, cell, key, count)
	local have = cell.items[key] or 0
	if count > have then count = have end
	if not is_fluid_key(key) then count = math.floor(count) end
	if count <= 0 or not M.usable(net) then return 0 end
	local claimed = arrive(net, key, count)
	local n = claimed + insert_key(net, key, count - claimed, cell.data and cell.data[key])
	if n > 0 then cell_add(cell, cell_spec(cell.name), key, -n) end
	return n
end

--- Up to `count` of `key` from the network into the cell record: what its room and partition (its cards) let in. Returns
--- what went.
function M.network_to_cell(net, cell, key, count)
	if not M.usable(net) then return 0 end
	local spec = cell_spec(cell.name)
	local n = math.min(count, cell_room(cell, spec, key), net.items[key] or 0)
	if not is_fluid_key(key) then n = math.floor(n) end
	if n <= 0 then return 0 end
	local data = key:find("#", 1, true) and data_of(net, key) or nil
	local got = extract_key(net, key, n)
	if got > 0 then
		cell_add(cell, spec, key, got)
		if data then
			cell.data = cell.data or {}
			cell.data[key] = data
		end
	end
	return got
end

--- what of `key` the cell record can still take (issue #386: the IO port asks before it goes through the network's keys)
function M.cell_room(cell, key) return cell_room(cell, cell_spec(cell.name), key) end

--- what the network holds of fluid `name` at every temperature, or of those a filter key takes
function M.fluid_total(net, name, filter)
	if not M.usable(net) then return 0 end
	local items, n = net.items, 0
	for _, key in ipairs(M.fluid_keys(net, name)) do
		local a = items[key]
		if a and (not filter or fluid_matches(filter, key)) then n = n + a end
	end
	return n
end

--- { fluid name -> amount } (every temperature of a fluid added up)
function M.fluid_contents(net)
	local out = {}
	if not M.usable(net) then return out end
	for key, amount in pairs(net.items) do
		if is_fluid_key(key) then
			local name = split_fluid_key(key)
			out[name] = (out[name] or 0) + amount
		end
	end
	return out
end

--- { storage key -> amount } of the fluids (one entry per temperature)
function M.fluid_key_contents(net)
	local out = {}
	if not M.usable(net) then return out end
	for key, amount in pairs(net.items) do
		if is_fluid_key(key) then out[key] = amount end
	end
	return out
end

--- Issue #149: the rows of the power breakdown, biggest first: { key (a kind, or a crafting block's entity name), entity (true
--- for the latter), n (blocks), w (watts in all), per (watts of one block) }; their `w` add up to the network's power.
local function power_rows(net)
	if not net.power_by then update_power(state(), net) end    -- (a save from before the breakdown)
	local rows = {}
	for key, row in pairs(net.power_by) do
		rows[#rows + 1] = { key = key, entity = row.entity, n = row.n, w = row.w, per = row.w / row.n }
	end
	table.sort(rows, function(a, b)
		if a.w ~= b.w then return a.w > b.w end
		return a.key < b.key
	end)
	return rows
end

function M.stats(net)
	local ok, why = M.usable(net)
	local drives, cells, fcells, buses, fbuses = 0, 0, 0, 0, 0
	for _ in pairs(net.drives) do drives = drives + 1 end
	for _, cid in ipairs(M.cell_ids(net)) do
		local cell = net.cells[cid]
		local spec = not cell.ext and cell_spec(cell.name)
		if cell.side == "fluid" or cell.ext == "fluid-storage-bus" then fbuses = fbuses + 1   -- a storage bus on fluid
		elseif cell.ext then buses = buses + 1
		elseif spec and fluid_cell(spec) then fcells = fcells + 1 else cells = cells + 1 end
	end
	return { ok = ok, status = ok and "ok" or why, bytes = net.bytes, bytes_total = net.bytes_total,
		types = net.types, types_total = net.types_total, drives = drives, cells = cells, power = net.power,
		power_rows = power_rows(net),
		fbytes = net.fbytes or 0, fbytes_total = net.fbytes_total or 0, ftypes = net.ftypes or 0,
		ftypes_total = net.ftypes_total or 0, fluid_cells = fcells, storage_buses = buses,
		fluid_storage_buses = fbuses, members = net.n, id = net.id }
end

--- What the network does with an item, by its prototype type (issue #76). `stack.item` is no test for "carries data of
--- its own": every stack with a state has a LuaItem (a tool, ammo, a repair tool, armour, a planner, an item that spoils or
--- is damaged), and refusing all of them kept science packs, magazines and repair packs out for as long as there was a
--- network. "plain": nothing of its own (a gun, a capsule, a module, a rail planner, a platform starter pack). "worn": a
--- tool, ammo or repair tool, stored whole and never used (a stack holds one wear: its top item's, and taking an item out
--- of a stack takes the used one first, so a count says nothing about it). "tags": an item with tags, kept with its tags and
--- description. "label": a label type, kept when it has no label. Anything else carries data the network cannot keep and
--- is refused; the value is the reason, the suffix of the locale key [fork-me-net] error-<reason>, one for each kind of
--- thing so that the message names it. A type this table does not know (a new one of a later version) is refused as
--- "cannot-store": storing it plain would drop what it carries without a word.
local ITEM_CLASS = {
	["item"] = "plain", ["gun"] = "plain", ["capsule"] = "plain", ["module"] = "plain", ["rail-planner"] = "plain",
	["space-platform-starter-pack"] = "plain",
	["tool"] = "worn", ["ammo"] = "worn", ["repair-tool"] = "worn",
	["item-with-tags"] = "tags", ["item-with-label"] = "label",
	["blueprint"] = "cannot-store-blueprint", ["blueprint-book"] = "cannot-store-blueprint",
	["deconstruction-item"] = "cannot-store-planner", ["upgrade-item"] = "cannot-store-planner",
	["selection-tool"] = "cannot-store-planner", ["copy-paste-tool"] = "cannot-store-planner",
	["spidertron-remote"] = "cannot-store-remote", ["item-with-entity-data"] = "cannot-store-entity",
	["armor"] = "cannot-store-armor", ["item-with-inventory"] = "cannot-store-inventory",
}

--- the class of an item prototype type (see ITEM_CLASS)
function M.item_class(proto_type) return ITEM_CLASS[proto_type] or "cannot-store" end

--- Can a stack of this item be damaged (issue #84)? The stack of an item that places an entity (a mined wall, belt or
--- chest: rails too) carries the entity's health, below 1 when it was damaged. A damaged stack does not merge with whole
--- ones, but a count and a removal by count do not tell them apart, so the paths that move such items by count walk the
--- stacks (remove_whole) when they take items out. Decided per prototype (static), never saved.
function M.can_be_damaged(proto)
	return proto.place_result ~= nil or proto.type == "rail-planner"
end

--- is the top item of this stack used up in part (a tool, a repair tool or ammo) or damaged? `proto`: its prototype.
--- The test of a stack with its wear: a full item has the durability or the magazine its prototype says (a quality scales
--- the durability, not the magazine).
local function is_used(stack, proto)
	if stack.health < 1 then return true end
	local t = proto.type
	if t == "ammo" then return stack.ammo < proto.magazine_size end
	if t == "tool" or t == "repair-tool" then
		local full = proto.get_durability(stack.quality)
		return full ~= nil and stack.durability < full
	end
	return false
end

--- Issue #479: does this stack stand for the plain key of its item (the key N.storable gives it)? Not when its top item is used
--- or damaged, nor when an item with tags or a label carries a label, tags or a description of its own: N.storable keys those
--- apart, and a count or a removal by count cannot tell them from the plain ones. Read per stack, since the prototype type does
--- not decide it (Quality Turrets Reworked makes every turret an item with tags, and only the mined veterans carry tags).
--- (A field, not a local: the main chunk is at the limit of 200 locals.)
function M.plain_stack(stack, proto)
	if is_used(stack, proto) then return false end
	local class = ITEM_CLASS[proto.type]
	if class == "tags" then
		if stack.label then return false end
		local tags = stack.tags
		if tags and next(tags) then return false end
		local desc = stack.custom_description
		return desc == nil or desc == ""
	elseif class == "label" then
		return stack.label == nil
	end
	return true
end

--- the items of `name` and `quality` in whole stacks of an inventory (a worn type: the stacks whose top item is not used; an
--- item with tags or a label, issue #479: the stacks that carry nothing, M.plain_stack)
function M.count_whole(inv, name, quality)
	local n = 0
	for i = 1, #inv do
		local stack = inv[i]
		if stack.valid_for_read and stack.name == name and stack.quality.name == quality and M.plain_stack(stack, stack.prototype) then
			n = n + stack.count
		end
	end
	return n
end

--- is there a stack of `name` and `quality` in the inventory whose top item is used? (new items merge into it)
function M.has_used(inv, name, quality)
	for i = 1, #inv do
		local stack = inv[i]
		if stack.valid_for_read and stack.name == name and stack.quality.name == quality and is_used(stack, stack.prototype) then return true end
	end
	return false
end

--- Take up to `count` items of `name` and `quality` out of the whole stacks of an inventory, never out of a used one: a
--- removal by count (LuaInventory.remove) takes the used item first and would hand it on as a full one. Nor out of a stack
--- with tags, a label or a description (issue #479, M.plain_stack): it would leave as a plain item. Returns the count.
function M.remove_whole(inv, name, quality, count)
	local left = count
	for i = 1, #inv do
		if left <= 0 then break end
		local stack = inv[i]
		if stack.valid_for_read and stack.name == name and stack.quality.name == quality and M.plain_stack(stack, stack.prototype) then
			local take = math.min(left, stack.count)
			if take >= stack.count then stack.clear() else stack.count = stack.count - take end
			left = left - take
		end
	end
	return count - left
end

--- { key -> count } of the items of a worn type, of the items that can be damaged (issue #84) and of the items with tags or a
--- label (issue #479), in the stacks of an inventory that stand for their plain key (one pass; M.plain_stack: a stack whose top
--- item is used or damaged, or that carries tags, a label or a description, counts as none)
function M.whole_counts(inv)
	local out = {}
	for i = 1, #inv do
		local stack = inv[i]
		if stack.valid_for_read then
			local proto = stack.prototype
			local class = ITEM_CLASS[proto.type]
			if (class == "worn" or class == "tags" or class == "label" or M.can_be_damaged(proto)) and M.plain_stack(stack, proto) then
				local key = key_of(stack.name, stack.quality.name)
				out[key] = (out[key] or 0) + stack.count
			end
		end
	end
	return out
end

--- is `reason` (from storable, insert_stack) a refusal of this one stack, as opposed to a network that takes nothing
function M.refuses_stack(reason)
	return reason ~= nil and reason:sub(1, 12) == "cannot-store"
end

--- Issue #115: what M.storable reads of an item's prototype, once per item name and load (a stack's `prototype` and the
--- spoil ticks are engine calls that make new objects): the prototype, its class, whether it spoils (a quality scales the
--- spoil time, so an item that does not spoil at normal quality spoils at none), whether a stack of it can be damaged
local item_facts_cache = {}
local function item_facts(stack)
	local name = stack.name
	local f = item_facts_cache[name]
	if not f then
		local proto = stack.prototype
		f = { proto = proto, class = ITEM_CLASS[proto.type] or "cannot-store", spoils = proto.get_spoil_ticks("normal") > 0,
			damageable = M.can_be_damaged(proto) }
		item_facts_cache[name] = f
	end
	return f
end

--- Why a stack cannot go into the network (a locale key suffix), or nil and its key and data
function M.storable(stack)
	if not (stack and stack.valid_for_read) then return "empty" end
	local facts = item_facts(stack)
	local proto = facts.proto
	if facts.spoils then return "cannot-store-spoil" end
	local class = facts.class
	if class ~= "plain" and class ~= "worn" and class ~= "tags" and class ~= "label" then return class end
	local tags, desc, own, label, color
	if class == "tags" then
		--- issue #485: a label is kept in the key's data beside the tags (Quality Turrets Reworked labels a turret mined with
		--- kills "<name> (N Kills)"); a stack definition cannot carry it, so M.extract_to sets it on the stack the key lands in
		label = stack.label
		if label then color = stack.label_color end
		tags, desc = stack.tags, stack.custom_description
		own = label or (tags and next(tags)) or (desc and desc ~= "")
	end
	if class == "plain" or class == "tags" then
		local health = stack.health                                       -- (the one read a plain item needs)
		if health < 1 then
			if not facts.damageable then return "cannot-store-damaged-item" end
			--- issue #102: a damaged item (a mined wall, belt, chest) is stored with its health, as a key of its own like an item
			--- with tags: its health is part of the key, the stack comes out with it. All items of a stack share one health, so
			--- a count of such a key is exact. (A partly used tool, ammo or repair tool stays refused: its wear is that of the
			--- top item only, and two stacks of the same wear would come out as one used item and the rest whole.)
			--- Issue #481: so is a damaged item with tags (Quality Turrets Reworked makes every turret one). An untagged one gets
			--- the key of a damaged plain item (`description` is the terminal's damage text); one with tags or a description of
			--- its own keeps them beside its health, and the terminal makes the damage text from the health
			--- (fork-me-gui.lua key_description); stack_def puts the description back only when it is not the damage text.
			local data = own and { tags = tags or {}, description = desc, health = health, label = label, label_color = color }
				or { health = health, description = { "fork-me-net.damaged-item", math.floor(health * 100 + 0.5) } }
			return nil, key_of(stack.name, stack.quality, helpers.table_to_json(data)), data
		end
		if own then
			local data = { tags = tags or {}, description = desc, label = label, label_color = color }
			return nil, key_of(stack.name, stack.quality, helpers.table_to_json(data)), data
		end
	elseif is_used(stack, proto) then
		return "cannot-store-damaged"
	elseif class == "label" then
		label = stack.label
		if label then                                                   -- issue #485: kept like an item with tags' label
			local data = { label = label, label_color = stack.label_color }
			return nil, key_of(stack.name, stack.quality, helpers.table_to_json(data)), data
		end
	end
	return nil, key_of(stack.name, stack.quality), nil
end

--- Store (part of) a LuaItemStack; the stack shrinks by what was stored. Returns the count, or nil and a reason.
--- (`skip`: insert_key's, issue #531)
function M.insert_stack(net, stack, skip)
	local ok, why = M.usable(net)
	if not ok then return nil, why end
	local problem, key, data = M.storable(stack)
	if problem then return nil, problem end
	local claimed = (data or net.chest) and 0 or arrive(net, key, stack.count)
	local n = claimed + insert_key(net, key, stack.count - claimed, data, skip)
	if n <= 0 then return nil, "no-storage" end
	if n >= stack.count then stack.clear() else stack.count = stack.count - n end
	return n
end

--- Store up to `max` items of a LuaItemStack (the stack shrinks). Returns the count, or nil and a reason. (`skip`: issue #531)
function M.insert_partial(net, stack, max, skip)
	local ok, why = M.usable(net)
	if not ok then return nil, why end
	local problem, key, data = M.storable(stack)
	if problem then return nil, problem end
	local want = math.min(stack.count, math.floor(max))
	local claimed = (data or net.chest) and 0 or arrive(net, key, want)
	local n = claimed + insert_key(net, key, want - claimed, data, skip)
	if n <= 0 then return nil, "no-storage" end
	if n >= stack.count then stack.clear() else stack.count = stack.count - n end
	return n
end

--- the stack definition for `count` of `key` (with the tags of an item with tags), and the key's data (nil for a plain key)
local function stack_def(net, key, count)
	local name, q = parse_key(key)
	local def = { name = name, quality = q, count = count }
	local data = key:find("#", 1, true) and data_of(net, key)        -- only items with tags and damaged items have data
	if data then
		def.tags = data.tags
		if data.health then def.health = data.health end                -- issue #102: a damaged item comes out as damaged
		--- (only an item with tags has a description of its own; the terminal shows the one in the key for the others. Issue
		--- #481: the damage text of a damaged item's key is none of the stack's, also when the item became one with tags later)
		local d = data.description
		if d and not (type(d) == "table" and d[1] == "fork-me-net.damaged-item") and prototypes.item[name].type == "item-with-tags" then
			def.custom_description = d
		end
	end
	return def, data or nil
end

--- Issue #485: put the label of a key's `data` on `stack` (set_stack of a stack definition cannot)
function M.set_label(stack, data)
	stack.label = data.label
	if data.label_color then stack.label_color = data.label_color end
end

--- Issue #485: up to `def.count` of a key with a label into `target` (as M.extract_to), each stack written into an empty slot
--- and labelled there. Never through insert: an inserted definition has no label, and an inserted stack merges into one of the
--- same label and tags whatever its health (averaging it); nor on top of a stack of the same key (the engine ignores a raised
--- count on a stack with tags, 2.1.23). Into an entity: its main inventory, else its first one (a chest's; can_set_stack keeps
--- a turret out of a furnace's fuel or a filtered slot). Returns the amount moved and { stack, count } of what went where.
function M.put_labelled(target, def, data)
	local size = prototypes.item[def.name].stack_size
	local placed = {}
	if target.object_name == "LuaItemStack" then
		if target.valid_for_read then return 0, placed end
		def.count = math.min(def.count, size)
		if not target.set_stack(def) then return 0, placed end
		M.set_label(target, data)
		placed[1] = { target, target.count }
		return target.count, placed
	end
	local inv = target
	if target.object_name ~= "LuaInventory" then
		inv = target.get_main_inventory()
		if not inv and target.object_name == "LuaEntity" then inv = target.get_inventory(defines.inventory.chest) end
		if not inv then return 0, placed end
	end
	local last = #inv
	if inv.supports_bar() then last = math.min(last, inv.get_bar() - 1) end      -- (set_stack does not stop at the bar)
	local left, total = def.count, def.count
	for i = 1, last do
		if left <= 0 then break end
		local st = inv[i]
		if not st.valid_for_read then
			def.count = math.min(left, size)
			if st.can_set_stack(def) and st.set_stack(def) then
				M.set_label(st, data)
				placed[#placed + 1] = { st, def.count }
				left = left - def.count
			end
		end
	end
	return total - left, placed
end

--- Move up to `count` of `key` into `target` (LuaPlayer, LuaEntity, LuaInventory: anything with insert, or an
--- empty LuaItemStack). Returns the amount moved. (`skip`, issue #537: external cells left out, as M.count_key_skip)
function M.extract_to(net, target, key, count, skip)
	if not M.usable(net) then return 0 end
	count = math.min(math.floor(count), skip and M.count_key_skip(net, key, skip) or net.items[key] or 0)
	if count <= 0 or not key_item_exists(key) then return 0 end
	local def, data = stack_def(net, key, count)
	if data and data.label then
		local moved, placed = M.put_labelled(target, def, data)
		if moved <= 0 then return 0 end
		local got = extract_key(net, key, moved, skip)
		local surplus = moved - got                 -- (never duplicate, as below: taken back from the stacks it wrote)
		for i = #placed, 1, -1 do
			if surplus <= 0 then break end
			local st, n = placed[i][1], placed[i][2]
			if n <= surplus then st.clear() surplus = surplus - n
			else st.count = n - surplus surplus = 0 end
		end
		return got
	end
	local moved
	if target.object_name == "LuaItemStack" then
		if target.valid_for_read then return 0 end
		local size = prototypes.item[def.name].stack_size
		def.count = math.min(def.count, size)
		if not target.set_stack(def) then return 0 end
		moved = target.count
	elseif target.object_name == "LuaInventory" then
		moved = M.bound(target).insert(def)               -- (an inventory the caller keeps: issue #115)
	else
		moved = target.insert(def)
	end
	if moved <= 0 then return 0 end
	local got = extract_key(net, key, moved, skip)
	if got < moved then                       -- a storage bus's chest had less than its snapshot: never duplicate
		local surplus = { name = def.name, quality = def.quality, count = moved - got }
		if target.object_name == "LuaItemStack" then
			if got <= 0 then target.clear() else target.count = got end
		elseif target.object_name == "LuaInventory" then target.remove(surplus)
		else target.remove_item(surplus) end
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
			position = { x = entity.position.x, y = entity.position.y }, leds = {},
			chest = kinds()[entity.name] == "chest" or nil }                  -- (issue #229: one slot, its own light)
		s.drives[unit] = d
	end
	return d
end

local function drive_net(s, unit)
	local node = s.nodes[unit]
	return node and s.nets[node.net] or nil
end

--- put a cell record into a free slot of a drive (and into its network's totals); a cell without partition takes
--- the slot's partition from a blueprint (d.slot_partition)
local function place_cell(s, d, slot, cell)
	d.slots[slot] = cell
	local template = d.slot_partition and d.slot_partition[slot]
	if template and not (cell.partition or cell.deny or cell.gkeys) then
		M.set_cell_keys(cell, template)                       -- (a cell with an Inverter Card: a blacklist)
		d.slot_partition[slot] = nil
	end
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
	if not (drive and drive.valid and CELL_KINDS[M.kind_of(drive.name)]) then return nil, "no-drive" end
	if not (stack and stack.valid_for_read and cell_spec(stack.name)) then return nil, "not-a-cell" end
	local d = drive_record(s, drive)
	if slot == nil then
		for i = 1, slots_of(drive) do
			if not d.slots[i] then slot = i break end
		end
		if not slot then return nil, "drive-full" end
	end
	if slot > slots_of(drive) then return nil, "drive-full" end
	if d.slots[slot] then return nil, "slot-taken" end
	local cell = M.cell_from_stack(stack)                   -- (issue #394: with its quality)
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
--- up to `amount` of `key` into the cells of drive record `d` (slot order), its network's totals updated;
--- returns the amount stored
local function store_key_in_drive(s, d, unit, key, amount, data)
	local net = drive_net(s, unit)
	local left = amount
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
					local p = fluid_cell(spec) and "f" or ""
					net[p .. "bytes"], net[p .. "types"] = net[p .. "bytes"] + db, net[p .. "types"] + dt
					net.items[key] = (net.items[key] or 0) + n
					idx_add(net, key, cid)
					moved_key(net, key, true)
				end
				left = left - n
				if left < ZERO then left = 0 end
			end
		end
	end
	if left < amount then mark_drive(s, unit) end
	return amount - left
end

function M.store_in_drive(drive, stack)
	local s = state()
	local d = drive and drive.valid and s.drives[drive.unit_number]
	if not d then return nil, "no-drive" end
	local problem, key, data = M.storable(stack)
	if problem then return nil, problem end
	local n = store_key_in_drive(s, d, drive.unit_number, key, stack.count, data)
	if n <= 0 then return nil, "no-storage" end
	if n >= stack.count then stack.clear() else stack.count = stack.count - n end
	return n
end

--------------------------------------------------------------------------------
--- ME CHEST (issue #229; AE2's MEChestBlockEntity). A member with one cell slot: a drive record of one slot (s.drives), so
--- its cell is network storage at its priority like a drive's. The entity is a one-slot container that inserters fill; the
--- chest empties it into its cell every tick (input only, AE2's InputInventoryFilter: what the cell refuses stays in the slot,
--- the window gives it back). On its tile: a hidden storage tank with a pipe connection on every side (a fluid cell is filled
--- from it) and a hidden electric buffer. AE2's chest draws on its network first, then on its own buffer: here the buffer draws
--- from the power grid while the chest's network does not work (a member of a working network is paid by the controller, the
--- usual 4 kW). Its own terminal works on its cell only, with or without a network (the view below; AE2: the integrated
--- terminal sees the mounted cell only). s.chests[unit] = { entity, power, tank, powered, wait }.
--------------------------------------------------------------------------------

CH.RETRY = 30                       -- ticks: the input is tried again this much later when the cell took nothing of it
CH.inv = {}                         -- unit -> the container's inventory (per load: derived from the entity)
CH.views = {}                       -- unit -> the chest's view (per load, below)
CH.NO_ITEMS = {}

function CH.names() return mod_data().chest or {} end

--- the hidden parts of a chest: found on its tile (a clone, a rebuild) or made
function CH.parts(s, entity)
	s.chests = s.chests or {}
	local unit = entity.unit_number
	local c = s.chests[unit]
	if not c then
		c = {}
		s.chests[unit] = c
	end
	c.entity = entity
	local names = CH.names()
	local function part(name)
		if not name then return nil end
		local e = entity.surface.find_entity(name, entity.position)
		if not (e and e.valid) then
			e = entity.surface.create_entity{ name = name, position = entity.position, force = entity.force,
				create_build_effect_smoke = false }
		end
		if e then e.destructible = false end
		return e
	end
	if not (c.power and c.power.valid) then c.power = part(names.power) end
	if not (c.tank and c.tank.valid) then c.tank = part(names.fluid) end
	return c
end

--- a chest left: its hidden parts go (the fluid in its tank with them)
function CH.gone(s, unit)
	local c = s.chests and s.chests[unit]
	if not c then return end
	if c.power and c.power.valid then c.power.destroy() end
	if c.tank and c.tank.valid then c.tank.destroy() end
	s.chests[unit] = nil
	CH.inv[unit] = nil
end

--- is the chest powered: its network works, or its own buffer has energy (AE2: isPowered)
function CH.powered(s, unit)
	local node = s.nodes[unit]
	local net = node and s.nets[node.net]
	if net and M.usable(net) then return true end
	local c = s.chests and s.chests[unit]
	local e = c and c.power
	return e ~= nil and e.valid and e.energy > 0
end

--- once a second (slow step): the buffer draws from the grid only while the chest's network does not work; a change of the
--- power state redraws the chest's light (dark without power, AE2's black LED)
function CH.power_step(s)
	if not s.chests then return end
	local draw = (CH.names().watts or MEMBER_POWER) / 60
	for unit, c in pairs(s.chests) do
		if c.entity and c.entity.valid then
			local node = s.nodes[unit]
			local net = node and s.nets[node.net]
			local want = (net and M.usable(net)) and 0 or draw
			local p = c.power
			if p and p.valid and p.power_usage ~= want then p.power_usage = want end
			local on = CH.powered(s, unit)
			if on ~= c.powered then
				c.powered = on
				mark_drive(s, unit)
			end
		end
	end
end

--- Every tick (control.lua): what inserters put into a chest and what pipes put into its tank goes into its cell, while the
--- chest is powered. One table walk while there is no chest.
function M.chest_tick(tick)
	local s = storage.fork_me_net
	local list = s and s.chests
	if not list or next(list) == nil then return end
	for unit, c in pairs(list) do
		local d = s.drives[unit]
		local cell = d and d.slots[1]
		local e = c.entity
		if cell and e and e.valid and not (c.wait and c.wait > tick) then
			local spec = cell_spec(cell.name)
			if spec and fluid_cell(spec) then
				local tank = c.tank
				local fb = tank and tank.valid and tank.get_fluid(1)
				if fb and CH.powered(s, unit) then
					--- (the tank's share of its fluid segment: extract_fluid takes what was stored out of the segment; setting the
					--- fluid box would empty the pipes connected to it as well)
					local key = fluid_key(fb.name, fb.temperature)
					local n = store_key_in_drive(s, d, unit, key, fb.amount)
					if n > 0 then
						local got = tank.extract_fluid{ name = fb.name, amount = n, temperature = fb.temperature }
						if got < n - ZERO then CH.take_from_drive(s, d, unit, key, n - got) end   -- (never more than came out)
					else
						c.wait = tick + CH.RETRY
					end
				end
			elseif spec then
				local inv = CH.inv[unit]
				if not (inv and inv.valid) then
					inv = e.get_inventory(defines.inventory.chest)
					CH.inv[unit] = inv
				end
				if inv and not inv.is_empty() and CH.powered(s, unit) then
					local stack = inv[1]
					local n = 0
					if stack.valid_for_read then
						local problem, key, data = M.storable(stack)
						if not problem then n = store_key_in_drive(s, d, unit, key, stack.count, data) end
						if n >= stack.count then stack.clear() elseif n > 0 then stack.count = stack.count - n end
					end
					if n <= 0 then c.wait = tick + CH.RETRY end
				end
			end
		end
	end
end

--- up to `amount` of `key` out of the cells of drive record `d` (slot order), its network's totals updated: the cell part of
--- extract_key for one drive; returns the amount taken
function CH.take_from_drive(s, d, unit, key, amount)
	local net = drive_net(s, unit)
	local left = amount
	for slot = 1, drive_slots() do
		if left <= 0 then break end
		local cell = d.slots[slot]
		local n = cell and math.min(left, cell.items[key] or 0) or 0
		if n > 0 and cell.creative then left, n = 0, 0 end     -- (issue #441: a creative cell gives without end, its count kept)
		if n > 0 then
			local spec = cell_spec(cell.name)
			local had_room = not cell.eq and spec.bytes - cell.bytes > 0
			local db, dt = cell_add(cell, spec, key, -n)
			local cid = unit .. ":" .. slot
			if net and net.cells[cid] == cell then
				local p = fluid_cell(spec) and "f" or ""
				net[p .. "bytes"], net[p .. "types"] = net[p .. "bytes"] + db, net[p .. "types"] + dt
				local now = (net.items[key] or 0) - n
				net.items[key] = now > ZERO and now or nil
				if not cell.items[key] then idx_del(net, key, cid) end
				if (db < 0 or dt < 0) and not cell.partition then reopen(net, cid, had_room) end
				if dt < 0 and net.wait_room then fire_units(net, "wait_room") end
				if net.wait_room then net.room_pending = true end
				moved_key(net, key, false)
			end
			left = left - n
			if left < ZERO then left = 0 end
		end
	end
	if left < amount then mark_drive(s, unit) end
	return amount - left
end

--- The view of a chest: stands in for a network where the terminal module takes one. M.usable, insert_key, extract_key and
--- data_of know it (`view.chest`), so insert_stack, insert_partial, extract_to, contents and the terminal's grid work on the
--- chest's cell alone. Its `items` are the cell's; its `cver` is its network's id and contents version (every change of a
--- mounted cell counts there). One per chest and load: the terminal keeps its lists per view.
function CH.view_cell(v)
	local s = storage.fork_me_net
	local d = s and s.drives[v.chest]
	return d and d.slots[1] or nil
end
CH.view_mt = { __index = function(v, k)
	if k == "items" then
		local cell = CH.view_cell(v)
		return cell and cell.items or CH.NO_ITEMS
	elseif k == "cver" then
		local s = storage.fork_me_net
		local node = s and s.nodes[v.chest]
		local net = node and s.nets[node.net]
		return net and (net.id .. ":" .. (net.cver or 0)) or "-"
	end
	return nil
end }

--- the view of a chest entity (nil for anything else)
function M.chest_view(entity)
	if not (entity and entity.valid and kinds()[entity.name] == "chest") then return nil end
	local unit = entity.unit_number
	local v = CH.views[unit]
	if not (v and v.entity == entity) then
		v = setmetatable({ chest = unit, entity = entity }, CH.view_mt)
		CH.views[unit] = v
	end
	return v
end

function CH.usable(v)
	local s = storage.fork_me_net
	if not (v.entity.valid and s and s.nodes[v.chest]) then return false, "no-network" end
	local d = s.drives[v.chest]
	if not (d and d.slots[1]) then return false, "chest-no-cell" end
	if not CH.powered(s, v.chest) then return false, "chest-no-power" end
	return true
end

function CH.store(v, key, count, data)
	local s = storage.fork_me_net
	local d = s and s.drives[v.chest]
	if not d or count <= 0 then return 0 end
	return store_key_in_drive(s, d, v.chest, key, count, data)
end

function CH.take(v, key, count)
	local s = storage.fork_me_net
	local d = s and s.drives[v.chest]
	if not d or count <= 0 then return 0 end
	return CH.take_from_drive(s, d, v.chest, key, count)
end

function CH.data(v, key)
	local cell = CH.view_cell(v)
	return cell and cell.data and cell.data[key] or nil
end

--- what the chest's window shows (and the tests read): { priority, network (its network works), powered, own (it runs on
--- its own buffer), energy, buffer, cell = { name, bytes, bytes_total, types, types_total, fluid, state }, input = { name,
--- quality, count } (what waits in the input slot), fluid = { name, amount, temperature } (in its tank) }
function M.chest_info(entity)
	local s = storage.fork_me_net
	if not (s and entity and entity.valid and kinds()[entity.name] == "chest") then return nil end
	local unit = entity.unit_number
	local c = s.chests and s.chests[unit]
	local d = s.drives[unit]
	local cell = d and d.slots[1]
	local node = s.nodes[unit]
	local net = node and s.nets[node.net]
	local net_ok = (net and M.usable(net)) and true or false
	local p = c and c.power
	local powered = CH.powered(s, unit)
	local out = { priority = d and d.priority or 0, network = net_ok, powered = powered, own = powered and not net_ok,
		energy = p and p.valid and p.energy or 0, buffer = p and p.valid and p.electric_buffer_size or 0 }
	if cell then
		local spec = cell_spec(cell.name) or { bytes = 0, types = 0 }
		out.cell = { name = cell.name, bytes = cell.bytes, bytes_total = spec.bytes, types = cell.types,
			types_total = spec.types, fluid = fluid_cell(spec), state = cell_state(cell) }
	end
	local inv = entity.get_inventory(defines.inventory.chest)
	local st = inv and inv[1]
	if st and st.valid_for_read then out.input = { name = st.name, quality = st.quality.name, count = st.count } end
	local tank = c and c.tank
	local fb = tank and tank.valid and tank.get_fluid(1)
	if fb then out.fluid = { name = fb.name, amount = fb.amount, temperature = fb.temperature } end
	return out
end

--- the window's input slot: what waits there goes into `target` (an empty cursor stack, or an inventory); true when it moved
function M.chest_take_input(entity, target)
	if not (entity and entity.valid and kinds()[entity.name] == "chest" and target) then return false end
	local inv = entity.get_inventory(defines.inventory.chest)
	local st = inv and inv[1]
	if not (st and st.valid_for_read) then return false end
	if target.object_name == "LuaItemStack" then
		if target.valid_for_read then return false end
		return target.transfer_stack(st)
	end
	local n = target.insert(st)
	if n <= 0 then return false end
	if n >= st.count then st.clear() else st.count = st.count - n end
	return true
end

--- Store up to `amount` of fluid `name` in the fluid cells of one drive, whether or not its network works (the
--- migration). Returns the amount stored.
function M.store_fluid_in_drive(drive, name, amount)
	local s = state()
	local d = drive and drive.valid and s.drives[drive.unit_number]
	if not (d and prototypes.fluid[name] and amount > 0) then return 0 end
	return store_key_in_drive(s, d, drive.unit_number, FLUID_PREFIX .. name, amount, nil)
end

--- Store up to `amount` of fluid `name` in the fluid cells of a network's drives, whether or not the network works
--- (the migration). Returns the amount stored.
function M.store_fluid_in_network(net, name, amount)
	local s = state()
	if not (net and prototypes.fluid[name] and amount > 0) then return 0 end
	local units = {}
	for unit in pairs(net.drives) do units[#units + 1] = unit end
	table.sort(units)
	local left = amount
	for _, unit in ipairs(units) do
		if left <= ZERO then break end
		local d = s.drives[unit]
		if d and d.entity.valid then left = left - store_key_in_drive(s, d, unit, FLUID_PREFIX .. name, left, nil) end
	end
	return amount - math.max(0, left)
end

--- The drives on a surface (of a force) with room for fluid `name`, nearest to `position` first
function M.fluid_drives_near(surface_index, force_name, position, name)
	local s = state()
	local out = {}
	for unit, d in pairs(s.drives) do
		if d.entity.valid and d.surface == surface_index and d.force == force_name then
			local room = 0
			for slot = 1, drive_slots() do
				local cell = d.slots[slot]
				if cell then room = room + cell_room(cell, cell_spec(cell.name), FLUID_PREFIX .. name) end
			end
			if room > ZERO then
				local dx, dy = d.position.x - (position.x or position[1]), d.position.y - (position.y or position[2])
				out[#out + 1] = { entity = d.entity, unit = unit, dist = dx * dx + dy * dy }
			end
		end
	end
	table.sort(out, function(a, b)
		if a.dist ~= b.dist then return a.dist < b.dist end
		return a.unit < b.unit
	end)
	return out
end

--- Fill fluids ({ name -> amount }) into a drive's cells; what they cannot hold goes into new cells `cell_name`
--- in the drive's free slots (four cells of an old fluid drive hold its fluid only while it has few types).
--- Returns what is left ({ name -> amount }, empty when everything fit) and the number of cells added.
function M.fill_fluids(drive, cell_name, contents)
	local s = state()
	local d = drive and drive.valid and drive_record(s, drive)
	local left, added = {}, 0
	if not d then return contents, 0 end
	local names = {}
	for name, amount in pairs(contents) do
		if prototypes.fluid[name] and type(amount) == "number" and amount > ZERO then names[#names + 1] = name end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local rest = contents[name] - store_key_in_drive(s, d, drive.unit_number, FLUID_PREFIX .. name, contents[name], nil)
		while rest > ZERO do
			local free
			for slot = 1, drive_slots() do
				if not d.slots[slot] then free = slot break end
			end
			if not (free and cell_spec(cell_name)) then break end
			local cell = new_cell(cell_name)
			local unit = drive.unit_number
			local net = drive_net(s, unit)
			d.slots[free] = cell
			if net then net_cell(net, unit .. ":" .. free, cell, 1) end
			added = added + 1
			rest = rest - store_key_in_drive(s, d, unit, FLUID_PREFIX .. name, rest, nil)
		end
		if rest > ZERO then left[name] = rest end
	end
	return left, added
end

--- Fluids ({ name -> amount }) in new cells `cell_name`, as stack definitions (for a chest or the ground)
function M.fluid_cells(cell_name, contents)
	local out = {}
	local spec = cell_spec(cell_name)
	if not spec then return out end
	local names = {}
	for name, amount in pairs(contents) do
		if prototypes.fluid[name] and amount > ZERO then names[#names + 1] = name end
	end
	table.sort(names)
	local cell = new_cell(cell_name)
	for _, name in ipairs(names) do
		local rest = contents[name]
		while rest > ZERO do
			local n = math.min(rest, cell_room(cell, spec, FLUID_PREFIX .. name))
			if n <= ZERO then
				out[#out + 1] = cell_stack(cell)
				cell = new_cell(cell_name)
			else
				cell_add(cell, spec, FLUID_PREFIX .. name, n)
				rest = rest - n
			end
		end
	end
	if next(cell.items) then out[#out + 1] = cell_stack(cell) end
	return out
end

--------------------------------------------------------------------------------
--- drive priority and cell partitions (R3; the drive and cell windows, blueprints and settings paste use these)
--------------------------------------------------------------------------------

local MAX_PRIORITY = 1000

local function touch_order(s, unit)
	local net = drive_net(s, unit)
	if net then net.order_dirty = true end
end

--- the priority of a drive (-1000 ... 1000, default 0); higher priority drives are filled first
function M.get_priority(drive)
	local s = storage.fork_me_net
	local d = s and drive and drive.valid and s.drives[drive.unit_number]
	return d and d.priority or 0
end

function M.set_priority(drive, priority)
	if not (drive and drive.valid and CELL_KINDS[M.kind_of(drive.name)]) then return false end
	local s = state()
	local d = drive_record(s, drive)
	local p = math.floor(tonumber(priority) or 0)
	d.priority = math.max(-MAX_PRIORITY, math.min(MAX_PRIORITY, p))
	if d.priority == 0 then d.priority = nil end
	touch_order(s, drive.unit_number)
	return true
end

--- the partition of the cell in `slot`: a sorted list of keys (empty: none)
function M.get_partition(drive, slot)
	local s = storage.fork_me_net
	local d = s and drive and drive.valid and s.drives[drive.unit_number]
	local cell = d and d.slots[slot]
	return cell and M.cell_keys(cell) or {}
end

--- Restrict the cell in `slot` to `keys` (items "name"/"name@quality", fluids "fluid/<name>"); an empty list
--- removes the partition. What the cell holds stays. Returns true when the slot has a cell.
function M.set_partition(drive, slot, keys)
	local s = state()
	local d = drive and drive.valid and s.drives[drive.unit_number]
	local cell = d and d.slots[slot]
	if not cell then return false end
	M.set_cell_keys(cell, keys)
	touch_order(s, drive.unit_number)
	mark_drive(s, drive.unit_number)
	return true
end

--- AE2's "partition storage": the cell is restricted to what it holds now
function M.partition_from_contents(drive, slot)
	local s = state()
	local d = drive and drive.valid and s.drives[drive.unit_number]
	local cell = d and d.slots[slot]
	if not cell then return false end
	local keys = {}
	for key in pairs(cell.items) do if not key:find("#") then keys[#keys + 1] = key end end
	return M.set_partition(drive, slot, keys)
end

--- the settings of a drive for blueprints and settings paste: { priority, partitions = { [slot] = { keys } } }
function M.drive_settings(drive)
	local s = storage.fork_me_net
	local d = s and drive and drive.valid and s.drives[drive.unit_number]
	if not d then return nil end
	local parts = {}
	for slot = 1, drive_slots() do
		local keys = M.get_partition(drive, slot)
		if #keys > 0 then parts[tostring(slot)] = keys end
	end
	if not d.priority and not next(parts) then return nil end
	return { priority = d.priority or 0, partitions = parts }
end

--- Apply drive settings: the priority, and each slot's partition onto the cell in it (a slot without a cell keeps
--- the partition for the next cell put into it, as a blueprint does).
function M.apply_drive_settings(drive, settings)
	if type(settings) ~= "table" or not (drive and drive.valid and CELL_KINDS[M.kind_of(drive.name)]) then return false end
	local s = state()
	local d = drive_record(s, drive)
	M.set_priority(drive, settings.priority or 0)
	for slot_text, keys in pairs(type(settings.partitions) == "table" and settings.partitions or {}) do
		local slot = tonumber(slot_text)
		if slot and slot >= 1 and slot <= slots_of(drive) and type(keys) == "table" then
			if d.slots[slot] then
				M.set_partition(drive, slot, keys)
			else
				d.slot_partition = d.slot_partition or {}
				d.slot_partition[slot] = keys
			end
		end
	end
	return true
end

--- the drives of a network for the terminal's cell view: { { entity, unit, priority, cells = drive_info } },
--- higher priority first
--- the drives of a network (priority descending, then unit number) with their cells (drive_info; `light`: without each
--- cell's items and cards, issue #50, lever 8: the terminal's cells tab shows only fill, types and partition)
function M.drives_of(net, light)
	local s = state()
	local out = {}
	if not net then return out end
	for unit in pairs(net.drives) do
		local d = s.drives[unit]
		if d and d.entity.valid then
			out[#out + 1] = { entity = d.entity, unit = unit, priority = d.priority or 0, cells = M.drive_info(d.entity, light) }
		end
	end
	table.sort(out, function(a, b)
		if a.priority ~= b.priority then return a.priority > b.priority end
		return a.unit < b.unit
	end)
	return out
end

--- plain data of a drive's slots for GUIs and tests: { [slot] = { name, items, bytes, bytes_total, types, state } }
--- (`light`: no `items` and `cards`, the copies that cost)
function M.drive_info(drive, light)
	local s = storage.fork_me_net
	local d = s and drive and drive.valid and s.drives[drive.unit_number]
	local out = {}
	if not d then return out end
	for slot = 1, drive_slots() do
		local cell = d.slots[slot]
		if cell then
			local spec = cell_spec(cell.name) or { bytes = 0, types = 0 }
			local items
			if not light then
				items = {}
				for k, v in pairs(cell.items) do items[k] = v end
			end
			out[slot] = { name = cell.name, items = items, bytes = cell.bytes, bytes_total = spec.bytes,
				types = cell.types, types_total = spec.types, state = cell_state(cell), fluid = fluid_cell(spec),
				partition = M.cell_keys(cell),
				--- issue #17: the cell's cards (from the Cell Workbench)
				cards = not light and { table.unpack(cell.cards or {}) } or nil, inverted = cell.deny ~= nil or M.has_card(cell, "inverter"),
				fuzzy = cell.fnames ~= nil or M.has_card(cell, "fuzzy"), equal = cell.eq, void = cell.void == true,
				sticky = cell.sticky == true, voidcell = spec.void, gfilter = M.has_card(cell, "gfilter"), gtext = cell.gtext,
				voided = cell.voided or 0 }
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
M.spill = spill

--- the names of a drive's (or chest's) light and cell entities, and how many bays their pictures have (the mod-data's
--- drive view: issue #264, docs/API.md); the cell entity exists only when a graphics mod gave the view cell sprites
local function part_names(d)
	local kind = d.chest and "chest" or "drive"
	local v = mod_data().drive_view
	local bays = v and v[kind] and v[kind].bays
	local cell = "me-" .. kind .. "-cell"
	return "me-" .. kind .. "-light", prototypes.entity[cell] and cell or nil, bays and #bays or 0
end

local function destroy_part(p)
	if type(p) == "number" then                          -- (a render object of a save from before issue #267)
		local obj = rendering.get_object_by_id(p)
		if obj and obj.valid then obj.destroy() end
	elseif p and p.valid then
		p.destroy()
	end
end

--- the drive's lights and cells (issue #267: entities; before it render object ids)
local function clear_leds(d)
	for _, list in pairs({ d.leds or {}, d.cells or {} }) do
		for _, p in pairs(list) do destroy_part(p) end
	end
	d.leds, d.led_state, d.cells, d.cell_kinds = {}, {}, nil, nil
end

local function new_part(e, name, variation)
	local p = e.surface.create_entity{ name = name, position = e.position, force = e.force, create_build_effect_smoke = false }
	if p then
		p.destructible = false
		p.graphics_variation = variation
	end
	return p
end

--- the lights of a drive: one per cell, by its fill state, and with a graphics mod's view the cell itself. Issue #5: a
--- light is made when a cell goes in, destroyed when it goes out and only changed when the cell's state changes
--- (d.led_state[slot]); every other redraw request costs one state check per slot. Issue #267: the first time a drive
--- record draws (a new drive, a clone, a save from before) the parts on its tile go first: a clone's copies of its
--- source's parts, the render objects of before.
local function draw_leds(s, d)
	local e = d.entity
	if not e.valid then clear_leds(d) return end
	local light_name, cell_name, bays = part_names(d)
	if not d.parts then
		clear_leds(d)
		local names = { light_name, cell_name }
		for _, p in pairs(e.surface.find_entities_filtered{ name = names, position = e.position, radius = 0.01 }) do p.destroy() end
		d.parts = true
	end
	d.leds = d.leds or {}
	d.led_state = d.led_state or {}
	for slot = 1, drive_slots() do
		local cell = d.slots[slot]
		local light = d.leds[slot]
		if light and not (type(light) ~= "number" and light.valid) then destroy_part(light) light = nil end
		if cell and slot <= bays then
			--- issue #264: the cell itself, when a graphics mod gives sprites for it
			local kind = cell_name and (fluid_cell(cell_spec(cell.name) or {}) and 2 or 1) or nil
			if (d.cell_kinds and d.cell_kinds[slot]) ~= kind then
				d.cells, d.cell_kinds = d.cells or {}, d.cell_kinds or {}
				destroy_part(d.cells[slot])
				d.cells[slot] = kind and new_part(e, cell_name, (slot - 1) * 2 + kind) or nil
				d.cell_kinds[slot] = kind
			end
			local st = cell_state(cell)
			if d.chest and not CH.powered(s, e.unit_number) then st = "off" end   -- (issue #229: AE2's black LED)
			local variation = (slot - 1) * 4 + LIGHT_STATE[st]
			if not light then
				d.leds[slot] = new_part(e, light_name, variation)
			elseif d.led_state[slot] ~= st then
				light.graphics_variation = variation
			end
			d.led_state[slot] = st
		else
			destroy_part(light)
			d.leds[slot], d.led_state[slot] = nil, nil
			if d.cells and d.cells[slot] then
				destroy_part(d.cells[slot])
				d.cells[slot], d.cell_kinds[slot] = nil, nil
			end
		end
	end
end

--- issue #278: the ME Controller's state as a graphics mod shows it (the mod-data's controller view, docs/API.md): a
--- hidden entity on the controller's position (data-final-fixes.lua, only when the view has an animation) whose variation
--- is the state: dark without power, lit while its network works, a conflict (two controllers) while it has power. The
--- slow step sets every controller's part once a second with the look at its network's power that it makes anyway
--- (refresh_screens); a part that shows its state already costs one comparison. `s.controller_lights[unit] = { part,
--- st }`; a controller that is removed takes its part along, a clone (or a save from before) gets its own the next second.
local CONTROLLER_LIGHT = "me-controller-light"
local CONTROLLER_STATE = { off = 1, on = 2, conflict = 3 }

local function controller_state(e, net)
	if not (net and e.valid) then return "off" end
	if net.status == "conflict" then
		return (e.status ~= defines.entity_status.no_power and e.energy > 0) and "conflict" or "off"
	end
	return M.usable(net) and "on" or "off"
end

local function set_controller_light(s, unit, e, st)
	local rec = s.controller_lights[unit]
	local p = rec and rec.part
	if p and p.valid then
		if rec.st ~= st then
			p.graphics_variation = CONTROLLER_STATE[st]
			rec.st = st
		end
		return
	end
	--- (a clone's copy of its source's part goes first)
	for _, old in pairs(e.surface.find_entities_filtered{ name = CONTROLLER_LIGHT, position = e.position, radius = 0.01 }) do
		old.destroy()
	end
	s.controller_lights[unit] = { part = new_part(e, CONTROLLER_LIGHT, CONTROLLER_STATE[st]), st = st }
end

local function controller_light_gone(s, unit)
	local rec = s.controller_lights and s.controller_lights[unit]
	if not rec then return end
	destroy_part(rec.part)
	s.controller_lights[unit] = nil
end

--- every controller's part to its state (`ids`: the networks, sorted); nothing without a graphics mod's view
local function refresh_controller_lights(s, ids)
	if not prototypes.entity[CONTROLLER_LIGHT] then
		s.controller_lights = nil                             -- (the view's mod is gone: the game removed the parts)
		return
	end
	local cl = s.controller_lights
	if not cl then
		cl = {}
		s.controller_lights = cl
	end
	if s.controller_version ~= s.version then                  -- a controller that left without an event
		for unit in pairs(cl) do
			local node = s.nodes[unit]
			if not (node and node.kind == "controller") then controller_light_gone(s, unit) end
		end
		s.controller_version = s.version
	end
	for _, id in ipairs(ids) do
		local net = s.nets[id]
		local units
		for unit in pairs(net.controllers or {}) do
			units = units or {}
			units[#units + 1] = unit
		end
		if units then
			if #units > 1 then table.sort(units) end
			for _, unit in ipairs(units) do
				local e = s.nodes[unit] and s.nodes[unit].entity
				if e and e.valid then set_controller_light(s, unit, e, controller_state(e, net)) end
			end
		end
	end
end

--- (tests, issue #278) what a controller's part shows: nil without one, else { name, variation, position, state }
function M.controller_light_of(entity)
	local s = storage.fork_me_net
	local rec = s and s.controller_lights and entity and entity.valid and s.controller_lights[entity.unit_number]
	local p = rec and rec.part
	if not (p and p.valid) then return nil end
	return { name = p.name, variation = p.graphics_variation, position = p.position, state = rec.st }
end

--- (tests, issues #264, #267) what a drive or chest shows per slot: { [slot] = { light = { name, variation, position },
--- cell = { name, variation, position } } }
function M.drive_lights_of(entity)
	local s = storage.fork_me_net
	local d = s and s.drives and entity and entity.valid and s.drives[entity.unit_number]
	if not d then return nil end
	local out = {}
	for slot = 1, drive_slots() do
		local l = d.leds and d.leds[slot]
		local c = d.cells and d.cells[slot]
		l = type(l) ~= "number" and l and l.valid and l or nil
		c = type(c) ~= "number" and c and c.valid and c or nil
		if l or c then
			out[slot] = {
				light = l and { name = l.name, variation = l.graphics_variation, position = l.position } or nil,
				cell = c and { name = c.name, variation = c.graphics_variation, position = c.position } or nil,
			}
		end
	end
	return out
end

--------------------------------------------------------------------------------
--- the drive window's logic (the window itself: scripts/fork-me-windows.lua)
--------------------------------------------------------------------------------

--- a click on a slot: with a cell in the cursor it goes into the slot (a cell there is swapped into the cursor);
--- with an empty cursor the cell goes into the cursor (shift: into the inventory). Returns a reason on failure
--- ("no-inventory" when shift asks for an inventory and there is none: remote view without a character, issue #177; the
--- cell stays), and "out" as the second value when a cell was taken into the inventory.
function M.drive_click(cursor, inventory, drive, slot, shift)
	local s = state()
	if not (drive and drive.valid and CELL_KINDS[M.kind_of(drive.name)]) then return "no-drive" end
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
		if not inventory then return "no-inventory" end
		if not M.take_cell(drive, slot, inventory) then return "inventory-full" end
		return nil, "out"
	elseif cursor then
		if not M.take_cell(drive, slot, cursor) then return "inventory-full" end
	end
	return nil
end

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

--- the old drive item a build consumed (placing it gives an ME Drive with its four empty cells; issue #146: the items
--- stay, 0.5.0 left them in inventories as they were)
local function legacy_item(event)
	local md = mod_data()
	local function tags_of(st) return st.is_item_with_tags and st.tags or nil end
	local stack = event and event.stack
	if stack and stack.valid and stack.valid_for_read and md.legacy_drives[stack.name] then return stack.name, tags_of(stack) end
	local consumed = event and event.consumed_items
	if consumed and consumed.valid then
		for i = 1, #consumed do
			local st = consumed[i]
			if st.valid_for_read and md.legacy_drives[st.name] then return st.name, tags_of(st) end
		end
	end
	return nil
end

--- `event`: the build event (for the item that was placed); `source`: the original of a clone
function M.on_built(entity, event)
	if not (entity and entity.valid) then return end
	local kind = kinds()[entity.name]
	if not kind then return end
	local s = state()
	if kind == "toggle" and not M.toggle_wants(entity) then         -- issue #355: an open toggle bus is no member
		s.toggle_off = s.toggle_off or {}
		s.toggle_off[entity.unit_number] = true
		return
	end
	if kind == "drive" then
		local d = drive_record(s, entity)
		local old, tags = legacy_item(event)
		if old then
			local info = mod_data().legacy_drives[old]
			for i = 1, info.cells do d.slots[i] = new_cell(info.cell) end
			--- an old fluid drive item carries its fluid in its tags: into the cells (more cells if needed)
			local fluid = info.fluid and type(tags) == "table" and type(tags[info.fluid_tag]) == "table" and tags[info.fluid_tag]
			if fluid then
				local left = M.fill_fluids(entity, info.cell, fluid)
				for _, def in ipairs(M.fluid_cells(info.cell, left)) do spill(entity.surface, entity.position, def) end
			end
			if info.extra and prototypes.item[info.extra.name] then
				local player = event.player_index and game.get_player(event.player_index)
				local got = player and player.insert(info.extra) or 0
				if got < info.extra.count then spill(entity.surface, entity.position, { name = info.extra.name, count = info.extra.count - got }) end
			end
		end
	end
	if kind == "chest" then
		drive_record(s, entity)
		CH.parts(s, entity)
	end
	add_node(s, entity, kind)
	if CELL_KINDS[kind] then
		mark_drive(s, entity.unit_number)
		--- priority and partitions from a blueprint (R3)
		local t = event and type(event.tags) == "table" and event.tags[DRIVE_TAG]
		if type(t) == "table" then M.apply_drive_settings(entity, t) end
	end
end

--- the drive settings of a clone (on_entity_cloned; the cells of the source are not copied)
function M.on_cloned(source, destination)
	if not (source and source.valid and destination and destination.valid) then return end
	if CELL_KINDS[kinds()[source.name]] and CELL_KINDS[kinds()[destination.name]] then
		M.apply_drive_settings(destination, M.drive_settings(source) or { priority = 0, partitions = {} })
	end
end

--- settings paste between drives: the priority and the partition of each slot
function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (src and src.valid and dst and dst.valid) then return end
	if not (CELL_KINDS[kinds()[src.name]] and CELL_KINDS[kinds()[dst.name]]) then return end
	local settings = M.drive_settings(src) or { priority = 0, partitions = {} }
	--- every slot of the destination gets the source slot's partition (none: cleared)
	for slot = 1, drive_slots() do
		local key = tostring(slot)
		if not settings.partitions[key] then settings.partitions[key] = {} end
	end
	M.apply_drive_settings(dst, settings)
end

--- blueprint hook of the autocrafting module: the drive settings as tag fork_me_drive
function M.tag_blueprint(bp, mapping)
	for index, entity in pairs(mapping) do
		if entity.valid and CELL_KINDS[kinds()[entity.name]] then
			local settings = M.drive_settings(entity)
			if settings then bp.set_blueprint_entity_tag(index, DRIVE_TAG, settings) end
		end
	end
end

--------------------------------------------------------------------------------
--- issue #355: the ME Toggle Bus and the ME Inverted Toggle Bus (prototypes/autocrafting.lua; their checks:
--- scripts/fork-me-toggle.lua). A toggle bus is a member only while it joins: an open one is unregistered like a removed
--- cable (the network splits as for a removal), a closing one registered like a built one (the networks it touches merge).
--- `s.toggle_off` holds the open ones (rebuild skips them).
--------------------------------------------------------------------------------

M.TOGGLE_WIRES = { defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green }   -- (a field: no main-chunk local)

--- does the toggle bus want to join? Its lamp's circuit condition, switched on and on a circuit network, holds (AE2's
--- redstone signal); the inverted one wants the opposite, so it joins without a wire
function M.toggle_wants(entity)
	local cb = entity.get_control_behavior()
	local holds = false
	if cb and cb.circuit_enable_disable and not cb.disabled then
		for _, w in pairs(M.TOGGLE_WIRES) do
			if entity.get_circuit_network(w) then holds = true break end
		end
	end
	if entity.name == mod_data().names.inverted_toggle_bus then return not holds end
	return holds
end

--- is the toggle bus a member now (it joins)?
function M.toggle_joined(entity)
	local s = storage.fork_me_net
	return s ~= nil and entity.valid and s.nodes[entity.unit_number] ~= nil
end

--- the toggle bus joins (`joined` true) or opens; returns true when that changed the graph
function M.set_toggle(entity, joined)
	if not (entity and entity.valid and kinds()[entity.name] == "toggle") then return false end
	local s = state()
	local unit = entity.unit_number
	s.toggle_off = s.toggle_off or {}
	if joined then
		s.toggle_off[unit] = nil
		if s.nodes[unit] then return false end
		add_node(s, entity, "toggle")
	else
		s.toggle_off[unit] = true
		if not s.nodes[unit] then return false end
		remove_node_graph(s, unit)
	end
	return true
end

--- Issue #385: link the ME Quantum Bridges `a` and `b` (entities; `b` nil: unlink `a` from its partner). A link is a graph edge
--- like a cable between the two, on any surface and at any distance: the networks on both sides become one (a split when it
--- goes, as for a removed cable). The links are state (`s.qlink`, unit -> partner unit, both ways); scripts/fork-me-qbridge.lua
--- decides them. Returns true when the graph changed.
function M.set_qlink(a, b)
	local s = state()
	if not (a and a.valid) then return false end
	local au = a.unit_number
	s.qlink = s.qlink or {}
	local old = s.qlink[au]
	local bu = b and b.valid and b.unit_number or nil
	if old == bu then return false end
	local function again(unit)                          -- (registered again: its edges as the links say now)
		local node = s.nodes[unit]
		if node and node.entity.valid then
			remove_node_graph(s, unit)
			add_node(s, node.entity, node.kind)
		end
	end
	if old then
		s.qlink[au] = nil
		if s.qlink[old] == au then s.qlink[old] = nil end
		again(au)
	end
	if bu then
		local prev = s.qlink[bu]
		if prev then
			s.qlink[bu] = nil
			if s.qlink[prev] == bu then s.qlink[prev] = nil end
			again(prev)
		end
		s.qlink[au], s.qlink[bu] = bu, au
		again(au)
	end
	return true
end

--- the unit of the bridge `entity` is linked to (nil: none)
function M.qlink_of(entity)
	local s = storage.fork_me_net
	return s and s.qlink and entity and entity.valid and s.qlink[entity.unit_number] or nil
end

--- Issue #559: the edges of the ME Wireless Links. All links of a frequency on a surface form one wireless network
--- (scripts/fork-me-qbridge.lua decides which pairs of them are linked: a spanning forest within their range), so a link
--- may have several partners: `s.wlinks` = { [unit] = { [unit] = true } }, both ways, state like `s.qlink`. Each edge is a
--- graph edge like a cable. Returns the set of a link's partners (nil: none).
function M.wlinks_of(entity)
	local s = storage.fork_me_net
	return s and s.wlinks and entity and entity.valid and s.wlinks[entity.unit_number] or nil
end

--- forget every edge of `unit` (both ways); returns the units that lost an edge to it
function M.drop_wlinks(s, unit)
	local set = s.wlinks and s.wlinks[unit]
	if not set then return M.NONE end
	local lost = {}
	for other in pairs(set) do
		local o = s.wlinks[other]
		if o then
			o[unit] = nil
			if next(o) == nil then s.wlinks[other] = nil end
		end
		lost[#lost + 1] = other
	end
	s.wlinks[unit] = nil
	return lost
end

--- The edges among the links `units` (unit numbers) become `edges` ({ { a, b } } pairs of them); an edge of one of them to a link
--- outside the list goes. Only the links whose edges changed (and the ones that lost an edge) are registered again, in unit
--- order. Returns true when the graph changed.
function M.set_wlinks(units, edges)
	local s = state()
	s.wlinks = s.wlinks or {}
	local want = {}
	for _, u in ipairs(units) do want[u] = {} end
	for _, e in ipairs(edges) do
		if want[e[1]] and want[e[2]] and e[1] ~= e[2] then
			want[e[1]][e[2]] = true
			want[e[2]][e[1]] = true
		end
	end
	local dirty = {}
	for _, u in ipairs(units) do
		local old, new = s.wlinks[u] or M.NONE, want[u]
		local same = true
		for k in pairs(old) do if not new[k] then same = false break end end
		if same then for k in pairs(new) do if not old[k] then same = false break end end end
		if not same then
			dirty[u] = true
			for _, k in ipairs(M.drop_wlinks(s, u)) do dirty[k] = true end
		end
	end
	if next(dirty) == nil then return false end
	for u in pairs(dirty) do
		for k in pairs(want[u] or M.NONE) do
			s.wlinks[u] = s.wlinks[u] or {}
			s.wlinks[k] = s.wlinks[k] or {}
			s.wlinks[u][k], s.wlinks[k][u] = true, true
			dirty[k] = true
		end
	end
	local list = {}
	for u in pairs(dirty) do list[#list + 1] = u end
	table.sort(list)
	for _, u in ipairs(list) do
		local node = s.nodes[u]
		if node and node.entity.valid then
			remove_node_graph(s, u)
			add_node(s, node.entity, node.kind)
		end
	end
	return true
end

--- issue #355: the energy the network's controllers hold now (J; the level emitter's "stored energy")
function M.stored_energy(net)
	local s = storage.fork_me_net
	local n = 0
	for unit in pairs(net and net.controllers or {}) do
		local node = s and s.nodes[unit]
		local e = node and node.entity
		--- (issue #442: a network with a Creative Energy Cell is full)
		if e and e.valid then n = n + (net.creative and e.electric_buffer_size or e.energy) end
	end
	return n
end

--- A member is mined (its cells go into `buffer`), destroyed (`died`: its cells are spilled) or removed by a
--- script. Call before the entity is gone.
function M.on_removed(entity, buffer)
	if not (entity and entity.valid and entity.unit_number) then return end
	local s = storage.fork_me_net
	if s and s.toggle_off then s.toggle_off[entity.unit_number] = nil end   -- (issue #355)
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
	CH.gone(s, entity.unit_number)              -- (issue #229: an ME Chest's hidden parts)
	controller_light_gone(s, entity.unit_number)   -- (issue #278)
	M.ext_detach(entity.unit_number)               -- a storage bus: its inventory leaves the network
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
	CH.gone(s, unit)
	controller_light_gone(s, unit)
	M.ext_detach(unit)
	for _, f in ipairs(M.vanish_hooks) do f(unit) end
	if node then remove_node(s, unit) end
end

--- functions(unit) of other modules called for a member that vanished without an event (issue #6: a crafting block
--- leaves its CPU)
M.vanish_hooks = {}

--- a member whose power draw changed (M.power_hooks): its network computes the controller's draw again before its next use
function M.power_changed(entity)
	local net = entity and entity.valid and M.network_of(entity)
	if net then net.power_dirty = true end
end

--- functions of other modules called at every slow step (the Cell Workbench's sweep, issue #17)
M.slow_hooks = {}

--- every 60 ticks (from the terminal module): the lights of changed drives, the sweep
function M.slow_step()
	for _, f in ipairs(M.slow_hooks) do f() end
	local s = storage.fork_me_net
	if not s then return end
	--- issue #38: endpoints parked for their network's power are woken by M.usable when it sees the power back;
	--- a network nobody asks is asked here, once a second (one controller status read per such network)
	local ids, rooms
	for id, net in pairs(s.nets) do
		if net.wait_use and next(net.wait_use) then
			ids = ids or {}
			ids[#ids + 1] = id
		end
		if net.room_pending then
			rooms = rooms or {}
			rooms[#rooms + 1] = id
		end
	end
	if ids then
		table.sort(ids)
		for _, id in ipairs(ids) do M.usable(s.nets[id]) end
	end
	if rooms then                                                  -- something was extracted since the last step
		table.sort(rooms)
		for _, id in ipairs(rooms) do
			local net = s.nets[id]
			net.room_pending = nil
			if net.wait_room then fire_units(net, "wait_room") end
		end
	end
	refresh_controller_lights(s, refresh_screens(s))
	CH.power_step(s)
	if next(s.asm) then M.assembler_step(s) end                -- (issue #560)
	if not s.light_parts then                                      -- issue #267: the lights of a save from before
		s.light_parts = true
		for unit in pairs(s.drives) do s.dirty[unit] = true end
	end
	local n = 0
	for unit in pairs(s.dirty) do
		if n >= LEDS_PER_STEP_N then break end
		s.dirty[unit] = nil
		local d = s.drives[unit]
		if d then draw_leds(s, d) end
		n = n + 1
	end
	--- underground ends that lost their partner: pair them if the engine connected them to another end
	if s.ug_dirty and next(s.ug_dirty) then
		local list = {}
		for unit in pairs(s.ug_dirty) do list[#list + 1] = unit end
		table.sort(list)
		s.ug_dirty = {}
		for _, unit in ipairs(list) do
			local node = s.nodes[unit]
			if node and node.kind == "underground" and not node.partner and node.entity.valid then
				local partner = find_partner(s, node)
				if partner and not partner.partner then
					remove_node_graph(s, unit)
					add_node(s, node.entity, "underground")
				end
			end
		end
	end
	--- sweep: members removed without an event, SWEEP_PER_STEP at a time over the list of the members (issue #5; issue #43:
	--- the list is kept as members join and leave, it was taken and sorted anew every round: 141 ms at 20 000 members). A save
	--- from before has none: it is made once, sorted, at the first sweep.
	local list = s.nlist
	if not list then
		list = {}
		for unit in pairs(s.nodes) do list[#list + 1] = unit end
		table.sort(list)
		for k, unit in ipairs(list) do s.nodes[unit].li = k end
		s.nlist, s.sweep_list = list, nil
	end
	local k = s.sweep or 1
	if k > #list then k = 1 end
	for _ = 1, SWEEP_PER_STEP do
		local unit = list[k]
		if not unit then break end
		local node = s.nodes[unit]
		if node and not node.entity.valid then
			vanish(s, unit)                              -- (the last member now stands at k: look at it next)
		else
			k = k + 1
		end
	end
	s.sweep = k
end

--- the open key on a drive with a cell in the cursor: the cell goes into the first free slot (true when it did
--- something; else the drive window opens)
function M.quick_insert(player, entity)
	if not (entity and entity.valid and CELL_KINDS[kinds()[entity.name]]) then return false end
	local cursor = player.cursor_stack
	if not (cursor and cursor.valid_for_read and cell_spec(cursor.name)) then return false end
	if not player.can_reach_entity(entity) then return true end
	local _, why = M.insert_cell(entity, cursor)
	if why then player.create_local_flying_text{ text = { "fork-me-net.error-" .. why }, create_at_cursor = true } end
	return true
end

--------------------------------------------------------------------------------
--- rebuild (on_init, on_configuration_changed): the only map scan
--------------------------------------------------------------------------------

--- Issue #420: what the graph is made of: the rules (GRAPH_RULES below: raised when who connects to whom changes) and per
--- member name its kind and tile size. A save whose graph was made with the same is taken over by M.rebuild (M.keep_graph).
function M.graph_sig()
	local GRAPH_RULES = 1
	local k = kinds()
	local list = {}
	for name in pairs(k) do list[#list + 1] = name end
	table.sort(list)
	local parts = { "rules " .. GRAPH_RULES }
	for _, name in ipairs(list) do
		local p = prototypes.entity[name]
		parts[#parts + 1] = name .. "=" .. k[name] .. ":" .. (p.tile_width or 1) .. "x" .. (p.tile_height or 1)
	end
	return table.concat(parts, ";")
end

--- Issue #503: the stored key of an item that no longer exists (a mod removed or renamed it; a JSON migration renames items
--- in the engine's inventories only, never in `storage`) is the key of its replacement (M.alias: the same quality and tags),
--- or nil when there is none: it is dropped, as the engine drops removed items. Other keys (fluids too) come back as they are.
function M.live_key(key)
	if type(key) ~= "string" or is_fluid_key(key) or key_item_exists(key) then return key end
	local new = alias_key(key)
	if new ~= key and key_item_exists(new) then return new end
	return nil
end

--- Issue #503: a key set ({ key -> true }) with live keys only, nil when empty; `set` itself when nothing changed
function M.live_set(set)
	if type(set) ~= "table" then return set end
	local dead
	for key in pairs(set) do
		if M.live_key(key) ~= key then dead = true break end
	end
	if not dead then return set end
	local out = {}
	for key in pairs(set) do
		local k = M.live_key(key)
		if k then out[k] = true end
	end
	return next(out) and out or nil
end

--- Issue #503: a list of keys (or item names) with live ones only, in their order, without doubles; `list` itself when
--- nothing changed
function M.live_list(list)
	if type(list) ~= "table" then return list end
	local dead
	for _, key in ipairs(list) do
		if M.live_key(key) ~= key then dead = true break end
	end
	if not dead then return list end
	local out, seen = {}, {}
	for _, key in ipairs(list) do
		local k = M.live_key(key)
		if k and not seen[k] then
			seen[k] = true
			out[#out + 1] = k
		end
	end
	return out
end

--- Issue #503: the contents of a cell record (`items` and `data`) with live keys only: a replaced item's count added to its
--- replacement's (its data kept unless the replacement has its own), a removed one's dropped. `note(old, count, new)` is told
--- of each dead key. Returns the new items and data, or nil when the cell holds no dead key.
function M.live_contents(items, data, note)
	local dead
	for key in pairs(items) do
		if M.live_key(key) ~= key then dead = true break end
	end
	if not dead then return nil end
	local keys = {}
	for key in pairs(items) do keys[#keys + 1] = key end
	table.sort(keys)
	local out, odata = {}, {}
	for _, key in ipairs(keys) do
		local k = M.live_key(key)
		if k then out[k] = (out[k] or 0) + items[key] end
		if k ~= key then note(key, items[key], k) end
	end
	for _, key in ipairs(keys) do                     -- (the data of a live key first, a replaced key's only where none)
		local d = data and data[key]
		if d and M.live_key(key) == key then odata[key] = d end
	end
	for _, key in ipairs(keys) do
		local k, d = M.live_key(key), data and data[key]
		if d and k and k ~= key and odata[k] == nil and out[k] then odata[k] = d end
	end
	return out, odata
end

--- Issue #503: the dead keys met by the cleaning of on_configuration_changed (this module's and the other modules'), by item
--- name: { count, new } (per load: logged by M.log_removed_items, once per name)
M.dead_names = {}
function M.note_removed_item(key, count, new)
	local name = parse_key(key)
	local r = M.dead_names[name]
	if not r then
		r = { 0, new and (parse_key(new)) or nil }
		M.dead_names[name] = r
	end
	r[1] = r[1] + (count or 0)
end
--- `ME-REMOVED-ITEM <name> <count>` (dropped) or `ME-REPLACED-ITEM <name> <new> <count>` for each name noted, with the amount
--- the cells held (0: only settings named it)
function M.log_removed_items()
	local names = {}
	for name in pairs(M.dead_names) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local r = M.dead_names[name]
		local n = r[1] == math.floor(r[1]) and string.format("%d", r[1]) or tostring(r[1])
		log(r[2] and ("ME-REPLACED-ITEM " .. name .. " " .. r[2] .. " " .. n) or ("ME-REMOVED-ITEM " .. name .. " " .. n))
	end
	M.dead_names = {}
	return #names
end

--- Issue #503: the cells in the drives and ME Chests and the snapshots of the storage buses with live keys only, before the
--- graph rebuild of on_configuration_changed computes every network's totals and index from them: a cell's contents,
--- partition (or blacklist) and cards; a creative cell holds its amount of every key of its list.
function M.clean_removed_items()
	local s = state()
	local units = {}
	for unit in pairs(s.drives) do units[#units + 1] = unit end
	table.sort(units)
	for _, unit in ipairs(units) do
		local d = s.drives[unit]
		for slot = 1, drive_slots() do
			local cell = d.slots[slot]
			local spec = cell and cell_spec(cell.name)
			if spec then
				local changed
				local items, data = M.live_contents(cell.items, cell.data, spec.creative and function() end or M.note_removed_item)
				if items then
					changed = true
					cell.items, cell.data, cell.bytes, cell.types = {}, {}, 0, 0
					local keys = {}
					for key in pairs(items) do keys[#keys + 1] = key end
					table.sort(keys)
					for _, key in ipairs(keys) do
						if not spec.creative then cell_add(cell, spec, key, items[key]) end
						if data[key] then cell.data[key] = data[key] end
					end
				end
				for _, field in ipairs({ "partition", "deny", "gkeys" }) do
					local set = M.live_set(cell[field])
					if set ~= cell[field] then
						for key in pairs(cell[field]) do if M.live_key(key) ~= key then M.note_removed_item(key, 0, M.live_key(key)) end end
						cell[field], changed = set, true
					end
				end
				local cards = M.live_list(cell.cards)
				if cards ~= cell.cards then cell.cards, changed = cards, true end
				if changed then
					if spec.creative then
						cell.items = {}
						for key in pairs(cell.partition or {}) do cell.items[key] = M.CREATIVE end
					end
					M.apply_cell_cards(cell)
					s.dirty[unit] = true
				end
			end
		end
	end
	units = {}
	for unit in pairs(s.ext) do units[#units + 1] = unit end
	table.sort(units)
	for _, unit in ipairs(units) do
		local cell = s.ext[unit]
		local items, data = M.live_contents(cell.items or {}, cell.data, function() end)   -- (a snapshot: the storage holds the items)
		if items then cell.items, cell.data, cell.full = items, data, nil end
		cell.partition = M.live_set(cell.partition)
	end
end

--- Issue #420: the graph the build and removal events kept is taken over when it still matches the world: made with the same
--- rules and prototypes (s.graph_sig), and with few members that changed without an event: those that vanished are taken out
--- as the sweep takes them out (vanish), member entities that came without an event (the count of the map's member
--- entities says so) are put in as a build puts them in (M.on_built), in the order of their unit numbers; more than
--- KEEP_CHANGES or a sixteenth of the members make the whole rebuild. The rebuild's other work is done as before: the waits
--- fire, the drives' cells are checked against the cell prototypes and drawn again, the external cells checked, every
--- network computed again (its cells, totals, power), the screens. What it saves at 20 000 endpoints (80 000 members) is the
--- map scan, the nodes, the neighbour search and the components: about 1.8 of 2.2 s. (A save of a version before has no
--- s.graph_sig: its nodes, a box table and a position each, are made anew by the whole rebuild.) Returns true when the graph
--- was kept.
function M.keep_graph(s)
	local KEEP_CHANGES = 64
	local sig = M.graph_sig()
	if s.graph_sig ~= sig or not next(s.nodes) then return false end
	local members, gone = 0, {}
	for unit, node in pairs(s.nodes) do
		if node.entity.valid then members = members + 1 else gone[#gone + 1] = unit end
	end
	local off = 0
	for _ in pairs(s.toggle_off or {}) do off = off + 1 end
	local names, on_map = M.node_names(), 0
	for _, surface in pairs(game.surfaces) do on_map = on_map + surface.count_entities_filtered{ name = names } end
	local new = on_map - members - off                      -- (members that came without an event; < 0: a stale open toggle)
	if #gone + math.abs(new) > math.max(KEEP_CHANGES, members / 16) then return false end
	for _, node in pairs(s.nodes) do clear_link(node) end
	table.sort(gone)
	for _, unit in ipairs(gone) do vanish(s, unit) end
	if new > 0 then
		local found = {}
		for _, surface in pairs(game.surfaces) do
			for _, e in pairs(surface.find_entities_filtered{ name = names }) do
				local unit = e.unit_number
				if not s.nodes[unit] and not (s.toggle_off and s.toggle_off[unit]) then found[#found + 1] = e end
			end
		end
		table.sort(found, function(a, b) return a.unit_number < b.unit_number end)
		for _, e in ipairs(found) do M.on_built(e) end
	end
	for unit, c in pairs(s.chests or {}) do               -- (issue #229: the hidden parts of chests that are gone)
		if not (c.entity and c.entity.valid) then CH.gone(s, unit) end
	end
	local ids = {}
	for id in pairs(s.nets) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do fire_all_waits(s.nets[id]) end   -- (issue #38: no parked endpoint loses its wake)
	s.version = s.version + 1
	--- the drives keep their cells; a cell whose prototype is gone, or in a slot the drive no longer has, is spilled
	for unit, d in pairs(s.drives) do
		if d.entity.valid then
			d.leds = d.leds or {}
			d.chest = kinds()[d.entity.name] == "chest" or nil
			clear_leds(d)
			for slot in pairs(d.slots) do
				if slot > slots_of(d.entity) or not cell_spec(d.slots[slot].name) then
					spill(d.entity.surface, d.position, cell_stack(d.slots[slot]))
					d.slots[slot] = nil
				end
			end
			s.dirty[unit] = true
		end
	end
	local old_ext = s.ext
	s.ext = {}
	for unit, cell in pairs(old_ext) do
		if cell.entity and cell.entity.valid and kinds()[cell.entity.name] == cell.ext then
			s.ext[unit] = cell
		else
			local h = M.ext_handlers[cell.ext]
			if h and h.detached then h.detached(cell) end
		end
	end
	for _, id in ipairs(ids) do recompute(s, s.nets[id]) end
	if s.screens then
		local units = {}
		for unit in pairs(s.nodes) do units[#units + 1] = unit end
		table.sort(units)
		for _, unit in ipairs(units) do
			local node = s.nodes[unit]
			if has_screen(node.kind) and not s.screens[unit] then screen_made(s, unit, node.entity, node.kind) end
		end
	end
	for _, hook in pairs(M.change_hooks) do hook(nil) end
	return true
end

--- `full`: rebuild the graph from the map even when the kept one matches it (issue #420)
function M.rebuild(full)
	names_cache, names_list = nil, nil
	local s = state()
	if not full and M.keep_graph(s) then return true end
	s.graph_sig = M.graph_sig()
	local old_drives = s.drives
	for unit, c in pairs(s.chests or {}) do               -- (issue #229: the hidden parts of chests that are gone)
		if not (c.entity and c.entity.valid) then CH.gone(s, unit) end
	end
	for _, node in pairs(s.nodes) do clear_link(node) end
	local ids = {}
	for id in pairs(s.nets) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do fire_all_waits(s.nets[id]) end   -- (issue #38: no parked endpoint loses its wake)
	s.nodes, s.nets, s.version = {}, {}, s.version + 1
	s.drives, s.dirty, s.sweep, s.sweep_list, s.nlist = {}, {}, 1, nil, {}
	s.asm = {}                                             -- (issue #560)
	local names = M.node_names()
	--- issue #43: each property of an entity is read once (a read is an engine call, and the sort read two per comparison: 1 s
	--- at 20 000 members); the members are sorted by unit number as before
	local ents, surface_of, units = {}, {}, {}
	for _, surface in pairs(game.surfaces) do
		local index = surface.index
		for _, e in pairs(surface.find_entities_filtered{ name = names }) do
			local unit = e.unit_number
			if not (s.toggle_off and s.toggle_off[unit]) then          -- (issue #355: an open toggle bus is no member)
				units[#units + 1] = unit
				ents[unit] = e
				surface_of[unit] = index
			end
		end
	end
	table.sort(units)
	--- drives keep their cells (by unit number); cells of drives that are gone are spilled where they stood
	for unit, d in pairs(old_drives) do
		if d.entity.valid and CELL_KINDS[kinds()[d.entity.name]] then
			s.drives[unit] = d
			d.leds = d.leds or {}
			d.chest = kinds()[d.entity.name] == "chest" or nil
			clear_leds(d)
			for slot in pairs(d.slots) do
				if slot > slots_of(d.entity) or not cell_spec(d.slots[slot].name) then
					local surface = slot > slots_of(d.entity) and game.get_surface(d.surface)
					if surface then spill(surface, d.position, cell_stack(d.slots[slot])) end
					d.slots[slot] = nil
				end
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
	--- external cells (storage buses) of members that still exist are kept with their snapshot
	local old_ext = s.ext
	s.ext = {}
	for unit, cell in pairs(old_ext) do
		if cell.entity and cell.entity.valid and kinds()[cell.entity.name] == cell.ext then
			s.ext[unit] = cell
		else
			local h = M.ext_handlers[cell.ext]
			if h and h.detached then h.detached(cell) end   -- (issue #28: the cards in its slots are spilled, never lost)
		end
	end
	--- nodes without links first, then the links, then the components
	local sizes, force_names = {}, {}
	for _, unit in ipairs(units) do
		local e = ents[unit]
		local name, pos, dir, fi = e.name, e.position, e.direction, e.force_index
		local size = sizes[name]
		if not size then
			local p = prototypes.entity[name]
			size = { p.tile_width or 1, p.tile_height or 1 }
			sizes[name] = size
		end
		local fname = force_names[fi]
		if not fname then
			fname = game.forces[fi].name
			force_names[fi] = fname
		end
		local w, h = size[1], size[2]
		if (dir == defines.direction.east or dir == defines.direction.west) and w ~= h then w, h = h, w end
		local kind = kinds()[name]
		local node = { math.floor(pos.x - w / 2 + 0.5), math.floor(pos.y - h / 2 + 0.5),
			math.floor(pos.x + w / 2 + 0.5), math.floor(pos.y + h / 2 + 0.5),
			entity = e, kind = kind, adj = {}, surface = surface_of[unit], force = fname, li = #s.nlist + 1 }
		s.nodes[unit] = node
		s.nlist[#s.nlist + 1] = unit                       -- (`units` is sorted)
		if kind == "underground" then node.dir = dir end
		if kind == "assembler" then s.asm[unit] = true end     -- (issue #560)
		if CELL_KINDS[kind] then drive_record(s, e) s.dirty[unit] = true end
		if kind == "chest" then CH.parts(s, e) end
	end
	--- the neighbours: the members that touch a member's box along an edge, from a grid of the tiles the members cover (one table
	--- per surface), not from an engine query per member (a query with the names of all members: 1.2 s at 20 000 members). The
	--- same members the query found: those of the same force whose boxes share an edge of positive length, that connect.
	local OFF, MUL = 2097152, 4194304
	local grids = {}
	for _, unit in ipairs(units) do
		local node = s.nodes[unit]
		local g = grids[node.surface]
		if not g then
			g = {}
			grids[node.surface] = g
		end
		local b = node
		for tx = b[1], b[3] - 1 do
			for ty = b[2], b[4] - 1 do
				local key = (tx + OFF) * MUL + (ty + OFF)
				local c = g[key]
				if c == nil then g[key] = unit                 -- (a tile of one member holds its unit number, of several a list)
				elseif type(c) == "number" then g[key] = { c, unit }
				else c[#c + 1] = unit end
			end
		end
	end
	local function link(c, unit, node, b)
		if type(c) == "number" then
			if c ~= unit then
				local other = s.nodes[c]
				if other.force == node.force and adjacent(b, other) and connects(node, other) then node.adj[c] = true end
			end
		else
			for i = 1, #c do
				local ou = c[i]
				if ou ~= unit then
					local other = s.nodes[ou]
					if other.force == node.force and adjacent(b, other) and connects(node, other) then node.adj[ou] = true end
				end
			end
		end
	end
	for _, unit in ipairs(units) do
		local node = s.nodes[unit]
		local b, g = node, grids[node.surface]
		local x1, y1, x2, y2 = b[1], b[2], b[3], b[4]
		for ty = y1, y2 - 1 do                              -- the tiles beside the west and east edges
			local c = g[(x1 - 1 + OFF) * MUL + (ty + OFF)]
			if c then link(c, unit, node, b) end
			c = g[(x2 + OFF) * MUL + (ty + OFF)]
			if c then link(c, unit, node, b) end
		end
		for tx = x1, x2 - 1 do                              -- and above and below
			local c = g[(tx + OFF) * MUL + (y1 - 1 + OFF)]
			if c then link(c, unit, node, b) end
			c = g[(tx + OFF) * MUL + (y2 + OFF)]
			if c then link(c, unit, node, b) end
		end
	end
	--- underground cables pair as the engine connected them
	for _, unit in ipairs(units) do
		local node = s.nodes[unit]
		if node.kind == "underground" and not node.partner then
			local partner = find_partner(s, node)
			if partner then link_pair(node, partner) end
		end
	end
	--- issue #385: the linked ME Quantum Bridges (their links are state: s.qlink, kept by scripts/fork-me-qbridge.lua)
	for unit, qu in pairs(s.qlink or {}) do
		local a, b = s.nodes[unit], s.nodes[qu]
		if a and b then
			a.adj[qu] = true
			b.adj[unit] = true
		end
	end
	--- issue #559: the edges of the ME Wireless Links (s.wlinks)
	for unit, set in pairs(s.wlinks or {}) do
		local a = s.nodes[unit]
		for wu in pairs(set) do
			local b = s.nodes[wu]
			if a and b then
				a.adj[wu] = true
				b.adj[unit] = true
			end
		end
	end
	local seen = {}
	for _, unit in ipairs(units) do
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
	--- issue #128: a terminal (#254: or level maintainer) without a screen gets one (the others keep theirs: render objects
	--- are not made twice)
	if s.screens then
		for _, unit in ipairs(units) do
			local node = s.nodes[unit]
			if has_screen(node.kind) then
				if s.screens[unit] and not node.entity.valid then screen_gone(s, unit) end
				if not s.screens[unit] then screen_made(s, unit, node.entity, node.kind) end
			end
		end
	end
	if not s.asm_told then                                 -- issue #560: once, at the first rebuild with the assemblers as members
		s.asm_told = true
		M.tell_asm_conflicts(s)
	end
	for _, hook in pairs(M.change_hooks) do hook(nil) end
end

--- Issue #560: an older save's ME Molecular Assemblers join the networks they touch, so two networks that only met in an
--- assembler (between their pattern providers) are one now, with two controllers: its force is told where, once
function M.tell_asm_conflicts(s)
	local ids = {}
	for id in pairs(s.nets) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local net = s.nets[id]
		local asm, ctrl
		if net.status == "conflict" then
			for unit in pairs(net.nodes) do
				local node = s.nodes[unit]
				if node.kind == "assembler" then asm = true end
				if node.kind == "controller" and node.entity.valid and not (ctrl and ctrl.unit_number < unit) then ctrl = node.entity end
			end
		end
		local force = asm and ctrl and game.forces[net.force]
		if force then
			force.print({ "fork-me-net.assembler-conflict", string.format("[gps=%d,%d,%s]", math.floor(ctrl.position.x),
				math.floor(ctrl.position.y), ctrl.surface.name) })
		end
	end
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
		local bx = node
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
			local bx = s.nodes[unit]
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
			for _, e in ipairs(targets) do
				unreached[e.unit_number] = e
				local why = {}
				for k, target in pairs(target_tiles) do
					if target == e then
						local x, y = k:match("^(-?%d+),(-?%d+)$")
						x, y = tonumber(x), tonumber(y)
						local blockers = {}
						for _, o in pairs(surface.find_entities_filtered{ area = { { x + 0.05, y + 0.05 }, { x + 0.95, y + 0.95 } } }) do
							blockers[#blockers + 1] = o.name
						end
						why[#why + 1] = k .. (is_free(x, y) and " free" or " blocked") .. (foreign(x, y, root_net) and " foreign" or "")
							.. (parent[k] ~= nil and " reached" or "") .. " [" .. table.concat(blockers, " ") .. "]"
					end
				end
				table.sort(why)
				log("FORK-ME-NET: no cable path to " .. e.name .. ": " .. table.concat(why, "; ") .. " (" .. (qi - 1) .. " tiles searched)")
			end
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
	--- issue #229: what an ME Chest's window shows (M.chest_info), its input slot into a target, its view's grid entries
	chest = function(entity) return M.chest_info(entity) end,
	chest_take_input = function(entity, target) return M.chest_take_input(entity, target) end,
	removed = function(entity, buffer) M.on_removed(entity, buffer) end,
	chest_count = function(entity, key)
		local v = M.chest_view(entity)
		return v and v.items[key] or 0
	end,
	--- issue #59 (tests): the kept holder lists and cursors against lists sorted anew: lists, differing, the first problem
	check_holder_lists = function() return M.check_holder_lists() end,
	--- issue #420 (tests): the controller's draw as the joins and removals kept it, and as the walk over every member counts it
	power_recount = function(entity)
		local net = M.network_of(entity)
		if not net then return nil end
		if net.power_dirty then return { dirty = true } end
		local kept, by = net.power, {}
		for k, row in pairs(net.power_by or {}) do by[k] = row.n .. "/" .. row.w end
		update_power(state(), net)
		local walked = {}
		for k, row in pairs(net.power_by) do walked[k] = row.n .. "/" .. row.w end
		return { kept = kept, walked = net.power, kept_by = by, walked_by = walked }
	end,
	--- issue #420 (tests): a member's node: its folded tile box, and whether it still has the fields of before
	node_fold = function(entity)
		local s = storage.fork_me_net
		local node = s and entity and entity.valid and s.nodes[entity.unit_number]
		if not node then return nil end
		return { node[1], node[2], node[3], node[4], box = node.box ~= nil, position = node.position ~= nil }
	end,
	--- issue #420 (tests): the network's cell ids in their order, and how many cells it has
	cell_ids = function(entity)
		local net = M.network_of(entity)
		if not net then return nil end
		local n = 0
		for _ in pairs(net.cells) do n = n + 1 end
		local ids = {}
		for i, cid in ipairs(M.cell_ids(net)) do ids[i] = cid end
		return { ids = ids, cells = n }
	end,
	--- tests: is the sweep list the members, each once, each node at its place? (true, or false and what is wrong)
	sweep_list_ok = function()
		local s = storage.fork_me_net
		local list = s and s.nlist
		if not list then return true end
		local n = 0
		for unit, node in pairs(s.nodes) do
			n = n + 1
			if list[node.li or 0] ~= unit then return false, "member " .. unit .. " is not at its place " .. tostring(node.li) end
		end
		if n ~= #list then return false, #list .. " in the list, " .. n .. " members" end
		return true
	end,
	--- tests (issue #254): is the screen list the screens, each once, each record at its place? (true, or false and why)
	screen_list_ok = function()
		local s = storage.fork_me_net
		local list = s and s.screen_list
		if not list then return true end
		local n = 0
		for unit, sc in pairs(s.screens or {}) do
			n = n + 1
			if list[sc.li or 0] ~= unit then return false, "screen " .. unit .. " is not at its place " .. tostring(sc.li) end
		end
		if n ~= #list then return false, #list .. " in the screen list, " .. n .. " screens" end
		return true
	end,
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
	--- fluids (issue #68, R2): by name, amounts may be fractional; issue #159: an optional temperature (nil: the default)
	insert_fluid = function(entity, name, amount, temperature) return M.insert_fluid(M.network_of(entity), name, amount, temperature) end,
	extract_fluid = function(entity, name, amount, temperature) return M.extract_fluid(M.network_of(entity), name, amount, temperature) end,
	fluid_count = function(entity, name, temperature) return M.fluid_count(M.network_of(entity), name, temperature) end,
	can_insert_fluid = function(entity, name, amount, temperature)
		return M.can_insert_fluid(M.network_of(entity), name, amount, temperature)
	end,
	fluid_contents = function(entity) return M.fluid_contents(M.network_of(entity)) end,
	--- issue #159: { storage key -> amount }, one entry per temperature ("fluid/<name>", "fluid/<name>@<degrees>")
	fluid_key_contents = function(entity) return M.fluid_key_contents(M.network_of(entity)) end,
	fluid_key = function(name, temperature) return fluid_key(name, temperature) end,
	store_fluid_in_drive = function(drive, name, amount) return M.store_fluid_in_drive(drive, name, amount) end,
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
	--- tests (issue #414): every storage cell's spec by item name
	cell_specs = function() return M.cell_specs() end,
	take_cell = function(drive, slot, target) return M.take_cell(drive, slot, target) end,
	drive = function(drive) return M.drive_info(drive) end,
	--- drive priority and cell partitions (R3)
	get_priority = function(drive) return M.get_priority(drive) end,
	set_priority = function(drive, priority) return M.set_priority(drive, priority) end,
	get_partition = function(drive, slot) return M.get_partition(drive, slot) end,
	set_partition = function(drive, slot, keys) return M.set_partition(drive, slot, keys) end,
	partition_from_contents = function(drive, slot) return M.partition_from_contents(drive, slot) end,
	drive_settings = function(drive) return M.drive_settings(drive) end,
	apply_drive_settings = function(drive, settings) return M.apply_drive_settings(drive, settings) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	tag_blueprint = function(bp, mapping) M.tag_blueprint(bp, mapping) end,
	--- what building a ghost with blueprint tags does
	built_with_tags = function(entity, tags) M.on_built(entity, { tags = tags }) end,
	--- the insertion order of the network's cells: { { cid, p } }
	order = function(entity)
		local net = M.network_of(entity)
		if not net then return {} end
		local order = ordered(state(), net)
		local out = {}
		for i, c in ipairs(order) do out[i] = { cid = c.cid, p = c.p } end
		return out
	end,
	--- which cells hold `key`: { cid -> count }
	holders = function(entity, key)
		local net = M.network_of(entity)
		local out = {}
		for cid in pairs(net and net.index[key] or {}) do out[cid] = net.cells[cid].items[key] end
		return out
	end,
	--- a click on a slot of the drive window, for a cursor stack and a main inventory
	drive_click = function(cursor, inventory, drive, slot, shift) return M.drive_click(cursor, inventory, drive, slot, shift) end,
	--- issue #17: what Overflow Destruction Cards destroyed on the map so far, per key
	voided = function()
		local s = storage.fork_me_net
		return s and s.voided or {}
	end,
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
	slow_step = function() M.slow_step() end,                  -- (tests: the sweep of the members runs from it)
	version = function() return M.version() end,
	cable_variation = function(cable) return cable.graphics_variation end,
	kind = function(name) return M.kind_of(name) end,                 -- (issue #130 tests) the kind of an entity name
	screen = function(entity) return M.screen_of(entity) end,         -- (issue #128 tests) what a terminal's screen shows
	drive_lights = function(entity) return M.drive_lights_of(entity) end,  -- (issue #264 tests) a drive's lights and cells
	controller_light = function(entity) return M.controller_light_of(entity) end,   -- (issue #278 tests) a controller's part
	--- what the rotation event does (entity.rotate raises none)
	rotated = function(entity) M.on_rotated(entity) end,
	--- what on_configuration_changed does with the graph (the whole map)
	rebuild = function(full) return M.rebuild(full) == true end,      -- (issue #420: true when the kept graph was taken over)
	--- tests (issue #38): forget every wait of the entity's network, as if all its wakes had been missed
	drop_waits = function(entity)
		local net = M.network_of(entity)
		if not net then return false end
		net.wait_in, net.wait_out, net.wait_below, net.wait_use, net.wait_room = nil, nil, nil, nil, nil
		return true
	end,
	--- the unit number of an underground cable's partner, or nil
	underground_partner = function(entity)
		local s = storage.fork_me_net
		local node = s and entity and entity.valid and s.nodes[entity.unit_number]
		return node and node.partner or nil
	end,
	--- tests: the turn of the underground cables of an older save; with `surface` and `area` only there (and again)
	migrate_underground_direction = function(surface, area)
		return M.migrate_underground_direction(surface and { surface = surface, area = area } or nil)
	end,
	--- tests: the underground pair a drag of ME Cable from `a` to `b` makes over an obstacle (scripts/fork-me-cabledrag.lua);
	--- the underground cables come from and the cables go to the inventory of the chest `chest` (nil: ghosts only)
	drag_bridge = function(a, b, chest)
		local inv = chest and chest.valid and chest.get_inventory(defines.inventory.chest) or nil
		local exit, entry = M.drag_bridge(a, b, inv)          -- (set by scripts/fork-me-cabledrag.lua)
		return exit, entry
	end,
})

return M
