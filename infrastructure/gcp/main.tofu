# ══════════════════════════════════════════════════════════════════════════════
# GKE Cluster — AI Inference Datacenter
# ══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# Cluster control plane
# ──────────────────────────────────────────────────────────────────────────────
# We immediately remove the default node pool and manage our own pools below.
# Workload Identity is enabled so pods can authenticate to GCP APIs without
# static service-account keys.
# ──────────────────────────────────────────────────────────────────────────────

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone # Zonal cluster — GPU quota is per-zone

  # We don't want the default pool; we'll create purpose-built pools below.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Workload Identity lets Kubernetes service accounts act as GCP service
  # accounts, eliminating the need for exported key files.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # REGULAR channel gives us a good balance between stability and freshness.
  release_channel {
    channel = "REGULAR"
  }

  # Disabled for dev/iteration speed — enable in production!
  deletion_protection = false
}

# ──────────────────────────────────────────────────────────────────────────────
# System node pool
# ──────────────────────────────────────────────────────────────────────────────
# Runs cluster infrastructure: kube-system pods, ingress controllers,
# monitoring agents, etc. No GPUs needed here — just reliable compute.
# ──────────────────────────────────────────────────────────────────────────────

resource "google_container_node_pool" "system" {
  name    = "system"
  cluster = google_container_cluster.primary.id

  autoscaling {
    min_node_count = var.system_pool.min_node_count
    max_node_count = var.system_pool.max_node_count
  }

  node_config {
    machine_type = var.system_pool.machine_type
    disk_size_gb = var.system_pool.disk_size_gb
    image_type   = "COS_CONTAINERD"

    labels = {
      "ai.bekk.no/role" = "system"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# GPU node pools — one per enabled model
# ──────────────────────────────────────────────────────────────────────────────
# Each model in var.models gets its own node pool with dedicated GPU config.
# Pools start at 0 nodes (scale-to-zero) and autoscale based on pending pods.
#
# The label "ai.bekk.no/model" is used as a nodeSelector / nodeAffinity
# target so inference pods land on the correct hardware.
# ──────────────────────────────────────────────────────────────────────────────

resource "google_container_node_pool" "model" {
  for_each = { for k, v in var.models : k => v if v.enabled }

  name    = "model-${each.key}"
  cluster = google_container_cluster.primary.id

  # Start empty — the cluster autoscaler will provision nodes on demand.
  initial_node_count = 0

  autoscaling {
    min_node_count = each.value.min_nodes
    max_node_count = each.value.max_nodes
  }

  node_config {
    machine_type = each.value.machine_type
    spot         = each.value.spot
    disk_size_gb = each.value.disk_size_gb
    image_type   = "COS_CONTAINERD"

    # Attach GPUs and auto-install the latest NVIDIA drivers.
    guest_accelerator {
      type  = each.value.gpu_type
      count = each.value.gpu_count

      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    labels = {
      "ai.bekk.no/model" = each.key
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
