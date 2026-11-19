#!/bin/sh
# Docker remote API over mutual TLS (port 2376) on the MiBox.
#
# Generates, once, a private CA plus a server and a client certificate in
# $MIBOX_DOCKER_CERTS (default ~/.docker/mibox, the layout DOCKER_CERT_PATH
# expects: ca.pem cert.pem key.pem). The CA key never leaves the PC. Then
# installs ca.pem/server-cert.pem/server-key.pem in the Alpine tree under
# /etc/docker/tls, backs up the current daemon.json and writes one that keeps
# the local socket and adds tcp://0.0.0.0:2376 with tlsverify. dockerd is
# killed and the mibox-docker supervisor restarts it (5 s back-off).
# Data-side change only; boot1 is not touched.
#
# Usage: scripts/setup-docker-tls.sh [host]       (default 192.168.1.222)
# Client: DOCKER_HOST=tcp://192.168.1.222:2376 DOCKER_TLS_VERIFY=1
#         DOCKER_CERT_PATH=~/.docker/mibox docker version
set -eu
host=${1:-192.168.1.222}
dir=${MIBOX_DOCKER_CERTS:-$HOME/.docker/mibox}
key=${MIBOX_SSH_KEY:-$HOME/.ssh/mibox-console}
days=3650
export MSYS_NO_PATHCONV=1   # Git Bash: keep -subj /CN=... literal

mkdir -p "$dir"
chmod 700 "$dir"
cd "$dir"
if [ ! -e ca-key.pem ]; then
    umask 077
    openssl ecparam -name prime256v1 -genkey -noout -out ca-key.pem
    openssl req -new -x509 -sha256 -days "$days" -key ca-key.pem -subj "/CN=mibox-docker-ca" \
        -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign -out ca.pem
    openssl ecparam -name prime256v1 -genkey -noout -out server-key.pem
    openssl req -new -sha256 -key server-key.pem -subj "/CN=mibox" -out server.csr
    printf 'subjectAltName=IP:%s,DNS:mibox,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\n' "$host" > server.ext
    openssl x509 -req -sha256 -days "$days" -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
        -extfile server.ext -out server-cert.pem
    openssl ecparam -name prime256v1 -genkey -noout -out key.pem
    openssl req -new -sha256 -key key.pem -subj "/CN=mibox-docker-client" -out client.csr
    printf 'extendedKeyUsage=clientAuth\nkeyUsage=critical,digitalSignature\n' > client.ext
    openssl x509 -req -sha256 -days "$days" -in client.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
        -extfile client.ext -out cert.pem
    rm -f server.csr client.csr server.ext client.ext
    umask 022
fi
openssl verify -CAfile ca.pem server-cert.pem cert.pem

ssh_box() { ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=10 "root@$host" "$@"; }
# The SSH session runs inside the Alpine tree, where the engine's /etc lives.
tar -cf - ca.pem server-cert.pem server-key.pem | ssh_box '
set -eu
mkdir -p /etc/docker/tls
chmod 700 /etc/docker/tls
tar -xf - -C /etc/docker/tls
chown -R root:root /etc/docker/tls
chmod 600 /etc/docker/tls/server-key.pem
chmod 644 /etc/docker/tls/ca.pem /etc/docker/tls/server-cert.pem
if [ -e /etc/docker/daemon.json ] && ! grep -q tlsverify /etc/docker/daemon.json; then
    cp -p /etc/docker/daemon.json /etc/docker/daemon.json.pre-tls
fi
cat > /etc/docker/daemon.json.new <<JSON
{
  "storage-driver": "vfs",
  "ip6tables": false,
  "log-driver": "local",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "hosts": ["unix:///var/run/docker.sock", "tcp://0.0.0.0:2376"],
  "tls": true,
  "tlsverify": true,
  "tlscacert": "/etc/docker/tls/ca.pem",
  "tlscert": "/etc/docker/tls/server-cert.pem",
  "tlskey": "/etc/docker/tls/server-key.pem"
}
JSON
dockerd --validate --config-file /etc/docker/daemon.json.new
mv -f /etc/docker/daemon.json.new /etc/docker/daemon.json
sync
# procps pkill -x does not match dockerd here; signal by PID.
pids=$(pidof dockerd || true)
if [ -n "$pids" ]; then kill -TERM $pids; fi
'
echo "Installed; waiting for the supervisor to restart dockerd"
for _ in $(seq 60); do
    # openssl, not curl: Git for Windows curl (Schannel) cannot load PEM client keys.
    if printf 'GET /_ping HTTP/1.0\r\n\r\n' | timeout 10 openssl s_client -quiet -connect "$host:2376" \
        -CAfile ca.pem -cert cert.pem -key key.pem -verify_return_error 2>/dev/null | grep -q '^OK'; then
        echo "MIBOX_DOCKER_TLS_READY https://$host:2376"
        exit 0
    fi
    sleep 2
done
echo "MIBOX_DOCKER_TLS_TIMEOUT" >&2
exit 1
