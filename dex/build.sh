#!/usr/bin/env bash
# ======================================================================
#  COPG-VD  ::  global device spoofer
#  Spoof your device fingerprint and build: Zygisk, KernelSU/APatch/Magisk.
#
#  Copyright (C) 2026  AlirezaParsi & VD171
#  SPDX-License-Identifier: Apache-2.0
#  Fork by VD171.
#
#  Licensed under the Apache License, Version 2.0; you may obtain a copy at
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Site           : https://vd171.ru
#  Site           : https://vd.priv8.ru
#  Source         : https://github.com/VD171/COPG-VD
#  GitHub         : @VD171 https://github.com/VD171
#  XDA-Developers : @VD171 https://xdaforums.com/m/vd171.4699873/
#  XDA thread     : https://xdaforums.com/t/COPG-VD.4807698/
#  Telegram       : @VD_Priv8 https://t.me/VD_Priv8
#  Channel        : @Priv8_VD https://t.me/Priv8_VD
#  Discord        : @VD.Priv8 https://discord.com/users/1296831918989639721
#  E-mail         : vd.priv8@pm.me
# ======================================================================
#
#  Build the framework scope-helper dex (javac + d8). Arch-independent: one
#  copgvd_scope.dex serves every ABI. Output -> module/etc/copgvd_scope.dex.
#  Requires an Android SDK (platform android.jar + build-tools/d8) and a JDK.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
# ANDROID_JAR allows a build without a full SDK layout (a Termux install has
# android.jar and d8 on PATH but no platforms/ or build-tools/ tree).
# The `|| true`s matter: under `set -e`, a failing command substitution in an
# assignment exits the script silently, before the error message below runs.
AJ="${ANDROID_JAR:-$(ls -d "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1 || true)}"
D8="$(ls -d "$SDK"/build-tools/*/d8 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$D8" ] && [ -x "$D8" ] || D8="$(command -v d8 2>/dev/null || true)"
[ -f "$AJ" ] || { echo "android.jar not found (set ANDROID_JAR, or install platforms/ under $SDK)" >&2; exit 1; }
[ -n "$D8" ] && [ -x "$D8" ] || { echo "d8 not found (set up build-tools/ under $SDK, or put d8 on PATH)" >&2; exit 1; }

OUT="$ROOT/dex/out"; rm -rf "$OUT"; mkdir -p "$OUT" "$ROOT/module/etc"
# shellcheck disable=SC2046
javac --release 11 -cp "$AJ" -d "$OUT" $(find "$ROOT/dex/src" -name '*.java')
# Two entry points, one dex each, kept apart so a class added for one verb can
# never change the startup cost of the other: Scope runs on every WebUI open,
# Identity only when the user asks for an identifier.
"$D8" --min-api 26 --lib "$AJ" --output "$ROOT/dex" \
    $(find "$OUT/com/vd171/copgvd" -maxdepth 1 -name 'Scope*.class')
mv "$ROOT/dex/classes.dex" "$ROOT/module/etc/copgvd_scope.dex"
"$D8" --min-api 26 --lib "$AJ" --output "$ROOT/dex" \
    $(find "$OUT/com/vd171/copgvd" -maxdepth 1 -name 'Identity*.class')
mv "$ROOT/dex/classes.dex" "$ROOT/module/etc/copgvd_identity.dex"
rm -rf "$OUT"
echo "built module/etc/copgvd_scope.dex ($(wc -c < "$ROOT/module/etc/copgvd_scope.dex") bytes)"
echo "built module/etc/copgvd_identity.dex ($(wc -c < "$ROOT/module/etc/copgvd_identity.dex") bytes)"
