#!/usr/bin/env node

const assert = require("assert/strict");
const fs = require("fs");
const path = require("path");

const {
  normalizeTenantFeatureSettings,
} = require("../src/utils/tenantFeatureSettings");
const {
  buildTenantProcessingScopes,
  rotateTenantProcessingScopes,
  scopeLabel,
} = require("../src/utils/tenantProcessingScopes");

function listFilesRecursive(root) {
  const files = [];
  if (!fs.existsSync(root)) return files;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "node_modules" || entry.name === ".dart_tool") continue;
      files.push(...listFilesRecursive(fullPath));
      continue;
    }
    if (entry.isFile()) files.push(fullPath);
  }
  return files;
}

function testDefaults() {
  const settings = normalizeTenantFeatureSettings();
  assert.equal(settings.client_group_switcher_enabled, true);
  assert.equal(settings.qr_existing_client_join_enabled, true);
  assert.equal(settings.dangerous_action_audit_enabled, true);
  assert.equal(settings.product_change_history_enabled, false);
  assert.equal(settings.client_cancel_anytime_enabled, true);
  assert.equal(settings.delivery.client_cancel_anytime_enabled, true);
  assert.equal(settings.worker_delivery_assembly_enabled, false);
  assert.equal(settings.worker.delivery_assembly_enabled, false);
  assert.equal(settings.phone_access_approval_enabled, false);
  assert.equal(settings.client.phone_access_approval_enabled, false);
  assert.equal(settings.creator_notification_diagnostics_enabled, true);
  assert.equal(settings.creator_bootstrap_monitoring_enabled, true);
  assert.deepEqual(settings.client_city_options, []);
}

function testCityListPersistence() {
  const settings = normalizeTenantFeatureSettings({
    registration: {
      client_city_options: ["Город A", "Город B", " город a "],
    },
  });
  assert.deepEqual(settings.client_city_options, ["Город A", "Город B"]);
  assert.deepEqual(settings.registration.client_city_options, [
    "Город A",
    "Город B",
  ]);
  assert.equal(settings.custom_workflows_enabled, true);
}

function testTopLevelAndNestedFlags() {
  const settings = normalizeTenantFeatureSettings({
    client_group_switcher_enabled: false,
    qr_existing_client_join_enabled: "0",
    phone_access_approval_enabled: "да",
    tenant_console: {
      operations_menu_enabled: "yes",
      product_change_history_enabled: true,
    },
    worker: {
      delivery_assembly_enabled: "on",
    },
    delivery: {
      client_cancel_anytime_enabled: "да",
    },
    dangerous_action_audit_enabled: "нет",
    diagnostics: {
      notification_diagnostics_enabled: false,
      bootstrap_monitoring_enabled: "off",
    },
  });
  assert.equal(settings.client_group_switcher_enabled, false);
  assert.equal(settings.client.group_switcher_enabled, false);
  assert.equal(settings.qr_existing_client_join_enabled, false);
  assert.equal(settings.client.qr_existing_client_join_enabled, false);
  assert.equal(settings.phone_access_approval_enabled, true);
  assert.equal(settings.client.phone_access_approval_enabled, true);
  assert.equal(settings.tenant_operations_menu_enabled, true);
  assert.equal(settings.tenant_console.operations_menu_enabled, true);
  assert.equal(settings.dangerous_action_audit_enabled, false);
  assert.equal(settings.tenant_console.dangerous_action_audit_enabled, false);
  assert.equal(settings.product_change_history_enabled, true);
  assert.equal(settings.tenant_console.product_change_history_enabled, true);
  assert.equal(settings.client_cancel_anytime_enabled, true);
  assert.equal(settings.delivery.client_cancel_anytime_enabled, true);
  assert.equal(settings.worker_delivery_assembly_enabled, true);
  assert.equal(settings.worker.delivery_assembly_enabled, true);
  assert.equal(settings.creator_notification_diagnostics_enabled, false);
  assert.equal(settings.diagnostics.notification_diagnostics_enabled, false);
  assert.equal(settings.creator_bootstrap_monitoring_enabled, false);
  assert.equal(settings.diagnostics.bootstrap_monitoring_enabled, false);
}

function testWorkflowPayloadCompatibility() {
  const settings = normalizeTenantFeatureSettings({
    workflow_settings: {
      registration: { client_city_options: ["Не используется"] },
    },
    client: {
      group_switcher_enabled: true,
      qr_existing_client_join_enabled: true,
      phone_access_approval_enabled: true,
    },
    tenant_console: {
      dangerous_action_audit_enabled: true,
      product_change_history_enabled: true,
    },
  });
  assert.equal(settings.client_group_switcher_enabled, true);
  assert.equal(settings.qr_existing_client_join_enabled, true);
  assert.equal(settings.phone_access_approval_enabled, true);
  assert.equal(settings.dangerous_action_audit_enabled, true);
  assert.equal(settings.product_change_history_enabled, true);
}

function testTenantScopedEmailMigration() {
  const migrationPath = path.resolve(
    __dirname,
    "../migrations/076_users_email_tenant_scope.sql",
  );
  const sql = fs.readFileSync(migrationPath, "utf8").toLowerCase();
  assert.match(sql, /drop constraint if exists users_email_key/);
  assert.match(sql, /ux_users_tenant_lower_email/);
  assert.match(sql, /coalesce\(tenant_id/);
  assert.match(sql, /lower\(email\)/);
}

function testInviteJoinUsesTenantScopedEmailLookup() {
  const routePath = path.resolve(__dirname, "../src/routes/auth.js");
  const source = fs.readFileSync(routePath, "utf8");
  assert.match(source, /qr_existing_client_join_enabled/);
  assert.match(source, /u\.tenant_id = \$2::uuid/);
  assert.match(source, /tenant_id = \$2::uuid/);
  assert.match(source, /allowLegacyNullTenantRows/);
}

function testAmbiguousLoginRequestsTenantSelection() {
  const authRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/auth.js"),
    "utf8",
  );
  const authScreen = fs.readFileSync(
    path.resolve(__dirname, "../../lib/screens/auth_screen.dart"),
    "utf8",
  );
  assert.match(authRoute, /findLoginTenantCandidatesByPassword/);
  assert.match(authRoute, /tenant_selection_required: true/);
  assert.match(authRoute, /buildPublicLoginTenantOption/);
  assert.match(authRoute, /result\?\.reason === 'password_mismatch'/);
  assert.match(authRoute, /passwordMatchedTenants\.length === 1/);
  assert.doesNotMatch(authRoute, /!result\?\.ok &&\s+tenantCodeHint &&/);
  assert.match(authScreen, /_showLoginTenantSelection/);
  assert.match(authScreen, /tenant_selection_required/);
  assert.match(authScreen, /_retryLoginWithTenantSelection/);
}

function testAuthRecoveryUsesScopedEmailTokens() {
  const routePath = path.resolve(__dirname, "../src/routes/auth.js");
  const source = fs.readFileSync(routePath, "utf8");
  assert.match(source, /function parseAuthEmailToken/);
  assert.match(source, /function encodeAuthEmailToken/);
  assert.match(source, /runWithAuthEmailTokenScope\(parsedToken\.scopeKey/);
  assert.match(source, /scopeKey: resolveAuthEmailTokenScopeKey/);
  assert.match(source, /db\.runWithTenantRow\(scopedTenant/);
}

function testAuthRecoveryAndEmailPreflightAreTenantScoped() {
  const authRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/auth.js"),
    "utf8",
  );
  const authScreen = fs.readFileSync(
    path.resolve(__dirname, "../../lib/screens/auth_screen.dart"),
    "utf8",
  );
  const authService = fs.readFileSync(
    path.resolve(__dirname, "../../lib/services/auth_service.dart"),
    "utf8",
  );
  const phoneNameScreen = fs.readFileSync(
    path.resolve(__dirname, "../../lib/screens/phone_name_screen.dart"),
    "utf8",
  );

  assert.match(authRoute, /function tenantScopedUserFilterSql/);
  assert.match(
    authRoute,
    /router\.post\('\/check_email'[\s\S]*db\.resolveTenantByCode\(tenantCodeHint\)[\s\S]*tenantScopedUserFilterSql/,
  );
  assert.match(
    authRoute,
    /router\.post\('\/register\/email-code\/request'[\s\S]*tenantScopedUserFilterSql/,
  );
  assert.match(
    authRoute,
    /async function resolveTenantForEmailAuthRequest[\s\S]*if \(tenantCodeHint\)[\s\S]*return \{ tenant, isPlatformCreator: false \}/,
  );
  assert.match(
    authRoute,
    /async function findUserForEmailAuthRequest[\s\S]*tenantScopedUserFilterSql\([\s\S]*attachTenantScopeToLegacyAuthUser\(db, found, tenant\)/,
  );
  assert.match(authRoute, /c\.tenant_id AS token_tenant_id/);
  assert.match(
    authRoute,
    /COALESCE\(u\.tenant_id, c\.tenant_id\) AS effective_tenant_id/,
  );
  assert.match(
    authRoute,
    /LEFT JOIN tenants t ON t\.id = COALESCE\(u\.tenant_id, c\.tenant_id\)/,
  );
  assert.match(
    authRoute,
    /router\.post\('\/magic-link\/consume'[\s\S]*attachTenantScopeToLegacyAuthUser\([\s\S]*client[\s\S]*claimedTenant/,
  );
  assert.match(
    authRoute,
    /router\.post\('\/password-reset\/confirm'[\s\S]*tenant_code: isPlatformCreator/,
  );
  assert.match(
    authScreen,
    /Future<void> _requestEmailAction[\s\S]*_currentTenantCodeForAuthRequest\(\)[\s\S]*'tenant_code': tenantCode/,
  );
  assert.match(authScreen, /await _authService\.applyAuthResponse\(resp\)/);
  assert.match(authService, /Future<void> applyAuthResponse\(Response resp\)/);
  assert.match(phoneNameScreen, /await authService\.applyAuthResponse\(resp\)/);
  assert.doesNotMatch(
    phoneNameScreen,
    /applyLoginResponse\([\s\S]{0,160}respData\['user'\]/,
  );
}

function testLegacyBootstrapScansTenantSessionScopes() {
  const authRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/auth.js"),
    "utf8",
  );
  assert.match(authRoute, /async function findLegacySessionTenantScope/);
  assert.match(authRoute, /db\.isIsolatedTenantRow\(tenantRow\)/);
  assert.match(authRoute, /db\.isSchemaIsolatedTenantRow\(tenantRow\)/);
  assert.match(authRoute, /getUserSessionBySessionId\(\{\s*queryable: db,/);
  assert.match(authRoute, /String\(session\.user_id \|\| ''\)\.trim\(\) === normalizedUserId/);
  assert.match(
    authRoute,
    /router\.post\('\/refresh\/bootstrap'[\s\S]*findLegacySessionTenantScope/,
  );
}

function testRefreshHydratesLegacyTenantNullUsers() {
  const authRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/auth.js"),
    "utf8",
  );
  assert.match(authRoute, /function buildAuthTenantSnapshot/);
  assert.match(authRoute, /async function attachTenantScopeToLegacyAuthUser/);
  assert.match(authRoute, /SET tenant_id = \$1[\s\S]{0,120}tenant_id IS NULL/);
  assert.match(authRoute, /runWithRefreshScope\(scopeKey, async \(refreshTenantScope\)/);
  assert.match(
    authRoute,
    /router\.post\('\/refresh'[\s\S]*attachTenantScopeToLegacyAuthUser\([\s\S]{0,180}refreshTenantScope/,
  );
  assert.match(
    authRoute,
    /router\.post\('\/refresh'[\s\S]*buildAuthTenantSnapshot\(user, refreshTenantScope\)/,
  );
  assert.match(
    authRoute,
    /router\.post\('\/refresh\/bootstrap'[\s\S]*attachTenantScopeToLegacyAuthUser\([\s\S]{0,180}tenantScope/,
  );
  assert.match(
    authRoute,
    /router\.post\('\/refresh\/bootstrap'[\s\S]*buildAuthTenantSnapshot\(user, tenantScope\)/,
  );
}

function testAuthMiddlewareHydratesLegacyTenantNullUsers() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "../src/utils/auth.js"),
    "utf8",
  );
  assert.match(source, /async function attachTenantScopeToLegacyAuthContextUser/);
  assert.match(source, /SET tenant_id = \$1[\s\S]{0,120}tenant_id IS NULL/);
  assert.match(
    source,
    /!isPlatformCreator && !row\.tenant_id && tenantScope[\s\S]{0,100}attachTenantScopeToLegacyAuthContextUser\(row, tenantScope\)/,
  );
  assert.match(
    source,
    /tenantCodeHint \|\| row\.tenant_code \|\| tenantScope\?\.code/,
  );
  assert.match(
    source,
    /const effectiveTenantId = String\(row\.tenant_id \|\| tenantScope\?\.id \|\| ''\)/,
  );
}

function testNotificationInboxDedupeIsAtomic() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "../src/utils/notifications.js"),
    "utf8",
  );
  assert.match(source, /ON CONFLICT \(user_id, dedupe_key\)/);
  assert.match(source, /WHERE dedupe_key IS NOT NULL AND btrim\(dedupe_key\) <> ''/);
  assert.match(source, /DO UPDATE SET/);
  assert.doesNotMatch(
    source,
    /FROM notification_inbox_items[\s\S]{0,160}WHERE user_id = \$1[\s\S]{0,160}AND dedupe_key = \$2[\s\S]{0,240}INSERT INTO notification_inbox_items/,
  );
}

function testManualRevisionUsesManualShelfKeys() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/worker.js"),
    "utf8",
  );
  assert.match(source, /async function fetchRevisionShelves/);
  assert.match(source, /if \(options\.manualShelfEnabled === true\)/);
  assert.match(source, /manualRevisionShelfLabelSql\('p'\)/);
  assert.match(source, /lower\(\$\{manualShelfSql\}\) AS shelf_key/);
  assert.match(source, /GROUP BY vc\.shelf_key/);
  assert.match(source, /selectedShelfKey: manualShelfEnabled \? requestedShelfKey : ''/);
  assert.match(source, /selectedShelfNumber: manualShelfEnabled \? null : selectedShelfNumber/);
  assert.match(source, /manualShelfEnabled[\s\S]{0,300}normalizeRevisionShelfKey\(post\.revision_shelf_key\)/);

  const manualBranchStart = source.indexOf("if (options.manualShelfEnabled === true)");
  const fallbackBranchStart = source.indexOf(
    "const includeHiddenMissingPhotoShelf",
    manualBranchStart,
  );
  assert.ok(manualBranchStart >= 0);
  assert.ok(fallbackBranchStart > manualBranchStart);
  const manualBranch = source.slice(manualBranchStart, fallbackBranchStart);
  assert.doesNotMatch(manualBranch, /Array\.from\(\{ length: 10 \}/);
  assert.doesNotMatch(manualBranch, /p\.shelf_number BETWEEN 1 AND 10/);
}

function testProductDescriptionOptionalProjectWide() {
  const workerRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/worker.js"),
    "utf8",
  );
  const adminRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/admin.js"),
    "utf8",
  );
  const workerPanel = fs.readFileSync(
    path.resolve(__dirname, "../../lib/screens/worker_panel.dart"),
    "utf8",
  );
  const adminPanel = fs.readFileSync(
    path.resolve(__dirname, "../../lib/screens/admin_panel.dart"),
    "utf8",
  );

  assert.match(workerPanel, /labelText: 'Описание \(необязательно\)'/);
  assert.match(adminPanel, /labelText: 'Описание \(необязательно\)'/);
  assert.match(
    workerPanel,
    /description\.isNotEmpty && _countLetterRunes\(description\) < 2/,
  );
  assert.match(adminPanel, /description\.isNotEmpty && description\.length < 2/);
  assert.match(workerRoute, /if \(normalizedDescription && !hasAtLeastTwoLetters/);
  assert.match(workerRoute, /if \(nextDescription && !hasAtLeastTwoLetters/);
  assert.match(workerRoute, /if \(description && !hasAtLeastTwoLetters\(description\)\)/);
  assert.match(adminRoute, /if \(description && description\.length < 2\)/);
  assert.doesNotMatch(workerRoute, /Описание товара обязательно/);
  assert.doesNotMatch(adminRoute, /Описание товара обязательно/);

  const requeueStart = workerPanel.indexOf("Future<void> _requeueProduct");
  const requeueEnd = workerPanel.indexOf(
    "Future<void> _quickDuplicateProduct",
    requeueStart,
  );
  assert.ok(requeueStart >= 0, "_requeueProduct must exist");
  assert.ok(requeueEnd > requeueStart, "_quickDuplicateProduct must follow _requeueProduct");
  const requeueBlock = workerPanel.slice(requeueStart, requeueEnd);
  assert.match(
    requeueBlock,
    /final description = \(product\['description'\] \?\? ''\)\.toString\(\)\.trim\(\);/,
  );
  assert.doesNotMatch(requeueBlock, /_descriptionCtrl\.text\.trim\(\)\.isNotEmpty/);
  assert.doesNotMatch(requeueBlock, /_titleCtrl\.text\.trim\(\)\.isNotEmpty/);
  assert.doesNotMatch(requeueBlock, /_pickedImage/);
  assert.doesNotMatch(requeueBlock, /_existingImageUrl/);
  assert.doesNotMatch(requeueBlock, /_removeImageOnSubmit/);
  assert.match(requeueBlock, /imageUrl: existingImage/);

  const payloadStart = workerPanel.indexOf("FormData _buildRequeuePayload");
  const payloadEnd = workerPanel.indexOf("Future<void> _loadChannels", payloadStart);
  assert.ok(payloadStart >= 0, "_buildRequeuePayload must be synchronous");
  assert.ok(payloadEnd > payloadStart, "_buildRequeuePayload block must be bounded");
  const payloadBlock = workerPanel.slice(payloadStart, payloadEnd);
  assert.match(payloadBlock, /required String imageUrl/);
  assert.match(payloadBlock, /map\['image_url'\] = imageUrl/);
  assert.doesNotMatch(payloadBlock, /_pickedImage/);
  assert.doesNotMatch(payloadBlock, /_existingImageUrl/);
  assert.doesNotMatch(payloadBlock, /_removeImageOnSubmit/);

  assert.match(workerRoute, /const hasDescriptionField = Object\.prototype\.hasOwnProperty\.call/);
  assert.match(
    workerRoute,
    /const nextDescription = hasDescriptionField\s*\?\s*String\(description \|\| ''\)\.trim\(\)\s*:\s*String\(current\.description \|\| ''\)\.trim\(\);/,
  );
}

function testClientCancelAnytimeHandlesDeliveryBatchLinks() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/cart.js"),
    "utf8",
  );
  assert.match(source, /const CLIENT_CANCEL_ANYTIME_STATUSES = new Set/);
  assert.match(source, /'handing_to_courier'/);
  assert.match(source, /async function updateLinkedDeliveryBatchAfterCartCancel/);
  assert.match(source, /COALESCE\(di\.assembly_status, 'pending'\) <> 'removed'/);
  assert.match(source, /dbt\.status = ANY\(\$2::text\[\]\)/);
  assert.match(source, /delivery_status = CASE[\s\S]*'returned_to_cart'/);
  assert.match(source, /processed_sum = totals\.processed_sum/);
  assert.match(source, /processed_items_count = totals\.processed_items_count/);
  assert.match(source, /status = 'cancelled'[\s\S]{0,180}WHERE id = \$1/);
  assert.doesNotMatch(
    source,
    /if \(hasDeliveryLink\) return false/,
  );
}

function testNightlyAuditChecksTenantFeaturePolicy() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "nightly-self-audit.js"),
    "utf8",
  );
  assert.match(source, /async function checkTenantFeaturePolicy/);
  assert.match(source, /getTenantFeatureSettings/);
  assert.match(source, /phone_access_approval_enabled/);
  assert.match(source, /tenant_features\.phone_access_enabled/);
  assert.match(source, /tenant_features\.policy_drift/);
  assert.match(source, /client_cancel_anytime_disabled/);
  assert.match(source, /await checkTenantFeaturePolicy\(\)/);
}

function testNightlyAuditChecksNotificationQueueAcrossTenantScopes() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "nightly-self-audit.js"),
    "utf8",
  );
  assert.match(source, /async function checkNotificationQueueHealth/);
  assert.match(source, /notifications\.queue\.backlog/);
  assert.match(source, /notifications\.queue\.failures/);
  assert.match(source, /notifications\.queue\.check_failed/);
  assert.match(source, /stale_processing_count/);
  assert.match(source, /unavailable_targets/);
  assert.match(source, /db_mode IN \('isolated', 'schema_isolated'\)/);
  assert.match(source, /db\.runWithTenantRow\(tenant, fn\)/);
  assert.match(source, /await checkNotificationQueueHealth\(\)/);
}

function testNightlyAuditChecksMonitoringBacklogAcrossTenantScopes() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "nightly-self-audit.js"),
    "utf8",
  );
  assert.match(source, /async function checkMonitoringBacklog/);
  assert.match(source, /monitoring\.unresolved_recent/);
  assert.match(source, /monitoring\.unavailable_targets/);
  assert.match(source, /monitoring\.check_failed/);
  assert.match(source, /unresolved_recent/);
  assert.match(source, /unavailable_targets/);
  assert.match(source, /db_mode IN \('isolated', 'schema_isolated'\)/);
  assert.match(source, /db\.runWithTenantRow\(tenant, fn\)/);
  assert.match(source, /await checkMonitoringBacklog\(\)/);
}

function testNightlyAuditChecksTenantMigrationDrift() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "nightly-self-audit.js"),
    "utf8",
  );
  assert.match(source, /async function checkTenantMigrationDrift/);
  assert.match(source, /schema_migrations/);
  assert.match(source, /tenant_migrations\.drift/);
  assert.match(source, /tenant_migrations\.synced/);
  assert.match(source, /db_mode IN \('isolated', 'schema_isolated'\)/);
  assert.match(source, /pending_migration_files/);
  assert.match(source, /await checkTenantMigrationDrift\(\)/);
}

function testNightlyAuditChecksSchemaContractProjectWide() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "nightly-self-audit.js"),
    "utf8",
  );
  assert.match(source, /const SHARED_SCHEMA_CONTRACT = \[/);
  assert.match(source, /const PLATFORM_SCHEMA_CONTRACT = \[/);
  assert.match(source, /table: "auth_email_tokens"/);
  assert.match(source, /async function checkDatabaseSchemaContract/);
  assert.match(source, /schema\.contract_drift/);
  assert.match(source, /schema\.contract_healthy/);
  assert.match(source, /information_schema\.columns/);
  assert.match(source, /missing_contract_items/);
  assert.match(source, /db_mode IN \('isolated', 'schema_isolated'\)/);
  assert.match(source, /normalizePgSchema\(tenant\?\.db_schema/);
  assert.match(source, /db\.runWithTenantRow\(tenant, fn\)/);
  assert.match(source, /await checkDatabaseSchemaContract\(\)/);
}

function testNightlyAuditChecksTenantUserIndexDrift() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "nightly-self-audit.js"),
    "utf8",
  );
  assert.match(source, /async function checkTenantUserIndexDrift/);
  assert.match(source, /tenant_user_index\.drift/);
  assert.match(source, /tenant_user_index\.synced/);
  assert.match(source, /loadExpectedTenantIndexUsers/);
  assert.match(source, /orphan_index_rows/);
  assert.match(source, /mismatched_index_rows/);
  assert.match(source, /await checkTenantUserIndexDrift\(\)/);
}

function testAuthSessionsArePersistentProjectWide() {
  const authRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/auth.js"),
    "utf8",
  );
  assert.match(
    authRoute,
    /function buildSessionExpiry\(\) \{[\s\S]{0,180}return null;[\s\S]{0,80}\}/,
  );
  assert.doesNotMatch(authRoute, /AUTH_SESSION_AUTO_EXPIRY_ENABLED/);
  assert.doesNotMatch(authRoute, /SESSION_AUTO_EXPIRY_ENABLED/);
  assert.doesNotMatch(authRoute, /SESSION_TTL_MS/);

  const migration = fs.readFileSync(
    path.resolve(
      __dirname,
      "../migrations/079_enforce_persistent_user_sessions.sql",
    ),
    "utf8",
  );
  assert.match(migration, /UPDATE user_sessions/);
  assert.match(migration, /SET expires_at = NULL/);
  assert.match(migration, /WHERE is_active = true/);
}

function testNightlyAuditChecksAuthSessionsProjectWide() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "nightly-self-audit.js"),
    "utf8",
  );
  assert.match(source, /async function checkAuthSessionHealth/);
  assert.match(source, /auth_sessions\.policy_drift/);
  assert.match(source, /auth_sessions\.healthy/);
  assert.match(source, /active_sessions_with_expiry/);
  assert.match(source, /active_refresh_without_public_id/);
  assert.match(source, /auth_session_auto_expiry_env_enabled/);
  assert.match(source, /db_mode IN \('isolated', 'schema_isolated'\)/);
  assert.match(source, /await checkAuthSessionHealth\(\)/);
}

function testNightlyAuditChecksAuthIdentityProjectWide() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "nightly-self-audit.js"),
    "utf8",
  );
  assert.match(source, /async function checkAuthIdentityIntegrity/);
  assert.match(source, /auth_identity\.integrity_drift/);
  assert.match(source, /auth_identity\.healthy/);
  assert.match(source, /duplicate_active_email_groups/);
  assert.match(source, /duplicate_active_phone_groups/);
  assert.match(source, /credential_email_groups/);
  assert.match(source, /active_email_groups_without_valid_password/);
  assert.match(source, /active_users_missing_password_hash/);
  assert.match(source, /active_users_invalid_password_hash/);
  assert.match(source, /const hardDriftFields = \[/);
  assert.match(source, /"active_users_invalid_password_hash"/);
  assert.match(source, /active_sessions_for_inactive_users/);
  assert.match(source, /active_notification_endpoints_for_inactive_users/);
  assert.match(source, /pending_phone_requests_without_active_owner/);
  assert.match(source, /db_mode IN \('isolated', 'schema_isolated'\)/);
  assert.match(source, /db\.runWithTenantRow\(tenant, fn\)/);
  assert.match(source, /await checkAuthIdentityIntegrity\(\)/);
}

function testNightlyAuditChecksAuthEmailTokensProjectWide() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "nightly-self-audit.js"),
    "utf8",
  );
  assert.match(source, /async function checkAuthEmailTokenIntegrity/);
  assert.match(source, /auth_email_tokens\.integrity_drift/);
  assert.match(source, /auth_email_tokens\.healthy/);
  assert.match(source, /unexpired_tokens_missing_user/);
  assert.match(source, /unexpired_tokens_inactive_user/);
  assert.match(source, /unexpired_tokens_email_mismatch/);
  assert.match(source, /unexpired_tokens_tenant_mismatch/);
  assert.match(source, /duplicate_unexpired_user_kind_groups/);
  assert.match(source, /db_mode IN \('isolated', 'schema_isolated'\)/);
  assert.match(source, /db\.runWithTenantRow\(tenant, fn\)/);
  assert.match(source, /await checkAuthEmailTokenIntegrity\(\)/);
}

function testSessionBootstrapE2ECoversRefreshAndPersistentSessions() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "e2e-session-bootstrap-flow.js"),
    "utf8",
  );
  assert.match(source, /function assertPersistentAuthPayload/);
  assert.match(source, /session_expires_at must be null/);
  assert.match(source, /\/api\/auth\/refresh/);
  assert.match(source, /refresh token flow keeps persistent session/);
  assert.match(source, /refresh\/bootstrap accepts expired signed access token/);
  assert.match(source, /assertPersistentAuthPayload\(loginPayload, 'login'\)/);
  assert.match(source, /assertPersistentAuthPayload\(refreshRoot, 'refresh'\)/);
  assert.match(source, /assertPersistentAuthPayload\(root, 'bootstrap'\)/);
}

function testUploadRecoveryScriptsAreTenantAware() {
  const audit = fs.readFileSync(
    path.resolve(__dirname, "uploads_recovery_audit.js"),
    "utf8",
  );
  assert.match(audit, /function scopeMetadata/);
  assert.match(audit, /scope_key/);
  assert.match(audit, /summaryOnly/);
  assert.match(audit, /--summary-only/);
  assert.match(audit, /if \(!args\.summaryOnly\)/);
  assert.match(audit, /db_mode IN \('isolated', 'schema_isolated'\)/);
  assert.match(audit, /db\.runWithTenantRow\(scope\.tenantRow \|\| null/);
  assert.match(audit, /db\.closeAllPools\(\)/);
  assert.doesNotMatch(audit, /db\.platformQuery\(sql\)/);

  const placeholders = fs.readFileSync(
    path.resolve(__dirname, "uploads_recovery_apply_placeholders.js"),
    "utf8",
  );
  assert.match(placeholders, /function groupEntriesByScope/);
  assert.match(placeholders, /async function runWithManifestScope/);
  assert.match(placeholders, /db\.resolveTenantById\(tenantId\)/);
  assert.match(placeholders, /db\.runWithTenantRow\(tenantRow, fn\)/);
  assert.match(placeholders, /applyPlaceholderEntriesInCurrentScope/);
  assert.doesNotMatch(placeholders, /db\.platformConnect\(\)/);

  const relink = fs.readFileSync(
    path.resolve(__dirname, "uploads_recovery_relink_restored.js"),
    "utf8",
  );
  assert.match(relink, /function groupEntriesByScope/);
  assert.match(relink, /async function runWithManifestScope/);
  assert.match(relink, /db\.resolveTenantById\(tenantId\)/);
  assert.match(relink, /db\.runWithTenantRow\(tenantRow, fn\)/);
  assert.match(relink, /relinkEntriesInCurrentScope/);
  assert.doesNotMatch(relink, /db\.platformConnect\(\)/);
}

function testNightlyAuditChecksUploadRecoveryHealth() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "nightly-self-audit.js"),
    "utf8",
  );
  assert.match(source, /function checkUploadRecoveryHealth/);
  assert.match(source, /uploads_recovery_audit\.js/);
  assert.match(source, /--missing-only/);
  assert.match(source, /--summary-only/);
  assert.match(source, /uploads\.recovery\.missing_refs/);
  assert.match(source, /uploads\.recovery\.healthy/);
  assert.match(source, /scopes_checked/);
  assert.match(source, /entries_checked/);
  assert.match(source, /checkUploadRecoveryHealth\(\)/);
}

function testNightlyAuditChecksProductCartIntegrityProjectWide() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "nightly-self-audit.js"),
    "utf8",
  );
  assert.match(source, /async function checkProductCartIntegrity/);
  assert.match(source, /products\.integrity_drift/);
  assert.match(source, /products\.integrity_healthy/);
  assert.match(source, /active_cart_deleted_products/);
  assert.match(source, /active_reservation_deleted_products/);
  assert.match(source, /active_queue_deleted_products/);
  assert.match(source, /active_delivery_deleted_products/);
  assert.match(source, /visible_deleted_product_messages/);
  assert.match(source, /visible_missing_product_messages/);
  assert.match(source, /db_mode IN \('isolated', 'schema_isolated'\)/);
  assert.match(source, /db\.runWithTenantRow\(tenant, fn\)/);
  assert.match(source, /await checkProductCartIntegrity\(\)/);
}

function testNightlyAuditChecksPublicationPipelineProjectWide() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "nightly-self-audit.js"),
    "utf8",
  );
  assert.match(source, /async function checkPublicationPipelineHealth/);
  assert.match(source, /publication\.pipeline_stalled/);
  assert.match(source, /publication\.pipeline_healthy/);
  assert.match(source, /queued_queue_items_without_active_batch/);
  assert.match(source, /publishing_queue_items_without_active_batch/);
  assert.match(source, /stale_queued_queue_items/);
  assert.match(source, /stale_publishing_queue_items/);
  assert.match(source, /active_batches_without_active_items/);
  assert.match(source, /active_batch_counter_drift/);
  assert.match(source, /failed_queue_items/);
  assert.match(source, /db_mode IN \('isolated', 'schema_isolated'\)/);
  assert.match(source, /db\.runWithTenantRow\(tenant, fn\)/);
  assert.match(source, /await checkPublicationPipelineHealth\(\)/);
}

function testNightlyAuditChecksChatRecencyProjectWide() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "nightly-self-audit.js"),
    "utf8",
  );
  assert.match(source, /async function checkChatRecencyIntegrity/);
  assert.match(source, /chats\.recency_drift/);
  assert.match(source, /chats\.recency_healthy/);
  assert.match(source, /latest_message_at > chat_updated_at/);
  assert.match(source, /stale_main_channel_count/);
  assert.match(source, /stale_system_channel_count/);
  assert.match(source, /db_mode IN \('isolated', 'schema_isolated'\)/);
  assert.match(source, /db\.runWithTenantRow\(tenant, fn\)/);
  assert.match(source, /await checkChatRecencyIntegrity\(\)/);
}

function testReleaseAuditRunsBeforeDeployAndIncludesBusinessGates() {
  const fullAudit = fs.readFileSync(
    path.resolve(__dirname, "../../scripts/full_cluster_audit.sh"),
    "utf8",
  );
  assert.match(fullAudit, /npm run test:business:settings/);
  assert.match(fullAudit, /npm run lint/);
  assert.match(fullAudit, /npm run audit:gate/);
  assert.match(fullAudit, /RUN_GITHUB_ACTIONS="\$\{RUN_GITHUB_ACTIONS:-0\}"/);
  assert.match(fullAudit, /github_actions_health_check\.js/);
  assert.match(fullAudit, /--require-current-head/);
  assert.match(fullAudit, /RUN_E2E="\$\{RUN_E2E:-0\}"/);
  assert.match(fullAudit, /npm run test:e2e:full/);
  assert.match(fullAudit, /find src scripts -type f -name "\*\.js"/);
  assert.match(fullAudit, /== production self-audit ==/);
  const productionSelfAuditRuns =
    fullAudit.match(/NODE_ENV=production npm run audit:self/g) || [];
  assert.ok(
    productionSelfAuditRuns.length >= 2,
    "full_cluster_audit must run production self-audit for both SSH auth branches",
  );

  const releaseWithAudit = fs.readFileSync(
    path.resolve(__dirname, "../../scripts/release_with_audit.sh"),
    "utf8",
  );
  const auditIndex = releaseWithAudit.indexOf("full_cluster_audit.sh");
  const deployIndex = releaseWithAudit.indexOf("deploy_full.sh");
  assert.ok(auditIndex >= 0, "release_with_audit must run full_cluster_audit");
  assert.ok(deployIndex >= 0, "release_with_audit must run deploy_full");
  assert.match(releaseWithAudit, /RUN_E2E_AUDIT="\$\{RUN_E2E_AUDIT:-1\}"/);
  assert.match(releaseWithAudit, /RUN_E2E="\$RUN_E2E_AUDIT"/);
  assert.match(releaseWithAudit, /RUN_GITHUB_ACTIONS=1/);
  assert.match(releaseWithAudit, /E2E_REQUIRE_FULL="\$E2E_REQUIRE_FULL"/);
  assert.ok(
    auditIndex < deployIndex,
    "release_with_audit must run full_cluster_audit before deploy_full",
  );
}

function testGithubActionsHealthCheckExplainsRunnerStartupFailures() {
  const source = fs.readFileSync(
    path.resolve(__dirname, "../../scripts/github_actions_health_check.js"),
    "utf8",
  );
  assert.match(source, /run\("gh", \[\s*"run",\s*"list"/);
  assert.match(source, /actions\/runs\/\$\{runId\}\/jobs/);
  assert.match(source, /check_run_url/);
  assert.match(source, /step_count === 0/);
  assert.match(source, /billing issue/i);
  assert.match(source, /--require-current-head/);
  assert.match(source, /Latest GitHub Actions run does not match current HEAD/);
}

function testGithubCiRunsReleaseGuards() {
  const workflowPaths = [
    path.resolve(__dirname, "../../.github/workflows/security-ci.yml"),
    path.resolve(__dirname, "../../.github/workflows/nightly-self-audit.yml"),
  ];
  const securityCi = fs.readFileSync(workflowPaths[0], "utf8");
  assert.match(securityCi, /workflow_dispatch:/);

  for (const workflowPath of workflowPaths) {
    const workflow = fs.readFileSync(workflowPath, "utf8");
    assert.match(
      workflow,
      /npm run --prefix server test:business:settings/,
      workflowPath,
    );
    assert.match(workflow, /bash -n scripts\/full_cluster_audit\.sh/, workflowPath);
    assert.match(workflow, /bash -n scripts\/release_with_audit\.sh/, workflowPath);
  }
}

function testGithubWorkflowSecretsAreCheckedInsideSteps() {
  const workflow = fs.readFileSync(
    path.resolve(__dirname, "../../.github/workflows/critical-integration.yml"),
    "utf8",
  );
  assert.doesNotMatch(workflow, /critical_e2e:[\s\S]{0,160}\n\s+if:\s*\$\{\{\s*secrets\./);
  assert.match(workflow, /if \[ -z "\$\{E2E_BASE_URL\}" \]/);
  assert.match(workflow, /Skip critical integration checks/);
}

function testNotificationWorkerTenantScopes() {
  const tenantRows = [
    { code: "alpha", db_mode: "isolated" },
    { code: "beta", db_mode: "schema_isolated" },
    { code: "shared", db_mode: "shared" },
  ];
  const scopes = buildTenantProcessingScopes(tenantRows);
  assert.equal(scopes.length, 3);
  assert.equal(scopeLabel(scopes[0]), "platform");
  assert.equal(scopeLabel(scopes[1]), "alpha");
  assert.equal(scopeLabel(scopes[2]), "beta");

  const rotated = rotateTenantProcessingScopes(scopes);
  assert.deepEqual(rotated.map(scopeLabel), ["platform", "alpha", "beta"]);
  const rotatedAgain = rotateTenantProcessingScopes(scopes);
  assert.deepEqual(rotatedAgain.map(scopeLabel), ["alpha", "beta", "platform"]);
}

function testNoTenantSpecificWorkflowHardcode() {
  const files = [
    path.resolve(__dirname, "../src/routes/delivery.js"),
    path.resolve(__dirname, "../../lib/screens/worker_panel.dart"),
    path.resolve(__dirname, "../../lib/screens/chat_screen.dart"),
  ];
  for (const file of files) {
    const source = fs.readFileSync(file, "utf8").toLowerCase();
    const blockedTenantCodes = [
      ["ki", "nel-8997"].join(""),
      ["anna-ut", "evskaya-4898"].join(""),
    ];
    const blockedHelperNames = [
      ["is", "kinel", "tenantscope"].join(""),
      ["is", "anna", "ut"].join(""),
    ];
    for (const code of blockedTenantCodes) {
      assert.doesNotMatch(source, new RegExp(code, "i"));
    }
    for (const helperName of blockedHelperNames) {
      assert.doesNotMatch(source, new RegExp(helperName, "i"));
    }
  }
}

function testNoRealPersonExamplesInDemoDataAndHints() {
  const files = [
    path.resolve(__dirname, "../src/routes/delivery.js"),
    path.resolve(__dirname, "../../lib/screens/chats_screen.dart"),
    path.resolve(__dirname, "../../docs/client_group_switcher_prototype.html"),
  ];
  const blockedNameParts = [
    ["Ан", "на"],
    ["Мак", "сим"],
    ["Вал", "ерия"],
    ["Бел", "оозер"],
    ["Уте", "вск"],
    ["Шку", "рова"],
  ];
  const blockedPatterns = [
    ...blockedNameParts.map(
      (parts) => new RegExp(parts.join(""), "i"),
    ),
    new RegExp(["890", "333", "47530"].join("")),
    new RegExp(["vip", "-shkurova"].join(""), "i"),
    new RegExp(["ki", "nel-8997"].join(""), "i"),
    new RegExp(["anna-ut", "evskaya-4898"].join(""), "i"),
  ];
  for (const file of files) {
    const source = fs.readFileSync(file, "utf8");
    for (const pattern of blockedPatterns) {
      assert.doesNotMatch(source, pattern, file);
    }
  }
}

function testWorkerDeliveryAssemblyFeatureFlag() {
  const settings = normalizeTenantFeatureSettings({
    worker_delivery_assembly_enabled: true,
  });
  assert.equal(settings.worker_delivery_assembly_enabled, true);
  assert.equal(settings.worker.delivery_assembly_enabled, true);

  const adminRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/admin.js"),
    "utf8",
  );
  const deliveryRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/delivery.js"),
    "utf8",
  );
  assert.match(adminRoute, /worker_delivery_assembly_enabled/);
  assert.match(deliveryRoute, /worker_delivery_assembly_enabled/);
  assert.match(deliveryRoute, /delivery_assembly_enabled/);
}

function testDeliveryLocalityNormalizerIsGeneric() {
  const deliveryRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/delivery.js"),
    "utf8",
  );
  assert.match(deliveryRoute, /function toTitleCaseLocality/);
  assert.match(deliveryRoute, /LOCALITY_ALIAS_RULES/);
  assert.match(deliveryRoute, /canonical: "Новокуйбышевск"/);
  assert.doesNotMatch(deliveryRoute, /value\.includes\("кинель"\)/);
  assert.doesNotMatch(deliveryRoute, /value\.includes\("самара"\)/);
  assert.doesNotMatch(deliveryRoute, /value\.includes\("тольят"\)/);
}

function testPublicAuthErrorsUseNeutralSupportWording() {
  const files = [
    path.resolve(__dirname, "../src/routes/auth.js"),
    path.resolve(__dirname, "../src/utils/auth.js"),
  ];
  for (const file of files) {
    const source = fs.readFileSync(file, "utf8");
    assert.doesNotMatch(source, /Обратитесь к создателю/);
    assert.doesNotMatch(source, /создателю приложения/);
    assert.doesNotMatch(source, /создателю за новым ключом/);
    assert.doesNotMatch(source, /владельцу приложения/);
  }

  const tenantUtils = fs.readFileSync(
    path.resolve(__dirname, "../src/utils/tenants.js"),
    "utf8",
  );
  assert.doesNotMatch(tenantUtils, /владельцу приложения|владельцем приложения/);
}

function testUnreachableFirstCallAutoDeleteDefaultsOff() {
  const deliveryRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/delivery.js"),
    "utf8",
  );
  const envExample = fs.readFileSync(
    path.resolve(__dirname, "../.env.example"),
    "utf8",
  );
  assert.match(
    deliveryRoute,
    /process\.env\.CLIENT_UNREACHABLE_FIRST_CALL_AUTO_DELETE \|\| "false"/,
  );
  assert.match(
    deliveryRoute,
    /CLIENT_UNREACHABLE_FIRST_CALL_AUTO_DELETE[\s\S]*?\.trim\(\) === "true"/,
  );
  assert.match(envExample, /^CLIENT_UNREACHABLE_FIRST_CALL_AUTO_DELETE=false$/m);
}

function testInactiveClientAccountAutoDeleteDefaultsOff() {
  const deliveryRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/delivery.js"),
    "utf8",
  );
  const envExample = fs.readFileSync(
    path.resolve(__dirname, "../.env.example"),
    "utf8",
  );
  assert.match(
    deliveryRoute,
    /process\.env\.CLIENT_INACTIVITY_ACCOUNT_AUTO_DELETE_ENABLED \|\| "false"/,
  );
  assert.match(
    deliveryRoute,
    /if \(CLIENT_INACTIVITY_ACCOUNT_AUTO_DELETE_ENABLED\)/,
  );
  assert.doesNotMatch(deliveryRoute, /reason: "inactive_180d"/);
  assert.match(envExample, /^CLIENT_INACTIVITY_ACCOUNT_AUTO_DELETE_ENABLED=false$/m);
}

function testNoPersonalSubscriptionContactName() {
  const files = [
    path.resolve(__dirname, "../../lib/main.dart"),
    path.resolve(__dirname, "../../lib/screens/system_tests_screen.dart"),
    path.resolve(__dirname, "../../test/messenger_ui_helpers_test.dart"),
  ];
  const blockedName = ["Ваз", "ген"].join("");
  for (const file of files) {
    const source = fs.readFileSync(file, "utf8");
    assert.doesNotMatch(source, new RegExp(blockedName), file);
  }
}

function testPlatformCreatorFlagIsReturnedToClient() {
  const authRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/auth.js"),
    "utf8",
  );
  const profileRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/profile.js"),
    "utf8",
  );
  const authService = fs.readFileSync(
    path.resolve(__dirname, "../../lib/services/auth_service.dart"),
    "utf8",
  );
  assert.match(authRoute, /is_platform_creator: isPlatformCreator/);
  assert.match(profileRoute, /is_platform_creator: req\.user\?\.is_platform_creator === true/);
  assert.match(authService, /final bool isPlatformCreator/);
  assert.match(authService, /m\['is_platform_creator'\]/);
}

function testPhoneAccessDefaultDoesNotRestrictMissingTenant() {
  const authRoute = fs.readFileSync(
    path.resolve(__dirname, "../src/routes/auth.js"),
    "utf8",
  );
  const authUtil = fs.readFileSync(
    path.resolve(__dirname, "../src/utils/auth.js"),
    "utf8",
  );
  assert.match(authRoute, /if \(!normalizedTenantId\) return false/);
  assert.match(authUtil, /if \(!normalizedTenantId\) return false/);
}

function testPhoneAccessDoesNotExposeFirstOwnerIdentity() {
  const files = [
    path.resolve(__dirname, "../src/utils/phoneAccess.js"),
    path.resolve(__dirname, "../src/utils/auth.js"),
    path.resolve(__dirname, "../../lib/main.dart"),
    path.resolve(__dirname, "../../lib/screens/main_shell.dart"),
    path.resolve(__dirname, "../../lib/screens/phone_access_pending_screen.dart"),
    path.resolve(__dirname, "../../lib/screens/creator_keys_screen.dart"),
  ];
  for (const file of files) {
    const source = fs.readFileSync(file, "utf8");
    assert.doesNotMatch(source, /owner_name|owner_email/, file);
    assert.doesNotMatch(source, /первого владельца|Владелец номера/, file);
    assert.doesNotMatch(source, /доступ к вашей корзине/, file);
  }
}

function testAuthHydrationClearsMissingPhoneAccessState() {
  const authService = fs.readFileSync(
    path.resolve(__dirname, "../../lib/services/auth_service.dart"),
    "utf8",
  );
  assert.match(authService, /final hasPhoneAccessState =/);
  assert.match(authService, /merged\['phone_access_state'\] = 'none'/);
  assert.doesNotMatch(
    authService,
    /merged\['phone_access_state'\]\s*=\s*current\.phoneAccessState/,
  );
}

function testFullDeployStampsWebBuildVersion() {
  const deployFull = fs.readFileSync(
    path.resolve(__dirname, "../../scripts/deploy_full.sh"),
    "utf8",
  );
  assert.match(deployFull, /install_web_build_version_marker\(\)/);
  assert.match(deployFull, /web_build_token/);
  assert.match(deployFull, /WEB_DEPLOYED_AT/);
}

function testAndroidReleaseUsesProductionDownloadsRoot() {
  const files = [
    path.resolve(__dirname, "../../scripts/deploy_full.sh"),
    path.resolve(__dirname, "../../scripts/release_android_update.sh"),
    path.resolve(__dirname, "../../scripts/ANDROID_UPDATE_RELEASE.md"),
    path.resolve(__dirname, "../../docs/ROLLBACK_PLAYBOOK.md"),
    path.resolve(__dirname, "../.env.example"),
    path.resolve(__dirname, "../.env.local.example"),
  ];
  for (const file of files) {
    const source = fs.readFileSync(file, "utf8");
    assert.doesNotMatch(source, /\/opt\/fenix\/server\/downloads/);
    assert.doesNotMatch(source, /fenix-1\.0\.1\.apk/);
  }

  const deployFull = fs.readFileSync(
    path.resolve(__dirname, "../../scripts/deploy_full.sh"),
    "utf8",
  );
  const releaseAndroid = fs.readFileSync(
    path.resolve(__dirname, "../../scripts/release_android_update.sh"),
    "utf8",
  );
  const rollbackPlaybook = fs.readFileSync(
    path.resolve(__dirname, "../../docs/ROLLBACK_PLAYBOOK.md"),
    "utf8",
  );
  assert.match(
    deployFull,
    /REMOTE_DOWNLOADS_DIR="\$\{REMOTE_DOWNLOADS_DIR:-\/opt\/fenix-data\/downloads\}"/,
  );
  assert.match(
    releaseAndroid,
    /REMOTE_DOWNLOADS_DIR="\$\{REMOTE_DOWNLOADS_DIR:-\/opt\/fenix-data\/downloads\}"/,
  );
  assert.match(rollbackPlaybook, /\/opt\/fenix-data\/downloads/);
}

function testNoHardcodedPlatformOwnerIdentity() {
  const roots = [
    path.resolve(__dirname, "../../lib"),
    path.resolve(__dirname, "../src"),
    path.resolve(__dirname, "../scripts"),
    path.resolve(__dirname, "../../audit"),
  ];
  const files = [
    ...roots.flatMap(listFilesRecursive),
    path.resolve(__dirname, "../.env.example"),
  ].filter((file) => /\.(dart|js|md|example)$/.test(file));
  const blockedEmail = ["zerotwo02166", "gmail.com"].join("@");
  const blockedCreatorField = ["_creator", "Email"].join("");
  const blockedCreatorComment = ["special creator", "email"].join(" ");
  const blockedPatterns = [
    new RegExp(blockedEmail.replace(".", "\\."), "i"),
    new RegExp(blockedCreatorField),
    new RegExp(blockedCreatorComment, "i"),
  ];

  for (const file of files) {
    const source = fs.readFileSync(file, "utf8");
    for (const pattern of blockedPatterns) {
      assert.doesNotMatch(source, pattern, file);
    }
  }
}

testDefaults();
testCityListPersistence();
testTopLevelAndNestedFlags();
testWorkflowPayloadCompatibility();
testTenantScopedEmailMigration();
testInviteJoinUsesTenantScopedEmailLookup();
testAmbiguousLoginRequestsTenantSelection();
testAuthRecoveryUsesScopedEmailTokens();
testAuthRecoveryAndEmailPreflightAreTenantScoped();
testLegacyBootstrapScansTenantSessionScopes();
testRefreshHydratesLegacyTenantNullUsers();
testAuthMiddlewareHydratesLegacyTenantNullUsers();
testNotificationInboxDedupeIsAtomic();
testManualRevisionUsesManualShelfKeys();
testProductDescriptionOptionalProjectWide();
testClientCancelAnytimeHandlesDeliveryBatchLinks();
testNightlyAuditChecksTenantFeaturePolicy();
testNightlyAuditChecksNotificationQueueAcrossTenantScopes();
testNightlyAuditChecksMonitoringBacklogAcrossTenantScopes();
testNightlyAuditChecksTenantMigrationDrift();
testNightlyAuditChecksSchemaContractProjectWide();
testNightlyAuditChecksTenantUserIndexDrift();
testAuthSessionsArePersistentProjectWide();
testNightlyAuditChecksAuthSessionsProjectWide();
testNightlyAuditChecksAuthIdentityProjectWide();
testNightlyAuditChecksAuthEmailTokensProjectWide();
testSessionBootstrapE2ECoversRefreshAndPersistentSessions();
testUploadRecoveryScriptsAreTenantAware();
testNightlyAuditChecksUploadRecoveryHealth();
testNightlyAuditChecksProductCartIntegrityProjectWide();
testNightlyAuditChecksPublicationPipelineProjectWide();
testNightlyAuditChecksChatRecencyProjectWide();
testReleaseAuditRunsBeforeDeployAndIncludesBusinessGates();
testGithubActionsHealthCheckExplainsRunnerStartupFailures();
testGithubCiRunsReleaseGuards();
testGithubWorkflowSecretsAreCheckedInsideSteps();
testNotificationWorkerTenantScopes();
testNoTenantSpecificWorkflowHardcode();
testNoRealPersonExamplesInDemoDataAndHints();
testWorkerDeliveryAssemblyFeatureFlag();
testDeliveryLocalityNormalizerIsGeneric();
testPublicAuthErrorsUseNeutralSupportWording();
testUnreachableFirstCallAutoDeleteDefaultsOff();
testInactiveClientAccountAutoDeleteDefaultsOff();
testNoPersonalSubscriptionContactName();
testPlatformCreatorFlagIsReturnedToClient();
testPhoneAccessDefaultDoesNotRestrictMissingTenant();
testPhoneAccessDoesNotExposeFirstOwnerIdentity();
testAuthHydrationClearsMissingPhoneAccessState();
testFullDeployStampsWebBuildVersion();
testAndroidReleaseUsesProductionDownloadsRoot();
testNoHardcodedPlatformOwnerIdentity();

console.log("business-settings-unit: ok");
