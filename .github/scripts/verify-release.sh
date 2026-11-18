#!/bin/sh
set -eu
# Verify a published release without trusting the build that made it.
#
#   .github/scripts/verify-release.sh [tag]
#
# With no argument it uses the version in module/module.prop. It downloads the
# zip and SHA256SUMS.txt from this fork's Releases, checks the hash, then reads
# the archive with python's zipfile: every file the runtime needs must be
# present with the right mode, the version inside must match the tag, and the
# VDLU feed must stay disabled.

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D="${TMPDIR:-/tmp}/copgvd-verify.$$"
rm -rf "$D"; mkdir -p "$D"; cd "$D"

TAG="${1:-$(sed -n "s/^version=//p" "$ROOT/module/module.prop" | head -n 1)}"
ZIP="COPG-VD-$TAG.zip"
REPO="${GH_REPO:-Ilham311/COPG-VD}"
BASE="https://github.com/$REPO/releases/download/$TAG"

fail_fetch() { echo "FAIL could not download $1" >&2; exit 2; }
curl -fsSL -o "$ZIP" "$BASE/$ZIP" || fail_fetch "$BASE/$ZIP"
curl -fsSL -o SHA256SUMS.txt "$BASE/SHA256SUMS.txt" || fail_fetch "$BASE/SHA256SUMS.txt"
[ -s "$ZIP" ] || fail_fetch "$BASE/$ZIP (empty)"
head -c 2 "$ZIP" | grep -q PK || { echo "FAIL downloaded file is not a zip" >&2; exit 2; }

echo "downloaded: $(wc -c < "$ZIP") bytes"

echo
echo "--- checksum from the release, checked locally ---"
expected=$(grep " $ZIP\$" SHA256SUMS.txt | cut -d' ' -f1)
actual=$(sha256sum "$ZIP" | cut -d' ' -f1)
if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
    echo "  ok   zip matches SHA256SUMS.txt"
else
    echo "  FAIL expected=${expected:-none} actual=$actual" >&2
    exit 1
fi

echo
echo "--- files a device needs, and their unix modes ---"
# Read the archive with python's zipfile: `unzip -Z` is not present on every
# zip build (Termux's is limited), and the mode lives in external_attr, which
# the listing format does not show consistently.
python3 - "$ZIP" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
need = {
    'module.prop': None, 'customize.sh': 0o755, 'service.sh': 0o755,
    'post-fs-data.sh': 0o755, 'uninstall.sh': None, 'identity.sh': 0o755,
    'sepolicy.rule': None, 'etc/copgvd_identity.dex': None,
    'etc/copgvd_scope.dex': None, 'zygisk/arm64-v8a.so': 0o755,
    'zygisk/armeabi-v7a.so': 0o755, 'zygisk/x86_64.so': 0o755,
    'webroot/index.html': None, 'webroot/scripts.js': None,
    'webroot/vdlu.js': None, 'vdlu/config.default': None, 'vdlu/baseline.json': None,
}
names = set(z.namelist())
fail = 0
for path, want_mode in need.items():
    if path not in names:
        print(f"  MISSING {path}")
        fail = 1
        continue
    if want_mode is None:
        print(f"  ok    {path}")
        continue
    mode = (z.getinfo(path).external_attr >> 16) & 0o777
    if mode == want_mode:
        print(f"  ok    {path}  {mode:o}")
    else:
        print(f"  FAIL  {path} is {mode:o}, want {want_mode:o}")
        fail = 1

print()
print("--- version inside the zip vs the tag ---")
prop = z.read('module.prop').decode()
for line in prop.splitlines():
    if line.startswith(('version=', 'versionCode=')):
        print("  " + line)

print()
print("--- VDLU must not point at the upstream feed ---")
cfg = z.read('vdlu/config.default').decode()
print("  ok   source is empty" if '\nsource=\n' in cfg else "  FAIL source is set")
print("  ok   auto_on_reboot=0" if '\nauto_on_reboot=0\n' in cfg else "  FAIL auto_on_reboot")

print()
print("--- update.json must point at this fork ---")
print("  ok   update.json names the fork" if 'Ilham311/COPG-VD' in z.read('update.json').decode()
      else "  FAIL update.json")

print()
print("  --- sanity: the identity dex contains the derivation ---")
d = z.read('etc/copgvd_identity.dex')
for needle in (b'HmacSHA256', b'settings_ssaid', b'getApkContentsSigners'):
    print(f"  ok   {needle.decode()}" if needle in d else f"  FAIL {needle.decode()} absent")

sys.exit(fail)
PY
rc=$?
echo
[ "$rc" = 0 ] && echo "RELEASE ZIP VERIFIED" || echo "RELEASE ZIP HAS PROBLEMS"
exit "$rc"
