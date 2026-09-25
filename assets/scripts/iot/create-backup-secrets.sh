#!/usr/bin/env bash
#
# 원격 NAS 백업(restic + SFTP, Cloudflare Tunnel 경유)에 필요한 비밀 값을 허브와 엣지 클러스터의 backup 네임스페이스에 만듭니다.
# 허브에 kubectl 로 접근할 수 있는 곳에서 실행합니다: bash create-backup-secrets.sh [NAS_USER] [REPO_PATH] [EDGE_KUBECONFIG] [SSH_KEY]
#   예: bash create-backup-secrets.sh [NAS_USER] /backup/k8s k3s-[SITE].yaml ~/.ssh/id_ed25519
# SSH_KEY 는 NAS 에 이미 등록된 개인 키입니다(터미널 접속에 쓰는 서버용 키를 그대로 씁니다). 키를 바꿀 때는 새 키로 다시 실행하면 두 클러스터의 키가 교체됩니다.
# 앞서 cloudflare-tunnel-setup.sh 가 허브에 backup/cloudflare-access(서비스 토큰)를 만들어 두어야 합니다. backup-credentials 는 이미 있으면 건너뜁니다(비밀번호 유지).

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
NAS_HOST=nas-ssh.[DOMAIN]                   # Cloudflare Tunnel 로 연 NAS 의 SSH 이름
CLOUDFLARED=$HOME/.local/bin/cloudflared
CLOUDFLARED_VERSION=2026.9.1
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---------- 1. 사전 검사 ----------
log "사전 검사"
NAS_USER=${1:-}; REPO_PATH=${2:-}; EDGE_KUBECONFIG=${3:-}; SSH_KEY=${4:-$HOME/.ssh/id_ed25519}
[ -n "$NAS_USER" ] && [[ "$REPO_PATH" == /* ]] && [ -r "$EDGE_KUBECONFIG" ] && [ -r "$SSH_KEY" ] \
  || die "사용법: bash create-backup-secrets.sh [NAS_USER] [REPO_PATH] [EDGE_KUBECONFIG] [SSH_KEY]"
HUB=(kubectl); EDGE=(kubectl --kubeconfig "$EDGE_KUBECONFIG")
"${HUB[@]}" -n backup get secret cloudflare-access >/dev/null || die "허브에 backup/cloudflare-access 가 없습니다. cloudflare-tunnel-setup.sh 를 먼저 실행하세요."
"${EDGE[@]}" get nodes >/dev/null || die "엣지 kubeconfig 로 접근할 수 없습니다."
if [ ! -x "$CLOUDFLARED" ]; then
  mkdir -p "$(dirname "$CLOUDFLARED")"
  curl -fsSL -o "$CLOUDFLARED" "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-amd64"
  chmod +x "$CLOUDFLARED"
fi
TOKEN_ID=$("${HUB[@]}" -n backup get secret cloudflare-access -o jsonpath='{.data.CF_ACCESS_CLIENT_ID}' | base64 -d)
TOKEN_SECRET=$("${HUB[@]}" -n backup get secret cloudflare-access -o jsonpath='{.data.CF_ACCESS_CLIENT_SECRET}' | base64 -d)

# ---------- 2. NAS 호스트 키와 로그인 확인 ----------
# 백업 파드는 StrictHostKeyChecking=yes 로 접속하므로 NAS 의 호스트 키를 받아 두고, 그 키로 SFTP 에 로그인되는지 확인합니다.
log "NAS 접속 확인 ($NAS_USER@$NAS_HOST)"
# 서비스 토큰은 명령줄(ps 에 보임) 대신 cloudflared 가 읽는 환경 변수로 넘깁니다.
echo "pwd" | TUNNEL_SERVICE_TOKEN_ID=$TOKEN_ID TUNNEL_SERVICE_TOKEN_SECRET=$TOKEN_SECRET sftp -b - -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$TMP/known_hosts" \
    -o ConnectTimeout=20 -o ProxyCommand="$CLOUDFLARED access ssh --hostname %h" "$NAS_USER@$NAS_HOST" >/dev/null 2>"$TMP/sftp.err" \
  || die "SFTP 로그인 실패: $(tail -1 "$TMP/sftp.err"). 이 키($(ssh-keygen -lf "$SSH_KEY" | cut -d' ' -f2))가 NAS 의 $NAS_USER 계정에 등록돼 있는지, NAS 의 SSH·SFTP 가 켜져 있는지 확인하세요."
cut -d' ' -f2- "$TMP/known_hosts" | sed 's/^/  호스트 키: /'

# ---------- 3. restic 저장소 비밀번호 ----------
# 저장소 하나를 두 클러스터가 함께 쓰므로 비밀번호도 하나입니다. 허브에 있으면 그것을 씁니다.
RESTIC_PASSWORD=$("${HUB[@]}" -n backup get secret backup-credentials -o jsonpath='{.data.RESTIC_PASSWORD}' 2>/dev/null | base64 -d || true)
NEW_PASSWORD=no
if [ -z "$RESTIC_PASSWORD" ]; then RESTIC_PASSWORD=$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-32); NEW_PASSWORD=yes; fi

# ---------- 4. 클러스터별 Secret ----------
# backup-credentials(환경 변수)는 없을 때만 만들고, backup-ssh(키·known_hosts)는 항상 덮어써 키 교체를 재실행으로 끝냅니다.
make_secrets() {
  local name=$1; shift
  "$@" get ns backup >/dev/null 2>&1 || "$@" create ns backup >/dev/null
  if ! "$@" -n backup get secret backup-credentials >/dev/null 2>&1; then
    "$@" -n backup create secret generic backup-credentials \
      --from-literal=RESTIC_REPOSITORY="sftp:$NAS_USER@$NAS_HOST:$REPO_PATH" \
      --from-literal=RESTIC_PASSWORD="$RESTIC_PASSWORD" \
      --from-literal=TUNNEL_SERVICE_TOKEN_ID="$TOKEN_ID" \
      --from-literal=TUNNEL_SERVICE_TOKEN_SECRET="$TOKEN_SECRET" >/dev/null
    echo "  $name: backup-credentials 만듦"
  else echo "  $name: backup-credentials 있음, 건너뜀"; fi
  "$@" -n backup create secret generic backup-ssh --from-file=id_ed25519="$SSH_KEY" --from-file=known_hosts="$TMP/known_hosts" \
    --dry-run=client -o yaml | "$@" apply -f - >/dev/null
  echo "  $name: backup-ssh 적용 ($(ssh-keygen -lf "$SSH_KEY" | cut -d' ' -f2))"
}
log "허브 Secret"; make_secrets hub "${HUB[@]}"
log "엣지 Secret"; make_secrets edge "${EDGE[@]}"
# 허브는 TimescaleDB 를 pg_dump 로 받으므로 DB 비밀번호를 같은 Secret 에 넣습니다.
PGPASS=$("${HUB[@]}" -n timescaledb get secret timescaledb-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
printf '{"stringData":{"PGPASSWORD":"%s"}}' "$PGPASS" \
  | "${HUB[@]}" -n backup patch secret backup-credentials --type merge --patch-file=/dev/stdin >/dev/null

# ---------- 5. 안내 ----------
log "완료"
if [ "$NEW_PASSWORD" = yes ]; then
  echo "restic 저장소 비밀번호입니다. 잃으면 백업을 열 수 없으니 비밀번호 관리자에 보관합니다(다시 보려면 Secret backup/backup-credentials)."
  echo "$RESTIC_PASSWORD"
fi
