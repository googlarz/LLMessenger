# Privacy & Data Flow

LLMessenger is a personal tool that reads your messages from the messaging services you connect, summarises them with an LLM, and shows you the brief. This file documents — concretely — what data the app handles, where it goes, and what guarantees you can rely on.

## TL;DR

* **There is no LLMessenger server.** The developer cannot see your messages.
* **Your messages live only on your Mac**, in `~/Library/Application Support/LLMessenger/`.
* **Cloud egress happens only if you configure it.** With Ollama + no Anthropic/OpenAI key + no Slack: zero message content ever leaves your machine.
* **API keys and Slack tokens are stored in the macOS Keychain.** They are not written to any plaintext file.
* **No analytics, telemetry or crash upload, and nothing is sent to the developer.** The one thing the app looks up on its own is a new version on GitHub, when it starts and at most once a day. Switch it off in Settings → AI & Privacy → Privacy → Updates.

## Where your data is stored

| Data | Location | Read or write? |
| --- | --- | --- |
| Briefs, messages, conversation state | `~/Library/Application Support/LLMessenger/llmessenger.db` (SQLite) | LLMessenger |
| iMessage history | `~/Library/Messages/chat.db` | LLMessenger reads (requires Full Disk Access) |
| WhatsApp history *(opt-in)* | `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite` | LLMessenger reads, read-only (requires Full Disk Access); WhatsApp Desktop writes. LLMessenger never sends through WhatsApp. |
| Signal history | `~/.local/share/signal-mcp/messages.db` | LLMessenger reads (signal-cli daemon writes) |
| Telegram history | LLMessenger DB (synced via subprocess adapter) | LLMessenger |
| Slack history | LLMessenger DB (synced via HTTPS) | LLMessenger |
| API keys (Anthropic, OpenAI) | macOS Keychain | LLMessenger |
| Slack OAuth tokens | macOS Keychain (one JSON blob, one entry per workspace) | LLMessenger |
| Signal phone number | macOS Keychain | LLMessenger |
| Instrumentation events | Session-local process log. No message content, just event names and bounded metadata | LLMessenger |

Nothing in this table leaves your Mac unless one of the cloud egress paths below fires.

## Cloud egress — the complete list

When the app talks to anything that is **not** localhost, it goes to exactly one of these endpoints, all enumerated below. There are no other outbound destinations.

| Destination | Trigger | What's sent |
| --- | --- | --- |
| `https://api.anthropic.com/v1/messages` | Brief generation, chat, drafts — only if you configured an Anthropic key | The system prompt + the relevant messages in the brief window |
| `https://api.openai.com/v1/chat/completions` | Same as above — only if you configured an OpenAI key (and no Anthropic key) | Same as above |
| `https://slack.com/api/*` | Slack adapter polls + send — only if you added a Slack workspace | Your OAuth token in the Authorization header; channel/user IDs in queries; outbound messages on `chat.postMessage` |
| Telegram MTProto servers | Telegram adapter — only if you signed in | Your Telegram session + outbound messages |
| `https://api.github.com/repos/googlarz/LLMessenger/releases/latest` | When the app starts, at most once a day, unless you turn it off in Settings → AI & Privacy → Privacy → Updates | No message content or account details. Like any web request, GitHub sees your IP address and the app and macOS versions |
| `http://127.0.0.1:11434` (Ollama) | LLM calls when Ollama is selected | Localhost only — never leaves your Mac |
| `http://127.0.0.1:7583` (signal-cli daemon) | Signal send | Localhost only — never leaves your Mac |

Anthropic and OpenAI receive relevant message text when they generate a brief or draft. Slack and Telegram receive content when those connected services are polled or when you send through them. The GitHub update check never receives message content.

If you don't want any of that, see "Local-only mode" below.

## What the app does NOT do

* No analytics, no crash reporter, no telemetry beacon.
* No silent download or installation of updates. The optional GitHub request only reads the latest release's version number and link.
* No background uploading of any kind.
* No sharing of one user's data with another user's instance.
* No use of message content for model training (this is governed by your contract with Anthropic / OpenAI / Slack, not by LLMessenger).

## The relationship model stays on your Mac

LLMessenger v2.0 learns who matters to you — per-conversation context (who's a key sender, what's important, what's noise), reply-owed state, and behavior-based suggestions. **This model never leaves your machine.**

* It lives entirely in the local SQLite store (`conversationContexts`, `triageEvents`, `priorityCorrections`) — there is no server copy and no sync.
* It is fully visible (in each conversation's Context editor) and deletable: clear a conversation's context, or delete the store folder, and it's gone.
* There is **no cross-conversation identity graph** — context is scoped to one conversation; the app does not link "who's who" across chats.
* A conversation you mark **Local-only** (per-conversation privacy) is never sent to a cloud model, even if your global backend is a cloud provider: with a cloud provider selected it is left out of digests and gets no reply drafts, and while MCP is on it is left out of digests regardless. One marked **Never draft** gets no reply drafts, no suggested replies and no auto-send, and is left out of digests entirely. (An AI app connected over MCP can still read a Never-draft conversation; it just can't propose replies for it.)

## The agent, and the one place it can send for you

LLMessenger v2.1 adds an agent that prepares actions — drafted replies, follow-ups, RSVPs — for you to approve. By default **nothing is ever sent without an explicit tap from you.** The agent only writes proposals to the local `agentActions` table; you Approve, Edit, or Skip.

There is exactly one way the app can send without a per-message tap, and it is entirely under your control:

* **Scoped delegation is opt-in and off by default.** You enable it per conversation, for a specific low-risk action type only (acknowledgements, RSVPs) — in that conversation's Context editor.
* **The decision to auto-send reads only your settings and structured action fields — never message content as authorization.** A single function (`AgentDelegation.decide`) is the only thing that can authorize an automatic send, and it requires *all* of: you delegated that action type for that conversation; the action is low-risk and high-confidence; the recipient is someone you already have a conversation with (never brand-new); and the draft contains no links, monetary amounts, or credential-like text. Incoming messages can naturally trigger an acknowledgement or RSVP within a scope you already delegated, but crafted content cannot enable delegation, widen it, bypass a guard, or authorize another action type.
* **Every auto-send has a 30-second Undo** (cancellable from the menu bar) and is recorded in a local **action audit log** (what, where, why, when). Nothing about it is transmitted anywhere.
* **A global kill switch** (the DELEGATED / PAUSED pill in the window toolbar) and the per-conversation toggle instantly revert the app to prepare-only — propose, never send.
* **The app does not use the microphone or speech recognition.** **Calendar events** are written to your local calendar via EventKit; no calendar data leaves your Mac.

## Local-only mode

Settings → AI & Privacy → Privacy → **Local-only mode** disables every cloud egress path that carries message content:

* Disables Anthropic + OpenAI clients (forces Ollama)
* Skips registering the Slack adapter
* Blocks every MCP read (see below)
* Telegram is opt-in to begin with; you can simply not connect it

With Ollama running locally, no message content is sent to a cloud AI provider. Connected messaging services still receive the traffic inherent in using them, including replies you approve or delegated sends; disconnect Telegram as well if you want no non-local connector traffic.

## MCP server mode (opt-in)

Settings → AI & Privacy → Privacy → **Let AI apps read LLMessenger** is off by default, and asks you to confirm before it turns on. When it is on, `LLMessenger --mcp` lets an MCP client you configure (Claude Desktop, Claude Code, Cursor, …) read your owed replies, digests created after you enabled it, conversation lists and messages, and search them. That client may pass what it reads to its own model, which may be a cloud model — this is an egress path you control by choosing the client.

* Conversations marked **Local-only** are never returned by any MCP tool, and are left out of digests entirely while MCP is on.
* Global **Local-only mode** blocks every MCP read.
* Conversations marked **Never draft** can be read, but no reply can be proposed for them.
* An agent can only *propose* a reply: it lands in your Act queue tagged **External agent** (it came from a connected app, not from you), is never part of a batch send, and is sent only if you approve it.
* The MCP server speaks over stdio to a process on your Mac; it opens no network port.

## Network audit log

Settings → AI & Privacy → Privacy → **Network Log** shows cloud HTTPS calls made by the built-in LLM, Slack, and update clients during this session, with timestamp, provider, endpoint path, request size in bytes, and response status. Queries, headers, bodies, and provider error bodies are omitted. Telegram runs in a separate process and is not represented in this in-app log.

## Verifying for yourself

* **Source code:** every line is in this repository.
* **Egress audit:** `grep -r 'URL(string: "http' LLMessenger/` lists every outbound URL constant.
* **Entitlements:** `LLMessenger/LLMessenger.entitlements` declares exactly what macOS lets the app do.
* **Run with Little Snitch** or `lsof -i -p <pid>` to watch egress yourself.

## Threat model and limitations

This section is deliberately concrete about what the app does **not** protect against.

* **The OS still trusts you:** anyone with your Mac unlocked can open LLMessenger and read your briefs. Use FileVault, screen lock, etc.
* **Cloud LLM providers see what you send them.** When Anthropic or OpenAI is configured, the message text in the brief window goes to them. Their terms apply. If that's not acceptable for some conversation, use Local-only mode.
* **Slack's server sees the same metadata it always saw.** Adding LLMessenger doesn't change Slack's visibility into your activity — Slack is already the system of record.
* **Adapters can crash or misbehave.** The app does its best to surface errors without losing data, but a buggy adapter could miss messages or duplicate them. We test against this but cannot prove the absence of bugs.
* **No end-to-end encryption claim.** LLMessenger isn't a secure messaging tool. It's a summariser on top of services you already use; their security properties (E2E for iMessage/Signal/Telegram-secret-chats; server-side for Slack) are unchanged.

## Changes to this document

This file is part of the source code. Any change to the data-flow story is visible as a diff in the commit history.
