const express = require("express");
const { v4: uuidv4 } = require("uuid");

const router = express.Router();
const db = require("../db");
const { authMiddleware } = require("../utils/auth");

function buildCartSummaryReply(total, processed) {
  return `Общая сумма вашей корзины: ${total} RUB. Обработано на сумму: ${processed} RUB.`;
}

function normalizeSettings(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw;
}

async function ensureBugReportsChannel(client, createdBy) {
  const existing = await client.query(
    `SELECT id, title, type, settings, created_at, updated_at
     FROM chats
     WHERE type = 'channel'
       AND (
         COALESCE(settings->>'kind', '') = 'bug_reports'
         OR LOWER(TRIM(title)) = LOWER(TRIM($1))
       )
     ORDER BY
       CASE WHEN COALESCE(settings->>'kind', '') = 'bug_reports' THEN 0 ELSE 1 END,
       updated_at DESC NULLS LAST,
       created_at DESC
     LIMIT 1`,
    ["Баг-репорты"],
  );

  if (existing.rowCount > 0) {
    const current = existing.rows[0];
    const currentSettings = normalizeSettings(current.settings);
    const nextSettings = {
      ...currentSettings,
      kind: "bug_reports",
      visibility: "private",
      admin_only: true,
      worker_can_post: false,
      is_post_channel: false,
      description:
        currentSettings.description || "Служебный канал баг-репортов",
    };

    const updated = await client.query(
      `UPDATE chats
       SET title = $1,
           settings = $2::jsonb,
           updated_at = now()
       WHERE id = $3
       RETURNING id, title, type, settings, created_at, updated_at`,
      ["Баг-репорты", JSON.stringify(nextSettings), current.id],
    );
    return { channel: updated.rows[0], created: false };
  }

  const settings = {
    kind: "bug_reports",
    visibility: "private",
    admin_only: true,
    worker_can_post: false,
    is_post_channel: false,
    description: "Служебный канал баг-репортов",
  };

  const inserted = await client.query(
    `INSERT INTO chats (id, title, type, created_by, settings, created_at, updated_at)
     VALUES ($1, $2, 'channel', $3, $4::jsonb, now(), now())
     RETURNING id, title, type, settings, created_at, updated_at`,
    [uuidv4(), "Баг-репорты", createdBy || null, JSON.stringify(settings)],
  );

  return { channel: inserted.rows[0], created: true };
}

async function ensureAdminCreatorMembers(client, chatId) {
  await client.query(
    `DELETE FROM chat_members cm
     USING users u
     WHERE cm.chat_id = $1
       AND cm.user_id = u.id
       AND u.role NOT IN ('admin', 'creator')`,
    [chatId],
  );

  const staff = await client.query(
    `SELECT id, role
     FROM users
     WHERE role IN ('admin', 'creator')`,
  );

  for (const user of staff.rows) {
    const role =
      String(user.role || "").toLowerCase() === "creator"
        ? "owner"
        : "moderator";
    await client.query(
      `INSERT INTO chat_members (id, chat_id, user_id, joined_at, role)
       VALUES ($1, $2, $3, now(), $4)
       ON CONFLICT (chat_id, user_id) DO NOTHING`,
      [uuidv4(), chatId, user.id, role],
    );
  }
}

router.post("/ask", authMiddleware, async (req, res) => {
  try {
    const userId = req.user.id;
    const message = String(req.body?.message || "")
      .toLowerCase()
      .trim();

    const asksCartSum = message.includes("сум") && message.includes("корз");
    if (!asksCartSum) {
      return res.json({
        ok: true,
        data: {
          reply:
            'Поддержка: пока доступны ответы по сумме корзины. Напишите вопрос со словами "сумма" и "корзина".',
        },
      });
    }

    const result = await db.query(
      `SELECT c.status, c.quantity, p.price
       FROM cart_items c
       JOIN products p ON p.id = c.product_id
       WHERE c.user_id = $1`,
      [userId],
    );

    let total = 0;
    let processed = 0;
    for (const row of result.rows) {
      const line = Number(row.price) * Number(row.quantity);
      total += line;
      if (row.status === "processed" || row.status === "in_delivery") {
        processed += line;
      }
    }

    return res.json({
      ok: true,
      data: {
        reply: buildCartSummaryReply(total, processed),
      },
    });
  } catch (err) {
    console.error("support.ask error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  }
});

// Отправить баг-репорт в отдельный приватный канал для admin/creator
router.post("/bug-report", authMiddleware, async (req, res) => {
  const role = String(req.user?.role || "")
    .toLowerCase()
    .trim();
  if (role !== "admin" && role !== "creator") {
    return res.status(403).json({
      ok: false,
      error: "Баг-репорты доступны только admin и creator",
    });
  }

  const message = String(req.body?.message || "").trim();
  if (!message) {
    return res
      .status(400)
      .json({ ok: false, error: "Текст баг-репорта обязателен" });
  }
  if (message.length > 5000) {
    return res.status(400).json({
      ok: false,
      error: "Слишком длинный текст (максимум 5000 символов)",
    });
  }

  const client = await db.pool.connect();
  try {
    await client.query("BEGIN");

    const profileQ = await client.query(
      `SELECT id, email, role, name
       FROM users
       WHERE id = $1
       LIMIT 1`,
      [req.user.id],
    );
    if (profileQ.rowCount === 0) {
      await client.query("ROLLBACK");
      return res
        .status(404)
        .json({ ok: false, error: "Пользователь не найден" });
    }
    const reporter = profileQ.rows[0];

    const { channel, created } = await ensureBugReportsChannel(
      client,
      req.user.id,
    );
    await ensureAdminCreatorMembers(client, channel.id);

    const title = reporter.name || reporter.email || reporter.id;
    const text = [
      "🐞 Новый баг-репорт",
      `От: ${title}`,
      `Роль: ${reporter.role}`,
      `Email: ${reporter.email || "—"}`,
      "",
      message,
    ].join("\n");

    const meta = {
      kind: "bug_report",
      reporter_id: reporter.id,
      reporter_email: reporter.email,
      reporter_role: reporter.role,
      reporter_name: reporter.name,
      source: "settings_bug_report",
    };

    const messageInsert = await client.query(
      `INSERT INTO messages (id, chat_id, sender_id, text, meta, created_at)
       VALUES ($1, $2, $3, $4, $5::jsonb, now())
       RETURNING id, chat_id, sender_id, text, meta, created_at`,
      [uuidv4(), channel.id, reporter.id, text, JSON.stringify(meta)],
    );

    await client.query("UPDATE chats SET updated_at = now() WHERE id = $1", [
      channel.id,
    ]);

    await client.query("COMMIT");

    const io = req.app.get("io");
    if (io) {
      if (created) {
        io.emit("chat:created", { chatId: channel.id });
      }
      io.to(`chat:${channel.id}`).emit("chat:message", {
        chatId: channel.id,
        message: messageInsert.rows[0],
      });
    }

    return res.status(201).json({
      ok: true,
      data: {
        chat_id: channel.id,
        message_id: messageInsert.rows[0].id,
      },
    });
  } catch (err) {
    await client.query("ROLLBACK");
    console.error("support.bug_report error", err);
    return res.status(500).json({ ok: false, error: "Ошибка сервера" });
  } finally {
    client.release();
  }
});

module.exports = router;
