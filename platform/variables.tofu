variable "infrastructure_state_path" {
  description = "Path to the infrastructure stack's local state file."
  type        = string
  default     = "../infrastructure/gcp/terraform.tfstate"
}

variable "models_file" {
  description = "Path to the shared model catalogue."
  type        = string
  default     = "../models.yaml"
}

variable "namespace" {
  description = "Namespace for all platform workloads."
  type        = string
  default     = "ai-datacenter"
}

variable "hf_token" {
  description = "Optional Hugging Face token. Not needed for the default models, but avoids anonymous rate limits."
  type        = string
  default     = ""
  sensitive   = true
}

variable "vllm_image" {
  description = "vLLM image. GLM-5.3 needs >= v0.29.0."
  type        = string
  default     = "vllm/vllm-openai:v0.32.0"
}

variable "vllm_tpu_image" {
  description = "vLLM build for Cloud TPU, used by models with node.accelerator = tpu."
  type        = string
  default     = "vllm/vllm-tpu:v0.33.0"
}

variable "litellm_chart_version" {
  type    = string
  default = "1.108.3"
}

variable "open_webui_chart_version" {
  type    = string
  default = "18.0.0"
}

variable "expose_publicly" {
  description = <<-EOT
    Give LiteLLM and Open WebUI external LoadBalancer IPs, restricted to
    `allowed_source_ranges`. When false, use `make port-forward`.
  EOT
  type        = bool
  default     = false
}

variable "allowed_source_ranges" {
  description = "CIDRs allowed to reach the public LoadBalancers (only used when expose_publicly = true)."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.expose_publicly || length(var.allowed_source_ranges) > 0
    error_message = "Set allowed_source_ranges when expose_publicly is true — don't expose the gateway to the whole internet."
  }
}

variable "enable_kagent" {
  description = "Install kagent (Kubernetes-native AI agents) wired to LiteLLM."
  type        = bool
  default     = true
}

variable "kagent_chart_version" {
  description = "kagent and kagent-crds chart version (kept on the 0.10 line; 1.0 needs Kubernetes 1.37+)."
  type        = string
  default     = "0.10.4"
}

variable "kagent_model" {
  description = "LiteLLM model name kagent's agents use by default."
  type        = string
  default     = "medium"
}
