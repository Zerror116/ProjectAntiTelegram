const nodemailer = require('nodemailer');

function parseBooleanEnv(rawValue, fallback = false) {
  if (rawValue === undefined || rawValue === null || rawValue === '') {
    return fallback;
  }
  const normalized = String(rawValue).trim().toLowerCase();
  return ['1', 'true', 'yes', 'on', 'y'].includes(normalized);
}

function getMailerConfig() {
  const smtpUrl = String(process.env.SMTP_URL || '').trim();
  if (smtpUrl) {
    return {
      transport: smtpUrl,
      from: String(process.env.SMTP_FROM || '').trim(),
    };
  }

  const host = String(process.env.SMTP_HOST || '').trim();
  if (!host) {
    return {
      transport: null,
      from: String(process.env.SMTP_FROM || '').trim(),
    };
  }

  const port = Math.max(1, Number(process.env.SMTP_PORT || 587) || 587);
  const secure = parseBooleanEnv(process.env.SMTP_SECURE, port === 465);
  const user = String(process.env.SMTP_USER || '').trim();
  const pass = String(process.env.SMTP_PASSWORD || '').trim();

  return {
    transport: {
      host,
      port,
      secure,
      auth: user ? { user, pass } : undefined,
    },
    from: String(process.env.SMTP_FROM || '').trim(),
  };
}

let cachedTransporter = null;
let cachedTransportKey = '';

function isMailConfigured() {
  const config = getMailerConfig();
  return Boolean(config.transport && config.from);
}

function getTransporter() {
  const config = getMailerConfig();
  if (!config.transport || !config.from) return null;

  const transportKey = JSON.stringify({
    transport: config.transport,
    from: config.from,
  });
  if (cachedTransporter && cachedTransportKey === transportKey) {
    return cachedTransporter;
  }

  cachedTransporter = nodemailer.createTransport(config.transport);
  cachedTransportKey = transportKey;
  return cachedTransporter;
}

async function sendMail({ to, subject, text, html }) {
  const config = getMailerConfig();
  const transporter = getTransporter();
  if (!config.from || !transporter) {
    const error = new Error(
      'Почта для восстановления пока не настроена на сервере',
    );
    error.statusCode = 503;
    throw error;
  }

  return await transporter.sendMail({
    from: config.from,
    to,
    subject,
    text,
    html,
  });
}

module.exports = {
  isMailConfigured,
  sendMail,
};
