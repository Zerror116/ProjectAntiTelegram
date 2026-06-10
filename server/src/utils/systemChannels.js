const { v4: uuidv4 } = require("uuid");
const { Pool } = require("pg");
const { encryptMessageText, decryptMessageRow } = require("./messageCrypto");
const { emitToTenant } = require("./socket");

function normalizeSettings(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw;
}

function mergeWithSystemDuplicateFlags(settings, archivedSystemKey) {
  const base = normalizeSettings(settings);
  return {
    ...base,
    kind: "system_duplicate",
    system_key: archivedSystemKey,
    hidden_in_chat_list: true,
    visibility: "private",
    is_post_channel: false,
    worker_can_post: false,
  };
}

async function listSystemDuplicates(client, tenantId, keepId, systemKey) {
  if (systemKey === "main_channel") {
    const q = await client.query(
      `SELECT id, title, settings
       FROM chats
       WHERE type = 'channel'
         AND ($1::uuid IS NULL OR tenant_id = $1::uuid)
         AND id <> $2
         AND (
           COALESCE(settings->>'system_key', '') = 'main_channel'
           OR COALESCE((settings->>'is_post_channel')::boolean, false) = true
           OR LOWER(TRIM(title)) = 'основной канал'
         )`,
      [tenantId || null, keepId],
    );
    return q.rows;
  }

  if (systemKey === "posts_archive") {
    const q = await client.query(
      `SELECT id, title, settings
       FROM chats
       WHERE type = 'channel'
         AND ($1::uuid IS NULL OR tenant_id = $1::uuid)
         AND id <> $2
         AND (
           COALESCE(settings->>'system_key', '') = 'posts_archive'
           OR COALESCE(settings->>'kind', '') = 'posts_archive'
           OR LOWER(TRIM(title)) = 'архив постов'
         )`,
      [tenantId || null, keepId],
    );
    return q.rows;
  }

  const q = await client.query(
    `SELECT id, title, settings
     FROM chats
     WHERE type = 'channel'
       AND ($1::uuid IS NULL OR tenant_id = $1::uuid)
       AND id <> $2
       AND (
         COALESCE(settings->>'system_key', '') = 'reserved_orders'
         OR COALESCE(settings->>'kind', '') = 'reserved_orders'
         OR LOWER(TRIM(title)) = 'забронированный товар'
       )`,
    [tenantId || null, keepId],
  );
  return q.rows;
}

async function consolidateSystemDuplicates(client, tenantId, keepId, systemKey) {
  const duplicates = await listSystemDuplicates(client, tenantId, keepId, systemKey);
  if (!Array.isArray(duplicates) || duplicates.length === 0) return;
  const duplicateIds = duplicates
    .map((row) => String(row.id || "").trim())
    .filter(Boolean);
  if (duplicateIds.length === 0) return;

  await client.query(
    `UPDATE product_publication_queue
     SET channel_id = $1
     WHERE channel_id = ANY($2::uuid[])
       AND status = 'pending'
       AND COALESCE(is_sent, false) = false`,
    [keepId, duplicateIds],
  );

  await client.query(
    `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
     SELECT gen_random_uuid(), $1, cm.user_id, now(), cm.role
     FROM chat_members cm
     WHERE cm.chat_id = ANY($2::uuid[])
     ON CONFLICT (chat_id, user_id) DO NOTHING`,
    [keepId, duplicateIds],
  );

  await client.query(
    `UPDATE messages
     SET chat_id = $1
     WHERE chat_id = ANY($2::uuid[])`,
    [keepId, duplicateIds],
  );

  await client.query(
    `UPDATE message_reads mr
     SET chat_id = $1
     FROM messages m
     WHERE mr.message_id = m.id
       AND mr.chat_id = ANY($2::uuid[])
       AND m.chat_id = $1`,
    [keepId, duplicateIds],
  );

  const archivedSystemKey =
    systemKey === "main_channel"
      ? "archived_main_channel_duplicate"
      : systemKey === "posts_archive"
        ? "archived_posts_archive_duplicate"
        : "archived_reserved_orders_duplicate";

  for (const row of duplicates) {
    const currentSettings = normalizeSettings(row.settings);
    const nextSettings = mergeWithSystemDuplicateFlags(
      currentSettings,
      archivedSystemKey,
    );
    await client.query(
      `UPDATE chats
       SET settings = $2::jsonb,
           updated_at = now(),
           title = CASE
             WHEN LOWER(TRIM(title)) LIKE '%дубликат%' THEN title
             ELSE title || ' (дубликат)'
           END
       WHERE id = $1`,
      [row.id, JSON.stringify(nextSettings)],
    );
  }

  await client.query(
    `UPDATE chats
     SET updated_at = now()
     WHERE id = $1`,
    [keepId],
  );
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
    ? ["worker", "admin", "tenant", "creator"]
    : ["admin", "tenant", "creator"];

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
       AND (
         $2::uuid IS NULL
         OR tenant_id = $2::uuid
         OR (role = 'creator' AND tenant_id IS NULL)
       )`,
    [allowedRoles, tenantId || null],
  );

  for (const staff of staffQ.rows) {
    const normalizedRole = String(staff.role || "").toLowerCase();
    const memberRole =
      normalizedRole === "creator"
        ? "owner"
        : normalizedRole === "admin" || normalizedRole === "tenant"
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

async function findPostsArchiveChannel(client, tenantId = null) {
  return client.query(
    `SELECT id, title, type, created_by, settings, created_at, updated_at
     FROM chats
     WHERE type = 'channel'
       AND ($1::uuid IS NULL OR tenant_id = $1::uuid)
       AND (
         COALESCE(settings->>'system_key', '') = 'posts_archive'
         OR COALESCE(settings->>'kind', '') = 'posts_archive'
         OR LOWER(TRIM(title)) = 'архив постов'
       )
     ORDER BY
       CASE WHEN COALESCE(settings->>'system_key', '') = 'posts_archive' THEN 0 ELSE 1 END,
       updated_at DESC NULLS LAST,
       created_at DESC
     LIMIT 1`,
    [tenantId || null],
  );
}

async function ensurePostsArchiveChannel(client, createdBy, tenantId = null) {
  const archiveQ = await findPostsArchiveChannel(client, tenantId);
  const baseSettings = {
    kind: "posts_archive",
    system_key: "posts_archive",
    tenant_id: tenantId || null,
    visibility: "private",
    admin_only: true,
    worker_can_post: false,
    is_post_channel: false,
    hidden_in_chat_list: false,
    description:
      "Системный архив всех постов товаров. Доступен только администраторам и создателю.",
  };

  if (archiveQ.rowCount > 0) {
    const current = archiveQ.rows[0];
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
        current.title || "Архив постов",
        JSON.stringify(nextSettings),
        current.id,
        tenantId || null,
      ],
    );

    await ensureStaffMembers(client, updated.rows[0].id, tenantId, {
      removeNonStaff: true,
      includeWorkers: false,
    });
    return { channel: updated.rows[0], created: false };
  }

  const inserted = await client.query(
    `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
     VALUES ($1, $2, 'channel', $3, $4, $5::jsonb, now(), now())
     RETURNING id, title, type, created_by, settings, created_at, updated_at`,
    [
      uuidv4(),
      "Архив постов",
      createdBy || null,
      tenantId || null,
      JSON.stringify(baseSettings),
    ],
  );

  await ensureStaffMembers(client, inserted.rows[0].id, tenantId, {
    removeNonStaff: true,
    includeWorkers: false,
  });
  return { channel: inserted.rows[0], created: true };
}

async function findAdminSystemChat(client, tenantId = null) {
  return client.query(
    `SELECT id, title, type, created_by, settings, created_at, updated_at
     FROM chats
     WHERE type <> 'channel'
       AND ($1::uuid IS NULL OR tenant_id = $1::uuid)
       AND (
         COALESCE(settings->>'system_key', '') = 'admin_system'
         OR COALESCE(settings->>'kind', '') = 'admin_system'
         OR LOWER(TRIM(title)) = 'система'
       )
     ORDER BY
       CASE WHEN COALESCE(settings->>'system_key', '') = 'admin_system' THEN 0 ELSE 1 END,
       updated_at DESC NULLS LAST,
       created_at DESC
     LIMIT 1`,
    [tenantId || null],
  );
}

async function ensureAdminSystemChat(client, createdBy, tenantId = null) {
  const systemQ = await findAdminSystemChat(client, tenantId);
  const baseSettings = {
    kind: "admin_system",
    system_key: "admin_system",
    tenant_id: tenantId || null,
    visibility: "private",
    admin_only: true,
    worker_can_post: false,
    is_post_channel: false,
    description: "Системные уведомления для администраторов",
  };

  if (systemQ.rowCount > 0) {
    const current = systemQ.rows[0];
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
        current.title || "Система",
        JSON.stringify(nextSettings),
        current.id,
        tenantId || null,
      ],
    );

    await ensureStaffMembers(client, updated.rows[0].id, tenantId, {
      removeNonStaff: true,
      includeWorkers: false,
    });
    if (createdBy) {
      await client.query(
        `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
         VALUES ($1, $2, $3, now(), 'owner')
         ON CONFLICT (chat_id, user_id) DO UPDATE SET role = EXCLUDED.role`,
        [uuidv4(), updated.rows[0].id, createdBy],
      );
    }
    return { chat: updated.rows[0], created: false };
  }

  const inserted = await client.query(
    `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
     VALUES ($1, 'Система', 'private', $2, $3, $4::jsonb, now(), now())
     RETURNING id, title, type, created_by, settings, created_at, updated_at`,
    [uuidv4(), createdBy || null, tenantId || null, JSON.stringify(baseSettings)],
  );

  await ensureStaffMembers(client, inserted.rows[0].id, tenantId, {
    removeNonStaff: true,
    includeWorkers: false,
  });
  if (createdBy) {
    await client.query(
      `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
       VALUES ($1, $2, $3, now(), 'owner')
       ON CONFLICT (chat_id, user_id) DO UPDATE SET role = EXCLUDED.role`,
      [uuidv4(), inserted.rows[0].id, createdBy],
    );
  }
  return { chat: inserted.rows[0], created: true };
}

async function findDiscussionsChat(client, tenantId = null) {
  return client.query(
    `SELECT id, title, type, created_by, settings, created_at, updated_at
     FROM chats
     WHERE type = 'private'
       AND ($1::uuid IS NULL OR tenant_id = $1::uuid)
       AND (
         COALESCE(settings->>'system_key', '') = 'discussions'
         OR COALESCE(settings->>'kind', '') = 'discussions'
         OR LOWER(TRIM(title)) = 'обсуждения'
       )
     ORDER BY
       CASE WHEN COALESCE(settings->>'system_key', '') = 'discussions' THEN 0 ELSE 1 END,
       updated_at DESC NULLS LAST,
       created_at DESC
     LIMIT 1`,
    [tenantId || null],
  );
}

async function findPlatformDiscussionsChat(client) {
  return client.query(
    `SELECT id, title, type, created_by, settings, created_at, updated_at
     FROM chats
     WHERE type = 'private'
       AND tenant_id IS NULL
       AND (
         COALESCE(settings->>'system_key', '') = 'platform_discussions'
         OR COALESCE(settings->>'kind', '') = 'platform_discussions'
       )
     ORDER BY
       CASE WHEN COALESCE(settings->>'system_key', '') = 'platform_discussions' THEN 0 ELSE 1 END,
       updated_at DESC NULLS LAST,
       created_at DESC
     LIMIT 1`,
  );
}

async function ensureDiscussionBaseMembers(client, chatId, tenantId, createdBy = null) {
  const memberQ = await client.query(
    `SELECT id, role
     FROM users
     WHERE (
       role = 'tenant'
       AND ($1::uuid IS NULL OR tenant_id = $1::uuid)
     )
     OR (
       role = 'creator'
       AND (
         tenant_id IS NULL
         OR $1::uuid IS NULL
         OR tenant_id = $1::uuid
       )
     )
     OR id = $2::uuid`,
    [tenantId || null, createdBy || null],
  );

  for (const row of memberQ.rows) {
    const role = String(row.role || "").toLowerCase().trim();
    const memberRole = role === "creator" ? "owner" : "member";
    await client.query(
      `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
       VALUES ($1, $2, $3, now(), $4)
       ON CONFLICT (chat_id, user_id)
       DO UPDATE SET role = CASE
         WHEN EXCLUDED.role = 'owner' THEN 'owner'
         ELSE chat_members.role
       END`,
      [uuidv4(), chatId, row.id, memberRole],
    );
  }
}

function normalizeDiscussionUserRole(rawRole) {
  const role = String(rawRole || "client").toLowerCase().trim();
  return ["client", "worker", "admin", "tenant", "creator"].includes(role)
    ? role
    : "client";
}

function normalizeDiscussionEmail(rawEmail) {
  return String(rawEmail || "").trim().toLowerCase();
}

function fallbackDiscussionName(email, role = "client") {
  const localPart = String(email || "").split("@")[0]?.trim();
  if (localPart) return localPart;
  return role === "tenant" ? "Арендатор" : "Пользователь";
}

function normalizeDiscussionRemovedUserIds(settings) {
  const raw = normalizeSettings(settings).discussion_removed_user_ids;
  if (!Array.isArray(raw)) return [];
  return raw
    .map((value) => String(value || "").trim())
    .filter((value) =>
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
        value,
      ),
    );
}

function isPoolLikeQueryable(queryable) {
  return (
    queryable &&
    typeof queryable.connect === "function" &&
    typeof queryable.release !== "function"
  );
}

async function prepareUnscopedPlatformClient(client) {
  await client.query("SELECT set_config('app.tenant_id', '', false)");
  await client.query("SELECT set_config('search_path', 'public', false)");
}

async function withUnscopedPlatformClient(queryable, fn) {
  if (isPoolLikeQueryable(queryable)) {
    const client = await queryable.connect();
    try {
      await prepareUnscopedPlatformClient(client);
      return await fn(client);
    } finally {
      client.release();
    }
  }
  await prepareUnscopedPlatformClient(queryable);
  return await fn(queryable);
}

async function ensurePlatformDiscussionUserShadow(queryable, user = {}) {
  if (isPoolLikeQueryable(queryable)) {
    return withUnscopedPlatformClient(queryable, (client) =>
      ensurePlatformDiscussionUserShadow(client, user),
    );
  }
  const client = queryable;
  await prepareUnscopedPlatformClient(client);

  const userId = String(user?.id || user?.user_id || "").trim();
  if (!userId) return null;

  const email = normalizeDiscussionEmail(user?.email);
  const role = normalizeDiscussionUserRole(user?.base_role || user?.role);
  const name = String(user?.name || "").trim() || fallbackDiscussionName(email, role);
  const tenantId = String(user?.tenant_id || "").trim() || null;

  let emailForUsers = email;
  if (emailForUsers) {
    const duplicateEmailQ = await client.query(
      `SELECT id
       FROM users
       WHERE lower(email) = $1
         AND id <> $2::uuid
       LIMIT 1`,
      [emailForUsers, userId],
    );
    if (duplicateEmailQ.rowCount > 0) {
      emailForUsers = "";
    }
  }

  const existingQ = await client.query(
    `SELECT id, email
     FROM users
     WHERE id = $1::uuid
     LIMIT 1`,
    [userId],
  );
  const existing = existingQ.rows[0] || null;

  if (existing) {
    const updateValues = [userId, role, name, tenantId];
    const emailSet = emailForUsers ? ", email = COALESCE(NULLIF($5, ''), email)" : "";
    if (emailForUsers) updateValues.push(emailForUsers);
    const updatedQ = await client.query(
      `UPDATE users
       SET role = CASE
             WHEN role = 'creator' THEN 'creator'
             ELSE $2
           END,
           name = COALESCE(NULLIF(BTRIM(name), ''), $3),
           tenant_id = COALESCE(tenant_id, $4::uuid),
           is_active = true,
           updated_at = now()
           ${emailSet}
       WHERE id = $1::uuid
       RETURNING id, email, role`,
      updateValues,
    );
    return updatedQ.rows[0] || existing;
  }

  const insertedQ = await client.query(
    `INSERT INTO users (
       id,
       email,
       role,
       name,
       is_active,
       tenant_id,
       created_at,
       updated_at
     )
     VALUES ($1::uuid, NULLIF($2, ''), $3, $4, true, $5::uuid, now(), now())
     ON CONFLICT (id) DO UPDATE
     SET role = CASE
           WHEN users.role = 'creator' THEN 'creator'
           ELSE EXCLUDED.role
         END,
         name = COALESCE(NULLIF(BTRIM(users.name), ''), EXCLUDED.name),
         tenant_id = COALESCE(users.tenant_id, EXCLUDED.tenant_id),
         is_active = true,
         updated_at = now()
     RETURNING id, email, role`,
    [userId, emailForUsers, role, name, tenantId],
  );
  return insertedQ.rows[0] || null;
}

async function syncPlatformDiscussionIndexedUsers(queryable, roles = null) {
  if (isPoolLikeQueryable(queryable)) {
    return withUnscopedPlatformClient(queryable, (client) =>
      syncPlatformDiscussionIndexedUsers(client, roles),
    );
  }
  const client = queryable;
  await prepareUnscopedPlatformClient(client);

  const normalizedRoles = Array.isArray(roles)
    ? roles.map(normalizeDiscussionUserRole).filter(Boolean)
    : null;
  await client.query(
    `WITH indexed_users AS (
       SELECT tui.user_id,
              lower(tui.email) AS email,
              CASE
                WHEN lower(tui.role) IN ('client', 'worker', 'admin', 'tenant', 'creator')
                  THEN lower(tui.role)
                ELSE 'client'
              END AS role,
              COALESCE(NULLIF(split_part(lower(tui.email), '@', 1), ''), 'Пользователь') AS name,
              COALESCE(tui.is_active, true) AS is_active,
              tui.tenant_id,
              COALESCE(tui.created_at, now()) AS created_at,
              COALESCE(tui.updated_at, tui.created_at, now()) AS indexed_at
       FROM tenant_user_index tui
       WHERE COALESCE(tui.is_active, true) = true
         AND NULLIF(BTRIM(tui.email), '') IS NOT NULL
         AND ($1::text[] IS NULL OR lower(tui.role) = ANY($1::text[]))
     ),
     ranked_users AS (
       SELECT *,
              row_number() OVER (
                PARTITION BY user_id
                ORDER BY indexed_at DESC, created_at DESC, tenant_id ASC
              ) AS user_rank,
              row_number() OVER (
                PARTITION BY email
                ORDER BY indexed_at DESC, created_at DESC, user_id ASC
              ) AS email_rank
       FROM indexed_users
     )
     INSERT INTO users (
       id,
       email,
       role,
       name,
       is_active,
       tenant_id,
       created_at,
       updated_at
     )
     SELECT user_id,
            email,
            role,
            name,
            is_active,
            tenant_id,
            created_at,
            now()
     FROM ranked_users
     WHERE user_rank = 1
       AND email_rank = 1
       AND NOT EXISTS (
         SELECT 1
         FROM users existing
         WHERE lower(existing.email) = ranked_users.email
           AND existing.id <> ranked_users.user_id
       )
     ON CONFLICT (id) DO UPDATE
     SET role = CASE
           WHEN users.role = 'creator' THEN 'creator'
           ELSE EXCLUDED.role
         END,
         email = COALESCE(NULLIF(users.email, ''), EXCLUDED.email),
         name = COALESCE(NULLIF(BTRIM(users.name), ''), EXCLUDED.name),
         tenant_id = COALESCE(users.tenant_id, EXCLUDED.tenant_id),
         is_active = EXCLUDED.is_active,
         updated_at = now()`,
    [normalizedRoles && normalizedRoles.length > 0 ? normalizedRoles : null],
  );
}

async function upsertPlatformDiscussionShadowUser(client, user, fallbackTenantId = null) {
  const userId = String(user?.id || user?.user_id || "").trim();
  if (!userId) return;

  const email = normalizeDiscussionEmail(user?.email);
  const role = normalizeDiscussionUserRole(user?.role);
  const name =
    String(user?.name || "").trim() ||
    String(user?.phone || "").trim() ||
    fallbackDiscussionName(email, role);
  const tenantId = String(user?.tenant_id || fallbackTenantId || "").trim() || null;
  const isActive = user?.is_active !== false;
  const createdAt = user?.created_at || new Date();

  let emailForUsers = email;
  if (emailForUsers) {
    const duplicateEmailQ = await client.query(
      `SELECT id
       FROM users
       WHERE lower(email) = $1
         AND id <> $2::uuid
       LIMIT 1`,
      [emailForUsers, userId],
    );
    if (duplicateEmailQ.rowCount > 0) {
      emailForUsers = "";
    }
  }

  await client.query(
    `INSERT INTO users (
       id,
       email,
       role,
       name,
       is_active,
       tenant_id,
       created_at,
       updated_at
     )
     VALUES ($1::uuid, NULLIF($2, ''), $3, NULLIF($4, ''), $5, $6::uuid, $7, now())
     ON CONFLICT (id) DO UPDATE
     SET email = COALESCE(NULLIF($2, ''), users.email),
         role = CASE
           WHEN users.role = 'creator' THEN 'creator'
           ELSE $3
         END,
         name = COALESCE(NULLIF($4, ''), users.name),
         is_active = $5,
         tenant_id = COALESCE(users.tenant_id, $6::uuid),
         updated_at = now()`,
    [userId, emailForUsers, role, name, isActive, tenantId, createdAt],
  );

  if (tenantId && email) {
    await client.query(
      `INSERT INTO tenant_user_index (
         tenant_id,
         user_id,
         email,
         role,
         is_active,
         created_at,
         updated_at
       )
       VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, now())
       ON CONFLICT (tenant_id, user_id) DO UPDATE
       SET email = EXCLUDED.email,
           role = EXCLUDED.role,
           is_active = EXCLUDED.is_active,
           updated_at = now()`,
      [tenantId, userId, email, role, isActive, createdAt],
    );
  }

  const phone = String(user?.phone || "").trim();
  if (phone) {
    await client.query(
      `INSERT INTO phones (user_id, phone, status, created_at)
       VALUES ($1::uuid, $2, 'pending_verification', now())
       ON CONFLICT (user_id) DO UPDATE
       SET phone = EXCLUDED.phone,
           status = COALESCE(NULLIF(phones.status, ''), EXCLUDED.status)`,
      [userId, phone],
    );
  }
}

async function syncPlatformDiscussionTenantUsers(queryable, roles = null) {
  if (isPoolLikeQueryable(queryable)) {
    return withUnscopedPlatformClient(queryable, (client) =>
      syncPlatformDiscussionTenantUsers(client, roles),
    );
  }
  const client = queryable;
  await prepareUnscopedPlatformClient(client);

  await syncPlatformDiscussionIndexedUsers(client, roles);

  const normalizedRoles = Array.isArray(roles)
    ? roles.map(normalizeDiscussionUserRole).filter(Boolean)
    : null;
  const tenantsQ = await client.query(
    `SELECT id, code, db_url
     FROM tenants
     WHERE COALESCE(is_deleted, false) = false
       AND COALESCE(status, 'active') <> 'deleted'
       AND lower(COALESCE(db_mode, '')) = 'isolated'
       AND NULLIF(BTRIM(db_url), '') IS NOT NULL
       AND lower(COALESCE(code, '')) <> 'default'
     ORDER BY created_at ASC`,
  );

  for (const tenant of tenantsQ.rows) {
    const tenantPool = new Pool({ connectionString: String(tenant.db_url || "") });
    try {
      const tenantUsersQ = await tenantPool.query(
        `SELECT u.id,
                lower(u.email) AS email,
                COALESCE(
                  NULLIF(BTRIM(u.name), ''),
                  NULLIF(p.phone, ''),
                  NULLIF(split_part(lower(u.email), '@', 1), ''),
                  'Пользователь'
                ) AS name,
                lower(COALESCE(NULLIF(BTRIM(u.role), ''), 'client')) AS role,
                COALESCE(u.is_active, true) AS is_active,
                COALESCE(u.tenant_id, $2::uuid) AS tenant_id,
                COALESCE(u.created_at, now()) AS created_at,
                p.phone
         FROM users u
         LEFT JOIN phones p ON p.user_id = u.id
         WHERE COALESCE(u.is_active, true) = true
           AND NULLIF(BTRIM(u.email), '') IS NOT NULL
           AND ($1::text[] IS NULL OR lower(COALESCE(u.role, 'client')) = ANY($1::text[]))
         ORDER BY u.created_at DESC
         LIMIT 5000`,
        [normalizedRoles && normalizedRoles.length > 0 ? normalizedRoles : null, tenant.id],
      );
      for (const row of tenantUsersQ.rows) {
        await upsertPlatformDiscussionShadowUser(client, row, tenant.id);
      }
    } catch (err) {
      console.error("syncPlatformDiscussionTenantUsers tenant sync error", {
        tenant_id: tenant.id,
        tenant_code: tenant.code,
        error: err?.message || String(err),
      });
    } finally {
      await tenantPool.end();
    }
  }
}

async function ensurePlatformDiscussionBaseMembers(client, chatId, createdBy = null) {
  await prepareUnscopedPlatformClient(client);
  await syncPlatformDiscussionTenantUsers(client, ["tenant"]);

  const chatQ = await client.query(
    `SELECT settings
     FROM chats
     WHERE id = $1
     LIMIT 1`,
    [chatId],
  );
  const removedUserIds = normalizeDiscussionRemovedUserIds(
    chatQ.rows[0]?.settings,
  );

  const memberQ = await client.query(
    `SELECT u.id, u.role
     FROM users u
     LEFT JOIN tenants t ON t.id = u.tenant_id
     WHERE u.is_active IS DISTINCT FROM false
       AND (
         u.role = 'creator'
         OR u.id = $1::uuid
         OR (
           u.role = 'tenant'
           AND COALESCE(t.code, '') <> 'default'
         )
       )
       AND (
         u.role = 'creator'
         OR NOT (u.id = ANY($2::uuid[]))
       )
     ORDER BY
       CASE WHEN u.role = 'creator' THEN 0 WHEN u.role = 'tenant' THEN 1 ELSE 2 END,
       COALESCE(NULLIF(BTRIM(t.name), ''), NULLIF(BTRIM(t.code), ''), '') ASC,
       u.created_at ASC`,
    [createdBy || null, removedUserIds],
  );

  for (const row of memberQ.rows) {
    const role = String(row.role || "").toLowerCase().trim();
    const memberRole = role === "creator" ? "owner" : "member";
    await client.query(
      `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
       VALUES ($1, $2, $3, now(), $4)
       ON CONFLICT (chat_id, user_id)
       DO UPDATE SET role = CASE
         WHEN EXCLUDED.role = 'owner' THEN 'owner'
         ELSE chat_members.role
       END`,
      [uuidv4(), chatId, row.id, memberRole],
    );
  }
}

async function ensurePlatformDiscussionsChat(queryable, createdBy = null) {
  if (isPoolLikeQueryable(queryable)) {
    return withUnscopedPlatformClient(queryable, (client) =>
      ensurePlatformDiscussionsChat(client, createdBy),
    );
  }
  const client = queryable;
  await prepareUnscopedPlatformClient(client);

  const discussionsQ = await findPlatformDiscussionsChat(client);
  const baseSettings = {
    kind: "discussions",
    system_key: "platform_discussions",
    tenant_id: null,
    scope: "platform",
    global_discussions: true,
    visibility: "private",
    admin_only: false,
    worker_can_post: false,
    is_post_channel: false,
    creator_managed: true,
    description:
      "Общий закрытый чат для создателя, всех арендаторов и пользователей, которым создатель выдал доступ.",
  };

  if (discussionsQ.rowCount > 0) {
    const current = discussionsQ.rows[0];
    const currentSettings = normalizeSettings(current.settings);
    const nextSettings = mergeJson(currentSettings, baseSettings);
    const updated = await client.query(
      `UPDATE chats
       SET title = COALESCE(NULLIF(BTRIM(title), ''), 'Обсуждения'),
           settings = $2::jsonb,
           tenant_id = NULL,
           updated_at = now()
       WHERE id = $1
       RETURNING id, title, type, created_by, tenant_id, settings, created_at, updated_at`,
      [current.id, JSON.stringify(nextSettings)],
    );
    await ensurePlatformDiscussionBaseMembers(client, updated.rows[0].id, createdBy);
    return { chat: updated.rows[0], created: false };
  }

  const inserted = await client.query(
    `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
     VALUES ($1, 'Обсуждения', 'private', $2, NULL, $3::jsonb, now(), now())
     RETURNING id, title, type, created_by, tenant_id, settings, created_at, updated_at`,
    [uuidv4(), createdBy || null, JSON.stringify(baseSettings)],
  );
  await ensurePlatformDiscussionBaseMembers(client, inserted.rows[0].id, createdBy);
  return { chat: inserted.rows[0], created: true };
}

async function ensureDiscussionsChat(client, createdBy, tenantId = null) {
  const discussionsQ = await findDiscussionsChat(client, tenantId);
  const baseSettings = {
    kind: "discussions",
    system_key: "discussions",
    tenant_id: tenantId || null,
    visibility: "private",
    admin_only: false,
    worker_can_post: false,
    is_post_channel: false,
    creator_managed: true,
    description:
      "Закрытый чат для создателя, арендаторов и пользователей, которым создатель выдал доступ.",
  };

  if (discussionsQ.rowCount > 0) {
    const current = discussionsQ.rows[0];
    const currentSettings = normalizeSettings(current.settings);
    const nextSettings = mergeJson(currentSettings, baseSettings);
    const updated = await client.query(
      `UPDATE chats
       SET title = COALESCE(NULLIF(BTRIM(title), ''), 'Обсуждения'),
           settings = $2::jsonb,
           tenant_id = $3,
           updated_at = now()
       WHERE id = $1
       RETURNING id, title, type, created_by, settings, created_at, updated_at`,
      [current.id, JSON.stringify(nextSettings), tenantId || null],
    );
    await ensureDiscussionBaseMembers(
      client,
      updated.rows[0].id,
      tenantId,
      createdBy,
    );
    return { chat: updated.rows[0], created: false };
  }

  const inserted = await client.query(
    `INSERT INTO chats (id, title, type, created_by, tenant_id, settings, created_at, updated_at)
     VALUES ($1, 'Обсуждения', 'private', $2, $3, $4::jsonb, now(), now())
     RETURNING id, title, type, created_by, settings, created_at, updated_at`,
    [uuidv4(), createdBy || null, tenantId || null, JSON.stringify(baseSettings)],
  );
  await ensureDiscussionBaseMembers(
    client,
    inserted.rows[0].id,
    tenantId,
    createdBy,
  );
  return { chat: inserted.rows[0], created: true };
}

async function insertAdminSystemMessage(
  client,
  {
    tenantId = null,
    createdBy = null,
    text,
    meta = {},
    dedupeKey = "",
  } = {},
) {
  const plainText = String(text || "").trim();
  if (!plainText) return { chat: null, message: null, duplicate: false };

  const { chat } = await ensureAdminSystemChat(client, createdBy, tenantId);
  if (!chat?.id) return { chat: null, message: null, duplicate: false };

  const normalizedDedupeKey = String(dedupeKey || "").trim();
  if (normalizedDedupeKey) {
    const existingQ = await client.query(
      `SELECT id
       FROM messages
       WHERE chat_id = $1
         AND COALESCE(meta->>'dedupe_key', '') = $2
       LIMIT 1`,
      [chat.id, normalizedDedupeKey],
    );
    if (existingQ.rowCount > 0) {
      return { chat, message: null, duplicate: true };
    }
  }

  const nextMeta = {
    ...(meta && typeof meta === "object" && !Array.isArray(meta) ? meta : {}),
    kind:
      meta && typeof meta === "object" && !Array.isArray(meta) && meta.kind
        ? meta.kind
        : "system_notice",
    ...(normalizedDedupeKey ? { dedupe_key: normalizedDedupeKey } : {}),
  };
  const inserted = await client.query(
    `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
     VALUES ($1, $2, NULL, $3, $4::jsonb, now())
     RETURNING id,
               chat_id,
               sender_id,
               text,
               meta,
               created_at,
               false AS from_me,
               false AS is_read_by_me,
               false AS read_by_others,
               0::int AS read_count,
               'Система'::text AS sender_name,
               NULL::text AS sender_email,
               NULL::text AS sender_avatar_url,
               0::float8 AS sender_avatar_focus_x,
               0::float8 AS sender_avatar_focus_y,
               1::float8 AS sender_avatar_zoom`,
    [uuidv4(), chat.id, encryptMessageText(plainText), JSON.stringify(nextMeta)],
  );
  await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
    chat.id,
  ]);
  const message = decryptMessageRow(inserted.rows[0] || null);
  const io = global.__projectPhoenixSocketIo || null;
  if (io && message?.id) {
    const payload = {
      event_id: `chat-message:${message.id}:system_notice`,
      entity: "chat_message",
      entity_id: String(message.id),
      action: "system_notice",
      updated_at: message.created_at || new Date().toISOString(),
      chatId: String(chat.id),
      chat_id: String(chat.id),
      message_id: String(message.id),
      message,
    };
    io.to(`chat:${chat.id}`).emit("chat:message", payload);
    emitToTenant(io, tenantId || null, "chat:message", payload);
    emitToTenant(io, tenantId || null, "chat:updated", {
      chatId: String(chat.id),
      chat_id: String(chat.id),
      title: "Система",
      type: "private",
      settings: normalizeSettings(chat.settings),
      updated_at: payload.updated_at,
    });
  }

  return {
    chat,
    message,
    duplicate: false,
  };
}

async function ensureSystemChannels(client, createdBy, tenantId = null) {
  const main = await ensureMainChannel(client, createdBy, tenantId);
  const reserved = await ensureReservedOrdersChannel(client, createdBy, tenantId);
  const postsArchive = await ensurePostsArchiveChannel(client, createdBy, tenantId);
  const adminSystem = await ensureAdminSystemChat(client, createdBy, tenantId);
  await consolidateSystemDuplicates(
    client,
    tenantId,
    main.channel.id,
    "main_channel",
  );
  await consolidateSystemDuplicates(
    client,
    tenantId,
    reserved.channel.id,
    "reserved_orders",
  );
  await consolidateSystemDuplicates(
    client,
    tenantId,
    postsArchive.channel.id,
    "posts_archive",
  );
  return {
    mainChannel: main.channel,
    reservedChannel: reserved.channel,
    postsArchiveChannel: postsArchive.channel,
    adminSystemChat: adminSystem.chat,
    discussionsChat: null,
    created: {
      main: main.created,
      reserved: reserved.created,
      posts_archive: postsArchive.created,
      admin_system: adminSystem.created,
      discussions: false,
    },
  };
}

module.exports = {
  ensureSystemChannels,
  ensureStaffMembers,
  ensureAdminSystemChat,
  ensureDiscussionsChat,
  ensurePlatformDiscussionUserShadow,
  syncPlatformDiscussionIndexedUsers,
  syncPlatformDiscussionTenantUsers,
  ensurePlatformDiscussionsChat,
  insertAdminSystemMessage,
  normalizeSettings,
};
