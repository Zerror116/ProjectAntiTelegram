#!/usr/bin/env node

/* eslint-disable no-console */

const BASE_URL = String(process.env.E2E_BASE_URL || "http://127.0.0.1:3000")
  .trim()
  .replace(/\/+$/, "");

const CREATOR_EMAIL = String(
  process.env.E2E_CREATOR_EMAIL || process.env.E2E_EMAIL || "",
)
  .trim()
  .toLowerCase();
const CREATOR_PASSWORD = String(
  process.env.E2E_CREATOR_PASSWORD || process.env.E2E_PASSWORD || "",
).trim();

const STAFF_EMAIL = String(process.env.E2E_STAFF_EMAIL || "")
  .trim()
  .toLowerCase();
const STAFF_PASSWORD = String(process.env.E2E_STAFF_PASSWORD || "").trim();

const CLIENT_EMAIL = String(process.env.E2E_CLIENT_EMAIL || "")
  .trim()
  .toLowerCase();
const CLIENT_PASSWORD = String(process.env.E2E_CLIENT_PASSWORD || "").trim();

const TENANT_CODE = String(process.env.E2E_TENANT_CODE || "").trim();

const GLOBAL_TOTP_CODE = String(process.env.E2E_TOTP_CODE || "").trim();
const GLOBAL_BACKUP_CODE = String(process.env.E2E_BACKUP_CODE || "").trim();

const CREATOR_TOTP_CODE = String(
  process.env.E2E_CREATOR_TOTP_CODE || GLOBAL_TOTP_CODE || "",
).trim();
const CREATOR_BACKUP_CODE = String(
  process.env.E2E_CREATOR_BACKUP_CODE || GLOBAL_BACKUP_CODE || "",
).trim();

const STAFF_TOTP_CODE = String(
  process.env.E2E_STAFF_TOTP_CODE || GLOBAL_TOTP_CODE || "",
).trim();
const STAFF_BACKUP_CODE = String(
  process.env.E2E_STAFF_BACKUP_CODE || GLOBAL_BACKUP_CODE || "",
).trim();

const CLIENT_TOTP_CODE = String(
  process.env.E2E_CLIENT_TOTP_CODE || GLOBAL_TOTP_CODE || "",
).trim();
const CLIENT_BACKUP_CODE = String(
  process.env.E2E_CLIENT_BACKUP_CODE || GLOBAL_BACKUP_CODE || "",
).trim();

const CREATOR_DEVICE_FINGERPRINT = String(
  process.env.E2E_CREATOR_DEVICE_FINGERPRINT || `sub-guard-creator-${process.platform}`,
)
  .trim()
  .slice(0, 180);
const STAFF_DEVICE_FINGERPRINT = String(
  process.env.E2E_STAFF_DEVICE_FINGERPRINT || `sub-guard-staff-${process.platform}`,
)
  .trim()
  .slice(0, 180);
const CLIENT_DEVICE_FINGERPRINT = String(
  process.env.E2E_CLIENT_DEVICE_FINGERPRINT || `sub-guard-client-${process.platform}`,
)
  .trim()
  .slice(0, 180);

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

function normalizeRole(value) {
  return String(value || "")
    .toLowerCase()
    .trim();
}

function printStep(step, details) {
  const stamp = new Date().toISOString();
  console.log(`[${stamp}] ${step} ${details}`);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function login({
  email,
  password,
  deviceFingerprint,
  totpCode = "",
  backupCode = "",
}) {
  const body = {
    email,
    password,
    device_fingerprint: deviceFingerprint,
  };
  if (TENANT_CODE) body.tenant_code = TENANT_CODE;

  let { response, data } = await requestJson("/api/auth/login", {
    method: "POST",
    body,
  });

  if (response.status === 401 && (data?.two_factor_required || data?.twoFactorRequired)) {
    const code = String(totpCode || backupCode || "").trim();
    if (!code) {
      throw new Error(
        `2FA required for ${email}. Set TOTP/BACKUP env vars for this account.`,
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
  const payload = asObject(data, "login");
  const token = String(payload.token || "").trim();
  if (!token) throw new Error(`login(${email}) -> token missing`);
  const user = asObject(payload.user || {}, "login.user");
  return { token, user };
}

async function getProfile(token) {
  const { response, data } = await requestJson("/api/profile", { token });
  if (!response.ok) {
    throw new Error(`/api/profile failed: HTTP ${response.status}`);
  }
  const root = asObject(data, "profile.root");
  const user = asObject(root.user || root.data || {}, "profile.user");
  return user;
}

async function fetchTenantById(creatorToken, tenantId) {
  const { response, data } = await requestJson("/api/admin/tenants", {
    token: creatorToken,
  });
  if (!response.ok) {
    throw new Error(`/api/admin/tenants failed: HTTP ${response.status}`);
  }
  const root = asObject(data, "admin.tenants.root");
  const rows = asList(root.data || root.rows || [], "admin.tenants.data");
  return rows.find((row) => String(row?.id || "").trim() === tenantId) || null;
}

async function patchTenantStatus(creatorToken, tenantId, status) {
  const { response, data } = await requestJson(
    `/api/admin/tenants/${encodeURIComponent(tenantId)}/status`,
    {
      method: "PATCH",
      token: creatorToken,
      body: { status },
    },
  );
  if (!response.ok) {
    throw new Error(
      `PATCH /api/admin/tenants/${tenantId}/status (${status}) failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
    );
  }
  const root = asObject(data, "tenant.status.update");
  return asObject(root.data || {}, "tenant.status.update.data");
}

async function assertStaffBlocked(staffToken) {
  const { response, data } = await requestJson("/api/chats", { token: staffToken });
  if (![402, 403].includes(response.status)) {
    throw new Error(
      `Expected staff restriction HTTP 402/403, got ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
    );
  }
  const code = String(data?.code || "")
    .toLowerCase()
    .trim();
  if (code && code !== "tenant_blocked" && code !== "tenant_expired") {
    throw new Error(`Unexpected restriction code for staff: ${code}`);
  }
}

async function assertClientStillWorks(clientToken) {
  const chats = await requestJson("/api/chats", { token: clientToken });
  if (!chats.response.ok) {
    throw new Error(
      `Client /api/chats should remain available, got HTTP ${chats.response.status} ${JSON.stringify(chats.data).slice(0, 500)}`,
    );
  }

  const cart = await requestJson("/api/cart", { token: clientToken });
  if (!cart.response.ok) {
    throw new Error(
      `Client /api/cart should remain available, got HTTP ${cart.response.status} ${JSON.stringify(cart.data).slice(0, 500)}`,
    );
  }
  const root = asObject(cart.data, "client.cart.root");
  if (root.ok !== true) {
    throw new Error("Client /api/cart response does not contain ok=true");
  }
}

async function assertStaffRecovered(staffToken) {
  const { response, data } = await requestJson("/api/chats", { token: staffToken });
  if (response.status === 402 || response.status === 403) {
    throw new Error(
      `Staff is still restricted after restore: HTTP ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
    );
  }
  if (!response.ok) {
    throw new Error(
      `Staff /api/chats after restore failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
    );
  }
}

async function run() {
  if (!CREATOR_EMAIL || !CREATOR_PASSWORD) {
    throw new Error(
      "Set E2E_CREATOR_EMAIL/E2E_CREATOR_PASSWORD (or fallback E2E_EMAIL/E2E_PASSWORD)",
    );
  }
  if (!STAFF_EMAIL || !STAFF_PASSWORD) {
    throw new Error("Set E2E_STAFF_EMAIL and E2E_STAFF_PASSWORD");
  }
  if (!CLIENT_EMAIL || !CLIENT_PASSWORD) {
    throw new Error("Set E2E_CLIENT_EMAIL and E2E_CLIENT_PASSWORD");
  }

  printStep("AUTH", "creator login");
  const creator = await login({
    email: CREATOR_EMAIL,
    password: CREATOR_PASSWORD,
    deviceFingerprint: CREATOR_DEVICE_FINGERPRINT,
    totpCode: CREATOR_TOTP_CODE,
    backupCode: CREATOR_BACKUP_CODE,
  });

  printStep("AUTH", "staff login");
  const staff = await login({
    email: STAFF_EMAIL,
    password: STAFF_PASSWORD,
    deviceFingerprint: STAFF_DEVICE_FINGERPRINT,
    totpCode: STAFF_TOTP_CODE,
    backupCode: STAFF_BACKUP_CODE,
  });

  printStep("AUTH", "client login");
  const client = await login({
    email: CLIENT_EMAIL,
    password: CLIENT_PASSWORD,
    deviceFingerprint: CLIENT_DEVICE_FINGERPRINT,
    totpCode: CLIENT_TOTP_CODE,
    backupCode: CLIENT_BACKUP_CODE,
  });

  const creatorRole = normalizeRole(creator.user.base_role || creator.user.role);
  if (creatorRole !== "creator") {
    throw new Error(`Creator account role mismatch: expected creator, got ${creatorRole || "empty"}`);
  }

  const staffRole = normalizeRole(staff.user.base_role || staff.user.role);
  if (!new Set(["tenant", "admin", "worker"]).has(staffRole)) {
    throw new Error(
      `Staff account role mismatch: expected tenant/admin/worker, got ${staffRole || "empty"}`,
    );
  }

  const clientRole = normalizeRole(client.user.base_role || client.user.role);
  if (clientRole !== "client") {
    throw new Error(`Client account role mismatch: expected client, got ${clientRole || "empty"}`);
  }

  printStep("CHECK", "staff profile and tenant");
  const staffProfile = await getProfile(staff.token);
  const tenantId = String(staffProfile.tenant_id || staff.user.tenant_id || "").trim();
  if (!tenantId) {
    throw new Error("Staff account has no tenant_id");
  }

  const clientTenantId = String(
    client.user.tenant_id || client?.user?.tenantId || "",
  ).trim();
  if (clientTenantId && clientTenantId !== tenantId) {
    throw new Error("Client and staff must be in the same tenant for this test");
  }

  printStep("CHECK", "creator tenant access");
  const tenant = await fetchTenantById(creator.token, tenantId);
  if (!tenant) {
    throw new Error(`Creator cannot see tenant ${tenantId}`);
  }
  const tenantCode = String(tenant.code || "")
    .toLowerCase()
    .trim();
  if (tenantCode === "default") {
    printStep(
      "SKIP",
      "subscription-guard flow skipped: default tenant cannot be blocked by design",
    );
    return;
  }

  const previousStatus = normalizeRole(tenant.status || "active") || "active";
  let switchedToBlocked = false;

  try {
    if (previousStatus !== "blocked") {
      printStep("ACTION", "set tenant status=blocked");
      await patchTenantStatus(creator.token, tenantId, "blocked");
      switchedToBlocked = true;
      await sleep(300);
    } else {
      printStep("INFO", "tenant was already blocked before test");
    }

    printStep("CHECK", "staff gets subscription restriction");
    await assertStaffBlocked(staff.token);

    printStep("CHECK", "client remains functional");
    await assertClientStillWorks(client.token);
  } finally {
    if (switchedToBlocked) {
      printStep("RESTORE", `restore tenant status=${previousStatus}`);
      await patchTenantStatus(creator.token, tenantId, previousStatus);
      await sleep(300);
      await assertStaffRecovered(staff.token);
    } else {
      printStep("RESTORE", "no restore required");
    }
  }

  printStep("SUCCESS", "subscription guard flow passed");
}

run().catch((err) => {
  console.error("SUBSCRIPTION GUARD E2E FAILED:", err?.message || err);
  process.exit(1);
});

