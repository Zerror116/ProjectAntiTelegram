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
  const tenantPatternMatch = normalized.match(/^([A-Z]{3})-([A-Z0-9]{1,32})-KEY$/);
  if (tenantPatternMatch) {
    return `${tenantPatternMatch[1]}-****-KEY`;
  }
  if (normalized.length <= 8) return `${normalized.slice(0, 2)}****`;
  return `${normalized.slice(0, 4)}-****-${normalized.slice(-4)}`;
}

const cyrillicToLatin = {
  а: "a",
  б: "b",
  в: "v",
  г: "g",
  д: "d",
  е: "e",
  ё: "e",
  ж: "zh",
  з: "z",
  и: "i",
  й: "y",
  к: "k",
  л: "l",
  м: "m",
  н: "n",
  о: "o",
  п: "p",
  р: "r",
  с: "s",
  т: "t",
  у: "u",
  ф: "f",
  х: "h",
  ц: "ts",
  ч: "ch",
  ш: "sh",
  щ: "sch",
  ъ: "",
  ы: "y",
  ь: "",
  э: "e",
  ю: "yu",
  я: "ya",
};

function normalizeTenantSlug(raw) {
  const source = String(raw || "").toLowerCase();
  let latin = "";
  for (const ch of source) {
    if (/[a-z0-9]/.test(ch)) {
      latin += ch;
      continue;
    }
    if (Object.prototype.hasOwnProperty.call(cyrillicToLatin, ch)) {
      latin += cyrillicToLatin[ch];
      continue;
    }
    latin += "-";
  }
  return latin
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40);
}

function generateTenantCode(name) {
  const base = normalizeTenantSlug(name);
  const suffix = Math.floor(Math.random() * 9000) + 1000;
  return `${base || "tenant"}-${suffix}`;
}

function generateAccessKey() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  const middle = Array.from(
    { length: 7 },
    () => alphabet[Math.floor(Math.random() * alphabet.length)],
  ).join("");
  return `PHX-${middle}-KEY`;
}

function isTenantAccessKey(raw) {
  const normalized = normalizeAccessKey(raw);
  return /^[A-Z]{3}-[A-Z0-9]{1,32}-KEY$/.test(normalized);
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
  isTenantAccessKey,
  generateAccessKey,
  generateInviteCode,
  generateTenantCode,
  isTenantActive,
  isPlatformCreatorEmail,
};
