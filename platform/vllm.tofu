# ──────────────────────────────────────────────────────────────────────────────
# vLLM — one release per enabled model in models.yaml
# ──────────────────────────────────────────────────────────────────────────────
# Each release renders charts/vllm-model: a Deployment pinned to the model's
# node pool via `ai.bekk.no/model`, a Service `vllm-<key>:8000`, and a PVC
# that caches the weights.
#
# `wait = false`: the first start of a large model takes 15–30 minutes
# (download + load). We don't block `tofu apply` on it — use `make status`.
# ──────────────────────────────────────────────────────────────────────────────

resource "helm_release" "vllm" {
  for_each = local.models

  name      = "vllm-${each.key}"
  namespace = kubernetes_namespace_v1.platform.metadata[0].name
  chart     = "${path.module}/charts/vllm-model"
  wait      = false

  values = [yamlencode({
    key        = each.key
    hfModel    = each.value.hf_model
    servedName = each.value.served_name
    # TPUs need the vllm-tpu build; a model can also pin its own image.
    image    = try(each.value.serving.image, try(each.value.node.accelerator, "gpu") == "tpu" ? var.vllm_tpu_image : var.vllm_image)
    replicas = try(each.value.serving.replicas, 1)

    resources = {
      cpu    = each.value.serving.cpu
      memory = each.value.serving.memory
    }

    accelerator = {
      type        = try(each.value.node.accelerator, "gpu")
      count       = try(each.value.node.accelerator, "gpu") == "tpu" ? each.value.node.tpu_chips : each.value.node.gpu_count
      tpuType     = try(each.value.node.tpu_type, "")
      tpuTopology = try(each.value.node.tpu_topology, "")
    }

    shm = try(each.value.serving.shm, "16Gi")

    cache = {
      size         = each.value.serving.cache_size
      storageClass = kubernetes_storage_class_v1.hyperdisk.metadata[0].name
    }

    hfTokenSecret = var.hf_token != "" ? kubernetes_secret_v1.hf_token[0].metadata[0].name : ""

    env  = try(each.value.serving.env, {})
    args = try(each.value.serving.args, [])
  })]
}
