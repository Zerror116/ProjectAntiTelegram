// server/src/index.js
// Главный файл Express приложения с Socket.io

require('dotenv').config();
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const bodyParser = require('body-parser');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const rateLimit = require('express-rate-limit');
const validator = require('validator');

const db = require('./db');

// ✅ Сначала создаём app, потом использу��м его
const app = express();

// Импортируем роуты и middleware ПОСЛЕ создания app
const profileUpdateRoutes = require('./routes/profileUpdate');
const setupRouter = require('./routes/setup');
const phonesRouter = require('./routes/phones');
const chatsRouter = require('./routes/chats');
const profileRouter = require('./routes/profile');
const authRouter = require('./routes/auth');
const adminRoutes = require('./routes/admin');
const { authMiddleware } = require('./utils/auth');

// ===================================
// MIDDLEWARE И КОНФИГУРАЦИЯ
// ===================================

// Общие middleware
app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));

// Логирование входящих запросов и времени обработки
app.use((req, res, next) => {
  const start = Date.now();
  console.log('SERVER REQ START →', req.method, req.url);
  res.on('finish', () => {
    const duration = Date.now() - start;
    console.log(`SERVER REQ END ← ${req.method} ${req.url} ${res.statusCode} ${duration}ms`);
  });
  next();
});

// Лимитер для маршрутов аутентифика��ии (защита от brute-force)
const authLimiter = rateLimit({
  windowMs: 2 * 1000,      // 2 секунды
  max: 6,                   // максимум 6 запросов в окне
  message: { error: 'Слишком быстро, чуть чуть подождите' },
  standardHeaders: true,
  legacyHeaders: false,
});

app.use('/api/auth/register', authLimiter);
app.use('/api/auth/login', authLimiter);

// ===================================
// РОУТЫ
// ===================================

// Setup роут (инициализация БД)
app.use('/api/setup', setupRouter);

// Auth роуты
app.use('/api/auth', authRouter);

// Остальные роуты
app.use('/api/phones', phonesRouter);
app.use('/api/profile', [profileUpdateRoutes, profileRouter]);
app.use('/api/chats', chatsRouter);
app.use('/api/admin', adminRoutes);

// ===================================
// КОНФИГУРАЦИЯ И УТИЛИТЫ
// ===================================

const PORT = process.env.PORT || 3000;
const JWT_SECRET = process.env.JWT_SECRET || 'change_me_long_secret';
const SALT_ROUNDS = parseInt(process.env.SALT_ROUNDS || '10', 10);

/**
 * Подписывает JWT токен
 */
function signToken(payload) {
  return jwt.sign(payload, JWT_SECRET, { expiresIn: '7d' });
}

/**
 * Ищет пользователя по email
 */
async function findUserByEmail(email) {
  try {
    const res = await db.query(
      'SELECT id, email, password_hash FROM users WHERE email = $1',
      [email]
    );
    return res.rows[0] || null;
  } catch (err) {
    console.error('findUserByEmail error:', err);
    return null;
  }
}

// ===================================
// HEALTH CHECK ENDPOINTS
// ===================================

// Базовый health check
app.get('/', (req, res) => {
  res.json({ ok: true, service: 'ProjectAntiTelegram API' });
});

// Ping для проверки доступности
app.get('/ping', (req, res) => {
  res.json({ ok: true, timestamp: Date.now() });
});

// Детальный здоровье сервера
app.get('/health', async (req, res) => {
  try {
    // Проверяем подключение к БД
    await db.query('SELECT 1');
    res.json({
      ok: true,
      status: 'healthy',
      database: 'connected',
      timestamp: Date.now()
    });
  } catch (err) {
    console.error('Health check error:', err);
    res.status(503).json({
      ok: false,
      status: 'unhealthy',
      database: 'disconnected',
      error: err.message
    });
  }
});

// ===================================
// ЗАЩИЩЁННЫЕ РОУТЫ
// ===================================

// Пример защищённого роута — получение профиля
app.get('/api/user/profile', authMiddleware, async (req, res) => {
  try {
    const { id } = req.user;
    const result = await db.query(
      'SELECT id, email, name, phone, role, created_at FROM users WHERE id = $1',
      [id]
    );
    const user = result.rows[0];
    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }
    return res.json({ ok: true, user });
  } catch (err) {
    console.error('Profile error:', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
});

// ===================================
// ERROR HANDLERS
// ===================================

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not found', path: req.path });
});

// Глобальный обработчик ошибок (ДОЛЖЕН быть последним!)
app.use((err, req, res, next) => {
  console.error('Unhandled error:', err);
  const status = err.status || err.statusCode || 500;
  res.status(status).json({
    error: 'Server error',
    message: err.message,
    ...(process.env.NODE_ENV === 'development' && { stack: err.stack })
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
    const creatorEmail = process.env.CREATOR_EMAIL || 'zerotwo02166@gmail.com';
    console.log(`Checking for creator: ${creatorEmail}`);

    const res = await db.query(
      'SELECT id, role FROM users WHERE email = $1',
      [creatorEmail]
    );

    if (res.rowCount === 1 && res.rows[0].role !== 'creator') {
      await db.query(
        'UPDATE users SET role = $1 WHERE id = $2',
        ['creator', res.rows[0].id]
      );
      console.log(`✅ Marked user ${creatorEmail} as creator`);
    } else if (res.rowCount === 0) {
      console.log(`⚠️ Creator user not found: ${creatorEmail}`);
    }
  } catch (err) {
    console.error('ensureCreator error:', err);
  }
}

// ===================================
// SERVER STARTUP
// ===================================

/**
 * Запуск сервера в async IIFE
 */
(async () => {
  try {
    console.log('🚀 Starting server initialization...');

    // Помечаем creator (если пользователь с таким email существует)
    await ensureCreator();

    // Создаём HTTP сервер
    const server = http.createServer(app);

    // Инициализируем Socket.io
    const io = new Server(server, {
      cors: {
        origin: '*',
        methods: ['GET', 'POST'],
        credentials: false,
      },
      transports: ['websocket', 'polling'],
    });

    // Делаем io доступным в express
    app.set('io', io);
    console.log('✅ Socket.io initialized');

    // ===================================
    // SOCKET.IO MIDDLEWARE И HANDLERS
    // ===================================

    /**
     * Аутентификация сокета по JWT токену
     */
    io.use((socket, next) => {
      try {
        const token = socket.handshake.auth?.token || socket.handshake.query?.token;
        if (!token) {
          console.log(`Socket ${socket.id} connected without token (anonymous)`);
          return next(); // разрешаем подключение без токена
        }

        try {
          const payload = jwt.verify(token, JWT_SECRET);
          socket.user = payload; // { id, email, role, ... }
          console.log(`Socket ${socket.id} authenticated as user ${payload.id}`);
        } catch (err) {
          console.warn(`Socket ${socket.id} token verification failed:`, err.message);
          // Разрешаем подключение, но без user info
        }
        return next();
      } catch (err) {
        console.error('io.use middleware error:', err);
        return next();
      }
    });

    /**
     * Обработчики подключений сокета
     */
    io.on('connection', (socket) => {
      const sid = socket.id;
      const uid = socket.user?.id;
      console.log(`📡 Socket connected: ${sid} (user=${uid || 'anonymous'})`);

      // ✅ ИСПРАВЛЕНИЕ: Если юзер залогинился, очисти его старые сокеты
      if (uid) {
        // Получи все сокеты этого юзера
        const userSockets = io.sockets.sockets;
        let socketCount = 0;

        for (const [existingSid, existingSocket] of userSockets) {
          if (existingSocket.user?.id === uid && existingSid !== sid) {
            console.log(`🔌 Disconnecting old socket ${existingSid} for user ${uid}`);
            existingSocket.disconnect(true); // true = отправи клиенту disconnect событие
            socketCount++;
          }
        }

        if (socketCount > 0) {
          console.log(`✅ Cleaned up ${socketCount} old socket(s) for user ${uid}`);
        }
      }

      // Присоединение к комнате чата
      socket.on('join_chat', (chatId) => {
        try {
          if (!chatId) {
            console.warn(`Socket ${sid}: join_chat called with empty chatId`);
            return;
          }

          // ✅ ИСПРАВЛЕНИЕ: Сначала выйди из всех чатов, потом присоединись к новому
          // Получи текущие ком��аты сокета
          const currentRooms = socket.rooms;

          // Выйди из всех chat:* комнат
          for (const room of currentRooms) {
            if (room.startsWith('chat:')) {
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
      socket.on('leave_chat', (chatId) => {
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
      socket.on('disconnect', (reason) => {
        console.log(`📡 Socket disconnected: ${sid} (user=${uid || 'anonymous'}, reason: ${reason})`);

        // Все комнаты автоматически очищаются при disconnect
        const roomsBeforeDisconnect = Array.from(socket.rooms);
        console.log(`   Rooms cleared: ${roomsBeforeDisconnect.join(', ')}`);
      });

      // Обработчик ошибок сокета
      socket.on('error', (error) => {
        console.error(`Socket ${sid} error:`, error);
      });

      // ✅ Логирование всех событий для отладки (опционально)
      socket.onAny((eventName, ...args) => {
        if (!['ping', 'pong'].includes(eventName)) {
          console.log(`Socket ${sid} event: ${eventName}`, args.length > 0 ? args[0] : '');
        }
      });
    });

    // Запуск сервера
    server.listen(PORT, '0.0.0.0', () => {
      console.log(`\n✅ Server listening on http://0.0.0.0:${PORT}`);
      console.log(`📝 Environment: ${process.env.NODE_ENV || 'development'}`);
      console.log(`🔐 JWT Secret: ${JWT_SECRET === 'change_me_long_secret' ? '⚠️ DEFAULT (CHANGE ME!)' : '✅ Custom'}`);
      console.log('\n');
    });

  } catch (err) {
    console.error('❌ Failed to start server:', err);
    process.exit(1);
  }
})();

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down gracefully...');
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log('SIGINT received, shutting down gracefully...');
  process.exit(0);
});