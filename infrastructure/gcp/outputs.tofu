# ──────────────────────────────────────────────────────────────────────────────
# Outputs — consumed by the platform stack via terraform_remote_state
# ──────────────────────────────────────────────────────────────────────────────

output "project_id" {
  value = var.project_id
}

output "zone" {
  value = var.zone
}

output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  value     = google_container_cluster.primary.endpoint
  sensitive = true
}

output "cluster_ca_certificate" {
  value     = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "get_credentials_command" {
  description = "Configure kubectl for the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${var.zone} --project ${var.project_id}"
}

output "database_host" {
  value = google_sql_database_instance.main.private_ip_address
}

output "database_credentials" {
  description = "Per-application database name, user and password."
  value = {
    for db in local.databases : db => {
      database = google_sql_database.app[db].name
      username = google_sql_user.app[db].name
      password = random_password.db[db].result
    }
  }
  sensitive = true
}

output "model_node_pools" {
  description = "Map of model key to its GKE node pool name."
  value       = { for k, pool in google_container_node_pool.model : k => pool.name }
}

output "kube_context" {
  description = "kubectl context name created by get_credentials_command."
  value       = "gke_${var.project_id}_${var.zone}_${google_container_cluster.primary.name}"
}
