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
	--- issue #537: the automatic mode reads this many requester points per tick (about 25 us each) and offers at most this
	--- many stacks of an item
	int("me-network-logistic-interface-demand-points-per-tick", "b26", 2, 1, 1000),
	int("me-network-logistic-interface-auto-stacks", "b27", 1, 0, 100),
	--- issue #538: the safety net of what construction needs, logistic cells rescanned per second (132 us each on the
	--- maintainer's Nauvis; 0: none, the events alone)
	int("me-network-logistic-interface-construction-cells-per-second", "b28", 10, 0, 6000),
	--- issue #603: the wireless refill, players visited per tick (a visit reads the character's requests and trash)
	int("me-network-wireless-refill-visits-per-tick", "b29", 1, 1, 1000),
	int("me-network-wireless-refill-visits-per-tick-max", "b291", 4, 1, 1000),
	int("me-network-io-port-visits-per-tick", "b3", 2, 1, 1000),         -- issue #386: the ME IO Port
	int("me-network-io-port-visits-per-tick-max", "b4", 8, 1, 1000),
	int("me-network-p2p-visits-per-tick", "b5", 2, 1, 1000),             -- issue #633: the ME P2P tunnels on their own
	int("me-network-p2p-visits-per-tick-max", "b6", 8, 1, 1000),
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
})

--- Issue #680: the power use of the ME blocks, startup settings in kW (the defaults are the numbers of before). The data stage
--- reads them where the constants were (prototypes/api.lua, ME.power_w): the entities' energy, buffers and flow limits, the
--- descriptions and the mod-data the runtime reads agree. A mod that sets these numbers in its own data stage still wins.
--- Order "p...": one group in the settings list, named "Power use: ..." in the locale. A block that draws from the power grid
--- itself takes at least 1 W; what the ME Controller draws for a block may be 0.
local function power(name, order, default_kw, min_kw, max_kw)
	return { type = "double-setting", name = "me-network-power-" .. name, setting_type = "startup", order = "p" .. order,
		default_value = default_kw, minimum_value = min_kw, maximum_value = max_kw }
end
local TW = 1000000000                      -- 1 TW in kW
data:extend({
	power("quantum-bridge", "01", 1000, 0.001, TW),
	power("wireless-link", "02", 10, 0.001, TW),
	power("wireless-link-per-32-tiles", "03", 50, 0, TW),
	power("access-point", "04", 20, 0, TW),
	power("access-point-booster", "05", 10, 0, TW),
	power("member", "06", 4, 0, TW),
	power("terminal", "07", 8, 0, TW),
	power("level-maintainer", "08", 30, 0, TW),
	power("monitor", "09", 2, 0, TW),
	power("io-port", "10", 5, 0, TW),
	power("toggle-bus", "11", 0.5, 0, TW),
	power("chest", "12", 4, 0.001, TW),
	power("molecular-assembler", "13", 375, 0.001, TW),
})

--- Issue #598: with Krastorio 2 (or Krastorio 2 Spaced Out) the ME recipes and technologies follow its materials and science
--- tiers (data-updates.lua, prototypes/compat/krastorio2.lua); off, they stay the standalone ones. Only with one of the two.
if mods["Krastorio2"] or mods["Krastorio2-spaced-out"] then
	data:extend({ { type = "bool-setting", name = "me-network-krastorio2-recipes", setting_type = "startup", order = "z",
		default_value = true } })
end

--- Space Exploration: with it the ME recipes and technologies follow its materials and science tiers (data-updates.lua,
--- prototypes/compat/space-exploration.lua); off, they stay the standalone ones (or Krastorio 2's). Only with Space Exploration.
if mods["space-exploration"] then
	data:extend({ { type = "bool-setting", name = "me-network-space-exploration-recipes", setting_type = "startup", order = "z2",
		default_value = true } })
end
