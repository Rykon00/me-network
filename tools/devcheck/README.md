# devcheck: headless test harness

Loads ME Network (`me-network`) in headless Factorio and checks what the game only notices late or never: missing
graphics files, recipes and technologies that cannot be reached, and the network's runtime behaviour. On vanilla
(with Space Age and quality, or `--base-only`) and with Gregtorio Continued (`--with-gregtorio DIR`), which puts the
network on its GregTech tiers.

## Setup (once per machine)

Needs Python 3, `pip install pillow` (for the sprite size check) and the headless Factorio (Linux: downloaded from
factorio.com; Windows: copy a Factorio `bin/` and `config/` into `.devcheck/factorio/` and link its `data/`).

```bash
python tools/devcheck/devcheck.py setup                         # latest stable headless Factorio
python tools/devcheck/devcheck.py setup --factorio /path/to/factorio
# for --with-gregtorio runs: Gregtorio's dependency mods from the portal (FACTORIO_USERNAME/FACTORIO_TOKEN)
python tools/devcheck/devcheck.py setup --with-gregtorio ../Gregtorio
python tools/devcheck/devcheck.py setup --with-gregtorio ../Gregtorio --mods-from /folder/with/zips
```

Everything lands in `.devcheck/` (git-ignored). The working copy (and a Gregtorio checkout) is linked in, so every run
tests the current files.

## Commands

| Command | What it does |
|---|---|
| `check` | Creates a map. Fails on a load error, a reference to a missing prototype, a missing `__me-network__/` file, a too small sprite sheet, a name missing in `locale/en` (items, entities and technologies with an icon of this mod), a technology of this mod that cannot be researched, a recipe of this mod (`ME_NETWORK.recipes`) that is not unlocked by a researchable technology or cannot be crafted, and (with `--base-only`) any unlocked recipe of the game that cannot be crafted. The progression model starts from water, steam, the resources, trees, rocks, fish, asteroid chunks, tile fluids and burnt results and adds what reachable machines craft and what researchable technologies unlock. With Space Age it does not know every source (captive biter spawners), so those recipes and technologies are listed as information only. `--with-gregtorio DIR` loads Gregtorio Continued too (its recipes and tiers of the ME items). |
| `runtime` | Creates a map with a fixed seed (`--seed`, `random` for another), builds the test networks in `on_init` and runs the map (`--ticks`, default 1500). Every test reports a `DEVCHECK-RUNTIME-<KEY>` line; when every test has reported (at the latest at tick 1450) `DEVCHECK-RUNTIME-DONE`. The tests (`runtimemod/control.lua`, written in Gregtorio, issue numbers there are Gregtorio's): the cable graph (join, split, two controllers, a member removed without an event, the cable router, the underground cable, walkable cables, power), storage cells (slots, contents in the tags, AE2 capacity, quality, a cell in a cell, the drive window, a destroyed drive, old drive items, robots), the terminal's functions, interface and buses (config rows, rotation, settings paste, blueprints), autocrafting (a two-level job, a shortfall, a cancelled job, a CPU replaced, a pattern machine removed, a machine of another type), encoded patterns at a furnace (encoding, clearing, blueprints, mined and destroyed providers), recipe switching on one molecular assembler, a processing line through a chest and an import bus, fluids (the ME Interface's fluid sides, a fluid cell's round trip, robots, full cells, jobs with fluid inputs and outputs), fluid cells and the buses on tanks, partitions, priorities and the window data of every block, the storage bus on chests and on tanks, the unified blocks (an interface with item and fluid rows and its sides, buses on a machine with a fluid recipe, a storage bus switching between chest and tank, old fluid blocks and their ghosts converted), the level maintainer, the crafting CPU tiers, the circuit interface, settings in blueprints, paste and clones, whether a click with each cursor tool opens an ME window (real item stacks of every tool; the harness has no player), a crafting machine's recipe pasted onto the ME Interface, the storage, export and import bus (every crafting machine lists them as pastable; the paste handler called with the event's shape: item, fluid and quality recipes, a furnace, machines without a recipe, more ingredients than rows or filters), the scheduler (issue #5: an export bus woken by its item, an import bus by a chest built in front of it, a full storage bus passed by until its read, random inserts and extracts against the cells and a chest), and the multiblock crafting CPUs (issue #6, `runtimemod/cpus.lua`: the smallest CPU, a rectangle of every block kind, a group that is no rectangle and one without storage, the bytes of a plan, a job too big for every CPU refused and a level maintainer waiting, two jobs on two CPUs and a third refused, a block removed during a job (it pauses and goes on on the rest of its CPU, nothing lost), a clone and a blueprint of a CPU, a legacy CPU without byte limit), and the windows with the player's inventory (issue #28: every registered window has the pane and a shift + click target; the terminal, the blocks without slots, the drive, the cell window and the provider take or refuse what is shift-clicked; the storage bus card slots and the ME Cell Workbench's cell and card slots, through the module functions and through the clicks of the inventory pane and the block's slots, with an inventory standing for the player's: what is taken, what is refused before it moves, half a stack, merge and swap, nothing made or lost). `--with-gregtorio DIR` runs the same tests on Gregtorio's machines and recipes. |
| `all` | `check` and `runtime` (both take `--with-gregtorio`). |
| `migrate` | `--from-ref <tag or commit>` (default `v0.1.0`): unpacks that version (`git archive`) into `.devcheck/old-<ref>`, creates a map with it and the helper mod `migratemod/` (every old fluid block with settings and fluid, their ghosts, old items in a chest, a blueprint, the cells and a cell taken out, an item interface next to a pipe, a maintainer and patterns naming old items), then loads it with the working copy and checks the unified blocks, their settings, that nothing old is left and that the fluid in the area and the cells is the same after the update and after 150 ticks (`--ticks`, default 300). A version that already has the unified blocks (0.2.0 and later, issue #5) gets another scenario: a network with every kind of block (buses on chests, an interface with a row and items, an interface on a tank, storage buses on a chest and a tank, a circuit interface, a level maintainer); after the load (with the same version number there is no `on_configuration_changed`, so the scheduler's state must come up on its own) each of them must have done its work by tick 150, and the fluid must be the same; issue #6: the save holds a running job on each of the three legacy CPUs (ME Crafting CPU, Co-Processing, Quantum), which must end done on the CPU it started on (not for an old version that already has the multiblock CPUs: it starts no job on a legacy CPU); issue #28: an old version with upgrade cards (a commit of `main` before #28) gets a storage bus with two cards and an ME Cell Workbench holding a cell with a partition and two cards, which must be items in their script inventories after the load. |
| `bench` | Performance at size (issue #5, `docs/PERFORMANCE.md`). For each size (`--sizes`, default `100,1000,5000` buses and interfaces) the benchmark mod `benchmod/` builds a synthetic base on one ME network (see below), saves it and runs it `--runs` times (default 3) with `--benchmark-verbose all`. Reported, the median of the runs: the script time per tick (`scriptUpdate`: average, 99th percentile, worst tick, ticks over 5 ms) over the window (`--ticks`, default 3600, from tick 600, without the ticks next to the two probes), the Lua garbage collector, the whole update and the save size; the items and fluid moved per second, in total, per endpoint and per kind of endpoint (counted at the probes from what the sources lost and the sinks got); the latencies (a storage bus sees a chest change, a level maintainer reacts to a stock below its target, its job hands the first ingredients to a machine). A conservation check counts every item and fluid in the world at both probes (cells, chests, interfaces, machines with a craft in progress, inserter hands, job pools, tanks and fluid segments, items on the ground, robots): the difference must be what the machines crafted. `--reference` adds the native scenes (chest, inserter, chest with fast and bulk inserters; requester chests served by logistic robots) with the same counting. `--profile 1000,5000` adds one run of those sizes with an instrumented copy of the mod (`.devcheck/bench-profile`: the functions listed in `PROFILE_WRAP` timed with `LuaProfiler`, inclusive time and calls; the mod itself never contains a profiler) and the time of single engine calls on the scene's entities, of the storage API, of building and removing one bus and of the graph rebuild. `--from-ref <tag or commit>` runs the same scenes against an older version of the mod (`git archive`, as `migrate` does), `--set name=value` with other runtime settings of the mod (written into `.devcheck/mods/mod-settings.dat` for the map, the defaults again afterwards). Fails on a load error, a setup problem, a job that cannot start, a run that does not finish or a conservation difference. All numbers go into `.devcheck/bench-results.json`. |

Exit code 0 means OK, 1 means problems (details in the output, the full Factorio log is in `.devcheck/last-run.log`).

## Vanilla and Gregtorio

The runtime tests name a few machines and recipes of Gregtorio Continued (a gear recipe from a plate and two sticks, a
macerator, chemical reactors and an extractor with fluid recipes, an iron furnace with a dust recipe). Without
Gregtorio, `runtimemod/data.lua` adds stand-ins with the same names, the same inputs and outputs and the same machine
sizes and fluid boxes (copies of the assembling machine 2, the chemical plant and the stone furnace), so the same test
code runs in both. The stand-ins are test fixtures and never part of the mod. The blank pattern job takes the
ingredients of the blank pattern recipe of the game it runs in.

## How it works

Helper mods are linked into the test mod folder next to the mod:

- `checkmod/` (`zz-me-network-devcheck`): `data.lua` lists references to missing prototypes, `data-final-fixes.lua`
  dumps recipes, machines, items, technologies, resources, file paths, sprite layers, locale names and the names in
  `ME_NETWORK` into the log (`DEVCHECK-<SECTION>-BEGIN/END`).
- `runtimemod/` (`zz-me-network-devcheck-runtime`): the stand-ins (`data.lua`, vanilla only), the fixtures of the
  recipe paste test (a machine with six fluid inputs in `data.lua`, two recipes with more ingredients than the ME
  blocks hold in `data-final-fixes.lua`; with Gregtorio too) and the runtime tests.
- `benchmod/` (`zz-me-network-devcheck-bench`, copied with a generated `config.lua` into `.devcheck/bench-mod`):
  the benchmark scenes. `data.lua` adds two fixtures (a warehouse of 800 slots and a tank of 1 000 000 units for the
  capacity probes); `profile.lua` and `profile-remote.lua` are put into the instrumented copy of `bench --profile`.
  The ME scene of size N, on a surface of lab tiles, one network along cable rows: import buses on chests (18 % of
  N) and export buses into chests (12 %), assembling machines with an export bus on their input and an import bus on
  their output (10 %), import and export buses on tanks (8 % each), ME Interfaces with an item row and inserters taking
  from and feeding them (20 %), ME Interfaces importing a tank and exporting into one (10 % each), capacity probes
  (1 % each: buses on the warehouse and the big tank), storage buses (N / 10: 70 % on chests, some at priority -10 or
  10 with filters, 30 % on tanks), pattern providers with molecular assemblers (N / 25; jobs for a quarter of them),
  level maintainers (N / 10), circuit interfaces (N / 50, half of them filtered), drives of 256k cells (N / 50 drives,
  about 70 % full: every raw material in millions, about 2000 other item types in every quality) and fluid drives,
  quantum crafting CPUs for the jobs. Sources are filled and sinks emptied at the first probe; the graph is built in
  one pass (`rebuild`) and every block registered with `script_raised_built`.

The migration of Gregtorio saves (the hand-over of their ME state to this mod, totals and settings before and after)
is tested in Gregtorio's own devcheck: `devcheck.py migrate --from-ref <tag>` there.

Limits: headless Factorio does not load graphics, so how things look and the windows themselves still need a real game.
