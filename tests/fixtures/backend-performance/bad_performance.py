"""Intentional test fixture — DO NOT FIX, DO NOT IMPORT.

Deliberately violates backend-performance's hard-rule table
(skills/backend-performance/SKILL.md). Used only to regression-test that the
skill's hard-rule detection still fires; see
tests/fixtures/backend-performance/check.sh.
"""

from fastapi import FastAPI
import httpx

app = FastAPI()


@app.get("/orders")
async def list_orders():
    # violation: no limit/offset, no cap — returns every row in the table,
    # today and forever, as the table grows
    result = await db.execute(select(Order))
    return result.scalars().all()


async def fetch_upstream(item_id: str):
    # violation: a new client (and its own connection pool) is opened and
    # torn down on every single call instead of reusing one constructed once
    async with httpx.AsyncClient() as client:
        return await client.get(f"https://upstream/items/{item_id}")
