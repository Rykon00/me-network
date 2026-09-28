#!/usr/bin/env python3
"""Syntax check of all Lua files with luac (luac5.4 or luac must be installed).

    python tools/check_syntax.py            # all .lua files
    python tools/check_syntax.py --loaded   # only files data.lua/control.lua actually load
"""
import shutil, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
luac = shutil.which("luac5.4") or shutil.which("luac5.3") or shutil.which("luac") or shutil.which("luac5.2")
if not luac:
    sys.exit("luac not found")
import re
files = sorted(f for f in ROOT.rglob("*.lua") if ".git" not in f.parts and "dist" not in f.parts)
if "--loaded" in sys.argv:
    # only files that are actually loaded via require (ignore commented-out tiers)
    loaded = set()
    for entry in ["data.lua", "data-updates.lua", "data-final-fixes.lua", "control.lua", "settings.lua"]:
        p = ROOT / entry
        if not p.exists():
            continue
        loaded.add(p)
        for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r'\s*require\s*\(?\s*["\']([^"\']+)["\']', line)
            if m:
                loaded.add(ROOT / (m.group(1).replace(".", "/") + ".lua"))
    files = [f for f in files if f in loaded]
bad = 0
for f in files:
    r = subprocess.run([luac, "-p", str(f)], capture_output=True, text=True)
    if r.returncode:
        bad += 1
        print(r.stderr.strip())
print(f"{bad} file(s) with syntax errors")
sys.exit(1 if bad else 0)
