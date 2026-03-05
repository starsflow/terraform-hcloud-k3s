# Tests

Automated infrastructure test suite using [Terratest](https://terratest.gruntwork.io/). These tests create real Hetzner Cloud resources and cost money.

## Test Cases

| Test | What It Does | Duration |
|---|---|---|
| `TestValidation` | Plan-only input validation (even master count, count limits, private masters without LB). **No infra created.** | ~1 min |
| `TestDevClusterFull` | Deploys a dev cluster, validates outputs, nodes, labels, private workers, system pods, CCM, CSI, pod scheduling, volume provisioning, NAT gateway | ~15 min |
| `TestScaleUpDown` | Deploys, scales workers 1 to 2 then back to 1, verifies node count | ~20 min |
| `TestGracefulDrain` | Deploys with a workload, destroys, verifies drain and node removal in output | ~15 min |
| `TestHACluster` | Deploys 3 private masters + API LB + worker, validates HA, etcd quorum, LB routing, cross-node networking | ~25 min |
| `TestBYOCNI` | Deploys with `disable_builtin_cni=true`, verifies no flannel and nodes are NotReady (proving CNI is needed) | ~10 min |
| `TestMultipleWorkerPools` | Deploys with 2 named worker pools, verifies both exist with correct names | ~15 min |
| `TestEmbeddedRegistry` | Deploys with Spegel enabled, verifies registry config and image pulls work | ~15 min |
| `TestIngressLB` | Deploys with ingress LB enabled, verifies LB IP is returned | ~10 min |

## Running Tests

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

## Cost Considerations

- `TestValidation` is free (plan-only, no resources created)
- All other tests create real Hetzner servers, networks, and load balancers
- Each test cleans up after itself (`defer terraform.Destroy`)
- Run validation tests on every PR; run full infra tests on a schedule (nightly)
