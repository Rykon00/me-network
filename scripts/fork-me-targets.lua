--------------------------------------------------------------------------------
--- ME NETWORK: WHAT A BUS WORKS WITH (issue #3; docs/ME-REWORK.md "Items and fluids in one block")
--- One place for the entity types the import bus, the export bus and the storage bus use, and for the checks
--- every unified block shares: the tile in front of a rotatable block, an ME block (never a target), whether an
--- entity has fluid boxes (by prototype, cached: a machine without a fluid recipe has its boxes switched off but
--- still counts, so the decision does not change with the recipe).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

M.FRONT = {
	[defines.direction.north] = { 0, -1 }, [defines.direction.east] = { 1, 0 },
	[defines.direction.south] = { 0, 1 }, [defines.direction.west] = { -1, 0 },
}

--- the inventory an import bus takes from, by entity type
M.OUTPUT = {
	["assembling-machine"] = defines.inventory.crafter_output, ["furnace"] = defines.inventory.crafter_output,
	["container"] = defines.inventory.chest, ["logistic-container"] = defines.inventory.chest,
	["infinity-container"] = defines.inventory.chest,   -- the editor's infinity chest
}
--- the inventory an export bus puts into, by entity type
M.INPUT = {
	["assembling-machine"] = defines.inventory.crafter_input, ["furnace"] = defines.inventory.crafter_input,
	["container"] = defines.inventory.chest, ["logistic-container"] = defines.inventory.chest,
	["infinity-container"] = defines.inventory.chest,
	["lab"] = defines.inventory.lab_input,               -- issue #86: one slot per science pack the lab uses
}
--- the entity types whose input has slots of their own for what they use: an export bus tops each filtered item up to
--- one stack of it, a crafting machine up to two crafts of its recipe when that is more (issue #382); a chest is filled
--- as far as it has room
M.SLOTTED = { ["assembling-machine"] = true, ["furnace"] = true, ["lab"] = true }
--- the inventory a storage bus makes network storage, by entity type
M.STORAGE = {
	["container"] = defines.inventory.chest, ["logistic-container"] = defines.inventory.chest,
	["infinity-container"] = defines.inventory.chest, ["cargo-wagon"] = defines.inventory.cargo_wagon,
}

--- the hidden side tanks of the ME Interface (prototypes/network.lua)
M.SIDE = "me-network-interface-side"

--- the position of the tile in front of a rotatable block
function M.front(entity)
	local d = M.FRONT[entity.direction] or M.FRONT[defines.direction.north]
	return { entity.position.x + d[1], entity.position.y + d[2] }
end

--- an ME block or a hidden part of one: never the target of a bus
function M.is_me(entity)
	return N.kind_of(entity.name) ~= nil or entity.name == M.SIDE
end

local fluid_cache = {}
--- does the entity's prototype have fluid boxes?
function M.has_fluid_boxes(entity)
	local name = entity.name
	local v = fluid_cache[name]
	if v == nil then
		local p = entity.prototype
		v = (p.fluidbox_prototypes and #p.fluidbox_prototypes > 0) or false
		fluid_cache[name] = v
	end
	return v
end

--- Issue #487 (Factorio 2.1): LuaEntity::fluidbox and LuaFluidBox are gone; a fluid box is read and written through
--- its entity (get_fluid, set_fluid, clear_fluid, fluids_count, ...), whose methods the hot paths call through N.bound
--- (issue #115). These keep the meaning the LuaFluidBox calls of this mod had.

--- the capacity of box `i` as LuaFluidBox.get_capacity gave it: its fluid segment's (a tank with the pipes it joins),
--- else the box's own (a crafting machine's box has no segment)
function M.capacity(entity, i)
	local B = N.bound(entity)
	if B.has_fluid_segment(i) then return B.get_fluid_segment_capacity(i) end
	return B.get_fluid_capacity(i)
end

--- the id of box `i`'s fluid segment, nil without one (2.1's get_fluid_segment_id raises an error then)
function M.segment_id(entity, i)
	local B = N.bound(entity)
	return B.has_fluid_segment(i) and B.get_fluid_segment_id(i) or nil
end

--- what box `i`'s fluid segment holds, { [name] = amount } (LuaFluidBox.get_fluid_segment_contents; a segment holds one
--- fluid), nil without a segment
function M.segment_contents(entity, i)
	local B = N.bound(entity)
	if not B.has_fluid_segment(i) then return nil end
	local f = B.get_fluid_segment_fluid(i)
	return f and { [f.name] = f.amount } or {}
end

--- is anything connected to box `i`? (LuaFluidBox.get_connections)
function M.connected(entity, i)
	return #N.bound(entity).get_fluid_box_neighbours(i) > 0
end

--- box `i` set to `fluid`, or emptied (nil): LuaFluidBox's `fluidbox[i] = fluid` (set_fluid takes no nil since 2.1)
function M.set_fluid(entity, i, fluid)
	if fluid then N.bound(entity).set_fluid(i, fluid) else N.bound(entity).clear_fluid(i) end
end

--- A stand-in of 2.0's LuaFluidBox of a machine for the code that works on its boxes as a whole (autocrafting): `fb[i]`
--- reads and writes box i, `#fb` is the number of boxes, and the methods this mod called (get_prototype, get_filter,
--- get_capacity, get_connections, get_pipe_connections, get_fluid_segment_id, get_fluid_segment_contents) keep their
--- meaning. Made per call, as `entity.fluidbox` was.
local BOX_METHODS = {
	get_prototype = function(e, i) return N.bound(e).get_fluid_box_prototype(i) end,
	get_filter = function(e, i) return M.fluid_filter(e, i) end,
	get_capacity = function(e, i) return M.capacity(e, i) end,
	get_connections = function(e, i) return N.bound(e).get_fluid_box_neighbours(i) end,
	get_pipe_connections = function(e, i) return N.bound(e).get_fluid_box_pipe_connections(i) end,
	get_fluid_segment_id = function(e, i) return M.segment_id(e, i) end,
	get_fluid_segment_contents = function(e, i) return M.segment_contents(e, i) end,
}
local BOX_MT = {
	__index = function(b, k)
		local e = rawget(b, "entity")
		if type(k) == "number" then return N.bound(e).get_fluid(k) end
		local f = BOX_METHODS[k]
		if f then
			local m = function(i) return f(e, i) end
			rawset(b, k, m)
			return m
		end
		if k == "valid" then return e.valid end
		if k == "owner" then return e end
		return nil
	end,
	__newindex = function(b, k, v)
		if type(k) == "number" then M.set_fluid(rawget(b, "entity"), k, v) end
	end,
	__len = function(b) return rawget(b, "entity").fluids_count end,
}
function M.boxes(entity)
	return setmetatable({ entity = entity }, BOX_MT)
end
--- the same for an entity or a scan's view of one (autocrafting's machine_view keeps its own `fluidbox`)
function M.boxes_of(machine)
	if type(machine) == "table" then return machine.fluidbox end
	return M.boxes(machine)
end

--- the filter of box `i` as LuaFluidBox.get_filter gave it: { name, minimum_temperature, maximum_temperature }, nil
--- without one. 2.1's get_fluid_filter is the fluid's prototype only; a crafting machine's input box takes its recipe's
--- temperature range, so for a crafting machine (`crafter`; nil: by the entity's type) the range comes from the recipe's
--- ingredients of that fluid (the narrowest of them) as 2.0's box filter had it
M.CRAFTER = { ["assembling-machine"] = true, furnace = true, ["rocket-silo"] = true }
function M.fluid_filter(entity, i, crafter)
	local p = N.bound(entity).get_fluid_filter(i)
	if not p then return nil end
	local f = { name = p.name }
	if crafter == nil then crafter = M.CRAFTER[entity.type] end
	local r = crafter and entity.get_recipe()
	for _, ing in pairs(r and r.ingredients or {}) do
		if ing.type == "fluid" and ing.name == p.name then
			local lo, hi = ing.minimum_temperature, ing.maximum_temperature
			if lo and (not f.minimum_temperature or lo > f.minimum_temperature) then f.minimum_temperature = lo end
			if hi and (not f.maximum_temperature or hi < f.maximum_temperature) then f.maximum_temperature = hi end
		end
	end
	return f
end

--- Issue #59, lever 5: an entity's storage inventory, made once per load (`get_inventory` makes a new object at every
--- call: 144 bytes of garbage). Keyed by the entity object the caller keeps in its record (weak: an entity no longer
--- kept leaves); an object that turned invalid is made anew. Nothing is saved.
local inventories = setmetatable({}, { __mode = "k" })
local inventory_index = setmetatable({}, { __mode = "k" })
--- the inventory `index` of the entity (nil when it has none)
function M.inventory(entity, index)
	local inv = inventories[entity]
	if not (inv and inventory_index[entity] == index and inv.valid) then
		inv = entity.get_inventory(index)
		inventories[entity], inventory_index[entity] = inv, index
	end
	return inv
end

return M
