# ──────────────────────────────────────────────────────────────────────────────
# Provider & OpenTofu version constraints
# ──────────────────────────────────────────────────────────────────────────────
# This stack is applied *after* infrastructure/gcp. It reads that stack's
# outputs (cluster endpoint, database credentials) from its state, so the
# Kubernetes/Helm providers are always configured against a cluster that
# already exists.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.8"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # backend "gcs" {
  #   bucket = "my-tofu-state-bucket"
  #   prefix = "ai-datacenter/platform"
  # }
}

data "terraform_remote_state" "infrastructure" {
  backend = "local"
  config = {
    path = var.infrastructure_state_path
  }

  # With the GCS backend:
  # backend = "gcs"
  # config  = { bucket = "my-tofu-state-bucket", prefix = "ai-datacenter/infrastructure" }
}

locals {
  infra = data.terraform_remote_state.infrastructure.outputs
}

provider "google" {
  project = local.infra.project_id
}

data "google_client_config" "current" {}

provider "kubernetes" {
  host                   = "https://${local.infra.cluster_endpoint}"
  token                  = data.google_client_config.current.access_token
  cluster_ca_certificate = base64decode(local.infra.cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = "https://${local.infra.cluster_endpoint}"
    token                  = data.google_client_config.current.access_token
    cluster_ca_certificate = base64decode(local.infra.cluster_ca_certificate)
  }
}
