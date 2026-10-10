# Licenses of ME Network

This repository holds **two mods with two licenses** (issue #239):

- **ME Network** (`me-network`, the repository root): GPLv3 (`LICENSE`), its GT5-Unofficial graphics LGPL-3.0. It
  runs complete on its own and has no dependency on the second mod.
- **ME Network - AE2 Textures** (`me-network-ae2-textures`, the folder `ae2-textures/`): graphics of Applied
  Energistics 2 under CC BY-NC-SA 3.0, with its own `info.json`, license text, manifest, changelog and version. It
  depends on `me-network` and replaces sprites of it when a player installs both.

The repository is a collection with a license per folder, as AE2 is itself; the rule that matters is the **package
rule**: no zip contains both licenses. `tools/build.py` builds `me-network_<version>.zip` without `ae2-textures/` and
`me-network-ae2-textures_<version>.zip` from `ae2-textures/` alone, and fails when either holds what belongs to the
other. Issue #235 had first put the AE2 graphics into a folder `graphics/ae2/` inside the GPLv3 mod; a review of that
idea called it a direct combination, which the GPL does not allow with an NC part, so issue #239 made it a mod of its
own that the player installs.

This page lists every origin of what the repository and the two zips contain, where it lies and under which license.
It is a record of what the authors state and of what the maintainer knows, not legal advice; nobody of the AE2
project has confirmed it (AE2 #9022 was closed without an answer to licensing questions).

## Origins

| Origin | License | Where | In which zip | How it gets in |
|---|---|---|---|---|
| ME Network's own code, locale, docs and tools | GPLv3 (`LICENSE`) | everything not named below | `me-network` (code, locale, graphics; docs and tools are not packed) | written here |
| [GT5-Unofficial](https://github.com/GTNewHorizons/GT5-Unofficial) graphics by GTNewHorizons: machine casings and screens, circuit boards, circuits, memory chips, an SMD chip, the signs of its machine GUI buttons | LGPL-3.0 | inside the sprites and icons of `graphics/entity/`, `graphics/icons/`, `graphics/technology/`, `thumbnail.png` | `me-network` | `tools/gen_ae2_sprites.py --gt <checkout>` |
| [Applied Energistics 2](https://github.com/AppliedEnergistics/Applied-Energistics-2) code (© 2013 - 2020 AlgorithmX2 et al.): functions ported to Lua | LGPL-3.0 (its API MIT) | the ported functions, each with a comment naming its source; the files are listed in `README.md`, "License" (none so far) | `me-network` | written anew for Lua and the Factorio API |
| Applied Energistics 2 textures and models (AE2: © 2020 Ridanisaurus Rid, © 2013 - 2020 AlgorithmX2 et al.; AE2-Unofficial: © 2013 - 2015 AlgorithmX2 et al.) | CC BY-NC-SA 3.0 | `ae2-textures/graphics/` only (`ae2-textures/README.md`, `ae2-textures/MANIFEST.tsv`); so far the item icons of the cells, cards and patterns (issue #247) and seven blocks with their icons (issues #260, #269), from AE2-Unofficial | `me-network-ae2-textures` only | `tools/import_ae2_textures.py` only |
| The texture mod's own code, locale and texts (`ae2-textures/info.json`, `overrides.lua`, `data-final-fixes.lua`, `locale/`, `changelog.txt`, `README.md`) | CC BY-NC-SA 3.0 (nothing in `ae2-textures/` is GPL) | `ae2-textures/` | `me-network-ae2-textures` | written here |
| Applied Energistics 2 text and translations | CC0 | `locale/`, `docs/`: the block and item names follow AE2's | `me-network` | names taken over, texts written here |

The sprites under `graphics/entity/fork/ae2/` are named after AE2's blocks but are **not** AE2 graphics: the script
draws them from GT5-Unofficial textures and Pillow shapes, so they are GPLv3/LGPL-3.0 like the rest.

**No graphics of the original Gregtorio (issue #238).** Until 0.5.2, 17 icons in `graphics/icons/` (the ME controller,
drive, terminal, interface and chest, the fluix cable, the storage housing and the storage components 1k to 256m) were
byte-identical to the original Gregtorio 0.1.9 by Damien Reave and look like Applied Energistics 2's art. Issue #238
replaced them by icons that `tools/gen_ae2_sprites.py --own-icons` draws, and drew the graphics that had been made from
them anew (cells, old drive items, fluid variants, the wireless terminal and module, five technology icons).
`tools/upstream-icon-hashes.tsv` keeps the old files' hashes, and `devcheck.py check` fails on a file with one of them
under `graphics/` or as `thumbnail.png` (with `--with-gregtorio` in that checkout too). As far as the maintainer knows,
no graphics of the original Gregtorio are left; releases 0.1.0 to 0.5.2 still contain the 17 files.

## Rules

- **The package rule.** The me-network zip never contains `ae2-textures/`, the CC BY-NC-SA text or a file with the
  bytes of an image of `ae2-textures/MANIFEST.tsv` or of its AE2 source, and no Lua file or `info.json` of it names the
  texture mod: me-network does not know it. The texture zip contains only its own files (`info.json`, `changelog.txt`,
  `data-final-fixes.lua`, `overrides.lua`, `locale/<language>/*.cfg`, the license text, `README.md`, `MANIFEST.tsv`)
  and the images of its manifest, never the GPL text. `tools/build.py` fails otherwise. Each zip goes only to its own
  page on the mod portal (`me-network`, `me-network-ae2-textures`): the release workflow uploads both through
  `tools/portal_upload.sh`, which takes the mod name from the zip's own `info.json` (issue #243).
- **Never mix origins in one image.** An image is either AE2-derived (and lies in `ae2-textures/graphics/`) or not; a
  file derived from AE2 and from GT5-Unofficial or Gregtorio graphics would have no license that satisfies both. The
  texture mod replaces one file or one layer of a me-network sprite at a time (`ae2-textures/overrides.lua`); the
  layers of another origin around it stay separate files of me-network.
- `tools/gen_ae2_sprites.py` makes the GPLv3/LGPL graphics and never reads AE2 graphics or the texture mod.
- AE2 graphics come into `ae2-textures/graphics/` only through `tools/import_ae2_textures.py`, from a checkout of AE2
  or of GTNewHorizons' AE2-Unofficial (the same authors' work under the same license), never traced and never from
  anywhere else. The manifest records the repository, the source path, the commit, the SHA-256 of the source, the
  author (from the checkout's README), the license and whether and how the file was changed.
- A change to a file in `ae2-textures/` (recolour, crop, scale, animation frames) stays CC BY-NC-SA 3.0 and stays in
  the folder; record an image's change with `tools/import_ae2_textures.py --mark-changed`. A contribution that touches
  the folder is made under CC BY-NC-SA 3.0.
- `python tools/devcheck/devcheck.py check` enforces the folder (every image has a manifest row, every row its image,
  nothing but the texture mod's own files and its images), builds both zips and runs the package checks, fails when a
  file outside the folder is byte-identical to an image of the manifest or to its AE2 source (with `--with-gregtorio`
  in the Gregtorio checkout too), and loads the texture mod next to me-network once.

## What CC BY-NC-SA 3.0 means for the texture mod

- **BY:** every AE2-derived file needs attribution: author, source, license link and a "changed" notice
  (`ae2-textures/MANIFEST.tsv`, `ae2-textures/README.md`).
- **NC:** the texture mod may not be used commercially, by us or by anyone who takes it. The maintainer has to keep
  this in mind for donations or paid offerings around it (nothing is decided here, it is only documented). me-network
  itself is GPLv3 and carries no NC part.
- **SA:** any change to a file of the texture mod stays CC BY-NC-SA 3.0.
- The texture mod is optional: me-network never needs it, and a player who installs only me-network gets nothing under
  CC BY-NC-SA 3.0.

## Gregtorio Continued

The sister repository ships no ME graphics since its issue #83, holds no AE2-derived file and depends on me-network
only, never on the texture mod. It has to stay so: if it ever needs AE2 graphics, it first gets a mod, a manifest and
checks of its own (a separate issue). `devcheck.py check --with-gregtorio <checkout>` here fails when a file of that
checkout is byte-identical to an image of `ae2-textures/MANIFEST.tsv` or to its AE2 source, or when its `info.json`
names the texture mod; that run never loads the texture mod.
