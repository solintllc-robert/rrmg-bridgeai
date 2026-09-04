# Demo Guide: Customer Directory Assistant

## What You're Showing

A proof-of-concept chatbot powered by AWS Bedrock AgentCore that demonstrates **identity-driven access control** — where authorization decisions happen *before* the agent touches data, not inside the chatbot itself.

---

## The Demo Flow (for your tech audience)

### Part 1: Live Demo (5-10 min)
1. **Sign in as an admin user** → shows Cognito integration
2. **Ask:** "What is Dana Whitfield's home address?" → Agent finds it ✓
3. **Sign out, then sign in as support user**
4. **Ask the same question** → Agent is denied by the policy engine ✗
5. **Ask something support CAN see:** "What is Dana's work address?" → It works ✓

**Key insight:** The refusal happens at the policy engine, not the agent. The architecture doesn't trust the AI to enforce permissions.

---

## Architecture Tour (what to emphasize)

```
Browser ──→ Cognito                    [Identity: email + group membership]
   │
   └──→ CloudFront + WAF               [Single entry point, DDoS protection]
             │
             ├── /* ──→ S3             [Static site]
             │
             └── /api/* ──→ ACGW-API   [Agent front door]
                             │
                             ↓
                         Runtime       [Bedrock Agent Core: Python, validates token]
                             │
                             ↓
                        ACGW-MCP       [Tools gateway + Cedar policy engine]
                             │         [Authorization happens HERE]
                             ↓
                        Mock API       [REST: customer data]
```

### Key Components to Highlight

| Component | Why It Matters | Demo Point |
|---|---|---|
| **Cognito** | Centralized identity; group membership carries authorization signal | Show user groups in the policy |
| **CloudFront + WAF** | Single domain for everything; protects against DDoS | Mention: everything is on the same origin |
| **ACGW-API Gateway** | Clean, stable URL; token passes through untouched | Show it in the invoke script |
| **Agent Runtime** | Validates token + forwards it; does NOT enforce auth | Show in runtime.tf: `request_header_allowlist = ["Authorization"]` |
| **ACGW-MCP Gateway** | Turns REST API into tools; where Cedar policy lives | **This is the enforcement point** |
| **Cedar Policies** | Default-deny, group-based | Show policy.tf: `principal.getTag("cognito:groups") like "*customer-admin*"` |
| **CloudWatch + X-Ray** | Full observability; agent logs queries and calls | Show a query in CloudWatch |

---

## Why This Design Matters (the narrative)

### Security Principle
**"Identity travels with the request."**

Each component trusts the *same token* (issued by Cognito). Nothing swaps it for a service account or API key. If identity stopped at the gateway, the only enforcement left would be the agent's own good behavior — which is not a security control.

### Authorization Principle
**"Enforce at the boundary, not in the AI."**

The policy engine (Cedar) runs *before* the agent's decision reaches the data. An agent that's somehow tricked into requesting forbidden data gets rejected at the gateway. The model's instructions matter, but they're not what stops a breach.

### Architectural Principle
**"Know your infrastructure."**

Every piece is codified in Terraform. Cognito rules, policy rules, timeouts, logging — nothing is hand-configured. A reviewer can understand the entire system by reading `terraform/`.

---

## Talking Points (in order of difficulty)

### Easy (explain without code)
- "The agent asks the tools gateway for a customer's home address."
- "The gateway checks the user's group membership before forwarding the request."
- "Support users aren't in the admin group, so they get denied at the gateway."

### Medium (point to code)
- Show `policy.tf`: the Cedar policy that checks `principal.getTag("cognito:groups")`
- Show `cognito.tf`: the two groups (`customer-admin` and `customer-support`)
- Show `gateway_mcp.tf`: how the gateway loads and enforces the policy

### Advanced (for people who know AWS)
- Explain **confused-deputy protection** in `gateway_mcp.tf` policy: `condition { test = "StringEquals" ... "aws:SourceAccount" }`
- Mention **workload identity** in `runtime.tf`: restricts the agent to only run when called through ACGW-API
- Discuss **JWT passthrough** in `gateway_api.tf`: why the gateway forwards the original token instead of swapping it for its own credentials

---

## Demo Checklist

- [ ] Terraform stack is deployed (~15 min, or pre-deploy if time is short)
- [ ] Admin and support test users are created (outputs will show passwords)
- [ ] CloudWatch logs are accessible (for showing observability)
- [ ] `scripts/verify.sh` passes (24 checks across the stack)
- [ ] `scripts/invoke-runtime.py` works both ways:
  - `--user admin "What is Dana Whitfield's home address?"` → ✓
  - `--user support "What is Dana Whitfield's home address?"` → ✗
- [ ] A follow-up question works in the web app: ask "Look up Dana Whitfield", then "Where does she live?" — the second names nobody, so an answer proves the agent is following the conversation
- [ ] The web app is deployed and working

---

## Observability Demo (optional, but impressive)

If you want to show logging/tracing:

1. **CloudWatch Logs:** Show agent invocation and tool calls
2. **X-Ray:** Show the trace from browser → gateway → runtime → policy engine → API
3. **CloudWatch Metrics:** Show request counts, latencies

This demonstrates that the infrastructure is instrumented for operational visibility.

---

## Cost Note

Good to mention: everything pay-per-use except CloudFront WAF (~$6-10/month). No long-lived compute. Agent sessions timeout after 15 min idle, 1 hour max.

---

## Gotcha: Memory Is Deliberately Short-Term

If someone asks "does it remember me?", the answer is: it remembers this conversation, not you. Ask a follow-up ("and her work address?") and it works. Start a new conversation and it knows nothing about you.

That is a design decision, not a missing feature, and it is worth explaining rather than apologizing for. Replayed history reaches the model *without* passing the policy engine — it isn't a tool call, so Cedar never sees it. Long-term memory would therefore let a fact learned while someone held `customer-admin` be repeated back after they lost it, with no authorization check in the way. See Q6 in `docs/OPEN-QUESTIONS.md`; `terraform/memory.tf` has the same reasoning at the point it is enforced.

This is a strong talking point for a security-minded audience: it shows the boundary was thought about in the place where it is easiest to leak past.

---

## Phrases to Use

- "The identity never gets swapped out for a service account."
- "Authorization happens at the boundary, before the model sees it."
- "Cedar enforces the policy; the model respects it because it doesn't have a choice."
- "Everything is infrastructure as code — if you want to change who can see what, you edit Terraform and re-apply."
