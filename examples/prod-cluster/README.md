# Prod Cluster Example

3 HA masters (private), API load balancer, workers. Production-ready baseline.

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

- 3 master nodes (cx23, private joining masters, master-00 public as bastion)
- 1 worker node (cx23, private, NAT via master-00)
- API load balancer (lb11) for HA kubectl access
- Private network + subnet + NAT gateway route
- Base firewall (SSH, K8s API) + ingress firewall (HTTP, HTTPS)
- Hetzner CCM + CSI
- Kubeconfig written locally (API endpoint via LB)

## Smoke test

After deploy, validate the cluster:

```bash
./smoke-test.sh
```

Checks everything the dev smoke test does, plus: HA master count, etcd quorum, API via load balancer, worker private networking, and cross-node pod communication.

## Files

| File | Purpose |
|---|---|
| `main.tf` | Module call with prod configuration |
| `variables.tf` | Input variables (token, CIDRs) |
| `outputs.tf` | Forwarded module outputs |
| `terraform.tfvars.example` | Template for your `terraform.tfvars` |
| `smoke-test.sh` | Post-deploy validation script |
