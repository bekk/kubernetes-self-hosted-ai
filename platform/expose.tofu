# ──────────────────────────────────────────────────────────────────────────────
# Optional public access
# ──────────────────────────────────────────────────────────────────────────────
# Neither upstream chart supports loadBalancerSourceRanges, so instead of
# flipping their Services to LoadBalancer we add our own, firewalled to
# `allowed_source_ranges`. Selectors match the labels the charts put on pods.
# ──────────────────────────────────────────────────────────────────────────────

locals {
  public_services = var.expose_publicly ? {
    litellm = {
      port = 4000
      selector = {
        "app.kubernetes.io/name"     = "litellm"
        "app.kubernetes.io/instance" = helm_release.litellm.name
      }
    }
    open-webui = {
      port = 80
      selector = {
        "app.kubernetes.io/instance"  = helm_release.open_webui.name
        "app.kubernetes.io/component" = "open-webui"
      }
    }
  } : {}
}

resource "kubernetes_service_v1" "public" {
  for_each = local.public_services

  metadata {
    name      = "${each.key}-public"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
  }

  spec {
    type                        = "LoadBalancer"
    selector                    = each.value.selector
    load_balancer_source_ranges = var.allowed_source_ranges

    port {
      name        = "http"
      port        = each.value.port
      target_port = "http"
    }
  }
}

output "public_endpoints" {
  description = "External URLs (only when expose_publicly = true). Plain HTTP — put TLS in front for anything beyond a demo."
  value = {
    for name, svc in kubernetes_service_v1.public :
    name => "http://${svc.status[0].load_balancer[0].ingress[0].ip}:${local.public_services[name].port}"
  }
}
