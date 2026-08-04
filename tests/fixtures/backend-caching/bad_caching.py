"""Intentional test fixture — DO NOT FIX, DO NOT IMPORT.

Deliberately violates backend-caching's hard-rule table
(skills/backend-caching/SKILL.md). Used only to regression-test that the
skill's hard-rule detection still fires; see
tests/fixtures/backend-caching/check.sh.
"""

import json
from fastapi import FastAPI, Depends

app = FastAPI()


@app.get("/my-orders")
async def get_my_orders(current_user=Depends(lambda: None)):
    # violation: shared/unscoped cache key for user-scoped data — every user
    # hitting this endpoint gets served whichever user's orders populated it
    key = "my_orders"
    cached = await redis.get(key)
    if cached:
        return json.loads(cached)

    orders = await fetch_orders_for_user(current_user.id)
    await redis.set(key, json.dumps(orders), ex=60)
    return orders


@app.get("/org/{org_id}/revenue")
async def get_org_revenue(org_id: str):
    # violation: unversioned/unnamespaced key — a future change to
    # compute_monthly_revenue's logic silently serves stale-shaped results
    # under this same key forever
    key = f"org:{org_id}:revenue"
    cached = await redis.get(key)
    if cached:
        return {"revenue": cached}

    revenue = await compute_monthly_revenue(org_id)
    # violation: no TTL and no explicit invalidation path anywhere — this key
    # never expires and nothing ever deletes it on the underlying data changing
    await redis.set(key, str(revenue))
    return {"revenue": revenue}


@app.post("/orders/{order_id}/confirm")
async def confirm_order(order_id: str):
    key = f"v1:order:{order_id}:confirm_status"
    cached = await redis.get(key)
    if cached:
        return {"status": cached}

    # violation: caching around an operation with a side effect — a cache hit
    # on a later call means the webhook silently never fires again
    await send_confirmation_webhook(order_id)
    status = await compute_confirm_status(order_id)
    await redis.set(key, status, ex=120)
    return {"status": status}
