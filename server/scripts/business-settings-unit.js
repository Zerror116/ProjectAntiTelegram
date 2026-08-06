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
  assert.equal(settings.client_cancel_anytime_enabled, false);
  assert.equal(settings.delivery.client_cancel_anytime_enabled, false);
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
    assert.doesNotMatch(source, /kinel-8997|anna-utevskaya-4898/);
    assert.doesNotMatch(source, /iskineltenantscope|isannaut/);
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
  }
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
testNotificationWorkerTenantScopes();
testNoTenantSpecificWorkflowHardcode();
testWorkerDeliveryAssemblyFeatureFlag();
testDeliveryLocalityNormalizerIsGeneric();
testPublicAuthErrorsUseNeutralSupportWording();
testUnreachableFirstCallAutoDeleteDefaultsOff();
testPlatformCreatorFlagIsReturnedToClient();
testPhoneAccessDefaultDoesNotRestrictMissingTenant();
testAndroidReleaseUsesProductionDownloadsRoot();
testNoHardcodedPlatformOwnerIdentity();

console.log("business-settings-unit: ok");
