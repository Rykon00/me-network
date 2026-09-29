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
| `check` | Creates a map. Reports load errors, draft recipes hidden by the draft guard, researchable technologies, where progression stops, every technology that cannot be researched and the disabled or missing prerequisites that block it, missing `__gregtorio-continued__/` files, too small sprite sheets, and unlocked recipes that cannot be crafted (no machine, unobtainable ingredient, not enough fluid ports). `--locale-out names.tsv` also writes the input for `tools/gen_locale.py`. `--techs REGEX` lists the matching technologies and whether they are researchable. |
| `runtime` | Places every assembling machine that has an item, gives it a recipe and power, builds a small ME network (controller, one drive per tier, interface, terminal) and runs the map (`--ticks`, default 1500). At tick 300 the ME network is checked: interface default, terminal power and network, taking items out and storing them again through the terminal's code. An LV alloy smelter with a mold recipe must stop without a mold, then run with a mold in its mold slot and keep it there. Autocrafting (`docs/AE2.md`): from tick 60 a network with a crafting CPU, two Molecular Assemblers and a macerator with pattern providers runs a two-level job (result and used ingredients checked), a job with missing raw material (exact shortfall reported, nothing started), a queued job that is cancelled, a CPU removed and replaced during a job, a removed pattern machine with a cancel afterwards (raw material conserved) and a GT machine as pattern machine; it reports `autocrafting test: ok`. Fluids (`docs/AE2.md`, from tick 60 as well, in its own network further down): a 1k fluid drive, an ME Fluid Interface with a storage tank of chlorine connected to it (import), a second interface set to export 1000 units, a roboport with construction robots, HV chemical reactors and an EV extractor with fluid recipes behind pattern providers, and a reactor with a pipe on its input. It checks the import (tank empty, export interface at its level, fluid conserved, totals and capacity right), that the export holds its level and re-imports when switched, a drive round trip by script (`pack_drive`/`unpack_drive`, contents on the item tags; the loaded item is also stored in and withdrawn from the network through the terminal) and by robots (deconstruction, item in the drive chest with tags, ghost, rebuilt with the same contents), full drives (the import reports `full` and leaves the fluid in the tank, an export of a fluid the network lacks reports `empty-network`), the piped reactor counted under `fluid-pipes` and not craftable, the exact fluid and item shortfall of a too large request, three jobs (silicon tetrachloride: fluid in and out, molten tin: fluid out, phenolic circuit board: fluid in) that must finish with the expected amounts, empty pools and empty machines, and a reactor deconstructed by robots while it holds a job's chlorine (the fluid returns with the pool); it reports `fluid test: ok`. Fluid recovery (issue #26, from tick 60, a third network): a destroyed loaded drive (the other drive takes what fits, the rest becomes recovered fluid, totals conserved), its ghost rebuilt by robots (takes the recovered fluid over), the upgrade planner on a loaded drive (fluid stays on the old item), the cells taken out of the loaded item by hand inside and outside a network (the function the craft event calls), a loaded drive removed without an event, and a drive destroyed on a second surface that is then deleted; it reports `fluid recovery test: ok`. Endgame power (`prototypes/136-fork-power.lua`, `scripts/fork-power.lua`): a LuV large plasma turbine with helium plasma and a turbine output hatch next to it and a UV large naquadah reactor with naquadah based fuel MK1, each with an electric energy interface drawing the generator's full output; at tick 420 both must generate, the turbine must have burnt about one plasma per second and the hatch must hold the cooled helium for it, the reactor must have burnt fuel at its rate; it reports `power test: ok`. Fuel check (issue #25, `scripts/fork-power.lua`): a LuV plasma turbine with steam from a pipe, a UV naquadah reactor with steam, a plasma turbine with naquadah fuel and a naquadah reactor with helium plasma, each under full load in its own network, must make no power, keep all their fluid and show "Wrong fuel"; after they are emptied and get the right fuel they must run with no status. A running plasma turbine whose plasma is replaced by steam between two checks may burn steam for at most one check interval (10 ticks) and must then stay stopped; it reports `fuel check test: ok (window: ...)`. At tick 1450 the technology `victory` is researched by script and the game must be finished (`scripts/fork-victory.lua`); winning stops the scripts of the benchmark, so this runs last. |
| `migrate --from-ref <tag/commit>` or `--from-zip <zip>` | Creates a save with an older version and loads it with the working copy. The unmodified upstream 0.1.9 import is commit `0e935ba` (tag `v0.1.9-upstream`). If the old version has ME fluid drives, the helper mod `migratemod/` builds loaded drives in the save and checks after the update that they kept their contents and that a destroyed one is recovered (`fluid drives of the old save: ok`; `skipped` for older versions). If the old version has the large naquadah reactor, it also builds one full of steam under load, which must be stopped with the "Wrong fuel" status and keep its steam after the update (`reactor on steam in the old save: ok`; `skipped` for older versions). |
| `all` | `check` and `runtime`. |

Exit code 0 means OK, 1 means problems (details in the output, the full Factorio log is in
`.devcheck/last-run.log`).

## How it works

Small helper mods are linked into the test mod folder next to Gregtorio:

- `checkmod/` (`zz-gregtorio-devcheck`): `data.lua` lists references to missing prototypes,
  `data-final-fixes.lua` dumps recipes, machines, items, techs, file paths and sprite layers
  into the log (`DEVCHECK-<SECTION>-BEGIN/END`).
- `runtimemod/` (`zz-gregtorio-devcheck-runtime`): places the machines on a new map.
- `migratemod/` (`zz-gregtorio-devcheck-migrate`, `migrate` only): loaded fluid drives in the old save.

`devcheck.py` parses the dump and solves progression as a fixed point: starting from water,
steam and the recipes that are enabled from the start, it repeatedly adds everything that can
be crafted with reachable machines and every technology whose prerequisites and science packs
are available. Vanilla resource patches disabled by `102-fork-resources.lua` do not count.

Limits: headless Factorio does not load graphics, so how things look, pipe connections and
balance still need a real game.
