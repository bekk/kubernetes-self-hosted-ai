# ══════════════════════════════════════════════════════════════════════════════
# Platform — namespace, storage, shared secrets
# ══════════════════════════════════════════════════════════════════════════════

locals {
  models = {
    for key, model in yamldecode(file("${path.module}/${var.models_file}")).models :
    key => model if try(model.enabled, true)
  }

  db = local.infra.database_credentials

  # Every LiteLLM alias (tier + extra aliases) → the model's served name.
  alias_pairs = flatten([
    for model in values(local.models) : [
      for alias in concat([model.tier], try(model.aliases, [])) : { alias = alias, target = model.served_name }
    ]
  ])
  alias_names = [for pair in local.alias_pairs : pair.alias]
  # Grouping (`...`) so a duplicate hits the precondition below, not a crash.
  aliases = { for alias, targets in { for pair in local.alias_pairs : pair.alias => pair.target... } : alias => targets[0] }
}

# Aliases must be unique, or LiteLLM can't tell which model "large" is.
resource "terraform_data" "unique_aliases" {
  lifecycle {
    precondition {
      condition     = length(local.alias_names) == length(distinct(local.alias_names))
      error_message = "Two enabled models in models.yaml claim the same tier or alias: ${join(", ", local.alias_names)}"
    }
  }
}

resource "kubernetes_namespace_v1" "platform" {
  metadata {
    name = var.namespace
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Storage for model weights
# ──────────────────────────────────────────────────────────────────────────────
# B200 and RTX PRO 6000 nodes only attach Hyperdisk. The default throughput
# (~140 MiB/s) would take well over an hour to read GLM-5.3's ~760 GB, so we
# provision the disk near Hyperdisk Balanced's 2.4 GiB/s ceiling.
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_storage_class_v1" "hyperdisk" {
  metadata {
    name = "vllm-weights"
  }

  storage_provisioner    = "pd.csi.storage.gke.io"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type                               = "hyperdisk-balanced"
    "provisioned-throughput-on-create" = "2400Mi"
    "provisioned-iops-on-create"       = "10000"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Secrets
# ──────────────────────────────────────────────────────────────────────────────

resource "random_password" "litellm_master_key" {
  length  = 48
  special = false
}

resource "kubernetes_secret_v1" "litellm_master_key" {
  metadata {
    name      = "litellm-master-key"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
  }

  data = {
    # LiteLLM requires master keys to start with "sk-".
    "master-key" = "sk-${random_password.litellm_master_key.result}"
  }
}

resource "kubernetes_secret_v1" "hf_token" {
  count = var.hf_token != "" ? 1 : 0

  metadata {
    name      = "hf-token"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
  }

  data = {
    token = var.hf_token
  }
}

resource "kubernetes_secret_v1" "litellm_db" {
  metadata {
    name      = "litellm-db"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
  }

  data = {
    username = local.db.litellm.username
    password = local.db.litellm.password
  }
}

resource "kubernetes_secret_v1" "open_webui_db" {
  metadata {
    name      = "open-webui-db"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
  }

  data = {
    url = "postgresql://${local.db.openwebui.username}:${local.db.openwebui.password}@${local.infra.database_host}:5432/${local.db.openwebui.database}"
  }
}
