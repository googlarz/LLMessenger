# Production Readiness

Last verified: 2026-07-13

LLMessenger is release-candidate quality for an unsigned, open-source macOS distribution. It is not honest to call any messaging agent "100% production ready" without signed distribution and field validation, so this document separates enforced evidence from launch-owner obligations.

## Enforced Gates

- `SWIFT_STRICT_CONCURRENCY=complete` and warnings-as-errors for the app, widget, unit tests, and UI tests.
- 709 unit, integration, migration, security, adapter, and performance tests passed; one snapshot test was intentionally skipped.
- One live macOS accessibility UI audit passed for actions, descriptions, element detection, hierarchy, and hit regions.
- Semantic and service colors are resolved and checked at WCAG AA 4.5:1 across light/dark appearances and every app surface.
- Release static analysis passed with no source warnings.
- `scripts/security-audit.sh` rejects credential-shaped production text, unsafe entitlements, plaintext credential preferences, and provider response-body leakage.
- `scripts/verify-app-bundle.sh` rejects malformed metadata, missing widget payloads, test/compiler artifacts, world-writable files, and non-universal binaries.
- CI and tagged releases run security, registration, tests, analysis, universal archive, and artifact verification from `project.yml`.

## Measured Capacity

The executable performance gate uses 100,000 messages across 1,000 conversations and four services. On the 2026-07-13 Apple Silicon baseline:

| Operation | Measured | CI gate |
| --- | ---: | ---: |
| Fetch 2,000 pending messages | 0.008 s | < 2.0 s |
| Fetch 500 service messages | 0.002 s | < 2.0 s |
| Ranked FTS search, 50 results | 0.001 s | < 2.0 s |
| SQLite size, 100,000 messages | 53.9 MiB | < 256 MiB |

Query-plan tests also prevent the two pending-message paths from degrading to full table scans. Full methodology is in [PERF-2026-07-13.md](performance/PERF-2026-07-13.md).

## Verified Artifact

The unsigned Release archive built successfully with no archive warnings. The main app and widget are both universal `x86_64 arm64` binaries, the productivity category and macOS 14 minimum are present, and app/widget dSYMs are included.

Tagged releases intentionally remain unsigned. Checksums prove package integrity relative to the workflow output; they do not provide Apple identity verification or Gatekeeper notarization.

## Launch Conditions

These require credentials, people, or real external accounts and cannot be completed by repository changes alone:

- **Developer ID:** sign, notarize, staple, and verify the distributed artifact on a clean Mac. Until then, preserve the explicit unsigned-download warning.
- **Connector soak:** run 24-72 hour clean-machine tests with real iMessage, Signal, Telegram, and Slack accounts, including revoked credentials, offline recovery, rate limits, duplicates, and send undo.
- **Human accessibility:** complete VoiceOver keyboard walkthroughs in light and dark mode at the minimum and default window sizes.
- **Operations:** assign release owner, incident contact, rollback procedure, support channel, privacy review, and dependency/security update cadence.
- **Beta evidence:** obtain the planned 3-5 user validation sessions before a broad launch, especially around trust, missed-message confidence, and delegated sends.

## Release Decision

A release owner may ship the unsigned community build when CI is green and the connector soak plus beta checks are signed off. A mainstream "production ready" claim should wait for Developer ID notarization and successful clean-machine field validation.
