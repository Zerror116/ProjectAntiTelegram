const crypto = require("crypto");

const PLATFORM_CREATOR_EMAIL = String(
  process.env.CREATOR_EMAIL || "zerotwo02166@gmail.com",
)
  .toLowerCase()
  .trim();

function normalizeAccessKey(raw) {
  return String(raw || "")
    .toUpperCase()
    .replace(/\s+/g, "")
    .trim();
}

function normalizeInviteCode(raw) {
  return String(raw || "")
    .toUpperCase()
    .replace(/[^A-Z0-9-]/g, "")
    .trim();
}

function hashAccessKey(raw) {
  const normalized = normalizeAccessKey(raw);
  if (!normalized) return "";
  return crypto.createHash("sha256").update(normalized).digest("hex");
}

function maskAccessKey(raw) {
  const normalized = normalizeAccessKey(raw);
  if (!normalized) return "";
  if (normalized.length <= 8) return `${normalized.slice(0, 2)}****`;
  return `${normalized.slice(0, 4)}-****-${normalized.slice(-4)}`;
}

function generateTenantCode(name) {
  const base = String(name || "")
    .toLowerCase()
    .replace(/[^a-z0-9а-яё]+/gi, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40);
  const suffix = Math.floor(Math.random() * 9000) + 1000;
  return `${base || "tenant"}-${suffix}`;
}

function generateAccessKey() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const chunk = () =>
    Array.from({ length: 4 }, () => alphabet[Math.floor(Math.random() * alphabet.length)]).join("");
  return `PHX-${chunk()}-${chunk()}-${chunk()}`;
}

function generateInviteCode() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const chunk = (size) =>
    Array.from({ length: size }, () => alphabet[Math.floor(Math.random() * alphabet.length)]).join("");
  return `INV-${chunk(4)}-${chunk(4)}`;
}

function isTenantActive(tenantRow) {
  if (!tenantRow) {
    return { ok: false, reason: "tenant_not_found", error: "Арендатор не найден" };
  }

  const status = String(tenantRow.status || "")
    .toLowerCase()
    .trim();
  if (status !== "active") {
    return {
      ok: false,
      reason: "tenant_blocked",
      error: "Подписка приостановлена. Обратитесь к владельцу приложения.",
    };
  }

  const expiresAtRaw = tenantRow.subscription_expires_at;
  const expiresAt = expiresAtRaw ? new Date(expiresAtRaw) : null;
  if (!expiresAt || Number.isNaN(expiresAt.getTime())) {
    return {
      ok: false,
      reason: "tenant_expiry_invalid",
      error: "Подписка настроена некорректно. Обратитесь к владельцу приложения.",
    };
  }

  if (expiresAt.getTime() < Date.now()) {
    return {
      ok: false,
      reason: "tenant_expired",
      error:
        "Срок подписки истёк. Доступ будет открыт после подтверждения оплаты владельцем приложения.",
    };
  }

  return { ok: true };
}

function isPlatformCreatorEmail(email) {
  return String(email || "")
    .toLowerCase()
    .trim() === PLATFORM_CREATOR_EMAIL;
}

module.exports = {
  PLATFORM_CREATOR_EMAIL,
  normalizeAccessKey,
  normalizeInviteCode,
  hashAccessKey,
  maskAccessKey,
  generateAccessKey,
  generateInviteCode,
  generateTenantCode,
  isTenantActive,
  isPlatformCreatorEmail,
};
