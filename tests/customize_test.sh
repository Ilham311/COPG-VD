#!/system/bin/sh
# Test module/customize.sh's post-prompt logic without flashing anything.
#
#   sh tests/customize_test.sh
#
# It runs the real customize.sh in a fake root: /data is redirected by sourcing
# only the functions we test after rewriting the absolute paths, because the
# script hard-codes /data/adb. What is checked is the behaviour that broke a
# real install: a conflicting module present must NOT abort, must be removed via
# the manager's markers, and must be copied somewhere recoverable first.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SRC="$REPO/module/customize.sh"

TMP=${TMPDIR:-${TEMP:-${TMP:-/tmp}}}/copgvd-inst.$$
mkdir -p "$TMP/data/modules/playintegrityfix" "$TMP/data/modules/other" 2>/dev/null ||
    { echo "cannot create a work dir at $TMP"; exit 2; }
trap 'rm -rf "$TMP"' EXIT INT TERM

FAIL=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }

# Minimal harness: the pieces of customize.sh the function needs.
# customize.sh runs under the manager's shell WITHOUT `set -u`, and its code
# reads optional variables (COPGVD_CONFLICT_KEEP) directly. The harness must
# match that or it fails where the real installer succeeds.
set +u

ui_print() { echo "$1"; }
print_box_start() { :; }
print_box_end() { :; }
print_empty_line() { :; }
print_failure_and_exit() { echo "  !! would ABORT the install"; return 1; }

# Pull in only check_conflict_modules(), with /data/adb pointed at the fixture.
eval "$(sed -n '/^check_conflict_modules()/,/^}/p' "$SRC" \
        | sed "s|/data/adb|$TMP/data|g")"
DATA_DIR="$TMP/data/COPG-VD"
CONFLICT_MODULES="COPG playintegrity playintegrityfix [i][n][t][e][g][r][i][t][y][-]*[b][o][x]"

echo "conflicting module present"
printf 'marker' > "$TMP/data/modules/playintegrityfix/module.prop"

out=$(check_conflict_modules 2>&1); rc=$?
[ "$rc" = 0 ] && ok "does not abort the install (rc=0)" || bad "returned $rc"
case "$out" in *ABORT*) bad "aborted";; *) ok "never calls print_failure_and_exit";; esac
case "$out" in *"removed: playintegrityfix"*) ok "reports the removal";; *) bad "no removal line: $out";; esac

[ -f "$TMP/data/modules/playintegrityfix/remove" ] && ok "sets the manager's remove marker" ||
    bad "no remove marker"
[ -f "$TMP/data/modules/playintegrityfix/disable" ] && ok "sets the disable marker" ||
    bad "no disable marker"

kept=$(find "$DATA_DIR/removed-modules" -maxdepth 2 -name playintegrityfix -type d 2>/dev/null | head -n 1)
if [ -n "$kept" ] && [ -f "$kept/module.prop" ]; then
    ok "keeps a recoverable copy ($kept)"
else
    bad "no recoverable copy under $DATA_DIR/removed-modules"
fi

# A module that is NOT a conflict must be untouched.
[ -f "$TMP/data/modules/other/remove" ] && bad "removed an unrelated module" ||
    ok "leaves unrelated modules alone"

echo "no conflict present"
rm -rf "$TMP/data/modules/playintegrityfix"
out=$(check_conflict_modules 2>&1)
case "$out" in *"Conflicting"*) bad "prompted with nothing to remove";; *) ok "silent when clean";; esac

echo "escape hatch"
mkdir -p "$TMP/data/modules/playintegrityfix"
out=$(COPGVD_CONFLICT_KEEP=1 check_conflict_modules 2>&1)
case "$out" in *"leaving them in place"*) ok "COPGVD_CONFLICT_KEEP keeps them";; *) bad "escape hatch ignored: $out";; esac
[ -f "$TMP/data/modules/playintegrityfix/remove" ] && bad "removed despite KEEP" || ok "not removed with KEEP set"

if [ "$FAIL" -gt 0 ]; then echo; echo "$FAIL failure(s)"; exit 1; fi
echo
echo "all installer tests passed"
