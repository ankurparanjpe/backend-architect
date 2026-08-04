"""Intentional test fixture — DO NOT FIX, DO NOT IMPORT.

Deliberately violates fastapi-architecture's hard-rule table
(skills/fastapi-architecture/SKILL.md). Used only to regression-test that the
skill's hard-rule detection still fires; see tests/fixtures/fastapi/check.sh.
"""

import requests
from fastapi import FastAPI

app = FastAPI()


@app.on_event("startup")  # violation: deprecated, use lifespan instead
async def startup() -> None:
    app.state.http_client = None


@app.get("/bad")
async def bad() -> dict:
    try:
        resp = requests.get("https://example.com")  # violation: blocking call in async def
        return {"status": resp.status_code}
    except Exception:  # violation: bare except around route body
        return {"status": "error"}
