#!/usr/bin/env node

/* eslint-disable no-console */

const path = require("path");
const { spawnSync } = require("child_process");
const fs = require("fs");

const dotenv = require("dotenv");
const serverRoot = path.resolve(__dirname, "..");
dotenv.config({ path: path.join(serverRoot, ".env") });
const localEnvPath = path.join(serverRoot, ".env.local");
if (fs.existsSync(localEnvPath)) {
  dotenv.config({ path: localEnvPath, override: true });
}

const {
  suggestAddresses,
  reverseGeocodePoint,
  validateAddressSelection,
  getAddressProviderMeta,
  isAddressProviderError,
} = require("../src/utils/deliveryAddressing");

const QUERY = String(
  process.env.ADDRESS_SMOKE_QUERY || "Самара, Ново-Садовая улица, 106",
)
  .trim();
const LAT = Number(process.env.ADDRESS_SMOKE_LAT || 53.2171681);
const LNG = Number(process.env.ADDRESS_SMOKE_LNG || 50.1489919);
const SHOULD_SIMULATE_UNAVAILABLE =
  process.argv.includes("--simulate-unavailable") ||
  ["1", "true", "yes"].includes(
    String(process.env.ADDRESS_SMOKE_TEST_UNAVAILABLE || "")
      .toLowerCase()
      .trim(),
  );

function fail(message, details = null) {
  console.error(`ADDRESS_SMOKE_FAIL: ${message}`);
  if (details) {
    console.error(
      typeof details === "string" ? details : JSON.stringify(details, null, 2),
    );
  }
  process.exit(1);
}

function pass(label, payload) {
  console.log(
    `ADDRESS_SMOKE_OK: ${label}${
      payload ? ` -> ${JSON.stringify(payload)}` : ""
    }`,
  );
}

function assertFiniteLatLng(item, label) {
  if (
    !item ||
    !Number.isFinite(Number(item.lat)) ||
    !Number.isFinite(Number(item.lng))
  ) {
    fail(`${label}: ожидаются валидные lat/lng`, item);
  }
}

function runUnavailableSimulation() {
  const repoServerRoot = path.resolve(__dirname, "..");
  const childSource = `
    require('dotenv').config();
    const { suggestAddresses, isAddressProviderError } = require('./src/utils/deliveryAddressing');
    suggestAddresses('Самара, Ново-Садовая улица, 106', { limit: 1 })
      .then((items) => {
        console.error('EXPECTED_PROVIDER_FAILURE_BUT_GOT_RESULT', JSON.stringify(items));
        process.exit(2);
      })
      .catch((err) => {
        if (isAddressProviderError(err)) {
          console.log(JSON.stringify({
            ok: true,
            code: err.code,
            status: err.status,
            provider: err.provider,
          }));
          process.exit(0);
        }
        console.error(err && err.stack ? err.stack : String(err));
        process.exit(1);
      });
  `;
  const childEnv = {
    ...process.env,
    DELIVERY_ADDRESS_PROVIDER: "photon",
    DELIVERY_ADDRESS_SUGGEST_URL: "http://127.0.0.1:9/api",
    DELIVERY_ADDRESS_REVERSE_URL: "http://127.0.0.1:9/reverse",
    DELIVERY_ADDRESS_ALLOW_PUBLIC_FALLBACK: "false",
    DELIVERY_ADDRESS_TIMEOUT_MS: "900",
    DELIVERY_ADDRESS_RETRY_COUNT: "0",
  };
  const result = spawnSync(process.execPath, ["-e", childSource], {
    cwd: repoServerRoot,
    env: childEnv,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    fail("simulate-unavailable: controlled provider failure not received", {
      status: result.status,
      stdout: result.stdout,
      stderr: result.stderr,
    });
  }
  const output = String(result.stdout || "").trim();
  pass("provider_unavailable", output ? JSON.parse(output) : null);
}

async function main() {
  if (!QUERY || !Number.isFinite(LAT) || !Number.isFinite(LNG)) {
    fail("ADDRESS_SMOKE_QUERY / LAT / LNG заданы некорректно");
  }

  pass("meta", getAddressProviderMeta());

  const suggestions = await suggestAddresses(QUERY, {
    limit: 3,
    lat: LAT,
    lng: LNG,
  });
  if (!Array.isArray(suggestions) || suggestions.length === 0) {
    fail("suggest: провайдер не вернул ни одной подсказки", { query: QUERY });
  }
  assertFiniteLatLng(suggestions[0], "suggest");
  pass("suggest", {
    count: suggestions.length,
    top_label: suggestions[0].label || suggestions[0].address_text || "",
    provider: suggestions[0].provider || null,
  });

  const reverse = await reverseGeocodePoint(LAT, LNG);
  if (!reverse) {
    fail("reverse: не удалось распознать точку", { lat: LAT, lng: LNG });
  }
  assertFiniteLatLng(reverse, "reverse");
  pass("reverse", {
    label: reverse.label || reverse.address_text || "",
    provider: reverse.provider || null,
  });

  const validation = await validateAddressSelection({
    addressText: QUERY,
    lat: LAT,
    lng: LNG,
    zones: [],
  });
  if (!validation || !["accept", "confirm", "fix"].includes(validation.action)) {
    fail("validate: получен неожиданный результат", validation);
  }
  pass("validate", {
    action: validation.action,
    provider: validation.provider || null,
    zone_status: validation.zone_status || null,
    mismatch_distance_meters: validation.mismatch_distance_meters ?? null,
  });

  if (SHOULD_SIMULATE_UNAVAILABLE) {
    runUnavailableSimulation();
  }
}

main().catch((error) => {
  if (isAddressProviderError(error)) {
    fail("provider_error", {
      message: error.message,
      code: error.code,
      status: error.status,
      provider: error.provider,
    });
  }
  fail("unexpected_error", error && error.stack ? error.stack : String(error));
});
