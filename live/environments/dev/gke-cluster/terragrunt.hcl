# live/environments/dev/gke-cluster/terragrunt.hcl
#
# Creates a PRIVATE ZONAL GKE cluster for the dev environment.
#
# "Private" means:
#   - Nodes have NO public IPs (they reach the internet via Cloud NAT).
#   - The Kubernetes API (control plane) has a PUBLIC endpoint, but it is
#     restricted to specific CIDRs via master_authorized_networks.
#
# This gives you the security of private nodes while still being able to
# run `kubectl` from your laptop without a bastion or VPN.
#
# Dependency chain:
#   project → vpc → cloud-nat → gke-cluster (this file)

# ---------------------------------------------------------------------------
# 1. Include root config (provider, backend, common/env inputs)
# ---------------------------------------------------------------------------
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
  # expose = true lets us read include.root.locals.* below.
  # We use it here to keep the option open; in this file we read YAML
  # directly into our own locals block instead (both approaches work).
}

# ---------------------------------------------------------------------------
# 2. Source module — the community "private-cluster" submodule
# ---------------------------------------------------------------------------
# Why "private-cluster" and not the root module?
#   The root module (terraform-google-modules/kubernetes-engine) supports
#   private clusters too, but the //modules/private-cluster submodule turns
#   on private-node defaults for you, making intent explicit.
#
# Why not "safer-cluster"?
#   safer-cluster is very opinionated (e.g. forces Binary Authorization,
#   intranode visibility, network policies). Great for prod, but it
#   requires several IAM and org-policy preconditions that add complexity.
#   We'll upgrade to safer-cluster when we do prod.
terraform {
  source = "git::https://github.com/terraform-google-modules/terraform-google-kubernetes-engine.git//modules/private-cluster?ref=v44.0.0"
}

# ---------------------------------------------------------------------------
# 3. Dependencies — outputs from upstream units
# ---------------------------------------------------------------------------
dependency "project" {
  config_path = "../project"
  mock_outputs = {
    project_id = "mock-project-id"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "fmt"]
}

dependency "vpc" {
  config_path = "../networking/vpc"
  mock_outputs = {
    network_name  = "mock-network"
    subnets_names = ["mock-subnet"]
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "fmt"]
}

# Cloud NAT isn't referenced in any input, but we declare the dependency
# so Terragrunt applies NAT *before* the cluster. Without NAT, private
# nodes can't pull container images and pods will fail to start.
dependency "cloud_nat" {
  config_path  = "../networking/cloud-nat"
  skip_outputs = true # we don't need any outputs from NAT
}

# ---------------------------------------------------------------------------
# 4. Locals — build names and read YAML
# ---------------------------------------------------------------------------
locals {
  common_vars = yamldecode(file("${get_parent_terragrunt_dir()}/common.yaml"))
  env_vars    = yamldecode(file(find_in_parent_folders("env.yaml")))

  env    = local.env_vars.environment       # "dev"
  app    = local.common_vars.app_name       # "omnifeed"
  region = local.common_vars.default_region # "europe-west1"

  # Subnet and secondary range names must match what the vpc unit creates.
  subnet_name     = "${local.app}-${local.env}-gke-subnet"
  pods_range_name = "${local.subnet_name}-pods"
  svc_range_name  = "${local.subnet_name}-services"
}

# ---------------------------------------------------------------------------
# 5. Inputs — every field is annotated with WHY
# ---------------------------------------------------------------------------
inputs = {
  # --- Identity ---
  project_id = dependency.project.outputs.project_id
  name       = "${local.app}-${local.env}-cluster"

  # --- Location ---
  # regional = false → zonal cluster. Cheaper for dev because you get one
  # control plane replica instead of three. Trade-off: if europe-west1-b has
  # a zone outage, the cluster is unreachable. Acceptable for dev.
  regional = false
  zones    = [local.env_vars.gke_zone]

  # --- Networking ---
  network           = dependency.vpc.outputs.network_name
  subnetwork        = local.subnet_name
  ip_range_pods     = local.pods_range_name
  ip_range_services = local.svc_range_name

  # --- Private cluster settings ---
  # enable_private_nodes: nodes get internal IPs only → no direct SSH from
  #   the internet, no scanning. Egress goes via Cloud NAT.
  enable_private_nodes = true
  # enable_private_endpoint: false = the k8s API has a PUBLIC IP (restricted
  #   by master_authorized_networks below). Set true in prod for full lockdown.
  enable_private_endpoint = false

  # The control plane gets its own /28 VPC-peered range. This MUST NOT overlap
  # with any subnet in your VPC. 172.16.0.0/28 is the conventional choice.
  master_ipv4_cidr_block = "172.16.0.0/28"

  # master_authorized_networks: who can reach the k8s API.
  # IMPORTANT: replace the CIDR in env.yaml with your real public IP.
  # Run: curl -s https://icanhazip.com
  master_authorized_networks = [
    {
      cidr_block   = local.env_vars.master_authorized_cidr
      display_name = "Home / office"
    },
  ]

  # --- Node pool ---
  # Best practice: delete the default node pool and create a dedicated one.
  # The default pool can't be fully configured and can't be resized to 0.
  remove_default_node_pool = true

  node_pools = [
    {
      name         = "general"
      machine_type = local.env_vars.machine_type # e2-standard-2

      # --- Autoscaling ---
      # autoscaling = true enables the Cluster Autoscaler for this pool.
      # It watches for pods stuck in Pending (not enough CPU/memory) and
      # adds nodes up to max_count. When demand drops, it drains and
      # removes idle nodes down to min_count.
      #
      # initial_node_count = how many nodes to start with (optional,
      # defaults to min_count if omitted).
      autoscaling        = true
      min_count          = local.env_vars.gke_min_node_count # 1
      max_count          = local.env_vars.gke_max_node_count # 3
      initial_node_count = local.env_vars.gke_min_node_count # start small

      # Disk: pd-standard is cheaper; pd-ssd for latency-sensitive workloads.
      disk_type    = "pd-standard"
      disk_size_gb = 50

      # auto_repair: GKE automatically rebuilds unhealthy nodes.
      # auto_upgrade: GKE rolls nodes to the latest patch version.
      # Both are best practice — keep them on.
      auto_repair  = true
      auto_upgrade = true

      # Preemptible / Spot nodes are ~60-80% cheaper but can be reclaimed at
      # any time (max 24h). Excellent for dev workloads that tolerate restarts.
      # Set to false if you need stable long-running pods in dev.
      preemptible = true

      # GKE_METADATA = enable GKE Metadata Server on nodes.
      # This is required for Workload Identity to work.
      node_metadata = "GKE_METADATA"
    },
    {
      # Dedicated pool for GitHub Actions self-hosted runners.
      # Runners are isolated from app workloads via node taint (below).
      # Scale-to-zero: min_count=0 means no cost when CI is idle.
      # NOT preemptible — CI jobs must not be interrupted mid-build.
      name         = "runner"
      machine_type = "e2-standard-4" # 4 vCPU, 16 GB — comfortable for Docker builds

      autoscaling        = true
      min_count          = 0 # scale to zero when idle
      max_count          = 5
      initial_node_count = 0

      disk_type    = "pd-ssd" # faster I/O for Docker layer caching
      disk_size_gb = 100      # Docker images can be large

      auto_repair  = true
      auto_upgrade = true
      preemptible  = false # runners must not be preempted mid-job

      node_metadata = "GKE_METADATA" # required for Workload Identity (AR push)
    },
  ]

  # Labels applied to node VMs — useful for cost attribution and filtering.
  node_pools_labels = {
    all = {}
    general = {
      environment = local.env
      workload    = "app"
    }
    runner = {
      environment = local.env
      workload    = "ci"
    }
  }

  # OAuth scopes — "cloud-platform" is the broadest scope. Access is then
  # controlled by IAM roles on the node's service account, not by scopes.
  # This is the recommended pattern (don't limit access via scopes).
  node_pools_oauth_scopes = {
    all = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  # Tags: applied as network tags on node VMs. Useful for firewall rules.
  node_pools_tags = {
    all     = []
    general = ["gke-${local.env}-node"]
    runner  = ["gke-${local.env}-runner"]
  }

  # Taints: only pods that explicitly tolerate workload=ci can land on runner nodes.
  # This prevents accidental app scheduling on expensive runner machines.
  node_pools_taints = {
    all     = []
    general = []
    runner = [
      {
        key    = "workload"
        value  = "ci"
        effect = "NO_SCHEDULE"
      },
    ]
  }

  # --- Cluster features ---

  # Horizontal Pod Autoscaler — lets Deployments scale on CPU/memory/custom
  # metrics. Always enable; no cost when idle.
  horizontal_pod_autoscaling = true

  # HTTP load balancing: installs the GKE Ingress controller so you can
  # create Ingress resources that provision Google Cloud Load Balancers.
  http_load_balancing = true

  # Network Policy: enables Calico-based NetworkPolicy enforcement.
  # Lets you write "only pod A can talk to pod B on port 443" rules.
  # Small performance cost; worth it for security learning.
  network_policy = true

  # Logging & monitoring — send to Cloud Logging / Cloud Monitoring.
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  # Release channel: REGULAR gets new k8s versions after they've baked in
  # RAPID for a few weeks. Good balance of freshness vs stability.
  release_channel = "REGULAR"

  # Maintenance window: 03:00–07:00 UTC on weekdays. GKE may briefly
  # disrupt the control plane during upgrades; pick a low-traffic window.
  maintenance_start_time = "2024-01-01T03:00:00Z"
  maintenance_end_time   = "2024-01-01T07:00:00Z"
  maintenance_recurrence = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"

  # deletion_protection: prevents accidental `terraform destroy` from
  # deleting the cluster. Set false for dev (easy teardown); true for prod.
  deletion_protection = false
}
