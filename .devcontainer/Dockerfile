FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TERRAGRUNT_VERSION=v0.99.2
ENV TFDOCS_VERSION=v0.21.0
ENV K9S_VERSION=v0.32.7
ENV HELM_VERSION=v3.16.3
ENV KUSTOMIZE_VERSION=v5.5.0

# ---------------------------------------------------------------------------
# Multi-arch support
# ---------------------------------------------------------------------------
# TARGETARCH is set automatically by Docker BuildKit (amd64 or arm64).
# We map it to the naming conventions each tool uses in its download URL.
#   amd64 → amd64   (most tools)
#   arm64 → arm64    (most tools)
# Google Cloud apt repo handles arch automatically, Terraform/HashiCorp too.
# We only need TARGETARCH for the GitHub-released Go binaries.
ARG TARGETARCH

# 1. Install base tools, ZSH, and pipx
RUN apt-get update && apt-get install -y \
  curl \
  wget \
  git \
  sudo \
  zsh \
  python3 \
  pipx \
  apt-transport-https \
  ca-certificates \
  gnupg \
  lsb-release \
  && rm -rf /var/lib/apt/lists/*

# 2. Install Google Cloud CLI + kubectl + GKE auth plugin
# The Google apt repo auto-detects architecture — works on both amd64 and arm64.
RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && \
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
  apt-get update && apt-get install -y \
    google-cloud-cli \
    google-cloud-cli-gke-gcloud-auth-plugin \
    kubectl

# 3. Install Terraform (HashiCorp apt repo handles arch automatically)
RUN wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && \
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list && \
  apt-get update && apt-get install -y terraform

# 4. Install Terragrunt & terraform-docs (arch-aware)
RUN curl -Lo /usr/local/bin/terragrunt \
    https://github.com/gruntwork-io/terragrunt/releases/download/${TERRAGRUNT_VERSION}/terragrunt_linux_${TARGETARCH} && \
  chmod +x /usr/local/bin/terragrunt && \
  curl -Lo /tmp/terraform-docs.tar.gz \
    https://github.com/terraform-docs/terraform-docs/releases/download/${TFDOCS_VERSION}/terraform-docs-${TFDOCS_VERSION}-linux-${TARGETARCH}.tar.gz && \
  tar -xzf /tmp/terraform-docs.tar.gz -C /usr/local/bin terraform-docs && \
  chmod +x /usr/local/bin/terraform-docs && \
  rm /tmp/terraform-docs.tar.gz

# 5. Install k9s — terminal UI for Kubernetes (arch-aware)
# k9s uses "arm64" for ARM and "amd64" for x86 in its release names.
RUN curl -Lo /tmp/k9s.tar.gz \
    https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${TARGETARCH}.tar.gz && \
  tar -xzf /tmp/k9s.tar.gz -C /usr/local/bin k9s && \
  chmod +x /usr/local/bin/k9s && \
  rm /tmp/k9s.tar.gz

# 6. Install Helm — the Kubernetes package manager (arch-aware)
RUN curl -Lo /tmp/helm.tar.gz \
    https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz && \
  tar -xzf /tmp/helm.tar.gz -C /tmp && \
  mv /tmp/linux-${TARGETARCH}/helm /usr/local/bin/helm && \
  chmod +x /usr/local/bin/helm && \
  rm -rf /tmp/helm.tar.gz /tmp/linux-${TARGETARCH}

# 7. Install Kustomize — template-free Kubernetes manifest customization (arch-aware)
# Kustomize lets you overlay/patch K8s manifests without forking them.
# Useful for per-environment diffs (dev vs prod) without Helm charts.
RUN curl -Lo /tmp/kustomize.tar.gz \
    https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${TARGETARCH}.tar.gz && \
  tar -xzf /tmp/kustomize.tar.gz -C /usr/local/bin kustomize && \
  chmod +x /usr/local/bin/kustomize && \
  rm /tmp/kustomize.tar.gz

# 8. Grant passwordless sudo
RUN echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# 9. Switch to ubuntu user BEFORE installing Oh My Zsh.
# Pre-create .config so Docker doesn't create it as root when it sets up the
# ~/.config/gcloud bind mount — that would block helm from writing ~/.config/helm.
USER ubuntu
RUN mkdir -p /home/ubuntu/.config /home/ubuntu/.kube /home/ubuntu/.cache

# 10. Install Oh My Zsh and plugins
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended && \
  git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions && \
  git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting

# 11. Enable plugins in .zshrc
# kubectl: adds completion + aliases (k=kubectl, kgp=kubectl get pods, etc.)
# helm: adds completion for helm commands
# kustomize: adds completion for kustomize commands
RUN sed -i 's/plugins=(git)/plugins=(git terraform gcloud kubectl helm zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc

# 12. Custom aliases and environment
RUN cat >> ~/.zshrc <<'EOF'

# --- Kubernetes aliases ---
alias k="kubectl"
alias kgp="kubectl get pods"
alias kgs="kubectl get svc"
alias kgd="kubectl get deployments"
alias kgn="kubectl get nodes"
alias kga="kubectl get all"
alias kns="kubectl config set-context --current --namespace"  # usage: kns my-namespace
alias kctx="kubectl config get-contexts"
alias kdp="kubectl describe pod"
alias kds="kubectl describe svc"
alias kdd="kubectl describe deployment"
alias kl="kubectl logs"
alias klf="kubectl logs -f"                                   # follow logs
alias kex="kubectl exec -it"                                  # usage: kex pod-name -- /bin/sh
alias kaf="kubectl apply -f"                                  # usage: kaf manifest.yaml
alias kdf="kubectl delete -f"                                 # usage: kdf manifest.yaml

# --- Helm aliases ---
alias hls="helm list -A"                                      # list all releases
alias hst="helm status"

# --- Terragrunt auto-completion ---
complete -C /usr/bin/terraform terragrunt
EOF

# GKE auth plugin env var — tells kubectl to use the new plugin-based
# authentication instead of the deprecated built-in gcloud auth.
ENV USE_GKE_GCLOUD_AUTH_PLUGIN=True
ENV PATH="/home/ubuntu/.local/bin:${PATH}"
