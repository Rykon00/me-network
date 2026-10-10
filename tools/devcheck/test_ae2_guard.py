#!/usr/bin/env python3
"""Self-test of the guard of the texture mod ae2-textures/ (tools/ae2_manifest.py, issues #235 and #239) and of the
package checks of tools/build.py: the guard and the checks must pass on a clean tree and fail with a clear message
on each broken one. The trees and zips are built in a temporary folder (the real manifest may be empty);
`devcheck.py check` runs these cases, and

    python tools/devcheck/test_ae2_guard.py -v

prints each case with the message the guard gave.
"""
import json, shutil, sys, tempfile, unittest, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import ae2_manifest as M
import build as B

PNG = M.PNG_MAGIC + b"\0\0\0\rIHDR an AE2 texture"
SRC_SHA = M.hashlib.sha256(PNG).hexdigest()
REPO = "https://github.com/AppliedEnergistics/Applied-Energistics-2"
ROW = dict(file="drive/bottom.png", repository=REPO, source=M.REPOSITORIES[REPO] + "block/drive/drive_bottom.png",
           commit="de2b845e9d1e5ac137e05018e5fa1dbd9e58d427", source_sha256=SRC_SHA,
           author="(c) 2020, Ridanisaurus Rid, (c) 2013 - 2020 AlgorithmX2 et al", license=M.LICENSE,
           changed="no", note="test texture")
VERBOSE = False


class Guard(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="ae2-guard-"))
        self.root = self.tmp / "mod"
        mod = self.root / M.MOD_FOLDER
        (mod / "locale/en").mkdir(parents=True)
        for d in (M.LICENSE_FILE, "README.md") + M.MOD_FILES:
            shutil.copyfile(ROOT / M.MOD_FOLDER / d, mod / d)
        (mod / "locale/en/me-network-ae2-textures.cfg").write_text("[mod-name]\n", encoding="utf-8")
        (self.root / "tools").mkdir()
        (self.root / "tools/gen_ae2_sprites.py").write_text('"""GT casings and Pillow shapes"""\n', encoding="utf-8")
        # the me-network side of the tree: enough for its zip
        shutil.copyfile(ROOT / "LICENSE", self.root / "LICENSE")
        (self.root / "info.json").write_text(json.dumps({"name": "me-network", "version": "9.9.9"}), encoding="utf-8")
        (self.root / "data.lua").write_text('require("prototypes.api")\n', encoding="utf-8")
        (self.root / "graphics/icons").mkdir(parents=True)
        (self.root / "graphics/icons/me-cable.png").write_bytes(M.PNG_MAGIC + b"a GPLv3 icon")
        self.rows = []
        M.write_manifest(self.rows, self.root)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def add(self, **change):
        """one imported texture: its file and its row"""
        row = dict(ROW, **change)
        p = self.root / M.FOLDER / row["file"]
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(PNG)
        self.rows.append(row)
        M.write_manifest(self.rows, self.root)
        return p

    def guard(self, others=()):
        count, problems, _ = M.check_tree(self.root, others)
        return count, problems

    def packages(self, include=None):
        """(me-network zip, texture zip, problems of both checks), built as tools/build.py builds them"""
        dist = self.tmp / "dist"
        dist.mkdir(exist_ok=True)
        old = B.INCLUDE
        B.INCLUDE = include or old
        try:
            me = B.build_me_network(self.root, dist)
        finally:
            B.INCLUDE = old
        tex = B.build_textures(self.root, dist)
        return me, tex, B.check_me_network_zip(me, self.root) + B.check_texture_zip(tex, self.root)

    def expect(self, problems, expected):
        self.assertTrue(problems, "the check passed a broken tree")
        self.assertTrue(any(expected in p for p in problems), f"no problem names {expected!r}: {problems}")
        if VERBOSE:
            print("".join(f"\n    guard: {p}" for p in problems), end="\n    ", file=sys.stderr)
        return problems

    def fails(self, expected, others=()):
        return self.expect(self.guard(others)[1], expected)

    def package_fails(self, expected, include=None):
        return self.expect(self.packages(include)[2], expected)

    # the guard of the texture mod's folder

    def test_empty_folder_passes(self):
        self.assertEqual(self.guard(), (0, []))

    def test_imported_file_passes(self):
        self.add()
        self.assertEqual(self.guard(), (1, []))

    def test_file_without_row(self):
        self.add()
        (self.root / M.FOLDER / "stray.png").write_bytes(PNG + b"other")
        self.fails("ae2-textures/graphics/stray.png: no row in MANIFEST.tsv")

    def test_row_without_file(self):
        self.add().unlink()
        self.fails("ae2-textures/graphics/drive/bottom.png does not exist")

    def test_copy_outside_folder(self):
        self.add()
        (self.root / "graphics/icons/me-drive.png").write_bytes(PNG)
        self.fails("graphics/icons/me-drive.png is byte-identical to ae2-textures/graphics/drive/bottom.png")

    def test_copy_of_source_outside_folder(self):
        p = self.add(changed="yes", note="recoloured")
        p.write_bytes(PNG + b"recoloured")
        self.assertEqual(self.guard(), (1, []))
        (self.root / "graphics/entity").mkdir(parents=True)
        (self.root / "graphics/entity/drive.png").write_bytes(PNG)
        self.fails("graphics/entity/drive.png is byte-identical to the AE2 source of ae2-textures/graphics/drive/bottom.png")

    # issue #260: a file made from more than one texture of the same checkout
    SECOND = M.PNG_MAGIC + b"\0\0\0\rIHDR the lights of an AE2 block"
    SECOND_ROW = dict(changed="yes", note="a block with its lights",
                      source=ROW["source"] + M.SOURCE_SEP + M.REPOSITORIES[REPO] + "block/drive/drive_lights.png",
                      source_sha256=SRC_SHA + M.SOURCE_SEP + M.hashlib.sha256(SECOND).hexdigest())

    def test_two_sources_pass(self):
        self.add(**self.SECOND_ROW).write_bytes(PNG + b"made from both")
        self.assertEqual(self.guard(), (1, []))

    def test_two_sources_unchanged(self):
        self.add(**dict(self.SECOND_ROW, changed="no"))
        self.fails("a file made from several sources is changed: yes")

    def test_two_sources_one_sha(self):
        self.add(**dict(self.SECOND_ROW, source_sha256=SRC_SHA)).write_bytes(PNG + b"made from both")
        self.fails("2 sources but 1 SHA-256 values")

    def test_two_sources_still_second_bytes(self):
        self.add(**self.SECOND_ROW).write_bytes(self.SECOND)
        self.fails("changed is yes, but the file is the source's bytes")

    def test_copy_of_second_source_outside_folder(self):
        self.add(**self.SECOND_ROW).write_bytes(PNG + b"made from both")
        (self.root / "graphics/entity").mkdir(parents=True)
        (self.root / "graphics/entity/lights.png").write_bytes(self.SECOND)
        self.fails("graphics/entity/lights.png is byte-identical to the AE2 source of ae2-textures/graphics/drive/bottom.png "
                   "(src/main/resources/assets/ae2/textures/block/drive/drive_lights.png)")

    def test_second_source_outside_textures(self):
        self.add(**dict(self.SECOND_ROW, source=ROW["source"] + M.SOURCE_SEP + "src/main/java/Lights.png")
                 ).write_bytes(PNG + b"made from both")
        self.fails("source 'src/main/java/Lights.png' is not under src/main/resources/assets/ae2/textures/")

    def test_copy_in_other_checkout(self):
        self.add()
        other = self.tmp / "gregtorio"
        (other / "graphics").mkdir(parents=True)
        (other / "graphics/me.png").write_bytes(PNG)
        self.fails("graphics/me.png is byte-identical to ae2-textures/graphics/drive/bottom.png", [other])

    def test_not_an_image(self):
        (self.root / M.FOLDER).mkdir(parents=True)
        (self.root / M.FOLDER / "notes.txt").write_text("x", encoding="utf-8")
        self.fails("notes.txt: not an image")

    def test_not_a_png(self):
        self.add()
        (self.root / M.FOLDER / "fake.png").write_bytes(b"GIF89a")
        self.fails("fake.png: not a PNG file")

    def test_foreign_file_in_mod(self):
        (self.root / M.MOD_FOLDER / "control.lua").write_text("-- GPLv3 code\n", encoding="utf-8")
        self.fails("ae2-textures/control.lua: not a file of the texture mod")

    def test_image_outside_graphics(self):
        (self.root / M.MOD_FOLDER / "thumbnail.png").write_bytes(PNG)
        self.fails("ae2-textures/thumbnail.png: not a file of the texture mod")

    def test_mod_file_missing(self):
        (self.root / M.MOD_FOLDER / "info.json").unlink()
        self.fails("ae2-textures/info.json is missing")

    def test_unchanged_but_different(self):
        self.add().write_bytes(PNG + b"edited")
        self.fails("changed is no, but the file is not the source's bytes")

    def test_bad_row(self):
        self.add(license="GPLv3", commit="main", repository="https://example.com/fork")
        problems = self.fails("license 'GPLv3' is not 'CC BY-NC-SA 3.0'")
        self.assertTrue(any("not a full git commit hash" in p for p in problems))
        self.assertTrue(any("not an AE2 repository" in p for p in problems))

    def test_source_outside_textures(self):
        self.add(source="src/main/resources/assets/ae2/models/block/drive.json")
        self.fails("is not under src/main/resources/assets/ae2/textures/")

    def test_license_text_changed(self):
        with open(self.root / M.MOD_FOLDER / M.LICENSE_FILE, "a", encoding="utf-8") as f:
            f.write("\nextra\n")
        self.fails("is not the legal code text of CC BY-NC-SA 3.0")

    def test_doc_missing(self):
        (self.root / M.MOD_FOLDER / "README.md").unlink()
        self.fails("ae2-textures/README.md is missing")

    def test_sprite_generator_names_folder(self):
        (self.root / "tools/gen_ae2_sprites.py").write_text('SRC = "ae2-textures/graphics/drive/bottom.png"\n', encoding="utf-8")
        self.fails("tools/gen_ae2_sprites.py line 1 names the texture mod")

    # the package checks of tools/build.py (issue #239): no zip holds both licenses

    def test_packages_pass(self):
        self.add()
        me, tex, problems = self.packages()
        self.assertEqual(problems, [])
        with zipfile.ZipFile(tex) as z:
            self.assertIn("me-network-ae2-textures_0.1.0/graphics/drive/bottom.png", z.namelist())
        with zipfile.ZipFile(me) as z:
            self.assertFalse([n for n in z.namelist() if "ae2-textures" in n or M.LICENSE_FILE in n])

    def test_texture_folder_in_me_network_zip(self):
        self.add()
        self.package_fails("ae2-textures/graphics/drive/bottom.png is a file of the texture mod",
                           include=B.INCLUDE + [M.MOD_FOLDER])

    def test_texture_bytes_in_me_network_zip(self):
        self.add()
        (self.root / "graphics/icons/me-drive.png").write_bytes(PNG)
        self.package_fails("graphics/icons/me-drive.png is byte-identical to ae2-textures/graphics/drive/bottom.png: "
                           "AE2 graphics are never in the me-network zip")

    def test_cc_text_in_me_network_zip(self):
        shutil.copyfile(ROOT / M.MOD_FOLDER / M.LICENSE_FILE, self.root / "graphics" / M.LICENSE_FILE)
        self.package_fails("is the CC BY-NC-SA 3.0 text; the me-network zip is GPLv3 only")

    def test_me_network_names_texture_mod(self):
        (self.root / "data.lua").write_text('if mods["me-network-ae2-textures"] then end\n', encoding="utf-8")
        self.package_fails("data.lua names me-network-ae2-textures; me-network never knows the texture mod")

    def test_file_without_row_in_texture_zip(self):
        self.add()
        (self.root / M.FOLDER / "stray.png").write_bytes(PNG + b"other")
        self.package_fails("graphics/stray.png has no row in ae2-textures/MANIFEST.tsv")

    def test_foreign_file_in_texture_zip(self):
        (self.root / M.MOD_FOLDER / "control.lua").write_text("-- GPLv3 code\n", encoding="utf-8")
        self.package_fails("control.lua is not a file of the texture mod")

    def test_gpl_text_in_texture_zip(self):
        shutil.copyfile(ROOT / "LICENSE", self.root / M.MOD_FOLDER / "LICENSE")
        self.package_fails("LICENSE is the GPLv3 text; the texture zip is CC BY-NC-SA 3.0 only")

    def test_real_tree_passes(self):
        count, problems, _ = M.check_tree(ROOT)
        self.assertEqual(problems, [])


def run_quiet():
    """for devcheck, which checks the real tree itself: (cases run, [failed case: reason])"""
    names = [n for n in unittest.defaultTestLoader.getTestCaseNames(Guard) if n != "test_real_tree_passes"]
    suite = unittest.TestSuite(Guard(n) for n in names)
    result = unittest.TestResult()
    suite.run(result)
    bad = [f"{t.id().rsplit('.', 1)[-1]}: {tb.strip().splitlines()[-1]}" for t, tb in result.failures + result.errors]
    return result.testsRun, bad


if __name__ == "__main__":
    VERBOSE = "-v" in sys.argv
    unittest.main(verbosity=2 if VERBOSE else 1)
