#!/bin/bash
# Create a self-signed code signing cert "TimeSink Dev" in login keychain.
set -e
if security find-identity -p codesigning -v | grep -q "TimeSink Dev"; then
  echo "cert already exists"; exit 0
fi
TMP=$(mktemp -d)
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -subj "/CN=TimeSink Dev" \
  -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning"
/usr/bin/openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:timesink
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P timesink -T /usr/bin/codesign
rm -rf "$TMP"
echo "imported. If codesign later fails with 'unable to build chain',"
echo "open Keychain Access > login > Certificates > 'TimeSink Dev' > Trust > Code Signing: Always Trust"
security find-identity -p codesigning -v | grep "TimeSink Dev" || true
