const express = require('express');
const router = express.Router();
const axios = require('axios');

const startTime = Date.now();
const TENANT_ID = process.env.TENANT_ID || 'default';
const AUTH_SERVICE_URL = process.env.AUTH_SERVICE_URL || 'http://localhost:3001';
const API_SERVICE_URL = process.env.API_SERVICE_URL || 'http://localhost:3002';

// Check service availability
async function checkService(url, serviceName) {
  try {
    const response = await axios.get(`${url}/health/live`, { timeout: 3000 });
    return response.status === 200 ? 'ok' : 'degraded';
  } catch (error) {
    return 'unavailable';
  }
}

// Liveness probe
router.get('/live', (req, res) => {
  res.status(200).json({
    status: 'alive',
    service: 'dashboard-service',
    tenant: TENANT_ID,
    timestamp: new Date().toISOString()
  });
});

// Readiness probe
router.get('/ready', async (req, res) => {
  const checks = {
    service: 'ok',
    authService: await checkService(AUTH_SERVICE_URL, 'auth'),
    apiService: await checkService(API_SERVICE_URL, 'api')
  };

  const isReady = checks.service === 'ok';
  const hasDegradedDependencies =
    checks.authService !== 'ok' || checks.apiService !== 'ok';

  res.status(isReady ? 200 : 503).json({
    status: isReady ? (hasDegradedDependencies ? 'degraded' : 'ready') : 'not ready',
    service: 'dashboard-service',
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
    service: 'dashboard-service',
    tenant: TENANT_ID,
    uptime: `${uptime}ms`,
    timestamp: new Date().toISOString()
  });
});

// General health check
router.get('/', async (req, res) => {
  const uptime = process.uptime();
  const checks = {
    authService: await checkService(AUTH_SERVICE_URL, 'auth'),
    apiService: await checkService(API_SERVICE_URL, 'api')
  };

  res.json({
    status: 'healthy',
    service: 'dashboard-service',
    tenant: TENANT_ID,
    uptime: `${Math.floor(uptime)}s`,
    dependencies: checks,
    timestamp: new Date().toISOString(),
    memory: {
      used: `${Math.round(process.memoryUsage().heapUsed / 1024 / 1024)}MB`,
      total: `${Math.round(process.memoryUsage().heapTotal / 1024 / 1024)}MB`
    }
  });
});

module.exports = router;
