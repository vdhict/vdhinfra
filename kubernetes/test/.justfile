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

[doc('Create QEMU cluster with rook-ceph at version (default 1.16.5 — starts prod-parity rehearsal)')]
up-qemu version='1.16.5':
    just qemu create
    just qemu start
    just qemu apply-config
    just qemu bootstrap
    just deploy-rook-ceph {{ version }}

[doc('Full Rook-Ceph upgrade rehearsal: fresh cluster → 1.16.5 → 1.17.9 → 1.18.10 → 1.19.3')]
rook-rehearsal:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Rook-Ceph Upgrade Rehearsal ==="
    echo "Path: 1.16.5 → 1.17.9 → 1.18.10 → 1.19.3"
    echo ""
    just qemu create
    just qemu start
    just qemu apply-config
    just qemu bootstrap
    just deploy-rook-ceph 1.16.5
    just write-test-data
    echo ""
    echo "=== HOP 1: 1.16.5 → 1.17.9 ==="
    just upgrade-rook 1.17.9
    just verify-test-data
    echo ""
    echo "=== HOP 2: 1.17.9 → 1.18.10 ==="
    just upgrade-rook 1.18.10
    just verify-test-data
    echo ""
    echo "=== HOP 3: 1.18.10 → 1.19.3 ==="
    just upgrade-rook 1.19.3
    just verify-test-data
    echo ""
    echo "=== REHEARSAL COMPLETE — all three hops succeeded with data intact ==="

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

[doc('Deploy rook-ceph operator and cluster at given version (default 1.16.5)')]
deploy-rook-ceph version='1.16.5':
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG="{{ kubernetes_dir }}/kubeconfig"
    echo "=== Deploying Rook-Ceph v{{ version }} ==="

    # Add Helm repo
    helm repo add rook-release https://charts.rook.io/release 2>/dev/null || true
    helm repo update rook-release > /dev/null 2>&1

    # Install rook-ceph operator
    echo "  Creating rook-ceph namespace..."
    kubectl create namespace rook-ceph --dry-run=client -o yaml | kubectl apply --server-side -f - > /dev/null 2>&1
    kubectl label namespace rook-ceph pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged --overwrite > /dev/null 2>&1

    echo "  Installing rook-ceph operator v{{ version }}..."
    helm upgrade --install rook-ceph-operator rook-release/rook-ceph \
      --namespace rook-ceph \
      --version v{{ version }} \
      --set crds.enabled=true \
      --set csi.enableCephfsDriver=true \
      --set monitoring.enabled=false \
      --set resources.requests.memory=128Mi \
      --set resources.requests.cpu=50m \
      --wait --timeout 10m

    echo "  Operator: OK"
    kubectl -n rook-ceph wait --for=condition=Available deployment/rook-ceph-operator --timeout=120s > /dev/null 2>&1

    # Discover worker nodes and OSD disk
    echo "  Discovering worker nodes..."
    workers=()
    while IFS= read -r node; do
      [ -n "$node" ] && workers+=("$node")
    done < <(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o custom-columns=':metadata.name' | tr -d ' ')
    echo "  Found ${#workers[@]} workers: ${workers[*]}"

    osd_disk=""
    for disk in vdb sdb nvme1n1; do
      if talosctl get disks -n "${workers[0]}" 2>/dev/null | grep -q "$disk"; then
        osd_disk="$disk"
        break
      fi
    done
    [ -z "$osd_disk" ] && osd_disk="vdb"
    echo "  OSD disk: $osd_disk"

    node_sets=""
    for idx in "${!workers[@]}"; do
      node_sets="$node_sets --set cephClusterSpec.storage.nodes[$idx].name=${workers[$idx]}"
      node_sets="$node_sets --set cephClusterSpec.storage.nodes[$idx].devices[0].name=$osd_disk"
    done

    echo "  Installing rook-ceph cluster v{{ version }}..."
    helm upgrade --install rook-ceph-cluster rook-release/rook-ceph-cluster \
      --namespace rook-ceph \
      --version v{{ version }} \
      --values "{{ kubernetes_dir }}/rook-ceph-test-values.yaml" \
      $node_sets \
      --timeout 15m

    echo "  Cluster helm release: OK"
    just wait-ceph-healthy

    echo ""
    echo "=== Rook-Ceph v{{ version }} deployed ==="
    kubectl -n rook-ceph get cephcluster
    echo ""
    kubectl -n rook-ceph get pods

[doc('Upgrade Rook-Ceph from current version to target (sequential minor hops only)')]
upgrade-rook version:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG="{{ kubernetes_dir }}/kubeconfig"
    echo "=== Upgrading Rook-Ceph to v{{ version }} ==="

    # Pre-flight: cluster must be healthy before upgrading
    echo "  Pre-flight health check..."
    just wait-ceph-healthy

    current=$(helm -n rook-ceph get metadata rook-ceph-operator -o json 2>/dev/null | jq -r '.version' || echo "unknown")
    echo "  Current operator: $current → target: v{{ version }}"

    # Step 1: Apply new CRDs BEFORE helm upgrade (Helm-installed Rook does not manage its own CRDs).
    # Use `helm template -s templates/resources.yaml` so Helm actually *renders* the manifest
    # (helm pull --untar gives you the unrendered Go template, which is not valid YAML).
    # --force-conflicts lets us take ownership of fields managed by the helm install.
    echo "  [1/5] Rendering and applying CRDs from chart v{{ version }}..."
    helm template rook-ceph-crds rook-release/rook-ceph \
      --version v{{ version }} \
      --namespace rook-ceph \
      -s templates/resources.yaml \
      | kubectl apply --server-side --force-conflicts -f -
    echo "    CRDs applied"

    # Step 2: Upgrade operator
    # --force-conflicts is required because the Rook operator mutates fields at runtime
    # (e.g. healthCheck intervals, storage.nodes), so Helm's server-side apply would
    # otherwise refuse to take ownership of those fields during upgrade.
    echo "  [2/5] Upgrading operator to v{{ version }}..."
    helm upgrade rook-ceph-operator rook-release/rook-ceph \
      --namespace rook-ceph \
      --version v{{ version }} \
      --reset-then-reuse-values \
      --force-conflicts \
      --take-ownership \
      --wait --timeout 10m

    echo "  [3/5] Waiting for operator pod rollout..."
    kubectl -n rook-ceph rollout status deployment/rook-ceph-operator --timeout=5m

    # Step 3: Upgrade cluster chart (re-discover nodes since --reuse-values only works for operator)
    echo "  [4/5] Upgrading rook-ceph-cluster to v{{ version }}..."
    workers=()
    while IFS= read -r node; do
      [ -n "$node" ] && workers+=("$node")
    done < <(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o custom-columns=':metadata.name' | tr -d ' ')

    osd_disk=""
    for disk in vdb sdb nvme1n1; do
      if talosctl get disks -n "${workers[0]}" 2>/dev/null | grep -q "$disk"; then
        osd_disk="$disk"
        break
      fi
    done
    [ -z "$osd_disk" ] && osd_disk="vdb"

    node_sets=""
    for idx in "${!workers[@]}"; do
      node_sets="$node_sets --set cephClusterSpec.storage.nodes[$idx].name=${workers[$idx]}"
      node_sets="$node_sets --set cephClusterSpec.storage.nodes[$idx].devices[0].name=$osd_disk"
    done

    helm upgrade rook-ceph-cluster rook-release/rook-ceph-cluster \
      --namespace rook-ceph \
      --version v{{ version }} \
      --values "{{ kubernetes_dir }}/rook-ceph-test-values.yaml" \
      $node_sets \
      --force-conflicts \
      --timeout 20m

    # Step 4: Wait for health + all pods on new version
    echo "  [5/5] Waiting for cluster to stabilise on v{{ version }}..."
    just wait-ceph-healthy

    echo ""
    echo "  Pod images after upgrade:"
    kubectl -n rook-ceph get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[*].image}{"\n"}{end}' | grep -v '^$' | awk '{print "    "$0}'

    echo ""
    echo "=== Upgrade to v{{ version }} complete ==="

[doc('Wait for CephCluster to report Ready + HEALTH_OK/WARN')]
wait-ceph-healthy:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG="{{ kubernetes_dir }}/kubeconfig"
    for attempt in $(seq 1 120); do
      phase=$(kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
      health=$(kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.health}' 2>/dev/null || echo "unknown")
      if [ "$phase" = "Ready" ] && { [ "$health" = "HEALTH_OK" ] || [ "$health" = "HEALTH_WARN" ]; }; then
        echo "    Ceph ready: phase=$phase health=$health"
        exit 0
      fi
      echo "    waiting: phase=$phase health=$health ($attempt/120)"
      sleep 15
    done
    echo "    TIMEOUT — cluster did not reach Ready+HEALTH_OK/WARN"
    kubectl -n rook-ceph get cephcluster -o yaml | tail -40
    kubectl -n rook-ceph get pods
    exit 1

[doc('Write sha256-checksummed test data to rook-ceph-block and rook-ceph-filesystem PVCs')]
write-test-data:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG="{{ kubernetes_dir }}/kubeconfig"
    echo "=== Writing test data ==="

    kubectl create namespace rook-test --dry-run=client -o yaml | kubectl apply --server-side -f - > /dev/null 2>&1
    kubectl -n rook-test delete pod test-writer --ignore-not-found --wait=true > /dev/null 2>&1

    kubectl apply --server-side -f - <<'EOF' > /dev/null
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: test-rbd
      namespace: rook-test
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: rook-ceph-block
      resources:
        requests: {storage: 1Gi}
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: test-cephfs
      namespace: rook-test
    spec:
      accessModes: [ReadWriteMany]
      storageClassName: rook-ceph-filesystem
      resources:
        requests: {storage: 1Gi}
    ---
    apiVersion: v1
    kind: Pod
    metadata:
      name: test-writer
      namespace: rook-test
    spec:
      restartPolicy: Never
      containers:
        - name: writer
          image: busybox:1.37
          command: [/bin/sh, -c]
          args:
            - |
              set -e
              echo "Writing 10MB random data to RBD..."
              dd if=/dev/urandom of=/rbd/data.bin bs=1M count=10 2>/dev/null
              sha256sum /rbd/data.bin | awk '{print $1}' > /rbd/data.sha256
              echo "RBD checksum: $(cat /rbd/data.sha256)"
              echo "Writing 10MB random data to CephFS..."
              dd if=/dev/urandom of=/cephfs/data.bin bs=1M count=10 2>/dev/null
              sha256sum /cephfs/data.bin | awk '{print $1}' > /cephfs/data.sha256
              echo "CephFS checksum: $(cat /cephfs/data.sha256)"
              echo "WRITE OK"
          volumeMounts:
            - {name: rbd, mountPath: /rbd}
            - {name: cephfs, mountPath: /cephfs}
      volumes:
        - name: rbd
          persistentVolumeClaim: {claimName: test-rbd}
        - name: cephfs
          persistentVolumeClaim: {claimName: test-cephfs}
    EOF

    echo "  Waiting for writer pod to complete..."
    for attempt in $(seq 1 60); do
      phase=$(kubectl -n rook-test get pod test-writer -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
      [ "$phase" = "Succeeded" ] && break
      [ "$phase" = "Failed" ] && { kubectl -n rook-test logs test-writer; exit 1; }
      sleep 5
    done

    kubectl -n rook-test logs test-writer
    echo "=== Test data written ==="

[doc('Read back and verify test data after an upgrade hop')]
verify-test-data:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG="{{ kubernetes_dir }}/kubeconfig"
    echo "=== Verifying test data ==="

    kubectl -n rook-test delete pod test-verifier --ignore-not-found --wait=true > /dev/null 2>&1

    kubectl apply --server-side -f - <<'EOF' > /dev/null
    apiVersion: v1
    kind: Pod
    metadata:
      name: test-verifier
      namespace: rook-test
    spec:
      restartPolicy: Never
      containers:
        - name: verifier
          image: busybox:1.37
          command: [/bin/sh, -c]
          args:
            - |
              set -e
              rbd_expected=$(cat /rbd/data.sha256)
              rbd_actual=$(sha256sum /rbd/data.bin | awk '{print $1}')
              if [ "$rbd_expected" != "$rbd_actual" ]; then
                echo "RBD CORRUPTION: expected $rbd_expected got $rbd_actual"
                exit 1
              fi
              echo "RBD OK: $rbd_actual"
              cephfs_expected=$(cat /cephfs/data.sha256)
              cephfs_actual=$(sha256sum /cephfs/data.bin | awk '{print $1}')
              if [ "$cephfs_expected" != "$cephfs_actual" ]; then
                echo "CEPHFS CORRUPTION: expected $cephfs_expected got $cephfs_actual"
                exit 1
              fi
              echo "CEPHFS OK: $cephfs_actual"
              echo "VERIFY OK"
          volumeMounts:
            - {name: rbd, mountPath: /rbd}
            - {name: cephfs, mountPath: /cephfs}
      volumes:
        - name: rbd
          persistentVolumeClaim: {claimName: test-rbd}
        - name: cephfs
          persistentVolumeClaim: {claimName: test-cephfs}
    EOF

    for attempt in $(seq 1 60); do
      phase=$(kubectl -n rook-test get pod test-verifier -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
      [ "$phase" = "Succeeded" ] && break
      [ "$phase" = "Failed" ] && { kubectl -n rook-test logs test-verifier; exit 1; }
      sleep 5
    done

    kubectl -n rook-test logs test-verifier
    echo "=== Test data verified ==="

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}
