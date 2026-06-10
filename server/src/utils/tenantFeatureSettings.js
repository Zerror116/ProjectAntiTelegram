const db = require("../db");

const DEFAULT_TENANT_FEATURE_SETTINGS = Object.freeze({
  custom_workflows_enabled: false,
  publication_interval_ms: 2000,
  manual_shelf_enabled: false,
  pickup_only_enabled: false,
  cart_delivery_ready_enabled: false,
  cart_delivery_ready_min_amount: 1500,
  cart_retention_days: 30,
  revision_delete_approval_enabled: false,
  defect_stats_enabled: false,
  auto_publish_enabled: false,
  auto_publish_delay_minutes: 5,
  shelf_field_label: "Полка",
  floor_field_label: "Этаж",
  group_rules_text: "",
});

const DEFAULT_TENANT_WORKFLOW_SETTINGS = Object.freeze({
  version: 1,
  product_processing: Object.freeze({
    mode: "manual",
    auto_delay_minutes: 60,
  }),
  delivery: Object.freeze({
    mode: "classic",
    client_ready_button: false,
    min_amount: 1500,
    cart_retention_days: 30,
    snapshot_on_admin_approve: false,
  }),
  worker: Object.freeze({
    manual_shelf_enabled: false,
    pickup_only_enabled: false,
    revision_delete_approval_enabled: false,
    shelf_field_label: "Полка",
    floor_field_label: "Этаж",
  }),
  channels: Object.freeze({
    publication_interval_ms: 2000,
    auto_publish_enabled: false,
    auto_publish_delay_minutes: 5,
  }),
  registration: Object.freeze({
    client_city_options: Object.freeze([]),
  }),
  analytics: Object.freeze({
    defect_stats_enabled: false,
  }),
  rules: Object.freeze({
    group_rules_text: "",
  }),
});

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function parseBoolean(value, fallback = false) {
  if (typeof value === "boolean") return value;
  const normalized = String(value ?? "").toLowerCase().trim();
  if (["1", "true", "yes", "on", "y", "да"].includes(normalized)) return true;
  if (["0", "false", "no", "off", "n", "нет"].includes(normalized)) return false;
  return fallback;
}

function clampNumber(value, min, max, fallback) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

function normalizeText(value, maxLength = 120) {
  return String(value ?? "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxLength);
}

function normalizeStringList(value, { maxItems = 80, maxLength = 80 } = {}) {
  const input = Array.isArray(value)
    ? value
    : String(value ?? "")
        .split(/\r?\n|,/)
        .map((item) => item.trim());
  const result = [];
  const seen = new Set();
  for (const raw of input) {
    const normalized = normalizeText(raw, maxLength);
    if (!normalized) continue;
    const key = normalized.toLocaleLowerCase("ru-RU");
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(normalized);
    if (result.length >= maxItems) break;
  }
  return result;
}

function oneOf(value, allowed, fallback) {
  const normalized = String(value ?? "")
    .toLowerCase()
    .trim();
  return allowed.includes(normalized) ? normalized : fallback;
}

function sectionOf(source, key) {
  const value = source[key];
  return isPlainObject(value) ? value : {};
}

function normalizeTenantFeatureSettings(raw = {}) {
  const source = isPlainObject(raw) ? raw : {};
  const enabled = parseBoolean(
    source.custom_workflows_enabled,
    DEFAULT_TENANT_FEATURE_SETTINGS.custom_workflows_enabled,
  );
  const productProcessingSource = sectionOf(source, "product_processing");
  const deliverySource = sectionOf(source, "delivery");
  const workerSource = sectionOf(source, "worker");
  const channelsSource = sectionOf(source, "channels");
  const registrationSource = sectionOf(source, "registration");
  const analyticsSource = sectionOf(source, "analytics");
  const rulesSource = sectionOf(source, "rules");

  const publicationIntervalMs = Math.round(
    clampNumber(
      channelsSource.publication_interval_ms ?? source.publication_interval_ms,
      500,
      10 * 60 * 1000,
      DEFAULT_TENANT_FEATURE_SETTINGS.publication_interval_ms,
    ),
  );
  const manualShelfEnabled = parseBoolean(
    workerSource.manual_shelf_enabled ?? source.manual_shelf_enabled,
    enabled,
  );
  const pickupOnlyEnabled = parseBoolean(
    workerSource.pickup_only_enabled ?? source.pickup_only_enabled,
    enabled,
  );
  const cartDeliveryReadyEnabled = parseBoolean(
    deliverySource.client_ready_button ?? source.cart_delivery_ready_enabled,
    enabled,
  );
  const cartDeliveryReadyMinAmount = clampNumber(
    deliverySource.min_amount ?? source.cart_delivery_ready_min_amount,
    0,
    10_000_000,
    DEFAULT_TENANT_FEATURE_SETTINGS.cart_delivery_ready_min_amount,
  );
  const cartRetentionDays = Math.round(
    clampNumber(
      deliverySource.cart_retention_days ?? source.cart_retention_days,
      1,
      365,
      DEFAULT_TENANT_FEATURE_SETTINGS.cart_retention_days,
    ),
  );
  const revisionDeleteApprovalEnabled = parseBoolean(
    workerSource.revision_delete_approval_enabled ??
      source.revision_delete_approval_enabled,
    enabled,
  );
  const defectStatsEnabled = parseBoolean(
    analyticsSource.defect_stats_enabled ?? source.defect_stats_enabled,
    enabled,
  );
  const productProcessingMode = oneOf(
    productProcessingSource.mode ?? source.product_processing_mode,
    ["manual", "auto_after_delay"],
    DEFAULT_TENANT_WORKFLOW_SETTINGS.product_processing.mode,
  );
  const autoDelayMinutes = Math.round(
    clampNumber(
      productProcessingSource.auto_delay_minutes ??
        source.auto_product_processing_delay_minutes,
      1,
      24 * 60,
      DEFAULT_TENANT_WORKFLOW_SETTINGS.product_processing.auto_delay_minutes,
    ),
  );
  const deliveryMode = oneOf(
    deliverySource.mode ?? source.delivery_mode,
    ["classic", "snapshot_after_admin_approve", "off"],
    DEFAULT_TENANT_WORKFLOW_SETTINGS.delivery.mode,
  );
  const snapshotOnAdminApprove = parseBoolean(
    deliverySource.snapshot_on_admin_approve ??
      source.delivery_snapshot_on_admin_approve,
    deliveryMode === "snapshot_after_admin_approve",
  );
  const clientCityOptions = normalizeStringList(
    registrationSource.client_city_options ?? source.client_city_options,
  );
  const autoPublishEnabled = parseBoolean(
    channelsSource.auto_publish_enabled ?? source.auto_publish_enabled,
    DEFAULT_TENANT_FEATURE_SETTINGS.auto_publish_enabled,
  );
  const autoPublishDelayMinutes = Math.round(
    clampNumber(
      channelsSource.auto_publish_delay_minutes ??
        source.auto_publish_delay_minutes,
      1,
      24 * 60,
      DEFAULT_TENANT_FEATURE_SETTINGS.auto_publish_delay_minutes,
    ),
  );
  const shelfFieldLabel =
    normalizeText(
      workerSource.shelf_field_label ?? source.shelf_field_label,
      40,
    ) || DEFAULT_TENANT_FEATURE_SETTINGS.shelf_field_label;
  const floorFieldLabel =
    normalizeText(
      workerSource.floor_field_label ?? source.floor_field_label,
      40,
    ) || DEFAULT_TENANT_FEATURE_SETTINGS.floor_field_label;
  const groupRulesText = String(
    rulesSource.group_rules_text ?? source.group_rules_text ?? "",
  )
    .replace(/\r\n/g, "\n")
    .trim()
    .slice(0, 12000);
  const customWorkflowsEnabled =
    parseBoolean(source.custom_workflows_enabled, false) ||
    productProcessingMode !==
      DEFAULT_TENANT_WORKFLOW_SETTINGS.product_processing.mode ||
    publicationIntervalMs !==
      DEFAULT_TENANT_FEATURE_SETTINGS.publication_interval_ms ||
    manualShelfEnabled === true ||
    pickupOnlyEnabled === true ||
    cartDeliveryReadyEnabled === true ||
    cartRetentionDays !== DEFAULT_TENANT_FEATURE_SETTINGS.cart_retention_days ||
    revisionDeleteApprovalEnabled === true ||
    defectStatsEnabled === true ||
    clientCityOptions.length > 0 ||
    autoPublishEnabled === true ||
    autoPublishDelayMinutes !==
      DEFAULT_TENANT_FEATURE_SETTINGS.auto_publish_delay_minutes ||
    shelfFieldLabel !== DEFAULT_TENANT_FEATURE_SETTINGS.shelf_field_label ||
    floorFieldLabel !== DEFAULT_TENANT_FEATURE_SETTINGS.floor_field_label ||
    groupRulesText.length > 0;

  return {
    version: 1,
    product_processing: {
      mode: productProcessingMode,
      auto_delay_minutes: autoDelayMinutes,
    },
    delivery: {
      mode: deliveryMode,
      client_ready_button: cartDeliveryReadyEnabled,
      min_amount: cartDeliveryReadyMinAmount,
      cart_retention_days: cartRetentionDays,
      snapshot_on_admin_approve: snapshotOnAdminApprove,
    },
    worker: {
      manual_shelf_enabled: manualShelfEnabled,
      pickup_only_enabled: pickupOnlyEnabled,
      revision_delete_approval_enabled: revisionDeleteApprovalEnabled,
      shelf_field_label: shelfFieldLabel,
      floor_field_label: floorFieldLabel,
    },
    channels: {
      publication_interval_ms: publicationIntervalMs,
      auto_publish_enabled: autoPublishEnabled,
      auto_publish_delay_minutes: autoPublishDelayMinutes,
    },
    registration: {
      client_city_options: clientCityOptions,
    },
    analytics: {
      defect_stats_enabled: defectStatsEnabled,
    },
    rules: {
      group_rules_text: groupRulesText,
    },
    ...DEFAULT_TENANT_FEATURE_SETTINGS,
    custom_workflows_enabled: customWorkflowsEnabled,
    publication_interval_ms: publicationIntervalMs,
    manual_shelf_enabled: manualShelfEnabled,
    pickup_only_enabled: pickupOnlyEnabled,
    cart_delivery_ready_enabled: cartDeliveryReadyEnabled,
    cart_delivery_ready_min_amount: cartDeliveryReadyMinAmount,
    cart_retention_days: cartRetentionDays,
    revision_delete_approval_enabled: revisionDeleteApprovalEnabled,
    defect_stats_enabled: defectStatsEnabled,
    client_city_options: clientCityOptions,
    auto_publish_enabled: autoPublishEnabled,
    auto_publish_delay_minutes: autoPublishDelayMinutes,
    shelf_field_label: shelfFieldLabel,
    floor_field_label: floorFieldLabel,
    group_rules_text: groupRulesText,
    product_processing_mode: productProcessingMode,
    auto_product_processing_enabled:
      productProcessingMode === "auto_after_delay",
    auto_product_processing_delay_minutes: autoDelayMinutes,
    delivery_mode: deliveryMode,
    delivery_snapshot_on_admin_approve: snapshotOnAdminApprove,
  };
}

function normalizeTenantFeaturePatch(raw = {}) {
  return normalizeTenantFeatureSettings(raw);
}

function mergePlainObjects(base, patch) {
  const result = { ...(isPlainObject(base) ? base : {}) };
  const source = isPlainObject(patch) ? patch : {};
  for (const [key, value] of Object.entries(source)) {
    if (isPlainObject(value) && isPlainObject(result[key])) {
      result[key] = mergePlainObjects(result[key], value);
    } else {
      result[key] = value;
    }
  }
  return result;
}

async function getTenantFeatureSettings(tenantId) {
  const normalizedTenantId = String(tenantId || "").trim();
  if (!normalizedTenantId) {
    return normalizeTenantFeatureSettings();
  }
  const q = await db.platformQuery(
    `SELECT settings
     FROM tenant_feature_settings
     WHERE tenant_id = $1::uuid
     LIMIT 1`,
    [normalizedTenantId],
  );
  return normalizeTenantFeatureSettings(q.rows[0]?.settings || {});
}

async function patchTenantFeatureSettings(tenantId, rawPatch) {
  const normalizedTenantId = String(tenantId || "").trim();
  if (!normalizedTenantId) {
    throw new Error("tenant_id is required");
  }
  const current = await getTenantFeatureSettings(normalizedTenantId);
  const next = normalizeTenantFeatureSettings(
    mergePlainObjects(current, rawPatch),
  );
  const q = await db.platformQuery(
    `INSERT INTO tenant_feature_settings (tenant_id, settings, created_at, updated_at)
     VALUES ($1::uuid, $2::jsonb, now(), now())
     ON CONFLICT (tenant_id)
     DO UPDATE SET settings = EXCLUDED.settings,
                   updated_at = now()
     RETURNING settings`,
    [normalizedTenantId, JSON.stringify(next)],
  );
  return normalizeTenantFeatureSettings(q.rows[0]?.settings || next);
}

function normalizeInviteSettings(raw = {}) {
  const source = isPlainObject(raw) ? raw : {};
  return {
    client_city_options: normalizeStringList(source.client_city_options),
  };
}

function getInviteClientCityOptions(inviteRow) {
  return normalizeInviteSettings(inviteRow?.settings || {}).client_city_options;
}

module.exports = {
  DEFAULT_TENANT_FEATURE_SETTINGS,
  DEFAULT_TENANT_WORKFLOW_SETTINGS,
  getInviteClientCityOptions,
  getTenantFeatureSettings,
  normalizeInviteSettings,
  normalizeStringList,
  normalizeTenantFeaturePatch,
  normalizeTenantFeatureSettings,
  patchTenantFeatureSettings,
};
