/**
 * Sign-in against Cognito using the authorization code flow with PKCE.
 *
 * This browser app is a public client: it has no secret, because anything
 * shipped to a browser can be read. PKCE covers that gap. The app generates a
 * random secret per sign-in, sends only a hash of it to Cognito, and proves it
 * holds the original when exchanging the code for tokens. An intercepted code
 * is useless without that secret.
 *
 * The user's password is only ever typed into Cognito's own page. This app
 * never sees it.
 */

const DOMAIN = import.meta.env.VITE_COGNITO_DOMAIN;
const CLIENT_ID = import.meta.env.VITE_COGNITO_CLIENT_ID;
const REDIRECT_URI = import.meta.env.VITE_REDIRECT_URI || `${window.location.origin}/callback`;
const SCOPES = "openid email profile";

const VERIFIER_KEY = "pkce_verifier";
const TOKENS_KEY = "auth_tokens";

function base64Url(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function randomVerifier() {
  return base64Url(crypto.getRandomValues(new Uint8Array(32)));
}

async function challengeFor(verifier) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64Url(digest);
}

/** Send the browser to Cognito's hosted sign-in page. */
export async function login() {
  const verifier = randomVerifier();
  sessionStorage.setItem(VERIFIER_KEY, verifier);

  const params = new URLSearchParams({
    client_id: CLIENT_ID,
    response_type: "code",
    scope: SCOPES,
    redirect_uri: REDIRECT_URI,
    code_challenge: await challengeFor(verifier),
    code_challenge_method: "S256",
  });

  window.location.assign(`${DOMAIN}/oauth2/authorize?${params}`);
}

/**
 * Complete sign-in after Cognito redirects back with a code.
 * Returns true if tokens were obtained.
 */
export async function completeLogin() {
  const params = new URLSearchParams(window.location.search);
  const code = params.get("code");
  if (!code) return false;

  const verifier = sessionStorage.getItem(VERIFIER_KEY);
  if (!verifier) throw new Error("Sign-in could not be completed: the browser lost its PKCE secret.");

  const response = await fetch(`${DOMAIN}/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: CLIENT_ID,
      code,
      redirect_uri: REDIRECT_URI,
      code_verifier: verifier,
    }),
  });

  if (!response.ok) {
    throw new Error(`Token exchange failed (${response.status}): ${await response.text()}`);
  }

  const tokens = await response.json();
  sessionStorage.removeItem(VERIFIER_KEY);
  storeTokens(tokens);

  // Drop the code from the address bar so a refresh cannot replay it.
  window.history.replaceState({}, document.title, "/");
  return true;
}

function storeTokens(tokens) {
  sessionStorage.setItem(
    TOKENS_KEY,
    JSON.stringify({
      access_token: tokens.access_token,
      expires_at: Date.now() + (tokens.expires_in ?? 3600) * 1000,
    })
  );
}

export function getAccessToken() {
  const raw = sessionStorage.getItem(TOKENS_KEY);
  if (!raw) return null;

  const tokens = JSON.parse(raw);
  // Treat a token about to expire as already gone, so a request cannot fail
  // halfway through because it aged out in flight.
  if (Date.now() > tokens.expires_at - 30_000) {
    sessionStorage.removeItem(TOKENS_KEY);
    return null;
  }
  return tokens.access_token;
}

export function isSignedIn() {
  return getAccessToken() !== null;
}

/** Read claims from the token for display. Never used to decide access. */
export function currentUser() {
  const token = getAccessToken();
  if (!token) return null;

  try {
    const part = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const claims = JSON.parse(atob(part.padEnd(part.length + ((4 - (part.length % 4)) % 4), "=")));
    return {
      subject: claims.sub,
      groups: claims["cognito:groups"] ?? [],
      expiresAt: new Date(claims.exp * 1000),
    };
  } catch {
    return null;
  }
}

export function logout() {
  sessionStorage.removeItem(TOKENS_KEY);
  const params = new URLSearchParams({
    client_id: CLIENT_ID,
    logout_uri: window.location.origin,
  });
  window.location.assign(`${DOMAIN}/logout?${params}`);
}
