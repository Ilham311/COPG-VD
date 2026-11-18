# Releasing

Two scripts, one version source. `module/module.prop` is the only place a
version is written; everything else reads it.

## Build a zip locally

```sh
bash .github/scripts/build-release.sh            # runs the host suite first
bash .github/scripts/build-release.sh --skip-tests
```

It needs the native libraries already built per ABI (`zygisk/build/<abi>/libspoof.so`)
and a JDK plus `android.jar` for the dex helpers. It refuses to produce a zip
when:

- an ABI is missing from `zygisk/build/`,
- a dex helper is missing and cannot be built,
- a file the runtime needs did not make it into the archive.

Output: `COPG-VD-<version>.zip` and `SHA256SUMS.txt` in the repo root.

Building the native libraries on ARM Termux: only the host ABI links locally
(Termux ships a C++ runtime for its own architecture only). Use the CI
workflow, or an NDK, for all three.

## Release

GitHub Actions → **COPG-VD** → *Run workflow*:

| input | meaning |
|---|---|
| `bump` | `none` to ship the current version, or `patch`/`minor`/`major` to bump first (rewrites `module.prop` and `update.json`, commits the bump) |
| `release` | `true` to publish a GitHub Release; `false` to only produce the artifact |
| `notes` | extra CHANGELOG lines for a version that has no section yet |

The workflow stages the tree, builds the zip, uploads the artifact, and then:

1. **tags** the commit it built from (`git/refs` API, `refs/tags/<version>`),
2. **publishes** the release for that tag with the zip and `SHA256SUMS.txt`.

A tag that already exists is reused, so re-running is safe.

## Verify a published release

```sh
sh .github/scripts/verify-release.sh            # uses module.prop's version
sh .github/scripts/verify-release.sh v6.16.1-vd
```

It downloads the zip and checksums from the release, checks the hash, and then
reads the archive independently: every file the runtime needs must be present
with the right unix mode, the version inside must match the tag, the VDLU feed
must stay disabled, and the identity dex must contain the derivation. Exit 2
means it could not download; exit 1 means the archive is wrong.

## Why in-place self-update is off

Upstream's VDLU feed
(`https://vd171.github.io/VD-Modules/COPG-VD/manifest.json`) is live and its
signed manifest lists **upstream's** `service.sh`, `fingerprint-update.sh` and
`zygisk/*.so`. With the boot auto-update enabled, a device running this fork
would fetch that manifest, verify it (the signature is genuine — it is
upstream's), and overwrite this fork's files. Every fix in it would vanish on
the first boot.

So `module/vdlu/config.default` ships `source=` (empty) and
`auto_on_reboot=0`. The engine treats a missing source as an error and does
nothing, which is the correct fail-closed behaviour here.

Updates reach devices through `module/update.json`, which points at this fork's
Releases. To re-enable in-place updates you need a feed signed with your own
key — `module/vdlu/RELEASE.md` documents the producer steps
(`vdlu-pack` + `vdlu-sign`), and `config.default` lists what to change.
