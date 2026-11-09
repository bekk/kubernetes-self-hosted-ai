# ══════════════════════════════════════════════════════════════════════════════
# GKE Cluster — AI Inference Datacenter
# ══════════════════════════════════════════════════════════════════════════════

locals {
  models = {
    for key, model in yamldecode(file("${path.module}/${var.models_file}")).models :
    key => model if try(model.enabled, true)
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Node service account
# ──────────────────────────────────────────────────────────────────────────────
# Nodes run as a minimal service account rather than the default compute SA.
# ──────────────────────────────────────────────────────────────────────────────

resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE nodes for ${var.cluster_name}"

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cluster control plane
# ──────────────────────────────────────────────────────────────────────────────

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone # Zonal cluster — GPU capacity is per zone

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.nodes.id

  # We manage our own pools below. The throwaway default pool still uses our
  # SA, since org policies often disable the default compute SA.
  remove_default_node_pool = true
  initial_node_count       = 1

  node_config {
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Private nodes, public (but authenticated) control plane.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  dynamic "master_authorized_networks_config" {
    for_each = length(var.authorized_networks) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.authorized_networks
        content {
          cidr_block = cidr_blocks.value
        }
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # REGULAR is well past the minimum versions B200 (1.32.7) and
  # RTX PRO 6000 (1.34.0) node pools need.
  release_channel {
    channel = "REGULAR"
  }

  # Upgrades drain nodes, and on an 8× B200 node that means a 10–30 minute
  # model reload. Restrict them to weekend nights, and freeze them entirely
  # around important dates (e.g. a live demo) via var.upgrade_freezes.
  maintenance_policy {
    recurring_window {
      start_time = "2026-01-03T00:00:00Z"
      end_time   = "2026-01-03T06:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }

    dynamic "maintenance_exclusion" {
      for_each = var.upgrade_freezes
      content {
        exclusion_name = maintenance_exclusion.key
        start_time     = maintenance_exclusion.value.start
        end_time       = maintenance_exclusion.value.end
        exclusion_options {
          scope = "NO_MINOR_OR_NODE_UPGRADES"
        }
      }
    }
  }

  deletion_protection = var.deletion_protection

  # node_config only shapes the default pool, which is deleted right after
  # creation; don't let it show up as drift.
  lifecycle {
    ignore_changes = [node_config]
  }

  depends_on = [google_project_service.apis, google_project_iam_member.nodes]
}

# ──────────────────────────────────────────────────────────────────────────────
# System node pool
# ──────────────────────────────────────────────────────────────────────────────
# Runs LiteLLM, Open WebUI and kube-system. No GPUs.
# ──────────────────────────────────────────────────────────────────────────────

resource "google_container_node_pool" "system" {
  name    = "system"
  cluster = google_container_cluster.primary.id

  autoscaling {
    min_node_count = var.system_pool.min_node_count
    max_node_count = var.system_pool.max_node_count
  }

  node_config {
    machine_type    = var.system_pool.machine_type
    disk_size_gb    = var.system_pool.disk_size_gb
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      "ai.bekk.no/role" = "system"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  depends_on = [google_project_iam_member.nodes]
}
