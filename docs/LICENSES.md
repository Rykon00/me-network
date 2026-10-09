# Licenses of ME Network

ME Network is GPLv3 (`LICENSE`), with one exception: the folder `graphics/ae2/`, which holds graphics of
Applied Energistics 2 under CC BY-NC-SA 3.0 (issue #235). This page lists every origin of what the repository and
the mod zip contain, where it lies and under which license. It is a record of what the authors state, not legal
advice.

## Origins

| Origin | License | Where | How it gets in |
|---|---|---|---|
| ME Network's own code, locale, docs and tools | GPLv3 (`LICENSE`) | everything not named below | written here |
| [GT5-Unofficial](https://github.com/GTNewHorizons/GT5-Unofficial) graphics by GTNewHorizons: machine casings and screens, circuit boards, circuits, an SMD chip, the signs of its machine GUI buttons | LGPL-3.0 | inside the sprites and icons of `graphics/entity/`, `graphics/icons/`, `graphics/technology/`, `thumbnail.png` | `tools/gen_ae2_sprites.py --gt <checkout>` |
| Original Gregtorio by Damien Reave: some item icons | GPLv3 | `graphics/icons/` | taken over from Gregtorio Continued |
| [Applied Energistics 2](https://github.com/AppliedEnergistics/Applied-Energistics-2) code (© 2013 - 2020 AlgorithmX2 et al.): functions ported to Lua | LGPL-3.0 (its API MIT) | the ported functions, each with a comment naming its source; the files are listed in `README.md`, "License" (none so far) | written anew for Lua and the Factorio API |
| Applied Energistics 2 textures and models (AE2: © 2020 Ridanisaurus Rid, © 2013 - 2020 AlgorithmX2 et al.; AE2-Unofficial: © 2013 - 2015 AlgorithmX2 et al.) | CC BY-NC-SA 3.0 | `graphics/ae2/` only (`graphics/ae2/README.md`, `graphics/ae2/MANIFEST.tsv`) | `tools/import_ae2_textures.py` only |
| Applied Energistics 2 text and translations | CC0 | `locale/`, `docs/`: the block and item names follow AE2's | names taken over, texts written here |

The sprites under `graphics/entity/fork/ae2/` are named after AE2's blocks but are **not** AE2 graphics: the script
draws them from GT5-Unofficial textures and Pillow shapes, so they are GPLv3/LGPL-3.0 like the rest.

## Rules

- **Never mix origins in one image.** An image is either AE2-derived (and lies in `graphics/ae2/`) or not; a file
  derived from AE2 and from GT5-Unofficial or Gregtorio graphics would have no license that satisfies both. A sprite
  that needs an AE2 part and a part of another origin is built from two layers in the prototype (Factorio `layers`),
  one file per origin.
- `tools/gen_ae2_sprites.py` makes the GPLv3/LGPL graphics and never reads AE2 graphics or `graphics/ae2/`.
- AE2 graphics come into `graphics/ae2/` only through `tools/import_ae2_textures.py`, from a checkout of AE2 or of
  GTNewHorizons' AE2-Unofficial (the same authors' work under the same license), never traced and never from anywhere
  else. The manifest records the repository, the source path, the commit, the SHA-256 of the source, the author, the
  license and whether and how the file was changed.
- A change to a file in `graphics/ae2/` (recolour, crop, scale, animation frames) stays CC BY-NC-SA 3.0 and stays in
  the folder; record it with `tools/import_ae2_textures.py --mark-changed`. A contribution that touches the folder is
  made under CC BY-NC-SA 3.0.
- `python tools/devcheck/devcheck.py check` enforces the folder (every file has a manifest row, every row its file,
  nothing but images and the three documentation files) and fails when a file outside it is byte-identical to a file
  of the manifest or to its AE2 source; with `--with-gregtorio` it compares the Gregtorio checkout as well.

## What CC BY-NC-SA 3.0 means for the folder

In the words of issue #235:

- **BY:** every AE2-derived file needs attribution: author, source, license link and a "changed" notice
  (`graphics/ae2/MANIFEST.tsv`, `graphics/ae2/README.md`).
- **NC:** the graphics folder may not be used commercially, by us or by anyone who takes it. The maintainer has to
  keep this in mind for donations or paid offerings around the mod (nothing is decided here, it is only documented).
- **SA:** any change to an AE2-derived file stays CC BY-NC-SA.
- Whether a Factorio mod with GPL code and NC graphics is "one work" or "an aggregate" is legally open. AE2 itself
  lives with the same split; keeping the folder separate, with no graphics mixed, is the mitigation.

## Gregtorio Continued

The sister repository ships no ME graphics since its issue #83 and holds no AE2-derived file. It has to stay so: if it
ever needs one, it first gets a folder, a manifest and checks of its own (a separate issue). `devcheck.py check
--with-gregtorio <checkout>` here fails when a file of that checkout is byte-identical to a file of
`graphics/ae2/MANIFEST.tsv` or to its AE2 source.
