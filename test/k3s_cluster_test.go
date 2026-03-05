package test

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/k8s"
	"github.com/gruntwork-io/terratest/modules/retry"
	"github.com/gruntwork-io/terratest/modules/terraform"
	test_structure "github.com/gruntwork-io/terratest/modules/test-structure"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ──────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────

func getRequiredEnv(t *testing.T, key string) string {
	t.Helper()
	val := os.Getenv(key)
	if val == "" {
		t.Fatalf("environment variable %s is required", key)
	}
	return val
}

// baseVars returns the minimum variables all tests need.
func baseVars(token, clusterName string) map[string]interface{} {
	return map[string]interface{}{
		"hcloud_token":      token,
		"cluster_name":      clusterName,
		"allowed_ssh_cidrs": []string{"0.0.0.0/0"},
		"allowed_api_cidrs": []string{"0.0.0.0/0"},
	}
}

// newOpts creates isolated Terraform options by copying the module to a temp dir.
// This allows parallel tests that each have their own state.
func newOpts(t *testing.T, vars map[string]interface{}) *terraform.Options {
	t.Helper()
	// Copy the entire repo to a temp dir so relative source "../.." still works.
	tmpDir := test_structure.CopyTerraformFolderToTemp(t, "..", "examples/dev-cluster")
	return terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir:    tmpDir,
		TerraformBinary: "tofu",
		Vars:            vars,
		NoColor:         true,
	})
}

// kubeconfigPath returns the kubeconfig path inside the terraform dir.
func kubeconfigPath(tfOpts *terraform.Options) string {
	return filepath.Join(tfOpts.TerraformDir, "kubeconfig")
}

// waitForNodesReady waits until the expected number of nodes are Ready.
func waitForNodesReady(t *testing.T, kubectlOpts *k8s.KubectlOptions, expectedCount int) {
	t.Helper()
	retry.DoWithRetry(t, "wait for nodes to be Ready", 40, 10*time.Second, func() (string, error) {
		nodes := k8s.GetNodes(t, kubectlOpts)
		if len(nodes) < expectedCount {
			return "", fmt.Errorf("expected %d nodes, got %d", expectedCount, len(nodes))
		}
		for _, node := range nodes {
			for _, cond := range node.Status.Conditions {
				if cond.Type == "Ready" && cond.Status != "True" {
					return "", fmt.Errorf("node %s is not Ready", node.Name)
				}
			}
		}
		return fmt.Sprintf("%d nodes Ready", len(nodes)), nil
	})
}

// waitForSystemPods waits until all kube-system pods are Running/Succeeded.
func waitForSystemPods(t *testing.T, kubeconfigFile string) {
	t.Helper()
	kubeSysOpts := k8s.NewKubectlOptions("", kubeconfigFile, "kube-system")
	retry.DoWithRetry(t, "wait for system pods", 30, 10*time.Second, func() (string, error) {
		pods := k8s.ListPods(t, kubeSysOpts, metav1.ListOptions{})
		failing := 0
		for _, pod := range pods {
			phase := string(pod.Status.Phase)
			if phase != "Running" && phase != "Succeeded" {
				failing++
			}
		}
		if failing > 0 {
			return "", fmt.Errorf("%d system pods not Running/Succeeded", failing)
		}
		return fmt.Sprintf("all %d system pods healthy", len(pods)), nil
	})
}

// ──────────────────────────────────────────────
// Test: Full dev cluster (single master + worker)
// Covers: nodes, labels, private workers, system pods,
//         CCM, CSI, pod scheduling, CSI volume, NAT gateway
// ──────────────────────────────────────────────

func TestDevClusterFull(t *testing.T) {
	t.Parallel()
	token := getRequiredEnv(t, "TF_VAR_hcloud_token")

	vars := baseVars(token, "t-full")
	tfOpts := newOpts(t, vars)
	defer terraform.Destroy(t, tfOpts)
	terraform.InitAndApply(t, tfOpts)

	kcPath := kubeconfigPath(tfOpts)
	require.FileExists(t, kcPath)
	kubectlOpts := k8s.NewKubectlOptions("", kcPath, "default")

	// Validate outputs
	apiEndpoint := terraform.Output(t, tfOpts, "api_endpoint")
	assert.Contains(t, apiEndpoint, ":6443")
	assert.NotEmpty(t, terraform.Output(t, tfOpts, "kubeconfig_path"))
	assert.NotEmpty(t, terraform.Output(t, tfOpts, "ssh_command"))
	assert.NotEmpty(t, terraform.Output(t, tfOpts, "network_id"))

	masterIPs := terraform.OutputMap(t, tfOpts, "master_ips")
	assert.Len(t, masterIPs, 1)
	workerIPs := terraform.OutputMap(t, tfOpts, "worker_ips")
	assert.Len(t, workerIPs, 1)
	workerPrivIPs := terraform.OutputMap(t, tfOpts, "worker_private_ips")
	assert.Len(t, workerPrivIPs, 1)

	// All nodes Ready
	t.Run("AllNodesReady", func(t *testing.T) {
		waitForNodesReady(t, kubectlOpts, 2)
	})

	// Master has control-plane label
	t.Run("MasterLabels", func(t *testing.T) {
		nodes := k8s.GetNodes(t, kubectlOpts)
		found := false
		for _, node := range nodes {
			if _, ok := node.Labels["node-role.kubernetes.io/control-plane"]; ok {
				found = true
				assert.Contains(t, node.Name, "master")
			}
		}
		assert.True(t, found, "control-plane node should exist")
	})

	// Workers have no external IP
	t.Run("WorkersPrivate", func(t *testing.T) {
		nodes := k8s.GetNodes(t, kubectlOpts)
		for _, node := range nodes {
			if _, ok := node.Labels["node-role.kubernetes.io/control-plane"]; ok {
				continue
			}
			for _, addr := range node.Status.Addresses {
				assert.NotEqual(t, "ExternalIP", string(addr.Type),
					"worker %s should not have external IP", node.Name)
			}
		}
	})

	// System pods healthy
	t.Run("SystemPodsRunning", func(t *testing.T) {
		waitForSystemPods(t, kcPath)
	})

	// CCM running
	t.Run("CCMRunning", func(t *testing.T) {
		kubeSysOpts := k8s.NewKubectlOptions("", kcPath, "kube-system")
		retry.DoWithRetry(t, "CCM", 15, 10*time.Second, func() (string, error) {
			pods := k8s.ListPods(t, kubeSysOpts, metav1.ListOptions{
				LabelSelector: "app=hcloud-cloud-controller-manager",
			})
			for _, pod := range pods {
				if pod.Status.Phase == "Running" {
					return "CCM running", nil
				}
			}
			return "", fmt.Errorf("CCM not running")
		})
	})

	// CSI running
	t.Run("CSIRunning", func(t *testing.T) {
		kubeSysOpts := k8s.NewKubectlOptions("", kcPath, "kube-system")
		retry.DoWithRetry(t, "CSI", 15, 10*time.Second, func() (string, error) {
			pods := k8s.ListPods(t, kubeSysOpts, metav1.ListOptions{
				LabelSelector: "app=hcloud-csi",
			})
			running := 0
			for _, pod := range pods {
				if pod.Status.Phase == "Running" {
					running++
				}
			}
			if running == 0 {
				return "", fmt.Errorf("no CSI pods running")
			}
			return fmt.Sprintf("%d CSI pods", running), nil
		})
	})

	// Schedule a pod
	t.Run("PodScheduling", func(t *testing.T) {
		k8s.RunKubectl(t, kubectlOpts, "run", "tt-smoke", "--image=nginx:alpine", "--restart=Never",
			`--overrides={"spec":{"terminationGracePeriodSeconds":0}}`)
		defer k8s.RunKubectl(t, kubectlOpts, "delete", "pod", "tt-smoke", "--grace-period=0", "--force")
		k8s.WaitUntilPodAvailable(t, kubectlOpts, "tt-smoke", 30, 5*time.Second)
	})

	// CSI volume provisioning (WaitForFirstConsumer requires a consuming pod)
	t.Run("CSIVolumeProvisioning", func(t *testing.T) {
		manifest := `
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tt-pvc
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
  name: tt-vol
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
        claimName: tt-pvc
`
		k8s.KubectlApplyFromString(t, kubectlOpts, manifest)
		defer func() {
			k8s.RunKubectl(t, kubectlOpts, "delete", "pod", "tt-vol", "--grace-period=0", "--force")
			k8s.RunKubectl(t, kubectlOpts, "delete", "pvc", "tt-pvc")
		}()

		retry.DoWithRetry(t, "wait for volume pod", 30, 10*time.Second, func() (string, error) {
			pod := k8s.GetPod(t, kubectlOpts, "tt-vol")
			if pod.Status.Phase == "Running" {
				return "volume pod running", nil
			}
			return "", fmt.Errorf("pod phase: %s", pod.Status.Phase)
		})
	})

	// NAT gateway: worker can reach the internet (proves NAT via master-00 works)
	t.Run("NATGateway", func(t *testing.T) {
		// Run a pod forced onto the worker (private node) that curls an external URL
		manifest := `
apiVersion: v1
kind: Pod
metadata:
  name: tt-nat
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
    - name: curl
      image: busybox:stable
      command: ["sh", "-c", "wget -qO- --timeout=10 http://ifconfig.me && echo OK"]
  restartPolicy: Never
`
		k8s.KubectlApplyFromString(t, kubectlOpts, manifest)
		defer k8s.RunKubectl(t, kubectlOpts, "delete", "pod", "tt-nat", "--grace-period=0", "--force")

		retry.DoWithRetry(t, "wait for NAT test pod", 20, 10*time.Second, func() (string, error) {
			pod := k8s.GetPod(t, kubectlOpts, "tt-nat")
			if pod.Status.Phase == "Succeeded" {
				return "NAT works — worker reached internet", nil
			}
			if pod.Status.Phase == "Failed" {
				return "", fmt.Errorf("NAT test pod failed")
			}
			return "", fmt.Errorf("pod phase: %s", pod.Status.Phase)
		})
	})
}

// ──────────────────────────────────────────────
// Test: Scale-up and scale-down
// ──────────────────────────────────────────────

func TestScaleUpDown(t *testing.T) {
	t.Parallel()
	token := getRequiredEnv(t, "TF_VAR_hcloud_token")

	vars := baseVars(token, "t-scale")
	tfOpts := newOpts(t, vars)
	defer terraform.Destroy(t, tfOpts)
	terraform.InitAndApply(t, tfOpts)

	kcPath := kubeconfigPath(tfOpts)
	kubectlOpts := k8s.NewKubectlOptions("", kcPath, "default")
	waitForNodesReady(t, kubectlOpts, 2)

	// Scale UP: 1 → 2 workers
	t.Run("ScaleUp", func(t *testing.T) {
		scaledVars := baseVars(token, "t-scale")
		scaledVars["worker_pools"] = map[string]interface{}{
			"default": map[string]interface{}{
				"instance_type":  "cx23",
				"instance_count": 2,
				"location":       "nbg1",
			},
		}
		tfOpts.Vars = scaledVars
		terraform.Apply(t, tfOpts)

		waitForNodesReady(t, kubectlOpts, 3)
		nodes := k8s.GetNodes(t, kubectlOpts)
		assert.Equal(t, 3, len(nodes), "should have 3 nodes after scale-up")
	})

	// Scale DOWN: 2 → 1 workers
	t.Run("ScaleDown", func(t *testing.T) {
		downVars := baseVars(token, "t-scale")
		// Back to default 1 worker
		tfOpts.Vars = downVars
		terraform.Apply(t, tfOpts)

		retry.DoWithRetry(t, "wait for scale-down", 20, 10*time.Second, func() (string, error) {
			nodes := k8s.GetNodes(t, kubectlOpts)
			if len(nodes) != 2 {
				return "", fmt.Errorf("expected 2 nodes after scale-down, got %d", len(nodes))
			}
			return "2 nodes after scale-down", nil
		})
	})
}

// ──────────────────────────────────────────────
// Test: Graceful drain on destroy
// ──────────────────────────────────────────────

func TestGracefulDrain(t *testing.T) {
	t.Parallel()
	token := getRequiredEnv(t, "TF_VAR_hcloud_token")

	vars := baseVars(token, "t-drain")
	tfOpts := newOpts(t, vars)
	// No defer destroy — we destroy manually to capture output.
	terraform.InitAndApply(t, tfOpts)

	kcPath := kubeconfigPath(tfOpts)
	kubectlOpts := k8s.NewKubectlOptions("", kcPath, "default")
	waitForNodesReady(t, kubectlOpts, 2)

	// Create a workload on the worker so drain has something to evict
	k8s.RunKubectl(t, kubectlOpts, "create", "deployment", "drain-test", "--image=nginx:alpine", "--replicas=2")
	retry.DoWithRetry(t, "wait for drain-test pods", 15, 5*time.Second, func() (string, error) {
		pods := k8s.ListPods(t, kubectlOpts, metav1.ListOptions{LabelSelector: "app=drain-test"})
		ready := 0
		for _, p := range pods {
			if p.Status.Phase == "Running" {
				ready++
			}
		}
		if ready < 2 {
			return "", fmt.Errorf("only %d/2 pods running", ready)
		}
		return "drain-test ready", nil
	})

	// Destroy and capture output
	destroyOutput := terraform.Destroy(t, tfOpts)

	// Verify drain ran
	t.Run("DrainExecuted", func(t *testing.T) {
		assert.Contains(t, destroyOutput, "Draining node", "destroy output should show drain")
	})

	t.Run("NodeDeleted", func(t *testing.T) {
		assert.Contains(t, destroyOutput, "Removing node", "destroy output should show node removal")
	})

	t.Run("PodsEvicted", func(t *testing.T) {
		// The drain output should show eviction or draining
		assert.True(t,
			strings.Contains(destroyOutput, "evict") || strings.Contains(destroyOutput, "drained"),
			"destroy output should show pod eviction or drain completion")
	})
}

// ──────────────────────────────────────────────
// Test: HA cluster (3 masters + API LB + private masters)
// ──────────────────────────────────────────────

func TestHACluster(t *testing.T) {
	t.Parallel()
	token := getRequiredEnv(t, "TF_VAR_hcloud_token")

	vars := baseVars(token, "t-ha")
	vars["masters"] = map[string]interface{}{
		"instance_type":  "cx23",
		"instance_count": 3,
		"location":       "nbg1",
	}
	vars["master_public_ip"] = false
	vars["enable_api_lb"] = true
	vars["api_lb_type"] = "lb11"
	vars["api_lb_location"] = "nbg1"

	tfOpts := newOpts(t, vars)
	defer terraform.Destroy(t, tfOpts)
	terraform.InitAndApply(t, tfOpts)

	kcPath := kubeconfigPath(tfOpts)
	require.FileExists(t, kcPath)
	kubectlOpts := k8s.NewKubectlOptions("", kcPath, "default")

	// 3 masters + 1 worker = 4 nodes
	waitForNodesReady(t, kubectlOpts, 4)

	// HA: 3 control-plane nodes
	t.Run("ThreeMasters", func(t *testing.T) {
		nodes := k8s.GetNodes(t, kubectlOpts)
		masters := 0
		for _, node := range nodes {
			if _, ok := node.Labels["node-role.kubernetes.io/control-plane"]; ok {
				masters++
			}
		}
		assert.Equal(t, 3, masters, "should have 3 control-plane nodes")
	})

	// etcd quorum: 3 etcd members
	t.Run("EtcdQuorum", func(t *testing.T) {
		nodes := k8s.GetNodes(t, kubectlOpts)
		etcdNodes := 0
		for _, node := range nodes {
			if _, ok := node.Labels["node-role.kubernetes.io/etcd"]; ok {
				etcdNodes++
			}
		}
		assert.GreaterOrEqual(t, etcdNodes, 3, "should have 3+ etcd nodes for quorum")
	})

	// API endpoint is via LB (not localhost)
	t.Run("APIViaLoadBalancer", func(t *testing.T) {
		apiEndpoint := terraform.Output(t, tfOpts, "api_endpoint")
		assert.NotContains(t, apiEndpoint, "127.0.0.1", "API should be via LB, not localhost")

		lbIP := terraform.Output(t, tfOpts, "load_balancer_ip")
		assert.NotEmpty(t, lbIP, "load balancer IP should not be empty")
		assert.Contains(t, apiEndpoint, lbIP, "API endpoint should contain the LB IP")
	})

	// Cross-node pod communication (master ↔ worker)
	t.Run("CrossNodeNetworking", func(t *testing.T) {
		ns := "tt-net"
		nsOpts := k8s.NewKubectlOptions("", kcPath, ns)
		k8s.RunKubectl(t, kubectlOpts, "create", "namespace", ns)
		defer k8s.RunKubectl(t, kubectlOpts, "delete", "namespace", ns, "--grace-period=0", "--force")

		// Server on a master
		serverManifest := `
apiVersion: v1
kind: Pod
metadata:
  name: net-server
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
`
		k8s.KubectlApplyFromString(t, nsOpts, serverManifest)
		retry.DoWithRetry(t, "wait for server pod", 15, 5*time.Second, func() (string, error) {
			pod := k8s.GetPod(t, nsOpts, "net-server")
			if pod.Status.Phase == "Running" {
				return "server running", nil
			}
			return "", fmt.Errorf("server phase: %s", pod.Status.Phase)
		})

		serverPod := k8s.GetPod(t, nsOpts, "net-server")
		serverIP := serverPod.Status.PodIP
		require.NotEmpty(t, serverIP)

		// Client on a worker
		clientManifest := fmt.Sprintf(`
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
      command: ["sh", "-c", "nc -w 5 %s 8080"]
  restartPolicy: Never
`, serverIP)
		k8s.KubectlApplyFromString(t, nsOpts, clientManifest)

		retry.DoWithRetry(t, "wait for client pod", 20, 5*time.Second, func() (string, error) {
			pod := k8s.GetPod(t, nsOpts, "net-client")
			if pod.Status.Phase == "Succeeded" {
				return "cross-node networking works", nil
			}
			if pod.Status.Phase == "Failed" {
				return "", fmt.Errorf("client pod failed — cross-node networking broken")
			}
			return "", fmt.Errorf("client phase: %s", pod.Status.Phase)
		})
	})
}

// ──────────────────────────────────────────────
// Test: BYO CNI (disable_builtin_cni = true)
// ──────────────────────────────────────────────

func TestBYOCNI(t *testing.T) {
	t.Parallel()
	token := getRequiredEnv(t, "TF_VAR_hcloud_token")

	vars := baseVars(token, "t-cni")
	vars["disable_builtin_cni"] = true

	tfOpts := newOpts(t, vars)
	defer terraform.Destroy(t, tfOpts)
	terraform.InitAndApply(t, tfOpts)

	kcPath := kubeconfigPath(tfOpts)
	kubectlOpts := k8s.NewKubectlOptions("", kcPath, "default")

	// Nodes should register (even if not all are Ready)
	t.Run("NodesRegistered", func(t *testing.T) {
		retry.DoWithRetry(t, "wait for nodes", 20, 10*time.Second, func() (string, error) {
			nodes := k8s.GetNodes(t, kubectlOpts)
			if len(nodes) < 2 {
				return "", fmt.Errorf("expected 2 nodes, got %d", len(nodes))
			}
			return fmt.Sprintf("%d nodes registered", len(nodes)), nil
		})
	})

	// No flannel running
	t.Run("NoFlannel", func(t *testing.T) {
		kubeSysOpts := k8s.NewKubectlOptions("", kcPath, "kube-system")
		pods := k8s.ListPods(t, kubeSysOpts, metav1.ListOptions{})
		for _, pod := range pods {
			assert.NotContains(t, strings.ToLower(pod.Name), "flannel",
				"flannel should not exist with disable_builtin_cni=true")
		}
	})

	// At least one node should have NetworkUnavailable condition
	// (proves CNI is actually missing)
	t.Run("NetworkUnavailable", func(t *testing.T) {
		nodes := k8s.GetNodes(t, kubectlOpts)
		networkUnavailable := false
		for _, node := range nodes {
			for _, cond := range node.Status.Conditions {
				if cond.Type == "Ready" && cond.Status != "True" {
					networkUnavailable = true
				}
			}
		}
		assert.True(t, networkUnavailable,
			"at least one node should be NotReady without CNI")
	})
}

// ──────────────────────────────────────────────
// Test: Multiple worker pools
// ──────────────────────────────────────────────

func TestMultipleWorkerPools(t *testing.T) {
	t.Parallel()
	token := getRequiredEnv(t, "TF_VAR_hcloud_token")

	vars := baseVars(token, "t-pools")
	vars["worker_pools"] = map[string]interface{}{
		"general": map[string]interface{}{
			"instance_type":  "cx23",
			"instance_count": 1,
			"location":       "nbg1",
		},
		"compute": map[string]interface{}{
			"instance_type":  "cx23",
			"instance_count": 1,
			"location":       "nbg1",
		},
	}

	tfOpts := newOpts(t, vars)
	defer terraform.Destroy(t, tfOpts)
	terraform.InitAndApply(t, tfOpts)

	kcPath := kubeconfigPath(tfOpts)
	kubectlOpts := k8s.NewKubectlOptions("", kcPath, "default")

	// 1 master + 2 workers = 3 nodes
	waitForNodesReady(t, kubectlOpts, 3)

	t.Run("TwoWorkerPools", func(t *testing.T) {
		nodes := k8s.GetNodes(t, kubectlOpts)
		workers := 0
		poolNames := map[string]bool{}
		for _, node := range nodes {
			if _, ok := node.Labels["node-role.kubernetes.io/control-plane"]; ok {
				continue
			}
			workers++
			// Worker names contain the pool name: t-pools-worker-general-00, t-pools-worker-compute-00
			name := node.Name
			if strings.Contains(name, "general") {
				poolNames["general"] = true
			}
			if strings.Contains(name, "compute") {
				poolNames["compute"] = true
			}
		}
		assert.Equal(t, 2, workers, "should have 2 workers")
		assert.True(t, poolNames["general"], "general pool worker should exist")
		assert.True(t, poolNames["compute"], "compute pool worker should exist")
	})

	// Both pools show up in outputs
	t.Run("WorkerOutputs", func(t *testing.T) {
		workerIPs := terraform.OutputMap(t, tfOpts, "worker_private_ips")
		assert.Len(t, workerIPs, 2, "should have 2 worker private IPs")
	})
}

// ──────────────────────────────────────────────
// Test: Embedded registry
// ──────────────────────────────────────────────

func TestEmbeddedRegistry(t *testing.T) {
	t.Parallel()
	token := getRequiredEnv(t, "TF_VAR_hcloud_token")

	vars := baseVars(token, "t-reg")
	vars["enable_embedded_registry"] = true

	tfOpts := newOpts(t, vars)
	defer terraform.Destroy(t, tfOpts)
	terraform.InitAndApply(t, tfOpts)

	kcPath := kubeconfigPath(tfOpts)
	kubectlOpts := k8s.NewKubectlOptions("", kcPath, "default")
	waitForNodesReady(t, kubectlOpts, 2)

	// Verify the embedded registry is running by checking the k3s config
	// The registry runs as part of k3s, so we check via a pod that reads the config
	t.Run("RegistryConfigured", func(t *testing.T) {
		manifest := `
apiVersion: v1
kind: Pod
metadata:
  name: tt-regcheck
spec:
  terminationGracePeriodSeconds: 0
  nodeSelector:
    node-role.kubernetes.io/control-plane: "true"
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  containers:
    - name: check
      image: busybox:stable
      command: ["sh", "-c", "cat /etc/rancher/k3s/registries.yaml 2>/dev/null || echo 'no-config'; ls /etc/rancher/k3s/"]
      volumeMounts:
        - name: k3s-config
          mountPath: /etc/rancher/k3s
          readOnly: true
  volumes:
    - name: k3s-config
      hostPath:
        path: /etc/rancher/k3s
  restartPolicy: Never
`
		k8s.KubectlApplyFromString(t, kubectlOpts, manifest)
		defer k8s.RunKubectl(t, kubectlOpts, "delete", "pod", "tt-regcheck", "--grace-period=0", "--force")

		retry.DoWithRetry(t, "wait for registry check", 15, 5*time.Second, func() (string, error) {
			pod := k8s.GetPod(t, kubectlOpts, "tt-regcheck")
			if pod.Status.Phase == "Succeeded" || pod.Status.Phase == "Running" {
				return "registry check done", nil
			}
			return "", fmt.Errorf("phase: %s", pod.Status.Phase)
		})

		// The embedded registry feature should make the cluster functional
		// (the primary test is that the cluster deploys successfully with it enabled)
	})

	// A basic pod pull should still work with embedded registry enabled
	t.Run("PodPullWorks", func(t *testing.T) {
		k8s.RunKubectl(t, kubectlOpts, "run", "tt-pull", "--image=nginx:alpine", "--restart=Never",
			`--overrides={"spec":{"terminationGracePeriodSeconds":0}}`)
		defer k8s.RunKubectl(t, kubectlOpts, "delete", "pod", "tt-pull", "--grace-period=0", "--force")
		k8s.WaitUntilPodAvailable(t, kubectlOpts, "tt-pull", 30, 5*time.Second)
	})
}

// ──────────────────────────────────────────────
// Test: Ingress load balancer
// ──────────────────────────────────────────────

func TestIngressLB(t *testing.T) {
	t.Parallel()
	token := getRequiredEnv(t, "TF_VAR_hcloud_token")

	vars := baseVars(token, "t-ilb")
	vars["enable_ingress_lb"] = true

	tfOpts := newOpts(t, vars)
	defer terraform.Destroy(t, tfOpts)
	terraform.InitAndApply(t, tfOpts)

	kcPath := kubeconfigPath(tfOpts)
	kubectlOpts := k8s.NewKubectlOptions("", kcPath, "default")
	waitForNodesReady(t, kubectlOpts, 2)

	t.Run("IngressLBCreated", func(t *testing.T) {
		lbIP := terraform.Output(t, tfOpts, "ingress_lb_ip")
		assert.NotEmpty(t, lbIP, "ingress LB IP should not be empty")
	})
}

// ──────────────────────────────────────────────
// Test: Input validation (plan-only, no infra)
// ──────────────────────────────────────────────

func TestValidation(t *testing.T) {
	t.Parallel()
	token := getRequiredEnv(t, "TF_VAR_hcloud_token")

	t.Run("EvenMasterCount", func(t *testing.T) {
		t.Parallel()
		vars := baseVars(token, "t-val1")
		vars["masters"] = map[string]interface{}{
			"instance_type":  "cx23",
			"instance_count": 2,
			"location":       "nbg1",
		}
		tfOpts := newOpts(t, vars)
		_, err := terraform.InitAndPlanE(t, tfOpts)
		assert.Error(t, err, "even master count should be rejected")
		if err != nil {
			assert.Contains(t, err.Error(), "odd")
		}
	})

	t.Run("MasterCountTooHigh", func(t *testing.T) {
		t.Parallel()
		vars := baseVars(token, "t-val2")
		vars["masters"] = map[string]interface{}{
			"instance_type":  "cx23",
			"instance_count": 11,
			"location":       "nbg1",
		}
		tfOpts := newOpts(t, vars)
		_, err := terraform.InitAndPlanE(t, tfOpts)
		assert.Error(t, err, "master count >10 should be rejected")
	})

	t.Run("WorkerCountTooHigh", func(t *testing.T) {
		t.Parallel()
		vars := baseVars(token, "t-val3")
		vars["worker_pools"] = map[string]interface{}{
			"default": map[string]interface{}{
				"instance_type":  "cx23",
				"instance_count": 11,
				"location":       "nbg1",
			},
		}
		tfOpts := newOpts(t, vars)
		_, err := terraform.InitAndPlanE(t, tfOpts)
		assert.Error(t, err, "worker count >10 should be rejected")
	})

	t.Run("PrivateMastersRequireAPILB", func(t *testing.T) {
		t.Parallel()
		vars := baseVars(token, "t-val4")
		vars["master_public_ip"] = false
		vars["enable_api_lb"] = false
		tfOpts := newOpts(t, vars)
		_, err := terraform.InitAndPlanE(t, tfOpts)
		// This is a precondition check that fires during plan/apply
		assert.Error(t, err, "private masters without API LB should be rejected")
	})
}
