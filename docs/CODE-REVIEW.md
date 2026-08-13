# Guided code review

A reading order for the code, built around one question: **how does the system
know who is asking, and how does it stop the wrong person seeing a home
address?** Everything else exists to serve that.

Roughly 45 minutes. Six stops, following a single request from the browser to
the data and back.

---

## Stop 1 — The data, and why the home address is kept separate

**`mock-api/src/app.py`**

Start here because one decision in this file shapes everything downstream.

- **Line 17, `PUBLIC_CUSTOMER_FIELDS`** — the list of fields the general
  lookups return. Neither address is on it.
- **Line 107, `ROUTES`** — four routes. Note that home address and work address
  are separate endpoints rather than fields of the customer record.

**Why it matters.** Because the home address is its own endpoint, it becomes
its own tool, and a tool can be permitted or refused on its own. Had the
address been a field inside the customer record, the only way to withhold it
would have been to fetch the record and strip the field out afterwards — which
means the data was already retrieved, and something has to be trusted to
remember to remove it.

**Question to push on:** is there any path that returns an address without
going through the address endpoints? (Look at `_public`, line 34.)

---

## Stop 2 — The API refuses unsigned callers

**`terraform/mock_api.tf`, line 79**

```hcl
authorization = "AWS_IAM"
```

One line, and it is the reason there is no API key in this system. Callers must
prove who they are with AWS credentials. The tools gateway does that using the
role it runs as.

Also worth seeing in this file: the API uses a single catch-all route and does
its own routing in code. When the entire data model was replaced partway
through — the system was originally about employees — only two things changed.
Per-endpoint routing would have meant rebuilding the routing layer.

**Question to push on:** what stops something else in the account from calling
this API? (Answer: only the roles granted `execute-api:Invoke`. Worth deciding
whether that is tight enough.)

---

## Stop 3 — The tools gateway, and the two directions of trust

**`terraform/gateway_mcp.tf`**

This file is where two different trust relationships meet, and it is the most
important file to understand.

- **Line 88, `protocol_type = "MCP"`** — makes this gateway a tool provider.
- **Line 92, `custom_jwt_authorizer`** — *inbound*: who may call this gateway.
  It accepts tokens from our Cognito pool. Note it matches on
  `allowed_clients`, not audience, because Cognito's access tokens carry no
  audience claim. Matching on audience fails silently and totally.
- **Line 135, `gateway_iam_role`** — *outbound*: how the gateway reaches the
  API. It signs with its own role. No credential is stored, and the agent never
  holds one.
- **Line 109, `policy_engine_configuration`** — attaches the permission rules
  from stop 5.

**Why it matters.** Inbound and outbound identity are deliberately different.
The gateway checks *a person* on the way in and presents *itself* on the way
out. That is what keeps API credentials away from the agent and the model
entirely.

---

## Stop 4 — The agent, and the header it depends on

**`agent/main.py`** and **`terraform/runtime.tf`**

- **`runtime.tf` line 163, `request_header_allowlist = ["Authorization"]`** —
  without this one line the agent cannot see the caller's token at all, and the
  whole design collapses into a service account.
- **`main.py` line 58, `_bearer_token`** — takes the caller's token out of the
  request.
- **`main.py` line 153** — the agent opens the tools gateway *using the
  caller's token*, not one of its own.

**Why it matters.** Everything else depends on this one line. The agent
is not a privileged actor holding keys to the customer database. It borrows the
identity of whoever asked, which is why the gateway can make a decision about
that person a moment later.

- **`main.py` line 29, `SYSTEM_PROMPT`** — note it *tells* the model that some
  data is restricted and not to work around a refusal. Read this as a courtesy
  to the user, not a control. Stop 5 is the control.
- **`main.py` line 111, `_diagnostic`** — a mode that reports who is calling
  and which tools they can reach, without invoking a model. Added when it
  emerged that no model was reachable from this account; it is how the identity
  chain was proven. It is useful in its own right for checking connectivity.

**Question to push on:** if the system prompt were deleted entirely, what would
change about what a support user can obtain? (Intended answer: nothing.)

---

## Stop 5 — Where permission is actually decided

**`terraform/policy.tf`**

The heart of the review.

- **Line 30** — a permit rule for the three unrestricted tools.
- **Line 59** — a permit rule for the home address tool, with a condition.
- **Line 66** — the condition itself: the caller's groups must include
  `customer-admin`.

Three things to look at closely:

1. **Default deny.** The engine refuses anything not explicitly permitted. Add
   an endpoint to the API and it is unreachable until a rule allows it. That is
   the safe direction to fail.

2. **The comment at line 49.** The group list arrives as one string rather than
   a list, so the check is a substring match. That is correct today and would
   quietly become wrong if a group were ever named so that another group's name
   sat inside it. **This is the single most likely thing to break later, and
   worth deciding whether to tighten now.**

3. **Where this runs.** At the gateway, before the tool call is forwarded. Not
   in the agent, not in the API. A model that decided to misbehave still cannot
   get the data.

**Evidence it works:** `docs/TEST-RESULTS.md`, Phase 7. Same question, same
agent instructions, two users, different outcomes.

---

## Stop 6 — The edge, and one deliberate naming choice

**`terraform/web.tf`** and **`web/src/auth.js`**

- **`web.tf`, the two origins** — the page comes from S3, the agent from the
  front-door gateway, both on one address. This is not tidiness: AgentCore
  sends no cross-origin headers, so a browser calling it from a different
  address would simply be blocked. Same origin sidesteps the problem instead of
  fighting it.
- **`web.tf` line 213, `path_pattern = "/api/*"`** — the front-door target is
  *named* `api`, so the gateway's own path is already `/api/invocations` and
  CloudFront forwards the request untouched. Naming it anything else would have
  required a URL-rewriting function here.
- **`auth.js` line 33, `challengeFor`** — sign-in uses a one-time secret so
  that an intercepted sign-in code is useless on its own. The application has
  no password of its own, because anything shipped to a browser can be read.
- **`auth.js` line 121, `currentUser`** — reads the token only to show who is
  signed in. Never to decide access. Worth confirming nothing else uses it.

**Question to push on:** the browser holds a token that can call the agent
directly, bypassing CloudFront and the firewall. Is that acceptable? See Q2b in
`OPEN-QUESTIONS.md` — it was meant to be closed off and could not be.

---

## Things I would want challenged

1. **The substring group check** (stop 5, line 66). Works, but fragile in a way
   that would not announce itself.

2. **The runtime is reachable directly.** The intended lockdown conflicts with
   passing the user's identity through. I chose identity over the lockdown. That
   was a judgement call and it is reversible — one flag.

3. **Password sign-in is enabled** on the browser app client so tokens can be
   fetched from a terminal for testing. Reasonable while building, worth
   removing before anyone else uses this.

4. **One permission is granted unscoped.** `terraform/gateway_mcp.tf`, the
   `ReadPolicyEngine` block. Scoping it to the policy engine's own address was
   rejected by AWS even though the address matched exactly. Worth another look.

5. **The agent has never written an answer.** Everything around the model is
   tested; the model itself is unreachable from this account. Read
   `TEST-RESULTS.md` for the precise boundary between what is proven and what
   is assumed.

---

## If you only have ten minutes

Read **stop 4** and **stop 5** — the header that carries identity, and the rule
that uses it. Those two, taken together, are the entire argument this proof of
concept is making.
