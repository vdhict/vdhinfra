set positional-arguments := true
set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

kubernetes_dir := justfile_dir()
bootstrap_dir := kubernetes_dir + '/bootstrap'

[private]
default: talos kubernetes (kubeconfig "node") wait namespaces resources crds apps kubeconfig

[doc('Install Talos on all nodes')]
talos:
    just log info "Installing Talos on all nodes..."
    for n in $(ls {{ kubernetes_dir }}/talos/nodes | sed -e 's/.yaml.j2//'); do \
      if ! op=$(just talos apply-node "$n" --insecure 2>&1); then \
        if [[ "$op" == *"certificate required"* ]]; then \
          just log info "Talos already configured, skipping apply" "node" "$n"; \
          continue; \
        fi; \
        just log fatal "Failed to apply Talos configuration" "node" "$n" "output" "$op"; \
      fi; \
    done

[doc('Bootstrap Kubernetes')]
kubernetes:
    just log info "Bootstrapping Talos Kubernetes..."
    just talos bootstrap

[doc('Fetch kubeconfig')]
kubeconfig lb="cilium":
    just log info "Fetching kubeconfig..."
    just talos fetch-kubeconfig {{ lb }}

[doc('Wait for nodes to be ready')]
wait:
    just log info "Waiting for all nodes to be ready..."
    if ! kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then \
      until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do \
        just log info "Nodes not available, retrying in 5 seconds..."; \
        sleep 5; \
      done \
    fi

[doc('Create Kubernetes namespaces')]
namespaces:
    just log info "Creating namespaces..."
    find "{{ kubernetes_dir }}/apps" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | while IFS= read -r ns; do \
      if ! kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply --server-side -f -; then \
        just log fatal "Failed to apply namespace" "namespace" "$ns"; \
      fi; \
    done

[doc('Apply bootstrap resources')]
resources:
    just log info "Applying resources..."
    if [ -f "{{ bootstrap_dir }}/resources.yaml" ]; then \
      kubectl apply --server-side -f "{{ bootstrap_dir }}/resources.yaml"; \
    fi

[doc('Apply Helmfile CRDs')]
crds:
    just log info "Installing CRDs..."
    if ! helmfile -f "{{ bootstrap_dir }}/helmfile.d/00-crds.yaml" template -q | kubectl apply --server-side -f -; then \
      just log fatal "Failed to apply CRDs"; \
    fi

[doc('Apply Helmfile Apps')]
apps:
    just log info "Installing applications..."
    if ! helmfile -f "{{ bootstrap_dir }}/helmfile.d/01-apps.yaml" sync --hide-notes; then \
      just log fatal "Failed to sync helmfile"; \
    fi
