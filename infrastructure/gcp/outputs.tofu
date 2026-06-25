# ──────────────────────────────────────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────────────────────────────────────

output "cluster_endpoint" {
  description = "The IP address of the GKE cluster's Kubernetes API server."
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate for the cluster's API server."
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.primary.name
}

output "get_credentials_command" {
  description = "Run this command to configure kubectl for the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${var.zone} --project ${var.project_id}"
}

# Map of model name → node pool name, useful for downstream tooling that
# needs to reference specific pools (e.g. for drain / cordon scripts).
output "model_node_pools" {
  description = "Map of model name to its GKE node pool name."
  value       = { for k, pool in google_container_node_pool.model : k => pool.name }
}
