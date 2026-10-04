--- Runtime settings (issue #5, docs/PERFORMANCE.md): the budgets of the scheduler (scripts/fork-me-schedule.lua) and the
--- speed of the buses. Map settings (runtime-global), so every player of a game has the same values. The defaults
--- come from the benchmark (tools/devcheck/devcheck.py bench).
local function int(name, order, default, min, max)
	return { type = "int-setting", name = name, setting_type = "runtime-global", order = order,
		default_value = default, minimum_value = min, maximum_value = max }
end

--- Issue #38: the visits per tick are what is due, between a floor (the settings of 0.3.0, "at least") and a
--- ceiling ("at most"); when a block is due comes from the buffer on its other side (scripts/fork-me-io.lua, the
--- headroom rule), a block with nothing to do is probed or parked (scripts/fork-me-schedule.lua, M.run).
data:extend({
	int("me-network-io-visits-per-tick", "a1", 16, 1, 1000),
	int("me-network-io-visits-per-tick-max", "a2", 32, 1, 1000),
	int("me-network-storage-bus-visits-per-tick", "b1", 8, 1, 1000),
	int("me-network-storage-bus-visits-per-tick-max", "b2", 24, 1, 1000),
	int("me-network-maintainer-checks-per-tick", "c1", 4, 1, 1000),
	int("me-network-maintainer-checks-per-tick-max", "c2", 12, 1, 1000),
	int("me-network-circuit-updates-per-second", "d", 10, 1, 6000),
	int("me-network-crafting-jobs-per-tick", "e1", 1, 1, 100),
	int("me-network-crafting-jobs-per-tick-max", "e2", 2, 1, 100),
	int("me-network-bus-items-per-second", "f", 256, 1, 100000),
	int("me-network-bus-fluid-per-second", "g", 4000, 1, 10000000),
	int("me-network-idle-limit", "h", 300, 15, 3600),
	int("me-network-storage-bus-idle-limit", "i", 120, 15, 3600),
})
