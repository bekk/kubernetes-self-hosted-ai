# Adding a Model

Step-by-step guide for onboarding a new model to the AI Datacenter platform.

> [!IMPORTANT]
> The **Model Key** ties infrastructure to application config. The key you choose in `terraform.tfvars` (e.g. `llama-4-scout`) becomes the node label `ai.bekk.no/model: llama-4-scout`, and the Helm values must use the same key in `nodeSelector`. If these don't match, the vLLM pod won't schedule onto the GPU node.

## 1. Choose the Model and Determine GPU Requirements

Before adding anything, figure out how much GPU memory the model needs:

1. **Check the model card** on HuggingFace for parameter count and recommended hardware.
2. **Estimate VRAM** — rough rule of thumb:

   | Precision | VRAM per Billion Parameters |
   |-----------|----------------------------|
   | FP16 / BF16 | ~2 GB/B |
   | INT8 | ~1 GB/B |
   | INT4 | ~0.5 GB/B |

   For a 27B model at INT4: ~14 GB → fits on a single L4 (24 GB).

3. **Pick a GCP machine type** based on GPU count:

   | Machine Type | GPUs | GPU Memory | Use Case |
   |--------------|------|------------|----------|
   | `g2-standard-8` | 1× L4 | 24 GB | Models ≤ 20B (INT4) or ≤ 12B (FP16) |
   | `g2-standard-24` | 2× L4 | 48 GB | Models ≤ 40B (INT4) or ≤ 24B (FP16) |
   | `g2-standard-48` | 4× L4 | 96 GB | Models ≤ 80B (INT4) or ≤ 48B (FP16) |
   | `a2-highgpu-1g` | 1× A100 | 40 GB | Latency-sensitive or large-context workloads |

   Cross-reference with the [Verified Models table](../README.md#verified-models) for known-good configurations.

4. **Check that you have GPU quota** in your target region:

   ```bash
   gcloud compute regions describe europe-west4 \
     --format="table(quotas.metric,quotas.limit,quotas.usage)" \
     | grep -i gpu
   ```

   If using Spot, you need `PREEMPTIBLE_NVIDIA_L4_GPUS` quota (separate from on-demand).

## 2. Add Infrastructure

Add an entry to the `models` map in `infrastructure/gcp/terraform.tfvars`:

```hcl
models = {
  # Existing models
  gemma-4 = {
    machine_type = "g2-standard-8"
    gpu_type     = "nvidia-l4"
    gpu_count    = 1
    spot         = true
  }

  # New model
  llama-4-scout = {
    machine_type = "g2-standard-24"
    gpu_type     = "nvidia-l4"
    gpu_count    = 2
    spot         = true
  }
}
```

Apply the change:

```bash
cd infrastructure/gcp
tofu plan    # Review — should show a new node pool being created
tofu apply
```

This creates a new GKE node pool with:
- The specified machine type and GPU configuration
- The node label `ai.bekk.no/model: llama-4-scout`
- A matching taint so only pods that tolerate it get scheduled there

> [!NOTE]
> Spot node pools can take a few minutes to scale up, and nodes may be preempted. For production-critical models, set `spot = false`.

## 3. Add Application Config

Add an entry to `modelSpec[]` in your Helm values file:

```yaml
modelSpec:
  # Existing models
  - name: "gemma-4"
    enabled: true
    modelURL: "google/gemma-4-27b-it"
    requestGPU: 1
    nodeSelector:
      ai.bekk.no/model: "gemma-4"

  # New model
  - name: "llama-4-scout"
    enabled: true
    modelURL: "meta-llama/Llama-4-Scout-17B-16E-Instruct"
    requestGPU: 2
    nodeSelector:
      ai.bekk.no/model: "llama-4-scout"
```

Deploy:

```bash
cd applications
helm upgrade ai-datacenter . --namespace ai-datacenter
```

Wait for the vLLM pod to start. Model download and loading can take several minutes depending on model size:

```bash
kubectl get pods --namespace ai-datacenter -w
kubectl logs -f deploy/vllm-llama-4-scout --namespace ai-datacenter
```

## 4. Verify

**Check the vLLM router** lists the new model:

```bash
kubectl port-forward svc/vllm-router 8081:80 --namespace ai-datacenter
curl http://localhost:8081/v1/models | jq '.data[].id'
```

You should see `llama-4-scout` in the output.

**Test inference through LiteLLM:**

```bash
kubectl port-forward svc/litellm 4000:4000 --namespace ai-datacenter

curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-your-litellm-key" \
  -d '{
    "model": "llama-4-scout",
    "messages": [{"role": "user", "content": "Hello, who are you?"}],
    "max_tokens": 128
  }'
```

**Test in Open WebUI** — open the UI, select the new model from the dropdown, and send a message.

## 5. Update the Verified Models Table

Once you've confirmed the model works, add it to the [Verified Models table](../README.md#verified-models) in `README.md`:

```markdown
| Llama 4 Scout | `meta-llama/Llama-4-Scout-17B-16E-Instruct` | `llama-4-scout` | `ai.bekk.no/model: llama-4-scout` | `g2-standard-24` | 2× NVIDIA L4 (48 GB) | ~X GB | Your notes here. |
```

## Label Convention Reference

The label `ai.bekk.no/model` is the glue between infrastructure and application:

```
terraform.tfvars                        Helm values
─────────────────                       ───────────
models = {                              modelSpec:
  llama-4-scout = {  ◄── Model Key ──►   - name: "llama-4-scout"
    ...                                     nodeSelector:
  }                                           ai.bekk.no/model: "llama-4-scout"
}                                                     ▲
        │                                             │
        ▼                                             │
  Node label:                                   Pod scheduling
  ai.bekk.no/model: llama-4-scout ─────────────►  matches label
```

Both sides **must use the same key**. If they diverge, the pod stays in `Pending` because no node matches its `nodeSelector`.
