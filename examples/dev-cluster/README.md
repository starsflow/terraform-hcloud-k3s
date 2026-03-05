# Dev Cluster Example

Single master, single worker, no load balancer. Minimal setup for development and testing.

## Usage

```bash
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

## What it creates

- 1 master node (cx23, public IP, bastion)
- 1 worker node (cx23, private, NAT via master)
- Private network + subnet
- Base firewall (SSH, K8s API) + ingress firewall (HTTP, HTTPS)
- Hetzner CCM + CSI
- Kubeconfig written locally

## Smoke test

After deploy, validate the cluster:

```bash
./smoke-test.sh
```

Checks API connectivity, node readiness, system pods, CCM, CSI, pod scheduling, and volume provisioning.

## Files

| File | Purpose |
|---|---|
| `main.tf` | Module call with dev configuration |
| `variables.tf` | Input variables (token, CIDRs, overrides) |
| `outputs.tf` | Forwarded module outputs |
| `terraform.tfvars.example` | Template for your `terraform.tfvars` |
| `smoke-test.sh` | Post-deploy validation script |
