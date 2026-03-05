# Examples

This directory contains ready-to-use example configurations and a test suite for the module.

## Example Configurations

| Directory | Description |
|---|---|
| [dev-cluster](dev-cluster/) | Single master, single worker, no load balancer. Minimal setup for development. |
| [prod-cluster](prod-cluster/) | 3 HA masters (private), API load balancer, workers. Production-ready baseline. |

Each example is a complete root module you can deploy directly.

### Deploying an Example

```bash
cd examples/dev-cluster  # or prod-cluster

# Configure your variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Hetzner token and IP allowlists

tofu init
tofu apply
```

After apply:

```bash
export KUBECONFIG=$(tofu output -raw kubeconfig_path)
kubectl get nodes
```

### Files in Each Example

| File | Purpose |
|---|---|
| `main.tf` | Module call with example configuration |
| `variables.tf` | Input variables (token, CIDRs, overrides) |
| `outputs.tf` | Forwarded module outputs (IPs, kubeconfig, SSH command) |
| `terraform.tfvars.example` | Template for your `terraform.tfvars` |
| `smoke-test.sh` | Post-deploy validation script (see below) |

## Smoke Tests

Each example includes a `smoke-test.sh` script that validates a running cluster. These are **not** automated CI tests -- they're meant to be run manually after a `tofu apply` to verify everything works.

### When to Use

- After your first deploy to confirm the cluster is healthy
- After upgrading k3s or changing node configuration
- When debugging issues -- the script checks each component individually
- As a quick health check before handing off a cluster

### How to Run

```bash
# From the example directory, after a successful tofu apply:
./smoke-test.sh

# Or with an explicit kubeconfig path:
./smoke-test.sh ./kubeconfig
```

### What They Check

**dev-cluster** smoke test:
1. API server reachability
2. All nodes Ready
3. kube-system pods healthy
4. Hetzner CCM running
5. Hetzner CSI running
6. Pod scheduling (creates and deletes an nginx pod)
7. CSI volume provisioning (creates a PVC, mounts it in a pod, cleans up)

**prod-cluster** smoke test (includes everything above, plus):
- HA master count (3+ control-plane nodes)
- etcd quorum (3+ etcd members)
- API endpoint is via load balancer (not localhost)
- Workers are private (no external IP)
- Cross-node pod communication (master-to-worker networking)

### Output

The script prints colored `[PASS]`/`[FAIL]`/`[INFO]` lines for each check and exits with code 0 (all passed) or 1 (any failure).

## Automated Tests (Terratest)

The [`test/`](../test/) directory contains a Go test suite using [Terratest](https://terratest.gruntwork.io/) for automated infrastructure testing. These tests create real Hetzner Cloud resources and cost money.

### Test Cases

| Test | What It Does | Duration |
|---|---|---|
| `TestDevClusterFull` | Deploys a dev cluster, validates outputs, nodes, labels, private workers, system pods, CCM, CSI, pod scheduling, volume provisioning, NAT gateway | ~15 min |
| `TestScaleUpDown` | Deploys, scales workers 1 to 2 then back to 1, verifies node count | ~20 min |
| `TestGracefulDrain` | Deploys with a workload, destroys, verifies drain and node removal in output | ~15 min |
| `TestHACluster` | Deploys 3 private masters + API LB + worker, validates HA, etcd quorum, LB routing, cross-node networking | ~25 min |
| `TestBYOCNI` | Deploys with `disable_builtin_cni=true`, verifies no flannel and nodes are NotReady (proving CNI is needed) | ~10 min |
| `TestMultipleWorkerPools` | Deploys with 2 named worker pools, verifies both exist with correct names | ~15 min |
| `TestEmbeddedRegistry` | Deploys with Spegel enabled, verifies registry config and image pulls work | ~15 min |
| `TestIngressLB` | Deploys with ingress LB enabled, verifies LB IP is returned | ~10 min |
| `TestValidation` | Plan-only tests for input validation (even master count, count limits, private masters without LB). **No infra created.** | ~1 min |

### Running Tests

```bash
cd test

# Validation only (free, fast -- good for CI on every PR)
export TF_VAR_hcloud_token="your-token"
go test -v -timeout 10m -run TestValidation

# Single test
go test -v -timeout 30m -run TestDevClusterFull

# All tests (parallel, uses real infra -- ~70 min, costs money)
go test -v -timeout 180m -p 1 -parallel 1
```

### Cost Considerations

- `TestValidation` is free (plan-only, no resources created)
- All other tests create real Hetzner servers, networks, and load balancers
- Each test cleans up after itself (`defer terraform.Destroy`)
- Run validation tests on every PR; run full infra tests on a schedule (nightly)
