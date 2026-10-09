#!/usr/bin/env python3
"""Self-test of the guard of graphics/ae2/ (tools/ae2_manifest.py, issue #235): the guard must pass on a clean tree
and fail with a clear message on each broken one. The trees are built in a temporary folder (the real manifest may
be empty); `devcheck.py check` runs these cases, and

    python tools/devcheck/test_ae2_guard.py -v

prints each case with the message the guard gave.
"""
import shutil, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import ae2_manifest as M

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
        folder = self.root / M.FOLDER
        folder.mkdir(parents=True)
        for d in (M.LICENSE_FILE, "README.md"):
            shutil.copyfile(ROOT / M.FOLDER / d, folder / d)
        (self.root / "tools").mkdir()
        (self.root / "tools/gen_ae2_sprites.py").write_text('"""GT casings and Pillow shapes"""\n', encoding="utf-8")
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

    def fails(self, expected):
        count, problems = self.guard()
        self.assertTrue(problems, "the guard passed a broken tree")
        self.assertTrue(any(expected in p for p in problems), f"no problem names {expected!r}: {problems}")
        if VERBOSE:
            for p in problems:
                print(f"\n    guard: {p}", end="", file=sys.stderr)
        return problems

    def test_empty_folder_passes(self):
        self.assertEqual(self.guard(), (0, []))

    def test_imported_file_passes(self):
        self.add()
        self.assertEqual(self.guard(), (1, []))

    def test_file_without_row(self):
        self.add()
        (self.root / M.FOLDER / "stray.png").write_bytes(PNG + b"other")
        self.fails("stray.png: no row in MANIFEST.tsv")

    def test_row_without_file(self):
        self.add().unlink()
        self.fails("graphics/ae2/drive/bottom.png does not exist")

    def test_copy_outside_folder(self):
        self.add()
        (self.root / "graphics/icons").mkdir(parents=True)
        (self.root / "graphics/icons/me-drive.png").write_bytes(PNG)
        self.fails("graphics/icons/me-drive.png is byte-identical to graphics/ae2/drive/bottom.png")

    def test_copy_of_source_outside_folder(self):
        p = self.add(changed="yes", note="recoloured")
        p.write_bytes(PNG + b"recoloured")
        self.assertEqual(self.guard(), (1, []))
        (self.root / "graphics/entity").mkdir(parents=True)
        (self.root / "graphics/entity/drive.png").write_bytes(PNG)
        self.fails("graphics/entity/drive.png is byte-identical to the AE2 source of graphics/ae2/drive/bottom.png")

    def test_copy_in_other_checkout(self):
        self.add()
        other = self.tmp / "gregtorio"
        (other / "graphics").mkdir(parents=True)
        (other / "graphics/me.png").write_bytes(PNG)
        count, problems = self.guard([other])
        self.assertTrue(any("graphics/me.png is byte-identical" in p for p in problems), problems)

    def test_not_an_image(self):
        (self.root / M.FOLDER / "notes.txt").write_text("x", encoding="utf-8")
        self.fails("notes.txt: not an image")

    def test_not_a_png(self):
        self.add()
        (self.root / M.FOLDER / "fake.png").write_bytes(b"GIF89a")
        self.fails("fake.png: not a PNG file")

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
        with open(self.root / M.FOLDER / M.LICENSE_FILE, "a", encoding="utf-8") as f:
            f.write("\nextra\n")
        self.fails("is not the legal code text of CC BY-NC-SA 3.0")

    def test_doc_missing(self):
        (self.root / M.FOLDER / "README.md").unlink()
        self.fails("graphics/ae2/README.md is missing")

    def test_sprite_generator_names_folder(self):
        (self.root / "tools/gen_ae2_sprites.py").write_text('SRC = "graphics/ae2/drive/bottom.png"\n', encoding="utf-8")
        self.fails("tools/gen_ae2_sprites.py line 1 names graphics/ae2/")

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
