# ══════════════════════════════════════════════════════════════════════════════
# AI Datacenter — one command up, one command down
# ══════════════════════════════════════════════════════════════════════════════
#   make up            Provision infrastructure, then deploy the platform
#   make down          Tear everything down (platform first, then infrastructure)
#   make status        Show GPU nodes and model pods
#   make port-forward  LiteLLM on :4000, Open WebUI on :8080
#   make claude-env    Print the env vars that point Claude Code at LiteLLM
#   make sleep / wake  Scale every model to 0 / back to 1 replica
#   make benchmark     Throughput + cost per 1M tokens (needs make port-forward)
#   make agent-benchmark  Many developers running coding agents at once
#   make demo-break    Deploy a model that bypasses the platform (stays Pending)
#   make demo-fix      Remove it again
# ══════════════════════════════════════════════════════════════════════════════

INFRA     := infrastructure/gcp
PLATFORM  := platform
NAMESPACE := ai-datacenter
TOFU      := tofu

# Every kubectl call is pinned to this cluster, whatever your current context
# is. Make expands a recipe before running it, so `down` still sees these
# values after the infrastructure state is gone.
KUBE_CONTEXT = $(shell $(TOFU) -chdir=$(INFRA) output -raw kube_context 2>/dev/null | grep '^gke_')
PROJECT_ID   = $(word 2,$(subst _, ,$(KUBE_CONTEXT)))
KUBECTL      = kubectl --context=$(or $(KUBE_CONTEXT),$(error No cluster in infrastructure state - run 'make infra' first))

.NOTPARALLEL:
.PHONY: up down infra platform plan credentials status logs port-forward claude-env sleep wake benchmark agent-benchmark demo-break demo-fix

up: infra credentials platform

infra:
	$(TOFU) -chdir=$(INFRA) init -input=false
	$(TOFU) -chdir=$(INFRA) apply

platform:
	$(TOFU) -chdir=$(PLATFORM) init -input=false
	$(TOFU) -chdir=$(PLATFORM) apply

plan:
	$(TOFU) -chdir=$(INFRA) plan
	$(TOFU) -chdir=$(PLATFORM) plan

# The weight caches are 200 GB–1.2 TB Hyperdisks. They are only deleted once
# their pods are gone, so wait for that before deleting the cluster —
# otherwise they are orphaned and keep billing.
down:
	$(TOFU) -chdir=$(PLATFORM) destroy
	-$(KUBECTL) wait --for=delete pv --all --timeout=15m
	$(TOFU) -chdir=$(INFRA) destroy
	@echo "Leftover disks (should be empty):"
	@gcloud compute disks list --project=$(PROJECT_ID) --filter="name~^pvc-" --format="table(name,zone,sizeGb)"

credentials:
	$$($(TOFU) -chdir=$(INFRA) output -raw get_credentials_command)

status:
	$(KUBECTL) get nodes -L ai.bekk.no/model,ai.bekk.no/tier
	$(KUBECTL) -n $(NAMESPACE) get pods -o wide

# Usage: make logs MODEL=glm-5-3
logs:
	$(KUBECTL) -n $(NAMESPACE) logs -f deploy/vllm-$(MODEL)

port-forward:
	@echo "LiteLLM:    http://localhost:4000   (UI at /ui)"
	@echo "Open WebUI: http://localhost:8080"
	@echo "kagent UI:  http://localhost:8081   (if enable_kagent = true)"
	trap 'kill 0' INT TERM EXIT; \
	$(KUBECTL) -n $(NAMESPACE) port-forward svc/litellm 4000:4000 & \
	$(KUBECTL) -n $(NAMESPACE) port-forward svc/open-webui 8080:80 & \
	$(KUBECTL) -n kagent port-forward svc/kagent-ui 8081:8080 2>/dev/null & \
	wait

claude-env:
	@echo "export ANTHROPIC_BASE_URL=http://localhost:4000"
	@echo "export ANTHROPIC_AUTH_TOKEN=$$($(TOFU) -chdir=$(PLATFORM) output -raw litellm_master_key)"
	@echo "export ANTHROPIC_DEFAULT_OPUS_MODEL=large"
	@echo "export ANTHROPIC_DEFAULT_SONNET_MODEL=medium"
	@echo "export ANTHROPIC_DEFAULT_HAIKU_MODEL=small"

# Scaling to 0 lets the autoscaler remove the GPU nodes (~10 min idle). The
# weight caches (PVCs) survive, so `make wake` only reloads from disk.
# Usage: make sleep [MODEL=glm-5-3]   — omit MODEL to sleep all models
sleep:
	$(KUBECTL) -n $(NAMESPACE) scale deploy --replicas=0 $(if $(MODEL),vllm-$(MODEL),-l app.kubernetes.io/name=vllm)

wake:
	$(KUBECTL) -n $(NAMESPACE) scale deploy --replicas=1 $(if $(MODEL),vllm-$(MODEL),-l app.kubernetes.io/name=vllm)

# Hourly prices are rough on-demand list prices for the TPU tiers in us-east5;
# API prices are Anthropic list prices (output, per 1M tokens) as of Oct 2026.
# Override with: make benchmark BENCH_ARGS="--models small --concurrency 1,8"
BENCH_ARGS ?= --models small,medium --concurrency 1,4,8,16 \
	--price small=11 --price medium=23 \
	--api-price "Opus 5.5=20" --api-price "Sonnet 5.5=10" --api-price "Haiku 5.5=0.5"

benchmark:
	python3 scripts/benchmark.py $(BENCH_ARGS) --json benchmark-$$(date +%Y%m%d-%H%M).json

# Simulated developers running coding agents against the medium tier. API
# prices are input/output/cache-read per 1M tokens (Anthropic, Oct 2026).
AGENT_BENCH_ARGS ?= --model medium --developers 4,8,16,32 --duration 120 --price 23 \
	--api "Sonnet 5.5=2/10/0.2" --api "Opus 5.5=4/20/0.2"

agent-benchmark:
	python3 scripts/agent_benchmark.py $(AGENT_BENCH_ARGS) --json agent-benchmark-$$(date +%Y%m%d-%H%M).json

# kagent demo: a workload that bypasses models.yaml and never schedules.
# Costs nothing: no node pool matches, and the image is a pause container.
demo-break:
	$(KUBECTL) apply -f demo/ny-modell.yaml
	@echo "Ask plattform-agent in the kagent UI: «Teamet mitt deployet ny-modell, men den starter aldri. Hvorfor?»"

demo-fix:
	$(KUBECTL) delete -f demo/ny-modell.yaml --ignore-not-found
