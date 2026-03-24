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

function toSafeApkFileName(rawValue) {
  const candidate = cleanString(rawValue);
  if (!candidate) return "";
  const safeName = path.basename(candidate);
  if (!safeName || safeName === "." || safeName === "..") return "";
  return safeName;
}

function resolveAndroidApkAbsolutePath(fileName) {
  const safeName = toSafeApkFileName(fileName);
  if (!safeName) return null;
  const absolute = path.join(downloadsRoot, safeName);
  if (!fs.existsSync(absolute)) return null;
  return absolute;
}

function resolveAndroidDownloadUrl(rawUrl) {
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
      const absolute = resolveAndroidApkAbsolutePath(decoded);
      if (!absolute) return "";
      const safeName = path.basename(absolute);
      return `/api/app/update/android/apk?file=${encodeURIComponent(safeName)}`;
    }
    return explicit;
  }

  const defaultFile = toSafeApkFileName(
    process.env.APP_UPDATE_ANDROID_DEFAULT_FILE || "fenix-1.0.1.apk",
  );
  if (!defaultFile) return "";
  const absolute = resolveAndroidApkAbsolutePath(defaultFile);
  if (!absolute) return "";
  return "/api/app/update/android/apk";
}

function buildPlatformConfig(prefix) {
  const latestVersion = cleanString(process.env[`${prefix}_LATEST_VERSION`]);
  const latestBuild = parsePositiveInt(process.env[`${prefix}_LATEST_BUILD`], 0);
  const minSupportedVersion = cleanString(process.env[`${prefix}_MIN_VERSION`]);
  const minSupportedBuild = parsePositiveInt(process.env[`${prefix}_MIN_BUILD`], 0);
  const rawDownloadUrl = cleanString(process.env[`${prefix}_DOWNLOAD_URL`]);
  const downloadUrl = prefix === "APP_UPDATE_ANDROID"
    ? resolveAndroidDownloadUrl(rawDownloadUrl)
    : rawDownloadUrl;
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
  );

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
    if (androidOnly && !isAndroidUserAgent(req)) {
      return res.status(403).json({
        ok: false,
        error: "APK download is allowed only from Android devices",
      });
    }

    const requestedFile = toSafeApkFileName(req.query?.file || "");
    const fallbackFile = toSafeApkFileName(
      process.env.APP_UPDATE_ANDROID_DEFAULT_FILE || "fenix-1.0.1.apk",
    );
    const targetFile = requestedFile || fallbackFile;
    const absolute = resolveAndroidApkAbsolutePath(targetFile);
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

router.get("/", (req, res) => {
  try {
    const android = buildPlatformConfig("APP_UPDATE_ANDROID");
    const ios = buildPlatformConfig("APP_UPDATE_IOS");
    if (android.download_url) {
      android.download_url = toAbsolutePublicUrl(android.download_url, req);
    }
    if (ios.download_url) {
      ios.download_url = toAbsolutePublicUrl(ios.download_url, req);
    }

    return res.json({
      ok: true,
      data: {
        android,
        ios,
        checked_at: new Date().toISOString(),
      },
    });
  } catch (err) {
    console.error("app.update.get error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

module.exports = router;
