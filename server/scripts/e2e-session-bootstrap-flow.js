#!/usr/bin/env node

/* eslint-disable no-console */

const path = require('path');
const jwt = require('jsonwebtoken');
const dotenv = require('dotenv');

const serverRoot = path.resolve(__dirname, '..');
dotenv.config({ path: path.join(serverRoot, '.env') });
if (process.env.NODE_ENV !== 'production') {
  dotenv.config({ path: path.join(serverRoot, '.env.local'), override: true });
}

const { signJwt } = require('../src/utils/jwt');

const BASE_URL = String(process.env.E2E_BASE_URL || 'http://127.0.0.1:3000')
  .trim()
  .replace(/\/+$/, '');
const EMAIL = String(process.env.E2E_EMAIL || '').trim().toLowerCase();
const PASSWORD = String(process.env.E2E_PASSWORD || '').trim();
const TENANT_CODE = String(process.env.E2E_TENANT_CODE || '').trim();
const TOTP_CODE = String(process.env.E2E_TOTP_CODE || '').trim();
const BACKUP_CODE = String(process.env.E2E_BACKUP_CODE || '').trim();
const DEVICE_FINGERPRINT = String(
  process.env.E2E_SESSION_BOOTSTRAP_FINGERPRINT ||
    `session-bootstrap-e2e-${process.platform}`,
)
  .trim()
  .slice(0, 180);

function printStep(step, details) {
  const stamp = new Date().toISOString();
  console.log(`[${stamp}] ${step} ${details}`);
}

function asObject(value, context) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return value;
  }
  throw new Error(`${context}: expected object`);
}

function createHeaders(token = '') {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  return headers;
}

async function requestJson(pathName, { method = 'GET', token = '', body } = {}) {
  const response = await fetch(`${BASE_URL}${pathName}`, {
    method,
    headers: createHeaders(token),
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

async function login() {
  const body = {
    email: EMAIL,
    password: PASSWORD,
    device_fingerprint: DEVICE_FINGERPRINT,
  };
  if (TENANT_CODE) body.tenant_code = TENANT_CODE;

  let result = await requestJson('/api/auth/login', {
    method: 'POST',
    body,
  });

  if (
    result.response.status === 401 &&
    (result.data?.two_factor_required || result.data?.twoFactorRequired)
  ) {
    const code = TOTP_CODE || BACKUP_CODE;
    if (!code) {
      throw new Error(
        '2FA is enabled. Provide E2E_TOTP_CODE or E2E_BACKUP_CODE.',
      );
    }
    result = await requestJson('/api/auth/login', {
      method: 'POST',
      body: {
        ...body,
        otp_code: code,
      },
    });
  }

  if (!result.response.ok) {
    throw new Error(
      `login failed: HTTP ${result.response.status} ${JSON.stringify(result.data).slice(0, 600)}`,
    );
  }
  const root = asObject(result.data, 'login.root');
  const token = String(root.token || '').trim();
  if (!token) throw new Error('login did not return access token');
  if (!String(root.refresh_token || '').trim()) {
    throw new Error('login did not return refresh token');
  }
  return root;
}

function assertPersistentAuthPayload(root, context) {
  const token = String(root?.token || '').trim();
  const refreshToken = String(root?.refresh_token || '').trim();
  if (!token || !refreshToken) {
    throw new Error(`${context}: response did not return token pair`);
  }
  if (root.session_expires_at !== null && root.session_expires_at !== undefined) {
    throw new Error(`${context}: session_expires_at must be null for persistent sessions`);
  }
  const decoded = jwt.decode(token);
  if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)) {
    throw new Error(`${context}: access token is not decodable`);
  }
  if (!String(decoded.sid || decoded.session_id || '').trim()) {
    throw new Error(`${context}: access token does not contain session id`);
  }
}

function buildExpiredAccessToken(sourceToken) {
  const decoded = jwt.decode(sourceToken);
  if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)) {
    throw new Error('cannot decode login token');
  }
  const payload = { ...decoded };
  delete payload.exp;
  delete payload.iat;
  delete payload.nbf;
  if (!String(payload.sid || payload.session_id || '').trim()) {
    throw new Error('login token does not contain sid');
  }
  return signJwt(payload, { expiresIn: '1s' });
}

async function run() {
  if (!EMAIL || !PASSWORD) {
    throw new Error('Set E2E_EMAIL and E2E_PASSWORD');
  }

  printStep('AUTH', 'login and create active server session');
  const loginPayload = await login();
  assertPersistentAuthPayload(loginPayload, 'login');

  printStep('CHECK', 'refresh token flow keeps persistent session');
  const refresh = await requestJson('/api/auth/refresh', {
    method: 'POST',
    body: {
      refresh_token: loginPayload.refresh_token,
    },
  });
  if (!refresh.response.ok) {
    throw new Error(
      `refresh failed: HTTP ${refresh.response.status} ${JSON.stringify(refresh.data).slice(0, 700)}`,
    );
  }
  const refreshRoot = asObject(refresh.data, 'refresh.root');
  assertPersistentAuthPayload(refreshRoot, 'refresh');

  printStep('CHECK', 'refreshed access token works for profile');
  const refreshedProfile = await requestJson('/api/profile', {
    token: refreshRoot.token,
  });
  if (!refreshedProfile.response.ok) {
    throw new Error(
      `/api/profile failed after refresh: HTTP ${refreshedProfile.response.status}`,
    );
  }

  const expiredToken = buildExpiredAccessToken(refreshRoot.token);

  printStep('WAIT', 'let synthetic access token expire');
  await new Promise((resolve) => setTimeout(resolve, 1300));

  printStep('CHECK', 'refresh/bootstrap accepts expired signed access token');
  const bootstrap = await requestJson('/api/auth/refresh/bootstrap', {
    method: 'POST',
    token: expiredToken,
  });
  if (!bootstrap.response.ok) {
    throw new Error(
      `refresh/bootstrap failed: HTTP ${bootstrap.response.status} ${JSON.stringify(bootstrap.data).slice(0, 700)}`,
    );
  }
  const root = asObject(bootstrap.data, 'bootstrap.root');
  const nextToken = String(root.token || '').trim();
  const nextRefresh = String(root.refresh_token || '').trim();
  if (!nextToken || !nextRefresh) {
    throw new Error('bootstrap response did not return new token pair');
  }
  assertPersistentAuthPayload(root, 'bootstrap');

  printStep('CHECK', 'new access token works for profile');
  const profile = await requestJson('/api/profile', { token: nextToken });
  if (!profile.response.ok) {
    throw new Error(`/api/profile failed after bootstrap: HTTP ${profile.response.status}`);
  }
  const profileRoot = asObject(profile.data, 'profile.root');
  if (profileRoot.ok !== true || !profileRoot.user) {
    throw new Error('/api/profile after bootstrap returned malformed payload');
  }

  printStep('DONE', 'session bootstrap flow passed');
}

run().catch((err) => {
  console.error('SESSION BOOTSTRAP E2E FAILED:', err?.message || err);
  process.exit(1);
});
