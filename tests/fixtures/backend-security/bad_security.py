"""Intentional test fixture — DO NOT FIX, DO NOT IMPORT.

Deliberately violates backend-security's hard-rule table
(skills/backend-security/SKILL.md). Used only to regression-test that the
skill's hard-rule detection still fires; see
tests/fixtures/backend-security/check.sh.
"""

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


@app.delete("/posts/{post_id}")
async def delete_post(post_id: str, request: Request):
    user = get_current_user(request)
    post = get_post(post_id)
    if user.role != "admin" and user.id != post.owner_id:  # violation: inline permission check
        return {"error": "forbidden"}
    query = f"DELETE FROM posts WHERE id={post_id}"  # violation: string-formatted SQL
    db_execute(query)
    return {"ok": True}
