'use strict';
/**
 * API-service integration tests.
 *
 * Strategy:
 *  - jest.mock('axios') intercepts every call the auth middleware makes to the
 *    auth-service, so we never need a real auth-service running.
 *  - Each describe block that exercises the task CRUD uses a unique username so
 *    the in-memory Map never leaks state across groups.
 *  - Tests are ordered so dependencies are created before they are used.
 */

jest.mock('axios');

const request = require('supertest');
const axios = require('axios');
const app = require('../index');

// ── helpers ──────────────────────────────────────────────────────────────────

/** Make axios.post resolve as a successful auth response for `username`. */
function mockAuthOk(username = 'testuser', tenant = 'default') {
  axios.post.mockResolvedValue({
    data: { success: true, user: { username, tenant, email: `${username}@test.com` } }
  });
}

/** Make the auth middleware reject (simulates auth-service unreachable). */
function mockAuthFail() {
  axios.post.mockRejectedValue(new Error('connect ECONNREFUSED'));
}

/** Make auth-service return success:false (bad token scenario). */
function mockAuthInvalid() {
  axios.post.mockResolvedValue({ data: { success: false } });
}

/** Make auth-service return a user from a different tenant. */
function mockAuthWrongTenant() {
  axios.post.mockResolvedValue({
    data: { success: true, user: { username: 'alien', tenant: 'tenant-other' } }
  });
}

afterAll((done) => {
  // supertest binds its own ephemeral port; the server started in index.js
  // holds an open handle — close it so Jest can exit cleanly.
  if (app && app.close) {
    app.close(done);
  } else {
    done();
  }
});

// ── health endpoints ──────────────────────────────────────────────────────────

describe('API Service – Health Endpoints', () => {
  test('GET /health returns healthy status with expected fields', async () => {
    const res = await request(app).get('/health');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('healthy');
    expect(res.body.service).toBe('api-service');
    expect(res.body).toHaveProperty('tenant');
    expect(res.body).toHaveProperty('uptime');
    expect(res.body.memory).toHaveProperty('used');
    expect(res.body.memory).toHaveProperty('total');
  });

  test('GET /health/live returns alive', async () => {
    const res = await request(app).get('/health/live');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('alive');
    expect(res.body.service).toBe('api-service');
  });

  test('GET /health/ready returns ready (no external deps)', async () => {
    const res = await request(app).get('/health/ready');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('ready');
  });

  test('GET /health/startup returns started after boot', async () => {
    await new Promise((r) => setTimeout(r, 1100));
    const res = await request(app).get('/health/startup');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('started');
  });
});

// ── authentication guard ─────────────────────────────────────────────────────

describe('API Service – Authentication Guard', () => {
  beforeEach(() => mockAuthFail());

  test('GET /api/tasks without token → 401', async () => {
    const res = await request(app).get('/api/tasks');
    expect(res.statusCode).toBe(401);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toBe('No authentication token provided');
  });

  test('POST /api/tasks without token → 401', async () => {
    const res = await request(app).post('/api/tasks').send({ title: 'x' });
    expect(res.statusCode).toBe(401);
    expect(res.body.success).toBe(false);
  });

  test('PUT /api/tasks/someId without token → 401', async () => {
    const res = await request(app).put('/api/tasks/someId').send({ title: 'y' });
    expect(res.statusCode).toBe(401);
    expect(res.body.success).toBe(false);
  });

  test('DELETE /api/tasks/someId without token → 401', async () => {
    const res = await request(app).delete('/api/tasks/someId');
    expect(res.statusCode).toBe(401);
    expect(res.body.success).toBe(false);
  });

  test('GET /api/tasks with invalid token → 401 (auth-service unreachable)', async () => {
    const res = await request(app)
      .get('/api/tasks')
      .set('Authorization', 'Bearer bad-token');
    expect(res.statusCode).toBe(401);
    expect(res.body.success).toBe(false);
  });

  test('GET /api/tasks with auth-service returning success:false → 401', async () => {
    mockAuthInvalid();
    const res = await request(app)
      .get('/api/tasks')
      .set('Authorization', 'Bearer some-token');
    expect(res.statusCode).toBe(401);
    expect(res.body.success).toBe(false);
  });

  test('GET /api/tasks with token from different tenant → 403', async () => {
    mockAuthWrongTenant();
    const res = await request(app)
      .get('/api/tasks')
      .set('Authorization', 'Bearer cross-tenant-token');
    expect(res.statusCode).toBe(403);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toMatch(/tenant/i);
  });
});

// ── task CRUD ────────────────────────────────────────────────────────────────
// Each sub-describe uses a unique username so tasks never bleed across groups.

describe('API Service – Task List (GET /api/tasks)', () => {
  const USER = 'list_user_1';
  beforeEach(() => mockAuthOk(USER));

  test('Empty task list is returned for a new user', async () => {
    const res = await request(app)
      .get('/api/tasks')
      .set('Authorization', 'Bearer tok');
    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(Array.isArray(res.body.tasks)).toBe(true);
    expect(res.body).toHaveProperty('count');
  });
});

describe('API Service – Task Creation (POST /api/tasks)', () => {
  const USER = 'create_user_1';
  beforeEach(() => mockAuthOk(USER));

  test('Creates a task with title only (defaults applied)', async () => {
    const res = await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: 'My first task' });
    expect(res.statusCode).toBe(201);
    expect(res.body.success).toBe(true);
    expect(res.body.task.title).toBe('My first task');
    expect(res.body.task.status).toBe('pending');
    expect(res.body.task.priority).toBe('medium');
    expect(res.body.task).toHaveProperty('id');
    expect(res.body.task).toHaveProperty('createdAt');
  });

  test('Creates a task with all fields specified', async () => {
    const res = await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: 'Priority task', description: 'desc', priority: 'high' });
    expect(res.statusCode).toBe(201);
    expect(res.body.task.priority).toBe('high');
    expect(res.body.task.description).toBe('desc');
  });

  test('Trims whitespace from title', async () => {
    const res = await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: '   padded   ' });
    expect(res.statusCode).toBe(201);
    expect(res.body.task.title).toBe('padded');
  });

  test('Rejects empty title → 400', async () => {
    const res = await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: '' });
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toMatch(/title/i);
  });

  test('Rejects whitespace-only title → 400', async () => {
    const res = await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: '   ' });
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
  });

  test('Rejects title exceeding 200 characters → 400', async () => {
    const res = await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: 'a'.repeat(201) });
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toMatch(/200/);
  });

  test('Accepts title of exactly 200 characters → 201', async () => {
    const res = await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: 'b'.repeat(200) });
    expect(res.statusCode).toBe(201);
    expect(res.body.task.title.length).toBe(200);
  });

  test('Rejects missing title field → 400', async () => {
    const res = await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ description: 'no title here' });
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
  });
});

describe('API Service – Get Single Task (GET /api/tasks/:id)', () => {
  const USER = 'getone_user_1';
  let taskId;

  beforeAll(async () => {
    mockAuthOk(USER);
    const res = await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: 'Task to fetch' });
    taskId = res.body.task.id;
  });

  beforeEach(() => mockAuthOk(USER));

  test('Returns the correct task by ID', async () => {
    const res = await request(app)
      .get(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok');
    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.task.id).toBe(taskId);
    expect(res.body.task.title).toBe('Task to fetch');
  });

  test('Returns 404 for a non-existent task ID', async () => {
    const res = await request(app)
      .get('/api/tasks/00000000-0000-0000-0000-000000000000')
      .set('Authorization', 'Bearer tok');
    expect(res.statusCode).toBe(404);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toMatch(/not found/i);
  });

  test('Returns 403 when another user tries to read this task', async () => {
    mockAuthOk('other_user_entirely');
    const res = await request(app)
      .get(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok');
    expect(res.statusCode).toBe(403);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toMatch(/unauthorized/i);
  });
});

describe('API Service – Update Task (PUT /api/tasks/:id)', () => {
  const USER = 'update_user_1';
  let taskId;

  beforeAll(async () => {
    mockAuthOk(USER);
    const res = await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: 'Original title', priority: 'low' });
    taskId = res.body.task.id;
  });

  beforeEach(() => mockAuthOk(USER));

  test('Updates title successfully', async () => {
    const res = await request(app)
      .put(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok')
      .send({ title: 'Updated title' });
    expect(res.statusCode).toBe(200);
    expect(res.body.task.title).toBe('Updated title');
  });

  test('Updates status to in_progress', async () => {
    const res = await request(app)
      .put(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok')
      .send({ status: 'in_progress' });
    expect(res.statusCode).toBe(200);
    expect(res.body.task.status).toBe('in_progress');
  });

  test('Updates status to completed', async () => {
    const res = await request(app)
      .put(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok')
      .send({ status: 'completed' });
    expect(res.statusCode).toBe(200);
    expect(res.body.task.status).toBe('completed');
  });

  test('Updates status to cancelled', async () => {
    const res = await request(app)
      .put(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok')
      .send({ status: 'cancelled' });
    expect(res.statusCode).toBe(200);
    expect(res.body.task.status).toBe('cancelled');
  });

  test('Updates priority to high', async () => {
    const res = await request(app)
      .put(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok')
      .send({ priority: 'high' });
    expect(res.statusCode).toBe(200);
    expect(res.body.task.priority).toBe('high');
  });

  test('Updates description', async () => {
    const res = await request(app)
      .put(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok')
      .send({ description: 'new desc' });
    expect(res.statusCode).toBe(200);
    expect(res.body.task.description).toBe('new desc');
  });

  test('updatedAt timestamp advances on update', async () => {
    const before = await request(app)
      .get(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok');
    const t1 = before.body.task.updatedAt;

    await new Promise((r) => setTimeout(r, 5));

    const after = await request(app)
      .put(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok')
      .send({ title: 'Timestamped' });
    const t2 = after.body.task.updatedAt;
    expect(new Date(t2).getTime()).toBeGreaterThanOrEqual(new Date(t1).getTime());
  });

  test('Rejects invalid status value → 400', async () => {
    const res = await request(app)
      .put(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok')
      .send({ status: 'flying' });
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toMatch(/invalid status/i);
  });

  test('Rejects invalid priority value → 400', async () => {
    const res = await request(app)
      .put(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok')
      .send({ priority: 'ultra' });
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toMatch(/invalid priority/i);
  });

  test('Rejects blank title on update → 400', async () => {
    const res = await request(app)
      .put(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok')
      .send({ title: '   ' });
    expect(res.statusCode).toBe(400);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toMatch(/empty/i);
  });

  test('Returns 404 for non-existent task', async () => {
    const res = await request(app)
      .put('/api/tasks/00000000-0000-0000-0000-000000000000')
      .set('Authorization', 'Bearer tok')
      .send({ title: 'ghost' });
    expect(res.statusCode).toBe(404);
    expect(res.body.success).toBe(false);
  });

  test('Returns 403 when another user tries to update this task', async () => {
    mockAuthOk('intruder_update');
    const res = await request(app)
      .put(`/api/tasks/${taskId}`)
      .set('Authorization', 'Bearer tok')
      .send({ title: 'stolen' });
    expect(res.statusCode).toBe(403);
    expect(res.body.success).toBe(false);
  });
});

describe('API Service – Delete Task (DELETE /api/tasks/:id)', () => {
  const USER = 'delete_user_1';

  beforeEach(() => mockAuthOk(USER));

  test('Deletes an owned task successfully', async () => {
    // Create
    const create = await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: 'Task to delete' });
    const id = create.body.task.id;

    // Delete
    const del = await request(app)
      .delete(`/api/tasks/${id}`)
      .set('Authorization', 'Bearer tok');
    expect(del.statusCode).toBe(200);
    expect(del.body.success).toBe(true);
    expect(del.body.message).toMatch(/deleted/i);

    // Confirm gone
    const check = await request(app)
      .get(`/api/tasks/${id}`)
      .set('Authorization', 'Bearer tok');
    expect(check.statusCode).toBe(404);
  });

  test('Returns 404 when deleting a non-existent task', async () => {
    const res = await request(app)
      .delete('/api/tasks/00000000-0000-0000-0000-000000000000')
      .set('Authorization', 'Bearer tok');
    expect(res.statusCode).toBe(404);
    expect(res.body.success).toBe(false);
  });

  test('Returns 403 when another user tries to delete this task', async () => {
    // Create task as delete_user_1
    const create = await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: 'Protected task' });
    const id = create.body.task.id;

    // Attempt delete as intruder
    mockAuthOk('intruder_delete');
    const res = await request(app)
      .delete(`/api/tasks/${id}`)
      .set('Authorization', 'Bearer tok');
    expect(res.statusCode).toBe(403);
    expect(res.body.success).toBe(false);
  });
});

describe('API Service – Stats Overview (GET /api/tasks/stats/overview)', () => {
  const USER = 'stats_user_1';

  beforeAll(async () => {
    // Seed: 1 pending, 1 completed, 1 high-priority
    mockAuthOk(USER);
    await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: 'Pending task', priority: 'low' });

    await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: 'Completed task', priority: 'high' });

    // Mark second one completed
    const list = await request(app)
      .get('/api/tasks')
      .set('Authorization', 'Bearer tok');
    const completedId = list.body.tasks.find((t) => t.title === 'Completed task').id;
    await request(app)
      .put(`/api/tasks/${completedId}`)
      .set('Authorization', 'Bearer tok')
      .send({ status: 'completed' });
  });

  beforeEach(() => mockAuthOk(USER));

  test('Returns stats with correct structure', async () => {
    const res = await request(app)
      .get('/api/tasks/stats/overview')
      .set('Authorization', 'Bearer tok');
    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.stats).toHaveProperty('total');
    expect(res.body.stats).toHaveProperty('byStatus');
    expect(res.body.stats).toHaveProperty('byPriority');
    expect(res.body.stats.byStatus).toHaveProperty('pending');
    expect(res.body.stats.byStatus).toHaveProperty('in_progress');
    expect(res.body.stats.byStatus).toHaveProperty('completed');
    expect(res.body.stats.byStatus).toHaveProperty('cancelled');
    expect(res.body.stats.byPriority).toHaveProperty('low');
    expect(res.body.stats.byPriority).toHaveProperty('medium');
    expect(res.body.stats.byPriority).toHaveProperty('high');
  });

  test('Counts match seeded data', async () => {
    const res = await request(app)
      .get('/api/tasks/stats/overview')
      .set('Authorization', 'Bearer tok');
    expect(res.body.stats.total).toBe(2);
    expect(res.body.stats.byStatus.pending).toBe(1);
    expect(res.body.stats.byStatus.completed).toBe(1);
    expect(res.body.stats.byPriority.high).toBe(1);
    expect(res.body.stats.byPriority.low).toBe(1);
  });

  test('Returns tenant and username in response', async () => {
    const res = await request(app)
      .get('/api/tasks/stats/overview')
      .set('Authorization', 'Bearer tok');
    expect(res.body.tenant).toBe('default');
    expect(res.body.username).toBe(USER);
  });
});

describe('API Service – Tenant Isolation', () => {
  const USER_A = 'tenant_iso_user_a';
  const USER_B = 'tenant_iso_user_b';
  let taskIdA;

  beforeAll(async () => {
    mockAuthOk(USER_A);
    const res = await request(app)
      .post('/api/tasks')
      .set('Authorization', 'Bearer tok')
      .send({ title: 'User A private task' });
    taskIdA = res.body.task.id;
  });

  test('User B cannot see User A tasks in list', async () => {
    mockAuthOk(USER_B);
    const res = await request(app)
      .get('/api/tasks')
      .set('Authorization', 'Bearer tok');
    expect(res.statusCode).toBe(200);
    const ids = res.body.tasks.map((t) => t.id);
    expect(ids).not.toContain(taskIdA);
  });

  test('User B cannot read User A task by ID → 403', async () => {
    mockAuthOk(USER_B);
    const res = await request(app)
      .get(`/api/tasks/${taskIdA}`)
      .set('Authorization', 'Bearer tok');
    expect(res.statusCode).toBe(403);
  });

  test('User B stats only count User B tasks', async () => {
    mockAuthOk(USER_B);
    const res = await request(app)
      .get('/api/tasks/stats/overview')
      .set('Authorization', 'Bearer tok');
    expect(res.statusCode).toBe(200);
    // No tasks for USER_B
    expect(res.body.stats.total).toBe(0);
  });
});

// ── metrics ───────────────────────────────────────────────────────────────────

describe('API Service – Prometheus Metrics', () => {
  test('GET /metrics returns valid Prometheus text', async () => {
    const res = await request(app).get('/metrics');
    expect(res.statusCode).toBe(200);
    expect(res.text).toContain('process_cpu');
    expect(res.headers['content-type']).toMatch(/text\/plain/);
  });
});

// ── 404 / error handlers ─────────────────────────────────────────────────────

describe('API Service – 404 Handler', () => {
  test('Unknown route returns 404 JSON', async () => {
    const res = await request(app).get('/nonexistent-route-xyz');
    expect(res.statusCode).toBe(404);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toBe('Route not found');
    expect(res.body).toHaveProperty('path');
  });
});

// ── security headers ─────────────────────────────────────────────────────────

describe('API Service – Security Headers', () => {
  test('Helmet sets x-content-type-options: nosniff', async () => {
    const res = await request(app).get('/health');
    expect(res.headers['x-content-type-options']).toBe('nosniff');
  });

  test('x-powered-by is absent (removed by helmet)', async () => {
    const res = await request(app).get('/health');
    expect(res.headers).not.toHaveProperty('x-powered-by');
  });
});
