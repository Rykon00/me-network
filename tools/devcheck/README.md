# devcheck: headless test harness

Loads Gregtorio in headless Factorio (Linux) and checks things the game only notices late
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
| `check` | Creates a map. Reports load errors, draft recipes hidden by the draft guard, researchable technologies and where progression stops, missing `__Gregtorio__/` files, too small sprite sheets, and unlocked recipes that cannot be crafted (no machine, unobtainable ingredient, not enough fluid ports). `--locale-out names.tsv` also writes the input for `tools/gen_locale.py`. `--techs REGEX` lists the matching technologies and whether they are researchable. |
| `runtime` | Places every assembling machine that has an item, gives it a recipe and power, builds a small ME network (controller, one drive per tier, interface, terminal) and runs the map (`--ticks`, default 600). At tick 300 the ME network is checked: interface default, terminal power and network, taking items out and storing them again through the terminal's code. An LV alloy smelter with a mold recipe must stop without a mold, then run with a mold in its mold slot and keep it there. |
| `migrate --from-ref <tag/commit>` or `--from-zip <zip>` | Creates a save with an older version and loads it with the working copy. The unmodified upstream 0.1.9 import is commit `0e935ba` (tag `v0.1.9-upstream`). |
| `all` | `check` and `runtime`. |

Exit code 0 means OK, 1 means problems (details in the output, the full Factorio log is in
`.devcheck/last-run.log`).

## How it works

Two small helper mods are linked into the test mod folder next to Gregtorio:

- `checkmod/` (`zz-gregtorio-devcheck`): `data.lua` lists references to missing prototypes,
  `data-final-fixes.lua` dumps recipes, machines, items, techs, file paths and sprite layers
  into the log (`DEVCHECK-<SECTION>-BEGIN/END`).
- `runtimemod/` (`zz-gregtorio-devcheck-runtime`): places the machines on a new map.

`devcheck.py` parses the dump and solves progression as a fixed point: starting from water,
steam and the recipes that are enabled from the start, it repeatedly adds everything that can
be crafted with reachable machines and every technology whose prerequisites and science packs
are available. Vanilla resource patches disabled by `102-fork-resources.lua` do not count.

Limits: headless Factorio does not load graphics, so how things look, pipe connections and
balance still need a real game.
