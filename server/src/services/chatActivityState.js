const chatActivityState = new Map();

function normalizeChatActivityEvent(raw) {
  const value = String(raw || "chat:typing")
    .trim()
    .toLowerCase();
  if (
    value === "chat:typing" ||
    value === "chat:recording_voice" ||
    value === "chat:recording_video"
  ) {
    return value;
  }
  return null;
}

function parseChatActivityTtlMs(raw) {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) return 4500;
  return Math.max(800, Math.min(12000, Math.round(parsed)));
}

function pruneChatActivityState(chatId = null) {
  const now = Date.now();
  const chatIds = chatId ? [chatId] : Array.from(chatActivityState.keys());
  for (const currentChatId of chatIds) {
    const entries = chatActivityState.get(currentChatId);
    if (!entries) continue;
    for (const [key, activity] of entries.entries()) {
      if (!activity || Number(activity.expiresAtMs || 0) <= now) {
        entries.delete(key);
      }
    }
    if (entries.size === 0) {
      chatActivityState.delete(currentChatId);
    }
  }
}

function rememberChatActivity({
  chatId,
  userId,
  eventName,
  active,
  ttlMs,
  tenantId,
  eventId,
  sentAt,
}) {
  const normalizedChatId = String(chatId || "").trim();
  const normalizedUserId = String(userId || "").trim();
  const normalizedEventName = normalizeChatActivityEvent(eventName);
  if (!normalizedChatId || !normalizedUserId || !normalizedEventName) return;
  pruneChatActivityState(normalizedChatId);
  const entries = chatActivityState.get(normalizedChatId) || new Map();
  const key = `${normalizedEventName}:${normalizedUserId}`;
  if (!active) {
    entries.delete(key);
  } else {
    const safeTtlMs = parseChatActivityTtlMs(ttlMs);
    const now = Date.now();
    entries.set(key, {
      eventName: normalizedEventName,
      userId: normalizedUserId,
      tenantId: tenantId || null,
      eventId: eventId || null,
      sentAt: sentAt || new Date(now).toISOString(),
      ttlMs: safeTtlMs,
      expiresAtMs: now + safeTtlMs,
    });
  }
  if (entries.size > 0) {
    chatActivityState.set(normalizedChatId, entries);
  } else {
    chatActivityState.delete(normalizedChatId);
  }
}

function activeChatActivities(chatId, { excludeUserId = "" } = {}) {
  const normalizedChatId = String(chatId || "").trim();
  if (!normalizedChatId) return [];
  pruneChatActivityState(normalizedChatId);
  const entries = chatActivityState.get(normalizedChatId);
  if (!entries) return [];
  const excluded = String(excludeUserId || "").trim();
  const now = Date.now();
  return Array.from(entries.values())
    .filter((activity) => {
      const userId = String(activity.userId || "").trim();
      return userId && userId !== excluded && activity.expiresAtMs > now;
    })
    .map((activity) => ({
      type: activity.eventName,
      user_id: activity.userId,
      userId: activity.userId,
      tenant_id: activity.tenantId || null,
      event_id: activity.eventId || null,
      sent_at: activity.sentAt || null,
      ttl_ms: Math.max(800, activity.expiresAtMs - now),
      expires_at: new Date(activity.expiresAtMs).toISOString(),
    }));
}

module.exports = {
  activeChatActivities,
  rememberChatActivity,
};
