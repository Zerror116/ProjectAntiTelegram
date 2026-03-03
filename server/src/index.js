// server/src/index.js
// Главный файл Express приложения с Socket.io

require("dotenv").config();
const express = require("express");
const http = require("http");
const { Server } = require("socket.io");
const fs = require("fs");
const path = require("path");
const cors = require("cors");
const bodyParser = require("body-parser");
const bcrypt = require("bcryptjs");
const jwt = require("jsonwebtoken");
const rateLimit = require("express-rate-limit");
const validator = require("validator");

const db = require("./db");

// ✅ Сначала создаём app, потом использу��м его
const app = express();

// Импортируем роуты и middleware ПОСЛЕ создания app
const profileUpdateRoutes = require("./routes/profileUpdate");
const setupRouter = require("./routes/setup");
const phonesRouter = require("./routes/phones");
const chatsRouter = require("./routes/chats");
const profileRouter = require("./routes/profile");
const authRouter = require("./routes/auth");
const adminRoutes = require("./routes/admin");
const deliveryRoutes = require("./routes/delivery");
const workerRoutes = require("./routes/worker");
const cartRoutes = require("./routes/cart");
const supportRoutes = require("./routes/support");
const { authMiddleware } = require("./utils/auth");
const { bootstrapDatabase } = require("./utils/bootstrap");

// ===================================
// MIDDLEWARE И КОНФИГУРАЦИЯ
// ===================================

// Общие middleware
const uploadsRoot = path.resolve(__dirname, "..", "uploads");
fs.mkdirSync(path.join(uploadsRoot, "products"), { recursive: true });

app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use("/uploads", express.static(uploadsRoot));

// Логирование входящих запросов и времени обработки
app.use((req, res, next) => {
  const start = Date.now();
  console.log("SERVER REQ START →", req.method, req.url);
  res.on("finish", () => {
    const duration = Date.now() - start;
    console.log(
      `SERVER REQ END ← ${req.method} ${req.url} ${res.statusCode} ${duration}ms`,
    );
  });
  next();
});

// Лимитер для маршрутов аутентифика��ии (защита от brute-force)
const authLimiter = rateLimit({
  windowMs: 2 * 1000, // 2 секунды
  max: 6, // максимум 6 запросов в окне
  message: { error: "Слишком быстро, чуть чуть подождите" },
  standardHeaders: true,
  legacyHeaders: false,
});

app.use("/api/auth/register", authLimiter);
app.use("/api/auth/login", authLimiter);

// ===================================
// РОУТЫ
// ===================================

// Setup роут (инициализация БД)
app.use("/api/setup", setupRouter);

// Auth роуты
app.use("/api/auth", authRouter);

// Остальные роуты
app.use("/api/phones", phonesRouter);
app.use("/api/profile", [profileUpdateRoutes, profileRouter]);
app.use("/api/chats", chatsRouter);
app.use("/api/admin", adminRoutes);
app.use("/api/admin/delivery", deliveryRoutes);
app.use("/api/delivery", deliveryRoutes);
app.use("/api/worker", workerRoutes);
app.use("/api/cart", cartRoutes);
app.use("/api/support", supportRoutes);

// ===================================
// КОНФИГУРАЦИЯ И УТИЛИТЫ
// ===================================

const PORT = process.env.PORT || 3000;
const JWT_SECRET = process.env.JWT_SECRET || "change_me_long_secret";
const SALT_ROUNDS = parseInt(process.env.SALT_ROUNDS || "10", 10);

/**
 * Подписывает JWT токен
 */
function signToken(payload) {
  return jwt.sign(payload, JWT_SECRET, { expiresIn: "7d" });
}

/**
 * Ищет пользователя по email
 */
async function findUserByEmail(email) {
  try {
    const res = await db.query(
      "SELECT id, email, password_hash FROM users WHERE email = $1",
      [email],
    );
    return res.rows[0] || null;
  } catch (err) {
    console.error("findUserByEmail error:", err);
    return null;
  }
}

// ===================================
// HEALTH CHECK ENDPOINTS
// ===================================

// Базовый health check
app.get("/", (req, res) => {
  res.json({ ok: true, service: "ProjectAntiTelegram API" });
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
  const role = String(user?.role || "client")
    .toLowerCase()
    .trim();
  if (!userId || !chatId) return false;

  const chatQ = await db.query(
    "SELECT id, title, type, settings FROM chats WHERE id = $1",
    [chatId],
  );
  if (chatQ.rowCount === 0) return false;

  const chat = chatQ.rows[0];
  if (chat.type === "channel") {
    const settings =
      chat.settings &&
      typeof chat.settings === "object" &&
      !Array.isArray(chat.settings)
      ? chat.settings
      : {};
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
      return role === "admin" || role === "creator";
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

    // Помечаем creator (если пользователь с таким email существует)
    await ensureCreator();

    // Создаём HTTP сервер
    const server = http.createServer(app);

    // Инициализируем Socket.io
    const io = new Server(server, {
      cors: {
        origin: "*",
        methods: ["GET", "POST"],
        credentials: false,
      },
      transports: ["websocket", "polling"],
    });

    // Делаем io доступным в express
    app.set("io", io);
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
    io.use((socket, next) => {
      try {
        const token =
          socket.handshake.auth?.token || socket.handshake.query?.token;
        if (!token) return next(new Error("Unauthorized"));

        try {
          const payload = jwt.verify(token, JWT_SECRET);
          const userId = payload.id || payload.userId || payload.sub;
          if (!userId) return next(new Error("Unauthorized"));
          const baseRole = String(payload.role || "client")
            .toLowerCase()
            .trim();
          const requestedViewRole = String(
            socket.handshake.auth?.view_role || "",
          )
            .toLowerCase()
            .trim();
          const allowedViewRoles = new Set([
            "client",
            "worker",
            "admin",
            "creator",
          ]);
          const effectiveRole =
            baseRole === "creator" &&
            allowedViewRoles.has(requestedViewRole) &&
            requestedViewRole
              ? requestedViewRole
              : baseRole;
          socket.user = {
            ...payload,
            id: userId,
            role: effectiveRole,
            base_role: baseRole,
            effective_role: effectiveRole,
            view_role: effectiveRole !== baseRole ? effectiveRole : null,
          };
          console.log(
            `Socket ${socket.id} authenticated as user ${payload.id} (role=${effectiveRole})`,
          );
        } catch (err) {
          console.warn(
            `Socket ${socket.id} token verification failed:`,
            err.message,
          );
          return next(new Error("Unauthorized"));
        }
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
      console.log(`📡 Socket connected: ${sid} (user=${uid || "anonymous"})`);

      if (uid) {
        socket.join(`user:${uid}`);
        console.log(`Socket ${sid} joined user:${uid}`);
      }

      // ✅ ИСПРАВЛЕНИЕ: Если юзер залогинился, очисти его старые сокеты
      if (uid) {
        // Получи все сокеты этого юзера
        const userSockets = io.sockets.sockets;
        let socketCount = 0;

        for (const [existingSid, existingSocket] of userSockets) {
          if (existingSocket.user?.id === uid && existingSid !== sid) {
            console.log(
              `🔌 Disconnecting old socket ${existingSid} for user ${uid}`,
            );
            existingSocket.disconnect(true); // true = отправи клиенту disconnect событие
            socketCount++;
          }
        }

        if (socketCount > 0) {
          console.log(
            `✅ Cleaned up ${socketCount} old socket(s) for user ${uid}`,
          );
        }
      }

      // Присоединение к комнате чата
      socket.on("join_chat", async (chatId) => {
        try {
          if (!chatId) {
            console.warn(`Socket ${sid}: join_chat called with empty chatId`);
            return;
          }

          if (!uid) {
            console.warn(`Socket ${sid}: unauthorized join_chat`);
            socket.emit("chat:error", { error: "Unauthorized" });
            return;
          }

          const allowed = await canUserAccessChat(socket.user, chatId);
          if (!allowed) {
            console.warn(
              `Socket ${sid}: user ${uid} has no access to chat ${chatId}`,
            );
            socket.emit("chat:error", { error: "Access denied" });
            return;
          }

          // ✅ ИСПРАВЛЕНИЕ: Сначала выйди из всех чатов, потом присоединись к новому
          // Получи текущие ком��аты сокета
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
          console.log(`Socket ${sid} joined chat:${chatId}`);
        } catch (err) {
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

      // ✅ ИСПРАВЛЕНИЕ: Обработка отключения с логированием
      socket.on("disconnect", (reason) => {
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
    server.listen(PORT, "0.0.0.0", () => {
      console.log(`\n✅ Server listening on http://0.0.0.0:${PORT}`);
      console.log(`📝 Environment: ${process.env.NODE_ENV || "development"}`);
      console.log(
        `🔐 JWT Secret: ${JWT_SECRET === "change_me_long_secret" ? "⚠️ DEFAULT (CHANGE ME!)" : "✅ Custom"}`,
      );
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
