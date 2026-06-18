/**
 * API /health endpoint
 * Same pattern as frontend — checks ALL dependencies
 */

const express = require('express');
const router = express.Router();

router.get('/health', async (req, res) => {
  const checks = {};
  let healthy = true;

  // DB check
  try {
    await req.app.locals.db.query('SELECT 1');
    checks.database = 'ok';
  } catch (err) {
    checks.database = `error: ${err.message}`;
    healthy = false;
  }

  // Redis check
  try {
    await req.app.locals.redis.ping();
    checks.cache = 'ok';
  } catch (err) {
    checks.cache = `error: ${err.message}`;
    healthy = false;
  }

  res.status(healthy ? 200 : 503).json({
    status: healthy ? 'healthy' : 'unhealthy',
    service: 'api',
    region: process.env.REGION || 'unknown',
    checks,
    timestamp: new Date().toISOString()
  });
});

module.exports = router;
