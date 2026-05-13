FROM python:3.12-alpine

ARG KUBECTL_VERSION=v1.35.3
ARG GITLEAKS_VERSION=8.21.2
ARG TARGETARCH=amd64

RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      git \
      openssh-client \
      openssl \
      jq \
      mosquitto-clients \
      tzdata \
 && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
      -o /usr/local/bin/kubectl \
 && chmod +x /usr/local/bin/kubectl \
 && curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
      | tar -xz -C /usr/local/bin gitleaks \
 && chmod +x /usr/local/bin/gitleaks \
 && adduser -D -u 1000 health

# No python deps beyond stdlib — keeps the image small and avoids supply-chain risk.
# All scripts use urllib + subprocess.

USER health
WORKDIR /home/health
ENV PYTHONUNBUFFERED=1 \
    TZ=Europe/Amsterdam

ENTRYPOINT ["/bin/sh", "-c"]
CMD ["echo 'cluster-health image — invoked via CronJob commands'"]
