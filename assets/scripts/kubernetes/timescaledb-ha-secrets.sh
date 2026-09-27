#!/usr/bin/env bash
#
# TimescaleDB Patroni 클러스터(iot/hub/timescaledb, stacks/seoul/timescaledb)의 비밀값을 만듭니다. 여러 번 실행해도 됩니다.
#   - Patroni superuser(postgres)·replication(replicator) 비밀번호: ~/.config/iot/secrets.env 에 없으면 무작위로 만들어 적습니다
#   - 허브 timescaledb/timescaledb-patroni Secret (PATRONI_SUPERUSER_PASSWORD, PATRONI_REPLICATION_PASSWORD)
#   - 서울 NAS 멤버용 파일(~/.config/portainer/secrets/, portainer-stack.sh 가 Swarm secret 으로 만듦):
#       timescaledb_superuser_password_<SUFFIX>, timescaledb_replication_password_<SUFFIX>,
#       timescaledb_kubeconfig_<SUFFIX>  (ServiceAccount patroni-nas 토큰. timescaledb 네임스페이스 안에서만 권한이 있음)
#   - 지역 DB(iot/edge/timescaledb)의 timescaledb/timescaledb-patroni Secret (EDGE_KUBECONFIG 를 준 지역마다, 허브와 같은 값)
# 허브의 iot·grafana 비밀번호(timescaledb-credentials)는 blog 의 create-iot-secrets.sh 가 만든 것을 그대로 씁니다.
#
# 사용법: bash scripts/timescaledb-ha-secrets.sh [SUFFIX] [EDGE_KUBECONFIG ...]
#   SUFFIX 기본값 v1(값을 바꿀 때는 새 SUFFIX 로). EDGE_KUBECONFIG 는 허브 kubectl 호스트 기준 경로(예: /home/ubuntu/k8s-daejeon.yaml)

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
KUBECTL=(ssh ubuntu@[CONTROL_PLANE_IP] kubectl)      # 허브 kubectl (내부망 DNS 의 역할 이름. 노드를 바꿔도 그대로)
API_SERVER=https://[API_VIP]:6443             # NAS 가 붙을 API 주소(VIP, Tailscale 서브넷 경로로 닿음)
# --------------------------------------

SUFFIX=${1:-v1}
EDGE_KUBECONFIGS=("${@:2}")
ENV_FILE=$HOME/.config/iot/secrets.env
OUT=$HOME/.config/portainer/secrets
log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR
umask 077
mkdir -p "$(dirname "$ENV_FILE")" "$OUT"

# ---------- 1. 비밀번호 ----------
log "비밀번호 ($ENV_FILE)"
touch "$ENV_FILE"
for v in PATRONI_SUPERUSER_PASSWORD PATRONI_REPLICATION_PASSWORD; do
  if ! grep -q "^$v=" "$ENV_FILE"; then
    echo "$v=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')" >> "$ENV_FILE"; echo "    $v: 만듦"
  else echo "    $v: 있음"; fi
done
set -a; . "$ENV_FILE"; set +a

# ---------- 2. 허브 Secret ----------
log "허브 timescaledb/timescaledb-patroni"
"${KUBECTL[@]}" create namespace timescaledb --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null
# 값은 표준입력으로 넘겨 명령줄·기록에 남기지 않습니다
printf 'PATRONI_SUPERUSER_PASSWORD=%s\nPATRONI_REPLICATION_PASSWORD=%s\n' "$PATRONI_SUPERUSER_PASSWORD" "$PATRONI_REPLICATION_PASSWORD" \
  | "${KUBECTL[@]}" -n timescaledb create secret generic timescaledb-patroni --from-env-file=/dev/stdin --dry-run=client -o yaml \
  | "${KUBECTL[@]}" apply -f - >/dev/null

# ---------- 2-1. 지역 DB Secret ----------
for k in "${EDGE_KUBECONFIGS[@]}"; do
  log "지역 timescaledb/timescaledb-patroni ($k)"
  E=("${KUBECTL[@]}" --kubeconfig "$k")
  "${E[@]}" create namespace timescaledb --dry-run=client -o yaml | "${E[@]}" apply -f - >/dev/null
  printf 'PATRONI_SUPERUSER_PASSWORD=%s\nPATRONI_REPLICATION_PASSWORD=%s\n' "$PATRONI_SUPERUSER_PASSWORD" "$PATRONI_REPLICATION_PASSWORD" \
    | "${E[@]}" -n timescaledb create secret generic timescaledb-patroni --from-env-file=/dev/stdin --dry-run=client -o yaml \
    | "${E[@]}" apply -f - >/dev/null
done

# ---------- 3. NAS 멤버 파일 ----------
log "NAS 멤버 파일 → $OUT"
printf '%s' "$PATRONI_SUPERUSER_PASSWORD" > "$OUT/timescaledb_superuser_password_$SUFFIX"
printf '%s' "$PATRONI_REPLICATION_PASSWORD" > "$OUT/timescaledb_replication_password_$SUFFIX"
# ServiceAccount 토큰은 iot/hub/timescaledb/patroni-rbac.yaml 의 Secret 에 컨트롤러가 채웁니다(Argo CD 동기화 뒤)
# jsonpath 는 ssh 너머에서 따옴표·역슬래시가 풀리므로 JSON 으로 받아 여기서 꺼냅니다
SA_JSON=$("${KUBECTL[@]}" -n timescaledb get secret patroni-nas-token -o json 2>/dev/null || echo '{}')
TOKEN=$(python3 -c 'import sys,json,base64; d=json.loads(sys.stdin.read()).get("data",{}); print(base64.b64decode(d.get("token","")).decode())' <<<"$SA_JSON")
CA=$(python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("data",{}).get("ca.crt",""))' <<<"$SA_JSON")
[ -n "$TOKEN" ] && [ -n "$CA" ] || die "timescaledb/patroni-nas-token 에 토큰·CA 가 없습니다. iot/hub/timescaledb 가 동기화된 뒤 다시 실행합니다."
cat > "$OUT/timescaledb_kubeconfig_$SUFFIX" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: hub
    cluster: { server: $API_SERVER, certificate-authority-data: $CA }
users:
  - name: patroni-nas
    user: { token: $TOKEN }
contexts:
  - name: hub
    context: { cluster: hub, user: patroni-nas, namespace: timescaledb }
current-context: hub
EOF
ls -1 "$OUT" | grep "timescaledb_.*_$SUFFIX" | sed 's/^/    /'

# ---------- 4. NAS 멤버의 자리표시 Pod ----------
# Patroni 의 쿠버네티스 DCS 는 멤버 상태를 "멤버 이름과 같은 Pod" 의 주석에 적습니다. NAS 멤버는 클러스터 밖이라 Pod 가 없으므로
# 어느 노드에도 스케줄되지 않는 Pod(nas)를 둡니다. 실행되지 않아 자원을 쓰지 않고, 노드가 죽어도 영향이 없습니다.
# Argo CD 는 Pending Pod 를 계속 Progressing 으로 보므로 저장소가 아니라 여기서 만듭니다.
log "NAS 멤버 자리표시 Pod (timescaledb/nas)"
"${KUBECTL[@]}" apply -f - >/dev/null <<'POD'
apiVersion: v1
kind: Pod
metadata:
  name: nas
  namespace: timescaledb
  labels: { application: patroni, cluster-name: timescaledb }
spec:
  nodeSelector: { patroni.placeholder/never-schedule: "true" }
  containers:
    - { name: placeholder, image: registry.k8s.io/pause:3.10 }
POD
log "완료."
