#!/usr/bin/env node

/* eslint-disable no-console */

const fs = require('fs');
const path = require('path');

const BASE_URL = String(process.env.E2E_BASE_URL || 'http://127.0.0.1:3000')
  .trim()
  .replace(/\/+$/, '');

const USER_A_EMAIL = String(process.env.E2E_TENANT_A_EMAIL || '').trim().toLowerCase();
const USER_A_PASSWORD = String(process.env.E2E_TENANT_A_PASSWORD || '').trim();
const USER_A_TENANT_CODE = String(process.env.E2E_TENANT_A_CODE || '').trim();
const USER_A_TOTP_CODE = String(
  process.env.E2E_TENANT_A_TOTP_CODE || process.env.E2E_TOTP_CODE || '',
).trim();
const USER_A_BACKUP_CODE = String(
  process.env.E2E_TENANT_A_BACKUP_CODE || process.env.E2E_BACKUP_CODE || '',
).trim();

const USER_B_EMAIL = String(process.env.E2E_TENANT_B_EMAIL || '').trim().toLowerCase();
const USER_B_PASSWORD = String(process.env.E2E_TENANT_B_PASSWORD || '').trim();
const USER_B_TENANT_CODE = String(process.env.E2E_TENANT_B_CODE || '').trim();
const USER_B_TOTP_CODE = String(
  process.env.E2E_TENANT_B_TOTP_CODE || process.env.E2E_TOTP_CODE || '',
).trim();
const USER_B_BACKUP_CODE = String(
  process.env.E2E_TENANT_B_BACKUP_CODE || process.env.E2E_BACKUP_CODE || '',
).trim();

const USER_A_DEVICE_FINGERPRINT = String(
  process.env.E2E_TENANT_A_DEVICE_FINGERPRINT || `tenant-reg-a-${process.platform}`,
)
  .trim()
  .slice(0, 180);
const USER_B_DEVICE_FINGERPRINT = String(
  process.env.E2E_TENANT_B_DEVICE_FINGERPRINT || `tenant-reg-b-${process.platform}`,
)
  .trim()
  .slice(0, 180);

const REQUIRE_STRICT = ['1', 'true', 'yes'].includes(
  String(process.env.E2E_REQUIRE_TENANT_REGRESSION || '').trim().toLowerCase(),
);
const REQUIRE_FULL = ['1', 'true', 'yes'].includes(
  String(process.env.E2E_TENANT_ISOLATION_REQUIRE_FULL || '').trim().toLowerCase(),
);

const OUTPUT_PATH = path.resolve(
  process.cwd(),
  process.env.E2E_TENANT_REGRESSION_REPORT_PATH || 'audit/tenant-isolation-regression.md',
);

const results = [];

function printStep(step, details) {
  const stamp = new Date().toISOString();
  console.log(`[${stamp}] ${step} ${details}`);
}

function record(status, id, title, details = '') {
  const normalizedStatus = String(status || 'fail').toLowerCase().trim();
  const entry = {
    status: normalizedStatus,
    id: String(id || '').trim(),
    title: String(title || '').trim(),
    details: String(details || '').trim(),
  };
  results.push(entry);

  const prefix =
    normalizedStatus === 'pass'
      ? 'PASS'
      : normalizedStatus === 'skip'
        ? 'SKIP'
        : 'FAIL';
  const suffix = entry.details ? ` — ${entry.details}` : '';
  printStep(prefix, `${entry.id} ${entry.title}${suffix}`.trim());
}

function asObject(value, context) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return value;
  }
  throw new Error(`${context}: expected object`);
}

function asList(value, context) {
  if (Array.isArray(value)) return value;
  throw new Error(`${context}: expected array`);
}

function normalizeDigits(value) {
  return String(value || '').replace(/\D/g, '');
}

function createHeaders({ token = '', json = true } = {}) {
  const headers = {};
  if (json) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = `Bearer ${token}`;
  return headers;
}

async function requestJson(pathname, { method = 'GET', token = '', body } = {}) {
  const response = await fetch(`${BASE_URL}${pathname}`, {
    method,
    headers: createHeaders({ token, json: true }),
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

async function login({
  email,
  password,
  tenantCode,
  deviceFingerprint,
  totpCode = '',
  backupCode = '',
}) {
  const body = {
    email,
    password,
    device_fingerprint: deviceFingerprint,
  };
  if (tenantCode) body.tenant_code = tenantCode;

  let { response, data } = await requestJson('/api/auth/login', {
    method: 'POST',
    body,
  });

  if (response.status === 401 && (data?.two_factor_required || data?.twoFactorRequired)) {
    const code = String(totpCode || backupCode || '').trim();
    if (!code) {
      throw new Error(`2FA required for ${email}`);
    }
    ({ response, data } = await requestJson('/api/auth/login', {
      method: 'POST',
      body: {
        ...body,
        otp_code: code,
      },
    }));
  }

  if (!response.ok) {
    throw new Error(
      `login failed for ${email}: HTTP ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
    );
  }

  const root = asObject(data, `login(${email})`);
  const token = String(root.token || '').trim();
  if (!token) throw new Error(`login(${email}): missing token`);
  const user = asObject(root.user || {}, `login(${email}).user`);
  return { token, user };
}

async function getProfile(token, label) {
  const { response, data } = await requestJson('/api/profile', { token });
  if (!response.ok) {
    throw new Error(`${label} /api/profile failed: HTTP ${response.status}`);
  }
  const root = asObject(data, `${label}.profile.root`);
  return asObject(root.user || root.data || {}, `${label}.profile.user`);
}

function foreignIdentity(profile) {
  return {
    id: String(profile?.id || '').trim(),
    email: String(profile?.email || '').trim().toLowerCase(),
    phone: normalizeDigits(profile?.phone || ''),
  };
}

function objectLeaksIdentity(row, identity) {
  if (!row || typeof row !== 'object') return false;

  const idKeys = [
    'id',
    'user_id',
    'contact_user_id',
    'peer_id',
    'client_id',
    'sender_id',
    'owner_user_id',
    'requester_user_id',
    'created_by',
    'processed_by_id',
  ];

  const emailKeys = [
    'email',
    'user_email',
    'peer_email',
    'client_email',
    'requester_email',
  ];

  const phoneKeys = [
    'phone',
    'user_phone',
    'peer_phone',
    'client_phone',
  ];

  for (const key of idKeys) {
    const value = String(row[key] || '').trim();
    if (identity.id && value && value === identity.id) {
      return true;
    }
  }

  for (const key of emailKeys) {
    const value = String(row[key] || '').trim().toLowerCase();
    if (identity.email && value && value === identity.email) {
      return true;
    }
  }

  for (const key of phoneKeys) {
    const value = normalizeDigits(row[key] || '');
    if (identity.phone && value && value === identity.phone) {
      return true;
    }
  }

  return false;
}

function payloadLeaksIdentity(payload, identity) {
  const queue = [payload];
  while (queue.length > 0) {
    const current = queue.shift();
    if (current == null) continue;

    if (Array.isArray(current)) {
      for (const item of current) queue.push(item);
      continue;
    }

    if (typeof current !== 'object') continue;
    if (objectLeaksIdentity(current, identity)) {
      return true;
    }

    for (const value of Object.values(current)) {
      if (value && typeof value === 'object') {
        queue.push(value);
      }
    }
  }
  return false;
}

async function checkDirectSearch(source, foreign) {
  const probes = [];
  if (foreign.identity.email) probes.push(foreign.identity.email);
  if (foreign.identity.phone.length >= 10) probes.push(foreign.identity.phone);

  if (probes.length === 0) {
    record('skip', `${source.id}.direct_search`, 'direct search by email/phone', 'foreign probes are empty');
    return;
  }

  for (const probe of probes) {
    const checkId = `${source.id}.direct_search.${probe.includes('@') ? 'email' : 'phone'}`;
    const title = `direct search (${source.label} -> ${foreign.label})`;
    try {
      const { response, data } = await requestJson(
        `/api/chats/direct/search?query=${encodeURIComponent(probe)}&limit=10`,
        { token: source.token },
      );
      if (!response.ok) {
        record('fail', checkId, title, `HTTP ${response.status}`);
        continue;
      }

      const root = asObject(data, `${checkId}.root`);
      const payload = asObject(root.data || {}, `${checkId}.data`);
      const candidates = asList(payload.candidates || [], `${checkId}.candidates`);
      const exact = payload.exact && typeof payload.exact === 'object' ? payload.exact : null;
      const combined = exact ? [exact, ...candidates] : candidates;
      const leaked = payloadLeaksIdentity(combined, foreign.identity);
      if (leaked) {
        record('fail', checkId, title, 'foreign user leaked in direct search results');
      } else {
        record('pass', checkId, title);
      }
    } catch (err) {
      record('fail', checkId, title, String(err?.message || err));
    }
  }
}

async function checkDirectOpen(source, foreign) {
  const title = `direct open blocked (${source.label} -> ${foreign.label})`;

  if (foreign.identity.id) {
    const idCheck = `${source.id}.direct_open.user_id`;
    try {
      const { response } = await requestJson('/api/chats/direct/open', {
        method: 'POST',
        token: source.token,
        body: { user_id: foreign.identity.id },
      });
      if (response.status === 404) {
        record('pass', idCheck, title);
      } else {
        record('fail', idCheck, title, `expected 404, got ${response.status}`);
      }
    } catch (err) {
      record('fail', idCheck, title, String(err?.message || err));
    }
  }

  if (foreign.identity.email) {
    const emailCheck = `${source.id}.direct_open.query`;
    try {
      const { response } = await requestJson('/api/chats/direct/open', {
        method: 'POST',
        token: source.token,
        body: { query: foreign.identity.email },
      });
      if (response.status === 404) {
        record('pass', emailCheck, title);
      } else {
        record('fail', emailCheck, title, `expected 404, got ${response.status}`);
      }
    } catch (err) {
      record('fail', emailCheck, title, String(err?.message || err));
    }
  }
}

async function checkTenantClientsSearch(source, foreign) {
  const checkId = `${source.id}.tenant_clients.search`;
  const title = `tenant clients search isolation (${source.label} -> ${foreign.label})`;
  const probe = foreign.identity.phone.slice(-4);
  if (probe.length < 4) {
    record('skip', checkId, title, 'foreign phone probe is too short');
    return;
  }

  try {
    const { response, data } = await requestJson(
      `/api/profile/tenant/clients/search?query=${encodeURIComponent(probe)}`,
      { token: source.token },
    );

    if (response.status === 403 || response.status === 404) {
      record('skip', checkId, title, `endpoint unavailable for role (${response.status})`);
      return;
    }

    if (!response.ok) {
      record('fail', checkId, title, `HTTP ${response.status}`);
      return;
    }

    const root = asObject(data, `${checkId}.root`);
    const rows = asList(root.data || [], `${checkId}.data`);
    if (payloadLeaksIdentity(rows, foreign.identity)) {
      record('fail', checkId, title, 'foreign user leaked in tenant clients search');
    } else {
      record('pass', checkId, title);
    }
  } catch (err) {
    record('fail', checkId, title, String(err?.message || err));
  }
}

async function checkChatsList(source, foreign) {
  const checkId = `${source.id}.chats.list`;
  const title = `chats list isolation (${source.label} -> ${foreign.label})`;

  try {
    const { response, data } = await requestJson('/api/chats', { token: source.token });
    if (!response.ok) {
      record('fail', checkId, title, `HTTP ${response.status}`);
      return;
    }

    const root = asObject(data, `${checkId}.root`);
    const rows = asList(root.data || root.chats || [], `${checkId}.rows`);
    if (payloadLeaksIdentity(rows, foreign.identity)) {
      record('fail', checkId, title, 'foreign identity found in chats payload');
    } else {
      record('pass', checkId, title);
    }
  } catch (err) {
    record('fail', checkId, title, String(err?.message || err));
  }
}

async function checkCart(source, foreign) {
  const checkId = `${source.id}.cart.scope`;
  const title = `cart scope isolation (${source.label} -> ${foreign.label})`;

  try {
    const { response, data } = await requestJson('/api/cart', { token: source.token });
    if (!response.ok) {
      record('fail', checkId, title, `HTTP ${response.status}`);
      return;
    }

    const root = asObject(data, `${checkId}.root`);
    if (payloadLeaksIdentity(root, foreign.identity)) {
      record('fail', checkId, title, 'foreign identity found in cart payload');
    } else {
      record('pass', checkId, title);
    }
  } catch (err) {
    record('fail', checkId, title, String(err?.message || err));
  }
}

async function checkSupportTickets(source, foreign) {
  const checkId = `${source.id}.support.tickets`;
  const title = `support tickets isolation (${source.label} -> ${foreign.label})`;

  try {
    const { response, data } = await requestJson('/api/support/tickets', {
      token: source.token,
    });

    if (response.status === 403 || response.status === 404) {
      record('skip', checkId, title, `endpoint unavailable for role (${response.status})`);
      return;
    }

    if (!response.ok) {
      record('fail', checkId, title, `HTTP ${response.status}`);
      return;
    }

    const root = asObject(data, `${checkId}.root`);
    if (payloadLeaksIdentity(root, foreign.identity)) {
      record('fail', checkId, title, 'foreign identity found in support tickets payload');
    } else {
      record('pass', checkId, title);
    }
  } catch (err) {
    record('fail', checkId, title, String(err?.message || err));
  }
}

async function checkAdminPending(source, foreign) {
  const checkId = `${source.id}.admin.pending_posts`;
  const title = `admin pending posts isolation (${source.label} -> ${foreign.label})`;

  try {
    const { response, data } = await requestJson('/api/admin/channels/pending_posts', {
      token: source.token,
    });

    if (response.status === 403 || response.status === 404) {
      record('skip', checkId, title, `endpoint unavailable for role (${response.status})`);
      return;
    }

    if (!response.ok) {
      record('fail', checkId, title, `HTTP ${response.status}`);
      return;
    }

    const root = asObject(data, `${checkId}.root`);
    const rows = asList(root.data || [], `${checkId}.rows`);
    if (payloadLeaksIdentity(rows, foreign.identity)) {
      record('fail', checkId, title, 'foreign identity found in pending posts payload');
    } else {
      record('pass', checkId, title);
    }
  } catch (err) {
    record('fail', checkId, title, String(err?.message || err));
  }
}

function buildReport(meta) {
  const pass = results.filter((r) => r.status === 'pass').length;
  const fail = results.filter((r) => r.status === 'fail').length;
  const skip = results.filter((r) => r.status === 'skip').length;

  const lines = [];
  lines.push('# Tenant Isolation Regression Report');
  lines.push('');
  lines.push(`- Generated at: ${new Date().toISOString()}`);
  lines.push(`- Base URL: ${BASE_URL}`);
  lines.push(`- Tenant A: ${meta.tenantA}`);
  lines.push(`- Tenant B: ${meta.tenantB}`);
  lines.push(`- Summary: pass=${pass}, fail=${fail}, skip=${skip}`);
  lines.push('');
  lines.push('## Results');
  lines.push('');
  for (const item of results) {
    const icon = item.status === 'pass' ? 'PASS' : item.status === 'skip' ? 'SKIP' : 'FAIL';
    lines.push(`- [${icon}] ${item.id} — ${item.title}${item.details ? ` (${item.details})` : ''}`);
  }
  lines.push('');
  return lines.join('\n');
}

function persistReport(content) {
  fs.mkdirSync(path.dirname(OUTPUT_PATH), { recursive: true });
  fs.writeFileSync(OUTPUT_PATH, content, 'utf8');
  printStep('REPORT', OUTPUT_PATH);
}

async function run() {
  if (!USER_A_EMAIL || !USER_A_PASSWORD || !USER_B_EMAIL || !USER_B_PASSWORD) {
    const msg =
      'Missing env: E2E_TENANT_A_EMAIL/E2E_TENANT_A_PASSWORD/E2E_TENANT_B_EMAIL/E2E_TENANT_B_PASSWORD';
    if (REQUIRE_STRICT) {
      throw new Error(msg);
    }
    record('skip', 'setup.credentials', 'tenant regression setup', msg);
    persistReport(buildReport({ tenantA: 'unknown', tenantB: 'unknown' }));
    return;
  }

  const sideA = { id: 'A', label: USER_A_EMAIL };
  const sideB = { id: 'B', label: USER_B_EMAIL };

  printStep('AUTH', 'login tenant A');
  const loginA = await login({
    email: USER_A_EMAIL,
    password: USER_A_PASSWORD,
    tenantCode: USER_A_TENANT_CODE,
    deviceFingerprint: USER_A_DEVICE_FINGERPRINT,
    totpCode: USER_A_TOTP_CODE,
    backupCode: USER_A_BACKUP_CODE,
  });

  printStep('AUTH', 'login tenant B');
  const loginB = await login({
    email: USER_B_EMAIL,
    password: USER_B_PASSWORD,
    tenantCode: USER_B_TENANT_CODE,
    deviceFingerprint: USER_B_DEVICE_FINGERPRINT,
    totpCode: USER_B_TOTP_CODE,
    backupCode: USER_B_BACKUP_CODE,
  });

  printStep('CHECK', 'profiles + tenant ids');
  const profileA = await getProfile(loginA.token, sideA.id);
  const profileB = await getProfile(loginB.token, sideB.id);

  const tenantA = String(profileA.tenant_id || loginA.user.tenant_id || '').trim();
  const tenantB = String(profileB.tenant_id || loginB.user.tenant_id || '').trim();
  if (!tenantA || !tenantB) {
    throw new Error('tenant_id missing in one of profiles');
  }
  if (tenantA === tenantB) {
    throw new Error(`same tenant detected (${tenantA}); regression requires two different tenants`);
  }

  const a = {
    ...sideA,
    token: loginA.token,
    profile: profileA,
    identity: foreignIdentity(profileA),
  };
  const b = {
    ...sideB,
    token: loginB.token,
    profile: profileB,
    identity: foreignIdentity(profileB),
  };

  await checkDirectSearch(a, b);
  await checkDirectOpen(a, b);
  await checkTenantClientsSearch(a, b);
  await checkChatsList(a, b);
  await checkCart(a, b);
  await checkSupportTickets(a, b);
  await checkAdminPending(a, b);

  await checkDirectSearch(b, a);
  await checkDirectOpen(b, a);
  await checkTenantClientsSearch(b, a);
  await checkChatsList(b, a);
  await checkCart(b, a);
  await checkSupportTickets(b, a);
  await checkAdminPending(b, a);

  const report = buildReport({ tenantA, tenantB });
  persistReport(report);

  const fails = results.filter((r) => r.status === 'fail').length;
  const skips = results.filter((r) => r.status === 'skip').length;
  if (fails > 0) {
    throw new Error(`tenant isolation regression failed: ${fails} check(s)`);
  }
  if (REQUIRE_FULL && skips > 0) {
    throw new Error(`tenant isolation regression has ${skips} skipped check(s) in full mode`);
  }

  printStep('SUCCESS', 'tenant isolation regression passed');
}

run().catch((err) => {
  try {
    const partial = buildReport({ tenantA: 'unknown', tenantB: 'unknown' });
    persistReport(partial);
  } catch (_) {
    // ignore report-write errors on top-level failure.
  }
  console.error('TENANT ISOLATION REGRESSION FAILED:', err?.message || err);
  process.exit(1);
});
