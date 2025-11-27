const express = require('express');
const router = express.Router();

const startTime = Date.now();
const TENANT_ID = process.env.TENANT_ID || 'default';

// Liveness probe
router.get('/live', (req, res) => {
  res.status(200).json({
    status: 'alive',
    service: 'api-service',
    tenant: TENANT_ID,
    timestamp: new Date().toISOString()
  });
});

// Readiness probe
router.get('/ready', (req, res) => {
  const checks = {
    service: 'ok',
    // Add dependency checks here
  };

  const isReady = Object.values(checks).every(status => status === 'ok');

  res.status(isReady ? 200 : 503).json({
    status: isReady ? 'ready' : 'not ready',
    service: 'api-service',
    tenant: TENANT_ID,
    checks,
    timestamp: new Date().toISOString()
  });
});

// Startup probe
router.get('/startup', (req, res) => {
  const uptime = Date.now() - startTime;
  const isStarted = uptime > 1000;

  res.status(isStarted ? 200 : 503).json({
    status: isStarted ? 'started' : 'starting',
    service: 'api-service',
    tenant: TENANT_ID,
    uptime: `${uptime}ms`,
    timestamp: new Date().toISOString()
  });
});

// General health check
router.get('/', (req, res) => {
  const uptime = process.uptime();

  res.json({
    status: 'healthy',
    service: 'api-service',
    tenant: TENANT_ID,
    uptime: `${Math.floor(uptime)}s`,
    timestamp: new Date().toISOString(),
    memory: {
      used: `${Math.round(process.memoryUsage().heapUsed / 1024 / 1024)}MB`,
      total: `${Math.round(process.memoryUsage().heapTotal / 1024 / 1024)}MB`
    }
  });
});

module.exports = router;
