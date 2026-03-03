const express = require("express");
const { v4: uuidv4 } = require("uuid");

const router = express.Router();
const requireAuth = require("../middleware/requireAuth");
const requireRole = require("../middleware/requireRole");
const db = require("../db");

const SAMARA_CENTER = { lat: 53.195878, lng: 50.100202 };
const DEMO_USER_EMAIL_PREFIX = "phantom.delivery.";
const DEMO_PRODUCT_TITLE_PREFIX = "[DEMO DELIVERY]";
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

function buildEtaWindow(deliveryDate, routeOrder) {
  const normalizedDate =
    deliveryDate instanceof Date
      ? formatDateOnly(deliveryDate)
      : formatDateOnly(new Date(String(deliveryDate)));
  const start = new Date(`${normalizedDate}T11:00:00`);
  if (Number.isNaN(start.getTime())) {
    throw new Error(`Некорректная дата доставки: ${String(deliveryDate)}`);
  }
  const offsetMinutes = Math.max(0, Number(routeOrder || 1) - 1) * 40;
  start.setMinutes(start.getMinutes() + offsetMinutes);
  const end = new Date(start);
  end.setMinutes(end.getMinutes() + 35);
  return {
    eta_from: start.toISOString(),
    eta_to: end.toISOString(),
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

function buildCourierSlots(courierNames) {
  return courierNames.map((name, index) => ({
    slot: index + 1,
    name,
    items: [],
    currentLat: SAMARA_CENTER.lat,
    currentLng: SAMARA_CENTER.lng,
  }));
}

function distributeCustomersAcrossCouriers(customers, courierNames) {
  const slots = buildCourierSlots(courierNames);
  const withCoords = [];
  const withoutCoords = [];

  for (const customer of customers) {
    const lat = Number(customer.lat);
    const lng = Number(customer.lng);
    if (Number.isFinite(lat) && Number.isFinite(lng)) {
      withCoords.push({ ...customer, lat, lng });
    } else {
      withoutCoords.push(customer);
    }
  }

  while (withCoords.length > 0) {
    const orderedSlots = [...slots].sort(
      (a, b) => a.items.length - b.items.length || a.slot - b.slot,
    );
    for (const slot of orderedSlots) {
      if (withCoords.length === 0) break;
      let bestIndex = 0;
      let bestDistance = Number.POSITIVE_INFINITY;
      for (let i = 0; i < withCoords.length; i += 1) {
        const candidate = withCoords[i];
        const nextDistance = distanceKm(
          slot.currentLat,
          slot.currentLng,
          candidate.lat,
          candidate.lng,
        );
        if (nextDistance < bestDistance) {
          bestDistance = nextDistance;
          bestIndex = i;
        }
      }
      const [picked] = withCoords.splice(bestIndex, 1);
      slot.items.push(picked);
      slot.currentLat = picked.lat;
      slot.currentLng = picked.lng;
    }
  }

  for (const customer of withoutCoords) {
    const slot = [...slots].sort(
      (a, b) => a.items.length - b.items.length || a.slot - b.slot,
    )[0];
    slot.items.push(customer);
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
      processed_sum: toMoney(row.processed_sum),
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

async function findDraftBatchId(queryable) {
  const activeBatchQ = await queryable.query(
    `SELECT id
     FROM delivery_batches
     WHERE status = 'calling'
     ORDER BY created_at DESC
     LIMIT 1`,
  );
  if (activeBatchQ.rowCount === 0) return null;
  return String(activeBatchQ.rows[0].id);
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
            addr.lat,
            addr.lng
     FROM cart_items c
     JOIN products p ON p.id = c.product_id
     JOIN users u ON u.id = c.user_id
     LEFT JOIN phones ph ON ph.user_id = c.user_id
     LEFT JOIN user_shelves us ON us.user_id = c.user_id
     LEFT JOIN LATERAL (
       SELECT a.id, a.address_text, a.lat, a.lng
       FROM user_delivery_addresses a
       WHERE a.user_id = c.user_id
       ORDER BY a.is_default DESC, a.updated_at DESC
       LIMIT 1
     ) AS addr ON true
     WHERE c.status = 'processed'
       AND NOT EXISTS (
         SELECT 1
         FROM delivery_batch_items di
         JOIN delivery_batches dbt ON dbt.id = di.batch_id
         WHERE di.cart_item_id = c.id
           AND dbt.status <> 'cancelled'
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
        address_text: row.address_text || "",
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

async function createDeliveryBatch(queryable, thresholdAmount, createdBy) {
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

  const batchInsert = await queryable.query(
    `INSERT INTO delivery_batches (
       id, delivery_date, delivery_label, threshold_amount,
       status, courier_count, courier_names, created_by, created_at, updated_at
     )
     VALUES ($1, $2, $3, $4, 'calling', 0, '[]'::jsonb, $5, now(), now())
     RETURNING id`,
    [uuidv4(), deliveryDate, label, thresholdAmount, createdBy || null],
  );
  const batchId = String(batchInsert.rows[0].id);

  for (const candidate of candidates) {
    const batchCustomerId = uuidv4();
    await queryable.query(
      `INSERT INTO delivery_batch_customers (
         id, batch_id, user_id, customer_name, customer_phone,
         processed_sum, processed_items_count, shelf_number,
         address_id, address_text, lat, lng,
         call_status, delivery_status, created_at, updated_at
       )
       VALUES (
         $1, $2, $3, $4, $5,
         $6, $7, $8,
         $9, $10, $11, $12,
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
        candidate.address_text || null,
        candidate.lat,
        candidate.lng,
      ],
    );

    for (const item of candidate.items) {
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
    `SELECT user_id::text AS user_id
     FROM delivery_batch_customers
     WHERE batch_id = $1`,
    [batchId],
  );
  const existingUsers = new Set(
    existingUsersQ.rows.map((row) => String(row.user_id)),
  );

  let addedTotal = 0;
  for (const candidate of candidates) {
    if (existingUsers.has(candidate.user_id)) continue;
    const batchCustomerId = uuidv4();
    await queryable.query(
      `INSERT INTO delivery_batch_customers (
         id, batch_id, user_id, customer_name, customer_phone,
         processed_sum, processed_items_count, shelf_number,
         address_id, address_text, lat, lng,
         call_status, delivery_status, created_at, updated_at
       )
       VALUES (
         $1, $2, $3, $4, $5,
         $6, $7, $8,
         $9, $10, $11, $12,
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
        candidate.address_text || null,
        candidate.lat,
        candidate.lng,
      ],
    );

    for (const item of candidate.items) {
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

    existingUsers.add(candidate.user_id);
    addedTotal += 1;
  }

  return addedTotal;
}

async function ensureDeliveryChat(queryable, userId, createdBy) {
  const existingQ = await queryable.query(
    `SELECT c.id, c.title, c.type, c.settings, c.created_at, c.updated_at
     FROM chats c
     JOIN chat_members cm ON cm.chat_id = c.id
     WHERE cm.user_id = $1
       AND c.type = 'private'
       AND COALESCE(c.settings->>'kind', '') = 'delivery_dialog'
     ORDER BY c.updated_at DESC NULLS LAST, c.created_at DESC
     LIMIT 1`,
    [userId],
  );
  if (existingQ.rowCount > 0) {
    return { chat: existingQ.rows[0], created: false };
  }

  const settings = {
    kind: "delivery_dialog",
    visibility: "private",
    system_key: "delivery_dialog",
    description: "Системный диалог по доставке",
  };
  const chatInsert = await queryable.query(
    `INSERT INTO chats (id, title, type, created_by, settings, created_at, updated_at)
     VALUES ($1, $2, 'private', $3, $4::jsonb, now(), now())
     RETURNING id, title, type, settings, created_at, updated_at`,
    [uuidv4(), "Доставка", createdBy || null, JSON.stringify(settings)],
  );
  const chat = chatInsert.rows[0];
  await queryable.query(
    `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
     VALUES ($1, $2, $3, now(), 'member')
     ON CONFLICT (chat_id, user_id) DO NOTHING`,
    [uuidv4(), chat.id, userId],
  );
  return { chat, created: true };
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
  ].join("\n");
}

function buildDeliveryAcceptedText(addressText) {
  return [
    "Доставка подтверждена.",
    addressText ? `Адрес: ${addressText}` : null,
    "Мы готовим ваш заказ к отправке.",
  ]
    .filter(Boolean)
    .join("\n");
}

function buildDeliveryDeclinedText() {
  return "Хорошо, свяжемся с вами в следующий раз.";
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

    const client = await db.pool.connect();
    try {
      await client.query("BEGIN");
      const nextSettings = { threshold_amount: thresholdAmount };
      await saveDeliverySettings(client, nextSettings, req.user.id);
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
      await saveDeliverySettings(
        client,
        { threshold_amount: thresholdAmount },
        req.user.id,
      );

      const createdBatch = await createDeliveryBatch(
        client,
        thresholdAmount,
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
      await saveDeliverySettings(
        client,
        { threshold_amount: thresholdAmount },
        req.user.id,
      );

      let batchId = await findDraftBatchId(client);
      let created = false;
      let eligibleTotal = 0;
      let addedToExistingBatch = 0;
      let systemMessages = [];
      if (!batchId) {
        const createdBatch = await createDeliveryBatch(
          client,
          thresholdAmount,
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
        const ensured = await ensureDeliveryChat(client, customer.user_id, req.user.id);
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
          message: hydrated,
        });
      }

      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
        for (const item of systemMessages) {
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
        await client.query(
          `INSERT INTO user_delivery_addresses (
             id, user_id, label, address_text, lat, lng,
             is_default, created_at, updated_at
           )
           VALUES ($1, $2, 'Тестовый адрес', $3, $4, $5, true, now(), now())`,
          [uuidv4(), userId, point.address, point.lat, point.lng],
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
      if (String(customer.call_status || "") !== "pending") {
        await client.query("ROLLBACK");
        return res.status(400).json({ ok: false, error: "Ответ уже сохранен" });
      }

      const ensured = await ensureDeliveryChat(client, customer.user_id, null);
      const chat = ensured.chat;
      let addressId = customer.address_id ? String(customer.address_id) : null;
      let nextAddressText =
        addressText || String(customer.address_text || "").trim();
      let nextLat = Number.isFinite(lat) ? lat : customer.lat;
      let nextLng = Number.isFinite(lng) ? lng : customer.lng;

      if (accepted && nextAddressText) {
        await client.query(
          `UPDATE user_delivery_addresses
           SET is_default = false,
               updated_at = now()
           WHERE user_id = $1`,
          [customer.user_id],
        );
        const addressInsert = await client.query(
          `INSERT INTO user_delivery_addresses (
             id, user_id, label, address_text, lat, lng,
             is_default, created_at, updated_at
           )
           VALUES ($1, $2, 'Основной адрес', $3, $4, $5, true, now(), now())
           RETURNING id`,
          [uuidv4(), customer.user_id, nextAddressText || null, nextLat, nextLng],
        );
        addressId = String(addressInsert.rows[0].id);
      }

      await client.query(
        `UPDATE delivery_batch_customers
         SET call_status = $1,
             delivery_status = $2,
             address_id = $3,
             address_text = $4,
             lat = $5,
             lng = $6,
             updated_at = now()
         WHERE id = $7`,
        [
          accepted ? "accepted" : "declined",
          accepted ? "preparing_delivery" : "declined",
          addressId,
          nextAddressText || null,
          nextLat,
          nextLng,
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
             jsonb_set(COALESCE(meta, '{}'::jsonb), '{offer_status}', to_jsonb($1::text), true),
             '{address_text}',
             to_jsonb($2::text),
             true
           ),
           '{responded_at}',
           to_jsonb(now()),
           true
         )
         WHERE chat_id = $3
           AND COALESCE(meta->>'kind', '') = 'delivery_offer'
           AND COALESCE(meta->>'delivery_customer_id', '') = $4
         RETURNING id`,
        [
          accepted ? "accepted" : "declined",
          nextAddressText || "",
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
            ? buildDeliveryAcceptedText(nextAddressText)
            : buildDeliveryDeclinedText(),
          JSON.stringify({
            kind: "delivery_offer_result",
            delivery_batch_id: customer.batch_id,
            delivery_customer_id: customerId,
            offer_status: accepted ? "accepted" : "declined",
            address_text: nextAddressText || "",
          }),
        ],
      );

      await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
        chat.id,
      ]);
      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io) {
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
      if (String(customer.call_status || "") !== "pending") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error: "Клиент уже ответил на доставку",
        });
      }
      let addressId = customer.address_id ? String(customer.address_id) : null;
      let nextAddressText = addressText || String(customer.address_text || "").trim();
      let nextLat = Number.isFinite(lat) ? lat : customer.lat;
      let nextLng = Number.isFinite(lng) ? lng : customer.lng;
      const ensured = await ensureDeliveryChat(client, customer.user_id, req.user.id);
      const chat = ensured.chat;

      if (accepted && saveAsDefault && (nextAddressText || (Number.isFinite(nextLat) && Number.isFinite(nextLng)))) {
        if (nextAddressText) {
          await client.query(
            `UPDATE user_delivery_addresses
             SET is_default = false,
                 updated_at = now()
             WHERE user_id = $1`,
            [customer.user_id],
          );
          const addressInsert = await client.query(
            `INSERT INTO user_delivery_addresses (
               id, user_id, label, address_text, lat, lng,
               is_default, created_at, updated_at
             )
             VALUES ($1, $2, 'Основной адрес', $3, $4, $5, true, now(), now())
             RETURNING id`,
            [uuidv4(), customer.user_id, nextAddressText || null, nextLat, nextLng],
          );
          addressId = String(addressInsert.rows[0].id);
        }
      }

      await client.query(
        `UPDATE delivery_batch_customers
         SET call_status = $1,
             delivery_status = $2,
             address_id = $3,
             address_text = $4,
             lat = $5,
             lng = $6,
             updated_at = now()
         WHERE id = $7`,
        [
          accepted ? "accepted" : "declined",
          accepted ? "preparing_delivery" : "declined",
          addressId,
          nextAddressText || null,
          nextLat,
          nextLng,
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
             jsonb_set(COALESCE(meta, '{}'::jsonb), '{offer_status}', to_jsonb($1::text), true),
             '{address_text}',
             to_jsonb($2::text),
             true
           ),
           '{responded_at}',
           to_jsonb(now()),
           true
         )
         WHERE chat_id = $3
           AND COALESCE(meta->>'kind', '') = 'delivery_offer'
           AND COALESCE(meta->>'delivery_customer_id', '') = $4
         RETURNING id`,
        [
          accepted ? "accepted" : "declined",
          nextAddressText || "",
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
            ? buildDeliveryAcceptedText(nextAddressText)
            : buildDeliveryDeclinedText(),
          JSON.stringify({
            kind: "delivery_offer_result",
            delivery_batch_id: customer.batch_id,
            delivery_customer_id: customerId,
            offer_status: accepted ? "accepted" : "declined",
            address_text: nextAddressText || "",
            responded_by: "admin",
          }),
        ],
      );

      await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
        chat.id,
      ]);
      await client.query("UPDATE delivery_batches SET updated_at = now() WHERE id = $1", [
        batchId,
      ]);
      await client.query("COMMIT");

      const io = req.app.get("io");
      if (io && ensured.created) {
        io.to(`user:${customer.user_id}`).emit("chat:created", {
          chat,
        });
      }
      if (io) {
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
          chat,
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
        `SELECT id, delivery_date, status
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
      const deliveryDate = batchQ.rows[0].delivery_date;
      const batchStatus = String(batchQ.rows[0].status || "");
      if (batchStatus !== "calling") {
        await client.query("ROLLBACK");
        return res.status(400).json({
          ok: false,
          error:
            batchStatus === "handed_off"
              ? "Этот лист уже передан курьерам. Отправьте новую рассылку."
              : "Распределять по курьерам можно только текущий лист доставки",
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

      const slots = distributeCustomersAcrossCouriers(
        customersQ.rows,
        courierNames,
      );

      for (const slot of slots) {
        for (let i = 0; i < slot.items.length; i += 1) {
          const customer = slot.items[i];
          const routeOrder = i + 1;
          const eta = buildEtaWindow(deliveryDate, routeOrder);
          await client.query(
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

      await client.query(
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

      await client.query(
        `UPDATE delivery_batches
         SET courier_count = $1,
             courier_names = $2::jsonb,
             status = 'couriers_assigned',
             updated_at = now()
         WHERE id = $3`,
        [courierNames.length, JSON.stringify(courierNames), batchId],
      );

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

module.exports = router;
