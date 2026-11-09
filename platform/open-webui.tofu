# ──────────────────────────────────────────────────────────────────────────────
# Open WebUI — chat portal, talking to LiteLLM only
# ──────────────────────────────────────────────────────────────────────────────

resource "helm_release" "open_webui" {
  name       = "open-webui"
  namespace  = kubernetes_namespace_v1.platform.metadata[0].name
  repository = "https://helm.openwebui.com/"
  chart      = "open-webui"
  version    = var.open_webui_chart_version

  values = [yamlencode({
    nodeSelector = {
      "ai.bekk.no/role" = "system"
    }

    # All inference goes through LiteLLM; none of the bundled extras.
    ollama    = { enabled = false }
    pipelines = { enabled = false }
    websocket = { enabled = false }

    openaiBaseApiUrl              = "http://litellm.${var.namespace}.svc.cluster.local:4000/v1"
    openaiApiKeyExistingSecret    = kubernetes_secret_v1.litellm_master_key.metadata[0].name
    openaiApiKeyExistingSecretKey = "master-key"

    extraEnvVars = [
      {
        name = "DATABASE_URL"
        valueFrom = {
          secretKeyRef = {
            name = kubernetes_secret_v1.open_webui_db.metadata[0].name
            key  = "url"
          }
        }
      },
    ]

    # Uploads and the vector store still live on disk.
    persistence = {
      enabled = true
      size    = "20Gi"
    }
  })]

  depends_on = [helm_release.litellm]
}
