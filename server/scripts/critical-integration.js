#!/usr/bin/env node

/* eslint-disable no-console */

const crypto = require("crypto");

const BASE_URL = String(process.env.E2E_BASE_URL || "http://127.0.0.1:3000")
  .trim()
  .replace(/\/+$/, "");
const EMAIL = String(process.env.E2E_EMAIL || "").trim().toLowerCase();
const PASSWORD = String(process.env.E2E_PASSWORD || "").trim();
const TENANT_CODE = String(process.env.E2E_TENANT_CODE || "").trim();
const VIEW_ROLE = String(process.env.E2E_VIEW_ROLE || "").trim();
const TOTP_CODE = String(process.env.E2E_TOTP_CODE || "").trim();
const BACKUP_CODE = String(process.env.E2E_BACKUP_CODE || "").trim();
const DIRECT_QUERY = String(process.env.E2E_DIRECT_QUERY || "").trim();
const STRICT_ADMIN = ["1", "true", "yes"].includes(
  String(process.env.E2E_STRICT_ADMIN || "").trim().toLowerCase(),
);
const DEVICE_FINGERPRINT = String(
  process.env.E2E_DEVICE_FINGERPRINT || `critical-e2e-${process.platform}`,
)
  .trim()
  .slice(0, 180);

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

function collectSignedUploadUrls(payload, out = new Set()) {
  if (payload == null) return out;
  if (typeof payload === "string") {
    const text = payload.trim();
    if (
      /^https?:\/\/[^/\s]+\/uploads\/(products|channels|users|claims)\/[^?#\s]+(?:\?[^#\s]*)?$/i.test(
        text,
      )
    ) {
      out.add(text);
    }
    return out;
  }
  if (typeof payload !== "object") return out;
  if (Array.isArray(payload)) {
    payload.forEach((item) => collectSignedUploadUrls(item, out));
    return out;
  }
  Object.values(payload).forEach((value) => collectSignedUploadUrls(value, out));
  return out;
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

async function loginAndGetToken() {
  const loginBody = {
    email: EMAIL,
    password: PASSWORD,
    device_fingerprint: DEVICE_FINGERPRINT,
  };
  if (TENANT_CODE) loginBody.tenant_code = TENANT_CODE;
  if (VIEW_ROLE) loginBody.view_role = VIEW_ROLE;

  let { response, data } = await requestJson("/api/auth/login", {
    method: "POST",
    body: loginBody,
  });

  if (response.status === 401 && (data?.two_factor_required || data?.twoFactorRequired)) {
    const code = TOTP_CODE || BACKUP_CODE;
    if (!code) {
      throw new Error(
        "2FA is enabled. Provide E2E_TOTP_CODE or E2E_BACKUP_CODE for critical integration test.",
      );
    }
    ({ response, data } = await requestJson("/api/auth/login", {
      method: "POST",
      body: {
        ...loginBody,
        otp_code: code,
      },
    }));
  }

  if (!response.ok) {
    throw new Error(
      `Login failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
    );
  }

  const payload = asObject(data, "login");
  const token = String(payload.token || "").trim();
  if (!token) {
    throw new Error("Login response does not contain token");
  }
  const user = asObject(payload.user || {}, "login.user");
  return { token, user, loginPayload: payload };
}

function assertSignedUploadUrl(url, context) {
  const parsed = new URL(url);
  const exp = parsed.searchParams.get("exp");
  const sig = parsed.searchParams.get("sig");
  if (!exp || !sig) {
    throw new Error(`${context}: missing exp/sig in signed URL: ${url}`);
  }
  if (!/^\d+$/.test(exp)) {
    throw new Error(`${context}: invalid exp in signed URL: ${url}`);
  }
  if (!/^[a-f0-9]{64}$/i.test(sig)) {
    throw new Error(`${context}: invalid sig in signed URL: ${url}`);
  }
}

function printStep(step, details) {
  const stamp = new Date().toISOString();
  console.log(`[${stamp}] ${step} ${details}`);
}

async function run() {
  if (!EMAIL || !PASSWORD) {
    console.error(
      "Missing credentials. Set E2E_EMAIL and E2E_PASSWORD to run critical integration checks.",
    );
    process.exit(1);
  }

  const startedAt = Date.now();
  const allPayloads = [];

  printStep("AUTH", "login");
  const { token, user, loginPayload } = await loginAndGetToken();
  allPayloads.push(loginPayload);

  printStep("CHECK", "profile");
  {
    const { response, data } = await requestJson("/api/profile", { token });
    if (!response.ok) {
      throw new Error(`/api/profile failed: HTTP ${response.status}`);
    }
    const root = asObject(data, "profile.root");
    if (root.ok !== true) throw new Error("/api/profile -> ok != true");
    const profile = asObject(root.user || root.data || {}, "profile.user");
    if (!String(profile.id || "").trim()) {
      throw new Error("/api/profile -> missing user id");
    }
    allPayloads.push(root);
  }

  printStep("CHECK", "chats list + main channel");
  {
    const { response, data } = await requestJson("/api/chats", { token });
    if (!response.ok) {
      throw new Error(`/api/chats failed: HTTP ${response.status}`);
    }
    const root = asObject(data, "chats.root");
    const rows = asList(root.data || root.chats || [], "chats.data");
    const mainChannel = rows.find((item) => {
      if (!item || typeof item !== "object") return false;
      const title = String(item.title || item.display_title || "").toLowerCase();
      const settings =
        item.settings && typeof item.settings === "object" ? item.settings : {};
      return (
        settings.system_key === "main_channel" ||
        settings.kind === "main_channel" ||
        title.includes("основной канал")
      );
    });
    if (!mainChannel) {
      throw new Error("Main channel is missing in /api/chats");
    }
    allPayloads.push(root);
  }

  if (DIRECT_QUERY) {
    printStep("CHECK", "direct search");
    const query = encodeURIComponent(DIRECT_QUERY);
    const { response, data } = await requestJson(
      `/api/chats/direct/search?query=${query}&limit=10`,
      { token },
    );
    if (!response.ok) {
      throw new Error(`/api/chats/direct/search failed: HTTP ${response.status}`);
    }
    const root = asObject(data, "direct.search");
    if (root.ok !== true) throw new Error("direct search -> ok != true");
    allPayloads.push(root);
  } else {
    printStep("SKIP", "direct search (E2E_DIRECT_QUERY not set)");
  }

  printStep("CHECK", "cart snapshot");
  {
    const { response, data } = await requestJson("/api/cart", { token });
    if (!response.ok) {
      throw new Error(`/api/cart failed: HTTP ${response.status}`);
    }
    const root = asObject(data, "cart.root");
    if (root.ok !== true) throw new Error("/api/cart -> ok != true");
    allPayloads.push(root);
  }

  const adminEndpoints = [
    "/api/admin/ops/support/templates",
    "/api/admin/ops/notifications/center",
    "/api/admin/ops/returns/analytics",
    "/api/admin/ops/diagnostics/center",
    "/api/admin/channels",
  ];

  for (const endpoint of adminEndpoints) {
    printStep("CHECK", endpoint);
    const { response, data } = await requestJson(endpoint, { token });
    if (response.status === 403) {
      if (STRICT_ADMIN) {
        throw new Error(`${endpoint} returned 403 in strict admin mode`);
      }
      printStep("SKIP", `${endpoint} -> 403 (insufficient role)`);
      continue;
    }
    if (!response.ok) {
      throw new Error(`${endpoint} failed: HTTP ${response.status}`);
    }
    allPayloads.push(data);
  }

  printStep("CHECK", "signed uploads in payloads");
  const allUrls = new Set();
  allPayloads.forEach((payload) => collectSignedUploadUrls(payload, allUrls));

  if (allUrls.size === 0) {
    printStep(
      "WARN",
      "no /uploads/products|channels|users|claims URLs found in tested payloads",
    );
  }

  for (const url of allUrls) {
    assertSignedUploadUrl(url, "payload");
  }

  const sampleUrl = Array.from(allUrls)[0] || "";
  if (sampleUrl) {
    printStep("CHECK", "signed upload access");
    const signedResponse = await fetch(sampleUrl);
    if (![200, 304].includes(signedResponse.status)) {
      throw new Error(
        `Signed upload URL does not work: HTTP ${signedResponse.status} ${sampleUrl}`,
      );
    }

    const parsed = new URL(sampleUrl);
    const unsignedUrl = `${parsed.origin}${parsed.pathname}`;
    const unsignedResponse = await fetch(unsignedUrl);
    if (unsignedResponse.status !== 403) {
      throw new Error(
        `Unsigned upload URL must be denied with 403, got ${unsignedResponse.status}`,
      );
    }
  }

  const runtimeMs = Date.now() - startedAt;
  const digest = crypto
    .createHash("sha256")
    .update(`${EMAIL}|${user.id || ""}|${runtimeMs}|${allUrls.size}`)
    .digest("hex")
    .slice(0, 12);
  printStep(
    "DONE",
    `critical integration checks passed in ${runtimeMs}ms (urls=${allUrls.size}, run=${digest})`,
  );
}

run().catch((err) => {
  console.error("CRITICAL INTEGRATION FAILED:", err?.message || err);
  process.exit(1);
});

