# The release identity, so a local install keeps the permissions granted to
# the published app. Without this certificate: scripts/make_cert.sh, then
# CERT="TimeSink Dev" (switching identities means granting them again).
CERT ?= Developer ID Application: yilun shi (3MEBVQ3N3U)
APP = TimeSink
DIST = dist/$(APP).app
SPARKLE = $(DIST)/Contents/Frameworks/Sparkle.framework
# Hardened runtime always, so a local install behaves like a release.
# scripts/release.sh adds --timestamp through SIGN_FLAGS.
SIGN = codesign --force --options runtime --sign "$(CERT)" $(SIGN_FLAGS)

# swift build links through the toolchain's clang with --sysroot only, and
# clang then records the deployment target as the SDK version; macOS 26 draws
# such an app in its old look. Name the SDK the build really uses.
SDK_LINK = -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker $(shell xcrun --sdk macosx --show-sdk-version)
# One binary for Apple Silicon and Intel: without --arch, swift build makes
# only the build machine's, and the app then refuses to open on the other.
# Two archs move the products out of .build/release, so ask where they went.
ARCHS = --arch arm64 --arch x86_64
BIN = $(shell swift build -c release $(ARCHS) --show-bin-path)

.PHONY: build test run bundle install clean
build:
	swift build -c release $(ARCHS) $(SDK_LINK)
test:
	swift test
run:
	swift run $(SDK_LINK) TimeSink
bundle: build
	rm -rf $(DIST)
	mkdir -p $(DIST)/Contents/MacOS $(DIST)/Contents/Resources $(DIST)/Contents/Frameworks
	cp $(BIN)/$(APP) $(DIST)/Contents/MacOS/
	install_name_tool -add_rpath @executable_path/../Frameworks $(DIST)/Contents/MacOS/$(APP)
	cp packaging/Info.plist $(DIST)/Contents/Info.plist
	cp -R $(BIN)/TimeSink_TimeSinkKit.bundle $(DIST)/Contents/Resources/
	ditto $(BIN)/Sparkle.framework $(SPARKLE)
	xcrun xcstringstool compile packaging/Localizable.xcstrings -o $(DIST)/Contents/Resources
	cp packaging/en.lproj/InfoPlist.strings $(DIST)/Contents/Resources/en.lproj/
	# Chinese is the source language, so the catalog compiles no zh-Hans
	# table. Empty ones must exist: a zh-Hans.lproj without a table falls
	# through to the English one, and Chinese users would see English.
	mkdir -p $(DIST)/Contents/Resources/zh-Hans.lproj
	touch $(DIST)/Contents/Resources/zh-Hans.lproj/Localizable.strings $(DIST)/Contents/Resources/zh-Hans.lproj/InfoPlist.strings
	# Plural keys fall through the same way, to the English stringsdict
	# ("12 limits" in Chinese): each formats as its own key instead.
	python3 -c 'import plistlib, sys; keys = plistlib.load(open(sys.argv[1], "rb")); plistlib.dump({k: {"NSStringLocalizedFormatKey": k} for k in keys}, open(sys.argv[2], "wb"))' \
		$(DIST)/Contents/Resources/en.lproj/Localizable.stringsdict $(DIST)/Contents/Resources/zh-Hans.lproj/Localizable.stringsdict
	# Inside out, never --deep: Sparkle's own recipe for signing it outside Xcode.
	$(SIGN) $(SPARKLE)/Versions/B/XPCServices/Installer.xpc
	$(SIGN) --preserve-metadata=entitlements $(SPARKLE)/Versions/B/XPCServices/Downloader.xpc
	$(SIGN) $(SPARKLE)/Versions/B/Autoupdate
	$(SIGN) $(SPARKLE)/Versions/B/Updater.app
	$(SIGN) $(SPARKLE)
	$(SIGN) --entitlements packaging/TimeSink.entitlements $(DIST)
install: bundle
	rm -rf /Applications/$(APP).app
	cp -R $(DIST) /Applications/
clean:
	rm -rf .build dist
