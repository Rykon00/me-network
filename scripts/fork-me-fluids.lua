--------------------------------------------------------------------------------
--- FORK AE2: FLUIDS IN THE ME NETWORK (runtime; issue #68 step R2, prototypes/fluids.lua)
---   * Fluids are stored in fluid storage cells in ME Drives, by the storage engine of
---     scripts/fork-me-network.lua (keys "fluid/<name>", one temperature per fluid). This module offers the
---     fluid calls the other modules use (totals, count, insert, remove, capacity) on top of it.
---   * The ME Fluid Interface (a small storage tank) is gone since issue #3 of me-network: the ME Interface has
---     fluid sides (scripts/fork-me-io.lua). The settings of old ones (mode, fluid, level) stay in
---     storage.fork_me_fluids.interfaces until scripts/fork-me-unify.lua has replaced them.
---   * Temperature: the network stores fluids by name only. Importing drops the temperature, exporting (and
---     the autocrafting hand-over) uses the fluid's default temperature.
--- Nothing runs per tick.
--- State: storage.fork_me_fluids (the settings of old fluid interfaces; the old fluid drives, their recovered
--- fluid and the replacement spots of saves from before R2 are converted by scripts/fork-me-migrate.lua and dropped).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

--- functions called with every mined entity that is no fluid interface (autocrafting rescues the fluid of a
--- leased machine); registered at load time, so nothing is stored
M.mined_hooks = {}

--------------------------------------------------------------------------------
--- prototype data and state
--------------------------------------------------------------------------------

local md_cache                       -- prototype data, read once per load (reading mod-data copies the table)
local function mod_data()
	if not md_cache then
		local md = prototypes.mod_data["fork-me-fluids"]
		md_cache = md and md.data or { interface = {} }
	end
	return md_cache
end

--- the old ME Fluid Interface (issue #3: replaced by scripts/fork-me-unify.lua)
local function interface_name()
	return mod_data().interface.name or "me-fluid-interface"
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
--- events (build/mine from control.lua, GUI from the terminal module)
--------------------------------------------------------------------------------

--- mined by a player, a robot or a space platform (from control.lua): the mined hooks (autocrafting rescues the
--- fluid of a leased machine)
function M.on_mined_event(event)
	local entity = event.entity
	if not (entity and entity.valid) then return end
	if entity.name == interface_name() then return end
	for _, hook in pairs(M.mined_hooks) do hook(entity) end
end

--- After scripts/fork-me-unify.lua: the settings of old fluid interfaces that are gone are dropped.
function M.on_configuration_changed()
	local s = storage.fork_me_fluids
	if not (s and s.interfaces) then return end
	for unit, rec in pairs(s.interfaces) do
		if not (rec.entity and rec.entity.valid and rec.entity.name == interface_name()) then s.interfaces[unit] = nil end
	end
	s.ilist, s.icursor = nil, nil
	if not next(s.interfaces) then storage.fork_me_fluids = nil end
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
})

return M
