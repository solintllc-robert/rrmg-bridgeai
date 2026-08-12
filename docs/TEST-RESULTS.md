# What was tested

Every phase was checked against the live stack in account `817290607332`,
region `us-east-1`. This records what was actually observed, and — just as
importantly — what was not.

**To re-run all of it yourself:**

```bash
./scripts/verify.sh
```

Last run: **21 checks, all passing.** The script covers everything below that
does not need a language model, so it stays useful while model access is
pending.

---

## Phase 1 — Mock customer API

| Check | Result |
|---|---|
| Request with no AWS signature | `403 Missing Authentication Token` |
| Signed search `?name=dana` | `200` — Dana Whitfield, C-1001, North Harbor Logistics |
| `/customers/C-1001/home-address` | `200` — 418 Harrowgate Lane, Newton, MA 02458 |
| `/customers/C-1001/work-address` | `200` — 200 Seaport Boulevard, Boston, MA 02210 |
| Core record contains an address? | No — confirmed absent |
| Unknown customer | `404` with a clear message |
| OpenAPI spec published to S3 | Yes, with the live API address filled in |

## Phase 2 — Cognito

| Check | Result |
|---|---|
| Sign-in as each test user | Both succeeded |
| Admin token group claim | `customer-admin` |
| Support token group claim | `customer-support` |
| Client id in token | Matches the app client |

Worth noting: Cognito access tokens carry no `aud` claim, so every authorizer
in this system matches on `client_id` instead. Matching on audience would have
silently rejected every request.

## Phase 3 — Tools gateway (ACGW-MCP)

| Check | Result |
|---|---|
| Tools generated from the spec | 4, one per API operation |
| Tool naming | `customer-directory___<operationId>` |
| `searchCustomers` returns real data | Yes |
| `getCustomerHomeAddress` returns real data | Yes |

This proved the gateway reaches the API using its own IAM role, with no API
key anywhere, before any agent existed.

## Phase 4 — Agent and runtime

| Check | Result |
|---|---|
| Package size | 27 MB (limit is 250 MB) |
| Deployment without Docker | Yes — zip to S3 |
| Request with no token | `401` |
| Request with an invalid token | `403` |
| Identity reaching the agent | Subject, groups, client and issuer all correct |
| Agent reaching the tools gateway with the user's token | Yes — all 4 tools listed |

**This is the central result.** A token minted for a person in the browser was
carried through the runtime into the agent, and accepted by the tools gateway
as that same person. The user's identity is preserved across every hop rather
than being replaced by a service account.

## Phase 5 — Front door (ACGW-API)

| Check | Result |
|---|---|
| Invoking through the front door | `200`, identity preserved |
| Clean URL without an encoded ARN | Yes — `/api/invocations` |
| Restricting the runtime to the gateway | **Failed — see Q2b in OPEN-QUESTIONS.md** |

The lockdown rejected legitimate traffic as well as direct traffic, so it was
switched off and left behind a flag. The runtime remains reachable directly by
anyone holding a valid token.

## Phase 6 — Browser application

| Check | Result |
|---|---|
| Development server serves the app | `200` |
| Same-origin `/api` proxy reaches the agent | `200`, identity intact |
| Production build | 7 KB of JavaScript, no runtime dependencies |
| **Sign-in through a real browser** | **Not verified — see below** |

The browser automation tool could not start in this environment, so the
redirect-and-return sign-in sequence has not been watched end to end. The
pieces around it are verified: Cognito issues correct tokens, and the agent
accepts them over the same path the browser uses. What is unproven is the
browser-side exchange itself — the redirect out, the code coming back, and the
swap for a token. **This is the first thing to try when you return.**

## Phase 7 — Authorization

Each tool called directly against the gateway as each user:

| Tool | customer-admin | customer-support |
|---|---|---|
| `searchCustomers` | Allowed | Allowed |
| `getCustomerWorkAddress` | Allowed | Allowed |
| `getCustomerHomeAddress` | Allowed | **Denied** |

The denial message is `Tool Execution Denied: Tool call not allowed due to
policy enforcement`.

The agent's instructions were identical in both cases. Nothing about the
model's behaviour changed — the request was refused before it reached the API.
That is the point of putting the rule at the gateway: it holds regardless of
what the model decides to do.

## Phase 8 — Edge

| Check | Result |
|---|---|
| Application over CloudFront | `200` |
| Documentation page | `200` |
| Deep link falls back to the app | `200` |
| Reaching the S3 bucket directly | `403` — only CloudFront can read it |
| Agent through CloudFront `/api` | `200`, identity intact |
| Firewall attached | Yes — common rule set plus rate limiting |
| Tags on every resource | 15 of 15, including all AgentCore resources |

---

## Not tested

**The agent writing an answer.** No language model is reachable from this
account (Q0 in OPEN-QUESTIONS.md). Everything the agent does *around* the model
is verified — receiving the request, checking identity, discovering tools,
having calls allowed or refused — but it has never composed a reply in words.
When model access is granted this needs no redeployment; ask it a question and
watch.

**Browser sign-in**, as described under Phase 6.

**Redeploying into a different account.** Not run, because tearing this stack
down and rebuilding it would have left the environment broken for a long stretch
while unattended. Instead it was checked by inspection: no account number,
region, or generated identifier appears anywhere in the Terraform, the agent,
the browser application, or the scripts. Every such value is a variable or a
reference. The one manual step in a new account is submitting the Bedrock model
access form.
