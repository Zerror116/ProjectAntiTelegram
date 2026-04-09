#!/usr/bin/env node

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const { stableJson } = require('../server/src/utils/appUpdateManifest');

function fail(message) {
  console.error(`[check_android_manifest_parity] ERROR: ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const out = {
    manifestFile: '',
    manifestUrl: '',
    publicKey: '',
    publicKeyFile: '',
    stdin: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--manifest-file') {
      out.manifestFile = argv[index + 1] || '';
      index += 1;
    } else if (arg === '--manifest-url') {
      out.manifestUrl = argv[index + 1] || '';
      index += 1;
    } else if (arg === '--public-key') {
      out.publicKey = argv[index + 1] || '';
      index += 1;
    } else if (arg === '--public-key-file') {
      out.publicKeyFile = argv[index + 1] || '';
      index += 1;
    } else if (arg === '--stdin') {
      out.stdin = true;
    } else if (arg === '-h' || arg === '--help') {
      console.log(`Usage:
  node scripts/check_android_manifest_parity.js --stdin [--public-key "..."]
  node scripts/check_android_manifest_parity.js --manifest-file /abs/path/manifest.json [--public-key "..."]
  node scripts/check_android_manifest_parity.js --manifest-url https://example.com/api/app/update/android/manifest [--public-key "..."]

Env:
  APP_UPDATE_MANIFEST_PUBLIC_KEY=-----BEGIN PUBLIC KEY-----...`);
      process.exit(0);
    } else {
      fail(`Unknown arg: ${arg}`);
    }
  }
  return out;
}

function cleanPem(rawValue) {
  return String(rawValue || '').trim().replace(/\\n/g, '\n').trim();
}

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      data += chunk;
    });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', reject);
  });
}

async function loadJsonInput(options) {
  if (options.manifestFile) {
    return fs.readFileSync(path.resolve(options.manifestFile), 'utf8');
  }
  if (options.manifestUrl) {
    const response = await fetch(options.manifestUrl);
    const body = await response.text();
    if (!response.ok) {
      fail(`Manifest URL returned ${response.status}: ${body}`);
    }
    return body;
  }
  if (options.stdin || !process.stdin.isTTY) {
    return readStdin();
  }
  fail('Manifest input is required: use --stdin, --manifest-file, or --manifest-url');
}

function normalizeEnvelope(source) {
  if (!source || typeof source !== 'object') {
    fail('Manifest JSON must be an object');
  }
  const envelope = source.ok === true && source.data && typeof source.data === 'object'
    ? source.data
    : source;
  const manifest = envelope.manifest;
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
    fail('Envelope is missing manifest object');
  }
  const signature = String(envelope.signature || '').trim();
  const keyId = String(envelope.key_id || envelope.keyId || '').trim();
  const algorithm = String(envelope.algorithm || '').trim();
  if (!signature) fail('Envelope is missing signature');
  if (!algorithm) fail('Envelope is missing algorithm');
  return { manifest, signature, keyId, algorithm };
}

function androidCanonicalJson(value) {
  if (value === null || value === undefined) return 'null';
  if (Array.isArray(value)) {
    return `[${value.map((item) => androidCanonicalJson(item)).join(',')}]`;
  }
  if (typeof value === 'object') {
    const keys = Object.keys(value).sort();
    return `{${keys
      .map((key) => `${JSON.stringify(key)}:${androidCanonicalJson(value[key])}`)
      .join(',')}}`;
  }
  if (typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') return String(value);
  return JSON.stringify(String(value));
}

function resolvePublicKey(options) {
  if (options.publicKeyFile) {
    return cleanPem(fs.readFileSync(path.resolve(options.publicKeyFile), 'utf8'));
  }
  return cleanPem(options.publicKey || process.env.APP_UPDATE_MANIFEST_PUBLIC_KEY);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const raw = await loadJsonInput(options);
  const parsed = JSON.parse(raw);
  const envelope = normalizeEnvelope(parsed);
  const publicKey = resolvePublicKey(options);
  if (!publicKey) {
    fail(
      'Public key is required: pass --public-key, --public-key-file, or APP_UPDATE_MANIFEST_PUBLIC_KEY',
    );
  }

  const stable = stableJson(envelope.manifest);
  const android = androidCanonicalJson(envelope.manifest);
  const signatureBuffer = Buffer.from(envelope.signature, 'base64');
  const keyObject = crypto.createPublicKey(publicKey);
  const stableVerify = crypto.verify(
    null,
    Buffer.from(stable, 'utf8'),
    keyObject,
    signatureBuffer,
  );
  const androidVerify = crypto.verify(
    null,
    Buffer.from(android, 'utf8'),
    keyObject,
    signatureBuffer,
  );
  const same = stable === android;

  const summary = {
    key_id: envelope.keyId || null,
    algorithm: envelope.algorithm,
    same,
    stable_verify: stableVerify,
    android_verify: androidVerify,
    canonical_length: stable.length,
  };
  console.log(JSON.stringify(summary));

  if (!same) fail('Server stableJson and Android canonicalJson differ');
  if (!stableVerify || !androidVerify) {
    fail('Manifest signature failed verification');
  }
}

main().catch((error) => fail(error?.stack || error?.message || String(error)));
