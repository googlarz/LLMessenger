# LLMessenger Plugin API v1

This document is the authoritative reference for third-party adapter plugins.
A plugin is an executable that communicates with LLMessenger over stdin/stdout
using newline-delimited JSON (NDJSON).

---

## Overview

LLMessenger spawns each plugin as a child process and communicates through:

- **stdin** — requests from the app (one JSON object per line)
- **stdout** — responses from the plugin (one JSON object per line)
- **stderr** — for plugin diagnostic output only; not parsed by the app

All messages are UTF-8 encoded. Every JSON object is terminated by a single
newline (`\n`). Responses must not contain embedded newlines.

---

## Protocol Version Handshake

The very first message sent by the app is always:

```json
{"v":1,"method":"hello"}
```

The plugin **must** respond immediately with:

```json
{"v":1,"ok":true}
```

If the plugin responds with `"ok": false` or fails to respond within 5 seconds,
the app marks the plugin as failed and does not call it further. Any other
first response (wrong `v`, missing `ok`, malformed JSON) is treated as failure.

The `v` field is the protocol version. This document describes version `1`.

---

## Request Format

Every request after the handshake has the shape:

```json
{"v":1,"method":"<name>","params":{...}}
```

| Field    | Type   | Description                          |
|----------|--------|--------------------------------------|
| `v`      | int    | Always `1` in this version           |
| `method` | string | One of the six methods below         |
| `params` | object | Method-specific parameters (may be `{}`) |

---

## Response Format

### Success

```json
{"v":1,"result":{...}}
```

### Error

```json
{"v":1,"error":"<human-readable message>","code":<int>}
```

Standard error codes:

| Code | Meaning                        |
|------|--------------------------------|
| 1    | Unknown method                 |
| 2    | Invalid parameters             |
| 3    | Service unavailable            |
| 4    | Authentication required        |
| 5    | Rate limited                   |

Plugins may use codes ≥ 100 for service-specific errors.

---

## Methods

### `health`

Called every 60 seconds. Must respond within 5 seconds or the plugin is
disabled until the next app launch.

**Request params:** `{}`

**Response:**

```json
{
  "status": "ok",
  "reason": null
}
```

| Field    | Type          | Description                                      |
|----------|---------------|--------------------------------------------------|
| `status` | string        | `"ok"`, `"warning"`, or `"error"`                |
| `reason` | string\|null  | Human-readable explanation when not `"ok"`       |

---

### `fetchMessages`

Fetch messages for a conversation, optionally filtered by time or count.

**Request params:**

```json
{
  "conversationId": "chat_123",
  "mode": "time",
  "since": "2024-01-15T10:00:00Z"
}
```

Or by count:

```json
{
  "conversationId": "chat_123",
  "mode": "count",
  "limit": 50
}
```

| Field            | Type   | Required | Description                          |
|------------------|--------|----------|--------------------------------------|
| `conversationId` | string | yes      | Opaque conversation identifier       |
| `mode`           | string | yes      | `"time"` or `"count"`                |
| `since`          | string | if time  | ISO 8601 UTC timestamp               |
| `limit`          | int    | if count | Maximum number of messages to return |

**Response:**

```json
{
  "messages": [
    {
      "id": "msg_456",
      "sender": "alice",
      "text": "Hello!",
      "timestamp": "2024-01-15T10:05:00Z",
      "isFromMe": false
    }
  ]
}
```

Message object fields:

| Field       | Type   | Description                                  |
|-------------|--------|----------------------------------------------|
| `id`        | string | Unique message identifier                    |
| `sender`    | string | Display name or handle of the sender         |
| `text`      | string | Plain-text message body                      |
| `timestamp` | string | ISO 8601 UTC timestamp                       |
| `isFromMe`  | bool   | `true` if the authenticated user sent this   |

---

### `fetchConversations`

Return all conversations visible to this adapter.

**Request params:** `{}`

**Response:**

```json
{
  "conversations": [
    {
      "id": "chat_123",
      "name": "General",
      "type": "group"
    }
  ]
}
```

Conversation object fields:

| Field  | Type   | Description                                  |
|--------|--------|----------------------------------------------|
| `id`   | string | Unique conversation identifier               |
| `name` | string | Display name                                 |
| `type` | string | `"dm"`, `"group"`, `"channel"`, or `"unknown"` |

---

### `fetchContacts`

Return contacts known to this adapter (used for @ mention autocomplete).

**Request params:** `{}`

**Response:**

```json
{
  "contacts": [
    {
      "id": "user_789",
      "displayName": "Alice Smith",
      "isGroup": false
    }
  ]
}
```

Contact object fields:

| Field         | Type   | Description                          |
|---------------|--------|--------------------------------------|
| `id`          | string | Unique contact identifier            |
| `displayName` | string | Human-readable name                  |
| `isGroup`     | bool   | `true` for group chats               |

---

### `sendMessage`

Send a message to a conversation.

**Request params:**

```json
{
  "conversationId": "chat_123",
  "text": "Hello from LLMessenger!"
}
```

| Field            | Type   | Required | Description              |
|------------------|--------|----------|--------------------------|
| `conversationId` | string | yes      | Target conversation      |
| `text`           | string | yes      | Message body to send     |

**Response:**

```json
{"ok": true}
```

On failure, return an error response (see Error Format above).

---

### `markRead`

Mark messages in a conversation as read up to a given message ID.

**Request params:**

```json
{
  "conversationId": "chat_123",
  "upToMessageId": "msg_456"
}
```

| Field           | Type   | Required | Description                            |
|-----------------|--------|----------|----------------------------------------|
| `conversationId`| string | yes      | Conversation to update                 |
| `upToMessageId` | string | yes      | Mark all messages up to this ID as read|

**Response:**

```json
{"ok": true}
```

---

## Health-Check Semantics

- The app sends `health` every **60 seconds**.
- Timeout: **5 seconds**. No response within 5 s disables the plugin.
- A disabled plugin is not re-enabled until the next app launch.
- Plugins should use `"warning"` status for degraded but functional states
  (e.g., rate-limited, reconnecting).

---

## stdout Size Limit

Each response line must not exceed **10 MB** (10,485,760 bytes). Responses
exceeding this limit are discarded and treated as an error. If your response
would exceed this limit, return a paginated subset and indicate truncation in
an optional `"truncated": true` field in the result.

---

## Plugin Discovery

The app scans for plugins at startup:

```
~/.config/llmessenger/adapters/<name>/manifest.json
```

Each subdirectory under `adapters/` must contain a `manifest.json`. The `<name>`
directory component is informational; the authoritative name comes from the
manifest's `name` field.

### Manifest Schema

```json
{
  "name": "echo",
  "binary": "/path/to/echo_adapter.py",
  "protocolVersion": 1,
  "services": ["echo"]
}
```

| Field             | Type     | Description                                         |
|-------------------|----------|-----------------------------------------------------|
| `name`            | string   | Unique adapter name; used in UI and logging         |
| `binary`          | string   | Absolute path to the executable                     |
| `protocolVersion` | int      | Must be `1`                                         |
| `services`        | [string] | Logical service names this adapter provides         |

Validation rules applied at discovery time:

1. `protocolVersion` must equal `1`; other values are rejected.
2. `binary` must exist and be executable.
3. The binary path must be under the user's home directory (prevents path
   traversal attacks such as `../../../usr/bin/bash`).
4. Invalid manifests are logged and skipped; they do not prevent other plugins
   from loading.

---

## Security Model

Plugins run as the current user with no additional sandboxing. Trust model:

- Plugins are **user-installed**. The app makes no attempt to verify
  signatures or provenance.
- The app validates the manifest `binary` path without shell interpolation.
  The path is passed directly to `Process.executableURL`; no shell is invoked.
- Plugins inherit the app's environment. Do not rely on specific env vars being
  present or absent.
- Plugins have full filesystem and network access. Users should only install
  plugins from sources they trust.

---

## Echo Adapter Example

A minimal Python implementation that passes the handshake and responds to
`health` and `fetchMessages`. Save as `echo_adapter.py` and make it executable
(`chmod +x echo_adapter.py`).

```python
#!/usr/bin/env python3
import sys
import json

def respond(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            respond({"v": 1, "error": "invalid JSON", "code": 2})
            continue

        method = req.get("method")

        if method == "hello":
            respond({"v": 1, "ok": True})

        elif method == "health":
            respond({"v": 1, "result": {"status": "ok", "reason": None}})

        elif method == "fetchMessages":
            respond({"v": 1, "result": {"messages": []}})

        elif method == "fetchConversations":
            respond({"v": 1, "result": {"conversations": []}})

        elif method == "fetchContacts":
            respond({"v": 1, "result": {"contacts": []}})

        elif method == "sendMessage":
            respond({"v": 1, "result": {"ok": True}})

        elif method == "markRead":
            respond({"v": 1, "result": {"ok": True}})

        else:
            respond({"v": 1, "error": f"unknown method: {method}", "code": 1})

if __name__ == "__main__":
    main()
```

Manifest for local development:

```json
{
  "name": "echo",
  "binary": "/Users/yourname/.config/llmessenger/adapters/echo/echo_adapter.py",
  "protocolVersion": 1,
  "services": ["echo"]
}
```
