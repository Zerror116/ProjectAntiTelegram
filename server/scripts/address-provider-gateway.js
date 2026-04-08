#!/usr/bin/env node

/* eslint-disable no-console */

const fs = require("fs");
const path = require("path");
const express = require("express");
const dotenv = require("dotenv");

const serverRoot = path.resolve(__dirname, "..");
dotenv.config({ path: path.join(serverRoot, ".env") });
const localEnvPath = path.join(serverRoot, ".env.local");
if (fs.existsSync(localEnvPath)) {
  dotenv.config({ path: localEnvPath, override: true });
}

const app = express();

const PORT = Math.max(
  1,
  Math.min(65535, Number(process.env.ADDRESS_GATEWAY_PORT || 3011) || 3011),
);
const BIND_HOST = String(process.env.ADDRESS_GATEWAY_HOST || "127.0.0.1").trim() || "127.0.0.1";
const UPSTREAM_SEARCH_URL = String(
  process.env.ADDRESS_GATEWAY_UPSTREAM_SEARCH_URL ||
    "https://nominatim.openstreetmap.org/search",
).trim();
const UPSTREAM_REVERSE_URL = String(
  process.env.ADDRESS_GATEWAY_UPSTREAM_REVERSE_URL ||
    "https://nominatim.openstreetmap.org/reverse",
).trim();
const USER_AGENT = String(
  process.env.ADDRESS_GATEWAY_USER_AGENT ||
    "ProjectPhoenix/1.0 (self-hosted-address-gateway)",
).trim();
const COUNTRY_CODES = String(
  process.env.ADDRESS_GATEWAY_COUNTRY_CODES || "ru",
)
  .split(",")
  .map((item) => item.trim().toLowerCase())
  .filter(Boolean);
const TIMEOUT_MS = Math.max(
  800,
  Math.min(
    12000,
    Number(process.env.ADDRESS_GATEWAY_TIMEOUT_MS || 3200) || 3200,
  ),
);
const RETRY_COUNT = Math.max(
  0,
  Math.min(
    2,
    Math.round(Number(process.env.ADDRESS_GATEWAY_RETRY_COUNT || 1) || 1),
  ),
);
const CACHE_TTL_MS = Math.max(
  10 * 1000,
  Math.min(
    30 * 60 * 1000,
    Number(process.env.ADDRESS_GATEWAY_CACHE_TTL_MS || 5 * 60 * 1000) ||
      5 * 60 * 1000,
  ),
);

const cache = new Map();

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

function buildHeaders() {
  const headers = {
    Accept: "application/json",
  };
  if (USER_AGENT) {
    headers["User-Agent"] = USER_AGENT;
  }
  return headers;
}

function cacheKey(prefix, params) {
  return `${prefix}:${JSON.stringify(params)}`;
}

function getCached(key) {
  const entry = cache.get(key);
  if (!entry) return null;
  if (entry.expiresAt <= Date.now()) {
    cache.delete(key);
    return null;
  }
  return entry.payload;
}

function setCached(key, payload) {
  cache.set(key, {
    payload,
    expiresAt: Date.now() + CACHE_TTL_MS,
  });
}

function shouldRetryStatus(status) {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

function retryDelayMs(attempt) {
  return Math.min(1200, 180 * (attempt + 1));
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function fetchJson(url) {
  let lastError = null;
  for (let attempt = 0; attempt <= RETRY_COUNT; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
    try {
      const response = await fetch(url, {
        headers: buildHeaders(),
        signal: controller.signal,
      });
      clearTimeout(timer);
      if (!response.ok) {
        const body = await response.text().catch(() => "");
        const error = new Error(`Upstream address provider error: ${response.status}`);
        error.status = response.status;
        error.body = body || "";
        if (shouldRetryStatus(response.status) && attempt < RETRY_COUNT) {
          lastError = error;
          await wait(retryDelayMs(attempt));
          continue;
        }
        throw error;
      }
      return await response.json();
    } catch (error) {
      clearTimeout(timer);
      const normalized =
        error?.name === "AbortError"
          ? Object.assign(new Error("Upstream address provider timeout"), {
              status: 503,
            })
          : error;
      if (attempt < RETRY_COUNT) {
        lastError = normalized;
        await wait(retryDelayMs(attempt));
        continue;
      }
      throw normalized;
    }
  }
  throw lastError || new Error("Upstream address provider unavailable");
}

function countryAllowed(countryCode) {
  const normalized = String(countryCode || "").trim().toLowerCase();
  if (!normalized) return false;
  if (COUNTRY_CODES.length === 0) return true;
  return COUNTRY_CODES.includes(normalized);
}

function buildPhotonFeatureFromNominatim(item) {
  if (!item || typeof item !== "object") return null;
  const lat = toFiniteNumber(item.lat);
  const lng = toFiniteNumber(item.lon);
  if (lat == null || lng == null) return null;
  const address = sanitizeJsonObject(item.address);
  const countryCode = String(address.country_code || item.country_code || "")
    .toLowerCase()
    .trim();
  if (countryCode && !countryAllowed(countryCode)) return null;

  return {
    type: "Feature",
    id:
      normalizeWhitespace(`nominatim:place:${item.place_id || ""}`) ||
      normalizeWhitespace(`nominatim:${item.osm_type || ""}:${item.osm_id || ""}`),
    geometry: {
      type: "Point",
      coordinates: [lng, lat],
    },
    properties: {
      name: normalizeWhitespace(
        address.amenity || address.shop || address.office || item.name || "",
      ),
      country: normalizeWhitespace(address.country || ""),
      countrycode: countryCode,
      state: normalizeWhitespace(address.state || address.region || ""),
      county: normalizeWhitespace(
        address.county ||
          address.state_district ||
          address.municipality ||
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
      housenumber: normalizeWhitespace(
        address.house_number || address.house || "",
      ),
      postcode: normalizeWhitespace(address.postcode || ""),
      osm_type: String(item.osm_type || "").trim(),
      osm_id: String(item.osm_id || "").trim(),
      extent: null,
    },
  };
}

async function searchAddress(q, { limit }) {
  const key = cacheKey("search", { q, limit, countries: COUNTRY_CODES });
  const cached = getCached(key);
  if (cached) return cached;
  const params = new URLSearchParams({
    q,
    format: "jsonv2",
    addressdetails: "1",
    limit: String(limit),
    countrycodes: COUNTRY_CODES.join(",") || "ru",
    "accept-language": "ru",
  });
  const payload = await fetchJson(`${UPSTREAM_SEARCH_URL}?${params.toString()}`);
  const list = Array.isArray(payload) ? payload : [];
  const result = {
    type: "FeatureCollection",
    features: list.map(buildPhotonFeatureFromNominatim).filter(Boolean),
  };
  setCached(key, result);
  return result;
}

async function reverseAddress(lat, lon) {
  const key = cacheKey("reverse", {
    lat: Number(lat).toFixed(6),
    lon: Number(lon).toFixed(6),
    countries: COUNTRY_CODES,
  });
  const cached = getCached(key);
  if (cached) return cached;
  const params = new URLSearchParams({
    lat: String(lat),
    lon: String(lon),
    format: "jsonv2",
    addressdetails: "1",
    "accept-language": "ru",
    zoom: "18",
  });
  const payload = await fetchJson(`${UPSTREAM_REVERSE_URL}?${params.toString()}`);
  const feature = buildPhotonFeatureFromNominatim(payload);
  const result = {
    type: "FeatureCollection",
    features: feature ? [feature] : [],
  };
  setCached(key, result);
  return result;
}

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    service: "address-provider-gateway",
    provider: "photon-compatible",
    upstream: "nominatim",
    country_codes: COUNTRY_CODES,
    cache_ttl_ms: CACHE_TTL_MS,
  });
});

app.get("/api", async (req, res) => {
  const query = normalizeWhitespace(req.query?.q || "");
  const limit = Math.max(1, Math.min(10, Number(req.query?.limit) || 6));
  if (query.length < 3) {
    return res.json({ type: "FeatureCollection", features: [] });
  }
  try {
    const payload = await searchAddress(query, { limit });
    return res.json(payload);
  } catch (error) {
    console.error("address-gateway.search error", error);
    return res.status(503).json({
      error: "address_provider_unavailable",
      message: "Адресный поиск временно недоступен",
    });
  }
});

app.get("/reverse", async (req, res) => {
  const lat = toFiniteNumber(req.query?.lat);
  const lon = toFiniteNumber(req.query?.lon);
  if (lat == null || lon == null) {
    return res.status(400).json({
      error: "bad_request",
      message: "lat и lon обязательны",
    });
  }
  try {
    const payload = await reverseAddress(lat, lon);
    return res.json(payload);
  } catch (error) {
    console.error("address-gateway.reverse error", error);
    return res.status(503).json({
      error: "address_provider_unavailable",
      message: "Распознавание точки временно недоступно",
    });
  }
});

app.listen(PORT, BIND_HOST, () => {
  console.log(
    `Address gateway listening on http://${BIND_HOST}:${PORT} (Photon-compatible, upstream Nominatim)`,
  );
});
