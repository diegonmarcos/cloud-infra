#!/usr/bin/env bash
# test-vault-mtls-ca-key.sh — guard (#1117): the fleet client CA PRIVATE key (and any device .p12) never lives in
# this public repo. The only public artefact of the vault mTLS CA is src/inputs/vault-client-ca.pem, a CERTIFICATE.
# The key and the device bundles are sops-encrypted into the private repo by .github/workflows/vault-mtls-issue.yml.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT" || exit 1
FAIL=0; ok(){ echo "ok   $*"; }; bad(){ echo "FAIL $*" >&2; FAIL=1; }
PEM=1_cloud-configs/src/inputs/vault-client-ca.pem
if [ -f "$PEM" ]; then
  grep -q 'PRIVATE KEY' "$PEM" && bad "$PEM carries a private key" || ok "$PEM holds no private key"
  [ "$(grep -c 'BEGIN CERTIFICATE' "$PEM")" -ge 1 ] && ok "$PEM is a certificate" || bad "$PEM is not a certificate"
else ok "no CA cert committed yet (vault route stays mesh-only)"; fi
bad_files="$(git ls-files 2>/dev/null | grep -Ei '(vault[-_]?(client[-_]?)?ca.*\.(key|pem)$|\.p12$|\.pfx$)' | grep -v "^$PEM$" || true)"
[ -z "$bad_files" ] && ok "no tracked .p12/.pfx or vault CA key file" || bad "tracked key material: $bad_files"
# the issuing workflow must not print/upload secrets and must publish the key only through sops
WF=.github/workflows/vault-mtls-issue.yml
if [ -f "$WF" ]; then
  grep -q 'upload-artifact' "$WF" && bad "$WF uploads an artifact" || ok "$WF uploads no artifact"
  grep -q 'sops --encrypt' "$WF" && ok "$WF sops-encrypts the bundle" || bad "$WF does not sops-encrypt the bundle"
  grep -Eq 'echo .*(ca\.key|P12PW|\$pw|p12_password)' "$WF" && bad "$WF echoes secret material" || ok "$WF echoes no secret material"
fi
exit "$FAIL"
