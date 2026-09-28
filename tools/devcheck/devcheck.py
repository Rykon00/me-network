#!/usr/bin/env python3
"""Headless test harness for Gregtorio (Linux, e.g. cloud sessions / CI).

    python tools/devcheck/devcheck.py setup     # download headless Factorio + dependency mods
    python tools/devcheck/devcheck.py check     # load the mod and run all static checks
    python tools/devcheck/devcheck.py runtime   # place every machine on a map and run it
    python tools/devcheck/devcheck.py migrate --from-ref 0e935ba
                                                # create a save with an older version (git ref or
                                                # --from-zip), load it with the working copy
    python tools/devcheck/devcheck.py all       # check + runtime

Everything is kept in .devcheck/ in the repository root (git-ignored).

Setup needs network access to factorio.com and *.factorio.com. The required dependency
mods (see info.json) are downloaded from the mod portal, which needs a Factorio account:
set FACTORIO_USERNAME and FACTORIO_TOKEN (token: factorio.com -> your profile), or put the
zips into a folder and pass --mods-from DIR.

`check` fails (exit code 1) when any of these is true:
  * the mod does not load
  * a recipe/tech still references a missing prototype after the draft guard
  * a referenced __Gregtorio__/ file does not exist (headless Factorio does not load graphics,
    the real game crashes on missing files)
  * a sprite sheet is smaller than its width/height/frame_count need
  * an unlocked recipe cannot be crafted: no machine for its category, an ingredient that can
    never be obtained, or no reachable machine with enough fluid inputs/outputs
It also reports how many technologies are researchable and where progression stops.
"""
import argparse, json, os, re, shutil, subprocess, sys, tarfile, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
WORK = ROOT / ".devcheck"
FACTORIO = WORK / "factorio"
MODS = WORK / "mods"
LOG = WORK / "last-run.log"
BUILTIN = {"base", "core", "space-age", "quality", "elevated-rails"}


# --------------------------------------------------------------------------------------------
# setup
# --------------------------------------------------------------------------------------------

# factorio.com (Cloudflare) answers the default "Python-urllib" user agent with 403
USER_AGENT = "gregtorio-devcheck/1.0 (+https://github.com/Rykon00/Gregtorio)"


def urlopen(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}))


def download(url, dest):
    print(f"downloading {url.split('?')[0]}")
    with urlopen(url) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f)


def required_mods():
    info = json.loads((ROOT / "info.json").read_text(encoding="utf-8"))
    out = []
    for dep in info.get("dependencies", []):
        dep = dep.strip()
        if dep[:1] in "?!(~":
            continue
        name = re.split(r"\s*[<>=]", dep)[0].strip()
        if name not in BUILTIN:
            out.append(name)
    return out


def setup(a):
    WORK.mkdir(exist_ok=True)
    binary = FACTORIO / "bin/x64/factorio"
    if a.factorio:
        if FACTORIO.exists() or FACTORIO.is_symlink():
            FACTORIO.unlink() if FACTORIO.is_symlink() else shutil.rmtree(FACTORIO)
        FACTORIO.symlink_to(Path(a.factorio).resolve(), target_is_directory=True)
    elif not binary.exists():
        tar = WORK / "factorio-headless.tar.xz"
        download(f"https://factorio.com/get-download/{a.version}/headless/linux64", tar)
        with tarfile.open(tar) as t:
            t.extractall(WORK)
        tar.unlink()
    print("factorio:", subprocess.run([str(binary), "--version"], capture_output=True, text=True).stdout.splitlines()[0])

    MODS.mkdir(exist_ok=True)
    for name in required_mods():
        if list(MODS.glob(f"{name}_*.zip")):
            continue
        if a.mods_from:
            found = sorted(Path(a.mods_from).glob(f"{name}_*.zip"))
            if not found:
                sys.exit(f"{name}_*.zip not found in {a.mods_from}")
            shutil.copy2(found[-1], MODS / found[-1].name)
            print(f"copied {found[-1].name}")
            continue
        user, token = os.environ.get("FACTORIO_USERNAME"), os.environ.get("FACTORIO_TOKEN")
        if not user or not token:
            sys.exit(f"need {name}: set FACTORIO_USERNAME/FACTORIO_TOKEN or pass --mods-from DIR")
        meta = json.load(urlopen(f"https://mods.factorio.com/api/mods/{urllib.parse.quote(name)}"))
        rel = [r for r in meta["releases"] if r["info_json"].get("factorio_version") == "2.0"][-1]
        q = urllib.parse.urlencode({"username": user, "token": token})
        download(f"https://mods.factorio.com{rel['download_url']}?{q}", MODS / rel["file_name"])
    print("setup done")


# --------------------------------------------------------------------------------------------
# running factorio
# --------------------------------------------------------------------------------------------

def prepare_mods(with_runtime=False, gregtorio_zip=None):
    """mods/ = dependency zips + Gregtorio (working copy or a zip) + devcheck helper mods."""
    for p in MODS.iterdir():
        if p.name.startswith(("Gregtorio", "zz-gregtorio-devcheck")) or p.name == "mod-list.json":
            if p.is_symlink() or p.is_file():
                p.unlink()
            else:
                shutil.rmtree(p)
    if gregtorio_zip:
        import zipfile
        with zipfile.ZipFile(gregtorio_zip) as z:
            info = json.loads(z.read(next(n for n in z.namelist() if n.endswith("/info.json") and n.count("/") == 1)))
        # Factorio insists on <name>_<version>.zip
        shutil.copy2(gregtorio_zip, MODS / f"{info['name']}_{info['version']}.zip")
    else:
        (MODS / "Gregtorio").symlink_to(ROOT, target_is_directory=True)
    (MODS / "zz-gregtorio-devcheck").symlink_to(HERE / "checkmod", target_is_directory=True)
    enabled = ["base", "space-age", "quality", "elevated-rails", "Gregtorio", "zz-gregtorio-devcheck"]
    enabled += [z.name.rsplit("_", 1)[0] for z in MODS.glob("*.zip") if not z.name.startswith("Gregtorio")]
    if with_runtime:
        (MODS / "zz-gregtorio-devcheck-runtime").symlink_to(HERE / "runtimemod", target_is_directory=True)
        enabled.append("zz-gregtorio-devcheck-runtime")
    (MODS / "mod-list.json").write_text(json.dumps({"mods": [{"name": n, "enabled": True} for n in enabled]}))


def factorio(*args):
    binary = FACTORIO / "bin/x64/factorio"
    if not binary.exists():
        sys.exit("run `devcheck.py setup` first")
    r = subprocess.run([str(binary), "--mod-directory", str(MODS), *args], capture_output=True, text=True)
    LOG.write_text(r.stdout + r.stderr)
    return r.stdout + r.stderr


def sections(log):
    out = {}
    for m in re.finditer(r"DEVCHECK-([A-Z]+)-BEGIN\n(.*?)\nDEVCHECK-\1-END", log, re.S):
        out[m.group(1)] = [l.split("\t") for l in m.group(2).splitlines() if l]
    return out


def load_errors(log):
    if "Map version" in log or "Performed" in log:
        return None
    m = re.search(r"(Error.*?)(\n\s*\d+\.\d+ |\Z)", log, re.S)
    return m.group(1).strip() if m else "unknown error (see .devcheck/last-run.log)"


# --------------------------------------------------------------------------------------------
# analysis
# --------------------------------------------------------------------------------------------

class Model:
    def __init__(self, rows):
        split = lambda s: [x.split(":", 1)[1] for x in s.split(",") if x]
        kinds = lambda s: [x.split(":", 1)[0] for x in s.split(",") if x]
        self.R, self.C, self.CF, self.I, self.T = {}, {}, {}, {}, {}
        self.base = {"water", "steam"}
        for p in rows:
            k = p[0]
            if k == "R":
                self.R[p[1]] = dict(cat=p[2], en=p[3] == "true", ing=split(p[4]), res=split(p[5]),
                                    fin=kinds(p[4]).count("fluid"), fout=kinds(p[5]).count("fluid"))
            elif k == "C":
                self.C[p[1]] = p[3].split(",") if p[3] else []
                self.CF[p[1]] = (int(p[4]), int(p[5]))
            elif k == "I":
                self.I[p[1]] = p[3]
            elif k == "T":
                self.T[p[1]] = dict(pre=[x for x in p[2].split(",") if x], eff=[x for x in p[3].split(",") if x],
                                    sci=[x for x in p[4].split(",") if x], trig=p[5], en=p[6] == "true")
            elif k == "M" and p[4] != "gregtorio-disabled":
                if p[2]:
                    self.base.add(p[2])
                self.base.update(x.split(":", 1)[1] for x in p[3].split(",") if x)
            elif k == "O" and p[2]:
                self.base.add(p[2])
        self.solve()

    def solve(self):
        """Fixed point: what can be obtained, crafted and researched from the start."""
        R, C, T = self.R, self.C, self.T
        item_of = {}
        for it, pr in self.I.items():
            if pr:
                item_of.setdefault(pr, []).append(it)
        self.avail, self.researched = set(self.base), set()
        self.unlocked = {r for r, v in R.items() if v["en"]}
        self.crafters = {"character"}
        changed = True
        while changed:
            changed = False
            for e in C:
                if e not in self.crafters and any(i in self.avail for i in item_of.get(e, [])):
                    self.crafters.add(e)
                    changed = True
            cats = {c for m in self.crafters for c in C.get(m, [])}
            for r in self.unlocked:
                v = R[r]
                if v["cat"] in cats and all(i in self.avail for i in v["ing"]):
                    for x in v["res"]:
                        if x not in self.avail:
                            self.avail.add(x)
                            changed = True
            for t, v in T.items():
                if t in self.researched or not v["en"] or not all(p in self.researched for p in v["pre"]):
                    continue
                if v["sci"] and not all(s in self.avail for s in v["sci"]):
                    continue
                m = re.search(r'item = "([^"]+)"', v["trig"])
                if m and "craft" in v["trig"] and m.group(1) not in self.avail:
                    continue
                self.researched.add(t)
                changed = True
                self.unlocked.update(r for r in v["eff"] if r in R)
        self.cats = {c for m in self.crafters for c in C.get(m, [])}

    def frontier(self):
        out = []
        for t, v in sorted(self.T.items()):
            if t not in self.researched and v["en"] and all(p in self.researched for p in v["pre"]):
                out.append((t, [s for s in v["sci"] if s not in self.avail]))
        return out

    def uncraftable(self):
        out = []
        for r in sorted(self.unlocked):
            v = self.R[r]
            if r.endswith("-recycling") or r.startswith("void-") or v["cat"] in ("recycling", "parameters"):
                continue
            missing = [i for i in v["ing"] if i not in self.avail]
            machines = [m for m in self.crafters if v["cat"] in self.C.get(m, [])]
            if not machines:
                out.append((r, f"no machine for category {v['cat']}"))
            elif missing:
                out.append((r, "ingredients never obtainable: " + ", ".join(missing)))
            elif (v["fin"] or v["fout"]) and not any(
                    self.CF.get(m, (0, 0))[0] >= v["fin"] and self.CF.get(m, (0, 0))[1] >= v["fout"] for m in machines):
                out.append((r, f"needs {v['fin']} fluid in / {v['fout']} out, no reachable machine has that"))
        return out


def check_files(sec):
    missing = []
    for path, owner in sec.get("PATHS", []):
        if not (ROOT / path[len("__Gregtorio__/"):]).exists():
            missing.append(f"{path} ({owner})")
    return sorted(set(missing))


def check_sprites(sec):
    try:
        from PIL import Image
    except ImportError:
        return ["(Pillow not installed, sprite sizes not checked: pip install pillow)"]
    bad = []
    for name, key, fn, w, h, fc, ll, x, y in sec.get("SPRITES", []):
        if not fn.startswith("__Gregtorio__/"):
            continue
        f = ROOT / fn[len("__Gregtorio__/"):]
        if not f.exists():
            continue
        w, h, fc, ll, x, y = map(int, (w, h, fc, ll, x, y))
        ll = ll or fc
        W, H = Image.open(f).size
        need_w, need_h = x + min(ll, fc) * w, y + -(-fc // ll) * h
        if need_w > W or need_h > H:
            bad.append(f"{name} {key}: {fn} needs {need_w}x{need_h}, image is {W}x{H}")
    return bad


def report(title, items, limit=40):
    print(f"\n{title}: {len(items)}")
    for i in items[:limit]:
        print("  -", i)
    if len(items) > limit:
        print(f"  ... {len(items) - limit} more")


def check(a):
    prepare_mods()
    log = factorio("--create", str(WORK / "check-map.zip"))
    err = load_errors(log)
    sec = sections(log)
    validate = [" ".join(r) for r in sec.get("VALIDATE", [])]
    drafts = re.findall(r"FORK-DRAFT: recipe (\S+)", log)
    print(f"load: {'FAILED' if err else 'ok'}")
    if validate:
        report("references to missing prototypes (not caught by the draft guard)", validate)
    if err:
        print("\n" + err)
        return 1
    print(f"draft recipes hidden by the draft guard: {len(drafts)} (FORK-DRAFT in .devcheck/last-run.log)")
    m = Model(sec["DUMP"])
    files, sprites, uncraft = check_files(sec), check_sprites(sec), m.uncraftable()
    print(f"\nresearchable technologies: {len(m.researched)} of {sum(1 for v in m.T.values() if v['en'])}")
    for t, miss in m.frontier():
        print(f"  progression stops at {t}" + (f" (missing science: {', '.join(miss)})" if miss else ""))
    report("missing graphics files", files)
    report("sprite sheets too small", sprites)
    report("unlocked but uncraftable recipes", [f"{r}: {why}" for r, why in uncraft])
    if a.locale_out:
        Path(a.locale_out).write_text("\n".join("\t".join(r) for r in sec.get("LOCALE", [])))
        print(f"\nlocale name list written to {a.locale_out} (input for tools/gen_locale.py)")
    ok = not (files or [s for s in sprites if not s.startswith("(")] or uncraft)
    print("\nRESULT:", "OK" if ok else "PROBLEMS FOUND")
    return 0 if ok else 1


def runtime(a):
    prepare_mods(with_runtime=True)
    log = factorio("--create", str(WORK / "runtime-map.zip"))
    if load_errors(log):
        print(load_errors(log))
        return 1
    placed = re.search(r"DEVCHECK-RUNTIME (placed=.*)", log)
    fails = re.findall(r"DEVCHECK-RUNTIME-FAIL (.*)", log)
    print("runtime setup:", placed.group(1) if placed else "no result")
    log = factorio("--benchmark", str(WORK / "runtime-map.zip"), "--benchmark-ticks", str(a.ticks))
    ran = re.search(r"Performed (\d+) updates", log)
    err = re.search(r"(Error.*|non-recoverable.*)", log)
    print(f"benchmark: {ran.group(0) if ran else 'did not run'}")
    report("machines that could not be placed", fails)
    if err or not ran or fails:
        print(err.group(1) if err else "")
        print("\nRESULT: PROBLEMS FOUND")
        return 1
    print("\nRESULT: OK")
    return 0


def zip_from_ref(ref):
    """Build a mod zip of an older git ref (tag or commit), e.g. the upstream 0.1.9 import."""
    info = json.loads(subprocess.run(["git", "-C", str(ROOT), "show", f"{ref}:info.json"],
                                     capture_output=True, text=True, check=True).stdout)
    out = WORK / f"{info['name']}_{info['version']}.zip"
    subprocess.run(["git", "-C", str(ROOT), "archive", "--format=zip",
                    f"--prefix={info['name']}_{info['version']}/", "-o", str(out), ref], check=True)
    return out


def migrate(a):
    """Create a map with an older Gregtorio version, then load and run it with the working copy."""
    old = a.from_zip or zip_from_ref(a.from_ref)
    prepare_mods(gregtorio_zip=old)
    log = factorio("--create", str(WORK / "migrate-map.zip"))
    if load_errors(log):
        print("could not create the map with the old version:\n" + load_errors(log))
        return 1
    prepare_mods()
    log = factorio("--benchmark", str(WORK / "migrate-map.zip"), "--benchmark-ticks", str(a.ticks))
    ran = re.search(r"Performed (\d+) updates", log)
    print(f"old save loaded with working copy: {'ok, ' + ran.group(0) if ran else 'FAILED'}")
    if not ran:
        print(load_errors(log) or "")
    return 0 if ran else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("setup")
    s.add_argument("--version", default="stable", help="Factorio version, e.g. 2.0.77 (default: stable)")
    s.add_argument("--factorio", help="use an existing unpacked headless Factorio instead of downloading")
    s.add_argument("--mods-from", help="folder with the dependency mod zips instead of downloading them")
    c = sub.add_parser("check")
    c.add_argument("--locale-out", help="also write the locale name list for tools/gen_locale.py")
    r = sub.add_parser("runtime")
    r.add_argument("--ticks", type=int, default=600)
    m = sub.add_parser("migrate")
    src = m.add_mutually_exclusive_group(required=True)
    src.add_argument("--from-zip", help="older Gregtorio_x.y.z.zip to create the save with")
    src.add_argument("--from-ref", help="git tag or commit of an older version, e.g. 0e935ba (upstream 0.1.9)")
    m.add_argument("--ticks", type=int, default=300)
    al = sub.add_parser("all")
    al.add_argument("--ticks", type=int, default=600)
    al.add_argument("--locale-out")
    a = ap.parse_args()
    if a.cmd == "setup":
        return setup(a)
    if a.cmd == "check":
        return check(a)
    if a.cmd == "runtime":
        return runtime(a)
    if a.cmd == "migrate":
        return migrate(a)
    return check(a) or runtime(a)


if __name__ == "__main__":
    sys.exit(main())
