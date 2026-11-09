# ──────────────────────────────────────────────────────────────────────────────
# Project & location
# ──────────────────────────────────────────────────────────────────────────────

variable "project_id" {
  description = "GCP project ID where all resources are created."
  type        = string
}

variable "region" {
  description = "GCP region for the network, Cloud SQL and the cluster."
  type        = string
  default     = "europe-west4"
}

variable "zone" {
  description = <<-EOT
    GCP zone for the GKE cluster. Zonal on purpose: GPU capacity is per zone.
    europe-west4-b (Eemshaven, NL) is the only European zone offering B200,
    GB200, H100 and RTX PRO 6000 together. europe-north1-c (Hamina, FI) is
    closer to Oslo and has B200 + RTX PRO 6000, but far less capacity.
  EOT
  type        = string
  default     = "europe-west4-b"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cluster
# ──────────────────────────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Name of the GKE cluster (also used as a prefix for related resources)."
  type        = string
  default     = "ai-datacenter"
}

variable "authorized_networks" {
  description = "CIDR blocks allowed to reach the Kubernetes API. Empty = any (still requires Google auth)."
  type        = list(string)
  default     = []
}

variable "deletion_protection" {
  description = "Protect the cluster and database from `tofu destroy`. Enable outside of demos."
  type        = bool
  default     = false
}

variable "system_pool" {
  description = "The CPU-only pool that runs LiteLLM, Open WebUI and cluster add-ons."
  type = object({
    machine_type   = optional(string, "e2-standard-8")
    min_node_count = optional(number, 1)
    max_node_count = optional(number, 3)
    disk_size_gb   = optional(number, 100)
  })
  default = {}
}

variable "gpu_boot_disk_size_gb" {
  description = "Boot disk size for GPU nodes. Model weights live on PVCs, so this only holds images."
  type        = number
  default     = 200
}

variable "models_file" {
  description = "Path to the shared model catalogue."
  type        = string
  default     = "../../models.yaml"
}

# ──────────────────────────────────────────────────────────────────────────────
# Database
# ──────────────────────────────────────────────────────────────────────────────

variable "database_tier" {
  description = "Cloud SQL machine tier for the LiteLLM + Open WebUI database."
  type        = string
  default     = "db-custom-2-8192"
}

variable "upgrade_freezes" {
  description = <<-EOT
    Windows in which GKE must not upgrade nodes (max 32 days each), keyed by
    name. Times are RFC 3339. Example:
      upgrade_freezes = { demo = { start = "2026-11-13T00:00:00Z", end = "2026-11-21T00:00:00Z" } }
  EOT
  type = map(object({
    start = string
    end   = string
  }))
  default = {}
}
