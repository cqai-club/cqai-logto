#!/usr/bin/env bash

set -euo pipefail

image_ref=${1:?Image reference is required}
deploy_base=${2:-/data/cqai-logto}
compose_file="$deploy_base/docker-compose.production.yml"
env_file="$deploy_base/.env"
backup_dir="$deploy_base/backups"
retention_file="$deploy_base/image-retention.env"

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

previous_rollback_image=''
if [[ -f "$retention_file" ]]; then
  previous_rollback_image=$(sed -n 's/^rollback_image=//p' "$retention_file" | head -n 1)
fi

rollback_image="$previous_image"
if [[ -z "$rollback_image" || "$rollback_image" == "$image_ref" ]]; then
  rollback_image="$previous_rollback_image"
fi

rollback_app() {
  if [[ -z "$previous_image" || "$previous_image" == "$image_ref" ]]; then
    return 0
  fi

  echo "Restoring application image: $previous_image" >&2
  export LOGTO_IMAGE="$previous_image"
  if ! "${compose[@]}" up -d app; then
    echo "Failed to restore application image: $previous_image" >&2
    return 1
  fi
}

retain_app_images() {
  local image_repository
  local candidate
  local current_image=${1-}
  local retained_rollback_image=${2-}

  current_image=${current_image:-$image_ref}

  if [[ "$current_image" == *@* ]]; then
    image_repository="${current_image%%@*}"
  else
    image_repository="${current_image%:*}"
  fi

  while IFS= read -r candidate; do
    [[ -z "$candidate" || "$candidate" == '<none>:<none>' ]] && continue
    [[ "$candidate" == "$current_image" || "$candidate" == "$retained_rollback_image" ]] && continue
    # PostgreSQL may be mirrored into the same GHCR repository as the app.
    [[ "$candidate" == "$image_repository:postgres-17-alpine" ]] && continue

    echo "Removing old application image: $candidate"
    docker image rm "$candidate" || echo "Warning: could not remove $candidate" >&2
  done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' "$image_repository")

  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    echo "Removing dangling application image: $candidate"
    docker image rm "$candidate" || echo "Warning: could not remove $candidate" >&2
  done < <(docker image ls --filter dangling=true --format '{{.ID}}' "$image_repository" | sort -u)
}

write_retention_state() {
  local state_file="$retention_file.tmp"
  local current_image=${1-}
  local retained_rollback_image=${2-}

  current_image=${current_image:-$image_ref}

  {
    printf 'current_image=%s\n' "$current_image"
    printf 'rollback_image=%s\n' "$retained_rollback_image"
  } > "$state_file"
  chmod 600 "$state_file"
  mv "$state_file" "$retention_file"
}

restore_after_failure() {
  local failure_rollback_image

  if [[ -z "$previous_image" ]]; then
    return 0
  fi

  if ! rollback_app; then
    return 1
  fi

  failure_rollback_image="$previous_rollback_image"
  if [[ -n "$failure_rollback_image" ]] && ! docker image inspect "$failure_rollback_image" >/dev/null 2>&1; then
    failure_rollback_image=''
  fi

  rollback_image="$failure_rollback_image"
  retain_app_images "$previous_image" "$failure_rollback_image" || true
  write_retention_state "$previous_image" "$failure_rollback_image" || true
}

on_exit() {
  local status=$?

  if (( status != 0 )); then
    restore_after_failure || true
  fi

  exit "$status"
}

trap on_exit EXIT

# Pull the exact immutable commit image that the workflow pushed to GHCR.
docker pull "$image_ref"
if [[ -n "$rollback_image" ]] && ! docker image inspect "$rollback_image" >/dev/null 2>&1; then
  echo "Rollback image is no longer available locally: $rollback_image" >&2
  rollback_image=''
fi
"${compose[@]}" pull postgres
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

if ! "${compose[@]}" up -d app; then
  exit 1
fi

app_container=$("${compose[@]}" ps -q app)
if [[ -z "$app_container" ]]; then
  echo "The application container was not created." >&2
  exit 1
fi

for _ in {1..30}; do
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$app_container" || true)
  if [[ "$health" == 'healthy' ]]; then
    retain_app_images "$image_ref" "$rollback_image"
    write_retention_state "$image_ref" "$rollback_image"
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

exit 1
