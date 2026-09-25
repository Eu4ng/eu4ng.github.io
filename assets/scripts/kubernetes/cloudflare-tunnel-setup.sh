#!/usr/bin/env bash
#
# 공인 IP 나 포트포워딩 없이 SSH 를 Cloudflare 를 거쳐 열도록 Cloudflare Tunnel 과 Access 를 API 로 만듭니다. 여러 번 실행해도 결과가 같습니다.
#   1. 터널 두 개: nas(원격 NAS 에서 실행), homelab(허브 클러스터에서 실행)
#   2. 터널 경로: [이름].[DOMAIN] → ssh://[LAN 주소]:22
#   3. DNS: 이름마다 CNAME → [터널 ID].cfargotunnel.com (프록시)
#   4. Access: 이름마다 앱 하나. 사람은 이메일 확인(Allow), 백업 자동화는 서비스 토큰(Service Auth, NAS 만)
#   5. 토큰: 허브 터널 토큰과 백업 서비스 토큰은 허브에 Secret 으로 바로 넣고, NAS 터널 토큰은 파일(NAS_TOKEN_FILE)에 저장합니다.
#
# 사용법: bash cloudflare-tunnel-setup.sh [DOMAIN] [EMAIL]
# 준비:   설정용 API 토큰(~/.config/cloudflare/token 파일, 없으면 실행 중 입력). 권한은 정책 두 개로 나눠 넣습니다.
#           계정 정책: Access: Apps Write, Access: Policies Write, Access: Service Tokens Write, Cloudflare One Connector: cloudflared Write
#           존 정책:   DNS Write, Zone Read
#         이 토큰은 저장소·클러스터 어디에도 넣지 않습니다.
# 필요:   curl, python3, ssh(컨트롤플레인 kubectl)

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
CONTROL_PLANE=ubuntu@[CONTROL_PLANE_IP]  # kubectl 을 실행할 곳 (허브)
# 터널별 SSH 대상: "이름=주소" (이름.[DOMAIN] 으로 열림). nas 터널은 NAS 안의 cloudflared 가 자기 자신(localhost)으로 붙습니다.
NAS_ROUTES="nas-ssh=localhost"
HOMELAB_ROUTES="ssh-proxmox=[PROXMOX_IP] ssh-cp=[CONTROL_PLANE_IP] ssh-edge=[EDGE_IP]"
SERVICE_TOKEN_NAME=homelab-backup        # 백업 CronJob 이 NAS 에 붙을 때 쓰는 서비스 토큰
SESSION=24h                              # 사람 로그인 유지 시간
NAS_TOKEN_FILE=$HOME/.config/portainer/secrets/cloudflared_nas_token   # NAS 터널 토큰을 저장할 곳 (portainer-stack.sh 가 Swarm secret 으로 만듦)
# --------------------------------------

API=https://api.cloudflare.com/client/v4
log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
DOMAIN=${1:-}; EMAIL=${2:-}
[[ "$DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]+$ && "$EMAIL" == *@* ]] || die "사용법: bash cloudflare-tunnel-setup.sh [DOMAIN] [EMAIL]"
for cmd in curl python3 ssh; do command -v "$cmd" >/dev/null || die "$cmd 가 필요합니다."; done
# cloudflare-setup.sh 와 같은 파일에 저장해 두었으면 그 값을 씁니다. 없으면 입력받습니다.
if [ -r "$HOME/.config/cloudflare/token" ]; then
  CLOUDFLARE_API_TOKEN=$(cat "$HOME/.config/cloudflare/token")
else
  read -rs -p "Cloudflare 설정용 API 토큰: " CLOUDFLARE_API_TOKEN; echo
fi
[ -n "$CLOUDFLARE_API_TOKEN" ] || die "토큰이 비어 있습니다."

# cf METHOD PATH [JSON] → 응답 JSON. success=false 면 실패합니다. 결과는 `resp=$(cf …)` 처럼 단독 할당으로 받습니다.
cf() {
  local method=$1 path=$2 body=${3:-} out
  if [ -n "$body" ]; then
    out=$(curl -sS -X "$method" "$API$path" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" --data "$body")
  else
    out=$(curl -sS -X "$method" "$API$path" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")
  fi
  python3 -c '
import json, sys
raw = sys.stdin.read()
try: r = json.loads(raw)
except ValueError: sys.exit("응답이 JSON 이 아닙니다: " + raw[:200])
if not r.get("success"):
    sys.exit("API 오류 %s %s: %s" % (sys.argv[1], sys.argv[2], "; ".join("%s %s" % (e.get("code"), e.get("message")) for e in r.get("errors", []))))
print(raw)' "$method" "$path" <<<"$out"
}
jget() { python3 -c 'import json, sys; r = json.loads(sys.argv[1]); v = eval(sys.argv[2]); print(v if isinstance(v, str) else json.dumps(v, ensure_ascii=False))' "$1" "$2"; }

resp=$(cf GET '/accounts?per_page=1');     account_id=$(jget "$resp" 'r["result"][0]["id"]')
resp=$(cf GET "/zones?name=$DOMAIN");      zone_id=$(jget "$resp" 'r["result"][0]["id"]')
echo "계정: $account_id, 존: $zone_id"

# 권한 점검: 읽기 호출이 하나라도 거부되면 아무것도 만들지 않고 멈춥니다.
log "토큰 권한 점검"
for check in "cfd_tunnel?per_page=1|Cloudflare One Connector: cloudflared Write" \
             "access/service_tokens?per_page=1|Access: Service Tokens Write" \
             "access/apps?per_page=1|Access: Apps Write" \
             "access/policies?per_page=1|Access: Policies Write"; do
  ( cf GET "/accounts/$account_id/${check%%|*}" >/dev/null ) 2>/dev/null || die "토큰에 권한이 없습니다: ${check#*|}"
done
( cf GET "/zones/$zone_id/dns_records?per_page=1" >/dev/null ) 2>/dev/null || die "토큰에 권한이 없습니다: DNS Write (존 정책)"
echo "통과"

# ---------- 2. 서비스 토큰 ----------
# Client Secret 은 만들 때만 볼 수 있으므로, 허브에 Secret 이 이미 있으면 건너뛰고 없으면 옛 토큰을 지우고 새로 만듭니다.
log "서비스 토큰 $SERVICE_TOKEN_NAME"
resp=$(cf GET "/accounts/$account_id/access/service_tokens?per_page=100")
st_ids=$(jget "$resp" "\" \".join(t[\"id\"] for t in r[\"result\"] if t[\"name\"] == \"$SERVICE_TOKEN_NAME\")")
if ssh "$CONTROL_PLANE" 'kubectl -n backup get secret cloudflare-access >/dev/null 2>&1' && [ -n "$st_ids" ]; then
  st_id=${st_ids%% *}; echo "있음, 건너뜀"
else
  for id in $st_ids; do cf DELETE "/accounts/$account_id/access/service_tokens/$id" >/dev/null; done
  resp=$(cf POST "/accounts/$account_id/access/service_tokens" "{\"name\":\"$SERVICE_TOKEN_NAME\",\"duration\":\"forever\"}")
  st_id=$(jget "$resp" 'r["result"]["id"]')
  st_client_id=$(jget "$resp" 'r["result"]["client_id"]'); st_client_secret=$(jget "$resp" 'r["result"]["client_secret"]')
  printf '%s\n%s\n' "$st_client_id" "$st_client_secret" | ssh "$CONTROL_PLANE" '
    read -r id; read -r secret
    kubectl get ns backup >/dev/null 2>&1 || kubectl create ns backup >/dev/null
    kubectl -n backup create secret generic cloudflare-access --from-literal=CF_ACCESS_CLIENT_ID="$id" \
      --from-literal=CF_ACCESS_CLIENT_SECRET="$secret" --dry-run=client -o yaml | kubectl apply -f -'
  echo "만들고 허브 backup/cloudflare-access 에 넣었습니다."
fi

# ---------- 3. Access 정책 (재사용) ----------
# policy NAME DECISION INCLUDE_JSON → 정책 ID (이름이 같으면 갱신)
policy() {
  local resp id body="{\"name\":\"$1\",\"decision\":\"$2\",\"include\":$3,\"session_duration\":\"$SESSION\"}"
  resp=$(cf GET "/accounts/$account_id/access/policies?per_page=100")
  id=$(jget "$resp" "next((p[\"id\"] for p in r[\"result\"] if p[\"name\"] == \"$1\"), \"\")")
  if [ -n "$id" ]; then resp=$(cf PUT "/accounts/$account_id/access/policies/$id" "$body")
  else resp=$(cf POST "/accounts/$account_id/access/policies" "$body"); fi
  jget "$resp" 'r["result"]["id"]'
}
log "Access 정책"
pol_human=$(policy "homelab-ssh-owner" allow "[{\"email\":{\"email\":\"$EMAIL\"}}]")
pol_service=$(policy "homelab-ssh-backup" non_identity "[{\"service_token\":{\"token_id\":\"$st_id\"}}]")
echo "사람: $pol_human, 서비스: $pol_service"

# ---------- 4. 터널·경로·DNS·Access 앱 ----------
# tunnel NAME ROUTES WITH_SERVICE → 터널 토큰을 표준출력으로
tunnel() {
  local name=$1 routes=$2 with_service=$3 resp tid ingress="" host target rec
  resp=$(cf GET "/accounts/$account_id/cfd_tunnel?name=$name&is_deleted=false")
  tid=$(jget "$resp" 'r["result"][0]["id"] if r["result"] else ""')
  if [ -z "$tid" ]; then
    resp=$(cf POST "/accounts/$account_id/cfd_tunnel" "{\"name\":\"$name\",\"config_src\":\"cloudflare\"}")
    tid=$(jget "$resp" 'r["result"]["id"]')
  fi
  for route in $routes; do
    host="${route%%=*}.$DOMAIN"; target="${route#*=}"
    ingress+="{\"hostname\":\"$host\",\"service\":\"ssh://$target:22\"},"
    # DNS: CNAME → 터널 (프록시)
    resp=$(cf GET "/zones/$zone_id/dns_records?name=$host")
    rec=$(jget "$resp" 'r["result"][0]["id"] if r["result"] else ""')
    body="{\"type\":\"CNAME\",\"name\":\"$host\",\"content\":\"$tid.cfargotunnel.com\",\"proxied\":true}"
    if [ -n "$rec" ]; then cf PUT "/zones/$zone_id/dns_records/$rec" "$body" >/dev/null; else cf POST "/zones/$zone_id/dns_records" "$body" >/dev/null; fi
    # Access 앱
    local pols="[{\"id\":\"$pol_human\",\"precedence\":1}"
    [ "$with_service" = yes ] && pols+=",{\"id\":\"$pol_service\",\"precedence\":2}"
    pols+="]"
    body="{\"name\":\"$host\",\"domain\":\"$host\",\"type\":\"self_hosted\",\"session_duration\":\"$SESSION\",\"policies\":$pols}"
    resp=$(cf GET "/accounts/$account_id/access/apps?domain=$host")
    rec=$(jget "$resp" "next((a[\"id\"] for a in r[\"result\"] if a.get(\"domain\") == \"$host\"), \"\")")
    if [ -n "$rec" ]; then cf PUT "/accounts/$account_id/access/apps/$rec" "$body" >/dev/null; else cf POST "/accounts/$account_id/access/apps" "$body" >/dev/null; fi
    echo "  $host → ssh://$target:22" >&2
  done
  cf PUT "/accounts/$account_id/cfd_tunnel/$tid/configurations" "{\"config\":{\"ingress\":[${ingress}{\"service\":\"http_status:404\"}]}}" >/dev/null
  resp=$(cf GET "/accounts/$account_id/cfd_tunnel/$tid/token")
  jget "$resp" 'r["result"]'
}

log "터널 homelab (허브 클러스터에서 실행)"
homelab_token=$(tunnel homelab "$HOMELAB_ROUTES" no)
printf '%s' "$homelab_token" | ssh "$CONTROL_PLANE" '
  kubectl get ns cloudflared >/dev/null 2>&1 || kubectl create ns cloudflared >/dev/null
  kubectl -n cloudflared create secret generic cloudflared-token --from-file=TUNNEL_TOKEN=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -'

log "터널 nas (원격 NAS 에서 실행)"
nas_token=$(tunnel nas "$NAS_ROUTES" yes)

(umask 077; mkdir -p "$(dirname "$NAS_TOKEN_FILE")"; printf '%s' "$nas_token" > "$NAS_TOKEN_FILE")
echo "터널 토큰을 $NAS_TOKEN_FILE 에 저장했습니다."

log "완료"
