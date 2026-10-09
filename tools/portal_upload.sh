#!/usr/bin/env bash
# Uploads one mod zip to the Factorio mod portal (issue #243); .github/workflows/release.yml runs it for me-network
# and for the texture mod me-network-ae2-textures, each in a step of its own.
#
#   API_KEY=<key> bash tools/portal_upload.sh <zip> <mod name>
#
# The mod name and the version come from the zip's own info.json (its one top folder must be <name>_<version>), and
# the zip must be of <mod name>: a zip only ever goes to its own mod's page. Skips (exit 0) when API_KEY is empty or
# the portal already has that version. The key is only sent as the Authorization header, never printed.
# PORTAL_URL (default https://mods.factorio.com) and PYTHON (default python3) are for the self-test
# (tools/devcheck/test_release_texture.py, a fake portal on 127.0.0.1).
set -eo pipefail
ZIP=$1
EXPECT=$2
PORTAL=${PORTAL_URL:-https://mods.factorio.com}
PY=${PYTHON:-python3}
if [ -z "$ZIP" ] || [ -z "$EXPECT" ]; then
  echo "::error::usage: portal_upload.sh <zip> <mod name>"
  exit 2
fi
INFO=$("$PY" -c '
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
tops = {n.split("/", 1)[0] for n in z.namelist()}
if len(tops) != 1:
    sys.exit("%s: more than one top folder %s" % (sys.argv[1], sorted(tops)))
top = tops.pop()
d = json.loads(z.read(top + "/info.json"))
if top != "%s_%s" % (d["name"], d["version"]):
    sys.exit("%s: top folder %s is not %s_%s of its info.json" % (sys.argv[1], top, d["name"], d["version"]))
print(d["name"], d["version"])
' "$ZIP")
MOD=${INFO% *}
VERSION=${INFO#* }
if [ "$MOD" != "$EXPECT" ]; then
  echo "::error::$ZIP is the mod $MOD, not $EXPECT: not uploaded."
  exit 1
fi
if [ -z "$API_KEY" ]; then
  echo "::warning::Secret FACTORIO_MOD_API_KEY is not set: skipping the mod portal upload of $MOD $VERSION."
  exit 0
fi
if curl -fsS "$PORTAL/api/mods/$MOD" \
     | VERSION="$VERSION" "$PY" -c "import json,sys,os;d=json.loads(sys.stdin.read() or '{}');sys.exit(0 if any(r['version']==os.environ['VERSION'] for r in d.get('releases',[])) else 1)"; then
  echo "The mod portal already has $MOD $VERSION: skipping the upload."
  exit 0
fi
UPLOAD_URL=$(curl -fsS -X POST "$PORTAL/api/v2/mods/releases/init_upload" \
               -H "Authorization: Bearer $API_KEY" -F "mod=$MOD" \
             | "$PY" -c "import json,sys;d=json.loads(sys.stdin.read() or '{}');print(d.get('upload_url') or sys.exit('init_upload failed: %s' % d))")
RESULT=$(curl -sS -X POST "$UPLOAD_URL" -F "file=@$ZIP")
echo "$RESULT"
echo "$RESULT" | "$PY" -c "import json,sys;d=json.loads(sys.stdin.read() or '{}');sys.exit(0 if d.get('success') else 'upload failed')"
echo "Uploaded $MOD $VERSION to $PORTAL/mod/$MOD"
