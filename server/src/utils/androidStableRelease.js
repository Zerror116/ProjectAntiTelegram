const fs = require('fs');
const path = require('path');

const ANDROID_STABLE_RELEASE_FILE = 'android-stable.release.json';
const releaseCache = {
  mtimeMs: -1,
  size: -1,
  value: null,
};

function cleanString(rawValue) {
  return String(rawValue || '').trim();
}

function parsePositiveInt(rawValue, fallback = 0) {
  const parsed = Number.parseInt(String(rawValue || '').trim(), 10);
  if (!Number.isFinite(parsed) || parsed < 0) return fallback;
  return parsed;
}

function toSafeFileName(rawValue) {
  const candidate = cleanString(rawValue);
  if (!candidate) return '';
  const safeName = path.basename(candidate);
  if (!safeName || safeName === '.' || safeName === '..') return '';
  return safeName;
}

function normalizeStringList(rawValue) {
  if (Array.isArray(rawValue)) {
    return rawValue
      .map((item) => cleanString(item))
      .filter(Boolean);
  }
  const source = cleanString(rawValue);
  if (!source) return [];
  return source
    .split(/[\n,;]/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function normalizeChangelog(rawValue) {
  return normalizeStringList(rawValue);
}

function cacheAndReturn(stat, value) {
  releaseCache.mtimeMs = stat.mtimeMs;
  releaseCache.size = stat.size;
  releaseCache.value = value;
  return value;
}

function disabledReleaseState(code, message, details = null) {
  return {
    source: 'release_json',
    exists: true,
    active: false,
    errorCode: code,
    errorMessage: message,
    errorDetails: details,
  };
}

async function loadAndroidStableRelease({
  downloadsRoot,
  packageNameFallback,
  getDownloadFileMetadata,
}) {
  const releasePath = path.join(downloadsRoot, ANDROID_STABLE_RELEASE_FILE);

  let stat;
  try {
    stat = await fs.promises.stat(releasePath);
  } catch (err) {
    if (err && err.code === 'ENOENT') {
      return {
        source: 'env_fallback',
        exists: false,
        active: false,
        releasePath,
      };
    }
    throw err;
  }

  if (
    releaseCache.value &&
    releaseCache.mtimeMs === stat.mtimeMs &&
    releaseCache.size === stat.size
  ) {
    return releaseCache.value;
  }

  let parsed;
  try {
    const raw = await fs.promises.readFile(releasePath, 'utf8');
    parsed = JSON.parse(raw);
  } catch (err) {
    return cacheAndReturn(
      stat,
      disabledReleaseState(
        'invalid_release_json',
        'Текущий Android-релиз временно недоступен: release JSON поврежден.',
        err?.message || null,
      ),
    );
  }

  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return cacheAndReturn(
      stat,
      disabledReleaseState(
        'invalid_release_json',
        'Текущий Android-релиз временно недоступен: release JSON имеет неверный формат.',
      ),
    );
  }

  const version = cleanString(parsed.version);
  const build = parsePositiveInt(parsed.build, 0);
  const apkFile = toSafeFileName(parsed.apk_file);
  const packageName = cleanString(parsed.package_name) || cleanString(packageNameFallback);
  const channel = cleanString(parsed.channel) || 'stable';
  const changelog = normalizeChangelog(parsed.changelog);
  const mirrors = normalizeStringList(parsed.mirrors);
  const title = cleanString(parsed.title) || 'Доступно обновление Феникс';
  const message = cleanString(parsed.message);
  const minSupportedVersion = cleanString(parsed.min_supported_version);
  const minSupportedBuild = parsePositiveInt(parsed.min_supported_build, 0);
  const required = parsed.required === true || cleanString(parsed.required).toLowerCase() === 'true';
  const publishedAt = cleanString(parsed.published_at);

  if (!version || build <= 0 || !apkFile || !packageName) {
    return cacheAndReturn(
      stat,
      disabledReleaseState(
        'invalid_release_json',
        'Текущий Android-релиз временно недоступен: не хватает обязательных полей release JSON.',
      ),
    );
  }

  const absoluteApkPath = path.join(downloadsRoot, apkFile);
  if (!fs.existsSync(absoluteApkPath)) {
    return cacheAndReturn(
      stat,
      disabledReleaseState(
        'missing_release_apk',
        'Текущий Android-релиз временно недоступен: APK-файл не найден на сервере.',
        apkFile,
      ),
    );
  }

  let apkMetadata;
  try {
    apkMetadata = await getDownloadFileMetadata(absoluteApkPath);
  } catch (err) {
    return cacheAndReturn(
      stat,
      disabledReleaseState(
        'broken_release_apk',
        'Текущий Android-релиз временно недоступен: APK-файл не удалось проверить.',
        err?.message || null,
      ),
    );
  }

  return cacheAndReturn(stat, {
    source: 'release_json',
    exists: true,
    active: true,
    releasePath,
    absoluteApkPath,
    apkFile,
    apkMetadata,
    release: {
      version,
      build,
      channel,
      required,
      min_supported_version: minSupportedVersion || null,
      min_supported_build: minSupportedBuild > 0 ? minSupportedBuild : null,
      title,
      message: message || null,
      changelog,
      apk_file: apkFile,
      package_name: packageName,
      published_at: publishedAt || apkMetadata.publishedAt || null,
      mirrors,
    },
  });
}

module.exports = {
  ANDROID_STABLE_RELEASE_FILE,
  loadAndroidStableRelease,
};
