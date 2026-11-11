#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE=/etc/default/impostor-update
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
fi

REPO="${REPO:-YetAnotherRolesAU/Impostor}"
INSTALL_DIR="${INSTALL_DIR:-/opt/impostor/current}"
SERVICE="${SERVICE:-impostor}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:22023/api/games}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"

BASE_URL="https://github.com/${REPO}/releases/download/latest"
ASSET="Impostor-Server_linux-x64.tar.gz"
STATE_FILE="${INSTALL_DIR}/.deployed-version"
FAILED_FILE="${INSTALL_DIR}/.failed-version"
BACKUP_ROOT="${INSTALL_DIR}/.backup"
PRESERVE_REGEX='^(config\.json|plugins|libraries)$'

log() {
    echo "impostor-update: $*"
}

exec 9>/var/lock/impostor-update.lock
flock -n 9 || exit 0

if [ ! -d "$INSTALL_DIR" ]; then
    log "install dir not found: ${INSTALL_DIR}"
    exit 1
fi

if ! remote_version="$(curl -fsSL --max-time 30 "${BASE_URL}/version.txt" | tr -d '[:space:]')"; then
    log "could not fetch version.txt, will retry later"
    exit 0
fi

if [ -z "$remote_version" ]; then
    log "empty version.txt, will retry later"
    exit 0
fi

current_version="$(cat "$STATE_FILE" 2>/dev/null || true)"
failed_version="$(cat "$FAILED_FILE" 2>/dev/null || true)"

if [ "$remote_version" = "$current_version" ]; then
    exit 0
fi

if [ "$remote_version" = "$failed_version" ]; then
    log "version ${remote_version} failed before, skipping"
    exit 0
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

log "downloading ${remote_version}"
curl -fsSL --max-time 300 -o "${work_dir}/pkg.tar.gz" "${BASE_URL}/${ASSET}"
curl -fsSL --max-time 30 -o "${work_dir}/pkg.sha256" "${BASE_URL}/${ASSET}.sha256"

expected_hash="$(awk '{print $1}' "${work_dir}/pkg.sha256")"
echo "${expected_hash}  ${work_dir}/pkg.tar.gz" | sha256sum -c --quiet -

mkdir -p "${work_dir}/new"
tar -xzf "${work_dir}/pkg.tar.gz" -C "${work_dir}/new"

if [ ! -f "${work_dir}/new/Impostor.Server" ]; then
    log "package does not contain Impostor.Server"
    exit 1
fi

backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"

updated=()
while IFS= read -r -d '' path; do
    name="$(basename "$path")"
    if [[ "$name" =~ $PRESERVE_REGEX ]]; then
        continue
    fi
    updated+=("$name")
    if [ -e "${INSTALL_DIR}/${name}" ]; then
        cp -p "${INSTALL_DIR}/${name}" "${backup_dir}/${name}"
    fi
done < <(find "${work_dir}/new" -mindepth 1 -maxdepth 1 -type f -print0)

rollback() {
    log "rolling back"
    for name in "${updated[@]}"; do
        if [ -e "${backup_dir}/${name}" ]; then
            cp -p "${backup_dir}/${name}" "${INSTALL_DIR}/.${name}.rollback"
            mv -f "${INSTALL_DIR}/.${name}.rollback" "${INSTALL_DIR}/${name}"
        else
            rm -f "${INSTALL_DIR}/${name}"
        fi
    done
    systemctl restart "$SERVICE" || true
}

for name in "${updated[@]}"; do
    if [ -e "${INSTALL_DIR}/${name}" ]; then
        chown --reference="${INSTALL_DIR}/${name}" "${work_dir}/new/${name}" || true
        chmod --reference="${INSTALL_DIR}/${name}" "${work_dir}/new/${name}" || true
    else
        chmod 755 "${work_dir}/new/${name}"
    fi
    cp -p "${work_dir}/new/${name}" "${INSTALL_DIR}/.${name}.new"
    mv -f "${INSTALL_DIR}/.${name}.new" "${INSTALL_DIR}/${name}"
done

log "restarting ${SERVICE}"
systemctl restart "$SERVICE"

healthy=0
for _ in $(seq 1 30); do
    sleep 1
    if ! systemctl is-active --quiet "$SERVICE"; then
        continue
    fi
    if curl -fsS --max-time 3 -X PUT "$HEALTH_URL" -o /dev/null; then
        healthy=1
        break
    fi
done

if [ "$healthy" -ne 1 ]; then
    log "health check failed for ${remote_version}"
    echo "$remote_version" > "$FAILED_FILE"
    rollback
    exit 1
fi

echo "$remote_version" > "$STATE_FILE"
rm -f "$FAILED_FILE"
log "deployed ${remote_version}"

if [ -d "$BACKUP_ROOT" ]; then
    ls -1dt "${BACKUP_ROOT}"/*/ 2>/dev/null | tail -n +"$((KEEP_BACKUPS + 1))" | xargs -r rm -rf
fi
