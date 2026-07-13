#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/LLMessenger.app" >&2
  exit 64
fi

app="$1"
info="${app}/Contents/Info.plist"
main_binary="${app}/Contents/MacOS/LLMessenger"
widget="${app}/Contents/PlugIns/LLMessengerWidget.appex"
widget_info="${widget}/Contents/Info.plist"
widget_binary="${widget}/Contents/MacOS/LLMessengerWidget"

fail() {
  echo "verify-app-bundle: $1" >&2
  exit 1
}

[[ -d "${app}" ]] || fail "app bundle not found: ${app}"
[[ -f "${info}" ]] || fail "main Info.plist is missing"
[[ -x "${main_binary}" ]] || fail "main executable is missing or not executable"
[[ -d "${widget}" ]] || fail "widget extension is missing"
[[ -f "${widget_info}" ]] || fail "widget Info.plist is missing"
[[ -x "${widget_binary}" ]] || fail "widget executable is missing or not executable"

plutil -lint "${info}" "${widget_info}" >/dev/null

read_plist() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

[[ "$(read_plist "${info}" CFBundleIdentifier)" == "com.llmessenger.app" ]] \
  || fail "unexpected app bundle identifier"
[[ "$(read_plist "${widget_info}" CFBundleIdentifier)" == "com.llmessenger.app.widget" ]] \
  || fail "unexpected widget bundle identifier"
[[ "$(read_plist "${info}" LSApplicationCategoryType)" == "public.app-category.productivity" ]] \
  || fail "App Store category is missing or incorrect"
[[ "$(read_plist "${info}" LSMinimumSystemVersion)" == "14.0" ]] \
  || fail "minimum macOS version is not 14.0"
[[ -n "$(read_plist "${info}" CFBundleShortVersionString)" ]] \
  || fail "marketing version is missing"
[[ -n "$(read_plist "${info}" CFBundleVersion)" ]] \
  || fail "build version is missing"

for binary in "${main_binary}" "${widget_binary}"; do
  architectures="$(lipo -archs "${binary}")"
  [[ " ${architectures} " == *" arm64 "* ]] || fail "${binary} is missing arm64"
  [[ " ${architectures} " == *" x86_64 "* ]] || fail "${binary} is missing x86_64"
done

if find "${app}" \( -name '*.xctest' -o -name '*.swiftmodule' -o -name '*.swiftsourceinfo' \) -print -quit | grep -q .; then
  fail "test or compiler metadata leaked into the app bundle"
fi

if find "${app}" -type f -perm -0002 -print -quit | grep -q .; then
  fail "world-writable file found in app bundle"
fi

echo "verify-app-bundle: passed"
