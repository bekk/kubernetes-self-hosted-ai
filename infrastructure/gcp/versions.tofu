# ──────────────────────────────────────────────────────────────────────────────
# Provider & OpenTofu version constraints
# ──────────────────────────────────────────────────────────────────────────────
# State is local by default so `make up` works from a fresh clone. For a team,
# switch to the GCS backend below so everyone shares one state.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.8"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # backend "gcs" {
  #   bucket = "my-tofu-state-bucket"
  #   prefix = "ai-datacenter/infrastructure"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
