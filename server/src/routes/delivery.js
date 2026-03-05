const express = require("express");
const { v4: uuidv4 } = require("uuid");
const ExcelJS = require("exceljs");

const router = express.Router();
const requireAuth = require("../middleware/requireAuth");
const requireRole = require("../middleware/requireRole");
const db = require("../db");
const {
  readEncryptedText,
  writeEncryptedTextParams,
} = require("../utils/secureData");

const SAMARA_CENTER = { lat: 53.195878, lng: 50.100202 };
const DELIVERY_DAY_START_MINUTES = 10 * 60;
const DELIVERY_SOFT_END_MINUTES = 16 * 60;
const DELIVERY_HARD_END_MINUTES = 19 * 60;
const DELIVERY_STOP_SERVICE_MINUTES = 12;
const DELIVERY_STOP_BUFFER_MINUTES = 8;
const DELIVERY_DIALOG_AUTO_DELETE_MS = 60 * 1000;
const DELIVERY_DIALOG_CLEANUP_INTERVAL_MS = 15 * 1000;
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

function normalizeJsonObject(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw;
}

async function getDeliverySettings(queryable = db) {
  const result = await queryable.query(
    `SELECT value
     FROM system_settings
     WHERE key = 'delivery'
     LIMIT 1`,
  );
  const value = normalizeJsonObject(result.rows[0]?.value);
  return {
    threshold_amount: Math.max(0, toMoney(value.threshold_amount, 1500)),
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
  };
}

async function saveDeliverySettings(queryable, settings, userId) {
  await queryable.query(
    `INSERT INTO system_settings (key, value, updated_at, updated_by)
     VALUES ('delivery', $1::jsonb, now(), $2)
     ON CONFLICT (key) DO UPDATE
       SET value = EXCLUDED.value,
           updated_at = now(),
           updated_by = EXCLUDED.updated_by`,
    [JSON.stringify(settings), userId || null],
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
    lat: normalized.lat ?? SAMARA_CENTER.lat,
    lng: normalized.lng ?? SAMARA_CENTER.lng,
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
  if (!value) return "Самара";
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
  if (!normalized) return "Самара";
  const firstChunk = normalized.split(",")[0]?.trim() || "";
  return normalizeLocalityName(firstChunk || "Самара");
}

function buildGeocodeQuery(addressText) {
  const normalized = stripAddressServiceParts(addressText);
  const locality = detectAddressLocality(normalized);
  const hasLocalityInText = normalized
    .toLowerCase()
    .includes(locality.toLowerCase());
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
  const baseAddress = `${addressCore}, ${locality}`;
  return {
    locality,
    query: `${baseAddress}, Самарская область, Россия`,
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
  const cleaned = stripAddressServiceParts(originalNormalized);
  const { locality, query } = buildGeocodeQuery(cleaned);
  const queryVariants = [
    query,
    `${cleaned}, ${locality}, Самарская область, Россия`,
    `${cleaned}, ${locality}, Россия`,
  ].filter(Boolean);

  let chosen = null;
  for (const variant of queryVariants) {
    const params = new URLSearchParams({
      q: variant,
      format: "jsonv2",
      addressdetails: "1",
      limit: "5",
      countrycodes: "ru",
      "accept-language": "ru",
    });
    if (GEOCODER_API_KEY) {
      params.set("apikey", GEOCODER_API_KEY);
    }
    const headers = {
      Accept: "application/json",
    };
    if (GEOCODER_USER_AGENT) {
      headers["User-Agent"] = GEOCODER_USER_AGENT;
    }
    if (GEOCODER_AUTH_HEADER) {
      headers.Authorization = GEOCODER_AUTH_HEADER;
    }
    const response = await fetch(
      `${GEOCODER_SEARCH_URL}?${params.toString()}`,
      { headers },
    );
    if (!response.ok) {
      throw new Error(`Геокодер недоступен: ${response.status}`);
    }
    const payload = await response.json();
    if (!Array.isArray(payload) || payload.length === 0) {
      continue;
    }
    const exactCity = payload.find((item) => {
      const foundLocality = extractGeocodeLocality(item);
      return foundLocality.toLowerCase() === locality.toLowerCase();
    });
    chosen = exactCity || payload[0];
    if (chosen) break;
  }

  if (!chosen) {
    return null;
  }
  const lat = Number(chosen.lat);
  const lng = Number(chosen.lon);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return null;
  }
  const foundLocality = extractGeocodeLocality(chosen);
  if (locality && foundLocality && foundLocality.toLowerCase() !== locality.toLowerCase()) {
    return null;
  }
  return {
    address_text: originalNormalized,
    locality,
    lat,
    lng,
    resolved_label: chosen.display_name || "",
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

async function fetchBatchSummaries(queryable) {
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
            COUNT(c.id)::int AS customers_total,
            COUNT(*) FILTER (WHERE c.call_status = 'accepted')::int AS accepted_total,
            COUNT(*) FILTER (WHERE c.call_status = 'declined')::int AS declined_total,
            COUNT(*) FILTER (WHERE c.courier_name IS NOT NULL AND c.courier_name <> '')::int AS assigned_total
     FROM delivery_batches b
     LEFT JOIN delivery_batch_customers c ON c.batch_id = b.id
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
  );
  return result.rows.map(mapBatchRow);
}

async function fetchBatchDetails(queryable, batchId) {
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
            COUNT(c.id)::int AS customers_total,
            COUNT(*) FILTER (WHERE c.call_status = 'accepted')::int AS accepted_total,
            COUNT(*) FILTER (WHERE c.call_status = 'declined')::int AS declined_total,
            COUNT(*) FILTER (WHERE c.courier_name IS NOT NULL AND c.courier_name <> '')::int AS assigned_total
     FROM delivery_batches b
     LEFT JOIN delivery_batch_customers c ON c.batch_id = b.id
     WHERE b.id = $1
     GROUP BY b.id
     LIMIT 1`,
    [batchId],
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
                    'quantity', i.quantity,
                    'unit_price', i.unit_price,
                    'line_total', i.line_total
                  )
                  ORDER BY i.created_at ASC
                )
                FROM delivery_batch_items i
                WHERE i.batch_customer_id = c.id
              ),
              '[]'::json
            ) AS items
     FROM delivery_batch_customers c
     WHERE c.batch_id = $1
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
    [batchId],
  );

  return {
    ...mapBatchRow(batchQ.rows[0]),
    customers: customersQ.rows.map((row) => ({
      ...row,
      address_text: decodeAddressFromRow(row),
      processed_sum: toMoney(row.processed_sum),
      agreed_sum: toMoney(row.agreed_sum),
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

function emitDeliveryUpdated(io, batchId) {
  if (!io) return;
  io.emit("delivery:updated", {
    batchId: String(batchId || ""),
    updatedAt: new Date().toISOString(),
  });
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

async function findDraftBatchId(queryable) {
  const activeBatchQ = await queryable.query(
    `SELECT id
     FROM delivery_batches
     WHERE status IN ('calling', 'couriers_assigned')
     ORDER BY
       CASE status
         WHEN 'calling' THEN 0
         WHEN 'couriers_assigned' THEN 1
         ELSE 2
       END,
       created_at DESC
     LIMIT 1`,
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
  for (const item of items || []) {
    await queryable.query(
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
}

async function collectEligibleCustomers(queryable) {
  const itemsQ = await queryable.query(
    `SELECT c.id AS cart_item_id,
            c.user_id::text AS user_id,
            c.product_id::text AS product_id,
            c.quantity,
            c.created_at,
            c.updated_at,
            p.price,
            p.product_code,
            p.title AS product_title,
            p.description AS product_description,
            p.image_url AS product_image_url,
            COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Клиент') AS customer_name,
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
       SELECT a.id, a.address_text, a.lat, a.lng
              ,a.address_ciphertext, a.address_iv, a.address_tag
       FROM user_delivery_addresses a
       WHERE a.user_id = c.user_id
       ORDER BY a.is_default DESC, a.updated_at DESC
       LIMIT 1
     ) AS addr ON true
     WHERE c.status = 'processed'
       AND NOT EXISTS (
         SELECT 1
         FROM delivery_batch_items di
         JOIN delivery_batch_customers dbc ON dbc.id = di.batch_customer_id
         JOIN delivery_batches dbt ON dbt.id = di.batch_id
         WHERE di.cart_item_id = c.id
           AND dbt.status IN ('calling', 'couriers_assigned', 'handed_off')
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
  );

  const grouped = new Map();
  for (const row of itemsQ.rows) {
    const key = String(row.user_id);
    const lineTotal = toMoney(Number(row.price) * Number(row.quantity));
    if (!grouped.has(key)) {
      grouped.set(key, {
        user_id: key,
        customer_name: row.customer_name,
        customer_phone: row.customer_phone,
        shelf_number:
          row.shelf_number == null ? null : Number(row.shelf_number) || null,
        address_id: row.address_id || null,
        address_text: decodeAddressFromRow(row) || "",
        lat: row.lat == null ? null : Number(row.lat),
        lng: row.lng == null ? null : Number(row.lng),
        processed_sum: 0,
        processed_items_count: 0,
        items: [],
      });
    }
    const bucket = grouped.get(key);
    bucket.processed_sum = toMoney(bucket.processed_sum + lineTotal);
    bucket.processed_items_count += Number(row.quantity) || 0;
    bucket.items.push({
      cart_item_id: row.cart_item_id,
      user_id: row.user_id,
      product_id: row.product_id,
      quantity: Number(row.quantity) || 0,
      unit_price: toMoney(row.price),
      line_total: lineTotal,
      product_code: row.product_code == null ? null : Number(row.product_code),
      product_title: row.product_title,
      product_description: row.product_description,
      product_image_url: row.product_image_url,
    });
  }
  return Array.from(grouped.values());
}

async function createDeliveryBatch(queryable, settings, createdBy) {
  const thresholdAmount = Math.max(0, toMoney(settings?.threshold_amount, 1500));
  const existingDraftBatchId = await findDraftBatchId(queryable);
  if (existingDraftBatchId) {
    return {
      created: false,
      batchId: existingDraftBatchId,
      eligible_total: 0,
      message: "Черновой лист доставки уже существует",
    };
  }

  const grouped = await collectEligibleCustomers(queryable);
  const candidates = grouped
    .filter((entry) => entry.processed_sum >= thresholdAmount)
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

  for (const candidate of candidates) {
    const batchCustomerId = uuidv4();
    const encryptedAddress = buildAddressEncryption(candidate.address_text || "");
    await queryable.query(
      `INSERT INTO delivery_batch_customers (
         id, batch_id, user_id, customer_name, customer_phone,
         processed_sum, processed_items_count, shelf_number,
         address_id, address_text, address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at,
         lat, lng,
         call_status, delivery_status, created_at, updated_at
       )
       VALUES (
         $1, $2, $3, $4, $5,
         $6, $7, $8,
         $9, NULL, $10, $11, $12, $13, $14,
         $15, $16,
         'pending', 'awaiting_call', now(), now()
       )`,
      [
        batchCustomerId,
        batchId,
        candidate.user_id,
        candidate.customer_name,
        candidate.customer_phone,
        candidate.processed_sum,
        candidate.processed_items_count,
        candidate.shelf_number,
        candidate.address_id,
        encryptedAddress.ciphertext,
        encryptedAddress.iv,
        encryptedAddress.tag,
        encryptedAddress.version,
        encryptedAddress.encryptedAt,
        candidate.lat,
        candidate.lng,
      ],
    );

    await insertDeliveryBatchItems(queryable, batchId, batchCustomerId, candidate.items);
  }

  return {
    created: true,
    batchId,
    eligible_total: candidates.length,
    message: "",
  };
}

async function addEligibleCustomersToBatch(queryable, batchId, thresholdAmount) {
  const grouped = await collectEligibleCustomers(queryable);
  const candidates = grouped
    .filter((entry) => entry.processed_sum >= thresholdAmount)
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
      const encryptedAddress = buildAddressEncryption(candidate.address_text || "");
      await queryable.query(
        `UPDATE delivery_batch_customers
         SET customer_name = $2,
             customer_phone = $3,
             processed_sum = $4,
             processed_items_count = $5,
             shelf_number = $6,
             address_id = $7,
             address_text = NULL,
             address_ciphertext = $8,
             address_iv = $9,
             address_tag = $10,
             address_encryption_version = $11,
             address_encrypted_at = $12,
             lat = $13,
             lng = $14,
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
          candidate.processed_items_count,
          candidate.shelf_number,
          candidate.address_id,
          encryptedAddress.ciphertext,
          encryptedAddress.iv,
          encryptedAddress.tag,
          encryptedAddress.version,
          encryptedAddress.encryptedAt,
          candidate.lat,
          candidate.lng,
        ],
      );

      await queryable.query(
        `DELETE FROM delivery_batch_items
         WHERE batch_customer_id = $1`,
        [reusableRow.id],
      );
      await insertDeliveryBatchItems(queryable, batchId, reusableRow.id, candidate.items);
      addedTotal += 1;
      continue;
    }

    const batchCustomerId = uuidv4();
    const encryptedAddress = buildAddressEncryption(candidate.address_text || "");
    await queryable.query(
      `INSERT INTO delivery_batch_customers (
         id, batch_id, user_id, customer_name, customer_phone,
         processed_sum, processed_items_count, shelf_number,
         address_id, address_text, address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at,
         lat, lng,
         call_status, delivery_status, created_at, updated_at
       )
       VALUES (
         $1, $2, $3, $4, $5,
         $6, $7, $8,
         $9, NULL, $10, $11, $12, $13, $14,
         $15, $16,
         'pending', 'awaiting_call', now(), now()
       )`,
      [
        batchCustomerId,
        batchId,
        candidate.user_id,
        candidate.customer_name,
        candidate.customer_phone,
        candidate.processed_sum,
        candidate.processed_items_count,
        candidate.shelf_number,
        candidate.address_id,
        encryptedAddress.ciphertext,
        encryptedAddress.iv,
        encryptedAddress.tag,
        encryptedAddress.version,
        encryptedAddress.encryptedAt,
        candidate.lat,
        candidate.lng,
      ],
    );

    await insertDeliveryBatchItems(queryable, batchId, batchCustomerId, candidate.items);

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
       AND ($2::uuid IS NULL OR c.tenant_id = $2::uuid OR c.tenant_id IS NULL)
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
  return result.rows[0] || null;
}

function buildDeliveryOfferText(customer, batch) {
  const phone = String(customer.customer_phone || "—").trim() || "—";
  const amount = toMoney(customer.processed_sum);
  return [
    batch.delivery_label || "Доставка",
    `Номер телефона: ${phone}`,
    `Обработано товара на сумму: ${amount} RUB`,
    "Согласны принять доставку?",
    "Если да, нажмите кнопку подтверждения и отправьте адрес доставки.",
    "Доставка обычно идет с 10:00 до 16:00. При желании укажите время 'после' или 'до'.",
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
       AND call_status = 'accepted'`,
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

async function findUserByPhone(queryable, phone) {
  const normalized = normalizePhone(phone);
  if (!normalized) return null;
  const result = await queryable.query(
    `SELECT u.id::text AS user_id,
            COALESCE(NULLIF(BTRIM(u.name), ''), NULLIF(BTRIM(u.email), ''), 'Клиент') AS customer_name,
            ph.phone AS customer_phone
     FROM phones ph
     JOIN users u ON u.id = ph.user_id
     WHERE regexp_replace(COALESCE(ph.phone, ''), '\D+', '', 'g') = $1
     LIMIT 1`,
    [normalized],
  );
  return result.rows[0] || null;
}

async function collectEligibleCustomerForUser(queryable, userId) {
  const customers = await collectEligibleCustomers(queryable);
  return customers.find((entry) => String(entry.user_id) === String(userId)) || null;
}

router.get(
  "/dashboard",
  requireAuth,
  requireRole("admin", "creator"),
  async (_req, res) => {
    try {
      const settings = await getDeliverySettings();
      const batches = await fetchBatchSummaries(db);
      const activeBatchSummary =
        batches.find((item) => item.status !== "completed" && item.status !== "cancelled") ||
        null;
      const activeBatch = activeBatchSummary
        ? await fetchBatchDetails(db, activeBatchSummary.id)
        : null;
      return res.json({
        ok: true,
        data: {
          settings,
          batches,
          active_batch: activeBatch,
        },
      });
    } catch (err) {
      console.error("delivery.dashboard error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    }
  },
);

router.patch(
  "/settings",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const thresholdAmount = toMoney(req.body?.threshold_amount, NaN);
    if (!Number.isFinite(thresholdAmount) || thresholdAmount < 0) {
      return res
        .status(400)
        .json({ ok: false, error: "Некорректная сумма порога доставки" });
    }
    const routeOriginLabel =
      String(req.body?.route_origin_label || "Точка отправки").trim() ||
      "Точка отправки";
    const routeOriginAddress = String(req.body?.route_origin_address || "").trim();
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
            error: "Не удалось найти точку отправки в Самарской области",
          });
        }
        routeOriginLat = geocoded.lat;
        routeOriginLng = geocoded.lng;
      } catch (error) {
        return res.status(400).json({
          ok: false,
          error: error.message || "Не удалось проверить точку отправки",
        });
      }
    }

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const nextSettings = {
        threshold_amount: thresholdAmount,
        route_origin_label: routeOriginLabel,
        route_origin_address: routeOriginAddress,
        route_origin_lat: Number.isFinite(routeOriginLat) ? routeOriginLat : null,
        route_origin_lng: Number.isFinite(routeOriginLng) ? routeOriginLng : null,
      };
      await saveDeliverySettings(client, nextSettings, req.user.id);
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

router.get("/slots", requireAuth, async (req, res) => {
  try {
    const role = String(req.user?.role || "").toLowerCase().trim();
    const allowAll = (role === "admin" || role === "creator") && String(req.query?.all || "") === "1";
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
  requireRole("admin", "creator"),
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
  requireRole("admin", "creator"),
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
  requireRole("admin", "creator"),
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
  requireRole("admin", "creator"),
  async (req, res) => {
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const settings = await getDeliverySettings(client);
      const thresholdAmount = Math.max(
        0,
        toMoney(req.body?.threshold_amount, settings.threshold_amount),
      );
      const nextSettings = {
        ...settings,
        threshold_amount: thresholdAmount,
      };
      await saveDeliverySettings(client, nextSettings, req.user.id);

      const createdBatch = await createDeliveryBatch(
        client,
        nextSettings,
        req.user.id,
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
      const activeBatch = batchId ? await fetchBatchDetails(db, batchId) : null;
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
  requireRole("admin", "creator"),
  async (req, res) => {
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const settings = await getDeliverySettings(client);
      const thresholdAmount = Math.max(
        0,
        toMoney(req.body?.threshold_amount, settings.threshold_amount),
      );
      const nextSettings = {
        ...settings,
        threshold_amount: thresholdAmount,
      };
      await saveDeliverySettings(client, nextSettings, req.user.id);

      let batchId = await findDraftBatchId(client);
      let created = false;
      let eligibleTotal = 0;
      let addedToExistingBatch = 0;
      let systemMessages = [];
      if (!batchId) {
        const createdBatch = await createDeliveryBatch(
          client,
          nextSettings,
          req.user.id,
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
        );
      }

      const batch = await fetchBatchDetails(client, batchId);
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
            buildDeliveryOfferText(customer, batch),
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
        emitDeliveryUpdated(io, batchId);
      }

      const activeBatch = await fetchBatchDetails(db, batchId);
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
  requireRole("admin", "creator"),
  async (req, res) => {
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const affectedUsersQ = await client.query(
        `SELECT DISTINCT user_id::text AS user_id
         FROM delivery_batch_customers`,
      );
      const affectedUsers = affectedUsersQ.rows.map((row) => String(row.user_id));

      await client.query(
        `UPDATE cart_items
         SET status = 'processed',
             updated_at = now()
         WHERE status IN ('preparing_delivery', 'handing_to_courier', 'in_delivery')`,
      );

      const deliveryChatsQ = await client.query(
        `SELECT id
         FROM chats
         WHERE COALESCE(settings->>'kind', '') = 'delivery_dialog'`,
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

      await client.query(`DELETE FROM delivery_batch_items`);
      await client.query(`DELETE FROM delivery_batch_customers`);
      await client.query(`DELETE FROM delivery_batches`);

      const demoUsersQ = await client.query(
        `SELECT id
         FROM users
         WHERE email LIKE $1`,
        [`${DEMO_USER_EMAIL_PREFIX}%`],
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
         WHERE title LIKE $1`,
        [`${DEMO_PRODUCT_TITLE_PREFIX}%`],
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
        emitDeliveryUpdated(io, "reset");
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
  requireRole("admin", "creator"),
  async (req, res) => {
    const requested = Number(req.body?.count ?? 10);
    const count = Math.max(1, Math.min(20, Math.floor(requested)));
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const demoProducts = await ensureDemoProducts(client);
      const seedId = Date.now();
      let createdUsers = 0;

      for (let i = 0; i < count; i += 1) {
        const point = DEMO_SAMARA_POINTS[i % DEMO_SAMARA_POINTS.length];
        const email = `${DEMO_USER_EMAIL_PREFIX}${seedId}.${i}@phoenix.local`;
        const phone = `7999${String(seedId).slice(-4)}${String(i + 10).padStart(3, "0")}`;
        const userInsert = await client.query(
          `INSERT INTO users (id, email, password_hash, name, role, created_at, updated_at)
           VALUES ($1, $2, NULL, $3, 'client', now(), now())
           RETURNING id`,
          [uuidv4(), email, `${point.name} Тест`],
        );
        const userId = String(userInsert.rows[0].id);
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
        const targetSum = 1800 + (i % 5) * 350;
        const unitPrice = Number(product.price) || 500;
        const quantity = Math.max(1, Math.ceil(targetSum / unitPrice));
        await client.query(
          `INSERT INTO cart_items (
             id, user_id, product_id, quantity, status, created_at, updated_at
           )
           VALUES ($1, $2, $3, $4, 'processed', now(), now())`,
          [uuidv4(), userId, product.id, quantity],
        );
        createdUsers += 1;
      }

      await client.query("COMMIT");
      return res.status(201).json({
        ok: true,
        data: {
          created_users: createdUsers,
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
      let nextAddressText =
        addressText || decodeAddressFromRow(customer);
      let nextLat = Number.isFinite(lat) ? lat : customer.lat;
      let nextLng = Number.isFinite(lng) ? lng : customer.lng;

      if (accepted && addressText.length > 0 && (!Number.isFinite(lat) || !Number.isFinite(lng))) {
        const geocoded = await geocodeDeliveryAddress(addressText);
        if (!geocoded) {
          await client.query("ROLLBACK");
          return res.status(400).json({
            ok: false,
            error: "Не удалось найти этот адрес в указанном городе",
          });
        }
        nextAddressText = geocoded.address_text;
        nextLat = geocoded.lat;
        nextLng = geocoded.lng;
      }

      if (accepted && nextAddressText) {
        await client.query(
          `UPDATE user_delivery_addresses
           SET is_default = false,
               updated_at = now()
           WHERE user_id = $1`,
          [customer.user_id],
        );
        const encryptedAddress = buildAddressEncryption(nextAddressText);
        const addressInsert = await client.query(
          `INSERT INTO user_delivery_addresses (
             id, user_id, label, address_text,
             address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at,
             lat, lng, is_default, created_at, updated_at
           )
           VALUES (
             $1, $2, 'Основной адрес', NULL,
             $3, $4, $5, $6, $7,
             $8, $9, true, now(), now()
           )
           RETURNING id`,
          [
            uuidv4(),
            customer.user_id,
            encryptedAddress.ciphertext,
            encryptedAddress.iv,
            encryptedAddress.tag,
            encryptedAddress.version,
            encryptedAddress.encryptedAt,
            nextLat,
            nextLng,
          ],
        );
        addressId = String(addressInsert.rows[0].id);
      }

      const customerEncryptedAddress = buildAddressEncryption(nextAddressText || "");
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
             preferred_time_from = $11,
             preferred_time_to = $12,
             accepted_at = CASE WHEN $1 = 'accepted' THEN now() ELSE accepted_at END,
             agreed_sum = CASE WHEN $1 = 'accepted' THEN processed_sum ELSE agreed_sum END,
             updated_at = now()
         WHERE id = $13`,
        [
          accepted ? "accepted" : "declined",
          accepted ? "preparing_delivery" : "declined",
          addressId,
          customerEncryptedAddress.ciphertext,
          customerEncryptedAddress.iv,
          customerEncryptedAddress.tag,
          customerEncryptedAddress.version,
          customerEncryptedAddress.encryptedAt,
          nextLat,
          nextLng,
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
            nextAddressText || "",
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
          accepted
            ? buildDeliveryAcceptedText(
                nextAddressText,
                preferredWindow.fromText,
                preferredWindow.toText,
              )
            : buildDeliveryDeclinedText(),
          JSON.stringify({
            kind: "delivery_offer_result",
            delivery_batch_id: customer.batch_id,
            delivery_customer_id: customerId,
            offer_status: accepted ? "accepted" : "declined",
            address_text: nextAddressText || "",
            preferred_time_from: preferredWindow.fromText || "",
            preferred_time_to: preferredWindow.toText || "",
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
        emitCartUpdated(io, customer.user_id, {
          status: accepted ? "preparing_delivery" : "processed",
          reason: accepted ? "delivery_confirmed" : "delivery_declined",
        });
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
        emitDeliveryUpdated(io, customer.batch_id);
      }

      const activeBatch = await fetchBatchDetails(db, customer.batch_id);
      return res.json({
        ok: true,
        data: {
          customer_id: customerId,
          status: accepted ? "accepted" : "declined",
          active_batch: activeBatch,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.clientRespond error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/batches/:batchId/customers/:customerId/decision",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { batchId, customerId } = req.params;
    const accepted = req.body?.accepted === true;
    const declined = req.body?.accepted === false;
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
    const saveAsDefault = req.body?.save_as_default !== false;
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
         WHERE c.id = $1
           AND c.batch_id = $2
         LIMIT 1
         FOR UPDATE`,
        [customerId, batchId],
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
      let nextAddressText = addressText || decodeAddressFromRow(customer);
      let nextLat = Number.isFinite(lat) ? lat : customer.lat;
      let nextLng = Number.isFinite(lng) ? lng : customer.lng;
      const ensured = await ensureDeliveryChat(
        client,
        customer.user_id,
        req.user.id,
        req.user.tenant_id || null,
      );
      const chat = ensured.chat;

      if (accepted && addressText.length > 0 && (!Number.isFinite(lat) || !Number.isFinite(lng))) {
        const geocoded = await geocodeDeliveryAddress(addressText);
        if (!geocoded) {
          await client.query("ROLLBACK");
          return res.status(400).json({
            ok: false,
            error: "Не удалось найти этот адрес в указанном городе",
          });
        }
        nextAddressText = geocoded.address_text;
        nextLat = geocoded.lat;
        nextLng = geocoded.lng;
      }

      if (accepted && saveAsDefault && (nextAddressText || (Number.isFinite(nextLat) && Number.isFinite(nextLng)))) {
        if (nextAddressText) {
          await client.query(
            `UPDATE user_delivery_addresses
             SET is_default = false,
                 updated_at = now()
             WHERE user_id = $1`,
            [customer.user_id],
          );
          const encryptedAddress = buildAddressEncryption(nextAddressText);
          const addressInsert = await client.query(
            `INSERT INTO user_delivery_addresses (
               id, user_id, label, address_text,
               address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at,
               lat, lng, is_default, created_at, updated_at
             )
             VALUES (
               $1, $2, 'Основной адрес', NULL,
               $3, $4, $5, $6, $7,
               $8, $9, true, now(), now()
             )
             RETURNING id`,
            [
              uuidv4(),
              customer.user_id,
              encryptedAddress.ciphertext,
              encryptedAddress.iv,
              encryptedAddress.tag,
              encryptedAddress.version,
              encryptedAddress.encryptedAt,
              nextLat,
              nextLng,
            ],
          );
          addressId = String(addressInsert.rows[0].id);
        }
      }

      const customerEncryptedAddress = buildAddressEncryption(nextAddressText || "");
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
             preferred_time_from = $11,
             preferred_time_to = $12,
             accepted_at = CASE WHEN $1 = 'accepted' THEN now() ELSE accepted_at END,
             agreed_sum = CASE WHEN $1 = 'accepted' THEN processed_sum ELSE agreed_sum END,
             updated_at = now()
         WHERE id = $13`,
        [
          accepted ? "accepted" : "declined",
          accepted ? "preparing_delivery" : "declined",
          addressId,
          customerEncryptedAddress.ciphertext,
          customerEncryptedAddress.iv,
          customerEncryptedAddress.tag,
          customerEncryptedAddress.version,
          customerEncryptedAddress.encryptedAt,
          nextLat,
          nextLng,
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
          nextAddressText || "",
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
          accepted
            ? buildDeliveryAcceptedText(
                nextAddressText,
                preferredWindow.fromText,
                preferredWindow.toText,
              )
            : buildDeliveryDeclinedText(),
          JSON.stringify({
            kind: "delivery_offer_result",
            delivery_batch_id: customer.batch_id,
            delivery_customer_id: customerId,
            offer_status: accepted ? "accepted" : "declined",
            address_text: nextAddressText || "",
            preferred_time_from: preferredWindow.fromText || "",
            preferred_time_to: preferredWindow.toText || "",
            responded_by: "admin",
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
      } else {
        emitCartUpdated(io, customer.user_id, {
          status: "processed",
          reason: "delivery_declined",
        });
      }
      emitDeliveryUpdated(io, batchId);

      const activeBatch = await fetchBatchDetails(db, batchId);
      return res.json({
        ok: true,
        data: {
          customer_id: customerId,
          active_batch: activeBatch,
        },
      });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.customer.decision error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.patch(
  "/batches/:batchId/customers/:customerId/logistics",
  requireAuth,
  requireRole("admin", "creator"),
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
        `UPDATE delivery_batch_customers
         SET package_places = $1,
             bulky_places = $2,
             bulky_note = $3,
             updated_at = now()
         WHERE batch_id = $4
           AND id = $5
         RETURNING id`,
        [packagePlaces, bulkyPlaces, bulkyNote || null, batchId, customerId],
      );
      if (updated.rowCount === 0) {
        return res.status(404).json({
          ok: false,
          error: "Клиент в листе доставки не найден",
        });
      }
      const activeBatch = await fetchBatchDetails(db, batchId);
      const io = req.app.get("io");
      emitDeliveryUpdated(io, batchId);
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
  requireRole("admin", "creator"),
  async (req, res) => {
    const { batchId, customerId } = req.params;
    const courierName = String(req.body?.courier_name || "").trim();

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const batchQ = await client.query(
        `SELECT id, status, courier_names
         FROM delivery_batches
         WHERE id = $1
         LIMIT 1
         FOR UPDATE`,
        [batchId],
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

      const activeBatch = await fetchBatchDetails(db, batchId);
      const io = req.app.get("io");
      emitDeliveryUpdated(io, batchId);
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

router.post(
  "/batches/:batchId/customers/manual-add",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { batchId } = req.params;
    const phone = String(req.body?.phone || "").trim();
    const addressText = String(req.body?.address_text || "").trim();
    const bulkyNote = String(req.body?.bulky_note || "").trim();
    const packagePlaces = Number(req.body?.package_places ?? 1);
    const bulkyPlaces = Number(req.body?.bulky_places ?? 0);
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
        `SELECT id, status
         FROM delivery_batches
         WHERE id = $1
         LIMIT 1
         FOR UPDATE`,
        [batchId],
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

      const user = await findUserByPhone(client, phone);
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

      const eligible = await collectEligibleCustomerForUser(client, user.user_id);
      if (!eligible || !Array.isArray(eligible.items) || eligible.items.length === 0) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "У клиента нет обработанных товаров, готовых к доставке",
        });
      }

      const geocoded = await geocodeDeliveryAddress(addressText);
      if (!geocoded) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Не удалось найти этот адрес в указанном городе",
        });
      }

      await client.query(
        `UPDATE user_delivery_addresses
         SET is_default = false,
             updated_at = now()
         WHERE user_id = $1`,
        [user.user_id],
      );
      const encryptedAddress = buildAddressEncryption(geocoded.address_text);
      const addressInsert = await client.query(
        `INSERT INTO user_delivery_addresses (
           id, user_id, label, address_text,
           address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at,
           lat, lng, is_default, created_at, updated_at
         )
         VALUES (
           $1, $2, 'Основной адрес', NULL,
           $3, $4, $5, $6, $7,
           $8, $9, true, now(), now()
         )
         RETURNING id`,
        [
          uuidv4(),
          user.user_id,
          encryptedAddress.ciphertext,
          encryptedAddress.iv,
          encryptedAddress.tag,
          encryptedAddress.version,
          encryptedAddress.encryptedAt,
          geocoded.lat,
          geocoded.lng,
        ],
      );
      const addressId = String(addressInsert.rows[0].id);
      const batchCustomerId = uuidv4();

      const batchEncryptedAddress = buildAddressEncryption(geocoded.address_text);
      await client.query(
        `INSERT INTO delivery_batch_customers (
           id, batch_id, user_id, customer_name, customer_phone,
           processed_sum, agreed_sum, processed_items_count, shelf_number,
           address_id, address_text, address_ciphertext, address_iv, address_tag, address_encryption_version, address_encrypted_at, lat, lng,
           call_status, delivery_status, preferred_time_from, preferred_time_to,
           package_places, bulky_places, bulky_note, accepted_at, created_at, updated_at
         )
         VALUES (
           $1, $2, $3, $4, $5,
           $6, $6, $7, $8,
           $9, NULL, $10, $11, $12, $13, $14, $15, $16,
           'accepted', 'preparing_delivery', $17, $18,
           $19, $20, $21, now(), now(), now()
         )`,
        [
          batchCustomerId,
          batchId,
          user.user_id,
          eligible.customer_name,
          eligible.customer_phone,
          eligible.processed_sum,
          eligible.processed_items_count,
          eligible.shelf_number,
          addressId,
          batchEncryptedAddress.ciphertext,
          batchEncryptedAddress.iv,
          batchEncryptedAddress.tag,
          batchEncryptedAddress.version,
          batchEncryptedAddress.encryptedAt,
          geocoded.lat,
          geocoded.lng,
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
          buildDeliveryAcceptedText(
            geocoded.address_text,
            preferredWindow.fromText,
            preferredWindow.toText,
          ),
          JSON.stringify({
            kind: "delivery_offer_result",
            delivery_batch_id: batchId,
            delivery_customer_id: batchCustomerId,
            offer_status: "accepted",
            address_text: geocoded.address_text,
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
        emitDeliveryUpdated(io, batchId);
      }

      const activeBatch = await fetchBatchDetails(db, batchId);
      return res.status(201).json({ ok: true, data: { active_batch: activeBatch } });
    } catch (err) {
      await client.query("ROLLBACK");
      console.error("delivery.customer.manualAdd error", err);
      return res.status(500).json({ ok: false, error: "Ошибка сервера" });
    } finally {
      client.release();
    }
  },
);

router.post(
  "/batches/:batchId/assign-couriers",
  requireAuth,
  requireRole("admin", "creator"),
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
        `SELECT id, status
         FROM delivery_batches
         WHERE id = $1
         LIMIT 1
         FOR UPDATE`,
        [batchId],
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
         ORDER BY customer_name ASC`,
        [batchId],
      );
      if (customersQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "В листе нет подтвержденных клиентов для распределения по курьерам",
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

      const detail = await fetchBatchDetails(db, batchId);
      const io = req.app.get("io");
      if (io && detail) {
        for (const customer of detail.customers) {
          emitCartUpdated(io, customer.user_id, {
            status: "handing_to_courier",
            reason: "couriers_assigned",
          });
        }
        emitDeliveryUpdated(io, batchId);
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
  requireRole("admin", "creator"),
  async (req, res) => {
    const { batchId } = req.params;
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const batchQ = await client.query(
        `SELECT id
         FROM delivery_batches
         WHERE id = $1
         LIMIT 1
         FOR UPDATE`,
        [batchId],
      );
      if (batchQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Лист доставки не найден" });
      }

      const readyForHandoffQ = await client.query(
        `SELECT COUNT(*)::int AS total
         FROM delivery_batch_customers
         WHERE batch_id = $1
           AND call_status = 'accepted'
           AND courier_name IS NOT NULL
           AND courier_name <> ''`,
        [batchId],
      );
      if ((Number(readyForHandoffQ.rows[0]?.total) || 0) <= 0) {
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
           AND courier_name IS NOT NULL
           AND courier_name <> ''`,
        [batchId],
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
             AND c.courier_name IS NOT NULL
             AND c.courier_name <> ''
        )`,
        [batchId],
      );

      await client.query(
        `DELETE FROM user_shelves
         WHERE user_id IN (
           SELECT DISTINCT c.user_id
           FROM delivery_batch_customers c
           WHERE c.batch_id = $1
             AND c.call_status = 'accepted'
             AND c.courier_name IS NOT NULL
             AND c.courier_name <> ''
         )`,
        [batchId],
      );

      await client.query(
        `UPDATE delivery_batches
         SET status = 'handed_off',
             handed_off_at = now(),
             updated_at = now()
         WHERE id = $1`,
        [batchId],
      );

      await client.query("COMMIT");

      const detail = await fetchBatchDetails(db, batchId);
      const io = req.app.get("io");
      if (io && detail) {
        for (const customer of detail.customers) {
          if (customer.call_status !== "accepted") continue;
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
        emitDeliveryUpdated(io, batchId);
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
  requireRole("admin", "creator"),
  async (req, res) => {
    const { batchId } = req.params;
    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");

      const batchQ = await client.query(
        `SELECT id, status
         FROM delivery_batches
         WHERE id = $1
         LIMIT 1
         FOR UPDATE`,
        [batchId],
      );
      if (batchQ.rowCount === 0) {
        await client.query("ROLLBACK");
        return res.status(404).json({ ok: false, error: "Лист доставки не найден" });
      }
      const batchStatus = String(batchQ.rows[0].status || "");
      if (batchStatus !== "handed_off") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error:
            batchStatus === "completed"
              ? "Этот лист уже завершен"
              : "Завершить можно только лист, который уже передан курьерам",
        });
      }

      const usersQ = await client.query(
        `SELECT DISTINCT c.user_id::text AS user_id
         FROM delivery_batch_customers c
         WHERE c.batch_id = $1
           AND c.call_status = 'accepted'
           AND c.courier_name IS NOT NULL
           AND c.courier_name <> ''`,
        [batchId],
      );

      await client.query(
        `UPDATE delivery_batch_customers
         SET delivery_status = 'completed',
             updated_at = now()
         WHERE batch_id = $1
           AND call_status = 'accepted'
           AND courier_name IS NOT NULL
           AND courier_name <> ''`,
        [batchId],
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
             AND c.courier_name IS NOT NULL
             AND c.courier_name <> ''
         )`,
        [batchId],
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

      const detail = await fetchBatchDetails(db, batchId);
      const io = req.app.get("io");
      if (io) {
        for (const row of usersQ.rows) {
          emitCartUpdated(io, row.user_id, {
            status: "delivered",
            reason: "delivery_completed",
            batch_id: batchId,
          });
        }
        emitDeliveryUpdated(io, batchId);
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
  requireRole("admin", "creator"),
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
         WHERE c.id = $1
           AND c.batch_id = $2
         LIMIT 1
         FOR UPDATE`,
        [customerId, batchId],
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

      await client.query("COMMIT");

      const detail = await fetchBatchDetails(db, batchId);
      const io = req.app.get("io");
      if (io) {
        emitCartUpdated(io, customer.user_id, {
          status: "processed",
          reason: "delivery_removed_from_route",
          batch_id: batchId,
        });
        emitDeliveryUpdated(io, batchId);
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

router.get(
  "/batches/:batchId/export",
  requireAuth,
  requireRole("admin", "creator"),
  async (req, res) => {
    const { batchId } = req.params;
    try {
      const batchQ = await db.query(
        `SELECT id, delivery_date
         FROM delivery_batches
         WHERE id = $1
         LIMIT 1`,
        [batchId],
      );
      if (batchQ.rowCount === 0) {
        return res.status(404).json({ ok: false, error: "Лист доставки не найден" });
      }
      const rowsQ = await db.query(
        `SELECT customer_phone,
                customer_name,
                agreed_sum,
                processed_sum,
                address_text,
                address_ciphertext,
                address_iv,
                address_tag,
                courier_code,
                bulky_note,
                shelf_number,
                package_places,
                preferred_time_from,
                preferred_time_to,
                route_order
         FROM delivery_batch_customers
         WHERE batch_id = $1
           AND call_status = 'accepted'
         ORDER BY route_order ASC NULLS LAST, customer_name ASC`,
        [batchId],
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
        { header: "Габарит", key: "bulky_note", width: 26 },
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
          bulky_note: "",
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
            bulky_note: String(customer.bulky_note || "").trim(),
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
