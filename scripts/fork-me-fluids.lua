--------------------------------------------------------------------------------
--- FORK AE2: FLUID STORAGE OF THE ME NETWORK (runtime, see prototypes/122-fork-ae2-fluids.lua)
--- The fluid side of the ME network (scripts/fork-me-network.lua) is kept here until fluid cells replace the
--- fluid drives (issue #68, step R2):
---   * ME Fluid Drive: a 1x1 entity without fluid boxes. Its contents are virtual, a table
---     { fluid -> amount } in storage.fork_me_fluids.drives[unit_number], capped by the capacity
---     of the drive (mod-data "fork-me-fluids"). The network total of a fluid is the sum over the
---     drives that are members of that ME network; the network is looked up when a total is asked
---     for, so merging or splitting networks needs no bookkeeping.
---   * Picking a drive up moves its contents onto the item (item-with-tags, tag "fork_me_fluids"),
---     placing that item brings them back.
---   * Recovery: fluid that loses its drive (a destroyed drive, a drive removed by a script, a
---     loaded drive item taken apart by hand) goes into the other fluid drives of the ME network
---     at that position (the network of an ME member within 1.5 tiles; 10 for the hand disassembly) as far as they have room; the rest is kept as recovered fluid
---     (storage.fork_me_fluids.recovered: per surface and force, entries with the position). The
---     next fluid drive placed in that network takes it over (a robot rebuilding the ghost of a
---     destroyed drive does that; if no network covers the position any more, any drive placed on
---     the surface), or a drive's "take over" button. Only a deleted surface loses recovered
---     fluid. Every step is reported to the force (chat, with a map position). Drives that stand in
---     the network of an entry pull it in by themselves as soon as they have room (fluid step, a few
---     entries per step, round robin).
---   * Upgrades: a drive replaced by fast replace (hand) or by an upgrade order (robots, platforms)
---     does not put its fluid onto the old item; it is kept for the new drive at the same spot, and
---     what that drive cannot hold goes into the network, then into the recovered fluid.
---   * ME Fluid Interface: a small storage tank. In import mode its content is moved into the
---     network, in export mode it is filled with a chosen fluid up to a chosen level. Pumps and
---     pipes connect to it like to any tank. Mode, fluid and level live in
---     storage.fork_me_fluids.interfaces and are set in a panel next to the tank GUI. They are copied
---     by settings paste and cloning and kept in blueprints (entity tag "fork_me_fluid_interface").
---   * Temperature: the network stores fluids by name only. Importing drops the temperature,
---     exporting (and the autocrafting hand-over) uses the fluid's default temperature.
--- Work per step: INTERFACES_PER_STEP interfaces and RECOVERED_PER_STEP recovered entries every
--- STEP_TICKS ticks (round robin, the step is called by the I/O step of fork-me-io.lua) and the open drive GUIs. Nothing runs per tick; a network total loops over the drives (a few hundred
--- at most), nothing loops over all tanks.
--- State: storage.fork_me_fluids only. GUI state lives in the GUI elements (tags).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

--- functions called with every mined assembling machine, furnace, drive or interface (autocrafting
--- rescues the fluid of a leased machine); registered at load time, so nothing is stored
M.mined_hooks = {}

local STEP_TICKS = 15               -- the I/O step of fork-me-io.lua (20, 30 and 60 are taken)
local INTERFACES_PER_STEP = 8
local RECOVERED_PER_STEP = 4        -- recovered entries pulled into the drives of their network per step
local EPS = 1e-6                    -- fluid amounts are fixed point (1/2^24); below this a box counts as empty
local HAND_RADIUS = 10              -- the network "you stand in": the nearest ME member within this many tiles
local TAG = "fork_me_fluids"        -- item tag that carries the contents of a picked up drive
local IFACE_TAG = "fork_me_fluid_interface"   -- blueprint tag of an interface's settings { mode, fluid, level }
local DRIVE_FRAME = "fork_me_fluid_drive"
local IFACE_FRAME = "fork_me_fluid_interface"

--------------------------------------------------------------------------------
--- prototype data and state
--------------------------------------------------------------------------------

local function mod_data()
	local md = prototypes.mod_data["fork-me-fluids"]
	return md and md.data or { drives = {}, interface = {} }
end

local function drive_capacity(name)
	return mod_data().drives[name]
end

local function interface_name()
	return mod_data().interface.name or "me-fluid-interface"
end

local function interface_volume()
	return mod_data().interface.volume or 5000
end

local function state()
	local s = storage.fork_me_fluids
	if not s then
		s = {
			drives = {},        -- unit_number -> { entity, name, capacity, contents = { fluid -> amount }, used, surface, force }
			interfaces = {},    -- unit_number -> { entity, mode = "import"|"export", fluid, level, status }
			ilist = {},         -- unit numbers of interfaces (round robin)
			icursor = 1,
			gui = {},           -- player_index -> { entity, sig } while a drive GUI is open
			recovered = {},     -- surface index -> force name -> { { position, contents = { fluid -> amount }, moved } }
			--- created lazily (also in older saves):
			--- rcursor: round robin cursor over the recovered entries
			--- replacing: "surface:x:y" -> { contents, tick, surface, force, position, name } of a drive being replaced
			--- prebuild: player_index -> { tick, surface, position } of the player's last build (fast replace)
		}
		storage.fork_me_fluids = s
	end
	return s
end

--- the working ME network of an entity (scripts/fork-me-network.lua), nil if none
local function network_of(entity)
	return N.active_of(entity)
end

--- the working network at a position: that of an ME member within `radius` (default 1.5: the cable or block a
--- drive was connected to)
local function network_at(surface, position, force, radius)
	return N.network_near(surface, position, force, radius or 1.5)
end
M.network_of = network_of

--- fluid names of a { fluid -> amount } table in a fixed order (the same result on every peer)
local function sorted_names(t)
	local names = {}
	for name in pairs(t) do names[#names + 1] = name end
	table.sort(names)
	return names
end

--- "1234" or "12.3" for the GUI
function M.format(amount)
	if amount == math.floor(amount) then return string.format("%d", amount) end
	return string.format("%.1f", amount)
end
local format = M.format

--------------------------------------------------------------------------------
--- drives
--------------------------------------------------------------------------------

local function drive_record(s, entity)
	local unit = entity.unit_number
	local rec = s.drives[unit]
	if not rec then
		rec = { entity = entity, name = entity.name, capacity = drive_capacity(entity.name) or 0, contents = {}, used = 0,
			surface = entity.surface.index, force = entity.force.name, position = entity.position }
		s.drives[unit] = rec
	end
	return rec
end

local function rec_add(rec, name, amount)
	local now = (rec.contents[name] or 0) + amount
	if now < EPS then now = 0 end
	rec.contents[name] = now > 0 and now or nil
	local used = 0
	for _, a in pairs(rec.contents) do used = used + a end
	rec.used = used
end

--------------------------------------------------------------------------------
--- recovered fluid: per surface and force a list of entries { position, contents }, the position
--- being where the fluid lost its drive. A placed drive takes over the entries of its own ME
--- network and those whose network no longer exists.
--------------------------------------------------------------------------------

local MAX_ENTRIES = 32              -- per surface and force; more are merged into the last one

local function recovered(s)
	local r = s.recovered
	if not r then                   -- saves from before the recovery
		r = {}
		s.recovered = r
	end
	return r
end

--- the entry list of a surface and force (nil if there is none and `create` is not set)
local function entries_of(s, surface_index, force_name, create)
	local r = recovered(s)
	local per = r[surface_index]
	if not per then
		if not create then return nil end
		per = {}
		r[surface_index] = per
	end
	local list = per[force_name]
	if not list and create then
		list = {}
		per[force_name] = list
	end
	return list
end

--- the ME member nearest to a position within `radius` (default 1.5), working network or not, and its network
local function member_at(surface, position, force, radius)
	return N.member_near(surface, position, force, radius or 1.5, true)
end

--- the ME network an entry belongs to (working or not): that of the member it was recovered at (the cable or
--- block next to a destroyed drive, the member nearest to the player who took a loaded item apart), else that
--- of a member next to its position; nil when there is none any more
local function entry_member_net(surface, force, entry)
	local a = entry.anchor
	if a and a.valid and N.network_of(a) then return N.network_of(a) end
	local _, net = member_at(surface, entry.position, force)
	return net
end

--- the working ME network an entry belongs to now (nil: none, or it does not work)
local function entry_network(surface, force, entry)
	local net = entry_member_net(surface, force, entry)
	return net and N.usable(net) and net or nil
end

local function add_to(t, contents)
	for _, name in pairs(sorted_names(contents)) do t[name] = (t[name] or 0) + contents[name] end
end

--- keep `contents` for recovery; an entry of the same network (or the same spot) takes it. `anchor`: the ME
--- member the fluid was recovered at
local function pool_add(s, surface, force, position, contents, anchor)
	local list = entries_of(s, surface.index, force.name, true)
	local pos = { x = position.x or position[1], y = position.y or position[2] }
	local net
	if anchor and anchor.valid then net = N.network_of(anchor) else anchor, net = member_at(surface, pos, force) end
	local into
	for _, entry in ipairs(list) do
		local n = net and entry_member_net(surface, force, entry)
		if (n and n.id == net.id) or (entry.position.x == pos.x and entry.position.y == pos.y) then
			into = entry
			break
		end
	end
	if not into and #list >= MAX_ENTRIES then into = list[#list] end
	if not into then
		into = { position = pos, contents = {}, anchor = anchor }
		list[#list + 1] = into
	end
	add_to(into.contents, contents)
end

--- { fluid -> amount } over all entries of a surface and force (nil if there are none)
local function pool_sum(s, surface_index, force_name)
	local list = entries_of(s, surface_index, force_name)
	if not list then return nil end
	local out = {}
	for _, entry in ipairs(list) do add_to(out, entry.contents) end
	return next(out) and out or nil
end

--- drop empty entries and lists
local function pool_tidy(s, surface_index, force_name)
	local r = recovered(s)
	local per = r[surface_index]
	if not per then return end
	local list = per[force_name]
	if list then
		for i = #list, 1, -1 do
			if not next(list[i].contents) then table.remove(list, i) end
		end
		if #list == 0 then per[force_name] = nil end
	end
	if not next(per) then r[surface_index] = nil end
end

--- "Name [gps=x,y,surface]" for the chat
local function where(entity_name, surface, position)
	local proto = prototypes.entity[entity_name] or prototypes.item[entity_name]
	return { "", proto and proto.localised_name or entity_name,
		string.format(" [gps=%d,%d,%s]", math.floor(position.x or position[1]), math.floor(position.y or position[2]), surface.name) }
end

--- a report goes to `target` (a player or a force)
local function report(target, message)
	if target and target.valid then target.print(message) end
end

--- A drive record whose entity vanished without an event (another mod's destroy(), surface.clear()):
--- its contents go into the recovery pool of the surface it stood on.
local function rescue_orphan(s, rec)
	if not (next(rec.contents) and rec.surface and rec.force) then return end
	local surface = game.get_surface(rec.surface)
	local force = game.forces[rec.force]
	if not (surface and force) then return end      -- the surface is gone: on_pre_surface_deleted reported it
	pool_add(s, surface, force, rec.position or { 0, 0 }, rec.contents)
	report(force, { "fork-me-fluids.drive-vanished", { "entity-name." .. rec.name }, M.fluid_list(rec.contents, 8), surface.name })
	rec.contents, rec.used = {}, 0
end

--- drives standing in `net`, oldest first; records of removed entities are dropped on the way
local function drives_in(s, net)
	local list = {}
	if not net then return list end
	local id = net.id
	for unit, rec in pairs(s.drives) do
		local e = rec.entity
		if not e.valid then
			rescue_orphan(s, rec)
			s.drives[unit] = nil
		else
			rec.surface, rec.force = e.surface.index, e.force.name     -- saves from before the recovery, changed forces
			if not rec.position then rec.position = e.position end
			local n = network_of(e)
			if n and n.id == id then list[#list + 1] = rec end
		end
	end
	table.sort(list, function(a, b) return a.entity.unit_number < b.entity.unit_number end)
	return list
end

local function list_totals(list)
	local out = {}
	for _, rec in pairs(list) do
		for name, amount in pairs(rec.contents) do out[name] = (out[name] or 0) + amount end
	end
	return out
end

local function list_capacity(list)
	local total, used = 0, 0
	for _, rec in pairs(list) do
		total = total + rec.capacity
		used = used + rec.used
	end
	return total, used
end

local function list_count(list, name)
	local n = 0
	for _, rec in pairs(list) do n = n + (rec.contents[name] or 0) end
	return n
end

--- store up to `amount` of `name`: drives that already hold the fluid first, then the rest
local function list_insert(list, name, amount)
	if not (amount and amount > 0) then return 0 end
	local left = amount
	for pass = 1, 2 do
		for _, rec in pairs(list) do
			if left <= EPS then break end
			if pass == 2 or rec.contents[name] then
				local room = rec.capacity - rec.used
				if room > 0 then
					local put = math.min(room, left)
					rec_add(rec, name, put)
					left = left - put
				end
			end
		end
	end
	if left < EPS then left = 0 end
	return amount - left
end

local function list_remove(list, name, amount)
	if not (amount and amount > 0) then return 0 end
	local left = amount
	for _, rec in pairs(list) do
		if left <= EPS then break end
		local have = rec.contents[name] or 0
		if have > 0 then
			local take = math.min(have, left)
			rec_add(rec, name, -take)
			left = left - take
		end
	end
	if left < EPS then left = 0 end
	return amount - left
end

--- Fluid that lost its drive: into the fluid drives of the ME network at `position` (as far as
--- they have room), the rest into the recovery pool of the surface and force. Returns the amounts
--- moved into drives and the amounts pooled ({ fluid -> amount } each).
local function salvage(s, contents, surface, force, position, radius)
	local moved, pooled = {}, {}
	local anchor = position and member_at(surface, position, force, radius)
	local net = anchor and N.active_of(anchor)
	local list = drives_in(s, net)
	for _, name in pairs(sorted_names(contents)) do
		local amount = contents[name]
		if type(amount) == "number" and amount > EPS and prototypes.fluid[name] then
			local put = list_insert(list, name, amount)
			if put > 0 then moved[name] = put end
			if amount - put > EPS then pooled[name] = amount - put end
		end
	end
	if next(pooled) then pool_add(s, surface, force, position, pooled, anchor) end
	return moved, pooled
end

--- the chat lines for a salvage: `what` names the event ({ "fork-me-fluids.salvage-destroyed", where })
local function report_salvage(target, what, moved, pooled)
	if next(moved) then report(target, { "fork-me-fluids.salvage-moved", what, M.fluid_list(moved, 8) }) end
	if next(pooled) then report(target, { "fork-me-fluids.salvage-pooled", what, M.fluid_list(pooled, 8) }) end
end

--- A drive takes over recovered fluid of its surface and force, as far as it has room: the entries of
--- its own ME network and those whose network no longer exists, or every entry with `any` (the
--- "take over" button). Returns the amounts taken ({ fluid -> amount }, empty for none).
local function take_recovered(s, rec, entity, any)
	local surface, force = entity.surface, entity.force
	local list = entries_of(s, surface.index, force.name)
	local taken = {}
	if not list then return taken end
	local net = network_of(entity)
	for _, entry in ipairs(list) do
		if rec.capacity - rec.used <= EPS then break end
		local ok = any
		if not ok then
			local n = entry_member_net(surface, force, entry)
			ok = not n or (net and n.id == net.id)
		end
		if ok then
			for _, name in pairs(sorted_names(entry.contents)) do
				local amount = entry.contents[name]
				local room = rec.capacity - rec.used
				if not prototypes.fluid[name] then
					entry.contents[name] = nil     -- the fluid no longer exists
				elseif room > EPS then
					local put = math.min(room, amount)
					rec_add(rec, name, put)
					taken[name] = (taken[name] or 0) + put
					entry.contents[name] = amount - put > EPS and amount - put or nil
				end
			end
		end
	end
	pool_tidy(s, surface.index, force.name)
	if next(taken) then
		local left = pool_sum(s, surface.index, force.name)
		report(force, { "fork-me-fluids.recovered-taken", where(entity.name, surface, entity.position), M.fluid_list(taken, 8) })
		if left then report(force, { "fork-me-fluids.recovered-left", M.fluid_list(left, 8) }) end
	end
	return taken
end

--- "[gps=x,y,surface]" of a position
local function gps(surface, position)
	return string.format("[gps=%d,%d,%s]", math.floor(position.x or position[1]), math.floor(position.y or position[2]), surface.name)
end

--- Existing drives pull recovered fluid in: RECOVERED_PER_STEP entries per step (round robin over every
--- surface and force), each into the drives of the ME network at its position, as far as
--- they have room. An entry that is fully taken over is reported once. `drives_of(net)` gives the drive
--- list of a network (cached per step).
local function pull_recovered(s, drives_of)
	local r = s.recovered
	if not (r and next(r)) then return end
	local surfaces = {}
	for index in pairs(r) do surfaces[#surfaces + 1] = index end
	table.sort(surfaces)
	local refs = {}                                     -- { surface index, force name, entry }, a fixed order
	for _, index in ipairs(surfaces) do
		for _, force_name in ipairs(sorted_names(r[index])) do
			for _, entry in ipairs(r[index][force_name]) do refs[#refs + 1] = { index, force_name, entry } end
		end
	end
	local n = #refs
	if n == 0 then return end
	local cursor = s.rcursor or 1
	if cursor > n then cursor = 1 end
	local count = math.min(RECOVERED_PER_STEP, n)
	s.rcursor = cursor + count
	local touched = {}
	for k = 0, count - 1 do
		local ref = refs[(cursor - 1 + k) % n + 1]
		local surface, force, entry = game.get_surface(ref[1]), game.forces[ref[2]], ref[3]
		local net = surface and force and next(entry.contents) and entry_network(surface, force, entry)
		if net then
			local list = drives_of(net)
			local total, used = list_capacity(list)
			if total - used > EPS then
				for _, name in pairs(sorted_names(entry.contents)) do
					local amount = entry.contents[name]
					if prototypes.fluid[name] then
						local put = list_insert(list, name, amount)
						if put > 0 then
							entry.moved = entry.moved or {}
							entry.moved[name] = (entry.moved[name] or 0) + put
							entry.contents[name] = amount - put > EPS and amount - put or nil
						end
					end
				end
				if not next(entry.contents) then
					report(force, { "fork-me-fluids.recovered-returned", gps(surface, entry.position), M.fluid_list(entry.moved or {}, 8) })
					touched[#touched + 1] = ref
				end
			end
		end
	end
	for _, ref in ipairs(touched) do pool_tidy(s, ref[1], ref[2]) end
end

local function spot_key(surface_index, position)
	return surface_index .. ":" .. position.x .. ":" .. position.y
end

--- Keep the contents of a drive that is being replaced (fast replace, upgrade) for the drive built at
--- the same spot; its item gets no fluid.
local function hold_for_replacement(s, rec, entity)
	local pending = s.replacing or {}
	s.replacing = pending
	local key = spot_key(entity.surface.index, entity.position)
	local p = pending[key]
	if not p then
		p = { contents = {}, tick = game.tick, surface = entity.surface.index, force = entity.force.name,
			position = entity.position, name = entity.name }
		pending[key] = p
	end
	add_to(p.contents, rec.contents)
	rec.contents, rec.used = {}, 0
end

--- The drive built at the spot of a replaced drive takes its contents, as far as it has room; the rest
--- goes into the network, then into the recovered fluid.
local function take_replaced(s, rec, entity)
	local pending = s.replacing
	if not pending then return end
	local key = spot_key(entity.surface.index, entity.position)
	local p = pending[key]
	if not (p and p.force == entity.force.name) then return end
	pending[key] = nil
	local rest = {}
	for _, name in pairs(sorted_names(p.contents)) do
		local amount = p.contents[name]
		if prototypes.fluid[name] then
			local put = math.min(math.max(rec.capacity - rec.used, 0), amount)
			if put > 0 then rec_add(rec, name, put) end
			if amount - put > EPS then rest[name] = amount - put end
		end
	end
	if next(rest) then
		local moved, pooled = salvage(s, rest, entity.surface, entity.force, entity.position)
		report_salvage(entity.force, { "fork-me-fluids.salvage-replaced", where(entity.name, entity.surface, entity.position) }, moved, pooled)
	end
end

--- Contents held for a replacement that no drive took (no drive was built at that spot): into the
--- network at that spot, then into the recovered fluid. `all`: also those of this tick.
local function flush_replacing(s, all)
	local pending = s.replacing
	if not (pending and next(pending)) then return end
	for _, key in ipairs(sorted_names(pending)) do
		local p = pending[key]
		if all or p.tick < game.tick then
			pending[key] = nil
			local surface, force = game.get_surface(p.surface), game.forces[p.force]
			if surface and force and next(p.contents) then
				local moved, pooled = salvage(s, p.contents, surface, force, p.position)
				report_salvage(force, { "fork-me-fluids.salvage-removed", where(p.name, surface, p.position) }, moved, pooled)
			end
		end
	end
end

--- A player's build at `position` this tick: a drive that player mines at that spot in the same tick is
--- fast replaced (on_pre_build comes before the mined events of the replaced entity).
local function note_pre_build(s, player_index, surface_index, position)
	s.prebuild = s.prebuild or {}
	s.prebuild[player_index] = { tick = game.tick, surface = surface_index, position = position }
end

local function is_fast_replace(s, player_index, entity)
	local b = s.prebuild and s.prebuild[player_index]
	if not (b and b.tick == game.tick and b.surface == entity.surface.index) then return false end
	local pos = entity.position
	local bx, by = b.position.x or b.position[1], b.position.y or b.position[2]
	return math.abs(bx - pos.x) < 1 and math.abs(by - pos.y) < 1
end

--- The fluid on the drive items in `inventory` (e.g. the items a hand craft consumes) is salvaged at
--- `position` and removed from the items. `target` (player or force) gets the report.
--- Returns the amounts moved into drives and pooled.
local function salvage_items(s, inventory, surface, force, position, target)
	local contents = {}
	for i = 1, #inventory do
		local stack = inventory[i]
		if stack.valid_for_read and drive_capacity(stack.name) and stack.is_item_with_tags then
			local tags = stack.tags
			local stored = tags and tags[TAG]
			if type(stored) == "table" then
				for name, amount in pairs(stored) do
					if type(name) == "string" and type(amount) == "number" and amount > 0 then
						contents[name] = (contents[name] or 0) + amount * stack.count
					end
				end
				--- a fresh stack: no tags, no description (the fluid is not on the item any more)
				stack.set_stack{ name = stack.name, count = stack.count, quality = stack.quality }
			end
		end
	end
	if not next(contents) then return {}, {} end
	local moved, pooled = salvage(s, contents, surface, force, position, HAND_RADIUS)
	report_salvage(target, { "fork-me-fluids.salvage-item" }, moved, pooled)
	return moved, pooled
end

--- { fluid -> amount } stored in the network
function M.totals(net) return list_totals(drives_in(state(), net)) end

--- total capacity and used units of the network's fluid drives
function M.capacity(net) return list_capacity(drives_in(state(), net)) end

function M.count(net, name) return list_count(drives_in(state(), net), name) end

--- Store `amount` of `name` in the network. Returns the amount stored (less when the drives are full).
function M.insert(net, name, amount) return list_insert(drives_in(state(), net), name, amount) end

--- Take `amount` of `name` out of the network. Returns the amount taken.
function M.remove(net, name, amount) return list_remove(drives_in(state(), net), name, amount) end

--- drives of the network as plain data (for GUIs and tests)
function M.drives(net)
	local out = {}
	for _, rec in pairs(drives_in(state(), net)) do
		out[#out + 1] = { unit = rec.entity.unit_number, name = rec.name, capacity = rec.capacity, used = rec.used }
	end
	return out
end

--- LocalisedString "1234 Water, 12.3 Steam" for a { fluid -> amount } table
function M.fluid_list(contents, limit)
	local names = {}
	for name in pairs(contents) do names[#names + 1] = name end
	table.sort(names)
	local out = { "" }
	for i, name in ipairs(names) do
		if i > (limit or 8) then out[#out + 1] = ", ..." break end
		local proto = prototypes.fluid[name]
		out[#out + 1] = { "", (i > 1 and ", " or "") .. format(contents[name]) .. " ", proto and proto.localised_name or name }
	end
	return out
end

--- Put the contents of a drive onto its item (the stack the mined drive turned into)
local function pack_drive(s, entity, stack)
	local rec = s.drives[entity.unit_number]
	if not (rec and next(rec.contents)) then return false end
	if not (stack and stack.valid_for_read and stack.name == entity.name and stack.is_item_with_tags) then return false end
	local contents = {}
	for name, amount in pairs(rec.contents) do contents[name] = amount end
	local tags = stack.tags or {}
	tags[TAG] = contents
	stack.tags = tags
	stack.custom_description = { "fork-me-fluids.drive-item-holds", M.fluid_list(contents, 6) }
	rec.contents, rec.used = {}, 0          -- moved, not copied
	return true
end

--- A placed drive: an item that carried fluids gives them to the new entity (capped by its capacity)
local function unpack_drive(s, entity, tags)
	local rec = drive_record(s, entity)
	local stored = tags and tags[TAG]
	if type(stored) == "table" then
		local names = {}
		for name in pairs(stored) do names[#names + 1] = name end
		table.sort(names)
		for _, name in pairs(names) do
			local amount = stored[name]
			if type(name) == "string" and type(amount) == "number" and amount > 0 and prototypes.fluid[name] then
				local room = rec.capacity - rec.used
				if room > 0 then rec_add(rec, name, math.min(room, amount)) end
			end
		end
	end
	return rec
end

--------------------------------------------------------------------------------
--- interfaces
--------------------------------------------------------------------------------

local function register_interface(s, entity)
	local unit = entity.unit_number
	if not s.interfaces[unit] then
		s.interfaces[unit] = { entity = entity, mode = "import", fluid = nil, level = interface_volume(), status = "ok" }
		s.ilist[#s.ilist + 1] = unit
	end
	return s.interfaces[unit]
end

local function drop_interface(s, unit)
	s.interfaces[unit] = nil
	for i = #s.ilist, 1, -1 do
		if s.ilist[i] == unit then table.remove(s.ilist, i) end
	end
end

--- Move what the tank holds into the network (as much as fits); returns the amount moved.
--- Pipes and tanks connected without a pump share one fluid segment with the interface, and the
--- whole segment is taken (the interface's own box would only hold its share of it).
local function tank_to_network(e, held, list)
	local total, used = list_capacity(list)
	if total <= 0 then return 0, "no-drive" end
	local room = total - used
	if room <= EPS then return 0, "full" end
	local fb = e.fluidbox
	local segment = fb.get_fluid_segment_contents(1)
	local available = math.max(held.amount, (segment and segment[held.name] or 0) + 1)   -- segment counts are rounded
	local removed = e.remove_fluid{ name = held.name, amount = math.min(available, room) }
	if removed <= 0 then return 0, "ok" end
	local stored = list_insert(list, held.name, removed)
	if stored < removed then               -- cannot happen (room was checked), but never lose fluid
		e.insert_fluid{ name = held.name, amount = removed - stored, temperature = held.temperature }
	end
	return stored, "ok"
end

--- one import or export pass of an interface; `drives_of(net)` gives the drive list of a network
local function interface_step(rec, drives_of)
	local e = rec.entity
	local net = network_of(e)
	if not net then rec.status = "no-network" return end
	local list = drives_of(net)
	local held = e.fluidbox[1]
	if held and held.amount <= EPS then held = nil end
	if rec.mode == "import" then
		if not held then rec.status = "empty" return end
		local _, status = tank_to_network(e, held, list)
		rec.status = status
		return
	end
	--- export
	local fluid = rec.fluid
	if not fluid then rec.status = "no-fluid" return end
	if held and held.name ~= fluid then      -- another fluid in the tank: into the network first
		tank_to_network(e, held, list)
		held = e.fluidbox[1]
		if held and held.amount <= EPS then held = nil end
		if held and held.name ~= fluid then rec.status = "blocked" return end
	end
	local want = rec.level - (held and held.amount or 0)
	if want <= EPS then rec.status = "ok" return end
	local avail = list_count(list, fluid)
	if avail <= EPS then
		rec.status = list_capacity(list) > 0 and "empty-network" or "no-drive"
		return
	end
	local inserted = e.insert_fluid{ name = fluid, amount = math.min(want, avail) }
	if inserted > 0 then list_remove(list, fluid, inserted) end
	rec.status = "ok"
end

--------------------------------------------------------------------------------
--- GUIs
--------------------------------------------------------------------------------

--- breadth first search for a named element below `root`
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

--- drive GUI (screen frame, opened with the "open GUI" key on a drive)
local function drive_gui_refresh(player, g)
	local frame = player.gui.screen[DRIVE_FRAME]
	local entity = g.entity
	if not (frame and entity.valid) then return false end
	local s = state()
	local rec = s.drives[entity.unit_number] or drive_record(s, entity)
	local net = network_of(entity)
	local names, sig = {}, {}
	for name, amount in pairs(rec.contents) do names[#names + 1] = name end
	table.sort(names)
	for i, name in ipairs(names) do sig[i] = name .. "=" .. rec.contents[name] end
	local pool = pool_sum(s, entity.surface.index, entity.force.name)
	local pool_sig = {}
	for i, name in ipairs(pool and sorted_names(pool) or {}) do pool_sig[i] = name .. "=" .. pool[name] end
	sig = table.concat(sig, ",") .. "|" .. (net and net.id or "-") .. "|" .. table.concat(pool_sig, ",")
	if g.sig == sig then return true end
	g.sig = sig
	find(frame, "fork_mefd_used").caption = { "fork-me-fluids.drive-used", format(rec.used), format(rec.capacity) }
	local status = find(frame, "fork_mefd_status")
	status.caption = net and "" or { "fork-me-fluids.status-no-network" }
	status.visible = net == nil
	local pool_row = find(frame, "fork_mefd_pool_row")
	if pool_row then                           -- (not in a window opened before the recovery existed)
		pool_row.visible = pool ~= nil
		if pool then find(frame, "fork_mefd_pool").caption = { "fork-me-fluids.recovered-waiting", M.fluid_list(pool, 8) } end
	end
	local grid = find(frame, "fork_mefd_grid")
	grid.clear()
	for _, name in ipairs(names) do
		local proto = prototypes.fluid[name]
		if proto then
			grid.add{ type = "sprite", sprite = "fluid/" .. name }
			local label = grid.add{ type = "label", caption = proto.localised_name }
			label.style.minimal_width = 160
			grid.add{ type = "label", caption = format(rec.contents[name]) }
		end
	end
	if #names == 0 then
		grid.add{ type = "label", caption = { "fork-me-fluids.drive-empty" } }
	end
	return true
end

local function close_drive_gui(player)
	local frame = player.gui.screen[DRIVE_FRAME]
	if frame then frame.destroy() end
	state().gui[player.index] = nil
end

local function open_drive(player, entity)
	local s = state()
	local g = s.gui[player.index]
	local frame = player.gui.screen[DRIVE_FRAME]
	if g and frame and g.entity == entity then
		player.opened = frame
		return
	end
	close_drive_gui(player)
	frame = player.gui.screen.add{ type = "frame", name = DRIVE_FRAME, direction = "vertical", caption = entity.localised_name }
	frame.auto_center = true
	frame.add{ type = "label", name = "fork_mefd_used" }
	local status = frame.add{ type = "label", name = "fork_mefd_status" }
	status.style.single_line = false
	status.style.maximal_width = 320
	--- recovered fluid of the surface (destroyed drives, taken apart drive items), with a take over button
	local pool_row = frame.add{ type = "flow", name = "fork_mefd_pool_row", direction = "horizontal" }
	pool_row.style.vertical_align = "center"
	local pool = pool_row.add{ type = "label", name = "fork_mefd_pool" }
	pool.style.single_line = false
	pool.style.maximal_width = 240
	pool_row.add{ type = "button", name = "fork_mefd_take", caption = { "fork-me-fluids.recovered-take" },
		tooltip = { "fork-me-fluids.recovered-take-tooltip" } }
	local scroll = frame.add{ type = "scroll-pane", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = 300
	scroll.style.minimal_width = 320
	scroll.add{ type = "table", name = "fork_mefd_grid", column_count = 3 }
	s.gui[player.index] = { entity = entity }
	player.opened = frame
	drive_gui_refresh(player, s.gui[player.index])
end

--- interface panel (relative to the storage tank GUI, only for the fluid interface)
local function interface_gui_refresh(frame, rec)
	local e = rec.entity
	if not (frame and frame.valid and e.valid) then return end
	local net = network_of(e)
	local status = find(frame, "fork_mef_status")
	status.caption = { "fork-me-fluids.status-" .. (rec.status or "ok") }
	local line = find(frame, "fork_mef_network")
	if net then
		local list = drives_in(state(), net)
		local total, used = list_capacity(list)
		local held = rec.fluid and list_count(list, rec.fluid) or nil
		if held then
			line.caption = { "fork-me-fluids.network-line-fluid", format(used), format(total), format(held), prototypes.fluid[rec.fluid].localised_name }
		else
			line.caption = { "fork-me-fluids.network-line", format(used), format(total) }
		end
	else
		line.caption = { "fork-me-fluids.status-no-network" }
	end
	local fluid_row = find(frame, "fork_mef_fluid_row")
	fluid_row.visible = rec.mode == "export"
	find(frame, "fork_mef_level_row").visible = rec.mode == "export"
	--- another player (or a script) may have changed the settings: mirror the record
	local switch = find(frame, "fork_mef_mode")
	local want = rec.mode == "export" and "right" or "left"
	if switch.switch_state ~= want then switch.switch_state = want end
	local button = find(frame, "fork_mef_fluid")
	if button.elem_value ~= rec.fluid then button.elem_value = rec.fluid end
	local level = find(frame, "fork_mef_level")
	if tonumber(level.text) ~= rec.level then level.text = format(rec.level) end
end

local function open_interface_gui(player, entity)
	local s = state()
	local rec = s.interfaces[entity.unit_number] or register_interface(s, entity)
	local rel = player.gui.relative
	if rel[IFACE_FRAME] then rel[IFACE_FRAME].destroy() end
	local frame = rel.add{
		type = "frame", name = IFACE_FRAME, direction = "vertical", caption = { "fork-me-fluids.interface-title" },
		anchor = { gui = defines.relative_gui_type.storage_tank_gui, position = defines.relative_gui_position.right, names = { entity.name } },
		tags = { unit = entity.unit_number },
	}
	local help = frame.add{ type = "label", caption = { "fork-me-fluids.interface-help" } }
	help.style.single_line = false
	help.style.maximal_width = 300
	frame.add{
		type = "switch", name = "fork_mef_mode",
		left_label_caption = { "fork-me-fluids.mode-import" }, left_label_tooltip = { "fork-me-fluids.mode-import-tooltip" },
		right_label_caption = { "fork-me-fluids.mode-export" }, right_label_tooltip = { "fork-me-fluids.mode-export-tooltip" },
		switch_state = rec.mode == "export" and "right" or "left",
	}
	local fluid_row = frame.add{ type = "flow", name = "fork_mef_fluid_row", direction = "horizontal" }
	fluid_row.style.vertical_align = "center"
	fluid_row.add{ type = "label", caption = { "fork-me-fluids.fluid" } }
	fluid_row.add{ type = "choose-elem-button", name = "fork_mef_fluid", elem_type = "fluid", fluid = rec.fluid }
	local level_row = frame.add{ type = "flow", name = "fork_mef_level_row", direction = "horizontal" }
	level_row.style.vertical_align = "center"
	level_row.add{ type = "label", caption = { "fork-me-fluids.level", format(interface_volume()) } }
	local level = level_row.add{ type = "textfield", name = "fork_mef_level", text = format(rec.level), numeric = true,
		allow_decimal = false, allow_negative = false, lose_focus_on_confirm = true }
	level.style.width = 80
	local status = frame.add{ type = "label", name = "fork_mef_status" }
	status.style.single_line = false
	status.style.maximal_width = 300
	local line = frame.add{ type = "label", name = "fork_mef_network" }
	line.style.single_line = false
	line.style.maximal_width = 300
	interface_gui_refresh(frame, rec)
end

local function close_interface_gui(player)
	local frame = player.gui.relative[IFACE_FRAME]
	if frame then frame.destroy() end
end

--- the interface record and frame an element of the panel belongs to
local function interface_of_element(el)
	local frame = el
	while frame and frame.valid and frame.name ~= IFACE_FRAME do frame = frame.parent end
	if not (frame and frame.valid) then return nil end
	local unit = frame.tags and frame.tags.unit
	local rec = unit and state().interfaces[unit]
	if not (rec and rec.entity.valid) then return nil end
	return rec, frame
end

local function set_level(rec, text)
	local n = tonumber(text)
	if not n then return end
	rec.level = math.max(0, math.min(interface_volume(), math.floor(n)))
end

--- Set an interface from a script: mode "import"/"export", fluid name (export; false clears it), level (export)
function M.set_interface(entity, mode, fluid, level)
	if not (entity and entity.valid and entity.name == interface_name()) then return false end
	local rec = register_interface(state(), entity)
	if mode == "import" or mode == "export" then rec.mode = mode end
	if fluid ~= nil then rec.fluid = fluid and prototypes.fluid[fluid] and fluid or nil end   -- false clears it
	if level ~= nil then set_level(rec, level) end
	return true
end

function M.get_interface(entity)
	local rec = entity and entity.valid and state().interfaces[entity.unit_number]
	if not rec then return nil end
	return { mode = rec.mode, fluid = rec.fluid, level = rec.level, status = rec.status }
end

--------------------------------------------------------------------------------
--- step
--------------------------------------------------------------------------------

--- one fluid step: run by the I/O step of scripts/fork-me-io.lua, which registers the interval
function M.on_step()
	local s = storage.fork_me_fluids
	if not s then return end
	flush_replacing(s)
	local cache = {}                                        -- network id -> drive list, once per step
	local function drives_of(net)
		local list = cache[net.id]
		if not list then
			list = drives_in(s, net)
			cache[net.id] = list
		end
		return list
	end
	local n = #s.ilist
	if n > 0 then
		for _ = 1, math.min(INTERFACES_PER_STEP, n) do
			if s.icursor > #s.ilist then s.icursor = 1 end
			local unit = s.ilist[s.icursor]
			local rec = s.interfaces[unit]
			if rec and rec.entity.valid then
				interface_step(rec, drives_of)
				s.icursor = s.icursor + 1
			else
				drop_interface(s, unit)
			end
			if #s.ilist == 0 then break end
		end
	end
	pull_recovered(s, drives_of)
	if next(s.gui) then
		for index, g in pairs(s.gui) do
			local player = game.get_player(index)
			if not (player and player.valid) then
				s.gui[index] = nil
			else
				local frame = player.gui.screen[DRIVE_FRAME]
				--- dying or disconnecting closes the GUI without an event: the frame must not linger
				if not (frame and g.entity.valid and player.opened == frame and player.can_reach_entity(g.entity)) then
					close_drive_gui(player)
				else
					drive_gui_refresh(player, g)
				end
			end
		end
	end
	for _, player in pairs(game.connected_players) do
		local frame = player.gui.relative[IFACE_FRAME]
		if frame then
			local rec = interface_of_element(frame)
			if rec then interface_gui_refresh(frame, rec) else frame.destroy() end
		end
	end
end


--------------------------------------------------------------------------------
--- events (build/mine from control.lua, GUI from the terminal module and here)
--------------------------------------------------------------------------------

--- The tags of the drive item a build event consumed: `event.tags` (ghost tags, script_raised_revive),
--- the robot's `event.stack`, or the player's `event.consumed_items`.
function M.tags_from_event(event)
	if type(event.tags) == "table" and (event.tags[TAG] or event.tags[IFACE_TAG]) then return event.tags end
	local stack = event.stack
	if stack and stack.valid and stack.valid_for_read and stack.is_item_with_tags then
		local tags = stack.tags
		if tags and tags[TAG] then return tags end
	end
	local consumed = event.consumed_items
	if consumed and consumed.valid then
		for i = 1, #consumed do
			local st = consumed[i]
			if st.valid_for_read and st.is_item_with_tags then
				local tags = st.tags
				if tags and tags[TAG] then return tags end
			end
		end
	end
	return nil
end

--- `tags`: the item tags of the placed drive item, or the blueprint tags of a built interface ghost
--- (see tags_from_event); `source`: the original of a cloned entity (an interface copies its settings,
--- a cloned drive starts empty)
function M.on_built(entity, tags, source)
	if not (entity and entity.valid) then return end
	local s = state()
	if drive_capacity(entity.name) then
		local rec = unpack_drive(s, entity, tags)
		take_replaced(s, rec, entity)
		take_recovered(s, rec, entity)
	elseif entity.name == interface_name() then
		register_interface(s, entity)
		local settings = type(tags) == "table" and tags[IFACE_TAG] or nil
		if type(settings) == "table" then
			M.set_interface(entity, settings.mode, settings.fluid or false, settings.level)
		elseif source and source.valid and source.name == entity.name then
			local from = M.get_interface(source)
			if from then M.set_interface(entity, from.mode, from.fluid or false, from.level) end
		end
	end
end

--- copy mode, fluid and level from one interface to another (shift right click, shift left click)
function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (src and src.valid and dst and dst.valid and src.name == interface_name() and dst.name == interface_name()) then return end
	local from = M.get_interface(src) or { mode = "import", level = interface_volume() }
	M.set_interface(dst, from.mode, from.fluid or false, from.level)
	for _, player in pairs(game.connected_players) do       -- an open panel shows the new settings
		local frame = player.gui.relative[IFACE_FRAME]
		if frame then
			local rec = interface_of_element(frame)
			if rec then interface_gui_refresh(frame, rec) end
		end
	end
end

--- A blueprint with fluid interfaces carries their settings as entity tag (from the autocrafting
--- module's blueprint handler). Drive contents are not blueprint data (only the drive item carries fluid).
function M.tag_blueprint(bp, mapping)
	local s = storage.fork_me_fluids
	if not s then return end
	for index, entity in pairs(mapping) do
		if entity.valid and entity.name == interface_name() then
			local rec = s.interfaces[entity.unit_number]
			if rec then
				bp.set_blueprint_entity_tag(index, IFACE_TAG, { mode = rec.mode, fluid = rec.fluid, level = rec.level })
			end
		end
	end
end

--- mined by a player, a robot or a space platform: a drive's fluids go onto the item in `buffer`,
--- an interface's content goes back into the network (as far as the drives have room). A drive that is
--- being replaced (`replacing`: fast replace, upgrade) keeps its fluids for the new drive instead.
function M.on_mined(entity, buffer, replacing)
	if not (entity and entity.valid) then return end
	local s = state()
	local unit = entity.unit_number
	local rec = s.drives[unit]
	if rec then
		if replacing and next(rec.contents) then
			hold_for_replacement(s, rec, entity)
		elseif buffer and buffer.valid then
			for i = 1, #buffer do
				local stack = buffer[i]
				if stack.valid_for_read and stack.name == entity.name then
					pack_drive(s, entity, stack)
					break
				end
			end
		end
		s.drives[unit] = nil
		if next(rec.contents) then             -- no drive item in the buffer (another mod changed it): salvage
			local moved, pooled = salvage(s, rec.contents, entity.surface, entity.force, entity.position)
			report_salvage(entity.force, { "fork-me-fluids.salvage-removed", where(entity.name, entity.surface, entity.position) }, moved, pooled)
		end
	elseif s.interfaces[unit] then
		local held = entity.fluidbox[1]
		local net = held and held.amount > EPS and network_of(entity)
		if net then tank_to_network(entity, held, drives_in(s, net)) end
		drop_interface(s, unit)
	else
		for _, hook in pairs(M.mined_hooks) do hook(entity) end
	end
end

--- destroyed (`died`) or removed by a script without mining: a drive's fluids go into the other fluid
--- drives of its network, the rest into the recovery pool of the surface (an interface's tank content
--- is lost like that of any tank)
function M.on_removed(entity, died)
	if not (entity and entity.valid) then return end
	local s = state()
	local unit = entity.unit_number
	local rec = s.drives[unit]
	if rec then
		s.drives[unit] = nil                   -- first: the drive itself takes nothing
		if next(rec.contents) then
			local moved, pooled = salvage(s, rec.contents, entity.surface, entity.force, entity.position)
			local what = { died and "fork-me-fluids.salvage-destroyed" or "fork-me-fluids.salvage-removed",
				where(entity.name, entity.surface, entity.position) }
			report_salvage(entity.force, what, moved, pooled)
		end
	elseif s.interfaces[unit] then
		drop_interface(s, unit)
	end
end

--- the "open GUI" key on a selected entity (routed from the terminal's custom input handler)
function M.on_open_input(player, entity)
	if not (entity and entity.valid and drive_capacity(entity.name)) then return false end
	if not player.can_reach_entity(entity) then return true end
	open_drive(player, entity)
	return true
end

function M.on_gui_opened(event)
	if event.gui_type == defines.gui_type.entity and event.entity and event.entity.valid
		and event.entity.name == interface_name() then
		open_interface_gui(game.get_player(event.player_index), event.entity)
		return true
	end
	return false
end

function M.on_gui_closed(event)
	local player = game.get_player(event.player_index)
	if not player then return false end
	if event.element and event.element.valid and event.element.name == DRIVE_FRAME then
		close_drive_gui(player)
		return true
	end
	if event.gui_type == defines.gui_type.entity and event.entity and event.entity.valid
		and event.entity.name == interface_name() then
		close_interface_gui(player)
		return true
	end
	return false
end

function M.on_gui_text_changed(event)
	local el = event.element
	if not (el and el.valid and el.name == "fork_mef_level") then return false end
	local rec, frame = interface_of_element(el)
	if rec then
		set_level(rec, el.text)
		interface_gui_refresh(frame, rec)
	end
	return true
end

function M.on_player_removed(index)
	local s = state()
	s.gui[index] = nil
	if s.prebuild then s.prebuild[index] = nil end
end

--- the GUI events below are registered by the terminal module, which routes them (one handler per event)
function M.on_gui_switch_state_changed(event)
	local el = event.element
	if not (el and el.valid and el.name == "fork_mef_mode") then return false end
	local rec, frame = interface_of_element(el)
	if not rec then return true end
	rec.mode = el.switch_state == "right" and "export" or "import"
	rec.status = "ok"
	interface_gui_refresh(frame, rec)
	return true
end

function M.on_gui_elem_changed(event)
	local el = event.element
	if not (el and el.valid and el.name == "fork_mef_fluid") then return false end
	local rec, frame = interface_of_element(el)
	if not rec then return true end
	local value = el.elem_value
	rec.fluid = type(value) == "string" and prototypes.fluid[value] and value or nil
	rec.status = "ok"
	interface_gui_refresh(frame, rec)
	return true
end

function M.on_gui_confirmed(event)
	local el = event.element
	if not (el and el.valid and el.name == "fork_mef_level") then return false end
	local rec, frame = interface_of_element(el)
	if not rec then return true end
	set_level(rec, el.text)
	el.text = format(rec.level)
	interface_gui_refresh(frame, rec)
	return true
end

--- (a filter can only be given when one event is registered at a time)
--- How the mined drive and the drive built in its place are linked (see docs/AE2.md, "Upgrades"):
---   * by hand (fast replace, also onto a drive marked for upgrade): on_pre_build of the player at that
---     spot, then on_player_mined_entity of the old drive, then on_built_entity of the new one, one tick;
---   * robots and space platforms (upgrade planner): the old drive is still marked for upgrade in
---     on_robot_mined_entity / on_space_platform_mined_entity, then the built event follows in the same tick.
--- The key is the spot (surface and position); what no drive takes is salvaged by the next step.
function M.on_mined_event(event)
	local entity = event.entity
	local replacing = false
	if entity.valid and drive_capacity(entity.name) then
		if event.player_index then
			replacing = is_fast_replace(state(), event.player_index, entity)
		else
			replacing = entity.to_be_upgraded()
		end
	end
	M.on_mined(entity, event.buffer, replacing)
end
local on_mined_event = M.on_mined_event
script.on_event(defines.events.on_pre_build, function(event)
	local player = game.get_player(event.player_index)
	if player and event.position then note_pre_build(state(), event.player_index, player.surface.index, event.position) end
end)

--- a hand craft that consumes a loaded drive item (the disassembly recipe, hand crafting only): the
--- fluid is salvaged at the player's position before the item is gone (from control.lua)
function M.on_pre_player_crafted_item(event)
	local items = event.items
	local player = game.get_player(event.player_index)
	if not (items and items.valid and player) then return end
	salvage_items(state(), items, player.surface, player.force, player.position, player)
end

--- A cancelled hand craft returns its items. The fluid of a drive item among them was salvaged when
--- the craft was queued, so a drive item that comes back with its tags must not carry it twice.
function M.on_player_cancelled_crafting(event)
	local items = event.items
	if not (items and items.valid) then return end
	for i = 1, #items do
		local stack = items[i]
		if stack.valid_for_read and drive_capacity(stack.name) and stack.is_item_with_tags then
			local tags = stack.tags
			if tags and tags[TAG] then stack.set_stack{ name = stack.name, count = stack.count, quality = stack.quality } end
		end
	end
end

--- A surface is about to be deleted (from control.lua): its drives and its recovered fluid are lost; the
--- forces are told what.
function M.on_pre_surface_deleted(surface_index)
	local s = storage.fork_me_fluids
	if not s then return end
	local surface = game.get_surface(surface_index)
	local lost = {}                            -- force name -> { fluid -> amount }
	local function add(force_name, contents)
		local t = lost[force_name] or {}
		lost[force_name] = t
		for name, amount in pairs(contents) do t[name] = (t[name] or 0) + amount end
	end
	for unit, rec in pairs(s.drives) do
		local e = rec.entity
		local on_it = e.valid and e.surface.index == surface_index or (not e.valid and rec.surface == surface_index)
		if on_it then
			if next(rec.contents) then add(e.valid and e.force.name or rec.force, rec.contents) end
			s.drives[unit] = nil
		end
	end
	for key, p in pairs(s.replacing or {}) do
		if p.surface == surface_index then
			add(p.force, p.contents)
			s.replacing[key] = nil
		end
	end
	local per = recovered(s)[surface_index]
	if per then
		for force_name, list in pairs(per) do
			for _, entry in ipairs(list) do add(force_name, entry.contents) end
		end
		recovered(s)[surface_index] = nil
	end
	for _, force_name in pairs(sorted_names(lost)) do
		local force = game.forces[force_name]
		if force and next(lost[force_name]) then
			report(force, { "fork-me-fluids.surface-lost", surface and surface.name or tostring(surface_index), M.fluid_list(lost[force_name], 8) })
		end
	end
end

--- The drive of an open drive GUI takes over the recovered fluid of its surface ("take over" button).
function M.on_gui_click(event)
	local el = event.element
	if not (el and el.valid and el.name == "fork_mefd_take") then return false end
	local player = game.get_player(event.player_index)
	local s = state()
	local g = player and s.gui[player.index]
	if g and g.entity.valid then
		local rec = s.drives[g.entity.unit_number] or drive_record(s, g.entity)
		if not next(take_recovered(s, rec, g.entity, true)) then
			player.print({ "fork-me-fluids.recovered-no-room" })
		end
		g.sig = nil
		drive_gui_refresh(player, g)
	end
	return true
end

--- Rebuild the registries from the world. Drive contents are kept (matched by unit number),
--- interface settings too; open GUIs are closed.
function M.on_configuration_changed()
	local s = state()
	flush_replacing(s, true)
	for _, rec in pairs(s.drives) do
		if not rec.entity.valid then rescue_orphan(s, rec) end
	end
	local names = {}
	for name in pairs(mod_data().drives) do names[#names + 1] = name end
	names[#names + 1] = interface_name()
	local drives, interfaces = {}, {}
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = names }) do
			local unit = e.unit_number
			if drive_capacity(e.name) then
				local old = s.drives[unit]
				local rec = { entity = e, name = e.name, capacity = drive_capacity(e.name), contents = {}, used = 0,
					surface = e.surface.index, force = e.force.name, position = e.position }
				if old and old.contents then
					local list = {}
					for n in pairs(old.contents) do list[#list + 1] = n end
					table.sort(list)
					for _, n in pairs(list) do
						local a = old.contents[n]
						if prototypes.fluid[n] and type(a) == "number" and a > 0 then
							rec_add(rec, n, math.min(a, rec.capacity - rec.used))
						end
					end
				end
				drives[unit] = rec
			else
				local old = s.interfaces[unit]
				interfaces[unit] = {
					entity = e,
					mode = old and old.mode == "export" and "export" or "import",
					fluid = old and old.fluid and prototypes.fluid[old.fluid] and old.fluid or nil,
					level = old and old.level or interface_volume(),
					status = "ok",
				}
				if old then
					local keep = interfaces[unit]
					keep.level = math.max(0, math.min(interface_volume(), keep.level))
				end
			end
		end
	end
	--- recovered fluid: fluids that no longer exist are dropped; surfaces and forces that are gone take
	--- theirs with them (deleting a surface reports it, see on_pre_surface_deleted)
	local kept = {}
	for surface_index, per in pairs(recovered(s)) do
		if game.get_surface(surface_index) then
			for force_name, list in pairs(per) do
				if game.forces[force_name] then
					local entries = {}
					for _, entry in ipairs(list) do
						local clean = {}
						for name, amount in pairs(entry.contents or {}) do
							if prototypes.fluid[name] and type(amount) == "number" and amount > EPS then clean[name] = amount end
						end
						if next(clean) and entry.position then
							entries[#entries + 1] = { position = entry.position, contents = clean, moved = entry.moved, anchor = entry.anchor }
						end
					end
					if #entries > 0 then
						kept[surface_index] = kept[surface_index] or {}
						kept[surface_index][force_name] = entries
					end
				end
			end
		end
	end
	s.recovered = kept
	s.drives, s.interfaces, s.ilist, s.icursor = drives, interfaces, {}, 1
	for unit in pairs(interfaces) do s.ilist[#s.ilist + 1] = unit end
	table.sort(s.ilist)
	for index in pairs(s.gui) do
		local player = game.get_player(index)
		if player then close_drive_gui(player) else s.gui[index] = nil end
	end
	for _, player in pairs(game.players) do
		close_interface_gui(player)
		local opened = player.opened
		if opened and player.opened_gui_type == defines.gui_type.entity and opened.valid and opened.name == interface_name() then
			player.opened = nil
		end
	end
end

--- Other mods and the devcheck runtime test use the same code paths
remote.add_interface("gregtorio-me-fluids", {
	count = function(entity, fluid)
		local net = network_of(entity)
		return net and M.count(net, fluid) or 0
	end,
	totals = function(entity)
		local net = network_of(entity)
		return net and M.totals(net) or {}
	end,
	capacity = function(entity)
		local net = network_of(entity)
		if not net then return 0, 0 end
		return M.capacity(net)
	end,
	insert = function(entity, fluid, amount)
		local net = network_of(entity)
		return net and M.insert(net, fluid, amount) or 0
	end,
	remove = function(entity, fluid, amount)
		local net = network_of(entity)
		return net and M.remove(net, fluid, amount) or 0
	end,
	drives = function(entity)
		local net = network_of(entity)
		return net and M.drives(net) or {}
	end,
	drive = function(entity)
		local rec = entity and entity.valid and state().drives[entity.unit_number]
		if not rec then return nil end
		local contents = {}
		for n, a in pairs(rec.contents) do contents[n] = a end
		return { name = rec.name, capacity = rec.capacity, used = rec.used, contents = contents }
	end,
	set_interface = function(entity, mode, fluid, level) return M.set_interface(entity, mode, fluid, level) end,
	get_interface = function(entity) return M.get_interface(entity) end,
	--- settings paste between two interfaces (the handler of on_entity_settings_pasted)
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	--- what mining a drive does: the contents go onto `stack` (an item stack of the same drive item)
	pack_drive = function(entity, stack) return pack_drive(state(), entity, stack) end,
	--- what placing a drive item does: `tags` are the item's tags
	unpack_drive = function(entity, tags) M.on_built(entity, tags) end,
	--- recovered fluid ({ fluid -> amount }, all entries) of a surface (LuaSurface, name or index) and force
	recovered = function(surface, force)
		local index = type(surface) == "number" and surface
		if not index then
			local sf = game.get_surface(type(surface) == "userdata" and surface.index or surface)
			index = sf and sf.index
		end
		local force_name = type(force) == "userdata" and force.name or force or "player"
		return index and pool_sum(state(), index, force_name) or {}
	end,
	--- what a hand craft does with the drive items it consumes: `inventory` holds them, the fluid is
	--- salvaged at `position` on `surface` for `force`; returns moved, pooled
	salvage_items = function(inventory, surface, force, position)
		local sf = game.get_surface(type(surface) == "userdata" and surface.index or surface)
		local fo = game.forces[type(force) == "userdata" and force.name or force or "player"]
		if not (sf and fo and inventory and inventory.valid) then return {}, {} end
		return salvage_items(state(), inventory, sf, fo, position, fo)
	end,
	--- what the "take over" button of a drive's GUI does; returns the amounts taken
	--- what the build and mine events of a hand fast replace do, in the engine's order (a headless test has
	--- no player): on_pre_build of `player_index` at `position`, on_player_mined_entity with `buffer`
	pre_build = function(player_index, surface, position)
		local sf = game.get_surface(type(surface) == "userdata" and surface.index or surface)
		if sf then note_pre_build(state(), player_index, sf.index, position) end
	end,
	player_mined = function(entity, buffer, player_index)
		on_mined_event{ entity = entity, buffer = buffer, player_index = player_index }
	end,
	--- contents held for replacements that no drive has taken yet ({ fluid -> amount } over all spots)
	replacing = function()
		local out = {}
		for _, p in pairs(state().replacing or {}) do add_to(out, p.contents) end
		return out
	end,
	take_recovered = function(entity)
		if not (entity and entity.valid and drive_capacity(entity.name)) then return {} end
		local s = state()
		return take_recovered(s, s.drives[entity.unit_number] or drive_record(s, entity), entity, true)
	end,
})

return M
