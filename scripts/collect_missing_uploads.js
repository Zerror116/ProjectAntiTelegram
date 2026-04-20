#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

function cleanString(rawValue) {
  return String(rawValue || "").trim();
}

function parseArgs(argv) {
  const home = process.env.HOME || process.env.USERPROFILE || process.cwd();
  const args = {
    manifest: "",
    bundle: path.resolve(process.cwd(), "tmp/uploads-recovery-bundle"),
    sources: [
      path.join(home, "Desktop"),
      path.join(home, "Downloads"),
      path.join(home, "Documents"),
      path.join(home, "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"),
      path.join(home, "Library/Containers/ru.keepcoder.Telegram"),
    ],
  };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--manifest") {
      args.manifest = path.resolve(argv[index + 1] || "");
      index += 1;
      continue;
    }
    if (token === "--bundle") {
      args.bundle = path.resolve(argv[index + 1] || "");
      index += 1;
      continue;
    }
    if (token === "--source") {
      args.sources.push(path.resolve(argv[index + 1] || ""));
      index += 1;
      continue;
    }
    if (token === "-h" || token === "--help") {
      console.log("Usage: node scripts/collect_missing_uploads.js --manifest FILE [--bundle DIR] [--source DIR]");
      process.exit(0);
    }
  }
  if (!args.manifest) throw new Error("--manifest is required");
  return args;
}

function loadManifest(filePath) {
  const parsed = JSON.parse(fs.readFileSync(filePath, "utf8"));
  if (Array.isArray(parsed.entries)) return parsed;
  if (Array.isArray(parsed)) return { entries: parsed };
  throw new Error(`Unsupported manifest format: ${filePath}`);
}

function walkDirectory(rootPath, visitor) {
  const stack = [rootPath];
  while (stack.length > 0) {
    const current = stack.pop();
    let stat;
    try {
      stat = fs.lstatSync(current);
    } catch (_) {
      continue;
    }
    if (stat.isSymbolicLink()) continue;
    if (stat.isDirectory()) {
      let children = [];
      try {
        children = fs.readdirSync(current);
      } catch (_) {
        continue;
      }
      for (const child of children) {
        stack.push(path.join(current, child));
      }
      continue;
    }
    if (stat.isFile()) {
      visitor(current);
    }
  }
}

function buildFilenameSet(entries) {
  const filenames = new Set();
  for (const entry of entries) {
    const filename = cleanString(entry.expected_filename);
    if (filename) filenames.add(filename);
  }
  return filenames;
}

function copyFileSafe(sourcePath, targetPath) {
  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
  fs.copyFileSync(sourcePath, targetPath);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const manifest = loadManifest(args.manifest);
  const missingEntries = (manifest.entries || []).filter(
    (entry) => cleanString(entry.status) === "missing",
  );
  const neededFilenames = buildFilenameSet(missingEntries);
  const foundByFilename = new Map();

  for (const source of args.sources) {
    if (!source || !fs.existsSync(source)) continue;
    walkDirectory(source, (filePath) => {
      const filename = path.basename(filePath);
      if (!neededFilenames.has(filename) || foundByFilename.has(filename)) {
        return;
      }
      foundByFilename.set(filename, filePath);
    });
  }

  const restored = [];
  const unresolved = [];
  for (const entry of missingEntries) {
    const filename = cleanString(entry.expected_filename);
    const relativeUploadPath = cleanString(entry.relative_upload_path);
    if (!filename || !relativeUploadPath) {
      unresolved.push({ ...entry, reason: "invalid_manifest_entry" });
      continue;
    }
    const sourcePath = foundByFilename.get(filename);
    if (!sourcePath) {
      unresolved.push({ ...entry, reason: "not_found_in_sources" });
      continue;
    }
    const targetPath = path.join(args.bundle, ...relativeUploadPath.split("/"));
    copyFileSafe(sourcePath, targetPath);
    restored.push({
      ...entry,
      collected_from: sourcePath,
      bundle_path: targetPath,
    });
  }

  const payload = {
    generated_at: new Date().toISOString(),
    manifest: args.manifest,
    bundle_root: args.bundle,
    sources: args.sources.filter((source) => source && fs.existsSync(source)),
    restored_count: restored.length,
    unresolved_count: unresolved.length,
    restored,
    unresolved,
  };

  fs.mkdirSync(args.bundle, { recursive: true });
  const reportPath = path.join(args.bundle, "bundle-manifest.json");
  fs.writeFileSync(reportPath, JSON.stringify(payload, null, 2));

  console.log(`[collect_missing_uploads] restored=${restored.length} unresolved=${unresolved.length}`);
  console.log(`[collect_missing_uploads] bundle=${args.bundle}`);
  console.log(`[collect_missing_uploads] report=${reportPath}`);
}

try {
  main();
} catch (err) {
  console.error("[collect_missing_uploads] fatal", err);
  process.exit(1);
}
