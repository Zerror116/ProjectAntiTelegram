const disconnectReasons = new Map();
const authDeniedReasons = new Map();
const activityCounters = {
  total_connections: 0,
  active_connections: 0,
  recovered_connections: 0,
  unrecovered_connections: 0,
  total_disconnects: 0,
  join_requests: 0,
  join_successes: 0,
  join_denied: 0,
  replay_fallback_count: 0,
  duplicate_drop_count: 0,
  outbox_retry_failures: 0,
  outbox_retry_successes: 0,
};

const joinLatency = {
  count: 0,
  total_ms: 0,
  max_ms: 0,
};

function _normalizeKey(raw, fallback = 'unknown') {
  const value = String(raw || '').trim().toLowerCase();
  return value || fallback;
}

function _bump(map, rawKey) {
  const key = _normalizeKey(rawKey);
  map.set(key, Number(map.get(key) || 0) + 1);
}

function markConnection({ recovered = false } = {}) {
  activityCounters.total_connections += 1;
  activityCounters.active_connections += 1;
  if (recovered) {
    activityCounters.recovered_connections += 1;
  } else {
    activityCounters.unrecovered_connections += 1;
  }
}

function markDisconnect(reason) {
  activityCounters.total_disconnects += 1;
  activityCounters.active_connections = Math.max(
    0,
    activityCounters.active_connections - 1,
  );
  _bump(disconnectReasons, reason);
}

function markAuthDenied(reason) {
  _bump(authDeniedReasons, reason);
}

function markJoinRequest() {
  activityCounters.join_requests += 1;
}

function markJoinSuccess(latencyMs = 0) {
  activityCounters.join_successes += 1;
  const normalized = Number(latencyMs);
  if (Number.isFinite(normalized) && normalized >= 0) {
    joinLatency.count += 1;
    joinLatency.total_ms += normalized;
    joinLatency.max_ms = Math.max(joinLatency.max_ms, normalized);
  }
}

function markJoinDenied() {
  activityCounters.join_denied += 1;
}

function markReplayFallback() {
  activityCounters.replay_fallback_count += 1;
}

function markDuplicateDrop() {
  activityCounters.duplicate_drop_count += 1;
}

function markOutboxRetryFailure() {
  activityCounters.outbox_retry_failures += 1;
}

function markOutboxRetrySuccess() {
  activityCounters.outbox_retry_successes += 1;
}

function listTopEntries(map, limit = 8) {
  return [...map.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, limit)
    .map(([key, count]) => ({ key, count }));
}

function snapshot() {
  const averageJoinLatencyMs = joinLatency.count > 0
    ? Math.round(joinLatency.total_ms / joinLatency.count)
    : 0;
  return {
    ...activityCounters,
    join_latency: {
      average_ms: averageJoinLatencyMs,
      max_ms: joinLatency.max_ms,
      samples: joinLatency.count,
    },
    top_disconnect_reasons: listTopEntries(disconnectReasons),
    top_auth_denied_reasons: listTopEntries(authDeniedReasons),
  };
}

module.exports = {
  markConnection,
  markDisconnect,
  markAuthDenied,
  markJoinRequest,
  markJoinSuccess,
  markJoinDenied,
  markReplayFallback,
  markDuplicateDrop,
  markOutboxRetryFailure,
  markOutboxRetrySuccess,
  snapshot,
};
