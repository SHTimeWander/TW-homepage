#!/usr/bin/env bash
set -euo pipefail
umask 077

for name in APP_IMAGE APP_NAME APP_DEPLOY_PATH APP_PORT HOMEPAGE_ALLOWED_HOSTS GITHUB_SHA \
  ALIYUN_REGISTRY ALIYUN_REGISTRY_USER ALIYUN_REGISTRY_PASSWORD \
  SSH_JUMP_HOST SSH_JUMP_PORT SSH_JUMP_USER SSH_TEST_HOST SSH_TEST_PORT SSH_TEST_USER \
  SSH_KNOWN_HOSTS SSH_JUMP_PASSWORD SSH_TEST_PASSWORD; do
  [[ -n "${!name:-}" ]] || { echo "Missing deployment value: $name" >&2; exit 1; }
done
[[ "$APP_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
[[ "$ALIYUN_REGISTRY" =~ ^[a-z0-9.-]+$ && "$ALIYUN_REGISTRY_USER" =~ ^[a-zA-Z0-9_@.-]+$ ]]
[[ "$APP_IMAGE" == "$ALIYUN_REGISTRY/"* && "$APP_IMAGE" =~ ^[a-z0-9._/-]+$ ]]
[[ "$GITHUB_SHA" =~ ^[a-f0-9]{40}$ ]]
[[ "$APP_DEPLOY_PATH" =~ ^/[a-zA-Z0-9_/-]+$ && "$APP_DEPLOY_PATH" != / ]]
[[ "$HOMEPAGE_ALLOWED_HOSTS" =~ ^[a-zA-Z0-9.,:*_-]+$ ]]
for name in APP_PORT SSH_JUMP_PORT SSH_TEST_PORT; do
  [[ "${!name}" =~ ^[1-9][0-9]{0,4}$ ]] && (( ${!name} <= 65535 ))
done
for name in SSH_JUMP_HOST SSH_JUMP_USER SSH_TEST_HOST SSH_TEST_USER; do
  [[ "${!name}" =~ ^[a-zA-Z0-9_.-]+$ ]]
done

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
printf '%s\n' "$SSH_KNOWN_HOSTS" > "$work_dir/known_hosts"
cat > "$work_dir/ssh_config" <<EOF_CONFIG
Host jump-host
    HostName $SSH_JUMP_HOST
    Port $SSH_JUMP_PORT
    User $SSH_JUMP_USER
Host test-server
    HostName $SSH_TEST_HOST
    Port $SSH_TEST_PORT
    User $SSH_TEST_USER
    ProxyJump jump-host
Host *
    UserKnownHostsFile "$work_dir/known_hosts"
    StrictHostKeyChecking yes
    PubkeyAuthentication no
    PreferredAuthentications password
    NumberOfPasswordPrompts 1
    ConnectTimeout 15
    ServerAliveInterval 15
    ServerAliveCountMax 3
EOF_CONFIG
cat > "$work_dir/askpass" <<'EOF_ASKPASS'
#!/bin/sh
case "$1" in
  *"${SSH_JUMP_USER}@${SSH_JUMP_HOST}"*) printf '%s\n' "$SSH_JUMP_PASSWORD" ;;
  *"${SSH_TEST_USER}@${SSH_TEST_HOST}"*) printf '%s\n' "$SSH_TEST_PASSWORD" ;;
  *) exit 1 ;;
esac
EOF_ASKPASS
chmod 700 "$work_dir/askpass"
export SSH_ASKPASS="$work_dir/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=ci-deploy

cat > "$work_dir/.deploy.env" <<EOF_ENV
APP_IMAGE=$APP_IMAGE:$GITHUB_SHA
APP_NAME=$APP_NAME
APP_PORT=$APP_PORT
HOMEPAGE_ALLOWED_HOSTS=$HOMEPAGE_ALLOWED_HOSTS
EOF_ENV
printf '%s\n' "${APP_ENV_FILE:-}" > "$work_dir/.app.env"
cat > "$work_dir/.deploy.sh" <<'EOF_REMOTE'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export DOCKER_CONFIG
DOCKER_CONFIG=$(mktemp -d)
trap 'rm -rf "$DOCKER_CONFIG"' EXIT

docker login "$1" --username "$2" --password-stdin
docker compose --env-file .deploy.env pull
docker compose --env-file .deploy.env up -d --remove-orphans --wait --wait-timeout 120
docker compose --env-file .deploy.env ps
EOF_REMOTE

ssh -F "$work_dir/ssh_config" test-server "install -d -m 0750 '$APP_DEPLOY_PATH' '$APP_DEPLOY_PATH/config'"
scp -F "$work_dir/ssh_config" .github/compose.yaml "$work_dir/.deploy.env" \
  "$work_dir/.app.env" "$work_dir/.deploy.sh" "test-server:$APP_DEPLOY_PATH/"
printf '%s' "$ALIYUN_REGISTRY_PASSWORD" | ssh -F "$work_dir/ssh_config" test-server \
  "bash '$APP_DEPLOY_PATH/.deploy.sh' '$ALIYUN_REGISTRY' '$ALIYUN_REGISTRY_USER'"
