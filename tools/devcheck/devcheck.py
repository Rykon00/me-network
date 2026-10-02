#!/usr/bin/env python3
"""Headless test harness for Gregtorio (Linux, e.g. cloud sessions / CI).

    python tools/devcheck/devcheck.py setup     # download headless Factorio + dependency mods
    python tools/devcheck/devcheck.py check     # load the mod and run all static checks
    python tools/devcheck/devcheck.py runtime   # place every machine on a map and run it
    python tools/devcheck/devcheck.py migrate --from-ref 0e935ba
                                                # create a save with an older version (git ref or
                                                # --from-zip), load it with the working copy
    python tools/devcheck/devcheck.py all       # check + runtime
    python tools/devcheck/devcheck.py menusim --sim all --compare
                                                # run the main menu simulations with and without the mod

Everything is kept in .devcheck/ in the repository root (git-ignored).

Setup needs network access to factorio.com and *.factorio.com. The required dependency
mods (see info.json) are downloaded from the mod portal, which needs a Factorio account:
set FACTORIO_USERNAME and FACTORIO_TOKEN (token: factorio.com -> your profile), or put the
zips into a folder and pass --mods-from DIR.

`check` fails (exit code 1) when any of these is true:
  * the mod does not load
  * a recipe/tech still references a missing prototype after the draft guard
  * a referenced __gregtorio-continued__/ file does not exist (headless Factorio does not load graphics,
    the real game crashes on missing files)
  * a sprite sheet is smaller than its width/height/frame_count need
  * an unlocked recipe cannot be crafted: no machine for its category, an ingredient that can
    never be obtained, or no reachable machine with enough fluid inputs/outputs
  * an enabled technology cannot be researched and is not in UNRESEARCHABLE_OK (the vanilla
    armor/equipment techs), or one of the issue #29 QoL techs is neither researchable nor hidden
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
# `runtime` and `migrate` create their maps with this seed, so a run is reproducible (issue #47);
# `--seed N` or `--seed random` picks another one, the output prints the seed of every run
DEFAULT_SEED = 3115102263
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

MOD_NAMES = ("Gregtorio", "gregtorio-continued")   # the mod before and since 0.3.0


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


def prepare_mods(with_runtime=False, gregtorio_zip=None, with_migrate=False, menusim=None, gregtorio=True):
    """mods/ = dependency zips + the mod (working copy or a zip) + devcheck helper mods.
    menusim: name of a main menu simulation for the menusim helper mod; gregtorio=False leaves the mod out."""
    for p in MODS.iterdir():
        if p.name.startswith(MOD_NAMES + ("zz-gregtorio-devcheck",)) or p.name == "mod-list.json":
            remove_path(p)
    if not gregtorio:
        info = None
    elif gregtorio_zip:
        import zipfile
        with zipfile.ZipFile(gregtorio_zip) as z:
            info = json.loads(z.read(next(n for n in z.namelist() if n.endswith("/info.json") and n.count("/") == 1)))
        # Factorio insists on <name>_<version>.zip
        shutil.copy2(gregtorio_zip, MODS / f"{info['name']}_{info['version']}.zip")
    else:
        info = json.loads((ROOT / "info.json").read_text(encoding="utf-8"))
        link_dir(MODS / info["name"], ROOT)
    link_dir(MODS / "zz-gregtorio-devcheck", HERE / "checkmod")
    enabled = ["base", "space-age", "quality", "elevated-rails"] + ([info["name"]] if info else []) + ["zz-gregtorio-devcheck"]
    enabled += [z.name.rsplit("_", 1)[0] for z in MODS.glob("*.zip") if not z.name.startswith(MOD_NAMES)]
    if with_runtime:
        link_dir(MODS / "zz-gregtorio-devcheck-runtime", HERE / "runtimemod")
        enabled.append("zz-gregtorio-devcheck-runtime")
    if with_migrate:
        link_dir(MODS / "zz-gregtorio-devcheck-migrate", HERE / "migratemod")
        enabled.append("zz-gregtorio-devcheck-migrate")
    if menusim:
        # a copy, not a link: config.lua names the simulation to run
        shutil.copytree(HERE / "menusimmod", MODS / "zz-gregtorio-devcheck-menusim")
        (MODS / "zz-gregtorio-devcheck-menusim" / "config.lua").write_text(f"return {{ name = {json.dumps(menusim)} }}\n")
        enabled.append("zz-gregtorio-devcheck-menusim")
    (MODS / "mod-list.json").write_text(json.dumps({"mods": [{"name": n, "enabled": True} for n in enabled]}))


def factorio(*args):
    binary = FACTORIO / ("bin/x64/factorio.exe" if os.name == "nt" else "bin/x64/factorio")
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


def not_saved(log):
    """--create runs on_init and then saves; a failed save (e.g. a function in `storage`) keeps the
    previous map file, so the next run would test an old map"""
    m = re.search(r"Writing .* failed.*|Error while running event .*on_save.*\n.*", log)
    return "the map was not saved: " + m.group(0).strip() if m else None


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
                                    fin=kinds(p[4]).count("fluid"), fout=kinds(p[5]).count("fluid"),
                                    hidden=p[6] == "true", hide_craft=p[7] == "true", sg=p[8], group=p[9])
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

    def blockers(self, t, seen=None):
        """Root causes why a technology cannot be researched: disabled or missing prerequisites (recursively),
        science packs nobody can make, a craft trigger nobody can satisfy."""
        seen = seen if seen is not None else set()
        if t in seen:
            return []
        seen.add(t)
        v = self.T.get(t)
        if v is None:
            return [f"{t} (does not exist)"]
        if not v["en"]:
            return [f"{t} (disabled)"]
        out = []
        for p in v["pre"]:
            if p not in self.researched:
                out += self.blockers(p, seen)
        missing = [x for x in v["sci"] if x not in self.avail]
        if missing:
            out.append(f"{t} (no way to make {', '.join(missing)})")
        if not out and t not in self.researched:
            out.append(f"{t} (craft trigger or unknown)")
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


def check_crafting_menu(m, sec):
    """Issue #49: every recipe that is enabled or unlocked by a technology and whose category has a
    machine is listed in the crafting menu (not hide_from_player_crafting), except the allow-list
    FORK_CRAFTING_MENU_HIDDEN of prototypes/198-fork-crafting-menu.lua. Returns (info lines, problems)."""
    rows = sec.get("CRAFTMENU", [])
    setting = next((r[1] for r in rows if r[0] == "setting"), "absent")
    allow = {k: {} for k in ("categories", "subgroups", "recipes")}
    for r in rows:
        if r[0] in allow:
            allow[r[0]][r[1]] = r[2]
    if setting == "false":
        return ["skipped: startup setting gregtorio-continued-show-machine-recipes is off"], []
    machine_cats = {c for e, cats in m.C.items() if e != "character" for c in cats}
    reach = {r for r, v in m.R.items() if v["en"]}
    for v in m.T.values():
        if v["en"]:
            reach.update(r for r in v["eff"] if r in m.R)
    shown, kept, problems, tabs = 0, 0, [], {}
    for r in sorted(reach):
        v = m.R[r]
        if v["hidden"]:
            continue
        if not v["hide_craft"]:
            tabs[v["group"]] = tabs.get(v["group"], 0) + 1
        if v["cat"] not in machine_cats:
            continue
        if not v["hide_craft"]:
            shown += 1
        elif v["cat"] in allow["categories"] or v["sg"] in allow["subgroups"] or r in allow["recipes"]:
            kept += 1
        else:
            problems.append(f"{r} (category {v['cat']}, subgroup {v['sg']})")
    stale = [f"{k} {n} (allow-list entry matches nothing)" for k, names in allow.items() for n in names
             if (k == "recipes" and n not in m.R) or (k == "categories" and not any(v["cat"] == n for v in m.R.values()))
             or (k == "subgroups" and not any(v["sg"] == n for v in m.R.values()))]
    info = [f"machine recipes (enabled or unlocked by a technology): {shown} shown, {kept} kept hidden by the "
            f"allow-list, {len(problems)} hidden without an allow-list entry",
            "recipes shown per crafting menu tab: " + ", ".join(f"{g} {n}" for g, n in sorted(tabs.items(), key=lambda x: -x[1]))]
    return info, problems + stale


def check_files(sec):
    missing = []
    for path, owner in sec.get("PATHS", []):
        if not (ROOT / path[len("__gregtorio-continued__/"):]).exists():
            missing.append(f"{path} ({owner})")
    return sorted(set(missing))


def check_sprites(sec):
    try:
        from PIL import Image
    except ImportError:
        return ["(Pillow not installed, sprite sizes not checked: pip install pillow)"]
    bad = []
    for name, key, fn, w, h, fc, ll, x, y in sec.get("SPRITES", []):
        if not fn.startswith("__gregtorio-continued__/"):
            continue
        f = ROOT / fn[len("__gregtorio-continued__/"):]
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


# Recipes that must stay unlocked by a researchable technology and craftable in the progression model
# (issue #35: grades 7 and 8, FPIC/APIC, complex SMDs, which the runtime test also crafts once in a machine;
# issues #39 and #36: the drafts made real and the new endgame materials; phase 6a: plasma forge and QFT).
REQUIRED_RECIPES = [
    "grade-7-water", "grade-8-water", "quark-creation-catalyst", "fpic-wafer", "apic-wafer", "femto-power-ic",
    "atto-power-ic", "complex-smd-transistor", "complex-smd-resistor", "complex-smd-capacitor", "complex-smd-diode",
    "complex-smd-inductor",
    # issues #39 and #36: the drafts made real and the endgame materials
    "lapotronic-energy-orb-cluster", "high-density-plutonium", "plutonium-based-liquid-fuel", "super-coolant",
    "1080k-super-coolant-cell", "molten-fluxed-electrum", "fine-fluxed-electrum-wire", "bedrockium-cable",
    "bedrockium-plate", "molten-quantium", "quantium-cable",
    # phase 6a: the plasma forge, its catalysts and metals, the quantum force transformer and its recipes
    "dimensionally-transcendent-plasma-forge", "excited-dimensionally-transcendent-crude-catalyst",
    "excited-dimensionally-transcendent-resplendent-catalyst", "molten-spacetime-dtpf-crude",
    "molten-universium-dtpf-resplendent", "molten-transcendent-metal-dtpf-crude", "quantum-force-transformer",
    "metallic-platinum-powder-qft-platinum-dust", "iridium-group-sludge-qft-iridium-dust",
    "naquadah-oxide-mixture-qft-naquadahine-dust", "enriched-naquadah-oxide-mixture-qft-trinium-dust",
    # phase 6b: the godforge and its products, the stellar catalyst, the MAX line, components, hatches and machines
    "godforge", "raw-star-matter", "lead-plasma", "thorium-plasma", "naquadria-plasma", "molten-universium-godforge",
    "spacetime-time-space-separation", "molten-magmatter-from-neutronium", "molten-magmatter-from-infinity",
    "excited-dimensionally-transcendent-stellar-catalyst", "molten-universium-dtpf-stellar", "magmatter-plate",
    "magmatter-cable", "planck-processor-mainframe", "max-motor", "max-field-generator", "max-machine-hull",
    "max-energy-hatch", "max-dynamo-hatch", "max-assembling-machine", "max-electric-blast-furnace",
    "max-large-plasma-turbine", "max-science-pack-from-magmatter",
]


# Issues #39 and #36: the draft recipes the draft guard may still hide (docs/ROADMAP.md, "Drafts and endgame
# materials"); any other FORK-DRAFT recipe is a problem. Removed drafts are deleted in
# prototypes/137-fork-endgame-materials.lua (FORK-REMOVED in the log) and must not come back as drafts.
DRAFTS_OK = []


# Technologies that stay enabled but cannot be researched on purpose: vanilla armor, equipment and
# military techs whose vanilla prerequisites Gregtorio disables (docs/ROADMAP.md, "Final pass").
# Every other enabled technology must be researchable.
UNRESEARCHABLE_OK = [
    "battery-equipment", "battery-mk2-equipment", "battery-mk3-equipment", "belt-immunity-equipment",
    "energy-shield-equipment", "energy-shield-mk2-equipment", "exoskeleton-equipment", "explosives",
    "fission-reactor-equipment", "fusion-reactor", "fusion-reactor-equipment", "mech-armor", "modular-armor",
    "night-vision-equipment", "personal-roboport-equipment", "personal-roboport-mk2-equipment", "power-armor",
    "power-armor-mk2", "spidertron",
]
# Issue #29: the quality-of-life techs whose vanilla gate is disabled; each must be researchable or hidden
# (prototypes/103-fork-qol-techs.lua re-gates them onto Gregtorio techs)
QOL_TECHS = (["bulk-inserter", "stack-inserter", "logistics-3", "turbo-transport-belt",
              "transport-belt-capacity-1", "transport-belt-capacity-2"]
             + [f"inserter-capacity-bonus-{i}" for i in range(1, 8)]
             + [f"worker-robots-speed-{i}" for i in range(1, 8)]
             + [f"worker-robots-storage-{i}" for i in range(1, 4)])


def check_unresearchable(m):
    """Enabled but unresearchable technologies outside UNRESEARCHABLE_OK, QoL techs that are neither
    researchable nor hidden, and allow-list entries that are researchable, hidden or gone."""
    out = []
    for t in QOL_TECHS:
        if t not in m.T:
            out.append(f"{t}: issue #29 technology does not exist")
        elif m.T[t]["en"] and t not in m.researched:
            out.append(f"{t}: issue #29 technology is neither researchable nor hidden")
    for t, v in sorted(m.T.items()):
        if v["en"] and t not in m.researched and t not in UNRESEARCHABLE_OK and t not in QOL_TECHS:
            out.append(f"{t}: cannot be researched and is not in UNRESEARCHABLE_OK")
    for t in UNRESEARCHABLE_OK:
        if t not in m.T or not m.T[t]["en"] or t in m.researched:
            out.append(f"{t}: in UNRESEARCHABLE_OK but researchable, hidden or missing (remove the entry)")
    return out


def check_required(m):
    out = []
    for r in REQUIRED_RECIPES:
        if r not in m.R:
            out.append(f"{r}: recipe does not exist")
        elif r not in m.unlocked:
            out.append(f"{r}: not unlocked by a researchable technology")
        elif not all(x in m.avail for x in m.R[r]["res"]):
            out.append(f"{r}: products never obtainable")
    return out


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
    removed = re.findall(r"FORK-REMOVED: (\S+ \S+)", log)
    print(f"drafts removed for good: {len(removed)} prototypes (FORK-REMOVED)")
    new_drafts = [d for d in drafts if d not in DRAFTS_OK]
    m = Model(sec["DUMP"])
    files, sprites, uncraft = check_files(sec), check_sprites(sec), m.uncraftable()
    print(f"\nresearchable technologies: {len(m.researched)} of {sum(1 for v in m.T.values() if v['en'])}")
    for t, miss in m.frontier():
        print(f"  progression stops at {t}" + (f" (missing science: {', '.join(miss)})" if miss else ""))
    stuck = [f"{t}: blocked by {', '.join(sorted(set(m.blockers(t))))}"
             for t, v in sorted(m.T.items()) if v["en"] and t not in m.researched]
    report("technologies that cannot be researched", stuck, limit=100)
    unresearchable = check_unresearchable(m)
    print(f"  intentional (UNRESEARCHABLE_OK): {len(UNRESEARCHABLE_OK)}; issue #29 QoL technologies researchable: "
          f"{sum(1 for t in QOL_TECHS if t in m.researched)} of {len(QOL_TECHS)}, hidden: "
          f"{sum(1 for t in QOL_TECHS if t in m.T and not m.T[t]['en'])}")
    report("unexpected unresearchable technologies", unresearchable)
    if a.techs:
        rx = re.compile(a.techs)
        rows = []
        for t, v in sorted(m.T.items()):
            if rx.search(t) and v["en"]:
                state = "researchable" if t in m.researched else "NOT researchable"
                sci = ", ".join(s.replace("-science-pack", "") for s in v["sci"])
                rows.append(f"{t}: {state} [{sci}] unlocks {len(v['eff'])} recipes")
        report(f"technologies matching /{a.techs}/", rows, limit=400)
    report("missing graphics files", files)
    report("sprite sheets too small", sprites)
    report("unlocked but uncraftable recipes", [f"{r}: {why}" for r, why in uncraft])
    required = check_required(m)
    print(f"\nrequired recipes (issues #35, #36, #39, phases 6a and 6b): {len(REQUIRED_RECIPES) - len(required)} of {len(REQUIRED_RECIPES)} unlocked and craftable")
    report("required recipes not unlocked or not craftable", required)
    report("draft recipes outside DRAFTS_OK (issue #39)", new_drafts)
    menu_info, menu = check_crafting_menu(m, sec)
    print("\ncrafting menu (issue #49):")
    for line in menu_info:
        print("  " + line)
    report("machine recipes hidden from the crafting menu without an allow-list entry", menu)
    if a.locale_out:
        Path(a.locale_out).write_text("\n".join("\t".join(r) for r in sec.get("LOCALE", [])))
        print(f"\nlocale name list written to {a.locale_out} (input for tools/gen_locale.py)")
    if getattr(a, "balance_out", None):
        rows = ["\t".join(r) for r in sec.get("BALANCE", [])]
        Path(a.balance_out).write_text("[\n" + ",\n".join(rows) + "\n]\n", encoding="utf-8")
        print(f"\nbalance data written to {a.balance_out} (recipes, machines, technologies as JSON)")
    ok = not (files or [s for s in sprites if not s.startswith("(")] or uncraft or menu or required or unresearchable
              or new_drafts)
    print("\nRESULT:", "OK" if ok else "PROBLEMS FOUND")
    return 0 if ok else 1


def seed_args(a):
    if a.seed == "random":
        return []
    return ["--map-gen-seed", str(int(a.seed))]


def runtime(a):
    prepare_mods(with_runtime=True)
    log = factorio("--create", str(WORK / "runtime-map.zip"), *seed_args(a))
    if load_errors(log):
        print(load_errors(log))
        return 1
    if not_saved(log):
        print(not_saved(log))
        return 1
    placed = re.search(r"DEVCHECK-RUNTIME (placed=.*)", log)
    fails = re.findall(r"DEVCHECK-RUNTIME-FAIL (.*)", log)
    print("runtime setup:", placed.group(1) if placed else "no result")
    seed = re.search(r"DEVCHECK-RUNTIME-SEED (.*)", log)
    print("map seed:", seed.group(1) if seed else "unknown")
    log = factorio("--benchmark", str(WORK / "runtime-map.zip"), "--benchmark-ticks", str(a.ticks))
    ran = re.search(r"Performed (\d+) updates", log)
    err = re.search(r"(Error.*|non-recoverable.*)", log)
    fails += re.findall(r"DEVCHECK-RUNTIME-FAIL (.*)", log)
    print(f"benchmark: {ran.group(0) if ran else 'did not run'}")
    # issue #68: the ME network core (cable graph, cells, terminal, import/export)
    me_tests = [(label, re.search(rf"DEVCHECK-RUNTIME-{key} (.*)", log)) for key, label in
                (("MEGRAPH", "ME graph test"), ("MECELLS", "ME cell test"), ("METERMINAL", "ME terminal test"),
                 ("MEIO", "ME import/export test"))]
    for label, m in me_tests:
        print(f"{label}: {m.group(1) if m else 'did not run'}")
    mold = re.search(r"DEVCHECK-RUNTIME-MOLD (.*)", log)
    print(f"mold test: {mold.group(1) if mold else 'did not run'}")
    autocraft = re.search(r"DEVCHECK-RUNTIME-AUTOCRAFT (.*)", log)
    print(f"autocrafting test: {autocraft.group(1) if autocraft else 'did not run'}")
    furnace = re.search(r"DEVCHECK-RUNTIME-FURNACE (.*)", log)
    print(f"furnace pattern test: {furnace.group(1) if furnace else 'did not run'}")
    fluids = re.search(r"DEVCHECK-RUNTIME-FLUIDS (.*)", log)
    print(f"fluid test: {fluids.group(1) if fluids else 'did not run'}")
    recovery = re.search(r"DEVCHECK-RUNTIME-FLUIDCELLS (.*)", log)
    print(f"ME fluid cell test: {recovery.group(1) if recovery else 'did not run'}")
    power = re.search(r"DEVCHECK-RUNTIME-POWER (.*)", log)
    print(f"power test: {power.group(1) if power else 'did not run'}")
    fuel = re.search(r"DEVCHECK-RUNTIME-FUEL (.*)", log)
    print(f"fuel check test: {fuel.group(1) if fuel else 'did not run'}")
    cooled = re.search(r"DEVCHECK-RUNTIME-COOLED (.*)", log)
    print(f"cooled fluid test: {cooled.group(1) if cooled else 'did not run'}")
    tiers = re.search(r"DEVCHECK-RUNTIME-TIERS (.*)", log)
    print(f"turbine tier test: {tiers.group(1) if tiers else 'did not run'}")
    recipes = re.search(r"DEVCHECK-RUNTIME-RECIPES (.*)", log)
    print(f"recipe test: {recipes.group(1) if recipes else 'did not run'}")
    # issue #38: level maintainer, CPU tiers, circuit interface and blueprint/paste of the settings
    extras = [(label, re.search(rf"DEVCHECK-RUNTIME-{key} (.*)", log)) for key, label in
              (("MAINTAINER", "level maintainer test"), ("CPUTIERS", "crafting CPU tier test"),
               ("CIRCUIT", "circuit interface test"), ("SETTINGS", "settings copy test"),
               ("MER3", "ME partitions and windows test (issue #68 R3)"),
               ("MESTORAGEBUS", "ME storage bus test (issue #68)"),
               ("MEFLUIDSTORAGEBUS", "ME fluid storage bus test (issue #68)"),
               ("PATSWITCH", "pattern recipe switching test (issue #80)"),
               ("PATLINE", "processing line test (issue #80)"))]
    for label, m in extras:
        print(f"{label}: {m.group(1) if m else 'did not run'}")
    victory = re.search(r"DEVCHECK-RUNTIME-VICTORY (.*)", log)
    print(f"victory test: {victory.group(1) if victory else 'did not run'}")
    post = re.search(r"DEVCHECK-RUNTIME-POSTVICTORY (.*)", log)
    print(f"post-victory test: {post.group(1) if post else 'did not run'}")
    for label, m in me_tests:
        if not m:
            fails.append(f"{label} did not run (needs --ticks >= 1500)")
        elif not m.group(1).startswith("ok"):
            fails.append(f"{label} failed")
    if not mold:
        fails.append("mold test did not run (needs --ticks >= 1500)")
    if not autocraft:
        fails.append("autocrafting test did not run (needs --ticks >= 1500)")
    elif not autocraft.group(1).startswith("ok"):
        fails.append("autocrafting test failed")
    if not furnace:
        fails.append("furnace pattern test did not run (needs --ticks >= 1500)")
    elif not furnace.group(1).startswith("ok"):
        fails.append("furnace pattern test failed")
    if not fluids:
        fails.append("fluid test did not run (needs --ticks >= 1500)")
    elif not fluids.group(1).startswith("ok"):
        fails.append("fluid test failed")
    if not recovery:
        fails.append("ME fluid cell test did not run (needs --ticks >= 1500)")
    elif not recovery.group(1).startswith("ok"):
        fails.append("ME fluid cell test failed")
    if not power:
        fails.append("power test did not run (needs --ticks >= 420)")
    elif not power.group(1).startswith("ok"):
        fails.append("power test failed")
    if not fuel:
        fails.append("fuel check test did not run (needs --ticks >= 1500)")
    elif not fuel.group(1).startswith("ok"):
        fails.append("fuel check test failed")
    if not cooled:
        fails.append("cooled fluid test did not run (needs --ticks >= 1500)")
    elif not cooled.group(1).startswith("ok"):
        fails.append("cooled fluid test failed")
    if not tiers:
        fails.append("turbine tier test did not run (needs --ticks >= 1500)")
    elif not tiers.group(1).startswith("ok"):
        fails.append("turbine tier test failed")
    if not recipes:
        fails.append("recipe test did not run (needs --ticks >= 1500)")
    elif not recipes.group(1).startswith("ok"):
        fails.append("recipe test failed")
    for label, m in extras:
        if not m:
            fails.append(f"{label} did not run (needs --ticks >= 1500)")
        elif not m.group(1).startswith("ok"):
            fails.append(f"{label} failed")
    if not victory:
        fails.append("victory test did not run (needs --ticks >= 1500)")
    elif not victory.group(1).startswith("ok"):
        fails.append("victory test failed")
    if not post:
        fails.append("post-victory test did not run (needs --ticks >= 1500)")
    elif not post.group(1).startswith("ok"):
        fails.append("post-victory test failed")
    report("runtime problems (placement, ME graph, cell, terminal and import/export tests, mold test, autocrafting test, furnace pattern test, fluid test, ME fluid cell test, power test, fuel check test, cooled fluid test, turbine tier test, recipe test, level maintainer test, crafting CPU tier test, circuit interface test, settings copy test, victory test, post-victory test)", fails)
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
    """Create a map with an older version (also "Gregtorio" before 0.3.0), then load and run it with the working copy."""
    old = a.from_zip or zip_from_ref(a.from_ref)
    prepare_mods(gregtorio_zip=old, with_migrate=True)
    log = factorio("--create", str(WORK / "migrate-map.zip"), *seed_args(a))
    print(f"map seed: {'random' if a.seed == 'random' else a.seed}")
    if load_errors(log):
        print("could not create the map with the old version:\n" + load_errors(log))
        return 1
    if not_saved(log):
        print(not_saved(log))
        return 1
    setup = re.search(r"DEVCHECK-MIGRATE-SETUP (.*)", log)
    print(f"old save with loaded fluid drives: {setup.group(1) if setup else 'no result'}")
    setup = re.search(r"DEVCHECK-MIGRATE-SETUP-POWER (.*)", log)
    print(f"old save with a reactor on steam: {setup.group(1) if setup else 'no result'}")
    setup = re.search(r"DEVCHECK-MIGRATE-SETUP-TURBINE (.*)", log)
    print(f"old save with a plasma turbine: {setup.group(1) if setup else 'no result'}")
    setup = re.search(r"DEVCHECK-MIGRATE-SETUP-PATTERNS (.*)", log)
    print(f"old save with pattern providers: {setup.group(1) if setup else 'no result'}")
    setup = re.search(r"DEVCHECK-MIGRATE-SETUP-JOB (.*)", log)
    print(f"old save with a crafting job: {setup.group(1) if setup else 'no result'}")
    setup = re.search(r"DEVCHECK-MIGRATE-SETUP-MAINTAINER (.*)", log)
    print(f"old save with a level maintainer: {setup.group(1) if setup else 'no result'}")
    setup = re.search(r"DEVCHECK-MIGRATE-SETUP-ITEMS (.*)", log)
    print(f"old save with a logistic ME network (items): {setup.group(1) if setup else 'no result'}")
    prepare_mods(with_migrate=True)
    log = factorio("--benchmark", str(WORK / "migrate-map.zip"), "--benchmark-ticks", str(a.ticks))
    ran = re.search(r"Performed (\d+) updates", log)
    fluids = re.search(r"DEVCHECK-MIGRATE-FLUIDS (.*)", log)
    print(f"old save loaded with working copy: {'ok, ' + ran.group(0) if ran else 'FAILED'}")
    print(f"fluid drives of the old save: {fluids.group(1) if fluids else 'no result'}")
    power = re.search(r"DEVCHECK-MIGRATE-POWER (.*)", log)
    print(f"reactor on steam in the old save: {power.group(1) if power else 'no result'}")
    turbine = re.search(r"DEVCHECK-MIGRATE-TURBINE (.*)", log)
    print(f"plasma turbine of the old save: {turbine.group(1) if turbine else 'no result'}")
    patterns = re.search(r"DEVCHECK-MIGRATE-PATTERNS (.*)", log)
    print(f"pattern providers of the old save: {patterns.group(1) if patterns else 'no result'}")
    job = re.search(r"DEVCHECK-MIGRATE-JOB (.*)", log)
    print(f"crafting job of the old save: {job.group(1) if job else 'no result'}")
    items = re.search(r"DEVCHECK-MIGRATE-ITEMS (.*)", log)
    print(f"ME network of the old save converted (issue #68): {items.group(1) if items else 'no result'}")
    for line in re.findall(r"FORK-ME-MIGRATE: (.*)", log):
        print("  migration: " + line)
    for f in re.findall(r"DEVCHECK-MIGRATE-FAIL (.*)", log):
        print("  - " + f)
    if not ran:
        print(load_errors(log) or "")
    ok = ran and fluids and not fluids.group(1).startswith("failed") and power and not power.group(1).startswith("failed") \
        and turbine and not turbine.group(1).startswith("failed") \
        and patterns and not patterns.group(1).startswith("failed") and job and not job.group(1).startswith("failed") \
        and items and not items.group(1).startswith("failed")
    return 0 if ok else 1


def menusim_list(gregtorio):
    """{name: (save file, length)} of the main menu simulations, as the game has them with this mod set"""
    prepare_mods(menusim="none", gregtorio=gregtorio)
    log = factorio("--create", str(WORK / "menusim-list.zip"))
    if load_errors(log):
        sys.exit("the mods do not load:\n" + load_errors(log))
    return {r[0]: (r[1], int(r[2])) for r in sections(log).get("MENUSIMS", [])}


def save_path(path):
    m = re.match(r"__([\w-]+)__/(.*)", path)
    if not m:
        return None
    if m.group(1) in BUILTIN:
        return FACTORIO / "data" / m.group(1) / m.group(2)
    return ROOT / m.group(2) if m.group(1) in MOD_NAMES else None


def run_menusim(name, save, length, gregtorio):
    """Load the simulation's save with --benchmark for its length; the helper mod runs its init and update chunks"""
    prepare_mods(menusim=name, gregtorio=gregtorio)
    path = save_path(save)
    if not path or not path.exists():
        return f"skipped (no save file: {save or 'none'})", []
    log = factorio("--benchmark", str(path), "--benchmark-ticks", str(length))
    lines = re.findall(r"DEVCHECK-MENUSIM (.*)", log)
    ran = re.search(r"Performed (\d+) updates", log)
    err = re.search(r"(Error while running.*|non-recoverable.*|Error.*)(\n.*){0,3}", log)
    if any(l.startswith("FAIL") for l in lines):
        return next(l for l in lines if l.startswith("FAIL")), lines
    if err and not ran:
        return "ERROR " + " ".join(x.strip() for x in err.group(0).splitlines()), lines
    if not any(l == "init done" for l in lines):
        return "ERROR init did not run", lines
    deaths = sum(1 for l in lines if l.startswith("DIED"))
    return f"ok ({ran.group(1)} ticks{f', {deaths} characters died' if deaths else ''})", lines


def menusim(a):
    """Run main menu simulations with the mod (and with --compare also without it) and report errors."""
    variants = [True, False] if a.compare else [True]
    failed = False
    for gregtorio in variants:
        label = "with Gregtorio" if gregtorio else "without Gregtorio"
        sims = menusim_list(gregtorio)
        names = sorted(sims) if a.sim == "all" else [a.sim]
        print(f"== {label}: {len(sims)} menu simulations{'' if a.sim == 'all' else ', running ' + a.sim}")
        for name in names:
            if name not in sims:
                print(f"{name}: not in main_menu_simulations")
                continue
            save, length = sims[name]
            result, lines = run_menusim(name, save, a.ticks or length, gregtorio)
            print(f"{name}: {result}")
            if a.sim != "all" or a.verbose:
                for l in lines:
                    print("    " + l)
            failed |= result.startswith(("ERROR", "FAIL"))
    print("\nRESULT: " + ("PROBLEMS FOUND" if failed else "OK"))
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("setup")
    s.add_argument("--version", default="stable", help="Factorio version, e.g. 2.0.77 (default: stable)")
    s.add_argument("--factorio", help="use an existing unpacked headless Factorio instead of downloading")
    s.add_argument("--mods-from", help="folder with the dependency mod zips instead of downloading them")
    c = sub.add_parser("check")
    c.add_argument("--locale-out", help="also write the locale name list for tools/gen_locale.py")
    c.add_argument("--techs", help="regex: list matching technologies and whether they are researchable")
    c.add_argument("--balance-out", help="also write recipes (amounts, times), machine speeds and technology counts as JSON")
    r = sub.add_parser("runtime")
    r.add_argument("--ticks", type=int, default=1500)
    r.add_argument("--seed", default=str(DEFAULT_SEED), help=f"map seed or `random` (default {DEFAULT_SEED})")
    m = sub.add_parser("migrate")
    src = m.add_mutually_exclusive_group(required=True)
    src.add_argument("--from-zip", help="older Gregtorio_x.y.z.zip to create the save with")
    src.add_argument("--from-ref", help="git tag or commit of an older version, e.g. 0e935ba (upstream 0.1.9)")
    m.add_argument("--ticks", type=int, default=600)
    m.add_argument("--seed", default=str(DEFAULT_SEED), help=f"map seed or `random` (default {DEFAULT_SEED})")
    ms = sub.add_parser("menusim", help="run main menu simulations")
    ms.add_argument("--sim", default="nauvis_biter_base_laser_defense", help="simulation name or `all`")
    ms.add_argument("--compare", action="store_true", help="also run without Gregtorio")
    ms.add_argument("--ticks", type=int, help="ticks to run (default: the simulation's length)")
    ms.add_argument("--verbose", action="store_true", help="print the log lines with --sim all too")
    al = sub.add_parser("all")
    al.add_argument("--ticks", type=int, default=1500)
    al.add_argument("--locale-out")
    al.add_argument("--techs")
    al.add_argument("--seed", default=str(DEFAULT_SEED), help=f"map seed of the runtime map or `random` (default {DEFAULT_SEED})")
    a = ap.parse_args()
    if a.cmd == "setup":
        return setup(a)
    if a.cmd == "check":
        return check(a)
    if a.cmd == "runtime":
        return runtime(a)
    if a.cmd == "migrate":
        return migrate(a)
    if a.cmd == "menusim":
        return menusim(a)
    return check(a) or runtime(a)


if __name__ == "__main__":
    sys.exit(main())
