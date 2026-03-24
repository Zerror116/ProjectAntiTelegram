const express = require("express");

const router = express.Router();
const { bootstrapDatabase } = require("../utils/bootstrap");

let setupInFlight = null;
let lastSetupResult = null;

function isLoopbackIp(ip) {
  const raw = String(ip || "").trim();
  return (
    raw === "127.0.0.1" ||
    raw === "::1" ||
    raw === "::ffff:127.0.0.1" ||
    raw.endsWith("::1")
  );
}

function canRunSetup(req) {
  if (process.env.NODE_ENV !== "production") return true;
  const requiredToken = String(process.env.SETUP_TOKEN || "").trim();
  if (requiredToken) {
    const incoming = String(req.headers["x-setup-token"] || "").trim();
    if (incoming && incoming === requiredToken) return true;
  }
  const forwarded = String(req.headers["x-forwarded-for"] || "").split(",")[0].trim();
  const remote = req.ip || req.socket?.remoteAddress || "";
  return isLoopbackIp(forwarded || remote);
}

async function runSetupSafely() {
  if (!setupInFlight) {
    setupInFlight = bootstrapDatabase()
      .then((result) => {
        lastSetupResult = result;
        return result;
      })
      .finally(() => {
        setupInFlight = null;
      });
  }
  return await setupInFlight;
}

router.post("/", async (req, res) => {
  if (!canRunSetup(req)) {
    return res.status(403).json({
      ok: false,
      error: "Setup endpoint is restricted",
    });
  }
  try {
    const result = await runSetupSafely();
    return res.json(result);
  } catch (err) {
    console.error("Setup error:", err);
    const isProd = process.env.NODE_ENV === "production";
    return res.status(500).json({
      ok: false,
      error: isProd ? "Setup failed" : String(err),
    });
  }
});

router.get("/", (req, res) => {
  if (!canRunSetup(req)) {
    return res.status(403).json({
      ok: false,
      error: "Setup endpoint is restricted",
    });
  }
  return res.json({
    ok: true,
    in_progress: setupInFlight != null,
    last_result: lastSetupResult,
  });
});

module.exports = router;
