--- Issue #519: settings paste (Shift + right click on a block, Shift + left click on another). The game pastes between two
--- entities, and raises on_entity_settings_pasted, only when it can paste between their types itself (two lamps, two
--- constant combinators, two crafting machines, two electric energy interfaces) or when the source's prototype names the
--- destination in `additional_pastable_entities`; and it copies nothing from an entity, or onto one, whose
--- `allow_copy_paste` is false (the default of an electric energy interface). So every block whose paste handler in
--- scripts/ copies its settings is here, with the blocks it pastes onto and the module of the handler: data.lua gives
--- each its list (what is there already stays) and `allow_copy_paste`, data-final-fixes.lua the crafting machines theirs.
--- `devcheck check` (tools/devcheck/checkmod/data-final-fixes.lua) fails when a final prototype lacks a target or the
--- flag, and when a module of scripts/ has a paste handler that this file names neither as a handler nor in BUILTIN.
--- Required by data.lua, data-final-fixes.lua and the check mod; it has no prototypes of its own.

local M = {}

local MONITORS = { "me-storage-monitor", "me-conversion-monitor", "me-throughput-monitor" }

--- source -> { handler = the module in scripts/, targets = the blocks it pastes onto }
M.SOURCES = {
	--- the priority and the cell partitions; the ME Chest's one cell has them too (issue #68 step R3, #229)
	["me-drive"] = { handler = "fork-me-network", targets = { "me-drive", "me-chest" } },
	["me-chest"] = { handler = "fork-me-network", targets = { "me-chest", "me-drive" } },
	--- a container has no settings of its own: the filters, sides, priority and cards (scripts/fork-me-io.lua)
	["me-network-interface"] = { handler = "fork-me-io", targets = { "me-network-interface" } },
	["me-import-bus"] = { handler = "fork-me-io", targets = { "me-import-bus" } },
	["me-export-bus"] = { handler = "fork-me-io", targets = { "me-export-bus" } },
	["me-storage-bus"] = { handler = "fork-me-storagebus", targets = { "me-storage-bus" } },
	["me-logistic-storage-bus"] = { handler = "fork-me-storagebus", targets = { "me-logistic-storage-bus" } },   -- (issue #506)
	["me-pattern-provider"] = { handler = "fork-me-autocraft", targets = { "me-pattern-provider" } },            -- (issue #80)
	["me-io-port"] = { handler = "fork-me-ioport", targets = { "me-io-port" } },                                 -- (mode, cards)
	["me-wireless-access-point"] = { handler = "fork-me-wireless", targets = { "me-wireless-access-point" } },   -- (boosters)
	--- the frequency; the game also pastes an electric energy interface's power settings, which the handler sets back
	["me-quantum-bridge"] = { handler = "fork-me-qbridge", targets = { "me-quantum-bridge" } },
	["me-wireless-link"] = { handler = "fork-me-qbridge", targets = { "me-wireless-link" } },
	--- the resource, the lock and the unit, between any two of the three kinds
	["me-storage-monitor"] = { handler = "fork-me-monitor", targets = MONITORS },
	["me-conversion-monitor"] = { handler = "fork-me-monitor", targets = MONITORS },
	["me-throughput-monitor"] = { handler = "fork-me-monitor", targets = MONITORS },
}

--- issue #12: the recipe of a crafting machine of every mod pasted onto these (scripts/fork-me-recipe-paste.lua)
M.MACHINE_TYPES = { "assembling-machine", "furnace", "rocket-silo" }
M.MACHINE_TARGETS = { "me-network-interface", "me-import-bus", "me-export-bus", "me-storage-bus" }
M.MACHINE_HANDLER = "fork-me-recipe-paste"

--- the modules whose handler only follows a paste the game makes between blocks of its own types
M.BUILTIN = {
	["fork-me-circuit"] = "the level maintainer (a lamp) and the circuit interface (a constant combinator)",
	["fork-me-emitter"] = "the level emitters (constant combinators)",
	["fork-me-connector"] = "the circuit connector (a lamp); a block with a connector pastes by its own list here",
}

--- the entity prototype `name` (any type), or nil
function M.entity(name)
	for t in pairs(defines.prototypes.entity) do
		local p = data.raw[t] and data.raw[t][name]
		if p then return p end
	end
end

--- `proto` pastes onto `targets` too (what its list has stays)
function M.add_targets(proto, targets)
	local list = proto.additional_pastable_entities or {}
	local listed = {}
	for _, name in pairs(list) do listed[name] = true end
	for _, name in ipairs(targets) do
		if not listed[name] then list[#list + 1] = name end
	end
	proto.additional_pastable_entities = list
end

--- data.lua: every source of SOURCES gets its targets and allow_copy_paste
function M.apply()
	for name, spec in pairs(M.SOURCES) do
		local proto = M.entity(name)
		if proto then
			proto.allow_copy_paste = true
			M.add_targets(proto, spec.targets)
		end
	end
end

return M
