# ──────────────────────────────────────────────────────────────────────────────
# kagent — Kubernetes-native AI agents, running on our own models
# ──────────────────────────────────────────────────────────────────────────────
# kagent's default ModelConfig points at LiteLLM, so its agents use the
# cluster's own models through the same gateway as every other client.
#
# Pinned to the 0.10 line on purpose: kagent 1.0 needs Kubernetes 1.37+ and
# the Agent Substrate stack (gVisor sandboxes, its own CAs), which is far more
# than a demo needs.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  kagent_namespace = "kagent"

  # Built-in agents for things this cluster actually runs. The rest (Istio,
  # Cilium, Argo, Grafana, Prometheus, kgateway) would only show up broken.
  kagent_agents = {
    "k8s-agent"            = true
    "helm-agent"           = true
    "kgateway-agent"       = false
    "istio-agent"          = false
    "promql-agent"         = false
    "observability-agent"  = false
    "argo-rollouts-agent"  = false
    "cilium-policy-agent"  = false
    "cilium-manager-agent" = false
    "cilium-debug-agent"   = false
    # Not an agent, but a Grafana MCP server that would also only show up broken.
    "grafana-mcp" = false
  }
}

resource "kubernetes_namespace_v1" "kagent" {
  count = var.enable_kagent ? 1 : 0

  metadata {
    name = local.kagent_namespace
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# kagent's own LiteLLM key
# ──────────────────────────────────────────────────────────────────────────────
# A dedicated virtual key (alias "kagent") so agent traffic shows up separately
# under usage and spend in LiteLLM. We choose the key value ourselves and
# register it with a one-off Job, since LiteLLM keeps keys in its database
# rather than in config.
# ──────────────────────────────────────────────────────────────────────────────

resource "random_password" "kagent_litellm_key" {
  count = var.enable_kagent ? 1 : 0

  length  = 40
  special = false
}

locals {
  kagent_litellm_key = var.enable_kagent ? "sk-kagent-${random_password.kagent_litellm_key[0].result}" : ""
}

resource "kubernetes_secret_v1" "kagent_llm" {
  count = var.enable_kagent ? 1 : 0

  metadata {
    name      = "kagent-openai"
    namespace = kubernetes_namespace_v1.kagent[0].metadata[0].name
  }

  data = {
    OPENAI_API_KEY = local.kagent_litellm_key
  }
}

# A copy next to LiteLLM, for the registration Job (secrets don't cross namespaces).
resource "kubernetes_secret_v1" "kagent_litellm_key" {
  count = var.enable_kagent ? 1 : 0

  metadata {
    name      = "kagent-litellm-key"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
  }

  data = {
    key = local.kagent_litellm_key
  }
}

resource "kubernetes_job_v1" "register_kagent_key" {
  count = var.enable_kagent ? 1 : 0

  metadata {
    # New name per key, so a rotated key gets registered by a fresh Job.
    name      = "register-kagent-key-${substr(sha256(local.kagent_litellm_key), 0, 8)}"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
  }

  spec {
    backoff_limit              = 6
    ttl_seconds_after_finished = 3600

    template {
      metadata {}
      spec {
        restart_policy = "OnFailure"
        node_selector  = { "ai.bekk.no/role" = "system" }

        container {
          name  = "register"
          image = "curlimages/curl:8.11.1"

          env {
            name = "MASTER_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.litellm_master_key.metadata[0].name
                key  = "master-key"
              }
            }
          }
          env {
            name = "KAGENT_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.kagent_litellm_key[0].metadata[0].name
                key  = "key"
              }
            }
          }

          # Idempotent: an existing key counts as success.
          command = ["/bin/sh", "-c", <<-EOT
            set -u
            code=$(curl -s -o /tmp/out -w '%%{http_code}' -X POST \
              http://litellm.${var.namespace}.svc.cluster.local:4000/key/generate \
              -H "Authorization: Bearer $MASTER_KEY" -H 'Content-Type: application/json' \
              -d "{\"key\": \"$KAGENT_KEY\", \"key_alias\": \"kagent\", \"metadata\": {\"client\": \"kagent\"}}")
            echo "HTTP $code"; cat /tmp/out; echo
            [ "$code" = "200" ] && exit 0
            grep -qiE 'already exists|unique constraint|duplicate' /tmp/out && exit 0
            exit 1
          EOT
          ]
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "5m"
  }

  depends_on = [helm_release.litellm]
}

resource "helm_release" "kagent_crds" {
  count = var.enable_kagent ? 1 : 0

  name       = "kagent-crds"
  namespace  = kubernetes_namespace_v1.kagent[0].metadata[0].name
  repository = "oci://ghcr.io/kagent-dev/kagent/helm"
  chart      = "kagent-crds"
  version    = var.kagent_chart_version
}

resource "helm_release" "kagent" {
  count = var.enable_kagent ? 1 : 0

  name       = "kagent"
  namespace  = kubernetes_namespace_v1.kagent[0].metadata[0].name
  repository = "oci://ghcr.io/kagent-dev/kagent/helm"
  chart      = "kagent"
  version    = var.kagent_chart_version
  timeout    = 900

  values = [yamlencode(merge(
    {
      database = {
        postgres = {
          url     = "postgresql://${local.db.kagent.username}:${local.db.kagent.password}@${local.infra.database_host}:5432/${local.db.kagent.database}?sslmode=disable"
          bundled = { enabled = false }
        }
      }

      providers = {
        default = "openAI"
        openAI = {
          provider        = "OpenAI"
          model           = var.kagent_model
          apiKeySecretRef = kubernetes_secret_v1.kagent_llm[0].metadata[0].name
          apiKeySecretKey = "OPENAI_API_KEY"
          config = {
            baseUrl = "http://litellm.${var.namespace}.svc.cluster.local:4000/v1"
          }
        }
      }
    },
    { for agent, enabled in local.kagent_agents : agent => { enabled = enabled } },
  ))]

  depends_on = [helm_release.kagent_crds, helm_release.litellm]
}

# ──────────────────────────────────────────────────────────────────────────────
# Our own agent: plattform-agent
# ──────────────────────────────────────────────────────────────────────────────
# Its system prompt includes the model catalogue rendered from models.yaml, so
# the agent knows what *should* be running and where, and can spot workloads
# that bypass the platform.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  model_catalogue = join("\n", concat(
    [
      "| Nøkkel (node-label) | Aliaser i gatewayen | Modell | Maskin | Akseleratorer | Sone | Replicas |",
      "|---|---|---|---|---|---|---|",
    ],
    [
      for key, model in local.models : format(
        "| `%s` | %s | %s | %s | %s | %s | %s |",
        key,
        join(", ", concat([model.tier], try(model.aliases, []))),
        model.hf_model,
        model.node.machine_type,
        try(model.node.accelerator, "gpu") == "tpu" ? "${model.node.tpu_chips}× TPU (${model.node.tpu_type})" : "${model.node.gpu_count}× ${model.node.gpu_type}",
        try(model.node.zone, "clusterets sone"),
        try(model.serving.replicas, 1),
      )
    ],
  ))
}

resource "helm_release" "kagent_agents" {
  count = var.enable_kagent ? 1 : 0

  name      = "kagent-agents"
  namespace = kubernetes_namespace_v1.kagent[0].metadata[0].name
  chart     = "${path.module}/charts/kagent-agents"

  values = [yamlencode({
    modelConfig       = "default-model-config"
    toolServer        = "kagent-tool-server"
    platformNamespace = var.namespace
    modelCatalogue    = local.model_catalogue
  })]

  # The Agent CRD and the tool server come from the kagent releases.
  depends_on = [helm_release.kagent]
}
