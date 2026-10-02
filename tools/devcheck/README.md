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
| `runtime` | Creates a map with a fixed seed (`--seed`, `random` for another), builds the test networks in `on_init` and runs the map (`--ticks`, default 1500). Every test reports a `DEVCHECK-RUNTIME-<KEY>` line; when every test has reported (at the latest at tick 1450) `DEVCHECK-RUNTIME-DONE`. The tests (`runtimemod/control.lua`, written in Gregtorio, issue numbers there are Gregtorio's): the cable graph (join, split, two controllers, a member removed without an event, the cable router, the underground cable, walkable cables, power), storage cells (slots, contents in the tags, AE2 capacity, quality, a cell in a cell, the drive window, a destroyed drive, old drive items, robots), the terminal's functions, interface and buses (config rows, rotation, settings paste, blueprints), autocrafting (a two-level job, a shortfall, a cancelled job, a CPU replaced, a pattern machine removed, a machine of another type), encoded patterns at a furnace (encoding, clearing, blueprints, mined and destroyed providers), recipe switching on one molecular assembler, a processing line through a chest and an import bus, fluids (interfaces, a fluid cell's round trip, robots, full cells, jobs with fluid inputs and outputs), fluid cells and the fluid buses, partitions, priorities and the window data of every block, the storage bus and the fluid storage bus, the level maintainer, the crafting CPU tiers, the circuit interface, and settings in blueprints, paste and clones. `--with-gregtorio DIR` runs the same tests on Gregtorio's machines and recipes. |
| `all` | `check` and `runtime` (both take `--with-gregtorio`). |

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
- `runtimemod/` (`zz-me-network-devcheck-runtime`): the stand-ins (`data.lua`, vanilla only) and the runtime tests.

The migration of Gregtorio saves (the hand-over of their ME state to this mod, totals and settings before and after)
is tested in Gregtorio's own devcheck: `devcheck.py migrate --from-ref <tag>` there.

Limits: headless Factorio does not load graphics, so how things look and the windows themselves still need a real game.
