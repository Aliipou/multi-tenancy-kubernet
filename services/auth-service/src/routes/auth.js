const express = require('express');
const router = express.Router();
const jwt = require('jsonwebtoken');
const bcrypt = require('bcryptjs');
const { Counter } = require('prom-client');
const { logger } = require('../utils/logger');

// Metrics
const loginAttempts = new Counter({
  name: 'auth_login_attempts_total',
  help: 'Total number of login attempts',
  labelNames: ['status', 'tenant']
});

const registrationAttempts = new Counter({
  name: 'auth_registration_attempts_total',
  help: 'Total number of registration attempts',
  labelNames: ['status', 'tenant']
});

// In-memory user store (replace with database in production)
const users = new Map();

// JWT secret (should be in environment variable)
const JWT_SECRET = process.env.JWT_SECRET || 'your-secret-key-change-this';
const JWT_EXPIRY = process.env.JWT_EXPIRY || '24h';
const TENANT_ID = process.env.TENANT_ID || 'default';

// Validation middleware
const validateRegistration = (req, res, next) => {
  const { username, password, email } = req.body;

  if (!username || username.length < 3) {
    return res.status(400).json({
      success: false,
      message: 'Username must be at least 3 characters long'
    });
  }

  if (!password || password.length < 8) {
    return res.status(400).json({
      success: false,
      message: 'Password must be at least 8 characters long'
    });
  }

  if (!email || !email.includes('@')) {
    return res.status(400).json({
      success: false,
      message: 'Valid email is required'
    });
  }

  next();
};

const validateLogin = (req, res, next) => {
  const { username, password } = req.body;

  if (!username || !password) {
    return res.status(400).json({
      success: false,
      message: 'Username and password are required'
    });
  }

  next();
};

// Register endpoint
router.post('/register', validateRegistration, async (req, res) => {
  try {
    const { username, password, email } = req.body;
    const userKey = `${TENANT_ID}:${username}`;

    // Check if user already exists
    if (users.has(userKey)) {
      registrationAttempts.inc({ status: 'failed', tenant: TENANT_ID });
      return res.status(409).json({
        success: false,
        message: 'User already exists'
      });
    }

    // Hash password
    const hashedPassword = await bcrypt.hash(password, 10);

    // Store user
    users.set(userKey, {
      username,
      email,
      password: hashedPassword,
      tenant: TENANT_ID,
      createdAt: new Date().toISOString()
    });

    registrationAttempts.inc({ status: 'success', tenant: TENANT_ID });

    logger.info({
      message: 'User registered successfully',
      username,
      tenant: TENANT_ID
    });

    res.status(201).json({
      success: true,
      message: 'User registered successfully',
      user: {
        username,
        email,
        tenant: TENANT_ID
      }
    });
  } catch (error) {
    registrationAttempts.inc({ status: 'error', tenant: TENANT_ID });
    logger.error({
      message: 'Registration error',
      error: error.message,
      tenant: TENANT_ID
    });

    res.status(500).json({
      success: false,
      message: 'Registration failed'
    });
  }
});

// Login endpoint
router.post('/login', validateLogin, async (req, res) => {
  try {
    const { username, password } = req.body;
    const userKey = `${TENANT_ID}:${username}`;

    // Find user
    const user = users.get(userKey);

    if (!user) {
      loginAttempts.inc({ status: 'failed', tenant: TENANT_ID });
      return res.status(401).json({
        success: false,
        message: 'Invalid credentials'
      });
    }

    // Verify password
    const isPasswordValid = await bcrypt.compare(password, user.password);

    if (!isPasswordValid) {
      loginAttempts.inc({ status: 'failed', tenant: TENANT_ID });
      return res.status(401).json({
        success: false,
        message: 'Invalid credentials'
      });
    }

    // Generate JWT token
    const token = jwt.sign(
      {
        username: user.username,
        email: user.email,
        tenant: TENANT_ID
      },
      JWT_SECRET,
      { expiresIn: JWT_EXPIRY }
    );

    loginAttempts.inc({ status: 'success', tenant: TENANT_ID });

    logger.info({
      message: 'User logged in successfully',
      username,
      tenant: TENANT_ID
    });

    res.json({
      success: true,
      message: 'Login successful',
      token,
      user: {
        username: user.username,
        email: user.email,
        tenant: TENANT_ID
      }
    });
  } catch (error) {
    loginAttempts.inc({ status: 'error', tenant: TENANT_ID });
    logger.error({
      message: 'Login error',
      error: error.message,
      tenant: TENANT_ID
    });

    res.status(500).json({
      success: false,
      message: 'Login failed'
    });
  }
});

// Verify token endpoint
router.post('/verify', (req, res) => {
  try {
    const token = req.headers.authorization?.replace('Bearer ', '');

    if (!token) {
      return res.status(401).json({
        success: false,
        message: 'No token provided'
      });
    }

    const decoded = jwt.verify(token, JWT_SECRET);

    res.json({
      success: true,
      message: 'Token is valid',
      user: decoded
    });
  } catch (error) {
    logger.error({
      message: 'Token verification error',
      error: error.message,
      tenant: TENANT_ID
    });

    res.status(401).json({
      success: false,
      message: 'Invalid or expired token'
    });
  }
});

// Get current user info
router.get('/me', (req, res) => {
  try {
    const token = req.headers.authorization?.replace('Bearer ', '');

    if (!token) {
      return res.status(401).json({
        success: false,
        message: 'No token provided'
      });
    }

    const decoded = jwt.verify(token, JWT_SECRET);
    const userKey = `${TENANT_ID}:${decoded.username}`;
    const user = users.get(userKey);

    if (!user) {
      return res.status(404).json({
        success: false,
        message: 'User not found'
      });
    }

    res.json({
      success: true,
      user: {
        username: user.username,
        email: user.email,
        tenant: user.tenant,
        createdAt: user.createdAt
      }
    });
  } catch (error) {
    logger.error({
      message: 'Get user info error',
      error: error.message,
      tenant: TENANT_ID
    });

    res.status(401).json({
      success: false,
      message: 'Invalid or expired token'
    });
  }
});

// Get user statistics (for testing multi-tenancy)
router.get('/stats', (req, res) => {
  const tenantUsers = Array.from(users.entries())
    .filter(([key]) => key.startsWith(`${TENANT_ID}:`))
    .map(([, user]) => ({
      username: user.username,
      email: user.email,
      createdAt: user.createdAt
    }));

  res.json({
    success: true,
    tenant: TENANT_ID,
    userCount: tenantUsers.length,
    users: tenantUsers
  });
});

module.exports = router;
