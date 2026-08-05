#!/usr/bin/env node

const assert = require("assert/strict");
const fs = require("fs");
const path = require("path");

const {
  normalizeTenantFeatureSettings,
} = require("../src/utils/tenantFeatureSettings");

function testDefaults() {
  const settings = normalizeTenantFeatureSettings();
  assert.equal(settings.client_group_switcher_enabled, true);
  assert.equal(settings.qr_existing_client_join_enabled, true);
  assert.equal(settings.dangerous_action_audit_enabled, true);
  assert.equal(settings.product_change_history_enabled, false);
  assert.equal(settings.client_cancel_anytime_enabled, false);
  assert.equal(settings.delivery.client_cancel_anytime_enabled, false);
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

testDefaults();
testCityListPersistence();
testTopLevelAndNestedFlags();
testWorkflowPayloadCompatibility();
testTenantScopedEmailMigration();
testInviteJoinUsesTenantScopedEmailLookup();

console.log("business-settings-unit: ok");
