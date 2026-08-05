#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const dotenv = require("dotenv");

const serverRoot = path.resolve(__dirname, "..");
dotenv.config({ path: path.join(serverRoot, ".env") });

const nodeEnv = String(process.env.NODE_ENV || "development")
  .toLowerCase()
  .trim();
if (nodeEnv !== "production") {
  const localEnvPath = path.join(serverRoot, ".env.local");
  if (fs.existsSync(localEnvPath)) {
    dotenv.config({ path: localEnvPath, override: true });
  }
}

const db = require("../src/db");
const {
  runMessageEncryptionBackfill,
} = require("../src/utils/messageEncryptionBackfill");

async function main() {
  const result = await runMessageEncryptionBackfill({ logger: console });
  if (Number(result?.failed || 0) > 0) {
    process.exitCode = 1;
  }
}

main()
  .catch((err) => {
    console.error("[message-encryption] backfill failed", err);
    process.exitCode = 1;
  })
  .finally(async () => {
    try {
      await db.closeAllPools();
    } catch (_) {
      // Ignore shutdown cleanup errors.
    }
  });
