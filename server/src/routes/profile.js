const express = require("express");
const fs = require("fs");
const path = require("path");
const multer = require("multer");
const { v4: uuidv4 } = require("uuid");

const router = express.Router();
const { pool } = require("../db");
const authMiddleware = require("../middleware/requireAuth");
const SAMARA_TZ = "Europe/Samara";

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

async function loadUserProfile(userId) {
  const result = await pool.query(
    `SELECT 
       u.id,
       u.email,
       u.name,
       u.role,
       t.code AS tenant_code,
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

async function loadAdminStats(userId) {
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
  };
}

async function loadCreatorStats() {
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
     WHERE u.role = 'worker'`,
    [SAMARA_TZ],
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
  };
}

async function loadRoleStats(userId, role) {
  switch (String(role || "").trim()) {
    case "worker":
      return { role: "worker", periods: await loadWorkerStats(userId) };
    case "admin":
      return { role: "admin", periods: await loadAdminStats(userId) };
    case "creator":
      return { role: "creator", periods: await loadCreatorStats() };
    case "client":
    default:
      return { role: "client", periods: await loadClientStats(userId) };
  }
}

router.get("/", authMiddleware, async (req, res) => {
  try {
    const user = await loadUserProfile(req.user.id);
    const stats = await loadRoleStats(req.user.id, req.user.role);

    if (!user) {
      return res.status(404).json({
        ok: false,
        error: "User not found",
      });
    }

    return res.json({
      ok: true,
      user,
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

module.exports = router;
