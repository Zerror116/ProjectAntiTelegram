const NODE_ENV = String(process.env.NODE_ENV || "development")
  .toLowerCase()
  .trim();
const IS_PRODUCTION = NODE_ENV === "production";

const ADDRESS_PROVIDER = String(
  process.env.DELIVERY_ADDRESS_PROVIDER ||
    process.env.ADDRESS_SEARCH_PROVIDER ||
    "photon",
)
  .toLowerCase()
  .trim();

const PHOTON_SEARCH_URL = String(
  process.env.DELIVERY_ADDRESS_SUGGEST_URL || process.env.PHOTON_SEARCH_URL || "",
).trim();
const PHOTON_REVERSE_URL = String(
  process.env.DELIVERY_ADDRESS_REVERSE_URL || process.env.PHOTON_REVERSE_URL || "",
).trim();

const NOMINATIM_SEARCH_URL = String(
  process.env.GEOCODER_SEARCH_URL || "https://nominatim.openstreetmap.org/search",
).trim();
const NOMINATIM_REVERSE_URL = String(
  process.env.GEOCODER_REVERSE_URL ||
    "https://nominatim.openstreetmap.org/reverse",
).trim();
const ADDRESS_USER_AGENT = String(
  process.env.GEOCODER_USER_AGENT || "ProjectPhoenix/1.0 (delivery addressing)",
).trim();
const ADDRESS_AUTH_HEADER = String(process.env.GEOCODER_AUTH_HEADER || "").trim();
const ADDRESS_API_KEY = String(process.env.GEOCODER_API_KEY || "").trim();
const ADDRESS_COUNTRY_CODES = String(
  process.env.DELIVERY_ADDRESS_COUNTRY_CODES || "ru",
)
  .split(",")
  .map((item) => item.trim().toLowerCase())
  .filter(Boolean);
const ADDRESS_TIMEOUT_MS = Math.max(
  800,
  Math.min(
    12000,
    Number(process.env.DELIVERY_ADDRESS_TIMEOUT_MS || 3200) || 3200,
  ),
);
const ADDRESS_RETRY_COUNT = Math.max(
  0,
  Math.min(
    3,
    Math.round(Number(process.env.DELIVERY_ADDRESS_RETRY_COUNT || 1) || 1),
  ),
);
const ADDRESS_ALLOW_PUBLIC_FALLBACK = (() => {
  const raw = String(process.env.DELIVERY_ADDRESS_ALLOW_PUBLIC_FALLBACK || "")
    .toLowerCase()
    .trim();
  if (!raw) return !IS_PRODUCTION;
  return raw === "1" || raw === "true" || raw === "yes";
})();
const DEFAULT_PUBLIC_PHOTON_SEARCH_URL = "https://photon.komoot.io/api";
const DEFAULT_PUBLIC_PHOTON_REVERSE_URL = "https://photon.komoot.io/reverse";

class AddressProviderError extends Error {
  constructor(message, options = {}) {
    super(message);
    this.name = "AddressProviderError";
    this.code =
      String(options.code || "").trim() || "address_provider_unavailable";
    this.provider = String(options.provider || "").trim() || null;
    this.status = Number(options.status) || 503;
    this.retryable = options.retryable === true;
    this.details = options.details || null;
    this.cause = options.cause || null;
  }
}

function normalizeWhitespace(value) {
  return String(value || "")
    .replace(/\s+/g, " ")
    .replace(/\s*,\s*/g, ", ")
    .trim();
}

function toFiniteNumber(value) {
  const num = Number(value);
  return Number.isFinite(num) ? num : null;
}

function sanitizeJsonObject(raw) {
  return raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
}

function isAddressProviderError(error) {
  return error instanceof AddressProviderError;
}

function buildHeaders() {
  const headers = {
    Accept: "application/json",
  };
  if (ADDRESS_USER_AGENT) {
    headers["User-Agent"] = ADDRESS_USER_AGENT;
  }
  if (ADDRESS_AUTH_HEADER) {
    headers.Authorization = ADDRESS_AUTH_HEADER;
  }
  return headers;
}

function buildProviderError(message, options = {}) {
  return new AddressProviderError(message, options);
}

function shouldRetryStatus(status) {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

function retryDelayMs(attempt) {
  return Math.min(1500, 180 * (attempt + 1));
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function normalizeProviderError(error, provider, context) {
  if (isAddressProviderError(error)) {
    return error;
  }
  const messageContext = context ? ` (${context})` : "";
  if (error?.name === "AbortError") {
    return buildProviderError(
      `Сервис адресов${messageContext} не ответил вовремя. Попробуйте чуть позже.`,
      {
        provider,
        status: 503,
        code: "address_provider_timeout",
        retryable: true,
        cause: error,
      },
    );
  }
  return buildProviderError(
    `Сервис адресов${messageContext} временно недоступен. Попробуйте чуть позже.`,
    {
      provider,
      status: 503,
      code: "address_provider_unavailable",
      retryable: true,
      cause: error,
    },
  );
}

function resolvePhotonSearchUrl() {
  if (PHOTON_SEARCH_URL) return PHOTON_SEARCH_URL;
  if (!IS_PRODUCTION) return DEFAULT_PUBLIC_PHOTON_SEARCH_URL;
  throw buildProviderError(
    "Photon search URL не настроен. Укажите DELIVERY_ADDRESS_SUGGEST_URL.",
    {
      provider: "photon",
      status: 503,
      code: "address_provider_misconfigured",
      retryable: false,
    },
  );
}

function resolvePhotonReverseUrl() {
  if (PHOTON_REVERSE_URL) return PHOTON_REVERSE_URL;
  if (PHOTON_SEARCH_URL) {
    return PHOTON_SEARCH_URL.replace(/\/api\/?$/, "/reverse");
  }
  if (!IS_PRODUCTION) return DEFAULT_PUBLIC_PHOTON_REVERSE_URL;
  throw buildProviderError(
    "Photon reverse URL не настроен. Укажите DELIVERY_ADDRESS_REVERSE_URL.",
    {
      provider: "photon",
      status: 503,
      code: "address_provider_misconfigured",
      retryable: false,
    },
  );
}

function canUsePublicNominatimFallback() {
  return ADDRESS_PROVIDER === "photon" && ADDRESS_ALLOW_PUBLIC_FALLBACK;
}

function buildProviderAddressId(provider, rawId, fallbackId) {
  const direct = normalizeWhitespace(rawId);
  if (direct) return `${provider}:${direct}`;
  const alt = normalizeWhitespace(fallbackId);
  return alt ? `${provider}:${alt}` : "";
}

function countryAllowed(countryCode) {
  const normalized = String(countryCode || "").toLowerCase().trim();
  if (!normalized) return false;
  if (ADDRESS_COUNTRY_CODES.length === 0) return true;
  return ADDRESS_COUNTRY_CODES.includes(normalized);
}

function buildHumanAddress(parts) {
  return parts.map((part) => normalizeWhitespace(part)).filter(Boolean).join(", ");
}

function parsePhotonFeature(feature) {
  if (!feature || typeof feature !== "object") return null;
  const geometry = sanitizeJsonObject(feature.geometry);
  const coordinates = Array.isArray(geometry.coordinates)
    ? geometry.coordinates
    : [];
  const properties = sanitizeJsonObject(feature.properties);
  const lng = toFiniteNumber(coordinates[0]);
  const lat = toFiniteNumber(coordinates[1]);
  if (lat == null || lng == null) return null;
  const countryCode = String(
    properties.countrycode || properties.country_code || "",
  )
    .toLowerCase()
    .trim();
  if (countryCode && !countryAllowed(countryCode)) return null;
  const structured = {
    country: normalizeWhitespace(properties.country || ""),
    country_code: countryCode,
    region: normalizeWhitespace(properties.state || properties.region || ""),
    area: normalizeWhitespace(
      properties.county || properties.district || properties.state_district || "",
    ),
    city: normalizeWhitespace(
      properties.city ||
        properties.town ||
        properties.locality ||
        properties.village ||
        properties.municipality ||
        "",
    ),
    district: normalizeWhitespace(
      properties.district || properties.suburb || properties.neighbourhood || "",
    ),
    street: normalizeWhitespace(properties.street || ""),
    house: normalizeWhitespace(
      properties.housenumber || properties.house_number || "",
    ),
    postal_code: normalizeWhitespace(properties.postcode || ""),
    name: normalizeWhitespace(properties.name || ""),
    display_name: normalizeWhitespace(
      properties.name && properties.street
        ? buildHumanAddress([
            properties.city || properties.town || properties.locality || "",
            properties.street || "",
            properties.housenumber || properties.house_number || "",
            properties.name || "",
          ])
        : properties.name || "",
    ),
    provider: "photon",
    provider_address_id: buildProviderAddressId(
      "photon",
      `${properties.osm_type || ""}:${properties.osm_id || ""}`,
      feature.id,
    ),
  };
  const label = buildHumanAddress([
    structured.city,
    structured.street,
    structured.house,
    structured.name && structured.name !== structured.street
      ? structured.name
      : "",
  ]);
  return {
    provider: "photon",
    provider_address_id: structured.provider_address_id,
    label: label || structured.display_name || structured.name,
    address_text: label || structured.display_name || structured.name,
    lat,
    lng,
    country_code: countryCode,
    structured_address: structured,
    raw: feature,
  };
}

function parseNominatimItem(item) {
  if (!item || typeof item !== "object") return null;
  const lat = toFiniteNumber(item.lat);
  const lng = toFiniteNumber(item.lon);
  if (lat == null || lng == null) return null;
  const address = sanitizeJsonObject(item.address);
  const countryCode = String(address.country_code || item.country_code || "")
    .toLowerCase()
    .trim();
  if (countryCode && !countryAllowed(countryCode)) return null;
  const structured = {
    country: normalizeWhitespace(address.country || ""),
    country_code: countryCode,
    region: normalizeWhitespace(address.state || address.region || ""),
    area: normalizeWhitespace(
      address.county ||
        address.state_district ||
        address.municipality ||
        address.region ||
        "",
    ),
    city: normalizeWhitespace(
      address.city ||
        address.town ||
        address.village ||
        address.hamlet ||
        address.municipality ||
        "",
    ),
    district: normalizeWhitespace(
      address.suburb || address.neighbourhood || address.quarter || "",
    ),
    street: normalizeWhitespace(
      address.road || address.street || address.pedestrian || "",
    ),
    house: normalizeWhitespace(address.house_number || address.house || ""),
    postal_code: normalizeWhitespace(address.postcode || ""),
    name: normalizeWhitespace(address.amenity || address.shop || address.office || ""),
    display_name: normalizeWhitespace(item.display_name || ""),
    provider: "nominatim",
    provider_address_id: buildProviderAddressId(
      "nominatim",
      `place:${item.place_id || ""}`,
      `${item.osm_type || ""}:${item.osm_id || ""}`,
    ),
  };
  const label = buildHumanAddress([
    structured.city,
    structured.street,
    structured.house,
    structured.name &&
    structured.name !== structured.street &&
    structured.name !== structured.house
      ? structured.name
      : "",
  ]);
  return {
    provider: "nominatim",
    provider_address_id: structured.provider_address_id,
    label: label || structured.display_name,
    address_text: label || structured.display_name,
    lat,
    lng,
    country_code: countryCode,
    structured_address: structured,
    raw: item,
  };
}

function dedupeByProviderId(items) {
  const seen = new Set();
  const result = [];
  for (const item of items) {
    if (!item) continue;
    const key =
      item.provider_address_id ||
      `${item.provider}:${item.lat?.toFixed?.(6) || item.lat}:${item.lng?.toFixed?.(6) || item.lng}:${item.address_text || ""}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(item);
  }
  return result;
}

async function fetchJson(url, { provider, context }) {
  let lastError = null;
  for (let attempt = 0; attempt <= ADDRESS_RETRY_COUNT; attempt += 1) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), ADDRESS_TIMEOUT_MS);
    try {
      const response = await fetch(url, {
        headers: buildHeaders(),
        signal: controller.signal,
      });
      clearTimeout(timeout);
      if (!response.ok) {
        const bodyText = await response.text().catch(() => "");
        const retryable = shouldRetryStatus(response.status);
        const error = buildProviderError(
          response.status === 429
            ? "Сервис адресов временно перегружен. Попробуйте чуть позже."
            : "Сервис адресов вернул ошибку. Попробуйте чуть позже.",
          {
            provider,
            status: retryable ? 503 : 502,
            code:
              response.status === 429
                ? "address_provider_rate_limited"
                : "address_provider_bad_response",
            retryable,
            details: bodyText || null,
          },
        );
        if (retryable && attempt < ADDRESS_RETRY_COUNT) {
          lastError = error;
          await wait(retryDelayMs(attempt));
          continue;
        }
        throw error;
      }
      try {
        return await response.json();
      } catch (error) {
        throw buildProviderError(
          "Сервис адресов вернул некорректный ответ.",
          {
            provider,
            status: 502,
            code: "address_provider_bad_payload",
            retryable: false,
            cause: error,
          },
        );
      }
    } catch (error) {
      clearTimeout(timeout);
      const normalized = normalizeProviderError(error, provider, context);
      if (normalized.retryable && attempt < ADDRESS_RETRY_COUNT) {
        lastError = normalized;
        await wait(retryDelayMs(attempt));
        continue;
      }
      throw normalized;
    }
  }
  throw lastError ||
    buildProviderError("Сервис адресов временно недоступен. Попробуйте чуть позже.", {
      provider,
      status: 503,
      code: "address_provider_unavailable",
      retryable: false,
    });
}

async function suggestViaPhoton(query, options = {}) {
  const endpoint = resolvePhotonSearchUrl();
  const params = new URLSearchParams({
    q: query,
    limit: String(Math.max(1, Math.min(12, Number(options.limit) || 8))),
    lang: "ru",
  });
  const lat = toFiniteNumber(options.lat);
  const lng = toFiniteNumber(options.lng);
  if (lat != null && lng != null) {
    params.set("lat", String(lat));
    params.set("lon", String(lng));
  }
  const payload = await fetchJson(`${endpoint}?${params.toString()}`, {
    provider: "photon",
    context: "suggest",
  });
  const features = Array.isArray(payload?.features) ? payload.features : [];
  return dedupeByProviderId(features.map(parsePhotonFeature).filter(Boolean));
}

async function reverseViaPhoton(lat, lng) {
  const endpoint = resolvePhotonReverseUrl();
  const params = new URLSearchParams({
    lat: String(lat),
    lon: String(lng),
    lang: "ru",
    limit: "1",
  });
  const payload = await fetchJson(`${endpoint}?${params.toString()}`, {
    provider: "photon",
    context: "reverse",
  });
  const features = Array.isArray(payload?.features) ? payload.features : [];
  return features.map(parsePhotonFeature).filter(Boolean)[0] || null;
}

async function suggestViaNominatim(query, options = {}) {
  const params = new URLSearchParams({
    q: query,
    format: "jsonv2",
    addressdetails: "1",
    limit: String(Math.max(1, Math.min(12, Number(options.limit) || 8))),
    countrycodes: ADDRESS_COUNTRY_CODES.join(",") || "ru",
    "accept-language": "ru",
  });
  if (ADDRESS_API_KEY) params.set("apikey", ADDRESS_API_KEY);
  const payload = await fetchJson(`${NOMINATIM_SEARCH_URL}?${params.toString()}`, {
    provider: "nominatim",
    context: "suggest",
  });
  const items = Array.isArray(payload) ? payload : [];
  return dedupeByProviderId(items.map(parseNominatimItem).filter(Boolean));
}

async function reverseViaNominatim(lat, lng) {
  const params = new URLSearchParams({
    lat: String(lat),
    lon: String(lng),
    format: "jsonv2",
    addressdetails: "1",
    "accept-language": "ru",
    zoom: "18",
  });
  if (ADDRESS_API_KEY) params.set("apikey", ADDRESS_API_KEY);
  const payload = await fetchJson(`${NOMINATIM_REVERSE_URL}?${params.toString()}`, {
    provider: "nominatim",
    context: "reverse",
  });
  return parseNominatimItem(payload);
}

async function suggestAddresses(query, options = {}) {
  const normalizedQuery = normalizeWhitespace(query);
  if (normalizedQuery.length < 3) return [];
  if (ADDRESS_PROVIDER === "photon") {
    try {
      return await suggestViaPhoton(normalizedQuery, options);
    } catch (error) {
      if (!canUsePublicNominatimFallback()) {
        throw error;
      }
    }
  }
  return await suggestViaNominatim(normalizedQuery, options);
}

async function geocodeAddressText(query, options = {}) {
  const suggestions = await suggestAddresses(query, {
    ...options,
    limit: 1,
  });
  return suggestions[0] || null;
}

async function reverseGeocodePoint(lat, lng) {
  const safeLat = toFiniteNumber(lat);
  const safeLng = toFiniteNumber(lng);
  if (safeLat == null || safeLng == null) return null;
  if (ADDRESS_PROVIDER === "photon") {
    try {
      const result = await reverseViaPhoton(safeLat, safeLng);
      if (result) return result;
    } catch (error) {
      if (!canUsePublicNominatimFallback()) {
        throw error;
      }
    }
  }
  return await reverseViaNominatim(safeLat, safeLng);
}

function getAddressProviderMeta() {
  return {
    provider: ADDRESS_PROVIDER,
    timeout_ms: ADDRESS_TIMEOUT_MS,
    retry_count: ADDRESS_RETRY_COUNT,
    country_codes: [...ADDRESS_COUNTRY_CODES],
    allow_public_fallback: ADDRESS_ALLOW_PUBLIC_FALLBACK,
    photon_search_configured: Boolean(PHOTON_SEARCH_URL),
    photon_reverse_configured: Boolean(PHOTON_REVERSE_URL || PHOTON_SEARCH_URL),
    nominatim_search_url: NOMINATIM_SEARCH_URL,
    nominatim_reverse_url: NOMINATIM_REVERSE_URL,
  };
}

function distanceMeters(aLat, aLng, bLat, bLng) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const earthRadius = 6371000;
  const dLat = toRad(bLat - aLat);
  const dLng = toRad(bLng - aLng);
  const aa =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(aLat)) *
      Math.cos(toRad(bLat)) *
      Math.sin(dLng / 2) *
      Math.sin(dLng / 2);
  return Math.round(earthRadius * 2 * Math.atan2(Math.sqrt(aa), Math.sqrt(1 - aa)));
}

function normalizeDeliveryZones(rawZones) {
  if (!Array.isArray(rawZones)) return [];
  return rawZones
    .map((zone) => {
      const item = sanitizeJsonObject(zone);
      const center = sanitizeJsonObject(item.center);
      const lat = toFiniteNumber(center.lat);
      const lng = toFiniteNumber(center.lng);
      const radiusMeters = Math.max(
        50,
        Math.round(Number(item.radius_meters || item.radiusMeters || 0) || 0),
      );
      const title = normalizeWhitespace(item.title || item.label || "");
      if (lat == null || lng == null || !title || !Number.isFinite(radiusMeters)) {
        return null;
      }
      return {
        id: normalizeWhitespace(item.id || "") || `${title}:${lat}:${lng}`,
        title,
        is_active: item.is_active !== false,
        center: { lat, lng },
        radius_meters: radiusMeters,
      };
    })
    .filter((zone) => zone && zone.is_active !== false);
}

function evaluateDeliveryZones(lat, lng, rawZones) {
  const zones = normalizeDeliveryZones(rawZones);
  if (zones.length === 0) {
    return {
      zone_status: "unconfigured",
      zone: null,
      distance_to_zone_meters: null,
    };
  }
  let nearestZone = null;
  let nearestDistance = Number.POSITIVE_INFINITY;
  for (const zone of zones) {
    const distance = distanceMeters(lat, lng, zone.center.lat, zone.center.lng);
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestZone = zone;
    }
    if (distance <= zone.radius_meters) {
      return {
        zone_status: "inside",
        zone,
        distance_to_zone_meters: distance,
      };
    }
  }
  return {
    zone_status: "outside",
    zone: nearestZone,
    distance_to_zone_meters: Number.isFinite(nearestDistance)
      ? nearestDistance
      : null,
  };
}

function mergeStructuredAddress(...values) {
  const result = {};
  for (const raw of values) {
    const item = sanitizeJsonObject(raw);
    for (const [key, value] of Object.entries(item)) {
      if (value == null) continue;
      if (typeof value === "string") {
        const normalized = normalizeWhitespace(value);
        if (!normalized) continue;
        result[key] = normalized;
        continue;
      }
      result[key] = value;
    }
  }
  return result;
}

function inferConfidence(structuredAddress, hasPoint) {
  const street = normalizeWhitespace(structuredAddress.street || "");
  const house = normalizeWhitespace(structuredAddress.house || "");
  const city = normalizeWhitespace(structuredAddress.city || "");
  if (hasPoint && street && house) return "high";
  if (hasPoint && (street || city)) return "medium";
  if (street && house) return "medium";
  if (street || city) return "low";
  return "low";
}

function buildValidationSummary(action, zoneStatus, mismatchDistanceMeters) {
  if (action === "fix") {
    if (zoneStatus === "outside") {
      return "Точка находится вне зоны доставки. Уточните адрес или выберите другую точку.";
    }
    return "Адрес нужно уточнить, чтобы доставка поняла точную точку.";
  }
  if (action === "confirm") {
    if (Number.isFinite(mismatchDistanceMeters) && mismatchDistanceMeters > 0) {
      return `Текст адреса и точка на карте расходятся примерно на ${mismatchDistanceMeters} м. Подтвердите, что выбрана верная точка.`;
    }
    return "Проверьте адрес и точку на карте перед сохранением.";
  }
  return "Адрес подтвержден.";
}

async function validateAddressSelection({
  addressText,
  lat,
  lng,
  zones,
  structuredAddress,
  provider,
  providerAddressId,
}) {
  const normalizedText = normalizeWhitespace(addressText);
  const safeLat = toFiniteNumber(lat);
  const safeLng = toFiniteNumber(lng);
  const hasPoint = safeLat != null && safeLng != null;
  const textCandidate = normalizedText
    ? await geocodeAddressText(normalizedText, { limit: 1 })
    : null;
  const pointCandidate = hasPoint ? await reverseGeocodePoint(safeLat, safeLng) : null;
  const effectiveLat = hasPoint ? safeLat : toFiniteNumber(textCandidate?.lat);
  const effectiveLng = hasPoint ? safeLng : toFiniteNumber(textCandidate?.lng);
  const effectiveStructured = mergeStructuredAddress(
    textCandidate?.structured_address,
    pointCandidate?.structured_address,
    structuredAddress,
    {
      full_text: normalizedText,
    },
  );
  const effectiveProvider =
    normalizeWhitespace(provider) ||
    pointCandidate?.provider ||
    textCandidate?.provider ||
    null;
  const effectiveProviderAddressId =
    normalizeWhitespace(providerAddressId) ||
    pointCandidate?.provider_address_id ||
    textCandidate?.provider_address_id ||
    null;

  if (effectiveLat == null || effectiveLng == null) {
    return {
      action: "fix",
      summary: "Не удалось определить точку адреса. Выберите адрес из подсказок или отметьте место на карте.",
      lat: null,
      lng: null,
      structured_address: effectiveStructured,
      provider: effectiveProvider,
      provider_address_id: effectiveProviderAddressId,
      validation_confidence: inferConfidence(effectiveStructured, false),
      mismatch_distance_meters: null,
      zone_status: "unchecked",
      delivery_zone_id: null,
      delivery_zone_label: null,
      resolved_address_text: normalizedText,
      point_source: hasPoint ? "map" : "text",
    };
  }

  const zoneCheck = evaluateDeliveryZones(effectiveLat, effectiveLng, zones);
  const mismatchDistance =
    hasPoint &&
    textCandidate &&
    Number.isFinite(textCandidate.lat) &&
    Number.isFinite(textCandidate.lng)
      ? distanceMeters(effectiveLat, effectiveLng, textCandidate.lat, textCandidate.lng)
      : null;
  let action = "accept";
  if (zoneCheck.zone_status === "outside") {
    action = "fix";
  } else if (mismatchDistance != null && mismatchDistance >= 250) {
    action = mismatchDistance >= 1500 ? "fix" : "confirm";
  }

  const resolvedAddressText =
    normalizeWhitespace(
      pointCandidate?.address_text ||
        textCandidate?.address_text ||
        normalizedText,
    ) || normalizedText;

  return {
    action,
    summary: buildValidationSummary(action, zoneCheck.zone_status, mismatchDistance),
    lat: effectiveLat,
    lng: effectiveLng,
    structured_address: effectiveStructured,
    provider: effectiveProvider,
    provider_address_id: effectiveProviderAddressId,
    validation_confidence: inferConfidence(effectiveStructured, hasPoint),
    mismatch_distance_meters: mismatchDistance,
    zone_status: zoneCheck.zone_status,
    delivery_zone_id: zoneCheck.zone?.id || null,
    delivery_zone_label: zoneCheck.zone?.title || null,
    resolved_address_text: resolvedAddressText,
    point_source: hasPoint ? "map" : textCandidate ? "suggest" : "text",
  };
}

module.exports = {
  ADDRESS_PROVIDER,
  AddressProviderError,
  isAddressProviderError,
  normalizeWhitespace,
  suggestAddresses,
  geocodeAddressText,
  reverseGeocodePoint,
  validateAddressSelection,
  normalizeDeliveryZones,
  evaluateDeliveryZones,
  distanceMeters,
  getAddressProviderMeta,
};
