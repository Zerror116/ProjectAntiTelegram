const express = require('express');
const fs = require('fs');
const path = require('path');

const { resolveAuthContextFromToken } = require('../utils/auth');
const { createNotificationInboxItem } = require('../utils/notifications');
const { signManifestPayload } = require('../utils/appUpdateManifest');
const { loadAndroidStableRelease } = require('../utils/androidStableRelease');

const router = express.Router();
const downloadsRoot = path.resolve(__dirname, '..', '..', 'downloads');
const apkMetadataCache = new Map();

function parseBooleanEnv(rawValue, fallback = false) {
  if (rawValue === undefined || rawValue === null || rawValue === '') {
    return fallback;
  }
  const normalized = String(rawValue).toLowerCase().trim();
  return ['1', 'true', 'yes', 'on', 'y'].includes(normalized);
}

function parsePositiveInt(rawValue, fallback = 0) {
  const parsed = Number.parseInt(String(rawValue || '').trim(), 10);
  if (!Number.isFinite(parsed) || parsed < 0) return fallback;
  return parsed;
}

function cleanString(rawValue) {
  return String(rawValue || '').trim();
}

function cleanOptionalString(rawValue) {
  const normalized = cleanString(rawValue);
  return normalized || null;
}

function getTokenFromHeader(authHeader) {
  const raw = cleanString(authHeader);
  if (!raw) return '';
  if (raw.startsWith('Bearer ')) return raw.slice(7).trim();
  if (raw.startsWith('bearer ')) return raw.slice(7).trim();
  return '';
}

function looksLikePlaceholderUrl(rawValue) {
  const value = cleanString(rawValue).toLowerCase();
  if (!value) return false;
  return (
    value.includes('xxxxxxx') ||
    value.includes('example.com') ||
    value.includes('example.org') ||
    value.includes('example.test')
  );
}

function resolvePublicOrigin(req) {
  const configuredBase = cleanString(
    process.env.PUBLIC_BASE_URL || process.env.API_PUBLIC_BASE_URL,
  );
  if (configuredBase) {
    try {
      return new URL(configuredBase).origin;
    } catch (_) {}
  }
  if (!req) return '';
  const host = cleanString(req.get('host'));
  const protocol = cleanString(req.protocol);
  if (!host || !protocol) return '';
  return `${protocol}://${host}`;
}

function toAbsolutePublicUrl(rawUrl, req) {
  const normalized = cleanString(rawUrl);
  if (!normalized) return '';
  if (normalized.includes('://')) return normalized;
  const origin = resolvePublicOrigin(req);
  if (!origin) return normalized;
  if (normalized.startsWith('/')) return `${origin}${normalized}`;
  return `${origin}/${normalized}`;
}

function isAndroidUserAgent(req) {
  const userAgent = cleanString(req.headers['user-agent']).toLowerCase();
  return userAgent.includes('android');
}

function toSafeDownloadFileName(rawValue) {
  const candidate = cleanString(rawValue);
  if (!candidate) return '';
  const safeName = path.basename(candidate);
  if (!safeName || safeName === '.' || safeName === '..') return '';
  return safeName;
}

function resolveDownloadAbsolutePath(fileName) {
  const safeName = toSafeDownloadFileName(fileName);
  if (!safeName) return null;
  const absolute = path.join(downloadsRoot, safeName);
  if (!fs.existsSync(absolute)) return null;
  return absolute;
}

function parseStringList(rawValue) {
  const source = String(rawValue || '').trim();
  if (!source) return [];
  return source
    .split(/[\n,;]/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function resolveManagedDownloadUrl(rawUrl, { routePath, defaultFile }) {
  const explicit = cleanString(rawUrl);
  if (explicit) {
    let explicitPath = explicit;
    if (explicit.includes('://')) {
      try {
        explicitPath = new URL(explicit).pathname || explicit;
      } catch (_) {
        explicitPath = explicit;
      }
    }
    const marker = '/downloads/';
    const markerIndex = explicitPath.indexOf(marker);
    if (markerIndex >= 0) {
      const relativePart = explicitPath
        .slice(markerIndex + marker.length)
        .split('?')[0]
        .split('#')[0];
      const decoded = decodeURIComponent(relativePart);
      const absolute = resolveDownloadAbsolutePath(decoded);
      if (!absolute) return '';
      const safeName = path.basename(absolute);
      return `${routePath}?file=${encodeURIComponent(safeName)}`;
    }
    return explicit;
  }

  const safeDefault = toSafeDownloadFileName(defaultFile);
  if (!safeDefault) return '';
  const absolute = resolveDownloadAbsolutePath(safeDefault);
  if (!absolute) return '';
  return routePath;
}

function resolveAndroidDownloadUrl(rawUrl) {
  return resolveManagedDownloadUrl(rawUrl, {
    routePath: '/api/app/update/android/apk',
    defaultFile:
      process.env.APP_UPDATE_ANDROID_DEFAULT_FILE || 'fenix-1.0.1.apk',
  });
}

function resolveWindowsDownloadUrl(rawUrl) {
  return resolveManagedDownloadUrl(rawUrl, {
    routePath: '/api/app/update/windows/installer',
    defaultFile:
      process.env.APP_UPDATE_WINDOWS_DEFAULT_FILE || 'projectphoenix-setup.exe',
  });
}

function resolveMacosDownloadUrl(rawUrl) {
  return resolveManagedDownloadUrl(rawUrl, {
    routePath: '/api/app/update/macos/installer',
    defaultFile:
      process.env.APP_UPDATE_MACOS_DEFAULT_FILE || 'projectphoenix.dmg',
  });
}

function resolvePlatformDownloadUrl(prefix, rawUrl) {
  if (prefix === 'APP_UPDATE_ANDROID') return resolveAndroidDownloadUrl(rawUrl);
  if (prefix === 'APP_UPDATE_WINDOWS') return resolveWindowsDownloadUrl(rawUrl);
  if (prefix === 'APP_UPDATE_MACOS') return resolveMacosDownloadUrl(rawUrl);
  return cleanString(rawUrl);
}

function buildPlatformConfig(prefix) {
  const latestVersion = cleanString(process.env[`${prefix}_LATEST_VERSION`]);
  const latestBuild = parsePositiveInt(process.env[`${prefix}_LATEST_BUILD`], 0);
  const minSupportedVersion = cleanString(process.env[`${prefix}_MIN_VERSION`]);
  const minSupportedBuild = parsePositiveInt(process.env[`${prefix}_MIN_BUILD`], 0);
  const rawDownloadUrl = cleanString(process.env[`${prefix}_DOWNLOAD_URL`]);
  const resolvedDownloadUrl = resolvePlatformDownloadUrl(prefix, rawDownloadUrl);
  const hasPlaceholderDownload =
    looksLikePlaceholderUrl(rawDownloadUrl) ||
    looksLikePlaceholderUrl(resolvedDownloadUrl);
  const downloadUrl = hasPlaceholderDownload ? '' : resolvedDownloadUrl;
  const message = cleanString(process.env[`${prefix}_MESSAGE`]);
  const title =
    cleanString(process.env[`${prefix}_TITLE`]) || 'Доступно обновление Феникс';
  const required = parseBooleanEnv(process.env[`${prefix}_REQUIRED`], false);
  const channel = cleanString(process.env[`${prefix}_CHANNEL`]) || 'stable';
  const changelog = cleanString(process.env[`${prefix}_CHANGELOG`]);
  const publishedAt = cleanString(process.env[`${prefix}_PUBLISHED_AT`]);
  const mirrors = parseStringList(process.env[`${prefix}_MIRRORS`]);

  const hasConfig =
    latestVersion ||
    latestBuild > 0 ||
    minSupportedVersion ||
    minSupportedBuild > 0 ||
    downloadUrl ||
    message ||
    required ||
    changelog;

  const enabled = parseBooleanEnv(
    process.env[`${prefix}_ENABLED`],
    Boolean(hasConfig),
  ) && !hasPlaceholderDownload;

  return {
    enabled,
    latest_version: latestVersion || null,
    latest_build: latestBuild > 0 ? latestBuild : null,
    min_supported_version: minSupportedVersion || null,
    min_supported_build: minSupportedBuild > 0 ? minSupportedBuild : null,
    required,
    download_url: downloadUrl || null,
    title,
    message: message || null,
    channel,
    changelog: changelog || null,
    published_at: publishedAt || null,
    mirrors,
  };
}

function normalizeVersion(rawVersion) {
  return cleanString(rawVersion) || '0';
}

function safePositiveInt(rawValue, fallback = 0) {
  const parsed = Number.parseInt(String(rawValue || '').trim(), 10);
  if (!Number.isFinite(parsed) || parsed < 0) return fallback;
  return parsed;
}

function compareVersionWithBuild(left, right) {
  const leftParts = normalizeVersion(left.version)
    .split('.')
    .map((value) => safePositiveInt(value, 0));
  const rightParts = normalizeVersion(right.version)
    .split('.')
    .map((value) => safePositiveInt(value, 0));
  const length = Math.max(leftParts.length, rightParts.length);
  for (let index = 0; index < length; index += 1) {
    const leftValue = leftParts[index] || 0;
    const rightValue = rightParts[index] || 0;
    if (leftValue > rightValue) return 1;
    if (leftValue < rightValue) return -1;
  }
  if ((left.build || 0) > (right.build || 0)) return 1;
  if ((left.build || 0) < (right.build || 0)) return -1;
  return 0;
}

function resolveAndroidPackageName() {
  return (
    cleanString(process.env.APP_UPDATE_ANDROID_PACKAGE_NAME) ||
    'com.garphoenix.projectphoenix'
  );
}

function resolveAllowedUpdateHosts(req) {
  const hosts = new Set();
  for (const raw of parseStringList(process.env.APP_UPDATE_ALLOWED_HOSTS)) {
    try {
      hosts.add(new URL(raw.includes('://') ? raw : `https://${raw}`).host.toLowerCase());
    } catch (_) {
      hosts.add(raw.toLowerCase());
    }
  }
  const origin = resolvePublicOrigin(req);
  if (origin) {
    try {
      hosts.add(new URL(origin).host.toLowerCase());
    } catch (_) {}
  }
  return hosts;
}

function isAllowedAndroidDownloadUrl(rawUrl, req) {
  const normalized = cleanString(rawUrl);
  if (!normalized) return false;
  if (!normalized.includes('://')) return true;
  try {
    const parsed = new URL(normalized);
    const protocol = parsed.protocol.toLowerCase();
    const host = parsed.host.toLowerCase();
    if (process.env.NODE_ENV !== 'production') {
      if (protocol === 'http:' && (host.startsWith('127.0.0.1') || host.startsWith('localhost'))) {
        return true;
      }
    }
    if (protocol !== 'https:') return false;
    return resolveAllowedUpdateHosts(req).has(host);
  } catch (_) {
    return false;
  }
}

async function computeFileSha256(absolutePath) {
  return new Promise((resolve, reject) => {
    const hash = require('crypto').createHash('sha256');
    const stream = fs.createReadStream(absolutePath);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

async function getDownloadFileMetadata(absolutePath) {
  const stat = await fs.promises.stat(absolutePath);
  const cached = apkMetadataCache.get(absolutePath);
  if (
    cached &&
    cached.size === stat.size &&
    cached.mtimeMs === stat.mtimeMs
  ) {
    return cached;
  }

  const metadata = {
    absolutePath,
    size: stat.size,
    mtimeMs: stat.mtimeMs,
    lastModified: stat.mtime.toUTCString(),
    publishedAt: stat.mtime.toISOString(),
    etag: `W/\"${stat.size.toString(16)}-${Math.floor(stat.mtimeMs).toString(16)}\"`,
    sha256: await computeFileSha256(absolutePath),
  };
  apkMetadataCache.set(absolutePath, metadata);
  return metadata;
}

function resolveEnvAndroidDownloadAbsolutePath() {
  const fallbackFile = toSafeDownloadFileName(
    process.env.APP_UPDATE_ANDROID_DEFAULT_FILE || 'fenix-1.0.1.apk',
  );
  if (!fallbackFile) return null;
  return resolveDownloadAbsolutePath(fallbackFile);
}

function formatBytesRu(bytes) {
  const value = Number(bytes || 0);
  if (!Number.isFinite(value) || value <= 0) return '0 Б';
  const units = ['Б', 'КБ', 'МБ', 'ГБ'];
  let current = value;
  let index = 0;
  while (current >= 1024 && index < units.length - 1) {
    current /= 1024;
    index += 1;
  }
  const digits = current >= 10 || index === 0 ? 0 : 1;
  return `${current.toFixed(digits)} ${units[index]}`;
}

function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

async function buildEnvAndroidPublicConfig(req) {
  const android = buildPlatformConfig('APP_UPDATE_ANDROID');
  const absoluteDownloadUrl = toAbsolutePublicUrl(android.download_url, req);
  const mirrors = (android.mirrors || [])
    .map((raw) => toAbsolutePublicUrl(raw, req))
    .filter((raw) => isAllowedAndroidDownloadUrl(raw, req));

  const localApkPath = resolveEnvAndroidDownloadAbsolutePath();
  const localMetadata = localApkPath ? await getDownloadFileMetadata(localApkPath).catch(() => null) : null;
  const envFileSize = parsePositiveInt(process.env.APP_UPDATE_ANDROID_FILE_SIZE, 0);
  const envSha256 = cleanString(process.env.APP_UPDATE_ANDROID_SHA256).toLowerCase();
  const publishedAt =
    cleanOptionalString(android.published_at) ||
    cleanOptionalString(process.env.APP_UPDATE_ANDROID_PUBLISHED_AT) ||
    localMetadata?.publishedAt ||
    null;
  const fileSize = localMetadata?.size || envFileSize || null;
  const sha256 = localMetadata?.sha256 || envSha256 || null;

  const normalizedDownloadUrl = isAllowedAndroidDownloadUrl(absoluteDownloadUrl, req)
    ? absoluteDownloadUrl
    : '';

  return {
    ...android,
    channel: cleanString(android.channel) || 'stable',
    download_url: normalizedDownloadUrl || null,
    landing_url: toAbsolutePublicUrl('/download/android', req),
    manifest_url: toAbsolutePublicUrl('/api/app/update/android/manifest', req),
    mirrors,
    file_size: fileSize,
    sha256: sha256 || null,
    published_at: publishedAt,
    package_name: resolveAndroidPackageName(),
  };
}

async function loadAndroidReleaseState() {
  return loadAndroidStableRelease({
    downloadsRoot,
    packageNameFallback: resolveAndroidPackageName(),
    getDownloadFileMetadata,
  });
}

function buildDisabledAndroidReleaseConfig(req, releaseState) {
  return {
    enabled: false,
    latest_version: null,
    latest_build: null,
    min_supported_version: null,
    min_supported_build: null,
    required: false,
    download_url: null,
    title: 'Обновление Феникс временно недоступно',
    message:
      cleanString(releaseState?.errorMessage) ||
      'Android-релиз временно недоступен на сервере.',
    channel: 'stable',
    changelog: null,
    published_at: null,
    mirrors: [],
    landing_url: toAbsolutePublicUrl('/download/android', req),
    manifest_url: toAbsolutePublicUrl('/api/app/update/android/manifest', req),
    file_size: null,
    sha256: null,
    package_name: resolveAndroidPackageName(),
    source: 'release_json',
    error_code: cleanString(releaseState?.errorCode) || null,
    error_message: cleanString(releaseState?.errorMessage) || null,
  };
}

function buildAndroidReleaseConfig(req, releaseState) {
  if (!releaseState?.active) {
    return buildDisabledAndroidReleaseConfig(req, releaseState);
  }

  const release = releaseState.release;
  const mirrors = (release.mirrors || [])
    .map((raw) => toAbsolutePublicUrl(raw, req))
    .filter((raw) => isAllowedAndroidDownloadUrl(raw, req));
  const absoluteDownloadUrl = toAbsolutePublicUrl('/api/app/update/android/apk', req);

  return {
    enabled: true,
    latest_version: release.version,
    latest_build: release.build,
    min_supported_version: release.min_supported_version,
    min_supported_build: release.min_supported_build,
    required: release.required === true,
    download_url: isAllowedAndroidDownloadUrl(absoluteDownloadUrl, req)
      ? absoluteDownloadUrl
      : null,
    title: release.title || 'Доступно обновление Феникс',
    message: release.message || null,
    channel: cleanString(release.channel) || 'stable',
    changelog: Array.isArray(release.changelog)
      ? release.changelog.join('\n')
      : cleanOptionalString(release.changelog),
    changelog_items: Array.isArray(release.changelog)
      ? release.changelog
      : [],
    published_at: release.published_at || releaseState.apkMetadata?.publishedAt || null,
    mirrors,
    landing_url: toAbsolutePublicUrl('/download/android', req),
    manifest_url: toAbsolutePublicUrl('/api/app/update/android/manifest', req),
    file_size: releaseState.apkMetadata?.size || null,
    sha256: releaseState.apkMetadata?.sha256 || null,
    package_name: release.package_name || resolveAndroidPackageName(),
    source: 'release_json',
    release_file: release.apk_file,
  };
}

async function buildAndroidPublicConfig(req) {
  const releaseState = await loadAndroidReleaseState();
  if (releaseState?.source === 'release_json') {
    return buildAndroidReleaseConfig(req, releaseState);
  }
  const envConfig = await buildEnvAndroidPublicConfig(req);
  return {
    ...envConfig,
    source: 'env_fallback',
  };
}

async function buildAndroidManifestEnvelope(req) {
  const android = await buildAndroidPublicConfig(req);
  const latestVersion = normalizeVersion(android.latest_version);
  const latestBuild = safePositiveInt(android.latest_build, 0);
  if (!android.enabled || !latestVersion || latestBuild <= 0) {
    return null;
  }
  if (!android.download_url || !android.file_size || !android.sha256) {
    return null;
  }

  const manifest = {
    version: latestVersion,
    build: latestBuild,
    channel: cleanString(android.channel) || 'stable',
    required: android.required === true,
    title: cleanString(android.title) || 'Доступно обновление Феникс',
    message: cleanOptionalString(android.message),
    changelog: cleanOptionalString(android.changelog),
    download_url: android.download_url,
    file_size: safePositiveInt(android.file_size, 0),
    sha256: cleanString(android.sha256).toLowerCase(),
    published_at: cleanOptionalString(android.published_at),
    min_supported_version: cleanOptionalString(android.min_supported_version),
    min_supported_build: safePositiveInt(android.min_supported_build, 0) || null,
    mirrors: Array.isArray(android.mirrors) ? android.mirrors : [],
    package_name: cleanString(android.package_name) || resolveAndroidPackageName(),
  };
  const signed = signManifestPayload(manifest);
  return {
    manifest,
    signature: signed.signature,
    key_id: signed.keyId,
    algorithm: signed.algorithm,
    manifest_url: toAbsolutePublicUrl('/api/app/update/android/manifest', req),
    uses_dev_signing_fallback: signed.usesDevFallback,
  };
}

async function maybeCreateUpdateNotification(req, platformConfig, platform) {
  try {
    const token = getTokenFromHeader(req.get('authorization'));
    if (!token) return;
    const context = await resolveAuthContextFromToken(
      token,
      req.headers['x-view-role'],
      { ignoreTenantSubscription: true },
    );
    if (!context?.ok || !context.user?.id) return;

    const currentVersion = normalizeVersion(req.query?.current_version);
    const currentBuild = safePositiveInt(req.query?.current_build, 0);
    if (!cleanString(req.query?.current_version) && currentBuild <= 0) {
      return;
    }

    const latestVersion = normalizeVersion(platformConfig.latest_version);
    const latestBuild = safePositiveInt(platformConfig.latest_build, 0);
    const current = { version: currentVersion, build: currentBuild };
    const latest = { version: latestVersion, build: latestBuild };
    if (compareVersionWithBuild(latest, current) <= 0) {
      return;
    }

    const versionToken = `${latest.version}+${latest.build}`;
    await createNotificationInboxItem({
      user: context.user,
      category: 'updates',
      priority: platformConfig.required ? 'high' : 'low',
      channel: 'mixed',
      title:
        cleanString(platformConfig.title) || 'Доступно обновление Феникс',
      body:
        cleanString(platformConfig.message) ||
        `Доступна версия ${versionToken}.`,
      deepLink: `/update?platform=${encodeURIComponent(platform)}&version=${encodeURIComponent(versionToken)}`,
      payload: {
        version: versionToken,
        required_update: platformConfig.required === true,
        platform,
        download_url: cleanString(platformConfig.download_url),
        manifest_url: cleanString(platformConfig.manifest_url),
        cta_label: 'Открыть обновление',
      },
      dedupeKey: `update:${platform}:${versionToken}`,
      collapseKey: `update:${platform}:${versionToken}`,
      ttlSeconds: 60 * 60 * 24 * 3,
      sourceType: 'app_update',
      sourceId: `${platform}:${versionToken}`,
      forceShow: false,
      isActionable: true,
      emit: true,
      attemptPush: true,
    });
  } catch (err) {
    console.error('app.update.notification error', err);
  }
}

async function sendAndroidApk(req, res) {
  const androidOnly = parseBooleanEnv(
    process.env.APK_DOWNLOAD_ANDROID_ONLY,
    true,
  );
  const explicitAndroidClient =
    cleanString(req.get('x-fenix-platform')).toLowerCase() === 'android' ||
    cleanString(req.query?.platform).toLowerCase() === 'android';
  if (androidOnly && !isAndroidUserAgent(req) && !explicitAndroidClient) {
    return res.status(403).json({
      ok: false,
      error: 'APK download is allowed only from Android devices',
    });
  }

  const releaseState = await loadAndroidReleaseState();
  let absolute = null;
  let safeName = '';
  let metadata = null;

  if (releaseState?.source === 'release_json') {
    if (!releaseState.active) {
      return res.status(503).json({
        ok: false,
        error:
          cleanString(releaseState.errorMessage) ||
          'Android release is temporarily unavailable on server',
      });
    }
    absolute = releaseState.absoluteApkPath;
    safeName = releaseState.apkFile;
    metadata = releaseState.apkMetadata;
  } else {
    const requestedFile = toSafeDownloadFileName(req.query?.file || '');
    const fallbackFile = toSafeDownloadFileName(
      process.env.APP_UPDATE_ANDROID_DEFAULT_FILE || 'fenix-1.0.1.apk',
    );
    const targetFile = requestedFile || fallbackFile;
    absolute = resolveDownloadAbsolutePath(targetFile);
    if (!absolute) {
      return res.status(404).json({
        ok: false,
        error: 'APK file is not configured on server',
      });
    }
    metadata = await getDownloadFileMetadata(absolute);
    safeName = path.basename(absolute);
  }

  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Cache-Control', 'private, max-age=300');
  res.setHeader('Accept-Ranges', 'bytes');
  res.setHeader('ETag', metadata.etag);
  res.setHeader('Last-Modified', metadata.lastModified);
  res.setHeader('Content-Disposition', `attachment; filename=\"${safeName}\"`);
  return res.sendFile(absolute, {
    headers: {
      'Content-Type': 'application/vnd.android.package-archive',
    },
    acceptRanges: true,
    lastModified: true,
  });
}

function sendInstallerFromDownloads(req, res, options) {
  const { queryName, envName, fallbackFileName, notFoundMessage } = options;
  const requestedFile = toSafeDownloadFileName(req.query?.[queryName] || '');
  const fallbackFile = toSafeDownloadFileName(
    process.env[envName] || fallbackFileName,
  );
  const targetFile = requestedFile || fallbackFile;
  const absolute = resolveDownloadAbsolutePath(targetFile);
  if (!absolute) {
    return res.status(404).json({
      ok: false,
      error: notFoundMessage,
    });
  }
  const safeName = path.basename(absolute);
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Cache-Control', 'private, max-age=300');
  return res.download(absolute, safeName);
}

function renderAndroidDownloadUnavailablePage(config) {
  const title = escapeHtml(
    cleanString(config?.title) || 'Android APK временно недоступен',
  );
  const message = escapeHtml(
    cleanString(config?.message) ||
      'Сейчас сервер не может выдать актуальный Android-релиз. Попробуйте позже.',
  );
  return `<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${title}</title>
<style>
  :root {
    color-scheme: dark;
    --bg:#0d0816;
    --card:#1a1128;
    --line:rgba(255,255,255,.08);
    --muted:#cbbfe0;
    --text:#fff7ff;
    --warn:#ffb347;
  }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; background:radial-gradient(circle at top left,#2e134b 0%,var(--bg) 45%); color:var(--text); }
  .wrap { max-width:720px; margin:0 auto; padding:32px 18px 48px; }
  .card { background:linear-gradient(180deg,rgba(255,255,255,.05),rgba(255,255,255,.02)); border:1px solid var(--line); border-radius:28px; padding:24px; box-shadow:0 16px 44px rgba(0,0,0,.24); }
  .badge { display:inline-flex; padding:6px 10px; border-radius:999px; background:rgba(255,179,71,.12); color:#ffd8a0; font-weight:700; font-size:12px; }
  h1 { margin:14px 0 8px; font-size:32px; line-height:1.1; }
  p { color:var(--muted); line-height:1.6; margin:0; }
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <span class="badge">Официальная Android-установка</span>
      <h1>${title}</h1>
      <p>${message}</p>
    </div>
  </div>
</body>
</html>`;
}

function renderAndroidDownloadPage(config) {
  const changelogSource = Array.isArray(config.changelog_items)
    ? config.changelog_items.join('\n')
    : cleanString(config.changelog);
  const changelogItems = changelogSource
    .split(/\n+/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => `<li>${escapeHtml(line)}</li>`)
    .join('');

  const publishedLabel = config.published_at
    ? new Intl.DateTimeFormat('ru-RU', {
        dateStyle: 'medium',
        timeStyle: 'short',
      }).format(new Date(config.published_at))
    : 'Не указана';

  const downloadButton = config.download_url
    ? `<a class=\"cta\" href=\"${escapeHtml(config.download_url)}\">Скачать APK Феникс</a>`
    : '<div class="muted">APK пока не настроен на сервере.</div>';

  return `<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Феникс для Android</title>
<style>
  :root {
    color-scheme: dark;
    --bg:#0d0816;
    --card:#1a1128;
    --line:rgba(255,255,255,.08);
    --muted:#cbbfe0;
    --text:#fff7ff;
    --accent:#32db7c;
    --accent2:#19c7c9;
  }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif; background:radial-gradient(circle at top left,#2e134b 0%,var(--bg) 45%); color:var(--text); }
  .wrap { max-width:720px; margin:0 auto; padding:32px 18px 48px; }
  .card { background:linear-gradient(180deg,rgba(255,255,255,.05),rgba(255,255,255,.02)); border:1px solid var(--line); border-radius:28px; padding:24px; box-shadow:0 16px 44px rgba(0,0,0,.24); }
  .eyebrow { color:#9fffd0; font-size:12px; font-weight:700; text-transform:uppercase; letter-spacing:.14em; }
  h1 { margin:10px 0 6px; font-size:32px; line-height:1.1; }
  .lead { margin:0 0 22px; color:var(--muted); line-height:1.5; }
  .grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:12px; margin:18px 0 22px; }
  .meta { border:1px solid var(--line); border-radius:18px; padding:14px; background:rgba(255,255,255,.02); }
  .meta strong { display:block; font-size:12px; color:#aeead7; text-transform:uppercase; letter-spacing:.08em; margin-bottom:6px; }
  .cta { display:inline-flex; align-items:center; justify-content:center; min-height:52px; padding:0 20px; border-radius:18px; text-decoration:none; color:#062b21; background:linear-gradient(135deg,var(--accent),var(--accent2)); font-weight:800; box-shadow:0 12px 28px rgba(25,199,201,.24); }
  .section { margin-top:22px; }
  .section h2 { margin:0 0 10px; font-size:18px; }
  ul { margin:0; padding-left:20px; color:var(--muted); line-height:1.6; }
  .muted { color:var(--muted); line-height:1.6; }
  .badge { display:inline-flex; padding:6px 10px; border-radius:999px; background:rgba(50,219,124,.14); color:#aef7cb; font-weight:700; font-size:12px; }
  code { word-break:break-all; color:#ddfef7; }
  @media (max-width:640px){ .grid{grid-template-columns:1fr;} h1{font-size:28px;} }
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="eyebrow">Официальная Android-установка</div>
      <h1>Феникс для Android</h1>
      <p class="lead">Это официальная страница первой установки APK. Дальнейшие обновления приложение скачивает и показывает уже внутри себя.</p>
      <span class="badge">Официальный файл Феникс</span>
      <div class="grid">
        <div class="meta"><strong>Версия</strong>${escapeHtml(`${config.latest_version || '—'}+${config.latest_build || 0}`)}</div>
        <div class="meta"><strong>Размер APK</strong>${escapeHtml(formatBytesRu(config.file_size))}</div>
        <div class="meta"><strong>Дата релиза</strong>${escapeHtml(publishedLabel)}</div>
        <div class="meta"><strong>Канал</strong>${escapeHtml(config.channel || 'stable')}</div>
      </div>
      ${downloadButton}
      <div class="section">
        <h2>Что нового</h2>
        ${changelogItems ? `<ul>${changelogItems}</ul>` : `<div class="muted">${escapeHtml(config.message || 'Исправления ошибок и улучшение стабильности.')}</div>`}
      </div>
      <div class="section">
        <h2>Как установить</h2>
        <ul>
          <li>Скачайте APK на Android-устройство.</li>
          <li>Если Android попросит разрешение, разрешите установку для браузера.</li>
          <li>После установки новые версии Феникс будут обновляться уже из самого приложения.</li>
        </ul>
      </div>
      <div class="section">
        <h2>Проверка файла</h2>
        <div class="muted">SHA-256:<br/><code>${escapeHtml(config.sha256 || 'не настроен')}</code></div>
      </div>
    </div>
  </div>
</body>
</html>`;
}

router.get('/android/apk', async (req, res) => {
  try {
    return await sendAndroidApk(req, res);
  } catch (err) {
    console.error('app.update.android.apk error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/android/manifest', async (req, res) => {
  try {
    const envelope = await buildAndroidManifestEnvelope(req);
    if (!envelope) {
      const android = await buildAndroidPublicConfig(req);
      const statusCode =
        cleanString(android.error_code) === 'invalid_release_json' ||
        cleanString(android.error_code) === 'missing_release_apk' ||
        cleanString(android.error_code) === 'broken_release_apk'
          ? 503
          : 404;
      return res.status(statusCode).json({
        ok: false,
        error:
          cleanString(android.error_message) ||
          'Android update manifest is not configured on server',
      });
    }
    const android = await buildAndroidPublicConfig(req);
    void maybeCreateUpdateNotification(req, android, 'android');
    return res.json({ ok: true, data: envelope });
  } catch (err) {
    console.error('app.update.android.manifest error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/download/android', async (req, res) => {
  try {
    const android = await buildAndroidPublicConfig(req);
    if (!android.enabled) {
      const statusCode = cleanString(android.source) === 'release_json' ? 503 : 404;
      return res
        .status(statusCode)
        .type('html')
        .send(renderAndroidDownloadUnavailablePage(android));
    }
    return res.status(200).type('html').send(renderAndroidDownloadPage(android));
  } catch (err) {
    console.error('app.update.android.page error', err);
    return res.status(500).type('html').send('<h1>Ошибка сервера</h1>');
  }
});

router.get('/windows/installer', (req, res) => {
  try {
    return sendInstallerFromDownloads(req, res, {
      queryName: 'file',
      envName: 'APP_UPDATE_WINDOWS_DEFAULT_FILE',
      fallbackFileName: 'projectphoenix-setup.exe',
      notFoundMessage: 'Windows installer is not configured on server',
    });
  } catch (err) {
    console.error('app.update.windows.installer error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/macos/installer', (req, res) => {
  try {
    return sendInstallerFromDownloads(req, res, {
      queryName: 'file',
      envName: 'APP_UPDATE_MACOS_DEFAULT_FILE',
      fallbackFileName: 'projectphoenix.dmg',
      notFoundMessage: 'macOS installer is not configured on server',
    });
  } catch (err) {
    console.error('app.update.macos.installer error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

router.get('/', async (req, res) => {
  try {
    const android = await buildAndroidPublicConfig(req);
    const ios = buildPlatformConfig('APP_UPDATE_IOS');
    const windows = buildPlatformConfig('APP_UPDATE_WINDOWS');
    const macos = buildPlatformConfig('APP_UPDATE_MACOS');
    if (ios.download_url) {
      ios.download_url = toAbsolutePublicUrl(ios.download_url, req);
    }
    if (windows.download_url) {
      windows.download_url = toAbsolutePublicUrl(windows.download_url, req);
    }
    if (macos.download_url) {
      macos.download_url = toAbsolutePublicUrl(macos.download_url, req);
    }

    const requestedPlatform = cleanString(req.query?.platform).toLowerCase();
    if (requestedPlatform === 'android') {
      void maybeCreateUpdateNotification(req, android, 'android');
    } else if (requestedPlatform === 'ios') {
      void maybeCreateUpdateNotification(req, ios, 'ios');
    } else if (requestedPlatform === 'windows') {
      void maybeCreateUpdateNotification(req, windows, 'windows');
    } else if (requestedPlatform === 'macos') {
      void maybeCreateUpdateNotification(req, macos, 'macos');
    }

    return res.json({
      ok: true,
      data: {
        android,
        ios,
        windows,
        macos,
        checked_at: new Date().toISOString(),
      },
    });
  } catch (err) {
    console.error('app.update.get error', err);
    return res.status(500).json({ ok: false, error: 'Ошибка сервера' });
  }
});

module.exports = router;
