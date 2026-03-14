#!/usr/bin/env node

/* eslint-disable no-console */

const crypto = require("crypto");

const BASE_URL = String(process.env.E2E_BASE_URL || "http://127.0.0.1:3000")
  .trim()
  .replace(/\/+$/, "");
const OWNER_EMAIL = String(
  process.env.E2E_OWNER_EMAIL || process.env.E2E_EMAIL || "",
)
  .trim()
  .toLowerCase();
const OWNER_PASSWORD = String(
  process.env.E2E_OWNER_PASSWORD || process.env.E2E_PASSWORD || "",
).trim();
const DUP_INVITE_CODE = String(
  process.env.E2E_DUP_INVITE_CODE || process.env.E2E_INVITE_CODE || "",
)
  .trim()
  .toUpperCase();
const TENANT_CODE = String(process.env.E2E_TENANT_CODE || "").trim();
const VIEW_ROLE = String(process.env.E2E_VIEW_ROLE || "").trim();
const OWNER_DEVICE_FINGERPRINT = String(
  process.env.E2E_OWNER_DEVICE_FINGERPRINT || `phone-owner-${process.platform}`,
)
  .trim()
  .slice(0, 180);
const DUP_DEVICE_FINGERPRINT = String(
  process.env.E2E_DUP_DEVICE_FINGERPRINT ||
    `phone-dup-${process.platform}-${Date.now()}`,
)
  .trim()
  .slice(0, 180);

function randomToken(size = 6) {
  return crypto.randomBytes(size).toString("hex");
}

function createHeaders({ token = "", json = true } = {}) {
  const headers = {};
  if (json) headers["Content-Type"] = "application/json";
  if (token) headers.Authorization = `Bearer ${token}`;
  if (VIEW_ROLE) headers["X-View-Role"] = VIEW_ROLE;
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

function printStep(step, details) {
  const stamp = new Date().toISOString();
  console.log(`[${stamp}] ${step} ${details}`);
}

async function login({ email, password, deviceFingerprint }) {
  const body = {
    email,
    password,
    device_fingerprint: deviceFingerprint,
  };
  if (TENANT_CODE) body.tenant_code = TENANT_CODE;
  if (VIEW_ROLE) body.view_role = VIEW_ROLE;
  const { response, data } = await requestJson("/api/auth/login", {
    method: "POST",
    body,
  });
  if (!response.ok) {
    throw new Error(
      `Login failed for ${email}: HTTP ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
    );
  }
  const payload = asObject(data, "login");
  const token = String(payload.token || "").trim();
  if (!token) throw new Error(`login(${email}) -> token missing`);
  return { token, user: asObject(payload.user || {}, "login.user"), payload };
}

async function getOwnerPhone(ownerToken) {
  const { response, data } = await requestJson("/api/profile", {
    token: ownerToken,
  });
  if (!response.ok) {
    throw new Error(`/api/profile failed: HTTP ${response.status}`);
  }
  const root = asObject(data, "profile.root");
  const user = asObject(root.user || {}, "profile.user");
  const phone = String(user.phone || "").replace(/\D/g, "");
  if (phone.length < 10) {
    throw new Error(
      "Owner account has no valid phone. Set phone in owner profile before running this test.",
    );
  }
  return phone;
}

async function registerDuplicateClient({ phone, inviteCode }) {
  const duplicateEmail = `e2e-dup-${Date.now()}-${randomToken(3)}@example.com`;
  const duplicatePassword = `Pass!${randomToken(4)}Aa`;
  const duplicateName = `E2E Duplicate ${randomToken(2)}`;
  const body = {
    email: duplicateEmail,
    password: duplicatePassword,
    name: duplicateName,
    phone,
    invite_code: inviteCode,
    device_fingerprint: DUP_DEVICE_FINGERPRINT,
  };

  const { response, data } = await requestJson("/api/auth/register", {
    method: "POST",
    body,
  });
  if (!response.ok) {
    throw new Error(
      `Duplicate register failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 700)}`,
    );
  }
  const payload = asObject(data, "register");
  const user = asObject(payload.user || {}, "register.user");
  const token = String(payload.token || "").trim();
  if (!token) throw new Error("register duplicate -> token missing");
  return {
    duplicateEmail,
    duplicatePassword,
    duplicateName,
    duplicateToken: token,
    duplicateUser: user,
    registerPayload: payload,
  };
}

async function findPendingRequestForDuplicate(ownerToken, duplicateEmail) {
  const { response, data } = await requestJson("/api/auth/phone-access/requests", {
    token: ownerToken,
  });
  if (!response.ok) {
    throw new Error(
      `/api/auth/phone-access/requests failed: HTTP ${response.status}`,
    );
  }
  const root = asObject(data, "phone-access.requests");
  const rows = asList(root.data || [], "phone-access.requests.data");
  return (
    rows.find((row) => {
      if (!row || typeof row !== "object") return false;
      return (
        String(row.status || "").trim().toLowerCase() === "pending" &&
        String(row.requester_email || "").trim().toLowerCase() === duplicateEmail
      );
    }) || null
  );
}

async function approveRequest(ownerToken, requestId) {
  const { response, data } = await requestJson(
    `/api/auth/phone-access/requests/${encodeURIComponent(requestId)}/decision`,
    {
      method: "POST",
      token: ownerToken,
      body: { decision: "approve" },
    },
  );
  if (!response.ok) {
    throw new Error(
      `approve request failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
    );
  }
}

async function waitForApprovedStatus(duplicateToken, maxAttempts = 10) {
  for (let i = 0; i < maxAttempts; i += 1) {
    const { response, data } = await requestJson("/api/auth/phone-access/status", {
      token: duplicateToken,
    });
    if (!response.ok) {
      throw new Error(
        `/api/auth/phone-access/status failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
      );
    }
    const root = asObject(data, "phone-access.status.root");
    const stateData = asObject(root.data || {}, "phone-access.status.data");
    const state = String(stateData.state || "").toLowerCase().trim();
    if (state === "approved") return stateData;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error("Duplicate client status did not become approved in time");
}

async function run() {
  if (!OWNER_EMAIL || !OWNER_PASSWORD) {
    throw new Error("Set E2E_OWNER_EMAIL/E2E_OWNER_PASSWORD (or E2E_EMAIL/E2E_PASSWORD)");
  }
  if (!DUP_INVITE_CODE) {
    throw new Error("Set E2E_DUP_INVITE_CODE (or E2E_INVITE_CODE)");
  }

  printStep("AUTH", "owner login");
  const owner = await login({
    email: OWNER_EMAIL,
    password: OWNER_PASSWORD,
    deviceFingerprint: OWNER_DEVICE_FINGERPRINT,
  });

  printStep("CHECK", "owner phone from profile");
  const ownerPhone = await getOwnerPhone(owner.token);
  console.log(`owner phone: ${ownerPhone}`);

  printStep("ACTION", "register duplicate client on same phone");
  const duplicate = await registerDuplicateClient({
    phone: ownerPhone,
    inviteCode: DUP_INVITE_CODE,
  });
  console.log(`duplicate email: ${duplicate.duplicateEmail}`);

  const initialState = String(
    duplicate.registerPayload?.user?.phone_access_state || "",
  )
    .toLowerCase()
    .trim();
  if (initialState !== "pending") {
    throw new Error(
      `duplicate user phone_access_state expected 'pending', got '${initialState || "empty"}'`,
    );
  }

  printStep("CHECK", "owner sees pending request");
  const pending = await findPendingRequestForDuplicate(
    owner.token,
    duplicate.duplicateEmail,
  );
  if (!pending?.id) {
    throw new Error("Owner pending phone-access request for duplicate not found");
  }

  printStep("ACTION", "owner approves request");
  await approveRequest(owner.token, String(pending.id));

  printStep("CHECK", "duplicate status turns approved");
  const approved = await waitForApprovedStatus(duplicate.duplicateToken);
  if (String(approved.shared_cart_owner_id || "").trim() === "") {
    throw new Error("approved state has empty shared_cart_owner_id");
  }

  printStep("SUCCESS", "phone-access flow passed");
}

run().catch((err) => {
  console.error("PHONE ACCESS E2E FAILED:", err?.message || err);
  process.exit(1);
});

