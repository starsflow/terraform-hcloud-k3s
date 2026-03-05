# Comparison with Other k3s Hetzner Projects

There are several projects for running k3s on Hetzner Cloud. They differ significantly in scope, philosophy, and complexity.

## Overview

| | **terraform-hcloud-k3s** | **kube-hetzner** | **hetzner-k3s** | **identiops/k3s** |
|---|---|---|---|---|
| **Type** | Terraform module | Terraform module | CLI tool (Crystal) | Terraform module |
| **GitHub** | [starsflow](https://github.com/starsflow/terraform-hcloud-k3s) | [kube-hetzner](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner) | [vitobotta](https://github.com/vitobotta/hetzner-k3s) | [identiops](https://github.com/identiops/terraform-hcloud-k3s) |
| **Stars** | New | ~3,700 | ~3,300 | ~148 |
| **Philosophy** | Infrastructure only | All-in-one platform | CLI-driven simplicity | Security-first, gateway node |
| **OS** | Ubuntu 24.04 | openSUSE MicroOS | Ubuntu 24.04 | Ubuntu 24.04 |
| **Variables** | ~35 | ~128 | YAML config | ~30-40 |

## Feature Comparison

| Feature | **terraform-hcloud-k3s** | **kube-hetzner** | **hetzner-k3s** | **identiops/k3s** |
|---|---|---|---|---|
| HA control plane | Yes | Yes | Yes | Yes |
| Private workers | Yes (default) | Yes | No | Yes (default) |
| Private masters | Yes (opt-in) | Yes | No | Yes (gateway node) |
| API load balancer | Yes (opt-in) | Yes | No | No (gateway proxy) |
| Ingress LB | Yes (pre-created for CCM) | Yes (auto-configured) | No | No |
| Firewall | Yes (explicit CIDRs) | Yes | No | Yes |
| Deletion protection | Yes (opt-in) | No | No | Yes (default) |
| Placement groups | Yes | Yes | No | Yes |
| Graceful drain | Yes (on destroy) | Yes | Yes | Yes |
| Embedded registry (Spegel) | Yes (opt-in) | No | No | Yes |
| BYO CNI | Yes (`disable_builtin_cni`) | Built-in (Flannel/Calico/Cilium) | Flannel or Cilium | Cilium only |
| Ingress controller | None (BYO) | Traefik/Nginx/HAProxy | Traefik (optional) | None (BYO) |
| Cluster autoscaler | None (BYO) | Built-in | Built-in | Planned |
| Auto OS upgrades | None (BYO) | Yes (MicroOS transactional) | Via SUC | Yes (kured) |
| Auto k3s upgrades | None (BYO) | Yes (SUC) | Yes (SUC) | Yes (SUC) |
| Packer required | No | Yes (MicroOS snapshots) | No | No |
| Multi-arch (ARM) | No | Yes | Yes | No |
| WireGuard encryption | No | Yes (opt-in) | No | No |
| etcd S3 backups | No | Yes | No | Yes |
| OpenTofu compatible | Yes | Yes | N/A | Yes |

## When to Use What

### terraform-hcloud-k3s (this module)

- You want a clean infrastructure layer and manage the platform yourself (Helm, ArgoCD, Flux)
- You already have opinions about CNI, ingress, and GitOps tooling
- You value simplicity and composability over batteries-included
- You use Atmos, Terragrunt, or similar Terraform orchestrators

### kube-hetzner

- You want a fully managed platform from a single `tofu apply`
- You're OK with MicroOS, Packer, and ~128 variables
- You want built-in autoscaling, auto-upgrades, and ingress out of the box
- You don't plan to layer your own platform tooling on top

### hetzner-k3s (CLI)

- You don't use Terraform and want a single binary that creates clusters
- Speed is the priority (3-node HA in 2-3 minutes)
- You don't need IaC composability with other infrastructure

### identiops/k3s

- Security-first architecture with a dedicated gateway node (no public IPs on any cluster node)
- You want a clean Terraform module with security defaults enabled out of the box
- You're OK with Cilium as the only CNI option

## Key Differentiator

This module draws a clear boundary: **infrastructure stops at k3s**. Other modules bundle CNI selection, ingress controllers, storage backends, autoscalers, and upgrade controllers into the same Terraform state. That coupling means upgrading ArgoCD requires re-running Terraform, swapping CNIs means modifying the cluster module, and a bad Helm release can block infrastructure changes.

By keeping the module thin, each concern has its own lifecycle. Your CNI upgrades independently of your node count. Your GitOps tool deploys without touching Terraform. Your ingress controller is a Helm chart, not a Terraform variable.
