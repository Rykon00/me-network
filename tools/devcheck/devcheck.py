#!/usr/bin/env python3
"""Headless test harness for ME Network (me-network).

    python tools/devcheck/devcheck.py setup                 # link or download headless Factorio
    python tools/devcheck/devcheck.py check                 # load the mod and run the static checks (vanilla)
    python tools/devcheck/devcheck.py runtime               # the ME runtime tests on a new map (vanilla)
    python tools/devcheck/devcheck.py all                   # check + runtime
    python tools/devcheck/devcheck.py all --with-gregtorio ../Gregtorio
                                                            # the same with Gregtorio Continued loaded
    python tools/devcheck/devcheck.py all --with-mod Krastorio2 [--mods-from DIR]
                                                            # issue #591: with a third-party mod and its required
                                                            # dependencies (check --base-only: without Space Age)
    python tools/devcheck/devcheck.py migrate --from-ref v0.5.0
                                                            # a save of an older version loaded with the working copy
    python tools/devcheck/devcheck.py bench                 # script time, throughput and latencies of synthetic
                                                            # bases of 100, 1000 and 5000 endpoints (docs/PERFORMANCE.md)
    python tools/devcheck/devcheck.py bench --reference --profile 1000,5000
                                                            # the same with inserters and robots, and a profile
    python tools/devcheck/devcheck.py bench --sizes 5000 --idle --networks 10,100 --engine-share
                                                            # issue #38: an idle network, several networks, the
                                                            # engine's share of the ME entities
    python tools/devcheck/devcheck.py bench --long 30 --sizes 5000
                                                            # a run of 30 minutes, reported per 5 minutes
    python tools/devcheck/devcheck.py bench --planner [--with-gregtorio ../Gregtorio]
                                                            # the planner on every recipe of the game as deep trees
    python tools/devcheck/devcheck.py bench --check origin/main --sizes 1000,5000
                                                            # the working copy against a reference, in turns; fails
                                                            # when a number is worse by more than the measured noise

Everything is kept in .devcheck/ in the repository root (git-ignored). The working copy is linked into the test
mod folder, so every run tests the current files.

`check` fails (exit code 1) when the texture mod ae2-textures/ (me-network-ae2-textures, the CC BY-NC-SA 3.0 graphics of
Applied Energistics 2, issues #235 and #239) breaks its manifest or an AE2 file's bytes lie outside it
(tools/ae2_manifest.py; with Gregtorio in its checkout too), when one of the two zips of tools/build.py breaks the
license split, when the second load with the texture mod (a throw-away copy with two stand-in overrides) fails or does
not replace the stand-ins' sprites. me-network requires the texture mod (issue #325): every other load has an empty
stand-in of it in the mods folder (its info.json only), so those runs see me-network's own graphics;
when a file under graphics/ or thumbnail.png has the bytes of an icon taken over from Gregtorio 0.1.9 (issue #238,
tools/upstream_icons.py, tools/upstream-icon-hashes.tsv; with Gregtorio in its checkout too), when the mods do not load, a recipe or technology references a missing prototype, a
referenced __me-network__/ file is missing, a sprite sheet is too small, a name is missing in locale/en, a
technology of this mod cannot be researched, a recipe of this mod is not unlocked by a researchable technology or
cannot be crafted, or an unlocked recipe of the game cannot be crafted. `runtime` fails when a runtime test fails
or does not finish. `migrate` fails when the old save cannot be made or loaded, or its check reports a problem.
"""
import argparse, io, json, os, re, shutil, subprocess, sys, tarfile, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
# a second work folder (ME_DEVCHECK_WORK=path): two harness runs side by side from one checkout, each with its own
# Factorio copy (`setup` there), e.g. a long benchmark and a quick test
WORK = Path(os.environ["ME_DEVCHECK_WORK"]).resolve() if os.environ.get("ME_DEVCHECK_WORK") else ROOT / ".devcheck"
FACTORIO = WORK / "factorio"
MODS = WORK / "mods"
LOG = WORK / "last-run.log"
# `runtime` creates its map with this seed, so a run is reproducible; `--seed N` or `--seed random` picks another
DEFAULT_SEED = 3115102263
# issue #146: saves of older versions are refused (control.lua); `migrate --from-ref` an older one checks that
CUT_OFF = (0, 5, 0)
# (issue #487: Factorio 2.1 adds the built-in mod recycler, which space-age and quality depend on)
BUILTIN = {"base", "core", "space-age", "quality", "elevated-rails", "recycler"}
# the Factorio version the mods are written for (info.json factorio_version; the dependency mods are picked by it)
FACTORIO_VERSION = "2.1"
# issue #487: removed prototype keys of other mods (a leftover of a dependency of Gregtorio that neither mod can change:
# Factorio ignores it), by the prototype's "<type>/<name>" -> the reason; reported as information, never a failure
REMOVED_KEYS_OTHER_MODS = {
    "pump/configurable-valve": "configurable-valves 2.0.2 (for Factorio 2.1) still sets hide_connection_info on its fluid box",
    "storage-tank/configurable-valve-guage-input": "configurable-valves 2.0.2, as above",
    "storage-tank/configurable-valve-guage-output": "configurable-valves 2.0.2, as above",
    # issue #591: Krastorio 2 2.1.4 (devcheck --with-mod Krastorio2)
    "car/tank": "Krastorio 2 2.1.4 sets braking_power on the vanilla tank",
    "mining-drill/kr-electric-mining-drill-mk2": "Krastorio 2 2.1.4 still sets the circuit connector layers of 2.0",
    "mining-drill/kr-electric-mining-drill-mk3": "Krastorio 2 2.1.4, as above",
}
NAME = "me-network"
TEXTURES = "me-network-ae2-textures"     # the texture mod in ae2-textures/ (issue #239), required since issue #325
STAND_IN = "stand-in of the texture mod (devcheck, issue #325)"     # the title of its empty stand-in (texture_stand_in)
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


def dependency_names(info):
    """the required dependencies of an info.json (a dict): plain, `~` (no load order) and `+` ones; optional (`?`),
    hidden optional (`(?)`) and incompatible (`!`) ones are not pulled, nor the built-in mods, this mod and its
    texture mod (the stand-in of texture_stand_in)"""
    out = []
    for dep in info.get("dependencies", []):
        dep = dep.strip()
        if dep[:1] in "?!(":
            continue
        name = re.split(r"\s*[<>=]", dep.lstrip("~+ "))[0].strip()
        if name not in BUILTIN and name not in (NAME, TEXTURES):
            out.append(name)
    return out


def required_mods(info_path):
    return dependency_names(json.loads(Path(info_path).read_text(encoding="utf-8")))


def zip_info(path):
    """the info.json of a mod zip (it lies in the zip's one top folder)"""
    import zipfile
    with zipfile.ZipFile(path) as z:
        name = next(n for n in z.namelist() if n.count("/") == 1 and n.endswith("/info.json"))
        return json.loads(z.read(name).decode("utf-8"))


def mod_zip(name):
    """the newest zip of a mod in mods/ (Factorio loads the newest of several), None if there is none"""
    found = sorted(MODS.glob(f"{name}_*.zip"), key=lambda z: [int(x) for x in re.findall(r"\d+", z.stem.rsplit("_", 1)[1])])
    return found[-1] if found else None


def fetch_mod(name, mods_from=None):
    """a mod zip into mods/: from the folder `mods_from`, else its newest release for FACTORIO_VERSION from the mod
    portal (FACTORIO_USERNAME/FACTORIO_TOKEN)"""
    if mods_from:
        found = sorted(Path(mods_from).glob(f"{name}_*.zip"))
        if not found:
            sys.exit(f"{name}_*.zip not found in {mods_from}")
        shutil.copy2(found[-1], MODS / found[-1].name)
        print(f"copied {found[-1].name}")
        return
    user, token = os.environ.get("FACTORIO_USERNAME"), os.environ.get("FACTORIO_TOKEN")
    if not user or not token:
        sys.exit(f"need {name}: set FACTORIO_USERNAME/FACTORIO_TOKEN or pass --mods-from DIR")
    meta = json.load(urlopen(f"https://mods.factorio.com/api/mods/{urllib.parse.quote(name)}"))
    rels = [r for r in meta["releases"] if r["info_json"].get("factorio_version") == FACTORIO_VERSION]
    if not rels:
        sys.exit(f"{name} has no release for Factorio {FACTORIO_VERSION} on the mod portal")
    rel = rels[-1]
    q = urllib.parse.urlencode({"username": user, "token": token})
    download(f"https://mods.factorio.com{rel['download_url']}?{q}", MODS / rel["file_name"])


def fetch_mods(names, mods_from=None):
    """issue #591: the mods `names` and their required dependencies (dependency_names, recursively) into mods/, each
    one that is not there yet through fetch_mod. Returns every name of that closure."""
    MODS.mkdir(parents=True, exist_ok=True)
    todo, seen = list(names), []
    while todo:
        name = todo.pop(0)
        if name in seen:
            continue
        seen.append(name)
        if not mod_zip(name):
            fetch_mod(name, mods_from)
        todo += dependency_names(zip_info(mod_zip(name)))
    return seen


def mod_closure(names):
    """the mods `names` and their required dependencies (recursively) among the zips in mods/; fails on a missing one"""
    todo, seen = list(names), []
    while todo:
        name = todo.pop(0)
        if name in seen:
            continue
        z = mod_zip(name)
        if not z:
            sys.exit(f"{name}_*.zip is not in {MODS}: run `devcheck.py setup` with --with-gregtorio DIR or --with-mod NAME "
                     "(and --mods-from DIR for local zips)")
        seen.append(name)
        todo += dependency_names(zip_info(z))
    return seen


def steam_factorio():
    """the Steam install of Factorio on Windows: the Steam path from the registry, its library folders, the game"""
    if os.name != "nt":
        return None
    steams = []
    try:
        import winreg
        for hive, key, value in ((winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
                                 (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath")):
            try:
                with winreg.OpenKey(hive, key) as k:
                    steams.append(Path(winreg.QueryValueEx(k, value)[0]))
            except OSError:
                pass
    except ImportError:
        pass
    steams += [Path(r"C:\Program Files (x86)\Steam"), Path(r"C:\Program Files\Steam")]
    libraries = []
    for steam in steams:
        libraries.append(steam / "steamapps")
        vdf = steam / "steamapps" / "libraryfolders.vdf"
        if vdf.exists():
            for m in re.finditer(r'"path"\s+"([^"]+)"', vdf.read_text(encoding="utf-8", errors="replace")):
                libraries.append(Path(m.group(1).replace("\\\\", "\\")) / "steamapps")
    for lib in libraries:
        game = lib / "common" / "Factorio"
        if (game / "bin" / "x64" / "factorio.exe").exists():
            return game
    return None


def setup_from_install(game):
    """.devcheck/factorio from an installed Factorio (Windows): its bin/ copied (a second copy can run while the game
    runs), a config folder of its own (config-path.cfg, a config.ini whose paths point here), data/ linked"""
    FACTORIO.mkdir(parents=True, exist_ok=True)
    shutil.copytree(game / "bin", FACTORIO / "bin", dirs_exist_ok=True)
    (FACTORIO / "config").mkdir(exist_ok=True)
    # (LF line ends: with CRLF Factorio ignores the file and uses the system folders, where the game itself runs)
    (FACTORIO / "config-path.cfg").write_bytes(b"config-path=__PATH__executable__/../../config\n"
                                               b"use-system-read-write-data-directories=false\n")
    # the player's config.ini as the template (its [path] section pointed at the system folders, where the game
    # itself runs: this copy reads and writes inside .devcheck, so it never fights the game for the lock file)
    ini = Path(os.environ.get("APPDATA", "")) / "Factorio" / "config" / "config.ini"
    dest = FACTORIO / "config" / "config.ini"
    if not dest.exists():
        text = ini.read_text(encoding="utf-8", errors="replace") if ini.exists() else "; version=12\n[path]\nread-data=x\nwrite-data=x\n"
        text = re.sub(r"^read-data=.*$", "read-data=__PATH__executable__/../../data", text, flags=re.M)
        text = re.sub(r"^write-data=.*$", "write-data=__PATH__executable__/../..", text, flags=re.M)
        dest.write_text(text, encoding="utf-8")
    data = FACTORIO / "data"
    if not (data.exists() or data.is_symlink()):
        link_dir(data, game / "data")
    print(f"factorio: copied bin/ of {game}, linked its data/")


def setup(a):
    """headless Factorio (download, --factorio DIR, or on Windows the Steam install: bin/ copied, data/ linked), and
    for --with-gregtorio runs the dependency mods of Gregtorio Continued (from the mod portal, or --mods-from DIR)"""
    WORK.mkdir(exist_ok=True)
    binary = FACTORIO / ("bin/x64/factorio.exe" if os.name == "nt" else "bin/x64/factorio")
    if a.factorio:
        if FACTORIO.exists() or FACTORIO.is_symlink():
            remove_path(FACTORIO)                 # (a link or junction is removed, never what it points to)
        link_dir(FACTORIO, Path(a.factorio).resolve())
    elif not binary.exists() and os.name == "nt":
        game = steam_factorio()
        if not game:
            sys.exit("no Steam install of Factorio found: pass --factorio DIR (an unpacked Factorio with bin/ and data/)")
        setup_from_install(game)
    elif not binary.exists():
        tar = WORK / "factorio-headless.tar.xz"
        download(f"https://factorio.com/get-download/{a.version}/headless/linux64", tar)
        with tarfile.open(tar) as t:
            t.extractall(WORK)
        tar.unlink()
    print("factorio:", subprocess.run([str(binary), "--version"], capture_output=True, text=True).stdout.splitlines()[0])
    names = required_mods(Path(a.with_gregtorio) / "info.json") if a.with_gregtorio else []
    fetch_mods(names + (a.with_mod or []), a.mods_from)
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


def engine_version(fdir=None):
    """issue #487: major.minor of the Factorio in `fdir` (default: .devcheck/factorio), from its data/base/info.json"""
    try:
        v = json.loads((Path(fdir or FACTORIO) / "data" / "base" / "info.json").read_text(encoding="utf-8"))["version"]
    except (OSError, ValueError, KeyError):
        return FACTORIO_VERSION
    return ".".join(v.split(".")[:2])


def fit_info(folder):
    """issue #487: the info.json of a copied helper mod set to the Factorio in use (factorio_version and the base version)"""
    f = Path(folder) / "info.json"
    info = json.loads(f.read_text(encoding="utf-8"))
    v = engine_version()
    info["factorio_version"] = v
    info["dependencies"] = [re.sub(r"^base >= [0-9.]+$", f"base >= {v}", d) for d in info.get("dependencies", [])]
    f.write_text(json.dumps(info, indent=2), encoding="utf-8")


def helper_dir(src):
    """issue #487: a helper mod (checkmod/, runtimemod/, migratemod/) as it is when the Factorio in use is the one it is
    written for (FACTORIO_VERSION), else a copy in the work folder whose info.json says that Factorio's version: the
    helpers run in a 2.0 Factorio too (the old save of `migrate --old-factorio`, the 2.0 numbers of `bench`)"""
    if engine_version() == FACTORIO_VERSION:
        return src
    dest = WORK / ("helper-" + engine_version()) / src.name
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest)
    fit_info(dest)
    return dest


def texture_stand_in():
    """Issue #325: me-network requires the texture mod, so every load but the proof run's second one has an empty mod
    of its name in the mods folder: its info.json only (the version of ae2-textures/info.json), no override, no
    graphics; the prototypes are me-network's own, as without the texture mod before. Returns its folder."""
    stub = MODS / TEXTURES
    stub.mkdir()
    real = json.loads((ROOT / "ae2-textures" / "info.json").read_text(encoding="utf-8"))
    v = engine_version()                  # (issue #487: the Factorio in use, 2.0 for an old save)
    (stub / "info.json").write_text(json.dumps({"name": TEXTURES, "version": real["version"], "title": STAND_IN,
                                                "author": "devcheck", "factorio_version": v,
                                                "dependencies": [f"base >= {v}"]}), encoding="utf-8")
    return stub


def prepare_mods(gregtorio=None, with_runtime=False, base_only=False, mod_dir=None, with_migrate=False, bench_dir=None,
                 textures=None, with_mods=()):
    """mods/ = this mod (working copy, or `mod_dir`: an older version or the instrumented copy of `bench --profile`)
    + the devcheck helper mods (`bench_dir`: the benchmark mod with its config, instead of the check mod); with
    Gregtorio its checkout and its dependency zips. base_only: without Space Age and quality. textures: a folder
    of the texture mod me-network-ae2-textures to load next to this mod (issue #239, the proof run; never with
    Gregtorio); without it the empty stand-in of texture_stand_in, which me-network requires (issue #325).
    with_mods: third-party mods to load from their zips in mods/ (issue #591, `--with-mod`), with their required
    dependencies; every other zip there is disabled."""
    if textures and gregtorio:
        sys.exit("the texture mod's graphics are never loaded in a Gregtorio run (issue #239: the stand-in is)")
    MODS.mkdir(parents=True, exist_ok=True)
    for p in MODS.iterdir():
        if p.name in (NAME, TEXTURES, GREGTORIO, "mod-list.json") or p.name.startswith(HELPERS) \
                or p.name.startswith(TEXTURES + "_"):
            remove_path(p)
    link_dir(MODS / NAME, Path(mod_dir) if mod_dir else ROOT)
    if textures:
        link_dir(MODS / TEXTURES, Path(textures))
    else:
        texture_stand_in()
    if bench_dir:
        link_dir(MODS / "zz-me-network-devcheck-bench", bench_dir)
        enabled = ["base", NAME, "zz-me-network-devcheck-bench"]
    else:
        link_dir(MODS / "zz-me-network-devcheck", helper_dir(HERE / "checkmod"))
        enabled = ["base", NAME, "zz-me-network-devcheck"]
    # the built-in mods of the Factorio in use (issue #487: 2.1 adds recycler; a 2.0 Factorio for an old save has none)
    builtin = [n for n in ("space-age", "quality", "elevated-rails", "recycler") if (FACTORIO / "data" / n).is_dir()]
    disabled = builtin if base_only else []
    if not base_only:
        enabled += builtin
    zips = sorted({z.name.rsplit("_", 1)[0] for z in MODS.glob("*.zip")})
    wanted = mod_closure((required_mods(Path(gregtorio) / "info.json") if gregtorio else []) + list(with_mods or []))
    if gregtorio:
        link_dir(MODS / GREGTORIO, Path(gregtorio).resolve())
        enabled.append(GREGTORIO)
    enabled += wanted
    disabled += [z for z in zips if z not in wanted]
    if with_runtime:
        link_dir(MODS / "zz-me-network-devcheck-runtime", helper_dir(HERE / "runtimemod"))
        enabled.append("zz-me-network-devcheck-runtime")
    if with_migrate:
        link_dir(MODS / "zz-me-network-devcheck-migrate", helper_dir(HERE / "migratemod"))
        enabled.append("zz-me-network-devcheck-migrate")
    enabled.append(TEXTURES)
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


def create_map(mapfile, *args):
    """`factorio --create mapfile`: the file of an earlier run is removed first, so a failed creation (or a
    Factorio that did not start) cannot pass as the new map. Returns the log and an error text (None when the
    map was made)."""
    mapfile = Path(mapfile)
    if mapfile.exists():
        mapfile.unlink()
    log = factorio("--create", str(mapfile), *args)
    err = load_errors(log) or not_saved(log)
    if not err and not mapfile.exists():
        err = "the map was not created (no map file after --create; see .devcheck/last-run.log)"
    return log, err


def sections(log):
    out = {}
    for m in re.finditer(r"DEVCHECK-([A-Z0-9]+)-BEGIN\n(.*?)\nDEVCHECK-\1-END", log, re.S):
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
        self.R, self.C, self.CF, self.I, self.T, self.B, self.L, self.silos = {}, {}, {}, {}, {}, {}, {}, set()
        self.base = {"water", "steam"}
        for p in rows:
            k = p[0]
            if k == "R":
                self.R[p[1]] = dict(cat={c for c in p[2].split(",") if c}, en=p[3] == "true", ing=split(p[4]), res=split(p[5]),
                                    fin=kinds(p[4]).count("fluid"), fout=kinds(p[5]).count("fluid"))
            elif k == "C":
                self.C[p[1]] = p[3].split(",") if p[3] else []
                self.CF[p[1]] = (int(p[4]), int(p[5]))
                if p[2] == "rocket-silo":
                    self.silos.add(p[1])
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
            elif k == "L":
                self.L[p[1]] = split(p[2])
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
            # issue #591: the products of a rocket launched with an item, once a rocket silo is built
            if self.silos & self.crafters:
                for it, products in self.L.items():
                    if it in self.avail:
                        for x in products:
                            if x not in self.avail:
                                self.avail.add(x)
                                changed = True
            cats = {c for m in self.crafters for c in C.get(m, [])}
            for r in self.unlocked:
                v = R[r]
                if v["cat"] & cats and all(i in self.avail for i in v["ing"]):
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
        machines = [m for m in self.crafters if v["cat"] & set(self.C.get(m, []))]
        missing = [i for i in v["ing"] if i not in self.avail]
        if not machines:
            return f"no machine for category {', '.join(sorted(v['cat']))}"
        if missing:
            return "ingredients never obtainable: " + ", ".join(missing)
        if (v["fin"] or v["fout"]) and not any(
                self.CF.get(m, (0, 0))[0] >= v["fin"] and self.CF.get(m, (0, 0))[1] >= v["fout"] for m in machines):
            return f"needs {v['fin']} fluid in / {v['fout']} out, no reachable machine has that"
        return None

    def uncraftable(self):
        out = []
        for r in sorted(self.unlocked):
            if r.endswith("-recycling") or self.R[r]["cat"] & {"recycling", "parameters"}:
                continue
            if not self.R[r]["res"]:
                continue                # (issue #591: a recipe that makes nothing, such as Krastorio 2's void crushing of an item)
            why = self.why_not(r)
            if why:
                out.append((r, why))
        return out


def mod_file(path, textures=None):
    """the file on disk of an `__me-network__/` path (or of `__me-network-ae2-textures__/`, in the folder `textures`
    or ae2-textures/), None for another mod's"""
    for prefix, folder in (("__me-network__/", ROOT), (f"__{TEXTURES}__/", Path(textures or ROOT / "ae2-textures"))):
        if path.startswith(prefix):
            return folder / path[len(prefix):]
    return None


def check_files(sec, textures=None):
    missing = []
    for path, owner in sec.get("PATHS", []):
        if not mod_file(path, textures).exists():
            missing.append(f"{path} ({owner})")
    return sorted(set(missing))


def check_sprites(sec, textures=None):
    try:
        from PIL import Image
    except ImportError:
        return ["(Pillow not installed, sprite sizes not checked: pip install pillow)"]
    bad = []
    for name, key, fn, w, h, fc, ll, x, y in sec.get("SPRITES", []):
        f = mod_file(fn, textures)
        if not f or not f.exists():
            continue
        w, h, fc, ll, x, y = map(int, (w, h, fc, ll, x, y))
        ll = ll or fc
        W, H = Image.open(f).size
        need_w, need_h = x + min(ll, fc) * w, y + -(-fc // ll) * h
        if need_w > W or need_h > H:
            bad.append(f"{name} {key}: {fn} needs {need_w}x{need_h}, image is {W}x{H}")
    return bad


def check_icons(sec, textures=None):
    """issue #247: an icon of this mod or of the texture mod is a square image of its icon_size (or a mipmap strip of
    that height); headless Factorio loads no image, so a wrong size would show only in the game"""
    try:
        from PIL import Image
    except ImportError:
        return ["(Pillow not installed, icon sizes not checked: pip install pillow)"]
    bad, sizes = set(), {}
    for owner, fn, size in sec.get("ICONS", []):
        f = mod_file(fn, textures)
        if not f or not f.exists():
            continue
        if f not in sizes:
            sizes[f] = Image.open(f).size
        w, h = sizes[f]
        if h != int(size) or w % h:
            bad.add(f"{owner}: {fn} is {w}x{h}, icon_size is {size}")
    return sorted(bad)


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


# issue #474: every item of me-network (ME_NETWORK.items) sits in a subgroup of the item group "me-network" (the tab "ME
# Network", prototypes/network.lua), and so does every recipe of ME_NETWORK.recipes. TAB_ALLOW: the items that may sit
# elsewhere, item -> reason (none so far).
TAB_GROUP = "me-network"
TAB_ALLOW = {}
# The ME items that Gregtorio Continued puts outside the tab on purpose: a run with --with-gregtorio lists them as
# information and fails on any other ME item outside the tab; an entry that is back in the tab is listed to be removed
# here. Empty since Rykon00/Gregtorio#519 (its PR Rykon00/Gregtorio#554): Gregtorio's compat file keeps every ME item in
# the tab (the storage housing and the storage components were in its machine rows before), and its own devcheck fails
# for an ME item outside the tab.
TAB_GREGTORIO = set()


def check_tab(sec, gregtorio=None):
    """issue #474: (problems, information) of the tab "ME Network" from the TAB section of the check mod and the recipe
    rows of the dump"""
    rows = sec.get("TAB", [])
    items = {r[1]: r for r in rows if r[0] == "item"}
    sub = {r[1]: r for r in rows if r[0] == "subgroup"}
    problems = [f"{r[1]}: an item with an icon of me-network that is not in ME_NETWORK.items (made without add_item)"
                for r in rows if r[0] == "stray"]
    info = []
    if TAB_GROUP not in {r[2] for r in sub.values()}:
        problems.append(f"no subgroup of the item group {TAB_GROUP}")
    outside = {n: f"{n}: subgroup {r[2]}, group {r[3]}" for n, r in items.items() if r[3] != TAB_GROUP}
    for n, line in sorted(outside.items()):
        if n in TAB_ALLOW:
            info.append(f"{line} (allowed: {TAB_ALLOW[n]})")
        elif gregtorio and n in TAB_GREGTORIO:
            info.append(f"{line} (Gregtorio Continued, TAB_GREGTORIO)")
        else:
            problems.append(f"{line}: not in the tab ME Network")
    problems += [f"{n}: in TAB_ALLOW but in the tab (remove the entry)" for n in TAB_ALLOW if n in items and n not in outside]
    problems += [f"{n}: in TAB_ALLOW but not an item of ME_NETWORK.items" for n in TAB_ALLOW if n not in items]
    if gregtorio:
        info += [f"{n}: in TAB_GREGTORIO but in the tab (remove the entry)"
                 for n in sorted(TAB_GREGTORIO) if n in items and n not in outside]
    own_recipes = {n for k, n in sec.get("OWN", []) if k == "recipe"}
    for r in sec.get("DUMP", []):
        if r[0] == "R" and r[1] in own_recipes and r[9] != TAB_GROUP:
            line = f"recipe {r[1]}: subgroup {r[8]}, group {r[9]}"
            # with Gregtorio the recipes are its own (ME_NETWORK.replace_recipe), with its rows
            (info if gregtorio else problems).append(line + (" (Gregtorio's recipe)" if gregtorio else ": not in the tab ME Network"))
    print(f"\nitems of me-network in the tab ME Network: {len(items) - len(outside)} of {len(items)}"
          f" ({len({r[2] for r in items.values() if r[3] == TAB_GROUP})} rows)")
    return problems, info


def check_paste(sec):
    """issue #519: the problems of the settings paste: a prototype of prototypes/paste.lua (from the PASTE section of the
    check mod) without its targets or allow_copy_paste, a module of scripts/ with a paste handler the table does not
    name, a module the table names that has none. Issue #527: a block pasted by the mod's own keys (KEYS) instead has
    allow_copy_paste off and the two custom inputs; a handler needs one of the two ways"""
    rows = sec.get("PASTE", [])
    named = {r[1] for r in rows if r[0] == "handler"}
    problems = [f"{r[1]}: {r[2]}" for r in rows if r[0] == "missing"]
    found = {p.stem for p in (ROOT / "scripts").glob("*.lua")
             if re.search(r"^function M\.on_entity_settings_pasted\b", p.read_text(encoding="utf-8"), re.M)}
    problems += [f"scripts/{m}.lua: a paste handler that prototypes/paste.lua does not name (SOURCES, KEYS or BUILTIN)"
                 for m in sorted(found - named)]
    problems += [f"{m}: named in prototypes/paste.lua, but scripts/{m}.lua has no paste handler" for m in sorted(named - found)]
    if not named:
        problems.append("no PASTE section (checkmod/data-final-fixes.lua)")
    print(f"\nsettings paste: {sum(r[0] == 'handler' for r in rows)} modules with a paste handler, {len(found)} in scripts/")
    return problems


def report(title, items, limit=40):
    print(f"\n{title}: {len(items)}")
    for i in items[:limit]:
        print("  -", i)
    if len(items) > limit:
        print(f"  ... {len(items) - limit} more")


def check_ae2_graphics(gregtorio=None):
    """issues #235 and #239: the guard of the texture mod ae2-textures/ (CC BY-NC-SA 3.0, tools/ae2_manifest.py), the
    package checks of tools/build.py on the two zips of the working copy (built into a temporary folder) and their
    self-test; with Gregtorio, its checkout must hold no file byte-identical to an AE2 file or its source either, and
    it never depends on the texture mod"""
    import tempfile
    sys.path.insert(0, str(ROOT / "tools"))
    sys.path.insert(0, str(HERE))
    import ae2_manifest, build, test_ae2_guard
    others = [Path(gregtorio).resolve()] if gregtorio else []
    count, problems, compared = ae2_manifest.check_tree(ROOT, others)
    print(f"texture mod {ae2_manifest.MOD_FOLDER}/ ({ae2_manifest.MOD_NAME}, CC BY-NC-SA 3.0): {count} AE2 files "
          "in MANIFEST.tsv")
    with tempfile.TemporaryDirectory(prefix="me-network-zips-") as d:
        me, tex, zips = build.build_all(ROOT, d, no_psd=True)
    print(f"  packages: {me.name} (GPLv3) and {tex.name} (CC BY-NC-SA 3.0): "
          + ("no zip holds both licenses" if not zips else f"{len(zips)} problems"))
    for other in others:
        n = compared.get(str(other), 0)
        print(f"  Gregtorio Continued ({other}): "
              + (f"no file byte-identical to {n} AE2 hashes" if n else "nothing to compare (the manifest is empty)"))
        info = other / "info.json"
        deps = json.loads(info.read_text(encoding="utf-8")).get("dependencies", []) if info.is_file() else []
        if any(ae2_manifest.MOD_NAME in dep for dep in deps):
            problems.append(f"{info}: Gregtorio Continued depends on {ae2_manifest.MOD_NAME}; it depends on me-network only")
    ran, failed = test_ae2_guard.run_quiet()
    print(f"  guard and package self-test: {ran - len(failed)} of {ran} cases as expected")
    if problems:
        report("problems of the AE2 graphics", problems)
    if zips:
        report("problems of the packages", zips)
    if failed:
        report("guard self-test cases that failed", failed)
    return problems + zips + failed


def check_upstream_icons(gregtorio=None):
    """issue #238: no file under graphics/ and not thumbnail.png has the bytes of an icon taken over from Gregtorio 0.1.9
    (tools/upstream_icons.py) and its self-test; with Gregtorio, no file of its checkout either"""
    sys.path.insert(0, str(ROOT / "tools"))
    sys.path.insert(0, str(HERE))
    import upstream_icons, test_upstream_icon_guard
    others = [Path(gregtorio).resolve()] if gregtorio else []
    count, problems, compared = upstream_icons.check_tree(ROOT, others)
    print(f"icons taken over from Gregtorio 0.1.9 ({upstream_icons.LIST}): {count} hashes, "
          + ("none under graphics/ or as thumbnail.png" if not problems else "found"))
    for other in others:
        hits = [p for p in problems if p.startswith(f"{other}:")]
        print(f"  Gregtorio Continued ({other}): "
              + (f"no file byte-identical to the {compared.get(str(other), 0)} hashes" if not hits else f"{len(hits)} files"))
    ran, failed, skipped = test_upstream_icon_guard.run_quiet()
    print(f"  guard self-test: {ran - len(failed) - len(skipped)} of {ran} cases as expected"
          + "".join(f"; skipped {s}" for s in skipped))
    if problems:
        report("files with the bytes of an icon taken over from Gregtorio 0.1.9", problems)
    if failed:
        report("guard self-test cases that failed", failed)
    return problems + failed


def check_release_texture():
    """issue #243: the self-test of the texture mod's release (tools/release_textures.py on temporary git repositories,
    tools/portal_upload.sh against a fake mod portal, the wiring of .github/workflows/release.yml)"""
    sys.path.insert(0, str(ROOT / "tools"))
    sys.path.insert(0, str(HERE))
    import test_release_texture
    ran, failed, skipped = test_release_texture.run_quiet()
    print(f"texture mod release (version check, portal upload) self-test: {ran - len(failed) - len(skipped)} of {ran} "
          "cases as expected" + "".join(f"; skipped {s}" for s in skipped))
    if failed:
        report("release self-test cases that failed", failed)
    return failed


def check_map(a, mapfile, textures=None):
    """creates the map with the mods prepared and runs the static checks on its dump: (ok, sections, log); sections
    is None when the mods did not load"""
    log, err = create_map(mapfile)
    sec = sections(log)
    validate = [" ".join(r) for r in sec.get("VALIDATE", [])]
    print(f"load: {'FAILED' if err else 'ok'}")
    if "VALIDATEFINAL" in sec:
        # issue #591: a third-party mod (Krastorio 2) names in its data.lua recipes it adds in a later stage: only a
        # reference still missing at the end (checkmod/data-final-fixes.lua) is a problem
        final = {" ".join(r) for r in sec["VALIDATEFINAL"]}
        report("references to prototypes missing after data.lua only, there at the end (information)",
               [v for v in validate if v not in final])
        validate = [v for v in validate if v in final] + sorted(final - set(validate))
    if validate:
        report("references to missing prototypes", validate)
    if err:
        print("\n" + err)
        return False, None, log
    m = Model(sec["DUMP"])
    own = sec.get("OWN", [])
    own_recipes = [n for k, n in own if k == "recipe"]
    own_techs = [n for k, n in own if k == "technology"]
    print(f"\nresearchable technologies of the game: {len(m.researched)} of {sum(1 for v in m.T.values() if v['en'])}")
    techs = [f"{t}: cannot be researched" for t in own_techs if t not in m.researched]
    print(f"technologies of me-network: {len(own_techs) - len(techs)} of {len(own_techs)} researchable")
    report("technologies of me-network that cannot be researched", techs)
    # Rykon00/Gregtorio#215: a recipe Gregtorio keeps locked on purpose (its FORK_RECIPES_LOCKED) is not unlocked there
    locked = {row[0]: row[1] if len(row) > 1 else "" for row in sec.get("GREGTORIOLOCKED", [])}
    recipes, kept = [], []
    for r in own_recipes:
        if r not in m.R:
            recipes.append(f"{r}: does not exist")
        elif r not in m.unlocked:
            if r in locked:
                kept.append(f"{r}: {locked[r]}")
            else:
                recipes.append(f"{r}: not unlocked by a researchable technology")
        elif r in locked:
            recipes.append(f"{r}: in Gregtorio's FORK_RECIPES_LOCKED but unlocked")
        elif m.why_not(r):
            recipes.append(f"{r}: {m.why_not(r)}")
    print(f"recipes of me-network: {len(own_recipes) - len(recipes) - len(kept)} of {len(own_recipes)} unlocked and craftable")
    report("recipes of me-network kept locked by Gregtorio (its FORK_RECIPES_LOCKED, information)", kept)
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
    files, sprites, locale = check_files(sec, textures), check_sprites(sec, textures), check_locale(sec)
    icons = check_icons(sec, textures)
    report("missing graphics files", files)
    report("sprite sheets too small", sprites)
    report("icons whose image does not fit their icon_size", icons)
    report("names missing in locale/en", locale)
    # issue #487: a key Factorio removed (2.0 -> 2.1): 2.1 refuses a few with an error (a recipe's category, a product's
    # probability, an item's fuel_category, a fluid box's temperatures) and ignores the others: those fail silently
    rows = [r for r in sec.get("REMOVEDKEYS", []) if len(r) > 1]
    other = [r for r in rows if re.split(r"[.\[]", r[0])[0] in REMOVED_KEYS_OTHER_MODS]
    removed = [f"{r[0]}: {r[1]}" for r in rows if r not in other]
    report("prototype keys that Factorio removed, of other mods (information: REMOVED_KEYS_OTHER_MODS)",
           [f"{r[0]}: {r[1]} ({REMOVED_KEYS_OTHER_MODS[re.split(r'[.\[]', r[0])[0]]})" for r in other])
    print(f"prototype keys removed by Factorio {FACTORIO_VERSION}: {len(removed)}")
    report("prototype keys that Factorio removed (removed-keys.lua; ignored when loaded: they fail silently)", removed)
    tab, tab_info = check_tab(sec, getattr(a, "with_gregtorio", None))
    report("ME items and recipes outside the tab ME Network (information)", tab_info)
    report("ME items and recipes outside the tab ME Network (issue #474)", tab)
    ok = not (validate or files or [s for s in sprites + icons if not s.startswith("(")] or techs or recipes or uncraft
              or locale or tab or removed)
    return ok, sec, log


# issue #239, step 4: the stand-ins of the texture mod's proof run, one per form of ae2-textures/overrides.lua; each the
# first of its candidates that overrides.lua does not set itself (issue #260: the real entries are applied too)
PROOF_ITEMS = ("item:me-controller", "item:fluix-cable", "item:me-terminal",     # an icon (the file-name form: one file)
               "item:me-underground-cable", "item:me-level-maintainer", "item:me-circuit-interface")
PROOF_ENTITIES = ("me-drive", "me-wireless-access-point", "me-network-controller", "me-terminal",  # (the table form)
                  "me-level-maintainer", "me-circuit-interface", "me-underground-cable")
PROOF_DIR = "ae2-textures-proof"        # the throw-away copy in the work folder


def real_override_keys():
    """the keys ("<type>/<name>") that ae2-textures/overrides.lua sets (not the file names of a table's entries)"""
    src = (ROOT / "ae2-textures" / "overrides.lua").read_text(encoding="utf-8")
    return [k for k in re.findall(r'^\s*\["([^"]+)"\]\s*=', src, re.M) if not k.startswith("__")]


def stand_in_png(size):
    """a plain PNG of (width, height), generated here (one grey; nothing of AE2 or of any other image)"""
    import struct, zlib
    w, h = size
    chunk = lambda kind, data: (struct.pack(">I", len(data)) + kind + data
                                + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))
    rows = b"".join(b"\0" + b"\x80\x80\x80\xff" * w for _ in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def png_size(path):
    import struct
    with open(path, "rb") as f:
        head = f.read(24)
    return struct.unpack(">II", head[16:24])


def owners(sec):
    """{owner prototype ("type:name"): {files of me-network and of the texture mod it names}}"""
    out = {}
    for path, owner in sec.get("PATHS", []):
        out.setdefault(owner, set()).add(path)
    return out


def proof_copy(base_sec):
    """a throw-away copy of ae2-textures/ with two stand-in overrides added to its overrides.lua: the icon of an item of
    PROOF_ITEMS and one file of an entity of PROOF_ENTITIES (the first of each that overrides.lua does not set), each a
    generated PNG of the replaced file's size. Returns (folder, {owner: (old file, new file)}, problems)."""
    by_owner = owners(base_sec)
    problems, cases = [], {}
    taken = {k.replace("/", ":", 1) for k in real_override_keys()}
    item = next((o for o in PROOF_ITEMS if o not in taken and len(by_owner.get(o, ())) == 1), None)
    if not item:
        problems.append(f"proof: none of {PROOF_ITEMS} is free in overrides.lua and names one file of me-network")
    else:
        cases[item] = (sorted(by_owner[item])[0], f"__{TEXTURES}__/graphics/devcheck-stand-in-icon.png")
    entity = next((o for name in PROOF_ENTITIES for o in sorted(by_owner) if o.endswith(":" + name) and o not in taken
                   and o.split(":")[0] not in ("item", "recipe", "technology") and len(by_owner[o]) > 1), None)
    if not entity:
        problems.append(f"proof: none of the entities {PROOF_ENTITIES} is free in overrides.lua and names more than one "
                        "file of me-network")
    else:
        cases[entity] = (sorted(by_owner[entity])[0], f"__{TEXTURES}__/graphics/devcheck-stand-in-entity.png")
    dest = WORK / PROOF_DIR
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(ROOT / "ae2-textures", dest)
    lines = []
    for owner, (old, new) in cases.items():
        f = dest / new[len(f"__{TEXTURES}__/"):]
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(stand_in_png(png_size(mod_file(old))))
        key = owner.replace(":", "/", 1)
        lines.append(f'OVERRIDES["{key}"] = "{new}"' if owner.startswith("item:")
                     else f'OVERRIDES["{key}"] = {{ ["{old}"] = "{new}" }}')
    src = (dest / "overrides.lua").read_text(encoding="utf-8")
    (dest / "overrides.lua").write_text("-- devcheck: overrides.lua of ae2-textures/ plus the stand-ins of issue #239\n"
                                        "local OVERRIDES = (function()\n" + src + "\nend)()\n"
                                        + "\n".join(lines) + "\nreturn OVERRIDES\n", encoding="utf-8")
    return dest, cases, problems


def check_textures(a, base_sec):
    """issue #239: the second load, with the texture mod next to me-network (a throw-away copy of ae2-textures/ with
    the stand-ins of proof_copy): the same static checks, no override skipped, each stand-in in place of its file
    and nothing else of the prototype changed; without the texture mod (the first load) no file of it is named.
    The copy and its link are removed afterwards and ae2-textures/ is left as it was."""
    print(f"\n--- with the texture mod {TEXTURES} (issue #239): a throw-away copy of ae2-textures/ with two stand-in "
          "overrides ---")
    before = {p.relative_to(ROOT).as_posix(): p.read_bytes() for p in (ROOT / "ae2-textures").rglob("*") if p.is_file()}
    copy, cases, problems = proof_copy(base_sec)
    try:
        prepare_mods(base_only=a.base_only, textures=copy, with_mods=with_mods(a))
        ok, sec, log = check_map(a, WORK / "check-map-textures.zip", textures=copy)
    finally:
        link = MODS / TEXTURES
        if link.is_symlink() or (hasattr(link, "is_junction") and link.is_junction()) or link.exists():
            remove_path(link)                   # the link first: never delete through it
        shutil.rmtree(copy)
    after = {p.relative_to(ROOT).as_posix(): p.read_bytes() for p in (ROOT / "ae2-textures").rglob("*") if p.is_file()}
    if before != after:
        problems.append("ae2-textures/ changed during the proof run")
    if copy.exists() or (MODS / TEXTURES).exists():
        problems.append("the proof run left its copy or its link behind")
    applied = re.findall(rf"data-final-fixes\.lua:\d+: {TEXTURES}: (.*)", log)
    skipped = [l for l in applied if "SKIPPED" in l]
    problems += [f"override skipped: {l}" for l in skipped]
    stray = sorted({p for p, _ in base_sec.get("PATHS", []) if p.startswith(f"__{TEXTURES}__/")})
    if stray:
        problems.append(f"without the texture mod the prototypes name its files: {stray[:3]}")
    if sec is not None:
        base, now = owners(base_sec), owners(sec)
        for owner, (old, new) in cases.items():
            got = now.get(owner, set())
            if new not in got or old in got:
                problems.append(f"proof: {owner} names {sorted(got)}, expected {new} in place of {old}")
            elif got - {new} != base.get(owner, set()) - {old}:
                problems.append(f"proof: {owner}: other files changed ({sorted(got ^ base.get(owner, set()))})")
            else:
                print(f"proof: {owner}: {old} -> {new} with the texture mod, {old} without it")
    # issue #247: every entry of the real overrides.lua is applied, not only the stand-ins
    real = real_override_keys()
    done = {l.split(": ", 1)[0] for l in applied if "SKIPPED" not in l}
    problems += [f"override of overrides.lua not applied: {k}" for k in real if k not in done]
    print(f"overrides applied: {len(applied) - len(skipped)} ({len(real)} of overrides.lua, the {len(cases)} "
          f"stand-ins), skipped: {len(skipped)}")
    print("stand-ins and copy removed: " + ("yes" if not (copy.exists() or (MODS / TEXTURES).exists()) else "NO"))
    report("problems of the texture mod run", problems)
    return ok and sec is not None and not problems


def with_mods(a):
    """issue #591: the mods of `--with-mod` (each fetched with its required dependencies when not in mods/ yet:
    `--mods-from DIR` or the mod portal)"""
    names = getattr(a, "with_mod", None) or []
    if names:
        fetch_mods(names, getattr(a, "mods_from", None))
    return names


def mods_label(a, base_only=False):
    return (("base only" if base_only else "base, Space Age, quality")
            + (" + Gregtorio Continued" if getattr(a, "with_gregtorio", None) else "")
            + "".join(f" + {m}" for m in getattr(a, "with_mod", None) or []))


# issue #593: the vanilla stand-ins that every ME recipe swaps for a Krastorio 2 item (glass, certus quartz, piston)
K2_GONE = ("plastic-bar", "stone", "fast-inserter")


def check_krastorio2(sec):
    """issue #593: with the Krastorio 2 compatibility active no ME recipe keeps a stand-in of K2_GONE, and the ME Molecular
    Assembler crafts Krastorio 2's automation core (an assembler recipe of its first tier)"""
    rows = [p for p in sec.get("DUMP", []) if p[0] == "R"]
    recipes = {p[1]: p for p in rows}
    own = [n for k, n in sec.get("OWN", []) if k == "recipe"]
    out = []
    for n in own:
        ing = {x.split(":", 1)[1] for x in recipes[n][4].split(",") if x} if n in recipes else set()
        left = sorted(ing & set(K2_GONE))
        if left:
            out.append(f"{n} keeps the stand-in {', '.join(left)}")
    cats = {}
    for p in sec.get("DUMP", []):
        if p[0] == "C":
            cats[p[1]] = set(p[3].split(",")) if p[3] else set()
    core = recipes.get("kr-automation-core")
    if not core:
        out.append("Krastorio 2 has no recipe kr-automation-core")
    elif not set(core[2].split(",")) & cats.get("me-molecular-assembler", set()):
        out.append(f"the ME Molecular Assembler ({', '.join(sorted(cats.get('me-molecular-assembler', [])))}) cannot craft "
                   f"kr-automation-core ({core[2]})")
    assembler = [r[1] for r in sec.get("KRASTORIO2", [])[1:] if r[0] == "assembler"]
    print(f"ME Molecular Assembler with Krastorio 2: {', '.join(assembler) or '?'}")
    return out


def check(a):
    prepare_mods(gregtorio=a.with_gregtorio, base_only=a.base_only, with_mods=with_mods(a))
    print("mods: " + mods_label(a, a.base_only))
    ae2 = check_ae2_graphics(a.with_gregtorio) + check_upstream_icons(a.with_gregtorio) + check_release_texture()
    if a.with_gregtorio:
        # issue #239: no AE2 graphics in a Gregtorio run; since issue #325 me-network requires the texture mod, so the
        # Gregtorio run loads its empty stand-in (texture_stand_in), never the texture mod itself or a zip of it
        stub = MODS / TEXTURES
        stray = [p.name for p in MODS.iterdir() if p.name.startswith(TEXTURES + "_")]
        if stub.is_symlink() or (hasattr(stub, "is_junction") and stub.is_junction()) or not stub.is_dir() \
                or sorted(p.name for p in stub.iterdir()) != ["info.json"] \
                or json.loads((stub / "info.json").read_text(encoding="utf-8")).get("title") != STAND_IN:
            stray.append(TEXTURES)
        print(f"texture mod {TEXTURES}: " + ("its empty stand-in (no AE2 graphics in the Gregtorio run)"
                                             if not stray else f"NOT THE STAND-IN: {stray}"))
        ae2 += [f"{s}: the texture mod's graphics are never loaded in a Gregtorio run" for s in stray]
    ok, sec, _ = check_map(a, WORK / "check-map.zip")
    if sec is None:
        return 1
    # issue #514: the ME Terminal's row above the tabs (checkmod/control.lua): the quality filter with the quality mod only
    top = [r[1] for r in sec.get("TERMTOP", []) if len(r) > 1]
    quality = {"fork_me_qcmp", "fork_me_quality"}
    print(f"\nME Terminal, the row above the tabs: {', '.join(n or '(label)' for n in top) or 'not built'}")
    term = []
    if not top:
        term.append("the row was not built (checkmod/control.lua, remote terminal_top_view)")
    elif a.base_only and quality & set(top):
        term.append("the quality filter is there without the quality mod")
    elif not a.base_only and not quality <= set(top):
        term.append("the quality filter is missing with the quality mod")
    report("ME Terminal quality filter (issue #514)", term)
    ok = ok and not term
    paste = check_paste(sec)
    report("settings paste: missing lists, flags or handlers (issue #519, prototypes/paste.lua)", paste)
    ok = ok and not paste
    # issue #592: the Krastorio 2 compatibility (prototypes/compat/krastorio2.lua) runs with Krastorio 2 or Krastorio 2
    # Spaced Out and never with Gregtorio Continued
    k2 = {"Krastorio2", "Krastorio2-spaced-out"} & set(getattr(a, "with_mod", None) or [])
    want = "active" if k2 and not a.with_gregtorio else "inactive"
    got = (sec.get("KRASTORIO2") or [["missing"]])[0][0]
    print(f"\nKrastorio 2 compatibility: {got}")
    k2_problems = [] if got == want else [f"the Krastorio 2 compatibility is {got}, expected {want}"]
    if got == "active":
        k2_problems += check_krastorio2(sec)
    report("Krastorio 2 compatibility (issues #592, #593)", k2_problems)
    ok = ok and not k2_problems
    if not a.with_gregtorio:
        ok = check_textures(a, sec) and ok
    ok = ok and not ae2
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
    ("MAINTAINER", "level maintainer test"),
    ("CIRCUIT", "circuit interface test"), ("SETTINGS", "settings copy test"), ("SCHEDULER", "ME scheduler test"), ("PARKING", "ME parked blocks test"),
    ("STATS", "ME stats command test"), ("MARGIN", "ME margin of a short busy list test"), ("ACCEL", "Acceleration Card test"), ("BUSACCEL", "ME bus acceleration cards test"), ("REFUSED", "ME import bus with refused stacks test"), ("TAGITEM", "ME items with tags through storage buses test"), ("TAGDAMAGED", "ME damaged items with tags test"), ("TAGCRAFT", "ME autocrafting of items with tags test"), ("TAGLABEL", "ME items with a label test"), ("FUZZYDATA", "ME fuzzy export of items with data test"), ("DAMAGED", "damaged items on the by-count paths test"), ("LAB", "ME export bus into a lab test"), ("BULK", "ME export bus into a recipe of more than a stack test"), ("COPYPASTE", "ME settings through the copy-paste tool test"), ("SETTINGSPASTE", "ME settings paste through the game test"), ("PASTEKEYS", "ME settings paste through the copy and paste keys test"),("DISASSEMBLY", "ME cell disassembly test"), ("IOPORT", "ME IO Port test"), ("CELLQUALITY", "ME cell item quality test"), ("QBRIDGE", "ME Quantum Bridge test"), ("WLINK", "ME Wireless Link test"), ("REFILL", "ME storage bus refill test"),
    ("PLANS", "ME kept plans test"),
    ("SCAN", "ME provider scan test"),
    ("ENTRIES", "ME terminal entries test"), ("QUALITYTERM", "ME Terminal quality filter and sort test"),
    ("HOLDERLISTS", "ME holder lists test"),
    ("CRAFTER", "ME crafter choice test"),
    ("HOLDERS", "ME holder cursor test"),
    ("GRAPH", "ME graph removal test"),
    ("CURSOR", "open key and cursor test"), ("RECIPEPASTE", "recipe paste test"),
    ("CARDS", "ME upgrade card test"), ("PRIORITIES", "ME priority test"), ("WORKBENCH", "ME Cell Workbench test"),
    ("CARDSLOTS", "ME storage bus card slots test"), ("WBSLOTS", "ME Cell Workbench slots test"),
    ("PANE", "ME window pane test (storage bus)"), ("WBPANE", "ME window pane test (workbench)"),
    ("WBPICK69", "ME Cell Workbench partition buttons test"), ("WBTIP64", "ME cell tooltip test"), ("WBSLOTTIP75", "ME window slot tooltips test"), ("WBKEY79", "ME stored item descriptions test"), ("WBDRIVETIP147", "ME drive cell tooltips test"),
    ("STORABLE", "ME storable items test"),
    ("WALKABLE", "ME walkable blocks and selection over ore (issues #129, #268, Gregtorio#541)"),
    ("TEMPERATURE", "ME fluid temperature test (issue #159)"),
    ("PROVIDERS", "ME pattern provider machines test (issue #158)"),
    ("PASTECRAFT", "ME interface keeping one craft (issue #157)"),
    ("NATIVEINV", "ME windows with the native inventory (issue #542)"),
    ("WINSOUND", "ME window sounds (issue #545)"),
    ("BLOCKINV", "ME windows: block slots as inventory elements (issue #543)"),
    ("PATTERNCAP", "ME Pattern Capacity Card (issue #156)"),
    ("IFACETERM", "ME Interface Terminal (issue #336)"),
    ("BLOCKING", "ME Pattern Provider blocking mode (issue #335)"),
    ("LOCK", "ME Pattern Provider lock until the result is back (issue #346)"),
    ("QUALITYCRAFT", "Autocrafting in every quality (issue #352)"),
    ("GROUPBUS", "Group Filter Card on the import and export bus (issue #363)"),
    ("BUSCARDS", "Capacity, Fuzzy and Inverter Card on the import and export bus (issue #413)"),
    ("CRAFTCARD", "Crafting Card on the export bus and the interface (issue #411)"),
    ("CIRCUITBUS", "Circuit connector of the buses and the interface (issue #412)"),
    ("BIGCELLS", "Storage cells above 256k and the Singularity cell (issue #414)"),
    ("BIGCPUS", "Crafting storage above 256k and the crafting accelerators (issue #415)"),
    ("PTERMEX", "ME Pattern Terminal Ex (issue #416)"),
    ("FLUIDWAGON", "Fluid wagon on the ME Storage Bus (issue #417)"),
    ("MERGEJOB", "Crafting job merging (issue #418)"),
    ("PERF420", "Performance levers (issue #420)"),
    ("CIRCUITLOCK", "ME Pattern Provider lock by the circuit condition (issue #429)"),
    ("ADVEMITTER", "ME Advanced Level Emitter (issue #443)"),
    ("VIEWCELL", "View Cells (issue #440)"),
    ("CREATIVECELL", "Creative ME Storage Cell (issue #441)"),
    ("CREATIVEENERGY", "Creative Energy Cell (issue #442)"),
    ("BIGPOWER", "ME Controller buffer above 6 MW (issue #556)"),
    ("PENDING", "Pattern provider waiting for patterns (issue #558)"),
    ("MEMCARD", "ME Memory Card (issue #561)"),
    ("PATTERNBULK", "Pattern paste and bulk clearing (issue #585)"),
    ("BPCARDS", "Cards of blocks built from a blueprint (issue #590)"),
    ("WGROUP", "ME Wireless Link groups (issue #559)"),
    ("SINGFLUID", "Singularity cell for fluids (issue #562)"),
    ("FASTCRAFT", "Fast machines kept busy (issue #557)"),
    ("ASMNET", "ME Molecular Assembler carries the network (issue #560)"),
    ("CELLLIGHT", "Cell light with all types used (issue #468)"),
    ("MAINTROWS", "ME level maintainer rows (issue #351)"),
    ("CPUMODE", "ME crafting CPU choice and modes (issue #350)"),
    ("MONITORS", "ME Storage, Conversion and Throughput Monitor (issue #353)"),
    ("VOIDCELL", "Void ME Storage Cells (issue #354)"),
    ("TOGGLE", "ME Toggle Bus and Level Emitter (issue #355)"),
    ("IFACECAP", "ME Interface Capacity Card (issue #196)"),
    ("WIRELESS", "ME wireless terminal (issues #205 to #210)"),
    ("STICKY", "ME Sticky Card (issue #193)"),
    ("CHEST", "ME Chest (issue #229)"),
    ("SBUSMODE", "ME storage bus filter mode (issue #155)"),
    ("LSBUS", "ME logistic storage bus (issue #506)"),
    ("LIF", "ME logistic interface (issue #531)"),
    ("LIFAUTO", "ME logistic interface automatic mode (issue #537)"),
    ("LIFBUILD", "ME logistic interface construction supply (issue #538)"),
    ("REMOTEVIEW", "ME windows in remote view (issues #176, #177)"),
    ("GRIDFLUID", "ME pattern fluid amounts on the engine's grid (issue #261)"),
    ("IFACEWAKE", "ME interface wake (issue #313)"),
    ("IFACEFLUIDS", "ME interface window fluids (issue #311)"),
    ("DONE", "all tests reported"),
)


SAVELOAD_TICK = 500             # the runtime map is saved at this tick of a server run and loaded again (issue #38)
RCON_PORT = 27815


def rcon(sock, kind, body, req_id):
    """one Source RCON request (kind 3: auth, 2: command) and its response body"""
    import struct
    data = body.encode("utf-8")
    packet = struct.pack("<iii", 4 + 4 + len(data) + 2, req_id, kind) + data + b"\x00\x00"
    sock.sendall(packet)
    head = b""
    while len(head) < 4:
        chunk = sock.recv(4 - len(head))
        if not chunk:
            raise OSError("rcon: connection closed")
        head += chunk
    size = struct.unpack("<i", head)[0]
    rest = b""
    while len(rest) < size:
        chunk = sock.recv(size - len(rest))
        if not chunk:
            raise OSError("rcon: connection closed")
        rest += chunk
    rid, rtype = struct.unpack("<ii", rest[:8])
    if kind == 3 and rid == -1:
        raise OSError("rcon: authentication refused")
    return rest[8:-2].decode("utf-8", errors="replace")


def saveload(mapfile, ticks, extra_args=()):
    """The map runs as a headless server (real time, nobody connected) until SAVELOAD_TICK, saves through RCON
    (`game.server_save`) and quits; the save is then run with `--benchmark` to `ticks`. Returns the benchmark log
    of the loaded save, or None and a reason. (`--benchmark` cannot save: `game.auto_save` writes nothing there.)"""
    import socket, time
    binary = FACTORIO / ("bin/x64/factorio.exe" if os.name == "nt" else "bin/x64/factorio")
    settings = WORK / "server-settings.json"
    settings.write_text(json.dumps({"name": "devcheck", "description": "the save-and-load half of devcheck runtime",
                                    "visibility": {"public": False, "lan": False}, "auto_pause": False,
                                    "require_user_verification": False, "max_players": 1}), encoding="utf-8")
    saves = FACTORIO / "saves"
    saves.mkdir(exist_ok=True)
    save = saves / "devcheck-mid.zip"
    if save.exists():
        save.unlink()
    server_log = WORK / "saveload-server.log"
    start = WORK / "saveload-start.zip"                 # (a copy: the server saves the map back when it quits)
    shutil.copy2(mapfile, start)
    with open(server_log, "w", encoding="utf-8") as out:
        proc = subprocess.Popen([str(binary), "--mod-directory", str(MODS), "--start-server", str(start),
                                 "--server-settings", str(settings), "--bind", "127.0.0.1",
                                 "--rcon-bind", f"127.0.0.1:{RCON_PORT}", "--rcon-password", "devcheck", *extra_args],
                                stdout=out, stderr=subprocess.STDOUT)
        sock = None
        deadline = time.time() + 120
        try:
            while time.time() < deadline and proc.poll() is None:
                try:
                    sock = socket.create_connection(("127.0.0.1", RCON_PORT), timeout=5)
                    rcon(sock, 3, "devcheck", 1)
                    break
                except OSError:
                    sock = None
                    time.sleep(0.5)
            if not sock:
                return None, "the server did not start or answer RCON (" + str(server_log) + ")"
            while time.time() < deadline:
                t = rcon(sock, 2, "/silent-command rcon.print(game.tick)", 2).strip()
                if t.isdigit() and int(t) >= SAVELOAD_TICK:
                    break
                time.sleep(0.2)
            else:
                return None, "the server never reached tick " + str(SAVELOAD_TICK)
            saved_at = int(t)
            rcon(sock, 2, '/silent-command game.server_save("devcheck-mid")', 3)
            size = -1
            while time.time() < deadline:
                if save.exists() and save.stat().st_size == size and size > 0:
                    break
                size = save.stat().st_size if save.exists() else -1
                time.sleep(0.5)
            else:
                return None, "the server did not write the save"
            try:
                rcon(sock, 2, "/quit", 4)
            except OSError:
                pass
        finally:
            if sock:
                sock.close()
            try:
                proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                proc.kill()
    log = factorio("--benchmark", str(save), "--benchmark-ticks", str(ticks - saved_at))
    if not re.search(r"Performed (\d+) updates", log):
        return None, "the loaded save did not run: " + (load_errors(log) or "")
    return log, saved_at


def runtime(a):
    prepare_mods(gregtorio=a.with_gregtorio, with_runtime=True, with_mods=with_mods(a))
    print("mods: " + mods_label(a))
    log, err = create_map(WORK / "runtime-map.zip", *seed_args(a))
    if err:
        print(err)
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
    # issue #38 part 3: the lines of /me-stats rendered by the engine (log of a LocalisedString): no missing key, no unfilled parameter
    stats_lines = re.findall(r"DEVCHECK-STATS-LINE (.*)", log)
    for text in stats_lines:
        if "Unknown key" in text or re.search(r"__\d+__", text):
            fails.append(f"/me-stats prints an unrendered line: {text}")
    if stats_lines:
        print("/me-stats, rendered:")
        for text in stats_lines[:12]:
            print("  " + text)
    for key, label in RUNTIME_TESTS:
        m = re.search(rf"DEVCHECK-RUNTIME-{key} (.*)", log)
        print(f"{label}: {m.group(1) if m else 'did not run'}")
        if not m:
            fails.append(f"{label} did not run (needs --ticks >= 1500)")
        elif not m.group(1).startswith("ok"):
            fails.append(f"{label} failed")
    # issue #38: the same map saved in the middle of its run and loaded again must schedule like the unbroken run
    if not getattr(a, "no_saveload", False):
        digests = dict(re.findall(r"DEVCHECK-RUNTIME-SCHEDULE (\d+) (.*)", log))
        log_b, why = saveload(WORK / "runtime-map.zip", a.ticks)
        if not log_b:
            print(f"schedule after a save and load: {why}")
            fails.append("save and load: " + str(why))
        else:
            digests_b = dict(re.findall(r"DEVCHECK-RUNTIME-SCHEDULE (\d+) (.*)", log_b))
            fails_b = re.findall(r"DEVCHECK-RUNTIME-FAIL (.*)", log_b)
            problems = [f"after the load: {f}" for f in fails_b]
            if not digests or not digests_b:
                problems.append("no schedule digest in the " + ("unbroken" if not digests else "loaded") + " run")
            for tick, d in sorted(digests.items(), key=lambda kv: int(kv[0])):
                other = digests_b.get(tick)
                if other is None:
                    problems.append(f"the loaded run has no schedule digest at tick {tick}")
                elif other != d:
                    a_parts, b_parts = d.split(" "), other.split(" ")
                    diff = [x for x in a_parts if x not in b_parts][:3]
                    problems.append(f"the schedule at tick {tick} differs after the load: {diff}")
            n = len((next(iter(digests.values())) if digests else "").split(" "))
            print(f"schedule after a save and load test: {'ok' if not problems else 'failed'} (saved at tick {why}, "
                  f"digests at ticks {', '.join(sorted(digests, key=int))} with {n} entries{' equal' if not problems else ''})")
            fails += problems
    report("runtime problems", fails)
    if err or not ran or fails:
        print(err.group(1) if err else "")
        print("\nRESULT: PROBLEMS FOUND")
        return 1
    print("\nRESULT: OK")
    return 0


# --------------------------------------------------------------------------------------------
# migrate: a save of an older version, loaded with the working copy (issue #146: from 0.5.0 on; older ones are refused)
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


def bumped_tree():
    """the working copy as a plain folder whose version is one patch up, .devcheck/new-bumped: loading a save of the old version
    with it is an update as the game does it (Factorio runs on_configuration_changed; with the version of the working copy
    unchanged it does not)"""
    dest = WORK / "new-bumped"
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(ROOT, dest, ignore=shutil.ignore_patterns(".devcheck", ".git", "dist", "__pycache__"))
    f = dest / "info.json"
    info = json.loads(f.read_text(encoding="utf-8"))
    v = info["version"].split(".")
    v[-1] = str(int(v[-1]) + 1)
    info["version"] = ".".join(v)
    f.write_text(json.dumps(info, indent=2), encoding="utf-8")
    return dest


ITEMS_SETTING = "zz-me-network-devcheck-migrate-items"     # (migratemod/settings.lua, issue #503)


def migrate(a):
    try:
        return migrate_run(a)
    finally:
        if a.removed_items:
            startup_setting(ITEMS_SETTING, None)


def migrate_run(a):
    global FACTORIO
    # issue #503: `--from-ref working` makes the save with the working copy itself (the update is then only the helper's items)
    old = ROOT if a.from_ref == "working" else old_tree(a.from_ref)
    # issue #487: a version of another Factorio (2.0) makes its save in that Factorio (--old-factorio), the working copy
    # loads it in this one: a save of the last 2.0 version loaded in 2.1, as a player who updates sees it
    old_fv = json.loads((old / "info.json").read_text(encoding="utf-8")).get("factorio_version")
    new_factorio, settings, kept = FACTORIO, MODS / "mod-settings.dat", None
    if old_fv and old_fv != engine_version():
        if not a.old_factorio:
            sys.exit(f"{a.from_ref} is for Factorio {old_fv}, this one is {engine_version()}: pass --old-factorio DIR "
                     f"(an unpacked Factorio {old_fv} with bin/ and data/, see tools/devcheck/README.md)")
        FACTORIO = Path(a.old_factorio).resolve()
        if engine_version() != old_fv:
            sys.exit(f"--old-factorio {a.old_factorio} is Factorio {engine_version()}, {a.from_ref} needs {old_fv}")
        if settings.exists():             # (a newer Factorio's mod-settings.dat: the old one does not read it)
            kept = settings.read_bytes()
            settings.unlink()
    prepare_mods(mod_dir=None if old == ROOT else old, with_migrate=True)
    if a.removed_items:                   # issue #503: the save holds the helper's three test items (migratemod/data.lua)
        startup_setting(ITEMS_SETTING, "old")
    print(f"old version: {a.from_ref}" + (f" (Factorio {old_fv}: {FACTORIO})" if FACTORIO != new_factorio else ""))
    try:
        log, err = create_map(WORK / "migrate-map.zip", *seed_args(a))
    finally:
        FACTORIO = new_factorio
        if kept is not None:
            settings.write_bytes(kept)
    if err:
        print("could not create the map with the old version:\n" + err)
        return 1
    setup = re.search(r"DEVCHECK-MIGRATE-SETUP (.*)", log)
    print(f"old save (every kind of block): {setup.group(1) if setup else 'no result'}")
    prepare_mods(mod_dir=bumped_tree() if a.bump else None, with_migrate=True)
    if a.removed_items:                   # one of them removed, one renamed through ME_NETWORK.replace_item
        startup_setting(ITEMS_SETTING, "new")
    log = factorio("--benchmark", str(WORK / "migrate-map.zip"), "--benchmark-ticks", str(a.ticks))
    ran = re.search(r"Performed (\d+) updates", log)
    # issue #146: a save from before the cut-off must be refused when it loads, with the message that names 0.5.0
    old_version = json.loads((old / "info.json").read_text(encoding="utf-8"))["version"]
    if tuple(int(n) for n in old_version.split(".")[:3]) < CUT_OFF:
        refused = "no longer converts saves from before 0.5.0" in log
        print(f"old save of {old_version} (before the cut-off {'.'.join(map(str, CUT_OFF))}) loaded with the working copy: "
              + ("refused with the message" if refused and not ran else "NOT REFUSED" if ran else "failed without the message"))
        if not refused:
            print(load_errors(log) or "")
        ok = setup and setup.group(1).startswith("ok") and refused and not ran
        print("\nRESULT: " + ("OK" if ok else "PROBLEMS FOUND"))
        return 0 if ok else 1
    print(f"old save loaded with the working copy{' (version one patch up: an update, on_configuration_changed runs)' if a.bump else ''}: {'ok, ' + ran.group(0) if ran else 'FAILED'}")
    unified = re.search(r"DEVCHECK-MIGRATE-UNIFIED (.*)", log)
    fluids = re.search(r"DEVCHECK-MIGRATE-FLUIDS (.*)", log)
    print(f"the blocks after the update: {unified.group(1) if unified else 'no result'}")
    print(f"the fluid after the I/O steps: {fluids.group(1) if fluids else 'no result'}")
    lif = re.search(r"DEVCHECK-MIGRATE-LIF (.*)", log)       # issue #537 (a version with the ME Logistic Interface)
    if lif:
        print(f"the ME Logistic Interface after the update: {lif.group(1)}")
    fails = re.findall(r"DEVCHECK-MIGRATE-FAIL (.*)", log)
    for f in fails:
        print("  - " + f)
    if not ran:
        print(load_errors(log) or "")
    ok = ran and setup and setup.group(1).startswith("ok") and unified and unified.group(1).startswith("ok") \
        and fluids and fluids.group(1).startswith("ok") and not fails
    if a.removed_items:
        # issue #503: after the update the network holds the renamed item under its new name (counts added up, quality kept), the
        # removed one nowhere, and every circuit interface (one built after the load too) works; the log names each name once
        items = re.search(r"DEVCHECK-MIGRATE-ITEMS (.*)", log)
        print(f"removed and renamed items: {items.group(1) if items else 'no result'}")
        want = {"devcheck-removed-item": "ME-REMOVED-ITEM devcheck-removed-item 30",
                "devcheck-renamed-item": "ME-REPLACED-ITEM devcheck-renamed-item devcheck-new-item 45"}
        lines = {n: re.findall(rf"ME-(?:REMOVED|REPLACED)-ITEM {n} [^\r\n]*", log) for n in want}
        logged = all(lines[n] == [want[n]] for n in want)
        print(f"the log lines of the update: {'ok' if logged else 'failed'} ({'; '.join(l for n in want for l in lines[n]) or 'none'})")
        ok = ok and items and items.group(1).startswith("ok") and logged
    print("\nRESULT: " + ("OK" if ok else "PROBLEMS FOUND"))
    return 0 if ok else 1


# --------------------------------------------------------------------------------------------
# bench: synthetic bases (benchmod/), timed with --benchmark-verbose (issue #5, docs/PERFORMANCE.md)
# --------------------------------------------------------------------------------------------

BENCH_WARMUP = 600
BENCH_SAMPLE_TICKS, BENCH_STEADY_TICKS = 300, 1200      # (benchmod/control.lua SAMPLE_TICKS, STEADY_TICKS)
# issue #56: `--check` measures sizes from CHECK_LONG_SIZE with this window (without --ticks): the refill transient of about
# 2000 ticks at 20 000 is a small part of it, so its position no longer moves the 99th percentile
CHECK_LONG_SIZE, CHECK_LONG_TICKS = 20000, 10800
LATENCY_TICKS = 3700            # after the window: the latency probes (time out after 3600 ticks)
BURST_TICKS = 330               # after the latency probes: the build burst (build, remove, plain build, plain remove, issue #538: ghosts)
GHOST_WAIT = 600                # issue #538: the ghost paste waits for the allocation meter's ticks (ALLOC_FROM + ALLOC_TICKS)
SLICE_TICKS = 5 * 60 * 60       # the long run reports per 5 minutes
# the functions the profile times, per module of the instrumented copy (local functions through their upvalue,
# M.<name> through the module table, and the handler tables of the storage bus)
PROFILE_WRAP = {
    "scripts/fork-me-network.lua": ["M.insert", "M.extract", "M.can_insert", "M.insert_partial", "M.insert_stack",
                                    "M.extract_to", "M.insert_fluid", "M.extract_fluid", "M.can_insert_fluid",
                                    "M.ext_sync", "M.contents", "M.plain_counts", "M.fluid_contents", "M.storable",
                                    "M.slow_step", "M.stats", "insert_key", "extract_key", "room_for", "ordered",
                                    "recompute", "draw_leds", "add_node", "remove_node_graph", "update_power",
                                    "lookups", "holders", "extract_order", "moved_key", "M.on_built", "M.on_removed",
                                    "M.active_of", "M.network_of", "M.usable", "M.count_key", "components", "changed",
                                    "fire_all_waits", "take_waits", "remove_node", "net_cell", "M.wait_for", "put", "put_open", "cell_room", "cell_add",
                                    "idx_add", "holders", "drop_holders", "M.storable", "arrive", "M.on_arrival"],
    "scripts/fork-me-io.lua": ["M.interface_step", "M.bus_step", "M.fluid_bus_step", "import_items", "export_items",
                               "interface_sides", "tank_to_network", "export_side", "target_of", "ensure_tanks",
                               "M.on_tick", "visit", "probe", "probe_work", "probe_mark", "stack_of", "when",
                               "M.on_built", "M.on_removed", "config_of", "by_count", "drop", "wake", "destroy_tanks"],
    "scripts/fork-me-storagebus.lua": ["M.visit", "M.on_step", "M.on_tick", "resolve", "ITEM.room", "ITEM.insert",
                                       "ITEM.count", "ITEM.extract", "M.on_built", "M.on_removed", "inventory_of"],
    "scripts/fork-me-fluid-storagebus.lua": ["M.visit", "M.on_step", "M.on_tick", "claim", "contents_of", "M.handlers.room",
                                             "M.handlers.insert", "M.handlers.count", "M.handlers.extract"],
    # issue #506: the ME Logistic Storage Bus
    "scripts/fork-me-logistic-storagebus.lua": ["M.visit", "M.on_tick", "claim", "read", "HANDLER.room", "HANDLER.insert",
                                                "HANDLER.count", "HANDLER.extract"],
    # issue #531: the ME Logistic Interface
    "scripts/fork-me-logistic-interface.lua": ["M.on_tick", "visit", "pull", "offer", "request", "ensure_chests", "offered_in",
                                               "reserved",
                                               # issue #537: the automatic mode
                                               "demand_step", "scan_point", "scan_key", "decide", "auto_request",
                                               "auto_blocks", "me_waits"],
    # issue #538: what construction needs
    "scripts/fork-me-logistic-construction.lua": ["M.on_built", "M.on_object_destroyed", "M.on_tick", "track", "put", "drop",
                                                  "needs_of", "lid_of", "rescan_cell"],
    "scripts/fork-me-autocraft.lua": ["job_step", "maintenance", "scan_provider", "refresh_providers",
                                      "rebuild_patterns", "make_plan", "M.start", "assign_cpus", "await_index",
                                      "on_arrival", "awaiting", "cpus_in", "collect_output", "find_crafter",
                                      "start_lease", "close_lease", "flush_pool", "M.active_job_for", "M.free_slot",
                                      "M.job", "prune_finished", "job_network", "stock_of", "machine_idle", "M.on_tick",
                                      "groups_in", "pick_cpu", "add_block", "remove_block", "settle_group",
                                      "plan_bytes", "group_network",
                                      "step_jobs", "rescan_plan", "snapshot", "need", "apply_pattern", "M.plan",
                                      "M.on_built", "M.on_removed", "cpu_powered", "set_wait", "shallow", "step_ingredients",
                                      "step_products", "ensure_patterns", "job_ops", "release_lease", "take_back_input",
                                      "fluid_batch_limit", "find_pusher", "pool_add", "release_cpu", "key_of", "job_step_of"],
    "scripts/fork-me-circuit.lua": ["on_step", "on_tick", "maintainer_step", "circuit_step", "network_signals",
                                    "signals_of", "visit_maintainer", "visit_circuit"],
    "scripts/fork-me-schedule.lua": ["M.run", "M.at", "M.wake", "M.park", "M.headroom", "M.forget", "M.slot"],
    "scripts/fork-me-gui.lua": ["M.refresh_all"],
    "scripts/fork-me-terminal.lua": ["M.entries"],
}
# values captured at load time that must point at the wrapped function
PROFILE_REPOINT = {
    "scripts/fork-me-autocraft.lua": "N.on_arrival = on_arrival\nN.awaiting = awaiting\n",
}
# the columns of --benchmark-verbose all that the report uses (ns per tick)
TIMING_COLS = ("wholeUpdate", "gameUpdate", "entityUpdate", "electricNetworkUpdate", "fluidFlowUpdate",
               "logisticManagerUpdate", "luaGarbageIncremental", "scriptUpdate")


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
    try:                                  # (issue #487: in the version of the Factorio in use; an older one refuses a newer file)
        full = json.loads((FACTORIO / "data" / "base" / "info.json").read_text(encoding="utf-8"))["version"]
        version = tuple(int(x) for x in full.split(".")[:3]) + (0,)
    except (OSError, ValueError, KeyError):
        pass
    glob = {k: v for k, v in (root.get("runtime-global") or {}).items() if not k.startswith(NAME + "-")}
    for k, v in values.items():
        glob[k] = {"value": ("int", 6, int(v))}
    root.setdefault("startup", {})
    root["runtime-global"] = glob
    root.setdefault("runtime-per-user", {})
    f.write_bytes(_tree_write(version, root))


def startup_setting(name, value):
    """issue #503: a startup setting of a helper mod in mod-settings.dat (`value` None: removed, the default again)"""
    f = MODS / "mod-settings.dat"
    version, root = _tree_read(f.read_bytes()) if f.exists() else ((2, 0, 0, 0), {})
    root = root or {}
    try:                                  # (in the version of the Factorio in use, as runtime_settings)
        full = json.loads((FACTORIO / "data" / "base" / "info.json").read_text(encoding="utf-8"))["version"]
        version = tuple(int(x) for x in full.split(".")[:3]) + (0,)
    except (OSError, ValueError, KeyError):
        pass
    startup = root.get("startup") or {}
    if value is None:
        startup.pop(name, None)
    else:
        startup[name] = {"value": value}
    root["startup"] = startup
    root.setdefault("runtime-global", {})
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
    lines = ["return {"] + [f"  {k} = {lua(v)}," for k, v in cfg.items() if v is not None] + ["}"]
    (dest / "config.lua").write_text("\n".join(lines) + "\n", encoding="utf-8")
    fit_info(dest)                        # (issue #487: the 2.0 numbers come from a 2.0 Factorio)
    return dest


def instrumented_copy(src=None):
    """a copy of the working tree (or of `src`, an older version) in .devcheck/bench-profile whose functions are timed
    (benchmod/profile.lua)"""
    dest = WORK / "bench-profile"
    if dest.exists():
        shutil.rmtree(dest)
    # (every work folder is left out: .devcheck2 and the like hold junctions into the Steam install and into this tree)
    shutil.copytree(src or ROOT, dest, symlinks=True,
                    ignore=shutil.ignore_patterns(".git", ".devcheck*", "dist", "tools", "docs", "*.zip", "__pycache__"))
    for rel, names in PROFILE_WRAP.items():
        f = dest / rel
        if not f.exists():
            continue
        src = f.read_text(encoding="utf-8")
        mod = Path(rel).stem.replace("fork-me-", "")
        lines = []
        for name in names:
            last = re.escape(name.split(".")[-1])
            if "." in name:                                   # M.f, or a field of a handler table
                found = re.search(r"^function " + re.escape(name) + r"\(|^\s*" + last + r" = function\(", src, re.M)
            else:                                             # a local function (or a forward declared local)
                found = re.search(r"^local function " + last + r"\(|^local " + last + r"$|^function " + last + r"\(", src, re.M)
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


def tick_rows(log):
    """per tick the columns of --benchmark-verbose all (ms): {tick: {column: ms}}"""
    head = re.search(r"^tick,timestamp,(.*)$", log, re.M)
    if not head:
        return {}
    cols = head.group(1).rstrip(",").split(",")
    want = {c: cols.index(c) for c in TIMING_COLS if c in cols}
    rows = {}
    for m in re.finditer(r"^t(\d+),\d+,(.*)$", log, re.M):
        vals = m.group(2).rstrip(",").split(",")
        rows[int(m.group(1))] = {c: int(vals[i]) / 1e6 for c, i in want.items()}
    return rows


def sample_ticks(first, last):
    """issue #56: the ticks inside a window where the benchmark mod itself works (benchmod SAMPLE_TICKS: the backlogs, a walk
    over every block record with the versions that have it; STEADY_TICKS: the scheduler's counters); not part of the timing,
    like the probe ticks at the window's ends"""
    return {t for t in range(first, last + 1) if t % BENCH_SAMPLE_TICKS == 0} | {BENCH_WARMUP + BENCH_STEADY_TICKS}


def window_timings(rows, first, last, skip=None):
    """the columns of the ticks first..last as lists (without the ticks in `skip`)"""
    out = {c: [] for c in TIMING_COLS}
    for t in range(first, last + 1):
        if skip and t in skip:
            continue
        r = rows.get(t)
        if r:
            for c, v in r.items():
                out[c].append(v)
    return {c: v for c, v in out.items() if v}


def stat(values):
    if not values:
        return {}
    s = sorted(values)
    return {"avg": sum(s) / len(s), "max": s[-1], "p99": s[min(len(s) - 1, int(len(s) * 0.99))],
            "over5": sum(1 for v in s if v > 5.0), "sum": sum(s)}


def median(values):
    """the true median: the middle value, or the mean of the two middle values of an even number"""
    v = sorted(x for x in values if x is not None)
    if not v:
        return None
    n = len(v)
    return v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2


def load_report(log, rows):
    """the load: the wall time from `Loading map` to the scripts' checksums, and the script time of the first ticks
    after the load (the scheduler's queues and the lookups come up lazily)"""
    out = {}
    start = re.search(r"^\s*([\d.]+) Loading map", log, re.M)
    end = [m.group(1) for m in re.finditer(r"^\s*([\d.]+) Checksum for script", log, re.M)]
    if start and end:
        out["load_s"] = float(end[-1]) - float(start.group(1))
    first = [rows[t]["scriptUpdate"] for t in range(0, 60) if t in rows and "scriptUpdate" in rows[t]]
    if first:
        out.update({"tick0_ms": first[0], "tick1_ms": first[1] if len(first) > 1 else None,
                    "first_second_ms": sum(first), "first_second_max_ms": max(first)})
    return out


def burst_report(log, rows):
    """the build burst: per step the time of the loop (profiler) and the script and whole update of its tick"""
    out = {}
    for m in re.finditer(r"DEVCHECK-BENCH-BURST (\S+) (\d+) (\d+) Duration: ([\d.]+)ms", log):
        what, n, tick, ms = m.group(1), int(m.group(2)), int(m.group(3)), float(m.group(4))
        r = rows.get(tick, {})
        out[what] = {"n": n, "tick": tick, "ms": ms, "script_ms": r.get("scriptUpdate"), "whole_ms": r.get("wholeUpdate")}
    return out


def plan_report(log):
    plans = [{"key": m.group(1), "depth": int(m.group(2)), "amount": int(m.group(3)), "steps": int(m.group(4)),
              "runs": int(m.group(5)), "missing": int(m.group(6)), "status": m.group(7), "ms": float(m.group(8)),
              "missing_keys": m.group(9).strip()}
             for m in re.finditer(r"DEVCHECK-BENCH-PLAN (\S+) depth (\d+) amount (\d+) steps (-?\d+) runs (-?\d+) "
                                  r"missing (\d+) (\S+) Duration: ([\d.]+)ms(.*)", log)]
    fails = [{"key": m.group(1), "depth": int(m.group(2)), "amount": int(m.group(3)), "steps": int(m.group(4)),
              "runs": int(m.group(5)), "missing": int(m.group(6)), "status": m.group(7), "ms": float(m.group(8)),
              "without": m.group(9).strip()}
             for m in re.finditer(r"DEVCHECK-BENCH-PLAN-FAIL (\S+) depth (\d+) amount (\d+) steps (-?\d+) runs (-?\d+) "
                                  r"missing (\d+) (\S+) Duration: ([\d.]+)ms without (.*)", log)]
    starts = [{"key": m.group(1), "status": m.group(2), "ms": float(m.group(3))}
              for m in re.finditer(r"DEVCHECK-BENCH-PLAN-START (\S+) (\S+) Duration: ([\d.]+)ms", log)]
    ignored = bench_json(log, "PLANNER")
    kept = {(m.group(1), int(m.group(2))): float(m.group(3))
            for m in re.finditer(r"DEVCHECK-BENCH-PLAN-KEPT (\S+) amount (\d+) Duration: ([\d.]+)ms", log)}
    for pl in plans:
        pl["kept_ms"] = kept.get((pl["key"], pl["amount"]))
    stock = bench_json(log, "PLANSTOCK")
    digests = {f"{m.group(1)} {m.group(2)}": m.group(3) for m in re.finditer(r"DEVCHECK-BENCH-PLANDIGEST (\S+) (\d+) (.*)", log)}
    return {"plans": plans, "fails": fails, "starts": starts, "stock": stock[0] if stock else None, "digests": digests, "ignored": ignored[0].get("ignored") if ignored else None}


# the scene at the maintainer's size (issue #50, #51): `--sizes base` is one network of 2158 members (1767 cables and two
# underground cables, 189 interfaces and buses, 184 storage buses, 8 drives, 7 terminals), the mix of the ME scene
# scaled to its 189 interfaces and buses, no providers, maintainers, circuit interfaces or CPUs
BASE_SIZE = 189


def parse_sizes(text):
    return [x if x == "base" else int(x) for x in (text or "").split(",") if x]


def size_variant(size):
    """(the size of the ME scene, its variant) of a `--sizes` entry"""
    return (BASE_SIZE, {"base": True}) if size == "base" else (size, {})


def variant_name(v):
    parts = []
    if v.get("base"):
        parts.append("base")
    if v.get("idle"):
        parts.append("idle")
    if v.get("networks", 1) > 1:
        parts.append(f"net{v['networks']}")
    if v.get("noent"):
        parts.append("noent")
    if v.get("long"):
        parts.append("long")
    return "-".join(parts)


def bench_config(a, scene, size, variant, profile):
    window = a.long * 3600 if variant.get("long") else a.ticks
    cfg = {"scene": scene, "size": size, "warmup": BENCH_WARMUP, "window": window,
           "latency": scene == "me" and not profile and not variant.get("noent") and not variant.get("long"),
           "profile": profile, "alloc": bool(profile and getattr(a, "alloc", False)), "idle": bool(variant.get("idle")), "networks": variant.get("networks", 1),
           "exclusive": bool(profile and getattr(a, "exclusive", False)),
           "noent": bool(variant.get("noent")), "base": bool(variant.get("base")),
           "burst": 0 if (variant.get("long") or variant.get("noent") or variant.get("base") or scene != "me") else a.burst,
           "slice": (SLICE_TICKS if window >= 2 * SLICE_TICKS else max(300, window // 2 // 300 * 300)) if variant.get("long") else None,
           "planner_targets": a.planner_targets,
           # issue #506: a logistic network of that many roboports below the ME scene, with an ME Logistic Storage Bus
           "logistic": (getattr(a, "logistic", 0) or 0) if scene == "me" else 0,
           # issue #537: that many requester chests in the logistic network (for the ME Logistic Interface's automatic mode)
           "requesters": (getattr(a, "requesters", 0) or 0) if scene == "me" else 0,
           # issue #538: that many wall ghosts pasted in one tick (and removed in one) in that logistic network, after the burst
           "ghosts": (getattr(a, "ghosts", 0) or 0) if scene == "me" else 0}
    return cfg


def bench_map(a, cfg, mod_dir, mapfile, gregtorio=None):
    """the map of one scene, made with `mod_dir` (None: the working copy); returns (result skeleton, error)"""
    prepare_mods(mod_dir=mod_dir, bench_dir=bench_mod_dir(cfg), gregtorio=gregtorio,
                 with_mods=getattr(a, "with_mod", None) or ())
    runtime_settings({k: int(v) for k, v in (x.split("=", 1) for x in a.set or [])})
    log, err = create_map(mapfile, *seed_args(a))
    setup = bench_json(log, "SETUP")
    build = re.search(r"DEVCHECK-BENCH-BUILD (.*)", log)
    if err or not setup:
        return None, err or "no DEVCHECK-BENCH-SETUP line"
    machine = re.search(r"System info: \[(.*?)\]", log)
    strip = re.search(r"DEVCHECK-BENCH-STRIP (\d+)", log)
    out = {"scene": cfg["scene"], "size": cfg["size"], "variant": {k: cfg[k] for k in ("idle", "networks", "noent", "base")},
           "setup": setup[0], "build": build.group(1) if build else None, "save_bytes": Path(mapfile).stat().st_size,
           "runs": [], "machine": machine.group(1) if machine else None, "window": cfg["window"],
           "stripped": int(strip.group(1)) if strip else None}
    return out, None


def bench_run(a, cfg, mod_dir, mapfile, profile=False, gregtorio=None, label=""):
    """one --benchmark run of a made map; returns the parsed run or None"""
    prepare_mods(mod_dir=mod_dir, bench_dir=bench_mod_dir(cfg), gregtorio=gregtorio,
                 with_mods=getattr(a, "with_mod", None) or ())
    # (issue #487: mod-settings.dat in the version of the Factorio of this run: the 2.0 reference of --ref-factorio does
    # not read the file a 2.1 run wrote)
    runtime_settings({k: int(v) for k, v in (x.split("=", 1) for x in a.set or [])})
    window = cfg["window"]
    ticks = BENCH_WARMUP + window + (LATENCY_TICKS if cfg["latency"] else 30) + (BURST_TICKS if cfg["burst"] else 0) \
        + (GHOST_WAIT if cfg.get("ghosts") else 0)
    log = factorio("--benchmark", str(mapfile), "--benchmark-ticks", str(ticks), "--benchmark-verbose", "all")
    if not re.search(r"Performed (\d+) updates", log):
        print(f"  {label}: did not run\n{load_errors(log) or ''}")
        (WORK / f"bench-failed-{Path(mapfile).stem}.log").write_text(log, encoding="utf-8")
        return None
    rows = tick_rows(log)
    first, last = BENCH_WARMUP + 2, BENCH_WARMUP + window - 3
    tm = window_timings(rows, first, last, sample_ticks(first, last))
    run = {"timing": {c: stat(v) for c, v in tm.items()},
           "throughput": (bench_json(log, "THROUGHPUT") or [None])[0],
           "latency": (bench_json(log, "LATENCY") or [None])[0],
           "jobs": (bench_json(log, "JOBS") or [None])[0],
           "service": (bench_json(log, "SERVICE") or [None])[0],
           "alloc": (bench_json(log, "ALLOC") or [None])[0],
           "load": load_report(log, rows),
           "burst": burst_report(log, rows),
           "done": "DEVCHECK-BENCH-DONE" in log,
           "errors": re.findall(r"(Error.*|non-recoverable.*)", log)[:3]}
    if cfg["scene"] == "planner":
        run["plan"] = plan_report(log)
    if cfg.get("slice"):
        slices = bench_json(log, "SLICE")
        run["slices"] = []
        for k, sl in enumerate(slices):
            first = BENCH_WARMUP + k * cfg["slice"] + 2
            tms = window_timings(rows, first, sl["tick"] - 1, sample_ticks(first, sl["tick"] - 1))
            run["slices"].append({"tick": sl["tick"], "memory_kb": sl.get("memory_kb"), "backlogs": sl.get("backlogs"),
                                  "timing": {c: stat(v) for c, v in tms.items()}})
    if profile:
        run["profile"] = [(m.group(1), int(m.group(2)), float(m.group(3)))
                          for m in re.finditer(r"DEVCHECK-BENCH-PROF (\S+) (\d+) Duration: ([\d.]+)ms", log)]
        run["alloc"] = [(m.group(1), int(m.group(2)), float(m.group(3)))
                        for m in re.finditer(r"DEVCHECK-BENCH-ALLOC (\S+) (\d+) ([\d.]+)", log)]
        ov = re.search(r"DEVCHECK-BENCH-PROF-OVERHEAD wrapped Duration: ([\d.]+)ms plain Duration: ([\d.]+)ms", log)
        run["overhead_us"] = (float(ov.group(1)) - float(ov.group(2))) * 1000 if ov else None
        run["engine"] = [(m.group(1), int(m.group(2)), float(m.group(3)))
                         for m in re.finditer(r"DEVCHECK-BENCH-ENGINE (.+?) (\d+) Duration: ([\d.]+)ms", log)]
    sc = run["timing"].get("scriptUpdate", {})
    print(f"  {label}: script {sc.get('avg', 0):.3f} ms/tick avg, {sc.get('p99', 0):.2f} p99, {sc.get('max', 0):.2f} max")
    return run


def bench_scene(a, scene, size, profile=False, variant=None):
    """create the map of one scene and run it (a.runs times, once with --profile); returns the parsed results"""
    variant = variant or {}
    cfg = bench_config(a, scene, size, variant, profile)
    old = a.old_dir                                       # bench --from-ref: an older version of the mod
    mod_dir = instrumented_copy(old) if profile else old
    name = variant_name(variant)
    mapfile = WORK / f"bench-{scene}-{size}{'-' + name if name else ''}{'-profile' if profile else ''}.zip"
    label = f"{scene} {size}{' ' + name if name else ''}"
    out, err = bench_map(a, cfg, mod_dir, mapfile, gregtorio=a.with_gregtorio)
    if err:
        print(f"  {label}: the map was not created\n{err}")
        return None
    for r in range(1 if profile else a.runs):
        run = bench_run(a, cfg, mod_dir, mapfile, profile, gregtorio=a.with_gregtorio,
                        label=f"{label} run {r + 1}{' (profile)' if profile else ''}")
        if not run:
            return out
        out["runs"].append(run)
    return out


def med_tree(dicts):
    """the median per leaf over a list of dicts of the same shape (numbers; other values from the first)"""
    dicts = [d for d in dicts if d]
    if not dicts:
        return None
    out = {}
    for k in dicts[0]:
        vals = [d.get(k) for d in dicts if isinstance(d, dict)]
        if isinstance(dicts[0][k], dict):
            out[k] = med_tree([v for v in vals if isinstance(v, dict)])
        elif isinstance(dicts[0][k], (int, float)) and not isinstance(dicts[0][k], bool):
            out[k] = median([v for v in vals if isinstance(v, (int, float))])
        else:
            out[k] = dicts[0][k]
    return out


def summarize(res):
    """the median over the runs of a scene"""
    runs = [r for r in res["runs"] if r["timing"]]
    def med(col, key):
        return median([r["timing"].get(col, {}).get(key) for r in runs])
    s = {"scene": res["scene"], "size": res["size"], "variant": res.get("variant") or {}, "runs": len(runs),
         "save_mb": res["save_bytes"] / 1e6, "stripped": res.get("stripped"),
         "script_avg": med("scriptUpdate", "avg"), "script_max": med("scriptUpdate", "max"),
         "script_p99": med("scriptUpdate", "p99"), "script_over5": med("scriptUpdate", "over5"),
         "gc_avg": med("luaGarbageIncremental", "avg"), "gc_max": med("luaGarbageIncremental", "max"),
         "whole_avg": med("wholeUpdate", "avg"),
         "entity_avg": med("entityUpdate", "avg"), "electric_avg": med("electricNetworkUpdate", "avg"),
         "fluid_avg": med("fluidFlowUpdate", "avg"), "logistic_avg": med("logisticManagerUpdate", "avg")}
    if s["whole_avg"] is not None and s["script_avg"] is not None:
        s["engine_avg"] = s["whole_avg"] - s["script_avg"]
    tp = [r["throughput"] for r in runs if r["throughput"]]
    s["throughput"] = tp[0] if tp else None
    lat = [r["latency"] for r in runs if r["latency"]]
    if lat:
        s["latency"] = {k: {"median_s": median([l[k]["median_s"] for l in lat]), "max_s": median([l[k]["max_s"] for l in lat]),
                            "n": lat[0][k]["n"], "timeouts": max(l[k]["timeouts"] for l in lat)} for k in lat[0]}
    s["service"] = med_tree([r.get("service") for r in runs])
    s["load"] = med_tree([r.get("load") for r in runs])
    s["burst"] = med_tree([r.get("burst") for r in runs])
    plans = [r.get("plan") for r in runs if r.get("plan")]
    if plans:
        s["plan"] = plans[0]
        for i, pl in enumerate(s["plan"]["plans"]):
            pl["ms"] = median([q["plan"]["plans"][i]["ms"] for q in runs if q.get("plan") and i < len(q["plan"]["plans"])])
        for i, pl in enumerate(s["plan"].get("fails") or []):
            pl["ms"] = median([q["plan"]["fails"][i]["ms"] for q in runs if q.get("plan") and i < len(q["plan"].get("fails") or [])])
    sl = [r.get("slices") for r in runs if r.get("slices")]
    if sl:
        s["slices"] = sl[0]
    return s


def scene_problems(scene, size, res, wanted=None):
    problems = []
    name = variant_name(res.get("variant") or {})
    scene = f"{scene} {name}" if name else scene
    if wanted is not None and len(res["runs"]) < wanted:
        problems.append(f"{scene} {size}: only {len(res['runs'])} of {wanted} runs ran")
    for r in res["runs"]:
        if not r["done"]:
            problems.append(f"{scene} {size}: a run did not finish")
        if r["errors"]:
            problems.append(f"{scene} {size}: {r['errors'][0]}")
        if r.get("jobs") and r["jobs"]["failed"]:
            problems.append(f"{scene} {size}: jobs not started: {r['jobs']['failed'][:3]}")
        for q, st in (((r.get("service") or {}).get("sched")) or {}).items():
            if st.get("missed"):
                problems.append(f"{scene} {size}: {st['missed']} missed wakes in the {q} queue (a parked block found work at its fallback visit)")
        tp = r.get("throughput")
        if tp and tp.get("conservation") and tp["conservation"]["problems"]:
            problems.append(f"{scene} {size}: conservation: {tp['conservation']['problems']} keys differ, "
                            f"{tp['conservation']['first'][:2]}")
    if res["setup"].get("fails"):
        problems.append(f"{scene} {size}: setup problems: {res['setup']['fails'][:3]}")
    return problems


def compare_plans(a):
    """`--compare-plans REF` (issue #50): the planner scene with that version and with the working copy, one run each; every
    plan of its sample (the deepest items and every n-th item of the chain of usable patterns, amounts 1 and 37: fresh plans,
    never a kept one) must be the same: ok, missing, taken from storage, the patterns and their order, runs, loops, bytes.
    Issue #50, lever 6: also what the scan finds at every provider (`provider-N 0`: pattern id, ok, reason and machines per
    slot) and the network's ignored patterns by reason."""
    ref_dir = old_tree(a.compare_plans)
    digests = {}
    for tag, mod_dir in (("ref", ref_dir), ("wc", None)):
        res = bench_scene(argparse.Namespace(**{**vars(a), "runs": 1, "old_dir": mod_dir}), "planner", 0)
        if not res or not res["runs"] or not res["runs"][0].get("plan"):
            print(f"  {tag}: the planner scene did not run")
            return 1
        plan = res["runs"][0]["plan"]
        digests[tag] = dict(plan.get("digests") or {})
        digests[tag]["ignored"] = json.dumps(plan.get("ignored"), sort_keys=True)
    ref, wc = digests["ref"], digests["wc"]
    diff = [k for k in sorted(set(ref) | set(wc)) if ref.get(k) != wc.get(k)]
    scans = sum(1 for k in ref if k.startswith("provider-"))
    print(f"\nplans compared with {a.compare_plans}: {len(ref)} of the reference ({scans} provider scans and the ignored patterns among "
          f"them), {len(wc)} of the working copy, {len(diff)} differ")
    for k in diff[:10]:
        print(f"  {k}:\n    ref {ref.get(k)}\n    wc  {wc.get(k)}")
    ok = not diff and len(ref) > 0 and len(ref) == len(wc)
    print("\nRESULT:", "OK" if ok else "PROBLEMS FOUND")
    return 0 if ok else 1


def bench(a):
    with_mods(a)
    if a.check:
        return bench_check(a)
    if getattr(a, "compare_plans", None):
        return compare_plans(a)
    sizes = parse_sizes(a.sizes)
    results = {"factorio": (factorio("--version").splitlines() or ["?"])[0], "scenes": [], "profiles": [],
               "window": a.ticks, "ref": a.from_ref or "working copy", "gregtorio": a.with_gregtorio,
               "exclusive": bool(getattr(a, "exclusive", False))}
    a.old_dir = old_tree(a.from_ref) if a.from_ref else None
    print("mod:", results["ref"])
    print(results["factorio"])
    problems = []
    plan = []                                              # (scene, size, variant)
    if not a.planner_only:
        for scene in ["me"] + (["inserters", "robots"] if a.reference else []):
            for entry in sizes:
                size, base = size_variant(entry)
                if base and scene != "me":
                    continue
                plan.append((scene, size, dict(base)))
                if scene == "me":
                    if a.idle:
                        plan.append((scene, size, {**base, "idle": True}))
                    for k in [int(x) for x in (a.networks or "").split(",") if x]:
                        plan.append((scene, size, {**base, "networks": k}))
                    if a.engine_share:
                        plan.append((scene, size, {**base, "noent": True}))
        if a.long:
            plan.append(("me", max(x for x in sizes if x != "base"), {"long": True}))
    if a.planner or a.planner_only:
        plan.append(("planner", 0, {}))
    for scene, size, variant in plan:
        runs_before = a.runs
        if variant.get("long"):
            a.runs = 1
        res = bench_scene(a, scene, size, variant=variant)
        a.runs = runs_before
        if not res:
            problems.append(f"{scene} {size} {variant_name(variant)}: no map")
            continue
        s = summarize(res)
        s["setup"] = res["setup"]
        s["build"] = res["build"]
        results["machine"] = res["machine"]
        results["scenes"].append(s)
        problems += scene_problems(scene, size, res, 1 if variant.get("long") else a.runs)
    for entry in parse_sizes(a.profile):
        size, base = size_variant(entry)
        res = bench_scene(a, "me", size, profile=True, variant=base)
        if res and res["runs"]:
            results["profiles"].append({"size": size, **res["runs"][0]})
        else:
            problems.append(f"profile {size}: did not run")
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


def ticks_s(v):
    return "-" if v is None else f"{v / 60:.2f}"


def scene_label(s):
    name = variant_name(s.get("variant") or {})
    return f"{s['scene']}{' ' + name if name else ''}"


def print_service(s):
    sv = s.get("service")
    if not sv:
        return
    sched = sv.get("sched") or {}
    secs = s.get("window", 3600) / 60 if isinstance(s.get("window"), (int, float)) else None
    print(f"  {scene_label(s)} {s['size']}: mod heap {fmt(sv.get('memory_kb'), 0)} kB, alive after a collection {fmt(sv.get('live_kb'), 0)} kB")
    print(f"    {'queue':18} {'visits/tick':>11} {'due/tick':>9} {'backlog avg':>11} {'backlog max':>11} "
          f"{'busy interval s: median':>23} {'p99':>7} {'max':>7} {'n':>7} | {'idle interval s: median':>23} {'p99':>7} {'max':>7} {'n':>7}")
    for q in ("io", "io_probe", "storage_bus", "storage_bus_probe", "fluid_storage_bus", "fluid_storage_bus_probe",
              "logistic_storage_bus", "logistic_storage_bus_probe",                   # (issue #506)
              "logistic_interface", "logistic_interface_probe", "logistic_demand",  # (issue #531, #537)
              "maintainer", "maintainer_probe", "circuit", "jobs"):
        st = sched.get(q)
        if not st or not (st.get("visits") or st.get("due")):
            continue
        ticks = st.get("ticks") or 0
        full, part, idle = st.get("full") or {}, st.get("partial") or {}, st.get("idle") or {}
        busy = full if (full.get("n") or 0) >= (part.get("n") or 0) else part
        if q == "jobs":
            busy = part
        print(f"    {q:18} {fmt((st.get('visits') or 0) / ticks if ticks else None, 2):>11} "
              f"{fmt((st.get('due') or 0) / ticks if ticks else None, 2):>9} {fmt(st.get('backlog_avg'), 1):>11} "
              f"{fmt(st.get('backlog_max'), 0):>11} {ticks_s(busy.get('median')):>23} {ticks_s(busy.get('p99')):>7} "
              f"{ticks_s(busy.get('max')):>7} {fmt(busy.get('n'), 0):>7} | {ticks_s(idle.get('median')):>23} "
              f"{ticks_s(idle.get('p99')):>7} {ticks_s(idle.get('max')):>7} {fmt(idle.get('n'), 0):>7}")
        if q == "io" and full.get("n") and part.get("n"):
            print(f"    {'  io, moved all it could':18} {'':>11} {'':>9} {'':>11} {'':>11} {ticks_s(full.get('median')):>23} "
                  f"{ticks_s(full.get('p99')):>7} {ticks_s(full.get('max')):>7} {fmt(full.get('n'), 0):>7} | "
                  f"{'(moved some)':>23} {ticks_s(part.get('median')):>7} {ticks_s(part.get('p99')):>7} {fmt(part.get('n'), 0):>7}")
    io = sched.get("io") or {}
    if "starved" in io:
        steady = sv.get("io_steady") or {}
        out = io.get("out") or {}
        print(f"    io starved arrivals (a visit found its target empty or its source full): {fmt(io.get('starved'), 0)} in the window"
              + (f", {fmt(steady.get('starved'), 0)} in its last {fmt((steady.get('ticks') or 0) / 60, 0)} s" if steady else "")
              + (f"; the other side out for (by the rate of the visit before) median {fmt(out.get('median'), 0)}, longest "
                 f"{fmt(out.get('max'), 0)} ticks, {fmt(out.get('n'), 0)} arrivals; {fmt(io.get('sooner'), 0)} ran out sooner than that rate"
                 if "sooner" in io else ""))
    blocks = sv.get("blocks") or {}
    if blocks.get("io_units"):
        kinds = blocks.get("io_kinds") or {}
        why = ", ".join(f"{k.split(':', 1)[1]} {int(v)}" for k, v in sorted(kinds.items()))
        print(f"    blocks at the window end: {int(blocks.get('io_units', 0))} interfaces and buses: busy {int(blocks.get('io_busy', 0))}, "
              f"probing {int(blocks.get('io_probing', 0))}, parked {int(blocks.get('io_parked', 0))} ({why}); "
              f"storage buses busy {int(blocks.get('storage_bus_busy', 0))}, probing {int(blocks.get('storage_bus_probing', 0))}; "
              f"maintainers busy {int(blocks.get('maintainer_busy', 0))}, probing {int(blocks.get('maintainer_probing', 0))} "
              f"of {int(blocks.get('maintainer_units', 0))}")
    samples = sv.get("backlog_samples") or []
    if samples:
        print("    backlog over the window (io / storage bus / fluid storage bus / maintainer / circuit), one sample per 5 s:")
        print("      " + "  ".join(f"{int(x.get('io', 0))}/{int(x.get('storage_bus', 0))}/{int(x.get('fluid_storage_bus', 0))}/"
                                   f"{int(x.get('maintainer', 0))}/{int(x.get('circuit', 0))}" for x in samples))
    for group, m in sorted((sv.get("machines") or {}).items()):
        print(f"    machines ({group}): {fmt(m.get('n'), 0)}, working {fmt(m.get('working'), 0)}, waiting for ingredients "
              f"{fmt(m.get('no_ingredients'), 0)}, output full {fmt(m.get('full_output'), 0)}, other {fmt(m.get('other'), 0)}; "
              f"crafts {fmt(m.get('crafts'), 0)} of {fmt(m.get('possible'), 0)} possible = {fmt((m.get('utilisation') or 0) * 100, 1)} %")


def print_bench(results):
    print(f"\nmachine: {results.get('machine')}")
    print("script time per tick (ms, median of the runs; window without the probe ticks):")
    print(f"  {'scene':14} {'size':>5} {'avg':>7} {'p99':>7} {'max':>7} {'>5ms':>5} {'gc avg':>7} {'gc max':>7} {'whole avg':>9} "
          f"{'engine':>7} {'entity':>7} {'electr.':>7} {'fluid':>7} {'save MB':>7}")
    for s in results["scenes"]:
        print(f"  {scene_label(s):14} {s['size']:>5} {fmt(s['script_avg']):>7} {fmt(s['script_p99']):>7} "
              f"{fmt(s['script_max'], 2):>7} {fmt(s['script_over5'], 0):>5} {fmt(s['gc_avg']):>7} {fmt(s.get('gc_max'), 1):>7} "
              f"{fmt(s['whole_avg']):>9} {fmt(s.get('engine_avg')):>7} {fmt(s['entity_avg']):>7} {fmt(s.get('electric_avg')):>7} "
              f"{fmt(s.get('fluid_avg')):>7} {fmt(s['save_mb'], 1):>7}")
    print("\nthroughput (per second over the window):")
    for s in results["scenes"]:
        tp = s["throughput"]
        if not tp:
            continue
        if s["scene"] == "planner":
            print(f"  planner: jobs {tp.get('jobs')}; conservation: {tp['conservation']['keys']} keys, {tp['conservation']['problems']} problems")
            continue
        print(f"  {scene_label(s)} {s['size']}: items {fmt(tp['items_per_s'], 0)}/s, {fmt(tp['items_per_s_per_endpoint'], 2)}/s "
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
            print(f"  {scene_label(s)} {s['size']} {k:12}: median {fmt(v['median_s'], 2)}, max {fmt(v['max_s'], 2)} "
                  f"({v['n']} probes, {v['timeouts']} timed out)")
    print("\nservice quality (the scheduler's counters over the window; intervals between two visits of a block, by what "
          "the visit found):")
    for s in results["scenes"]:
        s.setdefault("window", results.get("window"))
        print_service(s)
    print("\nload (median of the runs): the save loaded until the scripts are checked, and the script time of the first ticks:")
    for s in results["scenes"]:
        ld = s.get("load") or {}
        if ld:
            print(f"  {scene_label(s)} {s['size']}: load {fmt(ld.get('load_s'), 2)} s; first tick {fmt(ld.get('tick0_ms'), 1)} ms, "
                  f"second {fmt(ld.get('tick1_ms'), 1)} ms, first second {fmt(ld.get('first_second_ms'), 1)} ms (max {fmt(ld.get('first_second_max_ms'), 1)})")
    print("\nbuild burst (median of the runs): ME blocks built and removed in one tick each, then plain chests (ms of the loop; "
          "the tick's script and whole update):")
    for s in results["scenes"]:
        b = s.get("burst") or {}
        for what in ("build", "remove", "plain-build", "plain-remove", "asm-build", "asm-remove", "ghost-paste", "ghost-remove",
                     "ghost-after"):
            v = b.get(what)
            if v:
                print(f"  {scene_label(s)} {s['size']} {what:12}: {fmt(v.get('n'), 0)} entities, loop {fmt(v.get('ms'), 1)} ms, "
                      f"tick script {fmt(v.get('script_ms'), 1)} ms, whole {fmt(v.get('whole_ms'), 1)} ms")
    for s in results["scenes"]:
        if s.get("plan"):
            st = s.get("setup") or {}
            print(f"\nplanner: {st.get('recipes')} recipes on shortest paths ({st.get('usable_recipes')} usable): {st.get('processing')} "
                  f"processing patterns at chests, {st.get('crafting')} crafting patterns at machines {st.get('machines')}, "
                  f"{st.get('no_machine')} with fluids but no machine (e.g. {st.get('no_machine_first')}); {st.get('encoded')} encoded, "
                  f"{st.get('rejected')} rejected, on {st.get('providers')} providers; {st.get('items')} items, {st.get('raw_items')} raw "
                  f"items and {st.get('raw_fluids')} raw fluids in stock, deepest tree {st.get('max_depth')}, items per depth {st.get('depths')}; "
                  f"patterns the network cannot use: {s['plan'].get('ignored')}; stocked because the network cannot make them: "
                  f"{(s['plan'].get('stock') or {}).get('extra_items')} items and {(s['plan'].get('stock') or {}).get('extra_fluids')} fluids "
                  f"(e.g. {(s['plan'].get('stock') or {}).get('extra_first')}); targets by the chain of usable patterns: "
                  f"{[(t.get('key'), t.get('depth')) for t in ((s['plan'].get('stock') or {}).get('targets') or [])]}")
            for pl in s["plan"]["plans"]:
                print(f"  plan {pl['key']} (depth {pl['depth']}) x{pl['amount']}: {pl['status']}, {pl['steps']} steps, "
                      f"{pl['runs']} runs, {pl['missing']} missing {pl.get('missing_keys') or ''}: {fmt(pl['ms'], 2)} ms fresh, "
                      f"{fmt(pl.get('kept_ms'), 3)} ms a refresh")
            for pl in s["plan"].get("fails") or []:
                print(f"  failing plan {pl['key']} (depth {pl['depth']}) x{pl['amount']} without {pl['without']}: {pl['status']}, "
                      f"{pl['steps']} steps, {pl['missing']} missing: {fmt(pl['ms'], 2)} ms")
            for st_ in s["plan"]["starts"]:
                print(f"  start {st_['key']} x10: {st_['status']}: {fmt(st_['ms'], 2)} ms")
    for s in results["scenes"]:
        if s.get("slices"):
            print(f"\nlong run {s['size']} (per slice of {SLICE_TICKS // 3600} minutes): script avg / p99 / max / >5ms, gc avg, mod heap, backlogs")
            for sl in s["slices"]:
                t = sl["timing"].get("scriptUpdate", {})
                g = sl["timing"].get("luaGarbageIncremental", {})
                bl = sl.get("backlogs") or {}
                print(f"  tick {sl['tick']:>7}: {fmt(t.get('avg'))} / {fmt(t.get('p99'), 2)} / {fmt(t.get('max'), 1)} / {fmt(t.get('over5'), 0)}, "
                      f"gc {fmt(g.get('avg'))}, heap {fmt(sl.get('memory_kb'), 0)} kB, backlogs io {bl.get('io')} sb {bl.get('storage_bus')} "
                      f"fsb {bl.get('fluid_storage_bus')} maint {bl.get('maintainer')} circ {bl.get('circuit')}")
    for p in results["profiles"]:
        kind = "exclusive (own time; a callee's wrapper falls on its caller)" if results.get("exclusive") else "inclusive"
        print(f"\nprofile, size {p['size']} ({kind} ms per tick of the window, calls per tick, us per call; "
              f"wrapper overhead {fmt(p.get('overhead_us'), 2)} us per call):")
        n_ticks = results["window"]
        for name, calls, ms in sorted(p.get("profile", []), key=lambda x: -x[2]):
            print(f"  {name:42} {ms / n_ticks:8.4f} ms/tick {calls / n_ticks:9.2f} calls/tick {ms * 1000 / max(1, calls):9.2f} us/call")
        if p.get("alloc"):
            print(f"  memory allocated (KB per tick of the window, KB per call; the collector was stopped):")
            for name, calls, kb in sorted(p["alloc"], key=lambda x: -x[2])[:40]:
                print(f"  {name:42} {kb / n_ticks:10.2f} KB/tick {kb / max(1, calls):10.3f} KB/call {calls / n_ticks:9.2f} calls/tick")
        print("  engine calls (us per call):")
        for name, n, ms in p.get("engine", []):
            print(f"    {name:52} {ms * 1000:10.2f}")
        if p.get("service"):
            print_service({"scene": "me", "size": p["size"], "service": p["service"], "variant": {}, "window": results["window"]})


# ------------------------------------------------------------------------------------------------
# bench --check REF: the working copy against a reference, in turns
# ------------------------------------------------------------------------------------------------

# (name, how to read it from a run, lower is better, floor: a difference under this share of the reference is never a
# regression; 2 % for averages over the window, 10 % for what one tick or one event gives, optionally False: reported,
# never failed. Since pull request 2 of issue #38 the busy interval is long on purpose (a block is visited when the
# buffer on its other side needs it), so it is reported; what fails is a machine of the scene waiting for its bus
# (pair utilisation) and visits that arrived at an empty target or a full source (starved arrivals).)
CHECK_METRICS = [
    ("script avg ms", lambda r: r["timing"].get("scriptUpdate", {}).get("avg"), True, 0.02),
    ("script p99 ms", lambda r: r["timing"].get("scriptUpdate", {}).get("p99"), True, 0.05),
    ("ticks over 5 ms", lambda r: r["timing"].get("scriptUpdate", {}).get("over5"), True, 0.10),
    ("gc avg ms", lambda r: r["timing"].get("luaGarbageIncremental", {}).get("avg"), True, 0.05),
    ("items/s", lambda r: (r.get("throughput") or {}).get("items_per_s"), False, 0.02),
    ("fluid/s", lambda r: (r.get("throughput") or {}).get("fluid_per_s"), False, 0.02),
    ("provider crafts/s", lambda r: (r.get("throughput") or {}).get("provider_crafts_per_s"), False, 0.02),
    ("storage bus latency max s", lambda r: ((r.get("latency") or {}).get("storage_bus") or {}).get("max_s"), True, 0.02),
    ("maintainer latency max s", lambda r: ((r.get("latency") or {}).get("maintainer") or {}).get("max_s"), True, 0.02),
    ("io busy interval p99 ticks", lambda r: (((r.get("service") or {}).get("sched") or {}).get("io") or {}).get("full", {}).get("p99"), True, 0.02, False),
    ("io starved arrivals", lambda r: (((r.get("service") or {}).get("sched") or {}).get("io") or {}).get("starved"), True, 0.10),
    ("io starved, steady part", lambda r: ((r.get("service") or {}).get("io_steady") or {}).get("starved"), True, 0.10),
    # issue #115: the mod's meter; a version without it reports the heap's growth (heap_kb_per_tick), which Factorio's
    # collection between ticks makes meaningless at small sizes: not compared
    ("lua alloc KB per tick", lambda r: (r.get("alloc") or {}).get("kb_per_tick"), True, 0.05),
    ("mod heap alive kB", lambda r: (r.get("service") or {}).get("live_kb"), True, 0.05, False),
    ("io backlog max", lambda r: (((r.get("service") or {}).get("sched") or {}).get("io") or {}).get("backlog_max"), True, 0.02),
    ("pair machines utilisation", lambda r: (((r.get("service") or {}).get("machines") or {}).get("pair") or {}).get("utilisation"), False, 0.02),
    ("burst build ms", lambda r: ((r.get("burst") or {}).get("build") or {}).get("ms"), True, 0.10),
    ("burst remove ms", lambda r: ((r.get("burst") or {}).get("remove") or {}).get("ms"), True, 0.10),
    ("load first tick ms", lambda r: (r.get("load") or {}).get("tick0_ms"), True, 0.10),
]


class engine:
    """issue #487: `with engine(dir):` runs Factorio from `dir` (an unpacked Factorio, e.g. 2.0 for the numbers of the last
    2.0 version) instead of .devcheck/factorio; `dir` None: no change"""
    def __init__(self, fdir):
        self.fdir = Path(fdir).resolve() if fdir else None

    def __enter__(self):
        global FACTORIO
        self.kept = FACTORIO
        if self.fdir:
            FACTORIO = self.fdir

    def __exit__(self, *exc):
        global FACTORIO
        FACTORIO = self.kept


def bench_check(a):
    """`--check REF`: the maps of the reference and of the working copy are made once; then both are run in turns
    (ref, wc, ref, wc, ...: `--runs` rounds, at least three). For every metric the medians are compared; a metric of the working copy
    that is worse than the reference by more than the measured noise (the larger spread of the two versions' runs,
    at least the metric's floor share of the reference) fails the check. Throughput that differs at all is reported: the
    scheduling changed."""
    sizes = parse_sizes(a.sizes)
    runs = max(3, a.runs)
    ref_dir = old_tree(a.check)
    print(f"check: working copy against {a.check}, {runs} rounds in turns, sizes {sizes}")
    print((factorio("--version").splitlines() or ["?"])[0])
    # issue #487: the reference in another Factorio (--ref-factorio: the last 2.0 version in 2.0): the engine differs, so
    # the differences are reported, never failed
    ref_engine = getattr(a, "ref_factorio", None)
    if ref_engine:
        with engine(ref_engine):
            print("reference: " + (factorio("--version").splitlines() or ["?"])[0] + " (differences are reported, not failed)")
    failed, rows_out, problems = [], [], []
    results = {"check": a.check, "sizes": sizes, "rounds": runs, "per_size": []}
    for entry in sizes:
        size, base = size_variant(entry)
        ca = a
        if not getattr(a, "ticks_given", True) and not base and size >= CHECK_LONG_SIZE:
            ca = argparse.Namespace(**{**vars(a), "ticks": CHECK_LONG_TICKS})
            print(f"  {entry}: a window of {CHECK_LONG_TICKS} ticks (issue #56; --ticks sets another)")
        cfg = bench_config(ca, "me", size, base, False)
        size = entry                                         # (the label: a number or `base`)
        maps = {}
        for tag, mod_dir in (("ref", ref_dir), ("wc", None)):
            mapfile = WORK / f"bench-check-{tag}-{size}.zip"
            with engine(ref_engine if tag == "ref" else None):
                out, err = bench_map(ca, cfg, mod_dir, mapfile, gregtorio=a.with_gregtorio)
            if err:
                print(f"  {tag} {size}: the map was not created\n{err}")
                return 1
            maps[tag] = (mapfile, out)
        runs_of = {"ref": [], "wc": []}
        for r in range(runs):
            for tag, mod_dir in (("ref", ref_dir), ("wc", None)):
                with engine(ref_engine if tag == "ref" else None):
                    run = bench_run(ca, cfg, mod_dir, maps[tag][0], gregtorio=a.with_gregtorio, label=f"{tag} {size} round {r + 1}")
                if not run:
                    return 1
                runs_of[tag].append(run)
                problems += scene_problems(f"{tag}", size, {"runs": [run], "setup": maps[tag][1]["setup"]})
        per = {"size": size, "window": ca.ticks, "metrics": []}
        print(f"\n  size {size}: {'metric':28} {'reference':>22} {'working copy':>22}  verdict")
        for name, get, lower, floor, *rest in CHECK_METRICS:
            fails = rest[0] if rest else True
            rv = [get(r) for r in runs_of["ref"]]
            wv = [get(r) for r in runs_of["wc"]]
            rv = [v for v in rv if v is not None]
            wv = [v for v in wv if v is not None]
            if not rv or not wv:
                continue
            rm, wm = median(rv), median(wv)
            noise = max(max(rv) - min(rv), max(wv) - min(wv), abs(rm) * floor)
            worse = (wm - rm) if lower else (rm - wm)
            verdict = ("FAIL" if fails and not ref_engine else "reported") if worse > noise else "ok"
            if verdict == "FAIL":
                failed.append(f"{size}: {name}: {rm:.4g} -> {wm:.4g} (noise {noise:.3g})")
            per["metrics"].append({"name": name, "ref": rv, "wc": wv, "ref_median": rm, "wc_median": wm, "noise": noise, "verdict": verdict})
            print(f"  {'':11} {name:28} {rm:>12.4g} ±{(max(rv) - min(rv)) / 2:<8.3g} {wm:>12.4g} ±{(max(wv) - min(wv)) / 2:<8.3g}  {verdict}")
        tp_r = [r["throughput"] for r in runs_of["ref"] if r.get("throughput")]
        tp_w = [r["throughput"] for r in runs_of["wc"] if r.get("throughput")]
        if tp_r and tp_w:
            same = all(abs((tp_r[0]["categories"][k].get("items_in_per_s", 0) or 0) - (tp_w[0]["categories"][k].get("items_in_per_s", 0) or 0)) < 1e-6
                       and abs((tp_r[0]["categories"][k].get("items_out_per_s", 0) or 0) - (tp_w[0]["categories"][k].get("items_out_per_s", 0) or 0)) < 1e-6
                       for k in tp_r[0]["categories"] if k in tp_w[0]["categories"])
            per["same_throughput"] = same
            print(f"  {'':11} throughput per kind of endpoint {'identical' if same else 'DIFFERS (the scheduling changed; look at the categories)'}")
        results["per_size"].append(per)
    runtime_settings({})
    out = WORK / f"bench-check-{re.sub(r'[^A-Za-z0-9._-]', '_', a.check)}.json"
    out.write_text(json.dumps(results, indent=1), encoding="utf-8")
    print(f"\nresults: {out}")
    report("regressions beyond the noise", failed)
    report("benchmark problems", problems)
    ok = not failed and not problems
    print("\nRESULT:", "OK" if ok else "PROBLEMS FOUND")
    return 0 if ok else 1


WITH_MOD_HELP = ("issue #591: load this third-party mod (e.g. Krastorio2) and its required dependencies from their zips in "
                 ".devcheck/mods, fetched from the mod portal or --mods-from DIR when missing (repeatable)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("setup")
    s.add_argument("--version", default="stable", help="Factorio version, e.g. 2.1.23 (default: stable; the mods need 2.1)")
    s.add_argument("--factorio", help="use an existing unpacked Factorio instead of downloading (or the Steam install on Windows)")
    s.add_argument("--with-gregtorio", metavar="DIR", help="also get the dependency mods of this Gregtorio checkout")
    s.add_argument("--mods-from", help="folder with the dependency mod zips instead of downloading them")
    s.add_argument("--with-mod", action="append", metavar="NAME", help=WITH_MOD_HELP)
    for name in ("check", "runtime", "all"):
        p = sub.add_parser(name)
        p.add_argument("--with-gregtorio", metavar="DIR", help="a Gregtorio Continued checkout to load as well")
        p.add_argument("--with-mod", action="append", metavar="NAME", help=WITH_MOD_HELP)
        p.add_argument("--mods-from", help="with --with-mod: folder with the mod zips that are not in .devcheck/mods yet")
        if name in ("check", "all"):
            p.add_argument("--base-only", action="store_true", help="check without Space Age and quality")
        if name in ("runtime", "all"):
            p.add_argument("--ticks", type=int, default=1500)
            p.add_argument("--seed", default=str(DEFAULT_SEED), help=f"map seed or `random` (default {DEFAULT_SEED})")
            p.add_argument("--no-saveload", action="store_true", help="skip the save-and-load half (the server run)")
    p = sub.add_parser("migrate")
    p.add_argument("--from-ref", default="v0.5.0", help="the git tag or commit of the old version (default v0.5.0; an older "
                   "one than the cut-off 0.5.0 must be refused: issue #146)")
    p.add_argument("--bump", action="store_true",
                   help="load the save with the working copy as a version one patch up (a copy in .devcheck/new-bumped): Factorio runs "
                        "on_configuration_changed, as it does when a player updates the mod (without it the version number is the "
                        "same and the migrations of the mod do not run: issue #131 checks the old save both ways)")
    p.add_argument("--removed-items", action="store_true",
                   help="issue #503: the save also holds items of the helper mod that the load removes or renames through "
                        "ME_NETWORK.replace_item (a startup setting of the helper); `--from-ref working` makes the save with the "
                        "working copy itself")
    p.add_argument("--ticks", type=int, default=300)
    p.add_argument("--seed", default=str(DEFAULT_SEED), help=f"map seed or `random` (default {DEFAULT_SEED})")
    p.add_argument("--old-factorio", metavar="DIR", help="issue #487: an unpacked Factorio of the old version's "
                   "factorio_version (bin/ and data/), which makes the old save when it is not this one's (a 2.0 version)")
    p = sub.add_parser("bench")
    p.add_argument("--sizes", default="100,1000,5000", help="buses and interfaces of the ME scenes (default 100,1000,5000)")
    p.add_argument("--runs", type=int, default=3, help="benchmark runs per scene, the median is reported (default 3)")
    p.add_argument("--ticks", type=int, help="the measured window in ticks, a multiple of 600 (default 3600; --check at 20 000 and more: %d, issue #56)" % CHECK_LONG_TICKS)
    p.add_argument("--reference", action="store_true", help="also the native scenes: inserters and logistic robots")
    p.add_argument("--profile", metavar="SIZES", help="also profile these sizes with an instrumented copy (e.g. 1000,5000)")
    p.add_argument("--alloc", action="store_true", help="with --profile: also the memory each function allocates, measured inside each call (the collector is stopped in the window: use a short --ticks, e.g. 600)")
    p.add_argument("--exclusive", action="store_true", help="with --profile: each function's own time (and allocation), its wrapped callees' left out (issue #122): small functions are no longer hidden in their callers' totals")
    p.add_argument("--seed", default=str(DEFAULT_SEED), help=f"map seed or `random` (default {DEFAULT_SEED})")
    p.add_argument("--from-ref", help="benchmark this git tag or commit instead of the working copy (the scenes and the "
                   "harness stay the working copy's)")
    p.add_argument("--set", action="append", metavar="NAME=VALUE",
                   help="a runtime setting of me-network for the run, e.g. me-network-io-visits-per-tick=24 (repeatable)")
    p.add_argument("--idle", action="store_true", help="also the idle variant of each size: nothing to move")
    p.add_argument("--networks", metavar="K[,K]", help="also the same blocks on K networks (e.g. 10,100)")
    p.add_argument("--engine-share", action="store_true", help="also each scene without its ME entities (the engine's share)")
    p.add_argument("--long", type=int, metavar="MINUTES", help="also one run of that many minutes at the largest size, reported per 5 minutes")
    p.add_argument("--burst", type=int, default=1000, metavar="N", help="ME blocks built and removed in one tick after the probes (default 1000, 0: none)")
    p.add_argument("--logistic", type=int, default=0, metavar="N", help="issue #506: every ME scene also gets a logistic network of N "
                   "roboports and N / 2 filled storage chests, and an ME Logistic Storage Bus and (issue #531) 16 ME Logistic "
                   "Interfaces on it (where the version has them)")
    p.add_argument("--requesters", type=int, default=0, metavar="N", help="issue #537: with --logistic, N requester chests in the "
                   "logistic network that ask for items it holds, items only the ME network has and items nobody has")
    p.add_argument("--ghosts", type=int, default=0, metavar="N", help="issue #538: with --logistic, N wall ghosts pasted in one tick "
                   "in the logistic network after the build burst, then removed in one tick")
    p.add_argument("--planner", action="store_true", help="also the planner scene: every recipe of the game as a processing pattern")
    p.add_argument("--planner-only", action="store_true", help="only the planner scene")
    p.add_argument("--compare-plans", metavar="REF", help="the planner scene with that git ref and the working copy: every plan of its "
                   "sample must be the same (issue #50)")
    p.add_argument("--planner-targets", type=int, default=5, help="items the planner is timed on, the deepest first (default 5)")
    p.add_argument("--with-gregtorio", metavar="DIR", help="load this Gregtorio Continued checkout as well (the planner on its recipes)")
    p.add_argument("--with-mod", action="append", metavar="NAME", help=WITH_MOD_HELP)
    p.add_argument("--mods-from", help="with --with-mod: folder with the mod zips that are not in .devcheck/mods yet")
    p.add_argument("--check", metavar="REF", help="run the working copy and this git ref in turns and fail when a number is "
                   "worse by more than the measured noise (--runs rounds, at least 3)")
    p.add_argument("--ref-factorio", metavar="DIR", help="issue #487: with --check, run the reference in this unpacked Factorio "
                   "(bin/ and data/; e.g. 2.0 for the last 2.0 version): every difference is reported, none fails")
    a = ap.parse_args()
    if a.cmd == "bench":
        a.ticks_given = a.ticks is not None
        if a.ticks is None:
            a.ticks = 3600
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
