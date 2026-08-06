"""Intentional test fixture — DO NOT FIX, DO NOT IMPORT.

Deliberately violates flask-architecture's hard-rule table
(skills/flask-architecture/SKILL.md). Used only to regression-test that the
skill's hard-rule detection still fires; see tests/fixtures/flask-architecture/check.sh.
"""

import time

import requests
from flask import Flask, request

# not a violation: the module-level instance is a structural preference, not a
# hard rule — see skills/flask-architecture/SKILL.md § Application factory pattern
app = Flask(__name__)

# violation: hardcoded config value in source
app.config["SQLALCHEMY_DATABASE_URI"] = "postgresql://prod-host/app"


@app.route("/orders", methods=["POST"])
def create_order():
    # violation: raw request.get_json() with no schema validation
    data = request.get_json()
    order = Order(sku=data["sku"], quantity=data["quantity"])
    db.session.add(order)
    db.session.commit()
    return {"id": order.id}


@app.route("/sync-report")
async def sync_report():
    # violation: blocking call inside an async def view
    resp = requests.get("https://partner.example.com/report")
    time.sleep(1)
    return resp.json()
