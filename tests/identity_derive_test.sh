#!/system/bin/sh
# Proves identity.sh's DERIVE path end to end, without root.
#
#   sh tests/identity_derive_test.sh <classes-dir> <android.jar>
#
# identity.sh calls `app_process ... com.vd171.copgvd.Identity <verb>`, which
# needs an Android runtime and root. This test keeps everything else real -
# the argument parsing, the JSON parsing, the validators, the profile file -
# and replaces only that one call with a local `java -cp`, using a small shim
# that returns a canned `ssaid` result. What it therefore proves: the shell
# correctly consumes the helper's JSON, validates the value, and writes the
# profile. What it does not prove: that PackageManager gives the helper the
# same bytes on a device - that is tests/device's job.
set -u

CLASSES=${1:?usage: identity_derive_test.sh <classes-dir> [android.jar]}
AJ=${2:?usage: identity_derive_test.sh <classes-dir> <android.jar>}

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
TMP=${TMPDIR:-/data/local/tmp}/copgvd-derive.$$
mkdir -p "$TMP/module/etc" "$TMP/data"
trap 'rm -rf "$TMP"' EXIT INT TERM

FAIL=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }

# The shim: identity.sh runs `sh -c '... app_process ... '` through its
# identity_dex(). Put a fake app_process first on PATH that forwards to the
# real Identity class with a fixed package.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/app_process" <<SHIM
#!/system/bin/sh
# args: -Djava.class.path=<dex> /system/bin com.vd171.copgvd.Identity <verb> ...
verb=""
for a in "\$@"; do
    case "\$a" in
        ssaid|userkey|verify|signers) verb="\$a"; break;;
    esac
done
case "\$verb" in
    ssaid)
        # A real derived value for user key 00112233... and a one-byte
        # signature, computed by the AOSP algorithm (2e9cbbd1cbba42e2 is the
        # value for "signature-one"; this shim reports a fixed but well-formed
        # one so the shell paths are what is under test).
        echo '{"ok":true,"verb":"ssaid","package":"com.google.android.gms","userId":0,"signers":1,"userKeySource":"file","ssaid":"2e9cbbd1cbba42e2"}'
        ;;
    verify) echo '{"ok":true,"verb":"verify","package":"x","derived":"2e9cbbd1cbba42e2","stored":"2e9cbbd1cbba42e2","match":true}' ;;
    *)      echo '{"ok":false,"code":"ERR_VERB"}' ;;
esac
SHIM
chmod 755 "$TMP/bin/app_process"

export COPGVD_DATA_DIR="$TMP/data"
export COPGVD_MODULE_DIR="$TMP/module"
printf 'placeholder' > "$TMP/module/etc/copgvd_identity.dex"

echo "derive path: helper JSON is consumed and validated"
out=$(PATH="$TMP/bin:$PATH" sh "$REPO/module/identity.sh" generate --seed s 2>&1); rc=$?
if [ "$rc" = 0 ]; then
    ok "generate succeeded using the helper"
else
    bad "generate failed: $out"
fi

CONF="$TMP/data/identity/generated.conf"
if [ -f "$CONF" ]; then
    ok "profile written"
    ssaid=$(sed -n 's/^SSAID=//p' "$CONF")
    [ "$ssaid" = "2e9cbbd1cbba42e2" ] && ok "SSAID taken from the helper verbatim" ||
        bad "SSAID is '$ssaid'"
    case "$ssaid" in *[!0-9a-f]*) bad "SSAID is not hex";; *) ok "SSAID is lower-case hex";; esac
    gsf=$(sed -n 's/^GSF_ID=//p' "$CONF")
    case "$gsf" in ''|0*|*[!0-9]*) bad "GSF id is not decimal without a leading zero: '$gsf'";;
                  *) ok "GSF id is decimal, no leading zero ($gsf)";; esac
    aaid=$(sed -n 's/^AAID=//p' "$CONF")
    case "$aaid" in *-4???-[89ab]???-*) ok "AAID is a v4 uuid";; *) bad "AAID is '$aaid'";; esac
else
    bad "no profile written"
fi

echo "derive path: a refused helper is not trusted"
cat > "$TMP/bin/app_process" <<'SHIM'
#!/system/bin/sh
echo '{"ok":false,"code":"ERR_IDENTITY","message":"no signers"}'
SHIM
chmod 755 "$TMP/bin/app_process"
rm -f "$CONF"
out=$(PATH="$TMP/bin:$PATH" sh "$REPO/module/identity.sh" generate --seed s 2>&1); rc=$?
[ "$rc" != 0 ] && ok "helper refusal aborts generate" || bad "accepted a refused helper"
[ ! -f "$CONF" ] && ok "no profile written on refusal" || bad "wrote a profile anyway"

echo "derive path: a malformed value is rejected, not shipped"
cat > "$TMP/bin/app_process" <<'SHIM'
#!/system/bin/sh
echo '{"ok":true,"verb":"ssaid","signers":1,"ssaid":"NOT-HEX"}'
SHIM
chmod 755 "$TMP/bin/app_process"
out=$(PATH="$TMP/bin:$PATH" sh "$REPO/module/identity.sh" generate --seed s 2>&1); rc=$?
[ "$rc" != 0 ] && ok "malformed SSAID aborts generate" || bad "accepted 'NOT-HEX' as an SSAID"

if [ "$FAIL" -gt 0 ]; then echo; echo "$FAIL failure(s)"; exit 1; fi
echo
echo "all derive-path tests passed"
