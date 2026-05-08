#!/usr/bin/env bash
# check-test-registration.sh
#
# Verifies that every *Tests.swift file in LLMessengerTests/ is registered in
# LLMessenger.xcodeproj/project.pbxproj (i.e., compiled by the test target).
#
# Usage: scripts/check-test-registration.sh
# Exit code: 0 if all tests are registered; 1 if any are missing.
#
# Run in CI or as an Xcode pre-build phase to prevent uncompiled test files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TESTS_DIR="${ROOT}/LLMessengerTests"
PBXPROJ="${ROOT}/LLMessenger.xcodeproj/project.pbxproj"

missing=()

while IFS= read -r -d '' swift_file; do
    filename="$(basename "${swift_file}")"
    # OllamaClientTests requires a live Ollama server and is intentionally excluded.
    if [[ "${filename}" == "OllamaClientTests.swift" ]]; then
        continue
    fi
    if ! grep -q "${filename}" "${PBXPROJ}"; then
        missing+=("${filename}")
    fi
done < <(find "${TESTS_DIR}" -name "*Tests.swift" -print0)

if [[ ${#missing[@]} -eq 0 ]]; then
    echo "✅ All test files are registered in project.pbxproj"
    exit 0
else
    echo "❌ The following test files are NOT registered in project.pbxproj:"
    for f in "${missing[@]}"; do
        echo "   - ${f}"
    done
    echo ""
    echo "Add each file to the LLMessengerTests target in Xcode,"
    echo "or run the registration script if one exists."
    exit 1
fi
