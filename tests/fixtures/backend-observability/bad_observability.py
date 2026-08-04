"""Intentional test fixture — DO NOT FIX, DO NOT IMPORT.

Deliberately violates backend-observability's hard-rule table
(skills/backend-observability/SKILL.md). Used only to regression-test that the
skill's hard-rule detection still fires; see
tests/fixtures/backend-observability/check.sh.
"""

import logging
from fastapi import FastAPI, Request

app = FastAPI()
logger = logging.getLogger(__name__)


@app.post("/login")
async def login(request: Request):
    data = await request.json()
    print(f"login attempt: {data}")  # violation: unstructured print() logging

    user = authenticate(data["email"], data["password"])
    if not user:
        # violation: logs the raw password in plaintext
        logger.info(f"failed login for {data['email']} with password {data['password']}")
        return {"ok": False}

    token = issue_token(user)
    logger.info(f"issued token {token} for user {user.id}")  # violation: token logged in plaintext

    # no request/correlation ID generated or read from headers, and none
    # propagated on the outbound call below — violation: missing correlation ID
    return {"token": token}


@app.get("/orders/{order_id}")
async def get_order(order_id: str):
    try:
        order = fetch_order_from_db(order_id)
    except Exception:
        pass  # violation: swallowed exception, no log line at all

    try:
        pricing = call_pricing_service(order_id)
    except Exception as e:
        logger.error(str(e))  # violation: discards stack trace, no exc_info/logger.exception
        pricing = None

    return {"order": order, "pricing": pricing}
