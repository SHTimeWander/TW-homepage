#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

required=(APP_NAME APP_DEPLOY_PATH APP_PORT HOMEPAGE_ALLOWED_HOSTS GITHUB_SHA
  SSH_JUMP_HOST SSH_JUMP_PORT SSH_JUMP_USER SSH_TEST_HOST SSH_TEST_PORT SSH_TEST_USER
  SSH_KNOWN_HOSTS SSH_JUMP_PASSWORD SSH_TEST_PASSWORD)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing Actions variable or secret: $name" >&2
    exit 1
  fi
done

[[ "$APP_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
[[ "$APP_DEPLOY_PATH" =~ ^/[a-zA-Z0-9_/-]+$ && "$APP_DEPLOY_PATH" != / ]]
[[ "/$APP_DEPLOY_PATH/" != */../* && "/$APP_DEPLOY_PATH/" != */./* ]]
[[ "$GITHUB_SHA" =~ ^[a-f0-9]{40}$ ]]
for name in APP_PORT SSH_JUMP_PORT SSH_TEST_PORT; do
  [[ "${!name}" =~ ^[1-9][0-9]{0,4}$ ]] && (( ${!name} <= 65535 ))
done
for name in SSH_JUMP_HOST SSH_TEST_HOST; do
  [[ "${!name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]
done
for name in SSH_JUMP_USER SSH_TEST_USER; do
  [[ "${!name}" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]
done
[[ "$HOMEPAGE_ALLOWED_HOSTS" != *$'\n'* && "$HOMEPAGE_ALLOWED_HOSTS" != *$'\r'* ]]
[[ -f "${1:?Usage: ci-deploy.sh IMAGE.tar.gz}" ]]

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work_dir=$(mktemp -d)
remote_dir=
cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$remote_dir" ]]; then
    ssh -F "$work_dir/ssh_config" test-server "rm -rf -- '$remote_dir'" || true
  fi
  rm -rf -- "$work_dir"
  exit "$status"
}
trap cleanup EXIT

printf '%s\n' "$SSH_KNOWN_HOSTS" > "$work_dir/known_hosts"
cat > "$work_dir/ssh_config" <<EOF
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
    LogLevel ERROR
EOF

# OpenSSH asks separately for the jump-host and target passwords. Neither
# password is placed in command arguments, the SSH config, or the payload.
cat > "$work_dir/askpass" <<'EOF'
#!/bin/sh
case "$1" in
  *"${SSH_JUMP_USER}@${SSH_JUMP_HOST}"*) printf '%s\n' "$SSH_JUMP_PASSWORD" ;;
  *"${SSH_TEST_USER}@${SSH_TEST_HOST}"*) printf '%s\n' "$SSH_TEST_PASSWORD" ;;
  *) exit 1 ;;
esac
EOF
chmod 700 "$work_dir/askpass"
export SSH_ASKPASS="$work_dir/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=ci-deploy

remote_dir=$(ssh -F "$work_dir/ssh_config" test-server 'umask 077; mktemp -d /tmp/homepage-deploy.XXXXXXXXXX')
[[ "$remote_dir" =~ ^/tmp/homepage-deploy\.[a-zA-Z0-9]+$ ]] || { remote_dir=; exit 1; }

{
  printf 'APP_NAME=%q\n' "$APP_NAME"
  printf 'APP_DEPLOY_PATH=%q\n' "$APP_DEPLOY_PATH"
  printf 'APP_PORT=%q\n' "$APP_PORT"
  printf 'IMAGE=%q\n' "$APP_NAME:$GITHUB_SHA"
} > "$work_dir/deploy.env"
printf '%s\n' "${APP_ENV_FILE:-}" > "$work_dir/app.env"
# The dedicated repository variable is authoritative, even if APP_ENV_FILE
# happens to contain an older HOMEPAGE_ALLOWED_HOSTS entry.
printf 'HOMEPAGE_ALLOWED_HOSTS=%s\n' "$HOMEPAGE_ALLOWED_HOSTS" >> "$work_dir/app.env"

# Several SSH streams tolerate the high-latency runner-to-jump-host link much
# better than a single large SCP. Retry individual chunks, then verify the
# complete archive before allowing the remote script to replace any container.
split -b 8M -d -a 4 "$1" "$work_dir/image.part-"
sha256sum "$1" | awk '{ print $1 "  image.tar.gz" }' > "$work_dir/image.sha256"
cat > "$work_dir/upload-part" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
part=$1
for attempt in 1 2 3; do
  if scp -F "$DEPLOY_SSH_CONFIG" "$part" "test-server:$DEPLOY_REMOTE_DIR/$(basename "$part")"; then
    echo "Uploaded $(basename "$part")"
    exit 0
  fi
  echo "Retrying $(basename "$part") (attempt $attempt)." >&2
  sleep 5
done
exit 1
EOF
chmod 700 "$work_dir/upload-part"
export DEPLOY_SSH_CONFIG="$work_dir/ssh_config" DEPLOY_REMOTE_DIR="$remote_dir"
find "$work_dir" -name 'image.part-*' -print0 | xargs -0 -n 1 -P 8 "$work_dir/upload-part"
scp -F "$work_dir/ssh_config" "$work_dir/image.sha256" "test-server:$remote_dir/"
ssh -F "$work_dir/ssh_config" test-server \
  "cd '$remote_dir' && cat image.part-* > image.tar.gz && sha256sum -c image.sha256 && rm -- image.part-*"
scp -F "$work_dir/ssh_config" "$work_dir/deploy.env" "$work_dir/app.env" \
  "$script_dir/deploy-remote.sh" "test-server:$remote_dir/"
ssh -F "$work_dir/ssh_config" test-server "bash '$remote_dir/deploy-remote.sh' '$remote_dir'"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf 'Deployed %s to the test server (port %s). Container health check passed.\n' \
    "$APP_NAME:$GITHUB_SHA" "$APP_PORT" >> "$GITHUB_STEP_SUMMARY"
fi
