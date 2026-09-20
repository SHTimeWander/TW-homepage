#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

payload_dir=${1:?Usage: deploy-remote.sh PAYLOAD_DIRECTORY}
# This file is generated with Bash %q quoting by ci-deploy.sh, never by users.
# shellcheck disable=SC1091
source "$payload_dir/deploy.env"
: "${APP_NAME:?}" "${APP_DEPLOY_PATH:?}" "${APP_PORT:?}" "${IMAGE:?}"

docker info > /dev/null
mkdir -p "$APP_DEPLOY_PATH/config"
exec 9> "$APP_DEPLOY_PATH/.deploy.lock"
flock -n 9 || { echo 'Another deployment is already running.' >&2; exit 1; }

backup="${APP_NAME}-rollback"
previous_image=
previous_running=false
has_backup=false
replacement_started=false

owned_container() {
  [[ "$(docker inspect --format '{{ index .Config.Labels "io.timewander.app" }}' "$1")" == "$APP_NAME" ]]
}

# Refuse to take over unrelated containers or a backup left by an interrupted run.
if docker container inspect "$backup" > /dev/null 2>&1; then
  echo "Container $backup already exists; inspect/recover the previous deployment first." >&2
  exit 1
fi
if docker container inspect "$APP_NAME" > /dev/null 2>&1; then
  owned_container "$APP_NAME" || { echo "Container $APP_NAME is not managed by this deployment." >&2; exit 1; }
  previous_image=$(docker inspect --format '{{.Config.Image}}' "$APP_NAME")
  previous_running=$(docker inspect --format '{{.State.Running}}' "$APP_NAME")
fi

# Load and validate the new image before changing the running service.
gzip -dc "$payload_dir/image.tar.gz" | docker load
[[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$IMAGE")" == linux/amd64 ]]

rollback() {
  status=$?
  trap - EXIT INT TERM
  if (( status != 0 )); then
    echo 'Deployment failed; restoring the previous container.' >&2
    if [[ "$replacement_started" == true ]]; then
      docker rm -f "$APP_NAME" > /dev/null 2>&1 || true
    fi
    if [[ "$has_backup" == true ]]; then
      if docker rename "$backup" "$APP_NAME"; then
        if [[ "$previous_running" == true ]]; then
          docker start "$APP_NAME" > /dev/null || echo 'ERROR: Could not restart the previous container.' >&2
        fi
      else
        echo "ERROR: Could not restore $backup; manual recovery is required." >&2
      fi
    fi
    if [[ "$IMAGE" != "$previous_image" ]]; then
      docker image rm "$IMAGE" > /dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n "$previous_image" ]]; then
  docker rename "$APP_NAME" "$backup"
  has_backup=true
  docker stop --time 30 "$backup" > /dev/null
fi

replacement_started=true
docker run -d \
  --name "$APP_NAME" \
  --label "io.timewander.app=$APP_NAME" \
  --restart unless-stopped \
  --publish "$APP_PORT:3000" \
  --env-file "$payload_dir/app.env" \
  --env PUID=1000 --env PGID=1000 \
  --volume "$APP_DEPLOY_PATH/config:/app/config:Z" \
  "$IMAGE" > /dev/null

healthy=false
for ((attempt = 0; attempt < 60; attempt++)); do
  health=$(docker inspect --format '{{.State.Health.Status}}' "$APP_NAME")
  if [[ "$health" == healthy ]]; then
    healthy=true
    break
  fi
  if [[ "$health" == unhealthy || "$(docker inspect --format '{{.State.Running}}' "$APP_NAME")" != true ]]; then
    break
  fi
  sleep 2
done
[[ "$healthy" == true ]] || { echo 'New container did not become healthy within 120 seconds.' >&2; exit 1; }

# Commit the deployment only after the Dockerfile's /api/healthcheck succeeds.
trap - EXIT INT TERM
if [[ "$has_backup" == true ]]; then
  docker rm "$backup" > /dev/null
fi
if [[ -n "$previous_image" && "$previous_image" != "$IMAGE" && "$previous_image" == "$APP_NAME:"* ]]; then
  docker image rm "$previous_image" > /dev/null 2>&1 || true
fi
echo "Deployment healthy: $IMAGE on port $APP_PORT"
