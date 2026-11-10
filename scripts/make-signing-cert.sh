#!/bin/sh
# Makes the local "Agentic OS Signing" code-signing certificate in the login keychain, so Agentic
# OS keeps its Microphone, Accessibility and Screen Recording permissions across rebuilds (an
# ad-hoc build is a new app to macOS every time). Run it once, by hand:  sh scripts/make-signing-cert.sh
# macOS may ask for the login password to trust the certificate. The certificate is only on this
# Mac and only for signing; it can be removed in Keychain Access.
set -e
D=$(mktemp -d); cd "$D"
cat > ext.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Agentic OS Signing
O=Get Truck Drivers
[v3]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
subjectKeyIdentifier=hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem -config ext.cnf 2>/dev/null
openssl pkcs12 -export -inkey key.pem -in cert.pem -out signing.p12 -passout pass:agenticos -name "Agentic OS Signing" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -out signing.p12 -passout pass:agenticos -name "Agentic OS Signing"
KC="$HOME/Library/Keychains/login.keychain-db"
security import signing.p12 -k "$KC" -P agenticos -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -r trustRoot -p codeSign -k "$KC" cert.pem
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KC" >/dev/null 2>&1 || true
cd /; rm -rf "$D"
security find-identity -v -p codesigning | grep "Agentic OS Signing" && echo "done: the build script will sign with it"
