// server/src/routes/chats.js
const express = require('express');
const router = express.Router();
const db = require('../db');
const { authMiddleware: requireAuth } = require('../utils/auth');
const { requireRole } = require('../utils/roles');
const { requireChatPermission } = require('../utils/permissions');
const { v4: uuidv4 } = require('uuid');

router.get('/', requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const publicQ = await db.query(
      `SELECT c.id, c.title, c.type,
              (SELECT text FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) as last_message,
              (SELECT created_at FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) as updated_at
       FROM chats c
       WHERE NOT EXISTS (SELECT 1 FROM chat_members cm WHERE cm.chat_id = c.id)
       ORDER BY updated_at DESC NULLS LAST
       LIMIT 100`
    );
    const privateQ = await db.query(
      `SELECT c.id, c.title, c.type,
              (SELECT text FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) as last_message,
              (SELECT created_at FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) as updated_at
       FROM chats c
       JOIN chat_members cm ON cm.chat_id = c.id
       WHERE cm.user_id = $1
       ORDER BY updated_at DESC NULLS LAST
       LIMIT 100`,
      [userId]
    );
    const chats = [...publicQ.rows, ...privateQ.rows];
    return res.json({ ok: true, data: chats });
  } catch (err) {
    console.error('chats.list error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

/**
 * POST /api/chats
 * Создать чат — только creator или admin
 * body: { title, type?: 'public'|'private', members?: [userId,...] }
 */
router.post('/', requireAuth, requireRole('creator', 'admin'), async (req, res) => {
  try {
    const { title, type = 'public', members = [] } = req.body || {};
    if (!title || typeof title !== 'string') {
      return res.status(400).json({ ok: false, error: 'title required' });
    }
    const insert = await db.query(
      `INSERT INTO chats (id, title, type, created_by, settings, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5, now(), now())
       RETURNING id, title, type, created_by`,
      [uuidv4(), title, type, req.user.id, JSON.stringify({})]
    );
    const chat = insert.rows[0];
    if (type === 'private') {
      const creatorId = req.user.id;
      const membersArr = Array.isArray(members) ? members : [];
      const toAdd = Array.from(new Set([creatorId, ...membersArr]));
      const insertPromises = toAdd.map((uid) =>
        db.query(
          `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
           VALUES ($1, $2, $3, now(), $4)
           ON CONFLICT (chat_id, user_id) DO NOTHING`,
          [uuidv4(), chat.id, uid, uid === creatorId ? 'owner' : 'member']
        )
      );
      await Promise.all(insertPromises);
    }
    const resultChat = { id: chat.id, title: chat.title, type: chat.type, created_by: chat.created_by };
    const io = req.app.get('io');
    if (type === 'public' && io) {
      io.emit('chat:created', { chat: resultChat });
    }
    try {
      await db.query(
        `INSERT INTO admin_actions (id, admin_id, action, target_user_id, details, created_at)
         VALUES ($1,$2,$3,$4,$5,now())`,
        [uuidv4(), req.user.id, 'create_chat', null, JSON.stringify({ chatId: chat.id, type })]
      );
    } catch (e) {
      // ignore audit errors
    }
    return res.status(201).json({ ok: true, data: resultChat });
  } catch (err) {
    console.error('chats.create error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

/**
 * GET /api/chats/:chatId/messages
 */
router.get('/:chatId/messages', requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const { chatId } = req.params;
    const chatQ = await db.query('SELECT id, title FROM chats WHERE id = $1', [chatId]);
    if (chatQ.rowCount === 0) return res.status(404).json({ ok: false, error: 'Chat not found' });
    const memberQ = await db.query('SELECT 1 FROM chat_members WHERE chat_id=$1 AND user_id=$2', [chatId, userId]);
    const isMember = memberQ.rowCount > 0;
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

/**
 * POST /api/chats/:chatId/messages
 * Поддержка client_msg_id для дедупликации (client-generated UUID)
 */
router.post('/:chatId/messages', requireAuth, async (req, res) => {
  try {
    const userId = req.user.id;
    const { chatId } = req.params;
    const { text, client_msg_id } = req.body || {}; // client_msg_id — optional UUID from client

    if (!text || !text.trim()) return res.status(400).json({ ok: false, error: 'Text required' });

    // Проверим существование чата и его тип
    const chatQ = await db.query('SELECT id, type FROM chats WHERE id = $1', [chatId]);
    if (chatQ.rowCount === 0) return res.status(404).json({ ok: false, error: 'Chat not found' });

    // Проверка участия: если в chat_members есть записи для этого чата, то это приватный чат и нужно быть участником.
    const hasMembers = (await db.query('SELECT 1 FROM chat_members WHERE chat_id=$1 LIMIT 1', [chatId])).rowCount > 0;
    if (hasMembers) {
      const memberQ = await db.query('SELECT 1 FROM chat_members WHERE chat_id=$1 AND user_id=$2', [chatId, userId]);
      if (memberQ.rowCount === 0) return res.status(403).json({ ok: false, error: 'Not a member' });
    }

    // Вставляем сообщение с поддержкой client_msg_id для дедупа
    let insert;
    if (client_msg_id) {
      insert = await db.query(
        `INSERT INTO messages (id, client_msg_id, chat_id, sender_id, text, created_at)
         VALUES ($1, $2, $3, $4, $5, now())
         ON CONFLICT (client_msg_id) DO NOTHING
         RETURNING id, client_msg_id, chat_id, sender_id, text, created_at`,
        [uuidv4(), client_msg_id, chatId, userId, text]
      );

      // Если вставка не произошла (конфликт), получим существующую запись
      if (insert.rowCount === 0) {
        const q = await db.query(
          'SELECT id, client_msg_id, chat_id, sender_id, text, created_at FROM messages WHERE client_msg_id = $1',
          [client_msg_id]
        );
        insert = q;
      }
    } else {
      // Без client_msg_id — обычная вставка
      insert = await db.query(
        `INSERT INTO messages (id, chat_id, sender_id, text, created_at)
         VALUES ($1, $2, $3, $4, now())
         RETURNING id, client_msg_id, chat_id, sender_id, text, created_at`,
        [uuidv4(), chatId, userId, text]
      );
    }

    const message = insert.rows[0];

    // Обновим updated_at у чата (если есть колонка)
    try {
      await db.query('UPDATE chats SET updated_at = now() WHERE id = $1', [chatId]);
    } catch (e) { /* ignore */ }

    // Broadcast message — включаем client_msg_id, чтобы клиент мог дедупить
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

/**
 * Members management endpoints
 * - GET /api/chats/:chatId/members
 * - POST /api/chats/:chatId/members  (invite)  — owner/moderator
 * - DELETE /api/chats/:chatId/members/:userId  — owner/moderator
 * - PATCH /api/chats/:chatId/members/:userId/role  — only owner
 */

// GET members
router.get('/:chatId/members', requireAuth, async (req, res) => {
  try {
    const { chatId } = req.params;
    const q = await db.query(
      `SELECT u.id as user_id, u.email, cm.role, cm.joined_at
       FROM users u
       JOIN chat_members cm ON cm.user_id = u.id
       WHERE cm.chat_id = $1
       ORDER BY cm.joined_at ASC`,
      [chatId]
    );
    return res.json({ ok: true, data: q.rows });
  } catch (err) {
    console.error('chats.members.list error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

// POST invite (owner/moderator)
router.post('/:chatId/members', requireAuth, requireChatPermission(['owner','moderator']), async (req, res) => {
  const { chatId } = req.params;
  const { userId, role = 'member' } = req.body || {};
  if (!userId) return res.status(400).json({ ok: false, error: 'userId required' });

  try {
    await db.query(
      `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
       VALUES ($1,$2,$3,now(),$4)
       ON CONFLICT (chat_id, user_id) DO UPDATE SET role = EXCLUDED.role`,
      [uuidv4(), chatId, userId, role]
    );

    // audit
    try {
      await db.query(
        `INSERT INTO admin_actions (id, admin_id, action, target_user_id, details, created_at)
         VALUES ($1,$2,$3,$4,$5,now())`,
        [uuidv4(), req.user.id, 'invite_user', userId, JSON.stringify({ chatId, role })]
      );
    } catch (e) { /* ignore audit errors */ }

    return res.status(201).json({ ok: true });
  } catch (err) {
    console.error('chats.members.add error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

// DELETE member (owner/moderator)
router.delete('/:chatId/members/:userId', requireAuth, requireChatPermission(['owner','moderator']), async (req, res) => {
  const { chatId, userId } = req.params;
  try {
    await db.query('DELETE FROM chat_members WHERE chat_id=$1 AND user_id=$2', [chatId, userId]);

    // audit
    try {
      await db.query(
        `INSERT INTO admin_actions (id, admin_id, action, target_user_id, details, created_at)
         VALUES ($1,$2,$3,$4,$5,now())`,
        [uuidv4(), req.user.id, 'remove_user', userId, JSON.stringify({ chatId })]
      );
    } catch (e) { /* ignore audit errors */ }

    return res.json({ ok: true });
  } catch (err) {
    console.error('chats.members.delete error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

// PATCH change role (only owner)
router.patch('/:chatId/members/:userId/role', requireAuth, requireChatPermission(['owner']), async (req, res) => {
  const { chatId, userId } = req.params;
  const { role } = req.body || {};
  if (!role) return res.status(400).json({ ok: false, error: 'role required' });
  try {
    await db.query('UPDATE chat_members SET role=$1 WHERE chat_id=$2 AND user_id=$3', [role, chatId, userId]);

    // audit
    try {
      await db.query(
        `INSERT INTO admin_actions (id, admin_id, action, target_user_id, details, created_at)
         VALUES ($1,$2,$3,$4,$5,now())`,
        [uuidv4(), req.user.id, 'change_role', userId, JSON.stringify({ chatId, role })]
      );
    } catch (e) { /* ignore audit errors */ }

    return res.json({ ok: true });
  } catch (err) {
    console.error('chats.members.role error', err);
    return res.status(500).json({ ok: false, error: 'Server error' });
  }
});

module.exports = router;
