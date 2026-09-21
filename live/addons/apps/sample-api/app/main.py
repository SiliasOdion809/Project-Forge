from fastapi import FastAPI
from datetime import datetime, timezone
import os

app = FastAPI(title="Project Forge Sample API")

APP_VERSION = os.getenv("APP_VERSION", "0.1.0")
ENVIRONMENT = os.getenv("ENVIRONMENT", "unknown")


@app.get("/health")
def health():
    """Liveness/readiness probe target."""
    return {"status": "ok"}


@app.get("/")
def root():
    return {
        "service": "sample-api",
        "environment": ENVIRONMENT,
        "version": APP_VERSION,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/api/v1/items")
def list_items():
    return {
        "items": [
            {"id": 1, "name": "widget"},
            {"id": 2, "name": "gadget"},
            {"id": 3, "name": "gizmo"},
        ]
    }