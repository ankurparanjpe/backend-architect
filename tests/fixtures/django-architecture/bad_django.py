"""Intentional test fixture — DO NOT FIX, DO NOT IMPORT.

Deliberately violates django-architecture's hard-rule table
(skills/django-architecture/SKILL.md). Used only to regression-test that the
skill's hard-rule detection still fires; see
tests/fixtures/django-architecture/check.sh.
"""

import os

from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from rest_framework import serializers, viewsets
from rest_framework.response import Response
from rest_framework.views import APIView

from orders.models import Order
from orders.models import User


# --- settings snippet ---------------------------------------------------------
# violation: DEBUG on in deployed settings — returns tracebacks with locals,
# settings and SQL to whoever triggers the error
DEBUG = True

# violation: Host-header check disabled
ALLOWED_HOSTS = ["*"]

# violation: hardcoded SECRET_KEY with the scaffolded django-insecure- prefix;
# signs sessions, CSRF and password-reset tokens
SECRET_KEY = "django-insecure-8f3k2mq9zzp1v7n4x0lc6rt8why2jd5b"

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    # violation: CsrfViewMiddleware removed — every cookie-authenticated write
    # becomes forgeable cross-site
]


# --- async view ---------------------------------------------------------------
async def order_detail(request, order_id):
    # violation: sync ORM call inside an async view — blocks the event loop
    order = Order.objects.get(pk=order_id)
    customer_name = order.customer.name
    return JsonResponse({"id": order.id, "customer": customer_name})


# --- N+1 ----------------------------------------------------------------------
def order_report(request):
    rows = []
    # violation: no select_related/prefetch_related — one query per row for
    # the customer, one more per row for the items count
    for order in Order.objects.all():
        rows.append({
            "id": order.id,
            "customer": order.customer.name,
            "item_count": order.items.count(),
        })
    return JsonResponse({"results": rows})


# --- serializers --------------------------------------------------------------
class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        # violation: "__all__" — every current and future column is both
        # client-writable and returned, password hash and internal flags included
        fields = "__all__"


class OrderSerializer(serializers.ModelSerializer):
    customer = UserSerializer()

    class Meta:
        model = Order
        fields = ["id", "customer", "status"]


class OrderViewSet(viewsets.ModelViewSet):
    # violation: nested serializer reads a relation with a bare .all() queryset
    # — N+1 once per row of every page
    queryset = Order.objects.all()
    serializer_class = OrderSerializer


# --- unvalidated input --------------------------------------------------------
@csrf_exempt  # violation: CSRF removed from a state-changing view, no reasoning
class OrderCreate(APIView):
    def post(self, request):
        # violation: raw request.data straight into the ORM, no serializer
        order = Order.objects.create(
            sku=request.data["sku"],
            quantity=request.data["quantity"],
        )
        return Response({"id": order.id})


class OrderUpdate(APIView):
    def patch(self, request, pk):
        serializer = OrderSerializer(data=request.data)
        # violation: is_valid() return value ignored — invalid data proceeds
        serializer.is_valid()
        Order.objects.filter(pk=pk).update(status=request.data["status"])
        return Response(status=204)


# --- per-call client ----------------------------------------------------------
def notify_warehouse(order_id):
    import requests

    # violation: a new Session (and connection pool) per call instead of one
    # module-level client reused across requests
    session = requests.Session()
    return session.post(os.environ["WAREHOUSE_URL"], json={"order": order_id})
