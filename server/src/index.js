// server/src/index.js
// Главный файл Express приложения с Socket.io

const fs = require("fs");
const path = require("path");
const dotenv = require("dotenv");

const serverRoot = path.resolve(__dirname, "..");
dotenv.config({ path: path.join(serverRoot, ".env") });

const bootNodeEnv = String(process.env.NODE_ENV || "development")
  .toLowerCase()
  .trim();
if (bootNodeEnv !== "production") {
  const localEnvPath = path.join(serverRoot, ".env.local");
  if (fs.existsSync(localEnvPath)) {
    dotenv.config({ path: localEnvPath, override: true });
  }
}

const express = require("express");
const http = require("http");
const { Server } = require("socket.io");
const cors = require("cors");
const helmet = require("helmet");
const bodyParser = require("body-parser");
const rateLimit = require("express-rate-limit");

const db = require("./db");
const {
  uploadsRoot,
  downloadsRoot,
  ensureStorageLayout,
} = require("./utils/storagePaths");
const {
  ensurePlaceholderAssets,
  PRODUCT_PLACEHOLDER_NAME,
  GENERIC_MEDIA_PLACEHOLDER_NAME,
  PUBLIC_MEDIA_PLACEHOLDER_NAME,
} = require("./utils/uploadRecovery");
const { refreshMediaAssetCache } = require("./utils/mediaAssets");

// ✅ Сначала создаём app, потом использу��м его
const app = express();
app.disable("x-powered-by");

// Импортируем роуты и middleware ПОСЛЕ создания app
const profileUpdateRoutes = require("./routes/profileUpdate");
const setupRouter = require("./routes/setup");
const phonesRouter = require("./routes/phones");
const chatsRouter = require("./routes/chats");
const profileRouter = require("./routes/profile");
const uploadsRecoveryRoutes = require("./routes/uploadsRecovery");
const authRouter = require("./routes/auth");
const adminRoutes = require("./routes/admin");
const opsRoutes = require("./routes/ops");
const deliveryRoutes = require("./routes/delivery");
const workerRoutes = require("./routes/worker");
const cartRoutes = require("./routes/cart");
const supportRoutes = require("./routes/support");
const appUpdateRoutes = require("./routes/appUpdate");
const webPushRoutes = require("./routes/webPush");
const notificationsRoutes = require("./routes/notifications");
const messengerRoutes = require("./routes/messenger");
const adminNotificationsRoutes = require("./routes/adminNotifications");
const { runNotificationDigestSweep } = require("./utils/notifications");
const { authMiddleware, resolveAuthContextFromToken } = require("./utils/auth");
const { bootstrapDatabase } = require("./utils/bootstrap");
const {
  runMessageEncryptionBackfill,
} = require("./utils/messageEncryptionBackfill");
const { logMonitoringEvent } = require("./utils/monitoring");
const realtimeDiagnostics = require("./utils/realtimeDiagnostics");
const { tenantRoom } = require("./utils/socket");
const {
  rewriteSignedUploadsInPayload,
  signedUploadGuard,
} = require("./utils/signedUploads");
const { queueChatMessageWebPushForRooms } = require("./utils/webPush");

if (!global.__fenixProcessMonitoringHooksInstalled) {
  global.__fenixProcessMonitoringHooksInstalled = true;
  process.on("unhandledRejection", (reason) => {
    console.error("Unhandled rejection:", reason);
    void logMonitoringEvent({
      queryable: db,
      scope: "process",
      subsystem: "runtime",
      level: "error",
      code: "unhandled_rejection",
      source: "process.on(unhandledRejection)",
      message: String(reason?.message || reason || "Unhandled promise rejection"),
      details: {
        stack: String(reason?.stack || "").trim() || null,
      },
    });
  });
  process.on("uncaughtException", (error) => {
    console.error("Uncaught exception:", error);
    void logMonitoringEvent({
      queryable: db,
      scope: "process",
      subsystem: "runtime",
      level: "critical",
      code: "uncaught_exception",
      source: "process.on(uncaughtException)",
      message: String(error?.message || error || "Uncaught exception"),
      details: {
        stack: String(error?.stack || "").trim() || null,
      },
    });
  });
}

// ===================================
// MIDDLEWARE И КОНФИГУРАЦИЯ
// ===================================

ensureStorageLayout();
ensurePlaceholderAssets("http://localhost");

const DEFAULT_ALLOWED_ORIGINS = [
  "http://localhost:3000",
  "https://localhost:3000",
  "http://127.0.0.1:3000",
  "https://127.0.0.1:3000",
  "http://localhost:5173",
  "https://localhost:5173",
  "http://127.0.0.1:5173",
  "https://127.0.0.1:5173",
  "http://localhost:8080",
  "https://localhost:8080",
  "http://127.0.0.1:8080",
  "https://127.0.0.1:8080",
  "http://localhost",
  "https://localhost",
  "http://127.0.0.1",
  "https://127.0.0.1",
];

const NODE_ENV = String(process.env.NODE_ENV || "development")
  .toLowerCase()
  .trim();
const IS_PRODUCTION = NODE_ENV === "production";

function parseBooleanEnv(rawValue, fallback = false) {
  if (rawValue === undefined || rawValue === null || rawValue === "") {
    return fallback;
  }
  const normalized = String(rawValue).toLowerCase().trim();
  return ["1", "true", "yes", "on", "y"].includes(normalized);
}

const TRUST_PROXY_HOPS = Math.max(
  0,
  Number(
    process.env.TRUST_PROXY_HOPS ||
      (IS_PRODUCTION ? 1 : 0),
  ) || 0,
);
if (TRUST_PROXY_HOPS > 0) {
  app.set("trust proxy", TRUST_PROXY_HOPS);
}

const ENFORCE_HTTPS = parseBooleanEnv(
  process.env.ENFORCE_HTTPS,
  IS_PRODUCTION,
);
const BLOCK_DIRECT_BACKEND_PUBLIC_ACCESS = parseBooleanEnv(
  process.env.BLOCK_DIRECT_BACKEND_PUBLIC_ACCESS,
  IS_PRODUCTION,
);
const APK_DOWNLOAD_ANDROID_ONLY = parseBooleanEnv(
  process.env.APK_DOWNLOAD_ANDROID_ONLY,
  true,
);
const REQUEST_LOGGING_ENABLED = parseBooleanEnv(
  process.env.REQUEST_LOGGING,
  !IS_PRODUCTION,
);
const BIND_HOST = String(
  process.env.BIND_HOST || (IS_PRODUCTION ? "127.0.0.1" : "0.0.0.0"),
)
  .trim()
  .toLowerCase();

function normalizeIp(rawValue) {
  let ip = String(rawValue || "")
    .split(",")[0]
    .trim()
    .toLowerCase();
  if (ip.startsWith("::ffff:")) {
    ip = ip.slice("::ffff:".length);
  }
  return ip;
}

function isLoopbackIp(rawValue) {
  const ip = normalizeIp(rawValue);
  return ip === "127.0.0.1" || ip === "::1" || ip === "localhost";
}

function normalizeOrigin(raw) {
  const value = String(raw || "").trim();
  if (!value) return "";
  if (value === "*") return "*";
  try {
    return new URL(value).origin;
  } catch (_) {
    return "";
  }
}

function parseAllowedOrigins(raw) {
  const allowed = new Set();
  for (const candidate of DEFAULT_ALLOWED_ORIGINS) {
    const normalized = normalizeOrigin(candidate);
    if (normalized) allowed.add(normalized);
  }
  for (const candidate of String(raw || "").split(",")) {
    const trimmed = candidate.trim();
    if (!trimmed) continue;
    if (trimmed === "*") {
      allowed.clear();
      allowed.add("*");
      return allowed;
    }
    const normalized = normalizeOrigin(trimmed);
    if (normalized) allowed.add(normalized);
  }
  return allowed;
}

const allowedOrigins = parseAllowedOrigins(process.env.CORS_ORIGINS || "");
const allowAnyOrigin = allowedOrigins.has("*");

function isOriginAllowed(origin) {
  if (!origin) return true; // mobile/desktop clients without browser Origin
  if (allowAnyOrigin) return true;
  const isLocalDev =
    process.env.NODE_ENV !== "production" &&
    /^(https?:\/\/)?(localhost|127\.0\.0\.1)(:\d+)?$/i.test(origin);
  if (isLocalDev) return true;
  const normalized = normalizeOrigin(origin);
  if (!normalized) return false;
  return allowedOrigins.has(normalized);
}

function isAndroidUserAgent(req) {
  const userAgent = String(req.headers["user-agent"] || "")
    .toLowerCase()
    .trim();
  if (!userAgent) return false;
  return userAgent.includes("android");
}

function extractBearerToken(rawValue) {
  const auth = String(rawValue || "").trim();
  if (!auth) return "";
  if (/^bearer\s+/i.test(auth)) {
    return auth.replace(/^bearer\s+/i, "").trim();
  }
  return auth;
}

function sanitizeRequestPathForLog(req) {
  const method = String(req?.method || "").toUpperCase().trim();
  const rawUrl = String(req?.originalUrl || req?.url || "").trim();
  if (!rawUrl) return method ? `${method} /` : "/";
  const qIndex = rawUrl.indexOf("?");
  const pathOnly = qIndex >= 0 ? rawUrl.slice(0, qIndex) : rawUrl;
  if (!method) return pathOnly || "/";
  return `${method} ${pathOnly || "/"}`;
}

const corsOptions = {
  origin(origin, callback) {
    // For disallowed origins we return `false` instead of throwing, so server
    // does not leak internal 500 errors on preflight requests.
    callback(null, isOriginAllowed(origin));
  },
  credentials: true,
  methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
  allowedHeaders: [
    "Authorization",
    "Content-Type",
    "X-View-Role",
    "X-Tenant-Code",
  ],
  exposedHeaders: ["Content-Disposition"],
};

app.use(
  helmet({
    contentSecurityPolicy: false,
    crossOriginResourcePolicy: { policy: "cross-origin" },
    referrerPolicy: { policy: "no-referrer" },
    frameguard: { action: "deny" },
    hsts: IS_PRODUCTION
      ? {
          maxAge: 31536000,
          includeSubDomains: true,
          preload: false,
        }
      : false,
  }),
);
app.use(cors(corsOptions));
app.options("*", cors(corsOptions));
app.use(
  bodyParser.json({
    limit: String(process.env.JSON_BODY_LIMIT || "2mb").trim() || "2mb",
  }),
);
app.use(
  bodyParser.urlencoded({
    extended: true,
    limit: String(process.env.URLENCODED_BODY_LIMIT || "2mb").trim() || "2mb",
  }),
);

app.use((req, res, next) => {
  if (!BLOCK_DIRECT_BACKEND_PUBLIC_ACCESS) return next();
  const remoteIp = normalizeIp(req.socket?.remoteAddress || req.ip || "");
  if (isLoopbackIp(remoteIp)) return next();
  return res.status(403).json({
    ok: false,
    error: "Direct backend access is disabled",
  });
});

app.use((req, res, next) => {
  if (!ENFORCE_HTTPS) return next();
  const forwardedProto = String(req.headers["x-forwarded-proto"] || "")
    .split(",")[0]
    .toLowerCase()
    .trim();
  const remoteIp = normalizeIp(req.socket?.remoteAddress || req.ip || "");
  const trustedForwardedProto =
    forwardedProto === "https" && isLoopbackIp(remoteIp);
  const isSecure = req.secure === true || trustedForwardedProto;
  if (isSecure) return next();

  const host = String(req.headers.host || "").trim();
  if ((req.method === "GET" || req.method === "HEAD") && host) {
    return res.redirect(308, `https://${host}${req.originalUrl || req.url || "/"}`);
  }
  return res.status(426).json({
    ok: false,
    error: "HTTPS required",
  });
});

function placeholderAbsolutePathForPublicDir(publicDir) {
  if (publicDir === "products") {
    return path.join(uploadsRoot, "products", PRODUCT_PLACEHOLDER_NAME);
  }
  if (publicDir === "claims") {
    return path.join(uploadsRoot, "claims", PUBLIC_MEDIA_PLACEHOLDER_NAME);
  }
  return path.join(
    uploadsRoot,
    "chat_media",
    "images",
    GENERIC_MEDIA_PLACEHOLDER_NAME,
  );
}

for (const publicDir of ["products", "channels", "users", "claims"]) {
  const fullDir = path.join(uploadsRoot, publicDir);
  app.use(
    `/uploads/${publicDir}`,
    signedUploadGuard(publicDir),
    (req, res, next) => {
      const relativePath = decodeURIComponent(
        String(req.path || req.url || "").replace(/^\/+/, ""),
      ).replace(/\\/g, "/");
      const parts = relativePath.split("/").filter(Boolean);
      if (
        parts.length === 0 ||
        parts.some(
          (part) =>
            !/^[A-Za-z0-9._-]+$/.test(part) || part === "." || part === "..",
        )
      ) {
        return next();
      }
      const absoluteDir = path.resolve(fullDir);
      const absoluteFilePath = path.resolve(fullDir, ...parts);
      const withinDir =
        absoluteFilePath === absoluteDir ||
        absoluteFilePath.startsWith(`${absoluteDir}${path.sep}`);
      if (!withinDir) return next();
      if (fs.existsSync(absoluteFilePath)) return next();

      const placeholderPath = placeholderAbsolutePathForPublicDir(publicDir);
      if (!placeholderPath || !fs.existsSync(placeholderPath)) {
        return next();
      }

      res.setHeader("X-Content-Type-Options", "nosniff");
      res.setHeader("Cache-Control", "public, max-age=300");
      res.setHeader("X-Fenix-Missing-Upload", "1");
      return res.sendFile(placeholderPath);
    },
    express.static(fullDir, {
      index: false,
      fallthrough: false,
      maxAge: "365d",
      immutable: true,
      setHeaders(res, filePath) {
        res.setHeader("X-Content-Type-Options", "nosniff");
        const normalizedPath = String(filePath || "").replace(/\\/g, "/");
        if (normalizedPath.includes("/variants/")) {
          res.setHeader("Cache-Control", "public, max-age=31536000, immutable");
          return;
        }
        res.setHeader("Cache-Control", "public, max-age=31536000, immutable");
      },
    }),
  );
}

app.use("/downloads", (req, res, next) => {
  if (!APK_DOWNLOAD_ANDROID_ONLY) return next();
  if (isAndroidUserAgent(req)) return next();
  return res.status(403).json({
    ok: false,
    error: "APK download is allowed only from Android devices",
  });
});

app.use(
  "/downloads",
  express.static(downloadsRoot, {
    index: false,
    fallthrough: false,
    maxAge: "5m",
    immutable: false,
    setHeaders(res) {
      res.setHeader("X-Content-Type-Options", "nosniff");
      res.setHeader("Cache-Control", "private, max-age=300");
      res.setHeader("Content-Disposition", "attachment");
    },
  }),
);

app.use((req, res, next) => {
  const originalJson = res.json.bind(res);
  res.json = (payload) =>
    originalJson(rewriteSignedUploadsInPayload(payload, { req }));
  next();
});

function patchSocketEmittersWithSignedUploads(io) {
  const baseUrl = String(
    process.env.PUBLIC_BASE_URL || process.env.API_PUBLIC_BASE_URL || "",
  ).trim();
  const rewrite = (value) =>
    rewriteSignedUploadsInPayload(value, {
      baseUrl,
    });

  const maybeQueueWebPush = (rooms, eventName, args) => {
    if (eventName !== "chat:message") return;
    const normalizedRooms = Array.isArray(rooms) ? rooms : [];
    if (!normalizedRooms.length) return;
    const payload = args?.[0];
    if (!payload || typeof payload !== "object") return;
    setImmediate(() => {
      queueChatMessageWebPushForRooms({
        rooms: normalizedRooms,
        payload,
      }).catch((err) => {
        console.error("queueChatMessageWebPushForRooms error:", err);
      });
    });
  };

  const patchEmitter = (emitter, rooms = []) => {
    if (!emitter || emitter.__signedUploadsPatched === true) return emitter;
    if (typeof emitter.emit !== "function") return emitter;
    const originalEmit = emitter.emit.bind(emitter);
    emitter.emit = (event, ...args) => {
      const signedArgs = args.map(rewrite);
      const result = originalEmit(event, ...signedArgs);
      maybeQueueWebPush(rooms, event, signedArgs);
      return result;
    };
    Object.defineProperty(emitter, "__signedUploadsPatched", {
      value: true,
      enumerable: false,
      configurable: false,
      writable: false,
    });
    return emitter;
  };

  patchEmitter(io);

  const originalTo = io.to.bind(io);
  io.to = (...rooms) => patchEmitter(originalTo(...rooms), rooms);

  const originalIn = io.in.bind(io);
  io.in = (...rooms) => patchEmitter(originalIn(...rooms), rooms);

  const originalExcept = io.except.bind(io);
  io.except = (...rooms) => patchEmitter(originalExcept(...rooms), rooms);

  if (io.sockets) {
    patchEmitter(io.sockets);
  }
}

// Логирование входящих запросов и времени обработки
app.use((req, res, next) => {
  if (!REQUEST_LOGGING_ENABLED) return next();
  const start = Date.now();
  const requestLabel = sanitizeRequestPathForLog(req);
  console.log("SERVER REQ START →", requestLabel);
  res.on("finish", () => {
    const duration = Date.now() - start;
    console.log(`SERVER REQ END ← ${requestLabel} ${res.statusCode} ${duration}ms`);
  });
  next();
});

// Лимитер для маршрутов аутентифика��ии (защита от brute-force)
const authLimiter = rateLimit({
  windowMs: 2 * 1000,
  max: 6,
  message: { error: "Слишком быстро, чуть чуть подождите" },
  standardHeaders: true,
  legacyHeaders: false,
});

const globalApiLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: Number(process.env.RATE_LIMIT_GLOBAL_MAX || 240),
  message: { error: "Слишком много запросов. Попробуйте через минуту." },
  standardHeaders: true,
  legacyHeaders: false,
});

const heavyWriteLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: Number(process.env.RATE_LIMIT_HEAVY_MAX || 60),
  message: {
    error:
      "Слишком много тяжелых операций (upload/publish/delivery/support). Повторите позже.",
  },
  standardHeaders: true,
  legacyHeaders: false,
});

const writeMethods = new Set(["POST", "PUT", "PATCH", "DELETE"]);
const applyForWriteMethods = (limiter) => (req, res, next) => {
  if (!writeMethods.has(req.method)) return next();
  return limiter(req, res, next);
};

app.use("/api", globalApiLimiter);
app.use("/api/auth/register", authLimiter);
app.use("/api/auth/login", authLimiter);
app.use("/api/auth/password-reset", authLimiter);
app.use("/api/auth/magic-link", authLimiter);
app.use("/api/chats", applyForWriteMethods(heavyWriteLimiter));
app.use("/api/worker", applyForWriteMethods(heavyWriteLimiter));
app.use("/api/admin/delivery", applyForWriteMethods(heavyWriteLimiter));
app.use("/api/admin/ops", applyForWriteMethods(heavyWriteLimiter));
app.use("/api/delivery", applyForWriteMethods(heavyWriteLimiter));
app.use("/api/support", applyForWriteMethods(heavyWriteLimiter));

// ===================================
// РОУТЫ
// ===================================

// Setup роут (инициализация БД)
app.use("/api/setup", setupRouter);

// Auth роуты
app.use("/api/auth", authRouter);

// Остальные роуты
app.use("/api/phones", phonesRouter);
app.use("/api/profile/uploads-recovery", uploadsRecoveryRoutes);
app.use("/api/profile", [profileUpdateRoutes, profileRouter]);
app.use("/api/chats", chatsRouter);
app.use("/api/admin", adminRoutes);
app.use("/api/admin/ops", opsRoutes);
app.use("/api/admin/delivery", deliveryRoutes);
app.use("/api/delivery", deliveryRoutes);
app.use("/api/worker", workerRoutes);
app.use("/api/cart", cartRoutes);
app.use("/api/support", supportRoutes);
app.use("/api/app/update", appUpdateRoutes);
app.get("/download/android", (req, res) => {
  const query = req.originalUrl.includes('?')
    ? req.originalUrl.slice(req.originalUrl.indexOf('?'))
    : '';
  return res.redirect(302, `/api/app/update/download/android${query}`);
});
app.use("/api/web-push", webPushRoutes);
app.use("/api/notifications", notificationsRoutes);
app.use("/api/messenger", messengerRoutes);
app.use("/api/admin/notifications", adminNotificationsRoutes);
app.use("/api/creator/notifications", adminNotificationsRoutes);

const PORT = process.env.PORT || 3000;
const JWT_SECRET = String(process.env.JWT_SECRET || "").trim();

// ===================================
// HEALTH CHECK ENDPOINTS
// ===================================

// Базовый health check
app.get("/", (req, res) => {
  res.json({ ok: true, service: "ProjectPhoenix API" });
});

// Ping для проверки доступности
app.get("/ping", (req, res) => {
  res.json({ ok: true, timestamp: Date.now() });
});

// Детальный здоровье сервера
app.get("/health", async (req, res) => {
  try {
    // Проверяем подключение к БД
    await db.query("SELECT 1");
    res.json({
      ok: true,
      status: "healthy",
      database: "connected",
      timestamp: Date.now(),
    });
  } catch (err) {
    console.error("Health check error:", err);
    res.status(503).json({
      ok: false,
      status: "unhealthy",
      database: "disconnected",
      error: err.message,
    });
  }
});

// ===================================
// ЗАЩИЩЁННЫЕ РОУТЫ
// ===================================

// Пример защищённого роута — получение профиля
app.get("/api/user/profile", authMiddleware, async (req, res) => {
  try {
    const { id } = req.user;
    const result = await db.query(
      `SELECT u.id, u.email, u.name, u.role, u.created_at, p.phone
       FROM users u
       LEFT JOIN phones p ON p.user_id = u.id
       WHERE u.id = $1
       LIMIT 1`,
      [id],
    );
    const user = result.rows[0];
    if (!user) {
      return res.status(404).json({ error: "User not found" });
    }
    return res.json({ ok: true, user });
  } catch (err) {
    console.error("Profile error:", err);
    return res.status(500).json({ error: "Internal server error" });
  }
});

// ===================================
// ERROR HANDLERS
// ===================================

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: "Not found", path: req.path });
});

// Глобальный обработчик ошибок (ДОЛЖЕН быть последним!)
app.use((err, req, res, next) => {
  console.error("Unhandled error:", err);
  const status = err.status || err.statusCode || 500;
  void logMonitoringEvent({
    queryable: db,
    tenantId: req.user?.tenant_id || null,
    userId: req.user?.id || null,
    scope: "http",
    level: status >= 500 ? "error" : "warn",
    code: "unhandled_http_error",
    source: `${req.method} ${req.path}`,
    message: err?.message || "Unhandled server error",
    details: {
      status,
      method: req.method,
      path: req.path,
      stack:
        process.env.NODE_ENV === "development"
          ? String(err?.stack || "")
          : undefined,
    },
  });
  res.status(status).json({
    error: "Server error",
    message: err.message,
    ...(process.env.NODE_ENV === "development" && { stack: err.stack }),
  });
});

// ===================================
// ФУНКЦИИ ИНИЦИАЛИЗАЦИИ
// ===================================

/**
 * Помечает пользователя с email CREATOR_EMAIL как 'creator' при старте
 */
async function ensureCreator() {
  try {
    const creatorEmail = process.env.CREATOR_EMAIL || "zerotwo02166@gmail.com";
    console.log(`Checking for creator: ${creatorEmail}`);

    const res = await db.query("SELECT id, role FROM users WHERE email = $1", [
      creatorEmail,
    ]);

    if (res.rowCount === 1 && res.rows[0].role !== "creator") {
      await db.query("UPDATE users SET role = $1 WHERE id = $2", [
        "creator",
        res.rows[0].id,
      ]);
      console.log(`✅ Marked user ${creatorEmail} as creator`);
    } else if (res.rowCount === 0) {
      console.log(`⚠️ Creator user not found: ${creatorEmail}`);
    }
  } catch (err) {
    console.error("ensureCreator error:", err);
  }
}

async function canUserAccessChat(user, chatId) {
  const userId = user?.id;
  const tenantId = user?.tenant_id || null;
  const rawRole = String(user?.role || "client")
    .toLowerCase()
    .trim();
  const role = rawRole === "tenant" ? "admin" : rawRole;
  if (!userId || !chatId) return false;

  const chatQ = await db.query(
    `SELECT id, title, type, settings
     FROM chats
     WHERE id = $1
       AND ($2::uuid IS NULL OR tenant_id = $2::uuid)`,
    [chatId, tenantId],
  );
  if (chatQ.rowCount === 0) return false;

  const chat = chatQ.rows[0];
  const settings =
    chat.settings &&
    typeof chat.settings === "object" &&
    !Array.isArray(chat.settings)
      ? chat.settings
      : {};
  if (chat.type === "private") {
    const directRequestStatus = String(settings.direct_request_status || "")
      .toLowerCase()
      .trim();
    if (directRequestStatus === "declined") {
      return false;
    }
  }
  if (chat.type === "channel") {
    const blacklistedUserIds = Array.isArray(settings.blacklisted_user_ids)
      ? settings.blacklisted_user_ids
          .map((v) => String(v || "").trim())
          .filter(Boolean)
      : [];
    if (
      blacklistedUserIds.includes(String(userId)) &&
      role !== "admin" &&
      role !== "creator"
    ) {
      return false;
    }
    const isBugReportsByTitle =
      String(chat.title || "")
        .toLowerCase()
        .trim() === "баг-репорты";
    const kind = String(settings.kind || "")
      .toLowerCase()
      .trim();
    const systemKey = String(settings.system_key || "")
      .toLowerCase()
      .trim();
    const isReservedOrders =
      kind === "reserved_orders" ||
      systemKey === "reserved_orders" ||
      String(chat.title || "")
        .toLowerCase()
        .trim() === "забронированный товар";
    if (isReservedOrders && role === "client") {
      return false;
    }

    const adminOnly =
      settings.admin_only === true ||
      kind === "bug_reports" ||
      isBugReportsByTitle;
    if (adminOnly) {
      return role === "admin" || role === "tenant" || role === "creator";
    }
    const visibility =
      String(settings.visibility || "public").toLowerCase() === "private"
        ? "private"
        : "public";
    if (visibility === "public") return true;
    if (role === "worker" || role === "admin" || role === "creator")
      return true;
  }

  const hasMembers =
    (
      await db.query("SELECT 1 FROM chat_members WHERE chat_id = $1 LIMIT 1", [
        chatId,
      ])
    ).rowCount > 0;
  if (!hasMembers) return true;

  const memberQ = await db.query(
    "SELECT 1 FROM chat_members WHERE chat_id = $1 AND user_id = $2",
    [chatId, userId],
  );
  return memberQ.rowCount > 0;
}

async function canEmitChatActivity(user, chatId) {
  const userId = user?.id;
  const tenantId = user?.tenant_id || null;
  if (!userId || !chatId) return false;
  const chatQ = await db.query(
    `SELECT id, type, settings
     FROM chats
     WHERE id = $1
       AND ($2::uuid IS NULL OR tenant_id = $2::uuid)
     LIMIT 1`,
    [chatId, tenantId],
  );
  if (chatQ.rowCount === 0) return false;
  const chat = chatQ.rows[0];
  const settings =
    chat.settings &&
    typeof chat.settings === "object" &&
    !Array.isArray(chat.settings)
      ? chat.settings
      : {};
  const kind = String(settings.kind || "").toLowerCase().trim();
  if (chat.type !== "private") return false;
  if (kind !== "direct_message") return false;
  if (settings.saved_messages === true) return false;
  return canUserAccessChat(user, chatId);
}

// ===================================
// SERVER STARTUP
// ===================================

/**
 * Запуск сервера в async IIFE
 */
(async () => {
  try {
    console.log("🚀 Starting server initialization...");

    // Автоподготовка БД/миграций/системных каналов без ручных команд.
    const bootstrap = await bootstrapDatabase();
    console.log(
      `✅ DB bootstrap: created=${bootstrap.dbCreated}, applied=${bootstrap.applied.length}, main_channel=${bootstrap.systemChannels.main_channel_id}, reserved_channel=${bootstrap.systemChannels.reserved_channel_id}`,
    );
    await refreshMediaAssetCache();

    // Помечаем creator (если пользователь с таким email существует)
    await ensureCreator();

    // Создаём HTTP сервер
    const server = http.createServer(app);

    // Инициализируем Socket.io
    const io = new Server(server, {
      cors: {
        origin(origin, callback) {
          if (isOriginAllowed(origin)) {
            callback(null, true);
            return;
          }
          callback(new Error("Socket origin is not allowed"));
        },
        methods: ["GET", "POST"],
        credentials: true,
      },
      allowEIO3: true,
      transports: ["websocket", "polling"],
      pingInterval: 25000,
      pingTimeout: 60000,
      connectTimeout: 45000,
      connectionStateRecovery: {
        maxDisconnectionDuration: 2 * 60 * 1000,
        skipMiddlewares: true,
      },
    });

    // Делаем io доступным в express
    app.set("io", io);
    app.set("realtimeDiagnostics", realtimeDiagnostics);
    global.__projectPhoenixSocketIo = io;
    patchSocketEmittersWithSignedUploads(io);
    console.log("✅ Socket.io initialized");
    if (typeof deliveryRoutes.startBackgroundTasks === "function") {
      deliveryRoutes.startBackgroundTasks(io);
    }

    // ===================================
    // SOCKET.IO MIDDLEWARE И HANDLERS
    // ===================================

    /**
     * Аутентификация сокета по JWT токену
     */
    io.use(async (socket, next) => {
      try {
        const token =
          String(socket.handshake.auth?.token || "").trim() ||
          String(socket.handshake.query?.token || "").trim() ||
          extractBearerToken(
            socket.handshake.headers?.authorization ||
              socket.handshake.headers?.Authorization,
          );
        if (!token) return next(new Error("Unauthorized"));

        const context = await resolveAuthContextFromToken(
          token,
          socket.handshake.auth?.view_role || "",
          {
            requestedTenantCode:
              socket.handshake.auth?.tenant_code ||
              socket.handshake.query?.tenant_code ||
              socket.handshake.headers?.['x-tenant-code'] ||
              '',
          },
        );
        if (!context.ok || !context.user?.id) {
          const authError = context.error || "Unauthorized";
          realtimeDiagnostics.markAuthDenied(authError);
          void logMonitoringEvent({
            queryable: db,
            scope: "socket",
            subsystem: "realtime",
            level: "warn",
            code: "socket_auth_denied",
            source: "socket.io",
            message: String(authError),
            details: {
              socket_id: socket.id,
              requested_tenant_code:
                socket.handshake.auth?.tenant_code ||
                socket.handshake.query?.tenant_code ||
                "",
            },
          });
          if (
            String(authError).toLowerCase().includes("сессия истекла") ||
            String(authError).toLowerCase().includes("revoked")
          ) {
            console.log(
              `Socket ${socket.id} stale session rejected: ${authError}`,
            );
          } else {
            console.warn(`Socket ${socket.id} auth denied:`, authError);
          }
          return next(new Error(context.error || "Unauthorized"));
        }
        socket.user = context.user;
        socket.tenantScope = context.tenantScope || null;
        console.log(
          `Socket ${socket.id} authenticated as user ${context.user.id} (role=${context.user.role})`,
        );
        return next();
      } catch (err) {
        console.error("io.use middleware error:", err);
        return next(new Error("Unauthorized"));
      }
    });

    /**
     * Обработчики подключений сокета
     */
    io.on("connection", (socket) => {
      const sid = socket.id;
      const uid = socket.user?.id;
      const runInSocketTenantContext = (fn) =>
        db.runWithTenantRow(socket.tenantScope || null, fn);
      realtimeDiagnostics.markConnection({ recovered: socket.recovered === true });
      console.log(`📡 Socket connected: ${sid} (user=${uid || "anonymous"})`);

      if (uid) {
        socket.join(`user:${uid}`);
        console.log(`Socket ${sid} joined user:${uid}`);
      }
      const scopedTenantRoom = tenantRoom(socket.user?.tenant_id || null);
      if (scopedTenantRoom) {
        socket.join(scopedTenantRoom);
        console.log(`Socket ${sid} joined ${scopedTenantRoom}`);
      }

      // Для тестов/мультисессии (например, creator + client view на одном устройстве)
      // разрешаем несколько активных сокетов одного пользователя.

      // Присоединение к комнате чата
      socket.on("join_chat", async (chatId) => {
        const joinStartedAt = Date.now();
        realtimeDiagnostics.markJoinRequest();
        try {
          await runInSocketTenantContext(async () => {
            if (!chatId) {
              console.warn(`Socket ${sid}: join_chat called with empty chatId`);
              realtimeDiagnostics.markJoinDenied();
              return;
            }

            if (!uid) {
              console.warn(`Socket ${sid}: unauthorized join_chat`);
              realtimeDiagnostics.markJoinDenied();
              socket.emit("chat:error", { error: "Unauthorized" });
              return;
            }

            const allowed = await canUserAccessChat(socket.user, chatId);
            if (!allowed) {
              console.warn(
                `Socket ${sid}: user ${uid} has no access to chat ${chatId}`,
              );
              realtimeDiagnostics.markJoinDenied();
              socket.emit("chat:error", { error: "Access denied" });
              return;
            }

            // ✅ ИСПРАВЛЕНИЕ: Сначала выйди из всех чатов, потом присоединись к новому
            // Получи текущие комнаты сокета
            const currentRooms = socket.rooms;

            // Выйди из всех chat:* комнат
            for (const room of currentRooms) {
              if (room.startsWith("chat:")) {
                socket.leave(room);
                console.log(`Socket ${sid} left room ${room}`);
              }
            }

            // Присоединись к новой комнате
            socket.join(`chat:${chatId}`);
            realtimeDiagnostics.markJoinSuccess(Date.now() - joinStartedAt);
            console.log(`Socket ${sid} joined chat:${chatId}`);
          });
        } catch (err) {
          realtimeDiagnostics.markJoinDenied();
          console.error(`Socket ${sid} join_chat error:`, err);
        }
      });

      // Выход из комнаты чата
      socket.on("leave_chat", (chatId) => {
        try {
          if (!chatId) {
            console.warn(`Socket ${sid}: leave_chat called with empty chatId`);
            return;
          }
          socket.leave(`chat:${chatId}`);
          console.log(`Socket ${sid} left chat:${chatId}`);
        } catch (err) {
          console.error(`Socket ${sid} leave_chat error:`, err);
        }
      });

      const relayChatActivity = (eventName) => {
        socket.on(eventName, async (payload) => {
          try {
            await runInSocketTenantContext(async () => {
              const map =
                payload && typeof payload === "object" && !Array.isArray(payload)
                  ? payload
                  : {};
              const chatId = String(map.chat_id || map.chatId || "").trim();
              if (!chatId || !uid) return;
              const allowed = await canEmitChatActivity(socket.user, chatId);
              if (!allowed) return;
              socket.to(`chat:${chatId}`).emit(eventName, {
                chat_id: chatId,
                chatId,
                user_id: uid,
                userId: uid,
                ttl_ms: 4500,
                sent_at: new Date().toISOString(),
              });
            });
          } catch (err) {
            console.error(`Socket ${sid} ${eventName} error:`, err);
          }
        });
      };

      relayChatActivity("chat:typing");
      relayChatActivity("chat:recording_voice");
      relayChatActivity("chat:recording_video");

      // ✅ ИСПРАВЛЕНИЕ: Обработка отключения с логированием
      socket.on("disconnect", (reason) => {
        realtimeDiagnostics.markDisconnect(reason);
        if (reason && reason !== "client namespace disconnect") {
          void logMonitoringEvent({
            queryable: db,
            tenantId: socket.user?.tenant_id || null,
            userId: socket.user?.id || null,
            scope: "socket",
            subsystem: "realtime",
            level:
              reason === "ping timeout" || reason === "transport close"
                ? "warn"
                : "info",
            code: "socket_disconnected",
            source: "socket.on(disconnect)",
            message: `Socket disconnected: ${reason}`,
            details: {
              socket_id: sid,
              recovered: socket.recovered === true,
            },
            userRole: socket.user?.role || null,
            tenantCode: socket.user?.tenant_code || null,
          });
        }
        console.log(
          `📡 Socket disconnected: ${sid} (user=${uid || "anonymous"}, reason: ${reason})`,
        );

        // Все комнаты автоматически очищаются при disconnect
        const roomsBeforeDisconnect = Array.from(socket.rooms);
        console.log(`   Rooms cleared: ${roomsBeforeDisconnect.join(", ")}`);
      });

      // Обработчик ошибок сокета
      socket.on("error", (error) => {
        console.error(`Socket ${sid} error:`, error);
        void logMonitoringEvent({
          queryable: db,
          tenantId: socket.user?.tenant_id || null,
          userId: socket.user?.id || null,
          scope: "socket",
          level: "error",
          code: "socket_runtime_error",
          source: "socket.on(error)",
          message: String(error?.message || error || "Socket runtime error"),
          details: {
            socket_id: sid,
          },
        });
      });

      // ✅ Логирование всех событий для отладки (опционально)
      socket.onAny((eventName, ...args) => {
        if (!["ping", "pong"].includes(eventName)) {
          console.log(
            `Socket ${sid} event: ${eventName}`,
            args.length > 0 ? args[0] : "",
          );
        }
      });
    });

    // Запуск сервера
    server.on("error", (err) => {
      if (err?.code === "EADDRINUSE") {
        console.error(
          `❌ Порт ${PORT} уже занят. Остановите предыдущий сервер или запустите с другим PORT.`,
        );
        process.exit(1);
      }
      console.error("❌ HTTP server error:", err);
      process.exit(1);
    });

    server.listen(PORT, BIND_HOST, () => {
      console.log(`\n✅ Server listening on http://${BIND_HOST}:${PORT}`);
      console.log(`📝 Environment: ${process.env.NODE_ENV || "development"}`);
      console.log(
        `🔐 JWT Secret: ${JWT_SECRET ? "✅ Configured" : "⚠️ Not configured"}`,
      );
      console.log(
        `🛡️ Security: trust_proxy=${TRUST_PROXY_HOPS}, enforce_https=${ENFORCE_HTTPS}`,
      );
      void runMessageEncryptionBackfill({ logger: console }).catch((err) => {
        console.error("message encryption backfill startup error:", err);
      });
      setInterval(() => {
        void runNotificationDigestSweep().catch((err) => {
          console.error("notification digest sweep error:", err);
        });
      }, 5 * 60 * 1000);
      void runNotificationDigestSweep().catch((err) => {
        console.error("notification digest startup sweep error:", err);
      });
      console.log("\n");
    });
  } catch (err) {
    console.error("❌ Failed to start server:", err);
    process.exit(1);
  }
})();

// Graceful shutdown
process.on("SIGTERM", () => {
  console.log("SIGTERM received, shutting down gracefully...");
  process.exit(0);
});

process.on("SIGINT", () => {
  console.log("SIGINT received, shutting down gracefully...");
  process.exit(0);
});
