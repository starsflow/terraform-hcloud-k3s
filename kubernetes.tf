## ──────────────────────────────────────────────
## API endpoint (computed after servers exist)
## ──────────────────────────────────────────────
locals {
  api_endpoint = var.enable_api_lb ? hcloud_load_balancer.api[0].ipv4 : hcloud_server.master_init.ipv4_address
}

## ──────────────────────────────────────────────
## Fetch kubeconfig from master-00
## ──────────────────────────────────────────────
resource "null_resource" "fetch_kubeconfig" {
  depends_on = [hcloud_server.master_init]

  triggers = {
    master_id = hcloud_server.master_init.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      SSH_KEY="${local_sensitive_file.ssh_private_key.filename}"
      HOST="${hcloud_server.master_init.ipv4_address}"
      PORT="${var.ssh_port}"
      KNOWN_HOSTS="/tmp/.known_hosts-${var.cluster_name}"

      echo "Collecting host key from master..."
      for i in $(seq 1 30); do
        if ssh-keyscan -p "$PORT" "$HOST" > "$KNOWN_HOSTS" 2>/dev/null && [ -s "$KNOWN_HOSTS" ]; then
          echo "Host key captured."
          break
        fi
        if [ "$i" -eq 30 ]; then
          echo "ERROR: Timed out waiting for host key after 30 attempts."
          exit 1
        fi
        echo "Attempt $i/30 - waiting 10s..."
        sleep 10
      done

      SSH_OPTS="-o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o UserKnownHostsFile=$KNOWN_HOSTS"

      echo "Waiting for k3s API and kubeconfig on master..."
      for i in $(seq 1 60); do
        if scp $SSH_OPTS -i "$SSH_KEY" -P "$PORT" \
          "root@$HOST":/etc/rancher/k3s/k3s.yaml "${var.kubeconfig_path}.tmp" 2>/dev/null; then
          echo "Kubeconfig fetched successfully."
          break
        fi
        if [ "$i" -eq 60 ]; then
          echo "ERROR: Timed out waiting for kubeconfig after 60 attempts."
          exit 1
        fi
        echo "Attempt $i/60 - waiting 10s..."
        sleep 10
      done

      sed 's|https://127.0.0.1:6443|https://${local.api_endpoint}:6443|g' \
        "${var.kubeconfig_path}.tmp" > "${var.kubeconfig_path}"
      rm -f "${var.kubeconfig_path}.tmp"
      chmod 600 "${var.kubeconfig_path}"
      echo "Kubeconfig written to ${var.kubeconfig_path}"
    EOT
  }
}

## ──────────────────────────────────────────────
## Store kubeconfig content in state (for CI/CD)
## ──────────────────────────────────────────────
data "external" "kubeconfig_content" {
  depends_on = [null_resource.fetch_kubeconfig]

  program = [
    "bash", "-c",
    "jq -Rs '{content: .}' < '${var.kubeconfig_path}'"
  ]
}

## ──────────────────────────────────────────────
## Hetzner Cloud secret for CCM/CSI
## ──────────────────────────────────────────────
resource "local_sensitive_file" "hcloud_secret_manifest" {
  count = (var.install_ccm || var.install_csi) ? 1 : 0
  content = templatefile("${path.module}/templates/hcloud-secret.yaml.tftpl", {
    hcloud_token = var.hcloud_token
    network_name = hcloud_network.cluster.name
  })
  filename        = "/tmp/.hcloud-secret-${var.cluster_name}.yaml"
  file_permission = "0600"
}

resource "null_resource" "hcloud_secret" {
  count      = (var.install_ccm || var.install_csi) ? 1 : 0
  depends_on = [null_resource.fetch_kubeconfig]

  triggers = {
    master_id     = hcloud_server.master_init.id
    manifest_hash = local_sensitive_file.hcloud_secret_manifest[0].id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --kubeconfig="${var.kubeconfig_path}" apply -f "${local_sensitive_file.hcloud_secret_manifest[0].filename}"
      rm -f "${local_sensitive_file.hcloud_secret_manifest[0].filename}"
    EOT
  }
}

## ──────────────────────────────────────────────
## Cloud Controller Manager
## ──────────────────────────────────────────────
resource "null_resource" "ccm" {
  count      = var.install_ccm ? 1 : 0
  depends_on = [null_resource.hcloud_secret]

  triggers = {
    ccm_version = var.ccm_version
    master_id   = hcloud_server.master_init.id
    secret_id   = null_resource.hcloud_secret[0].id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --kubeconfig="${var.kubeconfig_path}" apply -f \
        "https://github.com/hetznercloud/hcloud-cloud-controller-manager/releases/download/${var.ccm_version}/ccm-networks.yaml"
    EOT
  }
}

## ──────────────────────────────────────────────
## CSI Driver
## ──────────────────────────────────────────────
resource "null_resource" "csi" {
  count      = var.install_csi ? 1 : 0
  depends_on = [null_resource.hcloud_secret]

  triggers = {
    csi_version = var.csi_version
    master_id   = hcloud_server.master_init.id
    secret_id   = null_resource.hcloud_secret[0].id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl --kubeconfig="${var.kubeconfig_path}" apply -f \
        "https://raw.githubusercontent.com/hetznercloud/csi-driver/${var.csi_version}/deploy/kubernetes/hcloud-csi.yml"
    EOT
  }
}
