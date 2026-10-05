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
	["assembling-machine"] = defines.inventory.crafter_output, ["furnace"] = defines.inventory.furnace_result,
	["container"] = defines.inventory.chest, ["logistic-container"] = defines.inventory.chest,
	["infinity-container"] = defines.inventory.chest,   -- the editor's infinity chest
}
--- the inventory an export bus puts into, by entity type
M.INPUT = {
	["assembling-machine"] = defines.inventory.crafter_input, ["furnace"] = defines.inventory.furnace_source,
	["container"] = defines.inventory.chest, ["logistic-container"] = defines.inventory.chest,
	["infinity-container"] = defines.inventory.chest,
	["lab"] = defines.inventory.lab_input,               -- issue #86: one slot per science pack the lab uses
}
--- the entity types whose input has slots of their own for what they use: an export bus tops each filtered item up to
--- one stack of it (a chest is filled as far as it has room)
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

return M
