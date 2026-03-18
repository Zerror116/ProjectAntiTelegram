const express = require("express");

const router = express.Router();

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

function buildPlatformConfig(prefix) {
  const latestVersion = cleanString(process.env[`${prefix}_LATEST_VERSION`]);
  const latestBuild = parsePositiveInt(process.env[`${prefix}_LATEST_BUILD`], 0);
  const minSupportedVersion = cleanString(process.env[`${prefix}_MIN_VERSION`]);
  const minSupportedBuild = parsePositiveInt(process.env[`${prefix}_MIN_BUILD`], 0);
  const downloadUrl = cleanString(process.env[`${prefix}_DOWNLOAD_URL`]);
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

router.get("/", (req, res) => {
  try {
    const android = buildPlatformConfig("APP_UPDATE_ANDROID");
    const ios = buildPlatformConfig("APP_UPDATE_IOS");

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
