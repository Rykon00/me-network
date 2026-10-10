# ME Network - AE2 Textures (`me-network-ae2-textures`, CC BY-NC-SA 3.0)

An optional mod for [ME Network](https://github.com/Rykon00/me-network): it puts textures of
[Applied Energistics 2](https://github.com/AppliedEnergistics/Applied-Energistics-2) (or of GTNewHorizons'
[Applied-Energistics-2-Unofficial](https://github.com/GTNewHorizons/Applied-Energistics-2-Unofficial), the same
authors' work under the same license) in place of ME Network's own sprites. **Install ME Network too**: this mod
depends on it and does nothing alone, while ME Network runs complete without this mod and does not know it. It
replaces the item icons of the item and fluid storage cells (1k to 256k), the storage components and the housing, the
upgrade cards and the blank and encoded pattern (issues #247, #250, #251). AE2-Unofficial has no fluid cell and no
interface capacity card: the fluid cells show its item cell of their tier with a blue frame and body, the ME
Interface Capacity Card its Capacity Card with the turquoise stripe of an advanced card. The ME Drive, ME Chest, ME
Interface, ME Molecular Assembler, ME Cell Workbench and ME Charger are AE2-Unofficial's blocks in the world and AE2
cubes as icons (issue #260), the ME Pattern Provider its purple interface skin (issue #269, AE2-Unofficial has no provider); a cell in the drive or the chest is drawn as AE2 draws it (issue #264, through ME
Network's drive view). The ME Controller is four AE2-Unofficial controllers, dark without power, with AE2's running
lights while its network works and red in a conflict (issue #278, through ME Network's controller view). The ME
Terminal and the ME Pattern Terminal are AE2's terminal panels, dark or with their screen lit (issue #281). The ME
Import, Export and Storage Bus are AE2's bus fronts with ME Network's plate and arrows on them (issue #282, through ME
Network's bus view). The cable is AE2's Fluix glass cable (issue #283). The other blocks and the ME Underground Cable
look as without this mod.

**Nothing here is GPL.** This folder is a mod of its own, built into a zip of its own (`tools/build.py`), and
everything in it (the images, the code, the locale, these texts) is CC BY-NC-SA 3.0. ME Network is GPLv3 (its
GT5-Unofficial graphics LGPL-3.0) and lies in the rest of the repository; no zip holds both. See `docs/LICENSES.md`
in the repository.

- **Source:** every image so far comes from GTNewHorizons'
  [Applied-Energistics-2-Unofficial](https://github.com/GTNewHorizons/Applied-Energistics-2-Unofficial), commit
  `ab15e3a7259cbd9a7088138fade46e5f6f02ad18`, folders `src/main/resources/assets/appliedenergistics2/textures/items/`
  and `.../textures/blocks/` (the look GT New Horizons plays); `MANIFEST.tsv` names each file's source(s). The item
  icons are scaled from 16 x 16 to the size of the icon they replace (32 or 64 px, nearest neighbour, no new pixels)
  by `tools/scale_ae2_icons.py` of the repository, which first swaps some colours of the fluid cells and the
  interface capacity card. The blocks and their icons are made from a block face by `tools/ae2_blocks.py`: the face
  x3 with depth strips from its own edge and a contour, holes filled with its darkest colour; the working molecular
  assembler also from AE2's light animation (its second source). The manifest's notes say what was done to each.
- **Authors:** the AE2 textures and models are © 2013 - 2015 AlgorithmX2 et al. (AE2-Unofficial) and, in today's AE2,
  © 2020 Ridanisaurus Rid, © 2013 - 2020 AlgorithmX2 et al. The author of each file, as its repository's README states
  it, is in `MANIFEST.tsv`. The code and texts of this mod are by the ME Network contributors.
- **License:** [Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported](https://creativecommons.org/licenses/by-nc-sa/3.0/)
  (CC BY-NC-SA 3.0), the legal code is `LICENSE-CC-BY-NC-SA-3.0.txt`.
- **Changes:** `MANIFEST.tsv` says for every image whether it was changed (recoloured, cropped, scaled, put into an
  animation strip) and how. A file with `changed` `no` is a byte-identical copy of its source.

What the license means for this mod, in short:

1. **BY:** every image names its author, its source and this license (`MANIFEST.tsv`), and whether it was changed.
2. **NC:** nothing here may be used commercially, by this mod or by anyone who takes it.
3. **SA:** a changed version of a file here is CC BY-NC-SA 3.0 as well and stays in this mod.
4. One image is never put together from AE2 pixels and pixels of another origin: the mod replaces one of ME Network's
   files or layers by one of its own, and the layers of another origin around it stay separate files.
5. A contribution to this folder is made under CC BY-NC-SA 3.0.

## Files

| Path | Contents |
|---|---|
| `info.json` | the mod: `me-network-ae2-textures`, its own version, depends on `me-network` |
| `overrides.lua` | the table of what is replaced: `"<type>/<name>"` of an ME Network prototype to a file of this mod, or to a table from ME Network's file to this mod's (one entry per layer or file) |
| `data-updates.lua` | sets ME Network's drive view: where the cells and their lights sit on this mod's drive and chest, and the cell sprites (ME Network issues #264, #267; it makes their entities' pictures from it in its data-final-fixes); its controller view: the controller's lit and conflict pictures (issue #278); and its bus view: where the buses' plate and arrows sit on this mod's bus fronts (issue #282) |
| `data-final-fixes.lua` | sets those files on the prototypes by name (ME Network never renames a prototype); what it cannot apply it skips with a line in the log (`devcheck check` fails on it) |
| `locale/en/` | the mod's name and description |
| `changelog.txt` | this mod's own changelog |
| `graphics/` | the AE2-derived images, each with its row in `MANIFEST.tsv`: `icons/cells/`, `icons/cards/`, `icons/patterns/`, `icons/blocks/`, `blocks/` (with `blocks/lights/`: a texture the working molecular assembler is made with) |
| `LICENSE-CC-BY-NC-SA-3.0.txt`, `README.md`, `MANIFEST.tsv` | the license, this text, the manifest |

## The manifest

`MANIFEST.tsv` has one row per image (tab-separated, header in the first line):

| Column | Contents |
|---|---|
| `file` | the image's path inside `graphics/` |
| `repository` | the AE2 repository it was taken from |
| `source` | its path in that repository; a picture made from several textures of the same checkout (a block and its lights) lists them all, separated by `;` |
| `commit` | the commit of the checkout it was taken from |
| `source_sha256` | SHA-256 of the source file at that commit (one per source, in the same order) |
| `author` | the copyright line of "Textures and Models" in that repository's README |
| `license` | `CC BY-NC-SA 3.0` |
| `changed` | `no` (a byte-identical copy) or `yes` |
| `note` | what the file is for and, when changed, what was changed |

Images come in only through `tools/import_ae2_textures.py`, which writes the row; a change is recorded with its
`--mark-changed`. `python tools/devcheck/devcheck.py check` fails when an image has no row, a row has no image, the
folder holds anything else than the files above, or a file outside this folder is byte-identical to an image of the
manifest or to its source; it also loads this mod next to ME Network and checks that its overrides apply.
