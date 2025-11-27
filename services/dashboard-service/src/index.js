const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const path = require('path');
const { logger } = require('./utils/logger');
const { register, collectDefaultMetrics } = require('prom-client');
const dashboardRoutes = require('./routes/dashboard');
const healthRoutes = require('./routes/health');

// Collect default metrics
collectDefaultMetrics({ register });

const app = express();
const PORT = process.env.PORT || 3000;
const TENANT_ID = process.env.TENANT_ID || 'default';
const TENANT_NAME = process.env.TENANT_NAME || 'Default Tenant';

// Security middleware with CSP configuration for inline styles
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
      scriptSrc: ["'self'", "'unsafe-inline'"],
      imgSrc: ["'self'", "data:", "https:"],
    },
  },
}));

// CORS configuration
app.use(cors({
  origin: process.env.ALLOWED_ORIGINS?.split(',') || '*',
  credentials: true
}));

// Body parser
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Static files
app.use(express.static(path.join(__dirname, 'public')));

// View engine setup
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

// Make tenant info available to all templates
app.locals.tenantId = TENANT_ID;
app.locals.tenantName = TENANT_NAME;

// Request logging middleware
app.use((req, res, next) => {
  logger.info({
    method: req.method,
    path: req.path,
    tenant: TENANT_ID,
    ip: req.ip
  });
  next();
});

// Routes
app.use('/health', healthRoutes);
app.use('/', dashboardRoutes);

// Metrics endpoint
app.get('/metrics', async (req, res) => {
  try {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (err) {
    res.status(500).end(err);
  }
});

// 404 handler
app.use((req, res) => {
  res.status(404).render('error', {
    title: '404 - Not Found',
    message: 'Page not found',
    statusCode: 404
  });
});

// Global error handler
app.use((err, req, res, next) => {
  logger.error({
    message: err.message,
    stack: err.stack,
    path: req.path,
    tenant: TENANT_ID
  });

  res.status(err.statusCode || 500).render('error', {
    title: 'Error',
    message: err.message || 'Internal server error',
    statusCode: err.statusCode || 500,
    ...(process.env.NODE_ENV === 'development' && { stack: err.stack })
  });
});

// Graceful shutdown
const gracefulShutdown = (signal) => {
  logger.info(`${signal} received, shutting down gracefully`);
  server.close(() => {
    logger.info('Server closed');
    process.exit(0);
  });

  setTimeout(() => {
    logger.error('Forcing shutdown after timeout');
    process.exit(1);
  }, 10000);
};

const server = app.listen(PORT, () => {
  logger.info({
    message: 'Dashboard Service started',
    port: PORT,
    tenant: TENANT_ID,
    tenantName: TENANT_NAME,
    environment: process.env.NODE_ENV || 'development'
  });
});

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

process.on('uncaughtException', (err) => {
  logger.error({
    message: 'Uncaught Exception',
    error: err.message,
    stack: err.stack
  });
  process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
  logger.error({
    message: 'Unhandled Rejection',
    reason: reason
  });
  process.exit(1);
});

module.exports = app;
