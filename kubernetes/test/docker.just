set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

kubernetes_dir := justfile_dir()

# Cluster configuration
cluster_name := 'vdhinfra-test'
workers := '1'
kubernetes_version := '1.35.2'
subnet := '10.5.0.0/24'
memory_cp := '4GiB'
memory_worker := '2GiB'
cpus_cp := '2.0'
cpus_worker := '2.0'

[private]
default:
    just -l docker

[doc('Create the test cluster')]
create:
    just log info "Creating Docker-based Talos test cluster..." \
      "name" "{{ cluster_name }}" \
      "workers" "{{ workers }}"
    touch {{ kubernetes_dir }}/kubeconfig
    talosctl cluster create docker \
      --name {{ cluster_name }} \
      --workers {{ workers }} \
      --kubernetes-version {{ kubernetes_version }} \
      --subnet {{ subnet }} \
      --memory-controlplanes {{ memory_cp }} \
      --memory-workers {{ memory_worker }} \
      --cpus-controlplanes {{ cpus_cp }} \
      --cpus-workers {{ cpus_worker }}
    just log info "Test cluster created successfully"

[doc('Destroy the test cluster')]
destroy:
    just log info "Destroying test cluster..."
    -talosctl cluster destroy --name {{ cluster_name }} --force
    -rm -f {{ kubernetes_dir }}/kubeconfig {{ kubernetes_dir }}/talosconfig
    just log info "Test cluster destroyed"

[doc('Fetch kubeconfig for the test cluster')]
kubeconfig:
    just log info "Fetching test cluster kubeconfig..."
    kubectl config view --raw --context=admin@{{ cluster_name }} --flatten > {{ kubernetes_dir }}/kubeconfig
    kubectl --kubeconfig {{ kubernetes_dir }}/kubeconfig config rename-context admin@{{ cluster_name }} test || true

[doc('Wait for the test cluster to be ready')]
wait:
    just log info "Waiting for test cluster nodes to be ready..."
    until kubectl wait nodes --for=condition=Ready --all --timeout=5s &>/dev/null; do \
      just log info "Nodes not ready, retrying in 5 seconds..."; \
      sleep 5; \
    done
    just log info "All nodes ready"

[doc('Show cluster container status')]
containers:
    docker ps --filter "name={{ cluster_name }}" --format "table {{"{{"}}.Names{{"}}"}}\\t{{"{{"}}.Status{{"}}"}}\\t{{"{{"}}.Ports{{"}}"}}"

[doc('Stop the test cluster (preserves state)')]
stop:
    just log info "Stopping test cluster containers..."
    docker ps -q --filter "name={{ cluster_name }}" | xargs -r docker stop

[doc('Start a stopped test cluster')]
start:
    just log info "Starting test cluster containers..."
    docker ps -aq --filter "name={{ cluster_name }}" | xargs -r docker start
    just wait
