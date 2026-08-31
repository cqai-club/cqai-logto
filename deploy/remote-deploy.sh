#!/usr/bin/env bash

set -euo pipefail

image_ref=${1:?Image reference is required}
deploy_base=${2:-/data/cqai-logto}
compose_file="$deploy_base/docker-compose.production.yml"
env_file="$deploy_base/.env"
backup_dir="$deploy_base/backups"

if [[ ! -f "$compose_file" ]]; then
  echo "Missing deployment compose file: $compose_file" >&2
  exit 1
fi

if [[ ! -f "$env_file" ]]; then
  echo "Missing production environment file: $env_file" >&2
  echo "Copy $deploy_base/.env.example to $env_file and fill in the production values." >&2
  exit 1
fi

mkdir -p "$backup_dir"
cd "$deploy_base"

export LOGTO_IMAGE="$image_ref"
if docker compose version >/dev/null 2>&1; then
  compose=(docker compose --env-file "$env_file" -f "$compose_file")
elif command -v docker-compose >/dev/null 2>&1; then
  compose=(docker-compose --env-file "$env_file" -f "$compose_file")
else
  echo 'Docker Compose is required on the deployment server.' >&2
  exit 1
fi

previous_container=$("${compose[@]}" ps -q app 2>/dev/null || true)
previous_image=''
if [[ -n "$previous_container" ]]; then
  previous_image=$(docker inspect --format '{{.Config.Image}}' "$previous_container" 2>/dev/null || true)
fi

"${compose[@]}" pull postgres app
"${compose[@]}" up -d postgres

for _ in {1..24}; do
  if "${compose[@]}" exec -T postgres pg_isready -U logto -d logto >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

"${compose[@]}" exec -T postgres pg_isready -U logto -d logto >/dev/null

has_schema=$("${compose[@]}" exec -T postgres \
  psql -U logto -d logto -Atqc \
  "select exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'logto_configs');")

if [[ "$has_schema" == 't' ]]; then
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  "${compose[@]}" exec -T postgres pg_dump -U logto -d logto -Fc \
    > "$backup_dir/logto-$timestamp.dump"
  find "$backup_dir" -type f -name 'logto-*.dump' -mtime +14 -delete
  "${compose[@]}" run --rm app cli db alt deploy
else
  "${compose[@]}" run --rm app cli db seed -- --swe
  "${compose[@]}" exec -T postgres psql -U logto -d logto -v ON_ERROR_STOP=1 -c \
    "update sign_in_experiences set language_info = jsonb_build_object('autoDetect', false, 'fallbackLanguage', 'zh-CN') where tenant_id in ('admin', 'default');"
fi

"${compose[@]}" up -d app

app_container=$("${compose[@]}" ps -q app)
for _ in {1..30}; do
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$app_container")
  if [[ "$health" == 'healthy' ]]; then
    echo "Logto deployment is healthy: $image_ref"
    exit 0
  fi
  if [[ "$health" == 'unhealthy' || "$health" == 'exited' ]]; then
    break
  fi
  sleep 5
done

echo "Logto deployment did not become healthy." >&2
"${compose[@]}" logs --tail=200 app >&2 || true

if [[ -n "$previous_image" && "$previous_image" != "$image_ref" ]]; then
  echo "Rolling the application container back to $previous_image" >&2
  export LOGTO_IMAGE="$previous_image"
  "${compose[@]}" up -d app
fi

exit 1
