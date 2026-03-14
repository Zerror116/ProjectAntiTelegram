#!/usr/bin/env node

/* eslint-disable no-console */

const BASE_URL = String(process.env.E2E_BASE_URL || "http://127.0.0.1:3000")
  .trim()
  .replace(/\/+$/, "");

const TENANT_CODE = String(process.env.E2E_TENANT_CODE || "").trim();

const GLOBAL_TOTP_CODE = String(process.env.E2E_TOTP_CODE || "").trim();
const GLOBAL_BACKUP_CODE = String(process.env.E2E_BACKUP_CODE || "").trim();

const WORKER_EMAIL = String(
  process.env.E2E_WORKER_EMAIL ||
    process.env.E2E_STAFF_EMAIL ||
    process.env.E2E_ADMIN_EMAIL ||
    process.env.E2E_EMAIL ||
    "",
)
  .trim()
  .toLowerCase();
const WORKER_PASSWORD = String(
  process.env.E2E_WORKER_PASSWORD ||
    process.env.E2E_STAFF_PASSWORD ||
    process.env.E2E_ADMIN_PASSWORD ||
    process.env.E2E_PASSWORD ||
    "",
).trim();
const WORKER_TOTP_CODE = String(
  process.env.E2E_WORKER_TOTP_CODE ||
    process.env.E2E_STAFF_TOTP_CODE ||
    process.env.E2E_ADMIN_TOTP_CODE ||
    GLOBAL_TOTP_CODE ||
    "",
).trim();
const WORKER_BACKUP_CODE = String(
  process.env.E2E_WORKER_BACKUP_CODE ||
    process.env.E2E_STAFF_BACKUP_CODE ||
    process.env.E2E_ADMIN_BACKUP_CODE ||
    GLOBAL_BACKUP_CODE ||
    "",
).trim();

const ADMIN_EMAIL = String(
  process.env.E2E_ADMIN_EMAIL ||
    process.env.E2E_STAFF_EMAIL ||
    process.env.E2E_EMAIL ||
    "",
)
  .trim()
  .toLowerCase();
const ADMIN_PASSWORD = String(
  process.env.E2E_ADMIN_PASSWORD ||
    process.env.E2E_STAFF_PASSWORD ||
    process.env.E2E_PASSWORD ||
    "",
).trim();
const ADMIN_TOTP_CODE = String(
  process.env.E2E_ADMIN_TOTP_CODE ||
    process.env.E2E_STAFF_TOTP_CODE ||
    GLOBAL_TOTP_CODE ||
    "",
).trim();
const ADMIN_BACKUP_CODE = String(
  process.env.E2E_ADMIN_BACKUP_CODE ||
    process.env.E2E_STAFF_BACKUP_CODE ||
    GLOBAL_BACKUP_CODE ||
    "",
).trim();

const CLIENT_EMAIL = String(process.env.E2E_CLIENT_EMAIL || "")
  .trim()
  .toLowerCase();
const CLIENT_PASSWORD = String(process.env.E2E_CLIENT_PASSWORD || "").trim();
const CLIENT_TOTP_CODE = String(
  process.env.E2E_CLIENT_TOTP_CODE || GLOBAL_TOTP_CODE || "",
).trim();
const CLIENT_BACKUP_CODE = String(
  process.env.E2E_CLIENT_BACKUP_CODE || GLOBAL_BACKUP_CODE || "",
).trim();

const WORKER_DEVICE_FINGERPRINT = String(
  process.env.E2E_WORKER_DEVICE_FINGERPRINT ||
    `order-pipeline-worker-${process.platform}`,
)
  .trim()
  .slice(0, 180);
const ADMIN_DEVICE_FINGERPRINT = String(
  process.env.E2E_ADMIN_DEVICE_FINGERPRINT ||
    `order-pipeline-admin-${process.platform}`,
)
  .trim()
  .slice(0, 180);
const CLIENT_DEVICE_FINGERPRINT = String(
  process.env.E2E_CLIENT_DEVICE_FINGERPRINT ||
    `order-pipeline-client-${process.platform}`,
)
  .trim()
  .slice(0, 180);

const TEST_SHELF_NUMBER = Number(
  process.env.E2E_ORDER_PIPELINE_SHELF || 12,
);
const IMAGE_URL = String(
  process.env.E2E_ORDER_PIPELINE_IMAGE_URL ||
    "https://via.placeholder.com/512x512.png?text=E2E",
).trim();

function printStep(step, details) {
  const stamp = new Date().toISOString();
  console.log(`[${stamp}] ${step} ${details}`);
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

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
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

async function getWorkerMainChannel(workerToken) {
  const { response, data } = await requestJson("/api/worker/channels", {
    token: workerToken,
  });
  if (!response.ok) {
    throw new Error(
      `/api/worker/channels failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 400)}`,
    );
  }
  const root = asObject(data, "worker.channels.root");
  const rows = asList(root.data || [], "worker.channels.data");
  if (rows.length === 0) {
    throw new Error("worker.channels is empty");
  }
  return asObject(rows[0], "worker.channel[0]");
}

async function createWorkerPost(workerToken, channelId, payload) {
  const { response, data } = await requestJson(
    `/api/worker/channels/${encodeURIComponent(channelId)}/posts`,
    {
      method: "POST",
      token: workerToken,
      body: payload,
    },
  );
  if (!response.ok) {
    throw new Error(
      `worker post create failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 700)}`,
    );
  }
  const root = asObject(data, "worker.post.create");
  const rootData = asObject(root.data || {}, "worker.post.create.data");
  return {
    product: asObject(rootData.product || {}, "worker.post.create.product"),
    queue: asObject(rootData.queue || {}, "worker.post.create.queue"),
  };
}

async function getAdminPendingPosts(adminToken) {
  const { response, data } = await requestJson("/api/admin/channels/pending_posts", {
    token: adminToken,
  });
  if (!response.ok) {
    throw new Error(
      `/api/admin/channels/pending_posts failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 700)}`,
    );
  }
  const root = asObject(data, "admin.pending.root");
  return asList(root.data || [], "admin.pending.data");
}

async function publishPending(adminToken, queueIds) {
  const { response, data } = await requestJson("/api/admin/channels/publish_pending", {
    method: "POST",
    token: adminToken,
    body: { queue_ids: queueIds },
  });
  if (!response.ok) {
    throw new Error(
      `/api/admin/channels/publish_pending failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 700)}`,
    );
  }
  return asObject(data, "admin.publish.root");
}

async function waitForCatalogMessages(clientToken, chatId, productIds, maxAttempts = 15) {
  const target = new Set(productIds.map((id) => String(id || "").trim()).filter(Boolean));
  for (let i = 0; i < maxAttempts; i += 1) {
    const { response, data } = await requestJson(
      `/api/chats/${encodeURIComponent(chatId)}/messages`,
      { token: clientToken },
    );
    if (!response.ok) {
      throw new Error(
        `/api/chats/${chatId}/messages failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
      );
    }
    const root = asObject(data, "client.messages.root");
    const rows = asList(root.data || [], "client.messages.data");
    for (const row of rows) {
      if (!row || typeof row !== "object") continue;
      const meta =
        row.meta && typeof row.meta === "object" && !Array.isArray(row.meta)
          ? row.meta
          : {};
      if (String(meta.kind || "") !== "catalog_product") continue;
      const productId = String(meta.product_id || "").trim();
      if (target.has(productId)) {
        target.delete(productId);
      }
    }
    if (target.size === 0) return;
    await sleep(400);
  }
  throw new Error(
    `Catalog messages not found for products: ${Array.from(target).join(", ")}`,
  );
}

async function addToCart(clientToken, productId) {
  const { response, data } = await requestJson("/api/cart/add", {
    method: "POST",
    token: clientToken,
    body: { product_id: productId, quantity: 1 },
  });
  if (!response.ok) {
    throw new Error(
      `/api/cart/add failed for ${productId}: HTTP ${response.status} ${JSON.stringify(data).slice(0, 700)}`,
    );
  }
  const root = asObject(data, "cart.add.root");
  const rootData = asObject(root.data || {}, "cart.add.data");
  const item = asObject(rootData.item || {}, "cart.add.item");
  return item;
}

async function dispatchReserved(adminToken) {
  const { response, data } = await requestJson("/api/admin/orders/dispatch_reserved", {
    method: "POST",
    token: adminToken,
    body: {},
  });
  if (!response.ok) {
    throw new Error(
      `/api/admin/orders/dispatch_reserved failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 700)}`,
    );
  }
  const root = asObject(data, "admin.dispatch.root");
  const rootData = asObject(root.data || {}, "admin.dispatch.data");
  return asList(rootData.orders || [], "admin.dispatch.orders");
}

async function markPlaced(adminToken, body) {
  const { response, data } = await requestJson("/api/admin/orders/mark_placed", {
    method: "POST",
    token: adminToken,
    body,
  });
  if (!response.ok) {
    throw new Error(
      `/api/admin/orders/mark_placed failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 700)}`,
    );
  }
  const root = asObject(data, "admin.markPlaced.root");
  return asObject(root.data || {}, "admin.markPlaced.data");
}

async function fetchCart(clientToken) {
  const { response, data } = await requestJson("/api/cart", {
    token: clientToken,
  });
  if (!response.ok) {
    throw new Error(
      `/api/cart failed: HTTP ${response.status} ${JSON.stringify(data).slice(0, 500)}`,
    );
  }
  const root = asObject(data, "cart.list.root");
  return asObject(root.data || {}, "cart.list.data");
}

async function run() {
  if (!WORKER_EMAIL || !WORKER_PASSWORD) {
    throw new Error("Set worker credentials: E2E_WORKER_EMAIL / E2E_WORKER_PASSWORD");
  }
  if (!ADMIN_EMAIL || !ADMIN_PASSWORD) {
    throw new Error("Set admin credentials: E2E_ADMIN_EMAIL / E2E_ADMIN_PASSWORD");
  }
  if (!CLIENT_EMAIL || !CLIENT_PASSWORD) {
    throw new Error("Set client credentials: E2E_CLIENT_EMAIL / E2E_CLIENT_PASSWORD");
  }
  if (!Number.isFinite(TEST_SHELF_NUMBER) || TEST_SHELF_NUMBER <= 0) {
    throw new Error("E2E_ORDER_PIPELINE_SHELF must be a positive integer");
  }

  printStep("AUTH", "worker login");
  const worker = await login({
    email: WORKER_EMAIL,
    password: WORKER_PASSWORD,
    deviceFingerprint: WORKER_DEVICE_FINGERPRINT,
    totpCode: WORKER_TOTP_CODE,
    backupCode: WORKER_BACKUP_CODE,
  });

  printStep("AUTH", "admin login");
  const admin = await login({
    email: ADMIN_EMAIL,
    password: ADMIN_PASSWORD,
    deviceFingerprint: ADMIN_DEVICE_FINGERPRINT,
    totpCode: ADMIN_TOTP_CODE,
    backupCode: ADMIN_BACKUP_CODE,
  });

  printStep("AUTH", "client login");
  const client = await login({
    email: CLIENT_EMAIL,
    password: CLIENT_PASSWORD,
    deviceFingerprint: CLIENT_DEVICE_FINGERPRINT,
    totpCode: CLIENT_TOTP_CODE,
    backupCode: CLIENT_BACKUP_CODE,
  });

  const workerRole = normalizeRole(worker.user.base_role || worker.user.role);
  if (!new Set(["worker", "admin", "tenant", "creator"]).has(workerRole)) {
    throw new Error(`Worker role is not allowed: ${workerRole || "empty"}`);
  }
  const adminRole = normalizeRole(admin.user.base_role || admin.user.role);
  if (!new Set(["admin", "tenant", "creator"]).has(adminRole)) {
    throw new Error(`Admin role is not allowed: ${adminRole || "empty"}`);
  }
  const clientRole = normalizeRole(client.user.base_role || client.user.role);
  if (clientRole !== "client") {
    throw new Error(`Client role mismatch: expected client, got ${clientRole || "empty"}`);
  }

  printStep("SETUP", "resolve main channel");
  const workerChannel = await getWorkerMainChannel(worker.token);
  const channelId = String(workerChannel.id || "").trim();
  if (!channelId) throw new Error("worker main channel id is empty");

  const runTag = Date.now();
  const payloadA = {
    title: `E2E product A ${runTag}`,
    description: `E2E описание A ${runTag}`,
    price: 1500,
    quantity: 1,
    image_url: IMAGE_URL,
  };
  const payloadB = {
    title: `E2E product B ${runTag}`,
    description: `E2E описание B ${runTag}`,
    price: 1700,
    quantity: 1,
    image_url: IMAGE_URL,
  };

  printStep("ACTION", "worker creates 2 pending posts");
  const createdA = await createWorkerPost(worker.token, channelId, payloadA);
  const createdB = await createWorkerPost(worker.token, channelId, payloadB);

  const productIds = [
    String(createdA.product.id || "").trim(),
    String(createdB.product.id || "").trim(),
  ];
  if (productIds.some((id) => !id)) {
    throw new Error("Created products have empty ids");
  }

  printStep("CHECK", "admin sees pending posts");
  const pending = await getAdminPendingPosts(admin.token);
  const queueByProduct = new Map();
  for (const row of pending) {
    if (!row || typeof row !== "object") continue;
    const pid = String(row.product_id || "").trim();
    const qid = String(row.id || "").trim();
    if (!pid || !qid) continue;
    if (productIds.includes(pid) && !queueByProduct.has(pid)) {
      queueByProduct.set(pid, qid);
    }
  }
  if (queueByProduct.size !== productIds.length) {
    throw new Error(
      `Admin pending queue does not contain created products (${queueByProduct.size}/${productIds.length})`,
    );
  }

  const queueIds = productIds.map((id) => queueByProduct.get(id));
  printStep("ACTION", `admin publishes ${queueIds.length} pending posts`);
  const publish = await publishPending(admin.token, queueIds);
  if (Number(publish.published_count || 0) < queueIds.length) {
    throw new Error(
      `Expected published_count >= ${queueIds.length}, got ${publish.published_count}`,
    );
  }

  printStep("CHECK", "client sees catalog messages in channel");
  await waitForCatalogMessages(client.token, channelId, productIds);

  printStep("ACTION", "client buys both products");
  const cartItemA = await addToCart(client.token, productIds[0]);
  const cartItemB = await addToCart(client.token, productIds[1]);
  const cartItemIdA = String(cartItemA.id || "").trim();
  const cartItemIdB = String(cartItemB.id || "").trim();
  if (!cartItemIdA || !cartItemIdB) {
    throw new Error("cart.add did not return cart item ids");
  }

  printStep("ACTION", "admin dispatches reserved orders");
  const dispatchedOrders = await dispatchReserved(admin.token);
  const orderA = dispatchedOrders.find(
    (row) => String(row?.cart_item_id || "").trim() === cartItemIdA,
  );
  const orderB = dispatchedOrders.find(
    (row) => String(row?.cart_item_id || "").trim() === cartItemIdB,
  );
  if (!orderA || !orderB) {
    throw new Error("Dispatched orders do not contain both test cart items");
  }

  printStep("ACTION", "admin marks first item placed with manual shelf");
  const placedA = await markPlaced(admin.token, {
    cart_item_id: cartItemIdA,
    shelf_number: Math.floor(TEST_SHELF_NUMBER),
    manual_shelf: true,
  });
  const shelfA = Number(placedA.shelf_number || 0);
  if (!Number.isFinite(shelfA) || shelfA <= 0) {
    throw new Error(`First mark_placed returned invalid shelf: ${placedA.shelf_number}`);
  }

  printStep("ACTION", "admin marks second item placed without manual shelf");
  const placedB = await markPlaced(admin.token, {
    cart_item_id: cartItemIdB,
  });
  const shelfB = Number(placedB.shelf_number || 0);
  if (!Number.isFinite(shelfB) || shelfB <= 0) {
    throw new Error(`Second mark_placed returned invalid shelf: ${placedB.shelf_number}`);
  }
  if (shelfB !== shelfA) {
    throw new Error(
      `Shelf propagation failed: first shelf=${shelfA}, second shelf=${shelfB}`,
    );
  }

  printStep("CHECK", "client cart shows processed statuses");
  const cart = await fetchCart(client.token);
  const items = asList(cart.items || [], "cart.items");
  const itemA = items.find(
    (row) => String(row?.product_id || "").trim() === productIds[0],
  );
  const itemB = items.find(
    (row) => String(row?.product_id || "").trim() === productIds[1],
  );
  if (!itemA || !itemB) {
    throw new Error("Client cart does not contain both test products");
  }
  if (String(itemA.status || "") !== "processed") {
    throw new Error(`Product A status expected processed, got ${itemA.status || "empty"}`);
  }
  if (String(itemB.status || "") !== "processed") {
    throw new Error(`Product B status expected processed, got ${itemB.status || "empty"}`);
  }

  printStep(
    "SUCCESS",
    `order pipeline passed (products=${productIds.join(",")}, shelf=${shelfA})`,
  );
}

run().catch((err) => {
  console.error("ORDER PIPELINE E2E FAILED:", err?.message || err);
  process.exit(1);
});

