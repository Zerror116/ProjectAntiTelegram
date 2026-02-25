// server/src/index.js
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

// Роуты и middleware (не должны импортировать index.js)
const setupRouter = require('./routes/setup');
const phonesRouter = require('./routes/phones');
const chatsRouter = require('./routes/chats');
const profileRouter = require('./routes/profile');
const authRouter = require('./routes/auth');
const adminRoutes = require('./routes/admin');
const { authMiddleware } = require('./utils/auth');

// Создаём express app
const app = express();

// Общие middleware
app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));

// Логирование входящих запросов и времени обработки (временно)
app.use((req, res, next) => {
  const start = Date.now();
  console.log('SERVER REQ START →', req.method, req.url);
  res.on('finish', () => {
    console.log(`SERVER REQ END ← ${req.method} ${req.url} ${res.statusCode} ${Date.now() - start}ms`);
  });
  next();
});

// Лимитер для маршрутов аутентификации
const authLimiter = rateLimit({
  windowMs: 2 * 1000,
  max: 6,
  message: { error: 'Слишком быстро, чуть чуть подождите' }
});
app.use('/api/auth/register', authLimiter);
app.use('/api/auth/login', authLimiter);

// Подключаем setup роут (инициализация БД)
app.use('/api/setup', setupRouter);

// Подключаем остальные роуты
app.use('/api/auth', authRouter);
app.use('/api/phones', phonesRouter);
app.use('/api/profile', profileRouter);
app.use('/api/chats', chatsRouter);
app.use('/api/admin', adminRoutes);

// Конфигурация и утилиты
const PORT = process.env.PORT || 3000;
const JWT_SECRET = process.env.JWT_SECRET || 'change_me_long_secret';
const SALT_ROUNDS = parseInt(process.env.SALT_ROUNDS || '10', 10);

function signToken(payload) {
  return jwt.sign(payload, JWT_SECRET, { expiresIn: '7d' });
}

async function findUserByEmail(email) {
  const res = await db.query('SELECT id, email, password_hash FROM users WHERE email = $1', [email]);
  return res.rows[0] || null;
}

// Healthcheck
app.get('/', (req, res) => res.json({ ok: true }));

// Простой ping для проверки доступности
app.get('/ping', (req, res) => res.json({ ok: true, ts: Date.now() }));

// Пример защищённого роута — профиль (если дублируется с profileRouter, можно удалить этот фрагмент)
app.get('/api/profile', authMiddleware, async (req, res) => {
  try {
    const { id } = req.user;
    const result = await db.query('SELECT id, email, name, phone, role, created_at FROM users WHERE id = $1', [id]);
    const user = result.rows[0];
    if (!user) return res.status(404).json({ error: 'User not found' });
    return res.json({ user });
  } catch (err) {
    console.error('Profile error', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not found' });
});

// Глобальный обработчик ошибок
app.use((err, req, res, next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({ error: 'Server error' });
});

// Пометка CREATOR_EMAIL как creator при старте (опционально)
// По умолчанию CREATOR_EMAIL можно задать в env; если не задан, используем zerotwo02166@gmail.com
async function ensureCreator() {
  try {
    const creatorEmail = process.env.CREATOR_EMAIL || 'zerotwo02166@gmail.com';
    const res = await db.query('SELECT id, role FROM users WHERE email = $1', [creatorEmail]);
    if (res.rowCount === 1 && res.rows[0].role !== 'creator') {
      await db.query('UPDATE users SET role = $1 WHERE id = $2', ['creator', res.rows[0].id]);
      console.log('Marked CREATOR_EMAIL as creator');
    }
  } catch (err) {
    console.error('ensureCreator error', err);
  }
}

// Запуск сервера в async IIFE, чтобы можно было вызвать ensureCreator() перед listen
(async () => {
  try {
    // Помечаем creator (если пользователь с таким email существует)
    await ensureCreator();

    // Создаём HTTP сервер и Socket.io
    const server = http.createServer(app);
    const io = new Server(server, {
      cors: {
        origin: '*',
        methods: ['GET', 'POST'],
      },
      // transports: ['websocket'] // можно настроить при необходимости
    });

    // Делаем io доступным в express через app.get('io')
    app.set('io', io);

    // Простая аутентификация сокета по токену (если передан в handshake.auth.token или query.token)
    io.use((socket, next) => {
      try {
        const token = socket.handshake.auth?.token || socket.handshake.query?.token;
        if (!token) return next(); // разрешаем подключение без токена, но без user info
        try {
          const payload = jwt.verify(token, JWT_SECRET);
          socket.user = payload; // { id, email, role, ... }
        } catch (err) {
          // invalid token — всё равно позволим подключиться, но без user
          console.warn('Socket auth failed:', err.message);
        }
        return next();
      } catch (err) {
        console.error('io.use error', err);
        return next();
      }
    });

    io.on('connection', (socket) => {
      const sid = socket.id;
      const uid = socket.user?.id;
      console.log(`Socket connected: ${sid} user=${uid || 'anon'}`);

      // Клиент может присоединиться к комнате чата
      socket.on('join_chat', (chatId) => {
        try {
          if (!chatId) return;
          socket.join(`chat:${chatId}`);
          console.log(`Socket ${sid} joined chat:${chatId}`);
        } catch (err) {
          console.error('join_chat error', err);
        }
      });

      socket.on('leave_chat', (chatId) => {
        try {
          if (!chatId) return;
          socket.leave(`chat:${chatId}`);
          console.log(`Socket ${sid} left chat:${chatId}`);
        } catch (err) {
          console.error('leave_chat error', err);
        }
      });

      socket.on('disconnect', (reason) => {
        console.log(`Socket disconnected: ${sid} reason=${reason}`);
      });
    });

    server.listen(PORT, '0.0.0.0', () => {
      console.log(`Server listening on ${PORT}`);
    });
  } catch (err) {
    console.error('Failed to start server', err);
    process.exit(1);
  }
})();
