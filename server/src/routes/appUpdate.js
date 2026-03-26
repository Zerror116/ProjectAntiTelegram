const express = require("express");
const fs = require("fs");
const path = require("path");

const router = express.Router();
const downloadsRoot = path.resolve(__dirname, "..", "..", "downloads");

function parseBooleanEnv(rawValue, fallback = false) {
  if (rawValue === undefined || rawValue === null || rawValue === "") {
    return fallback;
  }
  const normalized = String(rawValue).toLowerCase().trim();
  return ["1", "true", "yes", "on", "y"].includes(normalized);
}

function parsePositiveInt(rawValue, fallback = 0) {
  const parsed = Number.parseInt(String(rawValue || "").trim(), 10);
  if (!Number.isFinite(parsed) || parsed < 0) return fallback;
  return parsed;
}

function cleanString(rawValue) {
  return String(rawValue || "").trim();
}

function looksLikePlaceholderUrl(rawValue) {
  const value = cleanString(rawValue).toLowerCase();
  if (!value) return false;
  return (
    value.includes("xxxxxxx") ||
    value.includes("example.com") ||
    value.includes("example.org") ||
    value.includes("example.test")
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
  if (!req) return "";
  const host = cleanString(req.get("host"));
  const protocol = cleanString(req.protocol);
  if (!host || !protocol) return "";
  return `${protocol}://${host}`;
}

function toAbsolutePublicUrl(rawUrl, req) {
  const normalized = cleanString(rawUrl);
  if (!normalized) return "";
  if (normalized.includes("://")) return normalized;
  const origin = resolvePublicOrigin(req);
  if (!origin) return normalized;
  if (normalized.startsWith("/")) return `${origin}${normalized}`;
  return `${origin}/${normalized}`;
}

function isAndroidUserAgent(req) {
  const userAgent = cleanString(req.headers["user-agent"]).toLowerCase();
  return userAgent.includes("android");
}

function toSafeDownloadFileName(rawValue) {
  const candidate = cleanString(rawValue);
  if (!candidate) return "";
  const safeName = path.basename(candidate);
  if (!safeName || safeName === "." || safeName === "..") return "";
  return safeName;
}

function resolveDownloadAbsolutePath(fileName) {
  const safeName = toSafeDownloadFileName(fileName);
  if (!safeName) return null;
  const absolute = path.join(downloadsRoot, safeName);
  if (!fs.existsSync(absolute)) return null;
  return absolute;
}

function resolveManagedDownloadUrl(rawUrl, { routePath, defaultFile }) {
  const explicit = cleanString(rawUrl);
  if (explicit) {
    let explicitPath = explicit;
    if (explicit.includes("://")) {
      try {
        explicitPath = new URL(explicit).pathname || explicit;
      } catch (_) {
        explicitPath = explicit;
      }
    }
    const marker = "/downloads/";
    const markerIndex = explicitPath.indexOf(marker);
    if (markerIndex >= 0) {
      const relativePart = explicitPath
        .slice(markerIndex + marker.length)
        .split("?")[0]
        .split("#")[0];
      const decoded = decodeURIComponent(relativePart);
      const absolute = resolveDownloadAbsolutePath(decoded);
      if (!absolute) return "";
      const safeName = path.basename(absolute);
      return `${routePath}?file=${encodeURIComponent(safeName)}`;
    }
    return explicit;
  }

  const safeDefault = toSafeDownloadFileName(defaultFile);
  if (!safeDefault) return "";
  const absolute = resolveDownloadAbsolutePath(safeDefault);
  if (!absolute) return "";
  return routePath;
}

function resolveAndroidDownloadUrl(rawUrl) {
  return resolveManagedDownloadUrl(rawUrl, {
    routePath: "/api/app/update/android/apk",
    defaultFile:
      process.env.APP_UPDATE_ANDROID_DEFAULT_FILE || "fenix-1.0.1.apk",
  });
}

function resolveWindowsDownloadUrl(rawUrl) {
  return resolveManagedDownloadUrl(rawUrl, {
    routePath: "/api/app/update/windows/installer",
    defaultFile:
      process.env.APP_UPDATE_WINDOWS_DEFAULT_FILE || "projectphoenix-setup.exe",
  });
}

function resolveMacosDownloadUrl(rawUrl) {
  return resolveManagedDownloadUrl(rawUrl, {
    routePath: "/api/app/update/macos/installer",
    defaultFile:
      process.env.APP_UPDATE_MACOS_DEFAULT_FILE || "projectphoenix.dmg",
  });
}

function resolvePlatformDownloadUrl(prefix, rawUrl) {
  if (prefix === "APP_UPDATE_ANDROID") return resolveAndroidDownloadUrl(rawUrl);
  if (prefix === "APP_UPDATE_WINDOWS") return resolveWindowsDownloadUrl(rawUrl);
  if (prefix === "APP_UPDATE_MACOS") return resolveMacosDownloadUrl(rawUrl);
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
  const downloadUrl = hasPlaceholderDownload ? "" : resolvedDownloadUrl;
  const message = cleanString(process.env[`${prefix}_MESSAGE`]);
  const title =
    cleanString(process.env[`${prefix}_TITLE`]) || "Доступно обновление Феникс";
  const required = parseBooleanEnv(process.env[`${prefix}_REQUIRED`], false);

  const hasConfig =
    latestVersion ||
    latestBuild > 0 ||
    minSupportedVersion ||
    minSupportedBuild > 0 ||
    downloadUrl ||
    message ||
    required;

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
  };
}

router.get("/android/apk", (req, res) => {
  try {
    const androidOnly = parseBooleanEnv(
      process.env.APK_DOWNLOAD_ANDROID_ONLY,
      true,
    );
    const explicitAndroidClient =
      cleanString(req.get("x-fenix-platform")).toLowerCase() === "android" ||
      cleanString(req.query?.platform).toLowerCase() === "android";
    if (androidOnly && !isAndroidUserAgent(req) && !explicitAndroidClient) {
      return res.status(403).json({
        ok: false,
        error: "APK download is allowed only from Android devices",
      });
    }

    const requestedFile = toSafeDownloadFileName(req.query?.file || "");
    const fallbackFile = toSafeDownloadFileName(
      process.env.APP_UPDATE_ANDROID_DEFAULT_FILE || "fenix-1.0.1.apk",
    );
    const targetFile = requestedFile || fallbackFile;
    const absolute = resolveDownloadAbsolutePath(targetFile);
    if (!absolute) {
      return res.status(404).json({
        ok: false,
        error: "APK file is not configured on server",
      });
    }

    const safeName = path.basename(absolute);
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Cache-Control", "private, max-age=300");
    return res.download(absolute, safeName);
  } catch (err) {
    console.error("app.update.android.apk error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

function sendInstallerFromDownloads(req, res, options) {
  const { queryName, envName, fallbackFileName, notFoundMessage } = options;
  const requestedFile = toSafeDownloadFileName(req.query?.[queryName] || "");
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
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Cache-Control", "private, max-age=300");
  return res.download(absolute, safeName);
}

router.get("/windows/installer", (req, res) => {
  try {
    return sendInstallerFromDownloads(req, res, {
      queryName: "file",
      envName: "APP_UPDATE_WINDOWS_DEFAULT_FILE",
      fallbackFileName: "projectphoenix-setup.exe",
      notFoundMessage: "Windows installer is not configured on server",
    });
  } catch (err) {
    console.error("app.update.windows.installer error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.get("/macos/installer", (req, res) => {
  try {
    return sendInstallerFromDownloads(req, res, {
      queryName: "file",
      envName: "APP_UPDATE_MACOS_DEFAULT_FILE",
      fallbackFileName: "projectphoenix.dmg",
      notFoundMessage: "macOS installer is not configured on server",
    });
  } catch (err) {
    console.error("app.update.macos.installer error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.get("/", (req, res) => {
  try {
    const android = buildPlatformConfig("APP_UPDATE_ANDROID");
    const ios = buildPlatformConfig("APP_UPDATE_IOS");
    const windows = buildPlatformConfig("APP_UPDATE_WINDOWS");
    const macos = buildPlatformConfig("APP_UPDATE_MACOS");
    if (android.download_url) {
      android.download_url = toAbsolutePublicUrl(android.download_url, req);
    }
    if (ios.download_url) {
      ios.download_url = toAbsolutePublicUrl(ios.download_url, req);
    }
    if (windows.download_url) {
      windows.download_url = toAbsolutePublicUrl(windows.download_url, req);
    }
    if (macos.download_url) {
      macos.download_url = toAbsolutePublicUrl(macos.download_url, req);
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
    console.error("app.update.get error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

module.exports = router;
