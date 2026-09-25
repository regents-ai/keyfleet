#!/usr/bin/env node
// SIWA agent client: sign in with a self-generated key, then send signed requests.
//
//   npm install viem
//   node siwa-agent.mjs keygen
//   node siwa-agent.mjs sign-in
//   node siwa-agent.mjs request POST https://example.app/api/agent/hello --body '{"name":"Astra"}'
//
// Environment:
//   SIWA_AUDIENCE   the audience you are joining, for example keyfleet (required)
//   SIWA_BROKER     the SIWA server base URL (default https://siwa-server.fly.dev)
//   SIWA_AGENT_HOME where the key and receipt are kept (default ~/.siwa-agent)
//
// The private key never leaves this machine. The SIWA server only ever sees the
// address, a signature over the challenge it issued, and signatures over requests.

import { createHash, randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

const CHAIN_ID = 8453;
const DEFAULT_BROKER = "https://siwa-server.fly.dev";
const RECEIPT_RENEW_MARGIN_SECONDS = 60;
const REQUEST_SIGNATURE_LIFETIME_SECONDS = 120;
const USER_AGENT = "siwa-agent-client/1.0 (node)";

class SiwaError extends Error {}

function settings() {
  const audience = (process.env.SIWA_AUDIENCE ?? "").trim();
  if (!audience) throw new SiwaError("set SIWA_AUDIENCE to the audience you are joining, for example keyfleet");
  const broker = (process.env.SIWA_BROKER ?? DEFAULT_BROKER).trim().replace(/\/+$/, "");
  const home = process.env.SIWA_AGENT_HOME ?? join(homedir(), ".siwa-agent");
  return { audience, broker, statePath: join(home, `${audience}.json`) };
}

function loadState(path) {
  return existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : null;
}

function saveState(path, state) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, JSON.stringify(state, null, 2));
  chmodSync(path, 0o600);
}

function requireKey(path) {
  const state = loadState(path);
  if (!state?.private_key) throw new SiwaError(`no key at ${path}; run keygen first`);
  return state;
}

async function httpJson(method, url, body, headers = {}) {
  const init = { method, headers: { accept: "application/json", "user-agent": USER_AGENT, ...headers } };
  if (body !== undefined) {
    init.body = body;
    init.headers["content-type"] ??= "application/json";
  }
  const response = await fetch(url, init);
  const text = await response.text();
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = text;
  }
  return { status: response.status, body: parsed };
}

async function personalSign(privateKey, message) {
  return privateKeyToAccount(privateKey).signMessage({ message });
}

function keygen(config, args) {
  const existing = loadState(config.statePath);
  if (existing && !args.includes("--force")) {
    console.log(JSON.stringify({ address: existing.address, state: config.statePath, created: false }));
    return;
  }
  const privateKey = generatePrivateKey();
  const state = {
    audience: config.audience,
    broker: config.broker,
    address: privateKeyToAccount(privateKey).address.toLowerCase(),
    private_key: privateKey,
  };
  saveState(config.statePath, state);
  console.log(JSON.stringify({ address: state.address, state: config.statePath, created: true }));
}

async function signIn(config, state) {
  const base = { wallet_address: state.address, chain_id: CHAIN_ID, audience: config.audience };
  const nonce = await httpJson("POST", `${config.broker}/api/shared/siwa/wallet/nonce`, JSON.stringify(base));
  if (nonce.status !== 200 || nonce.body?.code !== "nonce_issued") {
    throw new SiwaError(`nonce request failed (${nonce.status}): ${JSON.stringify(nonce.body)}`);
  }
  const challenge = nonce.body.data;
  const signature = await personalSign(state.private_key, challenge.message);
  const proof = { ...base, nonce: challenge.nonce, message: challenge.message, signature };
  const verified = await httpJson("POST", `${config.broker}/api/shared/siwa/wallet/verify`, JSON.stringify(proof));
  if (verified.status !== 200 || verified.body?.code !== "wallet_verified") {
    throw new SiwaError(`verification failed (${verified.status}): ${JSON.stringify(verified.body)}`);
  }
  const data = verified.body.data;
  state.receipt = data.receipt;
  state.receipt_expires_at = data.receiptExpiresAt;
  state.key_id = data.keyId;
  saveState(config.statePath, state);
  return data;
}

function receiptIsFresh(state) {
  if (!state.receipt || !state.receipt_expires_at) return false;
  return (Date.parse(state.receipt_expires_at) - Date.now()) / 1000 > RECEIPT_RENEW_MARGIN_SECONDS;
}

async function ensureReceipt(config, state) {
  if (!receiptIsFresh(state)) await signIn(config, state);
}

function contentDigest(body) {
  return `sha-256=:${createHash("sha256").update(body).digest("base64")}:`;
}

// Build the SIWA signed-request headers for one request. Each call signs fresh.
async function signedHeaders(state, method, url, body) {
  const parsed = new URL(url);
  const path = (parsed.pathname || "/") + parsed.search;
  const created = Math.floor(Date.now() / 1000);
  const expires = created + REQUEST_SIGNATURE_LIFETIME_SECONDS;
  const nonce = `sig-nonce-${randomBytes(16).toString("hex")}`;
  const headers = {
    "x-siwa-receipt": state.receipt,
    "x-key-id": state.key_id,
    "x-timestamp": String(created),
    "x-agent-wallet-address": state.address,
    "x-agent-chain-id": String(CHAIN_ID),
  };
  const components = ["@method", "@path", "x-siwa-receipt", "x-key-id", "x-timestamp", "x-agent-wallet-address", "x-agent-chain-id"];
  if (body !== undefined) {
    headers["content-digest"] = contentDigest(body);
    components.push("content-digest");
  }
  const params =
    `(${components.map((component) => `"${component}"`).join(" ")})` +
    `;created=${created};expires=${expires};nonce="${nonce}";keyid="${state.key_id}"`;
  const lines = components.map((component) => {
    const value = component === "@method" ? method.toLowerCase() : component === "@path" ? path : headers[component];
    return `"${component}": ${value}`;
  });
  lines.push(`"@signature-params": ${params}`);
  const signature = await personalSign(state.private_key, lines.join("\n"));
  headers["signature-input"] = `sig1=${params}`;
  headers["signature"] = `sig1=:${Buffer.from(signature.slice(2), "hex").toString("base64")}:`;
  return headers;
}

function parseRequestArgs(args) {
  const [method, url, ...rest] = args;
  if (!method || !url) throw new SiwaError("usage: <method> <url> [--body BODY] [--header NAME=VALUE]");
  let body;
  const extra = {};
  for (let index = 0; index < rest.length; index += 1) {
    if (rest[index] === "--body") body = Buffer.from(rest[++index] ?? "", "utf8");
    else if (rest[index] === "--header") {
      const [name, ...value] = (rest[++index] ?? "").split("=");
      extra[name] = value.join("=");
    } else throw new SiwaError(`unknown argument ${rest[index]}`);
  }
  return { method: method.toUpperCase(), url, body, extra };
}

async function sendSigned(state, request) {
  const headers = { ...request.extra, ...(await signedHeaders(state, request.method, request.url, request.body)) };
  return httpJson(request.method, request.url, request.body, headers);
}

function receiptRejected(body) {
  const text = JSON.stringify(body);
  return text.includes("receipt_invalid") || text.includes("receipt_binding_mismatch");
}

async function main(argv) {
  const [command, ...args] = argv;
  const config = settings();
  switch (command) {
    case "keygen":
      return keygen(config, args);
    case "sign-in": {
      const data = await signIn(config, requireKey(config.statePath));
      return console.log(JSON.stringify({ address: data.walletAddress, audience: data.audience, receiptExpiresAt: data.receiptExpiresAt }));
    }
    case "whoami": {
      const state = requireKey(config.statePath);
      return console.log(
        JSON.stringify({
          address: state.address,
          audience: config.audience,
          broker: config.broker,
          receiptFresh: receiptIsFresh(state),
          receiptExpiresAt: state.receipt_expires_at ?? null,
        }),
      );
    }
    case "headers": {
      const state = requireKey(config.statePath);
      await ensureReceipt(config, state);
      const request = parseRequestArgs(args);
      return console.log(JSON.stringify(await signedHeaders(state, request.method, request.url, request.body), null, 2));
    }
    case "request": {
      const state = requireKey(config.statePath);
      await ensureReceipt(config, state);
      const request = parseRequestArgs(args);
      let result = await sendSigned(state, request);
      if (result.status === 401 && receiptRejected(result.body)) {
        await signIn(config, state);
        result = await sendSigned(state, request);
      }
      console.log(JSON.stringify(result, null, 2));
      if (result.status >= 400) process.exitCode = 1;
      return undefined;
    }
    default:
      throw new SiwaError("commands: keygen [--force], sign-in, whoami, headers <method> <url>, request <method> <url>");
  }
}

main(process.argv.slice(2)).catch((error) => {
  console.error(JSON.stringify({ error: error.message }));
  process.exitCode = 2;
});
