# Adding a Model

Every model is one entry in [`models.yaml`](../models.yaml). Both OpenTofu stacks read that file, so you never have to keep a node pool and a Helm values file in sync by hand.

## 1. Size the hardware

Estimate the memory needed for the weights:

| Precision | Memory per billion parameters |
|---|---|
| BF16 | ~2 GB |
| FP8 | ~1 GB |
| NVFP4 / INT4 | ~0.5 GB |

Then add 20–50% headroom for the KV cache, which grows with context length and concurrent requests. MoE models still need **all** their weights in GPU memory, not just the active ones.

GPU machines in `europe-west4-b`:

| Machine | GPUs | GPU memory | Good for |
|---|---|---|---|
| `g4-standard-48` | 1× RTX PRO 6000 | 96 GB | ≤ 70B at FP8 |
| `g4-standard-384` | 8× RTX PRO 6000 | 768 GB | Mid-size MoE (no NVLink, so slower tensor parallelism) |
| `a3-highgpu-8g` | 8× H100 | 640 GB | ≤ ~500B at FP8 |
| `a4-highgpu-8g` | 8× B200 | 1.44 TB | ≤ ~1.2T at FP8, frontier MoE |

## 2. Find the serving flags

Check [recipes.vllm.ai](https://recipes.vllm.ai) for the model. Copy the tensor-parallel size, tool-call parser, reasoning parser and any model-specific flags. Check the minimum vLLM version against `vllm_image` in [`platform/variables.tofu`](../platform/variables.tofu).

## 3. Add the entry

```yaml
models:
  my-model:                       # DNS-safe key → node pool, Service and label name
    enabled: true
    tier: medium                  # LiteLLM alias; must be unique across models
    served_name: my-model         # name on /v1/models
    hf_model: org/My-Model-FP8    # Hugging Face repo
    node:
      machine_type: a3-highgpu-8g
      gpu_type: nvidia-h100-80gb
      gpu_count: 8
      spot: false
      min_nodes: 0
      max_nodes: 1
      reservation: ""
    serving:
      replicas: 1
      cpu: 32
      memory: 256Gi
      shm: 32Gi
      cache_size: 800Gi           # ≥ 1.5× the checkpoint size
      env: {}
      args:
        - --tensor-parallel-size=8
        - --enable-auto-tool-choice
        - --tool-call-parser=...
```

To replace the model behind an existing tier, give the new entry the same `tier` and set `enabled: false` on the old one. Clients using the alias won't notice the switch.

## 4. Apply

```bash
make up
```

The infrastructure stack creates the node pool. The platform stack creates the vLLM Deployment, its Service and its PVC, and adds the model to LiteLLM.

```bash
make status
make logs MODEL=my-model
```

## 5. Verify

```bash
make port-forward
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer $LITELLM_KEY" | jq '.data[].id'
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_KEY" -H "Content-Type: application/json" \
  -d '{"model": "my-model", "messages": [{"role": "user", "content": "Hello"}]}'
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Pod `Pending`, event says `GCE out of resources` | No capacity in the zone. Use a reservation, or try Spot |
| Pod `Pending`, `didn't match node selector` | The node pool hasn't been created. Run `make infra` |
| `CrashLoopBackOff` with CUDA OOM | Too little GPU memory. Lower `--max-model-len` or `--max-num-seqs`, or use a bigger machine |
| `Unknown tokenizer mode` / architecture not supported | vLLM image is too old for the model |
| Very slow first start | Expected. Weights download once to the PVC; restarts read from disk |
