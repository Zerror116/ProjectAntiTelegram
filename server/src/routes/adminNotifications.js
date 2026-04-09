const fs = require("fs");
const path = require("path");
const multer = require("multer");
const { v4: uuidv4 } = require("uuid");

const express = require("express");

const requireAuth = require("../middleware/requireAuth");
const requireRole = require("../middleware/requireRole");
const {
  dispatchPromotionCampaign,
  listPromotionCampaignsForAdmin,
  getPromotionAnalyticsForCreator,
} = require("../utils/notifications");

const router = express.Router();
const promotionUploadsDir = path.resolve(
  __dirname,
  "..",
  "..",
  "uploads",
  "promotions",
);
fs.mkdirSync(promotionUploadsDir, { recursive: true });

const promotionImageUpload = multer({
  storage: multer.diskStorage({
    destination: (_req, _file, cb) => cb(null, promotionUploadsDir),
    filename: (_req, file, cb) => {
      const ext = path.extname(file.originalname || "").toLowerCase();
      const safeExt = ext && ext.length <= 10 ? ext : ".jpg";
      cb(null, `${Date.now()}-${uuidv4()}${safeExt}`);
    },
  }),
  limits: { fileSize: 8 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    const mime = String(file.mimetype || "").toLowerCase().trim();
    const ext = path.extname(String(file.originalname || "")).toLowerCase();
    const allowedExt = new Set([
      ".jpg",
      ".jpeg",
      ".png",
      ".gif",
      ".webp",
      ".bmp",
      ".heic",
      ".heif",
    ]);
    const isImageMime = mime.startsWith("image/");
    const isOctetImage = mime === "application/octet-stream" && allowedExt.has(ext);
    if (isImageMime || isOctetImage) {
      cb(null, true);
      return;
    }
    cb(new Error("Можно загружать только изображения"));
  },
});

function isCreatorBase(user) {
  return String(user?.role || "").toLowerCase().trim() === "creator";
}

function isAdminBase(user) {
  return String(user?.role || "").toLowerCase().trim() === "admin";
}

function uploadPromotionImage(req, res, next) {
  promotionImageUpload.single("image")(req, res, (err) => {
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

function removeUploadedFile(file) {
  if (!file || !file.path) return;
  fs.unlink(file.path, () => {});
}

function toPromotionImageUrl(req, file) {
  if (!file || !file.filename) return null;
  return `${req.protocol}://${req.get("host")}/uploads/promotions/${file.filename}`;
}

router.post(
  "/promotions/image",
  requireAuth,
  requireRole("admin"),
  uploadPromotionImage,
  async (req, res) => {
    try {
      if (!isAdminBase(req.user)) {
        removeUploadedFile(req.file);
        return res.status(403).json({
          ok: false,
          error: "Только администратор может загружать картинки для promo",
        });
      }
      if (!req.file) {
        return res.status(400).json({
          ok: false,
          error: "Изображение не было загружено",
        });
      }
      return res.json({
        ok: true,
        data: {
          image_url: toPromotionImageUrl(req, req.file),
        },
      });
    } catch (err) {
      removeUploadedFile(req.file);
      console.error("adminNotifications.promotions.image error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post("/promotions", requireAuth, requireRole("admin"), async (req, res) => {
  try {
    if (!isAdminBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Только администратор может отправлять promo" });
    }
    if (isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Создатель может отправлять только test promo" });
    }
    const title = String(req.body?.title || "").trim();
    const body = String(req.body?.body || "").trim();
    if (!title || !body) {
      return res.status(400).json({ ok: false, error: "title и body обязательны" });
    }
    const data = await dispatchPromotionCampaign({
      actor: req.user,
      title,
      body,
      deepLink: req.body?.deep_link || "/",
      media: req.body?.media || {},
      testOnly: false,
    });
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("adminNotifications.promotions.post error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.get("/promotions", requireAuth, requireRole("admin"), async (req, res) => {
  try {
    if (!isAdminBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Только администратор может просматривать promo-кампании" });
    }
    if (isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Создатель не использует этот маршрут для real promo" });
    }
    const data = await listPromotionCampaignsForAdmin(req.user);
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("adminNotifications.promotions.get error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.get("/analytics", requireAuth, requireRole("creator"), async (req, res) => {
  try {
    if (!isCreatorBase(req.user)) {
      return res.status(403).json({ ok: false, error: "Только создатель видит аналитику" });
    }
    const data = await getPromotionAnalyticsForCreator();
    return res.json({ ok: true, data });
  } catch (err) {
    console.error("adminNotifications.analytics.get error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

module.exports = router;
