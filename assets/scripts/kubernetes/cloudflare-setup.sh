#!/usr/bin/env bash
#
# 외부 노출에 필요한 Cloudflare 쪽 설정을 API 로 합니다. 여러 번 실행해도 결과가 같습니다.
#   1. 존(도메인) 추가 → 등록기관에 넣을 네임서버 출력
#   2. SSL 모드 Full (strict), 최소 TLS 1.2
#   3. 클러스터용 토큰(DNS 편집만 가능) 발급 → cert-manager·cloudflare-ddns 네임스페이스에 Secret 생성
#
# 사용법: bash cloudflare-setup.sh [DOMAIN]
# 준비:   설정용 API 토큰(사용자 소유·계정 소유 어느 쪽이든)을 실행 중 입력합니다.
#         권한: Account/Account API Tokens/Edit, Zone/Zone/Edit, Zone/Zone Settings/Edit, Zone/Zone/Read,
#         Zone Resources 는 "All zones from an account". 이 토큰은 저장소·클러스터 어디에도 넣지 않습니다.
# 필요:   curl, python3, ssh(컨트롤플레인 kubectl)

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
CONTROL_PLANE=ubuntu@[CONTROL_PLANE_IP]  # kubectl 을 실행할 곳
SECRET_NAMESPACES="cert-manager cloudflare-ddns"
RUNTIME_TOKEN_NAME=k8s-gitops-dns        # 클러스터에 들어갈 토큰 이름 (Cloudflare 대시보드에서 보입니다)
# --------------------------------------

API=https://api.cloudflare.com/client/v4

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
DOMAIN=${1:-}
[[ "$DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]+$ ]] || die "사용법: bash cloudflare-setup.sh [DOMAIN]"
for cmd in curl python3 ssh; do command -v "$cmd" >/dev/null || die "$cmd 가 필요합니다."; done
read -rs -p "Cloudflare 설정용 API 토큰: " CLOUDFLARE_API_TOKEN; echo
[ -n "$CLOUDFLARE_API_TOKEN" ] || die "토큰이 비어 있습니다."

# cf METHOD PATH [JSON]  → 응답 JSON 을 표준출력으로. success=false 면 오류 메시지를 보이고 실패합니다.
# 호출 결과는 반드시 `resp=$(cf …)` 처럼 단독 할당으로 받습니다. 그래야 set -e 가 실패를 잡습니다.
cf() {
  local method=$1 path=$2 body=${3:-} out
  if [ -n "$body" ]; then
    out=$(curl -sS -X "$method" "$API$path" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
          -H "Content-Type: application/json" --data "$body")
  else
    out=$(curl -sS -X "$method" "$API$path" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")
  fi
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    r = json.loads(raw)
except ValueError:
    sys.exit("응답이 JSON 이 아닙니다: " + raw[:200])
if not r.get("success"):
    sys.exit("API 오류 %s %s: %s" % (sys.argv[1], sys.argv[2], "; ".join("%s %s" % (e.get("code"), e.get("message")) for e in r.get("errors", []))))
print(raw)' "$method" "$path" <<<"$out"
}

# jget JSON 파이썬식 → 예: jget "$zone" 'r["result"]["id"]'
jget() { python3 -c 'import json, sys; r = json.loads(sys.argv[1]); v = eval(sys.argv[2]); print(v if isinstance(v, str) else json.dumps(v, ensure_ascii=False))' "$1" "$2"; }

# ---------- 2. 토큰 검증 ----------
log "설정용 토큰 검증"
resp=$(cf GET '/accounts?per_page=1')
account_id=$(jget "$resp" 'r["result"][0]["id"]')
# 계정 소유 토큰(cfat_…)과 사용자 소유 토큰은 검증 주소가 다릅니다.
if [[ "$CLOUDFLARE_API_TOKEN" == cfat_* ]]; then
  resp=$(cf GET "/accounts/$account_id/tokens/verify")
else
  resp=$(cf GET /user/tokens/verify)
fi
status=$(jget "$resp" 'r["result"]["status"]')
[ "$status" = active ] || die "토큰 상태가 $status 입니다."
echo "계정: $account_id"

# ---------- 3. 존 ----------
log "존 $DOMAIN"
zones=$(cf GET "/zones?name=$DOMAIN")
if [ "$(jget "$zones" 'len(r["result"])')" = 0 ]; then
  echo "존이 없어 추가합니다."
  resp=$(cf POST /zones "{\"name\":\"$DOMAIN\",\"account\":{\"id\":\"$account_id\"},\"type\":\"full\"}")
  zone=$(jget "$resp" 'r["result"]')
else
  echo "존이 이미 있습니다."
  zone=$(jget "$zones" 'r["result"][0]')
fi
zone_id=$(jget "$zone" 'r["id"]')
zone_status=$(jget "$zone" 'r["status"]')
name_servers=$(jget "$zone" '" ".join(r["name_servers"])')
echo "존 ID: $zone_id, 상태: $zone_status"

# ---------- 4. 존 설정 ----------
log "SSL 모드 Full (strict), 최소 TLS 1.2"
cf PATCH "/zones/$zone_id/settings/ssl" '{"value":"strict"}' >/dev/null
cf PATCH "/zones/$zone_id/settings/min_tls_version" '{"value":"1.2"}' >/dev/null
echo "적용했습니다. (HTTP→HTTPS 리다이렉트는 Traefik 이 하므로 Always Use HTTPS 는 켜지 않습니다)"

# ---------- 5. 클러스터용 토큰 ----------
# DNS 편집과 존 읽기만 되는 계정 소유 토큰(cfat_…)을 이 존에 한해 만듭니다. 사용자 소유 토큰을 만드는 데 필요한
# User/API Tokens/Edit 권한은 Custom 토큰 빌더에 없기 때문입니다. 값은 생성 때만 볼 수 있으므로,
# 클러스터에 Secret 이 이미 다 있으면 건너뛰고, 하나라도 없으면 같은 이름의 옛 토큰을 지우고 새로 만듭니다.
log "클러스터용 토큰 $RUNTIME_TOKEN_NAME"
missing=$(ssh "$CONTROL_PLANE" "for ns in $SECRET_NAMESPACES; do kubectl -n \$ns get secret cloudflare-api-token >/dev/null 2>&1 || echo \$ns; done")
resp=$(cf GET "/accounts/$account_id/tokens?per_page=50")
existing_ids=$(jget "$resp" "\" \".join(t[\"id\"] for t in r[\"result\"] if t[\"name\"] == \"$RUNTIME_TOKEN_NAME\")")
if [ -z "$missing" ] && [ -n "$existing_ids" ]; then
  echo "토큰과 Secret 이 모두 있어 건너뜁니다."
else
  for id in $existing_ids; do
    echo "옛 토큰 $id 삭제"
    cf DELETE "/accounts/$account_id/tokens/$id" >/dev/null
  done
  groups=$(cf GET "/accounts/$account_id/tokens/permission_groups")
  dns_write=$(jget "$groups" '[g["id"] for g in r["result"] if g["name"] == "DNS Write"][0]')
  zone_read=$(jget "$groups" '[g["id"] for g in r["result"] if g["name"] == "Zone Read"][0]')
  resp=$(cf POST "/accounts/$account_id/tokens" "{
    \"name\": \"$RUNTIME_TOKEN_NAME\",
    \"policies\": [{
      \"effect\": \"allow\",
      \"resources\": {\"com.cloudflare.api.account.zone.$zone_id\": \"*\"},
      \"permission_groups\": [{\"id\": \"$dns_write\"}, {\"id\": \"$zone_read\"}]
    }]
  }")
  runtime_token=$(jget "$resp" 'r["result"]["value"]')
  echo "발급했습니다."

  # ---------- 6. 클러스터 Secret ----------
  # 토큰은 표준입력으로 넘겨 명령줄·셸 히스토리에 남기지 않습니다.
  log "클러스터 Secret 생성 ($SECRET_NAMESPACES)"
  for ns in $SECRET_NAMESPACES; do
    printf '%s' "$runtime_token" | ssh "$CONTROL_PLANE" "
      kubectl get ns $ns >/dev/null 2>&1 || kubectl create ns $ns >/dev/null
      kubectl -n $ns create secret generic cloudflare-api-token --from-file=token=/dev/stdin --dry-run=client -o yaml \
        | kubectl apply -f -"
  done
fi

# ---------- 7. 요약 ----------
log "완료"
if [ "$zone_status" = active ]; then
  echo "존이 활성 상태입니다. 네임서버는 이미 Cloudflare 를 가리킵니다."
else
  echo "존 상태가 '$zone_status' 입니다. 등록기관에서 네임서버를 아래 둘로 바꾸세요 (전파까지 수 분~수 시간):"
  for ns in $name_servers; do echo "  $ns"; done
fi
