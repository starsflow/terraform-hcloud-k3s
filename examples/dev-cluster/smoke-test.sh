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
echo " K3s Cluster Smoke Test"
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

# 3. System pods
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

# 4. CCM running
info "Checking Hetzner CCM..."
if kubectl get pods -n kube-system -l app=hcloud-cloud-controller-manager --no-headers 2>/dev/null | grep -q "Running"; then
  pass "Hetzner CCM is running"
else
  fail "Hetzner CCM not found or not running"
fi

# 5. CSI running
info "Checking Hetzner CSI..."
CSI_PODS=$(kubectl get pods -n kube-system --no-headers -l app=hcloud-csi 2>/dev/null | grep -c "Running" || true)
if [ "$CSI_PODS" -gt 0 ]; then
  pass "Hetzner CSI is running ($CSI_PODS pods)"
else
  fail "Hetzner CSI not found or not running"
fi
echo

# 6. Schedule a pod
info "Testing pod scheduling..."
kubectl run smoke-test --image=nginx:alpine --restart=Never --overrides='{"spec":{"terminationGracePeriodSeconds":0}}' &>/dev/null || true
if kubectl wait --for=condition=Ready pod/smoke-test --timeout=90s &>/dev/null; then
  pass "Pod scheduled and running"
else
  fail "Pod failed to become Ready"
fi
kubectl delete pod smoke-test --grace-period=0 --force &>/dev/null || true
echo

# 7. CSI volume provisioning (WaitForFirstConsumer requires a Pod to trigger binding)
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

# Summary
echo "============================================"
if [ "$FAILED" -eq 0 ]; then
  echo -e " ${GREEN}All checks passed${NC}"
else
  echo -e " ${RED}Some checks failed${NC}"
fi
echo "============================================"

exit "$FAILED"
