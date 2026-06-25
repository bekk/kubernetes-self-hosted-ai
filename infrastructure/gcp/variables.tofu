# ──────────────────────────────────────────────────────────────────────────────
# Project & location
# ──────────────────────────────────────────────────────────────────────────────

variable "project_id" {
  description = "GCP project ID where all resources are created."
  type        = string
}

variable "region" {
  description = "GCP region (used for provider default and regional resources)."
  type        = string
  default     = "europe-west4"
}

variable "zone" {
  description = <<-EOT
    GCP zone for the GKE cluster. We use a zonal cluster (not regional) because
    GPU availability is zone-specific and regional clusters would spread nodes
    across zones where GPUs may not be available.
  EOT
  type        = string
  default     = "europe-west4-a"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cluster identity
# ──────────────────────────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Name of the GKE cluster."
  type        = string
  default     = "ai-datacenter"
}

# ──────────────────────────────────────────────────────────────────────────────
# System node pool
# ──────────────────────────────────────────────────────────────────────────────
# Runs kube-system workloads, ingress controllers, monitoring, etc.
# No GPUs — just cheap, general-purpose VMs.
# ──────────────────────────────────────────────────────────────────────────────

variable "system_pool" {
  description = "Configuration for the system (non-GPU) node pool."
  type = object({
    machine_type   = optional(string, "e2-standard-4")
    min_node_count = optional(number, 1)
    max_node_count = optional(number, 3)
    disk_size_gb   = optional(number, 50)
  })
  default = {}
}

# ──────────────────────────────────────────────────────────────────────────────
# AI model node pools
# ──────────────────────────────────────────────────────────────────────────────
# Each entry in this map creates a dedicated GPU node pool. The map key is the
# model name (e.g. "gemma-4") and is used for labelling and naming.
#
# Key design decisions:
#   - min_nodes defaults to 0 → scale-to-zero when no inference traffic
#   - spot defaults to true    → up to 91% cheaper for interruptible workloads
#   - enabled flag             → disable a model without removing its config
# ──────────────────────────────────────────────────────────────────────────────

variable "models" {
  description = "Map of AI models, each getting a dedicated GPU node pool."
  type = map(object({
    enabled      = optional(bool, true)
    machine_type = string
    gpu_type     = string
    gpu_count    = optional(number, 1)
    min_nodes    = optional(number, 0)
    max_nodes    = optional(number, 2)
    spot         = optional(bool, true)
    disk_size_gb = optional(number, 200)
  }))
  default = {
    gemma-4 = {
      machine_type = "g2-standard-8" # 1×L4, 8 vCPU, 32 GiB
      gpu_type     = "nvidia-l4"
      gpu_count    = 1
    }
  }
}
