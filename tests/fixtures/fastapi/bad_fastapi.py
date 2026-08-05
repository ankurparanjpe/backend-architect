"""Intentional test fixture — DO NOT FIX, DO NOT IMPORT.

Deliberately violates fastapi-architecture's hard-rule table
(skills/fastapi-architecture/SKILL.md). Used only to regression-test that the
skill's hard-rule detection still fires; see tests/fixtures/fastapi/check.sh.
"""

import pytest  # violation: dev/test-only package imported by application code,
from tests.factories import make_user  # forcing pytest into the runtime dependency set

import requests
from fastapi import FastAPI
from sqlalchemy.ext.asyncio import create_async_engine

app = FastAPI()

# violation: pool_size/max_overflow left at driver defaults, no reasoning
# against worker count or the DB's max_connections
engine = create_async_engine("postgresql+asyncpg://localhost/app")


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


@app.get("/orders-with-items")
async def list_orders_with_items():
    orders = (await db.execute(select(Order))).scalars().all()
    for order in orders:
        # violation: N+1 — one query per row instead of selectinload/joinedload
        items = await db.execute(select(Item).where(Item.order_id == order.id))
        order.items = items.scalars().all()
    return orders


@app.get("/users/{user_id}")  # violation: no response_model, full ORM row serialized
async def get_user(user_id: str):
    return await db.get(User, user_id)


@app.post("/debug/seed")
async def seed_user():
    # violation (same rule as the imports above): a test factory called from a
    # production route — passes CI where the dev group is installed, raises
    # ModuleNotFoundError on the first production request
    assert pytest.__version__  # dev-only package used on a request path
    return make_user(email="seed@example.com")
