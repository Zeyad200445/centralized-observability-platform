from typing import Any, Literal, Optional
from pydantic import BaseModel, Field


class AlertItem(BaseModel):
    status: str = "firing"
    labels: dict[str, str] = Field(default_factory=dict)
    annotations: dict[str, str] = Field(default_factory=dict)
    startsAt: Optional[str] = None
    fingerprint: str = "unknown"


class AlertmanagerPayload(BaseModel):
    status: str = "firing"
    alerts: list[AlertItem] = Field(default_factory=list)
    commonLabels: dict[str, str] = Field(default_factory=dict)
    commonAnnotations: dict[str, str] = Field(default_factory=dict)


class TriageNote(BaseModel):
    summary: str = Field(description="1-2 sentence summary of what is happening.")
    evidence: list[str] = Field(
        description="Concrete facts gathered from Prometheus, Elasticsearch, or Kubernetes."
    )
    likely_cause: str = Field(description="Most probable root cause based strictly on evidence.")
    confidence: Literal["low", "medium", "high"] = Field(
        description="Confidence level based on how directly the evidence supports the cause."
    )
    suggested_commands: list[str] = Field(
        description="Read-only or safe remediation kubectl commands for a human operator to review and run."
    )


class TriageRecord(BaseModel):
    fingerprint: str
    alertname: str
    outcome: Literal["ok", "failed"]
    duration_seconds: float
    tool_calls: int
    note: Optional[TriageNote] = None
    error: Optional[str] = None
    raw_labels: dict[str, Any] = Field(default_factory=dict)
