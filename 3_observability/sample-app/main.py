"""
Sample tenant workload — Python/FastAPI with OpenTelemetry instrumentation.

Demonstrates:
  - OTLP trace export to the node-local OTel Collector DaemonSet
  - Custom span attributes (tenant_id, user_id)
  - Prometheus-compatible metrics via OTel SDK
  - Structured JSON logging enriched with trace/span IDs
  - DB query via RDS Proxy using DATABASE_URL from Secrets Manager (ESO-injected)
"""

import logging
import os
import json

from fastapi import FastAPI, HTTPException
import psycopg2
from psycopg2.extras import RealDictCursor
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource, SERVICE_NAME
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor

# ── OTel setup ─────────────────────────────────────────────────────────────────
TEAM_ID = os.getenv("TEAM_ID", "unknown")
SERVICE = os.getenv("OTEL_SERVICE_NAME", f"{TEAM_ID}-sample-app")
# OTEL_EXPORTER_OTLP_ENDPOINT points to the node-local DaemonSet (injected via Downward API)
OTEL_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")

resource = Resource(attributes={
    SERVICE_NAME: SERVICE,
    "tenant_id": TEAM_ID,
    "deployment.environment": os.getenv("ENVIRONMENT", "production"),
})

provider = TracerProvider(resource=resource)
exporter = OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True)
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(SERVICE)

# Auto-instrument FastAPI and psycopg2
FastAPIInstrumentor.instrument()
Psycopg2Instrumentor().instrument()

# ── Structured logging ─────────────────────────────────────────────────────────
class JSONFormatter(logging.Formatter):
    def format(self, record):
        span = trace.get_current_span().get_span_context()
        log_record = {
            "level": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
            "tenant_id": TEAM_ID,
            "trace_id": format(span.trace_id, "032x") if span.is_valid else None,
            "span_id": format(span.span_id, "016x") if span.is_valid else None,
        }
        return json.dumps(log_record)

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logging.basicConfig(handlers=[handler], level=logging.INFO, force=True)
logger = logging.getLogger(SERVICE)

# ── FastAPI app ────────────────────────────────────────────────────────────────
app = FastAPI(title=f"{TEAM_ID} sample app")

DATABASE_URL = os.getenv("DATABASE_URL")  # Injected by ESO via ExternalSecret


@app.get("/health")
def health():
    return {"status": "ok", "team": TEAM_ID}


@app.get("/items")
def list_items():
    """Return items for this tenant — demonstrates RLS enforcement."""
    if not DATABASE_URL:
        raise HTTPException(status_code=500, detail="DATABASE_URL not configured")

    with tracer.start_as_current_span("db.list_items") as span:
        span.set_attribute("tenant_id", TEAM_ID)
        span.set_attribute("db.operation", "SELECT")

        try:
            conn = psycopg2.connect(DATABASE_URL, cursor_factory=RealDictCursor)
            cur = conn.cursor()

            # Set app.tenant_id so RLS policies can enforce row-level isolation
            cur.execute("SET app.tenant_id = %s", (TEAM_ID,))
            cur.execute("SELECT id, name, created_at FROM items LIMIT 100")
            rows = cur.fetchall()
            conn.close()

            logger.info("Listed %d items for tenant %s", len(rows), TEAM_ID)
            return {"team": TEAM_ID, "items": rows}

        except Exception as exc:
            span.record_exception(exc)
            logger.error("DB error: %s", exc)
            raise HTTPException(status_code=500, detail="Database error")
