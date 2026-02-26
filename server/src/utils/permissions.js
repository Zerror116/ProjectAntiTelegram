// server/src/utils/permissions.js
const db = require('../db');

async function getUserGlobalRole(userId) {
  const res = await db.query('SELECT role FROM users WHERE id = $1', [userId]);
  if (res.rowCount === 0) return null;
  return res.rows[0].role;
}

async function getChatMemberRole(chatId, userId) {
  const res = await db.query('SELECT role FROM chat_members WHERE chat_id=$1 AND user_id=$2', [chatId, userId]);
  if (res.rowCount === 0) return null;
  return res.rows[0].role;
}

function requireGlobalRole(...allowed) {
  return async (req, res, next) => {
    try {
      const user = req.user;
      if (!user) return res.status(401).json({ ok: false, error: 'Unauthorized' });
      const role = await getUserGlobalRole(user.id);
      if (!role || !allowed.includes(role)) return res.status(403).json({ ok: false, error: 'Forbidden' });
      next();
    } catch (err) {
      console.error('requireGlobalRole error', err);
      res.status(500).json({ ok: false, error: 'Server error' });
    }
  };
}

function requireChatPermission(allowedRoles = ['owner','moderator']) {
  return async (req, res, next) => {
    try {
      const user = req.user;
      if (!user) return res.status(401).json({ ok: false, error: 'Unauthorized' });
      const chatId = req.params.chatId || req.body.chatId || req.query.chatId;
      if (!chatId) return res.status(400).json({ ok: false, error: 'chatId required' });
      const role = await getChatMemberRole(chatId, user.id);
      if (!role || !allowedRoles.includes(role)) return res.status(403).json({ ok: false, error: 'Forbidden' });
      next();
    } catch (err) {
      console.error('requireChatPermission error', err);
      res.status(500).json({ ok: false, error: 'Server error' });
    }
  };
}

module.exports = { requireGlobalRole, requireChatPermission, getUserGlobalRole, getChatMemberRole };
