import os
from fastapi import FastAPI

SERVICE_NAME = "${{ values.serviceName }}"
APP_VERSION = os.getenv("APP_VERSION", "0.1.0")
ENVIRONMENT = os.getenv("ENVIRONMENT", "dev")

app = FastAPI(title=SERVICE_NAME)


@app.get("/health")
def health():
    return {"status": "ok", "service": SERVICE_NAME}


@app.get("/")
def root():
    return {
        "service": SERVICE_NAME,
        "version": APP_VERSION,
        "environment": ENVIRONMENT,
        "description": "${{ values.description }}",
    }


@app.get("/api/v1/items")
def list_items():
    return {"items": [], "service": SERVICE_NAME}