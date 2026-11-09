# AI Datacenter

![OpenTofu Badge](https://img.shields.io/badge/OpenTofu-FFDA18?logo=opentofu&logoColor=000&style=for-the-badge)
![vLLM Badge](https://img.shields.io/badge/vLLM-30A2FF?logo=vllm&logoColor=fff&style=for-the-badge)
![Google Cloud Badge](https://img.shields.io/badge/Google%20Cloud-4285F4?logo=googlecloud&logoColor=fff&style=for-the-badge)
![Helm Badge](https://img.shields.io/badge/Helm-0F1689?logo=helm&logoColor=fff&style=for-the-badge)

Run frontier-class open-weight LLMs in your own GKE cluster instead of calling a hosted provider. Three model tiers behind one OpenAI- **and** Anthropic-compatible API, a ChatGPT-style portal, all from `make up`.

## Architecture

```
                       ┌──────────────┐
  Browser ───────────► │  Open WebUI  │──┐
                       └──────────────┘  │
  Claude Code ──┐                        ▼
  curl / SDKs ──┴────────────────► ┌──────────┐      ┌─────────────────────────────┐
     (OpenAI or Anthropic API)     │ LiteLLM  │─────►│ vllm-glm-5-3       8× B200  │ large
                                   │ gateway  │─────►│ vllm-glm-5-3-flash 8× B200  │ medium
                                   └────┬─────┘─────►│ vllm-qwen3-8-27b   1× RTX6000│ small
                                        │            └─────────────────────────────┘
                                   Cloud SQL (keys, budgets, spend, chats)
```

| Component | Role |
|---|---|
| **vLLM** | One Deployment per model, pinned to its own GPU node pool, weights cached on a Hyperdisk PVC. |
| **LiteLLM** | The single API: OpenAI (`/v1/chat/completions`) and Anthropic (`/v1/messages`) formats, virtual keys, budgets, usage tracking. |
| **Open WebUI** | Chat portal for non-developers. Talks only to LiteLLM. |
| **Cloud SQL** | Postgres for LiteLLM and Open WebUI. Private IP only. |

## Model tiers

| Tier | Alias | Model | Licence | GCP machine | GPUs |
|---|---|---|---|---|---|
| ≈ Opus | `large` | [GLM-5.3](https://huggingface.co/zai-org/GLM-5.3) — 753B MoE, FP8, 1M ctx | GLM-5.3 licence | `a4-highgpu-8g` | 8× B200 (1.44 TB) |
| ≈ Sonnet | `medium` | [GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash) — 320B MoE (18B active), FP8 | MIT | `a4-highgpu-8g` | 8× B200 |
| ≈ Haiku | `small` | [Qwen3.8-27B-FP8](https://huggingface.co/Qwen/Qwen3.8-27B) — dense 27B, 262K ctx | Apache 2.0 | `g4-standard-48` | 1× RTX PRO 6000 (96 GB) |

Clients should use the **tier alias**. Swapping the model behind a tier is a change to [`models.yaml`](models.yaml) only.

> [!NOTE]
> These are not 1:1 equivalents of Claude models. They're in the same class for coding, tool use and long-context work, based on public benchmarks as of November 2026. Benchmark your own workloads before you rely on them.

## How it fits together

Two OpenTofu stacks, one model catalogue:

```
models.yaml               ← the ONE place models are defined
infrastructure/gcp/       ← stack 1: VPC, NAT, GKE, GPU node pools, Cloud SQL
platform/                 ← stack 2: vLLM ×N, LiteLLM, Open WebUI (helm_release)
  charts/vllm-model/      ← tiny local chart: Deployment + Service + PVC
Makefile                  ← `make up` runs both stacks in order
```

Each model's key in `models.yaml` (e.g. `glm-5-3`) becomes:
- a node pool `model-glm-5-3` labelled `ai.bekk.no/model=glm-5-3` (stack 1)
- a Deployment and Service `vllm-glm-5-3` with a matching `nodeSelector` (stack 2)
- a LiteLLM route under its served name *and* its tier alias (stack 2)

**Why two stacks rather than one `tofu apply`?** The Helm and Kubernetes providers need a cluster endpoint at plan time. In a single state, that endpoint doesn't exist yet on the first run, and becomes unknown whenever the cluster is replaced. That's a well-known source of broken plans and stuck destroys. Splitting the state removes the problem, and `make up` still makes it one command.

## Prerequisites

### Tools

| Tool | Version |
|---|---|
| [OpenTofu](https://opentofu.org/docs/intro/install/) | ≥ 1.8 |
| [gcloud CLI](https://cloud.google.com/sdk/docs/install) | latest |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | ≥ 1.30 |
| make | any |

Helm is used through the OpenTofu Helm provider, so you don't need the `helm` CLI.

### GCP project

```bash
gcloud config set project my-ai-datacenter
gcloud auth login
gcloud auth application-default login
```

The infrastructure stack enables the APIs it needs.

### GPU capacity: do this first

> [!IMPORTANT]
> **Quota alone is not enough for B200.** On-demand A4 capacity in Europe is scarce. In practice you need a **reservation** (or a future reservation) in `europe-west4-b`. Talk to your Google account team as early as possible.

You need GPU quota in `europe-west4` for **16× B200** (two 8-GPU nodes) and **2× RTX PRO 6000**. To find them, search for "B200" and "RTX PRO 6000" in [IAM & Admin → Quotas](https://console.cloud.google.com/iam-admin/quotas).

You have two ways to get B200 capacity. Set one of them per model in `models.yaml`:

| Option | Setting | Trade-off |
|---|---|---|
| **Reservation** (recommended for a demo) | `node.reservation: "<name>"` | Guaranteed capacity, billed whether used or not |
| **Flex-start** (Dynamic Workload Scheduler) | `node.flex_start: true` | No reservation needed. GKE queues the scale-up until capacity is found (minutes to hours), and nodes are recycled after at most 7 days |

**Rehearse the scale-up this week.** Run `make up` and confirm both 8× B200 nodes actually appear (`make status`). Don't find out on demo day.

Also check the regional **Hyperdisk Balanced** throughput and capacity quotas. The three weight caches are provisioned at 2.4 GiB/s each, about 2 TB in total.

### Freeze upgrades around the demo

GKE upgrades drain nodes, which forces a model reload of 10–30 minutes. Upgrades are already limited to weekend nights. Add a hard freeze around the presentation in `infrastructure/gcp/terraform.tfvars`:

```hcl
upgrade_freezes = {
  demo = { start = "2026-11-13T00:00:00Z", end = "2026-11-21T00:00:00Z" }
}
```

**Why `europe-west4-b`?** It is the only European zone with B200, GB200, H100 and RTX PRO 6000 all together, and it has the most GPU capacity in Europe. `europe-north1-c` (Hamina, Finland) is closer to Oslo and has B200 and RTX PRO 6000, but much less capacity. The extra network latency from Oslo (around 20 ms) is negligible next to token generation time.

## Quick start

```bash
cp infrastructure/gcp/terraform.tfvars.example infrastructure/gcp/terraform.tfvars
# edit project_id

make up
```

`make up` takes about 15 minutes for infrastructure and platform. Then each model downloads and loads in the background:

| Model | First start | From cache (after `make wake`) |
|---|---|---|
| GLM-5.3 (~760 GB) | 20–40 min | 8–15 min |
| GLM-5.3-Flash (~330 GB) | 10–20 min | 5–8 min |
| Qwen3.8-27B (~30 GB) | 3–5 min | 1–2 min |

These times are estimates. Watch the progress:

```bash
make status
make logs MODEL=glm-5-3
```

## Using it

```bash
make port-forward        # LiteLLM on :4000, Open WebUI on :8080
```

- **Open WebUI:** open http://localhost:8080 and create the admin account (the first user becomes admin).
- **LiteLLM admin UI:** http://localhost:4000/ui. Sign in with the master key: `tofu -chdir=platform output -raw litellm_master_key`. Create a virtual key per user or team there.

### OpenAI-compatible

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "medium", "messages": [{"role": "user", "content": "Hello!"}]}'
```

### Claude Code

LiteLLM exposes the Anthropic Messages API, so Claude Code can run entirely on your cluster:

```bash
eval "$(make -s claude-env)"
claude
```

This maps Claude Code's Opus, Sonnet and Haiku slots to `large`, `medium` and `small`.

> [!NOTE]
> Agentic quality depends on each model's tool-calling. GLM-5.3 and GLM-5.3-Flash were trained for agentic coding. Test your actual workflows before demo day.

### kagent: AI agents inside the cluster

[kagent](https://kagent.dev) runs AI agents as Kubernetes resources. The platform installs it with its default model pointed at **our own LiteLLM** (`medium` tier), so the agents run entirely on the cluster's own models. The built-in `k8s-agent` and `helm-agent` are enabled; agents for tools this cluster doesn't run (Istio, Cilium, Argo, Grafana) are turned off.

```bash
make port-forward        # kagent UI on http://localhost:8081
```

Ask the k8s-agent things like *"Which pods in ai-datacenter are using TPUs, and are they healthy?"*. To turn kagent off, set `enable_kagent = false` in `platform/terraform.tfvars`. It's pinned to the 0.10 line: kagent 1.0 needs Kubernetes 1.37+ and the Agent Substrate stack.

### Public access (optional)

To share the endpoints without port-forwarding, set this in `platform/terraform.tfvars`:

```hcl
expose_publicly       = true
allowed_source_ranges = ["203.0.113.0/24"]   # your office / VPN
```

Then run `make platform` and check `tofu -chdir=platform output public_endpoints`. These endpoints are plain HTTP. For anything beyond a demo, put an HTTPS ingress (and ideally IAP) in front.

## Cost control

| | Approx. on-demand price |
|---|---|
| `a4-highgpu-8g` (8× B200) | very roughly $100+/h each. Check the [GCP pricing page](https://cloud.google.com/compute/gpus-pricing) for current rates |
| `g4-standard-48` (1× RTX PRO 6000) | a few $/h |

GPU node pools scale to zero when no model pod is scheduled:

```bash
make sleep                  # all models → 0 replicas; GPU nodes go away after ~10 min
make wake                   # back to 1 replica; reloads from the cached weights
make sleep MODEL=glm-5-3    # just one
make down                   # destroy everything
```

## Repository layout

| Path | What |
|---|---|
| [`models.yaml`](models.yaml) | Model catalogue: hardware and serving flags per model |
| [`infrastructure/gcp/`](infrastructure/gcp/) | Stack 1: network, GKE, GPU pools, Cloud SQL |
| [`platform/`](platform/) | Stack 2: vLLM releases, LiteLLM, Open WebUI |
| [`docs/adding-a-model.md`](docs/adding-a-model.md) | How to add or swap a model |
