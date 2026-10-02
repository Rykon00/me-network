#!/usr/bin/env python3
"""Headless test harness for ME Network (me-network).

    python tools/devcheck/devcheck.py setup                 # link or download headless Factorio
    python tools/devcheck/devcheck.py check                 # load the mod and run the static checks (vanilla)
    python tools/devcheck/devcheck.py runtime               # the ME runtime tests on a new map (vanilla)
    python tools/devcheck/devcheck.py all                   # check + runtime
    python tools/devcheck/devcheck.py all --with-gregtorio ../Gregtorio
                                                            # the same with Gregtorio Continued loaded
    python tools/devcheck/devcheck.py migrate --from-ref v0.1.0
                                                            # a save of an older version loaded with the working copy
    python tools/devcheck/devcheck.py bench                 # script time, throughput and latencies of synthetic
                                                            # bases of 100, 1000 and 5000 endpoints (docs/PERFORMANCE.md)
    python tools/devcheck/devcheck.py bench --reference --profile 1000,5000
                                                            # the same with inserters and robots, and a profile

Everything is kept in .devcheck/ in the repository root (git-ignored). The working copy is linked into the test
mod folder, so every run tests the current files.

`check` fails (exit code 1) when the mods do not load, a recipe or technology references a missing prototype, a
referenced __me-network__/ file is missing, a sprite sheet is too small, a name is missing in locale/en, a
technology of this mod cannot be researched, a recipe of this mod is not unlocked by a researchable technology or
cannot be crafted, or an unlocked recipe of the game cannot be crafted. `runtime` fails when a runtime test fails
or does not finish. `migrate` fails when the old save cannot be made or loaded, or its check reports a problem.
"""
import argparse, io, json, os, re, shutil, subprocess, sys, tarfile, urllib.parse, urllib.request
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


def prepare_mods(gregtorio=None, with_runtime=False, base_only=False, mod_dir=None, with_migrate=False, bench_dir=None):
    """mods/ = this mod (working copy, or `mod_dir`: an older version or the instrumented copy of `bench --profile`)
    + the devcheck helper mods (`bench_dir`: the benchmark mod with its config, instead of the check mod); with
    Gregtorio its checkout and its dependency zips. base_only: without Space Age and quality."""
    MODS.mkdir(parents=True, exist_ok=True)
    for p in MODS.iterdir():
        if p.name in (NAME, GREGTORIO, "mod-list.json") or p.name.startswith(HELPERS):
            remove_path(p)
    link_dir(MODS / NAME, Path(mod_dir) if mod_dir else ROOT)
    if bench_dir:
        link_dir(MODS / "zz-me-network-devcheck-bench", bench_dir)
        enabled = ["base", NAME, "zz-me-network-devcheck-bench"]
    else:
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
    if with_migrate:
        link_dir(MODS / "zz-me-network-devcheck-migrate", HERE / "migratemod")
        enabled.append("zz-me-network-devcheck-migrate")
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
    ("CIRCUIT", "circuit interface test"), ("SETTINGS", "settings copy test"), ("SCHEDULER", "ME scheduler test"),
    ("CURSOR", "open key and cursor test"), ("RECIPEPASTE", "recipe paste test"),
    ("CARDS", "ME upgrade card test"), ("PRIORITIES", "ME priority test"), ("WORKBENCH", "ME Cell Workbench test"),
    ("DONE", "all tests reported"),
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


# --------------------------------------------------------------------------------------------
# migrate: a save of an older version, loaded with the working copy (issue #3: the old fluid blocks)
# --------------------------------------------------------------------------------------------

def old_tree(ref):
    """the mod as it was at `ref` (git archive), unpacked into .devcheck/old-<ref> (plain files, no links)"""
    dest = WORK / ("old-" + re.sub(r"[^A-Za-z0-9._-]", "_", ref))
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    tar = subprocess.run(["git", "-C", str(ROOT), "archive", "--format=tar", ref], capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(tar)) as t:
        t.extractall(dest)
    return dest


def migrate(a):
    old = old_tree(a.from_ref)
    prepare_mods(mod_dir=old, with_migrate=True)
    print(f"old version: {a.from_ref}")
    log = factorio("--create", str(WORK / "migrate-map.zip"), *seed_args(a))
    if load_errors(log):
        print("could not create the map with the old version:\n" + load_errors(log))
        return 1
    if not_saved(log):
        print(not_saved(log))
        return 1
    setup = re.search(r"DEVCHECK-MIGRATE-SETUP (.*)", log)
    print(f"old save (0.1.0: every old fluid block; 0.2.0 and later: every kind of block): {setup.group(1) if setup else 'no result'}")
    prepare_mods(with_migrate=True)
    log = factorio("--benchmark", str(WORK / "migrate-map.zip"), "--benchmark-ticks", str(a.ticks))
    ran = re.search(r"Performed (\d+) updates", log)
    print(f"old save loaded with the working copy: {'ok, ' + ran.group(0) if ran else 'FAILED'}")
    for line in re.findall(r"FORK-ME-MIGRATE: (.*)", log):
        print("  migration: " + line)
    unified = re.search(r"DEVCHECK-MIGRATE-UNIFIED (.*)", log)
    fluids = re.search(r"DEVCHECK-MIGRATE-FLUIDS (.*)", log)
    print(f"the blocks after the update: {unified.group(1) if unified else 'no result'}")
    print(f"the fluid after the I/O steps: {fluids.group(1) if fluids else 'no result'}")
    fails = re.findall(r"DEVCHECK-MIGRATE-FAIL (.*)", log)
    for f in fails:
        print("  - " + f)
    if not ran:
        print(load_errors(log) or "")
    ok = ran and setup and setup.group(1).startswith("ok") and unified and unified.group(1).startswith("ok") \
        and fluids and fluids.group(1).startswith("ok") and not fails
    print("\nRESULT: " + ("OK" if ok else "PROBLEMS FOUND"))
    return 0 if ok else 1


# --------------------------------------------------------------------------------------------
# bench: synthetic bases (benchmod/), timed with --benchmark-verbose (issue #5, docs/PERFORMANCE.md)
# --------------------------------------------------------------------------------------------

BENCH_WARMUP = 600
LATENCY_TICKS = 3700            # after the window: the latency probes (time out after 3600 ticks)
# the functions the profile times, per module of the instrumented copy (local functions through their upvalue,
# M.<name> through the module table, and the handler tables of the storage bus)
PROFILE_WRAP = {
    "scripts/fork-me-network.lua": ["M.insert", "M.extract", "M.can_insert", "M.insert_partial", "M.insert_stack",
                                    "M.extract_to", "M.insert_fluid", "M.extract_fluid", "M.can_insert_fluid",
                                    "M.ext_sync", "M.contents", "M.plain_counts", "M.fluid_contents", "M.storable",
                                    "M.slow_step", "M.stats", "insert_key", "extract_key", "room_for", "ordered",
                                    "recompute", "draw_leds", "add_node", "remove_node_graph", "update_power",
                                    "lookups", "holders", "extract_order", "moved_key"],
    "scripts/fork-me-io.lua": ["M.interface_step", "M.bus_step", "M.fluid_bus_step", "import_items", "export_items",
                               "interface_sides", "tank_to_network", "export_side", "target_of", "ensure_tanks",
                               "M.on_tick", "visit"],
    "scripts/fork-me-storagebus.lua": ["M.visit", "M.on_step", "M.on_tick", "resolve", "ITEM.room", "ITEM.insert",
                                       "ITEM.count", "ITEM.extract"],
    "scripts/fork-me-fluid-storagebus.lua": ["M.visit", "M.on_step", "M.on_tick", "claim", "contents_of", "M.handlers.room",
                                             "M.handlers.insert", "M.handlers.count", "M.handlers.extract"],
    "scripts/fork-me-autocraft.lua": ["job_step", "maintenance", "scan_provider", "refresh_providers",
                                      "rebuild_patterns", "make_plan", "M.start", "assign_cpus", "await_index",
                                      "on_arrival", "awaiting", "cpus_in", "collect_output", "find_crafter",
                                      "start_lease", "close_lease", "flush_pool", "M.active_job_for", "M.free_slot",
                                      "M.job", "prune_finished", "job_network", "stock_of", "machine_idle", "M.on_tick",
                                      "step_jobs", "rescan_plan"],
    "scripts/fork-me-circuit.lua": ["on_step", "on_tick", "maintainer_step", "circuit_step", "network_signals",
                                    "signals_of", "visit_maintainer", "visit_circuit"],
    "scripts/fork-me-gui.lua": ["M.refresh_all"],
}
# values captured at load time that must point at the wrapped function
PROFILE_REPOINT = {
    "scripts/fork-me-autocraft.lua": "N.on_arrival = on_arrival\nN.awaiting = awaiting\n",
}


def _tree_read(d):
    """Factorio's property tree (mod-settings.dat): -> (version tuple, dict); integers as ("int", type, value)"""
    import struct
    pos = 9

    def take(fmt):
        nonlocal pos
        v = struct.unpack_from(fmt, d, pos)[0]
        pos += struct.calcsize(fmt)
        return v

    def string():
        nonlocal pos
        if take("<B"):
            return ""
        n = take("<B")
        if n == 255:
            n = take("<I")
        v = d[pos:pos + n].decode("utf-8")
        pos += n
        return v

    def tree():
        t = take("<B")
        take("<B")
        if t == 0:
            return None
        if t == 1:
            return bool(take("<B"))
        if t == 2:
            return take("<d")
        if t == 3:
            return string()
        if t in (4, 5):
            return {string(): tree() for _ in range(take("<I"))}
        if t in (6, 7):
            return ("int", t, take("<q" if t == 6 else "<Q"))
        raise ValueError(f"mod-settings.dat: unknown type {t}")
    return struct.unpack_from("<4H", d, 0), tree()


def _tree_write(version, root):
    import struct
    out = bytearray(struct.pack("<4H", *version) + bytes([0]))

    def string(v):
        b = v.encode("utf-8")
        out.extend(bytes([0]) + (bytes([len(b)]) if len(b) < 255 else bytes([255]) + struct.pack("<I", len(b))) + b)

    def tree(v):
        if v is None:
            out.extend(bytes([0, 0]))
        elif isinstance(v, bool):
            out.extend(bytes([1, 0, 1 if v else 0]))
        elif isinstance(v, tuple):
            out.extend(bytes([v[1], 0]) + struct.pack("<q" if v[1] == 6 else "<Q", v[2]))
        elif isinstance(v, (int, float)):
            out.extend(bytes([2, 0]) + struct.pack("<d", float(v)))
        elif isinstance(v, str):
            out.extend(bytes([3, 0]))
            string(v)
        else:
            out.extend(bytes([5, 0]) + struct.pack("<I", len(v)))
            for k, x in v.items():
                string(k)
                tree(x)
    tree(root)
    return bytes(out)


def runtime_settings(values):
    """mod-settings.dat with exactly these runtime-global settings of this mod (the others at their defaults): a new
    map takes them (bench --set); called with {} after the benchmark, so the other commands see the defaults"""
    f = MODS / "mod-settings.dat"
    version, root = _tree_read(f.read_bytes()) if f.exists() else ((2, 0, 0, 0), {})
    root = root or {}
    glob = {k: v for k, v in (root.get("runtime-global") or {}).items() if not k.startswith(NAME + "-")}
    for k, v in values.items():
        glob[k] = {"value": ("int", 6, int(v))}
    root.setdefault("startup", {})
    root["runtime-global"] = glob
    root.setdefault("runtime-per-user", {})
    f.write_bytes(_tree_write(version, root))


def bench_mod_dir(cfg):
    """the benchmark mod (benchmod/) with its config.lua, as plain files in .devcheck/bench-mod"""
    dest = WORK / "bench-mod"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(HERE / "benchmod", dest, ignore=shutil.ignore_patterns("profile*.lua"))
    def lua(v):
        if isinstance(v, dict):
            return "{ " + ", ".join(f'["{k}"] = {lua(x)}' for k, x in v.items()) + " }"
        return json.dumps(v) if isinstance(v, str) else str(v).lower()
    lines = ["return {"] + [f"  {k} = {lua(v)}," for k, v in cfg.items()] + ["}"]
    (dest / "config.lua").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return dest


def instrumented_copy(src=None):
    """a copy of the working tree (or of `src`, an older version) in .devcheck/bench-profile whose functions are timed
    (benchmod/profile.lua)"""
    dest = WORK / "bench-profile"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src or ROOT, dest, ignore=shutil.ignore_patterns(".git", ".devcheck", "dist", "tools", "docs", "*.zip"))
    for rel, names in PROFILE_WRAP.items():
        f = dest / rel
        src = f.read_text(encoding="utf-8")
        mod = Path(rel).stem.replace("fork-me-", "")
        lines = []
        for name in names:
            last = re.escape(name.split(".")[-1])
            if "." in name:                                   # M.f, or a field of a handler table
                found = re.search(r"^function " + re.escape(name) + r"\(|^\s*" + last + r" = function\(", src, re.M)
            else:                                             # a local function (or a forward declared local)
                found = re.search(r"^local function " + last + r"\(|^local " + last + r"$", src, re.M)
            if not found:                                     # (the list covers versions before and after issue #5)
                print(f"  profile: {name} is not in {rel}, not timed")
                continue
            lines.append(f'{name} = __BENCH_WRAP("{mod}.{name}", {name})')
        block = "\n".join(lines) + "\n" + PROFILE_REPOINT.get(rel, "")
        i = src.rstrip().rfind("\nreturn M")
        if i < 0:
            sys.exit(f"profile: no `return M` at the end of {rel}")
        src = src[:i + 1] + block + src[i + 1:]
        # captured at load time: the circuit step hook, every on_nth_tick handler
        for hook in ("on_step", "on_tick"):
            src = src.replace(f"autocraft.step_hooks[#autocraft.step_hooks + 1] = {hook}",
                              f"autocraft.step_hooks[#autocraft.step_hooks + 1] = function(...) return {hook}(...) end")
        f.write_text(src, encoding="utf-8")
    for f in (dest / "scripts").glob("*.lua"):
        src = f.read_text(encoding="utf-8")
        f.write_text(src.replace("script.on_nth_tick(", "__BENCH_NTH("), encoding="utf-8")
    ctl = dest / "control.lua"
    ctl.write_text((HERE / "benchmod" / "profile.lua").read_text(encoding="utf-8") + "\n" + ctl.read_text(encoding="utf-8")
                   + (HERE / "benchmod" / "profile-remote.lua").read_text(encoding="utf-8"), encoding="utf-8")
    return dest


def bench_json(log, key):
    return [json.loads(m) for m in re.findall(rf"DEVCHECK-BENCH-{key} (\{{.*\}})", log)]


def timings(log, first, last):
    """per tick columns of --benchmark-verbose all (ns) for the rows t<first> .. t<last>"""
    head = re.search(r"^tick,timestamp,(.*)$", log, re.M)
    if not head:
        return None
    cols = head.group(1).rstrip(",").split(",")
    want = {c: cols.index(c) for c in ("wholeUpdate", "gameUpdate", "entityUpdate", "logisticManagerUpdate",
                                       "luaGarbageIncremental", "scriptUpdate") if c in cols}
    rows = {c: [] for c in want}
    for m in re.finditer(r"^t(\d+),\d+,(.*)$", log, re.M):
        t = int(m.group(1))
        if first <= t <= last:
            vals = m.group(2).rstrip(",").split(",")
            for c, i in want.items():
                rows[c].append(int(vals[i]) / 1e6)
    return rows


def stat(values):
    if not values:
        return {}
    s = sorted(values)
    return {"avg": sum(s) / len(s), "max": s[-1], "p99": s[min(len(s) - 1, int(len(s) * 0.99))],
            "over5": sum(1 for v in s if v > 5.0)}


def median(values):
    v = sorted(x for x in values if x is not None)
    return v[len(v) // 2] if v else None


def bench_scene(a, scene, size, profile=False):
    """create the map of one scene and run it (a.runs times, once with --profile); returns the parsed results"""
    window = a.ticks
    cfg = {"scene": scene, "size": size, "warmup": BENCH_WARMUP, "window": window,
           "latency": scene == "me" and not profile, "profile": profile}
    old = a.old_dir                                       # bench --from-ref: an older version of the mod
    mod_dir = instrumented_copy(old) if profile else old
    prepare_mods(mod_dir=mod_dir, bench_dir=bench_mod_dir(cfg))
    runtime_settings({k: int(v) for k, v in (x.split("=", 1) for x in a.set or [])})
    mapfile = WORK / f"bench-{scene}-{size}{'-profile' if profile else ''}.zip"
    log = factorio("--create", str(mapfile), *seed_args(a))
    err = load_errors(log) or not_saved(log)
    setup = bench_json(log, "SETUP")
    build = re.search(r"DEVCHECK-BENCH-BUILD (.*)", log)
    if err or not setup:
        print(f"  {scene} {size}: the map was not created\n{err or ''}")
        return None
    machine = re.search(r"System info: \[(.*?)\]", log)
    out = {"scene": scene, "size": size, "setup": setup[0], "build": build.group(1) if build else None,
           "save_bytes": mapfile.stat().st_size, "runs": [], "machine": machine.group(1) if machine else None,
           "window": window}
    ticks = BENCH_WARMUP + window + (LATENCY_TICKS if cfg["latency"] else 30)
    for r in range(1 if profile else a.runs):
        log = factorio("--benchmark", str(mapfile), "--benchmark-ticks", str(ticks), "--benchmark-verbose", "all")
        if not re.search(r"Performed (\d+) updates", log):
            print(f"  {scene} {size} run {r + 1}: did not run\n{load_errors(log) or ''}")
            (WORK / f"bench-failed-{scene}-{size}.log").write_text(log, encoding="utf-8")
            return out
        tm = timings(log, BENCH_WARMUP + 2, BENCH_WARMUP + window - 3)
        run = {"timing": {c: stat(v) for c, v in (tm or {}).items()},
               "throughput": (bench_json(log, "THROUGHPUT") or [None])[0],
               "latency": (bench_json(log, "LATENCY") or [None])[0],
               "jobs": (bench_json(log, "JOBS") or [None])[0],
               "done": "DEVCHECK-BENCH-DONE" in log,
               "errors": re.findall(r"(Error.*|non-recoverable.*)", log)[:3]}
        if profile:
            run["profile"] = [(m.group(1), int(m.group(2)), float(m.group(3)))
                              for m in re.finditer(r"DEVCHECK-BENCH-PROF (\S+) (\d+) Duration: ([\d.]+)ms", log)]
            ov = re.search(r"DEVCHECK-BENCH-PROF-OVERHEAD wrapped Duration: ([\d.]+)ms plain Duration: ([\d.]+)ms", log)
            run["overhead_us"] = (float(ov.group(1)) - float(ov.group(2))) * 1000 if ov else None
            run["engine"] = [(m.group(1), int(m.group(2)), float(m.group(3)))
                             for m in re.finditer(r"DEVCHECK-BENCH-ENGINE (.+?) (\d+) Duration: ([\d.]+)ms", log)]
        out["runs"].append(run)
        sc = run["timing"].get("scriptUpdate", {})
        print(f"  {scene} {size} run {r + 1}{' (profile)' if profile else ''}: script "
              f"{sc.get('avg', 0):.3f} ms/tick avg, {sc.get('max', 0):.2f} max")
    return out


def summarize(res):
    """the median over the runs of a scene"""
    runs = [r for r in res["runs"] if r["timing"]]
    def med(col, key):
        return median([r["timing"].get(col, {}).get(key) for r in runs])
    s = {"scene": res["scene"], "size": res["size"], "runs": len(runs), "save_mb": res["save_bytes"] / 1e6,
         "script_avg": med("scriptUpdate", "avg"), "script_max": med("scriptUpdate", "max"),
         "script_p99": med("scriptUpdate", "p99"), "script_over5": med("scriptUpdate", "over5"),
         "gc_avg": med("luaGarbageIncremental", "avg"), "whole_avg": med("wholeUpdate", "avg"),
         "entity_avg": med("entityUpdate", "avg"), "logistic_avg": med("logisticManagerUpdate", "avg")}
    tp = [r["throughput"] for r in runs if r["throughput"]]
    s["throughput"] = tp[0] if tp else None
    lat = [r["latency"] for r in runs if r["latency"]]
    if lat:
        s["latency"] = {k: {"median_s": median([l[k]["median_s"] for l in lat]), "max_s": median([l[k]["max_s"] for l in lat]),
                            "n": lat[0][k]["n"], "timeouts": max(l[k]["timeouts"] for l in lat)} for k in lat[0]}
    return s


def bench(a):
    sizes = [int(x) for x in a.sizes.split(",") if x]
    scenes = ["me"] + (["inserters", "robots"] if a.reference else [])
    results = {"factorio": (factorio("--version").splitlines() or ["?"])[0], "scenes": [], "profiles": [],
               "window": a.ticks, "ref": a.from_ref or "working copy"}
    a.old_dir = old_tree(a.from_ref) if a.from_ref else None
    print("mod:", results["ref"])
    print(results["factorio"])
    problems = []
    for scene in scenes:
        for size in sizes:
            res = bench_scene(a, scene, size)
            if not res:
                problems.append(f"{scene} {size}: no map")
                continue
            s = summarize(res)
            s["setup"] = res["setup"]
            s["build"] = res["build"]
            results["machine"] = res["machine"]
            results["scenes"].append(s)
            for r in res["runs"]:
                if not r["done"]:
                    problems.append(f"{scene} {size}: a run did not finish")
                if r["errors"]:
                    problems.append(f"{scene} {size}: {r['errors'][0]}")
                if r.get("jobs") and r["jobs"]["failed"]:
                    problems.append(f"{scene} {size}: jobs not started: {r['jobs']['failed'][:3]}")
            if res["setup"].get("fails"):
                problems.append(f"{scene} {size}: setup problems: {res['setup']['fails'][:3]}")
            tp = s["throughput"]
            if tp and tp["conservation"]["problems"]:
                problems.append(f"{scene} {size}: conservation: {tp['conservation']['problems']} keys differ, "
                                f"{tp['conservation']['first'][:2]}")
    for size in [int(x) for x in (a.profile or "").split(",") if x]:
        res = bench_scene(a, "me", size, profile=True)
        if res and res["runs"]:
            results["profiles"].append({"size": size, **res["runs"][0]})
    runtime_settings({})
    results["settings"] = a.set or []
    print_bench(results)
    out = WORK / ("bench-results" + ("-" + re.sub(r"[^A-Za-z0-9._-]", "_", a.from_ref) if a.from_ref else "") + ".json")
    out.write_text(json.dumps(results, indent=1), encoding="utf-8")
    print(f"\nresults: {out}")
    report("benchmark problems", problems)
    print("\nRESULT:", "OK" if not problems else "PROBLEMS FOUND")
    return 0 if not problems else 1


def fmt(v, digits=3):
    return "-" if v is None else f"{v:.{digits}f}"


def print_bench(results):
    print(f"\nmachine: {results.get('machine')}")
    print("script time per tick (ms, median of the runs; window without the probe ticks):")
    print(f"  {'scene':10} {'size':>5} {'avg':>7} {'p99':>7} {'max':>7} {'>5ms':>5} {'gc avg':>7} {'whole avg':>9} "
          f"{'entity':>7} {'logist.':>7} {'save MB':>7}")
    for s in results["scenes"]:
        print(f"  {s['scene']:10} {s['size']:>5} {fmt(s['script_avg']):>7} {fmt(s['script_p99']):>7} "
              f"{fmt(s['script_max'], 2):>7} {fmt(s['script_over5'], 0):>5} {fmt(s['gc_avg']):>7} {fmt(s['whole_avg']):>9} "
              f"{fmt(s['entity_avg']):>7} {fmt(s['logistic_avg']):>7} {fmt(s['save_mb'], 1):>7}")
    print("\nthroughput (per second over the window):")
    for s in results["scenes"]:
        tp = s["throughput"]
        if not tp:
            continue
        print(f"  {s['scene']} {s['size']}: items {fmt(tp['items_per_s'], 0)}/s, {fmt(tp['items_per_s_per_endpoint'], 2)}/s "
              f"per endpoint ({tp['endpoints']} endpoints)"
              + (f", fluid {fmt(tp.get('fluid_per_s'), 0)}/s, provider crafts {fmt(tp.get('provider_crafts_per_s'), 1)}/s, "
                 f"dry sources {tp.get('dry_sources')}" if s["scene"] == "me" else "")
              + f"; conservation: {tp['conservation']['keys']} keys, {tp['conservation']['problems']} problems")
        for kind, c in sorted(tp["categories"].items()):
            vals = ", ".join(f"{k.replace('_per_s_per_endpoint', '/s/endpoint').replace('_per_s', '/s')} {fmt(v, 2)}"
                             for k, v in sorted(c.items()) if k != "endpoints")
            print(f"      {kind:12} {c['endpoints']:>5} endpoints: {vals}")
    print("\nlatencies (s, median and max over the probes):")
    for s in results["scenes"]:
        for k, v in (s.get("latency") or {}).items():
            print(f"  {s['scene']} {s['size']} {k:12}: median {fmt(v['median_s'], 2)}, max {fmt(v['max_s'], 2)} "
                  f"({v['n']} probes, {v['timeouts']} timed out)")
    for p in results["profiles"]:
        print(f"\nprofile, size {p['size']} (inclusive ms per tick of the window, calls per tick, us per call; "
              f"wrapper overhead {fmt(p.get('overhead_us'), 2)} us per call):")
        n_ticks = results["window"]
        for name, calls, ms in sorted(p.get("profile", []), key=lambda x: -x[2]):
            print(f"  {name:42} {ms / n_ticks:8.4f} ms/tick {calls / n_ticks:9.2f} calls/tick {ms * 1000 / max(1, calls):9.2f} us/call")
        print("  engine calls (us per call):")
        for name, n, ms in p.get("engine", []):
            print(f"    {name:52} {ms * 1000:10.2f}")


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
    p = sub.add_parser("migrate")
    p.add_argument("--from-ref", default="v0.1.0", help="the git tag or commit of the old version (default v0.1.0)")
    p.add_argument("--ticks", type=int, default=300)
    p.add_argument("--seed", default=str(DEFAULT_SEED), help=f"map seed or `random` (default {DEFAULT_SEED})")
    p = sub.add_parser("bench")
    p.add_argument("--sizes", default="100,1000,5000", help="buses and interfaces of the ME scenes (default 100,1000,5000)")
    p.add_argument("--runs", type=int, default=3, help="benchmark runs per scene, the median is reported (default 3)")
    p.add_argument("--ticks", type=int, default=3600, help="the measured window in ticks, a multiple of 600 (default 3600)")
    p.add_argument("--reference", action="store_true", help="also the native scenes: inserters and logistic robots")
    p.add_argument("--profile", metavar="SIZES", help="also profile these sizes with an instrumented copy (e.g. 1000,5000)")
    p.add_argument("--seed", default=str(DEFAULT_SEED), help=f"map seed or `random` (default {DEFAULT_SEED})")
    p.add_argument("--from-ref", help="benchmark this git tag or commit instead of the working copy (the scenes and the "
                   "harness stay the working copy's)")
    p.add_argument("--set", action="append", metavar="NAME=VALUE",
                   help="a runtime setting of me-network for the run, e.g. me-network-io-visits-per-tick=24 (repeatable)")
    a = ap.parse_args()
    if a.cmd == "bench":
        if a.ticks % BENCH_WARMUP:
            sys.exit(f"--ticks must be a multiple of {BENCH_WARMUP}")
        return bench(a)
    if a.cmd == "migrate":
        return migrate(a)
    if a.cmd == "setup":
        return setup(a)
    if a.cmd == "check":
        return check(a)
    if a.cmd == "runtime":
        return runtime(a)
    return check(a) or runtime(a)


if __name__ == "__main__":
    sys.exit(main())
