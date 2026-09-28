#!/usr/bin/env bash
#
# NVR(go2rtc, recorder, occupancy 수집기, archive)이 쓰는 Secret(nvr/nvr-credentials, nvr/backup-ssh)을 엣지 클러스터에 만듭니다.
# GitOps 저장소에는 비밀 값을 넣지 않으므로 매니페스트를 push 하기 전에 실행합니다.
# 허브에 kubectl 로 접근할 수 있고 엣지 kubeconfig 가 있는 곳(control plane)에서 실행합니다: bash create-nvr-secrets.sh [EDGE_KUBECONFIG]
# 카메라 RTSP 비밀번호는 환경 변수 CAMERA_RTSP_PASSWORD 가 있으면 그것을, 없으면 실행 중에 입력받습니다.
# MQTT 비밀번호는 환경 변수 MQTT_PASSWORD 가 있으면 그것을, 없으면 엣지 telegraf-credentials 에서 가져옵니다.
# DB 비밀번호는 허브·지역의 timescaledb/timescaledb-credentials 에서 복사합니다.
# NAS rsync 용 SSH 키(backup-ssh)는 엣지 backup 네임스페이스에서 복사합니다.

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
NAMESPACE=nvr
DB_SECRET=timescaledb/timescaledb-credentials
TELEGRAF_SECRET=telegraf/telegraf-credentials
BACKUP_SECRET=backup/backup-ssh
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
log "사전 검사"
EDGE_KUBECONFIG=${1:-}
[ -r "$EDGE_KUBECONFIG" ] || die "사용법: bash create-nvr-secrets.sh [EDGE_KUBECONFIG]"
EDGE=(--kubeconfig "$EDGE_KUBECONFIG")
kubectl get nodes >/dev/null || die "kubectl 로 허브 클러스터에 접근할 수 없습니다."
kubectl "${EDGE[@]}" get nodes >/dev/null || die "엣지 kubeconfig 로 엣지 클러스터에 접근할 수 없습니다."

# 네임스페이스 준비
kubectl "${EDGE[@]}" create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl "${EDGE[@]}" apply -f - >/dev/null

# ---------- 2. nvr-credentials ----------
if kubectl "${EDGE[@]}" -n "$NAMESPACE" get secret nvr-credentials >/dev/null 2>&1; then
  echo "  엣지 $NAMESPACE/nvr-credentials 있음, 건너뜀"
else
  log "비밀값 조회"
  # DB 비밀번호
  db_password() { kubectl "$@" -n "${DB_SECRET%%/*}" get secret "${DB_SECRET##*/}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; }
  PG_HUB=$(db_password) || true
  PG_LOCAL=$(db_password "${EDGE[@]}") || true
  [ -n "$PG_HUB" ] || die "허브 $DB_SECRET 에서 POSTGRES_PASSWORD 를 읽지 못했습니다."
  [ -n "$PG_LOCAL" ] || die "엣지 $DB_SECRET 에서 POSTGRES_PASSWORD 를 읽지 못했습니다."

  # MQTT 비밀번호
  MQTT_PASSWORD=${MQTT_PASSWORD:-}
  if [ -z "$MQTT_PASSWORD" ]; then
    MQTT_PASSWORD=$(kubectl "${EDGE[@]}" -n "${TELEGRAF_SECRET%%/*}" get secret "${TELEGRAF_SECRET##*/}" -o jsonpath='{.data.MQTT_PASSWORD}' | base64 -d) || true
  fi
  [ -n "$MQTT_PASSWORD" ] || die "MQTT 비밀번호를 찾지 못했습니다."

  # 카메라 RTSP 비밀번호
  CAMERA_RTSP_PASSWORD=${CAMERA_RTSP_PASSWORD:-}
  if [ -z "$CAMERA_RTSP_PASSWORD" ]; then
    log "카메라 RTSP 비밀번호 입력 (화면에 표시되지 않음)"
    read -rsp "CAMERA_RTSP_PASSWORD: " CAMERA_RTSP_PASSWORD; echo
    [ -n "$CAMERA_RTSP_PASSWORD" ] || die "카메라 RTSP 비밀번호가 비어 있습니다."
  fi

  log "엣지 $NAMESPACE/nvr-credentials 생성"
  printf 'RTSP_PASSWORD=%s\nMQTT_PASSWORD=%s\nPGPASSWORD_LOCAL=%s\nPGPASSWORD_HUB=%s\n' \
    "$CAMERA_RTSP_PASSWORD" "$MQTT_PASSWORD" "$PG_LOCAL" "$PG_HUB" \
    | kubectl "${EDGE[@]}" -n "$NAMESPACE" create secret generic nvr-credentials --from-env-file=/dev/stdin
  unset CAMERA_RTSP_PASSWORD MQTT_PASSWORD PG_HUB PG_LOCAL
fi

# ---------- 3. backup-ssh 복사 ----------
if kubectl "${EDGE[@]}" -n "$NAMESPACE" get secret backup-ssh >/dev/null 2>&1; then
  echo "  엣지 $NAMESPACE/backup-ssh 있음, 건너뜀"
else
  log "엣지 $NAMESPACE/backup-ssh 복사"
  kubectl "${EDGE[@]}" -n "${BACKUP_SECRET%%/*}" get secret "${BACKUP_SECRET##*/}" -o json \
    | jq --arg ns "$NAMESPACE" '.metadata = {"name": "backup-ssh", "namespace": $ns}' \
    | kubectl "${EDGE[@]}" apply -f -
fi

log "완료"
