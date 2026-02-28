const request = require('supertest');
const app = require('../index');

// Close server after all tests
let server;
beforeAll((done) => {
  // The app already starts listening in index.js, so we need to close it
  // and create our own for testing
  server = app;
  done();
});

afterAll((done) => {
  // Give time for server to close
  if (server && server.close) {
    server.close(done);
  } else {
    done();
  }
});

describe('Auth Service - Health Endpoints', () => {
  test('GET /health should return healthy status', async () => {
    const res = await request(app).get('/health');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('healthy');
    expect(res.body.service).toBe('auth-service');
    expect(res.body).toHaveProperty('tenant');
    expect(res.body).toHaveProperty('uptime');
    expect(res.body).toHaveProperty('memory');
  });

  test('GET /health/live should return alive', async () => {
    const res = await request(app).get('/health/live');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('alive');
  });

  test('GET /health/ready should return ready', async () => {
    const res = await request(app).get('/health/ready');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('ready');
  });
});

describe('Auth Service - Registration', () => {
  test('POST /api/auth/register should register a new user', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({
        username: 'testuser',
        password: 'testpass123',
        email: 'test@example.com'
      });
    expect(res.statusCode).toBe(201);
    expect(res.body.success).toBe(true);
    expect(res.body.user.username).toBe('testuser');
    expect(res.body.user.email).toBe('test@example.com');
    expect(res.body.user).toHaveProperty('tenant');
  });

  test('POST /api/auth/register should reject duplicate user', async () => {
    // First register
    await request(app)
      .post('/api/auth/register')
      .send({
        username: 'dupeuser',
        password: 'testpass123',
        email: 'dupe@example.com'
      });

    // Try again
    const res = await request(app)
      .post('/api/auth/register')
      .send({
        username: 'dupeuser',
        password: 'testpass123',
        email: 'dupe@example.com'
      });
    expect(res.statusCode).toBe(409);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toBe('User already exists');
  });

  test('POST /api/auth/register should reject short username', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({
        username: 'ab',
        password: 'testpass123',
        email: 'test@example.com'
      });
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
  });

  test('POST /api/auth/register should reject short password', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({
        username: 'validuser',
        password: 'short',
        email: 'test@example.com'
      });
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
  });

  test('POST /api/auth/register should reject invalid email', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({
        username: 'validuser2',
        password: 'testpass123',
        email: 'notanemail'
      });
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
  });

  test('POST /api/auth/register should reject missing fields', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({});
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
  });
});

describe('Auth Service - Login', () => {
  beforeAll(async () => {
    // Register a user for login tests
    await request(app)
      .post('/api/auth/register')
      .send({
        username: 'loginuser',
        password: 'password123',
        email: 'login@example.com'
      });
  });

  test('POST /api/auth/login should login successfully with valid credentials', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .send({
        username: 'loginuser',
        password: 'password123'
      });
    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body).toHaveProperty('token');
    expect(res.body.user.username).toBe('loginuser');
    expect(typeof res.body.token).toBe('string');
    expect(res.body.token.length).toBeGreaterThan(0);
  });

  test('POST /api/auth/login should reject wrong password', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .send({
        username: 'loginuser',
        password: 'wrongpassword'
      });
    expect(res.statusCode).toBe(401);
    expect(res.body.success).toBe(false);
  });

  test('POST /api/auth/login should reject non-existent user', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .send({
        username: 'ghostuser',
        password: 'password123'
      });
    expect(res.statusCode).toBe(401);
    expect(res.body.success).toBe(false);
  });

  test('POST /api/auth/login should reject missing fields', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .send({});
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
  });
});

describe('Auth Service - Token Verification', () => {
  let validToken;

  beforeAll(async () => {
    await request(app)
      .post('/api/auth/register')
      .send({
        username: 'verifyuser',
        password: 'password123',
        email: 'verify@example.com'
      });

    const loginRes = await request(app)
      .post('/api/auth/login')
      .send({
        username: 'verifyuser',
        password: 'password123'
      });
    validToken = loginRes.body.token;
  });

  test('POST /api/auth/verify should validate a good token', async () => {
    const res = await request(app)
      .post('/api/auth/verify')
      .set('Authorization', `Bearer ${validToken}`);
    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.user).toHaveProperty('username', 'verifyuser');
    expect(res.body.user).toHaveProperty('tenant');
  });

  test('POST /api/auth/verify should reject invalid token', async () => {
    const res = await request(app)
      .post('/api/auth/verify')
      .set('Authorization', 'Bearer invalidtoken123');
    expect(res.statusCode).toBe(401);
    expect(res.body.success).toBe(false);
  });

  test('POST /api/auth/verify should reject missing token', async () => {
    const res = await request(app)
      .post('/api/auth/verify');
    expect(res.statusCode).toBe(401);
    expect(res.body.success).toBe(false);
  });
});

describe('Auth Service - User Info', () => {
  let validToken;

  beforeAll(async () => {
    await request(app)
      .post('/api/auth/register')
      .send({
        username: 'infouser',
        password: 'password123',
        email: 'info@example.com'
      });

    const loginRes = await request(app)
      .post('/api/auth/login')
      .send({
        username: 'infouser',
        password: 'password123'
      });
    validToken = loginRes.body.token;
  });

  test('GET /api/auth/me should return user info with valid token', async () => {
    const res = await request(app)
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${validToken}`);
    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.user.username).toBe('infouser');
    expect(res.body.user.email).toBe('info@example.com');
    expect(res.body.user).toHaveProperty('createdAt');
    // Should NOT return password
    expect(res.body.user).not.toHaveProperty('password');
  });

  test('GET /api/auth/me should reject no token', async () => {
    const res = await request(app)
      .get('/api/auth/me');
    expect(res.statusCode).toBe(401);
  });
});

describe('Auth Service - Stats', () => {
  test('GET /api/auth/stats should return tenant user statistics', async () => {
    const res = await request(app)
      .get('/api/auth/stats');
    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body).toHaveProperty('tenant');
    expect(res.body).toHaveProperty('userCount');
    expect(typeof res.body.userCount).toBe('number');
    expect(Array.isArray(res.body.users)).toBe(true);
    // Users should not contain passwords
    res.body.users.forEach(user => {
      expect(user).not.toHaveProperty('password');
    });
  });
});

describe('Auth Service - Metrics', () => {
  test('GET /metrics should return Prometheus metrics', async () => {
    const res = await request(app).get('/metrics');
    expect(res.statusCode).toBe(200);
    expect(res.text).toContain('process_cpu');
    expect(res.headers['content-type']).toContain('text/plain');
  });
});

describe('Auth Service - 404 Handler', () => {
  test('GET /nonexistent should return 404', async () => {
    const res = await request(app).get('/nonexistent');
    expect(res.statusCode).toBe(404);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toBe('Route not found');
  });
});

describe('Auth Service - Security', () => {
  test('Response should include security headers from helmet', async () => {
    const res = await request(app).get('/health');
    // Helmet sets various security headers
    expect(res.headers).toHaveProperty('x-content-type-options');
    expect(res.headers['x-content-type-options']).toBe('nosniff');
  });

  test('POST /api/auth/register should handle oversized payload', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({
        username: 'x'.repeat(10000),
        password: 'x'.repeat(10000),
        email: 'x'.repeat(10000)
      });
    // Should either reject (413) or handle gracefully (400)
    expect([400, 413]).toContain(res.statusCode);
  });
});

describe('Tenant Isolation - Auth Service', () => {
  test('Users are scoped to tenant ID (default tenant)', async () => {
    const reg = await request(app)
      .post('/api/auth/register')
      .send({
        username: 'tenant_test_user',
        password: 'password123',
        email: 'tenant@example.com'
      });
    expect(reg.statusCode).toBe(201);
    expect(reg.body.user.tenant).toBe('default');

    const login = await request(app)
      .post('/api/auth/login')
      .send({
        username: 'tenant_test_user',
        password: 'password123'
      });
    expect(login.statusCode).toBe(200);
    expect(login.body.user.tenant).toBe('default');

    const verify = await request(app)
      .post('/api/auth/verify')
      .set('Authorization', `Bearer ${login.body.token}`);
    expect(verify.statusCode).toBe(200);
    expect(verify.body.user.tenant).toBe('default');
  });

  test('Stats endpoint only shows users for current tenant', async () => {
    const stats = await request(app).get('/api/auth/stats');
    expect(stats.statusCode).toBe(200);
    expect(stats.body.tenant).toBe('default');
    stats.body.users.forEach(user => {
      expect(user).toHaveProperty('username');
      expect(user).toHaveProperty('email');
      expect(user).not.toHaveProperty('password');
    });
  });

  test('JWT token includes tenant identifier', async () => {
    await request(app)
      .post('/api/auth/register')
      .send({
        username: 'jwt_tenant_user',
        password: 'password123',
        email: 'jwt_tenant@example.com'
      });

    const login = await request(app)
      .post('/api/auth/login')
      .send({
        username: 'jwt_tenant_user',
        password: 'password123'
      });

    const tokenParts = login.body.token.split('.');
    const payload = JSON.parse(Buffer.from(tokenParts[1], 'base64').toString());
    expect(payload).toHaveProperty('tenant', 'default');
    expect(payload).toHaveProperty('username', 'jwt_tenant_user');
    expect(payload).toHaveProperty('exp');
    expect(payload).toHaveProperty('iat');
  });
});

describe('Password Security', () => {
  test('Passwords are not exposed in API responses', async () => {
    await request(app)
      .post('/api/auth/register')
      .send({
        username: 'hash_test_user',
        password: 'myplainpassword',
        email: 'hash@example.com'
      });

    const stats = await request(app).get('/api/auth/stats');
    stats.body.users.forEach(user => {
      expect(user).not.toHaveProperty('password');
    });
  });

  test('Login should fail with slightly wrong password', async () => {
    await request(app)
      .post('/api/auth/register')
      .send({
        username: 'wrongpass_user',
        password: 'correctpassword',
        email: 'wrong@example.com'
      });

    const res = await request(app)
      .post('/api/auth/login')
      .send({
        username: 'wrongpass_user',
        password: 'correctpassworD'
      });
    expect(res.statusCode).toBe(401);
  });
});

// ── boundary conditions ───────────────────────────────────────────────────────

describe('Auth Service – Validation Boundaries', () => {
  test('Username of exactly 3 characters is accepted → 201', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ username: 'abc', password: 'password123', email: 'abc@example.com' });
    expect(res.statusCode).toBe(201);
    expect(res.body.success).toBe(true);
  });

  test('Username of 2 characters is rejected → 400', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ username: 'ab', password: 'password123', email: 'ab@example.com' });
    expect(res.statusCode).toBe(400);
    expect(res.body.message).toMatch(/3 characters/i);
  });

  test('Password of exactly 8 characters is accepted → 201', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ username: 'pass8user', password: '12345678', email: 'pass8@example.com' });
    expect(res.statusCode).toBe(201);
    expect(res.body.success).toBe(true);
  });

  test('Password of 7 characters is rejected → 400', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ username: 'short7usr', password: '1234567', email: 'short7@example.com' });
    expect(res.statusCode).toBe(400);
    expect(res.body.message).toMatch(/8 characters/i);
  });

  test('Email without @ is rejected → 400', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({ username: 'emailtest', password: 'password123', email: 'notanemail' });
    expect(res.statusCode).toBe(400);
    expect(res.body.message).toMatch(/email/i);
  });

  test('Login with missing username field → 400', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .send({ password: 'password123' });
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
  });

  test('Login with missing password field → 400', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .send({ username: 'someuser' });
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
  });
});

// ── token edge cases ──────────────────────────────────────────────────────────

describe('Auth Service – Token Edge Cases', () => {
  const jwt = require('jsonwebtoken');

  test('Token signed with wrong secret is rejected by /verify → 401', async () => {
    const fakeToken = jwt.sign(
      { username: 'hacker', tenant: 'default' },
      'wrong-secret-entirely'
    );
    const res = await request(app)
      .post('/api/auth/verify')
      .set('Authorization', `Bearer ${fakeToken}`);
    expect(res.statusCode).toBe(401);
    expect(res.body.success).toBe(false);
  });

  test('Malformed JWT (not three parts) is rejected → 401', async () => {
    const res = await request(app)
      .post('/api/auth/verify')
      .set('Authorization', 'Bearer notajwt');
    expect(res.statusCode).toBe(401);
    expect(res.body.success).toBe(false);
  });

  test('GET /me with valid token for unknown user → 404', async () => {
    // Sign a token for a username that was never registered
    const orphanToken = jwt.sign(
      { username: 'ghost_never_registered', tenant: 'default' },
      process.env.JWT_SECRET || 'your-secret-key-change-this',
      { expiresIn: '1h' }
    );
    const res = await request(app)
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${orphanToken}`);
    expect(res.statusCode).toBe(404);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toMatch(/not found/i);
  });

  test('Authorization header without "Bearer " prefix still works for /verify', async () => {
    // Register and login first
    await request(app)
      .post('/api/auth/register')
      .send({ username: 'prefix_user', password: 'password123', email: 'prefix@example.com' });
    const login = await request(app)
      .post('/api/auth/login')
      .send({ username: 'prefix_user', password: 'password123' });
    const rawToken = login.body.token;

    // auth.js strips 'Bearer ' with replace — so passing just the token also works
    const res = await request(app)
      .post('/api/auth/verify')
      .set('Authorization', rawToken);
    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
  });
});

// ── stats endpoint ────────────────────────────────────────────────────────────

describe('Auth Service – Stats Consistency', () => {
  test('userCount matches length of users array', async () => {
    const res = await request(app).get('/api/auth/stats');
    expect(res.statusCode).toBe(200);
    expect(res.body.userCount).toBe(res.body.users.length);
  });

  test('Each user in stats has username, email, createdAt', async () => {
    const res = await request(app).get('/api/auth/stats');
    res.body.users.forEach((u) => {
      expect(u).toHaveProperty('username');
      expect(u).toHaveProperty('email');
      expect(u).toHaveProperty('createdAt');
      expect(u).not.toHaveProperty('password');
    });
  });

  test('Stats tenant matches service TENANT_ID (default)', async () => {
    const res = await request(app).get('/api/auth/stats');
    expect(res.body.tenant).toBe('default');
  });
});
