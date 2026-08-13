# Summary report

What was built while you were out, what works, and what does not.

---

## In one paragraph

You can sign in to a web page and ask a chatbot questions about customers. It
finds them and answers from a live API. If you ask for someone's home address
and you are not permitted to see home addresses, you are refused — and the
refusal does not depend on the chatbot choosing to be discreet. It is enforced
by a rule that sits between the chatbot and the data. Everything is built with
Terraform, tagged, and contains no stored passwords or API keys of any kind.

## What exists

Fifteen AWS resources across seven parts:

| Part | Job |
|---|---|
| Cognito | Holds two test users and issues the sign-in token. Stands in for the enterprise identity system. |
| CloudFront + firewall | One public address for both the web page and the chatbot. |
| ACGW-API | Front door onto the chatbot. |
| Runtime | Runs the chatbot. Checks the caller's token before it starts. |
| ACGW-MCP | Turns the API into tools, and holds the permission rules. |
| Mock API | Customer records: names, companies, work and home addresses. |
| Terraform | Builds all of the above. |

Public address: `https://d5vwdby8tjqs1.cloudfront.net`
Documentation: `https://d5vwdby8tjqs1.cloudfront.net/docs.html`

## The point of it

The token issued when a person signs in is carried the whole way — into the
chatbot, and on to the gateway that fetches the data. Nothing along the way
swaps it for a system account.

That is what makes the permission rule possible. Because the last gateway knows
*which person* is asking, it can refuse. If the identity stopped at the front
door, the only thing left to enforce a rule would be the chatbot's own
behaviour, which is not something to rely on.

Demonstrated concretely: two users, same question, same chatbot instructions.

| | customer-admin | customer-support |
|---|---|---|
| Search for a customer | Allowed | Allowed |
| Read a work address | Allowed | Allowed |
| Read a home address | Allowed | **Refused** |

## How it was tested

`./scripts/verify.sh` runs 21 checks against the live system. **All 21 pass.**

Covered: the API rejects unsigned callers; each user's token carries the right
group; the gateway builds four tools from the API description; the permission
rules allow and refuse correctly; the caller's identity survives every hop; the
runtime rejects missing and invalid tokens; the public site serves correctly
and its storage is not readable directly; every resource is tagged; and the
deployed system matches the code exactly.

Full detail in `docs/TEST-RESULTS.md`.

## What does not work yet

**One thing needs you: this account has no model capacity at all.** Not a
permissions problem and not a model choice — every Bedrock daily token quota on
the account is zero and marked not adjustable. Verified against ten models from
six providers across four regions; all refuse identically. It needs an AWS
support request to raise the Bedrock quota.

So the chatbot has never actually written a sentence. Everything around that —
receiving the question, checking who is asking, finding the tools, being
allowed or refused — is tested and working. Nothing here needs redeploying when
the quota arrives; the model is already configured.

**One smaller gap:**

1. **The chatbot can be reached directly, bypassing the firewall.** AgentCore
   offers a setting to prevent this; it conflicts with passing the user's
   identity through, and turning it on rejected legitimate traffic too. I chose
   identity over the lockdown, since identity is the entire point. It is one
   flag to revisit. Written up as Q2b in `docs/OPEN-QUESTIONS.md`.

## Decisions I made without asking

Six, all in `docs/OPEN-QUESTIONS.md` with reasoning and how to reverse each.
The two worth your attention:

- **Group names** are `customer-admin` and `customer-support`. They appear in
  the token, the rules, and the tests.
- **The model** is set to Claude Sonnet 4.5. One variable to change.

## Cost

About **$7–10 a month** sitting idle. Almost all of that is the web firewall,
which has a fixed monthly charge; everything else is pay-per-use and rounds to
pennies at this volume. No servers, no databases, no gateways of the expensive
kind. Chatbot sessions end after 15 minutes idle and cannot exceed an hour, so
nothing can quietly accumulate. No model tokens have been spent, because no
model is reachable.

## One thing that wasted time, recorded so it does not again

This machine's clock drifted about seven minutes behind real time partway
through. AWS refuses any request signed more than five minutes ago, so commands
began failing in a way that reads exactly like a permissions problem. I chased
it as one for a while. It corrected itself. If AWS starts refusing things for
no reason, check the clock first — the command is in `docs/OPEN-QUESTIONS.md`.

## Where to start when you are back

1. Raise an AWS support request for Bedrock on-demand token quota. Until that
   lands, the chatbot cannot answer, and no code change will alter that.
2. Walk the code with `docs/CODE-REVIEW.md` — six stops, about 45 minutes.

Browser sign-in has since been confirmed working: signing in on the deployed
site produced a token that the tools gateway accepted. That attempt also
exposed two real defects, both fixed — see Q0a in `docs/OPEN-QUESTIONS.md`.
