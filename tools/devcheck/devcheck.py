#!/usr/bin/env python3
"""Headless test harness for ME Network (me-network).

    python tools/devcheck/devcheck.py setup                 # link or download headless Factorio
    python tools/devcheck/devcheck.py check                 # load the mod and run the static checks (vanilla)
    python tools/devcheck/devcheck.py runtime               # the ME runtime tests on a new map (vanilla)
    python tools/devcheck/devcheck.py all                   # check + runtime
    python tools/devcheck/devcheck.py all --with-gregtorio ../Gregtorio
                                                            # the same with Gregtorio Continued loaded

Everything is kept in .devcheck/ in the repository root (git-ignored). The working copy is linked into the test
mod folder, so every run tests the current files.

`check` fails (exit code 1) when the mods do not load, a recipe or technology references a missing prototype, a
referenced __me-network__/ file is missing, a sprite sheet is too small, a name is missing in locale/en, a
technology of this mod cannot be researched, a recipe of this mod is not unlocked by a researchable technology or
cannot be crafted, or an unlocked recipe of the game cannot be crafted. `runtime` fails when a runtime test fails
or does not finish.
"""
import argparse, json, os, re, shutil, subprocess, sys, tarfile, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
WORK = ROOT / ".devcheck"
FACTORIO = WORK / "factorio"
MODS = WORK / "mods"
LOG = WORK / "last-run.log"
# `runtime` creates its map with this seed, so a run is reproducible; `--seed N` or `--seed random` picks another
DEFAULT_SEED = 3115102263
BUILTIN = {"base", "core", "space-age", "quality", "elevated-rails"}
NAME = "me-network"
GREGTORIO = "gregtorio-continued"
HELPERS = ("zz-me-network-devcheck",)
# factorio.com (Cloudflare) answers the default "Python-urllib" user agent with 403
USER_AGENT = "me-network-devcheck/1.0 (+https://github.com/Rykon00/me-network)"


# --------------------------------------------------------------------------------------------
# setup
# --------------------------------------------------------------------------------------------

def urlopen(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}))


def download(url, dest):
    print(f"downloading {url.split('?')[0]}")
    with urlopen(url) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f)


def required_mods(info_path):
    info = json.loads(Path(info_path).read_text(encoding="utf-8"))
    out = []
    for dep in info.get("dependencies", []):
        dep = dep.strip()
        if dep[:1] in "?!(~":
            continue
        name = re.split(r"\s*[<>=]", dep)[0].strip()
        if name not in BUILTIN and name != NAME:
            out.append(name)
    return out


def setup(a):
    """headless Factorio (download, or --factorio DIR), and for --with-gregtorio runs the dependency mods of
    Gregtorio Continued (from the mod portal, or --mods-from DIR)"""
    WORK.mkdir(exist_ok=True)
    binary = FACTORIO / ("bin/x64/factorio.exe" if os.name == "nt" else "bin/x64/factorio")
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
    for name in required_mods(Path(a.with_gregtorio) / "info.json") if a.with_gregtorio else []:
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

def link_dir(link, target):
    """Directory link; on Windows without symlink rights a junction (never follow it when deleting)."""
    try:
        link.symlink_to(target, target_is_directory=True)
    except OSError:
        if os.name != "nt":
            raise
        subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(target)], check=True, capture_output=True)


def remove_path(p):
    if p.is_symlink() or (hasattr(p, "is_junction") and p.is_junction()):
        os.rmdir(p) if os.name == "nt" and p.is_dir() else p.unlink()
    elif p.is_file():
        p.unlink()
    else:
        shutil.rmtree(p)


def prepare_mods(gregtorio=None, with_runtime=False, base_only=False):
    """mods/ = this mod (working copy) + the devcheck helper mods; with Gregtorio its checkout and its dependency
    zips. base_only: without Space Age and quality."""
    MODS.mkdir(parents=True, exist_ok=True)
    for p in MODS.iterdir():
        if p.name in (NAME, GREGTORIO, "mod-list.json") or p.name.startswith(HELPERS):
            remove_path(p)
    link_dir(MODS / NAME, ROOT)
    link_dir(MODS / "zz-me-network-devcheck", HERE / "checkmod")
    enabled = ["base", NAME, "zz-me-network-devcheck"]
    disabled = ["space-age", "quality", "elevated-rails"] if base_only else []
    if not base_only:
        enabled += ["space-age", "quality", "elevated-rails"]
    zips = [z.name.rsplit("_", 1)[0] for z in MODS.glob("*.zip")]
    if gregtorio:
        link_dir(MODS / GREGTORIO, Path(gregtorio).resolve())
        enabled += [GREGTORIO] + zips
    else:
        disabled += zips
    if with_runtime:
        link_dir(MODS / "zz-me-network-devcheck-runtime", HERE / "runtimemod")
        enabled.append("zz-me-network-devcheck-runtime")
    (MODS / "mod-list.json").write_text(json.dumps({"mods": [{"name": n, "enabled": True} for n in enabled]
                                                    + [{"name": n, "enabled": False} for n in disabled]}))


def factorio(*args):
    binary = FACTORIO / ("bin/x64/factorio.exe" if os.name == "nt" else "bin/x64/factorio")
    if not binary.exists():
        sys.exit("run `devcheck.py setup` first")
    r = subprocess.run([str(binary), "--mod-directory", str(MODS), *args], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    LOG.write_text(r.stdout + r.stderr, encoding="utf-8")
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


def not_saved(log):
    """--create runs on_init and then saves; a failed save keeps the previous map file"""
    m = re.search(r"Writing .* failed.*|Error while running event .*on_save.*\n.*", log)
    return "the map was not saved: " + m.group(0).strip() if m else None


# --------------------------------------------------------------------------------------------
# analysis
# --------------------------------------------------------------------------------------------

class Model:
    """progression as a fixed point: from water, steam, the resources and the recipes enabled from the start, add
    everything reachable machines can craft and every technology whose prerequisites and packs are available"""

    def __init__(self, rows):
        split = lambda s: [x.split(":", 1)[1] for x in s.split(",") if x]
        kinds = lambda s: [x.split(":", 1)[0] for x in s.split(",") if x]
        self.R, self.C, self.CF, self.I, self.T, self.B = {}, {}, {}, {}, {}, {}
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
            elif k == "B":
                self.B[p[1]] = p[2]
        self.solve()

    def solve(self):
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
            for fuel, burnt in self.B.items():
                if fuel in self.avail and burnt not in self.avail:
                    self.avail.add(burnt)
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

    def why_not(self, r):
        v = self.R[r]
        machines = [m for m in self.crafters if v["cat"] in self.C.get(m, [])]
        missing = [i for i in v["ing"] if i not in self.avail]
        if not machines:
            return f"no machine for category {v['cat']}"
        if missing:
            return "ingredients never obtainable: " + ", ".join(missing)
        if (v["fin"] or v["fout"]) and not any(
                self.CF.get(m, (0, 0))[0] >= v["fin"] and self.CF.get(m, (0, 0))[1] >= v["fout"] for m in machines):
            return f"needs {v['fin']} fluid in / {v['fout']} out, no reachable machine has that"
        return None

    def uncraftable(self):
        out = []
        for r in sorted(self.unlocked):
            if r.endswith("-recycling") or self.R[r]["cat"] in ("recycling", "parameters"):
                continue
            why = self.why_not(r)
            if why:
                out.append((r, why))
        return out


def check_files(sec):
    missing = []
    for path, owner in sec.get("PATHS", []):
        if not (ROOT / path[len("__me-network__/"):]).exists():
            missing.append(f"{path} ({owner})")
    return sorted(set(missing))


def check_sprites(sec):
    try:
        from PIL import Image
    except ImportError:
        return ["(Pillow not installed, sprite sizes not checked: pip install pillow)"]
    bad = []
    for name, key, fn, w, h, fc, ll, x, y in sec.get("SPRITES", []):
        if not fn.startswith("__me-network__/"):
            continue
        f = ROOT / fn[len("__me-network__/"):]
        if not f.exists():
            continue
        w, h, fc, ll, x, y = map(int, (w, h, fc, ll, x, y))
        ll = ll or fc
        W, H = Image.open(f).size
        need_w, need_h = x + min(ll, fc) * w, y + -(-fc // ll) * h
        if need_w > W or need_h > H:
            bad.append(f"{name} {key}: {fn} needs {need_w}x{need_h}, image is {W}x{H}")
    return bad


def check_locale(sec):
    """every item, entity and technology with an icon of this mod has a name in locale/en"""
    have, current = {}, None
    for f in (ROOT / "locale" / "en").glob("*.cfg"):
        for line in f.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                current = line[1:-1]
            elif "=" in line and current:
                have.setdefault(current, set()).add(line.split("=", 1)[0])
    return sorted({f"{kind} {name}" for kind, name in sec.get("LOCALE", []) if name not in have.get(kind, set())})


def report(title, items, limit=40):
    print(f"\n{title}: {len(items)}")
    for i in items[:limit]:
        print("  -", i)
    if len(items) > limit:
        print(f"  ... {len(items) - limit} more")


def check(a):
    prepare_mods(gregtorio=a.with_gregtorio, base_only=a.base_only)
    print("mods: " + ("base only" if a.base_only else "base, Space Age, quality")
          + (" + Gregtorio Continued" if a.with_gregtorio else ""))
    log = factorio("--create", str(WORK / "check-map.zip"))
    err = load_errors(log)
    sec = sections(log)
    validate = [" ".join(r) for r in sec.get("VALIDATE", [])]
    print(f"load: {'FAILED' if err else 'ok'}")
    if validate:
        report("references to missing prototypes", validate)
    if err:
        print("\n" + err)
        return 1
    m = Model(sec["DUMP"])
    own = sec.get("OWN", [])
    own_recipes = [n for k, n in own if k == "recipe"]
    own_techs = [n for k, n in own if k == "technology"]
    print(f"\nresearchable technologies of the game: {len(m.researched)} of {sum(1 for v in m.T.values() if v['en'])}")
    techs = [f"{t}: cannot be researched" for t in own_techs if t not in m.researched]
    print(f"technologies of me-network: {len(own_techs) - len(techs)} of {len(own_techs)} researchable")
    report("technologies of me-network that cannot be researched", techs)
    recipes = []
    for r in own_recipes:
        if r not in m.R:
            recipes.append(f"{r}: does not exist")
        elif r not in m.unlocked:
            recipes.append(f"{r}: not unlocked by a researchable technology")
        elif m.why_not(r):
            recipes.append(f"{r}: {m.why_not(r)}")
    print(f"recipes of me-network: {len(own_recipes) - len(recipes)} of {len(own_recipes)} unlocked and craftable")
    report("recipes of me-network not unlocked or not craftable", recipes)
    uncraft = [f"{r}: {why}" for r, why in m.uncraftable()]
    print(f"\nunlocked recipes of the game: {len(m.unlocked)}")
    if a.base_only:
        report("unlocked but uncraftable recipes", uncraft)
    else:
        # the model knows resources, trees, rocks, fish, asteroids and tile fluids, but not every source of Space
        # Age (captive biter spawners, ...): the base game check (--base-only) holds every recipe to it
        report("unlocked recipes of the game the model cannot reach (information; --base-only checks them all)", uncraft)
        uncraft = []
    stuck = sorted(t for t, v in m.T.items() if v["en"] and t not in m.researched)
    report("technologies of the game the model cannot research (information)", stuck)
    files, sprites, locale = check_files(sec), check_sprites(sec), check_locale(sec)
    report("missing graphics files", files)
    report("sprite sheets too small", sprites)
    report("names missing in locale/en", locale)
    ok = not (validate or files or [s for s in sprites if not s.startswith("(")] or techs or recipes or uncraft or locale)
    print("\nRESULT:", "OK" if ok else "PROBLEMS FOUND")
    return 0 if ok else 1


def seed_args(a):
    if a.seed == "random":
        return []
    return ["--map-gen-seed", str(int(a.seed))]


# the runtime tests and their result keys (tools/devcheck/runtimemod/control.lua)
RUNTIME_TESTS = (
    ("MEGRAPH", "ME graph test"), ("MECELLS", "ME cell test"), ("METERMINAL", "ME terminal test"),
    ("MEIO", "ME import/export test"), ("AUTOCRAFT", "autocrafting test"), ("FURNACE", "furnace pattern test"),
    ("PATSWITCH", "pattern recipe switching test"), ("PATLINE", "processing line test"), ("FLUIDS", "fluid test"),
    ("FLUIDCELLS", "ME fluid cell test"), ("MER3", "ME partitions and windows test"),
    ("MESTORAGEBUS", "ME storage bus test"), ("MEFLUIDSTORAGEBUS", "ME fluid storage bus test"),
    ("UNIFIED", "ME unified I/O test"),
    ("MAINTAINER", "level maintainer test"), ("CPUTIERS", "crafting CPU tier test"),
    ("CIRCUIT", "circuit interface test"), ("SETTINGS", "settings copy test"), ("DONE", "all tests reported"),
)


def runtime(a):
    prepare_mods(gregtorio=a.with_gregtorio, with_runtime=True)
    print(f"mods: base, Space Age, quality{' + Gregtorio Continued' if a.with_gregtorio else ''}")
    log = factorio("--create", str(WORK / "runtime-map.zip"), *seed_args(a))
    if load_errors(log):
        print(load_errors(log))
        return 1
    if not_saved(log):
        print(not_saved(log))
        return 1
    setup_line = re.search(r"DEVCHECK-RUNTIME (setup.*)", log)
    fails = re.findall(r"DEVCHECK-RUNTIME-FAIL (.*)", log)
    print("runtime setup:", setup_line.group(1) if setup_line else "no result")
    seed = re.search(r"DEVCHECK-RUNTIME-SEED (.*)", log)
    print("map seed:", seed.group(1) if seed else "unknown")
    log = factorio("--benchmark", str(WORK / "runtime-map.zip"), "--benchmark-ticks", str(a.ticks))
    ran = re.search(r"Performed (\d+) updates", log)
    err = re.search(r"(Error.*|non-recoverable.*)", log)
    fails += re.findall(r"DEVCHECK-RUNTIME-FAIL (.*)", log)
    print(f"benchmark: {ran.group(0) if ran else 'did not run'}")
    for key, label in RUNTIME_TESTS:
        m = re.search(rf"DEVCHECK-RUNTIME-{key} (.*)", log)
        print(f"{label}: {m.group(1) if m else 'did not run'}")
        if not m:
            fails.append(f"{label} did not run (needs --ticks >= 1500)")
        elif not m.group(1).startswith("ok"):
            fails.append(f"{label} failed")
    report("runtime problems", fails)
    if err or not ran or fails:
        print(err.group(1) if err else "")
        print("\nRESULT: PROBLEMS FOUND")
        return 1
    print("\nRESULT: OK")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("setup")
    s.add_argument("--version", default="stable", help="Factorio version, e.g. 2.0.77 (default: stable)")
    s.add_argument("--factorio", help="use an existing unpacked headless Factorio instead of downloading")
    s.add_argument("--with-gregtorio", metavar="DIR", help="also get the dependency mods of this Gregtorio checkout")
    s.add_argument("--mods-from", help="folder with the dependency mod zips instead of downloading them")
    for name in ("check", "runtime", "all"):
        p = sub.add_parser(name)
        p.add_argument("--with-gregtorio", metavar="DIR", help="a Gregtorio Continued checkout to load as well")
        if name in ("check", "all"):
            p.add_argument("--base-only", action="store_true", help="check without Space Age and quality")
        if name in ("runtime", "all"):
            p.add_argument("--ticks", type=int, default=1500)
            p.add_argument("--seed", default=str(DEFAULT_SEED), help=f"map seed or `random` (default {DEFAULT_SEED})")
    a = ap.parse_args()
    if a.cmd == "setup":
        return setup(a)
    if a.cmd == "check":
        return check(a)
    if a.cmd == "runtime":
        return runtime(a)
    return check(a) or runtime(a)


if __name__ == "__main__":
    sys.exit(main())
