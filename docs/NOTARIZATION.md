# Notarization Guide

## Prerequisites

- Active Apple Developer Program membership
- Xcode 14+ with Command Line Tools installed
- `xcodegen` installed (`brew install xcodegen`)
- A valid **Developer ID Application** certificate in your keychain

## One-time Setup

### 1. Generate an App Store Connect API key

In [App Store Connect](https://appstoreconnect.apple.com/access/api), create an API key with
Developer role. Download the `.p8` file and note the Key ID and Issuer ID.

### 2. Store notarytool credentials

```bash
xcrun notarytool store-credentials "notarytool-profile" \
  --apple-id your@apple.com \
  --team-id YOUR_TEAM_ID \
  --password "@keychain:AC_PASSWORD"
```

Or using an App Store Connect API key:

```bash
xcrun notarytool store-credentials "notarytool-profile" \
  --key /path/to/AuthKey_KEYID.p8 \
  --key-id KEYID \
  --issuer ISSUER_UUID
```

### 3. Set your Team ID in ExportOptions.plist

Edit `scripts/ExportOptions.plist` and replace `REPLACE_WITH_TEAM_ID` with your 10-character
Apple Developer Team ID (visible at [developer.apple.com/account](https://developer.apple.com/account)).

### 4. Regenerate the Xcode project

```bash
xcodegen generate
```

This picks up the entitlements and hardened runtime settings added to `project.yml`.

## Development workflow

```bash
make build    # Debug build — fast iteration
make test     # Run full test suite
```

## Release workflow (full notarized DMG)

```bash
make dmg
```

This runs the full pipeline:
1. `archive` — Release build archived to `build/LLMessenger.xcarchive`
2. `export` — Exports signed `.app` to `build/` using `scripts/ExportOptions.plist`
3. `notarize` — Submits to Apple notary service, waits for approval, staples ticket
4. `dmg` — Wraps the stapled `.app` into `build/LLMessenger.dmg`

Each step can also be run individually: `make archive`, `make export`, `make notarize`.

## Entitlements

`LLMessenger/LLMessenger.entitlements` grants:

| Entitlement | Reason |
|---|---|
| `com.apple.security.network.client` | Outbound HTTPS to Anthropic, OpenAI, Ollama; localhost Signal JSON-RPC |
| `com.apple.security.cs.disable-library-validation` | PyInstaller Telegram adapter loads Python framework code at runtime |

**No app sandbox** — the sandbox (`com.apple.security.app-sandbox`) is intentionally absent.
The app reads signal-mcp's SQLite database, spawns subprocesses, and reads `~/Library/Messages`.
Sandboxing would break all of these.

## TCC permissions (Full Disk Access / iMessage)

Full Disk Access (required to read `~/Library/Messages` for iMessage) is a TCC permission.
It **cannot be pre-authorized** in the entitlements file — macOS requires the user to grant it
manually on first launch:

**System Settings → Privacy & Security → Full Disk Access → enable LLMessenger**

Document this in your app's onboarding flow.

## Expected app bundle layout

For the Telegram adapter to work, the `telegram-adapter` binary (built by PyInstaller) must be
present inside the app bundle at one of these locations:

```
LLMessenger.app/
└── Contents/
    ├── MacOS/
    │   └── LLMessenger          ← main binary
    └── Resources/
        └── telegram-adapter     ← PyInstaller binary (preferred location)
            └── telegram-adapter (or telegram-adapter.exe on Windows builds)
```

`SubprocessAdapter` resolves the binary path relative to
`Bundle.main.resourceURL` at runtime. Ensure your archive step (or a
`Run Script` build phase) copies the built adapter into
`$(BUILT_PRODUCTS_DIR)/$(CONTENTS_FOLDER_PATH)/Resources/`.

## Troubleshooting

- **Notarization rejected — library validation**: If a third-party dylib is flagged, ensure
  `com.apple.security.cs.disable-library-validation` is present (it is).
- **Stapling fails**: Stapler requires an internet connection to verify the notarization record.
- **`notarytool` profile not found**: Re-run the `store-credentials` command above.
- **Hardened Runtime rejects Python framework**: The `disable-library-validation` entitlement
  covers this; no additional `allow-jit` or `allow-unsigned-executable-memory` is needed for
  PyInstaller bundles.
