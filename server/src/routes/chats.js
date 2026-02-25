// server/src/routes/chats.js
const express = require('express');
const router = express.Router();
const db = require('../db');
const { authMiddleware: requireAuth } = require('../utils/auth');
const { requireRole } = require('../utils/roles');

// GET /api/chats
// Возвращает публичные чаты (без записей в chat_members) + приватные чаты, где пользователь является участником
router.get('/', requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;

    // Публичные чаты: те, у которых нет записей в chat_members
    const publicQ = await db.query(
      `SELECT c.id, c.title,
              (SELECT text FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) as last_message,
              (SELECT created_at FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) as updated_at
       FROM chats c
       WHERE NOT EXISTS (SELECT 1 FROM chat_members cm WHERE cm.chat_id = c.id)
       ORDER BY updated_at DESC NULLS LAST
       LIMIT 100`
    );

    // Приватные чаты, где пользователь член
    const privateQ = await db.query(
      `SELECT c.id, c.title,
              (SELECT text FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) as last_message,
              (SELECT created_at FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) as updated_at
       FROM chats c
       JOIN chat_members cm ON cm.chat_id = c.id
       WHERE cm.user_id = $1
       ORDER BY updated_at DESC NULLS LAST
       LIMIT 100`,
      [userId]
    );

    // Объединяем: публичные + приватные (где член)
    const chats = [...publicQ.rows, ...privateQ.rows];
    return res.json({ ok: true, data: chats });
  } catch (err) {
    console.error('chats.list error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

// POST /api/chats
// Создать чат — только creator или admin
// body: { title, type?: 'public'|'private', members?: [userId,...] }
router.post('/', requireAuth, requireRole('creator', 'admin'), async (req, res) => {
  try {
    const { title, type = 'public', members = [] } = req.body || {};
    if (!title || typeof title !== 'string') {
      return res.status(400).json({ ok: false, error: 'title required' });
    }

    // Вставляем чат (в вашей миграции есть created_at и updated_at)
    const insert = await db.query(
      `INSERT INTO chats (title, created_at, updated_at)
       VALUES ($1, now(), now())
       RETURNING id, title`,
      [title]
    );
    const chat = insert.rows[0];

    // Если приватный — добавляем участников в chat_members (включая создателя)
    if (type === 'private') {
      const creatorId = req.user.id;
      const membersArr = Array.isArray(members) ? members : [];
      const toAdd = Array.from(new Set([creatorId, ...membersArr]));
      const insertPromises = toAdd.map((uid) =>
        db.query(
          `INSERT INTO chat_members (chat_id, user_id, joined_at)
           VALUES ($1, $2, now())
           ON CONFLICT (chat_id, user_id) DO NOTHING`,
          [chat.id, uid]
        )
      );
      await Promise.all(insertPromises);
    }

    const resultChat = { id: chat.id, title: chat.title, type };

    // Emit event to connected clients for public chat
    const io = req.app.get('io');
    if (type === 'public' && io) {
      io.emit('chat:created', { chat: resultChat });
    }

    return res.status(201).json({ ok: true, data: resultChat });
  } catch (err) {
    console.error('chats.create error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

// GET /api/chats/:chatId/messages
router.get('/:chatId/messages', requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const { chatId } = req.params;

    // Проверим, существует ли чат
    const chatQ = await db.query('SELECT id, title FROM chats WHERE id = $1', [chatId]);
    if (chatQ.rowCount === 0) return res.status(404).json({ ok: false, error: 'Chat not found' });

    // Проверка участия: если есть запись в chat_members — пользователь участник.
    // Для публичных чатов участие не требуется.
    const memberQ = await db.query('SELECT 1 FROM chat_members WHERE chat_id=$1 AND user_id=$2', [chatId, userId]);
    const isMember = memberQ.rowCount > 0;

    // Если чат приватный (есть участники) и пользователь не участник — запрет
    const hasMembers = (await db.query('SELECT 1 FROM chat_members WHERE chat_id=$1 LIMIT 1', [chatId])).rowCount > 0;
    if (hasMembers && !isMember) {
      return res.status(403).json({ ok: false, error: 'Not a member' });
    }

    const { rows } = await db.query(
      `SELECT id, sender_id, text, created_at,
              (sender_id = $2) as from_me
       FROM messages
       WHERE chat_id = $1
       ORDER BY created_at ASC
       LIMIT 1000`,
      [chatId, userId]
    );
    return res.json({ ok: true, data: rows });
  } catch (err) {
    console.error('chats.messages error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

// POST /api/chats/:chatId/messages
router.post('/:chatId/messages', requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const { chatId } = req.params;
    const { text } = req.body || {};
    if (!text || !text.trim()) return res.status(400).json({ ok: false, error: 'Text required' });

    // Проверим существование чата
    const chatQ = await db.query('SELECT id FROM chats WHERE id = $1', [chatId]);
    if (chatQ.rowCount === 0) return res.status(404).json({ ok: false, error: 'Chat not found' });

    // Проверка участия: если в chat_members есть записи для этого чата, то это приватный чат и нужно быть участником.
    const hasMembers = (await db.query('SELECT 1 FROM chat_members WHERE chat_id=$1 LIMIT 1', [chatId])).rowCount > 0;
    if (hasMembers) {
      const memberQ = await db.query('SELECT 1 FROM chat_members WHERE chat_id=$1 AND user_id=$2', [chatId, userId]);
      if (memberQ.rowCount === 0) return res.status(403).json({ ok: false, error: 'Not a member' });
    }

    // Вставляем сообщение
    const insert = await db.query(
      `INSERT INTO messages (chat_id, sender_id, text, created_at)
       VALUES ($1, $2, $3, now())
       RETURNING id, chat_id, sender_id, text, created_at`,
      [chatId, userId, text]
    );

    // Обновим updated_at у чата (если есть колонка)
    try {
      await db.query('UPDATE chats SET updated_at = now() WHERE id = $1', [chatId]);
    } catch (e) { /* ignore */ }

    const message = insert.rows[0];

    // Emit message to room via io if available
    const io = req.app.get('io');
    if (io) {
      io.to(`chat:${chatId}`).emit('chat:message', { chatId, message });
      io.emit('chat:message:global', { chatId, message });
    }

    return res.status(201).json({ ok: true, data: message });
  } catch (err) {
    console.error('chats.postMessage error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

module.exports = router;
