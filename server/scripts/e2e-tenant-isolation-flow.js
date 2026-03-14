#!/usr/bin/env node

/* eslint-disable no-console */

const BASE_URL = String(process.env.E2E_BASE_URL || "http://127.0.0.1:3000")
  .trim()
  .replace(/\/+$/, "");

const REQUIRE_STRICT = ["1", "true", "yes"].includes(
  String(process.env.E2E_REQUIRE_TENANT_ISOLATION || "").trim().toLowerCase(),
);

const USER_A_EMAIL = String(
  process.env.E2E_TENANT_A_EMAIL || process.env.E2E_USER_A_EMAIL || "",
)
  .trim()
  .toLowerCase();
const USER_A_PASSWORD = String(
  process.env.E2E_TENANT_A_PASSWORD || process.env.E2E_USER_A_PASSWORD || "",
).trim();
const USER_A_TENANT_CODE = String(
  process.env.E2E_TENANT_A_CODE || process.env.E2E_TENANT_CODE_A || "",
).trim();

const USER_B_EMAIL = String(
  process.env.E2E_TENANT_B_EMAIL || process.env.E2E_USER_B_EMAIL || "",
)
  .trim()
  .toLowerCase();
const USER_B_PASSWORD = String(
  process.env.E2E_TENANT_B_PASSWORD || process.env.E2E_USER_B_PASSWORD || "",
).trim();
const USER_B_TENANT_CODE = String(
  process.env.E2E_TENANT_B_CODE || process.env.E2E_TENANT_CODE_B || "",
).trim();

const GLOBAL_TOTP_CODE = String(process.env.E2E_TOTP_CODE || "").trim();
const GLOBAL_BACKUP_CODE = String(process.env.E2E_BACKUP_CODE || "").trim();

const USER_A_TOTP_CODE = String(
  process.env.E2E_TENANT_A_TOTP_CODE || GLOBAL_TOTP_CODE || "",
).trim();
const USER_A_BACKUP_CODE = String(
  process.env.E2E_TENANT_A_BACKUP_CODE || GLOBAL_BACKUP_CODE || "",
).trim();

const USER_B_TOTP_CODE = String(
  process.env.E2E_TENANT_B_TOTP_CODE || GLOBAL_TOTP_CODE || "",
).trim();
const USER_B_BACKUP_CODE = String(
  process.env.E2E_TENANT_B_BACKUP_CODE || GLOBAL_BACKUP_CODE || "",
).trim();

const USER_A_DEVICE_FINGERPRINT = String(
  process.env.E2E_TENANT_A_DEVICE_FINGERPRINT || `tenant-a-${process.platform}`,
)
  .trim()
  .slice(0, 180);
const USER_B_DEVICE_FINGERPRINT = String(
  process.env.E2E_TENANT_B_DEVICE_FINGERPRINT || `tenant-b-${process.platform}`,
)
  .trim()
  .slice(0, 180);

function printStep(step, details) {
  const stamp = new Date().toISOString();
  console.log(`[${stamp}] ${step} ${details}`);
}

function normalizeRole(value) {
  return String(value || "")
    .trim()
    .toLowerCase();
}

function asObject(value, context) {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value;
  }
  throw new Error(`${context}: expected object`);
}

function asList(value, context) {
  if (Array.isArray(value)) return value;
  throw new Error(`${context}: expected array`);
}

function normalizedDigits(value) {
  return String(value || "").replace(/\D/g, "");
}

function createHeaders({ token = "", json = true } = {}) {
  const headers = {};
  if (json) headers["Content-Type"] = "application/json";
  if (token) headers.Authorization = `Bearer ${token}`;
  return headers;
}

async function requestJson(path, { method = "GET", token = "", body } = {}) {
  const response = await fetch(`${BASE_URL}${path}`, {
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
  totpCode = "",
  backupCode = "",
}) {
  const body = {
    email,
    password,
    device_fingerprint: deviceFingerprint,
  };
  if (tenantCode) body.tenant_code = tenantCode;

  let { response, data } = await requestJson("/api/auth/login", {
    method: "POST",
    body,
  });

  if (response.status === 401 && (data?.two_factor_required || data?.twoFactorRequired)) {
    const code = String(totpCode || backupCode || "").trim();
    if (!code) {
      throw new Error(
        `2FA required for ${email}. Set E2E_TENANT_*_TOTP_CODE (or backup code).`,
      );
    }

    ({ response, data } = await requestJson("/api/auth/login", {
      method: "POST",
      body: {
        ...body,
        otp_code: code,
      },
    }));
  }

  if (!response.ok) {
    throw new Error(
      `Login failed for ${email}: HTTP ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
    );
  }

  const root = asObject(data, "login.root");
  const token = String(root.token || "").trim();
  if (!token) throw new Error(`login(${email}) -> missing token`);
  const user = asObject(root.user || {}, "login.user");
  return { token, user };
}

async function getProfile(token) {
  const { response, data } = await requestJson("/api/profile", { token });
  if (!response.ok) {
    throw new Error(`/api/profile failed: HTTP ${response.status}`);
  }
  const root = asObject(data, "profile.root");
  return asObject(root.user || root.data || {}, "profile.user");
}

function listContainsForeignUser(items, foreign) {
  const foreignId = String(foreign.id || "").trim();
  const foreignEmail = String(foreign.email || "")
    .trim()
    .toLowerCase();
  const foreignPhone = normalizedDigits(foreign.phone);

  for (const row of items) {
    if (!row || typeof row !== "object") continue;
    const rowId = String(row.id || row.user_id || row.contact_user_id || "").trim();
    const rowEmail = String(row.email || row.user_email || "")
      .trim()
      .toLowerCase();
    const rowPhone = normalizedDigits(
      row.phone || row.user_phone || row.client_phone || "",
    );

    if (foreignId && rowId && rowId === foreignId) return true;
    if (foreignEmail && rowEmail && rowEmail === foreignEmail) return true;
    if (foreignPhone && rowPhone && rowPhone === foreignPhone) return true;
  }
  return false;
}

async function assertNoDirectSearchLeak(source, foreign) {
  const probes = new Set();
  const foreignEmail = String(foreign.email || "").trim();
  const foreignPhone = normalizedDigits(foreign.phone);
  if (foreignEmail) probes.add(foreignEmail);
  if (foreignPhone.length >= 10) probes.add(foreignPhone);

  for (const probe of probes) {
    printStep("CHECK", `${source.label} direct/search probe='${probe}'`);
    const { response, data } = await requestJson(
      `/api/chats/direct/search?query=${encodeURIComponent(probe)}&limit=10`,
      { token: source.token },
    );

    if (!response.ok) {
      throw new Error(
        `${source.label} direct/search failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
      );
    }

    const root = asObject(data, `${source.label}.direct.search.root`);
    const payload = asObject(root.data || {}, `${source.label}.direct.search.data`);
    const candidates = asList(payload.candidates || [], `${source.label}.direct.search.candidates`);
    const exact = payload.exact && typeof payload.exact === "object" ? payload.exact : null;

    const combined = exact ? [exact, ...candidates] : candidates;
    if (listContainsForeignUser(combined, foreign.profile)) {
      throw new Error(
        `${source.label} direct/search leaked user ${foreign.label} across tenants`,
      );
    }
  }
}

async function assertDirectOpenBlocked(source, foreign) {
  const foreignId = String(foreign.profile.id || "").trim();
  const foreignEmail = String(foreign.profile.email || "").trim();

  if (foreignId) {
    printStep("CHECK", `${source.label} direct/open by user_id blocked`);
    const byId = await requestJson("/api/chats/direct/open", {
      method: "POST",
      token: source.token,
      body: { user_id: foreignId },
    });
    if (byId.response.status !== 404) {
      throw new Error(
        `${source.label} direct/open by user_id expected 404, got ${byId.response.status}`,
      );
    }
  }

  if (foreignEmail) {
    printStep("CHECK", `${source.label} direct/open by query blocked`);
    const byQuery = await requestJson("/api/chats/direct/open", {
      method: "POST",
      token: source.token,
      body: { query: foreignEmail },
    });
    if (byQuery.response.status !== 404) {
      throw new Error(
        `${source.label} direct/open by query expected 404, got ${byQuery.response.status}`,
      );
    }
  }
}

async function assertNoTenantClientsLeak(source, foreign) {
  const probe = normalizedDigits(foreign.profile.phone).slice(-4);
  if (probe.length < 4) return;

  printStep("CHECK", `${source.label} tenant clients search probe='${probe}'`);
  const { response, data } = await requestJson(
    `/api/profile/tenant/clients/search?query=${encodeURIComponent(probe)}`,
    { token: source.token },
  );

  if (response.status === 403 || response.status === 404) {
    printStep("SKIP", `${source.label} tenant clients search not available for this role`);
    return;
  }

  if (!response.ok) {
    throw new Error(
      `${source.label} tenant clients search failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
    );
  }

  const root = asObject(data, `${source.label}.tenant.clients.root`);
  const rows = asList(root.data || [], `${source.label}.tenant.clients.data`);
  if (listContainsForeignUser(rows, foreign.profile)) {
    throw new Error(
      `${source.label} tenant clients search leaked ${foreign.label} across tenants`,
    );
  }
}

async function run() {
  const missing = [];
  if (!USER_A_EMAIL) missing.push("E2E_TENANT_A_EMAIL");
  if (!USER_A_PASSWORD) missing.push("E2E_TENANT_A_PASSWORD");
  if (!USER_B_EMAIL) missing.push("E2E_TENANT_B_EMAIL");
  if (!USER_B_PASSWORD) missing.push("E2E_TENANT_B_PASSWORD");

  if (missing.length > 0) {
    const msg = `Missing env for tenant isolation test: ${missing.join(", ")}`;
    if (REQUIRE_STRICT) {
      throw new Error(msg);
    }
    printStep("SKIP", msg);
    return;
  }

  printStep("AUTH", "tenant A login");
  const userA = await login({
    email: USER_A_EMAIL,
    password: USER_A_PASSWORD,
    tenantCode: USER_A_TENANT_CODE,
    deviceFingerprint: USER_A_DEVICE_FINGERPRINT,
    totpCode: USER_A_TOTP_CODE,
    backupCode: USER_A_BACKUP_CODE,
  });

  printStep("AUTH", "tenant B login");
  const userB = await login({
    email: USER_B_EMAIL,
    password: USER_B_PASSWORD,
    tenantCode: USER_B_TENANT_CODE,
    deviceFingerprint: USER_B_DEVICE_FINGERPRINT,
    totpCode: USER_B_TOTP_CODE,
    backupCode: USER_B_BACKUP_CODE,
  });

  printStep("CHECK", "load profiles");
  const profileA = await getProfile(userA.token);
  const profileB = await getProfile(userB.token);

  const tenantA = String(profileA.tenant_id || userA.user.tenant_id || "").trim();
  const tenantB = String(profileB.tenant_id || userB.user.tenant_id || "").trim();
  if (!tenantA || !tenantB) {
    throw new Error("tenant_id missing in one of profiles");
  }
  if (tenantA === tenantB) {
    throw new Error(
      `Both users are in same tenant (${tenantA}). Provide accounts from different tenants.`,
    );
  }

  const sideA = {
    label: `A(${normalizeRole(profileA.role || profileA.base_role) || "user"})`,
    token: userA.token,
    profile: profileA,
  };
  const sideB = {
    label: `B(${normalizeRole(profileB.role || profileB.base_role) || "user"})`,
    token: userB.token,
    profile: profileB,
  };

  await assertNoDirectSearchLeak(sideA, sideB);
  await assertDirectOpenBlocked(sideA, sideB);
  await assertNoTenantClientsLeak(sideA, sideB);

  await assertNoDirectSearchLeak(sideB, sideA);
  await assertDirectOpenBlocked(sideB, sideA);
  await assertNoTenantClientsLeak(sideB, sideA);

  printStep("SUCCESS", "tenant isolation flow passed");
}

run().catch((err) => {
  console.error("TENANT ISOLATION E2E FAILED:", err?.message || err);
  process.exit(1);
});
