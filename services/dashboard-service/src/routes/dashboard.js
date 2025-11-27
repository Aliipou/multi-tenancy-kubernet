const express = require('express');
const router = express.Router();
const axios = require('axios');
const { logger } = require('../utils/logger');

const AUTH_SERVICE_URL = process.env.AUTH_SERVICE_URL || 'http://localhost:3001';
const API_SERVICE_URL = process.env.API_SERVICE_URL || 'http://localhost:3002';
const TENANT_ID = process.env.TENANT_ID || 'default';
const TENANT_NAME = process.env.TENANT_NAME || 'Default Tenant';

// Home page
router.get('/', (req, res) => {
  res.render('index', {
    title: 'Dashboard',
    tenant: {
      id: TENANT_ID,
      name: TENANT_NAME
    }
  });
});

// Login page
router.get('/login', (req, res) => {
  res.render('login', {
    title: 'Login',
    tenant: {
      id: TENANT_ID,
      name: TENANT_NAME
    }
  });
});

// Register page
router.get('/register', (req, res) => {
  res.render('register', {
    title: 'Register',
    tenant: {
      id: TENANT_ID,
      name: TENANT_NAME
    }
  });
});

// Dashboard page (requires authentication)
router.get('/dashboard', async (req, res) => {
  try {
    const token = req.headers.authorization || req.query.token;

    if (!token) {
      return res.redirect('/login');
    }

    // Verify token with auth service
    const authResponse = await axios.post(
      `${AUTH_SERVICE_URL}/api/auth/verify`,
      {},
      {
        headers: { Authorization: token },
        timeout: 5000
      }
    );

    if (!authResponse.data.success) {
      return res.redirect('/login');
    }

    // Get tasks from API service
    let tasks = [];
    try {
      const tasksResponse = await axios.get(
        `${API_SERVICE_URL}/api/tasks`,
        {
          headers: { Authorization: token },
          timeout: 5000
        }
      );
      tasks = tasksResponse.data.tasks || [];
    } catch (error) {
      logger.warn({
        message: 'Failed to fetch tasks',
        error: error.message,
        tenant: TENANT_ID
      });
    }

    res.render('dashboard', {
      title: 'Dashboard',
      user: authResponse.data.user,
      tasks,
      tenant: {
        id: TENANT_ID,
        name: TENANT_NAME
      }
    });
  } catch (error) {
    logger.error({
      message: 'Dashboard error',
      error: error.message,
      tenant: TENANT_ID
    });
    res.redirect('/login');
  }
});

// Tenant info endpoint (for testing)
router.get('/api/tenant-info', (req, res) => {
  res.json({
    success: true,
    tenant: {
      id: TENANT_ID,
      name: TENANT_NAME
    },
    services: {
      auth: AUTH_SERVICE_URL,
      api: API_SERVICE_URL
    }
  });
});

module.exports = router;
