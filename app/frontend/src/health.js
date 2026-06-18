/**
 * /health endpoint — the most critical piece of DR infrastructure
 *
 * Front Door probes this every 30 seconds.
 * Must return HTTP 503 when ANY dependency is down.
 * If this always returns 200 — your entire DR system is theater.
 */

const express = require('express');
const router = express.Router();

router.get('/health', async (req, res) => {
  const checks = {};
  let healthy = true;

  // 1. Database check — REAL query, not just ping
  try {
    await req.app.locals.db.query('SELECT 1');
    checks.database = 'ok';
  } catch (err) {
    checks.database = `error: ${err.message}`;
    healthy = false;
  }

  // 2. Redis/cache check
  try {
    await req.app.locals.redis.ping();
    checks.cache = 'ok';
  } catch (err) {
    checks.cache = `error: ${err.message}`;
    healthy = false;
  }

  const response = {
    status: healthy ? 'healthy' : 'unhealthy',
    region: process.env.REGION || 'unknown',  // "eastus" or "westeurope"
    checks,
    timestamp: new Date().toISOString(),
    version: process.env.IMAGE_TAG || 'unknown'
  };

  // 200 = Front Door keeps routing here
  // 503 = Front Door marks backend unhealthy → triggers failover
  res.status(healthy ? 200 : 503).json(response);
});

module.exports = router;
