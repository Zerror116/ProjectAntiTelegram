#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const {
  cleanString,
  fileExists,
  discoverRecoverySources,
  locateRecoveryCandidate,
  restoreEntryFromCandidate,
  summaryFromManifest,
} = require("../src/utils/uploadRecovery");

function parseArgs(argv) {
  const args = {
    manifest: "",
    output: "",
    discover: true,
    sources: [],
    missingOnly: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--manifest") {
      args.manifest = path.resolve(argv[index + 1] || "");
      index += 1;
      continue;
    }
    if (token === "--output") {
      args.output = path.resolve(argv[index + 1] || "");
      index += 1;
      continue;
    }
    if (token === "--source") {
      args.sources.push(path.resolve(argv[index + 1] || ""));
      index += 1;
      continue;
    }
    if (token === "--no-discover") {
      args.discover = false;
      continue;
    }
    if (token === "--missing-only") {
      args.missingOnly = true;
      continue;
    }
    if (token === "-h" || token === "--help") {
      console.log(
        "Usage: node server/scripts/uploads_recovery_restore.js --manifest FILE [--output FILE] [--source PATH] [--no-discover] [--missing-only]",
      );
      process.exit(0);
    }
  }
  if (!args.manifest) {
    throw new Error("--manifest is required");
  }
  if (!args.output) {
    args.output = args.manifest;
  }
  return args;
}

function loadManifest(manifestPath) {
  const parsed = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  if (Array.isArray(parsed)) return { entries: parsed };
  if (Array.isArray(parsed.entries)) return parsed;
  throw new Error(`Manifest has unsupported shape: ${manifestPath}`);
}

function normalizeSources(args) {
  const sources = [];
  if (args.discover) {
    sources.push(...discoverRecoverySources());
  }
  for (const sourcePath of args.sources) {
    if (!sourcePath) continue;
    const stat = fs.existsSync(sourcePath) ? fs.statSync(sourcePath) : null;
    if (!stat) continue;
    sources.push({
      type: stat.isDirectory() ? "dir" : "archive",
      path: sourcePath,
    });
  }
  const unique = new Map();
  for (const source of sources) {
    unique.set(`${source.type}:${path.resolve(source.path)}`, {
      ...source,
      path: path.resolve(source.path),
    });
  }
  return Array.from(unique.values()).filter((source) => fs.existsSync(source.path));
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const manifest = loadManifest(args.manifest);
  const sources = normalizeSources(args);
  const indexCache = new Map();
  let restored = 0;
  let alreadyPresent = 0;
  let unresolved = 0;

  for (const entry of manifest.entries) {
    if (!entry || typeof entry !== "object") continue;
    const expectedPath = cleanString(entry.expected_path);
    if (!expectedPath) continue;
    if (fileExists(expectedPath)) {
      entry.status = "present";
      entry.resolved_from = entry.resolved_from || "current_uploads";
      alreadyPresent += 1;
      continue;
    }
    if (args.missingOnly && cleanString(entry.status) !== "missing") {
      continue;
    }
    const candidate = locateRecoveryCandidate(entry, sources, indexCache);
    if (!candidate) {
      entry.status = "missing";
      unresolved += 1;
      continue;
    }
    restoreEntryFromCandidate(entry, candidate);
    entry.status = fileExists(expectedPath) ? "present" : "missing";
    entry.resolved_from = candidate.resolved_from;
    if (entry.status === "present") {
      restored += 1;
    } else {
      unresolved += 1;
    }
  }

  manifest.generated_at = new Date().toISOString();
  manifest.restore_run = {
    restored,
    already_present: alreadyPresent,
    unresolved,
    sources: sources.map((source) => `${source.type}:${source.path}`),
    summary: summaryFromManifest(manifest.entries),
  };

  fs.mkdirSync(path.dirname(args.output), { recursive: true });
  fs.writeFileSync(args.output, JSON.stringify(manifest, null, 2));

  console.log(`[uploads_recovery_restore] restored=${restored} already_present=${alreadyPresent} unresolved=${unresolved}`);
  console.log(`[uploads_recovery_restore] wrote ${args.output}`);
  console.log(JSON.stringify(manifest.restore_run.summary, null, 2));
}

try {
  main();
} catch (err) {
  console.error("[uploads_recovery_restore] fatal", err);
  process.exit(1);
}
