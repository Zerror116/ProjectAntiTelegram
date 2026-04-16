#!/usr/bin/env node

const db = require('../src/db');
const { logReleaseCheck } = require('../src/utils/monitoring');

function parseArgs(argv) {
  const out = {
    scope: 'manual',
    status: 'warn',
    title: '',
    target: '',
    versionName: '',
    buildNumber: '',
    summary: '',
    tenantId: '',
    createdBy: '',
    detailsBase64: '',
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--scope') out.scope = argv[++i] || out.scope;
    else if (arg === '--status') out.status = argv[++i] || out.status;
    else if (arg === '--title') out.title = argv[++i] || out.title;
    else if (arg === '--target') out.target = argv[++i] || out.target;
    else if (arg === '--version') out.versionName = argv[++i] || out.versionName;
    else if (arg === '--build') out.buildNumber = argv[++i] || out.buildNumber;
    else if (arg === '--summary') out.summary = argv[++i] || out.summary;
    else if (arg === '--tenant-id') out.tenantId = argv[++i] || out.tenantId;
    else if (arg === '--created-by') out.createdBy = argv[++i] || out.createdBy;
    else if (arg === '--details-base64') out.detailsBase64 = argv[++i] || out.detailsBase64;
    else if (arg === '-h' || arg === '--help') {
      console.log('Usage: node server/scripts/report_release_health.js --scope deploy --status pass --title "Web deploy" [--target garphoenix.com] [--version 1.0.32] [--build 33] [--summary "prod smoke ok"] [--details-base64 <base64-json>]');
      process.exit(0);
    } else {
      throw new Error(`Unknown arg: ${arg}`);
    }
  }
  return out;
}

function decodeDetails(raw) {
  const normalized = String(raw || '').trim();
  if (!normalized) return {};
  try {
    return JSON.parse(Buffer.from(normalized, 'base64').toString('utf8'));
  } catch (err) {
    return { decode_error: String(err?.message || err) };
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.title.trim()) {
    throw new Error('--title is required');
  }
  const id = await logReleaseCheck({
    queryable: db,
    tenantId: args.tenantId || null,
    createdBy: args.createdBy || null,
    scope: args.scope,
    status: args.status,
    title: args.title,
    target: args.target || null,
    versionName: args.versionName || null,
    buildNumber: args.buildNumber || null,
    summary: args.summary || null,
    details: decodeDetails(args.detailsBase64),
  });
  console.log(JSON.stringify({ ok: true, id }));
}

main()
  .catch((err) => {
    console.error('report_release_health error', err);
    process.exit(1);
  })
  .finally(async () => {
    try {
      await db.platformPool.end();
    } catch (_) {}
  });
