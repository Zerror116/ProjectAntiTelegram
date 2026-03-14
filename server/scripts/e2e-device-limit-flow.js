#!/usr/bin/env node

/* eslint-disable no-console */

const crypto = require('crypto');

const BASE_URL = String(process.env.E2E_BASE_URL || 'http://127.0.0.1:3000')
  .trim()
  .replace(/\/+$/, '');

const INVITE_CODE = String(
  process.env.E2E_DEVICE_LIMIT_INVITE_CODE || process.env.E2E_INVITE_CODE || '',
)
  .trim()
  .toUpperCase();

const REQUIRE_STRICT = ['1', 'true', 'yes'].includes(
  String(process.env.E2E_REQUIRE_DEVICE_LIMIT || '').trim().toLowerCase(),
);

const DEVICE_FINGERPRINT = String(
  process.env.E2E_DEVICE_LIMIT_FINGERPRINT ||
    `device-limit-e2e-${process.platform}-${Date.now()}`,
)
  .trim()
  .slice(0, 180);

function printStep(step, details) {
  const stamp = new Date().toISOString();
  console.log(`[${stamp}] ${step} ${details}`);
}

function randomHex(size = 3) {
  return crypto.randomBytes(size).toString('hex');
}

function randomPhone() {
  const tail = String(Math.floor(Math.random() * 1_000_000_000))
    .padStart(9, '0')
    .slice(0, 9);
  return `79${tail}`;
}

function asObject(value, context) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return value;
  }
  throw new Error(`${context}: expected object`);
}

function createHeaders({ json = true } = {}) {
  const headers = {};
  if (json) headers['Content-Type'] = 'application/json';
  return headers;
}

async function requestJson(path, { method = 'GET', body } = {}) {
  const response = await fetch(`${BASE_URL}${path}`, {
    method,
    headers: createHeaders({ json: true }),
    body: body == null ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch (_) {
    data = { raw: text };
  }
  return { response, data };
}

async function registerClient({ idx }) {
  const email = `e2e-device-${Date.now()}-${idx}-${randomHex(2)}@example.com`;
  const password = `Pass!${randomHex(4)}Aa`;
  const payload = {
    email,
    password,
    name: `E2E Device ${idx}`,
    phone: randomPhone(),
    invite_code: INVITE_CODE,
    device_fingerprint: DEVICE_FINGERPRINT,
  };

  const { response, data } = await requestJson('/api/auth/register', {
    method: 'POST',
    body: payload,
  });
  return { response, data, payload };
}

async function run() {
  if (!INVITE_CODE) {
    const msg =
      'Missing invite code. Set E2E_DEVICE_LIMIT_INVITE_CODE (or E2E_INVITE_CODE).';
    if (REQUIRE_STRICT) {
      throw new Error(msg);
    }
    printStep('SKIP', msg);
    return;
  }

  printStep('INFO', `fingerprint=${DEVICE_FINGERPRINT}`);

  printStep('ACTION', 'register #1 with shared device fingerprint');
  const first = await registerClient({ idx: 1 });
  if (first.response.status !== 201) {
    throw new Error(
      `register #1 failed: HTTP ${first.response.status} ${JSON.stringify(first.data).slice(0, 600)}`,
    );
  }
  const firstRoot = asObject(first.data, 'register#1.root');
  if (!String(firstRoot.token || '').trim()) {
    throw new Error('register #1 -> token missing');
  }

  printStep('ACTION', 'register #2 with same device fingerprint');
  const second = await registerClient({ idx: 2 });
  if (second.response.status !== 201) {
    throw new Error(
      `register #2 failed: HTTP ${second.response.status} ${JSON.stringify(second.data).slice(0, 600)}`,
    );
  }
  const secondRoot = asObject(second.data, 'register#2.root');
  if (!String(secondRoot.token || '').trim()) {
    throw new Error('register #2 -> token missing');
  }

  printStep('ACTION', 'register #3 with same device fingerprint (must be blocked)');
  const third = await registerClient({ idx: 3 });
  if (third.response.status !== 403) {
    throw new Error(
      `register #3 expected HTTP 403, got ${third.response.status} ${JSON.stringify(third.data).slice(0, 700)}`,
    );
  }

  const errorText = String(third.data?.error || third.data?.message || '')
    .toLowerCase()
    .trim();
  if (!errorText.includes('максимум 2 аккаунта')) {
    throw new Error(
      `register #3 returned unexpected error text: ${JSON.stringify(third.data).slice(0, 500)}`,
    );
  }

  printStep('SUCCESS', 'device-account-limit flow passed');
}

run().catch((err) => {
  console.error('DEVICE LIMIT E2E FAILED:', err?.message || err);
  process.exit(1);
});
