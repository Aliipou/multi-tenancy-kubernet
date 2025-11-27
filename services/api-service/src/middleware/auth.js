const axios = require('axios');
const { logger } = require('../utils/logger');

const AUTH_SERVICE_URL = process.env.AUTH_SERVICE_URL || 'http://localhost:3001';
const TENANT_ID = process.env.TENANT_ID || 'default';

async function authMiddleware(req, res, next) {
  try {
    const token = req.headers.authorization;

    if (!token) {
      return res.status(401).json({
        success: false,
        message: 'No authentication token provided'
      });
    }

    // Verify token with auth service
    const response = await axios.post(
      `${AUTH_SERVICE_URL}/api/auth/verify`,
      {},
      {
        headers: { Authorization: token },
        timeout: 5000
      }
    );

    if (!response.data.success) {
      return res.status(401).json({
        success: false,
        message: 'Invalid or expired token'
      });
    }

    // Verify tenant match
    const user = response.data.user;
    if (user.tenant !== TENANT_ID) {
      logger.warn({
        message: 'Tenant mismatch',
        userTenant: user.tenant,
        serviceTenant: TENANT_ID,
        username: user.username
      });
      return res.status(403).json({
        success: false,
        message: 'Unauthorized access to this tenant'
      });
    }

    // Attach user to request
    req.user = user;
    next();
  } catch (error) {
    logger.error({
      message: 'Authentication error',
      error: error.message,
      tenant: TENANT_ID
    });

    res.status(401).json({
      success: false,
      message: 'Authentication failed'
    });
  }
}

module.exports = authMiddleware;
