const nodemailer = require('nodemailer');
const directTransport = require('nodemailer-direct-transport');

function parseBooleanEnv(rawValue, fallback = false) {
  if (rawValue === undefined || rawValue === null || rawValue === '') {
    return fallback;
  }
  const normalized = String(rawValue).trim().toLowerCase();
  return ['1', 'true', 'yes', 'on', 'y'].includes(normalized);
}

function deriveMailHost() {
  const candidates = [
    process.env.AUTH_EMAIL_LINK_BASE,
    process.env.PUBLIC_BASE_URL,
    process.env.API_PUBLIC_BASE_URL,
  ];
  for (const candidate of candidates) {
    const raw = String(candidate || '').trim();
    if (!raw) continue;
    try {
      const url = new URL(raw);
      let host = String(url.hostname || '').trim().toLowerCase();
      if (host.startsWith('www.')) {
        host = host.slice(4);
      }
      if (!host) continue;
      if (host === 'localhost') continue;
      if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) continue;
      return host;
    } catch (_) {
      continue;
    }
  }
  return '';
}

function resolveFromAddress() {
  const configured = String(process.env.SMTP_FROM || '').trim();
  if (configured) return configured;
  const host = deriveMailHost();
  if (!host) return '';
  return `Fenix <no-reply@${host}>`;
}

function canUseDirectFallback() {
  return parseBooleanEnv(process.env.MAIL_DIRECT_FALLBACK, false);
}

function getMailerConfig() {
  const from = resolveFromAddress();
  const smtpUrl = String(process.env.SMTP_URL || '').trim();
  if (smtpUrl) {
    return {
      transport: smtpUrl,
      from,
      mode: 'smtp_url',
    };
  }

  const host = String(process.env.SMTP_HOST || '').trim();
  if (!host) {
    const directHost = deriveMailHost();
    if (canUseDirectFallback() && directHost && from) {
      return {
        transport: directTransport({
          name: directHost,
          debug: parseBooleanEnv(process.env.SMTP_DEBUG, false),
          logger: parseBooleanEnv(process.env.SMTP_LOGGER, false),
        }),
        from,
        mode: 'direct',
      };
    }
    return { transport: null, from, mode: 'disabled' };
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
    from,
    mode: 'smtp_host',
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
    mode: config.mode,
    from: config.from,
    transport: config.mode === 'direct' ? { direct: true } : config.transport,
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

  const result = await transporter.sendMail({
    from: config.from,
    to,
    subject,
    text,
    html,
  });
  return result;
}

module.exports = {
  isMailConfigured,
  sendMail,
};
