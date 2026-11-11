# Kubernetes Self-Hosted AI

![OpenTofu Badge](https://img.shields.io/badge/OpenTofu-FFDA18?logo=opentofu&logoColor=000&style=for-the-badge)
![vLLM Badge](https://img.shields.io/badge/vLLM-30A2FF?logo=vllm&logoColor=fff&style=for-the-badge)
![Google Cloud Badge](https://img.shields.io/badge/Google%20Cloud-4285F4?logo=googlecloud&logoColor=fff&style=for-the-badge)
![Helm Badge](https://img.shields.io/badge/Helm-0F1689?logo=helm&logoColor=fff&style=for-the-badge)

Run open-weight LLMs on your own GKE cluster instead of calling a hosted provider: model tiers behind one OpenAI- **and** Anthropic-compatible gateway, a chat portal, and Kubernetes-native agents, all from `make up`.

It's built as a demo for platform engineers: how accelerators (GPUs and TPUs) are scheduled in Kubernetes, how to offer models as a platform product, and what it actually costs. The same patterns apply on any Kubernetes cluster with accelerators, including your own data centre.

## Architecture

```
                         ┌──────────────┐
  Browser ─────────────► │  Open WebUI  │──┐
                         └──────────────┘  │
  Claude Code ──┐                          ▼
  Codex ────────┤                    ┌──────────┐      ┌──────────────────────────────────┐
  Copilot CLI ──┼──────────────────► │ LiteLLM  │─────►│ vllm-gemma-4-31b-tpu    8× TPU v6e│ medium, large
  curl / SDKs ──┤  OpenAI, Anthropic │ gateway  │─────►│ vllm-qwen3-30b-a3b-tpu  4× TPU v6e│ small
  kagent ───────┘  or Responses API  └────┬─────┘      └──────────────────────────────────┘
                                          │
                                  Cloud SQL (keys, spend, chats, agent sessions)
```

| Component | Role |
|---|---|
| **vLLM** | One Deployment per model, pinned to its own accelerator node pool, weights cached on a Hyperdisk PVC. |
| **LiteLLM** | The single API: OpenAI (`/v1/chat/completions`, `/v1/responses`) and Anthropic (`/v1/messages`) formats, virtual keys per client, usage tracking. |
| **Open WebUI** | Chat portal for non-developers. Talks only to LiteLLM. |
| **kagent** | Kubernetes-native AI agents, thinking with the cluster's own models through LiteLLM. |
| **Cloud SQL** | Postgres for LiteLLM, Open WebUI and kagent. Private IP only. |

## Models

Defined in [`models.yaml`](models.yaml). Clients use the **tier alias**, so swapping the model behind a tier is a one-file change.

**Enabled by default (TPU v6e):**

| Tier | Model | Hardware | Measured |
|---|---|---|---|
| `medium` (also `large`) | [Gemma 4 31B-it](https://huggingface.co/google/gemma-4-31B-it), Apache 2.0 | `ct6e-standard-8t`, 8× TPU v6e | ~1 260 output tokens/s at 64 concurrent requests |
| `small` | [Qwen3-30B-A3B-Instruct-2507](https://huggingface.co/Qwen/Qwen3-30B-A3B-Instruct-2507), Apache 2.0 | `ct6e-standard-4t`, 4× TPU v6e | ~1 150 output tokens/s at 64 concurrent requests |

**Disabled alternatives (NVIDIA Blackwell):** GLM-5.3 on 8× B200 (`large`), GLM-5.3-Flash on 8× B200 or 8× RTX PRO 6000 (`medium`), and Qwen3.8-27B on 1× RTX PRO 6000 (`small`). Stronger models, but 8-GPU machines are rarely available on demand at short notice; see [Capacity](#capacity-do-this-first).

> [!NOTE]
> These aren't 1:1 equivalents of Claude models. Benchmark your own workloads before relying on them.

## How it fits together

Two OpenTofu stacks, one model catalogue:

```
models.yaml               ← the ONE place models are defined
infrastructure/gcp/       ← stack 1: VPC, NAT, private GKE, accelerator node pools, Cloud SQL
platform/                 ← stack 2: vLLM ×N, LiteLLM, Open WebUI, kagent (helm_release)
  charts/vllm-model/      ← local chart: Deployment + Service + weight-cache PVC (GPU or TPU)
  charts/kagent-agents/   ← plattform-agent, with the model catalogue in its system prompt
scripts/                  ← throughput and coding-agent benchmarks
demo/                     ← a workload that bypasses the platform, for the kagent demo
Makefile                  ← `make up` runs both stacks in order
```

Each model's key in `models.yaml` (e.g. `gemma-4-31b-tpu`) becomes:
- a node pool `model-gemma-4-31b-tpu`, labelled `ai.bekk.no/model=gemma-4-31b-tpu` (stack 1)
- a Deployment and Service `vllm-gemma-4-31b-tpu` with a matching `nodeSelector`, requesting `google.com/tpu` or `nvidia.com/gpu` (stack 2)
- a LiteLLM route under its served name and its tier alias (stack 2)

GKE taints accelerator nodes (`google.com/tpu` / `nvidia.com/gpu`, `NoSchedule`), so nothing but model pods lands on them. The label is what pulls the right model onto the right node pool.

**Why two stacks rather than one `tofu apply`?** The Helm and Kubernetes providers need a cluster endpoint at plan time. In a single state that endpoint doesn't exist on the first run and becomes unknown whenever the cluster is replaced: a well-known source of broken plans and stuck destroys. Splitting the state removes the problem, and `make up` still makes it one command.

## Prerequisites

| Tool | Version |
|---|---|
| [OpenTofu](https://opentofu.org/docs/intro/install/) | ≥ 1.8 |
| [gcloud CLI](https://cloud.google.com/sdk/docs/install) | latest |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | ≥ 1.30 |
| make, Python 3 | any |

Helm runs through the OpenTofu Helm provider, so you don't need the `helm` CLI.

```bash
gcloud config set project my-gcp-project
gcloud auth login
gcloud auth application-default login
```

The infrastructure stack enables the APIs it needs.

### Capacity: do this first

> [!IMPORTANT]
> **Quota is not capacity.** Having quota means you're allowed to start a machine, not that one is free. Large accelerator machines are often unavailable on demand, especially at short notice.

1. **Quota.** New projects often have **no on-demand quota** for large accelerators. For the default setup you need 12 TPU v6e chips in your region (`TPUS-PER-TPU-FAMILY`, family `CT6E`). Request it in [IAM & Admin → Quotas](https://console.cloud.google.com/iam-admin/quotas); TPU requests are often approved within minutes.
2. **Capacity.** Check availability before you rely on it:

   ```bash
   gcloud compute advice calendar-mode --tpu-version=V6E --chip-count=8 --region=us-east5 \
     --start-time-range=from=2026-12-01T08:00:00Z,to=2026-12-01T10:00:00Z --duration-range=min=24h,max=24h
   ```

3. **Guarantee it if it matters.** Set one of these per model in `models.yaml`:

| Option | Setting | Trade-off |
|---|---|---|
| **Calendar reservation** | `node.reservation: "<name>"` | Guaranteed capacity for a time window. TPUs: 6 h lead time; GPUs: 87 h. Minimum 24 h, billed whether used or not, and not cancellable close to the start. No quota needed. |
| **Flex-start** | `node.flex_start: true` | No reservation; GKE queues the scale-up until capacity appears (minutes to hours). Uses Spot/preemptible quota. |
| **On demand** | neither | Whatever is free right now. |

> [!TIP]
> `gcloud compute future-reservations create` insists on `--workload-type`, which TPU v6e rejects. Create TPU v6e calendar reservations through the REST API instead, without `workloadType`.

Also check the regional **Hyperdisk Balanced** throughput and capacity quotas: each weight cache is provisioned at 2.4 GiB/s.

## Quick start

```bash
cp infrastructure/gcp/terraform.tfvars.example infrastructure/gcp/terraform.tfvars
# set project_id (and region/zone if you're not using the TPU defaults)

make up
```

Measured with a TPU calendar reservation:

| Step | Time |
|---|---|
| Infrastructure (VPC, GKE, Cloud SQL) | ~8–10 min |
| Reserved TPU node, from request to `Ready` | ~3 min |
| Qwen3-30B-A3B, from deploy to serving (node, download, TPU compilation) | ~10 min |
| Gemma 4 31B, from deploy to serving | ~16 min |

```bash
make status                         # nodes with their model/tier labels, and pods
make logs MODEL=gemma-4-31b-tpu
```

### Freeze upgrades around a demo

GKE node upgrades drain nodes and force a model reload. Upgrades are limited to weekend nights by default; add a hard freeze in `infrastructure/gcp/terraform.tfvars`:

```hcl
upgrade_freezes = {
  demo = { start = "2026-12-01T00:00:00Z", end = "2026-12-03T00:00:00Z" }
}
```

## Using it

```bash
make port-forward   # LiteLLM :4000, Open WebUI :8090, kagent :8081 (reconnects if dropped)
```

- **Open WebUI:** http://localhost:8090. The first user to sign up becomes admin.
- **LiteLLM admin UI:** http://localhost:4000/ui, user `admin`, password = the master key:
  `tofu -chdir=platform output -raw litellm_master_key`. Create a virtual key per client or team so usage shows up separately.

### OpenAI-compatible

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_KEY" -H "Content-Type: application/json" \
  -d '{"model": "medium", "messages": [{"role": "user", "content": "Hello!"}]}'
```

### Claude Code

LiteLLM exposes the Anthropic Messages API, so Claude Code runs entirely on your cluster:

```bash
eval "$(make -s claude-env)"
claude
```

This maps Claude Code's Opus, Sonnet and Haiku slots to `large`, `medium` and `small`.

### GitHub Copilot CLI

Copilot CLI supports bring-your-own-model through environment variables:

```bash
export COPILOT_PROVIDER_TYPE=openai COPILOT_PROVIDER_BASE_URL=http://localhost:4000/v1 COPILOT_MODEL=medium
export COPILOT_PROVIDER_API_KEY=<a LiteLLM key>
copilot
```

Copilot CLI recommends 128k context; the default models run with 64k, which is enough for small and medium tasks.

### Codex

Add a provider to `~/.codex/config.toml` (LiteLLM serves the Responses API Codex uses):

```toml
[model_providers.ai-datacenter]
name = "AI Datacenter (LiteLLM)"
base_url = "http://localhost:4000/v1"
env_key = "AI_DATACENTER_KEY"
wire_api = "responses"

[profiles.ai-datacenter]
model = "medium"
model_provider = "ai-datacenter"
model_context_window = 65536
```

Then `AI_DATACENTER_KEY=<a LiteLLM key> codex --profile ai-datacenter`.

### kagent: AI agents inside the cluster

[kagent](https://kagent.dev) runs agents as Kubernetes resources. Its default model points at LiteLLM (`medium`) with its own virtual key (`kagent`), so agent usage shows up separately. Besides the built-in `k8s-agent` and `helm-agent`, the platform installs **`plattform-agent`**, whose system prompt includes the model catalogue rendered from `models.yaml`.

A three-act demo in the kagent UI (http://localhost:8081):

1. *"Hvilke modeller kjører vi, på hvilken maskinvare, og er alt friskt?"* The agent answers with a table of models, nodes and status.
2. `make demo-break` deploys a "model" that bypasses `models.yaml`: it requests TPUs with a `nodeSelector` no node pool matches, so it stays `Pending` (and costs nothing). Ask *"Teamet mitt deployet ny-modell, men den starter aldri. Hvorfor?"* The agent finds the nodeSelector mismatch and points to `models.yaml` as the fix. `make demo-fix` cleans up.
3. *"Legg small-modellen i dvale."* The agent asks for confirmation before scaling anything.

kagent is pinned to the 0.10 line: kagent 1.0 needs Kubernetes 1.37+ and the Agent Substrate stack. Set `enable_kagent = false` in `platform/terraform.tfvars` to skip it.

### Public access (optional)

```hcl
# platform/terraform.tfvars
expose_publicly       = true
allowed_source_ranges = ["203.0.113.0/24"]   # your office / VPN
```

Run `make platform`, then `tofu -chdir=platform output public_endpoints`. These endpoints are plain HTTP; put an HTTPS ingress (and ideally IAP) in front for anything beyond a demo.

## Benchmarks and cost

Two scripts, standard library only, run against LiteLLM through `make port-forward`:

```bash
make benchmark          # throughput at 1–16 concurrent requests, cost per 1M tokens, API break-even
make agent-benchmark    # N simulated developers running coding agents, cost per developer-hour
```

Override settings with `BENCH_ARGS=...` / `AGENT_BENCH_ARGS=...`; see each script's `--help`.

Measured on the default TPU setup (hourly prices are rough on-demand estimates):

| Gemma 4 31B on 8× TPU v6e (~23 USD/h) | 1 | 16 | 64 concurrent |
|---|---|---|---|
| Output tokens/s, total | 76 | 776 | 1 264 |
| USD per 1M output tokens at 100 % utilization | ~84 | ~8 | ~5 |

**Coding agents** (`make agent-benchmark`: ~14k-token system prompt, 10-turn sessions, tool time between turns): one 8-chip TPU machine kept **~16 developers** within the SLO (p95 time to first token ≤ 5 s). At 16 developers that's ~1.44 USD per active developer-hour, against ~3.54 USD for the same tokens through the Sonnet 5.5 API with prompt caching. Agents read a lot and write little (~21k tokens in, ~100 out per turn, 93 % reused prefix), so prefix caching dominates the cost on both sides.

The rule of thumb: **cost per token = hourly price ÷ (tokens/s × 3 600 × utilization)**. The formula is simple; utilization is the hard part.

### Saving money

Accelerator node pools scale to zero when no model pod is scheduled:

```bash
make sleep                          # all models → 0 replicas; nodes go away after ~10 min
make wake                           # back to 1 replica; reloads from the cached weights
make sleep MODEL=gemma-4-31b-tpu    # just one
make down                           # destroy everything (waits for weight-cache disks first)
```

## Lessons learned

- **Quota ≠ capacity.** On-demand 8× B200, 8× RTX PRO 6000 and 8-chip TPU v6e all came back "out of resources" in Europe at short notice. Reservations or flex-start are the reliable paths.
- **GKE requires TPU type and topology** (`cloud.google.com/gke-tpu-accelerator`, `cloud.google.com/gke-tpu-topology`) in the `nodeSelector` of any pod requesting `google.com/tpu`; its admission policy rejects the pod otherwise.
- **Accelerators go under `limits` only.** Kubernetes copies them to `requests`; if you set both, they must be equal.
- **Rolling updates hang** with one replica per node and a `ReadWriteOnce` weight cache: use `strategy: Recreate`.
- **`/dev/shm`** must be enlarged (memory-backed `emptyDir`) when a model is split across accelerators.
- **Clients send parameters models reject.** Claude Code sends `reasoning_effort`; strip it per model with `gateway.drop_params`.

## Repository layout

| Path | What |
|---|---|
| [`models.yaml`](models.yaml) | Model catalogue: hardware and serving flags per model |
| [`infrastructure/gcp/`](infrastructure/gcp/) | Stack 1: network, GKE, accelerator node pools, Cloud SQL |
| [`platform/`](platform/) | Stack 2: vLLM releases, LiteLLM, Open WebUI, kagent |
| [`scripts/`](scripts/) | `benchmark.py` and `agent_benchmark.py` |
| [`demo/`](demo/) | The broken workload for the kagent demo |
| [`docs/adding-a-model.md`](docs/adding-a-model.md) | How to add or swap a model |
