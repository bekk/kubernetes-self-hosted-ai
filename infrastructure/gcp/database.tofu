# ──────────────────────────────────────────────────────────────────────────────
# Cloud SQL for PostgreSQL
# ──────────────────────────────────────────────────────────────────────────────
# Shared by LiteLLM (keys, budgets, spend logs), Open WebUI (users, chats)
# and kagent (agent sessions).
# Private IP only; reachable from the cluster through Private Service Access.
# ──────────────────────────────────────────────────────────────────────────────

# Cloud SQL reserves a deleted instance's name for about a week, so a random
# suffix keeps `make down && make up` rehearsals working.
resource "random_id" "db_suffix" {
  byte_length = 3
}

resource "google_sql_database_instance" "main" {
  name             = "${var.cluster_name}-${random_id.db_suffix.hex}"
  database_version = "POSTGRES_17"
  region           = var.region

  settings {
    tier              = var.database_tier
    edition           = "ENTERPRISE"
    availability_type = "ZONAL"

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }

    backup_configuration {
      enabled = true
    }
  }

  deletion_protection = var.deletion_protection

  depends_on = [google_service_networking_connection.private_services]
}

locals {
  databases = toset(["litellm", "openwebui", "kagent"])
}

resource "google_sql_database" "app" {
  for_each = local.databases

  name     = each.value
  instance = google_sql_database_instance.main.name

  # The apps' tables can't be dropped cleanly; the instance goes anyway.
  deletion_policy = "ABANDON"
}

resource "random_password" "db" {
  for_each = local.databases

  length  = 32
  special = false
}

resource "google_sql_user" "app" {
  for_each = local.databases

  name     = each.value
  instance = google_sql_database_instance.main.name
  password = random_password.db[each.value].result

  # The user owns the apps' tables, so DROP ROLE fails on destroy.
  deletion_policy = "ABANDON"
}
