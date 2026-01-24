# Multi-Tenancy in Kubernetes for SaaS Applications

Namespace-Based Isolation, Helm Automation, and Empirical Evaluation

---

## Overview

This repository contains the full implementation and evaluation artifacts of a multi-tenant Software as a Service (SaaS) platform built on Kubernetes using namespace-based isolation.

The project was developed as a Bachelor’s thesis at Centria University of Applied Sciences (2026) and focuses on practical feasibility under severe infrastructure constraints.

The system was implemented, deployed, and evaluated on a single-node Kubernetes cluster (k3s) running on AWS Free Tier infrastructure.

---

## Problem Statement

Kubernetes multi-tenancy is often considered unsafe unless separate clusters or virtual clusters are used.

This project evaluates whether namespace-based isolation can provide acceptable security, performance, and resource fairness for small to medium SaaS platforms operating under tight budget and infrastructure constraints.

---

## Key Contributions

- Fully working multi-tenant SaaS platform
- Namespace-per-tenant isolation model
- Role-Based Access Control (RBAC)
- NetworkPolicy enforcement
- ResourceQuota and LimitRange enforcement
- Helm-based automated tenant provisioning
- JWT-based tenant isolation at application level
- Horizontal Pod Autoscaling (HPA)
- Host-based routing using Kubernetes Ingress

---

## System Architecture

The platform follows a microservice-based architecture composed of three stateless services:

### Authentication Service
- Tenant-scoped user registration and login
- JWT issuance with embedded tenant identifiers
- Tenant-specific signing secrets stored in Kubernetes Secrets

### API Service
- Stateless REST API
- Tenant context enforced via middleware
- Prometheus metrics exposed

### Dashboard Service
- Backend-for-Frontend (BFF) pattern
- Tenant-specific routing and views
- Integrated authentication middleware

Each tenant is deployed into a dedicated Kubernetes namespace containing isolated workloads and policies.

---

## Tenant Isolation Model

Tenant isolation is enforced across multiple independent layers:

- Kubernetes RBAC for control-plane access
- NetworkPolicy for network-level isolation
- ResourceQuota and LimitRange for resource fairness
- Application-level tenant validation using JWT claims

This layered approach reduces the impact of misconfiguration or failure of any single isolation mechanism.

---

## Deployment and Tenant Provisioning

Tenant provisioning is automated using Helm charts and supporting scripts.

Provisioning steps include:
1. Namespace creation
2. RBAC configuration
3. ResourceQuota and LimitRange enforcement
4. NetworkPolicy deployment
5. Application and Ingress deployment

Average tenant onboarding time is approximately 10 minutes.

---

## Performance Evaluation

All performance results are derived from empirical testing.

Test environment:
- Single-node k3s cluster
- AWS EC2 Free Tier (t3.micro)
- Load testing using `hey`

Key observed results:
- API service throughput: ~890 requests per second (P95 latency ~135 ms)
- Authentication service throughput: ~412 requests per second (P95 latency ~279 ms)
- No cross-tenant access observed during isolation testing
- Stable autoscaling behavior under load

---

## Threat Model and Limitations

This system assumes a trusted-tenant threat model.

Known limitations include:
- Shared Kubernetes control plane
- Shared Linux kernel across tenant pods
- Lack of isolation for cluster-scoped resources

This architecture is not suitable for hostile or highly regulated environments.

---

## When This Architecture Makes Sense

- Early-stage SaaS platforms
- Cost-sensitive startups
- Academic and research projects
- Internal multi-team platforms
- Trusted B2B SaaS environments

---

## Future Work

Potential future extensions include:
- Persistent storage integration
- Self-service tenant provisioning portal
- Advanced security hardening (Seccomp, AppArmor, runtime security)
- Higher tenant density testing
- Tenant billing and resource metering
- Service mesh integration

---

## Repository Structure

.
├── charts/
├── services/
├── scripts/
├── manifests/
├── tests/
└── README.md


---

## Academic Reference

Ali Pourrahim (2026)  
Multi-Tenancy in Kubernetes for SaaS Applications  
Centria University of Applied Sciences
