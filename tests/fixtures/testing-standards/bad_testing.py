"""Intentional test fixture — DO NOT FIX, DO NOT IMPORT.

Deliberately violates testing-standards' hard-rule table
(skills/testing-standards/SKILL.md). Used only to regression-test that the
skill's hard-rule detection still fires; see
tests/fixtures/testing-standards/check.sh.

This file is itself a (bad) test module. It is never collected — the filename
is deliberately not `test_*.py` so no runner picks it up.
"""

import json
from unittest.mock import MagicMock

import pytest

from billing.service import checkout
from orders.repository import OrderRepository

# violation: module-level mutable state shared between tests
CREATED_ORDER_IDS = []


class TestOrderRepositoryIntegration:
    """Integration tests for the order repository."""

    async def test_save_persists_order(self):
        # violation: an "integration" test that mocks the database — the only
        # boundary it exists to exercise; passes with invalid SQL, a dropped
        # column, or an unapplied migration
        fake_session = MagicMock()
        repo = OrderRepository(session=fake_session)

        await repo.save_order(user_id=42, total_cents=19900)

        assert fake_session.add.called
        assert fake_session.commit.called

    async def test_list_for_user_filters_by_user(self):
        fake_session = MagicMock()
        fake_session.execute.return_value.scalars.return_value.all.return_value = [
            MagicMock(id=1, user_id=42),
        ]
        repo = OrderRepository(session=fake_session)

        rows = await repo.list_for_user(42)

        assert len(rows) == 1


def test_create_order(client):
    resp = client.post("/orders", json={"total_cents": 19900})
    assert resp.status_code == 201
    # violation: leaves persistent state behind with no teardown, and stashes it
    # in module state for a later test to consume
    CREATED_ORDER_IDS.append(resp.json()["id"])


def test_get_created_order(client):
    # violation: order-dependent — only passes if test_create_order ran first in
    # the same session; fails when run alone, sharded, or randomised
    order_id = CREATED_ORDER_IDS[0]
    resp = client.get(f"/orders/{order_id}")
    assert resp.status_code == 200


def test_checkout_applies_volume_discount(monkeypatch):
    # violation: patches the business logic under test — calculate_discount is
    # the thing this test claims to verify, so the assertion is vacuous
    monkeypatch.setattr("billing.service.calculate_discount", lambda order: 2000)
    monkeypatch.setattr("billing.service.payment_gateway.charge", lambda *a: "ch_1")

    result = checkout(order_id=1, total_cents=19900)

    assert result.total_cents == 17900


def test_get_order_returns_200(client):
    # violation: /orders/{id} is consumed by the fulfilment service, but this
    # asserts only the status code — a field rename or type change passes here
    # and breaks the consumer in production
    resp = client.get("/orders/1")
    assert resp.status_code == 200


def test_admin_can_export_all_orders(client, admin_token):
    resp = client.get(
        "/admin/orders/export", headers={"Authorization": f"Bearer {admin_token}"}
    )
    assert resp.status_code == 200
    assert json.loads(resp.content)


# violation: critical paths untested — the only permission test above is the
# admin happy path. Nothing covers a non-admin calling /admin/orders/export, an
# expired token, the refund path, or rollback on a partially failed write.
#
# violation: no test anywhere for DELETE /orders/{id}, which hard-deletes rows.
@pytest.mark.skip(reason="TODO: flaky, revisit")
def test_delete_order_removes_row(client):
    resp = client.delete("/orders/1")
    assert resp.status_code == 204
