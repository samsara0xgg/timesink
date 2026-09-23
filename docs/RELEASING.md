# Releasing TimeSink

A release is a notarized disk image at
`https://d2e75eb005kjod.cloudfront.net/TimeSink.dmg` plus a Sparkle appcast
at `…/appcast.xml` that installed copies check once a day.

## One-time setup (per Mac)

- **Developer ID Application** certificate for team `3MEBVQ3N3U` in the login
  keychain (`security find-identity -v -p codesigning`). Shared with Typlus;
  its `docs/RELEASING.md` covers creating one.
- **Notary profile** `Typlus` (`xcrun notarytool history --keychain-profile
  Typlus` must work). Any profile of the same team will do; the name is set
  at the top of `scripts/release.sh`.
- **Sparkle EdDSA key**: `.build/artifacts/sparkle/Sparkle/bin/generate_keys`
  prints the public key if one is in the keychain, or makes one. Its public
  half is `SUPublicEDKey` in `packaging/Info.plist`. Export the private half
  with `generate_keys -x <file>` into a password manager: without it no
  installed copy will ever accept another update.
- **AWS credentials** that can write the releases bucket (`aws sts
  get-caller-identity`).

## Releasing

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in
   `packaging/Info.plist` and commit. Sparkle compares `CFBundleVersion`, an
   integer that only ever goes up; the script refuses one that is not higher
   than the published build.
2. `scripts/release.sh`

It builds, signs with hardened runtime, notarizes and staples the app,
wraps it in a disk image that is itself signed, notarized and stapled,
writes the appcast, uploads all three, and tags `vX.Y.Z` locally.

## Checking a release

```sh
spctl -a -vv dist/TimeSink.app       # accepted, source=Notarized Developer ID
curl -s https://d2e75eb005kjod.cloudfront.net/appcast.xml | head -20
```

An installed copy checks for updates at launch after a day has passed; to
make it check now, use Settings › General › Check for Updates…, or rewind its
clock: `defaults write com.alllllenshi.TimeSink SULastCheckTime -date
"$(date -v-1d -v+30S)"` and relaunch.

## Traps

- Signing identity changes (self-signed `TimeSink Dev` → Developer ID) make
  macOS treat the app as new: Accessibility, Screen Recording, Automation and
  Calendar must be granted again, and the Keychain asks once before handing
  over the stored sign-in.
- Chinese is the source language, so the string catalog compiles no zh-Hans
  table; the Makefile writes empty ones. A `zh-Hans.lproj` without a table
  falls through to English.
- `scripts/check_strings.py` (also in CI) fails on any Chinese literal that
  will not translate, any key without English, and any English whose
  placeholders differ from its key. New UI text needs an entry in
  `packaging/Localizable.xcstrings`.
