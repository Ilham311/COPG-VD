#!/usr/bin/env bash
# Host test suite. Everything here runs without a device.
#
#   ./tests/run_host_tests.sh
#
# Needs: a JDK (javac, java), android.jar, d8 for the dex build check.
# Everything else is standard POSIX tools. A rooted device is NOT required -
# the device-only probes live in tests/device and are described in
# tests/README.md.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-${TEMP:-${TMP:-/tmp}}}/copgvd-hosttest.$$"
mkdir -p "$WORK" 2>/dev/null || { echo "cannot create a work dir at $WORK"; exit 2; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
step() { printf '\n== %s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); }
no()   { FAIL=$((FAIL + 1)); printf '   FAILED: %s\n' "$*"; }

# ---------------------------------------------------------------- locate SDK
find_android_jar() {
    for c in \
        "${ANDROID_JAR:-}" \
        "$(ls -d "$ANDROID_SDK_ROOT"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)" \
        "$(ls -d "$HOME/Android/Sdk"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)" \
        /data/data/com.termux/files/usr/share/java/android.jar \
        /usr/lib/android-sdk/platforms/android-*/android.jar
    do
        [ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

AJ=$(find_android_jar) || { echo "android.jar not found; set ANDROID_JAR"; exit 2; }
echo "android.jar: $AJ"

# ------------------------------------------------------------- java sources
step "compile dex sources"
mkdir -p "$WORK/classes"
if javac --release 11 -cp "$AJ" -d "$WORK/classes" \
        $(find "$ROOT/dex/src" -name '*.java'); then
    echo "   javac ok"; ok
else
    no "javac"; exit 1
fi

# --------------------------------------------------------------- java tests
step "identity: SSAID derivation, crypto vectors, validators"
mkdir -p "$WORK/test-classes"
if javac -cp "$AJ:$WORK/classes" -d "$WORK/test-classes" \
        "$ROOT/tests/IdentityHostTest.java"; then
    if java -cp "$AJ:$WORK/classes:$WORK/test-classes" com.vd171.copgvd.IdentityHostTest; then
        ok
    else
        no "IdentityHostTest"
    fi
else
    no "compile IdentityHostTest"
fi

step "identity: the Java port and the independent Python reference agree"
if python3 "$ROOT/tests/identity_reference.py" >/dev/null 2>&1; then
    # Both sides emit the same vectors; compare them rather than trusting that
    # each self-check is enough.
    # The Java side below covers the first three vectors; the fourth (a 1.2 KB
    # DER certificate) is checked by IdentityHostTest against the same value.
    PY=$(python3 "$ROOT/tests/identity_reference.py" --vectors |
         python3 -c 'import json,sys; print(" ".join(v["ssaid"] for v in json.load(sys.stdin)[:3]))')
    JAVA=$(java -cp "$AJ:$WORK/classes" com.vd171.copgvd.Identity 2>/dev/null || true)
    cat > "$WORK/CrossCheck.java" <<'JAVA_EOF'
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
public final class CrossCheck {
    public static void main(String[] a) throws Exception {
        Method m = Class.forName("com.vd171.copgvd.Identity")
                .getDeclaredMethod("ssaid", String.class, byte[][].class);
        m.setAccessible(true);
        String[] keys = {
            "00112233445566778899aabbccddeeff",
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
            "AABBCCDDEEFF00112233445566778899"};
        byte[][] sigs = {a[1].getBytes(StandardCharsets.UTF_8)};
        byte[][] sigs2 = {a[2].getBytes(StandardCharsets.UTF_8), a[3].getBytes(StandardCharsets.UTF_8)};
        StringBuilder sb = new StringBuilder();
        sb.append(m.invoke(null, keys[0], (Object) new byte[][][]{sigs}[0])).append(' ');
        sb.append(m.invoke(null, keys[1], (Object) new byte[][][]{sigs}[0])).append(' ');
        sb.append(m.invoke(null, keys[2], (Object) new byte[][][]{sigs2}[0]));
        System.out.println(sb);
    }
}
JAVA_EOF
    javac -cp "$WORK/classes" -d "$WORK/test-classes" "$WORK/CrossCheck.java" 2>/dev/null &&
    JV=$(java -cp "$AJ:$WORK/classes:$WORK/test-classes" CrossCheck signature-one signature-one sigA signature-B 2>/dev/null)
    if [ "$PY" = "$JV" ]; then
        echo "   $PY"; ok
    else
        no "python/java vectors differ: py=[$PY] java=[$JV]"
    fi
else
    no "identity_reference.py"
fi

# -------------------------------------------------------------- shell tests
step "identity.sh: generators, validators, backups (fake root)"
if sh "$ROOT/tests/identity_sh_test.sh"; then ok; else no "identity_sh_test.sh"; fi

step "identity.sh: derive path consumes the helper correctly"
if sh "$ROOT/tests/identity_derive_test.sh" "$WORK/classes" "$AJ"; then ok; else no "identity_derive_test.sh"; fi

# ------------------------------------------------------------ script syntax
step "shell syntax"
for f in "$ROOT"/module/*.sh "$ROOT"/module/vdlu/update.sh "$ROOT"/module/vdlu/vdlu-verify; do
    [ -f "$f" ] || continue
    if sh -n "$f" 2>/dev/null; then ok; else no "syntax: ${f#$ROOT/}"; fi
done

step "feed signature: three states, fail-closed"
if sh "$ROOT/tests/feed_sig_test.sh" >/dev/null; then ok; else no "feed_sig_test.sh"; fi

# ------------------------------------------------------- scope regression
step "scope decision table (the fail-open regression)"
if command -v g++ >/dev/null 2>&1 || command -v clang++ >/dev/null 2>&1; then
    CXX_BIN=$(command -v g++ || command -v clang++)
    if "$CXX_BIN" -std=c++17 -O1 -o "$WORK/scope_test" "$ROOT/tests/scope_test.cpp" 2>/dev/null &&
       "$WORK/scope_test" >/dev/null; then
        echo "   scope table ok"; ok
    else
        no "scope_test"
    fi
else
    echo "   skipped (no C++ compiler for the host)"
fi

# ------------------------------------------------------------- native build
step "native module compiles for all three ABIs"
NDK="${ANDROID_NDK_HOME:-}"
if [ -n "$NDK" ] && [ -d "$NDK" ]; then
    for abi in arm64-v8a armeabi-v7a x86_64; do
        if cmake -S "$ROOT/zygisk" -B "$WORK/native-$abi" \
                -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
                -DANDROID_ABI="$abi" -DANDROID_PLATFORM=android-28 \
                -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1 &&
           cmake --build "$WORK/native-$abi" --parallel >/dev/null 2>&1; then
            ok
        else
            no "native build $abi"
        fi
    done
elif command -v clang++ >/dev/null 2>&1 && clang++ -target aarch64-linux-android24 -E -x c /dev/null >/dev/null 2>&1; then
    # Termux clang can target Android directly; use it as a syntax gate.
    for abi in aarch64-linux-android24 armv7a-linux-androideabi24 x86_64-linux-android24; do
        if clang++ -target "$abi" -std=c++17 -fsyntax-only \
                -fno-exceptions -fno-rtti -I"$ROOT/zygisk" \
                "$ROOT/zygisk/spoof_module.cpp" 2>/dev/null; then
            ok
        else
            no "native syntax $abi"
        fi
    done
else
    echo "   skipped (no NDK and no Android-capable clang)"
fi

# --------------------------------------------------------- config invariants
step "example config matches what the parser reads"
python3 - "$ROOT/module/COPG-VD.json.example" <<'PY'
import json, sys
path = sys.argv[1]
d = json.load(open(path))
errs = []
if not isinstance(d.get('process_overrides'), dict):
    errs.append('process_overrides must be an object')
if d.get('prop_method') not in ('mmap', 'off'):
    errs.append('prop_method must be mmap or off')
if d.get('scope_mode') not in ('playstore', 'global', 'whitelist', 'blacklist'):
    errs.append('scope_mode must be a known mode')
ident = d.get('COPG-VD-Identity')
if not isinstance(ident, dict):
    errs.append('COPG-VD-Identity block missing')
else:
    if ident.get('enabled') is not False:
        errs.append('identity must ship disabled')
# Every key the C++ parser looks for at the top level
known = {'Instructions','Strings extracted from','scope_mode','scope_whitelist',
         'scope_blacklist','scope_playstore_targets','motor_jni','motor_prop_hook',
         'prop_method','motor_drm','drm_targets','global_fields','process_overrides',
         'verbose_logs','COPG-VD','COPG-VD-Delete','COPG-VD-Settings',
         'COPG-VD-Identity','resetprop'}
unknown = set(d) - known
if unknown:
    errs.append('keys the module ignores: %s' % ', '.join(sorted(unknown)))
for e in errs:
    print('   FAILED:', e)
sys.exit(1 if errs else 0)
PY
if [ $? -eq 0 ]; then echo "   config invariants ok"; ok; else no "config invariants"; fi

# ------------------------------------------------------------------ summary
printf '\n-------------------------\n%d step(s) passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
