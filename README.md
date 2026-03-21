<div align="center">

[![Kubernetes](https://img.shields.io/badge/Kubernetes-k3s-326CE5?style=flat&amp;logo=kubernetes)](https://k3s.io)
[![Helm](https://img.shields.io/badge/Helm-3.x-0F1689?style=flat&amp;logo=helm)](https://helm.sh)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat)](LICENSE)

# Multi-Tenancy in Kubernetes

**Namespace-based tenant isolation, RBAC, and Helm automation for SaaS on k3s.**

*Bachelor's thesis — Centria University of Applied Sciences, 2026*

</div>

## Overview

This repository contains the full implementation and empirical evaluation of a multi-tenant SaaS platform built on Kubernetes. The system uses namespace-based isolation to give each tenant a dedicated execution environment while sharing the underlying infrastructure.

Developed and validated on a single-node k3s cluster under realistic resource constraints, demonstrating that multi-tenancy is achievable without enterprise-grade hardware.

## Architecture

```
Kubernetes Cluster (k3s)
         |
   ______|_______
  |      |       |
[tenant-a] [tenant-b] [tenant-c]    Isolated namespaces
     |
  [RBAC]          Each tenant has its own ServiceAccount,
  [Quotas]        ResourceQuota, NetworkPolicy, and LimitRange
  [Network Policy]
```

## What Is Implemented

**Namespace Isolation**
Each tenant gets a dedicated namespace. Resources are invisible across namespace boundaries.

**RBAC**
Per-tenant ServiceAccounts with minimal permissions. Cluster-admin privileges are never granted to tenant workloads.

**Resource Quotas**
CPU, memory, and storage limits enforced at the namespace level. One tenant cannot starve another.

**Helm Automation**
Tenant provisioning is automated via a Helm chart. Onboarding a new tenant is a single `helm install` command.

**Network Policies**
Ingress and egress rules prevent inter-tenant traffic at the network layer.

## Quick Start

```bash
# Provision a new tenant
helm install tenant-demo ./charts/tenant \
  --set tenant.name=demo \
  --set tenant.cpu_limit=2 \
  --set tenant.memory_limit=4Gi

# Verify isolation
kubectl get all -n tenant-demo
```

## Research Findings

The thesis evaluates the system against three dimensions: isolation effectiveness, resource overhead, and operational complexity. Full findings in `docs/thesis.pdf`.

## License

MIT
