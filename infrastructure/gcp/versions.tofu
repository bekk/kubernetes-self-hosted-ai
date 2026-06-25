# ──────────────────────────────────────────────────────────────────────────────
# Provider & OpenTofu version constraints
# ──────────────────────────────────────────────────────────────────────────────
# We use google-beta alongside google because some GKE features
# (e.g. GPU driver auto-install) are only available in the beta API.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Provider configuration
# ──────────────────────────────────────────────────────────────────────────────

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
