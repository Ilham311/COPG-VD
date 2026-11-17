# Identity overlay: SSAID, GSF ID, AAID

COPG-VD's profile rewrites the *build* identity: `android.os.Build`, the system
properties, and the Widevine level. Three identifiers are not part of that
profile, because each one is stored and served by a different component:

| Identifier | What apps read | Where it lives | Owned by |
|---|---|---|---|
| **SSAID** | `Settings.Secure.ANDROID_ID` | `/data/system/users/<user>/settings_ssaid.xml` | `system_server` (SettingsProvider) |
| **GSF ID** | the Play check-in id | `/data/data/com.google.android.gms/databases/gservices.db` | Play services |
| **AAID** | the advertising id | `/data/data/com.google.android.gms/shared_prefs/adid_settings.xml` | Play services |

This overlay is **off by default**. Rewriting any of them is destructive: a
wrong SSAID breaks banking and licence checks, a wrong GSF id makes the device
look like a different phone to Play, and a wrong AAID resets an identifier
apps are entitled to expect will stay put.

## How SSAID is derived, and why not just written

Android 8+ does not store one SSAID per device. SettingsProvider derives it
per package, from the package's signing certificate:

```
key   = ssaid_user_key            # 32 random bytes per user, upper-case hex
mac   = HMAC-SHA256(key)
for sig in package.signatures:    # DER, in PackageManager's array order
    mac.update(int32_be(len(sig)))
    mac.update(sig)
ssaid = lower_hex(mac.doFinal())[0:16]
```

Source: AOSP `packages/SettingsProvider/.../SettingsProvider.java`,
`generateSsaidLocked()`. The historical 16-byte keys from the O preview are
accepted too.

Two consequences shape the implementation:

1. **The value depends on the signing certificate**, which only
   `PackageManager` can hand out. `dumpsys package` prints a hex signature
   blob, not the DER the MAC consumes, and it needs the DUMP permission. So the
   derivation runs in `etc/copgvd_identity.dex`
   (`com.vd171.copgvd.Identity`), called as root through `app_process`, the
   same way the scope picker works.
2. **SettingsProvider caches the table** inside `system_server`. Writing the
   file does not make the running provider re-read it. A reboot is required,
   and the tool says so instead of implying otherwise.

The derivation is verified against an independent reference: the same
algorithm implemented with the Python standard library in
`tests/identity_reference.py`, and against FIPS/RFC 4231 vectors for SHA-256
and HMAC. `tests/run_host_tests.sh` fails if the two disagree.

## Usage

```sh
# inspect, never writes
sh /data/adb/modules/COPG-VD/identity.sh status

# which value does the OS return for a package right now?
sh identity.sh verify 0 com.google.android.gms

# derive a profile (SSAID comes from the real certificate)
sh identity.sh generate --seed "$(date +%s)"

# or pin the values yourself
sh identity.sh generate --seed s --ssaid 0123456789abcdef \
    --gsf 1321054460064982811 --aaid af26f9c7-b0b5-40c7-ab2e-9ff2b8df2e3a

# write them (backs up first)
sh identity.sh apply

# undo the newest apply
sh identity.sh restore
```

`apply` refuses to modify any file it could not back up first. Backups live in
`/data/adb/COPG-VD/identity/backup/<UTC stamp>/` and `backup-list` prints them.

## To enable it at boot

The overlay only runs from `service.sh` when the config opts in:

```json
"COPG-VD-Identity": { "enabled": true }
```

With `enabled: true`, `service.sh` runs `identity.sh apply` after the resetprop
pass. Nothing else in the module reads this block.

## What cannot be done from a script

- **GSF ID needs `sqlite3`.** Android images do not ship it. When it is
  missing, `apply` takes the backup, leaves the database untouched, and says
  so. It never edits SQLite pages by hand: a byte-length mismatch there
  corrupts the store.
- **AAID needs the `adid_key` string to already exist.** Play services writes
  `adid_settings.xml` on first run. If the file is absent, there is nothing to
  rewrite and the tool skips it rather than creating a file Play services will
  overwrite.
- **The SSAID change needs a reboot** for `system_server` to drop its cache.

## Verification status

| Layer | Covered by | Runs on |
|---|---|---|
| SSAID algorithm vs AOSP | `tests/IdentityHostTest.java`, `tests/identity_reference.py` | host |
| `.dex` builds and contains the verbs | `dex/build.sh` + CI `Check the shipped dex files exist` | host/CI |
| Shell generate/apply/restore logic | `tests/identity_sh_test.sh`, `tests/identity_derive_test.sh` | host |
| Reading the real certificate, real SettingsProvider, real Play files | **not covered by host tests** | rooted device |

The last row is the honest gap: it needs root, Play services and a real
`/data/system`. `identity.sh verify <user> <package>` is the one-command check
for that on a device — it derives the value from the live certificate and
compares it with the one the provider stored.
