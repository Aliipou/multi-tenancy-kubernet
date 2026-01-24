# Multi-Tenancy in Kubernetes for SaaS Applications
**Namespace-Based Isolation, Helm Automation, and Empirical Evaluation**

## Table of Contents
1. [Overview](#overview)
2. [Problem Statement](#problem-statement)
3. [Core Contributions](#core-contributions)
4. [Architecture](#architecture)
5. [Tenant Isolation Model](#tenant-isolation-model)
6. [Deployment & Tenant Provisioning](#deployment--tenant-provisioning)
7. [Performance & Evaluation](#performance--evaluation)
8. [Threat Model & Limitations](#threat-model--limitations)
9. [When This Architecture Makes Sense](#when-this-architecture-makes-sense)
10. [Future Work](#future-work)
11. [Repository Structure](#repository-structure)
12. [Academic Reference](#academic-reference)

---

## Overview
This repository contains the **full implementation and evaluation artifacts** of a multi-tenant Software as a Service (SaaS) platform built on Kubernetes using **namespace-based isolation**.

The project was developed as a **Bachelor’s thesis at Centria University of Applied Sciences (January 2026)** and focuses on **practical feasibility under resource constraints**, not theoretical idealism.

The system was implemented, deployed, and empirically evaluated on a **single-node Kubernetes cluster (k3s) running on AWS Free Tier infrastructure**.

---

## Problem Statement
Kubernetes multi-tenancy is often dismissed as unsafe unless **separate clusters or virtual clusters** are used.

This project challenges that assumption by asking:

> Can namespace-based isolation provide sufficient security, performance, and fairness for small to medium SaaS platforms operating under tight resource and budget constraints?

---

## Core Contributions
This repository provides:

- A fully functional **multi-tenant SaaS platform**
- Automated tenant provisioning using **Helm**
- Defense-in-depth isolation using native Kubernetes primitives
- Empirical performance, autoscaling, and isolation evaluation

Key features include:
- Namespace-per-tenant isolation
- Role-Based Access Control (RBAC)
- NetworkPolicy (default-deny, explicit allow rules)
- ResourceQuota and LimitRange enforcement
- Application-level tenant isolation using JWT claims
- Horizontal Pod Autoscaling (HPA)
- Host-based routing via Kubernetes Ingress

---

## Architecture
The platform follows a **microservice architecture** composed of three stateless services:

### Authentication Service
- Tenant-scoped user registration and login
- JWT issuance with embedded tenant identifiers
- Per-tenant signing secrets stored in Kubernetes Secrets

### API Service
- Stateless REST API
- Tenant context enforced via middleware
- Prometheus metrics exposed for observability

### Dashboard Service
- Backend-for-Frontend (BFF) pattern
- Tenant-specific views and routing
- Integrated authentication middleware

Each tenant is deployed into an isolated Kubernetes **namespace** containing its own deployments, services, quotas, and policies.

---

## Tenant Isolation Model
Tenant isolation is enforced across **four independent layers**:

| Layer | Mechanism |
|-----|----------|
| Control Plane | Kubernetes RBAC |
| Network | NetworkPolicy |
| Resources | ResourceQuota & LimitRange |
| Application | JWT tenant claim validation |

This layered approach ensures that failure of a single mechanism does not result in cross-tenant access.

---

## Deployment & Tenant Provisioning
Tenant provisioning is fully automated using **Helm charts** and supporting scripts.

Provisioning steps include:
1. Namespace creation
2. RBAC role and binding configuration
3. ResourceQuota and LimitRange enforcement
4. NetworkPolicy deployment
5. Service, Deployment, and Ingress creation

**Average tenant onboarding time:** ~10 minutes  
(previously 25+ minutes using manual provisioning)

---

## Performance & Evaluation
All results are derived from **controlled empirical testing**, not assumptions.

**Test Environment**
- Single-node k3s cluster
- AWS EC2 Free Tier (t3.micro)
- Load testing with `hey`

**Key Results**

| Service | Throughput | P95 Latency |
|------|-----------|-------------|
| API Service | 891 req/s | 135 ms |
| Authentication Service | 412 req/s | 279 ms |

Additional observations:
- HPA successfully scaled replicas under CPU pressure
- No cross-tenant network or API access was observed
- 100% service availability during the evaluation window

---

## Threat Model & Limitations
This system assumes a **trusted-tenant threat model**:
- Tenants are not actively malicious
- Failures may occur due to misconfiguration or excessive load

Known limitations:
- Shared Kubernetes control plane
- Shared Linux kernel between tenant pods
- Cluster-scoped resources are not isolated

This architecture is **not suitable** for hostile multi-tenant environments or highly regulated industries.

---

## When This Architecture Makes Sense
This approach is well-suited for:
- Early-stage SaaS platforms
- Cost-sensitive startups
- Academic and research projects
- Internal multi-team platforms
- Trusted B2B SaaS environments

---

## Future Work
Planned extensions include:
- Persistent storage integration
- Self-service tenant provisioning portal
- Advanced kernel-level security (Seccomp, AppArmor)
- Runtime security monitoring (Falco)
- Higher tenant density testing
- Tenant billing and resource metering
- Service mesh integration

---

## Repository Structure
