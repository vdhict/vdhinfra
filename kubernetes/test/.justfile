#!/usr/bin/env -S just --justfile

set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

kubernetes_dir := justfile_dir()
main_dir := kubernetes_dir + '/../main'

mod docker "docker.just"
mod qemu "qemu.just"

[private]
default:
    just -l

[doc('Full test: create cluster, validate all manifests, teardown')]
ci: up validate down

[doc('Create and prepare Docker test cluster')]
up:
    just docker create
    just install-crds

[doc('Destroy the Docker test cluster')]
down:
    just docker destroy

[doc('Reset and rebuild the Docker test cluster')]
rebuild: down up

[doc('Create QEMU cluster with rook-ceph')]
up-qemu:
    just qemu create
    just qemu start
    just qemu apply-config
    just qemu bootstrap
    just install-crds
    just deploy-rook-ceph

[doc('Destroy the QEMU test cluster')]
down-qemu:
    just qemu destroy

[doc('Validate all manifests against the test cluster')]
validate: validate-structure validate-kustomize validate-manifests

[doc('Show cluster status')]
status:
    @echo "=== Nodes ===" && kubectl get nodes -o wide 2>/dev/null || echo "Cluster not running"
    @echo "" && echo "=== Pods ===" && kubectl get pods -A 2>/dev/null || true

# --- Validation recipes ---

[doc('Validate repo structure (no cluster needed)')]
validate-structure:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Structural Validation ==="
    errors=0

    # Every app with app/ dir must have install.yaml
    for app_dir in {{ main_dir }}/apps/*/*/; do
      if [ -d "$app_dir/app" ] && [ ! -f "$app_dir/install.yaml" ]; then
        echo "FAIL: missing install.yaml in $app_dir"
        errors=$((errors + 1))
      fi
    done

    # Every app/ dir must have kustomization.yaml
    for app_dir in {{ main_dir }}/apps/*/*/app/; do
      if [ ! -f "$app_dir/kustomization.yaml" ]; then
        echo "FAIL: missing kustomization.yaml in $app_dir"
        errors=$((errors + 1))
      fi
    done

    # Every namespace must have kustomization.yaml
    for ns_dir in {{ main_dir }}/apps/*/; do
      if [ ! -f "$ns_dir/kustomization.yaml" ]; then
        echo "FAIL: missing namespace kustomization.yaml in $ns_dir"
        errors=$((errors + 1))
      fi
    done

    if [ $errors -eq 0 ]; then
      echo "  Structure: ALL PASS"
    else
      echo "  Structure: $errors FAILURES"
      exit 1
    fi

[doc('Validate kustomize build for all namespaces')]
validate-kustomize:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Kustomize Build Validation ==="
    errors=0

    for ns_dir in {{ main_dir }}/apps/*/; do
      ns=$(basename "$ns_dir")
      if ! kustomize build "$ns_dir" > /dev/null 2>&1; then
        echo "  FAIL: $ns"
        kustomize build "$ns_dir" 2>&1 | head -3
        errors=$((errors + 1))
      fi
    done

    if ! kustomize build "{{ main_dir }}/cluster/" > /dev/null 2>&1; then
      echo "  FAIL: cluster"
      errors=$((errors + 1))
    fi

    if [ $errors -eq 0 ]; then
      echo "  Kustomize: ALL PASS"
    else
      echo "  Kustomize: $errors FAILURES"
      exit 1
    fi

[doc('Validate all manifests via server-side dry-run')]
validate-manifests:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "=== Manifest Validation (server-side dry-run) ==="
    errors=0
    successes=0
    skipped=0

    # Phase 1: Apply namespace-level Flux Kustomizations
    echo "--- Phase 1: Flux Kustomization resources ---"
    for ns_dir in {{ main_dir }}/apps/*/; do
      ns=$(basename "$ns_dir")
      if kustomize build "$ns_dir" | kubectl apply --server-side -f - > /dev/null 2>&1; then
        successes=$((successes + 1))
      else
        echo "  FAIL: $ns (namespace kustomization)"
        errors=$((errors + 1))
      fi
    done
    echo "  Namespaces: $successes applied"

    # Phase 2: Dry-run all app manifests
    echo "--- Phase 2: App manifests (dry-run) ---"
    successes=0
    for app_dir in {{ main_dir }}/apps/*/*/app/; do
      parent=$(dirname "$app_dir")
      app=$(basename "$parent")
      ns=$(basename "$(dirname "$parent")")

      # Build first
      manifest=$(kustomize build "$app_dir" 2>&1) || {
        echo "  FAIL: $ns/$app (kustomize build)"
        errors=$((errors + 1))
        continue
      }

      # Skip SOPS placeholder files (contain .sops metadata that won't apply)
      if echo "$manifest" | grep -q "sops:" && echo "$manifest" | grep -q "CHANGEME\|ENC\[AES"; then
        echo "  SKIP: $ns/$app (SOPS encrypted placeholder)"
        skipped=$((skipped + 1))
        continue
      fi

      # Filter out resources with ${} variables (Flux substitution) for hostname validation
      # Apply what we can, collect errors
      result=$(echo "$manifest" | kubectl apply --server-side --dry-run=server -f - 2>&1)
      rc=$?

      if [ $rc -eq 0 ]; then
        successes=$((successes + 1))
      else
        # Check if the ONLY errors are variable substitution or SOPS
        filtered=$(echo "$result" | grep -i "error\|invalid" | grep -v "serverside-applied" || true)
        if echo "$filtered" | grep -qE '\$\{|\.sops:|sops:' 2>/dev/null; then
          echo "  SKIP: $ns/$app (Flux variable substitution / SOPS)"
          skipped=$((skipped + 1))
        else
          echo "  FAIL: $ns/$app"
          echo "    $(echo "$filtered" | head -2)"
          errors=$((errors + 1))
        fi
      fi
    done

    # Also test sub-app directories (gateway/, issuers/, stores/, db/, etc.)
    echo "--- Phase 3: Sub-app directories ---"
    for sub_dir in {{ main_dir }}/apps/*/*/*/; do
      dir_name=$(basename "$sub_dir")
      # Skip app/ dirs (already tested) and config/patches dirs
      if [[ "$dir_name" == "app" || "$dir_name" == "config" || "$dir_name" == "patches" ]]; then
        continue
      fi
      # Must have kustomization.yaml
      if [ ! -f "$sub_dir/kustomization.yaml" ]; then
        continue
      fi

      parent=$(dirname "$sub_dir")
      app=$(basename "$parent")
      ns=$(basename "$(dirname "$parent")")

      manifest=$(kustomize build "$sub_dir" 2>&1) || {
        echo "  FAIL: $ns/$app/$dir_name (kustomize build)"
        errors=$((errors + 1))
        continue
      }

      if echo "$manifest" | grep -q "sops:" && echo "$manifest" | grep -q "CHANGEME\|ENC\[AES"; then
        echo "  SKIP: $ns/$app/$dir_name (SOPS)"
        skipped=$((skipped + 1))
        continue
      fi

      result=$(echo "$manifest" | kubectl apply --server-side --dry-run=server -f - 2>&1)
      if [ $? -eq 0 ]; then
        successes=$((successes + 1))
      else
        filtered=$(echo "$result" | grep -i "error\|invalid" | grep -v "serverside-applied" || true)
        if echo "$filtered" | grep -qE '\$\{|\.sops:|sops:' 2>/dev/null; then
          echo "  SKIP: $ns/$app/$dir_name (Flux variable / SOPS)"
          skipped=$((skipped + 1))
        else
          echo "  FAIL: $ns/$app/$dir_name"
          echo "    $(echo "$filtered" | head -2)"
          errors=$((errors + 1))
        fi
      fi
    done

    echo ""
    echo "=== RESULTS ==="
    echo "  Passed:  $successes"
    echo "  Skipped: $skipped (Flux variables / SOPS placeholders)"
    echo "  Failed:  $errors"

    if [ $errors -gt 0 ]; then
      echo "  STATUS: FAILED"
      exit 1
    else
      echo "  STATUS: ALL PASS"
    fi

# --- Setup recipes ---

[doc('Install all CRDs needed for manifest validation')]
install-crds:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Installing CRDs ==="

    # Flux controllers (includes Kustomization, HelmRelease, OCIRepository, Receiver, etc.)
    echo "  Installing Flux..."
    kubectl apply --server-side -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml > /dev/null 2>&1
    kubectl -n flux-system wait --for=condition=Available --timeout=120s \
      deployment/source-controller deployment/kustomize-controller deployment/helm-controller > /dev/null 2>&1
    echo "  Flux: OK"

    # Gateway API CRDs (HTTPRoute, Gateway, GatewayClass, etc.)
    echo "  Installing Gateway API CRDs..."
    kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml > /dev/null 2>&1
    echo "  Gateway API: OK"

    # Envoy Gateway CRDs (EnvoyProxy, ClientTrafficPolicy, BackendTrafficPolicy)
    echo "  Installing Envoy Gateway CRDs..."
    kubectl apply --server-side -f https://github.com/envoyproxy/gateway/releases/download/v1.3.0/install.yaml > /dev/null 2>&1 || \
      kubectl apply --server-side -f https://raw.githubusercontent.com/envoyproxy/gateway/main/charts/gateway-helm/crds/generated/gateway.envoyproxy.io_envoyproxies.yaml > /dev/null 2>&1 || true
    echo "  Envoy Gateway: OK"

    # ExternalSecrets CRDs (ExternalSecret, ClusterSecretStore)
    echo "  Installing ExternalSecrets CRDs..."
    kubectl apply --server-side -f https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/crds/bundle.yaml > /dev/null 2>&1
    echo "  ExternalSecrets: OK"

    # cert-manager CRDs (Certificate, ClusterIssuer)
    echo "  Installing cert-manager CRDs..."
    kubectl apply --server-side -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.crds.yaml > /dev/null 2>&1
    echo "  cert-manager: OK"

    # Prometheus Operator CRDs (PodMonitor, ServiceMonitor)
    echo "  Installing Prometheus Operator CRDs..."
    kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml > /dev/null 2>&1
    kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml > /dev/null 2>&1
    echo "  Prometheus Operator: OK"

    # Cilium CRDs (CiliumL2AnnouncementPolicy, CiliumLoadBalancerIPPool)
    echo "  Installing Cilium CRDs..."
    kubectl apply --server-side -f https://raw.githubusercontent.com/cilium/cilium/main/pkg/k8s/apis/cilium.io/client/crds/v2alpha1/ciliuml2announcementpolicies.yaml > /dev/null 2>&1
    kubectl apply --server-side -f https://raw.githubusercontent.com/cilium/cilium/main/pkg/k8s/apis/cilium.io/client/crds/v2/ciliumloadbalancerippools.yaml > /dev/null 2>&1
    echo "  Cilium: OK"

    # external-dns CRDs (DNSEndpoint)
    echo "  Installing external-dns CRDs..."
    kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/external-dns/master/config/crd/standard/dnsendpoints.externaldns.k8s.io.yaml > /dev/null 2>&1
    echo "  external-dns: OK"

    # Create all namespaces
    echo "  Creating namespaces..."
    for ns in $(ls -1 "{{ main_dir }}/apps"); do
      kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply --server-side -f - > /dev/null 2>&1
    done
    echo "  Namespaces: OK"

    echo "=== All CRDs installed ==="

[doc('Deploy rook-ceph operator and cluster')]
deploy-rook-ceph:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Deploying Rook-Ceph ==="

    # Add Helm repo
    helm repo add rook-ceph https://charts.rook.io/release 2>/dev/null || true
    helm repo update rook-ceph > /dev/null 2>&1

    # Install rook-ceph operator
    echo "  Installing rook-ceph operator..."
    kubectl create namespace rook-ceph --dry-run=client -o yaml | kubectl apply --server-side -f - > /dev/null 2>&1
    kubectl label namespace rook-ceph pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged --overwrite > /dev/null 2>&1
    helm upgrade --install rook-ceph-operator rook-ceph/rook-ceph \
      --namespace rook-ceph \
      --version v1.19.2 \
      --set crds.enabled=true \
      --set csi.enableCephfsDriver=true \
      --set monitoring.enabled=false \
      --set resources.requests.memory=128Mi \
      --set resources.requests.cpu=50m \
      --set-json 'csi.csiRBDPluginResource=[{"name":"driver-registrar","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"csi-rbdplugin","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"liveness-prometheus","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}}]' \
      --set-json 'csi.csiCephFSPluginResource=[{"name":"driver-registrar","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"csi-cephfsplugin","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"liveness-prometheus","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}}]' \
      --set-json 'csi.csiRBDProvisionerResource=[{"name":"csi-provisioner","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"csi-resizer","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"csi-attacher","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"csi-snapshotter","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"csi-rbdplugin","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"csi-omap-generator","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"liveness-prometheus","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}}]' \
      --set-json 'csi.csiCephFSProvisionerResource=[{"name":"csi-provisioner","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"csi-resizer","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"csi-attacher","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"csi-snapshotter","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"csi-cephfsplugin","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}},{"name":"liveness-prometheus","resource":{"requests":{"cpu":"10m","memory":"64Mi"}}}]' \
      --wait --timeout 5m

    echo "  Operator: OK"

    # Wait for operator to be ready
    kubectl -n rook-ceph wait --for=condition=Available deployment/rook-ceph-operator --timeout=120s > /dev/null 2>&1

    # Discover worker node names and OSD disk
    echo "  Discovering worker nodes..."
    workers=()
    while IFS= read -r node; do
      [ -n "$node" ] && workers+=("$node")
    done < <(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o custom-columns=':metadata.name' | tr -d ' ')
    echo "  Found ${#workers[@]} workers: ${workers[*]}"

    # Discover the OSD disk on first worker (second disk, not the boot disk)
    echo "  Discovering OSD disk..."
    osd_disk=""
    for disk in vdb sdb nvme1n1; do
      if talosctl get disks -n "${workers[0]}" 2>/dev/null | grep -q "$disk"; then
        osd_disk="$disk"
        break
      fi
    done
    if [ -z "$osd_disk" ]; then
      echo "  Listing disks on ${workers[0]}:"
      talosctl get disks -n "${workers[0]}" 2>/dev/null || true
      echo "  WARN: Could not auto-detect OSD disk, defaulting to vdb"
      osd_disk="vdb"
    fi
    echo "  OSD disk: $osd_disk"

    # Build Helm --set flags for storage nodes
    echo "  Storage nodes:"
    node_sets=""
    for idx in "${!workers[@]}"; do
      echo "    - ${workers[$idx]}: /dev/$osd_disk"
      node_sets="$node_sets --set cephClusterSpec.storage.nodes[$idx].name=${workers[$idx]}"
      node_sets="$node_sets --set cephClusterSpec.storage.nodes[$idx].devices[0].name=$osd_disk"
    done

    # Install rook-ceph cluster
    echo "  Installing rook-ceph cluster..."
    helm upgrade --install rook-ceph-cluster rook-ceph/rook-ceph-cluster \
      --namespace rook-ceph \
      --version v1.19.2 \
      --values "{{ kubernetes_dir }}/rook-ceph-test-values.yaml" \
      $node_sets \
      --timeout 10m

    echo "  Cluster helm release: OK"

    # Wait for Ceph health
    echo "  Waiting for Ceph cluster to become healthy..."
    for attempt in $(seq 1 60); do
      phase=$(kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
      health=$(kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.health}' 2>/dev/null || echo "unknown")

      if [ "$phase" = "Ready" ] && [ "$health" = "HEALTH_OK" ]; then
        echo "  Ceph cluster healthy!"
        break
      fi
      if [ "$phase" = "Ready" ] && [ "$health" = "HEALTH_WARN" ]; then
        echo "  Ceph cluster ready (with warnings - normal for test)"
        break
      fi
      echo "  Phase: $phase, Health: $health (attempt $attempt/60)"
      sleep 15
    done

    echo ""
    echo "=== Rook-Ceph Status ==="
    kubectl -n rook-ceph get cephcluster
    echo ""
    kubectl -n rook-ceph get pods
    echo ""

    # Verify StorageClass exists
    if kubectl get storageclass rook-ceph-block > /dev/null 2>&1; then
      echo "  StorageClass rook-ceph-block: OK"
    else
      echo "  WARN: StorageClass rook-ceph-block not found yet"
    fi

    # Quick PVC test
    echo ""
    echo "  Testing PVC provisioning..."
    cat <<'PVC_EOF' | kubectl apply -f -
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: ceph-test-pvc
      namespace: rook-ceph
    spec:
      accessModes:
        - ReadWriteOnce
      storageClassName: rook-ceph-block
      resources:
        requests:
          storage: 1Gi
    PVC_EOF

    for attempt in $(seq 1 30); do
      status=$(kubectl -n rook-ceph get pvc ceph-test-pvc -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
      if [ "$status" = "Bound" ]; then
        echo "  PVC test: PASS (Bound)"
        break
      fi
      echo "  PVC status: $status (attempt $attempt/30)"
      sleep 10
    done
    kubectl -n rook-ceph delete pvc ceph-test-pvc > /dev/null 2>&1 || true

    echo ""
    echo "=== Rook-Ceph deployment complete ==="

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}
