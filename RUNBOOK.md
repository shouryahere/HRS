# HRS Multi-Tenant Platform — Runbook

Operational status, deployment summary, known gaps, and recovery steps for the
DevOps engineer technical assessment.

## TL;DR — what's live

| Component                  | Status      | Notes                                                       |
| -------------------------- | ----------- | ----------------------------------------------------------- |
| VPC, NAT, endpoints, flow logs | ✅       | Multi-AZ, S3/ECR/STS/SecretsManager VPC endpoints           |
| EKS 1.32 + managed node group | ✅        | etcd encrypted with KMS, audit logs to CloudWatch           |
| Cilium ENI chaining       | ✅          | Hubble relay/UI not functional (see Known gaps)             |
| ArgoCD                    | ✅           | GitOps for tenant apps                                       |
| Kyverno + policies        | ✅           | Cleanup CronJob image overridden (see eks.tf)               |
| cert-manager              | ✅           | Let's Encrypt issuer + ACM wildcard for `*.platform.talkit.chat` |
| External Secrets Operator | ✅           | IRSA → Secrets Manager, per-tenant scoping                  |
| AWS Load Balancer Controller | ✅        | ALB w/ ACM TLS, IP target type                              |
| Route53 hosted zone       | ✅           | NS records delegated at GoDaddy                             |
| 3 tenant namespaces       | ✅           | team-01, team-02, team-03 — RBAC, IRSA, NetworkPolicies, ExternalSecrets |
| **All 3 sample apps**     | ✅ **HTTP 200** | https://team-{01,02,03}.platform.talkit.chat → 3 ALBs → 6 nginx pods |
| ExternalSecrets sync (all 3 tenants + monitoring NR) | ✅ | SecretSynced=True                          |
| RDS Postgres + RDS Proxy  | ✅          | Per-tenant DB users provisioned                              |
| **Fluent Bit DaemonSet**  | ✅ 3/3       | Logs → CloudWatch, enriched with namespace + pod labels      |
| **OTel Collector DaemonSet** | ✅ 3/3    | OTLP receiver on 4317/4318 → New Relic OTLP exporter        |
| **Hubble Relay**          | ✅ 1/1       | Connected to all 3 node agents (fixed via internalTrafficPolicy=Cluster) |
| **Hubble UI**             | ✅ 2/2       | Frontend + backend Running (fixed via TCP-socket liveness probe) |
| Karpenter                 | ⚠️ Disabled  | IAM fixed; blocked by Karpenter v1.0 + EKS 1.32 version incompat — see Known gaps |
| NR alert policies         | 📝 Designed  | `3_observability/alerts/alert-rules.yaml` — applied via NR Terraform provider, not k8s |

---

## Demo URLs

| What                 | URL                                                  |
| -------------------- | ---------------------------------------------------- |
| Sample app team-01   | https://team-01.platform.talkit.chat                 |
| Sample app team-02   | https://team-02.platform.talkit.chat                 |
| Sample app team-03   | https://team-03.platform.talkit.chat                 |
| ArgoCD UI            | `kubectl port-forward -n argocd svc/argocd-server 8080:443` |

Verify end-to-end (each ALB hostname is in `kubectl get ing -n team-NN sample-app`):

```bash
for T in team-01 team-02 team-03; do
  HOST=$(kubectl get ing -n $T sample-app -o jsonpath='{.spec.rules[0].host}')
  ADDR=$(kubectl get ing -n $T sample-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  echo "$T: $(curl -s -o /dev/null -w '%{http_code}' -k -H "Host: $HOST" https://$ADDR/)"
done
# expect: team-01: 200, team-02: 200, team-03: 200
```

---

## How to bring this up from zero

```bash
# 1. State backend (idempotent, run once)
./scripts/bootstrap.sh

# 2. Sourceable secrets (file is gitignored, mode 600)
cd 2_infrastructure/terraform
source .secrets.local   # TF_VAR_rds_master_password, TF_VAR_newrelic_license_key

# 3. Single command brings up everything.
terraform init
terraform apply         # ~25 min — calls scripts/apply-manifests.sh at the end
                        # which applies all k8s + observability manifests +
                        # iterates the sample app across team-01/02/03.
```

That's the whole bring-up. Terraform now drives the Kubernetes manifest apply
via a `null_resource` provisioner (`null_resource.apply_manifests` in
[eks.tf](2_infrastructure/terraform/eks.tf)), so a fresh `terraform apply`
produces a working cluster with 3 tenants serving HTTP 200 — no `kubectl`
commands needed by hand.

### What still needs a human (and why)

| Step | Why it stays manual |
| ---- | ------------------- |
| Adding NS records at GoDaddy for the subdomain delegation | External registrar; outside AWS/Terraform's reach |
| Sourcing `.secrets.local` before `terraform apply` | Secret material; intentionally not in Git or in S3 plain state |
| Pushing tenant container images to per-team ECR (`docker push 390635870841.dkr.ecr.eu-central-1.amazonaws.com/hrs-platform/team-NN/app:latest`) | Build artifact; lives in the team's own CI pipeline, not this repo |
| Upgrading Karpenter to ≥ v1.5 (currently pinned at 1.0 + replicas=0) | K8s 1.32 compat requires breaking values migration — needs a maintenance window, not the demo apply |

---

## Known gaps & why

### Karpenter is scaled to 0
**Two compounding issues, one fixed, one structural.**

**Fixed:** Karpenter v1.0 requires `iam:GetInstanceProfile` plus 5 related
instance-profile actions, `ec2:DescribeSpotPriceHistory`, and
`pricing:GetProducts`. These were missing from the original IAM policy and
have been added in [iam.tf](2_infrastructure/terraform/iam.tf). Verified by
controller startup logs showing successful SSM parameter discovery (which
requires `ssm:GetParameter`) and no further AccessDenied errors.

**Structural blocker:** Karpenter v1.0.0 explicitly refuses to provision
nodes on Kubernetes 1.32 (`"karpenter version is not compatible with K8s
version 1.32"`). The fix is to upgrade Karpenter to ≥ v1.5, but that chart
version introduces a breaking values migration around feature gates
(`NodeRepair` requires a non-empty value) and the Helm chart's `service`
template requires `service.annotations` to be a defined map rather than nil.
A clean upgrade needs explicit values reconstruction — too risky to do
inside the assessment window without test coverage.

The managed node group covers all current load. Karpenter would carry the
spiky / opportunistic workloads in production.

**To re-enable (after fixing the version compat):**
```bash
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.5.0 --namespace karpenter \
  -f karpenter-values.yaml          # full values file, no --reuse-values
kubectl scale deployment/karpenter -n karpenter --replicas=1
```

### Hubble UI / Relay — fixed in IaC
Cilium ENI chaining mode (`eni.enabled=true, ipam.mode=eni, tunnel=disabled`)
on top of the AWS VPC CNI exposes two latent bugs in the Cilium 1.15 Helm
chart defaults:

1. The `hubble-peer` Service ships with `internalTrafficPolicy: Local`,
   which prevents the single hubble-relay replica from reaching agents on
   other nodes via the Service ClusterIP. Patched to `Cluster` in
   `null_resource.hubble_peer_cluster_traffic` in [eks.tf](2_infrastructure/terraform/eks.tf).
2. The `hubble-ui` frontend liveness probe is httpGet on `/healthz` with
   `timeoutSeconds: 1`. In Cilium ENI mode nginx isn't reliably answering
   the probe in 1s during startup, so the container crashloops at ~30s
   intervals. Switched to a TCP-socket probe with looser timing via Helm
   values in the `cilium` release.

Both Hubble Relay (1/1) and Hubble UI (2/2) are now Running. View flows at
`kubectl port-forward -n kube-system svc/hubble-ui 12000:80`.

### New Relic alert policies
[`3_observability/alerts/alert-rules.yaml`](3_observability/alerts/alert-rules.yaml)
is a declarative YAML of 5 NR alert policies (SLO breach, P99 latency, pod
crash loop, node memory pressure, cert expiry). These are applied via the
New Relic Terraform provider (not kubectl) because alert policies live in NR,
not the cluster. Stub provider invocation is intentionally out of scope for
the assessment apply path.

---

## Operational gotchas

### Cilium conntrack SourceSecurityID=0 race at pod startup
**Symptom:** Pod in `CrashLoopBackOff` with `i/o timeout` dialing
`172.20.0.1:443` (kube-apiserver ClusterIP), even though the same code path
worked moments before.

**Root cause:** A pod opens its first connection before Cilium has resolved
its security identity. The resulting CT entry carries `SourceSecurityID=0`
and is never matched by subsequent policy evaluation, so the pod is stuck
in the "no policy permits this flow" path until the entry expires.

**Recovery:**
```bash
for P in $(kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[*].metadata.name}'); do
  kubectl exec -n kube-system $P -- cilium bpf ct flush global
done
kubectl rollout restart deployment/<affected> -n <namespace>
```

The prevention is `platform-cilium-network-policies.yaml`, which names
`kube-apiserver` as a reserved Cilium entity in an egress allow rule. That
forces correct identity resolution at policy-eval time and bypasses the race.

### ALB targets time out despite healthy pods
**Symptom:** Health probes succeed locally on the pod (`curl localhost:8080`
→ 200) but the ALB target group shows "Request timed out".

**Root cause:** EC2 SrcDstCheck on the node ENI. In Cilium ENI mode, pod IPs
are managed by Cilium IPAM and may not be listed as explicit secondary IPs on
the ENI in EC2's view; the ENI's default `SrcDstCheck=true` drops the packet.

**Fix is now in IaC** (`null_resource.disable_node_eni_srcdstcheck` in
[eks.tf](2_infrastructure/terraform/eks.tf)) and runs after every `terraform apply`.

---

## Cost & teardown

Approximate run cost: **~$45/day** (NAT × 3 AZs dominates; managed NG t3.medium ×
3; RDS db.t3.small Multi-AZ; ALB). When the demo is no longer needed:

```bash
cd 2_infrastructure/terraform
source .secrets.local
terraform destroy
```

Destroy is non-trivial because of Kubernetes finalizers on ALB-managed Ingress
resources. If destroy hangs, delete Ingress objects first:
```bash
kubectl delete ingress --all -A
```
