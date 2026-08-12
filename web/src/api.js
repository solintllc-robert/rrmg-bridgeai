/**
 * Calls the agent.
 *
 * The request goes to /api on this same origin - the dev server proxies it in
 * development, CloudFront routes it in production. Either way the browser is
 * never making a cross-origin request, so no CORS headers are needed from
 * AgentCore, which does not send any.
 */

import { getAccessToken } from "./auth.js";

const INVOKE_PATH = "/api/invocations";

/** A stable id groups a conversation's turns into one runtime session. */
function sessionId() {
  const key = "agent_session_id";
  let id = sessionStorage.getItem(key);
  if (!id) {
    id = `web-${crypto.randomUUID()}`;
    sessionStorage.setItem(key, id);
  }
  return id;
}

export function resetSession() {
  sessionStorage.removeItem("agent_session_id");
}

export async function askAgent(prompt) {
  const token = getAccessToken();
  if (!token) throw new Error("Your session has expired. Please sign in again.");

  const response = await fetch(INVOKE_PATH, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      Accept: "application/json",
      "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": sessionId(),
    },
    body: JSON.stringify({ prompt }),
  });

  const text = await response.text();

  if (!response.ok) {
    if (response.status === 401 || response.status === 403) {
      throw new Error("You are not authorized. Your session may have expired - try signing in again.");
    }
    throw new Error(`The agent could not be reached (${response.status}). ${text.slice(0, 300)}`);
  }

  return readAnswer(text);
}

/** The agent returns {result: ...}; unwrap it, tolerating shape changes. */
function readAnswer(text) {
  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    return text;
  }

  const result = payload?.result ?? payload;
  if (typeof result === "string") return result;
  return JSON.stringify(result, null, 2);
}
