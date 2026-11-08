--------------------------------------------------------------------------------
--- STAND-INS OF GHOSTS (me-network issue #659): which entities are the stand-ins that scripts/fork-me-ghostwin.lua builds on
--- its hidden surface for the window of a ghost. A module without requires, so that the blocks that find each other by a
--- frequency (scripts/fork-me-qbridge.lua, scripts/fork-me-p2p.lua) can skip them: a stand-in must never take a frequency
--- from the blocks that stand in the world.
--- State: storage.fork_me_ghostwin.units = { [unit] = session key } (kept by scripts/fork-me-ghostwin.lua).
--------------------------------------------------------------------------------

local M = {}

--- is the entity (or the unit number) a stand-in of a ghost's window?
function M.is(entity_or_unit)
	local s = storage.fork_me_ghostwin
	if not (s and s.units and next(s.units)) then return false end
	local unit = entity_or_unit
	if type(unit) ~= "number" then
		if not (unit and unit.valid) then return false end
		unit = unit.unit_number
	end
	return unit ~= nil and s.units[unit] ~= nil
end

return M
