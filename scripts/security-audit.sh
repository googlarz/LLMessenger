#!/bin/bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() {
  printf 'security-audit: %s\n' "$1" >&2
  exit 1
}

secret_pattern='(sk-ant-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)'
secret_hits="$(git grep -nEI "$secret_pattern" -- \
  ':!LLMessengerTests/**' ':!docs/**' ':!README.md' ':!scripts/security-audit.sh' || true)"
if [[ -n "$secret_hits" ]]; then
  printf '%s\n' "$secret_hits" >&2
  fail 'credential-shaped text found in production sources'
fi

if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' \
  LLMessenger/LLMessenger.entitlements >/dev/null 2>&1; then
  fail 'main app disables hardened-runtime library validation'
fi

defaults_credential_hits="$(git grep -nE \
  'UserDefaults[^\n]*(api[_-]?(key|hash)|access[_-]?token|oauth|password|secret)' \
  -- 'LLMessenger/**/*.swift' || true)"
if [[ -n "$defaults_credential_hits" ]]; then
  printf '%s\n' "$defaults_credential_hits" >&2
  fail 'credential-shaped value appears to be stored in UserDefaults'
fi

if git grep -n 'providerError("HTTP.*String(data: data' -- 'LLMessenger/**/*.swift' >/dev/null; then
  fail 'provider response body is included in an error'
fi

printf 'security-audit: passed\n'
