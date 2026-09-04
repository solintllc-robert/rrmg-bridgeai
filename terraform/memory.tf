# ---------------------------------------------------------------------------
# AgentCore Memory: what the agent remembers
#
# Short-term only. No memory strategies are attached, so the service extracts
# nothing, summarises nothing, and carries nothing across conversations. The
# store holds the turns of a single conversation and that is all.
#
# That restraint is an authorization decision, not a cost one. Who may see a
# home address is settled at ACGW-MCP, per tool call, against the group in the
# caller's token - see policy.tf. Anything replayed to the model out of memory
# arrives without that decision being made again. Held to one conversation the
# replay is harmless: the caller was told every value in it minutes earlier, by
# a call the gateway did allow. Long-term memory would break that. A fact
# extracted while somebody held customer-admin would still be sitting there
# after they lost it, and the gateway would never get a say in whether it was
# repeated back to them.
#
# The agent binds each conversation to the entitlement it was held under, so a
# change in group membership starts a fresh one rather than inheriting the old
# contents. See _memory_session in agent/main.py.
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_memory" "conversations" {
  name        = replace("${var.name_prefix}_conversations", "-", "_")
  description = "Short-term conversation history for the customer directory agent."

  # This is a copy of customer data at rest, outside the API that owns it, so
  # it is worth keeping brief. The agent's own session ends after an hour (see
  # runtime.tf); this governs only how long the transcript outlives it.
  event_expiry_duration = var.memory_event_expiry_days

  # Left unset, so events are encrypted with an AWS-managed key. A stack
  # holding real records rather than the mock ones would want a customer
  # managed key here instead, for the audit trail on its use.
  # encryption_key_arn = ...
}
