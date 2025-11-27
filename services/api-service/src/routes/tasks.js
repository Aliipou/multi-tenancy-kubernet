const express = require('express');
const router = express.Router();
const { v4: uuidv4 } = require('uuid');
const { Counter, Histogram } = require('prom-client');
const { logger } = require('../utils/logger');

// Metrics
const tasksCreated = new Counter({
  name: 'api_tasks_created_total',
  help: 'Total number of tasks created',
  labelNames: ['tenant']
});

const tasksDeleted = new Counter({
  name: 'api_tasks_deleted_total',
  help: 'Total number of tasks deleted',
  labelNames: ['tenant']
});

const requestDuration = new Histogram({
  name: 'api_request_duration_seconds',
  help: 'Duration of API requests in seconds',
  labelNames: ['method', 'route', 'status_code']
});

// In-memory task store (replace with database in production)
const tasks = new Map();

const TENANT_ID = process.env.TENANT_ID || 'default';

// Request timing middleware
router.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    requestDuration.labels(req.method, req.route?.path || req.path, res.statusCode).observe(duration);
  });
  next();
});

// Validation middleware
const validateTask = (req, res, next) => {
  const { title } = req.body;

  if (!title || title.trim().length === 0) {
    return res.status(400).json({
      success: false,
      message: 'Task title is required'
    });
  }

  if (title.length > 200) {
    return res.status(400).json({
      success: false,
      message: 'Task title must be less than 200 characters'
    });
  }

  next();
};

// Get all tasks for current user
router.get('/', (req, res) => {
  try {
    const userTasks = Array.from(tasks.values())
      .filter(task => task.tenant === TENANT_ID && task.username === req.user.username)
      .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));

    res.json({
      success: true,
      count: userTasks.length,
      tasks: userTasks
    });
  } catch (error) {
    logger.error({
      message: 'Error fetching tasks',
      error: error.message,
      tenant: TENANT_ID,
      username: req.user.username
    });

    res.status(500).json({
      success: false,
      message: 'Failed to fetch tasks'
    });
  }
});

// Get single task
router.get('/:id', (req, res) => {
  try {
    const task = tasks.get(req.params.id);

    if (!task) {
      return res.status(404).json({
        success: false,
        message: 'Task not found'
      });
    }

    // Check ownership
    if (task.tenant !== TENANT_ID || task.username !== req.user.username) {
      return res.status(403).json({
        success: false,
        message: 'Unauthorized access to this task'
      });
    }

    res.json({
      success: true,
      task
    });
  } catch (error) {
    logger.error({
      message: 'Error fetching task',
      error: error.message,
      taskId: req.params.id,
      tenant: TENANT_ID,
      username: req.user.username
    });

    res.status(500).json({
      success: false,
      message: 'Failed to fetch task'
    });
  }
});

// Create task
router.post('/', validateTask, (req, res) => {
  try {
    const { title, description, priority = 'medium' } = req.body;

    const task = {
      id: uuidv4(),
      title: title.trim(),
      description: description?.trim() || '',
      priority,
      status: 'pending',
      tenant: TENANT_ID,
      username: req.user.username,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString()
    };

    tasks.set(task.id, task);
    tasksCreated.inc({ tenant: TENANT_ID });

    logger.info({
      message: 'Task created',
      taskId: task.id,
      tenant: TENANT_ID,
      username: req.user.username
    });

    res.status(201).json({
      success: true,
      message: 'Task created successfully',
      task
    });
  } catch (error) {
    logger.error({
      message: 'Error creating task',
      error: error.message,
      tenant: TENANT_ID,
      username: req.user.username
    });

    res.status(500).json({
      success: false,
      message: 'Failed to create task'
    });
  }
});

// Update task
router.put('/:id', (req, res) => {
  try {
    const task = tasks.get(req.params.id);

    if (!task) {
      return res.status(404).json({
        success: false,
        message: 'Task not found'
      });
    }

    // Check ownership
    if (task.tenant !== TENANT_ID || task.username !== req.user.username) {
      return res.status(403).json({
        success: false,
        message: 'Unauthorized access to this task'
      });
    }

    const { title, description, status, priority } = req.body;

    if (title !== undefined) {
      if (!title.trim()) {
        return res.status(400).json({
          success: false,
          message: 'Task title cannot be empty'
        });
      }
      task.title = title.trim();
    }

    if (description !== undefined) {
      task.description = description.trim();
    }

    if (status !== undefined) {
      if (!['pending', 'in_progress', 'completed', 'cancelled'].includes(status)) {
        return res.status(400).json({
          success: false,
          message: 'Invalid status value'
        });
      }
      task.status = status;
    }

    if (priority !== undefined) {
      if (!['low', 'medium', 'high'].includes(priority)) {
        return res.status(400).json({
          success: false,
          message: 'Invalid priority value'
        });
      }
      task.priority = priority;
    }

    task.updatedAt = new Date().toISOString();
    tasks.set(task.id, task);

    logger.info({
      message: 'Task updated',
      taskId: task.id,
      tenant: TENANT_ID,
      username: req.user.username
    });

    res.json({
      success: true,
      message: 'Task updated successfully',
      task
    });
  } catch (error) {
    logger.error({
      message: 'Error updating task',
      error: error.message,
      taskId: req.params.id,
      tenant: TENANT_ID,
      username: req.user.username
    });

    res.status(500).json({
      success: false,
      message: 'Failed to update task'
    });
  }
});

// Delete task
router.delete('/:id', (req, res) => {
  try {
    const task = tasks.get(req.params.id);

    if (!task) {
      return res.status(404).json({
        success: false,
        message: 'Task not found'
      });
    }

    // Check ownership
    if (task.tenant !== TENANT_ID || task.username !== req.user.username) {
      return res.status(403).json({
        success: false,
        message: 'Unauthorized access to this task'
      });
    }

    tasks.delete(req.params.id);
    tasksDeleted.inc({ tenant: TENANT_ID });

    logger.info({
      message: 'Task deleted',
      taskId: req.params.id,
      tenant: TENANT_ID,
      username: req.user.username
    });

    res.json({
      success: true,
      message: 'Task deleted successfully'
    });
  } catch (error) {
    logger.error({
      message: 'Error deleting task',
      error: error.message,
      taskId: req.params.id,
      tenant: TENANT_ID,
      username: req.user.username
    });

    res.status(500).json({
      success: false,
      message: 'Failed to delete task'
    });
  }
});

// Get task statistics
router.get('/stats/overview', (req, res) => {
  try {
    const userTasks = Array.from(tasks.values())
      .filter(task => task.tenant === TENANT_ID && task.username === req.user.username);

    const stats = {
      total: userTasks.length,
      byStatus: {
        pending: userTasks.filter(t => t.status === 'pending').length,
        in_progress: userTasks.filter(t => t.status === 'in_progress').length,
        completed: userTasks.filter(t => t.status === 'completed').length,
        cancelled: userTasks.filter(t => t.status === 'cancelled').length
      },
      byPriority: {
        low: userTasks.filter(t => t.priority === 'low').length,
        medium: userTasks.filter(t => t.priority === 'medium').length,
        high: userTasks.filter(t => t.priority === 'high').length
      }
    };

    res.json({
      success: true,
      tenant: TENANT_ID,
      username: req.user.username,
      stats
    });
  } catch (error) {
    logger.error({
      message: 'Error fetching statistics',
      error: error.message,
      tenant: TENANT_ID,
      username: req.user.username
    });

    res.status(500).json({
      success: false,
      message: 'Failed to fetch statistics'
    });
  }
});

module.exports = router;
