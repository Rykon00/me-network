#!/usr/bin/env python3
"""Self-test of the guard against the icons taken over from Gregtorio 0.1.9 (tools/upstream_icons.py, issue #238): the
guard must pass on a clean tree and fail with a message that names the file on each broken one. The trees are built in a
temporary folder; `devcheck.py check` runs these cases, and

    python tools/devcheck/test_upstream_icon_guard.py -v

prints each case with the message the guard gave. The case with a real old icon takes its bytes from git history
(OLD_REF, the last release with the old files) and is skipped when that is not at hand (a shallow clone).
"""
import hashlib, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import upstream_icons as U

PNG = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR an old icon"
OTHER = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR an icon drawn here"
OLD_REF = "v0.5.2"
OLD_FILE = "graphics/icons/me-drive.png"
VERBOSE = False


def old_icon():
    """the bytes of an old icon from git history, or None"""
    r = subprocess.run(["git", "-C", str(ROOT), "show", f"{OLD_REF}:{OLD_FILE}"], capture_output=True)
    return r.stdout if r.returncode == 0 and r.stdout else None


class Guard(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="upstream-icon-guard-"))
        self.root = self.tmp / "mod"
        (self.root / "tools").mkdir(parents=True)
        (self.root / "graphics/icons").mkdir(parents=True)
        (self.root / "graphics/icons/me-drive.png").write_bytes(OTHER)
        self.write_list([("graphics/icons/me-drive.png", hashlib.sha256(PNG).hexdigest(), "v0.1.9-upstream")])

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def write_list(self, rows, header="\t".join(U.COLUMNS)):
        text = header + "\n" + "".join("\t".join(r) + "\n" for r in rows)
        (self.root / U.LIST).write_bytes(text.encode("utf-8"))

    def guard(self, others=()):
        count, problems, _ = U.check_tree(self.root, others)
        return count, problems

    def fails(self, expected, others=()):
        count, problems = self.guard(others)
        self.assertTrue(problems, "the guard passed a broken tree")
        self.assertTrue(any(expected in p for p in problems), f"no problem names {expected!r}: {problems}")
        if VERBOSE:
            print("".join(f"\n    guard: {p}" for p in problems), end="\n    ", file=sys.stderr)
        return problems

    def test_clean_tree_passes(self):
        self.assertEqual(self.guard(), (1, []))

    def test_old_icon_under_graphics(self):
        (self.root / "graphics/entity/fork").mkdir(parents=True)
        (self.root / "graphics/entity/fork/copy.png").write_bytes(PNG)
        self.fails("graphics/entity/fork/copy.png is byte-identical to graphics/icons/me-drive.png of v0.1.9-upstream")

    def test_old_icon_back_in_place(self):
        (self.root / "graphics/icons/me-drive.png").write_bytes(PNG)
        self.fails("graphics/icons/me-drive.png is byte-identical to graphics/icons/me-drive.png of v0.1.9-upstream")

    def test_old_icon_as_thumbnail(self):
        (self.root / "thumbnail.png").write_bytes(PNG)
        self.fails("thumbnail.png is byte-identical to graphics/icons/me-drive.png")

    def test_outside_graphics_ignored(self):
        (self.root / "docs").mkdir()
        (self.root / "docs/old.png").write_bytes(PNG)
        self.assertEqual(self.guard(), (1, []))

    def test_old_icon_in_other_checkout(self):
        other = self.tmp / "gregtorio"
        (other / "graphics/icons").mkdir(parents=True)
        (other / "graphics/icons/me-drive.png").write_bytes(PNG)
        self.fails("graphics/icons/me-drive.png is byte-identical to graphics/icons/me-drive.png of v0.1.9-upstream",
                   [other])

    def test_list_missing(self):
        (self.root / U.LIST).unlink()
        self.fails(f"{U.LIST} is missing")

    def test_list_empty(self):
        self.write_list([])
        self.fails(f"{U.LIST} lists no hash")

    def test_bad_header_and_row(self):
        self.write_list([], header="name\thash")
        self.fails("the first line must be the header")
        self.write_list([("graphics/icons/me-drive.png", "abc", "v0.1.9-upstream"), ("only two", "fields")])
        problems = self.fails("'abc' is not a SHA-256")
        self.assertTrue(any("2 fields, the header has 3" in p for p in problems))

    def test_real_old_icon(self):
        """a temporary copy of a real old icon (from OLD_REF) with the real hash list"""
        data = old_icon()
        if data is None:
            self.skipTest(f"{OLD_REF}:{OLD_FILE} is not in this clone's history")
        shutil.copyfile(ROOT / U.LIST, self.root / U.LIST)
        self.assertEqual(self.guard()[1], [])
        (self.root / "graphics/icons/me-drive.png").write_bytes(data)
        self.fails("graphics/icons/me-drive.png is byte-identical to graphics/icons/me-drive.png of v0.1.9-upstream")

    def test_real_tree_passes(self):
        count, problems, _ = U.check_tree(ROOT)
        self.assertEqual(problems, [])
        self.assertEqual(count, 17)


def run_quiet():
    """for devcheck, which checks the real tree itself: (cases run, [failed case: reason], [skipped case: reason])"""
    names = [n for n in unittest.defaultTestLoader.getTestCaseNames(Guard) if n != "test_real_tree_passes"]
    suite = unittest.TestSuite(Guard(n) for n in names)
    result = unittest.TestResult()
    suite.run(result)
    bad = [f"{t.id().rsplit('.', 1)[-1]}: {tb.strip().splitlines()[-1]}" for t, tb in result.failures + result.errors]
    skipped = [f"{t.id().rsplit('.', 1)[-1]}: {why}" for t, why in result.skipped]
    return result.testsRun, bad, skipped


if __name__ == "__main__":
    VERBOSE = "-v" in sys.argv
    unittest.main(verbosity=2 if VERBOSE else 1)
