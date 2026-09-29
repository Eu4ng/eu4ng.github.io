#!/usr/bin/env bash
#
# NVR(go2rtc, recorder, occupancy 수집기, 일일 작업, 사후 검수)이 쓰는 Secret(nvr/nvr-credentials, nvr/backup-ssh, nvr/nvr-db)을 엣지 클러스터에 만듭니다.
# GitOps 저장소에는 비밀 값을 넣지 않으므로 매니페스트를 push 하기 전에 실행합니다.
# 허브에 kubectl 로 접근할 수 있고 엣지 kubeconfig 가 있는 곳(control plane)에서 실행합니다: bash create-nvr-secrets.sh [EDGE_KUBECONFIG]
# 카메라 RTSP 비밀번호는 환경 변수 CAMERA_RTSP_PASSWORD 가 있으면 그것을, 없으면 실행 중에 입력받습니다.
# MQTT 비밀번호는 환경 변수 MQTT_PASSWORD 가 있으면 그것을, 없으면 엣지 telegraf-credentials 에서 가져옵니다.
# 수집기는 DB 에 직접 쓰지 않습니다(MQTT → Telegraf → readings). 사후 검수는 실시간 재실자 수와 비교하려 DB 를 읽기만 하므로
# 엣지 timescaledb-credentials 의 읽기 전용 계정(grafana) 비밀번호를 nvr/nvr-db 로 복사합니다.
# NAS 이관(SFTP)용 SSH 키(backup-ssh)는 엣지 backup 네임스페이스에서 복사합니다.

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
NAMESPACE=nvr
TELEGRAF_SECRET=telegraf/telegraf-credentials
BACKUP_SECRET=backup/backup-ssh
DB_SECRET=timescaledb/timescaledb-credentials
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
  printf 'RTSP_PASSWORD=%s\nMQTT_PASSWORD=%s\n' "$CAMERA_RTSP_PASSWORD" "$MQTT_PASSWORD" \
    | kubectl "${EDGE[@]}" -n "$NAMESPACE" create secret generic nvr-credentials --from-env-file=/dev/stdin
  unset CAMERA_RTSP_PASSWORD MQTT_PASSWORD
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

# ---------- 4. nvr-db (사후 검수의 DB 읽기) ----------
if kubectl "${EDGE[@]}" -n "$NAMESPACE" get secret nvr-db >/dev/null 2>&1; then
  echo "  엣지 $NAMESPACE/nvr-db 있음, 건너뜀"
else
  log "엣지 $NAMESPACE/nvr-db 생성 (읽기 전용 계정 grafana)"
  PGPASSWORD=$(kubectl "${EDGE[@]}" -n "${DB_SECRET%%/*}" get secret "${DB_SECRET##*/}" -o jsonpath='{.data.GRAFANA_PASSWORD}' | base64 -d)
  [ -n "$PGPASSWORD" ] || die "엣지 ${DB_SECRET} 에서 GRAFANA_PASSWORD 를 찾지 못했습니다."
  printf 'PGPASSWORD=%s\n' "$PGPASSWORD" \
    | kubectl "${EDGE[@]}" -n "$NAMESPACE" create secret generic nvr-db --from-env-file=/dev/stdin
  unset PGPASSWORD
fi

log "완료"
