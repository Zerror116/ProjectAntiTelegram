# Android Update Release Ops

## 1. One-time manifest signing setup

Generate a dedicated Ed25519 key pair for the Android updater manifest:

```bash
/Users/zerror/PycharmProjects/ProjectAntiTelegram/scripts/generate_android_update_manifest_keys.sh
```

The script creates a secure output directory with:
- `private.pem` — keep only on the backend server
- `public.pem` — used by Android release builds and the backend
- `server_manifest.env` — backend env block
- `android_release_build.env` — local env block for release builds

### Server one-time setup
Add the contents of `server_manifest.env` to the backend server environment and restart the backend once.

Required vars:
- `APP_UPDATE_MANIFEST_KEY_ID`
- `APP_UPDATE_MANIFEST_PUBLIC_KEY`
- `APP_UPDATE_MANIFEST_PRIVATE_KEY`

### Local release one-time setup
Before building and publishing a release APK, load the public manifest key into your shell:

```bash
source /path/to/android_release_build.env
```

## 2. Prepare changelog

Create a plain text changelog file with one item per line:

```text
Исправления ошибок
Стабильнее загрузка APK
Быстрее проверка файла перед установкой
```

## 3. Publish a stable Android release

```bash
source /path/to/android_release_build.env
/Users/zerror/PycharmProjects/ProjectAntiTelegram/scripts/release_android_update.sh \
  --changelog-file /absolute/path/changelog.txt
```

Optional flags:
- `--message "Короткое описание релиза"`
- `--title "Доступно обновление Феникс"`
- `--required`
- `--min-supported keep|current|1.2.3+45`
- `--apk /absolute/path/app-release.apk`
- `--skip-build`

## 4. What the release script does

- runs `flutter pub get`
- runs `flutter analyze`
- builds `flutter build apk --release`
- rejects release builds with `dev-ed25519`
- verifies APK package name
- calculates SHA-256 and size
- publishes immutable APK name like `fenix-1.0.12-build13.apk`
- uploads `android-stable.release.json`
- smoke-checks:
  - `/api/app/update`
  - `/api/app/update/android/manifest`
  - `/api/app/update/android/apk`
  - `/download/android`

## 5. Source of truth on the server

The current stable Android release is defined by:
- `server/downloads/android-stable.release.json`

If this JSON exists but references a missing or broken APK, Android update endpoints fail closed.

## 6. Safety notes

- never commit generated manifest keys into git
- keep `private.pem` and `server_manifest.env` server-only
- only the public key and key id are needed for local Android release builds
- production Android download URLs must stay on your official `https` domain
