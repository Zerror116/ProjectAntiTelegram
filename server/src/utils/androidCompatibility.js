const fs = require('fs');
const path = require('path');

const { ANDROID_STABLE_RELEASE_FILE } = require('./androidStableRelease');

const compatibilityCache = {
  path: '',
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

async function loadAndroidReleaseCompatibility(downloadsRoot) {
  const releasePath = path.join(downloadsRoot, ANDROID_STABLE_RELEASE_FILE);
  let stat;
  try {
    stat = await fs.promises.stat(releasePath);
  } catch (_) {
    return {
      active: false,
      releasePath,
      minSupportedBuild: 0,
      minSupportedVersion: null,
      latestBuild: 0,
      latestVersion: null,
      required: false,
    };
  }

  if (
    compatibilityCache.value &&
    compatibilityCache.path === releasePath &&
    compatibilityCache.mtimeMs === stat.mtimeMs &&
    compatibilityCache.size === stat.size
  ) {
    return compatibilityCache.value;
  }

  let parsed = null;
  try {
    parsed = JSON.parse(await fs.promises.readFile(releasePath, 'utf8'));
  } catch (_) {
    parsed = null;
  }

  const value = {
    active: Boolean(parsed && typeof parsed === 'object' && !Array.isArray(parsed)),
    releasePath,
    minSupportedBuild: parsePositiveInt(parsed?.min_supported_build, 0),
    minSupportedVersion: cleanString(parsed?.min_supported_version) || null,
    latestBuild: parsePositiveInt(parsed?.build, 0),
    latestVersion: cleanString(parsed?.version) || null,
    required:
      parsed?.required === true ||
      cleanString(parsed?.required).toLowerCase() === 'true',
    title: cleanString(parsed?.title) || 'Требуется обновление Феникс',
    message: cleanString(parsed?.message) || null,
  };

  compatibilityCache.path = releasePath;
  compatibilityCache.mtimeMs = stat.mtimeMs;
  compatibilityCache.size = stat.size;
  compatibilityCache.value = value;
  return value;
}

function resolveAndroidClientBuild(req) {
  return parsePositiveInt(
    req.get('x-fenix-app-build') ||
      req.get('x-app-build') ||
      req.query?.current_build ||
      req.query?.app_build,
    0,
  );
}

function isAndroidClientRequest(req) {
  const platform = cleanString(
    req.get('x-fenix-platform') || req.query?.platform,
  ).toLowerCase();
  if (platform === 'android') return true;
  const userAgent = cleanString(req.get('user-agent')).toLowerCase();
  return userAgent.includes('android') && resolveAndroidClientBuild(req) > 0;
}

function shouldSkipAndroidCompatibilityGuard(req) {
  const pathName = String(req.path || req.originalUrl || '').toLowerCase();
  return (
    !pathName.startsWith('/api/') ||
    pathName.startsWith('/api/app/update') ||
    pathName.startsWith('/api/setup') ||
    pathName === '/api/health' ||
    pathName === '/health'
  );
}

async function androidCompatibilityGuard(req, res, next, options = {}) {
  try {
    if (shouldSkipAndroidCompatibilityGuard(req)) return next();
    if (!isAndroidClientRequest(req)) return next();

    const compatibility = await loadAndroidReleaseCompatibility(
      options.downloadsRoot,
    );
    const currentBuild = resolveAndroidClientBuild(req);
    const minBuild = compatibility.minSupportedBuild || 0;
    if (!compatibility.active || minBuild <= 0 || currentBuild <= 0) {
      return next();
    }
    if (currentBuild >= minBuild) return next();

    return res.status(426).json({
      ok: false,
      code: 'app_update_required',
      error:
        'Эта версия Феникс больше не поддерживается. Обновите приложение.',
      data: {
        platform: 'android',
        current_build: currentBuild,
        min_supported_build: minBuild,
        min_supported_version: compatibility.minSupportedVersion,
        latest_build: compatibility.latestBuild || null,
        latest_version: compatibility.latestVersion,
        required: true,
        title: compatibility.title,
        message: compatibility.message,
      },
    });
  } catch (err) {
    console.error('android.compatibility.guard error', err);
    return next();
  }
}

module.exports = {
  androidCompatibilityGuard,
  loadAndroidReleaseCompatibility,
  resolveAndroidClientBuild,
};
