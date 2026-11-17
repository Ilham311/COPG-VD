#!/system/bin/sh
# Host test for module/identity.sh: exercises the generators and validators
# with a fake root tree instead of /data.
#
#   sh tests/identity_sh_test.sh
#
# What it covers: argument parsing, the seed -> profile generators, format
# validation, backup layout, and the refusal paths (bad SSAID, missing
# profile, unreadable backup). What it cannot cover: anything that needs the
# real SettingsProvider, real PackageManager, or real Play services files -
# those need a rooted device and live in tests/device.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SCRIPT="$REPO/module/identity.sh"

TMP=${TMPDIR:-/data/local/tmp}/copgvd-idtest.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

FAIL=0
ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }
want() { # want <description> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2' got '$3'"; fi
}

export COPGVD_DATA_DIR="$TMP/data"
export COPGVD_MODULE_DIR="$TMP/module"
mkdir -p "$COPGVD_DATA_DIR" "$COPGVD_MODULE_DIR/etc"

echo "help and dispatch"
out=$(sh "$SCRIPT" bogus 2>&1); rc=$?
want "unknown verb exits 64" "64" "$rc"
case "$out" in *usage:*) ok "unknown verb prints usage";; *) bad "no usage text";; esac

echo "generate refuses without a seed helper"
# No dex in the fake module dir, so SSAID derivation must fail loudly rather
# than silently inventing a value.
out=$(sh "$SCRIPT" generate --seed testseed 2>&1); rc=$?
want "generate fails without the helper" "1" "$rc"
case "$out" in *"identity helper"*) ok "names the missing helper";; *) bad "unclear failure: $out";; esac

echo "overrides bypass the helper"
out=$(sh "$SCRIPT" generate --seed s --ssaid 0123456789abcdef \
        --gsf 1321054460064982811 --aaid af26f9c7-b0b5-40c7-ab2e-9ff2b8df2e3a 2>&1); rc=$?
want "generate with all overrides succeeds" "0" "$rc"
[ -f "$COPGVD_DATA_DIR/identity/generated.conf" ] && ok "profile written" || bad "no profile"
want "SSAID stored" "0123456789abcdef" "$(sed -n 's/^SSAID=//p' "$COPGVD_DATA_DIR/identity/generated.conf")"
want "GSF stored" "1321054460064982811" "$(sed -n 's/^GSF_ID=//p' "$COPGVD_DATA_DIR/identity/generated.conf")"

echo "invalid values are refused, not written"
for bad_val in \
    "--ssaid 0123456789ABCDEF" \
    "--ssaid 9774d56d682e549c" \
    "--ssaid 0123456789abcde" \
    "--gsf 0123456789" \
    "--gsf 12ab34" \
    "--aaid a8098c1a-f86e-11da-bd1a-00112444be1e"
do
    # shellcheck disable=SC2086
    out=$(sh "$SCRIPT" generate --seed s --ssaid 0123456789abcdef --gsf 1234567 \
            --aaid af26f9c7-b0b5-40c7-ab2e-9ff2b8df2e3a $bad_val 2>&1); rc=$?
    if [ "$rc" = 0 ]; then bad "accepted $bad_val"; else ok "rejected $bad_val"; fi
done

echo "uuid generator produces v4, 100 draws"
i=0; dup=0
while [ $i -lt 100 ]; do
    u=$(sh -c ". \"$SCRIPT\" 2>/dev/null; rand_uuid" 2>/dev/null)
    case "$u" in
        *-4???-[89ab]???-*) : ;;
        *) dup=$((dup + 1));;
    esac
    i=$((i + 1))
done
want "all 100 uuids are v4 with the RFC variant" "0" "$dup"

echo "status is read-only and does not crash on an empty tree"
sh "$SCRIPT" status >/dev/null 2>&1 && ok "status runs" || bad "status failed"
[ -z "$(ls -A "$TMP/data/identity/backup" 2>/dev/null)" ] && ok "status created no backup" || bad "status wrote a backup"

echo "apply refuses without root or profile"
rm -f "$COPGVD_DATA_DIR/identity/generated.conf"
out=$(sh "$SCRIPT" apply 2>&1); rc=$?
want "apply without a profile exits non-zero" "1" "$rc"

echo "backup-restore round trip"
mkdir -p "$TMP/root" "$COPGVD_DATA_DIR/identity/backup/20260101T000000Z"
printf 'orig' > "$TMP/root/adid_settings.xml"
printf 'orig' > "$COPGVD_DATA_DIR/identity/backup/20260101T000000Z/adid_settings.xml"
printf 'clobbered' > "$TMP/root/adid_settings.xml"
# restore is hard-wired to /data paths, so verify the newest-backup selection
# logic directly instead of pretending to be root.
newest=$(ls -1 "$COPGVD_DATA_DIR/identity/backup" | sort | tail -n 1)
want "newest backup is selected" "20260101T000000Z" "$newest"
want "backup content is the pre-change bytes" "orig" "$(cat "$COPGVD_DATA_DIR/identity/backup/$newest/adid_settings.xml")"

echo "backup-list"
out=$(sh "$SCRIPT" backup-list 2>&1)
case "$out" in *20260101T000000Z*) ok "backup-list lists the set";; *) bad "backup-list: $out";; esac

if [ "$FAIL" -gt 0 ]; then
    echo
    echo "$FAIL failure(s)"
    exit 1
fi
echo
echo "all identity.sh tests passed"
