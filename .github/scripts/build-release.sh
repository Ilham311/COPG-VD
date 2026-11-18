#!/usr/bin/env bash
# ======================================================================
#  COPG-VD  ::  build the release zip
#
#  One script, used by CI and by hand. It never invents a version: the
#  version comes from module/module.prop and nowhere else.
#
#      .github/scripts/build-release.sh [--out DIR] [--skip-tests]
#
#  Inputs it needs in the tree (CI produces these first):
#      zygisk/build/<abi>/libspoof.so     the native module, per ABI
#      module/etc/copgvd_scope.dex        javac + d8 of dex/src (Scope)
#      module/etc/copgvd_identity.dex     javac + d8 of dex/src (Identity)
#
#  It builds the dex files itself if they are missing and a JDK + android.jar
#  are available, so a local run does not depend on remembering the order.
# ======================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT"
SKIP_TESTS=0
EXPECTED_ABIS="arm64-v8a armeabi-v7a x86_64"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --skip-tests) SKIP_TESTS=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

cd "$ROOT"

prop() { sed -n "s/^$1=//p" module/module.prop | head -n 1; }
VERSION="$(prop version)"
VERSION_CODE="$(prop versionCode)"
[ -n "$VERSION" ] || { echo "::error::no version in module/module.prop" >&2; exit 1; }
[ -n "$VERSION_CODE" ] || { echo "::error::no versionCode in module/module.prop" >&2; exit 1; }
ZIP_NAME="COPG-VD-${VERSION}.zip"

echo "building $ZIP_NAME (versionCode $VERSION_CODE)"

# ---------------------------------------------------------------- tests
if [ "$SKIP_TESTS" = 0 ] && [ -x tests/run_host_tests.sh ]; then
    echo "running the host suite first"
    ANDROID_JAR="${ANDROID_JAR:-}" bash tests/run_host_tests.sh
fi

# ------------------------------------------------------------------ dex
find_android_jar() {
    for c in \
        "${ANDROID_JAR:-}" \
        "${ANDROID_SDK_ROOT:-/nonexistent}/platforms/android-35/android.jar" \
        "$(ls -d "${ANDROID_SDK_ROOT:-/nonexistent}"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)" \
        "$(ls -d "$HOME/Android/Sdk"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)" \
        /usr/local/lib/android/sdk/platforms/android-*/android.jar \
        /data/data/com.termux/files/usr/share/java/android.jar
    do
        [ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

need_dex=0
for f in module/etc/copgvd_scope.dex module/etc/copgvd_identity.dex; do
    [ -s "$f" ] || need_dex=1
done
if [ "$need_dex" = 1 ]; then
    if AJ=$(find_android_jar) && command -v javac >/dev/null && command -v d8 >/dev/null; then
        echo "building the dex helpers (android.jar: $AJ)"
        ANDROID_JAR="$AJ" ANDROID_SDK_ROOT="$(dirname "$(dirname "$AJ")")" bash dex/build.sh
    else
        echo "::error::dex helpers missing and no JDK/android.jar to build them" >&2
        exit 1
    fi
fi

# ------------------------------------------------------------------ ABI
missing=""
for abi in $EXPECTED_ABIS; do
    [ -f "zygisk/build/$abi/libspoof.so" ] || missing="$missing $abi"
done
if [ -n "$missing" ]; then
    echo "::error::native library missing for:$missing" >&2
    echo "  build it with the NDK first; see the 'Build zygisk libraries' CI step" >&2
    exit 1
fi

# ------------------------------------------------------- module assembly
echo "staging module/zygisk/<abi>.so"
mkdir -p module/zygisk
for abi in $EXPECTED_ABIS; do
    cp -f "zygisk/build/$abi/libspoof.so" "module/zygisk/$abi.so"
    chmod 0755 "module/zygisk/$abi.so"
done

# The WebUI reads these locally instead of fetching them from GitHub.
[ -f README.md ] && cp -f README.md module/webroot/README.md
[ -f LICENSE ] && cp -f LICENSE module/webroot/LICENSE

chmod 0755 module/customize.sh module/service.sh module/fingerprint-update.sh \
           module/post-fs-data.sh module/vdlu/update.sh module/vdlu/vdlu-verify \
           module/META-INF/com/google/android/update-binary 2>/dev/null
[ -f module/identity.sh ] && chmod 0755 module/identity.sh
[ -f module/etc/copgvd_scope.dex ] && chmod 0644 module/etc/copgvd_scope.dex
[ -f module/etc/copgvd_identity.dex ] && chmod 0644 module/etc/copgvd_identity.dex
[ -d module/vdlu/verify ] && find module/vdlu/verify -name ed25519-mini -exec chmod 0755 {} + 2>/dev/null

# Every shipped binary must be traceable to a pinned upstream.
if [ -d module/bin ]; then
    find module/bin -type f ! -name '.gitkeep' ! -name 'PROVENANCE.json' -exec chmod 0755 {} + 2>/dev/null
    for d in module/bin/*/; do
        [ -f "$d/PROVENANCE.json" ] || { echo "::error::missing provenance: $d" >&2; exit 1; }
    done
fi

# ------------------------------------------------------------- packaging
mkdir -p "$OUT"
ZIP_PATH="$OUT/$ZIP_NAME"
rm -f "$ZIP_PATH"
( cd module && zip -r9 "$ZIP_PATH" . \
    -x '.git*' -x 'vdlu/RELEASE.md' -x 'bin/*/.gitkeep' >/dev/null )
[ -s "$ZIP_PATH" ] || { echo "::error::zip was not produced" >&2; exit 1; }

# Fail the build if a file the runtime needs did not make it in.
for must in module.prop customize.sh service.sh post-fs-data.sh uninstall.sh \
            identity.sh sepolicy.rule etc/copgvd_identity.dex etc/copgvd_scope.dex \
            zygisk/arm64-v8a.so zygisk/armeabi-v7a.so zygisk/x86_64.so \
            webroot/index.html webroot/scripts.js; do
    if ! unzip -l "$ZIP_PATH" "$must" >/dev/null 2>&1; then
        echo "::error::$must is missing from $ZIP_NAME" >&2
        exit 1
    fi
done

# ------------------------------------------------------------ checksums
( cd "$OUT" && sha256sum "$ZIP_NAME" > SHA256SUMS.txt )
( cd module/zygisk && sha256sum *.so >> "$OUT/SHA256SUMS.txt" )

echo
echo "zip       : $ZIP_PATH ($(wc -c < "$ZIP_PATH") bytes)"
echo "entries   : $(unzip -l "$ZIP_PATH" | tail -n 1)"
echo "checksums : $OUT/SHA256SUMS.txt"
cat "$OUT/SHA256SUMS.txt"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "zip_name=$ZIP_NAME"
        echo "zip_path=$ZIP_PATH"
        echo "version=$VERSION"
        echo "version_code=$VERSION_CODE"
    } >> "$GITHUB_OUTPUT"
fi
