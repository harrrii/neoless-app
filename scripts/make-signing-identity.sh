#!/bin/bash
# One-time setup: creates a self-signed code-signing identity "neoless Local Signing"
# in your login keychain. Builds signed with it keep the same identity, so macOS
# keeps the Microphone / Speech / Accessibility permissions across updates.
# Undo: Keychain Access › login › delete the "neoless Local Signing" certificate and key.
set -euo pipefail
NAME="neoless Local Signing"
KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "已存在：$NAME"; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
# /usr/bin/openssl (LibreSSL) writes a PKCS#12 that `security import` understands.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:neoless -name "$NAME"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P neoless -T /usr/bin/codesign >/dev/null
# codesign only uses trusted identities. This trusts the certificate for code signing
# only, for your user only; macOS shows a confirmation dialog.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
echo "完成：$NAME。之后运行 scripts/build-app.sh --install 会自动使用它。"
