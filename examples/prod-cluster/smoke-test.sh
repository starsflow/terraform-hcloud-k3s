#!/bin/bash
set -euo pipefail

KUBECONFIG="${1:-./kubeconfig}"
export KUBECONFIG

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAILED=1; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

FAILED=0

echo "============================================"
echo " K3s Prod Cluster Smoke Test"
echo " Kubeconfig: $KUBECONFIG"
echo "============================================"
echo

# 1. API reachable
info "Checking API connectivity..."
if kubectl cluster-info &>/dev/null; then
  pass "API server is reachable"
else
  fail "Cannot reach API server"
  exit 1
fi

# 2. Nodes ready
info "Checking nodes..."
kubectl get nodes -o wide
echo
NOT_READY=$(kubectl get nodes --no-headers | grep -cv "Ready" || true)
TOTAL=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
if [ "$NOT_READY" -eq 0 ]; then
  pass "All $TOTAL nodes are Ready"
else
  fail "$NOT_READY of $TOTAL nodes are NotReady"
fi
echo

# 3. HA: multiple masters (k3s uses control-plane label, not master)
info "Checking HA master count..."
MASTERS=$(kubectl get nodes --no-headers -l node-role.kubernetes.io/control-plane 2>/dev/null | wc -l | tr -d ' ')
if [ "$MASTERS" -ge 3 ]; then
  pass "HA: $MASTERS control-plane nodes"
elif [ "$MASTERS" -ge 2 ]; then
  info "Partial HA: only $MASTERS control-plane nodes (3+ recommended)"
else
  fail "No HA: only $MASTERS control-plane node"
fi

# 4. HA: etcd health
info "Checking etcd members..."
ETCD_NODES=$(kubectl get nodes --no-headers -l node-role.kubernetes.io/etcd 2>/dev/null | wc -l | tr -d ' ')
if [ "$ETCD_NODES" -ge 3 ]; then
  pass "etcd quorum: $ETCD_NODES members"
else
  fail "etcd has only $ETCD_NODES members (need 3+ for quorum)"
fi
echo

# 5. API via load balancer
info "Checking API endpoint..."
API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "  Endpoint: $API_SERVER"
if echo "$API_SERVER" | grep -qv "127.0.0.1"; then
  pass "API endpoint is not localhost (LB or public IP)"
else
  fail "API endpoint points to 127.0.0.1"
fi
echo

# 6. Private networking: workers have no external IP
info "Checking worker private networking..."
WORKERS_WITH_EXTERNAL=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="ExternalIP")].address}{"\n"}{end}' 2>/dev/null \
  | awk '$2 != ""' | wc -l | tr -d ' ')
WORKER_COUNT=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' 2>/dev/null | wc -l | tr -d ' ')
if [ "$WORKERS_WITH_EXTERNAL" -eq 0 ] && [ "$WORKER_COUNT" -gt 0 ]; then
  pass "All $WORKER_COUNT workers are private (no external IP)"
elif [ "$WORKER_COUNT" -eq 0 ]; then
  fail "No worker nodes found"
else
  info "$WORKERS_WITH_EXTERNAL of $WORKER_COUNT workers have external IPs"
fi
echo

# 7. System pods (wait briefly for recently joined nodes to stabilize)
info "Waiting for system pods to settle..."
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=120s &>/dev/null || true
info "Checking kube-system pods..."
kubectl get pods -n kube-system
echo
FAILING=$(kubectl get pods -n kube-system --no-headers | grep -cvE "Running|Completed" || true)
if [ "$FAILING" -eq 0 ]; then
  pass "All kube-system pods are healthy"
else
  fail "$FAILING kube-system pods are not Running/Completed"
fi
echo

# 8. CCM running
info "Checking Hetzner CCM..."
if kubectl get pods -n kube-system -l app=hcloud-cloud-controller-manager --no-headers 2>/dev/null | grep -q "Running"; then
  pass "Hetzner CCM is running"
else
  fail "Hetzner CCM not found or not running"
fi

# 9. CSI running
info "Checking Hetzner CSI..."
CSI_PODS=$(kubectl get pods -n kube-system --no-headers -l app=hcloud-csi 2>/dev/null | grep -c "Running" || true)
if [ "$CSI_PODS" -gt 0 ]; then
  pass "Hetzner CSI is running ($CSI_PODS pods)"
else
  fail "Hetzner CSI not found or not running"
fi
echo

# 10. Schedule a pod
info "Testing pod scheduling..."
kubectl run smoke-test --image=nginx:alpine --restart=Never --overrides='{"spec":{"terminationGracePeriodSeconds":0}}' &>/dev/null || true
if kubectl wait --for=condition=Ready pod/smoke-test --timeout=90s &>/dev/null; then
  pass "Pod scheduled and running"
else
  fail "Pod failed to become Ready"
fi
kubectl delete pod smoke-test --grace-period=0 --force &>/dev/null || true
echo

# 11. CSI volume provisioning (WaitForFirstConsumer requires a Pod to trigger binding)
info "Testing CSI volume provisioning..."
kubectl apply -f - <<'EOF' &>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke-test-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: hcloud-volumes
---
apiVersion: v1
kind: Pod
metadata:
  name: smoke-test-vol
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: busybox
      image: busybox:stable
      command: ["sleep", "30"]
      volumeMounts:
        - mountPath: /data
          name: vol
  volumes:
    - name: vol
      persistentVolumeClaim:
        claimName: smoke-test-pvc
EOF
if kubectl wait --for=condition=Ready pod/smoke-test-vol --timeout=120s &>/dev/null; then
  pass "CSI volume provisioned, bound, and mounted"
else
  fail "CSI volume pod failed to become Ready"
fi
kubectl delete pod smoke-test-vol --grace-period=0 --force &>/dev/null || true
kubectl delete pvc smoke-test-pvc &>/dev/null || true
echo

# 12. Cross-node networking
info "Testing cross-node pod communication..."
kubectl create namespace smoke-test-net &>/dev/null || true
# Server pod pinned to a master
kubectl apply -n smoke-test-net -f - <<'EOF' &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: net-server
  labels:
    app: net-server
spec:
  terminationGracePeriodSeconds: 0
  nodeSelector:
    node-role.kubernetes.io/control-plane: "true"
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  containers:
    - name: server
      image: busybox:stable
      command: ["sh", "-c", "echo ok | nc -l -p 8080"]
EOF
kubectl wait -n smoke-test-net --for=condition=Ready pod/net-server --timeout=60s &>/dev/null || true
SERVER_IP=$(kubectl get pod -n smoke-test-net net-server -o jsonpath='{.status.podIP}' 2>/dev/null)

if [ -n "$SERVER_IP" ]; then
  # Client pod on a worker
  kubectl apply -n smoke-test-net -f - <<EOF &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: net-client
spec:
  terminationGracePeriodSeconds: 0
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
  containers:
    - name: client
      image: busybox:stable
      command: ["sh", "-c", "nc -w 5 $SERVER_IP 8080"]
EOF
  if kubectl wait -n smoke-test-net --for=condition=Ready pod/net-client --timeout=60s &>/dev/null; then
    # Give it a moment to complete
    sleep 3
    EXIT_CODE=$(kubectl get pod -n smoke-test-net net-client -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "unknown")
    if [ "$EXIT_CODE" = "0" ]; then
      pass "Cross-node pod networking works (master <-> worker)"
    else
      fail "Cross-node networking failed (exit code: $EXIT_CODE)"
    fi
  else
    fail "Network client pod failed to start"
  fi
else
  fail "Could not get server pod IP"
fi
kubectl delete namespace smoke-test-net --grace-period=0 --force &>/dev/null || true
echo

# Summary
echo "============================================"
if [ "$FAILED" -eq 0 ]; then
  echo -e " ${GREEN}All checks passed${NC}"
else
  echo -e " ${RED}Some checks failed${NC}"
fi
echo "============================================"

exit "$FAILED"
