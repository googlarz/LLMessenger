SCHEME        := LLMessenger
CONFIGURATION := Release
ARCHIVE_PATH  := build/LLMessenger.xcarchive
APP_PATH      := build/LLMessenger.app
DMG_PATH      := build/LLMessenger.dmg

DEBUG_APP := build/run/Build/Products/Debug/LLMessenger.app

.PHONY: build test install archive export notarize dmg clean

build:
	xcodebuild -scheme $(SCHEME) -configuration Debug build

install: build
	rm -rf /Applications/LLMessenger.app
	cp -R "$(DEBUG_APP)" /Applications/
	mdimport /Applications/LLMessenger.app
	@echo "✓ Installed to /Applications — Spotlight updated"

test:
	xcodebuild -scheme $(SCHEME) -configuration Debug test

archive:
	mkdir -p build
	xcodebuild archive \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-archivePath $(ARCHIVE_PATH)

export: archive
	xcodebuild -exportArchive \
		-archivePath $(ARCHIVE_PATH) \
		-exportPath build/ \
		-exportOptionsPlist scripts/ExportOptions.plist

notarize: export
	xcrun notarytool submit $(APP_PATH) \
		--keychain-profile "notarytool-profile" \
		--wait
	xcrun stapler staple $(APP_PATH)

dmg: notarize
	hdiutil create -volname LLMessenger \
		-srcfolder $(APP_PATH) \
		-ov -format UDZO $(DMG_PATH)
	@echo "DMG ready: $(DMG_PATH)"

clean:
	rm -rf build/
