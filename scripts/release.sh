#!/bin/bash
# Builds, signs, notarizes and publishes the version in packaging/Info.plist.
# One-time setup and how to check the result: docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: yilun shi (3MEBVQ3N3U)"
NOTARY_PROFILE=Typlus   # a notarytool keychain profile of the same team
BUCKET=timesink-releasese6ba3ebf-r1zuitysp3la            # stack output ReleasesBucket
DOWNLOADS=https://d2e75eb005kjod.cloudfront.net          # stack output DownloadsUrl
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" packaging/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" packaging/Info.plist)
DMG=dist/TimeSink-$VERSION.dmg

[ -z "$(git status --porcelain)" ] || { echo "commit first: a release is built from a clean tree" >&2; exit 1; }
python3 scripts/check_strings.py

# Sparkle offers an update only when CFBundleVersion is higher than the
# installed one, so a build that is not newer would reach nobody.
LIVE=$(curl -fsS "$DOWNLOADS/appcast.xml" 2>/dev/null | sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' | head -1 || true)
if [ -n "$LIVE" ] && [ "$BUILD" -le "$LIVE" ]; then
    echo "build $BUILD is not newer than the published build $LIVE; bump CFBundleVersion" >&2
    exit 1
fi

make bundle CERT="$IDENTITY" SIGN_FLAGS=--timestamp

notarize() {
    # grep without -q: -q exits at the first match, tee then dies of SIGPIPE
    # and pipefail fails a submission that was accepted.
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait | tee /dev/stderr | grep 'status: Accepted' > /dev/null
}

# The app gets its own ticket so the copy dragged out of the disk image
# opens without a network check.
rm -f dist/TimeSink.zip
ditto -c -k --keepParent dist/TimeSink.app dist/TimeSink.zip
notarize dist/TimeSink.zip
xcrun stapler staple dist/TimeSink.app
spctl -a -vv dist/TimeSink.app

rm -rf dist/dmg "$DMG"
mkdir dist/dmg
ditto dist/TimeSink.app dist/dmg/TimeSink.app
ln -s /Applications dist/dmg/Applications
hdiutil create -volname TimeSink -srcfolder dist/dmg -format UDZO -ov "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# The appcast names only this build, signed with the EdDSA key that
# generate_keys keeps in the login keychain. generate_appcast reading the
# keychain itself raises an Allow dialog that would stall the script, so
# generate_keys hands the key over through a private temporary file.
rm -rf dist/feed
mkdir dist/feed
cp "$DMG" dist/feed/
KEYDIR=$(mktemp -d)
trap 'rm -rf "$KEYDIR"' EXIT
"$SPARKLE_BIN/generate_keys" -x "$KEYDIR/key" > /dev/null
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$KEYDIR/key" --download-url-prefix "$DOWNLOADS/releases/" dist/feed
rm -rf "$KEYDIR"

aws s3 cp "$DMG" "s3://$BUCKET/releases/"
aws s3 cp "$DMG" "s3://$BUCKET/TimeSink.dmg" --cache-control max-age=300
aws s3 cp dist/feed/appcast.xml "s3://$BUCKET/appcast.xml" --cache-control max-age=300 --content-type application/xml
git tag "v$VERSION"
echo "published $VERSION ($BUILD): $DOWNLOADS/TimeSink.dmg"
