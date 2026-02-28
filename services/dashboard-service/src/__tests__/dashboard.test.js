const request = require('supertest');
const app = require('../index');

afterAll((done) => {
  if (app && app.close) {
    app.close(done);
  } else {
    done();
  }
});

describe('Dashboard Service - Health Endpoints', () => {
  test('GET /health should return healthy status', async () => {
    const res = await request(app).get('/health');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('healthy');
    expect(res.body.service).toBeDefined();
    expect(res.body).toHaveProperty('tenant');
    expect(res.body).toHaveProperty('uptime');
  });

  test('GET /health/live should return alive', async () => {
    const res = await request(app).get('/health/live');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('alive');
  });

  test('GET /health/ready should return degraded when dependencies are down', async () => {
    const res = await request(app).get('/health/ready');
    expect(res.statusCode).toBe(200);
    // Dashboard checks auth + api service availability
    // When they're not running, status is "degraded" (not "not ready")
    // because the service itself is ok, just dependencies are down
    expect(res.body.status).toBe('degraded');
    expect(res.body).toHaveProperty('checks');
    expect(res.body.checks.service).toBe('ok');
    expect(res.body.checks.authService).toBe('unavailable');
    expect(res.body.checks.apiService).toBe('unavailable');
  });
});

describe('Dashboard Service - Pages', () => {
  test('GET / should render home page', async () => {
    const res = await request(app).get('/');
    expect(res.statusCode).toBe(200);
    expect(res.text).toContain('html');
    expect(res.text).toContain('Dashboard');
    expect(res.headers['content-type']).toContain('text/html');
  });

  test('GET /login should render login page', async () => {
    const res = await request(app).get('/login');
    expect(res.statusCode).toBe(200);
    expect(res.text).toContain('Login');
    expect(res.text).toContain('username');
    expect(res.text).toContain('password');
    expect(res.headers['content-type']).toContain('text/html');
  });

  test('GET /register should render register page', async () => {
    const res = await request(app).get('/register');
    expect(res.statusCode).toBe(200);
    expect(res.text).toContain('Register');
    expect(res.text).toContain('username');
    expect(res.text).toContain('password');
    expect(res.text).toContain('email');
    expect(res.headers['content-type']).toContain('text/html');
  });

  test('GET /dashboard without token should redirect to login', async () => {
    const res = await request(app).get('/dashboard');
    expect(res.statusCode).toBe(302);
    expect(res.headers.location).toBe('/login');
  });

  test('GET /dashboard with invalid token should redirect to login', async () => {
    const res = await request(app)
      .get('/dashboard?token=Bearer invalidtoken');
    // Should redirect to login since auth-service is not running
    expect(res.statusCode).toBe(302);
    expect(res.headers.location).toBe('/login');
  });
});

describe('Dashboard Service - Tenant Info API', () => {
  test('GET /api/tenant-info should return tenant information', async () => {
    const res = await request(app).get('/api/tenant-info');
    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body).toHaveProperty('tenant');
    expect(res.body.tenant).toHaveProperty('id');
    expect(res.body.tenant).toHaveProperty('name');
    expect(res.body).toHaveProperty('services');
    expect(res.body.services).toHaveProperty('auth');
    expect(res.body.services).toHaveProperty('api');
  });
});

describe('Dashboard Service - Metrics', () => {
  test('GET /metrics should return Prometheus metrics', async () => {
    const res = await request(app).get('/metrics');
    expect(res.statusCode).toBe(200);
    expect(res.text).toContain('process_cpu');
  });
});

describe('Dashboard Service - 404', () => {
  test('GET /nonexistent should return 404 error page', async () => {
    const res = await request(app).get('/nonexistent-page-xyz');
    expect(res.statusCode).toBe(404);
    // Should render error view (HTML)
    expect(res.text).toContain('404');
  });
});

describe('Dashboard Service - Security', () => {
  test('Should include security headers', async () => {
    const res = await request(app).get('/');
    expect(res.headers).toHaveProperty('x-content-type-options', 'nosniff');
  });

  test('Tenant info should be present in pages', async () => {
    const res = await request(app).get('/login');
    expect(res.text).toContain('Tenant');
  });
});

// ── authenticated dashboard (axios mocked) ────────────────────────────────────

jest.mock('axios');
const axios = require('axios');

describe('Dashboard Service – Authenticated Dashboard', () => {
  test('GET /dashboard with valid token renders dashboard page', async () => {
    axios.post.mockResolvedValue({
      data: {
        success: true,
        user: { username: 'testuser', tenant: 'default', email: 'test@test.com' }
      }
    });
    axios.get.mockResolvedValue({
      data: { tasks: [{ id: '1', title: 'My Task', status: 'pending' }] }
    });

    const res = await request(app)
      .get('/dashboard')
      .set('Authorization', 'Bearer valid-token');
    expect(res.statusCode).toBe(200);
    expect(res.headers['content-type']).toContain('text/html');
    expect(res.text).toContain('Dashboard');
  });

  test('GET /dashboard with valid token but failing tasks API still renders', async () => {
    axios.post.mockResolvedValue({
      data: {
        success: true,
        user: { username: 'testuser2', tenant: 'default', email: 't2@test.com' }
      }
    });
    // Tasks endpoint is down — should gracefully degrade (empty task list)
    axios.get.mockRejectedValue(new Error('connect ECONNREFUSED'));

    const res = await request(app)
      .get('/dashboard')
      .set('Authorization', 'Bearer valid-token');
    expect(res.statusCode).toBe(200);
    expect(res.text).toContain('Dashboard');
  });

  test('GET /dashboard with auth-service returning success:false → redirect /login', async () => {
    axios.post.mockResolvedValue({ data: { success: false } });

    const res = await request(app)
      .get('/dashboard')
      .set('Authorization', 'Bearer bad-token');
    expect(res.statusCode).toBe(302);
    expect(res.headers.location).toBe('/login');
  });

  test('GET /dashboard when auth-service is unreachable → redirect /login', async () => {
    axios.post.mockRejectedValue(new Error('connect ECONNREFUSED'));

    const res = await request(app)
      .get('/dashboard')
      .set('Authorization', 'Bearer any-token');
    expect(res.statusCode).toBe(302);
    expect(res.headers.location).toBe('/login');
  });
});

// ── tenant-info API ───────────────────────────────────────────────────────────

describe('Dashboard Service – Tenant Info Completeness', () => {
  test('GET /api/tenant-info returns both auth and api service URLs', async () => {
    const res = await request(app).get('/api/tenant-info');
    expect(res.statusCode).toBe(200);
    expect(res.body.services.auth).toBeTruthy();
    expect(res.body.services.api).toBeTruthy();
    expect(res.body.tenant.id).toBeTruthy();
    expect(res.body.tenant.name).toBeTruthy();
  });
});
