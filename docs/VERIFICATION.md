# What was verified, and where

This branch was developed on a non-rooted device (`uid 10311`, no
`/data/adb`), so the split below is deliberate: everything that could be
exercised without root is pinned by an automated test, and everything that
needs root is written down as a device procedure rather than claimed as
tested.

## Verified on this machine

Run with `bash tests/run_host_tests.sh` — 19 steps, all green:

| Area | Test | Evidence |
|---|---|---|
| SSAID derivation matches AOSP | `tests/IdentityHostTest.java` | three vectors from an independent stdlib implementation, plus a 1.2 KB DER certificate |
| Crypto primitives | `tests/IdentityHostTest.java` | SHA-256 against FIPS 180-2, HMAC-SHA256 against RFC 4231 cases 1, 2, 6, 7 |
| Java and Python agree | `run_host_tests.sh` (cross-check step) | both emit the same 16-hex values for three keys |
| Scope fail-closed | `tests/scope_test.cpp` | 34 assertions; every unknown-mode spelling scopes narrowly |
| Identity shell paths | `tests/identity_sh_test.sh` | generators, validators, backup layout, refusal paths |
| Identity derive path | `tests/identity_derive_test.sh` | the shell consumes and validates the helper's JSON |
| Feed signature policy | `tests/feed_sig_test.sh` | 17 assertions across the three states |
| Native module compiles | `run_host_tests.sh` | `spoof_module.cpp` for arm64-v8a, armeabi-v7a, x86_64 (Termux clang 21, `-target ...-android24`) |
| Both dex files build | `dex/build.sh` via CI | `d8` output: `copgvd_scope.dex` and `copgvd_identity.dex` |
| Example config parses as the module expects | `run_host_tests.sh` | key allow-list, `process_overrides` is an object, identity ships off |

The dex was also decompiled with apktool after `d8` to confirm the shipping
bytecode contains the HMAC path, the `/data/system/users/%d/settings_ssaid.xml`
template and every verb — not just that the source compiled.

## NOT verified here, and cannot be

These need root, Play services, and a real `/data/system`. They are the honest
gap, not an oversight.

| Claim | Why it needs a device | How to check it |
|---|---|---|
| `Identity` reads the real signing certificate | `IPackageManager` + the DUMP-equivalent access only root has | `sh /data/adb/modules/COPG-VD/identity.sh verify 0 com.google.android.gms` → `"match":true` |
| The derived SSAID equals what the provider stored | needs the live `settings_ssaid.xml` and a running `system_server` | same command |
| `identity.sh apply` rewrites the file correctly | needs root and a real `settings_ssaid.xml` | `apply`, then `grep` the file, then `restore` |
| GSF write lands | requires `sqlite3` in the image **and** a real `gservices.db` | `identity.sh status` before/after |
| AAID write lands | requires Play services to have created `adid_settings.xml` | `identity.sh status` |
| The prop virtualizer still spoofs on this ROM | needs a rooted device and a fresh zygote | `tests/prop_virtualizer_probe.cpp` (see `tests/README.md`) |
| DRM L1/L3 both agree | needs an app that calls `MediaDrm` with `motor_drm` on | `getSecurityLevel()` vs `getPropertyString("securityLevel")` |
| Play Integrity passes | end to end, external oracle | the Play Integrity checker |

## Two design decisions the tests forced

1. **`scope_mode` rejects, it does not guess.** The first version of the
   fail-closed rule still returned `true` for the Play processes on an unknown
   mode; the test showed an unrelated app was still excluded, which is what
   "narrow" has to mean. Any future change that widens it fails
   `tests/scope_test.cpp`.
2. **Feed signatures are three-state, not boolean.** Making verification
   unconditionally required was the obvious "secure" change and would have
   broken every profile update: both feeds return 404 for `.sig` today. `auto`
   verifies when the signature exists, logs loudly when it does not, and
   `required` is one config line away once the feeds sign their files.
