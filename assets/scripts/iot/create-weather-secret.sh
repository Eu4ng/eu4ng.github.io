#!/usr/bin/env bash
#
# 바깥 날씨 수집기가 쓰는 Secret(weather/weather-credentials)을 허브 클러스터에 만듭니다. GitOps 저장소에는 비밀 값을 넣지 않으므로 폴더를 push 하기 전에 실행합니다.
# 허브에 kubectl 로 접근할 수 있는 곳(control plane)에서 실행합니다: bash create-weather-secret.sh
# 인증키는 실행 중에 입력받고, DB 비밀번호는 timescaledb/timescaledb-credentials 에서 복사합니다. 이미 있으면 건너뜁니다(바꾸려면 Secret 을 지우고 다시 실행).

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
NAMESPACE=weather                  # iot/hub/weather 폴더 이름 = 네임스페이스
DB_SECRET=timescaledb/timescaledb-credentials   # POSTGRES_PASSWORD 를 가진 Secret (<네임스페이스>/<이름>)
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
log "사전 검사"
kubectl get nodes >/dev/null || die "kubectl 로 허브 클러스터에 접근할 수 없습니다."
if kubectl -n "$NAMESPACE" get secret weather-credentials >/dev/null 2>&1; then
  echo "  $NAMESPACE/weather-credentials 있음, 건너뜀"; exit 0
fi
PG_PASSWORD=$(kubectl -n "${DB_SECRET%%/*}" get secret "${DB_SECRET##*/}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
[ -n "$PG_PASSWORD" ] || die "$DB_SECRET 에서 POSTGRES_PASSWORD 를 읽지 못했습니다."

# ---------- 2. 인증키 입력 ----------
log "기상청 API허브 인증키 입력 (화면에 표시되지 않음)"
read -rsp "authKey: " KMA_AUTH_KEY; echo
[ -n "$KMA_AUTH_KEY" ] || die "인증키가 비어 있습니다."
# 인증키와 매분자료 활용신청이 유효한지 한 분만 받아 봅니다
curl -fsS -m 60 "https://apihub.kma.go.kr/api/typ01/cgi-bin/url/nph-aws2_min?stn=133&disp=1&help=0&authKey=$KMA_AUTH_KEY" \
  | head -1 | grep -q '^#START7777' || die "API 응답이 올바르지 않습니다. 인증키와 '지상관측 > AWS 매분자료' 활용신청을 확인하세요."

# ---------- 3. Secret 만들기 ----------
log "$NAMESPACE/weather-credentials"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NAMESPACE" create secret generic weather-credentials \
  --from-literal=KMA_AUTH_KEY="$KMA_AUTH_KEY" --from-literal=PGPASSWORD="$PG_PASSWORD"

unset KMA_AUTH_KEY PG_PASSWORD
log "완료"
