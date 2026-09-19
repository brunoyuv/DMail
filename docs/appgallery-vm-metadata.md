# AppGallery 1.0.4 virtual-machine metadata correction

Huawei support reported an unpacking failure because `virtualMachine` lacked a
four-segment version. The submitted 1.0.4 APP contains `entry-default.hap`, whose
compiled `module.json` had `module.virtualMachine` set to `ark`. This property is
inserted by Hvigor; it is absent from the source `module.json5`.

The original bytecode has a PANDA header with version bytes `[13, 0, 1, 0]`.
The pinned compiler's `--target-bc-version --target-api-version 22` query returns
`13.0.1.0`. The correct metadata is therefore `ark13.0.1.0`, not the compiler's
newest default bytecode version (`24.0.0.0`).

## Cause and correction

The recorded Hvigor build swallowed the compiler-version subprocess failure.
A direct reproduction through Hvigor's ProcessUtils identified `spawnSync EPERM`
in the sandbox. Hvigor continued successfully with an empty version suffix.
Rebuilding the isolated original release staging with the subprocess permitted
and `--no-incremental` regenerated the correct metadata. Incremental packaging
alone retained the malformed cached profile.

The corrected release remains 1.0.4 / 1000004, bundle `some.DMail.hamorny`, based
on source revision `c21edcea3143b97c8e7818bc983b00125b18cf4e`. Only
`module.virtualMachine` changed in the embedded HAP. All bytecode, native
libraries, resources and other metadata are byte-identical to the submitted
release. The APP and standalone HAP were re-signed with the existing release
key/profile. Current uncommitted mail changes were not included. The user
requested no download log in this upload: neither the MailDownloadLog feature,
its settings nor diagnostic files are present in this original source/package.
Normal platform/protocol error handling is unchanged.

## Checks

- Twelve release-packaging regression tests pass. The release builder now rejects
  missing/malformed VM metadata, invalid bytecode headers and version mismatches.
- Huawei `verify-app` passes for both signed artifacts; extracted profiles match
  the release profile. Certificate chain, profile validity and certificate binding
  are checked. The profile is `release` / `app_gallery` for the registered bundle.
- Huawei `parseApp(ALL)` and APP unpacking succeed. The local parser also accepts
  the old bare `ark` value; success alone does not reproduce the cloud validator.
  An explicit check enforces the four-part version and bytecode agreement.
- APP/HAP identity and 1.0.4 / 1000004 agree. Release build, debug=false,
  compile SDK 26.0.0.105, minimum/target API 22 and Release API metadata remain.
- Phone/tablet/2in1 declarations are consistent. Native libraries are ARM64.
  INTERNET is the sole declared permission; no user-grant permission is requested.
- App and launcher ability use the same layered icon. Source layers are 1024²;
  the SDK-generated packaged layers are 512². Resources are unchanged.
- Archive integrity, unique entries, original source archive, checksums, license
  notices, and disabled Google browser sign-in policy pass verification.

Use `dist/D-Mail-1.0.4-arm64-v8a-appgallery-vm-fixed-signed.app` for the next upload.
Its SHA-256 and `*-signed-verification.json` are alongside it. No ZIP, upload,
installation, production launch, commit or push was performed for this correction.
Store acceptance, listing/account requirements and renewed device UX checks have
not been verified. This is a package audit, not a guarantee of AppGallery approval.

## References

- [Huawei unpacking tool and Distro fields](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/unpacking-tool)
- [Huawei explanation of packaged launcher icons being resized to 512 pixels](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-arkui-1149)
