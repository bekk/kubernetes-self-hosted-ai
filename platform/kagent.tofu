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

# kagent talks to LiteLLM with the same key as Open WebUI.
resource "kubernetes_secret_v1" "kagent_llm" {
  count = var.enable_kagent ? 1 : 0

  metadata {
    name      = "kagent-openai"
    namespace = kubernetes_namespace_v1.kagent[0].metadata[0].name
  }

  data = {
    OPENAI_API_KEY = kubernetes_secret_v1.litellm_master_key.data["master-key"]
  }
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
