# Open questions

Decisions made while working unattended. Each records what I chose, why, and
what to change if the guess was wrong. Nothing here is blocking; all are
reversible.

Status key: **OPEN** = wants your call. **FYI** = decided, low risk.

---

## Q0a. Bug found and fixed: agent code changes were not deploying — FYI

Found while chasing the first live error. Terraform was uploading new agent
code to S3, reporting success, and leaving the runtime running the *old* code.

The runtime's configuration named a bucket and a file path. Replacing the file
at that path changed neither, so Terraform saw nothing to update and skipped
the runtime entirely. The apply said it succeeded. The old agent kept
answering. Nothing anywhere reported a problem.

Fixed by pinning the exact object version in `terraform/runtime.tf`, so new
code produces a new version id, which Terraform sees as a real change.

Worth knowing because the failure was completely silent, and because anyone
editing the agent before this fix would have concluded their changes had no
effect.

---

## Q0b. This machine's clock drifted during the work — FYI, worth knowing

Partway through, this machine's clock fell about seven minutes behind real
time. AWS rejects any request whose signature is more than five minutes old, so
commands started failing with `InvalidSignatureException: Signature expired`
even though nothing was wrong with the credentials or the stack.

It corrected itself once the time service caught up, and everything passes now.
It is recorded here because the failure is thoroughly misleading: it looks like
a permissions problem, and I spent time chasing it as one. Some of the retries
I attributed to AWS being slow to propagate a permission change were probably
this instead.

**If AWS commands start failing for no apparent reason,** compare the clock
against AWS before investigating anything else:

```bash
date -u; curl -sI https://sts.us-east-1.amazonaws.com | grep -i '^date:'
```

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

## Q0. BLOCKER: this account has no model capacity at all — NEEDS AN AWS SUPPORT REQUEST

The agent is deployed and working right up to the point of writing a sentence.
It cannot get past that, and the reason is not what it first appeared to be.

**What it is not.** It is not model access, and it is not the choice of model.
Bedrock's model access page has been retired — models now enable themselves on
first use. The Anthropic use case form was submitted and did work: the error
moved on from "use case details have not been submitted" to something else.

**What it actually is.** Every one of this account's 99 Bedrock daily token
quotas is set to **zero**, and every one is marked **not adjustable**:

```
Model invocation max tokens per day for <any model>    Value: 0.0   Adjustable: False
```

So the account is allowed to call the models and has no allowance with which to
do so. Confirmed empirically, not just read off the quota table:

- **Ten models across six providers** — Amazon Nova, Meta Llama, Mistral,
  DeepSeek, Cohere, AI21 — all return `ThrottlingException: Too many tokens per
  day`.
- **Four regions** — us-east-1, us-west-2, us-east-2, eu-west-1 — all identical.

Choosing a different model cannot work around this, and neither can waiting:
the allowance is zero rather than exhausted.

**File it against Amazon Bedrock, not AgentCore.** Both exist as separate
services in Service Quotas (`bedrock` and `bedrock-agentcore`), and it is worth
being sure which one is starved. Of AgentCore's 184 quotas, **not one is zero** —
the runtime has 1,000 data-plane calls per second and 25 new sessions per
second. The throttle happens one layer further in, when the agent's
`BedrockModel` calls `bedrock-runtime` to generate text; that call is billed and
throttled against plain Bedrock no matter what is making it.

**The per-day quotas are not the ones to ask for.** They are non-adjustable, so
Service Quotas will not take a request for them. AWS documents the route as
asking for the *per-minute* quota instead, after which the support team offers
to raise the daily one alongside it:

> To request an increase for any combination of these quotas, request an
> increase for the **Cross-Region InvokeModel tokens per minute** quota […]
> After you do so, the support team will reach out and offer you the option of
> also increasing the other two quotas.

**Why self-service cannot fix this on its own.** The per-minute quotas *are*
adjustable, but Service Quotas refuses any value at or below the AWS default,
and this account sits below the default rather than above it:

```
L-F4DDD3EB  Cross-region tokens per minute, Sonnet 4.5    applied 0   default 5,000,000
L-4A6BFAB1  Cross-region requests per minute, Sonnet 4.5  applied 0   default 10,000
```

A request for a sane proof-of-concept number — 100,000 tokens per minute — is
rejected outright: *"You must provide a quota value greater than the default
quota value of 5000000.0."* There is no way to say "restore me to the default"
through the API. That is the whole trap: the applied value is zero, and the one
self-service tool that could move it will only move it past five million.

**What was requested, 2026-08-12.** Two increases, at the only values the API
would accept, both `PENDING`:

| Request id | Quota | Asked for |
|---|---|---|
| `8b76593910b64a19bda2c6448875d99fa5DJq9cR` | `L-F4DDD3EB` tokens per minute | 5,000,001 |
| `ad2cbecedcde4cb5b88f4c7c2a3d2be7fl1cuLYo` | `L-4A6BFAB1` requests per minute | 10,001 |

```bash
aws service-quotas list-requested-service-quota-change-history \
  --service-code bedrock --status PENDING --output table
```

The numbers are deliberately absurd for a proof of concept, and are not the
point — the point is that the request opens the channel to the support team,
whose follow-up is where a workable allowance actually gets set. Watch
`solint+aws1@solintllc.com` for it.

**Two things that may go wrong with it.** AWS states that *"priority will be
given to customers who generate traffic that consumes their existing quota
allocation. Your request might be denied if you don't meet this condition"* —
which cannot be met from an allocation of zero, so the case may need arguing on
exactly that point. And this account has no Premium Support subscription, so
there is no response-time commitment; a denial is still useful, because its
request id can be cited in a console limit-increase case that spells out the
applied-versus-default gap. Account 817290607332 is the management account of
its organisation, so there is no delegation step in the way.

**Nothing needs redeploying when it is granted.** The model id is already set
on the runtime. Ask a question and it will answer.

**What this did and did not stop.** Everything except the agent's own sentence
writing is built and tested — 21 automated checks, all passing. The identity
chain is proven end to end, and the authorization rules are proven at the
gateway where they are enforced. What has never been observed is the agent
forming a reply in words.

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
