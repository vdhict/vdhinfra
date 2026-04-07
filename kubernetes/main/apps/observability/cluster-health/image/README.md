# cluster-health image

Multi-tool image used by the `cluster-health` CronJobs in the `observability` namespace.

Contains: `python3` (stdlib only), `kubectl`, `git`, `openssh-client`, `jq`, `curl`, `mosquitto-clients`, `tzdata`.

Built and published by `.github/workflows/build-cluster-health-image.yml` to:

```
ghcr.io/vdhict/cluster-health:<tag>
```

The CronJob manifests reference a pinned tag. Bump via PR (Renovate will pick up new tags automatically once the first tag is published).

## Building locally

```bash
docker build -t ghcr.io/vdhict/cluster-health:dev kubernetes/main/apps/observability/cluster-health/image/
```

## First-time bootstrap

The image must exist in GHCR before Flux can pull it. Either:

1. Push a tag (`v0.1.0`) on `main` after this directory lands — the GH Actions workflow builds and publishes.
2. Or build and push manually:

```bash
docker buildx build \
  --platform linux/amd64 \
  -t ghcr.io/vdhict/cluster-health:v0.1.0 \
  --push \
  kubernetes/main/apps/observability/cluster-health/image/
```
