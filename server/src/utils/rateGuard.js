function createRateGuard({
  windowMs = 60 * 1000,
  max = 60,
  blockMs = 0,
  message = "Слишком много запросов, попробуйте позже",
  keyResolver = null,
  cleanupEvery = 250,
} = {}) {
  const buckets = new Map();
  let requestsSeen = 0;

  const safeWindow = Math.max(1000, Number(windowMs) || 60 * 1000);
  const safeMax = Math.max(1, Number(max) || 60);
  const safeBlock = Math.max(0, Number(blockMs) || 0);
  const cleanupThreshold = Math.max(50, Number(cleanupEvery) || 250);

  const resolveKey = (req) => {
    if (typeof keyResolver === "function") {
      const custom = String(keyResolver(req) || "").trim();
      if (custom) return custom;
    }
    const ip =
      String(req.ip || req.headers["x-forwarded-for"] || "").trim() || "ip:unknown";
    const tenantId = String(req.user?.tenant_id || "tenant:public").trim();
    const userId = String(req.user?.id || "user:guest").trim();
    return `${ip}|${tenantId}|${userId}`;
  };

  const cleanup = (now) => {
    for (const [key, state] of buckets.entries()) {
      if (!state) {
        buckets.delete(key);
        continue;
      }
      if (state.blockedUntil && state.blockedUntil > now) continue;
      if (state.resetAt > now) continue;
      buckets.delete(key);
    }
  };

  return function rateGuard(req, res, next) {
    const now = Date.now();
    requestsSeen += 1;
    if (requestsSeen % cleanupThreshold === 0) {
      cleanup(now);
    }

    const key = resolveKey(req);
    const existing = buckets.get(key);
    let state = existing;
    if (!state || state.resetAt <= now) {
      state = {
        count: 0,
        resetAt: now + safeWindow,
        blockedUntil: 0,
      };
      buckets.set(key, state);
    }

    if (state.blockedUntil && state.blockedUntil > now) {
      const retryAfterSec = Math.max(
        1,
        Math.ceil((state.blockedUntil - now) / 1000),
      );
      res.setHeader("Retry-After", retryAfterSec);
      return res.status(429).json({
        ok: false,
        error: message,
      });
    }

    state.count += 1;
    if (state.count > safeMax) {
      if (safeBlock > 0) {
        state.blockedUntil = now + safeBlock;
      }
      const waitTarget = state.blockedUntil > now ? state.blockedUntil : state.resetAt;
      const retryAfterSec = Math.max(1, Math.ceil((waitTarget - now) / 1000));
      res.setHeader("Retry-After", retryAfterSec);
      return res.status(429).json({
        ok: false,
        error: message,
      });
    }

    return next();
  };
}

module.exports = {
  createRateGuard,
};
