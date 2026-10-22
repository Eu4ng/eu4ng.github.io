#!/usr/bin/env bash
#
# 바깥 날씨 수집기가 쓰는 Secret(weather/weather-credentials)을 엣지 클러스터에 만듭니다. GitOps 저장소에는 비밀 값을 넣지 않으므로 폴더를 push 하기 전에 실행합니다.
# 수집기는 지역마다 엣지에서 돌며 새 값을 MQTT 로 내고(엣지 Telegraf 가 두 DB 에 넣음), 빠진 분은 지역 DB 와 허브 DB 에 직접 백필합니다.
# 허브에 kubectl 로 접근할 수 있고 엣지 kubeconfig 가 있는 곳(control plane)에서 실행합니다: bash create-weather-secret.sh [EDGE_KUBECONFIG]
# 인증키는 환경 변수 KMA_AUTH_KEY 가 있으면 그것을, 없으면 실행 중에 입력받습니다(값을 표준입력으로 넘겨도 됩니다).
# DB 비밀번호는 허브·지역의 timescaledb/timescaledb-credentials 에서, 브로커 비밀번호(계정 telegraf)는 엣지 telegraf/telegraf-credentials 에서 복사합니다.
# 이미 있으면 빠진 키(MQTT_PASSWORD)만 더합니다(값을 바꾸려면 Secret 을 지우고 다시 실행).

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
NAMESPACE=weather                  # iot/clusters/<지역>/weather 폴더 이름 = 네임스페이스
DB_SECRET=timescaledb/timescaledb-credentials   # POSTGRES_PASSWORD 를 가진 Secret (<네임스페이스>/<이름>, 허브·지역 같은 이름)
MQTT_SECRET=telegraf/telegraf-credentials       # MQTT_PASSWORD 를 가진 엣지 Secret (<네임스페이스>/<이름>)
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
log "사전 검사"
EDGE_KUBECONFIG=${1:-}
[ -r "$EDGE_KUBECONFIG" ] || die "사용법: bash create-weather-secret.sh [EDGE_KUBECONFIG]"
EDGE=(--kubeconfig "$EDGE_KUBECONFIG")
kubectl get nodes >/dev/null || die "kubectl 로 허브 클러스터에 접근할 수 없습니다."
kubectl "${EDGE[@]}" get nodes >/dev/null || die "엣지 kubeconfig 로 엣지 클러스터에 접근할 수 없습니다."
MQTT_PW=$(kubectl "${EDGE[@]}" -n "${MQTT_SECRET%%/*}" get secret "${MQTT_SECRET##*/}" -o jsonpath='{.data.MQTT_PASSWORD}' | base64 -d) || true
[ -n "$MQTT_PW" ] || die "엣지 $MQTT_SECRET 에서 MQTT_PASSWORD 를 읽지 못했습니다(create-iot-secrets.sh 를 먼저 실행)."
if kubectl "${EDGE[@]}" -n "$NAMESPACE" get secret weather-credentials >/dev/null 2>&1; then
  if [ -n "$(kubectl "${EDGE[@]}" -n "$NAMESPACE" get secret weather-credentials -o jsonpath='{.data.MQTT_PASSWORD}')" ]; then
    echo "  엣지 $NAMESPACE/weather-credentials 있음, 건너뜀"
  else
    # 값이 명령 인자에 남지 않게 표준입력으로 patch 합니다
    printf '{"data":{"MQTT_PASSWORD":"%s"}}' "$(printf '%s' "$MQTT_PW" | base64 -w0)" \
      | kubectl "${EDGE[@]}" -n "$NAMESPACE" patch secret weather-credentials --type merge --patch-file /dev/stdin >/dev/null
    echo "  엣지 $NAMESPACE/weather-credentials 에 MQTT_PASSWORD 추가"
  fi
  unset MQTT_PW; exit 0
fi
db_password() { kubectl "$@" -n "${DB_SECRET%%/*}" get secret "${DB_SECRET##*/}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; }
PG_HUB=$(db_password) || true; PG_LOCAL=$(db_password "${EDGE[@]}") || true
[ -n "$PG_HUB" ] || die "허브 $DB_SECRET 에서 POSTGRES_PASSWORD 를 읽지 못했습니다."
[ -n "$PG_LOCAL" ] || die "엣지 $DB_SECRET 에서 POSTGRES_PASSWORD 를 읽지 못했습니다(create-iot-secrets.sh 를 먼저 실행)."

# ---------- 2. 인증키 ----------
KMA_AUTH_KEY=${KMA_AUTH_KEY:-}
if [ -n "$KMA_AUTH_KEY" ]; then echo "  인증키: 환경 변수 KMA_AUTH_KEY"; else
  log "기상청 API허브 인증키 입력 (화면에 표시되지 않음)"
  read -rsp "authKey: " KMA_AUTH_KEY; echo
  [ -n "$KMA_AUTH_KEY" ] || die "인증키가 비어 있습니다."
fi
# 인증키와 매분자료 활용신청이 유효한지 한 분만 받아 봅니다
curl -fsS -m 60 "https://apihub.kma.go.kr/api/typ01/cgi-bin/url/nph-aws2_min?stn=133&disp=1&help=0&authKey=$KMA_AUTH_KEY" \
  | head -1 | grep -q '^#START7777' || die "API 응답이 올바르지 않습니다. 인증키와 '지상관측 > AWS 매분자료' 활용신청을 확인하세요."

# ---------- 3. Secret 만들기 ----------
log "엣지 $NAMESPACE/weather-credentials"
kubectl "${EDGE[@]}" create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl "${EDGE[@]}" apply -f - >/dev/null
printf 'KMA_AUTH_KEY=%s\nPGPASSWORD_LOCAL=%s\nPGPASSWORD_HUB=%s\nMQTT_PASSWORD=%s\n' "$KMA_AUTH_KEY" "$PG_LOCAL" "$PG_HUB" "$MQTT_PW" \
  | kubectl "${EDGE[@]}" -n "$NAMESPACE" create secret generic weather-credentials --from-env-file=/dev/stdin

unset KMA_AUTH_KEY PG_HUB PG_LOCAL MQTT_PW
log "완료"
