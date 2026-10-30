#!/bin/zsh
# Creates a local code-signing certificate named "NotchBar Local Signing" in your login
# keychain. build.sh signs with it when it exists.
#
# Why: an ad-hoc signed app gets a new identity on every build, so macOS forgets its
# Accessibility and Automation permissions each time. A stable certificate keeps them.
# The certificate never leaves this Mac and is only used to sign NotchBar.
set -euo pipefail
NAME="NotchBar Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists. Nothing to do."
  exit 0
fi
# macOS's own OpenSSL (LibreSSL): Homebrew's OpenSSL 3 writes a .p12 format the keychain
# can't import ("MAC verification failed").
OPENSSL=/usr/bin/openssl
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -out "$TMP/identity.p12" -passout pass:notchbar
security import "$TMP/identity.p12" -k ~/Library/Keychains/login.keychain-db -P notchbar -T /usr/bin/codesign
echo "Created \"$NAME\"."
echo "Next: run ./build.sh --run. If macOS asks whether codesign may use the key, choose Always Allow."
echo "Then remove NotchBar from Privacy & Security > Accessibility and add it once more. It will stick from now on."
