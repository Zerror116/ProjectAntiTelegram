const express = require("express");
const fs = require("fs");
const path = require("path");
const multer = require("multer");
const { v4: uuidv4 } = require("uuid");
const { generateInviteCode, normalizeInviteCode } = require("../utils/tenants");

const router = express.Router();
const { pool } = require("../db");
const authMiddleware = require("../middleware/requireAuth");
const requirePermission = require("../middleware/requirePermission");
const { resolvePermissionSet } = require("../utils/flexibleRoles");
const SAMARA_TZ = "Europe/Samara";
const requireTenantInvitesManagePermission = requirePermission(
  "tenant.invites.manage",
);

const profileUploadsDir = path.resolve(
  __dirname,
  "..",
  "..",
  "uploads",
  "users",
);
fs.mkdirSync(profileUploadsDir, { recursive: true });

const avatarUpload = multer({
  storage: multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, profileUploadsDir),
    filename: (_req, file, cb) => {
      const ext = path.extname(file.originalname || "").toLowerCase();
      const safeExt = ext && ext.length <= 10 ? ext : ".jpg";
      cb(null, `${Date.now()}-${uuidv4()}${safeExt}`);
    },
  }),
  limits: { fileSize: 8 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    if (String(file.mimetype || "").startsWith("image/")) {
      cb(null, true);
      return;
    }
    cb(new Error("Можно загружать только изображения"));
  },
});

function uploadProfileAvatar(req, res, next) {
  avatarUpload.single("avatar")(req, res, (err) => {
    if (!err) return next();
    if (err instanceof multer.MulterError && err.code === "LIMIT_FILE_SIZE") {
      return res
        .status(400)
        .json({ ok: false, error: "Размер фото не должен превышать 8MB" });
    }
    return res
      .status(400)
      .json({ ok: false, error: err.message || "Некорректный файл" });
  });
}

function clampNumber(value, min, max, fallback) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  if (n < min) return min;
  if (n > max) return max;
  return n;
}

function normalizeAvatarFocus(value, fallback = 0) {
  return clampNumber(value, -1, 1, fallback);
}

function normalizeAvatarZoom(value, fallback = 1) {
  return clampNumber(value, 1, 4, fallback);
}

function toProfileAvatarUrl(req, file) {
  if (!file || !file.filename) return null;
  return `${req.protocol}://${req.get("host")}/uploads/users/${file.filename}`;
}

function removeUploadedFile(file) {
  if (!file || !file.path) return;
  fs.unlink(file.path, () => {});
}

function removeProfileAvatarByUrl(raw) {
  const url = String(raw || "").trim();
  if (!url) return;
  const marker = "/uploads/users/";
  const idx = url.indexOf(marker);
  if (idx === -1) return;
  const filename = url.slice(idx + marker.length).split(/[?#]/)[0].trim();
  if (!filename) return;
  const fullPath = path.join(profileUploadsDir, filename);
  if (!fullPath.startsWith(profileUploadsDir)) return;
  fs.unlink(fullPath, () => {});
}

function normalizeRole(raw) {
  return String(raw || "").toLowerCase().trim();
}

function isTenantManager(user) {
  const baseRole = normalizeRole(user?.base_role || user?.role || "");
  return baseRole === "tenant" || baseRole === "creator";
}

function buildInviteLink(req, inviteCode, tenantCode = "") {
  const base = String(process.env.INVITE_LINK_BASE || "").trim();
  const encodedInvite = encodeURIComponent(String(inviteCode || "").trim());
  const encodedTenant = encodeURIComponent(String(tenantCode || "").trim());
  const tenantPart = encodedTenant ? `&tenant=${encodedTenant}` : "";
  if (base) {
    const glue = base.includes("?") ? "&" : "?";
    return `${base}${glue}invite=${encodedInvite}${tenantPart}`;
  }
  return `${req.protocol}://${req.get("host")}/?invite=${encodedInvite}${tenantPart}`;
}

async function loadUserProfile(userId) {
  const result = await pool.query(
    `SELECT 
       u.id,
       u.email,
       u.name,
       u.role,
       t.code AS tenant_code,
       t.name AS tenant_name,
       t.status AS tenant_status,
       t.subscription_expires_at,
       u.avatar_url,
       COALESCE(u.avatar_focus_x, 0) AS avatar_focus_x,
       COALESCE(u.avatar_focus_y, 0) AS avatar_focus_y,
       COALESCE(u.avatar_zoom, 1) AS avatar_zoom,
       p.phone,
       p.status AS phone_status,
       p.verified_at AS phone_verified_at
     FROM users u
     LEFT JOIN tenants t ON t.id = u.tenant_id
     LEFT JOIN phones p ON p.user_id = u.id
     WHERE u.id = $1
     LIMIT 1`,
    [userId],
  );

  if (result.rows.length === 0) {
    return null;
  }

  const row = result.rows[0];
  return {
    id: row.id,
    email: row.email,
    name: row.name || null,
    role: row.role || "client",
    tenant_code: row.tenant_code || null,
    tenant_name: row.tenant_name || null,
    tenant_status: row.tenant_status || null,
    subscription_expires_at: row.subscription_expires_at || null,
    avatar_url: row.avatar_url || null,
    avatar_focus_x: Number(row.avatar_focus_x || 0),
    avatar_focus_y: Number(row.avatar_focus_y || 0),
    avatar_zoom: Number(row.avatar_zoom || 1),
    phone: row.phone || null,
    phone_status: row.phone_status || null,
    phone_verified_at: row.phone_verified_at || null,
  };
}

function toNumber(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

async function loadWorkerPostsByName(tenantId = null) {
  const rowsQ = await pool.query(
    `WITH worker_candidates AS (
       SELECT u.id,
              u.name,
              u.email
       FROM users u
       WHERE ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
         AND (
           COALESCE(NULLIF(BTRIM(lower(u.role)), ''), '') = 'worker'
           OR EXISTS (
             SELECT 1
             FROM user_role_templates urt
             JOIN role_templates rt ON rt.id = urt.template_id
             WHERE urt.user_id = u.id
               AND (
                 COALESCE(NULLIF(BTRIM(lower(rt.code)), ''), '') = 'worker'
                 OR COALESCE(rt.permissions->>'product.create', 'false') = 'true'
               )
           )
           OR EXISTS (
             SELECT 1
             FROM products pp
             WHERE pp.created_by = u.id
           )
         )
     )
     SELECT wc.id::text AS worker_id,
            COALESCE(NULLIF(BTRIM(wc.name), ''), NULLIF(BTRIM(wc.email), ''), 'Работник') AS worker_name,
            COUNT(p.id) FILTER (
              WHERE timezone($1, p.created_at) >= date_trunc('day', timezone($1, now()))
            )::int AS posts_today,
            COUNT(p.id) FILTER (
              WHERE timezone($1, p.created_at) >= date_trunc('week', timezone($1, now()))
            )::int AS posts_week,
            COUNT(p.id) FILTER (
              WHERE timezone($1, p.created_at) >= date_trunc('week', timezone($1, now())) - interval '7 days'
                AND timezone($1, p.created_at) < date_trunc('week', timezone($1, now()))
            )::int AS posts_prev_week
     FROM worker_candidates wc
     LEFT JOIN products p ON p.created_by = wc.id
     GROUP BY wc.id, wc.name, wc.email
     ORDER BY posts_week DESC, posts_today DESC, worker_name ASC
     LIMIT 40`,
    [SAMARA_TZ, tenantId || null],
  );
  return rowsQ.rows.map((row) => ({
    worker_id: String(row.worker_id || ''),
    worker_name: String(row.worker_name || 'Работник'),
    posts_today: toNumber(row.posts_today),
    posts_week: toNumber(row.posts_week),
    posts_prev_week: toNumber(row.posts_prev_week),
  }));
}

async function loadClientStats(userId) {
  const result = await pool.query(
    `SELECT
       COALESCE(SUM(c.quantity) FILTER (
         WHERE timezone($2, c.created_at) >= date_trunc('day', timezone($2, now()))
       ), 0)::int AS items_today,
       COALESCE(SUM(c.quantity * p.price) FILTER (
         WHERE timezone($2, c.created_at) >= date_trunc('day', timezone($2, now()))
       ), 0)::numeric(12,2) AS spent_today,
       COALESCE(SUM(c.quantity) FILTER (
         WHERE timezone($2, c.created_at) >= timezone($2, now()) - interval '7 days'
       ), 0)::int AS items_week,
       COALESCE(SUM(c.quantity * p.price) FILTER (
         WHERE timezone($2, c.created_at) >= timezone($2, now()) - interval '7 days'
       ), 0)::numeric(12,2) AS spent_week,
       COALESCE(SUM(c.quantity) FILTER (
         WHERE timezone($2, c.created_at) >= timezone($2, now()) - interval '30 days'
       ), 0)::int AS items_month,
       COALESCE(SUM(c.quantity * p.price) FILTER (
         WHERE timezone($2, c.created_at) >= timezone($2, now()) - interval '30 days'
       ), 0)::numeric(12,2) AS spent_month,
       COALESCE(SUM(c.quantity), 0)::int AS items_all_time,
       COALESCE(SUM(c.quantity * p.price), 0)::numeric(12,2) AS spent_all_time
     FROM cart_items c
     JOIN products p ON p.id = c.product_id
     WHERE c.user_id = $1`,
    [userId, SAMARA_TZ],
  );
  const row = result.rows[0] || {};
  return {
    today: { items: toNumber(row.items_today), amount: toNumber(row.spent_today) },
    week: { items: toNumber(row.items_week), amount: toNumber(row.spent_week) },
    month: { items: toNumber(row.items_month), amount: toNumber(row.spent_month) },
    all_time: {
      items: toNumber(row.items_all_time),
      amount: toNumber(row.spent_all_time),
    },
  };
}

async function loadWorkerStats(userId) {
  const postsQ = await pool.query(
    `SELECT
       COUNT(*) FILTER (
         WHERE timezone($2, p.created_at) >= date_trunc('day', timezone($2, now()))
       )::int AS posts_today,
       COUNT(*) FILTER (
         WHERE timezone($2, p.created_at) >= timezone($2, now()) - interval '7 days'
       )::int AS posts_week,
       COUNT(*) FILTER (
         WHERE timezone($2, p.created_at) >= timezone($2, now()) - interval '30 days'
       )::int AS posts_month,
       COUNT(*)::int AS posts_all_time
     FROM products p
     WHERE p.created_by = $1`,
    [userId, SAMARA_TZ],
  );
  const salesQ = await pool.query(
    `SELECT
       COALESCE(SUM(c.quantity) FILTER (
         WHERE timezone($2, c.created_at) >= date_trunc('day', timezone($2, now()))
       ), 0)::int AS sold_today,
       COALESCE(SUM(c.quantity * p.price) FILTER (
         WHERE timezone($2, c.created_at) >= date_trunc('day', timezone($2, now()))
       ), 0)::numeric(12,2) AS revenue_today,
       COALESCE(SUM(c.quantity) FILTER (
         WHERE timezone($2, c.created_at) >= timezone($2, now()) - interval '7 days'
       ), 0)::int AS sold_week,
       COALESCE(SUM(c.quantity * p.price) FILTER (
         WHERE timezone($2, c.created_at) >= timezone($2, now()) - interval '7 days'
       ), 0)::numeric(12,2) AS revenue_week,
       COALESCE(SUM(c.quantity) FILTER (
         WHERE timezone($2, c.created_at) >= timezone($2, now()) - interval '30 days'
       ), 0)::int AS sold_month,
       COALESCE(SUM(c.quantity * p.price) FILTER (
         WHERE timezone($2, c.created_at) >= timezone($2, now()) - interval '30 days'
       ), 0)::numeric(12,2) AS revenue_month,
       COALESCE(SUM(c.quantity), 0)::int AS sold_all_time,
       COALESCE(SUM(c.quantity * p.price), 0)::numeric(12,2) AS revenue_all_time
     FROM cart_items c
     JOIN products p ON p.id = c.product_id
     WHERE p.created_by = $1`,
    [userId, SAMARA_TZ],
  );
  const posts = postsQ.rows[0] || {};
  const sales = salesQ.rows[0] || {};
  return {
    today: {
      posts: toNumber(posts.posts_today),
      sold: toNumber(sales.sold_today),
      amount: toNumber(sales.revenue_today),
    },
    week: {
      posts: toNumber(posts.posts_week),
      sold: toNumber(sales.sold_week),
      amount: toNumber(sales.revenue_week),
    },
    month: {
      posts: toNumber(posts.posts_month),
      sold: toNumber(sales.sold_month),
      amount: toNumber(sales.revenue_month),
    },
    all_time: {
      posts: toNumber(posts.posts_all_time),
      sold: toNumber(sales.sold_all_time),
      amount: toNumber(sales.revenue_all_time),
    },
  };
}

async function loadAdminStats(userId, tenantId = null) {
  const processedQ = await pool.query(
    `SELECT
       COALESCE(SUM(r.quantity) FILTER (
         WHERE timezone($2, r.fulfilled_at) >= date_trunc('day', timezone($2, now()))
       ), 0)::int AS processed_today,
       COALESCE(SUM(p.price * r.quantity) FILTER (
         WHERE timezone($2, r.fulfilled_at) >= date_trunc('day', timezone($2, now()))
       ), 0)::numeric(12,2) AS processed_amount_today,
       COALESCE(SUM(r.quantity) FILTER (
         WHERE timezone($2, r.fulfilled_at) >= timezone($2, now()) - interval '7 days'
       ), 0)::int AS processed_week,
       COALESCE(SUM(p.price * r.quantity) FILTER (
         WHERE timezone($2, r.fulfilled_at) >= timezone($2, now()) - interval '7 days'
       ), 0)::numeric(12,2) AS processed_amount_week,
       COALESCE(SUM(r.quantity) FILTER (
         WHERE timezone($2, r.fulfilled_at) >= timezone($2, now()) - interval '30 days'
       ), 0)::int AS processed_month,
       COALESCE(SUM(p.price * r.quantity) FILTER (
         WHERE timezone($2, r.fulfilled_at) >= timezone($2, now()) - interval '30 days'
       ), 0)::numeric(12,2) AS processed_amount_month,
       COALESCE(SUM(r.quantity), 0)::int AS processed_all_time,
       COALESCE(SUM(p.price * r.quantity), 0)::numeric(12,2) AS processed_amount_all_time
     FROM reservations r
     JOIN products p ON p.id = r.product_id
     WHERE r.fulfilled_by_id = $1
       AND r.fulfilled_at IS NOT NULL`,
    [userId, SAMARA_TZ],
  );
  const deliveriesQ = await pool.query(
    `SELECT
       COUNT(*) FILTER (
         WHERE timezone($2, b.assembled_at) >= date_trunc('day', timezone($2, now()))
       )::int AS deliveries_today,
       COUNT(*) FILTER (
         WHERE timezone($2, b.assembled_at) >= timezone($2, now()) - interval '7 days'
       )::int AS deliveries_week,
       COUNT(*) FILTER (
         WHERE timezone($2, b.assembled_at) >= timezone($2, now()) - interval '30 days'
       )::int AS deliveries_month,
       COUNT(*)::int AS deliveries_all_time
     FROM delivery_batches b
     WHERE b.assembled_by_id = $1
       AND b.assembled_at IS NOT NULL`,
    [userId, SAMARA_TZ],
  );
  const processed = processedQ.rows[0] || {};
  const deliveries = deliveriesQ.rows[0] || {};
  const workerPostsByName = await loadWorkerPostsByName(tenantId);
  return {
    today: {
      processed: toNumber(processed.processed_today),
      processed_amount: toNumber(processed.processed_amount_today),
      deliveries: toNumber(deliveries.deliveries_today),
    },
    week: {
      processed: toNumber(processed.processed_week),
      processed_amount: toNumber(processed.processed_amount_week),
      deliveries: toNumber(deliveries.deliveries_week),
    },
    month: {
      processed: toNumber(processed.processed_month),
      processed_amount: toNumber(processed.processed_amount_month),
      deliveries: toNumber(deliveries.deliveries_month),
    },
    all_time: {
      processed: toNumber(processed.processed_all_time),
      processed_amount: toNumber(processed.processed_amount_all_time),
      deliveries: toNumber(deliveries.deliveries_all_time),
    },
    worker_posts_by_name: workerPostsByName,
  };
}

async function loadCreatorStats(tenantId = null) {
  const totalsQ = await pool.query(
    `SELECT
       COUNT(*) FILTER (
         WHERE timezone($1, u.created_at) >= date_trunc('day', timezone($1, now()))
       )::int AS users_today,
       COUNT(*) FILTER (
         WHERE timezone($1, u.created_at) >= timezone($1, now()) - interval '7 days'
       )::int AS users_week,
       COUNT(*) FILTER (
         WHERE timezone($1, u.created_at) >= timezone($1, now()) - interval '30 days'
       )::int AS users_month,
       COUNT(*)::int AS users_all_time
     FROM users u`,
    [SAMARA_TZ],
  );
  const workerPostsQ = await pool.query(
    `SELECT
       COUNT(*) FILTER (
         WHERE timezone($1, p.created_at) >= date_trunc('day', timezone($1, now()))
       )::int AS posts_today,
       COUNT(*) FILTER (
         WHERE timezone($1, p.created_at) >= timezone($1, now()) - interval '7 days'
       )::int AS posts_week,
       COUNT(*) FILTER (
         WHERE timezone($1, p.created_at) >= timezone($1, now()) - interval '30 days'
       )::int AS posts_month,
       COUNT(*)::int AS posts_all_time
     FROM products p
     JOIN users u ON u.id = p.created_by
     WHERE u.role = 'worker'
       AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)`,
    [SAMARA_TZ, tenantId || null],
  );
  const processedQ = await pool.query(
    `SELECT
       COALESCE(SUM(r.quantity) FILTER (
         WHERE timezone($1, r.fulfilled_at) >= date_trunc('day', timezone($1, now()))
       ), 0)::int AS processed_today,
       COALESCE(SUM(r.quantity) FILTER (
         WHERE timezone($1, r.fulfilled_at) >= timezone($1, now()) - interval '7 days'
       ), 0)::int AS processed_week,
       COALESCE(SUM(r.quantity) FILTER (
         WHERE timezone($1, r.fulfilled_at) >= timezone($1, now()) - interval '30 days'
       ), 0)::int AS processed_month,
       COALESCE(SUM(r.quantity), 0)::int AS processed_all_time
     FROM reservations r
     WHERE r.fulfilled_at IS NOT NULL`,
    [SAMARA_TZ],
  );
  const revenueQ = await pool.query(
    `SELECT
       COALESCE(SUM(c.quantity * p.price) FILTER (
         WHERE timezone($1, c.created_at) >= date_trunc('day', timezone($1, now()))
       ), 0)::numeric(12,2) AS revenue_today,
       COALESCE(SUM(c.quantity * p.price) FILTER (
         WHERE timezone($1, c.created_at) >= timezone($1, now()) - interval '7 days'
       ), 0)::numeric(12,2) AS revenue_week,
       COALESCE(SUM(c.quantity * p.price) FILTER (
         WHERE timezone($1, c.created_at) >= timezone($1, now()) - interval '30 days'
       ), 0)::numeric(12,2) AS revenue_month,
       COALESCE(SUM(c.quantity * p.price), 0)::numeric(12,2) AS revenue_all_time
     FROM cart_items c
     JOIN products p ON p.id = c.product_id`,
    [SAMARA_TZ],
  );
  const liveQ = await pool.query(
    `SELECT
       (SELECT COUNT(*)::int
        FROM product_publication_queue q
        WHERE q.status = 'pending' AND COALESCE(q.is_sent, false) = false) AS pending_posts,
       (SELECT COALESCE(SUM(quantity), 0)::int
        FROM reservations
        WHERE is_fulfilled = false) AS unprocessed_reservations,
       (SELECT COUNT(*)::int
        FROM delivery_batch_customers c
        JOIN delivery_batches b ON b.id = c.batch_id
        WHERE b.status IN ('calling', 'couriers_assigned', 'handed_off')
          AND c.call_status = 'accepted') AS active_delivery_clients`,
  );
  const totals = totalsQ.rows[0] || {};
  const workerPosts = workerPostsQ.rows[0] || {};
  const processed = processedQ.rows[0] || {};
  const revenue = revenueQ.rows[0] || {};
  const live = liveQ.rows[0] || {};
  return {
    today: {
      users: toNumber(totals.users_today),
      worker_posts: toNumber(workerPosts.posts_today),
      admin_processed: toNumber(processed.processed_today),
      client_amount: toNumber(revenue.revenue_today),
    },
    week: {
      users: toNumber(totals.users_week),
      worker_posts: toNumber(workerPosts.posts_week),
      admin_processed: toNumber(processed.processed_week),
      client_amount: toNumber(revenue.revenue_week),
    },
    month: {
      users: toNumber(totals.users_month),
      worker_posts: toNumber(workerPosts.posts_month),
      admin_processed: toNumber(processed.processed_month),
      client_amount: toNumber(revenue.revenue_month),
    },
    all_time: {
      users: toNumber(totals.users_all_time),
      worker_posts: toNumber(workerPosts.posts_all_time),
      admin_processed: toNumber(processed.processed_all_time),
      client_amount: toNumber(revenue.revenue_all_time),
    },
    live: {
      pending_posts: toNumber(live.pending_posts),
      unprocessed_reservations: toNumber(live.unprocessed_reservations),
      active_delivery_clients: toNumber(live.active_delivery_clients),
    },
    worker_posts_by_name: await loadWorkerPostsByName(tenantId),
  };
}

async function loadRoleStats(userId, role, tenantId = null) {
  switch (String(role || "").trim()) {
    case "worker":
      return { role: "worker", periods: await loadWorkerStats(userId) };
    case "admin":
      return { role: "admin", periods: await loadAdminStats(userId, tenantId) };
    case "tenant":
      return { role: "tenant", periods: await loadAdminStats(userId, tenantId) };
    case "creator":
      return { role: "creator", periods: await loadCreatorStats(tenantId) };
    case "client":
    default:
      return { role: "client", periods: await loadClientStats(userId) };
  }
}

router.get("/", authMiddleware, async (req, res) => {
  try {
    const user = await loadUserProfile(req.user.id);
    const stats = await loadRoleStats(
      req.user.id,
      req.user.role,
      req.user?.tenant_id || null,
    );
    const resolvedPermissions = await resolvePermissionSet(req.user, pool);

    if (!user) {
      return res.status(404).json({
        ok: false,
        error: "User not found",
      });
    }

    return res.json({
      ok: true,
      user: {
        ...user,
        permissions:
          resolvedPermissions &&
          resolvedPermissions.permissions &&
          typeof resolvedPermissions.permissions === "object"
            ? resolvedPermissions.permissions
            : {},
        permission_source: resolvedPermissions?.source || "default_map",
      },
      stats,
    });
  } catch (err) {
    console.error("PROFILE ERROR:", err);

    return res.status(500).json({
      ok: false,
      error: "Internal server error",
    });
  }
});

router.post(
  "/avatar",
  authMiddleware,
  uploadProfileAvatar,
  async (req, res) => {
    const uploadedUrl = toProfileAvatarUrl(req, req.file);
    if (!uploadedUrl) {
      return res
        .status(400)
        .json({ ok: false, error: "Файл аватарки обязателен" });
    }

    try {
      const current = await pool.query(
        `SELECT avatar_url
         FROM users
         WHERE id = $1
         LIMIT 1`,
        [req.user.id],
      );
      if (current.rowCount === 0) {
        removeUploadedFile(req.file);
        return res.status(404).json({ ok: false, error: "Пользователь не найден" });
      }

      const previousAvatar = String(current.rows[0]?.avatar_url || "").trim();
      await pool.query(
        `UPDATE users
         SET avatar_url = $1,
             avatar_focus_x = 0,
             avatar_focus_y = 0,
             avatar_zoom = 1,
             updated_at = now()
         WHERE id = $2`,
        [uploadedUrl, req.user.id],
      );

      const user = await loadUserProfile(req.user.id);
      if (!user) {
        removeUploadedFile(req.file);
        return res.status(404).json({ ok: false, error: "Пользователь не найден" });
      }

      if (previousAvatar && previousAvatar !== uploadedUrl) {
        removeProfileAvatarByUrl(previousAvatar);
      }

      return res.json({ ok: true, user });
    } catch (err) {
      removeUploadedFile(req.file);
      console.error("profile.avatar error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.delete("/avatar", authMiddleware, async (req, res) => {
  try {
    const current = await pool.query(
      `SELECT avatar_url
       FROM users
       WHERE id = $1
       LIMIT 1`,
      [req.user.id],
    );
    if (current.rowCount === 0) {
      return res.status(404).json({ ok: false, error: "Пользователь не найден" });
    }

    const previousAvatar = String(current.rows[0]?.avatar_url || "").trim();
    await pool.query(
      `UPDATE users
       SET avatar_url = NULL,
           avatar_focus_x = 0,
           avatar_focus_y = 0,
           avatar_zoom = 1,
           updated_at = now()
       WHERE id = $1`,
      [req.user.id],
    );

    if (previousAvatar) {
      removeProfileAvatarByUrl(previousAvatar);
    }

    const user = await loadUserProfile(req.user.id);
    return res.json({ ok: true, user });
  } catch (err) {
    console.error("profile.avatar.remove error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.patch("/", authMiddleware, async (req, res) => {
  try {
    const nextFocusX = normalizeAvatarFocus(req.body?.avatar_focus_x, 0);
    const nextFocusY = normalizeAvatarFocus(req.body?.avatar_focus_y, 0);
    const nextZoom = normalizeAvatarZoom(req.body?.avatar_zoom, 1);

    await pool.query(
      `UPDATE users
       SET avatar_focus_x = $1,
           avatar_focus_y = $2,
           avatar_zoom = $3,
           updated_at = now()
       WHERE id = $4`,
      [nextFocusX, nextFocusY, nextZoom, req.user.id],
    );

    const user = await loadUserProfile(req.user.id);
    return res.json({ ok: true, user });
  } catch (err) {
    console.error("profile.patch error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.get(
  "/tenant/client-invite",
  authMiddleware,
  requireTenantInvitesManagePermission,
  async (req, res) => {
    if (!isTenantManager(req.user)) {
      return res.status(403).json({
        ok: false,
        error: "Доступно только арендатору или создателю",
      });
    }

    const tenantId = String(req.user?.tenant_id || "").trim();
    const tenantCode = String(req.user?.tenant_code || "").trim();
    if (!tenantId || !tenantCode) {
      return res.status(403).json({
        ok: false,
        error: "Аккаунт не привязан к группе арендатора",
      });
    }

    try {
      const existing = await pool.query(
        `SELECT id, code, is_active, max_uses, used_count, expires_at
         FROM tenant_invites
         WHERE tenant_id = $1
           AND role = 'client'
           AND is_active = true
           AND (expires_at IS NULL OR expires_at > now())
           AND (max_uses IS NULL OR used_count < max_uses)
         ORDER BY created_at DESC
         LIMIT 1`,
        [tenantId],
      );

      let inviteCode = "";
      let inviteId = "";
      if (existing.rowCount > 0) {
        inviteCode = String(existing.rows[0].code || "").trim();
        inviteId = String(existing.rows[0].id || "").trim();
      } else {
        let created = null;
        for (let i = 0; i < 5; i += 1) {
          const nextCode = normalizeInviteCode(generateInviteCode());
          try {
            const insert = await pool.query(
              `INSERT INTO tenant_invites (
                 id, tenant_id, code, role, is_active, max_uses,
                 used_count, expires_at, created_by, notes, created_at, updated_at
               )
               VALUES (
                 $1, $2, $3, 'client', true, NULL,
                 0, NULL, $4, 'Публичная клиентская ссылка', now(), now()
               )
               RETURNING id, code`,
              [uuidv4(), tenantId, nextCode, req.user.id],
            );
            created = insert.rows[0];
            break;
          } catch (err) {
            if (String(err?.code || "") === "23505") continue;
            throw err;
          }
        }

        if (!created) {
          return res.status(500).json({
            ok: false,
            error: "Не удалось создать клиентский код приглашения",
          });
        }
        inviteCode = String(created.code || "").trim();
        inviteId = String(created.id || "").trim();
      }

      return res.json({
        ok: true,
        data: {
          invite_id: inviteId,
          code: inviteCode,
          tenant_code: tenantCode,
          invite_link: buildInviteLink(req, inviteCode, tenantCode),
        },
      });
    } catch (err) {
      console.error("profile.tenant.clientInvite error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.get(
  "/tenant/clients",
  authMiddleware,
  async (req, res) => {
    if (!isTenantManager(req.user)) {
      return res.status(403).json({
        ok: false,
        error: "Доступно только арендатору или создателю",
      });
    }

    const tenantId = String(req.user?.tenant_id || "").trim();
    if (!tenantId) {
      return res.status(403).json({
        ok: false,
        error: "Аккаунт не привязан к группе арендатора",
      });
    }

    const rawSearch = String(req.query?.search || "").trim();
    const search = rawSearch.slice(0, 80);
    const digits = search.replace(/\D/g, "").slice(0, 20);

    try {
      const result = await pool.query(
        `SELECT u.id,
                u.name,
                u.email,
                u.role,
                u.created_at,
                p.phone
         FROM users u
         LEFT JOIN phones p ON p.user_id = u.id
         WHERE u.tenant_id = $1::uuid
           AND u.role = ANY($2::text[])
           AND (
             $3::text = ''
             OR COALESCE(u.name, '') ILIKE '%' || $3 || '%'
             OR COALESCE(u.email, '') ILIKE '%' || $3 || '%'
             OR ($4::text <> '' AND COALESCE(p.phone, '') ILIKE '%' || $4 || '%')
           )
         ORDER BY u.created_at DESC
         LIMIT 200`,
        [tenantId, ["client", "worker", "admin"], search, digits],
      );

      return res.json({ ok: true, data: result.rows });
    } catch (err) {
      console.error("profile.tenant.clients error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/tenant/clients/:userId/role",
  authMiddleware,
  async (req, res) => {
    if (!isTenantManager(req.user)) {
      return res.status(403).json({
        ok: false,
        error: "Доступно только арендатору или создателю",
      });
    }

    const tenantId = String(req.user?.tenant_id || "").trim();
    const userId = String(req.params?.userId || "").trim();
    const nextRole = normalizeRole(req.body?.role);

    if (!tenantId) {
      return res.status(403).json({
        ok: false,
        error: "Аккаунт не привязан к группе арендатора",
      });
    }
    if (!userId) {
      return res.status(400).json({ ok: false, error: "Некорректный userId" });
    }
    if (!["client", "worker", "admin"].includes(nextRole)) {
      return res.status(400).json({
        ok: false,
        error: "Разрешены роли: client, worker, admin",
      });
    }

    try {
      const targetQ = await pool.query(
        `SELECT id, role
         FROM users
         WHERE id = $1::uuid
           AND tenant_id = $2::uuid
         LIMIT 1`,
        [userId, tenantId],
      );
      if (targetQ.rowCount === 0) {
        return res.status(404).json({
          ok: false,
          error: "Пользователь не найден",
        });
      }

      const currentRole = normalizeRole(targetQ.rows[0].role);
      if (currentRole === "creator" || currentRole === "tenant") {
        return res.status(403).json({
          ok: false,
          error: "Нельзя менять роль этого пользователя",
        });
      }

      const updated = await pool.query(
        `UPDATE users
         SET role = $1,
             updated_at = now()
         WHERE id = $2::uuid
           AND tenant_id = $3::uuid
         RETURNING id, role`,
        [nextRole, userId, tenantId],
      );
      return res.json({ ok: true, data: updated.rows[0] });
    } catch (err) {
      console.error("profile.tenant.clients.role error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

module.exports = router;
