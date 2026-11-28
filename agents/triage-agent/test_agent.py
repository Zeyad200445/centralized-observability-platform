import asyncio, json
from app.agent import run_triage
from app.schemas import AlertItem

alert = AlertItem(
    fingerprint="test-fp-001",
    labels={"alertname": "GCPExporterDown", "namespace": "monitoring", "severity": "warning"},
    annotations={"summary": "GCP Stackdriver exporter is restarting"},
)
rec = asyncio.run(run_triage(alert))
print(json.dumps(rec.model_dump(), indent=2))
