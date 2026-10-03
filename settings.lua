--- Runtime settings (issue #5, docs/PERFORMANCE.md): the budgets of the scheduler (scripts/fork-me-schedule.lua) and the
--- speed of the buses. Map settings (runtime-global), so every player of a game has the same values. The defaults
--- come from the benchmark (tools/devcheck/devcheck.py bench).
local function int(name, order, default, min, max)
	return { type = "int-setting", name = name, setting_type = "runtime-global", order = order,
		default_value = default, minimum_value = min, maximum_value = max }
end

data:extend({
	int("me-network-io-visits-per-tick", "a", 16, 1, 1000),
	int("me-network-storage-bus-visits-per-tick", "b", 8, 1, 1000),
	int("me-network-maintainer-checks-per-tick", "c", 4, 1, 1000),
	int("me-network-circuit-updates-per-second", "d", 10, 1, 6000),
	int("me-network-crafting-jobs-per-tick", "e", 1, 1, 100),
	int("me-network-bus-items-per-second", "f", 256, 1, 100000),
	int("me-network-bus-fluid-per-second", "g", 4000, 1, 10000000),
	int("me-network-idle-limit", "h", 300, 15, 3600),
	int("me-network-storage-bus-idle-limit", "i", 120, 15, 3600),
})
