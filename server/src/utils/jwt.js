// server/src/utils/jwt.js
const jwt = require('jsonwebtoken');
require('dotenv').config();

const SECRET = process.env.JWT_SECRET || 'change_me_long_secret';
const EXPIRES_IN = '7d';

function signJwt(payload) {
  // payload должен содержать { id, email, role }
  return jwt.sign(payload, SECRET, { expiresIn: EXPIRES_IN });
}

function verifyJwt(token) {
  try {
    return jwt.verify(token, SECRET);
  } catch (err) {
    return null;
  }
}

module.exports = { signJwt, verifyJwt };
