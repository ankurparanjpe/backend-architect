"""Intentional test fixture — DO NOT FIX, DO NOT IMPORT.

Deliberately violates backend-security's hard-rule table
(skills/backend-security/SKILL.md). Used only to regression-test that the
skill's hard-rule detection still fires; see
tests/fixtures/backend-security/check.sh.
"""

import traceback

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import jwt

app = FastAPI()

app.add_middleware(  # violation: wildcard origin + credentials
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
)

JWT_SECRET = "super-secret-key-123"  # violation: hardcoded secret

# NEGATIVE CONTROL — deliberately NOT a violation. This is the committed
# .env.example config contract: placeholder values only, no real credentials.
# The skill must not flag it. See skills/backend-security/SKILL.md § Secrets
# management (the .env.example carve-out) and check.sh's refute() line.
ENV_EXAMPLE_TEMPLATE = """
# .env.example — committed to version control. No real secrets in this file.
POSTGRES_PASSWORD=changeme
STRIPE_API_KEY=sk_test_placeholder
"""


class SignupIn(BaseModel):  # violation: no extra="forbid", privileged field bound
    email: str
    password: str
    role: str = "user"


@app.post("/signup")
async def signup(data: SignupIn):
    user_id = create_user(data.email, data.password, data.role)
    token = jwt.encode(  # violation: long-lived token for direct client-side use
        {"sub": user_id, "exp": "365d"},
        JWT_SECRET,
        algorithm="HS256",
    )
    return {"token": token}


@app.post("/login")
async def login(data: SignupIn):
    user = authenticate(data.email, data.password)
    if not user:
        # violation: failure returned as HTTP 200 with the error in the body
        return {"success": False, "msg": "invalid credentials"}
    return {"success": True, "token": jwt.encode({"sub": user.id}, JWT_SECRET, algorithm="HS256")}


@app.delete("/posts/{post_id}")
async def delete_post(post_id: str, request: Request):
    user = get_current_user(request)
    post = get_post(post_id)
    if user.role != "admin" and user.id != post.owner_id:  # violation: inline permission check
        # violation: error shape differs from /login and /orders below
        return {"error": "forbidden"}
    query = f"DELETE FROM posts WHERE id={post_id}"  # violation: string-formatted SQL
    db_execute(query)
    return {"ok": True}


@app.get("/orders/{order_id}")
async def get_order(order_id: str):
    try:
        return fetch_order(order_id)
    except Exception as exc:
        # violation: internal exception/DB error text returned to the client
        return {"errors": [{"detail": str(exc), "trace": traceback.format_exc()}]}
