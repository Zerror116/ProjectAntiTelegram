const { v4: uuidv4 } = require("uuid");

function normalizeSettings(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw;
}

function mergeJson(base, patch) {
  return { ...base, ...patch };
}

async function ensureStaffMembers(
  client,
  chatId,
  tenantId,
  { removeNonStaff = false, includeWorkers = false } = {},
) {
  const allowedRoles = includeWorkers
    ? ["worker", "admin", "creator"]
    : ["admin", "creator"];

  if (removeNonStaff) {
    await client.query(
      `DELETE FROM chat_members cm
       USING users u
       WHERE cm.chat_id = $1
         AND cm.user_id = u.id
         AND ($3::uuid IS NULL OR u.tenant_id = $3::uuid)
         AND u.role <> ALL($2::text[])`,
      [chatId, allowedRoles, tenantId || null],
    );
  }

  const staffQ = await client.query(
    `SELECT id, role
     FROM users
     WHERE role = ANY($1::text[])
       AND ($2::uuid IS NULL OR tenant_id = $2::uuid)`,
    [allowedRoles, tenantId || null],
  );

  for (const staff of staffQ.rows) {
    const normalizedRole = String(staff.role || "").toLowerCase();
    const memberRole =
      normalizedRole === "creator"
        ? "owner"
        : normalizedRole === "admin"
          ? "moderator"
          : "member";
    await client.query(
      `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
       VALUES ($1, $2, $3, now(), $4)
       ON CONFLICT (chat_id, user_id) DO NOTHING`,
      [uuidv4(), chatId, staff.id, memberRole],
    );
  }
}

async function findMainChannel(client, tenantId = null) {
  return client.query(
    `SELECT id, title, type, created_by, settings, created_at, updated_at
     FROM chats
     WHERE type = 'channel'
       AND ($1::uuid IS NULL OR tenant_id = $1::uuid)
       AND (
         COALESCE(settings->>'system_key', '') = 'main_channel'
         OR (
           COALESCE(settings->>'kind', 'channel') = 'channel'
           AND COALESCE((settings->>'admin_only')::boolean, false) = false
           AND (
             COALESCE((settings->>'is_post_channel')::boolean, false) = true
             OR LOWER(TRIM(title)) = 'основной канал'
           )
         )
       )
     ORDER BY
       CASE WHEN COALESCE(settings->>'system_key', '') = 'main_channel' THEN 0 ELSE 1 END,
       updated_at DESC NULLS LAST,
       created_at DESC
     LIMIT 1`,
    [tenantId || null],
  );
}

async function findReservedChannel(client, tenantId = null) {
  return client.query(
    `SELECT id, title, type, created_by, settings, created_at, updated_at
     FROM chats
     WHERE type = 'channel'
       AND ($1::uuid IS NULL OR tenant_id = $1::uuid)
       AND (
         COALESCE(settings->>'system_key', '') = 'reserved_orders'
         OR COALESCE(settings->>'kind', '') = 'reserved_orders'
         OR LOWER(TRIM(title)) = 'забронированный товар'
       )
     ORDER BY
       CASE WHEN COALESCE(settings->>'system_key', '') = 'reserved_orders' THEN 0 ELSE 1 END,
       updated_at DESC NULLS LAST,
       created_at DESC
     LIMIT 1`,
    [tenantId || null],
  );
}

async function ensureMainChannel(client, createdBy, tenantId = null) {
  const mainQ = await findMainChannel(client, tenantId);

  const baseSettings = {
    kind: "channel",
    system_key: "main_channel",
    tenant_id: tenantId || null,
    visibility: "public",
    worker_can_post: true,
    is_post_channel: true,
    admin_only: false,
    description: "Основной канал с товарами",
  };

  if (mainQ.rowCount > 0) {
    const current = mainQ.rows[0];
    const currentSettings = normalizeSettings(current.settings);
    const nextSettings = mergeJson(currentSettings, baseSettings);

    const updated = await client.query(
      `UPDATE chats
       SET title = $1,
           settings = $2::jsonb,
           tenant_id = $4,
           updated_at = now()
       WHERE id = $3
       RETURNING id, title, type, created_by, settings, created_at, updated_at`,
      [
        current.title || "Основной канал",
        JSON.stringify(nextSettings),
        current.id,
        tenantId || null,
      ],
    );

    await client.query(
      `UPDATE chats
       SET settings = jsonb_set(COALESCE(settings, '{}'::jsonb), '{is_post_channel}', 'false'::jsonb, true),
           updated_at = now()
       WHERE type = 'channel'
         AND ($2::uuid IS NULL OR tenant_id = $2::uuid)
         AND id <> $1`,
      [updated.rows[0].id, tenantId || null],
    );

    await client.query(
      `UPDATE chats
       SET settings = jsonb_set(COALESCE(settings, '{}'::jsonb), '{is_post_channel}', 'true'::jsonb, true),
           updated_at = now()
       WHERE id = $1`,
      [updated.rows[0].id],
    );

    return { channel: updated.rows[0], created: false };
  }

  const inserted = await client.query(
    `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
     VALUES ($1, $2, 'channel', $3, $4, $5::jsonb, now(), now())
     RETURNING id, title, type, created_by, settings, created_at, updated_at`,
    [
      uuidv4(),
      "Основной канал",
      createdBy || null,
      tenantId || null,
      JSON.stringify(baseSettings),
    ],
  );

  await client.query(
    `UPDATE chats
     SET settings = jsonb_set(COALESCE(settings, '{}'::jsonb), '{is_post_channel}', 'false'::jsonb, true),
         updated_at = now()
     WHERE type = 'channel'
       AND ($2::uuid IS NULL OR tenant_id = $2::uuid)
       AND id <> $1`,
    [inserted.rows[0].id, tenantId || null],
  );

  return { channel: inserted.rows[0], created: true };
}

async function ensureReservedOrdersChannel(client, createdBy, tenantId = null) {
  const reservedQ = await findReservedChannel(client, tenantId);
  const baseSettings = {
    kind: "reserved_orders",
    system_key: "reserved_orders",
    tenant_id: tenantId || null,
    visibility: "private",
    admin_only: false,
    worker_can_post: false,
    is_post_channel: false,
    description: "Служебный канал заказов клиентов для сборки",
  };

  if (reservedQ.rowCount > 0) {
    const current = reservedQ.rows[0];
    const currentSettings = normalizeSettings(current.settings);
    const nextSettings = mergeJson(currentSettings, baseSettings);
    const updated = await client.query(
      `UPDATE chats
       SET title = $1,
           settings = $2::jsonb,
           tenant_id = $4,
           updated_at = now()
       WHERE id = $3
       RETURNING id, title, type, created_by, settings, created_at, updated_at`,
      [
        current.title || "Забронированный товар",
        JSON.stringify(nextSettings),
        current.id,
        tenantId || null,
      ],
    );

    await ensureStaffMembers(client, updated.rows[0].id, tenantId, {
      removeNonStaff: true,
      includeWorkers: true,
    });
    return { channel: updated.rows[0], created: false };
  }

  const inserted = await client.query(
    `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
     VALUES ($1, $2, 'channel', $3, $4, $5::jsonb, now(), now())
     RETURNING id, title, type, created_by, settings, created_at, updated_at`,
    [
      uuidv4(),
      "Забронированный товар",
      createdBy || null,
      tenantId || null,
      JSON.stringify(baseSettings),
    ],
  );

  await ensureStaffMembers(client, inserted.rows[0].id, tenantId, {
    removeNonStaff: true,
    includeWorkers: true,
  });
  return { channel: inserted.rows[0], created: true };
}

async function ensureSystemChannels(client, createdBy, tenantId = null) {
  const main = await ensureMainChannel(client, createdBy, tenantId);
  const reserved = await ensureReservedOrdersChannel(client, createdBy, tenantId);
  return {
    mainChannel: main.channel,
    reservedChannel: reserved.channel,
    created: {
      main: main.created,
      reserved: reserved.created,
    },
  };
}

module.exports = {
  ensureSystemChannels,
  ensureStaffMembers,
  normalizeSettings,
};
