/**
 * Customer directory assistant: sign in, then ask questions.
 *
 * Written without a UI framework. The page has two states - signed out and
 * signed in - and a list of messages, which is little enough that a framework
 * would add more to read than it saves.
 */

import "./styles.css";
import { askAgent, resetSession } from "./api.js";
import { completeLogin, currentUser, isSignedIn, login, logout } from "./auth.js";

const root = document.getElementById("root");
const messages = [];
let busy = false;

const SUGGESTIONS = [
  "What is Dana Whitfield's home address?",
  "Where does Marcus Bell work?",
  "Which customers are at enterprise tier?",
  "Look up Priya Raghunathan",
];

function escapeHtml(value) {
  const div = document.createElement("div");
  div.textContent = value;
  return div.innerHTML;
}

function renderSignedOut(error) {
  root.innerHTML = `
    <main class="centered">
      <div class="card">
        <h1>Customer Directory Assistant</h1>
        <p class="muted">Sign in to ask questions about customers.</p>
        ${error ? `<p class="error">${escapeHtml(error)}</p>` : ""}
        <button id="signin" class="primary">Sign in</button>
      </div>
    </main>
  `;
  document.getElementById("signin").addEventListener("click", () => login());
}

function renderSignedIn() {
  const user = currentUser();
  const groups = user?.groups?.length ? user.groups.join(", ") : "no groups";

  root.innerHTML = `
    <div class="layout">
      <header>
        <div>
          <strong>Customer Directory Assistant</strong>
          <span class="muted"> — signed in as <code>${escapeHtml(groups)}</code></span>
        </div>
        <div class="actions">
          <button id="clear" class="ghost">New conversation</button>
          <button id="signout" class="ghost">Sign out</button>
        </div>
      </header>

      <section id="thread" class="thread"></section>

      <form id="composer" class="composer">
        <input id="prompt" type="text" autocomplete="off"
               placeholder="Ask about a customer…" ${busy ? "disabled" : ""} />
        <button type="submit" class="primary" ${busy ? "disabled" : ""}>
          ${busy ? "Thinking…" : "Send"}
        </button>
      </form>
    </div>
  `;

  renderThread();

  document.getElementById("signout").addEventListener("click", () => logout());
  document.getElementById("clear").addEventListener("click", () => {
    messages.length = 0;
    resetSession();
    renderSignedIn();
  });
  document.getElementById("composer").addEventListener("submit", onSubmit);

  const input = document.getElementById("prompt");
  if (!busy) input.focus();
}

function renderThread() {
  const thread = document.getElementById("thread");
  if (!thread) return;

  if (messages.length === 0) {
    thread.innerHTML = `
      <div class="empty">
        <p class="muted">Try one of these:</p>
        <div class="suggestions">
          ${SUGGESTIONS.map((s) => `<button class="suggestion">${escapeHtml(s)}</button>`).join("")}
        </div>
      </div>
    `;
    thread.querySelectorAll(".suggestion").forEach((button) => {
      button.addEventListener("click", () => send(button.textContent));
    });
    return;
  }

  thread.innerHTML = messages
    .map(
      (message) => `
        <div class="message ${message.role}${message.isError ? " failed" : ""}">
          <div class="who">${message.role === "user" ? "You" : "Assistant"}</div>
          <div class="text">${escapeHtml(message.text)}</div>
        </div>`
    )
    .join("");

  if (busy) {
    thread.insertAdjacentHTML(
      "beforeend",
      `<div class="message assistant pending"><div class="who">Assistant</div><div class="text">Thinking…</div></div>`
    );
  }

  thread.scrollTop = thread.scrollHeight;
}

function onSubmit(event) {
  event.preventDefault();
  const input = document.getElementById("prompt");
  send(input.value);
}

async function send(prompt) {
  const text = (prompt || "").trim();
  if (!text || busy) return;

  messages.push({ role: "user", text });
  busy = true;
  renderSignedIn();

  try {
    const answer = await askAgent(text);
    messages.push({ role: "assistant", text: answer });
  } catch (error) {
    messages.push({ role: "assistant", text: error.message, isError: true });
  } finally {
    busy = false;
    renderSignedIn();
  }
}

async function start() {
  try {
    if (window.location.pathname === "/callback" || window.location.search.includes("code=")) {
      await completeLogin();
    }
  } catch (error) {
    renderSignedOut(error.message);
    return;
  }

  if (isSignedIn()) renderSignedIn();
  else renderSignedOut(new URLSearchParams(window.location.search).get("error_description"));
}

start();
