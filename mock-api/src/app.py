"""Mock customer directory API.

Runs behind an API Gateway REST API using a ``{proxy+}`` catch-all, so all
routing happens here rather than in API Gateway resources. Authorization is
handled entirely by API Gateway (AWS_IAM) - by the time a request reaches this
handler the caller has already been authenticated by SigV4.
"""

import json
import re

from data import CUSTOMERS

# Fields safe to return from the general directory endpoints. Both addresses
# are excluded on purpose and served only by their own endpoints, so that the
# home address can be authorized separately from everything else.
PUBLIC_CUSTOMER_FIELDS = (
    "id",
    "name",
    "email",
    "phone",
    "company",
    "job_title",
    "status",
    "customer_since",
    "closed_on",
    "account_tier",
)

_CUSTOMERS_BY_ID = {c["id"]: c for c in CUSTOMERS}


def _public(customer):
    return {k: customer[k] for k in PUBLIC_CUSTOMER_FIELDS if k in customer}


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _not_found(message):
    return _response(404, {"error": "not_found", "message": message})


def search_customers(params):
    """GET /customers - filter the directory by name, company, status, or tier."""
    results = CUSTOMERS

    name = (params.get("name") or "").strip().lower()
    if name:
        results = [c for c in results if name in c["name"].lower()]

    company = (params.get("company") or "").strip().lower()
    if company:
        results = [c for c in results if company in c["company"].lower()]

    status = (params.get("status") or "").strip().lower()
    if status:
        results = [c for c in results if c["status"].lower() == status]

    tier = (params.get("account_tier") or "").strip().lower()
    if tier:
        results = [c for c in results if c["account_tier"].lower() == tier]

    return _response(200, {"count": len(results), "customers": [_public(c) for c in results]})


def get_customer(customer_id):
    """GET /customers/{id} - core record, without either address."""
    customer = _CUSTOMERS_BY_ID.get(customer_id)
    if not customer:
        return _not_found(f"No customer with id {customer_id}")
    return _response(200, _public(customer))


def _address_response(customer_id, field, label):
    customer = _CUSTOMERS_BY_ID.get(customer_id)
    if not customer:
        return _not_found(f"No customer with id {customer_id}")
    return _response(
        200,
        {
            "customer_id": customer["id"],
            "name": customer["name"],
            "address_type": label,
            "address": customer[field],
        },
    )


def get_customer_work_address(customer_id):
    """GET /customers/{id}/work-address - business mailing address."""
    return _address_response(customer_id, "work_address", "work")


def get_customer_home_address(customer_id):
    """GET /customers/{id}/home-address - residential address."""
    return _address_response(customer_id, "home_address", "home")


# Route table: (method, compiled path pattern, handler). The handler receives
# any named groups from the pattern plus the query string parameters.
ROUTES = [
    ("GET", re.compile(r"^/customers$"), lambda m, q: search_customers(q)),
    ("GET", re.compile(r"^/customers/(?P<customer_id>[^/]+)$"), lambda m, q: get_customer(m["customer_id"])),
    (
        "GET",
        re.compile(r"^/customers/(?P<customer_id>[^/]+)/work-address$"),
        lambda m, q: get_customer_work_address(m["customer_id"]),
    ),
    (
        "GET",
        re.compile(r"^/customers/(?P<customer_id>[^/]+)/home-address$"),
        lambda m, q: get_customer_home_address(m["customer_id"]),
    ),
]


def _request_path(event):
    """Recover the logical path from a REST API proxy event."""
    proxy = (event.get("pathParameters") or {}).get("proxy")
    if proxy:
        return "/" + proxy.strip("/")
    return event.get("path") or "/"


def handler(event, context):
    method = (event.get("httpMethod") or "GET").upper()
    path = _request_path(event)
    query = event.get("queryStringParameters") or {}

    for route_method, pattern, action in ROUTES:
        match = pattern.match(path)
        if not match:
            continue
        if route_method != method:
            return _response(405, {"error": "method_not_allowed", "message": f"{method} not allowed on {path}"})
        return action(match.groupdict(), query)

    return _not_found(f"No route for {method} {path}")
