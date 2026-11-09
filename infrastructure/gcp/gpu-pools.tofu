# ──────────────────────────────────────────────────────────────────────────────
# Accelerator node pools — one per enabled model in models.yaml
# ──────────────────────────────────────────────────────────────────────────────
# `node.accelerator` is "gpu" (default) or "tpu". For TPUs, the machine type
# (e.g. ct6e-standard-8t) implies the chips; GKE labels the node with its TPU
# type and topology, and the vLLM chart selects on those.
#
# The label "ai.bekk.no/model" is what the vLLM Deployment's nodeSelector
# targets. GKE adds the nvidia.com/gpu / google.com/tpu NoSchedule taint
# automatically, which keeps everything except accelerator workloads off these
# (very expensive) nodes.
#
# Pools start at 0 nodes; the cluster autoscaler adds a node as soon as the
# model's pod is pending, and removes it again when the Deployment is scaled
# to 0 replicas.
# ──────────────────────────────────────────────────────────────────────────────

resource "google_container_node_pool" "model" {
  for_each = local.models

  name    = "model-${each.key}"
  cluster = google_container_cluster.primary.id

  # Accelerators live in specific zones (e.g. TPU v6e only in europe-west4-a),
  # so a pool may sit in a different zone of the region than the cluster.
  node_locations = try(each.value.node.zone, null) != null ? [each.value.node.zone] : null

  initial_node_count = 0

  autoscaling {
    min_node_count = try(each.value.node.min_nodes, 0)
    max_node_count = try(each.value.node.max_nodes, 1)
    # Flex-start provisions wherever DWS finds capacity; required by GKE.
    location_policy = try(each.value.node.flex_start, false) ? "ANY" : null
  }

  node_config {
    machine_type = each.value.node.machine_type
    spot         = try(each.value.node.spot, false)

    # Dynamic Workload Scheduler flex-start: GKE queues the scale-up until
    # capacity is found, instead of failing with a stockout. Nodes live for
    # at most 7 days, then get recycled.
    flex_start = try(each.value.node.flex_start, false) ? true : null

    # A4 (B200), G4 (RTX PRO 6000) and TPU v6e support Hyperdisk.
    disk_type    = "hyperdisk-balanced"
    disk_size_gb = var.gpu_boot_disk_size_gb
    image_type   = "COS_CONTAINERD"

    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Third-generation machine series require gVNIC.
    gvnic {
      enabled = true
    }

    dynamic "guest_accelerator" {
      for_each = try(each.value.node.accelerator, "gpu") == "gpu" ? [1] : []
      content {
        type  = each.value.node.gpu_type
        count = each.value.node.gpu_count

        gpu_driver_installation_config {
          gpu_driver_version = "LATEST"
        }
      }
    }

    labels = {
      "ai.bekk.no/model" = each.key
      "ai.bekk.no/tier"  = each.value.tier
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # B200 capacity in Europe is reservation-backed in practice. Set
    # `node.reservation` in models.yaml to pin a pool to your reservation,
    # or `node.flex_start` to queue for capacity without one.
    dynamic "reservation_affinity" {
      for_each = try(each.value.node.reservation, "") != "" ? [each.value.node.reservation] : []
      content {
        consume_reservation_type = "SPECIFIC_RESERVATION"
        key                      = "compute.googleapis.com/reservation-name"
        values                   = [reservation_affinity.value]
      }
    }

    dynamic "reservation_affinity" {
      for_each = try(each.value.node.flex_start, false) ? [1] : []
      content {
        consume_reservation_type = "NO_RESERVATION"
      }
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Node upgrades on an 8× B200 node mean a full model reload; do them one at
  # a time and never surge (a second 8-GPU node is rarely available).
  # Flex-start pools use GKE's own SHORT_LIVED strategy, so leave them alone.
  dynamic "upgrade_settings" {
    for_each = try(each.value.node.flex_start, false) ? [] : [1]
    content {
      max_surge       = 0
      max_unavailable = 1
    }
  }

  depends_on = [google_project_iam_member.nodes]

  lifecycle {
    # GKE fills these in server-side (flex-start's 7-day node lifetime, the
    # local SSDs bundled with A4, threads_per_core on TPU hosts); ignoring
    # them avoids replacing the pool on every apply.
    ignore_changes = [
      node_config[0].max_run_duration,
      node_config[0].ephemeral_storage_local_ssd_config,
      node_config[0].advanced_machine_features,
    ]

    precondition {
      condition     = !(try(each.value.node.flex_start, false) && try(each.value.node.reservation, "") != "")
      error_message = "Model ${each.key}: set either node.reservation or node.flex_start, not both."
    }
  }
}
