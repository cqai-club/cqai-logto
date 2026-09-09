#!/usr/bin/env bash

set -euo pipefail

: "${DEPLOY_HOST:?DEPLOY_HOST is required}"
: "${DEPLOY_PORT:?DEPLOY_PORT is required}"
: "${DEPLOY_USER:?DEPLOY_USER is required}"
: "${CERTBOT_TOKEN:?CERTBOT_TOKEN is required}"
: "${CERTBOT_VALIDATION:?CERTBOT_VALIDATION is required}"

challenge_directory=/var/www/certbot/.well-known/acme-challenge
ssh_options=(
  -i "$HOME/.ssh/id_ed25519"
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -p "$DEPLOY_PORT"
)

ssh "${ssh_options[@]}" "$DEPLOY_USER@$DEPLOY_HOST" \
  "install -d -m 755 '$challenge_directory'"
printf '%s' "$CERTBOT_VALIDATION" | ssh "${ssh_options[@]}" "$DEPLOY_USER@$DEPLOY_HOST" \
  "tee '$challenge_directory/$CERTBOT_TOKEN' >/dev/null && chmod 644 '$challenge_directory/$CERTBOT_TOKEN'"
