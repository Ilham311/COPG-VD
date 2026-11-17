# Tests

Two layers: host tests that run anywhere, and device probes that need root.

## Host tests (no device, no root)

```sh
./tests/run_host_tests.sh
```

Needs a JDK, an `android.jar`, and a C++ compiler. It runs:

| Step | What it proves |
|---|---|
| compile dex sources | the Java entry points compile against the public SDK |
| identity: SSAID derivation | SHA-256 and HMAC-SHA256 against FIPS/RFC 4231 vectors, and the SSAID against values from the Python reference |
| identity: Java vs Python | the shipping `Identity.ssaid()` and an independent stdlib implementation agree |
| identity.sh generators | argument parsing, format validation, backup layout, refusal paths |
| identity.sh derive path | the shell consumes the helper's JSON and validates it |
| shell syntax | every shipped script parses |
| feed signature | the three states, including "feed has no `.sig` yet" |
| scope decision table | the fail-open regression: an unknown `scope_mode` must scope narrowly, never to the whole device |
| native module | `spoof_module.cpp` compiles for arm64-v8a, armeabi-v7a and x86_64 |
| example config | the shipped JSON matches what the parser reads |

The scope test compiles its own copy of the decision table so it needs no Zygisk
link; the real module is covered by the ABI compile step.

## Device probes (need root)

Compile them by hand against an NDK and run from a fresh `adb shell` child on
the target device. They do not load the Zygisk module, create keystore keys, or
modify the COPG-VD config, global properties or Google data.

```sh
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
"$TOOLCHAIN/aarch64-linux-android28-clang++" -std=c++17 -O2 -static-libstdc++ \
  -Izygisk tests/prop_virtualizer_cold_probe.cpp zygisk/prop_virtualizer.cpp \
  -o prop-virtualizer-cold-probe
adb push prop-virtualizer-cold-probe /data/local/tmp/
adb shell chmod 755 /data/local/tmp/prop-virtualizer-cold-probe
adb shell /data/local/tmp/prop-virtualizer-cold-probe        # cold: nothing read before install()
adb shell /data/local/tmp/prop-virtualizer-cold-probe prime  # control: fingerprint read first
```

- `prop_virtualizer_probe.cpp` — long-to-short replacement, repeated callback
  reads, serial metadata, repeat install and board API preservation.
- `prop_virtualizer_cold_probe.cpp` — a cold process (no property read before
  `install()`) must still see the spoofed fingerprint; it exits non-zero if any
  value is wrong. `prime` reads the fingerprint first as a control.

## Identity on a device

The identity overlay cannot be fully tested without root and Play services.
The one-command check is:

```sh
sh /data/adb/modules/COPG-VD/identity.sh verify 0 com.google.android.gms
```

It derives the SSAID from the package's live signing certificate and compares
it with the value SettingsProvider stored. `{"match":true}` means the
derivation is reading the same inputs the framework does. What the host tests
cannot cover is exactly this row: `PackageManager`, `system_server` and the
real `gservices.db`/`adid_settings.xml` files.
