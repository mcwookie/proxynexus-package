#!/bin/sh
# Bootstraps a single-node Garage cluster (layout, bucket, key, public
# website access) and hands the generated S3 credentials to garage-init
# via a shared volume -- then runs the server in the foreground.
#
# Safe to re-run on every `docker compose up`: every step below checks
# current state first and skips anything already done. Verified by hand
# (fresh start, then restart with existing data) before this was written
# into the compose file.
set -e

BUCKET="proxynexus-collections"
KEY_NAME="proxynexus-key"
CREDS_FILE="/shared/garage-credentials.env"
RPC_SECRET_FILE="/data/rpc_secret"

# rpc_secret only guards intra-cluster/admin RPC, which never leaves the
# compose network here (no port published for it) -- auto-generate and
# persist it rather than asking for yet another secret in .env that the
# user would never actually need to type in anywhere.
if [ ! -f "$RPC_SECRET_FILE" ]; then
  head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$RPC_SECRET_FILE"
fi
RPC_SECRET=$(cat "$RPC_SECRET_FILE")
sed "s/__RPC_SECRET__/$RPC_SECRET/" /etc/garage.toml.template > /etc/garage.toml

/garage server &
SERVER_PID=$!

echo "Waiting for Garage RPC to come up..."
until /garage status >/dev/null 2>&1; do
  sleep 1
done

NODE_ID=$(/garage node id -q | cut -d'@' -f1)

if /garage status 2>/dev/null | grep -q "NO ROLE ASSIGNED"; then
  echo "No layout yet -- bootstrapping single-node layout..."
  /garage layout assign -z dc1 -c 1G "$NODE_ID"
  VERSION=$(/garage layout show 2>/dev/null | grep "Current cluster layout version:" | grep -oE '[0-9]+')
  /garage layout apply --version "$((VERSION + 1))"
else
  echo "Layout already assigned, skipping."
fi

if ! /garage bucket list 2>/dev/null | grep -q "$BUCKET"; then
  echo "Creating bucket $BUCKET..."
  /garage bucket create "$BUCKET"
else
  echo "Bucket $BUCKET already exists, skipping."
fi

if ! /garage key list 2>/dev/null | grep -q "$KEY_NAME"; then
  echo "Creating key $KEY_NAME..."
  /garage key create "$KEY_NAME"
else
  echo "Key $KEY_NAME already exists, skipping."
fi

/garage bucket allow --read --write --key "$KEY_NAME" "$BUCKET"
/garage bucket website --allow "$BUCKET"

mkdir -p /shared
KEY_ID=$(/garage key info "$KEY_NAME" --show-secret 2>/dev/null | grep "Key ID:" | awk '{print $3}')
SECRET=$(/garage key info "$KEY_NAME" --show-secret 2>/dev/null | grep "Secret key:" | awk '{print $3}')
cat > "$CREDS_FILE" << EOF
GARAGE_KEY_ID=$KEY_ID
GARAGE_SECRET=$SECRET
EOF
echo "Bootstrap complete, credentials written to $CREDS_FILE"

wait "$SERVER_PID"
