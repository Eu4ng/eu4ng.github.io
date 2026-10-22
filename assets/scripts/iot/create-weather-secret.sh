#!/usr/bin/env bash
#
# 바깥 날씨 수집기가 쓰는 Secret(weather/weather-credentials)을 클러스터에 만듭니다. GitOps 저장소에는 비밀 값을 넣지 않으므로 폴더를 push 하기 전에 실행합니다.
# 수집기는 새 값을 MQTT 로 내고(Telegraf 가 DB 에 넣음), 빠진 분은 DB 에 직접 백필합니다. DB 는 하나이므로 PGPASSWORD_LOCAL·PGPASSWORD_HUB 에 같은 값을 넣습니다
# (수집기 환경 변수 DB_HUB 는 비워 둡니다. 지역 DB 를 따로 둘 때만 두 번째 DB 로 씁니다).
# kubectl 로 클러스터에 접근할 수 있는 곳(control plane)에서 실행합니다: bash create-weather-secret.sh
# 인증키는 환경 변수 KMA_AUTH_KEY 가 있으면 그것을, 없으면 실행 중에 입력받습니다(값을 표준입력으로 넘겨도 됩니다).
# DB 비밀번호는 timescaledb/timescaledb-credentials 에서, 브로커 비밀번호(계정 telegraf)는 telegraf/telegraf-credentials 에서 복사합니다.
# 이미 있으면 빠진 키(MQTT_PASSWORD)만 더합니다(값을 바꾸려면 Secret 을 지우고 다시 실행).

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
NAMESPACE=weather                  # iot/weather 폴더 이름 = 네임스페이스
DB_SECRET=timescaledb/timescaledb-credentials   # POSTGRES_PASSWORD 를 가진 Secret (<네임스페이스>/<이름>)
MQTT_SECRET=telegraf/telegraf-credentials       # MQTT_PASSWORD 를 가진 Secret (<네임스페이스>/<이름>)
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
log "사전 검사"
kubectl get nodes >/dev/null || die "kubectl 로 클러스터에 접근할 수 없습니다."
MQTT_PW=$(kubectl -n "${MQTT_SECRET%%/*}" get secret "${MQTT_SECRET##*/}" -o jsonpath='{.data.MQTT_PASSWORD}' | base64 -d) || true
[ -n "$MQTT_PW" ] || die "$MQTT_SECRET 에서 MQTT_PASSWORD 를 읽지 못했습니다(create-iot-secrets.sh 를 먼저 실행)."
if kubectl -n "$NAMESPACE" get secret weather-credentials >/dev/null 2>&1; then
  if [ -n "$(kubectl -n "$NAMESPACE" get secret weather-credentials -o jsonpath='{.data.MQTT_PASSWORD}')" ]; then
    echo "  $NAMESPACE/weather-credentials 있음, 건너뜀"
  else
    # 값이 명령 인자에 남지 않게 표준입력으로 patch 합니다
    printf '{"data":{"MQTT_PASSWORD":"%s"}}' "$(printf '%s' "$MQTT_PW" | base64 -w0)" \
      | kubectl -n "$NAMESPACE" patch secret weather-credentials --type merge --patch-file /dev/stdin >/dev/null
    echo "  $NAMESPACE/weather-credentials 에 MQTT_PASSWORD 추가"
  fi
  unset MQTT_PW; exit 0
fi
PG_PASSWORD=$(kubectl -n "${DB_SECRET%%/*}" get secret "${DB_SECRET##*/}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d) || true
[ -n "$PG_PASSWORD" ] || die "$DB_SECRET 에서 POSTGRES_PASSWORD 를 읽지 못했습니다(create-iot-secrets.sh 를 먼저 실행)."

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
log "$NAMESPACE/weather-credentials"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
printf 'KMA_AUTH_KEY=%s\nPGPASSWORD_LOCAL=%s\nPGPASSWORD_HUB=%s\nMQTT_PASSWORD=%s\n' "$KMA_AUTH_KEY" "$PG_PASSWORD" "$PG_PASSWORD" "$MQTT_PW" \
  | kubectl -n "$NAMESPACE" create secret generic weather-credentials --from-env-file=/dev/stdin

unset KMA_AUTH_KEY PG_PASSWORD MQTT_PW
log "완료"
