# Customer Directory Assistant

A proof of concept for AWS Bedrock AgentCore: sign in to a web page, ask a
chatbot about customers, and get answers drawn from a live API — with the
question of *who is allowed to see what* decided outside the chatbot.

Cognito stands in for the enterprise identity provider.

---

## What it does

Sign in, ask "what is Dana Whitfield's home address?", and the assistant looks
her up and answers. Ask the same question signed in as someone from the support
team and it cannot tell you, because that person is not permitted to see home
addresses. Work addresses and everything else are available to both.

The refusal does not come from the chatbot deciding to be discreet. The request
is rejected before it reaches the data.

## The pieces

```
Browser ──→ Cognito                         sign in, receive a token
   │
   └──→ CloudFront + firewall               one address for everything
             │
             ├── /*      ──→ S3             the page and the API documentation
             │
             └── /api/*  ──→ ACGW-API       front door
                                  │
                                  ↓
                              Runtime  ←──→  Memory   what was said
                                  │                   earlier in this
                                  ↓                   conversation
                             ACGW-MCP       tools, and the authorization rules
                                  │
                                  ↓
                             Mock API       the customer data
```

| Component | What it is for |
|---|---|
| **Cognito** | Holds the users and issues the token everything else trusts. |
| **CloudFront + WAF** | Single public address; puts the page and the agent on one origin. |
| **ACGW-API** | Front door onto the agent, giving it a clean stable URL. |
| **Runtime** | Runs the agent. Checks the caller's token before the agent starts. |
| **Memory** | The turns of the conversation in progress, so a follow-up question makes sense. |
| **ACGW-MCP** | Turns the REST API into tools, and decides who may call which. |
| **Mock API** | The customer records: names, companies, work and home addresses. |

Both gateways are the same kind of AWS resource. One is set to speak the tool
protocol; the other is left plain so it can route to the agent. That single
setting is why there are two of them — a runtime cannot be attached to a
tool-protocol gateway.

## The idea worth taking away

The person's identity travels the whole way. The token issued to the browser at
sign-in is the same token that reaches the agent, and the same one the tools
gateway checks before allowing a lookup. Nothing along the way swaps it for a
service account.

That is what makes the permission rule enforceable. Because the gateway knows
*which person* is asking, it can refuse. If identity stopped at the front door,
the only thing left to enforce the rule would be the chatbot's own good
behaviour, which is not a security control.

There are no stored passwords or API keys anywhere in this system. Every step is
either a token belonging to a person, or one AWS service assuming a role.

### Where remembering could have undone that

The assistant remembers the conversation you are having, so "and her work
address?" works. Memory is worth being careful with here, because it is the one
thing that can put a customer's details in front of the model without the
gateway being asked first — the gateway rules on tool calls, and replayed
history is not a tool call.

So the store holds one conversation at a time and extracts nothing from it.
History is filed under the caller's own identity, and under the groups their
token carried, which means losing a permission starts a new conversation rather
than inheriting the old one. Somebody who could read home addresses this morning
and cannot this afternoon is not read them back by the assistant.

The cost of that restraint is that the assistant does not know you across
conversations. That is the right trade here: this is a directory, and the
records it reads are the live ones, not what someone was told last week.

---

## Running it

Requires the AWS CLI, Terraform, Node.js, and `uv`. Set `AWS_PROFILE` first.

```bash
export AWS_PROFILE=solint-standard

cd terraform
terraform init
terraform apply                 # builds everything; ~15 minutes for CloudFront

cd ..
./scripts/deploy-web.sh         # builds and publishes the site
```

`deploy-web.sh` prints the site address when it finishes.

### Working on the browser application locally

```bash
./scripts/write-web-config.sh   # point the app at the deployed stack
cd web && npm install && npm run dev
```

Runs at `http://localhost:5173`, already registered with Cognito as a permitted
sign-in address.

### Checking it still works

```bash
./scripts/verify.sh
```

24 checks across the whole stack — the API, sign-in, both gateways, the
permission rules, what the agent remembers, and the public site.

### Trying it without the browser

```bash
./scripts/invoke-runtime.py --user admin  "What is Dana Whitfield's home address?"
./scripts/invoke-runtime.py --user support "What is Dana Whitfield's home address?"
```

The two test users differ only in group membership, which is what the
permission rule keys on.

To hold a conversation rather than ask one question, run the turns together:

```bash
./scripts/test-agent-local.py admin "Look up Dana Whitfield" "Where does she live?"
```

The second question names nobody, so an answer to it is the agent remembering
the first. `invoke-runtime.py --conversation <id>` does the same against the
deployed runtime, one turn per call.

Other useful scripts:

| Script | Purpose |
|---|---|
| `get-token.sh` | Fetch a sign-in token for either test user. |
| `decode-jwt.sh` | Show what is inside a token. |
| `mcp_client.py` | Talk to the tools gateway directly, bypassing the agent. |
| `invoke-runtime.py` | Call the agent, directly or through the front door. |
| `build-agent.sh` | Package the agent for deployment. |
| `deploy-web.sh` | Build and publish the site. |
| `verify.sh` | Check the whole deployed stack end to end. |

---

## Documents

| File | Contents |
|---|---|
| [`docs/SUMMARY.md`](docs/SUMMARY.md) | Start here: what was built, what works, what does not. |
| [`docs/OPEN-QUESTIONS.md`](docs/OPEN-QUESTIONS.md) | Decisions made without you, and one thing needing your action. |
| [`docs/TEST-RESULTS.md`](docs/TEST-RESULTS.md) | What was tested, what was observed, what was not. |
| [`docs/CODE-REVIEW.md`](docs/CODE-REVIEW.md) | A guided tour of the code, in reading order. |

## Layout

```
terraform/     the whole system as infrastructure code
agent/         the agent that answers questions
mock-api/      the customer data and its API description
web/           the browser application
scripts/       build, deploy, and test helpers
docs/          notes for review
```

## Cost

Everything is pay-per-use except the web firewall, which is roughly $6–10 a
month. Idle, this stack costs a few dollars a month. Agent sessions end after
15 minutes of inactivity and cannot outlive an hour, so nothing can quietly run
up a bill. Stored conversations are deleted after seven days, which is the
shortest AgentCore Memory allows.

## Removing it

```bash
cd terraform && terraform destroy
```
