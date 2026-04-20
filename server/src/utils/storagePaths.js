const fs = require("fs");
const path = require("path");

const serverRoot = path.resolve(__dirname, "..", "..");

function cleanString(rawValue) {
  return String(rawValue || "").trim();
}

function resolveBaseRoot() {
  const explicitStorageRoot = cleanString(process.env.APP_STORAGE_ROOT);
  if (explicitStorageRoot) {
    return path.resolve(explicitStorageRoot);
  }
  return serverRoot;
}

function resolveUploadsRoot() {
  const explicitUploadsRoot = cleanString(process.env.UPLOADS_ROOT);
  if (explicitUploadsRoot) {
    return path.resolve(explicitUploadsRoot);
  }
  return path.join(resolveBaseRoot(), "uploads");
}

function resolveDownloadsRoot() {
  const explicitDownloadsRoot = cleanString(process.env.DOWNLOADS_ROOT);
  if (explicitDownloadsRoot) {
    return path.resolve(explicitDownloadsRoot);
  }
  return path.join(resolveBaseRoot(), "downloads");
}

const uploadsRoot = resolveUploadsRoot();
const downloadsRoot = resolveDownloadsRoot();

function uploadsPath(...parts) {
  return path.join(uploadsRoot, ...parts);
}

function downloadsPath(...parts) {
  return path.join(downloadsRoot, ...parts);
}

function ensureStorageLayout() {
  fs.mkdirSync(uploadsPath("products"), { recursive: true });
  fs.mkdirSync(uploadsPath("products", "variants"), { recursive: true });
  fs.mkdirSync(uploadsPath("channels"), { recursive: true });
  fs.mkdirSync(uploadsPath("channels", "variants"), { recursive: true });
  fs.mkdirSync(uploadsPath("users"), { recursive: true });
  fs.mkdirSync(uploadsPath("users", "variants"), { recursive: true });
  fs.mkdirSync(uploadsPath("claims"), { recursive: true });
  fs.mkdirSync(uploadsPath("claims", "variants"), { recursive: true });
  fs.mkdirSync(uploadsPath("chat_media", "images"), { recursive: true });
  fs.mkdirSync(uploadsPath("chat_media", "voice"), { recursive: true });
  fs.mkdirSync(uploadsPath("chat_media", "video"), { recursive: true });
  fs.mkdirSync(uploadsPath("chat_media", "files"), { recursive: true });
  fs.mkdirSync(uploadsPath("chat_media", "sessions"), { recursive: true });
  fs.mkdirSync(downloadsRoot, { recursive: true });
}

module.exports = {
  serverRoot,
  uploadsRoot,
  downloadsRoot,
  uploadsPath,
  downloadsPath,
  ensureStorageLayout,
};
