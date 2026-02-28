const express = require("express");
const fs = require("fs");
const path = require("path");
const multer = require("multer");
const { v4: uuidv4 } = require("uuid");

const router = express.Router();
const { pool } = require("../db");
const authMiddleware = require("../middleware/requireAuth");

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
       u.avatar_url,
       COALESCE(u.avatar_focus_x, 0) AS avatar_focus_x,
       COALESCE(u.avatar_focus_y, 0) AS avatar_focus_y,
       COALESCE(u.avatar_zoom, 1) AS avatar_zoom,
       p.phone,
       p.status AS phone_status,
       p.verified_at AS phone_verified_at
     FROM users u
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
    avatar_url: row.avatar_url || null,
    avatar_focus_x: Number(row.avatar_focus_x || 0),
    avatar_focus_y: Number(row.avatar_focus_y || 0),
    avatar_zoom: Number(row.avatar_zoom || 1),
    phone: row.phone || null,
    phone_status: row.phone_status || null,
    phone_verified_at: row.phone_verified_at || null,
  };
}

router.get("/", authMiddleware, async (req, res) => {
  try {
    const user = await loadUserProfile(req.user.id);

    if (!user) {
      return res.status(404).json({
        ok: false,
        error: "User not found",
      });
    }

    return res.json({
      ok: true,
      user,
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
