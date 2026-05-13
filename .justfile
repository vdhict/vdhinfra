#!/usr/bin/env -S just --justfile

set unstable := true
set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l

[doc('Run command for main cluster')]
main *args:
    export KUBECONFIG="{{ justfile_dir() }}/kubernetes/main/kubeconfig"; \
    export TALOSCONFIG="{{ justfile_dir() }}/kubernetes/main/talosconfig"; \
    just -f kubernetes/main/.justfile {{ args }}

[doc('Run command for test cluster (Docker)')]
test *args:
    export KUBECONFIG="{{ justfile_dir() }}/kubernetes/test/kubeconfig"; \
    export TALOSCONFIG="{{ justfile_dir() }}/kubernetes/test/talosconfig"; \
    just -f kubernetes/test/.justfile {{ args }}

[doc('Lint all YAML files')]
lint:
    yamllint -d "{extends: default, rules: {line-length: {max: 300}, truthy: {check-keys: false}, comments-indentation: disable, document-start: disable, braces: {max-spaces-inside: 1}}}" kubernetes/

[doc('Validate Kubernetes manifests')]
validate:
    find kubernetes/main -name "*.yaml" -not -name "*.sops.yaml" -not -path "*/config/*" -not -path "*/patches/*" | \
      xargs kubeconform -strict -ignore-missing-schemas -summary

[doc('Infrastructure operations CLI (changes, incidents, locks, CMDB)')]
ops *args:
    ./ops/ops {{ args }}
