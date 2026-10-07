--------------------------------------------------------------------------------
--- FORK AE2: FLUIDS IN THE ME NETWORK (runtime; issue #68 step R2, prototypes/fluids.lua)
---   * Fluids are stored in fluid storage cells in ME Drives, by the storage engine of
---     scripts/fork-me-network.lua (keys "fluid/<name>" and "fluid/<name>@<degrees>", issue #159). This module offers the
---     fluid calls the other modules use (totals, count, insert, remove, capacity) on top of it.
---   * The ME Fluid Interface (a small storage tank) is gone since issue #3 of me-network: the ME Interface has
---     fluid sides (scripts/fork-me-io.lua).
---   * Temperature (issue #159): the network keeps a fluid's temperature. Each temperature (whole degrees) is a key of
---     its own; the default temperature keeps the key of before ("fluid/<name>"). Nothing mixes in the network:
---     what came in at 250 °C goes out at 250 °C. The calls below take an optional temperature (nil: the default).
--- Nothing runs per tick. No state of its own (storage.fork_me_fluids held the old fluid interfaces until 0.5.0; issue
--- #146 drops it).
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
		md_cache = md and md.data or {}
	end
	return md_cache
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

--- { fluid -> amount } stored in the network (every temperature of a fluid added up)
function M.totals(net) return N.fluid_contents(net) end

--- { storage key -> amount }: one entry per fluid and temperature
function M.key_totals(net) return N.fluid_key_contents(net) end

--- capacity and use of the network's fluid cells, in units (8 per byte)
function M.capacity(net)
	if not N.usable(net) then return 0, 0 end
	local st = N.stats(net)
	return st.fbytes_total * 8, st.fbytes * 8
end

--- the amount of `name` at `temperature` (nil: the default temperature)
function M.count(net, name, temperature) return N.fluid_count(net, name, temperature) end

--- Store `amount` of `name` at `temperature` (nil: the default) in the network. Returns the amount stored (less when
--- the cells are full).
function M.insert(net, name, amount, temperature) return N.insert_fluid(net, name, amount, temperature) end

--- Take `amount` of `name` at `temperature` (nil: the default) out of the network. Returns the amount taken.
function M.remove(net, name, amount, temperature) return N.extract_fluid(net, name, amount, temperature) end

--- the same by storage key ("fluid/<name>", "fluid/<name>@<degrees>")
function M.insert_key(net, key, amount) return N.insert_fluid_key(net, key, amount) end
function M.remove_key(net, key, amount) return N.extract_fluid_key(net, key, amount) end

--- the fluid of a storage key as a LocalisedString: its name, and its temperature when that is not the default
--- ("Steam (250 °C)")
function M.key_name(key)
	local name, deg = N.split_fluid_key(key)
	local proto = prototypes.fluid[name]
	local ln = proto and proto.localised_name or name
	if not deg then return ln end
	return { "fork-me-gui.fluid-at-temperature", ln, tostring(deg) }
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

--------------------------------------------------------------------------------
--- events (build/mine from control.lua, GUI from the terminal module)
--------------------------------------------------------------------------------

--- mined by a player, a robot or a space platform (from control.lua): the mined hooks (autocrafting rescues the
--- fluid of a leased machine)
function M.on_mined_event(event)
	local entity = event.entity
	if not (entity and entity.valid) then return end
	for _, hook in pairs(M.mined_hooks) do hook(entity) end
end

--- issue #146: the old fluid interfaces' settings (0.5.0 dropped them when it replaced the interfaces)
function M.on_configuration_changed()
	storage.fork_me_fluids = nil
end

--- Other mods and the devcheck runtime test use the same code paths
remote.add_interface("gregtorio-me-fluids", {
	--- issue #159: `temperature` nil is the default temperature; "any" adds every temperature up
	count = function(entity, fluid, temperature)
		local net = network_of(entity)
		if not net then return 0 end
		if temperature == "any" then return N.fluid_total(net, fluid) end
		return M.count(net, fluid, temperature)
	end,
	totals = function(entity)
		local net = network_of(entity)
		return net and M.totals(net) or {}
	end,
	--- issue #159: { storage key -> amount }, one entry per temperature
	key_totals = function(entity)
		local net = network_of(entity)
		return net and M.key_totals(net) or {}
	end,
	--- capacity and use of the network's fluid cells in units
	capacity = function(entity)
		local net = network_of(entity)
		if not net then return 0, 0 end
		return M.capacity(net)
	end,
	insert = function(entity, fluid, amount, temperature)
		local net = network_of(entity)
		return net and M.insert(net, fluid, amount, temperature) or 0
	end,
	remove = function(entity, fluid, amount, temperature)
		local net = network_of(entity)
		return net and M.remove(net, fluid, amount, temperature) or 0
	end,
})

return M
