set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

kubernetes_dir := justfile_dir()
qemu_dir := kubernetes_dir + '/qemu'
iso_path := qemu_dir + '/talos-arm64.iso'
efi_code := '/opt/homebrew/share/qemu/edk2-aarch64-code.fd'

# Cluster configuration
cluster_prefix := 'talos-test'
cp_count := '1'
worker_count := '3'
# Custom schematic with random.trust_cpu=on for fast VM boot
talos_schematic := '455913e9d0d6786ecee2af4cb88d3b672e796e7013fbbd387db0211948c53ad2'
talos_version := 'v1.12.4'
kubernetes_version := '1.35.2'
memory_cp := '4096'
memory_worker := '6144'
cpus := '2'
boot_disk_size := '20G'
osd_disk_size := '5G'

# MAC address prefixes (deterministic per VM for IP discovery)
mac_prefix_cp := '52:54:00:12:34:0'
mac_prefix_worker := '52:54:00:12:35:0'

[private]
default:
    just -l qemu

[doc('Create QEMU disk images for test cluster')]
create: download-iso
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Creating QEMU disk images ==="
    mkdir -p "{{ qemu_dir }}"

    for i in $(seq 1 {{ cp_count }}); do
      name="{{ cluster_prefix }}-cp-${i}"
      boot_disk="{{ qemu_dir }}/${name}-boot.qcow2"
      vars="{{ qemu_dir }}/${name}-vars.fd"
      if [ -f "$boot_disk" ]; then
        echo "  $name already exists, skipping"
        continue
      fi
      echo "  Creating $name disks..."
      qemu-img create -f qcow2 "$boot_disk" {{ boot_disk_size }}
      dd if=/dev/zero of="$vars" bs=1m count=64 2>/dev/null
    done

    for i in $(seq 1 {{ worker_count }}); do
      name="{{ cluster_prefix }}-worker-${i}"
      boot_disk="{{ qemu_dir }}/${name}-boot.qcow2"
      osd_disk="{{ qemu_dir }}/${name}-osd.qcow2"
      vars="{{ qemu_dir }}/${name}-vars.fd"
      if [ -f "$boot_disk" ]; then
        echo "  $name already exists, skipping"
        continue
      fi
      echo "  Creating $name disks..."
      qemu-img create -f qcow2 "$boot_disk" {{ boot_disk_size }}
      qemu-img create -f qcow2 "$osd_disk" {{ osd_disk_size }}
      dd if=/dev/zero of="$vars" bs=1m count=64 2>/dev/null
    done

    echo "=== Disk images created ==="

[doc('Start all VMs (requires sudo for vmnet networking)')]
start:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Starting QEMU VMs ==="

    # Start control plane VMs
    for i in $(seq 1 {{ cp_count }}); do
      name="{{ cluster_prefix }}-cp-${i}"
      pidfile="{{ qemu_dir }}/${name}.pid"
      mac="{{ mac_prefix_cp }}${i}"

      if pgrep -f "qemu-system.*-name $name " > /dev/null 2>&1; then
        echo "  $name already running"
        continue
      fi
      rm -f "$pidfile"

      echo "  Starting $name (mac: $mac)..."
      sudo qemu-system-aarch64 \
        -name "$name" \
        -machine virt -cpu host -accel hvf \
        -m {{ memory_cp }} -smp {{ cpus }} \
        -drive if=pflash,format=raw,readonly=on,file={{ efi_code }} \
        -drive if=pflash,format=raw,file={{ qemu_dir }}/${name}-vars.fd \
        -drive file={{ qemu_dir }}/${name}-boot.qcow2,if=virtio,format=qcow2 \
        -cdrom "{{ iso_path }}" \
        -device virtio-rng-pci \
        -nic vmnet-shared,mac="$mac" \
        -display none -serial null -monitor null \
        -daemonize
      pgrep -f "qemu-system.*-name $name " > "$pidfile"
    done

    # Start worker VMs
    for i in $(seq 1 {{ worker_count }}); do
      name="{{ cluster_prefix }}-worker-${i}"
      pidfile="{{ qemu_dir }}/${name}.pid"
      mac="{{ mac_prefix_worker }}${i}"

      if pgrep -f "qemu-system.*-name $name " > /dev/null 2>&1; then
        echo "  $name already running"
        continue
      fi
      rm -f "$pidfile"

      echo "  Starting $name (mac: $mac)..."
      sudo qemu-system-aarch64 \
        -name "$name" \
        -machine virt -cpu host -accel hvf \
        -m {{ memory_worker }} -smp {{ cpus }} \
        -drive if=pflash,format=raw,readonly=on,file={{ efi_code }} \
        -drive if=pflash,format=raw,file={{ qemu_dir }}/${name}-vars.fd \
        -drive file={{ qemu_dir }}/${name}-boot.qcow2,if=virtio,format=qcow2 \
        -drive file={{ qemu_dir }}/${name}-osd.qcow2,if=virtio,format=qcow2 \
        -cdrom "{{ iso_path }}" \
        -device virtio-rng-pci \
        -nic vmnet-shared,mac="$mac" \
        -display none -serial null -monitor null \
        -daemonize
      pgrep -f "qemu-system.*-name $name " > "$pidfile"
    done

    echo "  Waiting for VMs to get IPs..."
    all_found=false
    for attempt in $(seq 1 60); do
      sleep 3
      missing=0

      # Check control planes
      for i in $(seq 1 {{ cp_count }}); do
        mac="{{ mac_prefix_cp }}${i}"
        # Strip leading zeros from MAC octets to match DHCP lease format
        lease_mac=$(echo "$mac" | sed 's/:0\([0-9a-f]\)/:\1/g; s/^0\([0-9a-f]\)/\1/')
        ip=$(grep -B 2 "$lease_mac" /var/db/dhcpd_leases 2>/dev/null | grep ip_address | awk -F= '{print $2}' | head -1 || true)
        if [ -z "$ip" ]; then
          missing=$((missing + 1))
        fi
      done

      # Check workers
      for i in $(seq 1 {{ worker_count }}); do
        mac="{{ mac_prefix_worker }}${i}"
        # Strip leading zeros from MAC octets to match DHCP lease format
        lease_mac=$(echo "$mac" | sed 's/:0\([0-9a-f]\)/:\1/g; s/^0\([0-9a-f]\)/\1/')
        ip=$(grep -B 2 "$lease_mac" /var/db/dhcpd_leases 2>/dev/null | grep ip_address | awk -F= '{print $2}' | head -1 || true)
        if [ -z "$ip" ]; then
          missing=$((missing + 1))
        fi
      done

      if [ "$missing" -eq 0 ]; then
        all_found=true
        break
      fi
      echo "  Waiting for $missing VMs to get IPs... (attempt $attempt)"
    done

    # Print results
    for i in $(seq 1 {{ cp_count }}); do
      mac="{{ mac_prefix_cp }}${i}"
      lease_mac=$(echo "$mac" | sed 's/:0\([0-9a-f]\)/:\1/g; s/^0\([0-9a-f]\)/\1/')
      ip=$(grep -B 2 "$lease_mac" /var/db/dhcpd_leases 2>/dev/null | grep ip_address | awk -F= '{print $2}' | head -1 || echo "unknown")
      echo "  {{ cluster_prefix }}-cp-${i}: $ip"
    done
    for i in $(seq 1 {{ worker_count }}); do
      mac="{{ mac_prefix_worker }}${i}"
      lease_mac=$(echo "$mac" | sed 's/:0\([0-9a-f]\)/:\1/g; s/^0\([0-9a-f]\)/\1/')
      ip=$(grep -B 2 "$lease_mac" /var/db/dhcpd_leases 2>/dev/null | grep ip_address | awk -F= '{print $2}' | head -1 || echo "unknown")
      echo "  {{ cluster_prefix }}-worker-${i}: $ip"
    done

    if [ "$all_found" = "true" ]; then
      echo "=== All VMs started ==="
    else
      echo "=== WARNING: Some VMs did not get IPs ==="
      exit 1
    fi

[doc('Apply Talos config to all nodes')]
apply-config:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "=== Generating and applying Talos configs ==="

    # Collect IPs
    declare -a cp_ips=()
    declare -a worker_ips=()

    for i in $(seq 1 {{ cp_count }}); do
      mac="{{ mac_prefix_cp }}${i}"
      lease_mac=$(echo "$mac" | sed 's/:0\([0-9a-f]\)/:\1/g; s/^0\([0-9a-f]\)/\1/')
      ip=$(grep -B 2 "$lease_mac" /var/db/dhcpd_leases 2>/dev/null | grep ip_address | awk -F= '{print $2}' | head -1)
      cp_ips+=("$ip")
      echo "  CP $i: $ip"
    done

    for i in $(seq 1 {{ worker_count }}); do
      mac="{{ mac_prefix_worker }}${i}"
      lease_mac=$(echo "$mac" | sed 's/:0\([0-9a-f]\)/:\1/g; s/^0\([0-9a-f]\)/\1/')
      ip=$(grep -B 2 "$lease_mac" /var/db/dhcpd_leases 2>/dev/null | grep ip_address | awk -F= '{print $2}' | head -1)
      worker_ips+=("$ip")
      echo "  Worker $i: $ip"
    done

    endpoint="${cp_ips[0]}"

    # Generate Talos secrets
    if [ ! -f "{{ qemu_dir }}/secrets.yaml" ]; then
      echo "  Generating Talos secrets..."
      talosctl gen secrets -o "{{ qemu_dir }}/secrets.yaml"
    fi

    # Generate configs with install image from factory
    install_image="factory.talos.dev/installer/{{ talos_schematic }}:{{ talos_version }}"
    echo "  Generating Talos configs (installer: $install_image)..."

    # Write patch file for install disk
    patch_file=$(mktemp)
    printf 'machine:\n  install:\n    disk: /dev/vda\n    wipe: true\n' > "$patch_file"

    talosctl gen config "talos-test" "https://${endpoint}:6443" \
      --with-secrets "{{ qemu_dir }}/secrets.yaml" \
      --kubernetes-version "{{ kubernetes_version }}" \
      --install-image "$install_image" \
      --output "{{ qemu_dir }}/controlplane.yaml" \
      --output-types controlplane \
      --force \
      --config-patch "@${patch_file}"

    talosctl gen config "talos-test" "https://${endpoint}:6443" \
      --with-secrets "{{ qemu_dir }}/secrets.yaml" \
      --kubernetes-version "{{ kubernetes_version }}" \
      --install-image "$install_image" \
      --output "{{ qemu_dir }}/worker.yaml" \
      --output-types worker \
      --force \
      --config-patch "@${patch_file}"

    rm -f "$patch_file"

    # Wait for Talos maintenance API
    echo "  Waiting for Talos maintenance API..."
    for attempt in $(seq 1 30); do
      if talosctl apply-config --insecure --nodes "${cp_ips[0]}" --file "{{ qemu_dir }}/controlplane.yaml" 2>/dev/null; then
        break
      fi
      echo "  Waiting... (attempt $attempt/30)"
      sleep 5
    done

    # Apply to remaining control planes (if more than 1)
    if [ {{ cp_count }} -gt 1 ]; then
      for i in $(seq 1 $(( {{ cp_count }} - 1 ))); do
        ip="${cp_ips[$i]}"
        echo "  Applying config to CP at $ip..."
        talosctl apply-config --insecure --nodes "$ip" --file "{{ qemu_dir }}/controlplane.yaml"
      done
    fi

    # Apply to workers
    for i in $(seq 0 $(( {{ worker_count }} - 1 ))); do
      ip="${worker_ips[$i]}"
      echo "  Applying config to worker at $ip..."
      talosctl apply-config --insecure --nodes "$ip" --file "{{ qemu_dir }}/worker.yaml"
    done

    # Set up talosctl context
    talosctl gen config "talos-test" "https://${endpoint}:6443" \
      --with-secrets "{{ qemu_dir }}/secrets.yaml" \
      --output "{{ qemu_dir }}/talosconfig" \
      --output-types talosconfig \
      --force
    cp "{{ qemu_dir }}/talosconfig" "{{ kubernetes_dir }}/talosconfig"
    talosctl config merge "{{ qemu_dir }}/talosconfig" 2>/dev/null || true
    talosctl config endpoint "$endpoint"
    talosctl config node "$endpoint"

    echo "=== Configs applied (nodes will reboot to install) ==="

[doc('Bootstrap Kubernetes on the cluster')]
bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "=== Bootstrapping Kubernetes ==="
    endpoint=$(talosctl config info 2>&1 | grep Endpoints | awk '{print $2}')

    echo "  Waiting for Talos API on $endpoint..."
    for attempt in $(seq 1 60); do
      if talosctl version --nodes "$endpoint" > /dev/null 2>&1; then
        echo "  Talos API ready"
        break
      fi
      echo "  Waiting... (attempt $attempt/60)"
      sleep 10
    done

    echo "  Running bootstrap..."
    for attempt in $(seq 1 30); do
      op=$(talosctl bootstrap 2>&1 || true)
      if echo "$op" | grep -q "AlreadyExists"; then
        echo "  Already bootstrapped"
        break
      fi
      if [ -z "$(echo "$op" | grep -i 'error')" ]; then
        echo "  Bootstrap initiated"
        break
      fi
      echo "  Bootstrap not ready, retrying in 10s..."
      sleep 10
    done

    echo "  Fetching kubeconfig..."
    for attempt in $(seq 1 30); do
      if talosctl kubeconfig -f --force-context-name talos-test "{{ kubernetes_dir }}/kubeconfig" > /dev/null 2>&1; then
        echo "  Kubeconfig fetched"
        break
      fi
      sleep 10
    done

    echo "  Waiting for all nodes to be Ready..."
    total=$(( {{ cp_count }} + {{ worker_count }} ))
    for attempt in $(seq 1 90); do
      ready=$(KUBECONFIG="{{ kubernetes_dir }}/kubeconfig" kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
      ready=${ready:-0}
      if [ "$ready" -eq "$total" ]; then
        echo "  All $total nodes Ready"
        break
      fi
      echo "  $ready/$total nodes ready (attempt $attempt/90)"
      sleep 10
    done

    KUBECONFIG="{{ kubernetes_dir }}/kubeconfig" kubectl get nodes -o wide
    echo "=== Kubernetes bootstrapped ==="

[doc('Fetch kubeconfig')]
kubeconfig:
    talosctl kubeconfig -f --force-context-name talos-test "{{ kubernetes_dir }}/kubeconfig"

[doc('Destroy all QEMU test VMs')]
destroy:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Destroying QEMU test cluster ==="
    for pid in $(pgrep -f "qemu-system.*-name {{ cluster_prefix }}" || true); do
      name=$(ps -p "$pid" -o args= 2>/dev/null | sed -n 's/.*-name \([^ ]*\).*/\1/p')
      echo "  Killing $name (PID $pid)..."
      sudo kill "$pid" 2>/dev/null || true
    done
    rm -f "{{ qemu_dir }}"/*.pid
    rm -f "{{ kubernetes_dir }}/kubeconfig" "{{ kubernetes_dir }}/talosconfig"
    rm -f "{{ qemu_dir }}"/*.qcow2 "{{ qemu_dir }}"/*.fd
    rm -f "{{ qemu_dir }}/controlplane.yaml" "{{ qemu_dir }}/worker.yaml"
    rm -f "{{ qemu_dir }}/talosconfig" "{{ qemu_dir }}/secrets.yaml"
    echo "=== Cluster destroyed ==="

[doc('Stop all VMs (preserves disk state)')]
stop:
    #!/usr/bin/env bash
    for pid in $(pgrep -f "qemu-system.*-name {{ cluster_prefix }}" || true); do
      name=$(ps -p "$pid" -o args= 2>/dev/null | sed -n 's/.*-name \([^ ]*\).*/\1/p')
      echo "  Stopping $name (PID $pid)..."
      sudo kill "$pid" 2>/dev/null || true
    done
    rm -f "{{ qemu_dir }}"/*.pid

[doc('Start stopped VMs')]
resume: start

[doc('Show VM status and IPs')]
status:
    #!/usr/bin/env bash
    echo "=== QEMU Test Cluster Status ==="

    for i in $(seq 1 {{ cp_count }}); do
      name="{{ cluster_prefix }}-cp-${i}"
      pidfile="{{ qemu_dir }}/${name}.pid"
      mac="{{ mac_prefix_cp }}${i}"
      lease_mac=$(echo "$mac" | sed 's/:0\([0-9a-f]\)/:\1/g; s/^0\([0-9a-f]\)/\1/')
      ip=$(grep -B 2 "$lease_mac" /var/db/dhcpd_leases 2>/dev/null | grep ip_address | awk -F= '{print $2}' | head -1 || echo "unknown")
      if pgrep -f "qemu-system.*-name $name " > /dev/null 2>&1; then
        echo "  $name: running ($ip)"
      else
        echo "  $name: stopped"
      fi
    done

    for i in $(seq 1 {{ worker_count }}); do
      name="{{ cluster_prefix }}-worker-${i}"
      mac="{{ mac_prefix_worker }}${i}"
      lease_mac=$(echo "$mac" | sed 's/:0\([0-9a-f]\)/:\1/g; s/^0\([0-9a-f]\)/\1/')
      ip=$(grep -B 2 "$lease_mac" /var/db/dhcpd_leases 2>/dev/null | grep ip_address | awk -F= '{print $2}' | head -1 || echo "unknown")
      if pgrep -f "qemu-system.*-name $name " > /dev/null 2>&1; then
        echo "  $name: running ($ip)"
      else
        echo "  $name: stopped"
      fi
    done

[doc('Download Talos ISO if not present')]
[private]
download-iso:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -f "{{ iso_path }}" ]; then
      echo "  Talos ISO already present"
      exit 0
    fi
    mkdir -p "{{ qemu_dir }}"
    echo "  Downloading Talos {{ talos_version }} ARM64 ISO (with random.trust_cpu=on)..."
    curl -sfL --retry 3 -o "{{ iso_path }}" \
      "https://factory.talos.dev/image/{{ talos_schematic }}/{{ talos_version }}/metal-arm64.iso"
    echo "  ISO downloaded"
