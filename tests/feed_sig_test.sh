#!/system/bin/sh
# Host test for the feed-signature policy in module/fingerprint-update.sh.
#
#   sh tests/feed_sig_test.sh
#
# The three states and what each must do when the feed has no .sig, when it
# has a valid one, and when it has a bad one. This is the regression for the
# hardcoded REQUIRE_FEED_SIG=0, and for the trap in the other direction: making
# verification unconditionally required would stop every profile update, since
# neither feed publishes .sig today.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SCRIPT="$REPO/module/fingerprint-update.sh"

TMP=${TMPDIR:-/data/local/tmp}/copgvd-feedsig.$$
mkdir -p "$TMP/data"
trap 'rm -rf "$TMP"' EXIT INT TERM

FAIL=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }

# A config file the script's cfg_setting() can read.
write_cfg() {  # write_cfg <feed_signature value or empty>
    {
        echo '{'
        echo '  "COPG-VD-Settings": {'
        if [ -n "$1" ]; then echo "    \"feed_signature\": \"$1\","; fi
        echo '    "autoupdate": false'
        echo '  }'
        echo '}'
    } > "$TMP/data/COPG-VD.json"
}

# Load just the policy block out of the script, plus require_sig() itself with
# its dependencies stubbed, so the test does not need a device or network.
load_policy() {
    sed -n '/^# --- feed signature/,/^FEED_KEY_ID=/p' "$SCRIPT"
    # require_sig(): from its definition to the closing brace at column 0.
    sed -n '/^require_sig()/,/^}/p' "$SCRIPT"
}

run_case() {  # run_case <label> <feed_signature setting> <expected: ok|refuse>
    label=$1; setting=$2; expect=$3
    write_cfg "$setting"
    out=$(
        # Stubs first: the policy block calls cfg_setting() while it is being
        # evaluated, so it must already exist.
        SIG_PRESENT=${SIG_PRESENT:-0}
        SIG_VALID=${SIG_VALID:-0}
        export SIG_PRESENT SIG_VALID
        CFG_FILE="$TMP/data/COPG-VD.json"
        cfg_setting() {
            tr -d '\n' < "$CFG_FILE" 2>/dev/null \
              | grep -o '"COPG-VD-Settings"[[:space:]]*:[[:space:]]*{[^}]*}' \
              | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|true|false)" | head -n 1 \
              | sed 's/.*:[[:space:]]*//; s/"//g'
        }
        log() { :; }
        download_to() {
            # download_to <url> <dest>
            case "$1" in
                *.sig)
                    [ "$SIG_PRESENT" = 1 ] || return 1
                    printf 'vd-fp-2026:AAAA' > "$2" || return 1
                    return 0;;
            esac
            return 1
        }
        verify_feed_sig() { [ "$SIG_VALID" = 1 ]; }
        # shellcheck disable=SC2046
        eval "$(load_policy)"
        # A policy that cannot see its own mode is a broken harness, not a
        # passing case: fail loudly instead of letting 127 look like "refused".
        case "${FEED_SIG_MODE:-}" in
            required|auto|off) : ;;
            *) echo "HARNESS: FEED_SIG_MODE unset (policy block did not evaluate)"; exit 99;;
        esac
        require_sig "$TMP/fake.json" https://feed.example/x.json
        echo "rc=$?"
    )
    rc=$(printf '%s' "$out" | sed -n 's/.*rc=//p' | tail -n 1)
    if printf '%s' "$out" | grep -q HARNESS; then
        bad "$label: harness error"
        return
    fi
    case "$expect" in
        ok)      [ "$rc" = 0 ] && ok "$label" || bad "$label (rc=$rc, want accept)";;
        refuse)  [ "$rc" = 1 ] && ok "$label" || bad "$label (rc=$rc, want refuse)";;
    esac
}

echo "mode resolution"
for pair in \
    "required:required" \
    "auto:auto" \
    "off:off" \
    "REQUIRED:required" \
    "OFF:off" \
    ":auto" \
    "garbage:auto" \
    "require:auto"
do
    setting=${pair%%:*}; want=${pair#*:}
    write_cfg "$setting"
    got=$(
        CFG_FILE="$TMP/data/COPG-VD.json"
        cfg_setting() {
            tr -d '\n' < "$CFG_FILE" 2>/dev/null \
              | grep -o '"COPG-VD-Settings"[[:space:]]*:[[:space:]]*{[^}]*}' \
              | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|true|false)" | head -n 1 \
              | sed 's/.*:[[:space:]]*//; s/"//g'
        }
        eval "$(load_policy)"
        printf '%s' "$FEED_SIG_MODE"
    )
    [ "$got" = "$want" ] && ok "feed_signature='$setting' -> $got" || bad "'$setting' resolved to '$got', want $want"
done

echo "policy: feed has no .sig (the state both feeds are in today)"
SIG_PRESENT=0; export SIG_PRESENT
for pair in "required:refuse" "auto:ok" "off:ok" ":ok" "garbage:ok"
do
    run_case "no .sig, feed_signature='${pair%%:*}'" "${pair%%:*}" "${pair#*:}"
done

echo "policy: feed has a .sig"
SIG_PRESENT=1; export SIG_PRESENT
SIG_VALID=1; export SIG_VALID
run_case "valid .sig, feed_signature=required" required ok
run_case "valid .sig, feed_signature=off (skips the fetch)" off ok
SIG_VALID=0; export SIG_VALID
run_case "bad .sig, feed_signature=required" required refuse
run_case "bad .sig, feed_signature=auto" auto refuse
unset SIG_VALID SIG_PRESENT

if [ "$FAIL" -gt 0 ]; then echo; echo "$FAIL failure(s)"; exit 1; fi
echo
echo "all feed-signature tests passed"
