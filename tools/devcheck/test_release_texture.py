#!/usr/bin/env python3
"""Self-test of the texture mod's release (issue #243): tools/release_textures.py (is the version of ae2-textures/ new,
may it be released) on temporary git repositories with release tags, and tools/portal_upload.sh (the upload step of
.github/workflows/release.yml for both mods) against a fake mod portal on 127.0.0.1. Nothing reaches the real portal.
Each failing case must fail with a message that names its cause; `devcheck.py check` runs these cases, and

    python tools/devcheck/test_release_texture.py -v

prints each case with the messages it gave. The upload cases need bash and curl (on Windows Git's bash); without them
they are skipped and say so.
"""
import contextlib, io, json, os, re, shutil, subprocess, sys, tempfile, threading, unittest, zipfile
from email.parser import BytesParser
from email.policy import default as email_policy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import release_textures as R

TEX = "me-network-ae2-textures"
KEY = "fake-key-for-the-self-test"
VERBOSE = False


def say(*lines):
    if VERBOSE:
        print("".join(f"\n    {line}" for line in lines), end="\n    ", file=sys.stderr)


def rmtree(path):
    """git's object files are read-only on Windows"""
    def retry(func, p, _):
        os.chmod(p, 0o700)
        func(p)
    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=retry)
    else:
        shutil.rmtree(path, onerror=retry)


class Repo:
    """a temporary git repository shaped like this one: info.json, changelog.txt, ae2-textures/"""

    def __init__(self, path):
        self.path = path
        path.mkdir(parents=True)
        self.git("init", "-q")
        self.write("info.json", json.dumps({"name": "me-network", "version": "0.5.2"}))
        self.write("changelog.txt", "Version: 0.5.2\n")

    def git(self, *args):
        r = subprocess.run(["git", "-C", str(self.path), "-c", "user.name=test", "-c", "user.email=test@example.invalid",
                            "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", "-c", "core.autocrlf=false", *args],
                           capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError(f"git {args}: {r.stderr}")
        return r.stdout.strip()

    def write(self, rel, text):
        p = self.path / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(text.encode("utf-8"))

    def textures(self, version, sections=None, readme=None):
        """the texture mod at version, its changelog with sections (default: just version)"""
        self.write("ae2-textures/info.json", json.dumps({"name": TEX, "title": "ME Network - AE2 Textures",
                                                         "version": version}))
        self.write("ae2-textures/changelog.txt", "".join(f"Version: {s}\n  Info:\n    - x\n"
                                                         for s in (sections or [version])))
        if readme is not None:
            self.write("ae2-textures/README.md", readme)

    def commit(self, tag=None):
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", "change")
        if tag:
            self.git("tag", tag)
        return self.git("rev-parse", "HEAD")


class Decide(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="release-texture-"))
        self.repo = Repo(self.tmp / "repo")

    def tearDown(self):
        rmtree(self.tmp)

    def decide(self, release_tag="v0.5.3", portal=(), hand=None):
        d = R.decide(self.repo.path, "HEAD", release_tag, portal, hand if hand is not None else {})
        say(*d["notes"], *(f"problem: {p}" for p in d["problems"]))
        return d

    def passes(self, new, **kw):
        d = self.decide(**kw)
        self.assertEqual(d["problems"], [], "a valid texture mod failed the check")
        self.assertEqual(d["new"], new, f"the texture version should{'' if new else ' not'} be new: {d['notes']}")
        return d

    def fails(self, expected, **kw):
        d = self.decide(**kw)
        self.assertTrue(d["problems"], f"the check passed a broken texture mod: {d['notes']}")
        self.assertTrue(any(expected in p for p in d["problems"]), f"no problem names {expected!r}: {d['problems']}")
        return d

    def released(self):
        """v0.5.2 released with the texture mod 0.1.0"""
        self.repo.textures("0.1.0", readme="first\n")
        return self.repo.commit("v0.5.2")

    # --- the rules of issue #243

    def test_unchanged_since_last_tag_is_not_new(self):
        self.released()
        self.repo.write("changelog.txt", "Version: 0.5.3\nVersion: 0.5.2\n")
        self.repo.commit()
        d = self.passes(False)
        self.assertEqual(d["last_tag"], "v0.5.2")
        self.assertIn("unchanged since v0.5.2", d["notes"][0])

    def test_changed_with_new_version_and_section_is_new(self):
        self.released()
        self.repo.textures("0.2.0", ["0.2.0", "0.1.0"], readme="second\n")
        self.repo.commit()
        self.assertIn("0.2.0 is new", self.passes(True)["notes"][0])

    def test_changed_without_new_version_fails(self):
        self.released()
        self.repo.write("ae2-textures/README.md", "changed\n")
        self.repo.commit()
        self.fails("ae2-textures/ changed since v0.5.2, but ae2-textures/info.json version 0.1.0 was released already "
                   "(release v0.5.2)")

    def test_new_version_without_changelog_section_fails(self):
        self.released()
        self.repo.textures("0.2.0", ["0.1.0"], readme="second\n")
        self.repo.commit()
        self.fails("ae2-textures/changelog.txt has no section 'Version: 0.2.0'")

    def test_missing_changelog_fails(self):
        self.released()
        self.repo.textures("0.2.0", readme="second\n")
        (self.repo.path / "ae2-textures/changelog.txt").unlink()
        self.repo.commit()
        self.fails("ae2-textures/changelog.txt has no section 'Version: 0.2.0'")

    def test_reused_older_version_fails(self):
        self.released()
        self.repo.textures("0.2.0", ["0.2.0", "0.1.0"], readme="second\n")
        self.repo.commit("v0.5.3")
        self.repo.textures("0.1.0", ["0.1.0"], readme="third\n")
        self.repo.commit()
        self.fails("version 0.1.0 was released already (release v0.5.2)", release_tag="v0.5.4")

    def test_version_on_the_portal_fails(self):
        self.released()
        self.repo.textures("0.2.0", ["0.2.0", "0.1.0"], readme="second\n")
        self.repo.commit()
        self.fails("version 0.2.0 was released already (the mod portal)", portal={"0.1.0", "0.2.0"})

    def test_first_release_of_the_texture_mod_is_new(self):
        self.repo.commit("v0.5.2")
        self.repo.textures("0.1.0")
        self.repo.commit()
        self.assertIn("changed since v0.5.2", self.passes(True)["notes"][0])

    def test_no_release_tag_at_all_is_new(self):
        self.repo.textures("0.1.0")
        self.repo.commit()
        d = self.passes(True)
        self.assertIsNone(d["last_tag"])

    def test_hand_release_unchanged_is_not_new(self):
        """the 0.1.0 of the portal, uploaded by hand from a commit after the last tag (HAND_RELEASES)"""
        self.repo.commit("v0.5.2")
        self.repo.textures("0.1.0")
        hand = self.repo.commit()
        self.repo.write("changelog.txt", "Version: 0.5.3\nVersion: 0.5.2\n")
        self.repo.commit()
        d = self.passes(False, hand={"0.1.0": hand}, portal={"0.1.0"})
        self.assertIn("as uploaded by hand", d["notes"][0])

    def test_hand_release_changed_since_fails(self):
        self.repo.commit("v0.5.2")
        self.repo.textures("0.1.0")
        hand = self.repo.commit()
        self.repo.write("ae2-textures/README.md", "changed after the hand upload\n")
        self.repo.commit()
        self.fails(f"version 0.1.0 was released already (the hand upload from {hand[:7]})",
                   hand={"0.1.0": hand}, portal={"0.1.0"})

    def test_tag_of_this_release_does_not_count(self):
        """a tag vX.Y.Z pushed by hand: the release's own tag is neither the last tag nor an earlier release"""
        self.released()
        self.repo.textures("0.2.0", ["0.2.0", "0.1.0"], readme="second\n")
        self.repo.commit("v0.5.3")
        d = self.passes(True, release_tag="v0.5.3")
        self.assertEqual(d["last_tag"], "v0.5.2")

    def test_other_tags_are_not_releases(self):
        self.released()
        self.repo.textures("0.2.0", ["0.2.0", "0.1.0"], readme="second\n")
        self.repo.commit("ae2-textures-test")
        self.repo.write("changelog.txt", "Version: 0.5.3\n")
        self.repo.commit()
        self.assertEqual(self.passes(True)["last_tag"], "v0.5.2")

    def test_version_order_is_numeric(self):
        """v0.10.0 comes after v0.9.0"""
        self.repo.textures("0.1.0")
        self.repo.commit("v0.10.0")
        self.repo.textures("0.2.0")
        self.repo.commit()
        self.repo.git("tag", "v0.9.0", "HEAD~1")
        self.assertEqual(self.passes(True)["last_tag"], "v0.10.0")

    # --- the command line the workflow runs

    def run_main(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = R.main(["--root", str(self.repo.path), "--release-tag", "v0.5.3", *args])
        say(*out.getvalue().splitlines())
        return code, out.getvalue()

    def test_cli_writes_the_outputs(self):
        self.released()
        self.repo.textures("0.2.0", ["0.2.0", "0.1.0"], readme="second\n")
        self.repo.commit()
        portal = self.tmp / "portal.json"
        portal.write_text(json.dumps({"releases": [{"version": "0.1.0"}]}), encoding="utf-8")
        outfile = self.tmp / "github_output"
        code, _ = self.run_main("--portal-json", str(portal), "--output", str(outfile))
        self.assertEqual(code, 0)
        self.assertEqual(outfile.read_text(encoding="utf-8").splitlines(), [
            f"textures_name={TEX}", "textures_title=ME Network - AE2 Textures", "textures_version=0.2.0",
            f"textures_zip=dist/{TEX}_0.2.0.zip", "textures_new=true", f"textures_attach=dist/{TEX}_0.2.0.zip"])

    def test_cli_not_new_attaches_nothing(self):
        self.released()
        self.repo.write("changelog.txt", "Version: 0.5.3\n")
        self.repo.commit()
        outfile = self.tmp / "github_output"
        self.assertEqual(self.run_main("--no-portal", "--output", str(outfile))[0], 0)
        lines = outfile.read_text(encoding="utf-8").splitlines()
        self.assertIn("textures_new=false", lines)
        self.assertIn("textures_attach=", lines)

    def test_cli_fails_with_an_error_line_and_no_outputs(self):
        self.released()
        self.repo.write("ae2-textures/README.md", "changed\n")
        self.repo.commit()
        outfile = self.tmp / "github_output"
        code, text = self.run_main("--no-portal", "--output", str(outfile))
        self.assertEqual(code, 1)
        self.assertRegex(text, r"(?m)^::error::ae2-textures/ changed since v0\.5\.2, but .* 0\.1\.0 was released already")
        self.assertFalse(outfile.exists(), "a failed check must not write the outputs")

    def test_cli_unreadable_portal_fails(self):
        self.released()
        code, text = self.run_main("--portal-json", str(self.tmp / "missing.json"))
        self.assertEqual(code, 1)
        self.assertIn(f"::error::cannot read the mod portal's versions of {TEX}", text)

    def test_hand_release_is_in_this_repository(self):
        """HAND_RELEASES names commits of this repository's history (skipped in a shallow clone)"""
        for version, commit in R.HAND_RELEASES.items():
            r = subprocess.run(["git", "-C", str(ROOT), "cat-file", "-t", commit], capture_output=True, text=True)
            if r.returncode:
                self.skipTest(f"{commit[:7]} is not in this clone's history")
            info = R.show_json(ROOT, commit, "ae2-textures/info.json")
            self.assertEqual(info and info["version"], version, f"{commit[:7]} does not hold the texture mod {version}")


def find_bash():
    """bash with curl: on Windows Git's (System32's bash is WSL's), else the one on PATH"""
    if os.name == "nt":
        git = shutil.which("git")
        for parent in Path(git).resolve().parents if git else []:
            for b in (parent / "bin/bash.exe", parent / "usr/bin/bash.exe"):
                if b.is_file():
                    return str(b)
        return None
    return shutil.which("bash")


class FakePortal(ThreadingHTTPServer):
    """the three calls of the mod portal that tools/portal_upload.sh makes; records what reaches it"""

    def __init__(self, releases, success=True):
        super().__init__(("127.0.0.1", 0), Handler)
        self.releases, self.success, self.calls, self.uploads = releases, success, [], []
        self.url = f"http://127.0.0.1:{self.server_address[1]}"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def form(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        msg = BytesParser(policy=email_policy).parsebytes(
            b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + body)
        return {p.get_param("name", header="content-disposition"): (p.get_filename(), p.get_payload(decode=True))
                for p in msg.iter_parts()}

    def do_GET(self):
        s = self.server
        s.calls.append(("GET", self.path))
        m = re.fullmatch(r"/api/mods/([\w-]+)", self.path)
        if m and m.group(1) in s.releases:
            return self.reply(200, {"name": m.group(1), "releases": [{"version": v} for v in s.releases[m.group(1)]]})
        self.reply(404, {"message": "Mod not found"})

    def do_POST(self):
        s = self.server
        s.calls.append(("POST", self.path))
        if self.path == "/api/v2/mods/releases/init_upload":
            if self.headers.get("Authorization") != f"Bearer {KEY}":
                return self.reply(403, {"error": "InvalidApiKey"})
            mod = self.form()["mod"][1].decode()
            return self.reply(200, {"upload_url": f"{s.url}/upload/{mod}"})
        if self.path.startswith("/upload/"):
            name, data = self.form()["file"]
            s.uploads.append((self.path[len("/upload/"):], name, data))
            return self.reply(200, {"success": s.success})
        self.reply(404, {})


class Upload(unittest.TestCase):
    def setUp(self):
        self.bash = find_bash()
        if not self.bash or subprocess.run([self.bash, "-c", "command -v curl"], capture_output=True).returncode:
            self.skipTest("no bash with curl (on Windows: Git for Windows)")
        self.tmp = Path(tempfile.mkdtemp(prefix="portal-upload-"))
        self.portal = None

    def tearDown(self):
        if self.portal:
            self.portal.shutdown()
            self.portal.server_close()
        shutil.rmtree(self.tmp)

    def serve(self, releases, success=True):
        self.portal = FakePortal(releases, success)
        threading.Thread(target=self.portal.serve_forever, daemon=True).start()

    def zip(self, name, version, top=None):
        path = self.tmp / f"{name}_{version}.zip"
        top = top or f"{name}_{version}"
        with zipfile.ZipFile(path, "w") as z:
            z.writestr(f"{top}/info.json", json.dumps({"name": name, "version": version}))
            z.writestr(f"{top}/changelog.txt", f"Version: {version}\n")
        return path

    def upload(self, zip_, expect, key=KEY):
        env = dict(os.environ, API_KEY=key, PYTHON=Path(sys.executable).as_posix(),
                   PORTAL_URL=self.portal.url if self.portal else "http://127.0.0.1:9")
        r = subprocess.run([self.bash, (ROOT / "tools/portal_upload.sh").as_posix(), zip_.as_posix(), expect],
                           capture_output=True, text=True, env=env)
        out = r.stdout + r.stderr
        say(*out.strip().splitlines())
        self.assertNotIn(KEY, out, "the upload printed the API key")
        return r.returncode, out

    def test_me_network_goes_to_its_own_page(self):
        self.serve({"me-network": ["0.5.2"], TEX: ["0.1.0"]})
        z = self.zip("me-network", "0.5.3")
        code, out = self.upload(z, "me-network")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.portal.uploads, [("me-network", z.name, z.read_bytes())])
        self.assertIn("Uploaded me-network 0.5.3", out)

    def test_texture_mod_goes_to_its_own_page(self):
        self.serve({"me-network": ["0.5.2"], TEX: ["0.1.0"]})
        z = self.zip(TEX, "0.2.0")
        code, out = self.upload(z, TEX)
        self.assertEqual(code, 0, out)
        self.assertEqual(self.portal.uploads, [(TEX, z.name, z.read_bytes())])

    def test_me_network_zip_never_goes_to_the_texture_page(self):
        self.serve({"me-network": ["0.5.2"], TEX: ["0.1.0"]})
        code, out = self.upload(self.zip("me-network", "0.5.3"), TEX)
        self.assertEqual(code, 1)
        self.assertIn(f"is the mod me-network, not {TEX}: not uploaded", out)
        self.assertEqual(self.portal.calls, [], "the portal was asked although the zip is of another mod")

    def test_zip_with_a_wrong_top_folder_is_refused(self):
        self.serve({TEX: ["0.1.0"]})
        code, out = self.upload(self.zip(TEX, "0.2.0", top=f"{TEX}_0.1.0"), TEX)
        self.assertNotEqual(code, 0)
        self.assertIn(f"top folder {TEX}_0.1.0 is not {TEX}_0.2.0 of its info.json", out)
        self.assertEqual(self.portal.calls, [])

    def test_version_on_the_portal_is_skipped(self):
        self.serve({TEX: ["0.1.0"]})
        code, out = self.upload(self.zip(TEX, "0.1.0"), TEX)
        self.assertEqual(code, 0, out)
        self.assertIn(f"already has {TEX} 0.1.0: skipping the upload", out)
        self.assertEqual(self.portal.calls, [("GET", f"/api/mods/{TEX}")])

    def test_without_key_nothing_is_sent(self):
        self.serve({TEX: ["0.1.0"]})
        code, out = self.upload(self.zip(TEX, "0.2.0"), TEX, key="")
        self.assertEqual(code, 0, out)
        self.assertIn("FACTORIO_MOD_API_KEY is not set: skipping", out)
        self.assertEqual(self.portal.calls, [])

    def test_refused_upload_fails(self):
        self.serve({TEX: ["0.1.0"]}, success=False)
        code, out = self.upload(self.zip(TEX, "0.2.0"), TEX)
        self.assertNotEqual(code, 0)
        self.assertIn("upload failed", out)

    def test_wrong_key_fails(self):
        self.serve({TEX: ["0.1.0"]})
        code, out = self.upload(self.zip(TEX, "0.2.0"), TEX, key="not-the-key")
        self.assertNotEqual(code, 0)
        self.assertIn("403", out)
        self.assertIn("init_upload failed", out)
        self.assertNotIn("Traceback", out)
        self.assertEqual(self.portal.uploads, [])


class Workflow(unittest.TestCase):
    """the wiring of .github/workflows/release.yml"""

    def setUp(self):
        self.yml = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")

    def test_every_upload_goes_through_the_script(self):
        self.assertNotIn("init_upload", self.yml, "an upload in release.yml does not use tools/portal_upload.sh")
        calls = re.findall(r"bash tools/portal_upload\.sh (\S+) (\S+)", self.yml)
        self.assertEqual(sorted(calls), [('"$ZIP"', '"$MOD"'), ('"$ZIP"', '"$MOD"')])

    def test_texture_upload_and_attach_only_when_new(self):
        step = self.yml.split("name: Upload the texture mod to the Factorio mod portal", 1)[1].split("- name:", 1)[0]
        self.assertIn("steps.rel.outputs.textures_new == 'true'", step)
        self.assertIn("MOD: ${{ steps.rel.outputs.textures_name }}", step)
        self.assertIn("ZIP: ${{ steps.rel.outputs.textures_zip }}", step)
        self.assertIn("${{ steps.rel.outputs.textures_attach }}", self.yml)
        self.assertNotIn("${{ steps.rel.outputs.textures_zip }}\n          body_path", self.yml)

    def test_me_network_upload_uses_its_own_name(self):
        step = self.yml.split("name: Upload me-network to the Factorio mod portal", 1)[1].split("- name:", 1)[0]
        self.assertIn("MOD: ${{ steps.rel.outputs.name }}", step)
        self.assertIn("ZIP: ${{ steps.rel.outputs.zip }}", step)


def run_quiet():
    """for devcheck: (cases run, [failed case: reason], [skipped case: reason])"""
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(c) for c in (Decide, Upload, Workflow))
    result = unittest.TestResult()
    suite.run(result)
    bad = [f"{t.id().rsplit('.', 1)[-1]}: {tb.strip().splitlines()[-1]}" for t, tb in result.failures + result.errors]
    skipped = [f"{t.id().rsplit('.', 1)[-1]}: {why}" for t, why in result.skipped]
    return result.testsRun, bad, skipped


if __name__ == "__main__":
    VERBOSE = "-v" in sys.argv
    unittest.main(verbosity=2 if VERBOSE else 1)
