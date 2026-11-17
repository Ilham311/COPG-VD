> **Languages:** English · [العربية](ar/CONFIGURATION.md) · [Čeština](cs/CONFIGURATION.md) · [Deutsch](de/CONFIGURATION.md) · [Español](es/CONFIGURATION.md) · [فارسی](fa/CONFIGURATION.md) · [Français](fr/CONFIGURATION.md) · [हिन्दी](hi/CONFIGURATION.md) · [Bahasa Indonesia](id/CONFIGURATION.md) · [Italiano](it/CONFIGURATION.md) · [日本語](ja/CONFIGURATION.md) · [한국어](ko/CONFIGURATION.md) · [Nederlands](nl/CONFIGURATION.md) · [Polski](pl/CONFIGURATION.md) · [Português](pt/CONFIGURATION.md) · [Русский](ru/CONFIGURATION.md) · [Svenska](sv/CONFIGURATION.md) · [ไทย](th/CONFIGURATION.md) · [Türkçe](tr/CONFIGURATION.md) · [Українська](uk/CONFIGURATION.md) · [Tiếng Việt](vi/CONFIGURATION.md) · [中文](zh/CONFIGURATION.md)

---

# Configuration reference

The whole module is driven by one file: `/data/adb/COPG-VD/COPG-VD.json`. The WebUI writes it for
you, but you can edit it by hand. A shipped example lives at `module/COPG-VD.json.example`.
This is the single source of truth; the copy under the module directory is only a read-only default.
A config left over from an older version at `/data/adb/COPG-VD.json` is moved into this directory
automatically. The module's own log and state (`update.log`, `update.state`) live here too.

Rules:

- **Strings use double quotes only**, as in JSON.
- **Every field is optional.** A field that is not provided is skipped and the ROM's own
  value is kept.
- Run **Analyze** after editing by hand: a file that does not parse makes the module spoof
  **nothing**, and only logcat says so.

## Top-level keys

| Key | Type | Meaning |
|---|---|---|
| `scope_mode` | string | `playstore` (default), `global`, `whitelist` or `blacklist`. See [USER-GUIDE.md](USER-GUIDE.md). |
| `scope_whitelist` | array | Packages that get the spoof when `scope_mode` is `whitelist`. |
| `scope_blacklist` | array | Packages excluded when `scope_mode` is `blacklist`. |
| `COPG-VD` | object | The profile: the Build fields to present (see below). |
| `COPG-VD-Delete` | array | Field names to remove instead of set (Build field becomes null; a property is removed with `resetprop --delete`). |
| `COPG-VD-Settings` | object | Module settings that travel with the profile (see below). |
| `motor_jni` | bool | Build-fields engine (rewrites `android.os.Build.*`). Default `true`. |
| `motor_prop_hook` | bool | Per-process property engine (clean-room property remap). Default `true`. |
| `prop_method` | string | How the property engine is delivered. Only `mmap` is implemented; `off` disables it. Default `mmap` since v6.16 (it used to default to `off`, so a fresh install silently had no native property spoofing). |
| `motor_drm` | bool | DRM / Widevine engine. Default `false`. |
| `drm_targets` | array | Apps that get the DRM spoof regardless of `scope_mode`. Empty = follow the scope. |
| `global_fields` | array | Build fields applied device-wide even in a scoped mode, for coherence-safe fields only. |
| `process_overrides` | object | Per-process field overrides: `{ "process.name": { "FIELD": "value" } }`. Must be an object; `{}` means none. |
| `COPG-VD-Identity` | object | The SSAID / GSF / AAID overlay. Off by default. See [IDENTITY.md](IDENTITY.md). |
| `verbose_logs` | bool | Extra logcat detail for debugging. Default `false`. |

## The `COPG-VD` profile object

Each entry is a device field presented to the targeted processes. The common ones:

| Group | Fields |
|---|---|
| Identity | `BRAND`, `DEVICE`, `MANUFACTURER`, `MODEL`, `PRODUCT`, `FINGERPRINT`, `BOARD`, `HARDWARE` |
| Build id | `DISPLAY`, `ID`, `INCREMENTAL`, `TIMESTAMP`, `TIME`, `HOST`, `USER`, `TYPE`, `TAGS`, `BOOTLOADER` |
| Attestation | `SECURITY_PATCH`, `FIRST_API_LEVEL`, `DEVICE_INITIAL_SDK_INT`, `UUID`, `SDK_FINGERPRINT` |
| Version (special) | `ANDROID_VERSION`, `RELEASE`, `SDK_INT`, `SDK`, `SDK_FULL`, `CODENAME`, `PREVIEW_SDK` |

The `*_FOR_ATTESTATION` variants (`BRAND_FOR_ATTESTATION`, `DEVICE_FOR_ATTESTATION`,
`MANUFACTURER_FOR_ATTESTATION`, `MODEL_FOR_ATTESTATION`, `PRODUCT_FOR_ATTESTATION`) let the
attestation path report a different value from the plain one, so the keystore stays
coherent.

> **The version group is special.** `ANDROID_VERSION`, `SDK_INT`, `SDK_FULL` and `CODENAME`
> describe your ROM, not the spoofed device. Raising them softloops the phone. They are not
> in the shipped profile and only apply when `COPG-VD-Settings.spoof_version` allows it -
> see [USER-GUIDE.md](USER-GUIDE.md#the-android-version-trap).

### Field states

| State | How | Result |
|---|---|---|
| Set | `"KEY": "value"` | Writes the value. |
| Empty | `"KEY": ""` | Writes an empty value. |
| Delete | name in `"COPG-VD-Delete": [ ... ]` | Removes the field. |
| Skip | leave the key out | Keeps the ROM's own value. |

### DRM

`DRM_SECURITY_LEVEL` (`L1` or `L3`) is the Widevine level reported when `motor_drm` is on.

## `COPG-VD-Settings`

Settings that travel with the profile, so a backup carries your choices.

| Key | Type / values | Meaning |
|---|---|---|
| `resetprop` | bool | Whether the device-wide resetprop engine runs. |
| `autoupdate` | bool | Whether `fingerprint-update.sh` runs once per boot. Default on. |
| `spoof_version` | `never` / `rom` / `force` | How the Android version group applies. `never` is the default; `force` is refused when restoring a backup. |
| `feed_signature` | `required` / `auto` / `off` | Whether a fetched profile must carry an ed25519 signature. `auto` (default) verifies when the feed publishes `<url>.sig` and otherwise applies the profile with a logged warning; `required` refuses an unsigned profile; `off` skips the check. Only the exact word `off` disables it, so a typo or a lost line leaves verification on. |
| `identity` | bool | Whether `service.sh` runs the identity overlay at boot. Default off; also needs `COPG-VD-Identity.enabled`. |

## `COPG-VD-Identity`

The three identifiers that are not part of the Build profile, because each is stored by a
different component. **Off by default**: every one of them is destructive to change. Full
detail, including why the SSAID is derived rather than invented, is in
[IDENTITY.md](IDENTITY.md).

| Key | Type | Meaning |
|---|---|---|
| `enabled` | bool | Run the overlay from `service.sh` at boot. Default `false`. |
| `ssaid` | 16 lower-case hex | `Settings.Secure.ANDROID_ID`. Leave empty to derive it from the package's signing certificate the way Android does. |
| `gsf_id` | decimal | The Play check-in id. Written to `gservices.db` when `sqlite3` is available. |
| `aaid` | UUID v4 | The advertising id written to `adid_settings.xml`. |
| `rotate_on_apply` | bool | Generate fresh values on every apply instead of keeping the stored ones. Default `false`. |

`ssaid_user_key` is accepted too, for restoring a known key; it must be 32 (or legacy 16)
hex bytes.

## `global_fields`

Build fields in this list are applied device-wide even in a scoped mode, to keep a value
consistent everywhere. Use it only for coherence-safe fields: the security patch is the
usual one. **Never** put identity or the Android version group here.

```json
"global_fields": ["SECURITY_PATCH"]
```

## Example

```json
{
  "scope_mode": "playstore",
  "COPG-VD": {
    "BRAND": "google",
    "DEVICE": "tegu",
    "MANUFACTURER": "Google",
    "MODEL": "Pixel 9a",
    "FINGERPRINT": "google/tegu_beta/tegu:CANARY/ZP11.261016.008/16754936:user/release-keys",
    "PRODUCT": "tegu_beta",
    "SECURITY_PATCH": "2026-11-05",
    "FIRST_API_LEVEL": "35",
    "DRM_SECURITY_LEVEL": "L1"
  },
  "motor_drm": false,
  "drm_targets": [],
  "global_fields": ["SECURITY_PATCH"],
  "process_overrides": {},
  "COPG-VD-Settings": { "autoupdate": true, "spoof_version": "never" }
}
```

<!-- doc-footer -->

---

> _This documentation was generated with Claude (Anthropic) and is maintained by VD171. Corrections and improvements are welcome; see [CONTRIBUTING.md](../CONTRIBUTING.md)._
