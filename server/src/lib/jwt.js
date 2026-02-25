// server/src/lib/jwt.js (пример)
const jwt = require('jsonwebtoken');

function createToken(user) {
  const payload = { sub: user.id, role: user.role };
  return jwt.sign(payload, process.env.JWT_SECRET, { expiresIn: '7d' });
}

module.exports = { createToken };
