#!/usr/bin/env bash

set -euo pipefail

: "${DEPLOY_HOST:?DEPLOY_HOST is required}"
: "${DEPLOY_PORT:?DEPLOY_PORT is required}"
: "${DEPLOY_USER:?DEPLOY_USER is required}"
: "${CERTBOT_TOKEN:?CERTBOT_TOKEN is required}"

challenge_file=/var/www/certbot/.well-known/acme-challenge/$CERTBOT_TOKEN
ssh -i "$HOME/.ssh/id_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -p "$DEPLOY_PORT" "$DEPLOY_USER@$DEPLOY_HOST" \
  "unlink '$challenge_file' 2>/dev/null || true"
