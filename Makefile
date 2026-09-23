CERT ?= TimeSink Dev
APP = TimeSink
DIST = dist/$(APP).app
SPARKLE = $(DIST)/Contents/Frameworks/Sparkle.framework
# Hardened runtime always, so a local install behaves like a release.
# scripts/release.sh adds --timestamp through SIGN_FLAGS.
SIGN = codesign --force --options runtime --sign "$(CERT)" $(SIGN_FLAGS)

.PHONY: build test run bundle install clean
build:
	swift build -c release
test:
	swift test
run:
	swift run TimeSink
bundle: build
	rm -rf $(DIST)
	mkdir -p $(DIST)/Contents/MacOS $(DIST)/Contents/Resources $(DIST)/Contents/Frameworks
	cp .build/release/$(APP) $(DIST)/Contents/MacOS/
	install_name_tool -add_rpath @executable_path/../Frameworks $(DIST)/Contents/MacOS/$(APP)
	cp packaging/Info.plist $(DIST)/Contents/Info.plist
	cp -R .build/release/TimeSink_TimeSinkKit.bundle $(DIST)/Contents/Resources/
	ditto .build/release/Sparkle.framework $(SPARKLE)
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
