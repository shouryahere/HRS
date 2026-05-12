# Phase 3 — Observability

Three-pillar observability (metrics, traces, logs) with multi-tenant isolation: every signal carries `tenant_id`, enabling per-team dashboards and alerts without cross-tenant data leakage.

## Architecture

```
Application Pods (OTel SDK)
        │  OTLP gRPC → node-local OTel Collector DaemonSet
        │                      │
        │            ┌─────────┴──────────┐
        │          Metrics              Traces
        │      (+ k8s cadvisor)       (enriched with
        │                              tenant_id)
        │                      │
        │              New Relic OTLP Endpoint
        │
Fluent Bit DaemonSet ──────────────────── CloudWatch Logs
  (enriched with namespace/pod labels)   /aws/eks/hrs-platform/applications
```

## Components

| Component | Location | Purpose |
|-----------|----------|---------|
| OTel Collector DaemonSet | `otel/otel-collector.yaml` | Receive OTLP from pods; scrape cadvisor; enrich with `tenant_id`; export to New Relic |
| Fluent Bit DaemonSet | `fluent-bit/fluent-bit.yaml` | Collect container logs; enrich with k8s metadata; ship to CloudWatch |
| Sample App | `sample-app/` | Python/FastAPI with OTel instrumentation, RDS Proxy, ESO-injected secrets |
| Platform Dashboard | `dashboards/platform-overview.json` | Cluster health, SLO burn rate, cross-tenant error/latency |
| Per-Tenant Dashboard | `dashboards/per-tenant.json` | Service health, latency percentiles, DB query performance |
| DORA Metrics Dashboard | `dashboards/dora-metrics.json` | Deployment frequency, lead time, change failure rate, MTTR |
| Alert Rules | `alerts/alert-rules.yaml` | SLO breach, high latency, CrashLoop, node memory, TLS expiry, RDS |

## Deploy

### OTel Collector

```bash
# Create the monitoring namespace (includes PSS privileged label for DaemonSet)
kubectl apply -f otel/otel-collector.yaml
```

### Fluent Bit

Patch the IRSA annotation on the ServiceAccount before applying:

```bash
FLUENT_BIT_ROLE=$(cd ../2_infrastructure/terraform && terraform output -raw fluent_bit_role_arn 2>/dev/null || echo "<role-arn>")

kubectl annotate serviceaccount -n monitoring fluent-bit \
  eks.amazonaws.com/role-arn="${FLUENT_BIT_ROLE}"

kubectl apply -f fluent-bit/fluent-bit.yaml
```

### Sample app

```bash
# Build and push (CI handles this; manual build for testing)
docker build -t sample-app:local sample-app/
kubectl apply -f sample-app/deployment.yaml
```

## Tenant isolation in telemetry

All OTel signals carry `tenant_id` (set from the `team` namespace label by the `k8sattributes` processor). This means:

- New Relic NRQL queries can `FACET tenant_id` to compare teams
- Alerts are faceted by `tenant_id` — one noisy tenant doesn't mask another's SLO breach
- CloudWatch Logs use `log_stream_prefix = namespace/` — cross-account queries remain possible but teams cannot see each other's log groups

## Dashboards

Import the JSON dashboard definitions into New Relic via the UI or NR CLI:

```bash
# Using NR CLI
nr1 nerdgraph query --query "$(cat dashboards/platform-overview.json)"
```

Or paste the JSON into New Relic → Dashboards → Import.

## Alert thresholds

| Alert | Warning | Critical |
|-------|---------|----------|
| Error rate | 0.05% | 0.1% (SLO breach) |
| P99 latency | 1,000 ms | 2,000 ms |
| Pod restarts | — | 5 in 5 min |
| Node memory | 75% | 85% |
| TLS expiry | 14 days | 7 days |
| RDS CPU | 60% | 80% |
| RDS connections | 700 | 900 |

## SLO definition

**Target**: 99.9% availability (43 minutes downtime budget per month)

Measured as: `(total_requests - 5xx_responses) / total_requests × 100`

- Burn rate window: 1h fast-burn + 24h slow-burn (multi-window alerting)
- Error budget dashboard refreshes every 5 minutes
