set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

kubernetes_dir := justfile_dir()
talos_dir := kubernetes_dir + '/talos'

[private]
default:
    just -l talos

[doc('Bootstrap the cluster for Kubernetes')]
bootstrap:
    until op=$(talosctl bootstrap 2>&1 || true) && [[ "$op" == *"AlreadyExists"* ]]; do \
      just log info "Kubernetes bootstrap in progress. Retrying in 5 seconds..."; \
      sleep 5; \
    done

[doc('Fetch kubeconfig')]
fetch-kubeconfig lb="cilium":
    -rm $KUBECONFIG
    if ! talosctl kubeconfig -f --force-context-name main $KUBECONFIG; then \
      just log fatal "Failed to fetch kubeconfig"; \
    fi
    -kubectl config rename-context admin@main main

[doc('Apply Talos config to a node')]
apply-node node *args:
    talosctl -n "{{ node }}" apply-config -f "{{ talos_dir }}/clusterconfig/{{ node }}.yaml" {{ args }}

[doc('Apply Talos config to all nodes')]
apply-cluster *args:
    kubectl get nodes --no-headers | while read -r node _; do \
      just log info "Applying Talos config to node ${node}"; \
      just talos apply-node ${node} {{ args }}; \
    done

[doc('Generate Talos config with talhelper')]
generate-config:
    cd "{{ talos_dir }}" && talhelper genconfig

[doc('Reboot a node')]
reboot-node node:
    gum confirm "Reboot node {{ node }}?" && \
      talosctl -n {{ node }} reboot -m powercycle || exit 0

[doc('Reset a node')]
reset-node node mode="reboot":
    gum confirm "Reset node {{ node }}?" && \
      talosctl -n "{{ node }}" reset --graceful=false {{ if mode == "reboot" { "--reboot" } else { "" } }} || exit 0

[doc('Reset all nodes in the cluster')]
reset-cluster mode="reboot":
    kubectl get nodes --no-headers | while read -r node _; do \
      just log info "Resetting Talos node ${node}"; \
      just talos reset-node ${node} {{ mode }}; \
    done

[doc('Upgrade Kubernetes version on the cluster')]
upgrade-k8s version:
    talosctl upgrade-k8s --to {{ version }}

[doc('Upgrade Talos on a node')]
upgrade-node node:
    talosctl -n "{{ node }}" upgrade -i "$(just talos machine-image {{ node }})" -m powercycle --timeout=10m

[doc('Download Talos machine image')]
download-image version schematic:
    gum spin --title "Downloading Talos {{ version }} ..." -- \
    curl -sfL --remove-on-error --retry 5 --retry-delay 5 --retry-all-errors \
        -o "{{ talos_dir }}/talos-{{ version }}-{{ replace_regex(schematic, '^(.{8}).*', '$1') }}.iso" \
        "https://factory.talos.dev/image/{{ schematic }}/{{ version }}/metal-amd64.iso"
    just log info "Downloaded Talos" version "{{ version }}" schematic "{{ schematic }}"

[doc('Get the machine image for a node')]
[private]
machine-image node:
    talosctl --nodes {{ node }} get machineconfig -o yaml | yq -e 'select(.metadata.id == "v1alpha1") | .spec' | yq -e 'select(.machine) | .machine.install.image'
