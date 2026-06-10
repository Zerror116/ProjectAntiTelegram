const express = require("express");
const { v4: uuidv4 } = require("uuid");
const ExcelJS = require("exceljs");

const router = express.Router();
const requireAuth = require("../middleware/requireAuth");
const requireRole = require("../middleware/requireRole");
const requirePermission = require("../middleware/requirePermission");
const db = require("../db");
const { antifraudGuard } = require("../utils/antifraud");
const {
  readEncryptedText,
  writeEncryptedTextParams,
} = require("../utils/secureData");
const { emitToTenant } = require("../utils/socket");
const {
  encryptMessageText,
  decryptMessageRow,
} = require("../utils/messageCrypto");
const {
  suggestAddresses,
  geocodeAddressText: providerGeocodeAddressText,
  reverseGeocodePoint,
  validateAddressSelection,
  isAddressProviderError,
} = require("../utils/deliveryAddressing");
const { getTenantFeatureSettings } = require("../utils/tenantFeatureSettings");

const requireDeliveryManagePermission = requirePermission("delivery.manage");
const KINEL_TENANT_CODE = "kinel-8997";

const DEFAULT_ROUTE_ORIGIN = { lat: 55.751244, lng: 37.618423 };
const DELIVERY_DAY_START_MINUTES = 10 * 60;
const DELIVERY_SOFT_END_MINUTES = 16 * 60;
const DELIVERY_HARD_END_MINUTES = 19 * 60;
const DELIVERY_STOP_SERVICE_MINUTES = 12;
const DELIVERY_STOP_BUFFER_MINUTES = 8;
const DELIVERY_DIALOG_AUTO_DELETE_MS = 60 * 1000;
const DELIVERY_DIALOG_CLEANUP_INTERVAL_MS = 15 * 1000;
const CART_RETENTION_WARNING_DAYS = 30;
const CLIENT_INACTIVITY_ACCOUNT_DELETE_DAYS = Math.max(
  30,
  Number(process.env.CLIENT_INACTIVITY_ACCOUNT_DELETE_DAYS || 180),
);
const CLIENT_RETENTION_SWEEP_LIMIT = Math.max(
  10,
  Number(process.env.CLIENT_RETENTION_SWEEP_LIMIT || 120),
);
const CLIENT_RETENTION_CLEANUP_INTERVAL_MS = Math.max(
  5 * 60 * 1000,
  Number(process.env.CLIENT_RETENTION_CLEANUP_INTERVAL_MS || 60 * 60 * 1000),
);
const CLIENT_UNREACHABLE_FIRST_CALL_AUTO_DELETE = String(
  process.env.CLIENT_UNREACHABLE_FIRST_CALL_AUTO_DELETE || "true",
)
  .toLowerCase()
  .trim() !== "false";
const CART_ACTIVE_STATUSES_FOR_AUTO_DISMANTLE = [
  "pending_processing",
  "processed",
  "preparing_delivery",
  "handing_to_courier",
  "in_delivery",
];
const CART_INACTIVITY_SWEEP_STATUSES = [
  "pending_processing",
  "processed",
];
const DEMO_USER_EMAIL_PREFIX = "phantom.delivery.";
const DEMO_PRODUCT_TITLE_PREFIX = "[DEMO DELIVERY]";
const GEOCODER_SEARCH_URL =
  String(process.env.GEOCODER_SEARCH_URL || "").trim() ||
  "https://nominatim.openstreetmap.org/search";
const GEOCODER_USER_AGENT =
  String(process.env.GEOCODER_USER_AGENT || "").trim() ||
  "ProjectPhoenix/1.0 (delivery geocoder)";
const GEOCODER_AUTH_HEADER = String(process.env.GEOCODER_AUTH_HEADER || "").trim();
const GEOCODER_API_KEY = String(process.env.GEOCODER_API_KEY || "").trim();
const DEMO_SAMARA_POINTS = [
  { name: "Анна", address: "Самара, Московское шоссе, 4к4", lat: 53.23327, lng: 50.18391 },
  { name: "Олег", address: "Самара, Ново-Садовая, 106", lat: 53.22794, lng: 50.16091 },
  { name: "Марина", address: "Самара, Дыбенко, 30", lat: 53.21267, lng: 50.19264 },
  { name: "Игорь", address: "Самара, Гагарина, 79", lat: 53.19982, lng: 50.18162 },
  { name: "Татьяна", address: "Самара, Авроры, 110", lat: 53.19141, lng: 50.17552 },
  { name: "Сергей", address: "Самара, Победы, 92", lat: 53.20512, lng: 50.22516 },
  { name: "Екатерина", address: "Самара, Свободы, 2", lat: 53.21078, lng: 50.24083 },
  { name: "Никита", address: "Самара, Металлургов, 84", lat: 53.23958, lng: 50.27651 },
  { name: "Ирина", address: "Самара, Ташкентская, 98", lat: 53.2474, lng: 50.22947 },
  { name: "Павел", address: "Самара, Стара-Загора, 56", lat: 53.23362, lng: 50.21885 },
  { name: "Юлия", address: "Самара, Демократическая, 7", lat: 53.26442, lng: 50.21443 },
  { name: "Роман", address: "Самара, Полевой спуск, 1", lat: 53.19937, lng: 50.11145 },
  { name: "Виктория", address: "Самара, Молодогвардейская, 210", lat: 53.20275, lng: 50.10648 },
  { name: "Дмитрий", address: "Самара, Ленинградская, 44", lat: 53.18679, lng: 50.09084 },
  { name: "Алина", address: "Самара, Фрунзе, 96", lat: 53.18753, lng: 50.08344 },
  { name: "Михаил", address: "Самара, Партизанская, 82", lat: 53.1861, lng: 50.16486 },
  { name: "Ксения", address: "Самара, Аэродромная, 47А", lat: 53.18736, lng: 50.18557 },
  { name: "Артем", address: "Самара, Революционная, 70", lat: 53.21424, lng: 50.16535 },
  { name: "Полина", address: "Самара, Осипенко, 41", lat: 53.21658, lng: 50.14503 },
  { name: "Глеб", address: "Самара, 5-я Просека, 110Е", lat: 53.24052, lng: 50.16349 },
];

let deliveryDialogCleanupTimer = null;
let deliveryDialogCleanupRunning = false;
let deliveryDialogCleanupIo = null;
let lastClientRetentionSweepAt = 0;

function cartRetentionDaysFromSettings(settings) {
  const parsed = Number(settings?.cart_retention_days);
  if (!Number.isFinite(parsed)) return CART_RETENTION_WARNING_DAYS;
  return Math.max(1, Math.min(365, Math.round(parsed)));
}

function normalizeRoleValue(value) {
  return String(value || "").toLowerCase().trim();
}

function isKinelTenantScope(user) {
  const tenantCode = String(user?.tenant_code || "")
    .toLowerCase()
    .trim();
  const tenantName = String(user?.tenant_name || "")
    .toLowerCase()
    .trim();
  return (
    tenantCode === KINEL_TENANT_CODE ||
    tenantCode.includes("kinel") ||
    tenantName.includes("кинель")
  );
}

function isKinelWorkerDeliveryAssemblyUser(user) {
  return normalizeRoleValue(user?.role) === "worker" && isKinelTenantScope(user);
}

function requireDeliveryAssemblyAccess(req, res, next) {
  if (!req.user) {
    return res.status(401).json({ ok: false, error: "Unauthorized" });
  }
  if (isKinelWorkerDeliveryAssemblyUser(req.user)) {
    return next();
  }
  return requireDeliveryManagePermission(req, res, next);
}

function deliveryDialogWhere(alias = "c") {
  return `${alias}.type = 'private'
    AND (
      COALESCE(${alias}.settings->>'kind', '') = 'delivery_dialog'
      OR COALESCE(${alias}.settings->>'system_key', '') = 'delivery_dialog'
      OR ${alias}.title = 'Доставка'
    )`;
}

function toMoney(value, fallback = 0) {
  const num = Number(value);
  if (!Number.isFinite(num)) return fallback;
  return Math.round(num * 100) / 100;
}

function isUuidLike(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    String(value || "").trim(),
  );
}

function normalizeJsonObject(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw;
}

function normalizeCityName(value) {
  return String(value || "")
    .normalize("NFKC")
    .trim()
    .replace(/\s+/g, " ")
    .slice(0, 120);
}

function normalizeDeliveryCityRates(raw) {
  if (!Array.isArray(raw)) return [];
  const seen = new Set();
  const rates = [];
  for (const item of raw) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const city = normalizeCityName(item.city || item.name || item.client_city);
    if (!city) continue;
    const key = city.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    const threshold = Math.max(
      0,
      toMoney(
        item.threshold_amount ??
          item.min_amount ??
          item.delivery_threshold_amount ??
          0,
        0,
      ),
    );
    rates.push({
      city,
      threshold_amount: threshold,
      delivery_fee_amount: 0,
      is_active: item.is_active !== false && item.enabled !== false,
    });
  }
  return rates;
}

function resolveCityRate(settings, city) {
  const normalized = normalizeCityName(city).toLowerCase();
  if (!normalized) return null;
  const rates = normalizeDeliveryCityRates(settings?.city_rates);
  return (
    rates.find(
      (rate) => rate.is_active !== false && rate.city.toLowerCase() === normalized,
    ) || null
  );
}

function deliveryRulesForCustomer(settings, city) {
  const rate = resolveCityRate(settings, city);
  const fallbackThreshold = Math.max(0, toMoney(settings?.threshold_amount, 1500));
  return {
    city: normalizeCityName(city),
    threshold_amount:
      rate && Number.isFinite(Number(rate.threshold_amount))
        ? Math.max(0, toMoney(rate.threshold_amount, fallbackThreshold))
        : fallbackThreshold,
    delivery_fee_amount: 0,
    city_rate_applied: Boolean(rate),
  };
}

function resolveTenantScopeId(explicitTenantId = null) {
  const rawExplicit = String(explicitTenantId || "").trim();
  if (rawExplicit) return rawExplicit;
  const context = typeof db.currentTenantContext === "function" ? db.currentTenantContext() : null;
  const fromContext = String(context?.tenant?.id || "").trim();
  return fromContext || null;
}

function deliverySettingsKey(tenantId = null) {
  const normalized = resolveTenantScopeId(tenantId);
  return normalized ? `delivery:${normalized}` : "delivery";
}

function canManageDeliveryPricing(user) {
  const role = String(user?.base_role || user?.role || "")
    .toLowerCase()
    .trim();
  return role === "creator" || role === "tenant";
}

async function getDeliverySettings(queryable = db, tenantId = null) {
  const scopedTenantId = resolveTenantScopeId(tenantId);
  const scopedKey = deliverySettingsKey(scopedTenantId);
  const fallbackKey = "delivery";
  const result = await queryable.query(
    `SELECT key, value
     FROM system_settings
     WHERE key = ANY($1::text[])
     ORDER BY CASE WHEN key = $2 THEN 0 ELSE 1 END
     LIMIT 1`,
    [[scopedKey, fallbackKey], scopedKey],
  );
  const value = normalizeJsonObject(result.rows[0]?.value);
  return {
    threshold_amount: Math.max(0, toMoney(value.threshold_amount, 1500)),
    city_rates: normalizeDeliveryCityRates(value.city_rates),
    route_origin_label: String(value.route_origin_label || "Точка отправки").trim() || "Точка отправки",
    route_origin_address: String(value.route_origin_address || "").trim(),
    route_origin_lat:
      value.route_origin_lat == null || value.route_origin_lat === ""
        ? null
        : Number(value.route_origin_lat),
    route_origin_lng:
      value.route_origin_lng == null || value.route_origin_lng === ""
        ? null
        : Number(value.route_origin_lng),
    delivery_zones: [],
  };
}

async function saveDeliverySettings(queryable, settings, userId, tenantId = null) {
  const key = deliverySettingsKey(tenantId);
  await queryable.query(
    `INSERT INTO system_settings (key, value, updated_at, updated_by)
     VALUES ($1, $2::jsonb, now(), $3)
     ON CONFLICT (key) DO UPDATE
       SET value = EXCLUDED.value,
           updated_at = now(),
           updated_by = EXCLUDED.updated_by`,
    [key, JSON.stringify(settings), userId || null],
  );
}

function nextDeliveryInfo(now = new Date()) {
  const next = new Date(now);
  const weekday = now.getDay();
  if (weekday === 6) {
    next.setDate(now.getDate() + 2);
    return { date: next, label: "Доставка на понедельник" };
  }
  if (weekday === 0) {
    next.setDate(now.getDate() + 1);
    return { date: next, label: "Доставка на понедельник" };
  }
  next.setDate(now.getDate() + 1);
  return { date: next, label: "Доставка на завтра" };
}

function formatDateOnly(date) {
  const yyyy = date.getFullYear();
  const mm = String(date.getMonth() + 1).padStart(2, "0");
  const dd = String(date.getDate()).padStart(2, "0");
  return `${yyyy}-${mm}-${dd}`;
}

function formatSamaraDateOnly(date = new Date()) {
  try {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: "Europe/Samara",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).formatToParts(date);
    const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
    if (values.year && values.month && values.day) {
      return `${values.year}-${values.month}-${values.day}`;
    }
  } catch (_) {}
  return date.toISOString().slice(0, 10);
}

function formatSamaraDateRu(date = new Date()) {
  try {
    return new Intl.DateTimeFormat("ru-RU", {
      timeZone: "Europe/Samara",
      day: "2-digit",
      month: "2-digit",
      year: "numeric",
    }).format(date);
  } catch (_) {}
  return date.toLocaleDateString("ru-RU");
}

function addDays(date, days) {
  const next = new Date(date);
  next.setDate(next.getDate() + Number(days || 0));
  return next;
}

function buildSelfPickupDeliveryLabel(date = new Date()) {
  return `Самовывоз ${formatSamaraDateRu(date)}`;
}

function firstLetterCode(name) {
  const trimmed = String(name || "").trim();
  if (!trimmed) return "?";
  return trimmed[0].toUpperCase();
}

function ensureIsoDate(value) {
  const normalizedDate =
    value instanceof Date ? formatDateOnly(value) : String(value || "").slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(normalizedDate)) {
    throw new Error(`Некорректная дата доставки: ${String(value)}`);
  }
  return normalizedDate;
}

function parseClockToMinutes(raw) {
  const value = String(raw || "").trim();
  if (!value) return null;
  const match = value.match(/^(\d{1,2}):(\d{2})(?::\d{2})?$/);
  if (!match) return null;
  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  if (!Number.isInteger(hours) || !Number.isInteger(minutes)) return null;
  if (hours < 0 || hours > 23 || minutes < 0 || minutes > 59) return null;
  return hours * 60 + minutes;
}

function minutesToClock(minutes) {
  if (!Number.isFinite(minutes)) return "";
  const normalized = Math.max(0, Math.round(minutes));
  const hours = Math.floor(normalized / 60);
  const mins = normalized % 60;
  return `${String(hours).padStart(2, "0")}:${String(mins).padStart(2, "0")}`;
}

function dateTimeFromMinutes(deliveryDate, minutes) {
  const normalizedDate = ensureIsoDate(deliveryDate);
  const base = new Date(`${normalizedDate}T00:00:00`);
  if (Number.isNaN(base.getTime())) {
    throw new Error(`Некорректная дата доставки: ${String(deliveryDate)}`);
  }
  base.setMinutes(Math.max(0, Math.round(minutes)));
  return base;
}

function buildEtaWindow(deliveryDate, etaMinutes) {
  const start = dateTimeFromMinutes(deliveryDate, etaMinutes);
  const end = new Date(start);
  end.setMinutes(end.getMinutes() + 30);
  return { eta_from: start.toISOString(), eta_to: end.toISOString() };
}

function trafficMultiplierForMinutes(minutes) {
  if (minutes >= 16 * 60) return 1.4;
  if (minutes >= 14 * 60) return 1.28;
  if (minutes >= 12 * 60) return 1.2;
  if (minutes >= 10 * 60) return 1.12;
  return 1;
}

function estimateTravelMinutesKm(distanceKmValue, departureMinutes) {
  const safeDistance = Math.max(0, Number(distanceKmValue) || 0);
  const kmPerHour = 25;
  const baseMinutes = safeDistance === 0 ? 0 : (safeDistance / kmPerHour) * 60;
  const traffic = trafficMultiplierForMinutes(departureMinutes);
  return Math.max(7, Math.round(baseMinutes * traffic) + 3);
}

function sanitizePreferredWindow(rawFrom, rawTo) {
  const fromMinutes = parseClockToMinutes(rawFrom);
  const toMinutes = parseClockToMinutes(rawTo);
  if (rawFrom && fromMinutes == null) {
    throw new Error("Некорректное время 'после'. Используйте формат ЧЧ:ММ");
  }
  if (rawTo && toMinutes == null) {
    throw new Error("Некорректное время 'до'. Используйте формат ЧЧ:ММ");
  }
  if (
    fromMinutes != null &&
    toMinutes != null &&
    fromMinutes >= toMinutes
  ) {
    throw new Error("Время 'после' должно быть раньше времени 'до'");
  }
  return {
    fromMinutes,
    toMinutes,
    fromText: fromMinutes == null ? null : minutesToClock(fromMinutes),
    toText: toMinutes == null ? null : minutesToClock(toMinutes),
  };
}

function preferredWindowPenalty(slot, customer) {
  const travelMinutes = estimateTravelMinutesKm(
    distanceKm(slot.currentLat, slot.currentLng, customer.lat, customer.lng),
    slot.currentMinutes,
  );
  const arrival = slot.currentMinutes + travelMinutes;
  const prefFrom = parseClockToMinutes(customer.preferred_time_from);
  const prefTo = parseClockToMinutes(customer.preferred_time_to);
  const waitMinutes = prefFrom != null && arrival < prefFrom ? prefFrom - arrival : 0;
  const lateMinutes = prefTo != null && arrival > prefTo ? arrival - prefTo : 0;
  return {
    travelMinutes,
    waitMinutes,
    lateMinutes,
    score:
      travelMinutes +
      waitMinutes * 0.45 +
      lateMinutes * 18 +
      slot.items.length * 6,
  };
}

function normalizeDeliveryOrigin(raw) {
  const origin = normalizeJsonObject(raw);
  const lat = origin.lat == null || origin.lat === "" ? null : Number(origin.lat);
  const lng = origin.lng == null || origin.lng === "" ? null : Number(origin.lng);
  return {
    label: String(origin.label || "Точка отправки").trim() || "Точка отправки",
    address: String(origin.address || "").trim(),
    lat: Number.isFinite(lat) ? lat : null,
    lng: Number.isFinite(lng) ? lng : null,
  };
}

function effectiveOriginPoint(origin) {
  const normalized = normalizeDeliveryOrigin(origin);
  return {
    ...normalized,
    lat: normalized.lat ?? DEFAULT_ROUTE_ORIGIN.lat,
    lng: normalized.lng ?? DEFAULT_ROUTE_ORIGIN.lng,
  };
}

function normalizeWhitespace(value) {
  return String(value || "")
    .replace(/\s+/g, " ")
    .replace(/\s*,\s*/g, ", ")
    .trim();
}

function normalizeClockValue(raw) {
  const value = String(raw || "").trim();
  if (!value) return null;
  const minutes = parseClockToMinutes(value);
  if (minutes == null) return null;
  return minutesToClock(minutes);
}

function decodeAddressFromRow(row) {
  const value = readEncryptedText(row, "address");
  return String(value || "").trim();
}

function buildAddressEncryption(addressText) {
  return writeEncryptedTextParams(addressText);
}

function sanitizeJsonObject(raw) {
  return raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
}

function normalizeValidationStatus(raw) {
  const value = String(raw || "").toLowerCase().trim();
  if (value === "accept" || value === "accepted") return "accepted";
  if (value === "confirm" || value === "confirm_required") {
    return "confirm_required";
  }
  if (value === "fix" || value === "fix_required") return "fix_required";
  return "unverified";
}

function normalizeValidationConfidence(raw) {
  const value = String(raw || "").toLowerCase().trim();
  if (["high", "medium", "low"].includes(value)) return value;
  return null;
}

function normalizePointSource(raw) {
  const value = String(raw || "").toLowerCase().trim();
  if (["map", "suggest", "saved", "text"].includes(value)) return value;
  return "text";
}

function normalizeZoneStatus(raw) {
  const value = String(raw || "").toLowerCase().trim();
  if (["inside", "outside", "unconfigured", "unchecked"].includes(value)) {
    return value;
  }
  return "unchecked";
}

function normalizeAddressStructured(raw, addressText = "") {
  const structured = sanitizeJsonObject(raw);
  const next = { ...structured };
  if (!next.full_text && addressText) {
    next.full_text = normalizeWhitespace(addressText);
  }
  return next;
}

function respondAddressProviderError(res, err, fallbackMessage) {
  if (!isAddressProviderError(err)) return false;
  return res.status(Number(err.status) || 503).json({
    ok: false,
    error: String(err.message || fallbackMessage || "Сервис адресов временно недоступен."),
    code: String(err.code || "address_provider_unavailable"),
    provider: err.provider || null,
    provider_unavailable: true,
  });
}

function mapStoredDeliveryAddressRow(row) {
  const addressText = decodeAddressFromRow(row);
  return {
    id: row.id,
    user_id: row.user_id || null,
    label: String(row.label || "Адрес").trim() || "Адрес",
    address_text: addressText,
    lat: row.lat == null ? null : Number(row.lat),
    lng: row.lng == null ? null : Number(row.lng),
    entrance: String(row.entrance || "").trim(),
    comment: String(row.comment || "").trim(),
    is_default: row.is_default === true,
    provider: String(row.provider || "").trim() || null,
    provider_address_id: String(row.provider_address_id || "").trim() || null,
    validation_status: normalizeValidationStatus(row.validation_status),
    validation_confidence: normalizeValidationConfidence(row.validation_confidence),
    point_source: normalizePointSource(row.point_source),
    mismatch_distance_meters:
      row.mismatch_distance_meters == null
        ? null
        : Math.max(0, Math.round(Number(row.mismatch_distance_meters) || 0)),
    delivery_zone_id: String(row.delivery_zone_id || "").trim() || null,
    delivery_zone_label: String(row.delivery_zone_label || "").trim() || null,
    delivery_zone_status: normalizeZoneStatus(row.delivery_zone_status),
    address_structured: normalizeAddressStructured(row.address_structured, addressText),
    created_at: row.created_at || null,
    updated_at: row.updated_at || null,
  };
}

function extractIncomingAddressSelection(body = {}) {
  const safe = sanitizeJsonObject(body);
  const addressText = normalizeWhitespace(
    safe.address_text || safe.resolved_address_text || safe.address || "",
  );
  const lat =
    safe.lat == null || safe.lat === "" ? null : Number(safe.lat);
  const lng =
    safe.lng == null || safe.lng === "" ? null : Number(safe.lng);
  const mismatchDistance =
    safe.mismatch_distance_meters == null || safe.mismatch_distance_meters === ""
      ? null
      : Math.max(0, Math.round(Number(safe.mismatch_distance_meters) || 0));
  return {
    label: String(safe.label || "").trim() || "Адрес",
    address_text: addressText,
    lat: Number.isFinite(lat) ? lat : null,
    lng: Number.isFinite(lng) ? lng : null,
    entrance: String(safe.entrance || safe.entrance_or_hint || "").trim(),
    comment: String(safe.comment || "").trim(),
    provider: String(safe.provider || "").trim() || null,
    provider_address_id: String(
      safe.provider_address_id || safe.provider_place_id || "",
    ).trim() || null,
    validation_status: normalizeValidationStatus(safe.validation_status),
    validation_confidence: normalizeValidationConfidence(
      safe.validation_confidence,
    ),
    point_source: normalizePointSource(safe.point_source),
    mismatch_distance_meters: mismatchDistance,
    delivery_zone_id: String(safe.delivery_zone_id || "").trim() || null,
    delivery_zone_label: String(safe.delivery_zone_label || "").trim() || null,
    delivery_zone_status: normalizeZoneStatus(safe.delivery_zone_status),
    address_structured: normalizeAddressStructured(
      safe.address_structured || safe.structured_address,
      addressText,
    ),
  };
}

function buildAddressDbPayload(selection) {
  const addressText = normalizeWhitespace(selection?.address_text || "");
  const structured = normalizeAddressStructured(
    selection?.address_structured,
    addressText,
  );
  return {
    label: String(selection?.label || "Адрес").trim() || "Адрес",
    address_text: addressText,
    encrypted: buildAddressEncryption(addressText),
    lat:
      selection?.lat == null || !Number.isFinite(Number(selection.lat))
        ? null
        : Number(selection.lat),
    lng:
      selection?.lng == null || !Number.isFinite(Number(selection.lng))
        ? null
        : Number(selection.lng),
    entrance: String(selection?.entrance || "").trim() || null,
    comment: String(selection?.comment || "").trim() || null,
    provider: String(selection?.provider || "").trim() || null,
    provider_address_id:
      String(selection?.provider_address_id || "").trim() || null,
    validation_status: normalizeValidationStatus(selection?.validation_status),
    validation_confidence: normalizeValidationConfidence(
      selection?.validation_confidence,
    ),
    point_source: normalizePointSource(selection?.point_source),
    mismatch_distance_meters:
      selection?.mismatch_distance_meters == null
        ? null
        : Math.max(
            0,
            Math.round(Number(selection.mismatch_distance_meters) || 0),
          ),
    delivery_zone_id: String(selection?.delivery_zone_id || "").trim() || null,
    delivery_zone_label:
      String(selection?.delivery_zone_label || "").trim() || null,
    delivery_zone_status: normalizeZoneStatus(selection?.delivery_zone_status),
    address_structured: structured,
  };
}

async function resolveValidatedAddressSelection({
  rawSelection,
  settings,
  requirePoint = false,
  allowConfirm = false,
}) {
  const baseSelection = extractIncomingAddressSelection(rawSelection);
  const hasAddress =
    baseSelection.address_text ||
    (Number.isFinite(baseSelection.lat) && Number.isFinite(baseSelection.lng));
  if (!hasAddress) {
    return {
      ok: false,
      error: "Нужно указать адрес доставки",
    };
  }

  let validation;
  try {
    validation = await validateAddressSelection({
      addressText: baseSelection.address_text,
      lat: baseSelection.lat,
      lng: baseSelection.lng,
      zones: [],
      structuredAddress: baseSelection.address_structured,
      provider: baseSelection.provider,
      providerAddressId: baseSelection.provider_address_id,
    });
  } catch (err) {
    const hasManualPoint =
      Number.isFinite(baseSelection.lat) && Number.isFinite(baseSelection.lng);
    if (!isAddressProviderError(err)) {
      throw err;
    }
    if (!hasManualPoint && !baseSelection.address_text) {
      throw err;
    }
    validation = {
      action: "accept",
      summary:
        "Адрес сохранен без внешней проверки. Проверьте текст адреса перед отправкой.",
      lat: baseSelection.lat,
      lng: baseSelection.lng,
      structured_address: baseSelection.address_structured,
      provider: baseSelection.provider,
      provider_address_id: baseSelection.provider_address_id,
      validation_confidence: baseSelection.validation_confidence || "low",
      mismatch_distance_meters: null,
      zone_status: baseSelection.delivery_zone_status || "unchecked",
      delivery_zone_id: baseSelection.delivery_zone_id || null,
      delivery_zone_label: baseSelection.delivery_zone_label || null,
      resolved_address_text: baseSelection.address_text,
      point_source: baseSelection.point_source || "map",
    };
  }

  if (requirePoint && (!Number.isFinite(validation.lat) || !Number.isFinite(validation.lng))) {
    return {
      ok: false,
      error: "Выберите точку на карте или адрес из подсказок",
    };
  }
  if (validation.action === "fix" && !requirePoint && baseSelection.address_text) {
    validation = {
      ...validation,
      action: "accept",
      summary: "Адрес сохранен без точной проверки. Проверьте текст адреса перед отправкой.",
      lat: Number.isFinite(validation.lat) ? validation.lat : baseSelection.lat,
      lng: Number.isFinite(validation.lng) ? validation.lng : baseSelection.lng,
      resolved_address_text:
        validation.resolved_address_text || baseSelection.address_text,
      point_source: validation.point_source || baseSelection.point_source || "text",
    };
  }
  if (validation.action === "confirm" && !requirePoint) {
    validation = {
      ...validation,
      action: "accept",
      summary: "Адрес сохранен. Точка на карте использована как подсказка.",
    };
  }
  if (validation.action === "fix") {
    return {
      ok: false,
      error: validation.summary,
      validation,
    };
  }
  return {
    ok: true,
    selection: {
      ...baseSelection,
      address_text: validation.resolved_address_text || baseSelection.address_text,
      lat: validation.lat,
      lng: validation.lng,
      provider: validation.provider || baseSelection.provider,
      provider_address_id:
        validation.provider_address_id || baseSelection.provider_address_id,
      validation_status:
        validation.action === "accept"
          ? "accepted"
          : validation.action === "confirm"
          ? "confirm_required"
          : "fix_required",
      validation_confidence:
        validation.validation_confidence || baseSelection.validation_confidence,
      point_source: validation.point_source || baseSelection.point_source,
      mismatch_distance_meters: validation.mismatch_distance_meters,
      delivery_zone_id: validation.delivery_zone_id || baseSelection.delivery_zone_id,
      delivery_zone_label:
        validation.delivery_zone_label || baseSelection.delivery_zone_label,
      delivery_zone_status:
        validation.zone_status || baseSelection.delivery_zone_status,
      address_structured: normalizeAddressStructured(
        validation.structured_address || baseSelection.address_structured,
        validation.resolved_address_text || baseSelection.address_text,
      ),
    },
    validation,
  };
}

function mapDeliverySlotRow(row) {
  return {
    id: row.id,
    title: String(row.title || "").trim(),
    from_time: normalizeClockValue(row.from_time),
    to_time: normalizeClockValue(row.to_time),
    sort_order: Number(row.sort_order) || 0,
    is_active: row.is_active !== false,
    is_system: row.is_system === true,
    tenant_id: row.tenant_id || null,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

function stripAddressServiceParts(addressText) {
  const normalized = normalizeWhitespace(addressText);
  if (!normalized) return "";
  const parts = normalized
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
  const filtered = parts.filter((part) => {
    const lower = part.toLowerCase();
    return !(
      lower.includes("подъезд") ||
      lower.includes("подьезд") ||
      lower.includes("этаж") ||
      /^кв\.?\s*\d+/i.test(part) ||
      /^квартира\s*\d+/i.test(lower) ||
      /^офис\s*\d+/i.test(lower) ||
      lower.includes("домофон")
    );
  });
  return filtered.join(", ");
}

function normalizeLocalityName(raw) {
  const value = normalizeWhitespace(raw).toLowerCase();
  if (!value) return "";
  if (value.includes("новик")) return "Новокуйбышевск";
  if (value.includes("новак")) return "Новокуйбышевск";
  if (value.includes("Новик")) return "Новокуйбышевск";
  if (value.includes("Новак")) return "Новокуйбышевск";
  if (value.includes("новокуйб")) return "Новокуйбышевск";
  if (value.includes("самара")) return "Самара";
  if (value.includes("чапаевск")) return "Чапаевск";
  if (value.includes("сызран")) return "Сызрань";
  if (value.includes("кинель")) return "Кинель";
  if (value.includes("тольят")) return "Тольятти";
  return raw;
}

function detectAddressLocality(addressText) {
  const normalized = normalizeWhitespace(addressText);
  if (!normalized) return "";
  const firstChunk = normalized.split(",")[0]?.trim() || "";
  return normalizeLocalityName(firstChunk);
}

function buildGeocodeQuery(addressText) {
  const normalized = stripAddressServiceParts(addressText);
  const locality = detectAddressLocality(normalized);
  const hasLocalityInText =
    Boolean(locality) && normalized.toLowerCase().includes(locality.toLowerCase());
  const withoutLocality = hasLocalityInText
    ? normalized
        .split(",")
        .map((part) => part.trim())
        .filter(Boolean)
        .filter((part, index) => {
          if (index != 0) return true;
          return normalizeLocalityName(part).toLowerCase() !== locality.toLowerCase();
        })
        .join(", ")
    : normalized;
  const addressCore = withoutLocality || normalized || locality;
  return {
    locality,
    query: `${addressCore}, Россия`,
  };
}

function extractGeocodeLocality(item) {
  const address = item?.address || {};
  return normalizeLocalityName(
    address.city ||
      address.town ||
      address.village ||
      address.municipality ||
      address.county ||
      address.state_district ||
      "",
  );
}

async function geocodeDeliveryAddress(addressText) {
  const originalNormalized = normalizeWhitespace(addressText);
  if (!originalNormalized) return null;
  const cleaned = stripAddressServiceParts(originalNormalized);
  const chosen = await providerGeocodeAddressText(cleaned || originalNormalized, {
    limit: 1,
  });
  if (!chosen) return null;
  return {
    address_text: originalNormalized,
    locality: normalizeWhitespace(
      chosen?.structured_address?.city ||
        chosen?.structured_address?.area ||
        "",
    ),
    lat: Number(chosen.lat),
    lng: Number(chosen.lng),
    resolved_label: chosen.label || chosen.address_text || "",
    structured_address: chosen.structured_address || {},
    provider: chosen.provider || null,
    provider_address_id: chosen.provider_address_id || null,
  };
}

function distanceKm(aLat, aLng, bLat, bLng) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const earthRadiusKm = 6371;
  const dLat = toRad(bLat - aLat);
  const dLng = toRad(bLng - aLng);
  const sinLat = Math.sin(dLat / 2);
  const sinLng = Math.sin(dLng / 2);
  const aa =
    sinLat * sinLat +
    Math.cos(toRad(aLat)) * Math.cos(toRad(bLat)) * sinLng * sinLng;
  const c = 2 * Math.atan2(Math.sqrt(aa), Math.sqrt(1 - aa));
  return earthRadiusKm * c;
}

function polarAngle(originLat, originLng, pointLat, pointLng) {
  const angle = Math.atan2(pointLat - originLat, pointLng - originLng);
  return angle >= 0 ? angle : angle + Math.PI * 2;
}

function optimizeSlotRoute(items, origin) {
  const pending = [...items];
  const ordered = [];
  let currentLat = origin.lat;
  let currentLng = origin.lng;
  let currentMinutes = DELIVERY_DAY_START_MINUTES;

  while (pending.length > 0) {
    let bestIndex = 0;
    let bestScore = Number.POSITIVE_INFINITY;
    for (let index = 0; index < pending.length; index += 1) {
      const candidate = pending[index];
      const candidateScore = preferredWindowPenalty(
        {
          currentLat,
          currentLng,
          currentMinutes,
          items: ordered,
        },
        candidate,
      );
      if (candidateScore.score < bestScore) {
        bestScore = candidateScore.score;
        bestIndex = index;
      }
    }
    const [picked] = pending.splice(bestIndex, 1);
    const travel = estimateTravelMinutesKm(
      distanceKm(currentLat, currentLng, picked.lat, picked.lng),
      currentMinutes,
    );
    const prefFrom = parseClockToMinutes(picked.preferred_time_from);
    let etaMinutes = currentMinutes + travel;
    if (prefFrom != null && etaMinutes < prefFrom) {
      etaMinutes = prefFrom;
    }
    etaMinutes = Math.max(DELIVERY_DAY_START_MINUTES, etaMinutes);
    if (etaMinutes > DELIVERY_HARD_END_MINUTES) {
      etaMinutes = DELIVERY_HARD_END_MINUTES;
    }
    ordered.push({
      ...picked,
      eta_minutes: etaMinutes,
    });
    currentLat = picked.lat;
    currentLng = picked.lng;
    currentMinutes =
      etaMinutes + DELIVERY_STOP_SERVICE_MINUTES + DELIVERY_STOP_BUFFER_MINUTES;
  }

  return ordered;
}

function buildCourierSlots(courierNames, origin) {
  const start = effectiveOriginPoint(origin);
  return courierNames.map((name, index) => ({
    slot: index + 1,
    name,
    items: [],
    currentLat: start.lat,
    currentLng: start.lng,
    currentMinutes: DELIVERY_DAY_START_MINUTES,
  }));
}

function distributeCustomersAcrossCouriers(customers, courierNames, origin) {
  const slots = buildCourierSlots(courierNames, origin);
  const start = effectiveOriginPoint(origin);
  const withCoords = [];
  const withoutCoords = [];
  const targetCounts = slots.map((_, index) => {
    const base = Math.floor(customers.length / slots.length);
    const remainder = customers.length % slots.length;
    return base + (index < remainder ? 1 : 0);
  });

  for (const customer of customers) {
    const lat = Number(customer.lat);
    const lng = Number(customer.lng);
    const lockedCourierName = String(customer.locked_courier_name || "").trim();
    const lockedSlot = Number(customer.locked_courier_slot);
    const lockedMatch = slots.find(
      (slot) =>
        (lockedCourierName && slot.name === lockedCourierName) ||
        (Number.isInteger(lockedSlot) && slot.slot === lockedSlot),
    );
    if (lockedMatch) {
      lockedMatch.items.push({
        ...customer,
        lat: Number.isFinite(lat) ? lat : customer.lat,
        lng: Number.isFinite(lng) ? lng : customer.lng,
        locked: true,
      });
      continue;
    }
    if (Number.isFinite(lat) && Number.isFinite(lng)) {
      withCoords.push({
        ...customer,
        lat,
        lng,
        angle: polarAngle(start.lat, start.lng, lat, lng),
      });
    } else {
      withoutCoords.push(customer);
    }
  }

  withCoords.sort((a, b) => a.angle - b.angle);
  let coordIndex = 0;
  for (let slotIndex = 0; slotIndex < slots.length; slotIndex += 1) {
    const slot = slots[slotIndex];
    let capacity = Math.max(0, targetCounts[slotIndex] - slot.items.length);
    while (capacity > 0 && coordIndex < withCoords.length) {
      slot.items.push(withCoords[coordIndex]);
      coordIndex += 1;
      capacity -= 1;
    }
  }
  while (coordIndex < withCoords.length) {
    const slot = [...slots].sort(
      (a, b) => a.items.length - b.items.length || a.slot - b.slot,
    )[0];
    slot.items.push(withCoords[coordIndex]);
    coordIndex += 1;
  }

  for (const customer of withoutCoords) {
    const slot = [...slots].sort(
      (a, b) => a.items.length - b.items.length || a.slot - b.slot,
    )[0];
    slot.items.push(customer);
  }

  for (const slot of slots) {
    const slotWithCoords = [];
    const slotWithoutCoords = [];
    for (const item of slot.items) {
      const itemLat = Number(item.lat);
      const itemLng = Number(item.lng);
      if (Number.isFinite(itemLat) && Number.isFinite(itemLng)) {
        slotWithCoords.push({
          ...item,
          lat: itemLat,
          lng: itemLng,
        });
      } else {
        slotWithoutCoords.push(item);
      }
    }
    slot.items = [
      ...optimizeSlotRoute(slotWithCoords, start),
      ...slotWithoutCoords.map((item, index) => ({
        ...item,
        eta_minutes: Math.min(
          DELIVERY_DAY_START_MINUTES +
              (slotWithCoords.length + index) *
                (DELIVERY_STOP_SERVICE_MINUTES + DELIVERY_STOP_BUFFER_MINUTES),
          DELIVERY_HARD_END_MINUTES,
        ),
      })),
    ];
  }

  return slots;
}

async function ensureDemoProducts(queryable) {
  const definitions = [
    { title: `${DEMO_PRODUCT_TITLE_PREFIX} | Коробка`, description: "Тестовый товар для маршрута", price: 360, quantity: 9999 },
    { title: `${DEMO_PRODUCT_TITLE_PREFIX} | Пакет`, description: "Тестовый товар для маршрута", price: 520, quantity: 9999 },
    { title: `${DEMO_PRODUCT_TITLE_PREFIX} | Ящик`, description: "Тестовый товар для маршрута", price: 780, quantity: 9999 },
  ];
  const result = [];
  for (let i = 0; i < definitions.length; i += 1) {
    const def = definitions[i];
    const existingQ = await queryable.query(
      `SELECT id, price, title
       FROM products
       WHERE title = $1
       LIMIT 1`,
      [def.title],
    );
    if (existingQ.rowCount > 0) {
      result.push(existingQ.rows[0]);
      continue;
    }
    const insertQ = await queryable.query(
      `INSERT INTO products (
         id, product_code, title, description, price, quantity,
         image_url, status, created_at, updated_at
       )
       VALUES ($1, $2, $3, $4, $5, $6, NULL, 'published', now(), now())
       RETURNING id, price, title`,
      [uuidv4(), 9000 + i, def.title, def.description, def.price, def.quantity],
    );
    result.push(insertQ.rows[0]);
  }
  return result;
}

function mapBatchRow(row) {
  return {
    id: row.id,
    delivery_date: row.delivery_date,
    delivery_label: row.delivery_label,
    route_origin_label: row.route_origin_label,
    route_origin_address: row.route_origin_address,
    route_origin_lat:
      row.route_origin_lat == null ? null : Number(row.route_origin_lat),
    route_origin_lng:
      row.route_origin_lng == null ? null : Number(row.route_origin_lng),
    threshold_amount: toMoney(row.threshold_amount, 1500),
    status: row.status,
    courier_count: Number(row.courier_count) || 0,
    courier_names: Array.isArray(row.courier_names) ? row.courier_names : [],
    customers_total: Number(row.customers_total) || 0,
    accepted_total: Number(row.accepted_total) || 0,
    declined_total: Number(row.declined_total) || 0,
    assigned_total: Number(row.assigned_total) || 0,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

async function fetchBatchSummaries(queryable, tenantId = null) {
  const scopedTenantId = resolveTenantScopeId(tenantId);
  const result = await queryable.query(
    `SELECT b.id,
            b.delivery_date,
            b.delivery_label,
            b.route_origin_label,
            b.route_origin_address,
            b.route_origin_lat,
            b.route_origin_lng,
            b.threshold_amount,
            b.status,
            b.courier_count,
            b.courier_names,
            b.created_at,
            b.updated_at,
            COUNT(c.id) FILTER (WHERE ($1::uuid IS NULL OR cu.tenant_id = $1::uuid))::int AS customers_total,
            COUNT(*) FILTER (
              WHERE ($1::uuid IS NULL OR cu.tenant_id = $1::uuid)
                AND c.call_status = 'accepted'
            )::int AS accepted_total,
            COUNT(*) FILTER (
              WHERE ($1::uuid IS NULL OR cu.tenant_id = $1::uuid)
                AND c.call_status = 'declined'
            )::int AS declined_total,
            COUNT(*) FILTER (
              WHERE ($1::uuid IS NULL OR cu.tenant_id = $1::uuid)
                AND c.courier_name IS NOT NULL
                AND c.courier_name <> ''
            )::int AS assigned_total
     FROM delivery_batches b
     LEFT JOIN delivery_batch_customers c ON c.batch_id = b.id
     LEFT JOIN users cu ON cu.id = c.user_id
     WHERE (
       $1::uuid IS NULL
       OR EXISTS (
         SELECT 1
         FROM users bu
         WHERE bu.id = b.created_by
           AND bu.tenant_id = $1::uuid
       )
       OR EXISTS (
         SELECT 1
         FROM delivery_batch_customers c2
         JOIN users u2 ON u2.id = c2.user_id
         WHERE c2.batch_id = b.id
           AND u2.tenant_id = $1::uuid
       )
     )
     GROUP BY b.id
     ORDER BY
       CASE b.status
         WHEN 'calling' THEN 0
         WHEN 'couriers_assigned' THEN 1
         WHEN 'handed_off' THEN 2
         WHEN 'completed' THEN 3
         ELSE 4
       END,
       b.delivery_date DESC,
       b.created_at DESC
     LIMIT 20`,
    [scopedTenantId],
  );
  return result.rows.map(mapBatchRow);
}

async function fetchBatchDetails(queryable, batchId, tenantId = null) {
  const scopedTenantId = resolveTenantScopeId(tenantId);
  const batchQ = await queryable.query(
    `SELECT b.id,
            b.delivery_date,
            b.delivery_label,
            b.route_origin_label,
            b.route_origin_address,
            b.route_origin_lat,
            b.route_origin_lng,
            b.threshold_amount,
            b.status,
            b.courier_count,
            b.courier_names,
            b.created_at,
            b.updated_at,
            COUNT(c.id) FILTER (WHERE ($2::uuid IS NULL OR cu.tenant_id = $2::uuid))::int AS customers_total,
            COUNT(*) FILTER (
              WHERE ($2::uuid IS NULL OR cu.tenant_id = $2::uuid)
                AND c.call_status = 'accepted'
            )::int AS accepted_total,
            COUNT(*) FILTER (
              WHERE ($2::uuid IS NULL OR cu.tenant_id = $2::uuid)
                AND c.call_status = 'declined'
            )::int AS declined_total,
            COUNT(*) FILTER (
              WHERE ($2::uuid IS NULL OR cu.tenant_id = $2::uuid)
                AND c.courier_name IS NOT NULL
                AND c.courier_name <> ''
            )::int AS assigned_total
     FROM delivery_batches b
     LEFT JOIN delivery_batch_customers c ON c.batch_id = b.id
     LEFT JOIN users cu ON cu.id = c.user_id
     WHERE b.id = $1
       AND (
         $2::uuid IS NULL
         OR EXISTS (
           SELECT 1
           FROM users bu
           WHERE bu.id = b.created_by
             AND bu.tenant_id = $2::uuid
         )
         OR EXISTS (
           SELECT 1
           FROM delivery_batch_customers c2
           JOIN users u2 ON u2.id = c2.user_id
           WHERE c2.batch_id = b.id
             AND u2.tenant_id = $2::uuid
         )
       )
     GROUP BY b.id
     LIMIT 1`,
    [batchId, scopedTenantId],
  );
  if (batchQ.rowCount === 0) return null;

  const customersQ = await queryable.query(
    `SELECT c.*,
            COALESCE(
              (
                SELECT json_agg(
                  json_build_object(
                    'id', i.id,
                    'cart_item_id', i.cart_item_id,
                    'product_id', i.product_id,
                    'product_code', i.product_code,
                    'product_title', i.product_title,
                    'product_description', i.product_description,
                    'product_image_url', i.product_image_url,
                    'product_shelf_number', p.shelf_number,
                    'manual_shelf_label', p.manual_shelf_label,
                    'shelf_floor', p.shelf_floor,
                    'quantity', i.quantity,
                    'unit_price', i.unit_price,
                    'line_total', i.line_total,
                    'assembly_status', i.assembly_status,
                    'is_bulky', i.is_bulky,
                    'bulky_note', i.bulky_note,
                    'bulky_price', i.bulky_price,
                    'removed_reason', i.removed_reason,
                    'removed_at', i.removed_at,
                    'bulky_stickers_requested', i.bulky_stickers_requested
                  )
                  ORDER BY i.created_at ASC
                )
                FROM delivery_batch_items i
                LEFT JOIN products p ON p.id = i.product_id
                WHERE i.batch_customer_id = c.id
              ),
              '[]'::json
            ) AS items
       FROM delivery_batch_customers c
       JOIN users scope_u ON scope_u.id = c.user_id
       WHERE c.batch_id = $1
         AND ($2::uuid IS NULL OR scope_u.tenant_id = $2::uuid)
       ORDER BY
       CASE c.call_status
         WHEN 'accepted' THEN 0
         WHEN 'pending' THEN 1
         WHEN 'declined' THEN 2
         ELSE 3
       END,
       c.route_order ASC NULLS LAST,
       c.processed_sum DESC,
       c.created_at ASC`,
    [batchId, scopedTenantId],
  );

  return {
    ...mapBatchRow(batchQ.rows[0]),
    customers: customersQ.rows.map((row) => ({
      ...row,
      address_text: decodeAddressFromRow(row),
      processed_sum: toMoney(row.processed_sum),
      agreed_sum: toMoney(row.agreed_sum),
      claim_return_sum: toMoney(row.claim_return_sum),
      claim_discount_sum: toMoney(row.claim_discount_sum),
      claims_total: toMoney(row.claims_total),
      items: Array.isArray(row.items) ? row.items : [],
    })),
  };
}

function emitCartUpdated(io, userId, payload) {
  if (!io || !userId) return;
  io.to(`user:${userId}`).emit("cart:updated", {
    userId: String(userId),
    ...payload,
  });
}

function emitDeliveryUpdated(io, batchId, tenantId = null) {
  if (!io) return;
  emitToTenant(io, tenantId, "delivery:updated", {
    batchId: String(batchId || ""),
    updatedAt: new Date().toISOString(),
  });
}

async function maybeCloseDeliveryBatchWithoutWork(queryable, batchId, tenantId = null) {
  const scopedTenantId = resolveTenantScopeId(tenantId);
  const activeQ = await queryable.query(
    `SELECT COUNT(*)::int AS total
     FROM delivery_batch_customers c
     JOIN users u ON u.id = c.user_id
     WHERE c.batch_id = $1
       AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
       AND COALESCE(c.call_status, '') IN ('pending', 'accepted')`,
    [batchId, scopedTenantId],
  );
  if ((Number(activeQ.rows[0]?.total) || 0) > 0) {
    return false;
  }
  const updated = await queryable.query(
    `UPDATE delivery_batches
     SET status = 'cancelled',
         updated_at = now()
     WHERE id = $1
       AND status IN ('calling', 'couriers_assigned')
     RETURNING id`,
    [batchId],
  );
  return updated.rowCount > 0;
}

function priceLabel(value) {
  const amount = toMoney(value);
  if (amount <= 0) return "";
  return `${amount.toFixed(2)} ₽`;
}

function safeStickerText(value, fallback = "") {
  const normalized = String(value ?? "").replace(/\s+/g, " ").trim();
  return normalized || fallback;
}

function mapStickerPrintJob(row) {
  if (!row) return null;
  return {
    id: String(row.id || ""),
    tenant_id: row.tenant_id ? String(row.tenant_id) : null,
    user_id: String(row.user_id || ""),
    sticker_type: String(row.sticker_type || ""),
    status: String(row.status || ""),
    payload: normalizeJsonObject(row.payload),
    source_type: String(row.source_type || ""),
    source_id: row.source_id ? String(row.source_id) : null,
    created_at: row.created_at || null,
  };
}

function normalDeliveryStickerPayload(customer) {
  return {
    phone: safeStickerText(customer?.customer_phone, "—"),
    name: safeStickerText(customer?.customer_name, "Клиент"),
    showFooter: true,
    footerText: "Феникс",
  };
}

function bulkyDeliveryStickerPayload(customer, item) {
  return {
    phone: safeStickerText(customer?.customer_phone, "—"),
    name: safeStickerText(customer?.customer_name, "Клиент"),
    productTitle: safeStickerText(
      item?.bulky_note || item?.product_title,
      "Габарит",
    ),
    priceLabel: priceLabel(item?.bulky_price || item?.unit_price || item?.line_total),
    kindLabel: "Габарит",
    showFooter: true,
    footerText: "Феникс",
  };
}

async function createStickerPrintJob(
  queryable,
  {
    tenantId,
    userId,
    createdBy,
    sourceId,
    stickerType,
    payload,
    sourceType = "delivery",
  },
) {
  const q = await queryable.query(
    `INSERT INTO sticker_print_jobs (
       id, tenant_id, user_id, created_by, source_type, source_id,
       sticker_type, status, payload, created_at, updated_at
     )
     VALUES ($1, $2, $3, $4, $5, $6, $7, 'pending', $8::jsonb, now(), now())
     RETURNING *`,
    [
      uuidv4(),
      tenantId || null,
      userId,
      createdBy || null,
      sourceType,
      sourceId || null,
      stickerType,
      JSON.stringify(payload || {}),
    ],
  );
  return mapStickerPrintJob(q.rows[0]);
}

function emitStickerPrintJobs(io, jobs) {
  if (!io || !Array.isArray(jobs)) return;
  for (const job of jobs) {
    const userId = String(job?.user_id || "").trim();
    if (!userId) continue;
    io.to(`user:${userId}`).emit("sticker:print-job", job);
  }
}

function bulkyPlacesFromItems(items) {
  return items.reduce((sum, item) => {
    if (item.assembly_status === "removed" || item.is_bulky !== true) return sum;
    return sum + 1;
  }, 0);
}

async function queueMissingAssemblyStickerJobs(
  queryable,
  { customer, items, tenantId, userId, createdBy },
) {
  const jobs = [];
  const customerId = String(customer?.id || "").trim();
  if (!customerId || !userId) return jobs;

  const packagePlaces = Math.max(1, Number(customer.package_places) || 1);
  const bulkyPlaces = bulkyPlacesFromItems(items);
  const normalPlaces = Math.max(1, packagePlaces - bulkyPlaces);
  const normalRequested = Math.max(
    0,
    Number(customer.normal_stickers_requested) || 0,
  );
  const missingNormal = Math.max(0, normalPlaces - normalRequested);

  for (let i = 0; i < missingNormal; i += 1) {
    jobs.push(
      await createStickerPrintJob(queryable, {
        tenantId,
        userId,
        createdBy,
        sourceId: customerId,
        stickerType: "delivery_normal",
        payload: normalDeliveryStickerPayload(customer),
      }),
    );
  }
  if (missingNormal > 0) {
    await queryable.query(
      `UPDATE delivery_batch_customers
       SET normal_stickers_requested = normal_stickers_requested + $2,
           updated_at = now()
       WHERE id = $1`,
      [customerId, missingNormal],
    );
    customer.normal_stickers_requested = normalRequested + missingNormal;
  }

  let totalBulkyMissing = 0;
  for (const item of items) {
    if (item.assembly_status === "removed" || item.is_bulky !== true) continue;
    const requested = Math.max(0, Number(item.bulky_stickers_requested) || 0);
    const missing = Math.max(0, 1 - requested);
    for (let i = 0; i < missing; i += 1) {
      jobs.push(
        await createStickerPrintJob(queryable, {
          tenantId,
          userId,
          createdBy,
          sourceId: item.id,
          stickerType: "delivery_bulky",
          payload: bulkyDeliveryStickerPayload(customer, item),
        }),
      );
    }
    if (missing > 0) {
      totalBulkyMissing += missing;
      await queryable.query(
        `UPDATE delivery_batch_items
         SET bulky_stickers_requested = bulky_stickers_requested + $2
         WHERE id = $1`,
        [item.id, missing],
      );
      item.bulky_stickers_requested = requested + missing;
    }
  }
  if (totalBulkyMissing > 0) {
    await queryable.query(
      `UPDATE delivery_batch_customers
       SET bulky_stickers_requested = bulky_stickers_requested + $2,
           updated_at = now()
       WHERE id = $1`,
      [customerId, totalBulkyMissing],
    );
    customer.bulky_stickers_requested =
      (Number(customer.bulky_stickers_requested) || 0) + totalBulkyMissing;
  }

  return jobs;
}

async function emitToCreators(io, eventName, payload) {
  if (!io || !eventName) return;
  try {
    const creatorsQ = await db.platformQuery(
      `SELECT id::text AS id
       FROM users
       WHERE COALESCE(NULLIF(BTRIM(role), ''), 'client') = 'creator'
         AND COALESCE(is_active, true) = true`,
    );
    for (const row of creatorsQ.rows) {
      const creatorId = String(row.id || "").trim();
      if (!creatorId) continue;
      io.to(`user:${creatorId}`).emit(eventName, payload);
    }
  } catch (err) {
    console.error("delivery.emitToCreators error", err);
  }
}

function normalizeCartStatusList(statuses) {
  if (!Array.isArray(statuses)) return [...CART_ACTIVE_STATUSES_FOR_AUTO_DISMANTLE];
  const normalized = statuses
    .map((status) => String(status || "").trim())
    .filter((status) => status.length > 0);
  return normalized.length > 0
    ? normalized
    : [...CART_ACTIVE_STATUSES_FOR_AUTO_DISMANTLE];
}

async function getCartRetentionSnapshot(
  queryable,
  userId,
  tenantId = null,
  statuses = CART_ACTIVE_STATUSES_FOR_AUTO_DISMANTLE,
  retentionDays = CART_RETENTION_WARNING_DAYS,
) {
  if (!userId) return null;
  const scopedTenantId = resolveTenantScopeId(tenantId);
  const safeStatuses = normalizeCartStatusList(statuses);
  const snapshotQ = await queryable.query(
    `SELECT MIN(c.created_at) AS oldest_created_at,
            COUNT(*)::int AS items_count,
            COALESCE(
              SUM((COALESCE(c.custom_price, p.price) * c.quantity)),
              0
            )::numeric AS total_sum
     FROM cart_items c
     JOIN users u ON u.id = c.user_id
     JOIN products p ON p.id = c.product_id
     WHERE c.user_id = $1
       AND c.status = ANY($2::text[])
       AND ($3::uuid IS NULL OR u.tenant_id = $3::uuid)`,
    [userId, safeStatuses, scopedTenantId],
  );
  const row = snapshotQ.rows[0] || {};
  if (!row.oldest_created_at || Number(row.items_count || 0) <= 0) return null;
  const oldestCreatedAt = new Date(row.oldest_created_at);
  if (Number.isNaN(oldestCreatedAt.getTime())) return null;
  const daysHeld = Math.max(
    0,
    Math.floor((Date.now() - oldestCreatedAt.getTime()) / (24 * 60 * 60 * 1000)),
  );
  const thresholdDays = Math.max(
    1,
    Math.min(365, Math.round(Number(retentionDays) || CART_RETENTION_WARNING_DAYS)),
  );
  return {
    oldest_created_at: oldestCreatedAt.toISOString(),
    items_count: Number(row.items_count || 0),
    total_sum: toMoney(row.total_sum),
    days_held: daysHeld,
    threshold_days: thresholdDays,
    is_stale: daysHeld >= thresholdDays,
  };
}

async function autoDismantleStaleCart(
  queryable,
  {
    userId,
    tenantId = null,
    statuses = CART_ACTIVE_STATUSES_FOR_AUTO_DISMANTLE,
    retentionDays = null,
  } = {},
) {
  const safeStatuses = normalizeCartStatusList(statuses);
  const effectiveRetentionDays =
    retentionDays == null
      ? cartRetentionDaysFromSettings(await getTenantFeatureSettings(tenantId || null))
      : Math.max(
          1,
          Math.min(365, Math.round(Number(retentionDays) || CART_RETENTION_WARNING_DAYS)),
        );
  const retention = await getCartRetentionSnapshot(
    queryable,
    userId,
    tenantId,
    safeStatuses,
    effectiveRetentionDays,
  );
  if (!retention || !retention.is_stale) {
    return { applied: false, retention };
  }

  const scopedTenantId = resolveTenantScopeId(tenantId);
  const itemsQ = await queryable.query(
    `SELECT c.id::text AS id,
            c.product_id::text AS product_id,
            c.quantity
     FROM cart_items c
     JOIN users u ON u.id = c.user_id
     WHERE c.user_id = $1
       AND c.status = ANY($2::text[])
       AND ($3::uuid IS NULL OR u.tenant_id = $3::uuid)
     FOR UPDATE`,
    [userId, safeStatuses, scopedTenantId],
  );
  if (itemsQ.rowCount === 0) {
    return { applied: false, retention };
  }

  const itemIds = itemsQ.rows
    .map((row) => String(row.id || "").trim())
    .filter((id) => id.length > 0);
  if (itemIds.length === 0) {
    return { applied: false, retention };
  }

  const productTotals = new Map();
  for (const row of itemsQ.rows) {
    const productId = String(row.product_id || "").trim();
    const quantity = Number(row.quantity) || 0;
    if (!productId || quantity <= 0) continue;
    productTotals.set(productId, (productTotals.get(productId) || 0) + quantity);
  }

  const reservationQ = await queryable.query(
    `SELECT id::text AS id, reserved_channel_message_id::text AS reserved_channel_message_id
     FROM reservations
     WHERE cart_item_id = ANY($1::uuid[])
     FOR UPDATE`,
    [itemIds],
  );
  const reservedMessageIds = reservationQ.rows
    .map((row) => String(row.reserved_channel_message_id || "").trim())
    .filter((id) => id.length > 0);
  if (reservedMessageIds.length > 0) {
    await queryable.query(
      `DELETE FROM messages
       WHERE id = ANY($1::uuid[])`,
      [reservedMessageIds],
    );
  }
  await queryable.query(
    `DELETE FROM reservations
     WHERE cart_item_id = ANY($1::uuid[])`,
    [itemIds],
  );

  await queryable.query(
    `DELETE FROM delivery_batch_items
     WHERE cart_item_id = ANY($1::uuid[])`,
    [itemIds],
  );

  for (const [productId, quantity] of productTotals.entries()) {
    await queryable.query(
      `UPDATE products
       SET quantity = quantity + $1,
           updated_at = now()
       WHERE id = $2`,
      [quantity, productId],
    );
  }

  for (const productId of productTotals.keys()) {
    const activeCartItemsQ = await queryable.query(
      `SELECT 1
       FROM cart_items c
       JOIN users u ON u.id = c.user_id
       WHERE c.product_id = $1
         AND c.status <> 'delivered'
         AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
       LIMIT 1`,
      [productId, scopedTenantId],
    );
    if (activeCartItemsQ.rowCount > 0) continue;

    const unresolvedReservationsQ = await queryable.query(
      `SELECT 1
       FROM reservations r
       JOIN users u ON u.id = r.user_id
       WHERE r.product_id = $1
         AND r.is_fulfilled = false
         AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
       LIMIT 1`,
      [productId, scopedTenantId],
    );
    if (unresolvedReservationsQ.rowCount > 0) continue;

    const activeDeliveryQ = await queryable.query(
      `SELECT 1
       FROM delivery_batch_items di
       JOIN delivery_batches dbt ON dbt.id = di.batch_id
       WHERE di.product_id = $1
         AND dbt.status IN ('calling', 'couriers_assigned', 'handed_off')
       LIMIT 1`,
      [productId],
    );
    if (activeDeliveryQ.rowCount > 0) continue;

    await queryable.query(
      `UPDATE products
       SET status = 'archived',
           quantity = 0,
           reusable_at = now(),
           updated_at = now()
       WHERE id = $1`,
      [productId],
    );
    await queryable.query(
      `UPDATE messages
       SET meta = jsonb_set(
             jsonb_set(
               COALESCE(meta, '{}'::jsonb),
               '{hidden_for_all}',
               'true'::jsonb,
               true
             ),
             '{archived_after_cart_dismantle}',
             'true'::jsonb,
             true
           )
       WHERE COALESCE(meta->>'kind', '') = 'catalog_product'
         AND COALESCE(meta->>'product_id', '') = $1::text
         AND COALESCE((meta->>'hidden_for_all')::boolean, false) = false`,
      [productId],
    );
  }

  await queryable.query(
    `DELETE FROM cart_items
     WHERE id = ANY($1::uuid[])`,
    [itemIds],
  );

  return {
    applied: true,
    retention,
    removed_items_count: itemIds.length,
    restored_products_count: productTotals.size,
  };
}

async function listStaleCartUserIds(
  queryable,
  {
    tenantId = null,
    limit = CLIENT_RETENTION_SWEEP_LIMIT,
    retentionDays = CART_RETENTION_WARNING_DAYS,
  } = {},
) {
  const scopedTenantId = resolveTenantScopeId(tenantId);
  const safeLimit = Math.max(1, Number(limit) || CLIENT_RETENTION_SWEEP_LIMIT);
  const safeRetentionDays = Math.max(
    1,
    Math.min(365, Math.round(Number(retentionDays) || CART_RETENTION_WARNING_DAYS)),
  );
  const result = await queryable.query(
    `SELECT c.user_id::text AS user_id,
            MAX(COALESCE(c.updated_at, c.created_at)) AS last_activity_at
     FROM cart_items c
     JOIN users u ON u.id = c.user_id
     WHERE c.status = ANY($1::text[])
       AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
       AND NOT EXISTS (
         SELECT 1
         FROM delivery_batch_customers dbc
         JOIN delivery_batches dbt ON dbt.id = dbc.batch_id
         WHERE dbc.user_id = c.user_id
           AND dbt.status IN ('calling', 'couriers_assigned', 'handed_off')
       )
     GROUP BY c.user_id
     HAVING MAX(COALESCE(c.updated_at, c.created_at))
       <= now() - make_interval(days => $3::int)
     ORDER BY MAX(COALESCE(c.updated_at, c.created_at)) ASC
     LIMIT $4`,
    [
      CART_INACTIVITY_SWEEP_STATUSES,
      scopedTenantId,
      safeRetentionDays,
      safeLimit,
    ],
  );
  return result.rows
    .map((row) => String(row.user_id || "").trim())
    .filter(Boolean);
}

async function listInactiveClientAccounts(
  queryable,
  {
    tenantId = null,
    inactivityDays = CLIENT_INACTIVITY_ACCOUNT_DELETE_DAYS,
    limit = CLIENT_RETENTION_SWEEP_LIMIT,
  } = {},
) {
  const scopedTenantId = resolveTenantScopeId(tenantId);
  const safeDays = Math.max(30, Number(inactivityDays) || 180);
  const safeLimit = Math.max(1, Number(limit) || CLIENT_RETENTION_SWEEP_LIMIT);
  const result = await queryable.query(
    `SELECT u.id::text AS user_id,
            u.email,
            COALESCE(NULLIF(BTRIM(p.phone), ''), '') AS phone,
            activity.last_activity_at
     FROM users u
     LEFT JOIN phones p ON p.user_id = u.id
     CROSS JOIN LATERAL (
       SELECT GREATEST(
         COALESCE(u.updated_at, u.created_at, to_timestamp(0)),
         COALESCE((SELECT MAX(d.last_seen) FROM devices d WHERE d.user_id = u.id), to_timestamp(0)),
         COALESCE((SELECT MAX(s.last_seen_at) FROM user_sessions s WHERE s.user_id = u.id), to_timestamp(0)),
         COALESCE((SELECT MAX(c.updated_at) FROM cart_items c WHERE c.user_id = u.id), to_timestamp(0)),
         COALESCE((SELECT MAX(m.created_at) FROM messages m WHERE m.sender_id = u.id), to_timestamp(0)),
         COALESCE((SELECT MAX(a.updated_at) FROM user_delivery_addresses a WHERE a.user_id = u.id), to_timestamp(0))
       ) AS last_activity_at
     ) activity
     WHERE COALESCE(NULLIF(BTRIM(u.role), ''), 'client') = 'client'
       AND COALESCE(u.is_active, true) = true
       AND ($1::uuid IS NULL OR u.tenant_id = $1::uuid)
       AND activity.last_activity_at < now() - make_interval(days => $2::int)
       AND NOT EXISTS (
         SELECT 1
         FROM delivery_batch_customers dbc
         JOIN delivery_batches dbt ON dbt.id = dbc.batch_id
         WHERE dbc.user_id = u.id
           AND dbt.status IN ('calling', 'couriers_assigned')
       )
     ORDER BY activity.last_activity_at ASC
     LIMIT $3`,
    [scopedTenantId, safeDays, safeLimit],
  );
  return result.rows;
}

async function deleteClientAccountByPolicy(
  queryable,
  { userId, tenantId = null, reason = "policy", source = "retention" } = {},
) {
  const scopedTenantId = resolveTenantScopeId(tenantId);
  const candidateId = String(userId || "").trim();
  if (!candidateId) return { applied: false, reason: "empty_user_id" };

  const userQ = await queryable.query(
    `SELECT u.id::text AS id,
            u.email,
            COALESCE(NULLIF(BTRIM(u.role), ''), 'client') AS role,
            u.tenant_id::text AS tenant_id,
            COALESCE(NULLIF(BTRIM(p.phone), ''), '') AS phone
     FROM users u
     LEFT JOIN phones p ON p.user_id = u.id
     WHERE u.id = $1
       AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
     LIMIT 1
     FOR UPDATE`,
    [candidateId, scopedTenantId],
  );
  if (userQ.rowCount === 0) return { applied: false, reason: "not_found" };
  const user = userQ.rows[0];
  if (String(user.role || "").toLowerCase().trim() !== "client") {
    return { applied: false, reason: "role_not_client", user };
  }

  const hasPendingDeliveryQ = await queryable.query(
    `SELECT 1
     FROM delivery_batch_customers dbc
     JOIN delivery_batches dbt ON dbt.id = dbc.batch_id
     WHERE dbc.user_id = $1
       AND dbt.status IN ('calling', 'couriers_assigned')
     LIMIT 1`,
    [candidateId],
  );
  if (hasPendingDeliveryQ.rowCount > 0) {
    return { applied: false, reason: "delivery_in_progress", user };
  }

  const deleted = await queryable.query(
    `DELETE FROM users
     WHERE id = $1
     RETURNING id`,
    [candidateId],
  );
  if (deleted.rowCount === 0) return { applied: false, reason: "delete_failed", user };

  try {
    await db.platformQuery(
      `DELETE FROM tenant_user_index
       WHERE user_id = $1`,
      [candidateId],
    );
  } catch (cleanupErr) {
    console.error("delivery.deleteClientAccountByPolicy tenant index cleanup error", cleanupErr);
  }

  return {
    applied: true,
    reason,
    source,
    user: {
      id: candidateId,
      email: String(user.email || ""),
      phone: String(user.phone || ""),
      tenant_id: String(user.tenant_id || ""),
    },
  };
}

async function runClientRetentionSweepInScope(
  queryable,
  { tenantId = null, io = null, scopeLabel = "shared" } = {},
) {
  const tenantSettings = await getTenantFeatureSettings(tenantId || null);
  const retentionDays = cartRetentionDaysFromSettings(tenantSettings);
  const staleUserIds = await listStaleCartUserIds(queryable, {
    tenantId,
    limit: CLIENT_RETENTION_SWEEP_LIMIT,
    retentionDays,
  });
  let staleCartsDismantled = 0;
  for (const userId of staleUserIds) {
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await autoDismantleStaleCart(client, {
        userId,
        tenantId,
        statuses: CART_INACTIVITY_SWEEP_STATUSES,
        retentionDays,
      });
      await client.query("COMMIT");
      if (result?.applied) {
        staleCartsDismantled += 1;
        emitCartUpdated(io, userId, {
          status: "empty",
          reason: "cart_auto_dismantled_inactive",
          auto_dismantled: true,
        });
        await emitToCreators(io, "creator:alert", {
          type: "cart_auto_dismantled_inactive",
          tenant_id: resolveTenantScopeId(tenantId),
          user_id: userId,
          reason: `inactive_${retentionDays}d`,
          at: new Date().toISOString(),
        });
      }
    } catch (err) {
      try {
        await client.query("ROLLBACK");
      } catch (_) {}
      console.error("delivery.retention stale cart cleanup error", {
        userId,
        scopeLabel,
        error: err?.message || err,
      });
    } finally {
      client.release();
    }
  }

  const inactiveClients = await listInactiveClientAccounts(queryable, {
    tenantId,
    inactivityDays: CLIENT_INACTIVITY_ACCOUNT_DELETE_DAYS,
    limit: CLIENT_RETENTION_SWEEP_LIMIT,
  });
  let inactiveClientsDeleted = 0;
  for (const row of inactiveClients) {
    const userId = String(row.user_id || "").trim();
    if (!userId) continue;
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const deletion = await deleteClientAccountByPolicy(client, {
        userId,
        tenantId,
        reason: "inactive_180d",
        source: "retention_sweep",
      });
      await client.query("COMMIT");
      if (deletion.applied) {
        inactiveClientsDeleted += 1;
        emitToTenant(io, tenantId, "tenant:client:auto_deleted", {
          user_id: deletion.user.id,
          email: deletion.user.email,
          phone: deletion.user.phone,
          reason: "inactive_180d",
          source: "retention_sweep",
          at: new Date().toISOString(),
        });
        await emitToCreators(io, "creator:alert", {
          type: "client_auto_deleted",
          tenant_id: deletion.user.tenant_id || resolveTenantScopeId(tenantId),
          user_id: deletion.user.id,
          email: deletion.user.email,
          phone: deletion.user.phone,
          reason: "inactive_180d",
          source: "retention_sweep",
          at: new Date().toISOString(),
        });
      }
    } catch (err) {
      try {
        await client.query("ROLLBACK");
      } catch (_) {}
      console.error("delivery.retention inactive client cleanup error", {
        userId,
        scopeLabel,
        error: err?.message || err,
      });
    } finally {
      client.release();
    }
  }

  if (staleCartsDismantled > 0 || inactiveClientsDeleted > 0) {
    console.log("delivery retention sweep", {
      scope: scopeLabel,
      stale_carts_dismantled: staleCartsDismantled,
      inactive_clients_deleted: inactiveClientsDeleted,
    });
  }

  return {
    stale_carts_dismantled: staleCartsDismantled,
    inactive_clients_deleted: inactiveClientsDeleted,
  };
}

async function runClientRetentionSweep(io = deliveryDialogCleanupIo) {
  const sharedSummary = await runClientRetentionSweepInScope(db, {
    tenantId: null,
    io,
    scopeLabel: "shared",
  });
  const isolatedTenants = await db.platformQuery(
    `SELECT id, code, db_mode, db_url, db_name, db_schema, status, subscription_expires_at
     FROM tenants
     WHERE (
       (db_mode = 'isolated' AND db_url IS NOT NULL)
       OR (db_mode = 'schema_isolated' AND db_schema IS NOT NULL)
     )`,
  );
  for (const tenant of isolatedTenants.rows) {
    await db.runWithTenantRow(tenant, async () => {
      await runClientRetentionSweepInScope(db, {
        tenantId: tenant.id,
        io,
        scopeLabel: String(tenant.code || tenant.id || "tenant"),
      });
    });
  }
  return sharedSummary;
}

async function upsertUserShelf(queryable, userId, shelfNumber) {
  const normalizedShelf = Number(shelfNumber);
  if (!userId || !Number.isInteger(normalizedShelf) || normalizedShelf <= 0) {
    return;
  }
  await queryable.query(
    `INSERT INTO user_shelves (user_id, shelf_number, created_at, updated_at)
     VALUES ($1, $2, now(), now())
     ON CONFLICT (user_id) DO UPDATE
       SET shelf_number = EXCLUDED.shelf_number,
           updated_at = now()`,
    [userId, normalizedShelf],
  );
}

async function findDraftBatchId(queryable, tenantId = null) {
  const scopedTenantId = resolveTenantScopeId(tenantId);
  const activeBatchQ = await queryable.query(
    `SELECT id
     FROM delivery_batches
     WHERE status IN ('calling', 'couriers_assigned')
       AND (
         $1::uuid IS NULL
         OR EXISTS (
           SELECT 1
           FROM users bu
           WHERE bu.id = delivery_batches.created_by
             AND bu.tenant_id = $1::uuid
         )
         OR EXISTS (
           SELECT 1
           FROM delivery_batch_customers c2
           JOIN users u2 ON u2.id = c2.user_id
           WHERE c2.batch_id = delivery_batches.id
             AND u2.tenant_id = $1::uuid
         )
       )
     ORDER BY
       CASE status
         WHEN 'calling' THEN 0
         WHEN 'couriers_assigned' THEN 1
         ELSE 2
       END,
       created_at DESC
     LIMIT 1`,
    [scopedTenantId],
  );
  if (activeBatchQ.rowCount === 0) return null;
  return String(activeBatchQ.rows[0].id);
}

async function insertDeliveryBatchItems(
  queryable,
  batchId,
  batchCustomerId,
  items,
) {
  let inserted = 0;
  for (const item of items || []) {
    const result = await queryable.query(
      `INSERT INTO delivery_batch_items (
         id, batch_id, batch_customer_id, cart_item_id, user_id, product_id,
         quantity, unit_price, line_total, product_code, product_title,
         product_description, product_image_url, is_bulky, bulky_note, created_at
       )
       VALUES (
         $1, $2, $3, $4, $5, $6,
         $7, $8, $9, $10, $11,
         $12, $13, $14, NULLIF(BTRIM($15::text), ''), now()
       )
       ON CONFLICT (cart_item_id) DO NOTHING
       RETURNING id`,
      [
        uuidv4(),
        batchId,
        batchCustomerId,
        item.cart_item_id,
        item.user_id,
        item.product_id,
        item.quantity,
        item.unit_price,
        item.line_total,
        item.product_code,
        item.product_title,
        item.product_description,
        item.product_image_url,
        item.is_bulky === true,
        item.is_bulky === true ? String(item.product_title || '') : '',
      ],
    );
    inserted += result.rowCount || 0;
  }
  return inserted;
}

async function collectEligibleCustomers(queryable, tenantId = null) {
  const scopedTenantId = resolveTenantScopeId(tenantId);
  const claimsQ = await queryable.query(
    `SELECT cc.user_id::text AS user_id,
            COALESCE(
              SUM(
                CASE WHEN status = 'approved_return' THEN approved_amount ELSE 0 END
              ),
              0
            )::numeric AS claim_return_sum,
            COALESCE(
              SUM(
                CASE WHEN status = 'approved_discount' THEN approved_amount ELSE 0 END
              ),
              0
            )::numeric AS claim_discount_sum,
            COALESCE(SUM(approved_amount), 0)::numeric AS claims_total
     FROM customer_claims cc
     JOIN users u ON u.id = cc.user_id
     WHERE cc.status IN ('approved_return', 'approved_discount')
       AND ($1::uuid IS NULL OR u.tenant_id = $1::uuid)
     GROUP BY cc.user_id`,
    [scopedTenantId],
  );
  const claimsByUser = new Map();
  for (const row of claimsQ.rows) {
    claimsByUser.set(String(row.user_id || ""), {
      claim_return_sum: toMoney(row.claim_return_sum),
      claim_discount_sum: toMoney(row.claim_discount_sum),
      claims_total: toMoney(row.claims_total),
    });
  }

  const itemsQ = await queryable.query(
    `SELECT c.id AS cart_item_id,
            c.user_id::text AS user_id,
            c.product_id::text AS product_id,
            c.quantity,
            COALESCE(c.processing_mode, 'standard') AS processing_mode,
            c.created_at,
            c.updated_at,
            COALESCE(c.custom_price, p.price) AS price,
            p.product_code,
            p.title AS product_title,
            p.description AS product_description,
            p.image_url AS product_image_url,
            COALESCE(p.pickup_only, false) AS pickup_only,
            COALESCE(p.is_bulky, false) AS is_bulky,
            COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Клиент') AS customer_name,
            COALESCE(NULLIF(BTRIM(u.client_city), ''), '') AS client_city,
            COALESCE(ph.phone, '') AS customer_phone,
            us.shelf_number,
            addr.id::text AS address_id,
            addr.address_text,
            addr.address_ciphertext,
            addr.address_iv,
            addr.address_tag,
            addr.lat,
            addr.lng
     FROM cart_items c
     JOIN products p ON p.id = c.product_id
     JOIN users u ON u.id = c.user_id
     LEFT JOIN phones ph ON ph.user_id = c.user_id
     LEFT JOIN user_shelves us ON us.user_id = c.user_id
     LEFT JOIN LATERAL (
       SELECT a.id, a.address_text, a.lat, a.lng,
              a.address_ciphertext, a.address_iv, a.address_tag,
              a.entrance, a.comment, a.address_structured,
              a.provider, a.provider_address_id,
              a.validation_status, a.validation_confidence, a.point_source,
              a.mismatch_distance_meters,
              a.delivery_zone_id, a.delivery_zone_label, a.delivery_zone_status
       FROM user_delivery_addresses a
       WHERE a.user_id = c.user_id
       ORDER BY a.is_default DESC, a.updated_at DESC
       LIMIT 1
     ) AS addr ON true
     WHERE c.status = ANY($2::text[])
       AND p.deleted_at IS NULL
       AND COALESCE(p.status, '') <> 'deleted'
       AND ($1::uuid IS NULL OR u.tenant_id = $1::uuid)
       AND NOT EXISTS (
         SELECT 1
         FROM delivery_batch_items di_existing
         WHERE di_existing.cart_item_id = c.id
       )
       AND NOT EXISTS (
         SELECT 1
         FROM delivery_batch_items di
         JOIN delivery_batch_customers dbc ON dbc.id = di.batch_customer_id
         JOIN delivery_batches dbt ON dbt.id = di.batch_id
         WHERE di.cart_item_id = c.id
           AND dbt.status IN ('calling', 'couriers_assigned', 'handed_off')
           AND (
             $1::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users ux
               WHERE ux.id = dbc.user_id
                 AND ux.tenant_id = $1::uuid
             )
           )
           AND (
             COALESCE(dbc.call_status, '') IN ('pending', 'accepted', 'declined')
             OR COALESCE(dbc.delivery_status, '') IN (
               'awaiting_call',
               'offer_sent',
               'preparing_delivery',
               'handing_to_courier',
               'in_delivery'
             )
           )
       )
     ORDER BY c.user_id ASC, c.updated_at DESC, c.created_at DESC`,
    [scopedTenantId, ["processed", "pending_processing", "pending"]],
  );

  const grouped = new Map();
  for (const row of itemsQ.rows) {
    const key = String(row.user_id);
    const lineTotal = toMoney(Number(row.price) * Number(row.quantity));
    if (!grouped.has(key)) {
      grouped.set(key, {
        user_id: key,
        customer_name: row.customer_name,
        client_city: normalizeCityName(row.client_city),
        customer_phone: row.customer_phone,
        shelf_number:
          row.shelf_number == null ? null : Number(row.shelf_number) || null,
        address_id: row.address_id || null,
        address_text: decodeAddressFromRow(row) || "",
        lat: row.lat == null ? null : Number(row.lat),
        lng: row.lng == null ? null : Number(row.lng),
        entrance: String(row.entrance || "").trim(),
        comment: String(row.comment || "").trim(),
        address_structured: normalizeAddressStructured(
          row.address_structured,
          decodeAddressFromRow(row) || "",
        ),
        provider: String(row.provider || "").trim() || null,
        provider_address_id: String(row.provider_address_id || "").trim() || null,
        validation_status: normalizeValidationStatus(row.validation_status),
        validation_confidence: normalizeValidationConfidence(
          row.validation_confidence,
        ),
        point_source: normalizePointSource(row.point_source),
        mismatch_distance_meters:
          row.mismatch_distance_meters == null
            ? null
            : Math.max(0, Math.round(Number(row.mismatch_distance_meters) || 0)),
        delivery_zone_id: String(row.delivery_zone_id || "").trim() || null,
        delivery_zone_label: String(row.delivery_zone_label || "").trim() || null,
        delivery_zone_status: normalizeZoneStatus(row.delivery_zone_status),
        bulky_places: 0,
        bulky_titles: [],
        has_pickup_only: false,
        processed_sum: 0,
        processed_items_count: 0,
        items: [],
      });
    }
    const bucket = grouped.get(key);
    bucket.processed_sum = toMoney(bucket.processed_sum + lineTotal);
    bucket.processed_items_count += Number(row.quantity) || 0;
    if (row.is_bulky === true) {
      bucket.bulky_places += Number(row.quantity) || 1;
      bucket.bulky_titles.push(String(row.product_title || '').trim() || 'Габарит');
    }
    if (row.pickup_only === true) {
      bucket.has_pickup_only = true;
    }
    bucket.items.push({
      cart_item_id: row.cart_item_id,
      user_id: row.user_id,
      product_id: row.product_id,
      quantity: Number(row.quantity) || 0,
      processing_mode: String(row.processing_mode || "standard"),
      unit_price: toMoney(row.price),
      line_total: lineTotal,
      product_code: row.product_code == null ? null : Number(row.product_code),
      product_title: row.product_title,
      product_description: row.product_description,
      product_image_url: row.product_image_url,
      pickup_only: row.pickup_only === true,
      is_bulky: row.is_bulky === true,
      bulky_note: row.is_bulky === true ? row.product_title : null,
    });
  }
  return Array.from(grouped.values()).map((entry) => {
    const claimInfo = claimsByUser.get(String(entry.user_id)) || {
      claim_return_sum: 0,
      claim_discount_sum: 0,
      claims_total: 0,
    };
    const rawProcessed = toMoney(entry.processed_sum);
    const adjusted = toMoney(Math.max(0, rawProcessed - claimInfo.claims_total));
    const bulkyTitles = Array.isArray(entry.bulky_titles)
      ? entry.bulky_titles
      : [];
    const visibleBulkyTitles = bulkyTitles.slice(0, 3);
    const bulkyOverflow = Math.max(0, bulkyTitles.length - visibleBulkyTitles.length);
    return {
      ...entry,
      raw_processed_sum: rawProcessed,
      processed_sum: adjusted,
      bulky_note:
        visibleBulkyTitles.length == 0
          ? ""
          : `${visibleBulkyTitles.join(", ")}${
              bulkyOverflow > 0 ? ` +${bulkyOverflow}` : ""
            }`,
      claim_return_sum: toMoney(claimInfo.claim_return_sum),
      claim_discount_sum: toMoney(claimInfo.claim_discount_sum),
      claims_total: toMoney(claimInfo.claims_total),
    };
  });
}

async function buildEligiblePreview(queryable, settings, tenantId = null) {
  const thresholdAmount = Math.max(0, toMoney(settings?.threshold_amount, 1500));
  const grouped = await collectEligibleCustomers(queryable, tenantId);
  const allCustomers = grouped
    .map((entry) => {
      const rules = deliveryRulesForCustomer(settings, entry.client_city);
      const customerThreshold = rules.threshold_amount;
      return {
        ...entry,
        delivery_threshold_amount: customerThreshold,
        delivery_fee_amount: rules.delivery_fee_amount,
        city_rate_applied: rules.city_rate_applied,
        eligible_for_delivery: entry.processed_sum >= customerThreshold,
        amount_to_threshold: toMoney(
          Math.max(0, customerThreshold - entry.processed_sum),
        ),
      };
    })
    .sort((a, b) => b.processed_sum - a.processed_sum);
  const eligibleCustomers = allCustomers.filter((entry) => entry.eligible_for_delivery);
  return {
    threshold_amount: thresholdAmount,
    eligible_count: eligibleCustomers.length,
    below_threshold_count: allCustomers.length - eligibleCustomers.length,
    eligible_sum: toMoney(
      eligibleCustomers.reduce(
        (sum, customer) => sum + toMoney(customer.processed_sum),
        0,
      ),
    ),
    customers: eligibleCustomers,
  };
}

async function createDeliveryBatch(
  queryable,
  settings,
  createdBy,
  tenantId = null,
) {
  const scopedTenantId = resolveTenantScopeId(tenantId);
  const thresholdAmount = Math.max(0, toMoney(settings?.threshold_amount, 1500));
  const existingDraftBatchId = await findDraftBatchId(queryable, scopedTenantId);
  if (existingDraftBatchId) {
    return {
      created: false,
      batchId: existingDraftBatchId,
      eligible_total: 0,
      message: "Черновой лист доставки уже существует",
    };
  }

  const grouped = await collectEligibleCustomers(queryable, scopedTenantId);
  const candidates = grouped
    .map((entry) => ({
      ...entry,
      ...deliveryRulesForCustomer(settings, entry.client_city),
    }))
    .filter((entry) => entry.processed_sum >= entry.threshold_amount)
    .sort((a, b) => b.processed_sum - a.processed_sum);

  if (candidates.length === 0) {
    return {
      created: false,
      batchId: null,
      eligible_total: 0,
      message: "Нет клиентов, набравших сумму для доставки",
    };
  }

  const { date: nextDate, label } = nextDeliveryInfo(new Date());
  const deliveryDate = formatDateOnly(nextDate);
  const routeOrigin = effectiveOriginPoint({
    label: settings?.route_origin_label,
    address: settings?.route_origin_address,
    lat: settings?.route_origin_lat,
    lng: settings?.route_origin_lng,
  });

  const batchInsert = await queryable.query(
    `INSERT INTO delivery_batches (
       id, delivery_date, delivery_label, threshold_amount,
       route_origin_label, route_origin_address, route_origin_lat, route_origin_lng,
       status, courier_count, courier_names, created_by, created_at, updated_at
     )
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'calling', 0, '[]'::jsonb, $9, now(), now())
     RETURNING id`,
    [
      uuidv4(),
      deliveryDate,
      label,
      thresholdAmount,
      routeOrigin.label,
      routeOrigin.address || null,
      routeOrigin.lat,
      routeOrigin.lng,
      createdBy || null,
    ],
  );
  const batchId = String(batchInsert.rows[0].id);

  let createdCustomers = 0;
  for (const candidate of candidates) {
    const batchCustomerId = uuidv4();
    const addressPayload = buildAddressDbPayload(candidate);
    await queryable.query(
      `INSERT INTO delivery_batch_customers (
         id, batch_id, user_id, customer_name, customer_phone,
         processed_sum, claim_return_sum, claim_discount_sum, claims_total, processed_items_count, shelf_number,
         address_id, address_text, address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at,
         lat, lng, entrance, comment, address_structured, provider, provider_address_id,
         validation_status, validation_confidence, point_source, mismatch_distance_meters,
         delivery_zone_id, delivery_zone_label, delivery_zone_status,
         bulky_places, bulky_note,
         call_status, delivery_status, created_at, updated_at
       )
       VALUES (
         $1, $2, $3, $4, $5,
         $6, $7, $8, $9, $10, $11,
         $12, NULL, $13, $14, $15, $16, $17,
         $18, $19, $20, $21, $22::jsonb, $23, $24,
         $25, $26, $27, $28,
         $29, $30, $31,
         $32, $33,
         'pending', 'awaiting_call', now(), now()
       )`,
      [
        batchCustomerId,
        batchId,
        candidate.user_id,
        candidate.customer_name,
        candidate.customer_phone,
        candidate.processed_sum,
        candidate.claim_return_sum,
        candidate.claim_discount_sum,
        candidate.claims_total,
        candidate.processed_items_count,
        candidate.shelf_number,
        candidate.address_id,
        addressPayload.encrypted.ciphertext,
        addressPayload.encrypted.iv,
        addressPayload.encrypted.tag,
        addressPayload.encrypted.version,
        addressPayload.encrypted.encryptedAt,
        addressPayload.lat,
        addressPayload.lng,
        addressPayload.entrance,
        addressPayload.comment,
        JSON.stringify(addressPayload.address_structured),
        addressPayload.provider,
        addressPayload.provider_address_id,
        addressPayload.validation_status,
        addressPayload.validation_confidence,
        addressPayload.point_source,
        addressPayload.mismatch_distance_meters,
        addressPayload.delivery_zone_id,
        addressPayload.delivery_zone_label,
        addressPayload.delivery_zone_status,
        candidate.bulky_places || 0,
        candidate.bulky_note || null,
      ],
    );

    await queryable.query(
      `UPDATE delivery_batch_customers
       SET client_city = NULLIF($2, ''),
           delivery_threshold_amount = $3,
           delivery_fee_amount = $4
       WHERE id = $1`,
      [
        batchCustomerId,
        normalizeCityName(candidate.client_city),
        toMoney(candidate.threshold_amount, thresholdAmount),
        toMoney(candidate.delivery_fee_amount, 0),
      ],
    );

    const insertedItems = await insertDeliveryBatchItems(
      queryable,
      batchId,
      batchCustomerId,
      candidate.items,
    );
    if (insertedItems <= 0) {
      await queryable.query(
        `DELETE FROM delivery_batch_customers WHERE id = $1`,
        [batchCustomerId],
      );
      continue;
    }
    createdCustomers += 1;
  }

  if (createdCustomers === 0) {
    await queryable.query(`DELETE FROM delivery_batches WHERE id = $1`, [batchId]);
    return {
      created: false,
      batchId: null,
      eligible_total: 0,
      message: "Нет новых товаров для доставки",
    };
  }

  return {
    created: true,
    batchId,
    eligible_total: createdCustomers,
    message: "",
  };
}

async function addEligibleCustomersToBatch(
  queryable,
  batchId,
  thresholdAmount,
  settings = null,
  tenantId = null,
) {
  const scopedTenantId = resolveTenantScopeId(tenantId);
  const effectiveSettings = settings || { threshold_amount: thresholdAmount };
  const grouped = await collectEligibleCustomers(queryable, scopedTenantId);
  const candidates = grouped
    .map((entry) => ({
      ...entry,
      ...deliveryRulesForCustomer(effectiveSettings, entry.client_city),
    }))
    .filter((entry) => entry.processed_sum >= entry.threshold_amount)
    .sort((a, b) => b.processed_sum - a.processed_sum);
  if (candidates.length === 0) return 0;

  const existingUsersQ = await queryable.query(
    `SELECT id::text AS id,
            user_id::text AS user_id,
            COALESCE(call_status, '') AS call_status,
            COALESCE(delivery_status, '') AS delivery_status
     FROM delivery_batch_customers
     WHERE batch_id = $1`,
    [batchId],
  );
  const existingUsers = new Map();
  for (const row of existingUsersQ.rows) {
    const key = String(row.user_id);
    if (!existingUsers.has(key)) existingUsers.set(key, []);
    existingUsers.get(key).push(row);
  }

  let addedTotal = 0;
  for (const candidate of candidates) {
    const existingRows = existingUsers.get(candidate.user_id) || [];
    const reusableRow =
      existingRows.find(
        (row) =>
          row.call_status === "removed" ||
          row.delivery_status === "returned_to_cart",
      ) || null;
    const hasBlockingRow = existingRows.some(
      (row) =>
        row.call_status !== "removed" &&
        row.delivery_status !== "returned_to_cart",
    );
    if (hasBlockingRow && !reusableRow) continue;

    if (reusableRow) {
      const addressPayload = buildAddressDbPayload(candidate);
      await queryable.query(
        `UPDATE delivery_batch_customers
         SET customer_name = $2,
             customer_phone = $3,
             processed_sum = $4,
             claim_return_sum = $5,
             claim_discount_sum = $6,
             claims_total = $7,
             processed_items_count = $8,
             shelf_number = $9,
             address_id = $10,
             address_text = NULL,
             address_ciphertext = $11,
             address_iv = $12,
             address_tag = $13,
             address_encryption_version = $14,
             address_encrypted_at = $15,
             lat = $16,
             lng = $17,
             entrance = $18,
             comment = $19,
             address_structured = $20::jsonb,
             provider = $21,
             provider_address_id = $22,
             validation_status = $23,
             validation_confidence = $24,
             point_source = $25,
             mismatch_distance_meters = $26,
             delivery_zone_id = $27,
             delivery_zone_label = $28,
             delivery_zone_status = $29,
             call_status = 'pending',
             delivery_status = 'awaiting_call',
             courier_slot = NULL,
             courier_name = NULL,
             courier_code = NULL,
             route_order = NULL,
             eta_from = NULL,
             eta_to = NULL,
             preferred_time_from = NULL,
             preferred_time_to = NULL,
             bulky_places = $30,
             bulky_note = $31,
             locked_courier_slot = NULL,
             locked_courier_name = NULL,
             locked_courier_code = NULL,
             updated_at = now()
         WHERE id = $1`,
        [
          reusableRow.id,
          candidate.customer_name,
          candidate.customer_phone,
          candidate.processed_sum,
          candidate.claim_return_sum,
          candidate.claim_discount_sum,
          candidate.claims_total,
          candidate.processed_items_count,
          candidate.shelf_number,
          candidate.address_id,
          addressPayload.encrypted.ciphertext,
          addressPayload.encrypted.iv,
          addressPayload.encrypted.tag,
          addressPayload.encrypted.version,
          addressPayload.encrypted.encryptedAt,
          addressPayload.lat,
          addressPayload.lng,
          addressPayload.entrance,
          addressPayload.comment,
          JSON.stringify(addressPayload.address_structured),
          addressPayload.provider,
          addressPayload.provider_address_id,
          addressPayload.validation_status,
          addressPayload.validation_confidence,
          addressPayload.point_source,
          addressPayload.mismatch_distance_meters,
          addressPayload.delivery_zone_id,
          addressPayload.delivery_zone_label,
          addressPayload.delivery_zone_status,
          candidate.bulky_places || 0,
          candidate.bulky_note || null,
        ],
      );

      await queryable.query(
        `DELETE FROM delivery_batch_items
         WHERE batch_customer_id = $1`,
        [reusableRow.id],
      );
      await queryable.query(
        `UPDATE delivery_batch_customers
         SET client_city = NULLIF($2, ''),
             delivery_threshold_amount = $3,
             delivery_fee_amount = $4
         WHERE id = $1`,
        [
          reusableRow.id,
          normalizeCityName(candidate.client_city),
          toMoney(candidate.threshold_amount, thresholdAmount),
          toMoney(candidate.delivery_fee_amount, 0),
        ],
      );
      const insertedItems = await insertDeliveryBatchItems(
        queryable,
        batchId,
        reusableRow.id,
        candidate.items,
      );
      if (insertedItems <= 0) {
        await queryable.query(
          `DELETE FROM delivery_batch_customers WHERE id = $1`,
          [reusableRow.id],
        );
        continue;
      }
      addedTotal += 1;
      continue;
    }

    const batchCustomerId = uuidv4();
    const addressPayload = buildAddressDbPayload(candidate);
    await queryable.query(
      `INSERT INTO delivery_batch_customers (
         id, batch_id, user_id, customer_name, customer_phone,
         processed_sum, claim_return_sum, claim_discount_sum, claims_total, processed_items_count, shelf_number,
         address_id, address_text, address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at,
         lat, lng, entrance, comment, address_structured, provider, provider_address_id,
         validation_status, validation_confidence, point_source, mismatch_distance_meters,
         delivery_zone_id, delivery_zone_label, delivery_zone_status,
         bulky_places, bulky_note,
         call_status, delivery_status, created_at, updated_at
       )
       VALUES (
         $1, $2, $3, $4, $5,
         $6, $7, $8, $9, $10, $11,
         $12, NULL, $13, $14, $15, $16, $17,
         $18, $19, $20, $21, $22::jsonb, $23, $24,
         $25, $26, $27, $28,
         $29, $30, $31,
         $32, $33,
         'pending', 'awaiting_call', now(), now()
       )`,
      [
        batchCustomerId,
        batchId,
        candidate.user_id,
        candidate.customer_name,
        candidate.customer_phone,
        candidate.processed_sum,
        candidate.claim_return_sum,
        candidate.claim_discount_sum,
        candidate.claims_total,
        candidate.processed_items_count,
        candidate.shelf_number,
        candidate.address_id,
        addressPayload.encrypted.ciphertext,
        addressPayload.encrypted.iv,
        addressPayload.encrypted.tag,
        addressPayload.encrypted.version,
        addressPayload.encrypted.encryptedAt,
        addressPayload.lat,
        addressPayload.lng,
        addressPayload.entrance,
        addressPayload.comment,
        JSON.stringify(addressPayload.address_structured),
        addressPayload.provider,
        addressPayload.provider_address_id,
        addressPayload.validation_status,
        addressPayload.validation_confidence,
        addressPayload.point_source,
        addressPayload.mismatch_distance_meters,
        addressPayload.delivery_zone_id,
        addressPayload.delivery_zone_label,
        addressPayload.delivery_zone_status,
        candidate.bulky_places || 0,
        candidate.bulky_note || null,
      ],
    );

    await queryable.query(
      `UPDATE delivery_batch_customers
       SET client_city = NULLIF($2, ''),
           delivery_threshold_amount = $3,
           delivery_fee_amount = $4
       WHERE id = $1`,
      [
        batchCustomerId,
        normalizeCityName(candidate.client_city),
        toMoney(candidate.threshold_amount, thresholdAmount),
        toMoney(candidate.delivery_fee_amount, 0),
      ],
    );

    const insertedItems = await insertDeliveryBatchItems(
      queryable,
      batchId,
      batchCustomerId,
      candidate.items,
    );
    if (insertedItems <= 0) {
      await queryable.query(
        `DELETE FROM delivery_batch_customers WHERE id = $1`,
        [batchCustomerId],
      );
      continue;
    }

    existingUsers.set(candidate.user_id, [
      ...(existingUsers.get(candidate.user_id) || []),
      {
        id: batchCustomerId,
        user_id: candidate.user_id,
        call_status: "pending",
        delivery_status: "awaiting_call",
      },
    ]);
    addedTotal += 1;
  }

  return addedTotal;
}

async function ensureDeliveryChat(queryable, userId, createdBy, tenantId = null) {
  const settings = {
    kind: "delivery_dialog",
    visibility: "private",
    system_key: "delivery_dialog",
    description: "Системный диалог по доставке",
  };
  const existingQ = await queryable.query(
    `SELECT c.id,
            c.title,
            c.type,
            c.settings,
            c.created_at,
            c.updated_at,
            EXISTS(
              SELECT 1
              FROM messages m
              WHERE m.chat_id = c.id
                AND COALESCE(m.meta->>'kind', '') = 'delivery_offer'
                AND COALESCE(m.meta->>'offer_status', 'pending') = 'pending'
            ) AS has_pending_offer
     FROM chats c
     JOIN chat_members cm ON cm.chat_id = c.id
     WHERE cm.user_id = $1
       AND (
         ($2::uuid IS NULL AND c.tenant_id IS NULL)
         OR c.tenant_id = $2::uuid
       )
       AND ${deliveryDialogWhere("c")}
     ORDER BY
       CASE
         WHEN EXISTS(
           SELECT 1
           FROM messages m
           WHERE m.chat_id = c.id
             AND COALESCE(m.meta->>'kind', '') = 'delivery_offer'
             AND COALESCE(m.meta->>'offer_status', 'pending') = 'pending'
         ) THEN 0
         ELSE 1
       END,
       c.updated_at DESC NULLS LAST,
       c.created_at DESC,
       c.id DESC`,
    [userId, tenantId || null],
  );
  if (existingQ.rowCount > 0) {
    const [primary, ...duplicates] = existingQ.rows;
    const duplicateIds = duplicates
      .map((row) => row.id?.toString())
      .filter((id) => id && id !== primary.id);
    if (duplicateIds.length > 0) {
      await queryable.query(
        `DELETE FROM chats
         WHERE id = ANY($1::uuid[])`,
        [duplicateIds],
      );
    }
    if (!primary.has_pending_offer) {
      await queryable.query(
        `DELETE FROM messages
         WHERE chat_id = $1`,
        [primary.id],
      );
    }
    await queryable.query(
      `UPDATE chats
       SET title = 'Доставка',
           tenant_id = COALESCE(tenant_id, $3::uuid),
           settings = $2::jsonb,
           updated_at = now()
       WHERE id = $1`,
      [primary.id, JSON.stringify(settings), tenantId || null],
    );
    const refreshedQ = await queryable.query(
      `SELECT id, title, type, settings, created_at, updated_at
       FROM chats
       WHERE id = $1
       LIMIT 1`,
      [primary.id],
    );
    return {
      chat: refreshedQ.rows[0],
      created: false,
      deletedChatIds: duplicateIds,
    };
  }

  const chatInsert = await queryable.query(
    `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
     VALUES ($1, $2, 'private', $3, $4, $5::jsonb, now(), now())
     RETURNING id, title, type, settings, created_at, updated_at`,
    [
      uuidv4(),
      "Доставка",
      createdBy || null,
      tenantId || null,
      JSON.stringify(settings),
    ],
  );
  const chat = chatInsert.rows[0];
  await queryable.query(
    `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
     VALUES ($1, $2, $3, now(), 'member')
     ON CONFLICT (chat_id, user_id) DO NOTHING`,
    [uuidv4(), chat.id, userId],
  );
  return { chat, created: true, deletedChatIds: [] };
}

async function markDeliveryChatForAutoDelete(
  queryable,
  chatId,
  delayMs = DELIVERY_DIALOG_AUTO_DELETE_MS,
) {
  if (!chatId) return null;
  const deleteAt = new Date(Date.now() + Math.max(1000, delayMs));
  await queryable.query(
    `UPDATE chats
     SET settings = jsonb_set(
           COALESCE(settings, '{}'::jsonb),
           '{auto_delete_after}',
           to_jsonb($2::text),
           true
         ),
         updated_at = now()
     WHERE id = $1`,
    [chatId, deleteAt.toISOString()],
  );
  return deleteAt.toISOString();
}

async function deleteDeliveryChatsByIds(queryable, chatIds) {
  const uniqueIds = [
    ...new Set(
      (chatIds || [])
        .map((id) => String(id || "").trim())
        .filter(Boolean),
    ),
  ];
  if (uniqueIds.length === 0) return [];
  const membersQ = await queryable.query(
    `SELECT chat_id::text AS chat_id, user_id::text AS user_id
     FROM chat_members
     WHERE chat_id = ANY($1::uuid[])`,
    [uniqueIds],
  );
  await queryable.query(
    `DELETE FROM chats
     WHERE id = ANY($1::uuid[])`,
    [uniqueIds],
  );
  const userIdsByChat = new Map();
  for (const row of membersQ.rows) {
    const chatId = String(row.chat_id);
    const current = userIdsByChat.get(chatId) || [];
    current.push(String(row.user_id));
    userIdsByChat.set(chatId, current);
  }
  return uniqueIds.map((chatId) => ({
    chatId,
    userIds: [...new Set(userIdsByChat.get(chatId) || [])],
  }));
}

function emitDeletedDeliveryChats(io, deletedChats) {
  if (!io || !Array.isArray(deletedChats) || deletedChats.length === 0) return;
  for (const item of deletedChats) {
    for (const userId of item.userIds || []) {
      io.to(`user:${userId}`).emit("chat:deleted", {
        chatId: item.chatId,
      });
    }
  }
}

async function cleanupExpiredDeliveryChats(
  queryable = db,
  io = deliveryDialogCleanupIo,
) {
  const expiredQ = await queryable.query(
    `SELECT c.id::text AS chat_id
     FROM chats c
     WHERE ${deliveryDialogWhere("c")}
       AND NULLIF(BTRIM(COALESCE(c.settings->>'auto_delete_after', '')), '')::timestamptz <= now()
       AND NOT EXISTS (
         SELECT 1
         FROM messages m
         WHERE m.chat_id = c.id
           AND COALESCE(m.meta->>'kind', '') = 'delivery_offer'
           AND COALESCE(m.meta->>'offer_status', 'pending') = 'pending'
       )`,
  );
  const deletedChats = await deleteDeliveryChatsByIds(
    queryable,
    expiredQ.rows.map((row) => row.chat_id),
  );
  emitDeletedDeliveryChats(io, deletedChats);
  return deletedChats.length;
}

async function cleanupDuplicateDeliveryChats(
  queryable = db,
  io = deliveryDialogCleanupIo,
) {
  const duplicatesQ = await queryable.query(
    `SELECT c.id::text AS chat_id,
            cm.user_id::text AS user_id,
            c.updated_at,
            c.created_at
     FROM chats c
     JOIN chat_members cm ON cm.chat_id = c.id
     WHERE ${deliveryDialogWhere("c")}
     ORDER BY
       cm.user_id,
       CASE
         WHEN EXISTS(
           SELECT 1
           FROM messages m
           WHERE m.chat_id = c.id
             AND COALESCE(m.meta->>'kind', '') = 'delivery_offer'
             AND COALESCE(m.meta->>'offer_status', 'pending') = 'pending'
         ) THEN 0
         ELSE 1
       END,
       c.updated_at DESC NULLS LAST,
       c.created_at DESC,
       c.id DESC`,
  );
  const keepByUser = new Set();
  const duplicateIds = [];
  for (const row of duplicatesQ.rows) {
    const userId = String(row.user_id);
    if (!keepByUser.has(userId)) {
      keepByUser.add(userId);
      continue;
    }
    duplicateIds.push(String(row.chat_id));
  }
  const deletedChats = await deleteDeliveryChatsByIds(queryable, duplicateIds);
  emitDeletedDeliveryChats(io, deletedChats);
  return deletedChats.length;
}

async function runDeliveryDialogCleanup(io = deliveryDialogCleanupIo) {
  if (deliveryDialogCleanupRunning) return;
  deliveryDialogCleanupRunning = true;
  try {
    await cleanupDuplicateDeliveryChats(db, io);
    await cleanupExpiredDeliveryChats(db, io);
    const isolatedTenants = await db.platformQuery(
      `SELECT id, code, db_mode, db_url, db_name, db_schema, status, subscription_expires_at
       FROM tenants
       WHERE (
         (db_mode = 'isolated' AND db_url IS NOT NULL)
         OR (db_mode = 'schema_isolated' AND db_schema IS NOT NULL)
       )`,
    );
    for (const tenant of isolatedTenants.rows) {
      await db.runWithTenantRow(tenant, async () => {
        await cleanupDuplicateDeliveryChats(db, io);
        await cleanupExpiredDeliveryChats(db, io);
      });
    }
    const nowMs = Date.now();
    if (nowMs - lastClientRetentionSweepAt >= CLIENT_RETENTION_CLEANUP_INTERVAL_MS) {
      lastClientRetentionSweepAt = nowMs;
      await runClientRetentionSweep(io);
    }
  } catch (error) {
    console.error("delivery dialog cleanup error", error);
  } finally {
    deliveryDialogCleanupRunning = false;
  }
}

function startDeliveryDialogCleanup(io) {
  deliveryDialogCleanupIo = io || deliveryDialogCleanupIo;
  if (deliveryDialogCleanupTimer) return;
  deliveryDialogCleanupTimer = setInterval(() => {
    runDeliveryDialogCleanup(deliveryDialogCleanupIo);
  }, DELIVERY_DIALOG_CLEANUP_INTERVAL_MS);
  if (typeof deliveryDialogCleanupTimer.unref === "function") {
    deliveryDialogCleanupTimer.unref();
  }
  setImmediate(() => {
    runDeliveryDialogCleanup(deliveryDialogCleanupIo);
  });
}

async function hydrateSystemMessage(queryable, messageId) {
  const result = await queryable.query(
    `SELECT m.id,
            m.chat_id,
            m.sender_id,
            m.text,
            m.meta,
            m.created_at,
            false AS from_me,
            false AS is_read_by_me,
            false AS read_by_others,
            0::int AS read_count,
            'Система'::text AS sender_name,
            NULL::text AS sender_email,
            NULL::text AS sender_avatar_url,
            0::float8 AS sender_avatar_focus_x,
            0::float8 AS sender_avatar_focus_y,
            1::float8 AS sender_avatar_zoom
     FROM messages m
     WHERE m.id = $1
     LIMIT 1`,
    [messageId],
  );
  return decryptMessageRow(result.rows[0] || null);
}

function buildDeliveryOfferText(customer, batch) {
  const phone = String(customer.customer_phone || "—").trim() || "—";
  const amount = toMoney(customer.processed_sum);
  return [
    batch.delivery_label || "Доставка",
    `Номер телефона: ${phone}`,
    `Обработано товара на сумму: ${amount} ₽`,
    "Согласны принять доставку?",
    "Если да, нажмите кнопку подтверждения и отправьте адрес доставки.",
    "Доставка обычно идет с 10:00 до 16:00. При желании укажите время 'после' или 'до'.",
  ].join("\n");
}

function buildPickupOnlyDeliveryBlockedText(customer) {
  const amount = toMoney(customer.processed_sum);
  return [
    "В вашей корзине есть товар только для самовывоза.",
    "Такую корзину нельзя отгрузить курьеру.",
    `Сумма обработанных товаров: ${amount} ₽`,
    "Пожалуйста, заберите корзину самовывозом или свяжитесь с администратором.",
  ].join("\n");
}

function buildDeliveryAcceptedText(addressText, preferredFrom, preferredTo) {
  const windowLabel =
    preferredFrom || preferredTo
      ? `Пожелание по времени: ${
          [
            preferredFrom ? `после ${preferredFrom}` : null,
            preferredTo ? `до ${preferredTo}` : null,
          ]
            .filter(Boolean)
            .join(", ")
        }`
      : null;
  return [
    "Доставка подтверждена.",
    addressText ? `Адрес: ${addressText}` : null,
    windowLabel,
    "Мы готовим ваш заказ к отправке.",
  ]
    .filter(Boolean)
    .join("\n");
}

function buildDeliveryDeclinedText() {
  return "Хорошо, свяжемся с вами в следующий раз.";
}

function buildDeliveryAutoDismantledText(autoResult) {
  const removedCount = Number(autoResult?.removed_items_count || 0);
  const daysHeld = Number(autoResult?.retention?.days_held || 0);
  const thresholdDays = Number(autoResult?.retention?.threshold_days || CART_RETENTION_WARNING_DAYS);
  return [
    "Доставка отклонена.",
    `Корзина была расформирована автоматически, так как держалась ${daysHeld} дн. при лимите ${thresholdDays} дн.`,
    removedCount > 0
      ? `Удалено позиций: ${removedCount}.`
      : "Позиции корзины были очищены.",
  ].join("\n");
}

function formatDeliveryPreferenceLabel(preferredFrom, preferredTo) {
  const fromText = String(preferredFrom || "").trim().slice(0, 5);
  const toText = String(preferredTo || "").trim().slice(0, 5);
  const defaultFrom = "10:00";
  const defaultTo = "16:00";
  if (!fromText && !toText) return "";
  if (fromText && toText) {
    if (fromText === defaultFrom && toText !== defaultTo) {
      return `До ${toText}`;
    }
    if (toText === defaultTo && fromText !== defaultFrom) {
      return `После ${fromText}`;
    }
    if (fromText === defaultFrom && toText === defaultTo) {
      return "";
    }
    return `С ${fromText} до ${toText}`;
  }
  if (toText) return `До ${toText}`;
  if (fromText) return `После ${fromText}`;
  return "";
}

async function rerouteAcceptedCustomers(queryable, batchId) {
  const batchQ = await queryable.query(
    `SELECT id,
            delivery_date,
            status,
            courier_names,
            route_origin_label,
            route_origin_address,
            route_origin_lat,
            route_origin_lng
     FROM delivery_batches
     WHERE id = $1
     LIMIT 1`,
    [batchId],
  );
  if (batchQ.rowCount === 0) return { rerouted: false, batchStatus: "" };
  const batch = batchQ.rows[0];
  const batchStatus = String(batch.status || "");
  const courierNames = Array.isArray(batch.courier_names)
    ? batch.courier_names.map((item) => String(item || "").trim()).filter(Boolean)
    : [];
  if (batchStatus !== "couriers_assigned" || courierNames.length === 0) {
    return { rerouted: false, batchStatus };
  }

  const customersQ = await queryable.query(
    `SELECT *
     FROM delivery_batch_customers
     WHERE batch_id = $1
       AND call_status = 'accepted'
       AND COALESCE(route_excluded, false) = false
       AND COALESCE(self_pickup, false) = false
     ORDER BY customer_name ASC`,
    [batchId],
  );
  if (customersQ.rowCount === 0) {
    return { rerouted: false, batchStatus };
  }

  await queryable.query(
    `UPDATE delivery_batch_customers
     SET courier_slot = NULL,
         courier_name = NULL,
         courier_code = NULL,
         route_order = NULL,
         eta_from = NULL,
         eta_to = NULL,
         delivery_status = 'preparing_delivery',
         updated_at = now()
     WHERE batch_id = $1
       AND call_status = 'accepted'
       AND COALESCE(route_excluded, false) = false
       AND COALESCE(self_pickup, false) = false`,
    [batchId],
  );

  const slots = distributeCustomersAcrossCouriers(customersQ.rows, courierNames, {
    label: batch.route_origin_label,
    address: batch.route_origin_address,
    lat: batch.route_origin_lat,
    lng: batch.route_origin_lng,
  });

  for (const slot of slots) {
    for (let i = 0; i < slot.items.length; i += 1) {
      const customer = slot.items[i];
      const routeOrder = i + 1;
      const eta = buildEtaWindow(batch.delivery_date, customer.eta_minutes);
      await queryable.query(
        `UPDATE delivery_batch_customers
         SET courier_slot = $1,
             courier_name = $2,
             courier_code = $3,
             route_order = $4,
             eta_from = $5,
             eta_to = $6,
             delivery_status = 'handing_to_courier',
             updated_at = now()
         WHERE id = $7`,
        [
          slot.slot,
          slot.name,
          firstLetterCode(slot.name),
          routeOrder,
          eta.eta_from,
          eta.eta_to,
          customer.id,
        ],
      );
    }
  }

  await queryable.query(
    `UPDATE cart_items
     SET status = 'handing_to_courier',
         updated_at = now()
     WHERE id IN (
       SELECT i.cart_item_id
       FROM delivery_batch_items i
       JOIN delivery_batch_customers c ON c.id = i.batch_customer_id
       WHERE i.batch_id = $1
         AND c.call_status = 'accepted'
         AND COALESCE(c.route_excluded, false) = false
         AND COALESCE(c.self_pickup, false) = false
     )`,
    [batchId],
  );

  await queryable.query(
    `UPDATE delivery_batches
     SET updated_at = now()
     WHERE id = $1`,
    [batchId],
  );

  return { rerouted: true, batchStatus };
}

function normalizePhone(value) {
  return String(value || "").replace(/\D+/g, "");
}

function normalizePhoneCore(value) {
  const digits = normalizePhone(value);
  if (digits.length >= 10) return digits.slice(-10);
  return digits;
}

function parseManualProcessingPhones(raw) {
  const source = Array.isArray(raw)
    ? raw
    : String(raw || "")
        .split(/[\s,;]+/g)
        .map((item) => item.trim());
  const seen = new Set();
  const entries = [];
  for (const value of source) {
    const rawPhone = String(value || "").trim();
    if (!rawPhone) continue;
    const phoneCore = normalizePhoneCore(rawPhone);
    if (phoneCore.length !== 10 || seen.has(phoneCore)) continue;
    seen.add(phoneCore);
    entries.push({
      ord: entries.length,
      raw_phone: rawPhone,
      phone_core: phoneCore,
    });
  }
  return entries;
}

async function findUserByPhone(queryable, phone, tenantId = null) {
  const normalized = normalizePhone(phone);
  if (!normalized) return null;
  const result = await queryable.query(
    `SELECT u.id::text AS user_id,
            COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Клиент') AS customer_name,
            ph.phone AS customer_phone
     FROM phones ph
     JOIN users u ON u.id = ph.user_id
     WHERE regexp_replace(COALESCE(ph.phone, ''), '\D+', '', 'g') = $1
       AND ($2::uuid IS NULL OR u.tenant_id = $2::uuid)
     LIMIT 1`,
    [normalized, tenantId || null],
  );
  return result.rows[0] || null;
}

async function collectEligibleCustomerForUser(queryable, userId, tenantId = null) {
  const customers = await collectEligibleCustomers(queryable, tenantId);
  return customers.find((entry) => String(entry.user_id) === String(userId)) || null;
}

async function fetchDeliveryCustomerForAssembly(
  queryable,
  batchId,
  customerId,
  tenantId = null,
  { forUpdate = false } = {},
) {
  const customerQ = await queryable.query(
    `SELECT c.*
     FROM delivery_batch_customers c
     JOIN users u ON u.id = c.user_id
     WHERE c.batch_id = $1
       AND c.id = $2
       AND ($3::uuid IS NULL OR u.tenant_id = $3::uuid)
     LIMIT 1
     ${forUpdate ? "FOR UPDATE OF c" : ""}`,
    [batchId, customerId, tenantId || null],
  );
  if (customerQ.rowCount === 0) return null;
  const itemsQ = await queryable.query(
    `SELECT i.*
     FROM delivery_batch_items i
     WHERE i.batch_id = $1
       AND i.batch_customer_id = $2
     ORDER BY i.created_at ASC
     ${forUpdate ? "FOR UPDATE OF i" : ""}`,
    [batchId, customerId],
  );
  return {
    ...customerQ.rows[0],
    items: itemsQ.rows,
  };
}

function normalizeAssemblyItemsPayload(rawItems) {
  if (!Array.isArray(rawItems)) return [];
  return rawItems
    .map((raw) => {
      const item = normalizeJsonObject(raw);
      const id = String(item.id || item.delivery_item_id || "").trim();
      if (!id) return null;
      const rawStatus = String(item.assembly_status || item.status || "").trim();
      const collected =
        item.collected === true ||
        rawStatus === "collected" ||
        rawStatus === "done";
      return {
        id,
        is_bulky: item.is_bulky === true,
        removed: item.removed === true || item.assembly_status === "removed",
        collected,
        removed_reason: String(item.removed_reason || "").trim().slice(0, 240),
        bulky_note: String(item.bulky_note || "").trim().slice(0, 240),
      };
    })
    .filter(Boolean);
}

async function recalculateDeliveryCustomerTotals(queryable, customerId) {
  const totalsQ = await queryable.query(
    `SELECT COALESCE(SUM(line_total) FILTER (WHERE assembly_status <> 'removed'), 0)::numeric AS sum,
            COALESCE(SUM(quantity) FILTER (WHERE assembly_status <> 'removed'), 0)::int AS count,
            COALESCE(COUNT(*) FILTER (WHERE assembly_status <> 'removed' AND is_bulky = true), 0)::int AS bulky_places,
            STRING_AGG(
              DISTINCT NULLIF(BTRIM(COALESCE(bulky_note, product_title, '')), ''),
              ', '
            ) FILTER (WHERE assembly_status <> 'removed' AND is_bulky = true) AS bulky_note
     FROM delivery_batch_items
     WHERE batch_customer_id = $1`,
    [customerId],
  );
  const row = totalsQ.rows[0] || {};
  const nextSum = toMoney(row.sum);
  const nextCount = Math.max(0, Number(row.count) || 0);
  const bulkyPlaces = Math.max(0, Number(row.bulky_places) || 0);
  await queryable.query(
    `UPDATE delivery_batch_customers
     SET processed_sum = $2,
         agreed_sum = CASE WHEN call_status = 'accepted' THEN $2 ELSE agreed_sum END,
         processed_items_count = $3,
         bulky_places = $4,
         bulky_note = NULLIF(BTRIM($5::text), ''),
         updated_at = now()
     WHERE id = $1`,
    [
      customerId,
      nextSum,
      nextCount,
      bulkyPlaces,
      String(row.bulky_note || "").slice(0, 240),
    ],
  );
  return {
    processed_sum: nextSum,
    processed_items_count: nextCount,
    bulky_places: bulkyPlaces,
    bulky_note: String(row.bulky_note || "").slice(0, 240),
  };
}

async function createDefectReportForDeliveryItem(
  queryable,
  { tenantId, item, reason, actorId },
) {
  await queryable.query(
    `INSERT INTO product_defect_reports (
       id, tenant_id, product_id, reported_by, created_by, title, reason,
       image_url, amount, status, created_at, updated_at
     )
     VALUES ($1, $2, $3, NULL, $4, $5, $6, $7, $8, 'active', now(), now())`,
    [
      uuidv4(),
      tenantId || null,
      item.product_id || null,
      actorId || null,
      String(item.product_title || "Товар").trim() || "Товар",
      reason || "Убран при сборке доставки",
      item.product_image_url || null,
      toMoney(item.line_total),
    ],
  );
}

async function createManualPhoneSelfPickupArchive(
  queryable,
  {
    actorUserId,
    tenantId = null,
    deliveryDate = new Date(),
    pickupNote,
    rows = [],
  },
) {
  const sourceRows = Array.isArray(rows)
    ? rows.filter((row) => row && !String(row.existing_delivery_item_id || "").trim())
    : [];
  const normalizedDeliveryDate = formatSamaraDateOnly(deliveryDate);
  const deliveryLabel = buildSelfPickupDeliveryLabel(deliveryDate);
  if (sourceRows.length === 0) {
    return {
      batchId: null,
      deliveryDate: normalizedDeliveryDate,
      deliveryLabel,
      archivedItems: 0,
      archivedCartItemIds: [],
      customerIds: [],
    };
  }

  const settings = await getDeliverySettings(queryable, tenantId);
  const existingBatchQ = await queryable.query(
    `SELECT b.id
     FROM delivery_batches b
     WHERE b.delivery_date = $1::date
       AND b.delivery_label = $2
       AND COALESCE(b.status, '') = 'completed'
       AND (
         $3::uuid IS NULL
         OR EXISTS (
           SELECT 1
           FROM users bu
           WHERE bu.id = b.created_by
             AND bu.tenant_id = $3::uuid
         )
         OR EXISTS (
           SELECT 1
           FROM delivery_batch_customers dbc
           JOIN users cu ON cu.id = dbc.user_id
           WHERE dbc.batch_id = b.id
             AND cu.tenant_id = $3::uuid
         )
       )
     ORDER BY b.created_at DESC
     LIMIT 1
     FOR UPDATE`,
    [normalizedDeliveryDate, deliveryLabel, tenantId || null],
  );

  let batchCreated = false;
  let batchId = existingBatchQ.rows[0]?.id
    ? String(existingBatchQ.rows[0].id)
    : "";
  if (!batchId) {
    const batchInsert = await queryable.query(
      `INSERT INTO delivery_batches (
         id, delivery_date, delivery_label, threshold_amount, status,
         courier_count, courier_names, created_by, confirmed_at,
         handed_off_at, completed_at, created_at, updated_at
       )
       VALUES (
         $1, $2::date, $3, $4, 'completed',
         0, '[]'::jsonb, $5, now(),
         now(), now(), now(), now()
       )
       RETURNING id`,
      [
        uuidv4(),
        normalizedDeliveryDate,
        deliveryLabel,
        toMoney(settings.threshold_amount, 1500),
        actorUserId || null,
      ],
    );
    batchId = String(batchInsert.rows[0].id);
    batchCreated = true;
  }

  const rowsByUserId = new Map();
  for (const row of sourceRows) {
    const userId = String(row.user_id || "").trim();
    if (!userId) continue;
    if (!rowsByUserId.has(userId)) rowsByUserId.set(userId, []);
    rowsByUserId.get(userId).push(row);
  }

  const archivedCartItemIds = [];
  const customerIds = [];
  let archivedItems = 0;
  for (const [userId, userRows] of rowsByUserId.entries()) {
    const first = userRows[0] || {};
    const items = [];
    let totalSum = 0;
    let itemCount = 0;
    for (const row of userRows) {
      const quantity = Math.max(1, Number(row.quantity) || 1);
      const unitPrice = toMoney(row.product_price);
      const lineTotal = toMoney(unitPrice * quantity);
      totalSum = toMoney(totalSum + lineTotal);
      itemCount += quantity;
      items.push({
        cart_item_id: row.cart_item_id,
        user_id: row.user_id,
        product_id: row.product_id,
        quantity,
        unit_price: unitPrice,
        line_total: lineTotal,
        product_code: row.product_code == null ? null : Number(row.product_code),
        product_title: row.product_title,
        product_description: row.product_description,
        product_image_url: row.product_image_url,
        is_bulky: row.is_bulky === true,
        bulky_note: row.is_bulky === true ? row.product_title : null,
      });
    }
    if (items.length === 0) continue;

    const clientCity = normalizeCityName(first.client_city);
    const rules = deliveryRulesForCustomer(settings, clientCity);
    const customerName =
      String(first.client_name || "").trim() ||
      String(first.email || "").trim() ||
      "Клиент";
    const customerPhone = String(first.stored_phone || "").trim();
    const shelfNumber =
      first.user_shelf_number == null
        ? null
        : Number(first.user_shelf_number) || null;
    const customerQ = await queryable.query(
      `INSERT INTO delivery_batch_customers (
         id, batch_id, user_id, customer_name, customer_phone,
         processed_sum, agreed_sum, claim_return_sum, claim_discount_sum,
         claims_total, processed_items_count, shelf_number,
         call_status, delivery_status, package_places, bulky_places,
         bulky_note, notes, accepted_at, assembly_status,
         assembly_started_at, assembly_started_by, assembly_completed_at,
         assembly_completed_by, client_city, delivery_threshold_amount,
         delivery_fee_amount, created_at, updated_at
       )
       VALUES (
         $1, $2, $3, $4, $5,
         $6, $6, 0, 0,
         0, $7, $8,
         'accepted', 'completed', 1, 0,
         NULL, $9, now(), 'assembled',
         now(), $10, now(),
         $10, NULLIF($11, ''), $12,
         $13, now(), now()
       )
       ON CONFLICT (batch_id, user_id) DO UPDATE
       SET customer_name = EXCLUDED.customer_name,
           customer_phone = EXCLUDED.customer_phone,
           call_status = 'accepted',
           delivery_status = 'completed',
           package_places = GREATEST(delivery_batch_customers.package_places, 1),
           bulky_places = 0,
           bulky_note = NULL,
           notes = CASE
             WHEN COALESCE(BTRIM(delivery_batch_customers.notes), '') = '' THEN EXCLUDED.notes
             WHEN delivery_batch_customers.notes LIKE '%' || EXCLUDED.notes || '%' THEN delivery_batch_customers.notes
             ELSE CONCAT(delivery_batch_customers.notes, E'\n', EXCLUDED.notes)
           END,
           accepted_at = COALESCE(delivery_batch_customers.accepted_at, now()),
           assembly_status = 'assembled',
           assembly_started_at = COALESCE(delivery_batch_customers.assembly_started_at, now()),
           assembly_started_by = COALESCE(delivery_batch_customers.assembly_started_by, $10),
           assembly_completed_at = now(),
           assembly_completed_by = $10,
           client_city = EXCLUDED.client_city,
           delivery_threshold_amount = EXCLUDED.delivery_threshold_amount,
           delivery_fee_amount = EXCLUDED.delivery_fee_amount,
           updated_at = now()
       RETURNING id`,
      [
        uuidv4(),
        batchId,
        userId,
        customerName,
        customerPhone,
        totalSum,
        itemCount,
        shelfNumber,
        pickupNote,
        actorUserId || null,
        clientCity,
        toMoney(rules.threshold_amount, settings.threshold_amount),
        toMoney(rules.delivery_fee_amount, 0),
      ],
    );
    const batchCustomerId = String(customerQ.rows[0].id);

    let insertedForCustomer = 0;
    for (const item of items) {
      const inserted = await queryable.query(
        `INSERT INTO delivery_batch_items (
           id, batch_id, batch_customer_id, cart_item_id, user_id, product_id,
           quantity, unit_price, line_total, product_code, product_title,
           product_description, product_image_url, assembly_status,
           is_bulky, bulky_note, removed_reason, removed_at, removed_by, created_at
         )
         VALUES (
           $1, $2, $3, $4, $5, $6,
           $7, $8, $9, $10, $11,
           $12, $13, 'collected',
           $14, NULLIF(BTRIM($15::text), ''), NULL, NULL, NULL, now()
         )
         ON CONFLICT (cart_item_id) DO NOTHING
         RETURNING id`,
        [
          uuidv4(),
          batchId,
          batchCustomerId,
          item.cart_item_id,
          item.user_id,
          item.product_id,
          item.quantity,
          item.unit_price,
          item.line_total,
          item.product_code,
          item.product_title,
          item.product_description,
          item.product_image_url,
          item.is_bulky === true,
          item.bulky_note || '',
        ],
      );
      if ((inserted.rowCount || 0) > 0) {
        insertedForCustomer += 1;
        archivedItems += 1;
        archivedCartItemIds.push(String(item.cart_item_id));
      }
    }

    if (insertedForCustomer > 0) {
      customerIds.push(batchCustomerId);
      await recalculateDeliveryCustomerTotals(queryable, batchCustomerId);
    }
  }

  if (archivedItems === 0) {
    if (batchCreated) {
      await queryable.query(`DELETE FROM delivery_batches WHERE id = $1`, [batchId]);
    }
    return {
      batchId: null,
      deliveryDate: normalizedDeliveryDate,
      deliveryLabel,
      archivedItems: 0,
      archivedCartItemIds: [],
      customerIds: [],
    };
  }

  await queryable.query(
    `UPDATE delivery_batches
     SET status = 'completed',
         confirmed_at = COALESCE(confirmed_at, now()),
         handed_off_at = COALESCE(handed_off_at, now()),
         completed_at = COALESCE(completed_at, now()),
         updated_at = now()
     WHERE id = $1`,
    [batchId],
  );

  return {
    batchId,
    deliveryDate: normalizedDeliveryDate,
    deliveryLabel,
    archivedItems,
    archivedCartItemIds,
    customerIds,
  };
}

router.post(
  "/manual-processing-by-phones",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const phoneEntries = parseManualProcessingPhones(
      req.body?.phones_text ?? req.body?.phones ?? req.body?.phone_numbers,
    );
    if (phoneEntries.length === 0) {
      return res.status(400).json({
        ok: false,
        error: "Введите хотя бы один полный номер телефона",
      });
    }

    const tenantId = req.user?.tenant_id || null;
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const processedByQ = await client.query(
        `SELECT name, email
         FROM users
         WHERE id = $1
         LIMIT 1`,
        [req.user.id],
      );
      const processedByName =
        String(processedByQ.rows[0]?.name || "").trim() ||
        String(processedByQ.rows[0]?.email || "").trim() ||
        "Администратор";

      const clientsQ = await client.query(
        `WITH input AS (
           SELECT *
           FROM jsonb_to_recordset($1::jsonb)
             AS x(ord int, raw_phone text, phone_core text)
         )
         SELECT i.ord,
                i.raw_phone,
                i.phone_core,
                u.id::text AS user_id,
                COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Клиент') AS client_name,
                u.email,
                ph.phone AS stored_phone
         FROM input i
         LEFT JOIN LATERAL (
           SELECT p.user_id, p.phone
           FROM phones p
           JOIN users pu ON pu.id = p.user_id
           WHERE RIGHT(regexp_replace(COALESCE(p.phone, ''), '[^0-9]+', '', 'g'), 10) = i.phone_core
             AND ($2::uuid IS NULL OR pu.tenant_id = $2::uuid)
             AND lower(COALESCE(pu.role, 'client')) = 'client'
           ORDER BY p.verified_at DESC NULLS LAST, p.created_at DESC NULLS LAST
           LIMIT 1
         ) ph ON true
         LEFT JOIN users u ON u.id = ph.user_id
         ORDER BY i.ord ASC`,
        [JSON.stringify(phoneEntries), tenantId],
      );

      const matchedUserIds = Array.from(
        new Set(
          clientsQ.rows
            .map((row) => String(row.user_id || "").trim())
            .filter(Boolean),
        ),
      );

      let itemRows = [];
      if (matchedUserIds.length > 0) {
        const itemsQ = await client.query(
          `SELECT c.id::text AS cart_item_id,
                  c.user_id::text AS user_id,
                  c.product_id::text AS product_id,
                  c.quantity,
                  c.status,
                  COALESCE(c.processing_mode, 'standard') AS processing_mode,
                  p.product_code,
                  p.shelf_number AS product_shelf_number,
                  p.title AS product_title,
                  p.description AS product_description,
                  p.image_url AS product_image_url,
                  COALESCE(p.is_bulky, false) AS is_bulky,
                  COALESCE(c.custom_price, p.price) AS product_price,
                  COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Клиент') AS client_name,
                  u.email,
                  COALESCE(NULLIF(BTRIM(u.client_city), ''), '') AS client_city,
                  COALESCE(ph.phone, '') AS stored_phone,
                  us.shelf_number AS user_shelf_number,
                  dbi.id::text AS existing_delivery_item_id,
                  dbi.batch_id::text AS existing_delivery_batch_id,
                  dbt.delivery_date AS existing_delivery_date,
                  dbt.delivery_label AS existing_delivery_label,
                  dbt.status AS existing_delivery_batch_status,
                  dbc.delivery_status AS existing_delivery_status
           FROM cart_items c
           JOIN products p ON p.id = c.product_id
           JOIN users u ON u.id = c.user_id
           LEFT JOIN phones ph ON ph.user_id = c.user_id
           LEFT JOIN user_shelves us ON us.user_id = c.user_id
           LEFT JOIN delivery_batch_items dbi ON dbi.cart_item_id = c.id
           LEFT JOIN delivery_batches dbt ON dbt.id = dbi.batch_id
           LEFT JOIN delivery_batch_customers dbc ON dbc.id = dbi.batch_customer_id
           WHERE c.user_id = ANY($1::uuid[])
             AND c.status = ANY($2::text[])
             AND ($3::uuid IS NULL OR u.tenant_id = $3::uuid)
             AND p.deleted_at IS NULL
             AND COALESCE(p.status, '') <> 'deleted'
           ORDER BY c.user_id ASC, p.shelf_number ASC NULLS LAST, p.product_code ASC NULLS LAST, c.updated_at DESC
           FOR UPDATE OF c`,
          [
            matchedUserIds,
            ["pending_processing", "pending", "processed"],
            tenantId,
          ],
        );
        itemRows = itemsQ.rows;
      }

      const shouldManuallyProcess = (status) =>
        ["pending_processing", "pending"].includes(String(status || "").trim());
      const cartItemIdsToProcess = itemRows
        .filter((row) => shouldManuallyProcess(row.status))
        .map((row) => String(row.cart_item_id || "").trim())
        .filter(Boolean);

      let updatedMessages = [];
      if (cartItemIdsToProcess.length > 0) {
        await client.query(
          `UPDATE cart_items
           SET status = 'processed',
               processing_mode = 'manual',
               updated_at = now()
           WHERE id = ANY($1::uuid[])`,
          [cartItemIdsToProcess],
        );

        await client.query(
          `UPDATE reservations
           SET is_fulfilled = true,
               is_sent = true,
               fulfilled_by_id = $2,
               fulfilled_at = now(),
               updated_at = now()
           WHERE cart_item_id = ANY($1::uuid[])`,
          [cartItemIdsToProcess, req.user.id],
        );

        const updatedMessagesQ = await client.query(
          `UPDATE messages
           SET meta = COALESCE(meta, '{}'::jsonb) || jsonb_build_object(
                 'placed', true,
                 'status', 'processed',
                 'processing_mode', 'manual',
                 'manual_processing', true,
                 'is_oversize', false,
                 'shelf_number', NULL::int,
                 'shelf_label', 'ручное',
                 'processed_by_id', $2::text,
                 'processed_by_name', $3::text
               )
           WHERE COALESCE(meta->>'kind', '') = 'reserved_order_item'
             AND COALESCE(meta->>'cart_item_id', '') = ANY($1::text[])
           RETURNING id, chat_id, sender_id, text, meta, created_at`,
          [cartItemIdsToProcess, String(req.user.id), processedByName],
        );
        updatedMessages = updatedMessagesQ.rows;
      }

      const itemsByUserId = new Map();
      const processedCartItemIdSet = new Set(cartItemIdsToProcess);
      for (const row of itemRows) {
        const userId = String(row.user_id || "");
        if (!itemsByUserId.has(userId)) itemsByUserId.set(userId, []);
        const cartItemId = String(row.cart_item_id || "").trim();
        const previousStatus = String(row.status || "").trim();
        const newlyProcessed = processedCartItemIdSet.has(cartItemId);
        const existingDeliveryItemId = String(row.existing_delivery_item_id || "").trim();
        itemsByUserId.get(userId).push({
          cart_item_id: cartItemId,
          product_id: row.product_id,
          product_code: row.product_code == null ? null : Number(row.product_code),
          product_shelf_number:
            row.product_shelf_number == null
              ? null
              : Number(row.product_shelf_number) || null,
          title: row.product_title,
          description: row.product_description,
          image_url: row.product_image_url,
          price: row.product_price,
          quantity: Number(row.quantity) || 1,
          previous_status: previousStatus,
          status: newlyProcessed ? "processed" : previousStatus,
          processing_mode: newlyProcessed ? "manual" : row.processing_mode,
          shelf_label: "ручное",
          newly_processed: newlyProcessed,
          already_processed: previousStatus === "processed",
          pickup_added: false,
          existing_delivery: Boolean(existingDeliveryItemId),
          existing_delivery_item_id: existingDeliveryItemId || null,
          existing_delivery_batch_id:
            String(row.existing_delivery_batch_id || "").trim() || null,
          existing_delivery_date: row.existing_delivery_date || null,
          existing_delivery_label:
            String(row.existing_delivery_label || "").trim() || null,
          existing_delivery_batch_status:
            String(row.existing_delivery_batch_status || "").trim() || null,
          existing_delivery_status:
            String(row.existing_delivery_status || "").trim() || null,
        });
      }

      const responseClients = clientsQ.rows.map((row) => {
        const userId = String(row.user_id || "").trim();
        const products = userId ? itemsByUserId.get(userId) || [] : [];
        return {
          raw_phone: row.raw_phone,
          phone_core: row.phone_core,
          found: Boolean(userId),
          user_id: userId || null,
          client_name: row.client_name || null,
          email: row.email || null,
          phone: row.stored_phone || row.raw_phone,
          reserved_count: products.length,
          processed_count: products.length,
          newly_processed_count: products.filter((product) => product.newly_processed).length,
          already_processed_count: products.filter((product) => product.already_processed).length,
          existing_delivery_count: products.filter((product) => product.existing_delivery).length,
          pickup_added_count: 0,
          products,
        };
      });
      const processedClients = responseClients.filter(
        (item) => Number(item.reserved_count) > 0,
      );
      const skippedNoItems = responseClients.filter(
        (item) => item.found && Number(item.reserved_count) === 0,
      );
      const notFound = responseClients.filter((item) => !item.found);

      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        const affectedUserIds = Array.from(
          new Set(itemRows.map((row) => String(row.user_id || "")).filter(Boolean)),
        );
        for (const userId of affectedUserIds) {
          emitCartUpdated(io, userId, {
            status: "processed",
            processing_mode: "manual",
            shelf_label: "ручное",
            reason: "manual_phone_processing",
          });
        }
        for (const message of updatedMessages) {
          io.to(`chat:${message.chat_id}`).emit("chat:message", {
            chatId: message.chat_id,
            message: decryptMessageRow(message),
          });
          emitToTenant(io, tenantId, "chat:updated", {
            chatId: message.chat_id,
          });
        }
        emitDeliveryUpdated(io, "manual-phone-processing", tenantId);
      }

      return res.json({
        ok: true,
        data: {
          requested_count: phoneEntries.length,
          matched_clients: responseClients.filter((item) => item.found).length,
          processed_clients: processedClients.length,
          processed_count: cartItemIdsToProcess.length,
          newly_processed_count: cartItemIdsToProcess.length,
          already_processed_count: itemRows.filter(
            (row) => String(row.status || "").trim() === "processed",
          ).length,
          pickup_added_count: 0,
          existing_delivery_count: itemRows.filter(
            (row) => String(row.existing_delivery_item_id || "").trim(),
          ).length,
          skipped_count: skippedNoItems.length + notFound.length,
          skipped_no_items_count: skippedNoItems.length,
          not_found_count: notFound.length,
          delivery_batch_id: null,
          delivery_date: null,
          delivery_label: null,
          pickup_note: null,
          clients: responseClients,
          skipped_no_items: skippedNoItems,
          not_found: notFound,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.manualProcessingByPhones error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.get(
  "/sticker-print-jobs/pending",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    try {
      const q = await db.query(
        `SELECT *
         FROM sticker_print_jobs
         WHERE user_id = $1
           AND status = 'pending'
           AND ($2::uuid IS NULL OR tenant_id = $2::uuid OR tenant_id IS NULL)
         ORDER BY created_at ASC
         LIMIT 20`,
        [req.user.id, req.user?.tenant_id || null],
      );
      return res.json({
        ok: true,
        data: q.rows.map(mapStickerPrintJob).filter(Boolean),
      });
    } catch (err) {
      console.error("delivery.stickerPrintJobs.pending error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post(
  "/sticker-print-jobs/:jobId/claim",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    try {
      const q = await db.query(
        `UPDATE sticker_print_jobs
         SET status = 'printing',
             updated_at = now(),
             error_text = NULL
         WHERE id = $1
           AND user_id = $2
           AND status IN ('pending', 'failed')
           AND ($3::uuid IS NULL OR tenant_id = $3::uuid OR tenant_id IS NULL)
         RETURNING *`,
        [req.params.jobId, req.user.id, req.user?.tenant_id || null],
      );
      if (q.rowCount === 0) {
        return res.status(409).json({
          ok: false,
          error: "Задание печати уже обрабатывается или не найдено",
        });
      }
      return res.json({ ok: true, data: mapStickerPrintJob(q.rows[0]) });
    } catch (err) {
      console.error("delivery.stickerPrintJobs.claim error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post(
  "/sticker-print-jobs/:jobId/printed",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    try {
      const q = await db.query(
        `UPDATE sticker_print_jobs
         SET status = 'printed',
             printed_at = COALESCE(printed_at, now()),
             updated_at = now(),
             error_text = NULL
         WHERE id = $1
           AND user_id = $2
           AND status IN ('pending', 'printing', 'failed')
           AND ($3::uuid IS NULL OR tenant_id = $3::uuid OR tenant_id IS NULL)
         RETURNING *`,
        [req.params.jobId, req.user.id, req.user?.tenant_id || null],
      );
      if (q.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Задание печати не найдено" });
      }
      return res.json({ ok: true, data: mapStickerPrintJob(q.rows[0]) });
    } catch (err) {
      console.error("delivery.stickerPrintJobs.printed error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post(
  "/sticker-print-jobs/:jobId/failed",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    try {
      const errorText = String(req.body?.error || "").trim().slice(0, 500);
      const q = await db.query(
        `UPDATE sticker_print_jobs
         SET status = 'failed',
             error_text = NULLIF($4, ''),
             updated_at = now()
         WHERE id = $1
           AND user_id = $2
           AND status IN ('pending', 'printing')
           AND ($3::uuid IS NULL OR tenant_id = $3::uuid OR tenant_id IS NULL)
         RETURNING *`,
        [req.params.jobId, req.user.id, req.user?.tenant_id || null, errorText],
      );
      if (q.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Задание печати не найдено" });
      }
      return res.json({ ok: true, data: mapStickerPrintJob(q.rows[0]) });
    } catch (err) {
      console.error("delivery.stickerPrintJobs.failed error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.get(
  "/dashboard",
  requireAuth,
  requireDeliveryAssemblyAccess,
  async (req, res) => {
    try {
      const tenantId = req.user?.tenant_id || null;
      const assemblyOnly = isKinelWorkerDeliveryAssemblyUser(req.user);
      const settings = await getDeliverySettings(db, tenantId);
      const batches = await fetchBatchSummaries(db, tenantId);
      const eligiblePreview = assemblyOnly
        ? null
        : await buildEligiblePreview(db, settings, tenantId);
      const activeBatchSummary =
        batches.find((item) => item.status !== "completed" && item.status !== "cancelled") ||
        null;
      const activeBatch = activeBatchSummary
        ? await fetchBatchDetails(db, activeBatchSummary.id, tenantId)
        : null;
      return res.json({
        ok: true,
        data: {
          settings,
          batches,
          eligible_preview: eligiblePreview,
          active_batch: activeBatch,
        },
      });
    } catch (err) {
      console.error("delivery.dashboard error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.get(
  "/batches/:batchId",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    try {
      const detail = await fetchBatchDetails(
        db,
        req.params.batchId,
        req.user?.tenant_id || null,
      );
      if (!detail) {
        return res.status(404).json({ ok: false, error: "Лист доставки не найден" });
      }
      return res.json({ ok: true, data: { batch: detail } });
    } catch (err) {
      console.error("delivery.batchDetails error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.get(
  "/city-rates",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    try {
      const settings = await getDeliverySettings(db, req.user?.tenant_id || null);
      return res.json({ ok: true, data: settings.city_rates || [] });
    } catch (err) {
      console.error("delivery.cityRates.get error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/city-rates",
  requireAuth,
  requireRole("tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    try {
      const tenantId = req.user?.tenant_id || null;
      const settings = await getDeliverySettings(db, tenantId);
      const nextSettings = {
        ...settings,
        city_rates: normalizeDeliveryCityRates(req.body?.city_rates),
      };
      await saveDeliverySettings(db, nextSettings, req.user.id, tenantId);
      const nextPreview = await buildEligiblePreview(db, nextSettings, tenantId);
      return res.json({
        ok: true,
        data: {
          city_rates: nextSettings.city_rates,
          eligible_preview: nextPreview,
        },
      });
    } catch (err) {
      console.error("delivery.cityRates.patch error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/settings",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const canEditPricing = canManageDeliveryPricing(req.user);
    const requestedThresholdAmount = toMoney(req.body?.threshold_amount, NaN);
    if (
      canEditPricing &&
      (!Number.isFinite(requestedThresholdAmount) || requestedThresholdAmount < 0)
    ) {
      return res
        .status(400)
        .json({ ok: false, error: "Некорректная сумма порога доставки" });
    }
    const routeOriginLabel =
      String(req.body?.route_origin_label || "Точка отправки").trim() ||
      "Точка отправки";
    const routeOriginAddress = String(req.body?.route_origin_address || "").trim();
    const cityRates = canEditPricing && Object.prototype.hasOwnProperty.call(
      req.body || {},
      "city_rates",
    )
      ? normalizeDeliveryCityRates(req.body?.city_rates)
      : null;
    let routeOriginLat =
      req.body?.route_origin_lat == null || req.body?.route_origin_lat === ""
        ? null
        : Number(req.body.route_origin_lat);
    let routeOriginLng =
      req.body?.route_origin_lng == null || req.body?.route_origin_lng === ""
        ? null
        : Number(req.body.route_origin_lng);

    if (
      routeOriginAddress &&
      (!Number.isFinite(routeOriginLat) || !Number.isFinite(routeOriginLng))
    ) {
      try {
        const geocoded = await geocodeDeliveryAddress(routeOriginAddress);
        if (!geocoded) {
          return res.status(400).json({
            ok: false,
            error: "Не удалось найти точку отправки",
          });
        }
        routeOriginLat = geocoded.lat;
        routeOriginLng = geocoded.lng;
      } catch (error) {
        const missingProvider =
          String(error?.message || "").includes("не настроен") ||
          String(error?.code || "").includes("ADDRESS_PROVIDER") ||
          String(error?.provider || "").trim().isNotEmpty;
        if (!missingProvider) {
          return res.status(400).json({
            ok: false,
            error: error.message || "Не удалось проверить точку отправки",
          });
        }
        routeOriginLat = null;
        routeOriginLng = null;
      }
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const settings = await getDeliverySettings(client, req.user?.tenant_id || null);
      const nextSettings = {
        threshold_amount: canEditPricing
          ? requestedThresholdAmount
          : settings.threshold_amount,
        route_origin_label: routeOriginLabel,
        route_origin_address: routeOriginAddress,
        route_origin_lat: Number.isFinite(routeOriginLat) ? routeOriginLat : null,
        route_origin_lng: Number.isFinite(routeOriginLng) ? routeOriginLng : null,
        city_rates: cityRates == null ? settings.city_rates : cityRates,
        delivery_zones: [],
      };
      await saveDeliverySettings(
        client,
        nextSettings,
        req.user.id,
        req.user?.tenant_id || null,
      );
      const activeBatchUpdate = await client.query(
        `UPDATE delivery_batches
         SET route_origin_label = $1,
             route_origin_address = $2,
             route_origin_lat = $3,
             route_origin_lng = $4,
             updated_at = now()
         WHERE id = (
           SELECT id
           FROM delivery_batches
           WHERE status IN ('calling', 'couriers_assigned')
             AND (
               $5::uuid IS NULL
               OR EXISTS (
                 SELECT 1
                 FROM users bu
                 WHERE bu.id = delivery_batches.created_by
                   AND bu.tenant_id = $5::uuid
               )
               OR EXISTS (
                 SELECT 1
                 FROM delivery_batch_customers c2
                 JOIN users u2 ON u2.id = c2.user_id
                 WHERE c2.batch_id = delivery_batches.id
                   AND u2.tenant_id = $5::uuid
               )
             )
           ORDER BY
             CASE status
               WHEN 'calling' THEN 0
               WHEN 'couriers_assigned' THEN 1
               ELSE 2
             END,
             created_at DESC
           LIMIT 1
         )
         RETURNING id, status`,
        [
          routeOriginLabel,
          routeOriginAddress || null,
          Number.isFinite(routeOriginLat) ? routeOriginLat : null,
          Number.isFinite(routeOriginLng) ? routeOriginLng : null,
          req.user?.tenant_id || null,
        ],
      );
      if (activeBatchUpdate.rowCount > 0) {
        const batchId = String(activeBatchUpdate.rows[0].id || "");
        if (batchId) {
          await rerouteAcceptedCustomers(client, batchId);
        }
      }
      await client.query("COMMIT");
      return res.json({ ok: true, data: nextSettings });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.settings.update error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.get("/zones", requireAuth, async (req, res) => {
  return res.json({ ok: true, data: [] });
});

router.get("/address/suggest", requireAuth, async (req, res) => {
  const query = normalizeWhitespace(req.query?.q || "");
  if (query.length < 3) {
    return res.json({ ok: true, data: [] });
  }
  try {
    const limit = Math.max(1, Math.min(10, Number(req.query?.limit) || 6));
    const lat =
      req.query?.lat == null || req.query?.lat === ""
        ? null
        : Number(req.query.lat);
    const lng =
      req.query?.lng == null || req.query?.lng === ""
        ? null
        : Number(req.query.lng);
    const suggestions = await suggestAddresses(query, {
      limit,
      lat: Number.isFinite(lat) ? lat : null,
      lng: Number.isFinite(lng) ? lng : null,
    });
    return res.json({
      ok: true,
      data: suggestions.map((item) => ({
        provider: item.provider,
        provider_address_id: item.provider_address_id,
        address_text: item.address_text,
        label: item.label,
        lat: item.lat,
        lng: item.lng,
        address_structured: item.structured_address || {},
      })),
    });
  } catch (err) {
    console.error("delivery.address.suggest error", err);
    if (
      respondAddressProviderError(
        res,
        err,
        "Подсказки адреса временно недоступны. Попробуйте позже или отметьте точку на карте.",
      )
    ) {
      return;
    }
    return res.status(500).json({ ok: false, error: "Не удалось получить подсказки адреса" });
  }
});

router.post("/address/reverse", requireAuth, async (req, res) => {
  const lat =
    req.body?.lat == null || req.body?.lat === "" ? null : Number(req.body.lat);
  const lng =
    req.body?.lng == null || req.body?.lng === "" ? null : Number(req.body.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return res.status(400).json({ ok: false, error: "Нужно передать lat и lng" });
  }
  try {
    const result = await reverseGeocodePoint(lat, lng);
    if (!result) {
      return res.status(404).json({ ok: false, error: "Не удалось распознать адрес точки" });
    }
    return res.json({
      ok: true,
      data: {
        provider: result.provider,
        provider_address_id: result.provider_address_id,
        address_text: result.address_text,
        label: result.label,
        lat: result.lat,
        lng: result.lng,
        address_structured: result.structured_address || {},
      },
    });
  } catch (err) {
    console.error("delivery.address.reverse error", err);
    if (
      respondAddressProviderError(
        res,
        err,
        "Не удалось распознать точку. Попробуйте позже или введите адрес вручную.",
      )
    ) {
      return;
    }
    return res.status(500).json({ ok: false, error: "Не удалось распознать адрес точки" });
  }
});

router.post("/address/validate", requireAuth, async (req, res) => {
  try {
    const settings = await getDeliverySettings(db, req.user?.tenant_id || null);
    const validationResult = await resolveValidatedAddressSelection({
      rawSelection: req.body,
      settings,
      requirePoint: false,
      allowConfirm: req.body?.confirm_selection === true,
    });
    if (!validationResult.ok) {
      return res.status(400).json({
        ok: false,
        error: validationResult.error,
        data: validationResult.validation || null,
      });
    }
    return res.json({
      ok: true,
      data: {
        ...validationResult.selection,
        summary: validationResult.validation?.summary || "Адрес подтвержден",
        next_action: validationResult.validation?.action || "accept",
      },
    });
  } catch (err) {
    console.error("delivery.address.validate error", err);
    if (
      respondAddressProviderError(
        res,
        err,
        "Сервис проверки адресов временно недоступен. Попробуйте чуть позже.",
      )
    ) {
      return;
    }
    return res.status(500).json({ ok: false, error: "Не удалось проверить адрес" });
  }
});

router.get("/addresses", requireAuth, async (req, res) => {
  try {
    const result = await db.query(
      `SELECT *
       FROM user_delivery_addresses
       WHERE user_id = $1
       ORDER BY is_default DESC, updated_at DESC, created_at DESC`,
      [req.user.id],
    );
    return res.json({
      ok: true,
      data: result.rows.map(mapStoredDeliveryAddressRow),
    });
  } catch (err) {
    console.error("delivery.addresses.list error", err);
    return res.status(500).json({ ok: false, error: "Не удалось загрузить адреса" });
  }
});

router.post("/addresses", requireAuth, async (req, res) => {
  try {
    const settings = await getDeliverySettings(db, req.user?.tenant_id || null);
    const validated = await resolveValidatedAddressSelection({
      rawSelection: req.body,
      settings,
      requirePoint: false,
      allowConfirm: req.body?.confirm_selection === true,
    });
    if (!validated.ok) {
      return res.status(400).json({
        ok: false,
        error: validated.error,
        data: validated.validation || null,
      });
    }
    const payload = buildAddressDbPayload(validated.selection);
    const isDefault = req.body?.is_default !== false;
    const label = normalizeWhitespace(req.body?.label || payload.label) || "Адрес";
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      if (isDefault) {
        await client.query(
          `UPDATE user_delivery_addresses
           SET is_default = false,
               updated_at = now()
           WHERE user_id = $1`,
          [req.user.id],
        );
      }
      const insertQ = await client.query(
        `INSERT INTO user_delivery_addresses (
           id, user_id, label, address_text,
           address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at,
           lat, lng, entrance, comment, is_default,
           address_structured, provider, provider_address_id,
           validation_status, validation_confidence, point_source,
           mismatch_distance_meters, delivery_zone_id, delivery_zone_label, delivery_zone_status,
           created_at, updated_at
         )
         VALUES (
           $1, $2, $3, NULL,
           $4, $5, $6, $7, $8,
           $9, $10, $11, $12, $13,
           $14::jsonb, $15, $16,
           $17, $18, $19,
           $20, $21, $22, $23,
           now(), now()
         )
         RETURNING *`,
        [
          uuidv4(),
          req.user.id,
          label,
          payload.encrypted.ciphertext,
          payload.encrypted.iv,
          payload.encrypted.tag,
          payload.encrypted.version,
          payload.encrypted.encryptedAt,
          payload.lat,
          payload.lng,
          payload.entrance,
          payload.comment,
          isDefault,
          JSON.stringify(payload.address_structured),
          payload.provider,
          payload.provider_address_id,
          payload.validation_status,
          payload.validation_confidence,
          payload.point_source,
          payload.mismatch_distance_meters,
          payload.delivery_zone_id,
          payload.delivery_zone_label,
          payload.delivery_zone_status,
        ],
      );
      await client.query("COMMIT");
      return res.status(201).json({
        ok: true,
        data: mapStoredDeliveryAddressRow(insertQ.rows[0]),
      });
    } catch (err) {
      await client.query("ROLLBACK");
      throw err;
    } finally {
      client.release();
    }
  } catch (err) {
    console.error("delivery.addresses.create error", err);
    if (
      respondAddressProviderError(
        res,
        err,
        "Не удалось проверить адрес перед сохранением. Попробуйте чуть позже.",
      )
    ) {
      return;
    }
    return res.status(500).json({ ok: false, error: "Не удалось сохранить адрес" });
  }
});

router.patch("/addresses/:addressId", requireAuth, async (req, res) => {
  const addressId = String(req.params?.addressId || "").trim();
  if (!addressId) {
    return res.status(400).json({ ok: false, error: "addressId обязателен" });
  }
  try {
    const existingQ = await db.query(
      `SELECT *
       FROM user_delivery_addresses
       WHERE id = $1
         AND user_id = $2
       LIMIT 1`,
      [addressId, req.user.id],
    );
    if (existingQ.rowCount === 0) {
      return res.status(404).json({ ok: false, error: "Адрес не найден" });
    }
    const current = mapStoredDeliveryAddressRow(existingQ.rows[0]);
    const settings = await getDeliverySettings(db, req.user?.tenant_id || null);
    const rawSelection = {
      ...current,
      ...sanitizeJsonObject(req.body),
      address_text: normalizeWhitespace(
        req.body?.address_text || current.address_text || "",
      ),
      lat: req.body?.lat ?? current.lat,
      lng: req.body?.lng ?? current.lng,
      address_structured:
        req.body?.address_structured ||
        req.body?.structured_address ||
        current.address_structured,
    };
    const validated = await resolveValidatedAddressSelection({
      rawSelection,
      settings,
      requirePoint: false,
      allowConfirm: req.body?.confirm_selection === true,
    });
    if (!validated.ok) {
      return res.status(400).json({
        ok: false,
        error: validated.error,
        data: validated.validation || null,
      });
    }
    const payload = buildAddressDbPayload(validated.selection);
    const isDefault = Object.prototype.hasOwnProperty.call(req.body || {}, "is_default")
      ? req.body?.is_default === true
      : current.is_default === true;
    const label = normalizeWhitespace(req.body?.label || current.label || payload.label) || "Адрес";
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      if (isDefault) {
        await client.query(
          `UPDATE user_delivery_addresses
           SET is_default = false,
               updated_at = now()
           WHERE user_id = $1
             AND id <> $2`,
          [req.user.id, addressId],
        );
      }
      const updateQ = await client.query(
        `UPDATE user_delivery_addresses
         SET label = $1,
             address_text = NULL,
             address_ciphertext = $2,
             address_iv = $3,
             address_tag = $4,
             address_encryption_version = $5,
             address_encrypted_at = $6,
             lat = $7,
             lng = $8,
             entrance = $9,
             comment = $10,
             is_default = $11,
             address_structured = $12::jsonb,
             provider = $13,
             provider_address_id = $14,
             validation_status = $15,
             validation_confidence = $16,
             point_source = $17,
             mismatch_distance_meters = $18,
             delivery_zone_id = $19,
             delivery_zone_label = $20,
             delivery_zone_status = $21,
             updated_at = now()
         WHERE id = $22
           AND user_id = $23
         RETURNING *`,
        [
          label,
          payload.encrypted.ciphertext,
          payload.encrypted.iv,
          payload.encrypted.tag,
          payload.encrypted.version,
          payload.encrypted.encryptedAt,
          payload.lat,
          payload.lng,
          payload.entrance,
          payload.comment,
          isDefault,
          JSON.stringify(payload.address_structured),
          payload.provider,
          payload.provider_address_id,
          payload.validation_status,
          payload.validation_confidence,
          payload.point_source,
          payload.mismatch_distance_meters,
          payload.delivery_zone_id,
          payload.delivery_zone_label,
          payload.delivery_zone_status,
          addressId,
          req.user.id,
        ],
      );
      await client.query("COMMIT");
      return res.json({
        ok: true,
        data: mapStoredDeliveryAddressRow(updateQ.rows[0]),
      });
    } catch (err) {
      await client.query("ROLLBACK");
      throw err;
    } finally {
      client.release();
    }
  } catch (err) {
    console.error("delivery.addresses.patch error", err);
    if (
      respondAddressProviderError(
        res,
        err,
        "Не удалось перепроверить адрес. Попробуйте чуть позже.",
      )
    ) {
      return;
    }
    return res.status(500).json({ ok: false, error: "Не удалось обновить адрес" });
  }
});

router.delete("/addresses/:addressId", requireAuth, async (req, res) => {
  const addressId = String(req.params?.addressId || "").trim();
  if (!addressId) {
    return res.status(400).json({ ok: false, error: "addressId обязателен" });
  }
  try {
    const deleted = await db.query(
      `DELETE FROM user_delivery_addresses
       WHERE id = $1
         AND user_id = $2
       RETURNING id`,
      [addressId, req.user.id],
    );
    if (deleted.rowCount === 0) {
      return res.status(404).json({ ok: false, error: "Адрес не найден" });
    }
    return res.json({ ok: true });
  } catch (err) {
    console.error("delivery.addresses.delete error", err);
    return res.status(500).json({ ok: false, error: "Не удалось удалить адрес" });
  }
});

router.get("/slots", requireAuth, async (req, res) => {
  try {
    const role = String(req.user?.role || "").toLowerCase().trim();
    const allowAll =
      (role === "admin" || role === "tenant" || role === "creator") &&
      String(req.query?.all || "") === "1";
    const result = await db.query(
      `SELECT id, tenant_id, title, from_time, to_time, sort_order, is_active, is_system, created_at, updated_at
       FROM delivery_slot_presets
       WHERE ($1::uuid IS NULL OR tenant_id = $1::uuid OR tenant_id IS NULL)
         AND ($2::boolean = true OR is_active = true)
       ORDER BY is_system DESC, sort_order ASC, created_at ASC`,
      [req.user?.tenant_id || null, allowAll],
    );
    return res.json({
      ok: true,
      data: result.rows.map(mapDeliverySlotRow),
    });
  } catch (err) {
    console.error("delivery.slots.list error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

router.post(
  "/slots",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const title = String(req.body?.title || "").trim();
    const fromTime = normalizeClockValue(req.body?.from_time);
    const toTime = normalizeClockValue(req.body?.to_time);
    const sortOrderRaw = Number(req.body?.sort_order);
    const sortOrder = Number.isFinite(sortOrderRaw)
      ? Math.max(1, Math.min(9999, Math.floor(sortOrderRaw)))
      : 100;
    const isActive = req.body?.is_active !== false;

    if (title.length < 2 || title.length > 48) {
      return res.status(400).json({
        ok: false,
        error: "Название слота должно быть от 2 до 48 символов",
      });
    }
    if (!fromTime && !toTime) {
      return res.status(400).json({
        ok: false,
        error: "Нужно указать время начала, окончания или оба значения",
      });
    }
    if (fromTime && toTime) {
      const fromMinutes = parseClockToMinutes(fromTime);
      const toMinutes = parseClockToMinutes(toTime);
      if (
        fromMinutes == null ||
        toMinutes == null ||
        fromMinutes >= toMinutes
      ) {
        return res.status(400).json({
          ok: false,
          error: "Время начала должно быть раньше времени окончания",
        });
      }
    }

    try {
      const created = await db.query(
        `INSERT INTO delivery_slot_presets (
           id, tenant_id, title, from_time, to_time, sort_order,
           is_active, is_system, created_by, created_at, updated_at
         )
         VALUES (
           $1, $2, $3, $4, $5, $6,
           $7, false, $8, now(), now()
         )
         RETURNING id, tenant_id, title, from_time, to_time, sort_order, is_active, is_system, created_at, updated_at`,
        [
          uuidv4(),
          req.user?.tenant_id || null,
          title,
          fromTime,
          toTime,
          sortOrder,
          isActive,
          req.user?.id || null,
        ],
      );
      return res.status(201).json({
        ok: true,
        data: mapDeliverySlotRow(created.rows[0]),
      });
    } catch (err) {
      console.error("delivery.slots.create error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/slots/:slotId",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const slotId = String(req.params?.slotId || "").trim();
    if (!slotId) {
      return res.status(400).json({ ok: false, error: "slotId обязателен" });
    }

    try {
      const existingQ = await db.query(
        `SELECT id, tenant_id, is_system, title, from_time, to_time, sort_order, is_active
         FROM delivery_slot_presets
         WHERE id = $1
         LIMIT 1`,
        [slotId],
      );
      if (existingQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Слот не найден" });
      }
      const existing = existingQ.rows[0];
      if (existing.is_system === true || existing.tenant_id == null) {
        return res.status(403).json({
          ok: false,
          error: "Системный слот нельзя изменять напрямую",
        });
      }
      if (String(existing.tenant_id) !== String(req.user?.tenant_id || "")) {
        return res.status(403).json({ ok: false, error: "Нет доступа" });
      }

      const nextTitle = Object.prototype.hasOwnProperty.call(req.body || {}, "title")
        ? String(req.body?.title || "").trim()
        : String(existing.title || "").trim();
      const nextFrom = Object.prototype.hasOwnProperty.call(req.body || {}, "from_time")
        ? normalizeClockValue(req.body?.from_time)
        : normalizeClockValue(existing.from_time);
      const nextTo = Object.prototype.hasOwnProperty.call(req.body || {}, "to_time")
        ? normalizeClockValue(req.body?.to_time)
        : normalizeClockValue(existing.to_time);
      const nextSortOrder = Object.prototype.hasOwnProperty.call(req.body || {}, "sort_order")
        ? Math.max(1, Math.min(9999, Math.floor(Number(req.body?.sort_order) || 100)))
        : Number(existing.sort_order) || 100;
      const nextIsActive = Object.prototype.hasOwnProperty.call(req.body || {}, "is_active")
        ? req.body?.is_active === true
        : existing.is_active !== false;

      if (nextTitle.length < 2 || nextTitle.length > 48) {
        return res.status(400).json({
          ok: false,
          error: "Название слота должно быть от 2 до 48 символов",
        });
      }
      if (!nextFrom && !nextTo) {
        return res.status(400).json({
          ok: false,
          error: "Нужно указать время начала, окончания или оба значения",
        });
      }
      if (nextFrom && nextTo) {
        const fromMinutes = parseClockToMinutes(nextFrom);
        const toMinutes = parseClockToMinutes(nextTo);
        if (
          fromMinutes == null ||
          toMinutes == null ||
          fromMinutes >= toMinutes
        ) {
          return res.status(400).json({
            ok: false,
            error: "Время начала должно быть раньше времени окончания",
          });
        }
      }

      const updated = await db.query(
        `UPDATE delivery_slot_presets
         SET title = $1,
             from_time = $2,
             to_time = $3,
             sort_order = $4,
             is_active = $5,
             updated_at = now()
         WHERE id = $6
         RETURNING id, tenant_id, title, from_time, to_time, sort_order, is_active, is_system, created_at, updated_at`,
        [nextTitle, nextFrom, nextTo, nextSortOrder, nextIsActive, slotId],
      );
      return res.json({
        ok: true,
        data: mapDeliverySlotRow(updated.rows[0]),
      });
    } catch (err) {
      console.error("delivery.slots.patch error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.delete(
  "/slots/:slotId",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const slotId = String(req.params?.slotId || "").trim();
    if (!slotId) {
      return res.status(400).json({ ok: false, error: "slotId обязателен" });
    }

    try {
      const updated = await db.query(
        `UPDATE delivery_slot_presets
         SET is_active = false,
             updated_at = now()
         WHERE id = $1
           AND tenant_id = $2
           AND is_system = false
         RETURNING id`,
        [slotId, req.user?.tenant_id || null],
      );
      if (updated.rowCount === 0) {
        return res.status(404).json({
          ok: false,
          error: "Слот не найден или недоступен для удаления",
        });
      }
      return res.json({ ok: true });
    } catch (err) {
      console.error("delivery.slots.delete error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post(
  "/batches/generate",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const tenantId = req.user?.tenant_id || null;
      const settings = await getDeliverySettings(client, tenantId);
      const canEditPricing = canManageDeliveryPricing(req.user);
      const thresholdAmount = canEditPricing
        ? Math.max(0, toMoney(req.body?.threshold_amount, settings.threshold_amount))
        : settings.threshold_amount;
      const nextSettings = {
        ...settings,
        threshold_amount: thresholdAmount,
      };
      if (canEditPricing) {
        await saveDeliverySettings(client, nextSettings, req.user.id, tenantId);
      }

      const createdBatch = await createDeliveryBatch(
        client,
        nextSettings,
        req.user.id,
        tenantId,
      );

      if (!createdBatch.created && !createdBatch.batchId) {
        await client.query("ROLLBACK");
        return res.json({
          ok: true,
          data: {
            created: false,
            threshold_amount: thresholdAmount,
            eligible_total: 0,
            message: createdBatch.message,
          },
        });
      }

      await client.query("COMMIT");

      const batchId = createdBatch.batchId;
      const activeBatch = batchId
        ? await fetchBatchDetails(db, batchId, tenantId)
        : null;
      return res.status(201).json({
        ok: true,
        data: {
          created: createdBatch.created,
          threshold_amount: thresholdAmount,
          eligible_total: createdBatch.eligible_total,
          active_batch: activeBatch,
          message: createdBatch.message,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.batch.generate error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/broadcast",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  antifraudGuard("admin.delivery.broadcast", (req) => ({
    threshold_amount: req.body?.threshold_amount ?? null,
  })),
  async (req, res) => {
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const tenantId = req.user?.tenant_id || null;
      const settings = await getDeliverySettings(client, tenantId);
      const canEditPricing = canManageDeliveryPricing(req.user);
      const thresholdAmount = canEditPricing
        ? Math.max(0, toMoney(req.body?.threshold_amount, settings.threshold_amount))
        : settings.threshold_amount;
      const nextSettings = {
        ...settings,
        threshold_amount: thresholdAmount,
      };
      if (canEditPricing) {
        await saveDeliverySettings(client, nextSettings, req.user.id, tenantId);
      }

      let batchId = await findDraftBatchId(client, tenantId);
      let created = false;
      let eligibleTotal = 0;
      let addedToExistingBatch = 0;
      let systemMessages = [];
      if (!batchId) {
        const createdBatch = await createDeliveryBatch(
          client,
          nextSettings,
          req.user.id,
          tenantId,
        );
        batchId = createdBatch.batchId;
        created = createdBatch.created;
        eligibleTotal = createdBatch.eligible_total;
        if (!batchId) {
          await client.query("ROLLBACK");
          return res.json({
            ok: true,
            data: {
              created: false,
              sent_total: 0,
              threshold_amount: thresholdAmount,
              message: createdBatch.message,
            },
          });
        }
      } else {
        addedToExistingBatch = await addEligibleCustomersToBatch(
          client,
          batchId,
          thresholdAmount,
          nextSettings,
          tenantId,
        );
      }

      const batch = await fetchBatchDetails(client, batchId, tenantId);
      if (!batch) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Лист доставки не найден" });
      }

      const targetCustomers = batch.customers.filter((customer) => {
        const callStatus = String(customer.call_status || "").trim();
        const deliveryStatus = String(customer.delivery_status || "").trim();
        return (
          callStatus === "pending" &&
          (deliveryStatus === "awaiting_call" || deliveryStatus === "offer_sent")
        );
      });

      for (const customer of targetCustomers) {
        const ensured = await ensureDeliveryChat(
          client,
          customer.user_id,
          req.user.id,
          req.user.tenant_id || null,
        );
        const chat = ensured.chat;
        if (customer.has_pickup_only === true) {
          const meta = {
            kind: "delivery_pickup_only_notice",
            delivery_batch_id: batch.id,
            delivery_customer_id: customer.id,
            delivery_label: batch.delivery_label,
            delivery_date: batch.delivery_date,
            customer_phone: customer.customer_phone || "",
            processed_sum: toMoney(customer.processed_sum),
            has_pickup_only: true,
          };
          const insert = await client.query(
            `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
             VALUES ($1, $2, NULL, $3, $4::jsonb, now())
             RETURNING id`,
            [
              uuidv4(),
              chat.id,
              encryptMessageText(buildPickupOnlyDeliveryBlockedText(customer)),
              JSON.stringify(meta),
            ],
          );
          const messageId = String(insert.rows[0].id);
          const hydrated = await hydrateSystemMessage(client, messageId);
          await client.query(
            `UPDATE delivery_batch_customers
             SET call_status = 'removed',
                 delivery_status = 'returned_to_cart',
                 notes = CONCAT_WS(
                   E'\n',
                   NULLIF(notes, ''),
                   'Автоматически исключено из доставки: в корзине есть товар только для самовывоза.'
                 ),
                 updated_at = now()
             WHERE id = $1`,
            [customer.id],
          );
          await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
            chat.id,
          ]);
          systemMessages.push({
            user_id: String(customer.user_id),
            chat,
            chatCreated: ensured.created,
            deletedChatIds: ensured.deletedChatIds || [],
            message: hydrated,
          });
          continue;
        }
        const meta = {
          kind: "delivery_offer",
          delivery_batch_id: batch.id,
          delivery_customer_id: customer.id,
          offer_status: "pending",
          delivery_label: batch.delivery_label,
          delivery_date: batch.delivery_date,
          customer_phone: customer.customer_phone || "",
          processed_sum: toMoney(customer.processed_sum),
          address_text: customer.address_text || "",
        };
        const insert = await client.query(
          `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
           VALUES ($1, $2, NULL, $3, $4::jsonb, now())
           RETURNING id`,
          [
            uuidv4(),
            chat.id,
            encryptMessageText(buildDeliveryOfferText(customer, batch)),
            JSON.stringify(meta),
          ],
        );
        const messageId = String(insert.rows[0].id);
        const hydrated = await hydrateSystemMessage(client, messageId);
        await client.query(
          `UPDATE delivery_batch_customers
           SET delivery_status = 'offer_sent',
               updated_at = now()
           WHERE id = $1`,
          [customer.id],
        );
        await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
          chat.id,
        ]);
        systemMessages.push({
          user_id: String(customer.user_id),
          chat,
          chatCreated: ensured.created,
          deletedChatIds: ensured.deletedChatIds || [],
          message: hydrated,
        });
      }

      await maybeCloseDeliveryBatchWithoutWork(client, batchId, tenantId);
      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        for (const item of systemMessages) {
          for (const deletedChatId of item.deletedChatIds || []) {
            io.to(`user:${item.user_id}`).emit("chat:deleted", {
              chatId: deletedChatId,
            });
          }
          if (item.chatCreated) {
            io.to(`user:${item.user_id}`).emit("chat:created", {
              chat: item.chat,
            });
          }
          io.to(`user:${item.user_id}`).emit("chat:updated", {
            chatId: item.chat.id,
            chat: item.chat,
          });
          if (item.message) {
            io.to(`user:${item.user_id}`).emit("chat:message", {
              chatId: item.chat.id,
              message: item.message,
            });
          }
        }
        emitDeliveryUpdated(io, batchId, req.user?.tenant_id || null);
      }

      const activeBatch = await fetchBatchDetails(
        db,
        batchId,
        req.user?.tenant_id || null,
      );
      return res.json({
        ok: true,
        data: {
          created,
          threshold_amount: thresholdAmount,
          eligible_total: eligibleTotal,
          added_to_existing_batch: addedToExistingBatch,
          sent_total: systemMessages.length,
          active_batch: activeBatch,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.broadcast error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/reset",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const tenantId = req.user?.tenant_id || null;
      const affectedUsersQ = await client.query(
        `SELECT DISTINCT c.user_id::text AS user_id
         FROM delivery_batch_customers c
         JOIN users u ON u.id = c.user_id
         WHERE ($1::uuid IS NULL OR u.tenant_id = $1::uuid)`,
        [tenantId],
      );
      const affectedUsers = affectedUsersQ.rows.map((row) => String(row.user_id));

      await client.query(
        `DELETE FROM sticker_print_jobs
         WHERE $1::uuid IS NULL
            OR tenant_id = $1::uuid`,
        [tenantId],
      );

      await client.query(
        `UPDATE cart_items ci
         SET status = 'processed',
             updated_at = now()
         FROM users u
         WHERE ci.user_id = u.id
           AND ci.status IN ('preparing_delivery', 'handing_to_courier', 'in_delivery')
           AND ($1::uuid IS NULL OR u.tenant_id = $1::uuid)`,
        [tenantId],
      );

      const deliveryChatsQ = await client.query(
        `SELECT id
         FROM chats
         WHERE COALESCE(settings->>'kind', '') = 'delivery_dialog'
           AND ($1::uuid IS NULL OR tenant_id = $1::uuid)`,
        [tenantId],
      );
      const deliveryChatIds = deliveryChatsQ.rows.map((row) => String(row.id));
      if (deliveryChatIds.length > 0) {
        await client.query(`DELETE FROM messages WHERE chat_id = ANY($1::uuid[])`, [
          deliveryChatIds,
        ]);
        await client.query(
          `DELETE FROM chat_members WHERE chat_id = ANY($1::uuid[])`,
          [deliveryChatIds],
        );
        await client.query(`DELETE FROM chats WHERE id = ANY($1::uuid[])`, [
          deliveryChatIds,
        ]);
      }

      const scopedCustomersQ = await client.query(
        `SELECT c.id::text AS id, c.batch_id::text AS batch_id
         FROM delivery_batch_customers c
         JOIN users u ON u.id = c.user_id
         WHERE ($1::uuid IS NULL OR u.tenant_id = $1::uuid)`,
        [tenantId],
      );
      const scopedCustomerIds = scopedCustomersQ.rows.map((row) => String(row.id));
      const scopedBatchIds = Array.from(
        new Set(scopedCustomersQ.rows.map((row) => String(row.batch_id || ""))),
      ).filter(Boolean);

      if (scopedCustomerIds.length > 0) {
        await client.query(
          `DELETE FROM delivery_batch_items
           WHERE batch_customer_id = ANY($1::uuid[])`,
          [scopedCustomerIds],
        );
        await client.query(
          `DELETE FROM delivery_batch_customers
           WHERE id = ANY($1::uuid[])`,
          [scopedCustomerIds],
        );
      }
      if (scopedBatchIds.length > 0) {
        await client.query(
          `DELETE FROM delivery_batches b
           WHERE b.id = ANY($1::uuid[])
             AND NOT EXISTS (
               SELECT 1
               FROM delivery_batch_customers c
               WHERE c.batch_id = b.id
             )`,
          [scopedBatchIds],
        );
      }

      const demoUsersQ = await client.query(
        `SELECT id
         FROM users
         WHERE email LIKE $1
           AND ($2::uuid IS NULL OR tenant_id = $2::uuid)`,
        [`${DEMO_USER_EMAIL_PREFIX}%`, tenantId],
      );
      const demoUserIds = demoUsersQ.rows.map((row) => String(row.id));
      if (demoUserIds.length > 0) {
        await client.query(
          `DELETE FROM cart_items
           WHERE user_id = ANY($1::uuid[])`,
          [demoUserIds],
        );
        await client.query(
          `DELETE FROM phones
           WHERE user_id = ANY($1::uuid[])`,
          [demoUserIds],
        );
        await client.query(
          `DELETE FROM user_shelves
           WHERE user_id = ANY($1::uuid[])`,
          [demoUserIds],
        );
        await client.query(
          `DELETE FROM user_delivery_addresses
           WHERE user_id = ANY($1::uuid[])`,
          [demoUserIds],
        );
        await client.query(
          `DELETE FROM users
           WHERE id = ANY($1::uuid[])`,
          [demoUserIds],
        );
      }
      await client.query(
        `DELETE FROM products
         WHERE title LIKE $1
           AND NOT EXISTS (
             SELECT 1
             FROM cart_items ci
             WHERE ci.product_id = products.id
           )
           AND NOT EXISTS (
             SELECT 1
             FROM product_publication_queue q
             WHERE q.product_id = products.id
           )
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users u
               WHERE u.id = products.created_by
                 AND u.tenant_id = $2::uuid
             )
           )`,
        [`${DEMO_PRODUCT_TITLE_PREFIX}%`, tenantId],
      );

      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        for (const userId of affectedUsers) {
          emitCartUpdated(io, userId, {
            status: "processed",
            reason: "delivery_reset",
          });
        }
        emitDeliveryUpdated(io, "reset", req.user?.tenant_id || null);
      }

      return res.json({
        ok: true,
        data: {
          cleared_batches: true,
          cleared_chats: deliveryChatIds.length,
          affected_users: affectedUsers.length,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.reset error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/demo-seed",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const demoSeedEnabled =
      String(process.env.ENABLE_DELIVERY_DEMO_SEED || "")
        .toLowerCase()
        .trim() === "true" || process.env.NODE_ENV !== "production";
    if (!demoSeedEnabled) {
      return res.status(403).json({
        ok: false,
        error: "Тестовое заполнение доставки отключено на сервере",
      });
    }

    const requested = Number(req.body?.count ?? 10);
    const count = Math.max(1, Math.min(100, Math.floor(requested)));
    const minTargetSum = Math.max(100, toMoney(req.body?.min_sum, 1000));
    const maxTargetSum = Math.max(
      minTargetSum,
      toMoney(req.body?.max_sum, 20000),
    );
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const demoProducts = await ensureDemoProducts(client);
      const seedId = Date.now();
      const tenantId = req.user?.tenant_id || null;
      let createdUsers = 0;
      let mainChannelMembersAdded = 0;
      const mainChannelQ = tenantId
        ? await client.query(
            `SELECT id
             FROM chats
             WHERE tenant_id = $1
               AND type = 'channel'
               AND (
                 COALESCE(settings->>'system_key', '') = 'main_channel'
                 OR lower(COALESCE(title, '')) = lower('Основной канал')
               )
             ORDER BY
               CASE WHEN COALESCE(settings->>'system_key', '') = 'main_channel' THEN 0 ELSE 1 END,
               created_at ASC
             LIMIT 1`,
            [tenantId],
          )
        : { rows: [] };
      const mainChannelId = mainChannelQ.rows[0]?.id || null;

      for (let i = 0; i < count; i += 1) {
        const point = DEMO_SAMARA_POINTS[i % DEMO_SAMARA_POINTS.length];
        const email = `${DEMO_USER_EMAIL_PREFIX}${seedId}.${i}@phoenix.local`;
        const phone = `7999${String(seedId).slice(-4)}${String(i + 10).padStart(3, "0")}`;
        const userInsert = await client.query(
          `INSERT INTO users (
             id, email, password_hash, name, role, tenant_id, created_at, updated_at
           )
           VALUES ($1, $2, NULL, $3, 'client', $4, now(), now())
           RETURNING id`,
          [uuidv4(), email, `${point.name} Тест`, tenantId],
        );
        const userId = String(userInsert.rows[0].id);
        if (mainChannelId) {
          const memberInsert = await client.query(
            `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
             VALUES ($1, $2, $3, now(), 'member')
             ON CONFLICT (chat_id, user_id) DO NOTHING`,
            [uuidv4(), mainChannelId, userId],
          );
          mainChannelMembersAdded += memberInsert.rowCount;
        }
        await client.query(
          `INSERT INTO phones (user_id, phone, status, created_at, verified_at)
           VALUES ($1, $2, 'verified', now(), now())`,
          [userId, phone],
        );
        await client.query(
          `INSERT INTO user_shelves (user_id, shelf_number, created_at, updated_at)
           VALUES ($1, $2, now(), now())`,
          [userId, 200 + i],
        );
        const encryptedAddress = buildAddressEncryption(point.address);
        await client.query(
          `INSERT INTO user_delivery_addresses (
             id, user_id, label, address_text,
             address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at,
             lat, lng, is_default, created_at, updated_at
           )
           VALUES (
             $1, $2, 'Тестовый адрес', NULL,
             $3, $4, $5, $6, $7,
             $8, $9, true, now(), now()
           )`,
          [
            uuidv4(),
            userId,
            encryptedAddress.ciphertext,
            encryptedAddress.iv,
            encryptedAddress.tag,
            encryptedAddress.version,
            encryptedAddress.encryptedAt,
            point.lat,
            point.lng,
          ],
        );

        const product = demoProducts[i % demoProducts.length];
        const randomFactor = Math.random();
        const targetSum = toMoney(
          minTargetSum + randomFactor * (maxTargetSum - minTargetSum),
        );
        const unitPrice = Number(product.price) || 500;
        const quantity = Math.max(1, Math.ceil(targetSum / unitPrice));
        await client.query(
          `INSERT INTO cart_items (
             id, user_id, product_id, quantity, custom_price, status, created_at, updated_at
           )
           VALUES ($1, $2, $3, $4, $5, 'processed', now(), now())`,
          [
            uuidv4(),
            userId,
            product.id,
            quantity,
            toMoney(targetSum / quantity),
          ],
        );
        createdUsers += 1;
      }

      await client.query("COMMIT");
      return res.status(201).json({
        ok: true,
        data: {
          created_users: createdUsers,
          main_channel_members_added: mainChannelMembersAdded,
          min_sum: minTargetSum,
          max_sum: maxTargetSum,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.demoSeed error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/offers/:customerId/respond",
  requireAuth,
  async (req, res) => {
    const customerId = String(req.params?.customerId || "").trim();
    if (!customerId) {
      return res
        .status(400)
        .json({ ok: false, error: "delivery customer id обязателен" });
    }

    const accepted = req.body?.accepted === true;
    const declined = req.body?.accepted === false;
    if (!accepted && !declined) {
      return res
        .status(400)
        .json({ ok: false, error: "Нужно передать accepted = true или false" });
    }

    const addressText = String(req.body?.address_text || "").trim();
    const lat =
      req.body?.lat == null || req.body?.lat === ""
        ? null
        : Number(req.body.lat);
    const lng =
      req.body?.lng == null || req.body?.lng === ""
        ? null
        : Number(req.body.lng);
    const entrance = String(req.body?.entrance || req.body?.entrance_or_hint || "").trim();
    const comment = String(req.body?.comment || "").trim();
    const saveAsDefault = req.body?.save_as_default !== false;
    const confirmSelection = req.body?.confirm_selection === true;
    let preferredWindow;
    try {
      preferredWindow = sanitizePreferredWindow(
        req.body?.preferred_time_from,
        req.body?.preferred_time_to,
      );
    } catch (error) {
      return res.status(400).json({ ok: false, error: error.message });
    }

    if (accepted) {
      const hasAddress =
        addressText.length > 0 || (Number.isFinite(lat) && Number.isFinite(lng));
      if (!hasAddress) {
        return res.status(400).json({
          ok: false,
          error: "Нужно указать адрес доставки",
        });
      }
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const customerQ = await client.query(
        `SELECT c.*,
                b.delivery_date,
                b.delivery_label,
                b.status AS batch_status
         FROM delivery_batch_customers c
         JOIN delivery_batches b ON b.id = c.batch_id
         WHERE c.id = $1
         LIMIT 1
         FOR UPDATE`,
        [customerId],
      );
      if (customerQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Заявка доставки не найдена" });
      }

      const customer = customerQ.rows[0];
      if (String(customer.user_id) !== String(req.user.id)) {
        await client.query("ROLLBACK");
        return res.status(403).json({ ok: false, error: "Нет доступа" });
      }
      if (!["calling", "couriers_assigned"].includes(String(customer.batch_status || ""))) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Этот лист уже закрыт для новых подтверждений",
        });
      }
      if (String(customer.call_status || "") !== "pending") {
        await client.query("ROLLBACK");
        return res.status(400).json({ ok: false, error: "Ответ уже сохранен" });
      }

      const ensured = await ensureDeliveryChat(
        client,
        customer.user_id,
        null,
        req.user.tenant_id || null,
      );
      const chat = ensured.chat;
      let addressId = customer.address_id ? String(customer.address_id) : null;
      let nextSelection = {
        ...mapStoredDeliveryAddressRow(customer),
        address_text: addressText || decodeAddressFromRow(customer),
        lat: Number.isFinite(lat) ? lat : customer.lat,
        lng: Number.isFinite(lng) ? lng : customer.lng,
        entrance: entrance || String(customer.entrance || "").trim(),
        comment: comment || String(customer.comment || "").trim(),
      };

      if (accepted) {
        const settings = await getDeliverySettings(client, req.user?.tenant_id || null);
        const validated = await resolveValidatedAddressSelection({
          rawSelection: {
            ...req.body,
            address_text: addressText,
            lat,
            lng,
            entrance,
            comment,
          },
          settings,
          requirePoint: false,
          allowConfirm: confirmSelection,
        });
        if (!validated.ok) {
          await client.query("ROLLBACK");
          return res.status(400).json({
            ok: false,
            error: validated.error,
            data: validated.validation || null,
          });
        }
        nextSelection = {
          ...nextSelection,
          ...validated.selection,
        };
      }

      if (accepted && saveAsDefault && nextSelection.address_text) {
        await client.query(
          `UPDATE user_delivery_addresses
           SET is_default = false,
               updated_at = now()
           WHERE user_id = $1`,
          [customer.user_id],
        );
        const addressPayload = buildAddressDbPayload(nextSelection);
        const addressInsert = await client.query(
          `INSERT INTO user_delivery_addresses (
             id, user_id, label, address_text,
             address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at,
             lat, lng, entrance, comment, is_default,
             address_structured, provider, provider_address_id,
             validation_status, validation_confidence, point_source, mismatch_distance_meters,
             delivery_zone_id, delivery_zone_label, delivery_zone_status,
             created_at, updated_at
           )
           VALUES (
             $1, $2, 'Основной адрес', NULL,
             $3, $4, $5, $6, $7,
             $8, $9, $10, $11, true,
             $12::jsonb, $13, $14,
             $15, $16, $17, $18,
             $19, $20, $21,
             now(), now()
           )
           RETURNING id`,
          [
            uuidv4(),
            customer.user_id,
            addressPayload.encrypted.ciphertext,
            addressPayload.encrypted.iv,
            addressPayload.encrypted.tag,
            addressPayload.encrypted.version,
            addressPayload.encrypted.encryptedAt,
            addressPayload.lat,
            addressPayload.lng,
            addressPayload.entrance,
            addressPayload.comment,
            JSON.stringify(addressPayload.address_structured),
            addressPayload.provider,
            addressPayload.provider_address_id,
            addressPayload.validation_status,
            addressPayload.validation_confidence,
            addressPayload.point_source,
            addressPayload.mismatch_distance_meters,
            addressPayload.delivery_zone_id,
            addressPayload.delivery_zone_label,
            addressPayload.delivery_zone_status,
          ],
        );
        addressId = String(addressInsert.rows[0].id);
      }

      const addressPayload = buildAddressDbPayload(nextSelection);
      await client.query(
        `UPDATE delivery_batch_customers
         SET call_status = $1,
             delivery_status = $2,
             address_id = $3,
             address_text = NULL,
             address_ciphertext = $4,
             address_iv = $5,
             address_tag = $6,
             address_encryption_version = $7,
             address_encrypted_at = $8,
             lat = $9,
             lng = $10,
             entrance = $11,
             comment = $12,
             address_structured = $13::jsonb,
             provider = $14,
             provider_address_id = $15,
             validation_status = $16,
             validation_confidence = $17,
             point_source = $18,
             mismatch_distance_meters = $19,
             delivery_zone_id = $20,
             delivery_zone_label = $21,
             delivery_zone_status = $22,
             preferred_time_from = $23,
             preferred_time_to = $24,
             accepted_at = CASE WHEN $1 = 'accepted' THEN now() ELSE accepted_at END,
             agreed_sum = CASE WHEN $1 = 'accepted' THEN processed_sum ELSE agreed_sum END,
             updated_at = now()
         WHERE id = $25`,
        [
          accepted ? "accepted" : "declined",
          accepted ? "preparing_delivery" : "declined",
          addressId,
          addressPayload.encrypted.ciphertext,
          addressPayload.encrypted.iv,
          addressPayload.encrypted.tag,
          addressPayload.encrypted.version,
          addressPayload.encrypted.encryptedAt,
          addressPayload.lat,
          addressPayload.lng,
          addressPayload.entrance,
          addressPayload.comment,
          JSON.stringify(addressPayload.address_structured),
          addressPayload.provider,
          addressPayload.provider_address_id,
          addressPayload.validation_status,
          addressPayload.validation_confidence,
          addressPayload.point_source,
          addressPayload.mismatch_distance_meters,
          addressPayload.delivery_zone_id,
          addressPayload.delivery_zone_label,
          addressPayload.delivery_zone_status,
          preferredWindow.fromText,
          preferredWindow.toText,
          customerId,
        ],
      );

      if (accepted) {
        await client.query(
          `UPDATE cart_items
           SET status = 'preparing_delivery',
               updated_at = now()
           WHERE id IN (
             SELECT cart_item_id
             FROM delivery_batch_items
             WHERE batch_customer_id = $1
           )`,
          [customerId],
        );
      }
      let autoDismantleResult = { applied: false, retention: null };
      if (declined) {
        autoDismantleResult = await autoDismantleStaleCart(client, {
          userId: customer.user_id,
          tenantId: req.user?.tenant_id || null,
        });
        if (autoDismantleResult.applied) {
          const note =
            "Авторасформировка корзины после отказа от доставки (корзина старше 30 дней).";
          await client.query(
            `UPDATE delivery_batch_customers
             SET call_status = 'removed',
                 delivery_status = 'returned_to_cart',
                 notes = CASE
                   WHEN COALESCE(BTRIM(notes), '') = '' THEN $2
                   ELSE CONCAT(notes, E'\n', $2)
                 END,
                 updated_at = now()
             WHERE id = $1`,
            [customerId, note],
          );
        }
      }

      const updatedOfferMessagesQ = await client.query(
        `UPDATE messages
         SET meta = jsonb_set(
           jsonb_set(
             jsonb_set(
               jsonb_set(
                 jsonb_set(COALESCE(meta, '{}'::jsonb), '{offer_status}', to_jsonb($1::text), true),
                 '{address_text}',
                 to_jsonb($2::text),
                 true
               ),
               '{preferred_time_from}',
               to_jsonb($3::text),
               true
             ),
             '{preferred_time_to}',
             to_jsonb($4::text),
             true
           ),
           '{responded_at}',
           to_jsonb(now()),
           true
         )
         WHERE chat_id = $5
           AND COALESCE(meta->>'kind', '') = 'delivery_offer'
           AND COALESCE(meta->>'delivery_customer_id', '') = $6
        RETURNING id`,
          [
            accepted ? "accepted" : "declined",
            nextSelection.address_text || "",
            preferredWindow.fromText || "",
            preferredWindow.toText || "",
            chat.id,
            customerId,
          ],
        );

      const followUpInsert = await client.query(
        `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
         VALUES ($1, $2, NULL, $3, $4::jsonb, now())
         RETURNING id`,
        [
          uuidv4(),
          chat.id,
          encryptMessageText(
            autoDismantleResult.applied
              ? buildDeliveryAutoDismantledText(autoDismantleResult)
              : accepted
              ? buildDeliveryAcceptedText(
                  nextSelection.address_text,
                  preferredWindow.fromText,
                  preferredWindow.toText,
                )
              : buildDeliveryDeclinedText(),
          ),
          JSON.stringify({
            kind: "delivery_offer_result",
            delivery_batch_id: customer.batch_id,
            delivery_customer_id: customerId,
            offer_status: accepted
              ? "accepted"
              : autoDismantleResult.applied
              ? "declined_auto_dismantled"
              : "declined",
            address_text: nextSelection.address_text || "",
            entrance: nextSelection.entrance || "",
            comment: nextSelection.comment || "",
            preferred_time_from: preferredWindow.fromText || "",
            preferred_time_to: preferredWindow.toText || "",
            auto_dismantled: autoDismantleResult.applied,
          }),
        ],
      );

      await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
        chat.id,
      ]);
      const autoDeleteAt = await markDeliveryChatForAutoDelete(client, chat.id);
      if (accepted) {
        await rerouteAcceptedCustomers(client, customer.batch_id);
      }
      await maybeCloseDeliveryBatchWithoutWork(
        client,
        customer.batch_id,
        req.user?.tenant_id || null,
      );
      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        for (const deletedChatId of ensured.deletedChatIds || []) {
          io.to(`user:${customer.user_id}`).emit("chat:deleted", {
            chatId: deletedChatId,
          });
        }
        for (const row of updatedOfferMessagesQ.rows) {
          const message = await hydrateSystemMessage(db, row.id);
          if (message) {
            io.to(`user:${customer.user_id}`).emit("chat:message", {
              chatId: chat.id,
              message,
            });
          }
        }
        const followUpMessage = await hydrateSystemMessage(
          db,
          followUpInsert.rows[0].id,
        );
        if (followUpMessage) {
          io.to(`user:${customer.user_id}`).emit("chat:message", {
            chatId: chat.id,
            message: followUpMessage,
          });
        }
        if (accepted) {
          emitCartUpdated(io, customer.user_id, {
            status: "preparing_delivery",
            reason: "delivery_confirmed",
          });
        } else if (autoDismantleResult.applied) {
          emitCartUpdated(io, customer.user_id, {
            status: "empty",
            reason: "cart_auto_dismantled",
            auto_dismantled: true,
          });
        } else {
          emitCartUpdated(io, customer.user_id, {
            status: "processed",
            reason: "delivery_declined",
          });
        }
        io.to(`user:${customer.user_id}`).emit("chat:updated", {
          chatId: chat.id,
          chat: {
            ...chat,
            settings: {
              ...(chat.settings && typeof chat.settings === "object"
                ? chat.settings
                : {}),
              auto_delete_after: autoDeleteAt,
            },
          },
        });
        emitDeliveryUpdated(io, customer.batch_id, req.user?.tenant_id || null);
      }

      const activeBatch = await fetchBatchDetails(
        db,
        customer.batch_id,
        req.user?.tenant_id || null,
      );
      return res.json({
        ok: true,
        data: {
          customer_id: customerId,
          status: accepted
            ? "accepted"
            : autoDismantleResult.applied
            ? "declined_auto_dismantled"
            : "declined",
          auto_dismantled: autoDismantleResult.applied,
          removed_items_count: Number(
            autoDismantleResult?.removed_items_count || 0,
          ),
          active_batch: activeBatch,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.clientRespond error", err);
      if (
        respondAddressProviderError(
          res,
          err,
          "Не удалось проверить адрес доставки. Попробуйте чуть позже.",
        )
      ) {
        return;
      }
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/batches/:batchId/customers/:customerId/decision",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const { batchId, customerId } = req.params;
    const accepted = req.body?.accepted === true;
    const declined = req.body?.accepted === false;
    const unreachableFirstCall =
      declined &&
      (req.body?.unreachable_first_call === true ||
        req.body?.call_unreachable === true ||
        req.body?.phone_unreachable === true);
    if (!accepted && !declined) {
      return res
        .status(400)
        .json({ ok: false, error: "Нужно указать accepted = true или false" });
    }

    const addressText = String(req.body?.address_text || "").trim();
    const lat =
      req.body?.lat == null || req.body?.lat === ""
        ? null
        : Number(req.body.lat);
    const lng =
      req.body?.lng == null || req.body?.lng === ""
        ? null
        : Number(req.body.lng);
    const entrance = String(req.body?.entrance || req.body?.entrance_or_hint || "").trim();
    const comment = String(req.body?.comment || "").trim();
    const saveAsDefault = req.body?.save_as_default !== false;
    const confirmSelection = req.body?.confirm_selection === true;
    let preferredWindow;
    try {
      preferredWindow = sanitizePreferredWindow(
        req.body?.preferred_time_from,
        req.body?.preferred_time_to,
      );
    } catch (error) {
      return res.status(400).json({ ok: false, error: error.message });
    }

    if (accepted) {
      const hasAddress = addressText.length > 0 || (Number.isFinite(lat) && Number.isFinite(lng));
      if (!hasAddress) {
        return res.status(400).json({
          ok: false,
          error: "При подтверждении нужно указать адрес или координаты",
        });
      }
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const customerQ = await client.query(
        `SELECT c.*,
                b.delivery_date,
                b.status AS batch_status
         FROM delivery_batch_customers c
         JOIN delivery_batches b ON b.id = c.batch_id
         JOIN users scope_u ON scope_u.id = c.user_id
         WHERE c.id = $1
           AND c.batch_id = $2
           AND ($3::uuid IS NULL OR scope_u.tenant_id = $3::uuid)
         LIMIT 1
         FOR UPDATE`,
        [customerId, batchId, req.user?.tenant_id || null],
      );
      if (customerQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Клиент в листе доставки не найден" });
      }

      const customer = customerQ.rows[0];
      if (!["calling", "couriers_assigned"].includes(String(customer.batch_status || ""))) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Этот лист уже закрыт для новых решений",
        });
      }
      if (String(customer.call_status || "") !== "pending") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Клиент уже ответил на доставку",
        });
      }
      let addressId = customer.address_id ? String(customer.address_id) : null;
      const ensured = await ensureDeliveryChat(
        client,
        customer.user_id,
        req.user.id,
        req.user.tenant_id || null,
      );
      const chat = ensured.chat;
      let nextSelection = {
        ...mapStoredDeliveryAddressRow(customer),
        address_text: addressText || decodeAddressFromRow(customer),
        lat: Number.isFinite(lat) ? lat : customer.lat,
        lng: Number.isFinite(lng) ? lng : customer.lng,
        entrance: entrance || String(customer.entrance || "").trim(),
        comment: comment || String(customer.comment || "").trim(),
      };

      if (accepted) {
        const settings = await getDeliverySettings(client, req.user?.tenant_id || null);
        const validated = await resolveValidatedAddressSelection({
          rawSelection: {
            ...req.body,
            address_text: addressText,
            lat,
            lng,
            entrance,
            comment,
          },
          settings,
          requirePoint: false,
          allowConfirm: confirmSelection,
        });
        if (!validated.ok) {
          await client.query("ROLLBACK");
          return res.status(400).json({
            ok: false,
            error: validated.error,
            data: validated.validation || null,
          });
        }
        nextSelection = {
          ...nextSelection,
          ...validated.selection,
        };
      }

      if (accepted && saveAsDefault && nextSelection.address_text) {
        await client.query(
          `UPDATE user_delivery_addresses
           SET is_default = false,
               updated_at = now()
           WHERE user_id = $1`,
          [customer.user_id],
        );
        const addressPayload = buildAddressDbPayload(nextSelection);
        const addressInsert = await client.query(
          `INSERT INTO user_delivery_addresses (
             id, user_id, label, address_text,
             address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at,
             lat, lng, entrance, comment, is_default,
             address_structured, provider, provider_address_id,
             validation_status, validation_confidence, point_source, mismatch_distance_meters,
             delivery_zone_id, delivery_zone_label, delivery_zone_status,
             created_at, updated_at
           )
           VALUES (
             $1, $2, 'Основной адрес', NULL,
             $3, $4, $5, $6, $7,
             $8, $9, $10, $11, true,
             $12::jsonb, $13, $14,
             $15, $16, $17, $18,
             $19, $20, $21,
             now(), now()
           )
           RETURNING id`,
          [
            uuidv4(),
            customer.user_id,
            addressPayload.encrypted.ciphertext,
            addressPayload.encrypted.iv,
            addressPayload.encrypted.tag,
            addressPayload.encrypted.version,
            addressPayload.encrypted.encryptedAt,
            addressPayload.lat,
            addressPayload.lng,
            addressPayload.entrance,
            addressPayload.comment,
            JSON.stringify(addressPayload.address_structured),
            addressPayload.provider,
            addressPayload.provider_address_id,
            addressPayload.validation_status,
            addressPayload.validation_confidence,
            addressPayload.point_source,
            addressPayload.mismatch_distance_meters,
            addressPayload.delivery_zone_id,
            addressPayload.delivery_zone_label,
            addressPayload.delivery_zone_status,
          ],
        );
        addressId = String(addressInsert.rows[0].id);
      }

      const addressPayload = buildAddressDbPayload(nextSelection);
      await client.query(
        `UPDATE delivery_batch_customers
         SET call_status = $1,
             delivery_status = $2,
             address_id = $3,
             address_text = NULL,
             address_ciphertext = $4,
             address_iv = $5,
             address_tag = $6,
             address_encryption_version = $7,
             address_encrypted_at = $8,
             lat = $9,
             lng = $10,
             entrance = $11,
             comment = $12,
             address_structured = $13::jsonb,
             provider = $14,
             provider_address_id = $15,
             validation_status = $16,
             validation_confidence = $17,
             point_source = $18,
             mismatch_distance_meters = $19,
             delivery_zone_id = $20,
             delivery_zone_label = $21,
             delivery_zone_status = $22,
             preferred_time_from = $23,
             preferred_time_to = $24,
             accepted_at = CASE WHEN $1 = 'accepted' THEN now() ELSE accepted_at END,
             agreed_sum = CASE WHEN $1 = 'accepted' THEN processed_sum ELSE agreed_sum END,
             updated_at = now()
         WHERE id = $25`,
        [
          accepted ? "accepted" : "declined",
          accepted ? "preparing_delivery" : "declined",
          addressId,
          addressPayload.encrypted.ciphertext,
          addressPayload.encrypted.iv,
          addressPayload.encrypted.tag,
          addressPayload.encrypted.version,
          addressPayload.encrypted.encryptedAt,
          addressPayload.lat,
          addressPayload.lng,
          addressPayload.entrance,
          addressPayload.comment,
          JSON.stringify(addressPayload.address_structured),
          addressPayload.provider,
          addressPayload.provider_address_id,
          addressPayload.validation_status,
          addressPayload.validation_confidence,
          addressPayload.point_source,
          addressPayload.mismatch_distance_meters,
          addressPayload.delivery_zone_id,
          addressPayload.delivery_zone_label,
          addressPayload.delivery_zone_status,
          preferredWindow.fromText,
          preferredWindow.toText,
          customerId,
        ],
      );

      if (accepted) {
        await client.query(
          `UPDATE cart_items
           SET status = 'preparing_delivery',
               updated_at = now()
           WHERE id IN (
             SELECT cart_item_id
             FROM delivery_batch_items
             WHERE batch_customer_id = $1
           )`,
          [customerId],
        );
      }
      let autoDismantleResult = { applied: false, retention: null };
      if (declined) {
        autoDismantleResult = await autoDismantleStaleCart(client, {
          userId: customer.user_id,
          tenantId: req.user?.tenant_id || null,
        });
        if (autoDismantleResult.applied) {
          const note =
            "Авторасформировка корзины после отказа от доставки (корзина старше 30 дней).";
          await client.query(
            `UPDATE delivery_batch_customers
             SET call_status = 'removed',
                 delivery_status = 'returned_to_cart',
                 notes = CASE
                   WHEN COALESCE(BTRIM(notes), '') = '' THEN $2
                   ELSE CONCAT(notes, E'\n', $2)
                 END,
                 updated_at = now()
             WHERE id = $1`,
            [customerId, note],
          );
        }
      }

      const updatedOfferMessagesQ = await client.query(
        `UPDATE messages
         SET meta = jsonb_set(
           jsonb_set(
             jsonb_set(
               jsonb_set(
                 jsonb_set(COALESCE(meta, '{}'::jsonb), '{offer_status}', to_jsonb($1::text), true),
                 '{address_text}',
                 to_jsonb($2::text),
                 true
               ),
               '{preferred_time_from}',
               to_jsonb($3::text),
               true
             ),
             '{preferred_time_to}',
             to_jsonb($4::text),
             true
           ),
           '{responded_at}',
           to_jsonb(now()),
           true
         )
         WHERE chat_id = $5
           AND COALESCE(meta->>'kind', '') = 'delivery_offer'
           AND COALESCE(meta->>'delivery_customer_id', '') = $6
        RETURNING id`,
        [
          accepted ? "accepted" : "declined",
          nextSelection.address_text || "",
          preferredWindow.fromText || "",
          preferredWindow.toText || "",
          chat.id,
          customerId,
        ],
      );

      const followUpInsert = await client.query(
        `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
         VALUES ($1, $2, NULL, $3, $4::jsonb, now())
         RETURNING id`,
        [
          uuidv4(),
          chat.id,
          encryptMessageText(
            autoDismantleResult.applied
              ? buildDeliveryAutoDismantledText(autoDismantleResult)
              : accepted
              ? buildDeliveryAcceptedText(
                  nextSelection.address_text,
                  preferredWindow.fromText,
                  preferredWindow.toText,
                )
              : buildDeliveryDeclinedText(),
          ),
          JSON.stringify({
            kind: "delivery_offer_result",
            delivery_batch_id: customer.batch_id,
            delivery_customer_id: customerId,
            offer_status: accepted
              ? "accepted"
              : autoDismantleResult.applied
              ? "declined_auto_dismantled"
              : "declined",
            address_text: nextSelection.address_text || "",
            entrance: nextSelection.entrance || "",
            comment: nextSelection.comment || "",
            preferred_time_from: preferredWindow.fromText || "",
            preferred_time_to: preferredWindow.toText || "",
            responded_by: "admin",
            auto_dismantled: autoDismantleResult.applied,
          }),
        ],
      );

      await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
        chat.id,
      ]);
      const autoDeleteAt = await markDeliveryChatForAutoDelete(client, chat.id);
      await client.query("UPDATE delivery_batches SET updated_at = now() WHERE id = $1", [
        batchId,
      ]);
      if (accepted) {
        await rerouteAcceptedCustomers(client, batchId);
      }
      await maybeCloseDeliveryBatchWithoutWork(
        client,
        batchId,
        req.user?.tenant_id || null,
      );
      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io && ensured.created) {
        io.to(`user:${customer.user_id}`).emit("chat:created", {
          chat,
        });
      }
      if (io) {
        for (const deletedChatId of ensured.deletedChatIds || []) {
          io.to(`user:${customer.user_id}`).emit("chat:deleted", {
            chatId: deletedChatId,
          });
        }
        for (const row of updatedOfferMessagesQ.rows) {
          const message = await hydrateSystemMessage(db, row.id);
          if (message) {
            io.to(`user:${customer.user_id}`).emit("chat:message", {
              chatId: chat.id,
              message,
            });
          }
        }
        const followUpMessage = await hydrateSystemMessage(
          db,
          followUpInsert.rows[0].id,
        );
        if (followUpMessage) {
          io.to(`user:${customer.user_id}`).emit("chat:message", {
            chatId: chat.id,
            message: followUpMessage,
          });
        }
        io.to(`user:${customer.user_id}`).emit("chat:updated", {
          chatId: chat.id,
          chat: {
            ...chat,
            settings: {
              ...(chat.settings && typeof chat.settings === "object"
                ? chat.settings
                : {}),
              auto_delete_after: autoDeleteAt,
            },
          },
        });
      }
      if (accepted) {
        emitCartUpdated(io, customer.user_id, {
          status: "preparing_delivery",
          reason: "delivery_confirmed",
        });
      } else if (autoDismantleResult.applied) {
        emitCartUpdated(io, customer.user_id, {
          status: "empty",
          reason: "cart_auto_dismantled",
          auto_dismantled: true,
        });
      } else {
        emitCartUpdated(io, customer.user_id, {
          status: "processed",
          reason: "delivery_declined",
        });
      }
      emitDeliveryUpdated(io, batchId, req.user?.tenant_id || null);

      let autoDeletedClient = false;
      if (
        declined &&
        unreachableFirstCall &&
        CLIENT_UNREACHABLE_FIRST_CALL_AUTO_DELETE
      ) {
        const deletion = await deleteClientAccountByPolicy(db, {
          userId: customer.user_id,
          tenantId: req.user?.tenant_id || null,
          reason: "phone_unreachable_first_call",
          source: "delivery_admin_decision",
        });
        autoDeletedClient = deletion.applied === true;
        if (autoDeletedClient) {
          emitToTenant(io, req.user?.tenant_id || null, "tenant:client:auto_deleted", {
            user_id: deletion.user.id,
            email: deletion.user.email,
            phone: deletion.user.phone,
            reason: "phone_unreachable_first_call",
            source: "delivery_admin_decision",
            at: new Date().toISOString(),
          });
          await emitToCreators(io, "creator:alert", {
            type: "client_auto_deleted",
            tenant_id:
              deletion.user.tenant_id || resolveTenantScopeId(req.user?.tenant_id || null),
            user_id: deletion.user.id,
            email: deletion.user.email,
            phone: deletion.user.phone,
            reason: "phone_unreachable_first_call",
            source: "delivery_admin_decision",
            at: new Date().toISOString(),
          });
        }
      }

      const activeBatch = await fetchBatchDetails(
        db,
        batchId,
        req.user?.tenant_id || null,
      );
      return res.json({
        ok: true,
        data: {
          customer_id: customerId,
          status: accepted
            ? "accepted"
            : autoDismantleResult.applied
            ? "declined_auto_dismantled"
            : "declined",
          auto_dismantled: autoDismantleResult.applied,
          removed_items_count: Number(
            autoDismantleResult?.removed_items_count || 0,
          ),
          auto_deleted_client: autoDeletedClient,
          active_batch: activeBatch,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.customer.decision error", err);
      if (
        respondAddressProviderError(
          res,
          err,
          "Не удалось проверить адрес клиента. Попробуйте чуть позже.",
        )
      ) {
        return;
      }
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.patch(
  "/batches/:batchId/customers/:customerId/assembly/start",
  requireAuth,
  requireDeliveryAssemblyAccess,
  async (req, res) => {
    const { batchId, customerId } = req.params;
    const tenantId = req.user?.tenant_id || null;
    const client = await db.pool.connect();
    let printJobs = [];
    try {
      await client.query("BEGIN");
      const customer = await fetchDeliveryCustomerForAssembly(
        client,
        batchId,
        customerId,
        tenantId,
        { forUpdate: true },
      );
      if (!customer) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Клиент доставки не найден" });
      }
      if (String(customer.call_status || "") !== "accepted") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Сборку можно начать только для подтвержденной доставки",
        });
      }
      if (String(customer.assembly_status || "not_started") === "assembled") {
        await client.query("ROLLBACK");
        return res.status(400).json({ ok: false, error: "Эта корзина уже собрана" });
      }

      if (String(customer.assembly_status || "not_started") === "not_started") {
        await client.query(
          `UPDATE delivery_batch_customers
           SET assembly_status = 'assembling',
               assembly_started_at = COALESCE(assembly_started_at, now()),
               assembly_started_by = COALESCE(assembly_started_by, $3),
               delivery_status = 'preparing_delivery',
               updated_at = now()
           WHERE batch_id = $1
             AND id = $2`,
          [batchId, customerId, req.user.id],
        );
        customer.assembly_status = "assembling";
      }

      const normalRequested = Math.max(
        0,
        Number(customer.normal_stickers_requested) || 0,
      );
      if (normalRequested < 1) {
        printJobs.push(
          await createStickerPrintJob(client, {
            tenantId,
            userId: req.user.id,
            createdBy: req.user.id,
            sourceId: customerId,
            stickerType: "delivery_normal",
            payload: normalDeliveryStickerPayload(customer),
          }),
        );
        await client.query(
          `UPDATE delivery_batch_customers
           SET normal_stickers_requested = 1,
               updated_at = now()
           WHERE id = $1`,
          [customerId],
        );
      }

      await client.query("COMMIT");

      const activeBatch = await fetchBatchDetails(db, batchId, tenantId);
      const io = req.app.get("io");
      if (io) {
        emitStickerPrintJobs(io, printJobs);
        emitDeliveryUpdated(io, batchId, tenantId);
      }
      return res.json({ ok: true, data: { active_batch: activeBatch } });
    } catch (err) {
      await client.query("ROLLBACK").catch(() => {});
      console.error("delivery.assembly.start error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.patch(
  "/batches/:batchId/customers/:customerId/assembly",
  requireAuth,
  requireDeliveryAssemblyAccess,
  async (req, res) => {
    const { batchId, customerId } = req.params;
    const tenantId = req.user?.tenant_id || null;
    const hasPackagePlaces = Object.prototype.hasOwnProperty.call(
      req.body || {},
      "package_places",
    );
    const packagePlaces = hasPackagePlaces ? Number(req.body?.package_places) : null;
    if (
      hasPackagePlaces &&
      (!Number.isInteger(packagePlaces) || packagePlaces <= 0)
    ) {
      return res.status(400).json({
        ok: false,
        error: "Количество мест должно быть больше нуля",
      });
    }
    const itemPayloads = normalizeAssemblyItemsPayload(req.body?.items);
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const customer = await fetchDeliveryCustomerForAssembly(
        client,
        batchId,
        customerId,
        tenantId,
        { forUpdate: true },
      );
      if (!customer) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Клиент доставки не найден" });
      }
      if (String(customer.call_status || "") !== "accepted") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Сборка доступна только для подтвержденной доставки",
        });
      }
      if (String(customer.assembly_status || "not_started") === "not_started") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Сначала нажмите “Начать сборку”",
        });
      }

      if (hasPackagePlaces) {
        await client.query(
          `UPDATE delivery_batch_customers
           SET package_places = $2,
               updated_at = now()
           WHERE id = $1`,
          [customerId, packagePlaces],
        );
      }

      const itemsById = new Map(customer.items.map((item) => [String(item.id), item]));
      let removedAny = false;
      for (const payload of itemPayloads) {
        const item = itemsById.get(String(payload.id));
        if (!item) continue;
        const wasRemoved = String(item.assembly_status || "") === "removed";
        const nextStatus = payload.removed
          ? "removed"
          : payload.collected
          ? "collected"
          : "pending";
        const bulky = payload.removed ? false : payload.is_bulky === true;
        const bulkyNote =
          payload.bulky_note ||
          (bulky ? String(item.product_title || "Габарит").trim() : "");
        if (payload.removed) {
          removedAny = true;
          if (!wasRemoved) {
            await createDefectReportForDeliveryItem(client, {
              tenantId,
              item,
              reason: payload.removed_reason || "Убран при сборке доставки",
              actorId: req.user.id,
            });
            await client.query(
              `UPDATE cart_items
               SET status = 'cancelled',
                   updated_at = now()
               WHERE id = $1`,
              [item.cart_item_id],
            );
          }
        }
        await client.query(
          `UPDATE delivery_batch_items
           SET assembly_status = $2,
               is_bulky = $3,
               bulky_note = NULLIF(BTRIM($4::text), ''),
               bulky_price = CASE WHEN $3 THEN $5::numeric ELSE 0::numeric END,
               removed_reason = CASE WHEN $2 = 'removed' THEN NULLIF(BTRIM($6::text), '') ELSE NULL END,
               removed_at = CASE
                 WHEN $2 = 'removed' AND assembly_status <> 'removed' THEN now()
                 WHEN $2 = 'removed' THEN removed_at
                 ELSE NULL
               END,
               removed_by = CASE
                 WHEN $2 = 'removed' THEN COALESCE(removed_by, $7)
                 ELSE NULL
               END
           WHERE id = $1`,
          [
            payload.id,
            nextStatus,
            bulky,
            bulkyNote,
            toMoney(item.unit_price || item.line_total),
            payload.removed_reason,
            req.user.id,
          ],
        );
      }

      await recalculateDeliveryCustomerTotals(client, customerId);
      await client.query(
        `UPDATE delivery_batch_customers
         SET assembly_status = CASE
               WHEN assembly_status = 'assembled' THEN 'assembled'
               WHEN $2 THEN 'issue'
               ELSE 'assembling'
             END,
             updated_at = now()
         WHERE id = $1`,
        [customerId, removedAny],
      );

      await client.query("COMMIT");

      const activeBatch = await fetchBatchDetails(db, batchId, tenantId);
      const io = req.app.get("io");
      if (io) {
        emitDeliveryUpdated(io, batchId, tenantId);
      }
      return res.json({ ok: true, data: { active_batch: activeBatch } });
    } catch (err) {
      await client.query("ROLLBACK").catch(() => {});
      console.error("delivery.assembly.save error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/batches/:batchId/customers/:customerId/assembly/complete",
  requireAuth,
  requireDeliveryAssemblyAccess,
  async (req, res) => {
    const { batchId, customerId } = req.params;
    const tenantId = req.user?.tenant_id || null;
    const packagePlaces = Number(req.body?.package_places);
    if (!Number.isInteger(packagePlaces) || packagePlaces <= 0) {
      return res.status(400).json({
        ok: false,
        error: "Количество мест должно быть больше нуля",
      });
    }
    const client = await db.pool.connect();
    let printJobs = [];
    try {
      await client.query("BEGIN");
      const customer = await fetchDeliveryCustomerForAssembly(
        client,
        batchId,
        customerId,
        tenantId,
        { forUpdate: true },
      );
      if (!customer) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Клиент доставки не найден" });
      }
      if (String(customer.call_status || "") !== "accepted") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Собрать можно только подтвержденную доставку",
        });
      }
      if (String(customer.assembly_status || "not_started") === "not_started") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Сначала нажмите “Начать сборку”",
        });
      }

      const pendingQ = await client.query(
        `SELECT COUNT(*)::int AS total
         FROM delivery_batch_items
         WHERE batch_customer_id = $1
           AND assembly_status = 'pending'`,
        [customerId],
      );
      if ((Number(pendingQ.rows[0]?.total) || 0) > 0) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error:
            "Нельзя завершить сборку: отметьте каждый товар как “Положил” или “Ненаход”.",
        });
      }
      await client.query(
        `UPDATE delivery_batch_customers
         SET package_places = $3,
             updated_at = now()
         WHERE batch_id = $1
           AND id = $2`,
        [batchId, customerId, packagePlaces],
      );
      await recalculateDeliveryCustomerTotals(client, customerId);
      const updatedCustomer = await fetchDeliveryCustomerForAssembly(
        client,
        batchId,
        customerId,
        tenantId,
        { forUpdate: true },
      );
      printJobs = await queueMissingAssemblyStickerJobs(client, {
        customer: updatedCustomer,
        items: updatedCustomer?.items || [],
        tenantId,
        userId: req.user.id,
        createdBy: req.user.id,
      });
      await client.query(
        `UPDATE delivery_batch_customers
         SET assembly_status = 'assembled',
             assembly_completed_at = now(),
             assembly_completed_by = $3,
             delivery_status = 'preparing_delivery',
             updated_at = now()
         WHERE batch_id = $1
           AND id = $2`,
        [batchId, customerId, req.user.id],
      );

      await client.query("COMMIT");

      const activeBatch = await fetchBatchDetails(db, batchId, tenantId);
      const io = req.app.get("io");
      if (io) {
        emitStickerPrintJobs(io, printJobs);
        emitDeliveryUpdated(io, batchId, tenantId);
      }
      return res.json({ ok: true, data: { active_batch: activeBatch } });
    } catch (err) {
      await client.query("ROLLBACK").catch(() => {});
      console.error("delivery.assembly.complete error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.patch(
  "/batches/:batchId/customers/:customerId/logistics",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const { batchId, customerId } = req.params;
    const packagePlaces = Number(req.body?.package_places);
    const bulkyPlaces = Number(req.body?.bulky_places ?? 0);
    const bulkyNote = String(req.body?.bulky_note || "").trim();
    if (!Number.isInteger(packagePlaces) || packagePlaces <= 0) {
      return res.status(400).json({
        ok: false,
        error: "Количество мест должно быть больше нуля",
      });
    }
    if (!Number.isInteger(bulkyPlaces) || bulkyPlaces < 0) {
      return res.status(400).json({
        ok: false,
        error: "Количество габаритов не может быть отрицательным",
      });
    }

    try {
      const updated = await db.query(
        `UPDATE delivery_batch_customers c
         SET package_places = $1,
             bulky_places = $2,
             bulky_note = $3,
             updated_at = now()
         FROM users u
         WHERE c.batch_id = $4
           AND c.id = $5
           AND u.id = c.user_id
           AND ($6::uuid IS NULL OR u.tenant_id = $6::uuid)
         RETURNING c.id`,
        [
          packagePlaces,
          bulkyPlaces,
          bulkyNote || null,
          batchId,
          customerId,
          req.user?.tenant_id || null,
        ],
      );
      if (updated.rowCount === 0) {
        return res.status(404).json({
          ok: false,
          error: "Клиент в листе доставки не найден",
        });
      }
      const activeBatch = await fetchBatchDetails(
        db,
        batchId,
        req.user?.tenant_id || null,
      );
      const io = req.app.get("io");
      emitDeliveryUpdated(io, batchId, req.user?.tenant_id || null);
      return res.json({ ok: true, data: { active_batch: activeBatch } });
    } catch (err) {
      console.error("delivery.customer.logistics error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.post(
  "/batches/:batchId/customers/:customerId/reassign",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const { batchId, customerId } = req.params;
    const courierName = String(req.body?.courier_name || "").trim();

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const batchQ = await client.query(
        `SELECT b.id, b.status, b.courier_names
         FROM delivery_batches b
         WHERE b.id = $1
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users bu
               WHERE bu.id = b.created_by
                 AND bu.tenant_id = $2::uuid
             )
             OR EXISTS (
               SELECT 1
               FROM delivery_batch_customers c2
               JOIN users u2 ON u2.id = c2.user_id
               WHERE c2.batch_id = b.id
                 AND u2.tenant_id = $2::uuid
             )
           )
         LIMIT 1
         FOR UPDATE`,
        [batchId, req.user?.tenant_id || null],
      );
      if (batchQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Лист доставки не найден" });
      }
      const batch = batchQ.rows[0];
      const batchStatus = String(batch.status || "");
      if (!["calling", "couriers_assigned"].includes(batchStatus)) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Менять курьера можно только в активном листе доставки",
        });
      }
      const courierNames = Array.isArray(batch.courier_names)
        ? batch.courier_names.map((item) => String(item || "").trim()).filter(Boolean)
        : [];
      let courierSlot = null;
      let courierCode = null;
      if (courierName) {
        courierSlot = courierNames.findIndex((item) => item === courierName);
        if (courierSlot < 0) {
          await client.query("ROLLBACK");
          return res.status(400).json({
            ok: false,
            error: "Такого курьера нет в текущем листе",
          });
        }
        courierSlot += 1;
        courierCode = firstLetterCode(courierName);
      }

      const customerQ = await client.query(
        `SELECT id, call_status
         FROM delivery_batch_customers
         WHERE id = $1
           AND batch_id = $2
         LIMIT 1`,
        [customerId, batchId],
      );
      if (customerQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({
          ok: false,
          error: "Клиент в листе доставки не найден",
        });
      }
      if (String(customerQ.rows[0].call_status || "") !== "accepted") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Курьера можно менять только для подтвержденного клиента",
        });
      }

      await client.query(
        `UPDATE delivery_batch_customers
         SET locked_courier_slot = $1,
             locked_courier_name = $2,
             locked_courier_code = $3,
             updated_at = now()
         WHERE id = $4
           AND batch_id = $5`,
        [courierSlot, courierName || null, courierCode, customerId, batchId],
      );

      await rerouteAcceptedCustomers(client, batchId);
      await client.query("COMMIT");

      const activeBatch = await fetchBatchDetails(
        db,
        batchId,
        req.user?.tenant_id || null,
      );
      const io = req.app.get("io");
      emitDeliveryUpdated(io, batchId, req.user?.tenant_id || null);
      return res.json({ ok: true, data: { active_batch: activeBatch } });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.customer.reassign error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.patch(
  "/batches/:batchId/route-order",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const batchId = String(req.params?.batchId || "").trim();
    const ordersRaw = Array.isArray(req.body?.orders) ? req.body.orders : [];
    if (!isUuidLike(batchId)) {
      return res.status(400).json({ ok: false, error: "Некорректный batchId" });
    }
    if (ordersRaw.length === 0) {
      return res.status(400).json({ ok: false, error: "Нужен список orders" });
    }

    const normalized = [];
    for (const raw of ordersRaw) {
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
      const customerId = String(raw.customer_id || "").trim();
      const routeOrder = Number(raw.route_order);
      const courierName = String(raw.courier_name || "").trim();
      if (!isUuidLike(customerId)) continue;
      if (!Number.isInteger(routeOrder) || routeOrder <= 0) continue;
      normalized.push({
        customer_id: customerId,
        route_order: routeOrder,
        courier_name: courierName || null,
      });
    }
    if (normalized.length === 0) {
      return res.status(400).json({
        ok: false,
        error: "В orders должны быть customer_id и route_order > 0",
      });
    }

    const uniqueIds = new Set();
    for (const row of normalized) {
      if (uniqueIds.has(row.customer_id)) {
        return res.status(400).json({
          ok: false,
          error: "Один customer_id указан несколько раз",
        });
      }
      uniqueIds.add(row.customer_id);
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const batchQ = await client.query(
        `SELECT b.id, b.status
         FROM delivery_batches b
         WHERE b.id = $1
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM delivery_batch_customers c2
               JOIN users u2 ON u2.id = c2.user_id
               WHERE c2.batch_id = b.id
                 AND u2.tenant_id = $2::uuid
             )
           )
         LIMIT 1
         FOR UPDATE`,
        [batchId, req.user?.tenant_id || null],
      );
      if (batchQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Лист доставки не найден" });
      }
      const batchStatus = String(batchQ.rows[0].status || "");
      if (!["calling", "couriers_assigned"].includes(batchStatus)) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Ручное редактирование маршрута доступно только в активном листе",
        });
      }

      const customerIds = normalized.map((item) => item.customer_id);
      const existingQ = await client.query(
        `SELECT c.id
         FROM delivery_batch_customers c
         WHERE c.batch_id = $1
           AND c.id = ANY($2::uuid[])
           AND c.call_status = 'accepted'
         FOR UPDATE`,
        [batchId, customerIds],
      );
      if (existingQ.rowCount !== customerIds.length) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error:
            "Можно менять порядок только для подтвержденных клиентов текущего листа",
        });
      }

      for (const row of normalized) {
        await client.query(
          `UPDATE delivery_batch_customers
           SET route_order = $1,
               courier_name = COALESCE($2, courier_name),
               updated_at = now()
           WHERE batch_id = $3
             AND id = $4`,
          [row.route_order, row.courier_name, batchId, row.customer_id],
        );

        await client.query(
          `INSERT INTO delivery_route_overrides (
             tenant_id,
             batch_id,
             customer_id,
             courier_name,
             route_order,
             updated_by,
             created_at,
             updated_at
           )
           VALUES ($1, $2, $3, $4, $5, $6, now(), now())
           ON CONFLICT (batch_id, customer_id) DO UPDATE
             SET courier_name = EXCLUDED.courier_name,
                 route_order = EXCLUDED.route_order,
                 updated_by = EXCLUDED.updated_by,
                 updated_at = now()`,
          [
            req.user?.tenant_id || null,
            batchId,
            row.customer_id,
            row.courier_name,
            row.route_order,
            req.user?.id || null,
          ],
        );
      }

      await client.query("COMMIT");

      const activeBatch = await fetchBatchDetails(
        db,
        batchId,
        req.user?.tenant_id || null,
      );
      const io = req.app.get("io");
      emitDeliveryUpdated(io, batchId, req.user?.tenant_id || null);
      return res.json({
        ok: true,
        data: {
          active_batch: activeBatch,
          updated_count: normalized.length,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.routeOrder.patch error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/batches/:batchId/customers/manual-add",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const { batchId } = req.params;
    const phone = String(req.body?.phone || "").trim();
    const addressText = String(req.body?.address_text || "").trim();
    const lat =
      req.body?.lat == null || req.body?.lat === ""
        ? null
        : Number(req.body.lat);
    const lng =
      req.body?.lng == null || req.body?.lng === ""
        ? null
        : Number(req.body.lng);
    const entrance = String(req.body?.entrance || req.body?.entrance_or_hint || "").trim();
    const comment = String(req.body?.comment || "").trim();
    const bulkyNote = String(req.body?.bulky_note || "").trim();
    const packagePlaces = Number(req.body?.package_places ?? 1);
    const bulkyPlaces = Number(req.body?.bulky_places ?? 0);
    const confirmSelection = req.body?.confirm_selection === true;
    let preferredWindow;
    try {
      preferredWindow = sanitizePreferredWindow(
        req.body?.preferred_time_from,
        req.body?.preferred_time_to,
      );
    } catch (error) {
      return res.status(400).json({ ok: false, error: error.message });
    }
    if (!phone) {
      return res.status(400).json({ ok: false, error: "Нужно указать номер телефона" });
    }
    if (!addressText) {
      return res.status(400).json({ ok: false, error: "Нужно указать адрес доставки" });
    }
    if (!Number.isInteger(packagePlaces) || packagePlaces <= 0) {
      return res.status(400).json({
        ok: false,
        error: "Количество мест должно быть больше нуля",
      });
    }
    if (!Number.isInteger(bulkyPlaces) || bulkyPlaces < 0) {
      return res.status(400).json({
        ok: false,
        error: "Количество габаритов не может быть отрицательным",
      });
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const batchQ = await client.query(
        `SELECT b.id, b.status
         FROM delivery_batches b
         WHERE b.id = $1
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users bu
               WHERE bu.id = b.created_by
                 AND bu.tenant_id = $2::uuid
             )
             OR EXISTS (
               SELECT 1
               FROM delivery_batch_customers c2
               JOIN users u2 ON u2.id = c2.user_id
               WHERE c2.batch_id = b.id
                 AND u2.tenant_id = $2::uuid
             )
           )
         LIMIT 1
         FOR UPDATE`,
        [batchId, req.user?.tenant_id || null],
      );
      if (batchQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Лист доставки не найден" });
      }
      const batchStatus = String(batchQ.rows[0].status || "");
      if (!["calling", "couriers_assigned"].includes(batchStatus)) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Вручную добавлять клиента можно только в текущий активный лист",
        });
      }

      const user = await findUserByPhone(
        client,
        phone,
        req.user?.tenant_id || null,
      );
      if (!user) {
        await client.query("ROLLBACK");
        return res.status(404).json({
          ok: false,
          error: "Клиент с таким номером телефона не найден",
        });
      }

      const existingQ = await client.query(
        `SELECT id, call_status
         FROM delivery_batch_customers
         WHERE batch_id = $1
           AND user_id = $2
         LIMIT 1`,
        [batchId, user.user_id],
      );
      if (existingQ.rowCount > 0) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error:
            String(existingQ.rows[0].call_status || "") === "pending"
              ? "Этот клиент уже в листе. Подтвердите его кнопкой в карточке."
              : "Этот клиент уже есть в текущем листе доставки",
        });
      }

      const eligible = await collectEligibleCustomerForUser(
        client,
        user.user_id,
        req.user?.tenant_id || null,
      );
      if (!eligible || !Array.isArray(eligible.items) || eligible.items.length === 0) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "У клиента нет обработанных товаров, готовых к доставке",
        });
      }

      const settings = await getDeliverySettings(client, req.user?.tenant_id || null);
      const validated = await resolveValidatedAddressSelection({
        rawSelection: {
          ...req.body,
          address_text: addressText,
          lat,
          lng,
          entrance,
          comment,
        },
        settings,
        requirePoint: false,
        allowConfirm: confirmSelection,
      });
      if (!validated.ok) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: validated.error,
          data: validated.validation || null,
        });
      }
      const selectedAddress = validated.selection;
      const addressPayload = buildAddressDbPayload(selectedAddress);

      await client.query(
        `UPDATE user_delivery_addresses
         SET is_default = false,
             updated_at = now()
         WHERE user_id = $1`,
        [user.user_id],
      );
      const addressInsert = await client.query(
        `INSERT INTO user_delivery_addresses (
           id, user_id, label, address_text,
           address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at,
           lat, lng, entrance, comment, is_default,
           address_structured, provider, provider_address_id,
           validation_status, validation_confidence, point_source, mismatch_distance_meters,
           delivery_zone_id, delivery_zone_label, delivery_zone_status,
           created_at, updated_at
         )
         VALUES (
           $1, $2, 'Основной адрес', NULL,
           $3, $4, $5, $6, $7,
           $8, $9, $10, $11, true,
           $12::jsonb, $13, $14,
           $15, $16, $17, $18,
           $19, $20, $21,
           now(), now()
         )
         RETURNING id`,
        [
          uuidv4(),
          user.user_id,
          addressPayload.encrypted.ciphertext,
          addressPayload.encrypted.iv,
          addressPayload.encrypted.tag,
          addressPayload.encrypted.version,
          addressPayload.encrypted.encryptedAt,
          addressPayload.lat,
          addressPayload.lng,
          addressPayload.entrance,
          addressPayload.comment,
          JSON.stringify(addressPayload.address_structured),
          addressPayload.provider,
          addressPayload.provider_address_id,
          addressPayload.validation_status,
          addressPayload.validation_confidence,
          addressPayload.point_source,
          addressPayload.mismatch_distance_meters,
          addressPayload.delivery_zone_id,
          addressPayload.delivery_zone_label,
          addressPayload.delivery_zone_status,
        ],
      );
      const addressId = String(addressInsert.rows[0].id);
      const batchCustomerId = uuidv4();

      await client.query(
        `INSERT INTO delivery_batch_customers (
           id, batch_id, user_id, customer_name, customer_phone,
           processed_sum, agreed_sum, claim_return_sum, claim_discount_sum, claims_total, processed_items_count, shelf_number,
           address_id, address_text, address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at, lat, lng,
           entrance, comment, address_structured, provider, provider_address_id,
           validation_status, validation_confidence, point_source, mismatch_distance_meters,
           delivery_zone_id, delivery_zone_label, delivery_zone_status,
           call_status, delivery_status, preferred_time_from, preferred_time_to,
           package_places, bulky_places, bulky_note, accepted_at, created_at, updated_at
         )
         VALUES (
           $1, $2, $3, $4, $5,
           $6, $6, $7, $8, $9, $10, $11,
           $12, NULL, $13, $14, $15, $16, $17, $18, $19,
           $20, $21, $22::jsonb, $23, $24,
           $25, $26, $27, $28,
           $29, $30, $31,
           'accepted', 'preparing_delivery', $32, $33,
           $34, $35, $36, now(), now(), now()
         )`,
        [
          batchCustomerId,
          batchId,
          user.user_id,
          eligible.customer_name,
          eligible.customer_phone,
          eligible.processed_sum,
          eligible.claim_return_sum,
          eligible.claim_discount_sum,
          eligible.claims_total,
          eligible.processed_items_count,
          eligible.shelf_number,
          addressId,
          addressPayload.encrypted.ciphertext,
          addressPayload.encrypted.iv,
          addressPayload.encrypted.tag,
          addressPayload.encrypted.version,
          addressPayload.encrypted.encryptedAt,
          addressPayload.lat,
          addressPayload.lng,
          addressPayload.entrance,
          addressPayload.comment,
          JSON.stringify(addressPayload.address_structured),
          addressPayload.provider,
          addressPayload.provider_address_id,
          addressPayload.validation_status,
          addressPayload.validation_confidence,
          addressPayload.point_source,
          addressPayload.mismatch_distance_meters,
          addressPayload.delivery_zone_id,
          addressPayload.delivery_zone_label,
          addressPayload.delivery_zone_status,
          preferredWindow.fromText,
          preferredWindow.toText,
          packagePlaces,
          bulkyPlaces,
          bulkyNote || null,
        ],
      );

      for (const item of eligible.items) {
        await client.query(
          `INSERT INTO delivery_batch_items (
             id, batch_id, batch_customer_id, cart_item_id, user_id, product_id,
             quantity, unit_price, line_total, product_code, product_title,
             product_description, product_image_url, created_at
           )
           VALUES (
             $1, $2, $3, $4, $5, $6,
             $7, $8, $9, $10, $11,
             $12, $13, now()
           )`,
          [
            uuidv4(),
            batchId,
            batchCustomerId,
            item.cart_item_id,
            item.user_id,
            item.product_id,
            item.quantity,
            item.unit_price,
            item.line_total,
            item.product_code,
            item.product_title,
            item.product_description,
            item.product_image_url,
          ],
        );
      }

      await client.query(
        `UPDATE cart_items
         SET status = 'preparing_delivery',
             updated_at = now()
         WHERE id IN (
           SELECT cart_item_id
           FROM delivery_batch_items
           WHERE batch_customer_id = $1
         )`,
        [batchCustomerId],
      );

      const ensured = await ensureDeliveryChat(
        client,
        user.user_id,
        req.user.id,
        req.user.tenant_id || null,
      );
      const chat = ensured.chat;
      const followUpInsert = await client.query(
        `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
         VALUES ($1, $2, NULL, $3, $4::jsonb, now())
         RETURNING id`,
        [
          uuidv4(),
          chat.id,
          encryptMessageText(
            buildDeliveryAcceptedText(
              selectedAddress.address_text,
              preferredWindow.fromText,
              preferredWindow.toText,
            ),
          ),
          JSON.stringify({
            kind: "delivery_offer_result",
            delivery_batch_id: batchId,
            delivery_customer_id: batchCustomerId,
            offer_status: "accepted",
            address_text: selectedAddress.address_text,
            entrance: selectedAddress.entrance || "",
            comment: selectedAddress.comment || "",
            preferred_time_from: preferredWindow.fromText || "",
            preferred_time_to: preferredWindow.toText || "",
            responded_by: "admin_manual_add",
          }),
        ],
      );

      await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
        chat.id,
      ]);

      await rerouteAcceptedCustomers(client, batchId);
      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io && ensured.created) {
        io.to(`user:${user.user_id}`).emit("chat:created", { chat });
      }
      if (io) {
        const followUpMessage = await hydrateSystemMessage(
          db,
          followUpInsert.rows[0].id,
        );
        if (followUpMessage) {
          io.to(`user:${user.user_id}`).emit("chat:message", {
            chatId: chat.id,
            message: followUpMessage,
          });
        }
        emitCartUpdated(io, user.user_id, {
          status:
            batchStatus === "couriers_assigned"
              ? "handing_to_courier"
              : "preparing_delivery",
          reason: "delivery_manual_add",
        });
        emitDeliveryUpdated(io, batchId, req.user?.tenant_id || null);
      }

      const activeBatch = await fetchBatchDetails(
        db,
        batchId,
        req.user?.tenant_id || null,
      );
      return res.status(201).json({ ok: true, data: { active_batch: activeBatch } });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.customer.manualAdd error", err);
      if (
        respondAddressProviderError(
          res,
          err,
          "Не удалось проверить адрес перед добавлением в лист доставки. Попробуйте чуть позже.",
        )
      ) {
        return;
      }
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/batches/:batchId/assign-couriers",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const { batchId } = req.params;
    const courierNames = Array.isArray(req.body?.courier_names)
      ? req.body.courier_names
          .map((item) => String(item || "").trim())
          .filter(Boolean)
      : [];
    if (courierNames.length === 0) {
      return res
        .status(400)
        .json({ ok: false, error: "Нужно указать хотя бы одного курьера" });
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const batchQ = await client.query(
        `SELECT b.id, b.status
         FROM delivery_batches b
         WHERE b.id = $1
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users bu
               WHERE bu.id = b.created_by
                 AND bu.tenant_id = $2::uuid
             )
             OR EXISTS (
               SELECT 1
               FROM delivery_batch_customers c2
               JOIN users u2 ON u2.id = c2.user_id
               WHERE c2.batch_id = b.id
                 AND u2.tenant_id = $2::uuid
             )
           )
         LIMIT 1
         FOR UPDATE`,
        [batchId, req.user?.tenant_id || null],
      );
      if (batchQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Лист доставки не найден" });
      }
      const batchStatus = String(batchQ.rows[0].status || "");
      if (!["calling", "couriers_assigned"].includes(batchStatus)) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error:
            batchStatus === "handed_off"
              ? "Этот лист уже передан курьерам. Отправьте новую рассылку."
              : "Распределять по курьерам можно только текущий активный лист доставки",
        });
      }

      const customersQ = await client.query(
        `SELECT *
         FROM delivery_batch_customers
         WHERE batch_id = $1
           AND call_status = 'accepted'
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users u
               WHERE u.id = delivery_batch_customers.user_id
                 AND u.tenant_id = $2::uuid
             )
           )
         ORDER BY customer_name ASC`,
        [batchId, req.user?.tenant_id || null],
      );
      if (customersQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "В листе нет подтвержденных клиентов для распределения по курьерам",
        });
      }
      const notAssembledQ = await client.query(
        `SELECT COUNT(*)::int AS total
         FROM delivery_batch_customers
         WHERE batch_id = $1
           AND call_status = 'accepted'
           AND COALESCE(assembly_status, 'not_started') <> 'assembled'
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users u
               WHERE u.id = delivery_batch_customers.user_id
                 AND u.tenant_id = $2::uuid
             )
           )`,
        [batchId, req.user?.tenant_id || null],
      );
      if ((Number(notAssembledQ.rows[0]?.total) || 0) > 0) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Сначала соберите все подтвержденные корзины",
        });
      }

      await client.query(
        `UPDATE delivery_batches
         SET courier_count = $1,
             courier_names = $2::jsonb,
             assembled_by_id = $4,
             assembled_at = now(),
             status = 'couriers_assigned',
             updated_at = now()
         WHERE id = $3`,
        [courierNames.length, JSON.stringify(courierNames), batchId, req.user.id],
      );

      await rerouteAcceptedCustomers(client, batchId);

      await client.query("COMMIT");

      const detail = await fetchBatchDetails(
        db,
        batchId,
        req.user?.tenant_id || null,
      );
      const io = req.app.get("io");
      if (io && detail) {
        for (const customer of detail.customers) {
          if (customer.self_pickup === true || customer.route_excluded === true) continue;
          emitCartUpdated(io, customer.user_id, {
            status: "handing_to_courier",
            reason: "couriers_assigned",
          });
        }
        emitDeliveryUpdated(io, batchId, req.user?.tenant_id || null);
      }

      return res.json({ ok: true, data: { active_batch: detail } });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.assignCouriers error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/batches/:batchId/confirm-handoff",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const { batchId } = req.params;
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const batchQ = await client.query(
        `SELECT b.id, b.status
         FROM delivery_batches b
         WHERE b.id = $1
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users bu
               WHERE bu.id = b.created_by
                 AND bu.tenant_id = $2::uuid
             )
             OR EXISTS (
               SELECT 1
               FROM delivery_batch_customers c2
               JOIN users u2 ON u2.id = c2.user_id
               WHERE c2.batch_id = b.id
                 AND u2.tenant_id = $2::uuid
             )
           )
         LIMIT 1
         FOR UPDATE`,
        [batchId, req.user?.tenant_id || null],
      );
      if (batchQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Лист доставки не найден" });
      }

      const batchStatus = String(batchQ.rows[0].status || "");
      if (batchStatus === "completed") {
        await client.query("ROLLBACK");
        return res.status(400).json({ ok: false, error: "Этот лист уже завершен" });
      }

      const readinessQ = await client.query(
        `SELECT
           COUNT(*) FILTER (
             WHERE call_status = 'accepted'
           )::int AS accepted_total,
           COUNT(*) FILTER (
             WHERE call_status = 'accepted'
               AND COALESCE(self_pickup, false) = false
               AND COALESCE(route_excluded, false) = false
           )::int AS route_total,
           COUNT(*) FILTER (
             WHERE call_status = 'accepted'
               AND COALESCE(assembly_status, 'not_started') <> 'assembled'
           )::int AS not_assembled_total,
           COUNT(*) FILTER (
             WHERE call_status = 'accepted'
               AND COALESCE(self_pickup, false) = false
               AND COALESCE(route_excluded, false) = false
               AND courier_name IS NOT NULL
               AND courier_name <> ''
               AND COALESCE(assembly_status, 'not_started') = 'assembled'
           )::int AS route_ready_total,
           COUNT(*) FILTER (
             WHERE call_status = 'accepted'
               AND COALESCE(self_pickup, false) = false
               AND COALESCE(route_excluded, false) = false
               AND COALESCE(assembly_status, 'not_started') = 'assembled'
               AND (courier_name IS NULL OR courier_name = '')
           )::int AS route_unassigned_total
         FROM delivery_batch_customers
         WHERE batch_id = $1
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users u
               WHERE u.id = delivery_batch_customers.user_id
                 AND u.tenant_id = $2::uuid
             )
           )`,
        [batchId, req.user?.tenant_id || null],
      );
      const readiness = readinessQ.rows[0] || {};
      const acceptedTotal = Number(readiness.accepted_total || 0);
      const routeTotal = Number(readiness.route_total || 0);
      const notAssembledTotal = Number(readiness.not_assembled_total || 0);
      const routeReadyTotal = Number(readiness.route_ready_total || 0);
      const routeUnassignedTotal = Number(readiness.route_unassigned_total || 0);

      if (acceptedTotal <= 0) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "В листе нет подтвержденных клиентов для передачи",
        });
      }

      if (notAssembledTotal > 0) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Передать курьерам можно только собранные корзины",
        });
      }

      if (routeTotal === 0) {
        const usersQ = await client.query(
          `SELECT DISTINCT c.user_id::text AS user_id
           FROM delivery_batch_customers c
           WHERE c.batch_id = $1
             AND c.call_status = 'accepted'
             AND (
               COALESCE(c.self_pickup, false) = true
               OR COALESCE(c.route_excluded, false) = true
             )
             AND COALESCE(c.assembly_status, 'not_started') = 'assembled'
             AND (
               $2::uuid IS NULL
               OR EXISTS (
                 SELECT 1
                 FROM users u
                 WHERE u.id = c.user_id
                   AND u.tenant_id = $2::uuid
               )
             )`,
          [batchId, req.user?.tenant_id || null],
        );

        await client.query(
          `UPDATE delivery_batch_customers
           SET delivery_status = 'completed',
               updated_at = now()
           WHERE batch_id = $1
             AND call_status = 'accepted'
             AND (
               COALESCE(self_pickup, false) = true
               OR COALESCE(route_excluded, false) = true
             )
             AND COALESCE(assembly_status, 'not_started') = 'assembled'
             AND (
               $2::uuid IS NULL
               OR EXISTS (
                 SELECT 1
                 FROM users u
                 WHERE u.id = delivery_batch_customers.user_id
                   AND u.tenant_id = $2::uuid
               )
             )`,
          [batchId, req.user?.tenant_id || null],
        );

        await client.query(
          `UPDATE cart_items
           SET status = 'delivered',
               updated_at = now()
           WHERE id IN (
             SELECT i.cart_item_id
             FROM delivery_batch_items i
             JOIN delivery_batch_customers c ON c.id = i.batch_customer_id
             WHERE i.batch_id = $1
               AND c.call_status = 'accepted'
               AND (
                 COALESCE(c.self_pickup, false) = true
                 OR COALESCE(c.route_excluded, false) = true
               )
               AND COALESCE(c.assembly_status, 'not_started') = 'assembled'
               AND (
                 $2::uuid IS NULL
                 OR EXISTS (
                   SELECT 1
                   FROM users u
                   WHERE u.id = c.user_id
                     AND u.tenant_id = $2::uuid
                 )
               )
           )`,
          [batchId, req.user?.tenant_id || null],
        );

        await client.query(
          `UPDATE delivery_batches
           SET status = 'completed',
               completed_at = COALESCE(completed_at, now()),
               updated_at = now()
           WHERE id = $1`,
          [batchId],
        );

        await client.query("COMMIT");

        const detail = await fetchBatchDetails(
          db,
          batchId,
          req.user?.tenant_id || null,
        );
        const io = req.app.get("io");
        if (io) {
          for (const row of usersQ.rows) {
            emitCartUpdated(io, row.user_id, {
              status: "delivered",
              reason: "self_pickup_completed",
              batch_id: batchId,
            });
          }
          emitDeliveryUpdated(io, batchId, req.user?.tenant_id || null);
        }

        return res.json({
          ok: true,
          data: { active_batch: detail, batch_id: batchId, self_pickup_completed: true },
        });
      }

      if (routeReadyTotal <= 0 || routeUnassignedTotal > 0) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Сначала распределите подтвержденных клиентов по курьерам",
        });
      }

      await client.query(
        `UPDATE delivery_batch_customers
         SET delivery_status = 'in_delivery',
             updated_at = now()
         WHERE batch_id = $1
           AND call_status = 'accepted'
           AND COALESCE(self_pickup, false) = false
           AND COALESCE(route_excluded, false) = false
           AND courier_name IS NOT NULL
           AND courier_name <> ''
           AND COALESCE(assembly_status, 'not_started') = 'assembled'
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users u
               WHERE u.id = delivery_batch_customers.user_id
                 AND u.tenant_id = $2::uuid
             )
           )`,
        [batchId, req.user?.tenant_id || null],
      );

      await client.query(
        `UPDATE cart_items
         SET status = 'in_delivery',
             updated_at = now()
         WHERE id IN (
           SELECT i.cart_item_id
           FROM delivery_batch_items i
           JOIN delivery_batch_customers c ON c.id = i.batch_customer_id
           WHERE i.batch_id = $1
             AND c.call_status = 'accepted'
             AND COALESCE(c.self_pickup, false) = false
             AND COALESCE(c.route_excluded, false) = false
             AND c.courier_name IS NOT NULL
             AND c.courier_name <> ''
             AND COALESCE(c.assembly_status, 'not_started') = 'assembled'
             AND (
               $2::uuid IS NULL
               OR EXISTS (
                 SELECT 1
                 FROM users u
                 WHERE u.id = c.user_id
                   AND u.tenant_id = $2::uuid
               )
             )
        )`,
        [batchId, req.user?.tenant_id || null],
      );

      await client.query(
        `DELETE FROM user_shelves
         WHERE user_id IN (
           SELECT DISTINCT c.user_id
           FROM delivery_batch_customers c
           WHERE c.batch_id = $1
             AND c.call_status = 'accepted'
             AND COALESCE(c.self_pickup, false) = false
             AND COALESCE(c.route_excluded, false) = false
             AND c.courier_name IS NOT NULL
             AND c.courier_name <> ''
             AND COALESCE(c.assembly_status, 'not_started') = 'assembled'
             AND (
               $2::uuid IS NULL
               OR EXISTS (
                 SELECT 1
                 FROM users u
                 WHERE u.id = c.user_id
                   AND u.tenant_id = $2::uuid
               )
             )
         )`,
        [batchId, req.user?.tenant_id || null],
      );

      await client.query(
        `UPDATE delivery_batches
         SET status = 'handed_off',
             handed_off_at = now(),
             updated_at = now()
         WHERE id = $1`,
        [batchId],
      );

      await client.query(
        `UPDATE products
         SET reusable_at = now(),
             updated_at = now()
         WHERE status = 'archived'
           AND id IN (
             SELECT DISTINCT i.product_id
             FROM delivery_batch_items i
             JOIN delivery_batch_customers c ON c.id = i.batch_customer_id
             WHERE i.batch_id = $1
               AND c.call_status = 'accepted'
               AND COALESCE(c.self_pickup, false) = false
               AND COALESCE(c.route_excluded, false) = false
               AND c.courier_name IS NOT NULL
               AND c.courier_name <> ''
               AND COALESCE(c.assembly_status, 'not_started') = 'assembled'
           )`,
        [batchId],
      );

      await client.query("COMMIT");

      const detail = await fetchBatchDetails(
        db,
        batchId,
        req.user?.tenant_id || null,
      );
      const io = req.app.get("io");
      if (io && detail) {
        for (const customer of detail.customers) {
          if (customer.call_status !== "accepted") continue;
          if (customer.self_pickup === true || customer.route_excluded === true) continue;
          emitCartUpdated(io, customer.user_id, {
            status: "in_delivery",
            reason: "delivery_handed_off",
            eta_from: customer.eta_from,
            eta_to: customer.eta_to,
            courier_name: customer.courier_name,
            courier_code: customer.courier_code,
            delivery_date: detail.delivery_date,
          });
        }
        emitDeliveryUpdated(io, batchId, req.user?.tenant_id || null);
      }

      return res.json({ ok: true, data: { active_batch: detail } });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.confirmHandoff error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/batches/:batchId/complete",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const { batchId } = req.params;
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const batchQ = await client.query(
        `SELECT b.id, b.status
         FROM delivery_batches b
         WHERE b.id = $1
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users bu
               WHERE bu.id = b.created_by
                 AND bu.tenant_id = $2::uuid
             )
             OR EXISTS (
               SELECT 1
               FROM delivery_batch_customers c2
               JOIN users u2 ON u2.id = c2.user_id
               WHERE c2.batch_id = b.id
                 AND u2.tenant_id = $2::uuid
             )
           )
         LIMIT 1
         FOR UPDATE`,
        [batchId, req.user?.tenant_id || null],
      );
      if (batchQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Лист доставки не найден" });
      }
      const batchStatus = String(batchQ.rows[0].status || "");
      const completionReadinessQ = await client.query(
        `SELECT
           COUNT(*) FILTER (
             WHERE call_status = 'accepted'
           )::int AS accepted_total,
           COUNT(*) FILTER (
             WHERE call_status = 'accepted'
               AND COALESCE(route_excluded, false) = false
               AND COALESCE(self_pickup, false) = false
           )::int AS route_total,
           COUNT(*) FILTER (
             WHERE call_status = 'accepted'
               AND COALESCE(assembly_status, 'not_started') <> 'assembled'
           )::int AS not_assembled_total
         FROM delivery_batch_customers
         WHERE batch_id = $1`,
        [batchId],
      );
      const readiness = completionReadinessQ.rows[0] || {};
      const routeTotal = Number(readiness.route_total || 0);
      const acceptedTotal = Number(readiness.accepted_total || 0);
      const notAssembledTotal = Number(readiness.not_assembled_total || 0);
      const selfPickupOnlyCompletion =
        routeTotal === 0 &&
        acceptedTotal > 0 &&
        notAssembledTotal === 0 &&
        ["calling", "couriers_assigned"].includes(batchStatus);
      if (batchStatus !== "handed_off" && !selfPickupOnlyCompletion) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error:
            batchStatus === "completed"
              ? "Этот лист уже завершен"
              : "Завершить можно только лист, который уже передан курьерам, или полностью собранный самовывоз",
        });
      }

      const usersQ = await client.query(
        `SELECT DISTINCT c.user_id::text AS user_id
         FROM delivery_batch_customers c
         WHERE c.batch_id = $1
           AND c.call_status = 'accepted'
           AND (
             (c.courier_name IS NOT NULL AND c.courier_name <> '')
             OR COALESCE(c.self_pickup, false) = true
             OR COALESCE(c.route_excluded, false) = true
           )
           AND COALESCE(c.assembly_status, 'not_started') = 'assembled'
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users u
               WHERE u.id = c.user_id
                 AND u.tenant_id = $2::uuid
             )
           )`,
        [batchId, req.user?.tenant_id || null],
      );

      await client.query(
        `UPDATE delivery_batch_customers
         SET delivery_status = 'completed',
             updated_at = now()
         WHERE batch_id = $1
           AND call_status = 'accepted'
           AND (
             (courier_name IS NOT NULL AND courier_name <> '')
             OR COALESCE(self_pickup, false) = true
             OR COALESCE(route_excluded, false) = true
           )
           AND COALESCE(assembly_status, 'not_started') = 'assembled'
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users u
               WHERE u.id = delivery_batch_customers.user_id
                 AND u.tenant_id = $2::uuid
             )
           )`,
        [batchId, req.user?.tenant_id || null],
      );

      await client.query(
        `UPDATE cart_items
         SET status = 'delivered',
             updated_at = now()
         WHERE id IN (
           SELECT i.cart_item_id
           FROM delivery_batch_items i
           JOIN delivery_batch_customers c ON c.id = i.batch_customer_id
           WHERE i.batch_id = $1
             AND c.call_status = 'accepted'
             AND (
               (c.courier_name IS NOT NULL AND c.courier_name <> '')
               OR COALESCE(c.self_pickup, false) = true
               OR COALESCE(c.route_excluded, false) = true
             )
             AND COALESCE(c.assembly_status, 'not_started') = 'assembled'
             AND (
               $2::uuid IS NULL
               OR EXISTS (
                 SELECT 1
                 FROM users u
                 WHERE u.id = c.user_id
                   AND u.tenant_id = $2::uuid
               )
             )
         )`,
        [batchId, req.user?.tenant_id || null],
      );

      await client.query(
        `UPDATE delivery_batches
         SET status = 'completed',
             completed_at = COALESCE(completed_at, now()),
             updated_at = now()
         WHERE id = $1`,
        [batchId],
      );

      await client.query("COMMIT");

      const detail = await fetchBatchDetails(
        db,
        batchId,
        req.user?.tenant_id || null,
      );
      const io = req.app.get("io");
      if (io) {
        for (const row of usersQ.rows) {
          emitCartUpdated(io, row.user_id, {
            status: "delivered",
            reason: "delivery_completed",
            batch_id: batchId,
          });
        }
        emitDeliveryUpdated(io, batchId, req.user?.tenant_id || null);
      }

      return res.json({ ok: true, data: { active_batch: detail, batch_id: batchId } });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.complete error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/batches/:batchId/customers/:customerId/remove-from-route",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const { batchId, customerId } = req.params;
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const customerQ = await client.query(
        `SELECT c.*,
                b.status AS batch_status
         FROM delivery_batch_customers c
         JOIN delivery_batches b ON b.id = c.batch_id
         JOIN users scope_u ON scope_u.id = c.user_id
         WHERE c.id = $1
           AND c.batch_id = $2
           AND ($3::uuid IS NULL OR scope_u.tenant_id = $3::uuid)
         LIMIT 1
         FOR UPDATE`,
        [customerId, batchId, req.user?.tenant_id || null],
      );
      if (customerQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Клиент в листе доставки не найден" });
      }

      const customer = customerQ.rows[0];
      const batchStatus = String(customer.batch_status || "");
      if (!["calling", "couriers_assigned", "handed_off"].includes(batchStatus)) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Из этого листа уже нельзя вернуть клиента в корзину",
        });
      }

      if (String(customer.call_status || "") !== "accepted") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Вернуть в корзину можно только клиента с подтвержденной доставкой",
        });
      }

      await client.query(
        `UPDATE delivery_batch_customers
         SET call_status = 'removed',
             delivery_status = 'returned_to_cart',
             courier_slot = NULL,
             courier_name = NULL,
             courier_code = NULL,
             route_order = NULL,
             eta_from = NULL,
             eta_to = NULL,
             locked_courier_slot = NULL,
             locked_courier_name = NULL,
             locked_courier_code = NULL,
             updated_at = now()
         WHERE id = $1`,
        [customerId],
      );

      await client.query(
        `UPDATE cart_items
         SET status = 'processed',
             updated_at = now()
         WHERE id IN (
           SELECT cart_item_id
           FROM delivery_batch_items
           WHERE batch_customer_id = $1
         )`,
        [customerId],
      );

      await upsertUserShelf(client, customer.user_id, customer.shelf_number);

      if (batchStatus === "couriers_assigned") {
        await rerouteAcceptedCustomers(client, batchId);
      }

      await client.query(
        `UPDATE delivery_batches
         SET updated_at = now()
         WHERE id = $1`,
        [batchId],
      );
      await maybeCloseDeliveryBatchWithoutWork(
        client,
        batchId,
        req.user?.tenant_id || null,
      );

      await client.query("COMMIT");

      const detail = await fetchBatchDetails(
        db,
        batchId,
        req.user?.tenant_id || null,
      );
      const io = req.app.get("io");
      if (io) {
        emitCartUpdated(io, customer.user_id, {
          status: "processed",
          reason: "delivery_removed_from_route",
          batch_id: batchId,
        });
        emitDeliveryUpdated(io, batchId, req.user?.tenant_id || null);
      }

      return res.json({
        ok: true,
        data: {
          customer_id: customerId,
          active_batch: detail,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.removeFromRoute error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/batches/:batchId/customers/:customerId/return-to-route",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const { batchId, customerId } = req.params;
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const customerQ = await client.query(
        `SELECT c.*,
                b.status AS batch_status
         FROM delivery_batch_customers c
         JOIN delivery_batches b ON b.id = c.batch_id
         JOIN users scope_u ON scope_u.id = c.user_id
         WHERE c.id = $1
           AND c.batch_id = $2
           AND ($3::uuid IS NULL OR scope_u.tenant_id = $3::uuid)
         LIMIT 1
         FOR UPDATE`,
        [customerId, batchId, req.user?.tenant_id || null],
      );
      if (customerQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Клиент в листе доставки не найден" });
      }

      const customer = customerQ.rows[0];
      const batchStatus = String(customer.batch_status || "");
      if (!["calling", "couriers_assigned", "handed_off", "cancelled"].includes(batchStatus)) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "В этот лист уже нельзя вернуть клиента на маршрут",
        });
      }

      if (String(customer.call_status || "") !== "declined") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Вернуть на маршрут можно только клиента со статусом отказа",
        });
      }

      const itemsQ = await client.query(
        `SELECT COUNT(*)::int AS total
         FROM delivery_batch_items
         WHERE batch_customer_id = $1
           AND COALESCE(assembly_status, 'pending') <> 'removed'`,
        [customerId],
      );
      if ((Number(itemsQ.rows[0]?.total) || 0) < 1) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "У клиента нет товаров, которые можно вернуть на маршрут",
        });
      }

      await client.query(
        `UPDATE delivery_batch_customers
         SET call_status = 'accepted',
             delivery_status = 'preparing_delivery',
             accepted_at = now(),
             agreed_sum = processed_sum,
             assembly_status = 'not_started',
             assembly_started_at = NULL,
             assembly_started_by = NULL,
             assembly_completed_at = NULL,
             assembly_completed_by = NULL,
             assembly_note = NULL,
             normal_stickers_requested = 0,
             bulky_stickers_requested = 0,
             courier_slot = NULL,
             courier_name = NULL,
             courier_code = NULL,
             route_order = NULL,
             eta_from = NULL,
             eta_to = NULL,
             updated_at = now()
         WHERE id = $1`,
        [customerId],
      );

      await client.query(
        `UPDATE delivery_batch_items
         SET assembly_status = 'pending',
             removed_reason = NULL,
             removed_at = NULL,
             removed_by = NULL
         WHERE batch_customer_id = $1
           AND COALESCE(assembly_status, 'pending') <> 'removed'`,
        [customerId],
      );

      await client.query(
        `UPDATE cart_items
         SET status = 'preparing_delivery',
             updated_at = now()
         WHERE id IN (
           SELECT cart_item_id
           FROM delivery_batch_items
           WHERE batch_customer_id = $1
             AND COALESCE(assembly_status, 'pending') <> 'removed'
         )`,
        [customerId],
      );

      await client.query(
        `UPDATE delivery_batches
         SET status = CASE WHEN status = 'cancelled' THEN 'calling' ELSE status END,
             updated_at = now()
         WHERE id = $1`,
        [batchId],
      );

      if (batchStatus === "couriers_assigned") {
        await rerouteAcceptedCustomers(client, batchId);
      }

      await client.query("COMMIT");

      const detail = await fetchBatchDetails(
        db,
        batchId,
        req.user?.tenant_id || null,
      );
      const io = req.app.get("io");
      if (io) {
        emitCartUpdated(io, customer.user_id, {
          status: "preparing_delivery",
          reason: "delivery_returned_to_route",
          batch_id: batchId,
        });
        emitDeliveryUpdated(io, batchId, req.user?.tenant_id || null);
      }

      return res.json({
        ok: true,
        data: {
          customer_id: customerId,
          status: "accepted",
          active_batch: detail,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK").catch(() => {});
      console.error("delivery.returnToRoute error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.get(
  "/archive",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    try {
      const deliveryDate = ensureIsoDate(req.query.date || new Date());
      const typeRaw = String(req.query.type || "all").trim().toLowerCase();
      const archiveType = ["delivery", "self_pickup", "all"].includes(typeRaw)
        ? typeRaw
        : "all";
      const tenantId = req.user?.tenant_id || null;

      const typePredicate =
        archiveType === "self_pickup"
          ? "AND COALESCE(c.self_pickup, false) = true"
          : archiveType === "delivery"
            ? "AND COALESCE(c.self_pickup, false) = false"
            : "";

      const batchesQ = await db.query(
        `SELECT DISTINCT b.id
         FROM delivery_batches b
         JOIN delivery_batch_customers c ON c.batch_id = b.id
         JOIN users u ON u.id = c.user_id
         WHERE b.delivery_date::date = $1::date
           AND c.call_status = 'accepted'
           AND (
             $2::uuid IS NULL
             OR u.tenant_id = $2::uuid
           )
           ${typePredicate}
         ORDER BY b.id ASC
         LIMIT 50`,
        [deliveryDate, tenantId],
      );

      const batches = [];
      for (const row of batchesQ.rows) {
        const detail = await fetchBatchDetails(db, row.id, tenantId);
        if (!detail) continue;
        const customers = (Array.isArray(detail.customers) ? detail.customers : [])
          .filter((customer) => {
            if (String(customer.call_status || "") !== "accepted") return false;
            if (archiveType === "self_pickup") {
              return customer.self_pickup === true;
            }
            if (archiveType === "delivery") {
              return customer.self_pickup !== true;
            }
            return true;
          });
        if (customers.length === 0) continue;
        batches.push({
          ...detail,
          customers,
        });
      }

      return res.json({
        ok: true,
        data: {
          date: deliveryDate,
          type: archiveType,
          batches,
        },
      });
    } catch (err) {
      const message = String(err?.message || "");
      if (message.includes("Некорректная дата")) {
        return res.status(400).json({ ok: false, error: message });
      }
      console.error("delivery.archive error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.get(
  "/batches/:batchId/export",
  requireAuth,
  requireRole("admin", "tenant", "creator"),
  requireDeliveryManagePermission,
  async (req, res) => {
    const { batchId } = req.params;
    try {
      const batchQ = await db.query(
        `SELECT b.id, b.delivery_date
         FROM delivery_batches b
         WHERE b.id = $1
           AND (
             $2::uuid IS NULL
             OR EXISTS (
               SELECT 1
               FROM users bu
               WHERE bu.id = b.created_by
                 AND bu.tenant_id = $2::uuid
             )
             OR EXISTS (
               SELECT 1
               FROM delivery_batch_customers c2
               JOIN users u2 ON u2.id = c2.user_id
               WHERE c2.batch_id = b.id
                 AND u2.tenant_id = $2::uuid
             )
           )
         LIMIT 1`,
        [batchId, req.user?.tenant_id || null],
      );
      if (batchQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Лист доставки не найден" });
      }
      const rowsQ = await db.query(
        `SELECT customer_phone,
                customer_name,
                agreed_sum,
                processed_sum,
                COALESCE(NULLIF(BTRIM(delivery_batch_customers.client_city), ''), NULLIF(BTRIM(u.client_city), ''), '') AS client_city,
                address_text,
                address_ciphertext,
                address_iv,
                address_tag,
                courier_code,
                bulky_note,
                (
                  SELECT COUNT(*)::int
                  FROM delivery_batch_items dbi
                  WHERE dbi.batch_customer_id = delivery_batch_customers.id
                    AND dbi.assembly_status <> 'removed'
                    AND dbi.is_bulky = true
                ) AS bulky_places,
                shelf_number,
                package_places,
                preferred_time_from,
                preferred_time_to,
                route_order
         FROM delivery_batch_customers
         JOIN users u ON u.id = delivery_batch_customers.user_id
         WHERE batch_id = $1
           AND call_status = 'accepted'
           AND (
             $2::uuid IS NULL
             OR u.tenant_id = $2::uuid
           )
         ORDER BY route_order ASC NULLS LAST, customer_name ASC`,
        [batchId, req.user?.tenant_id || null],
      );

      const workbook = new ExcelJS.Workbook();
      const worksheet = workbook.addWorksheet("Доставка");
      worksheet.columns = [
        { header: "Маршрут", key: "route_order", width: 12 },
        { header: "Телефон клиента", key: "customer_phone", width: 20 },
        { header: "Имя клиента", key: "customer_name", width: 24 },
        { header: "Сумма в доставке", key: "delivery_sum", width: 18 },
        { header: "Адрес клиента", key: "address_text", width: 52 },
        { header: "Курьер", key: "courier_code", width: 12 },
        { header: "НП", key: "city_letter", width: 8 },
        { header: "Габарит", key: "bulky_note", width: 26 },
        { header: "Габаритов", key: "bulky_places", width: 12 },
        { header: "Номер полки", key: "shelf_number", width: 14 },
        { header: "Сколько мест", key: "package_places", width: 14 },
      ];
      worksheet.getRow(1).font = { bold: true };
      worksheet.views = [{ state: "frozen", ySplit: 1 }];

      if (rowsQ.rows.length === 0) {
        worksheet.addRow({
          route_order: "",
          customer_phone: "",
          customer_name: "",
          delivery_sum: "",
          address_text: "",
          courier_code: "",
          city_letter: "",
          bulky_note: "",
          bulky_places: "",
          shelf_number: "",
          package_places: "",
        });
      } else {
        for (const customer of rowsQ.rows) {
          const row = worksheet.addRow({
            route_order:
              customer.route_order == null ? "" : Number(customer.route_order),
            customer_phone: String(customer.customer_phone || "").trim(),
            customer_name: String(customer.customer_name || "").trim(),
            delivery_sum: toMoney(customer.agreed_sum || customer.processed_sum),
            address_text: "",
            courier_code: String(customer.courier_code || "").trim(),
            city_letter: normalizeCityName(customer.client_city).slice(0, 1).toUpperCase(),
            bulky_note: String(customer.bulky_note || "").trim(),
            bulky_places: Number(customer.bulky_places || 0),
            shelf_number:
              customer.shelf_number == null ? "" : Number(customer.shelf_number),
            package_places:
              customer.package_places == null ? 1 : Number(customer.package_places),
          });
          const addressCell = row.getCell("address_text");
          const addressText = decodeAddressFromRow(customer);
          const preferenceLabel = formatDeliveryPreferenceLabel(
            customer.preferred_time_from,
            customer.preferred_time_to,
          );
          if (preferenceLabel) {
            const richText = [];
            if (addressText) {
              richText.push({ text: addressText });
              richText.push({ text: " " });
            }
            richText.push({ text: preferenceLabel, font: { bold: true } });
            addressCell.value = { richText };
          } else {
            addressCell.value = addressText;
          }
        }
      }

      worksheet.eachRow((row, rowNumber) => {
        row.alignment = {
          vertical: "top",
          wrapText: true,
        };
        if (rowNumber > 1) {
          row.getCell("delivery_sum").numFmt = "0.00";
        }
      });

      const buffer = await workbook.xlsx.writeBuffer();
      const filename = `delivery_${String(batchQ.rows[0].delivery_date || "sheet").slice(0, 10)}.xlsx`;

      res.setHeader(
        "Content-Type",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      );
      res.setHeader("Content-Disposition", `attachment; filename="${filename}"`);
      return res.send(buffer);
    } catch (err) {
      console.error("delivery.export error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.startBackgroundTasks = startDeliveryDialogCleanup;

module.exports = router;
