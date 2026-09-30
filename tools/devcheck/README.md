# devcheck: headless test harness

Loads Gregtorio Continued (`gregtorio-continued`) in headless Factorio (Linux) and checks things the game only notices late
or never: missing graphics files, unreachable recipes, machines without enough fluid ports,
broken save migration. Meant for cloud sessions, CI and anyone working on the mod on Linux.

## Setup (once per machine)

Needs Python 3, `pip install pillow` (for the sprite size check) and network access to
`factorio.com` / `*.factorio.com`.

```bash
# dependency mods from the mod portal need a Factorio account
export FACTORIO_USERNAME=...   # factorio.com -> your profile
export FACTORIO_TOKEN=...
python tools/devcheck/devcheck.py setup                 # latest stable headless Factorio
python tools/devcheck/devcheck.py setup --version 2.0.77
# alternatives: --factorio /path/to/unpacked/headless  --mods-from /folder/with/dependency/zips
```

Everything lands in `.devcheck/` in the repository root (git-ignored). The working copy is
linked in, so every run tests the current files.

## Commands

| Command | What it does |
|---|---|
| `check` | Creates a map. Reports load errors, draft recipes hidden by the draft guard (it fails on one that is not in the documented rest list `DRAFTS_OK`, issue #39; drafts removed for good are deleted in `prototypes/137-fork-endgame-materials.lua` and counted as `FORK-REMOVED`), researchable technologies, where progression stops, every technology that cannot be researched and the disabled or missing prerequisites that block it (it fails if one is not in the list `UNRESEARCHABLE_OK` of vanilla armor, equipment and military techs, if one of the 23 quality-of-life techs of issue #29 in `QOL_TECHS` is neither researchable nor hidden, or if an `UNRESEARCHABLE_OK` entry became researchable, hidden or missing), missing `__gregtorio-continued__/` files, too small sprite sheets, and unlocked recipes that cannot be crafted (no machine, unobtainable ingredient, not enough fluid ports). The recipes in `REQUIRED_RECIPES` (issue #35: grades 7 and 8, the quark creation catalyst, FPIC/APIC wafers and chips, complex SMDs) must be unlocked by a researchable technology and their products obtainable. Crafting menu (issue #49): every recipe that is enabled or unlocked by a technology, not `hidden` and whose category has a machine must not be `hide_from_player_crafting`, unless it is in the allow-list `FORK_CRAFTING_MENU_HIDDEN` (`prototypes/198-fork-crafting-menu.lua`, by category, subgroup or name); it prints how many are shown and kept hidden and the recipes shown per crafting menu tab, and also fails on allow-list entries that match nothing. Skipped when the startup setting `gregtorio-continued-show-machine-recipes` is off. `--locale-out names.tsv` also writes the input for `tools/gen_locale.py`. `--techs REGEX` lists the matching technologies and whether they are researchable. |
| `runtime` | Places every assembling machine that has an item, gives it a recipe and power, builds a small ME network (controller, one drive per tier, interface, terminal) and runs the map (`--ticks`, default 1500) with a fixed map seed (`--seed`, see below). At tick 300 the ME network is checked: interface default, terminal power and network, taking items out and storing them again through the terminal's code. An LV alloy smelter with a mold recipe must stop without a mold, then run with a mold in its mold slot (checked when the first glass is out, at the latest 900 ticks later) and keep it there. Autocrafting (`docs/AE2.md`): from tick 60 a network with a crafting CPU, two Molecular Assemblers and a macerator with pattern providers runs a two-level job (result and used ingredients checked), a job with missing raw material (exact shortfall reported, nothing started), a queued job that is cancelled, a CPU removed and replaced during a job, a removed pattern machine with a cancel afterwards (raw material conserved) and a GT machine as pattern machine; it reports `autocrafting test: ok`. Furnace patterns (issue #27, from tick 60, own network above the machine grid): two fresh iron furnaces with pattern providers are counted as `no-recipe`, the recipe options list only researched smelting recipes, a recipe chosen through the GUI's function makes one furnace a pattern at once, a job on it must finish with the ingots in storage and empty furnace slots; then settings paste, clearing the choice (the last smelted recipe stays), blueprint tags and a revived tagged ghost; it reports `furnace pattern test: ok`. Fluids (`docs/AE2.md`, from tick 60 as well, in its own network further down): a 1k fluid drive, an ME Fluid Interface with a storage tank of chlorine connected to it (import), a second interface set to export 1000 units, a roboport with construction robots, HV chemical reactors and an EV extractor with fluid recipes behind pattern providers, and a reactor with a pipe on its input. It checks the import (tank empty, export interface at its level, fluid conserved, totals and capacity right), that the export holds its level and re-imports when switched, a drive round trip by script (`pack_drive`/`unpack_drive`, contents on the item tags; the loaded item is also stored in and withdrawn from the network through the terminal) and by robots (deconstruction, item in the drive chest with tags, ghost, rebuilt with the same contents), full drives (the import reports `full` and leaves the fluid in the tank, an export of a fluid the network lacks reports `empty-network`), the piped reactor counted under `fluid-pipes` and not craftable, the exact fluid and item shortfall of a too large request, three jobs (silicon tetrachloride: fluid in and out, molten tin: fluid out, phenolic circuit board: fluid in) that must finish with the expected amounts, empty pools and empty machines, and a reactor deconstructed by robots while it holds a job's chlorine (the fluid returns with the pool); it reports `fluid test: ok`. Fluid recovery (issue #26, from tick 60, a third network): a destroyed loaded drive (the other drive takes what fits, the rest becomes recovered fluid, totals conserved), its ghost rebuilt by robots (takes the recovered fluid over), the upgrade planner on a loaded drive (fluid stays on the old item), the cells taken out of the loaded item by hand inside and outside a network (the function the craft event calls), a loaded drive removed without an event, and a drive destroyed on a second surface that is then deleted; it reports `fluid recovery test: ok`. Endgame power (`prototypes/136-fork-power.lua`, `scripts/fork-power.lua`): a LuV large plasma turbine with helium plasma and a turbine output hatch next to it and a UV large naquadah reactor with naquadah based fuel MK1, each with an electric energy interface drawing the generator's full output; at tick 420 both must generate, the turbine must have burnt about one plasma per second and the hatch must hold the cooled helium for it, the reactor must have burnt fuel at its rate; it reports `power test: ok`. Fuel check (issue #25, `scripts/fork-power.lua`): a LuV plasma turbine with steam from a pipe, a UV naquadah reactor with steam, a plasma turbine with naquadah fuel, a naquadah reactor with helium plasma, a UXV plasma turbine with steam and a UEV plasma turbine with naquadah fuel, each under full load in its own network, must make no power, keep all their fluid and show "Wrong fuel"; after they are emptied and get the right fuel they must run with no status. A running plasma turbine whose plasma is replaced by steam between two checks may burn steam for at most one check interval (10 ticks) and must then stay stopped; it reports `fuel check test: ok (window: ...)`. Cooled fluid (issue #28, `scripts/fork-power.lua`): LuV plasma turbines, each with an output hatch and a load set every tick, burn 4 helium plasma at full load, 2 at 40 % and 1.5 under a burst load (full for 5 ticks out of 23) to the last drop, and each hatch must then hold that much helium; an idle turbine returns only what filling its load's buffer took; a hatch that starts full keeps the rest owed and gets all of it once emptied; two turbines side by side on helium and nitrogen plasma fill only their own hatch. A running turbine is compared as hatch + owed + the energy of the current step / fuel value, tolerance 0.1 % + 0.001 units; it reports `cooled fluid test: ok (... worst error ...)`. The power test uses the same tolerance. Turbine tiers (issue #34): one UHV to UXV large plasma turbine each (helium, nitrogen and iron plasma) and a UXV one on neon plasma, each with an output hatch and a load of twice its output, must generate exactly four amps of their tier per tick and, once their plasma is burnt to the last drop, hold exactly that much cooled fluid (helium, nitrogen, molten iron, neon) in the hatch, same tolerance; it reports `turbine tier test: ok (...)`. Recipes (issue #35, `prototypes/129-fork-water-purification.lua`): above the machine grid, a water purification plant each for grade 7 and grade 8 water, UHV/UEV laser engravers and assembling machines for the FPIC/APIC wafers and chips, UV assembling machines for the five complex SMDs, ZPM assembly lines for the quark creation catalyst, the UEV and UIV energy hatches and the MK4 controller, a circuit assembly line for the wetware mainframe, and for issues #39 and #36 (`prototypes/137-fork-endgame-materials.lua`) the circuit assembler lapotronic energy orb cluster, the high density plutonium steps and the plutonium fuel, super coolant, the 1080k super coolant cell, the fluxed electrum, bedrockium and quantium ingots and melts, naquadah fuel MK2, grade 5 water and the UXV energy hatch get exactly one craft's ingredients (every item and fluid must fit); once a machine crafts, its progress is set close to the end and its main product must come out by tick 900; it reports `recipe test: ok`. When every other test has reported (at the latest at tick 1450, a test still running then is reported as unfinished) the technology `victory` is researched by script and the game must be finished (`scripts/fork-victory.lua`); winning stops the scripts of the benchmark, so this runs last. |
| `migrate --from-ref <tag/commit>` or `--from-zip <zip>` | Creates a save (same fixed map seed, `--seed`) with an older version and loads it with the working copy. The unmodified upstream 0.1.9 import is commit `0e935ba` (tag `v0.1.9-upstream`). If the old version has ME fluid drives, the helper mod `migratemod/` builds loaded drives in the save and checks after the update that they kept their contents and that a destroyed one is recovered (`fluid drives of the old save: ok`; `skipped` for older versions). If the old version has the large naquadah reactor, it also builds one full of steam under load, which must be stopped with the "Wrong fuel" status and keep its steam after the update (`reactor on steam in the old save: ok`; `skipped` for older versions). If the old version has pattern providers, it also builds a Molecular Assembler and a fresh iron furnace with providers: after the update the assembler must still be a pattern, the furnace must be counted as `no-recipe`, and a recipe chosen in the old provider must make the furnace a pattern (`pattern providers of the old save: ok`; `skipped` for older versions). If the old version has the large plasma turbine, it also builds one on helium plasma under full load with an output hatch: after the update it must run and, at tick 120, return one helium per plasma burnt within 0.1 % (`plasma turbine of the old save: ok`; `skipped` for older versions). A map that could not be saved (for example a function in `storage`) is reported instead of running the previous map file. |
| `all` | `check` and `runtime` (takes `--seed` too). |

Exit code 0 means OK, 1 means problems (details in the output, the full Factorio log is in
`.devcheck/last-run.log`).

## Map seed and reproducing a failure

`runtime` and `migrate` create their map with a fixed seed (`DEFAULT_SEED` in `devcheck.py`), so two
runs of the same working copy are the same game, tick for tick. The output prints the seed
(`map seed: ...`). `--seed N` uses another seed, `--seed random` lets Factorio pick one; to reproduce
a failed run, pass the seed it printed.

The runtime tests must not depend on the terrain: the runtime mod generates the chunks within 12
chunks of the origin (every test lies inside) and clears them before it places anything: trees,
rocks, cliffs, fish, decoratives and enemies are removed, water becomes landfill, the surface is
peaceful (the output reports how much was cleared). Entities placed by script ignore the terrain,
but construction robots do not build a ghost over a tree or on water; before this, the robot rebuild
of a fluid drive timed out on about one seed in three (issue #47). The default seed is one of those,
so a test area that is no longer cleared fails every run. A `--seed random` loop checks that the
tests pass on any terrain:

```bash
for i in $(seq 30); do python tools/devcheck/devcheck.py runtime --seed random | grep -E "map seed|RESULT"; done
```

Waiting in the tests: a test waits for a condition (a job done, a drive built by robots, the first
glass with a mold), checked every 10 ticks (the mold every tick), with an upper bound per step that
turns a hang into a failure with the state at that moment. For robot steps the message lists the
ghosts, what stands at the spot, the tile, the chunk and every construction network there with its
robots (position, energy, orders) and roboports. Fixed ticks are left only where a test measures
over a time span (the power test at tick 420, the export hold, a paused job) or checks a state that
does not change any more (the ME network at tick 300).

## How it works

Small helper mods are linked into the test mod folder next to Gregtorio:

- `checkmod/` (`zz-gregtorio-devcheck`): `data.lua` lists references to missing prototypes,
  `data-final-fixes.lua` dumps recipes (with `hidden`, `hide_from_player_crafting`, subgroup and tab), machines, items, techs, file paths, sprite layers and the crafting menu allow-list
  into the log (`DEVCHECK-<SECTION>-BEGIN/END`).
- `runtimemod/` (`zz-gregtorio-devcheck-runtime`): places the machines on a new map.
- `migratemod/` (`zz-gregtorio-devcheck-migrate`, `migrate` only): loaded fluid drives in the old save.

`devcheck.py` parses the dump and solves progression as a fixed point: starting from water,
steam and the recipes that are enabled from the start, it repeatedly adds everything that can
be crafted with reachable machines and every technology whose prerequisites and science packs
are available. Vanilla resource patches disabled by `102-fork-resources.lua` do not count.

Limits: headless Factorio does not load graphics, so how things look, pipe connections and
balance still need a real game.
