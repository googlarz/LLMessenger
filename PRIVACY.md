# Privacy & Data Flow

LLMessenger is a personal tool that reads your messages from the messaging services you connect, summarises them with an LLM, and shows you the brief. This file documents — concretely — what data the app handles, where it goes, and what guarantees you can rely on.

## TL;DR

* **There is no LLMessenger server.** The developer cannot see your messages.
* **Your messages live only on your Mac**, in `~/Library/Application Support/LLMessenger/`.
* **Cloud egress happens only if you configure it.** With Ollama + no Anthropic/OpenAI key + no Slack: zero message content ever leaves your machine.
* **API keys and Slack tokens are stored in the macOS Keychain.** They are not written to any plaintext file.
* **No analytics, no telemetry, no auto-update beacon.** The app does not call home.

## Where your data is stored

| Data | Location | Read or write? |
| --- | --- | --- |
| Briefs, messages, conversation state | `~/Library/Application Support/LLMessenger/llmessenger.db` (SQLite) | LLMessenger |
| iMessage history | `~/Library/Messages/chat.db` | LLMessenger reads (requires Full Disk Access) |
| Signal history | `~/.local/share/signal-mcp/messages.db` | LLMessenger reads (signal-cli daemon writes) |
| Telegram history | LLMessenger DB (synced via subprocess adapter) | LLMessenger |
| Slack history | LLMessenger DB (synced via HTTPS) | LLMessenger |
| API keys (Anthropic, OpenAI) | macOS Keychain | LLMessenger |
| Slack OAuth tokens | macOS Keychain (one JSON blob, one entry per workspace) | LLMessenger |
| Signal phone number | `UserDefaults` (no PII beyond a number you typed) | LLMessenger |
| Instrumentation events | A local log file. No content, just event names and counts | LLMessenger |

Nothing in this table leaves your Mac unless one of the cloud egress paths below fires.

## Cloud egress — the complete list

When the app talks to anything that is **not** localhost, it goes to exactly one of these endpoints, all enumerated below. There are no other outbound destinations.

| Destination | Trigger | What's sent |
| --- | --- | --- |
| `https://api.anthropic.com/v1/messages` | Brief generation, chat, drafts — only if you configured an Anthropic key | The system prompt + the relevant messages in the brief window |
| `https://api.openai.com/v1/chat/completions` | Same as above — only if you configured an OpenAI key (and no Anthropic key) | Same as above |
| `https://slack.com/api/*` | Slack adapter polls + send — only if you added a Slack workspace | Your OAuth token in the Authorization header; channel/user IDs in queries; outbound messages on `chat.postMessage` |
| Telegram MTProto servers | Telegram adapter — only if you signed in | Your Telegram session + outbound messages |
| `http://127.0.0.1:11434` (Ollama) | LLM calls when Ollama is selected | Localhost only — never leaves your Mac |
| `http://127.0.0.1:7583` (signal-cli daemon) | Signal send | Localhost only — never leaves your Mac |

The first three are also the **only** places where the *content* of your messages can travel: when Anthropic or OpenAI generates a brief, the relevant message text is in the prompt body. When Slack sends a message, your message text goes to Slack's API as part of `chat.postMessage`.

If you don't want any of that, see "Local-only mode" below.

## What the app does NOT do

* No analytics, no crash reporter, no telemetry beacon.
* No auto-update endpoint.
* No background uploading of any kind.
* No sharing of one user's data with another user's instance.
* No use of message content for model training (this is governed by your contract with Anthropic / OpenAI / Slack, not by LLMessenger).

## Local-only mode

Settings → About → **Local-only mode** disables every cloud egress path that carries message content:

* Disables Anthropic + OpenAI clients (forces Ollama)
* Skips registering the Slack adapter
* Telegram is opt-in to begin with; you can simply not connect it

With Ollama running locally, no message content ever leaves your Mac.

## Network audit log

Settings → About → **Network log** shows every cloud HTTPS call the app made during this session, with timestamp, provider, endpoint path, request size in bytes, and response status. **No message content is recorded.** It's a live verification that the egress table above is the complete story.

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
