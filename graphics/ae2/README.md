# graphics/ae2: graphics of Applied Energistics 2 (CC BY-NC-SA 3.0)

This folder is the one part of ME Network that is **not** GPLv3. It holds images taken from
[Applied Energistics 2](https://github.com/AppliedEnergistics/Applied-Energistics-2) (or from GTNewHorizons'
[Applied-Energistics-2-Unofficial](https://github.com/GTNewHorizons/Applied-Energistics-2-Unofficial), the same
authors' work under the same license) and images changed from them, and nothing of any other origin. The rest of the
mod (code, locale, docs, tools and the other graphics) is GPLv3 or LGPL-3.0: see `docs/LICENSES.md` in the repository.

- **Authors:** the AE2 textures and models are © 2013 - 2015 AlgorithmX2 et al. (AE2-Unofficial) and, in today's AE2,
  © 2020 Ridanisaurus Rid, © 2013 - 2020 AlgorithmX2 et al. The author of each file, as its repository's README states
  it, is in `MANIFEST.tsv`.
- **License:** [Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported](https://creativecommons.org/licenses/by-nc-sa/3.0/)
  (CC BY-NC-SA 3.0), the legal code is `LICENSE-CC-BY-NC-SA-3.0.txt`.
- **Changes:** `MANIFEST.tsv` says for every file whether it was changed (recoloured, cropped, scaled, put into an
  animation strip) and how. A file with `changed` `no` is a byte-identical copy of its source.

What the license means for this folder, in short:

1. **BY:** every file here names its author, its source and this license (`MANIFEST.tsv`), and whether it was changed.
2. **NC:** the files here may not be used commercially, by this mod or by anyone who takes them.
3. **SA:** a changed version of a file here is CC BY-NC-SA 3.0 as well and stays in this folder.
4. Nothing here is merged into one image with graphics of another origin; a sprite that needs both is two layers.
5. A contribution that touches this folder is made under CC BY-NC-SA 3.0.

## The manifest

`MANIFEST.tsv` has one row per image (tab-separated, header in the first line):

| Column | Contents |
|---|---|
| `file` | the image's path inside this folder |
| `repository` | the AE2 repository it was taken from |
| `source` | its path in that repository |
| `commit` | the commit of the checkout it was taken from |
| `source_sha256` | SHA-256 of the source file at that commit |
| `author` | the copyright line of "Textures and Models" in that repository's README |
| `license` | `CC BY-NC-SA 3.0` |
| `changed` | `no` (a byte-identical copy) or `yes` |
| `note` | what the file is for and, when changed, what was changed |

Files come in only through `tools/import_ae2_textures.py`, which writes the row; a change is recorded with its
`--mark-changed`. `python tools/devcheck/devcheck.py check` fails when a file has no row, a row has no file, the folder
holds anything else than images and the three documentation files (`LICENSE-CC-BY-NC-SA-3.0.txt`, `README.md`,
`MANIFEST.tsv`), or a file outside this folder is byte-identical to a file of the manifest or to its source.
