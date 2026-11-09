# ──────────────────────────────────────────────────────────────────────────────
# LiteLLM — the API gateway
# ──────────────────────────────────────────────────────────────────────────────
# Exposes every model under two names:
#   - its served name (e.g. "glm-5.3")
#   - its tier alias  (e.g. "large")
#
# Speaks both the OpenAI API (/v1/chat/completions) and the Anthropic Messages
# API (/v1/messages), so Claude Code can point straight at it.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  litellm_config = {
    model_list = [
      for key, model in local.models : {
        model_name = model.served_name
        litellm_params = merge(
          {
            model    = "hosted_vllm/${model.served_name}"
            api_base = "http://vllm-${key}.${var.namespace}.svc.cluster.local:8000/v1"
            # Long agentic turns on the large tier can run for minutes.
            timeout = 1800
          },
          length(try(model.gateway.drop_params, [])) > 0 ? { additional_drop_params = model.gateway.drop_params } : {},
        )
      }
    ]

    router_settings = {
      model_group_alias = local.aliases
    }

    litellm_settings = {
      # Clients send provider-specific params; drop what vLLM doesn't accept.
      drop_params = true
    }

    general_settings = {
      master_key = "os.environ/PROXY_MASTER_KEY"
    }
  }
}

resource "helm_release" "litellm" {
  name       = "litellm"
  namespace  = kubernetes_namespace_v1.platform.metadata[0].name
  repository = "oci://ghcr.io/berriai"
  chart      = "litellm-helm"
  version    = var.litellm_chart_version

  # The chart runs a Prisma migration job against Cloud SQL on install.
  timeout = 900

  values = [yamlencode({
    replicaCount = 2

    nodeSelector = {
      "ai.bekk.no/role" = "system"
    }

    masterkeySecretName = kubernetes_secret_v1.litellm_master_key.metadata[0].name
    masterkeySecretKey  = "master-key"

    db = {
      useExisting      = true
      deployStandalone = false
      endpoint         = local.infra.database_host
      database         = local.db.litellm.database
      secret = {
        name        = kubernetes_secret_v1.litellm_db.metadata[0].name
        usernameKey = "username"
        passwordKey = "password"
      }
    }

    proxy_config = local.litellm_config
  })]
}
