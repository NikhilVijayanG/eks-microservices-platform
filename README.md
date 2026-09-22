# EKS Microservices Platform

Production-grade Kubernetes platform on AWS EKS, fully defined in Terraform, with
Prometheus/Grafana/Loki observability and GitHub Actions CI/CD for both infrastructure
and applications. Ships with three sample microservices (gateway → orders → products)
that demonstrate the full path from commit to monitored production deployment.

```
                          GitHub Actions (OIDC, no static keys)
      ┌──────────────────────────────┬─────────────────────────────────────┐
      │ terraform.yml                │ ci.yml            deploy.yml         │
      │ fmt·validate·tflint·checkov  │ tests·trivy       build→ECR→sign     │
      │ plan (PR comment) → apply    │ kubeconform       dev → smoke → prod │
      └──────────────┬───────────────┴───────────────┬─────────────────────┘
                     ▼                               ▼
   ┌────────────────────────────────────────────────────────────────────────┐
   │ AWS account                                                            │
   │  VPC (3 AZ, private nodes, NAT/AZ, VPC endpoints, flow logs)           │
   │  ┌──────────────────────────── EKS 1.30 ────────────────────────────┐  │
   │  │ managed node groups (on-demand system · spot apps), IRSA, KMS    │  │
   │  │ addons: vpc-cni · coredns · kube-proxy · ebs-csi · pod-identity  │  │
   │  │ ─────────────────────── kube-system ───────────────────────────  │  │
   │  │ AWS LB Controller · metrics-server · cluster-autoscaler ·        │  │
   │  │ cert-manager · (external-dns)                                    │  │
   │  │ ─────────────────────── monitoring ────────────────────────────  │  │
   │  │ Prometheus Operator · Prometheus(HA) · Alertmanager(HA) ·        │  │
   │  │ Grafana · node-exporter · kube-state-metrics · Loki · Promtail   │  │
   │  │ ─────────────────────── microservices ─────────────────────────  │  │
   │  │  ALB ──▶ gateway ──▶ orders ──▶ products                         │  │
   │  │  (HPA, PDB, NetworkPolicy, ServiceMonitor, PrometheusRule)       │  │
   │  └──────────────────────────────────────────────────────────────────┘  │
   │  ECR (immutable tags, scan-on-push) · S3+DynamoDB state · Secrets Mgr  │
   └────────────────────────────────────────────────────────────────────────┘
```

## Repository layout

```
terraform/
  bootstrap/          # one-time: S3 state bucket, DynamoDB lock, GitHub OIDC provider + role
  modules/
    vpc/              # subnets tagged for EKS/ALB discovery, NAT, VPC endpoints, flow logs
    eks/              # cluster, KMS envelope encryption, node groups (IMDSv2, gp3), IRSA, addons, access entries
      irsa/           # reusable IAM-role-for-service-account module
    ecr/              # one repo per service, lifecycle policies
    addons/           # Helm: aws-load-balancer-controller, metrics-server, cluster-autoscaler, cert-manager, external-dns
    monitoring/       # Helm: kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Loki, Promtail
  envs/
    dev/              # 2 AZ, single NAT, spot nodes, 7d retention – cheap
    prod/             # 3 AZ, NAT per AZ, on-demand system pool + spot app pool, HA monitoring
kubernetes/
  base/{gateway,orders,products}/   # Deployment, Service, SA, HPA, PDB, ServiceMonitor, NetworkPolicy (+Ingress)
  monitoring/                       # PrometheusRule (SLO recording + alerting rules), Grafana dashboard ConfigMap
  overlays/{dev,prod}/              # Kustomize: replicas, HPA bounds, anti-affinity, node pool, TLS/WAF
services/
  Dockerfile                        # shared multi-stage, non-root, healthcheck
  {gateway,orders,products}/        # Node.js services with Prometheus metrics, probes, JSON logs, tests
.github/workflows/
  terraform.yml   ci.yml   deploy.yml   deploy-env.yml
scripts/            # load-test.sh, local Prometheus/Grafana config
docker-compose.yml  # run the services + Prometheus + Grafana locally without Kubernetes
Makefile
```

## Prerequisites

- AWS account + CLI credentials with admin rights (for bootstrap)
- Terraform ≥ 1.6, kubectl, kustomize, Docker, Node 20 (for local tests)
- A GitHub repository for this code

## Getting started

### 1. Bootstrap (once per account)

Creates the remote-state backend and an IAM role GitHub Actions can assume via OIDC.

```bash
make bootstrap GITHUB_REPO=your-org/your-repo
# note the outputs: state_bucket, lock_table, github_actions_role_arn
```

Add these to the GitHub repo:

| Type | Name | Value |
|---|---|---|
| Secret | `AWS_ROLE_ARN` | `github_actions_role_arn` output |
| Secret | `TF_STATE_BUCKET` | `state_bucket` output |
| Secret | `TF_LOCK_TABLE` | `lock_table` output |
| Secret | `SLACK_WEBHOOK_URL` | (optional) Alertmanager → Slack |
| Variable | `AWS_REGION` | e.g. `us-east-1` |
| Variable | `PROJECT` | `msplatform` |

Create GitHub **Environments** `dev`, `prod`, `dev-plan`, `prod-plan`; add required reviewers on `prod`.

### 2. Provision the platform

Either push to `main` (the Terraform workflow plans on PR and applies on merge), or locally:

```bash
cp terraform/envs/dev/dev.example.tfvars terraform/envs/dev/dev.auto.tfvars   # add the CI role ARN to admin_role_arns
make plan ENV=dev
make apply ENV=dev          # ~20 minutes
make kubeconfig ENV=dev
kubectl get nodes && kubectl -n monitoring get pods
```

### 3. Deploy the services

Push to `main` and the **Build & Deploy** workflow will build all three images, scan them with
Trivy, push to ECR with immutable `sha-<commit>` tags, sign them with cosign (keyless), deploy
to `dev`, run an in-cluster smoke test, then wait for approval and deploy to `prod`. If a
rollout or smoke test fails it rolls back automatically.

Manually:

```bash
make push ENV=dev                 # build + push images tagged with the current git SHA
make deploy ENV=dev               # render overlay with that tag, apply, wait for rollout
make smoke ENV=dev                # call the ALB: list products, create an order
```

### 4. Observe

```bash
make grafana ENV=dev     # prints admin password from Secrets Manager, port-forwards :3000
make prometheus          # :9090
make alertmanager        # :9093
scripts/load-test.sh "" 120 0.3    # 2 min of traffic with 30% injected errors -> watch alerts fire
```

Grafana ships with the kube-prometheus-stack dashboards plus **Microservices – RED overview**
(request rate, error ratio, p50/p95/p99, upstream latency, CPU/memory vs limits, HPA, orders KPI,
Loki error logs). Alerts: `ServiceHighErrorRate`, `ServiceHighLatencyP95`, `ServiceDown`,
`UpstreamDependencyFailing`, `PodCrashLooping`, `HPAAtMaxReplicas`, `ContainerMemoryNearLimit`,
`DeploymentReplicasMismatch`, routed to Slack when `SLACK_WEBHOOK_URL` is set.

## Local development (no AWS)

```bash
docker compose up -d --build
curl localhost:8090/api/products
curl -X POST localhost:8090/api/orders -H 'content-type: application/json' -d '{"productId":"p-100","quantity":2}'
open http://localhost:9090        # Prometheus with the same alert rules as the cluster
open http://localhost:3300        # Grafana (admin/admin) with the same dashboard
scripts/load-test.sh http://localhost:8090 60 0.3
```

## CI/CD workflows

| Workflow | Trigger | Steps |
|---|---|---|
| **Terraform** | PR / push to `main` touching `terraform/**`, manual | fmt → validate all roots → tflint → checkov (SARIF) → plan per env (PR comment, artifact) → apply dev then prod (saved plan, protected env) · manual destroy |
| **CI** | PR touching `services/**` or `kubernetes/**` | path-filtered matrix: `npm test` → Docker build → Trivy (HIGH/CRITICAL gate) → container smoke run · kustomize build → kubeconform (incl. Prometheus Operator CRDs) → promtool rule check → kube-score |
| **Build & Deploy** | push to `main`, manual (env + optional existing tag) | build+push all services with SBOM/provenance → Trivy CRITICAL gate → cosign sign → **deploy-env** dev → **deploy-env** prod |
| **deploy-env** (reusable) | called by Build & Deploy | verify cosign signatures → `kustomize edit set image` → server-side dry run → apply → rollout status → in-cluster smoke test → auto rollback on failure → summary with ALB URL |

## Security posture

- No long-lived AWS keys: GitHub OIDC → IAM role; pods use IRSA (and pod-identity agent is installed).
- EKS secrets envelope-encrypted with KMS; control-plane audit logs on; IMDSv2 enforced; encrypted gp3 volumes.
- Nodes in private subnets; ECR/S3/STS/Logs via VPC endpoints; VPC flow logs.
- Namespace `microservices` enforces the **restricted** Pod Security Standard; workloads run non-root, read-only rootfs, all capabilities dropped, seccomp RuntimeDefault, no SA token automount.
- NetworkPolicies default-deny ingress except intra-namespace + Prometheus; gateway exposed only via ALB.
- Images: immutable tags, scan-on-push, Trivy gates in CI/CD, cosign keyless signatures verified before deploy.
- Prod ingress: TLS via ACM, HTTP→HTTPS redirect, WAFv2 hook, invalid-header dropping.

## Cost notes

Dev is sized to be cheap: 2 AZs, one NAT gateway, 2× t3.large **spot**, 7-day metrics, 3-day logs.
Roughly: EKS control plane $73/mo + NAT ~$35 + nodes ~$30 + EBS/ALB ~$25 ≈ **$160–180/month**.
Run `make destroy ENV=dev` when not in use. Prod defaults (3 AZ, NAT per AZ, on-demand system
pool, HA monitoring) start around $500/month before application load.

## Live deployment (dev) – verified

This platform was applied for real to account `064580992425` / `us-east-1` on 2026-09-22:

- `terraform apply` created 77 resources (VPC, EKS 1.30, 2× m7i-flex.large nodes, addons, monitoring).
- Images built, Trivy-scanned (0 CRITICAL/HIGH), cosign-signed and pushed by GitHub Actions via OIDC.
- The **Build & Deploy** workflow deployed to the cluster end to end (signature verify → render →
  server-side apply → rollout → in-cluster smoke test); the gateway serves `/version` with the CI tag.
- Prometheus: 23/23 targets up incl. all service pods; 12 SLO/alert rules loaded; HPA scaled the gateway
  under load. Loki receives pod logs. Grafana (via ALB) has the RED dashboard with live data.

Issues found and fixed during the real run (kept in git history):

| Symptom | Cause | Fix |
|---|---|---|
| Node group stuck `CREATING` 25 min, ASG `InvalidParameterCombination … not eligible for Free Tier` | Account is on the **AWS Free Tier plan**, which only allows free-tier-eligible instance types | dev uses `m7i-flex.large` on-demand (see `envs/dev/main.tf`) |
| `terraform plan`: *Invalid count argument* in IRSA module | `count` depended on an unknown policy JSON | explicit `attach_inline_policy` bool |
| OIDC `Not authorized to perform sts:AssumeRoleWithWebIdentity` | GitHub now issues ID-suffixed subjects `repo:owner@<id>/name@<id>:…` | trust policy accepts both formats |
| `trivy-action` could not download its binary | action installer flakiness | run `aquasec/trivy` container directly |
| Trivy: CRITICAL/HIGH in `npm`'s bundled `tar`, `minimatch`, `glob`, OpenSSL | npm ships in the node base image | runtime stage removes npm/corepack and runs `apk upgrade` |
| Smoke pod rejected: *violates PodSecurity "restricted"* | probe pod was not hardened | hardened `securityContext` via `--overrides` |
| SSA dry-run *conflict with "kubectl"* on `image` | earlier `rollout undo` took field ownership | dry-run uses `--force-conflicts` like apply |

## Verification performed (offline)

- `terraform fmt -check` and `terraform validate` pass for `bootstrap`, `envs/dev`, `envs/prod`.
- `kubectl kustomize` renders 24 resources per overlay; `kubeconform -strict` validates all 48
  against Kubernetes and Prometheus Operator schemas (0 skipped).
- 10 unit tests pass across the three services.
- Local `docker compose` stack: images build, containers healthy and non-root, gateway → orders →
  products round-trip works, Prometheus scrapes all three targets, 12 recording/alerting rules load,
  error-ratio recording rule reflects injected failures, Grafana dashboard provisioned.
- All four workflow files parse as valid YAML.

Not verified here (requires an AWS account): `terraform apply`, Helm chart installation and
live ALB provisioning. Chart/app versions are pinned in module variables — check for newer
releases before first apply.

## Extending

- **New service**: copy `services/products`, add a `kubernetes/base/<name>` (copy + `sed`),
  reference it in both overlays, add the name to `var.services` (ECR) and the `SERVICES` lists in
  `Makefile`, `deploy.yml`, `deploy-env.yml`.
- **GitOps**: swap the `deploy-env` apply step for an Argo CD/Flux `Application` pointing at the
  overlay; the image-tag update step stays the same.
- **Karpenter**: subnets are already tagged `karpenter.sh/discovery`; replace the app node group
  and cluster-autoscaler with a Karpenter NodePool.
- **Private cluster**: set `endpoint_public_access = false` and run the deploy job on a
  self-hosted runner inside the VPC (or via SSM/VPN).
