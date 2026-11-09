output "litellm_master_key" {
  description = "Admin key for LiteLLM. Use it to mint per-user virtual keys in the LiteLLM UI."
  value       = kubernetes_secret_v1.litellm_master_key.data["master-key"]
  sensitive   = true
}

output "models" {
  description = "Enabled models and the LiteLLM names they answer to."
  value = {
    for key, model in local.models : key => {
      served_name = model.served_name
      aliases     = concat([model.tier], try(model.aliases, []))
      hf_model    = model.hf_model
      node_pool   = "model-${key}"
    }
  }
}
