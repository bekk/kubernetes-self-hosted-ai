# AI Datacenter

![OpenTofu Badge](https://img.shields.io/badge/OpenTofu-FFDA18?logo=opentofu&logoColor=000&style=for-the-badge)
![vLLM Badge](https://img.shields.io/badge/vLLM-30A2FF?logo=vllm&logoColor=fff&style=for-the-badge)
![Google Cloud Badge](https://img.shields.io/badge/Google%20Cloud-4285F4?logo=googlecloud&logoColor=fff&style=for-the-badge)
![Helm Badge](https://img.shields.io/badge/Helm-0F1689?logo=helm&logoColor=fff&style=for-the-badge)

Self-hosted AI inference platform on GKE. Deploy [vLLM](https://docs.vllm.ai/) for GPU-accelerated model serving, [LiteLLM](https://www.litellm.ai/) as a unified API gateway, and [Open WebUI](https://openwebui.com/) as a ChatGPT-like portal — all in one `tofu apply` + `helm install`.

Built for teams and businesses that want private, cost-effective LLM access for their developers — without sending data to third-party APIs.

## Architecture

```
Users → Open WebUI → LiteLLM (API gateway) → vLLM Router → per-model vLLM Deployment (on GPU nodes)
```

- **Open WebUI** — ChatGPT-style web interface. Users pick a model from a dropdown and chat.
- **LiteLLM** — OpenAI-compatible API proxy. Routes requests, tracks usage, and manages API keys. Any tool that speaks the OpenAI API can connect here.
- **vLLM Router** — Distributes inference requests across vLLM instances for a given model.
- **vLLM Deployments** — One Kubernetes Deployment per model, each pinned to a dedicated GPU node pool.

Infrastructure and applications are **decoupled via a label convention**. Each model gets a unique key (e.g. `gemma-4`). OpenTofu creates a node pool with the label `ai.bekk.no/model: gemma-4`, and the Helm chart uses a matching `nodeSelector` to schedule the vLLM pod onto that pool. This means you can add a model by editing two config files — no code changes required.

## Verified Models

Models tested and confirmed to work on this platform:

| Model | HuggingFace ID | Model Key | Node Label | GCP Machine (SKU) | GPU | VRAM Used | Notes |
|-------|----------------|-----------|------------|--------------------|-----|-----------|-------|
| Gemma 4 27B IT | `google/gemma-4-27b-it` | `gemma-4` | `ai.bekk.no/model: gemma-4` | `g2-standard-8` | 1× NVIDIA L4 (24 GB) | ~14–16 GB (INT4) | MoE — 26B total, 3.8B active. Fits on a single L4 with INT4 quantization. |

> [!NOTE]
> This table will grow as more models are tested. See [Adding a Model](docs/adding-a-model.md) for how to onboard new models.

## Prerequisites

### Tools

| Tool | Version | Install |
|------|---------|---------|
| OpenTofu | ≥ 1.6 | [opentofu.org](https://opentofu.org/docs/intro/install/) |
| Helm | ≥ 3.12 | [helm.sh](https://helm.sh/docs/intro/install/) |
| kubectl | ≥ 1.28 | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| gcloud CLI | latest | [cloud.google.com](https://cloud.google.com/sdk/docs/install) |

### GCP Project Setup

1. **Create or select a GCP project:**

   ```bash
   gcloud projects create my-ai-datacenter --name="AI Datacenter"
   # or
   gcloud config set project my-ai-datacenter
   ```

2. **Enable required APIs:**

   ```bash
   gcloud services enable container.googleapis.com compute.googleapis.com
   ```

3. **Request GPU quota.** GPU node pools require quota approval. Spot instances need a separate quota from on-demand.

   Check your current quota:

   ```bash
   gcloud compute regions describe europe-west4 \
     --format="table(quotas.metric,quotas.limit,quotas.usage)" \
     | grep -i gpu
   ```

   Request increases in the [GCP Console → IAM & Admin → Quotas](https://console.cloud.google.com/iam-admin/quotas). Look for:
   - `NVIDIA_L4_GPUS` (on-demand)
   - `PREEMPTIBLE_NVIDIA_L4_GPUS` (Spot)

4. **Authenticate:**

   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```

### HuggingFace Token

Required for gated models (e.g. Gemma, Llama).

1. Create a [HuggingFace account](https://huggingface.co/join).
2. Navigate to the model page (e.g. [google/gemma-4-27b-it](https://huggingface.co/google/gemma-4-27b-it)) and accept the license agreement.
3. Create an access token at [Settings → Access Tokens](https://huggingface.co/settings/tokens).
4. Create the Kubernetes secret:

   ```bash
   kubectl create secret generic hf-token \
     --namespace ai-datacenter \
     --from-literal=token=hf_xxx
   ```

### External Database (Optional)

The Helm chart includes a bundled PostgreSQL instance by default — no extra setup needed for development or evaluation.

For production, point LiteLLM and Open WebUI at an external database (e.g. Cloud SQL). Create the secret with connection strings for both services:

```bash
kubectl create secret generic ai-datacenter-db-credentials \
  --namespace ai-datacenter \
  --from-literal=litellm-database-url="postgresql://user:password@host:5432/litellm" \
  --from-literal=open-webui-database-url="postgresql://user:password@host:5432/openwebui"
```

## Quick Start

### 1. Provision Infrastructure

```bash
cd infrastructure/gcp
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your GCP project, region, and desired models. Then:

```bash
tofu init
tofu plan
tofu apply
```

### 2. Connect to the Cluster

```bash
gcloud container clusters get-credentials ai-datacenter \
  --zone europe-west4-a \
  --project my-ai-datacenter
```

### 3. Deploy Applications

```bash
cd applications
helm dependency update
helm install ai-datacenter . --namespace ai-datacenter --create-namespace
```

### 4. Access Open WebUI

```bash
kubectl port-forward svc/open-webui 8080:80 --namespace ai-datacenter
```

Open [http://localhost:8080](http://localhost:8080) and create your admin account.

## Contents

| Directory | Description |
|-----------|-------------|
| `infrastructure/` | OpenTofu modules for GKE cluster with GPU node pools. One node pool per model, with configurable machine type, GPU count, and Spot scheduling. |
| `applications/` | Helm umbrella chart packaging vLLM, LiteLLM, and Open WebUI into a single deployable unit. |
| `docs/` | Guides and reference documentation. |
