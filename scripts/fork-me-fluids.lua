--------------------------------------------------------------------------------
--- FORK AE2: FLUIDS IN THE ME NETWORK (runtime; issue #68 step R2, prototypes/122-fork-ae2-fluids.lua)
---   * Fluids are stored in fluid storage cells in ME Drives, by the storage engine of
---     scripts/fork-me-network.lua (keys "fluid/<name>", one temperature per fluid). This module offers the
---     fluid calls the other modules use (totals, count, insert, remove, capacity) on top of it.
---   * ME Fluid Interface: a small storage tank. In import mode (the default) its content is moved into the
---     network, in export mode it is filled with a chosen fluid up to a chosen level. Pumps and pipes connect
---     to it like to any tank. Mode, fluid and level live in storage.fork_me_fluids.interfaces and are set in a
---     window (scripts/fork-me-windows.lua); they are copied by settings paste and cloning and kept in blueprints (entity
---     tag "fork_me_fluid_interface").
---   * Temperature: the network stores fluids by name only. Importing drops the temperature, exporting (and
---     the autocrafting hand-over) uses the fluid's default temperature.
--- Work per step: INTERFACES_PER_STEP interfaces (round robin), called by the
--- I/O step of fork-me-io.lua every 15 ticks. Nothing runs per tick.
--- State: storage.fork_me_fluids (interfaces only; the old fluid drives, their recovered fluid and the
--- replacement spots of saves from before R2 are converted by scripts/fork-me-migrate.lua and dropped).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

--- functions called with every mined entity that is no fluid interface (autocrafting rescues the fluid of a
--- leased machine); registered at load time, so nothing is stored
M.mined_hooks = {}

local INTERFACES_PER_STEP = 8
local EPS = 1e-6                    -- fluid amounts are fixed point (1/2^24); below this a box counts as empty
local IFACE_TAG = "fork_me_fluid_interface"   -- blueprint tag of an interface's settings { mode, fluid, level }

--------------------------------------------------------------------------------
--- prototype data and state
--------------------------------------------------------------------------------

local function mod_data()
	local md = prototypes.mod_data["fork-me-fluids"]
	return md and md.data or { interface = {} }
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
		s = { interfaces = {}, ilist = {}, icursor = 1 }      -- unit_number -> { entity, mode, fluid, level, status }
		storage.fork_me_fluids = s
	end
	return s
end

--- the working ME network of an entity (scripts/fork-me-network.lua), nil if none
local function network_of(entity)
	return N.active_of(entity)
end

--- "1234" or "12.3" for the GUI
function M.format(amount)
	return N.amount_text(amount)
end
local format = M.format

--------------------------------------------------------------------------------
--- the fluid calls of the other modules (autocrafting, circuit interface, terminal)
--------------------------------------------------------------------------------

--- { fluid -> amount } stored in the network
function M.totals(net) return N.fluid_contents(net) end

--- capacity and use of the network's fluid cells, in units (8 per byte)
function M.capacity(net)
	if not N.usable(net) then return 0, 0 end
	local st = N.stats(net)
	return st.fbytes_total * 8, st.fbytes * 8
end

function M.count(net, name) return N.fluid_count(net, name) end

--- Store `amount` of `name` in the network. Returns the amount stored (less when the cells are full).
function M.insert(net, name, amount) return N.insert_fluid(net, name, amount) end

--- Take `amount` of `name` out of the network. Returns the amount taken.
function M.remove(net, name, amount) return N.extract_fluid(net, name, amount) end

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

--- Move what the tank holds into the network (as much as fits); returns the amount moved and a status.
--- Pipes and tanks connected without a pump share one fluid segment with the interface, and the
--- whole segment is taken (the interface's own box would only hold its share of it).
local function tank_to_network(e, held, net)
	local total = M.capacity(net)
	if total <= 0 then return 0, "no-drive" end
	local fb = e.fluidbox
	local segment = fb.get_fluid_segment_contents(1)
	local available = math.max(held.amount, (segment and segment[held.name] or 0) + 1)   -- segment counts are rounded
	local room = N.can_insert_fluid(net, held.name, available)
	if room <= EPS then return 0, "full" end
	local removed = e.remove_fluid{ name = held.name, amount = room }
	if removed <= 0 then return 0, "ok" end
	local stored = N.insert_fluid(net, held.name, removed)
	if stored < removed - EPS then          -- cannot happen (room was checked), but never lose fluid
		e.insert_fluid{ name = held.name, amount = removed - stored, temperature = held.temperature }
	end
	return stored, "ok"
end

--- one import or export pass of an interface
function M.interface_step(rec)
	local e = rec.entity
	local net = network_of(e)
	if not net then rec.status = "no-network" return end
	local held = e.fluidbox[1]
	if held and held.amount <= EPS then held = nil end
	if rec.mode == "import" then
		if not held then rec.status = "empty" return end
		local _, status = tank_to_network(e, held, net)
		rec.status = status
		return
	end
	--- export
	local fluid = rec.fluid
	if not fluid then rec.status = "no-fluid" return end
	if held and held.name ~= fluid then      -- another fluid in the tank: into the network first
		tank_to_network(e, held, net)
		held = e.fluidbox[1]
		if held and held.amount <= EPS then held = nil end
		if held and held.name ~= fluid then rec.status = "blocked" return end
	end
	local want = rec.level - (held and held.amount or 0)
	if want <= EPS then rec.status = "ok" return end
	local avail = N.fluid_count(net, fluid)
	if avail <= EPS then
		rec.status = M.capacity(net) > 0 and "empty-network" or "no-drive"
		return
	end
	local inserted = e.insert_fluid{ name = fluid, amount = math.min(want, avail) }
	if inserted > 0 then
		local got = N.extract_fluid(net, fluid, inserted)
		--- a fluid storage bus's segment had less than its snapshot: never duplicate
		if got < inserted - EPS then e.remove_fluid{ name = fluid, amount = inserted - got } end
	end
	rec.status = "ok"
end

--------------------------------------------------------------------------------
--- the window's logic (the window: scripts/fork-me-windows.lua)
--------------------------------------------------------------------------------

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
	local held = rec.entity.fluidbox[1]
	return { mode = rec.mode, fluid = rec.fluid, level = rec.level, status = rec.status, volume = interface_volume(),
		held = held and held.amount > EPS and { name = held.name, amount = held.amount } or nil }
end

--------------------------------------------------------------------------------
--- step (called by the I/O step of fork-me-io.lua, which registers the interval)
--------------------------------------------------------------------------------

function M.on_step()
	local s = storage.fork_me_fluids
	if not (s and s.ilist) then return end
	local n = #s.ilist
	if n > 0 then
		for _ = 1, math.min(INTERFACES_PER_STEP, n) do
			if s.icursor > #s.ilist then s.icursor = 1 end
			local unit = s.ilist[s.icursor]
			local rec = s.interfaces[unit]
			if rec and rec.entity.valid then
				M.interface_step(rec)
				s.icursor = s.icursor + 1
			else
				drop_interface(s, unit)
			end
			if #s.ilist == 0 then break end
		end
	end
end

--------------------------------------------------------------------------------
--- events (build/mine from control.lua, GUI from the terminal module)
--------------------------------------------------------------------------------

--- `tags`: the blueprint tags of a built interface ghost; `source`: the original of a cloned entity
function M.on_built(entity, tags, source)
	if not (entity and entity.valid and entity.name == interface_name()) then return end
	local s = state()
	register_interface(s, entity)
	local settings = type(tags) == "table" and tags[IFACE_TAG] or nil
	if type(settings) == "table" then
		M.set_interface(entity, settings.mode, settings.fluid or false, settings.level)
	elseif source and source.valid and source.name == entity.name then
		local from = M.get_interface(source)
		if from then M.set_interface(entity, from.mode, from.fluid or false, from.level) end
	end
end

--- copy mode, fluid and level from one interface to another (shift right click, shift left click)
function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (src and src.valid and dst and dst.valid and src.name == interface_name() and dst.name == interface_name()) then return end
	local from = M.get_interface(src) or { mode = "import", level = interface_volume() }
	M.set_interface(dst, from.mode, from.fluid or false, from.level)
end

--- A blueprint with fluid interfaces carries their settings as entity tag (from the autocrafting
--- module's blueprint handler).
function M.tag_blueprint(bp, mapping)
	local s = storage.fork_me_fluids
	if not (s and s.interfaces) then return end
	for index, entity in pairs(mapping) do
		if entity.valid and entity.name == interface_name() then
			local rec = s.interfaces[entity.unit_number]
			if rec then
				bp.set_blueprint_entity_tag(index, IFACE_TAG, { mode = rec.mode, fluid = rec.fluid, level = rec.level })
			end
		end
	end
end

--- mined by a player, a robot or a space platform (from control.lua): an interface's content goes back into
--- the network (as far as the cells have room); anything else goes to the mined hooks
function M.on_mined_event(event)
	local entity = event.entity
	if not (entity and entity.valid) then return end
	local s = state()
	local unit = entity.unit_number
	if unit and s.interfaces[unit] then
		local held = entity.fluidbox[1]
		local net = held and held.amount > EPS and network_of(entity)
		if net then tank_to_network(entity, held, net) end
		drop_interface(s, unit)
	else
		for _, hook in pairs(M.mined_hooks) do hook(entity) end
	end
end

--- destroyed or removed by a script: the interface's record goes (its tank content is lost like that of any tank)
function M.on_removed(entity)
	if not (entity and entity.valid and entity.unit_number) then return end
	local s = state()
	if s.interfaces[entity.unit_number] then drop_interface(s, entity.unit_number) end
end

--- Rebuild the interface records from the world (settings kept by unit number).
--- The old fluid state (drives, recovered fluid, replacement spots) was converted by the migration before.
function M.on_configuration_changed()
	local s = state()
	local old = s.interfaces or {}
	local interfaces = {}
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = interface_name() }) do
			local o = old[e.unit_number]
			interfaces[e.unit_number] = {
				entity = e,
				mode = o and o.mode == "export" and "export" or "import",
				fluid = o and o.fluid and prototypes.fluid[o.fluid] and o.fluid or nil,
				level = math.max(0, math.min(interface_volume(), o and o.level or interface_volume())),
				status = "ok",
			}
		end
	end
	storage.fork_me_fluids = { interfaces = interfaces, ilist = {}, icursor = 1 }
	s = storage.fork_me_fluids
	for unit in pairs(interfaces) do s.ilist[#s.ilist + 1] = unit end
	table.sort(s.ilist)
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
	--- capacity and use of the network's fluid cells in units
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
	set_interface = function(entity, mode, fluid, level) return M.set_interface(entity, mode, fluid, level) end,
	get_interface = function(entity) return M.get_interface(entity) end,
	--- one import or export pass of an interface now (what the step does)
	step = function(entity)
		if not (entity and entity.valid and entity.name == interface_name()) then return false end
		M.interface_step(register_interface(state(), entity))
		return true
	end,
	--- settings paste between two interfaces (the handler of on_entity_settings_pasted)
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
})

return M
