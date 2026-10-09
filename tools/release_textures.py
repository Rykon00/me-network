#!/usr/bin/env python3
"""The texture mod's part of a release (issue #243): is the version of ae2-textures/info.json new, and may it be released?

    python tools/release_textures.py --release-tag v0.5.3                    # check, explain, exit 1 on a problem
    python tools/release_textures.py --release-tag v0.5.3 --output "$GITHUB_OUTPUT"

.github/workflows/release.yml runs it in the release pull request checks and when it releases. The rules:

- "Changed" means: anything under ae2-textures/ differs between the last release tag (the highest vX.Y.Z reachable from
  the commit, not counting --release-tag) and the commit. Without such a tag, or when that tag has no ae2-textures/,
  it changed.
- Changed: ae2-textures/info.json must have a version that no earlier release used (no vX.Y.Z tag holds it, the mod
  portal does not have it, it is not in HAND_RELEASES) and ae2-textures/changelog.txt a section "Version: <it>". Then
  the version is new: the release attaches its zip and uploads it to the portal.
- Unchanged: the version is the one an earlier release had; nothing is attached or uploaded.
- One exception, for versions uploaded to the portal by hand (HAND_RELEASES: version -> the commit whose ae2-textures/
  was uploaded): when ae2-textures/ is that commit's, the version is not new and nothing is wrong.

me-network's version is checked by the workflow itself; the two versions are independent. Prints one line per finding
(problems as GitHub "::error::" lines); with --output it appends textures_name, textures_title, textures_version,
textures_zip, textures_new (true/false) and textures_attach (the zip path when new, else empty) as key=value lines.
--portal-json takes the portal's answer from a file or URL instead of https://mods.factorio.com/api/mods/<name>
(the self-test, tools/devcheck/test_release_texture.py); --no-portal leaves the portal out.
"""
import argparse, json, re, subprocess, sys, urllib.error, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FOLDER = "ae2-textures"
PORTAL_API = "https://mods.factorio.com/api/mods/"
# texture versions uploaded to the mod portal by hand: version -> the commit whose ae2-textures/ was uploaded
HAND_RELEASES = {
    "0.1.0": "e78a8d4474bde73d2272b156814e3feb6fd5aec1",  # the first upload creates the portal page (issue #243)
}


def git(root, *args, check=True):
    r = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, encoding="utf-8")
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r


def show_json(root, ref, path):
    """the JSON of path at ref, or None when it is not there"""
    r = git(root, "show", f"{ref}:{path}", check=False)
    return json.loads(r.stdout) if r.returncode == 0 else None


def tag_version(tag):
    m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", tag)
    return tuple(int(x) for x in m.groups()) if m else None


def release_tags(root, ref=None):
    """the vX.Y.Z tags (reachable from ref when given), oldest first"""
    args = ["tag", "--list", "v*"] + (["--merged", ref] if ref else [])
    tags = [t for t in git(root, *args).stdout.split() if tag_version(t)]
    return sorted(tags, key=tag_version)


def changed_since(root, base, ref):
    return git(root, "diff", "--quiet", base, ref, "--", f"{FOLDER}/", check=False).returncode != 0


def portal_versions(name, source=None):
    """the versions the mod portal has of name ({} when it does not know the mod)"""
    url = source or PORTAL_API + name
    if not re.match(r"https?://", url):
        data = json.loads(Path(url).read_text(encoding="utf-8"))
    else:
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                data = json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return set()
            raise
    return {r["version"] for r in data.get("releases", [])}


def decide(root=ROOT, ref="HEAD", release_tag=None, portal=(), hand=None):
    """{name, title, version, last_tag, changed, new, notes: [line], problems: [line]} of the texture mod at ref"""
    hand = HAND_RELEASES if hand is None else hand
    out = {"notes": [], "problems": []}
    info = show_json(root, ref, f"{FOLDER}/info.json")
    if info is None:
        out["problems"].append(f"{FOLDER}/info.json is missing")
        return out
    v = info["version"]
    out.update(name=info["name"], title=info.get("title", info["name"]), version=v)
    tags = [t for t in release_tags(root, ref) if t != release_tag]
    last = tags[-1] if tags else None
    out["last_tag"] = last
    # every version an earlier release used, and where
    used = {}
    for t in release_tags(root):
        tv = None if t == release_tag else show_json(root, t, f"{FOLDER}/info.json")
        if tv:
            used.setdefault(tv["version"], f"release {t}")
    for hv, commit in hand.items():
        used.setdefault(hv, f"the hand upload from {commit[:7]}")
    for pv in portal:
        used.setdefault(pv, "the mod portal")
    at_last = show_json(root, last, f"{FOLDER}/info.json") if last else None
    out["changed"] = changed = at_last is None or changed_since(root, last, ref)
    since = f"since {last}" if last else "(no earlier release tag)"
    if not changed:
        out["new"] = False
        out["notes"].append(f"{FOLDER}/ is unchanged {since}: {info['name']} {v} is released already; "
                            "no texture zip is attached or uploaded.")
        return out
    if v in hand and not changed_since(root, hand[v], ref):
        out["new"] = False
        out["notes"].append(f"{FOLDER}/ changed {since}, but it is {v} as uploaded by hand from {hand[v][:7]}: "
                            "no texture zip is attached or uploaded.")
        return out
    out["new"] = True
    if v in used:
        out["problems"].append(f"{FOLDER}/ changed {since}, but {FOLDER}/info.json version {v} was released already "
                               f"({used[v]}). Give the texture mod a new version.")
    log = git(root, "show", f"{ref}:{FOLDER}/changelog.txt", check=False)
    if log.returncode != 0 or not re.search(rf"^Version: {re.escape(v)}\s*$", log.stdout, re.M):
        out["problems"].append(f"{FOLDER}/changelog.txt has no section 'Version: {v}'.")
    if not out["problems"]:
        out["notes"].append(f"{FOLDER}/ changed {since}: {info['name']} {v} is new; the release attaches its zip "
                            "and uploads it to the mod portal.")
    return out


def outputs(d):
    zip_ = f"dist/{d['name']}_{d['version']}.zip"
    return {"textures_name": d["name"], "textures_title": d["title"], "textures_version": d["version"],
            "textures_zip": zip_, "textures_new": "true" if d["new"] else "false",
            "textures_attach": zip_ if d["new"] else ""}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--ref", default="HEAD")
    ap.add_argument("--release-tag", help="the tag of the release being made (vX.Y.Z), not an earlier release")
    ap.add_argument("--portal-json", help="the portal's answer from this file or URL (self-test)")
    ap.add_argument("--no-portal", action="store_true", help="do not ask the mod portal")
    ap.add_argument("--output", type=Path, help="append key=value lines to this file (GITHUB_OUTPUT)")
    a = ap.parse_args(argv)
    info = show_json(a.root, a.ref, f"{FOLDER}/info.json")
    portal = set()
    if info and not a.no_portal:
        try:
            portal = portal_versions(info["name"], a.portal_json)
        except (OSError, ValueError) as e:
            print(f"::error::cannot read the mod portal's versions of {info['name']}: {e}")
            return 1
    d = decide(a.root, a.ref, a.release_tag, portal)
    for n in d["notes"]:
        print(n)
    for p in d["problems"]:
        print(f"::error::{p}")
    if d["problems"]:
        return 1
    if a.output:
        with open(a.output, "a", encoding="utf-8", newline="\n") as f:
            f.write("".join(f"{k}={v}\n" for k, v in outputs(d).items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
