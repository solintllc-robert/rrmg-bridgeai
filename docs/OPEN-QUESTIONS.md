# Open questions

Decisions made while working unattended. Each records what I chose, why, and
what to change if the guess was wrong. Nothing here is blocking; all are
reversible.

Status key: **OPEN** = wants your call. **FYI** = decided, low risk.

---

## Q1. Password sign-in is enabled on the web app client — FYI

**Chose:** the Cognito app client allows both the browser redirect flow
(authorization code + PKCE) and direct username/password sign-in.

**Why:** the second lets me fetch tokens from the command line, which is how
every phase after Cognito gets tested. Without it there is no way to test the
gateway or the agent without driving a browser.

**If wrong:** remove `ALLOW_USER_PASSWORD_AUTH` from the app client. Browser
login keeps working; command-line testing stops.

---

## Q2. Test user passwords are generated and stored in Terraform state — FYI

**Chose:** passwords are randomly generated at apply time and exposed as
sensitive Terraform outputs.

**Why:** avoids putting a password in the repository. State is gitignored.

**If wrong:** the alternative is manually setting passwords outside Terraform.

---

## Q2b. The runtime cannot currently be locked to the gateway — OPEN, worth a decision

**What I wanted:** the runtime should refuse any request that did not arrive
through ACGW-API, so that somebody holding a valid user token cannot call the
agent directly and skip CloudFront and the firewall.

**Why it does not work.** AgentCore supports exactly this, via
`allowedWorkloadConfiguration` on the runtime. When I switched it on, the
runtime began rejecting *everything*, including legitimate requests forwarded
by ACGW-API:

> `Transaction token required: authorizer has AllowedWorkloadConfiguration configured`

The cause appears to be a conflict between two features we need at once.
ACGW-API forwards the end user's token untouched (`jwt_passthrough`), which is
what lets the agent reuse the caller's identity when it calls the tools
gateway. But because it forwards the token untouched, it never stamps its own
workload identity on the request, which is what the runtime is demanding. I
tried naming the gateway both by ARN and by workload identity; neither helped.
AWS documents both features but does not describe them interacting.

**What I did:** left the restriction switched off, so the system works. The
code is still there behind a flag — set `restrict_runtime_to_gateway = true`
in `terraform/variables.tf` to re-enable it.

**What this costs you.** The runtime is reachable directly by anyone holding a
valid Cognito token for this app client, bypassing CloudFront and the firewall.
Tokens are still required and still expire in an hour, and the authorization
rules on the tools gateway still apply, so this is not an open door — but it is
a wider entrance than intended.

**Options when you want to close it:** change ACGW-API's outbound auth from
token passthrough to the gateway's IAM role, and have the agent obtain user
context another way; or ask AWS whether transaction tokens can be issued
alongside passthrough. The first trades away the clean identity propagation
that makes this proof of concept interesting, so I did not do it unasked.

---

## Q3. Group names — OPEN

**Chose:** `customer-admin` (may read home addresses) and `customer-support`
(may not).

**Why:** the two roles the demo needs, named after what they can do.

**If wrong:** rename in `terraform/cognito.tf` and in the Cedar policy. The
names appear in the token, the policy, and the test scripts.

---

## Q0. BLOCKER: no usable model in this account — NEEDS YOUR ACTION

The agent is built and deployed, but it cannot currently call any language
model, because both available routes are closed off in this account:

- **Anthropic models** (Claude Sonnet 4.5 and every other Claude) return
  `ResourceNotFoundException: Model use case details have not been submitted
  for this account. Fill out the Anthropic use case details form before using
  the model.` This is a one-time form in the Bedrock console and cannot be
  done from the command line.
- **Amazon Nova models** return `ThrottlingException: Too many tokens per day`
  on every attempt, so the account's daily allowance for them is used up.

**What to do:** open the Bedrock console in us-east-1, go to Model access, and
submit the Anthropic use case details form. Access usually becomes active
within about fifteen minutes. Nothing needs redeploying afterwards — the model
id is already set on the runtime.

**What this did and did not stop.** Everything except the agent's own sentence
writing is built and tested. The identity chain is proven end to end using a
diagnostic mode on the agent that lists the tools a caller can reach without
invoking a model, and the authorization rules are tested directly against the
gateway, which is where they are actually enforced. What has not been observed
is the agent forming an answer in words. See `docs/TEST-RESULTS.md` for exactly
what was and was not exercised.

---

## Q4. Which model the agent uses — OPEN

**Chose:** Claude Sonnet 4.5 via Bedrock, using an inference profile.

**Why:** strong tool-calling at a sensible cost for a proof of concept.

**If wrong:** change `agent_model_id` in `terraform/variables.tf`. Note that
model access must be enabled in the Bedrock console for whichever model is
chosen.

---

## Q5. Session lifetime on the agent runtime — FYI

**Chose:** idle sessions end after 15 minutes; no session lives beyond 1 hour.

**Why:** keeps cost predictable. A forgotten browser tab cannot hold a session
open indefinitely.

**If wrong:** raise `idle_runtime_session_timeout` / `max_lifetime` in
`terraform/runtime.tf`.

---
