#!/bin/bash
# Create a self-signed code signing cert "TimeSink Dev" in login keychain.
set -e
if security find-certificate -c "TimeSink Dev" >/dev/null 2>&1; then
  echo "cert already exists"; exit 0
fi
TMP=$(mktemp -d)
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -subj "/CN=TimeSink Dev" \
  -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning"
/usr/bin/openssl pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:timesink
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P timesink -T /usr/bin/codesign
rm -rf "$TMP"
echo "imported. This self-signed cert is untrusted by default -- before signing,"
echo "open Keychain Access > login > Certificates > 'TimeSink Dev' > Trust > Code Signing: Always Trust."
echo "Skipping this can make codesign hang on an undisplayed keychain prompt, or fail"
echo "with 'unable to build chain' -- both are fixed by completing the trust step above."
security find-identity -p codesigning -v | grep "TimeSink Dev" || true
