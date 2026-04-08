Android release artifacts live in this directory.

Current production source of truth:
- `android-stable.release.json`

Expected stable release JSON shape:
- `version`
- `build`
- `channel`
- `required`
- `min_supported_version`
- `min_supported_build`
- `title`
- `message`
- `changelog[]`
- `apk_file`
- `package_name`
- `published_at`
- `mirrors[]`

The backend reads `android-stable.release.json` first.
If that file exists but the referenced APK is missing or broken, Android updater endpoints fail closed.

Typical APK naming convention:
- `fenix-<version>-build<build>.apk`

Operational publish flow:
- build and upload via `/Users/zerror/PycharmProjects/ProjectAntiTelegram/scripts/release_android_update.sh`
- one-time manifest key setup via `/Users/zerror/PycharmProjects/ProjectAntiTelegram/scripts/generate_android_update_manifest_keys.sh`
- step-by-step ops notes in `/Users/zerror/PycharmProjects/ProjectAntiTelegram/scripts/ANDROID_UPDATE_RELEASE.md`
- keep manifest signing secrets in server env
- do not update Android release metadata through `.env` in production

Legacy env-based Android updater settings remain only as dev fallback.
