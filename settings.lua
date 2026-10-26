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
	--- issue #506: the ME Logistic Storage Bus reads a whole logistic network per visit (0.28 ms at 473 storage chests)
	int("me-network-logistic-storage-bus-visits-per-tick", "b21", 1, 1, 100),
	int("me-network-logistic-storage-bus-visits-per-tick-max", "b22", 2, 1, 100),
	--- issue #531: the ME Logistic Interface (a visit pulls three chests in and fills or asks for its rows)
	int("me-network-logistic-interface-visits-per-tick", "b23", 2, 1, 1000),
	int("me-network-logistic-interface-visits-per-tick-max", "b24", 8, 1, 1000),
	--- issue #532: the keys an ME Logistic Interface asks for at most for what failed crafting starts lack
	int("me-network-logistic-interface-auto-keys", "b25", 20, 0, 200),
	int("me-network-io-port-visits-per-tick", "b3", 2, 1, 1000),         -- issue #386: the ME IO Port
	int("me-network-io-port-visits-per-tick-max", "b4", 8, 1, 1000),
	int("me-network-maintainer-checks-per-tick", "c1", 4, 1, 1000),
	int("me-network-maintainer-checks-per-tick-max", "c2", 12, 1, 1000),
	int("me-network-circuit-updates-per-second", "d", 10, 1, 6000),
	int("me-network-crafting-jobs-per-tick", "e1", 1, 1, 100),
	int("me-network-crafting-jobs-per-tick-max", "e2", 2, 1, 100),
	--- issue #415: the machine hand-overs of one job step at most (a CPU hands over 6 per step times 1 + its co-processors)
	int("me-network-crafting-ops-per-step", "e3", 1024, 6, 1000000),
	int("me-network-bus-items-per-second", "f", 256, 1, 100000),
	int("me-network-bus-fluid-per-second", "g", 4000, 1, 10000000),
	int("me-network-idle-limit", "h", 300, 15, 3600),
	int("me-network-storage-bus-idle-limit", "i", 120, 15, 3600),
	--- issue #150 / #168: the ME windows next to the game's own inventory window (a hand-over buffer); off: the inventory
	--- drawn by the mod in the window (issue #28)
	{ type = "bool-setting", name = "me-network-real-inventory", setting_type = "runtime-global", order = "z",
		default_value = true },
})
