const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { uploadsRoot } = require("./storagePaths");

const PRODUCT_PLACEHOLDER_NAME = "demo-placeholder.png";
const GENERIC_MEDIA_PLACEHOLDER_NAME = "media-unavailable.png";
const PUBLIC_MEDIA_PLACEHOLDER_NAME = "public-media-unavailable.png";
const PLACEHOLDER_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAoAAAAHgCAYAAAA10dzkAAAACXBIWXMAAAsSAAALEgHS3X78AAAGnElEQVR4nO3UQQ0AIBDAsAP/nuGNAvZoFSzZOjM7AID3zA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDvzA4A4N0MAIDv7AFCiwL6geiJ2QAAAABJRU5ErkJggg==";

const DEFAULT_DISCOVERY_ROOTS = [
  uploadsRoot,
  "/opt/fenix/server/uploads",
  "/root/fenix-restore-tmp/opt/fenix/server/uploads",
  "/root",
  "/opt",
  "/var/backups",
  "/backups",
];

function cleanString(rawValue) {
  return String(rawValue || "").trim();
}

function fileExists(targetPath) {
  try {
    return fs.existsSync(targetPath);
  } catch (_) {
    return false;
  }
}

function isDirectory(targetPath) {
  try {
    return fs.statSync(targetPath).isDirectory();
  } catch (_) {
    return false;
  }
}

function normalizeUploadsRelativePath(rawValue) {
  const value = cleanString(rawValue).replace(/\\/g, "/").replace(/^\/+/, "");
  if (!value) return null;
  const parts = value.split("/").filter(Boolean);
  if (!parts.length) return null;
  if (parts.some((part) => part === "." || part === "..")) return null;
  return parts.join("/");
}

function relativePathFromUploadsUrl(rawUrl) {
  const value = cleanString(rawUrl);
  if (!value) return null;
  let url;
  try {
    url = new URL(value, "http://localhost");
  } catch (_) {
    return null;
  }
  const pathname = decodeURIComponent(String(url.pathname || "").trim());
  if (!pathname) return null;

  const uploadsMarker = "/uploads/";
  const uploadsIndex = pathname.indexOf(uploadsMarker);
  if (uploadsIndex >= 0) {
    return normalizeUploadsRelativePath(
      pathname.slice(uploadsIndex + uploadsMarker.length),
    );
  }

  const chatMediaMatch = pathname.match(/^\/api\/chats\/media\/(image|voice|video|file)\/([^/]+)$/i);
  if (chatMediaMatch) {
    const kind = String(chatMediaMatch[1] || "").toLowerCase();
    const filename = cleanString(chatMediaMatch[2]);
    if (!filename) return null;
    const byKind = {
      image: "chat_media/images",
      voice: "chat_media/voice",
      video: "chat_media/video",
      file: "chat_media/files",
    };
    return normalizeUploadsRelativePath(`${byKind[kind]}/${filename}`);
  }

  return null;
}

function resolveManifestFileRef(rawUrl) {
  const relativeUploadPath = relativePathFromUploadsUrl(rawUrl);
  if (!relativeUploadPath) return null;
  return {
    original_url: cleanString(rawUrl),
    expected_filename: path.basename(relativeUploadPath),
    relative_upload_path: relativeUploadPath,
    expected_path: path.join(uploadsRoot, ...relativeUploadPath.split("/")),
  };
}

function ensureParentDir(targetPath) {
  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
}

function applySafePermissions(targetPath) {
  if (!fileExists(targetPath)) return;
  try {
    fs.chmodSync(targetPath, 0o644);
  } catch (_) {}
  let currentDir = path.dirname(targetPath);
  const rootDir = path.resolve(uploadsRoot);
  while (currentDir.startsWith(rootDir)) {
    try {
      fs.chmodSync(currentDir, 0o755);
    } catch (_) {}
    if (currentDir === rootDir) break;
    currentDir = path.dirname(currentDir);
  }
}

function buildManifestEntry({ kind, recordId, field, originalUrl, extra = {} }) {
  const resolved = resolveManifestFileRef(originalUrl);
  if (!resolved) return null;
  const status = fileExists(resolved.expected_path) ? "present" : "missing";
  return {
    kind: cleanString(kind),
    record_id: cleanString(recordId),
    field: cleanString(field),
    original_url: resolved.original_url,
    expected_filename: resolved.expected_filename,
    relative_upload_path: resolved.relative_upload_path,
    expected_path: resolved.expected_path,
    status,
    ...extra,
  };
}

function summaryFromManifest(entries) {
  const summary = {
    total: 0,
    present: 0,
    missing: 0,
    by_kind: {},
  };
  for (const entry of Array.isArray(entries) ? entries : []) {
    if (!entry || typeof entry !== "object") continue;
    summary.total += 1;
    const status = cleanString(entry.status) || "unknown";
    if (status === "present") summary.present += 1;
    if (status === "missing") summary.missing += 1;
    const kind = cleanString(entry.kind) || "unknown";
    const bucket =
      summary.by_kind[kind] ||
      (summary.by_kind[kind] = { total: 0, present: 0, missing: 0 });
    bucket.total += 1;
    if (status === "present") bucket.present += 1;
    if (status === "missing") bucket.missing += 1;
  }
  return summary;
}

function walkRecoveryRoots(roots, visitor, maxDepth = 6) {
  const seen = new Set();
  function visit(currentPath, depth) {
    const normalized = path.resolve(currentPath);
    if (seen.has(normalized)) return;
    seen.add(normalized);
    let stat;
    try {
      stat = fs.lstatSync(normalized);
    } catch (_) {
      return;
    }
    visitor(normalized, stat, depth);
    if (!stat.isDirectory() || depth >= maxDepth) return;
    let children = [];
    try {
      children = fs.readdirSync(normalized);
    } catch (_) {
      return;
    }
    for (const child of children) {
      visit(path.join(normalized, child), depth + 1);
    }
  }
  for (const root of roots) {
    if (!root) continue;
    visit(root, 0);
  }
}

function isSupportedArchive(filePath) {
  const lower = cleanString(filePath).toLowerCase();
  return (
    lower.endsWith(".tar") ||
    lower.endsWith(".tar.gz") ||
    lower.endsWith(".tgz") ||
    lower.endsWith(".zip")
  );
}

function discoverRecoverySources({ roots = DEFAULT_DISCOVERY_ROOTS, maxDepth = 6 } = {}) {
  const sources = [];
  walkRecoveryRoots(
    roots,
    (targetPath, stat) => {
      if (stat.isDirectory() && /[/\\]server[/\\]uploads$/.test(targetPath)) {
        sources.push({ type: "dir", path: targetPath });
        return;
      }
      if (stat.isFile() && isSupportedArchive(targetPath)) {
        sources.push({ type: "archive", path: targetPath });
      }
    },
    maxDepth,
  );
  const unique = new Map();
  for (const source of sources) {
    unique.set(`${source.type}:${path.resolve(source.path)}`, {
      ...source,
      path: path.resolve(source.path),
    });
  }
  return Array.from(unique.values());
}

function buildDirectoryIndex(rootPath) {
  const byRelative = new Map();
  const byFilename = new Map();
  walkRecoveryRoots(
    [rootPath],
    (targetPath, stat) => {
      if (!stat.isFile()) return;
      const relative = normalizeUploadsRelativePath(path.relative(rootPath, targetPath));
      if (!relative) return;
      byRelative.set(relative, targetPath);
      const filename = path.basename(relative);
      const current = byFilename.get(filename) || [];
      current.push(targetPath);
      byFilename.set(filename, current);
    },
    32,
  );
  return { byRelative, byFilename };
}

function listArchiveEntries(archivePath) {
  const lower = cleanString(archivePath).toLowerCase();
  try {
    if (lower.endsWith(".zip")) {
      const output = execFileSync("unzip", ["-Z1", archivePath], {
        encoding: "utf8",
        maxBuffer: 64 * 1024 * 1024,
      });
      return String(output || "")
        .split(/\r?\n/)
        .map((line) => normalizeUploadsRelativePath(line))
        .filter(Boolean);
    }
    const output = execFileSync("tar", ["-tf", archivePath], {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    });
    return String(output || "")
      .split(/\r?\n/)
      .map((line) => normalizeUploadsRelativePath(line))
      .filter(Boolean);
  } catch (_) {
    return [];
  }
}

function buildArchiveIndex(archivePath) {
  const entries = listArchiveEntries(archivePath);
  const byRelative = new Map();
  const byFilename = new Map();
  for (const entry of entries) {
    byRelative.set(entry, entry);
    const filename = path.basename(entry);
    const current = byFilename.get(filename) || [];
    current.push(entry);
    byFilename.set(filename, current);
  }
  return { byRelative, byFilename };
}

function extractArchiveEntry(archivePath, entryName) {
  const lower = cleanString(archivePath).toLowerCase();
  if (lower.endsWith(".zip")) {
    return execFileSync("unzip", ["-p", archivePath, entryName], {
      encoding: null,
      maxBuffer: 128 * 1024 * 1024,
    });
  }
  return execFileSync("tar", ["-xOf", archivePath, entryName], {
    encoding: null,
    maxBuffer: 128 * 1024 * 1024,
  });
}

function matchArchiveEntry(index, relativePath, filename) {
  const exact = index.byRelative.get(relativePath);
  if (exact) return exact;
  const suffixMatches = Array.from(index.byRelative.keys()).filter((entry) =>
    entry.endsWith(`/${relativePath}`),
  );
  if (suffixMatches.length > 0) return suffixMatches[0];
  const filenameMatches = index.byFilename.get(filename) || [];
  return filenameMatches[0] || null;
}

function locateRecoveryCandidate(entry, sources, cache = new Map()) {
  const relativePath = cleanString(entry?.relative_upload_path);
  const filename = cleanString(entry?.expected_filename);
  if (!relativePath || !filename) return null;

  for (const source of sources) {
    if (!source || !source.path) continue;
    const cacheKey = `${source.type}:${source.path}`;
    let index = cache.get(cacheKey);
    if (!index) {
      index = source.type === "archive"
        ? buildArchiveIndex(source.path)
        : buildDirectoryIndex(source.path);
      cache.set(cacheKey, index);
    }

    if (source.type === "archive") {
      const archiveEntry = matchArchiveEntry(index, relativePath, filename);
      if (archiveEntry) {
        return {
          type: "archive",
          source_path: source.path,
          source_entry: archiveEntry,
          resolved_from: `${source.path}:${archiveEntry}`,
        };
      }
      continue;
    }

    const exactPath = index.byRelative.get(relativePath);
    if (exactPath) {
      return {
        type: "dir",
        source_path: exactPath,
        resolved_from: exactPath,
      };
    }
    const filenameMatches = index.byFilename.get(filename) || [];
    if (filenameMatches.length > 0) {
      return {
        type: "dir",
        source_path: filenameMatches[0],
        resolved_from: filenameMatches[0],
      };
    }
  }

  return null;
}

function restoreEntryFromCandidate(entry, candidate) {
  if (!entry || !candidate) return false;
  const expectedPath = cleanString(entry.expected_path);
  if (!expectedPath) return false;
  ensureParentDir(expectedPath);
  if (candidate.type === "archive") {
    const content = extractArchiveEntry(candidate.source_path, candidate.source_entry);
    fs.writeFileSync(expectedPath, content);
  } else {
    fs.copyFileSync(candidate.source_path, expectedPath);
  }
  applySafePermissions(expectedPath);
  return true;
}

function ensurePlaceholderFile(targetPath) {
  ensureParentDir(targetPath);
  if (!fileExists(targetPath)) {
    fs.writeFileSync(targetPath, Buffer.from(PLACEHOLDER_PNG_BASE64, "base64"));
  }
  applySafePermissions(targetPath);
}

function buildAbsoluteUploadUrl(publicBaseUrl, relativeUploadPath) {
  const base = cleanString(publicBaseUrl).replace(/\/+$/, "");
  const relative = normalizeUploadsRelativePath(relativeUploadPath);
  if (!base || !relative) return null;
  return `${base}/uploads/${relative}`;
}

function ensurePlaceholderAssets(publicBaseUrl) {
  const productRelative = `products/${PRODUCT_PLACEHOLDER_NAME}`;
  const mediaRelative = `chat_media/images/${GENERIC_MEDIA_PLACEHOLDER_NAME}`;
  const publicMediaRelative = `claims/${PUBLIC_MEDIA_PLACEHOLDER_NAME}`;
  ensurePlaceholderFile(path.join(uploadsRoot, ...productRelative.split("/")));
  ensurePlaceholderFile(path.join(uploadsRoot, ...mediaRelative.split("/")));
  ensurePlaceholderFile(path.join(uploadsRoot, ...publicMediaRelative.split("/")));
  return {
    product_placeholder_url: buildAbsoluteUploadUrl(publicBaseUrl, productRelative),
    media_placeholder_url: buildAbsoluteUploadUrl(publicBaseUrl, mediaRelative),
    public_media_placeholder_url: buildAbsoluteUploadUrl(publicBaseUrl, publicMediaRelative),
  };
}

module.exports = {
  PRODUCT_PLACEHOLDER_NAME,
  GENERIC_MEDIA_PLACEHOLDER_NAME,
  PUBLIC_MEDIA_PLACEHOLDER_NAME,
  DEFAULT_DISCOVERY_ROOTS,
  cleanString,
  fileExists,
  isDirectory,
  normalizeUploadsRelativePath,
  relativePathFromUploadsUrl,
  resolveManifestFileRef,
  ensureParentDir,
  applySafePermissions,
  buildManifestEntry,
  summaryFromManifest,
  discoverRecoverySources,
  buildDirectoryIndex,
  buildArchiveIndex,
  locateRecoveryCandidate,
  restoreEntryFromCandidate,
  ensurePlaceholderAssets,
  buildAbsoluteUploadUrl,
};
