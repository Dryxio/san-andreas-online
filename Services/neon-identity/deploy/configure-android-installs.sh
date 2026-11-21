#!/usr/bin/env bash
# Run on the Neon Identity host after enabling Play Integrity for the release.
set -euo pipefail
umask 077

project=${1:-}
signer=${2:-}
version=${3:-1}
if [[ $# -lt 2 || $# -gt 3 || ! $project =~ ^[1-9][0-9]{0,15}$ ||
      ! $signer =~ ^[[:xdigit:]]{64}$ || ! $version =~ ^[1-9][0-9]{0,9}$ ]] || (( version > 2147483647 )); then
    echo "Usage: $0 PROJECT_NUMBER PLAY_SIGNER_SHA256_HEX [MINIMUM_VERSION_CODE]" >&2
    exit 2
fi
base=/etc/neon-identity
if [[ $EUID != 0 || ! -f $base/neon-identity.env ]]; then
    echo 'Run as root on the configured Neon Identity host.' >&2
    exit 1
fi
exec 9>"$base/.android-install.lock"
flock -x 9
ca=$base/android-install-ca
stage=$(mktemp -d "$base/.android-install.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
if [[ ! -e $ca ]]; then
    mkdir "$stage/ca"
    openssl req -new -x509 -sha256 -days 1825 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -subj '/CN=SA Online Android install CA' -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
        -addext 'keyUsage=critical,keyCertSign' -keyout "$stage/ca/key.pem" -out "$stage/ca/cert.pem"
    chown -R root:neon-identity "$stage/ca"
    chmod 0750 "$stage/ca"
    chmod 0640 "$stage/ca/"*.pem
    mv -T "$stage/ca" "$ca"
fi
# Refuse an expired or mismatched existing pair. Rotating a trusted CA is a separate operation.
openssl verify -CAfile "$ca/cert.pem" "$ca/cert.pem" > /dev/null
openssl pkey -in "$ca/key.pem" -pubout > "$stage/key.pub"
openssl x509 -in "$ca/cert.pem" -pubkey -noout > "$stage/cert.pub"
cmp "$stage/key.pub" "$stage/cert.pub"
printf "NEON_ANDROID_INSTALL_ENROLLMENT='{\"package_name\":\"com.saonline.neonlauncher\",\"signer_sha256\":\"%s\",\"minimum_version\":%s,\"play_project_number\":\"%s\",\"ca_cert_file\":\"%s/cert.pem\",\"ca_key_file\":\"%s/key.pem\"}'\n" \
    "${signer,,}" "$version" "$project" "$ca" "$ca" > "$stage/android-install.env"
mv -T "$stage/android-install.env" "$base/android-install.env"
