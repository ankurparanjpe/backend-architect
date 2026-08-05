"""Intentional test fixture — DO NOT FIX, DO NOT IMPORT.

Deliberately violates resilience-patterns' hard-rule table
(skills/resilience-patterns/SKILL.md). Used only to regression-test that the
skill's hard-rule detection still fires; see
tests/fixtures/resilience-patterns/check.sh.
"""

import uuid

import httpx
from fastapi import FastAPI
from sqlalchemy import select

app = FastAPI()

# violation: shared client with no default timeout — every call made through
# it inherits httpx's no-deadline behavior unless it passes its own
http_client = httpx.AsyncClient()


@app.get("/items/{item_id}")
async def get_item(item_id: str):
    # violation: outbound HTTP call with no explicit timeout — a hung upstream
    # holds this worker slot indefinitely
    upstream = await http_client.get(f"https://upstream/items/{item_id}")

    # violation: DB query with no statement/query timeout — a lock wait or
    # table scan upstream of this has no deadline either
    row = await db.execute(select(Item).where(Item.id == item_id))

    return {"upstream": upstream.json(), "item": row.scalar_one()}


@app.post("/charges")
async def create_charge(customer_id: str, amount_cents: int):
    for _ in range(3):
        try:
            # violation: retrying a non-idempotent POST that creates a charge
            # with no idempotency key — a timeout that fires after upstream
            # succeeded means the customer is billed again on each attempt
            return await http_client.post(
                "https://payments/charges",
                json={"customer": customer_id, "amount": amount_cents},
                # violation: fresh key per attempt, so upstream sees each retry
                # as a brand-new operation and the key protects nothing
                headers={"Idempotency-Key": str(uuid.uuid4())},
                timeout=5.0,
            )
        except httpx.TimeoutException:
            # violation: tight-loop retry with no backoff — three attempts as
            # fast as the loop can issue them, multiplying load on a dependency
            # that is already failing
            continue


@app.post("/orders")
async def create_order(customer_id: str, sku: str):
    order = await db_create_order(customer_id, sku)

    # violation: non-critical analytics call inline and unguarded on the
    # critical path — the vendor being down fails an order that already
    # committed, and the customer sees a 500
    await http_client.post(
        "https://analytics.vendor/events",
        json={"event": "order_created", "order": order.id},
        timeout=2.0,
    )

    try:
        await http_client.post(
            "https://notify.vendor/send",
            json={"order": order.id},
            timeout=2.0,
        )
    except Exception:
        # violation: failure swallowed with no record — the degraded path is
        # indistinguishable from the healthy one in production
        pass

    return order


@app.get("/recommendations/{user_id}")
async def get_recommendations(user_id: str):
    # violation: no fail-fast path for a dependency that has proven it's
    # failing — while recs is down every request still burns the full timeout
    # before failing, pinning latency and parking workers in a known-doomed wait
    resp = await http_client.get(f"https://recs/users/{user_id}", timeout=5.0)
    return resp.json()


async def reconcile_invoices(invoice_ids: list[str]):
    """Enqueued as a background job by the nightly scheduler."""
    for invoice_id in invoice_ids:
        # violation: task body is not safe to re-run after interruption — a
        # worker killed partway through the batch causes the job runner to
        # re-run it from the top, inserting a second payment row for every
        # invoice already processed in the dead attempt
        amount = await http_client.get(
            f"https://billing/invoices/{invoice_id}", timeout=5.0
        )
        await db_insert_payment(invoice_id, amount.json()["total"])
