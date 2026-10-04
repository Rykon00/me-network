# ME Network

An ME storage network for Factorio 2.0, inspired by Applied Energistics 2: ME blocks joined by cables, storage cells
in drives that keep their contents, a terminal as the hub, interfaces and buses for items and fluids, storage buses on
chests and tanks,
autocrafting with encoded patterns and crafting CPUs, level maintainers, and fluids. On the mod portal:
[ME Network](https://mods.factorio.com/mod/me-network) (`me-network`).

It was made in [Gregtorio Continued](https://github.com/Rykon00/Gregtorio) (issues #68, #38, #80) and became a mod of
its own in Gregtorio issue #83. On its own it uses vanilla recipes and technologies; Gregtorio Continued depends on it
and puts it on its GregTech tiers (its `prototypes/120-fork-me-network-compat.lua`, through the API below). Issue
numbers in the code and in `docs/` before 0.1.0 are Gregtorio's.

The player guide is `docs/AE2.md`, the design record `docs/ME-REWORK.md`, the data-stage API for other mods
`docs/API.md`, the measured cost at megabase size `docs/PERFORMANCE.md`.

## Layout

The repository root is the mod itself.

| Path | Contents |
|---|---|
| `data.lua` | refuses to load next to Gregtorio Continued before 0.5.0 (which contains this network itself), then loads the prototypes |
| `prototypes/api.lua` | the data-stage API `ME_NETWORK` (`docs/API.md`): items, recipes and technologies of this mod, replacing and removing recipes, setting technologies, the molecular assembler |
| `prototypes/network.lua` | cable and underground cable, controller, drive, storage components and cells (items with tags), housing, ME chest, interface, import, export and storage bus, terminal, the hidden prototypes of old Gregtorio saves, mod-data `fork-me-network`, technologies `me-network`, `me-storage-64k`, `me-storage-256k` |
| `prototypes/autocrafting.lua` | pattern provider, blank and encoded pattern, molecular assembler, the crafting blocks of the multiblock crafting CPUs (issue #6) and the three legacy CPUs, level maintainer, circuit interface, mod-data `fork-me-autocraft`, technologies `me-autocrafting`, `me-automation`, `me-co-processing`, `me-quantum-crafting` |
| `prototypes/fluids.lua` | fluid cells, the ME Interface's fluid sides, the hidden old fluid drives and old fluid blocks (fluid interface, fluid import, export and storage bus: replaced by the unified blocks), mod-data `fork-me-fluids`, technologies `me-fluid-storage`, `me-fluid-storage-256k` |
| `data-final-fixes.lua` | removes the recipes (also another mod's) that make an item this mod no longer makes (`ME_NETWORK.removed`); unlocks a crafting block recipe that no technology unlocks any more (issue #6); lets every crafting machine paste its settings onto the ME Interface, the import, export and storage bus (`additional_pastable_entities`) |
| `settings.lua` | the map settings: the scheduler's budgets, the bus speed and the idle limits (issue #5, `docs/PERFORMANCE.md`) |
| `control.lua` | the event registrations of every module, the one `on_tick` handler (the scheduler), `on_init` (with the hand-over from Gregtorio) and `on_configuration_changed` (graph rebuild, migrations, modules) |
| `scripts/fork-me-network.lua` | the core: cable graph, networks and their controller, storage cells and the storage API, the drive, partitions and priorities, external cells (storage buses), the cable router; remote interface `gregtorio-me-network` |
| `scripts/fork-me-schedule.lua` | the scheduler: queues of due units, budgets per tick, intervals, idle limits, the settings (issue #5) |
| `scripts/fork-me-stats.lua` | the command `/me-stats`: members, block states, the scheduler's counters of the last minute (issue #38, part 3) |
| `scripts/fork-me-io.lua` | ME Interface (items, and fluids through its four sides) and import/export buses (items and fluids), their scheduled visits; `gregtorio-me-io` |
| `scripts/fork-me-targets.lua` | what a bus works with: the entity types and inventories of the import, export and storage bus, the tile in front, fluid boxes |
| `scripts/fork-me-storagebus.lua`, `scripts/fork-me-fluid-storagebus.lua` | the storage bus: its item side (a chest, logistic chest or cargo wagon) and its fluid side (a tank's fluid segment) as network storage; `gregtorio-me-storagebus`, `gregtorio-me-fluid-storagebus` (the old remote, on the storage bus) |
| `scripts/fork-me-recipe-paste.lua` | a crafting machine's recipe pasted onto an ME Interface, import, export or storage bus (issue #12); `gregtorio-me-recipe-paste` |
| `scripts/fork-me-unify.lua` | turns the old fluid blocks of a save (and their ghosts, items, blueprints) into the unified blocks (issue #3) |
| `scripts/fork-me-terminal.lua`, `fork-me-gui.lua`, `fork-me-windows.lua` | the terminal (hub window), the shared GUI and the windows of every block; `gregtorio-me-terminal`, `gregtorio-me-gui` |
| `scripts/fork-me-autocraft.lua`, `fork-me-patterns.lua` | providers with encoded patterns, planner (with the bytes of a job), jobs, the multiblock CPUs (groups of crafting blocks kept up to date on build and removal) and the legacy CPUs, the pattern items; `gregtorio-me-autocraft` |
| `scripts/fork-me-circuit.lua` | level maintainer and circuit interface; `gregtorio-me-circuit` |
| `scripts/fork-me-fluids.lua` | the fluid calls of the other modules; `gregtorio-me-fluids` |
| `scripts/fork-me-migrate.lua` | converts the logistic-network ME of Gregtorio 0.3.2 and older and its fluid drives; `gregtorio-me-migrate` |
| `scripts/fork-me-handover.lua` | takes the ME state of a Gregtorio Continued save once (Gregtorio issue #83) |
| `graphics/` | sprites, icons and technology icons (`tools/gen_ae2_sprites.py`) |
| `locale/en/me-network.cfg` | English names and texts |
| `tools/devcheck/` | headless test harness: static checks and the runtime tests, on vanilla and with Gregtorio, and the benchmark (`bench`, `docs/PERFORMANCE.md`) (`tools/devcheck/README.md`) |
| `tools/build.py` | builds `dist/me-network_<version>.zip` (`--portal` for the mod portal, `--install` into the mods folder) |
| `tools/dev_link.py` | links the repository into the Factorio mods folder |
| `tools/check_syntax.py` | Lua syntax check (`--loaded`: only the files the mod loads) |
| `tools/gen_ae2_sprites.py` | the sprites and icons (GT5-Unofficial casings, screens, circuit boards and GUI signs + Pillow) |

The names (`fork-me-*.lua`, the storage keys `fork_me_*`, the remote interfaces `gregtorio-me-*`, every prototype
name) are kept from Gregtorio Continued: saves find their entities and items by name, the state of a Gregtorio save is
taken over without conversion, and other mods and the tests call the interfaces by these names.

## With Gregtorio Continued

Gregtorio Continued 0.5.0 and later depends on this mod. A save of an older Gregtorio with an ME network is taken over
when it is loaded with both mods: cells with their items and fluids, patterns, running jobs, maintainers and every
setting (`scripts/fork-me-handover.lua`). Loading this mod next to Gregtorio Continued before 0.5.0 is refused with a
message (both would run the same network).

## Workflow

```bash
python tools/dev_link.py                        # once: the working copy is loaded by Factorio
python tools/devcheck/devcheck.py setup         # once (see tools/devcheck/README.md)
python tools/devcheck/devcheck.py all           # before every pull request: RESULT: OK
python tools/devcheck/devcheck.py all --with-gregtorio ../Gregtorio
python tools/devcheck/devcheck.py migrate --from-ref v0.1.0   # a save of an older version (changes to saved state)
python tools/devcheck/devcheck.py bench         # script time, throughput and latencies at 100, 1000 and 5000 endpoints
```

Releases: `CONTRIBUTING.md`.

## License

GPLv3 (see `LICENSE`), like Gregtorio Continued, where this network was made.

The graphics are generated by `tools/gen_ae2_sprites.py` from
[GT5-Unofficial](https://github.com/GTNewHorizons/GT5-Unofficial) by GTNewHorizons (LGPL-3.0: machine casings and
screens; for the upgrade cards its circuit boards, circuits, an SMD chip and the signs of its machine GUI buttons) and
shapes drawn with Pillow; the ME cable, the drive's cell bays, the bus plates and arrows and the ME Cell Workbench are
drawn by the script or derived from those sprites, and `thumbnail.png` is put together from them (a drive and a
terminal). Some item icons come from the original Gregtorio by Damien Reave (GPLv3). No
textures of Applied Energistics 2 are used (its assets are not under a license compatible with GPLv3).
