#!/bin/sh
# Generates the self-signed TLS cert NGINX presents to SQL Server.
#
# IMPORTANT: reuse an existing cert, don't regenerate it. NGINX loads the
# cert at startup, and SQL Server loads it into its trusted-CA store at
# startup. If this service minted a NEW cert on every `docker compose up`, a
# re-up would leave NGINX serving the old cert while SQL trusts the new one
# (or vice-versa). The TLS handshake then fails with error 0x80070008 and
# AI_GENERATE_EMBEDDINGS calls break.
# Delete certs/nginx.crt + certs/nginx.key if you want a fresh cert.
if [ -f /certs/nginx.crt ] && [ -f /certs/nginx.key ]; then
  echo "TLS certificate already present, reusing it (keeps NGINX and SQL Server in sync)."
  exit 0
fi

echo "Generating self-signed TLS certificate..."
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /certs/nginx.key -out /certs/nginx.crt \
  -config /tmp/certs/openssl.cnf
echo "Certificate generated."
