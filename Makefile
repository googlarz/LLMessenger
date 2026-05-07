SCHEME        := LLMessenger
CONFIGURATION := Release
ARCHIVE_PATH  := build/LLMessenger.xcarchive
APP_PATH      := build/LLMessenger.app
DMG_PATH      := build/LLMessenger.dmg

DERIVED_DEBUG := $(shell xcodebuild -scheme $(SCHEME) -configuration Debug -project LLMessenger.xcodeproj -showBuildSettings 2>/dev/null | grep 'TARGET_BUILD_DIR' | head -1 | awk '{print $$3}')
DEBUG_APP     := $(DERIVED_DEBUG)/LLMessenger.app

.PHONY: build test install archive export notarize dmg clean

build:
	xcodebuild -scheme $(SCHEME) -configuration Debug build -project LLMessenger.xcodeproj

install: build
	rm -rf /Applications/LLMessenger.app
	cp -R "$(DEBUG_APP)" /Applications/
	mdimport /Applications/LLMessenger.app
	@echo "✓ Installed $(DEBUG_APP) → /Applications"

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
