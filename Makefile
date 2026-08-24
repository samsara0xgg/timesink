CERT ?= -
APP = TimeSink
DIST = dist/$(APP).app

.PHONY: build test run bundle install clean
build:
	swift build -c release
test:
	swift test
run:
	swift run TimeSink
bundle: build
	rm -rf $(DIST)
	mkdir -p $(DIST)/Contents/MacOS $(DIST)/Contents/Resources
	cp .build/release/$(APP) $(DIST)/Contents/MacOS/
	cp packaging/Info.plist $(DIST)/Contents/Info.plist
	if [ -d .build/release/TimeSink_TimeSinkKit.bundle ]; then \
		cp -R .build/release/TimeSink_TimeSinkKit.bundle $(DIST)/Contents/Resources/; fi
	codesign --force --sign "$(CERT)" $(DIST)
install: bundle
	rm -rf /Applications/$(APP).app
	cp -R $(DIST) /Applications/
clean:
	rm -rf .build dist
