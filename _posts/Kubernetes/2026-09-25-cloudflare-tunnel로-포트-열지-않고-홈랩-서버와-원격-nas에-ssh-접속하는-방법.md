---
layout: post
title: Cloudflare Tunnel로 포트 열지 않고 홈랩 서버와 원격 NAS에 SSH 접속하는 방법
description: 공유기와 NAS 의 포트를 열지 않고 Cloudflare Tunnel 과 Access 로 홈랩 서버와 원격 Synology NAS 에 SSH 로 접속하도록, 터널과 Access 설정은 API 스크립트로, 커넥터는 쿠버네티스와 Portainer Swarm 스택으로 배포하는 방법을 정리했습니다.
author: Eu4ng
tags: [cloudflare, cloudflare-tunnel, ssh, kubernetes, argo-cd, gitops, synology, portainer, docker-swarm]
permalink: /posts/51/
---

**Cloudflare Tunnel** 은 서버 쪽 커넥터(cloudflared)가 Cloudflare 로 바깥 방향 연결을 맺고, 그 연결로 들어온 요청을 LAN 의 서비스로 넘깁니다. 공유기 포트포워딩이나 공인 IP 가 필요 없습니다. 터널 앞에는 **Cloudflare Access** 를 두어, 사람은 이메일로 받은 일회용 PIN 으로 로그인하고 백업 같은 자동화는 서비스 토큰으로 통과하게 합니다. 터널은 두 개입니다. 집의 허브 클러스터에서 도는 `homelab` 터널은 Proxmox·control plane·엣지 노드의 SSH 를 열고, 원격지 NAS 에서 도는 `nas` 터널은 NAS 자신의 SSH 를 엽니다. 터널·DNS·Access 설정은 대시보드 대신 API 스크립트로 만듭니다.

1. 설정용 API 토큰 만들기
2. 터널과 Access 설정 스크립트 실행
3. 허브 커넥터 배포
4. NAS 커넥터 배포
5. 클라이언트 설정과 첫 로그인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| 허브 Kubernetes | `v1.37` (kubeadm, Argo CD) |
| cloudflared | `2026.9.1` |
| NAS | Synology DSM 7, Portainer CE `2.39` (Docker Swarm) |
| 클라이언트 | Ubuntu 24.04 |
| 작성 기준일 | `2026-09-25` |

다음 항목이 준비되어 있어야 합니다.

- Cloudflare 에 등록한 도메인 ([쿠버네티스 서비스를 VPN 없이 외부에서 HTTPS로 접속하는 방법](/posts/40/))
- Argo CD 가 GitOps 저장소의 `services/` 폴더를 배포하는 허브 클러스터 ([쿠버네티스에 Argo CD 설치하고 GitOps로 서비스 추가하는 방법](/posts/36/))
- NAS 의 SSH 서비스(포트 22)와, Docker Swarm 환경을 관리하는 Portainer
- 스크립트를 실행할 곳의 `curl`, `python3`(PyYAML), control plane 으로의 `ssh`

## 1. 설정용 API 토큰 만들기

[외부 접속 글](/posts/40/)에서 만든 설정용 토큰(**Manage Account** > **Account API Tokens**)을 편집해 권한을 더합니다. 새로 만들어도 됩니다. 권한 정책은 리소스가 계정인 것과 존(도메인)인 것 두 개로 나눕니다. 계정 단위 권한을 존 정책에 넣으면 저장은 되지만 적용되지 않습니다.

| 정책 | 리소스 | 권한 |
| :--- | :--- | :--- |
| 계정 정책 | 내 계정 | `Access: Apps Write` |
| 계정 정책 | 내 계정 | `Access: Policies Write` |
| 계정 정책 | 내 계정 | `Access: Service Tokens Write` |
| 계정 정책 | 내 계정 | `Cloudflare One Connector: cloudflared Write` |
| 존 정책 | `[DOMAIN]` | `DNS Write` |
| 존 정책 | `[DOMAIN]` | `Zone Read` |

토큰 값은 스크립트를 실행할 곳의 파일에 둡니다. 파일이 없으면 스크립트가 실행 중 입력받습니다.

```bash
# 붙여 넣은 토큰은 화면에 보이지 않습니다
mkdir -p ~/.config/cloudflare
(umask 077; read -rsp "Cloudflare 설정용 토큰: " T; echo; printf '%s' "$T" > ~/.config/cloudflare/token)
```

- **확인:** `ls -l ~/.config/cloudflare/token` 의 권한이 `-rw-------` 이고 크기가 0 이 아닙니다.

## 2. 터널과 Access 설정 스크립트 실행

스크립트는 터널 두 개와 이름별 경로, 이름마다 터널을 가리키는 CNAME, 이름마다 Access 애플리케이션을 만듭니다. Access 정책은 두 가지입니다. 사람용 정책은 지정한 이메일만 허용하고, 서비스 토큰 정책은 백업 자동화를 위해 `nas-ssh` 에만 붙습니다. 허브 터널 토큰과 백업 서비스 토큰은 허브 Secret 으로 바로 넣고, NAS 터널 토큰은 4단계에서 쓸 파일에 저장합니다. 여러 번 실행해도 결과가 같습니다.

```bash
# 스크립트 내려받기. 맨 앞 변수 블록의 주소를 환경에 맞게 고칩니다
wget https://eu4ng.github.io/assets/scripts/kubernetes/cloudflare-tunnel-setup.sh
bash cloudflare-tunnel-setup.sh [DOMAIN] [EMAIL]
```

<details markdown="1">
<summary>cloudflare-tunnel-setup.sh 전문</summary>

```bash
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
```
{: file="cloudflare-tunnel-setup.sh" }

</details>

- **확인:** 출력에 `토큰 권한 점검` 의 `통과`, 이름별 경로(`ssh-cp.[DOMAIN] → ssh://[CONTROL_PLANE_IP]:22` 등), `터널 토큰을 … 에 저장했습니다` 가 보입니다. 두 번째 실행부터는 서비스 토큰이 `있음, 건너뜀` 이고 허브 Secret 이 `unchanged` 입니다.

## 3. 허브 커넥터 배포

허브 클러스터에서 `homelab` 터널의 커넥터를 돌립니다. 파드를 둘 두면 한쪽 노드가 내려가도 터널이 유지됩니다. 토큰은 환경 변수로 넣지 않고 Secret 을 파일로 마운트해 `TUNNEL_TOKEN_FILE` 로 읽게 합니다. 그래야 파드 정의나 `kubectl describe` 에 토큰이 드러나지 않습니다.

```yaml
# Cloudflare Tunnel "homelab". 공인 IP·포트포워딩 없이 LAN 호스트의 SSH 를 ssh-*.[DOMAIN] 으로 엽니다(앞단은 Cloudflare Access).
# 터널·경로·DNS·Access 는 cloudflare-tunnel-setup.sh 가 API 로 만들고(원격 관리형 터널), 여기서는 커넥터만 돌립니다.
# 터널 토큰은 GitOps 밖에서 만듭니다 (같은 스크립트가 Secret cloudflared-token 을 생성).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
spec:
  replicas: 2                # 커넥터를 둘 두면 한쪽 파드·노드가 내려가도 터널이 유지됩니다
  selector:
    matchLabels: { app: cloudflared }
  template:
    metadata:
      labels: { app: cloudflared }
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:2026.9.1
          args: ["tunnel", "--no-autoupdate", "--metrics", "0.0.0.0:2000", "run"]
          env:
            - { name: TUNNEL_TOKEN_FILE, value: /etc/cloudflared/token }   # 토큰은 환경 변수가 아니라 Secret 파일로 읽습니다
          ports: [{ containerPort: 2000 }]
          volumeMounts:
            - { name: token, mountPath: /etc/cloudflared, readOnly: true }
          readinessProbe:
            httpGet: { path: /ready, port: 2000 }   # 엣지와 연결이 하나라도 있으면 200
            periodSeconds: 10
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits: { memory: 128Mi }
          securityContext:
            runAsNonRoot: true
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
      volumes:
        - name: token
          secret:
            secretName: cloudflared-token
            items: [{ key: TUNNEL_TOKEN, path: token }]
            defaultMode: 0444     # 이미지가 root 가 아닌 계정으로 돕니다
```
{: file="services/cloudflared/deployment.yaml" }

```bash
git add services/cloudflared
git commit -m "feat(cloudflared): SSH 용 Cloudflare Tunnel 커넥터 추가"
git push
```

- **확인:** `kubectl -n cloudflared get pods` 에 파드 두 개가 `Running`, `1/1` 이고, Cloudflare 대시보드의 터널 목록에서 `homelab` 이 `Healthy` 입니다.

## 4. NAS 커넥터 배포

NAS 에는 쿠버네티스가 없으므로 Portainer 의 **Git 저장소 스택**으로 커넥터를 돌립니다. Portainer 가 GitOps 저장소를 주기적으로 읽어 스택 파일이 바뀌면 다시 배포합니다. 커넥터가 NAS 의 `localhost:22` 로 붙어야 하는데 Swarm 은 `network_mode: host` 를 무시하므로, 호스트 네트워크(`host`)를 외부 네트워크로 붙입니다. 토큰은 Swarm secret 으로 넣습니다.

```yaml
# 원격지 NAS(Synology, Portainer Swarm)의 Cloudflare Tunnel "nas" 커넥터. 공인 IP·포트포워딩 없이 NAS 의 SSH 를
# nas-ssh.[DOMAIN] 으로 열어, 허브·엣지 클러스터의 백업(restic SFTP)이 Cloudflare Access 서비스 토큰으로 붙게 합니다.
# Portainer 의 Git 저장소 스택으로 배포합니다. 터널 토큰은 저장소·환경 변수에 두지 않고 Swarm secret 으로 넣습니다:
#   Portainer Secrets > Add secret, 이름 cloudflared_nas_token (값은 cloudflare-tunnel-setup.sh 가 출력한 nas 터널 토큰)
version: "3.8"
services:
  cloudflared:
    image: cloudflare/cloudflared:2026.9.1
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN_FILE=/run/secrets/cloudflared_nas_token   # 값이 아니라 파일 경로. 컨테이너 정보에 토큰이 드러나지 않습니다
    secrets:
      - cloudflared_nas_token
    networks:
      - hostnet               # Swarm 은 network_mode: host 를 무시하므로 호스트 네트워크에 붙여 NAS 의 localhost:22 로 갑니다
    deploy:
      replicas: 1
      restart_policy:
        condition: any

secrets:
  cloudflared_nas_token:
    external: true            # Portainer 에서 미리 만든 secret. 바꿀 때는 새 이름으로 만들고 이 파일의 이름을 바꿉니다

networks:
  hostnet:
    external: true
    name: host
```
{: file="stacks/[REGION]/cloudflared/stack.yml" }

GitOps 저장소가 비공개면 Portainer 가 저장소를 읽을 때 GitHub 토큰이 필요한데, Portainer CE 에는 Git 인증 정보를 저장해 두는 기능이 없습니다. 그래서 스택 등록을 API 스크립트로 합니다. 스크립트는 스택 파일의 external secret 을 값 파일에서 만들고, 스택이 없으면 등록하고 있으면 다시 배포합니다.

1. Portainer 의 **My account** > **Access tokens**에서 토큰을 만듭니다.
2. GitHub 에서 fine-grained 토큰을 만듭니다. 저장소는 GitOps 저장소 하나, 권한은 **Contents: Read-only** 만 줍니다.
3. 두 값을 스크립트가 읽는 파일에 넣습니다. NAS 터널 토큰 파일은 2단계에서 이미 만들어졌습니다.

```bash
# 붙여 넣은 값은 화면에 보이지 않습니다
mkdir -p ~/.config/portainer ~/.config/github
echo "https://portainer.[DOMAIN]" > ~/.config/portainer/url
(umask 077; read -rsp "Portainer 토큰: " T; echo; printf '%s' "$T" > ~/.config/portainer/api-key)
(umask 077; read -rsp "GitHub 토큰: " T; echo; printf '%s' "$T" > ~/.config/github/portainer-pat)

# GitOps 저장소 루트에서. 스택 파일을 먼저 push 해 둡니다(Portainer 는 원격 저장소의 파일을 씁니다)
git add stacks/[REGION]/cloudflared && git commit -m "feat(stacks): NAS Cloudflare Tunnel 커넥터 추가" && git push
bash scripts/portainer-stack.sh stacks/[REGION]/cloudflared/stack.yml
```

<details markdown="1">
<summary>scripts/portainer-stack.sh 전문</summary>

```bash
#!/usr/bin/env bash
#
# 이 저장소의 Swarm 스택 파일(stacks/<지역>/<이름>/stack.yml)을 Portainer 에 "Git 저장소 스택"으로 등록하거나 다시 배포합니다.
# Portainer Community Edition 은 Git 인증 정보를 저장해 두는 기능이 없어, 스택마다 폼에 토큰을 넣는 대신 이 스크립트가 API 로 등록합니다.
# 스택 파일이 external secret 을 쓰면 값 파일에서 Swarm secret 을 먼저 만듭니다(이미 있으면 건너뜀). 여러 번 실행해도 됩니다.
#
# 사용법: bash scripts/portainer-stack.sh <stack.yml 경로> [스택 이름]     (스택 이름 기본값: 폴더 이름)
# 준비(저장소 밖, 권한 600):
#   ~/.config/portainer/url         Portainer 주소 (예: https://portainer.[DOMAIN])
#   ~/.config/portainer/api-key     Portainer My account > Access tokens 에서 만든 토큰
#   ~/.config/github/portainer-pat  GitHub fine-grained 토큰 (이 저장소만, Contents: Read-only)
#   ~/.config/portainer/secrets/<이름>   external secret 의 값 (스택이 쓰는 것만)
# 필요: curl, python3(PyYAML)

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
REPO_URL=https://github.com/[OWNER]/[REPO]
REPO_REF=refs/heads/main
REPO_USER=[OWNER]
AUTO_UPDATE=5m                           # Portainer 가 저장소를 확인하는 주기 (GitOps updates)
ENDPOINT_NAME=                           # Portainer 환경 이름. 비우면 첫 Swarm 환경
# --------------------------------------

CONF=$HOME/.config
log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

STACK_FILE=${1:-}
[ -f "$STACK_FILE" ] || die "사용법: bash scripts/portainer-stack.sh <stack.yml 경로> [스택 이름]"
STACK_NAME=${2:-$(basename "$(dirname "$STACK_FILE")")}
for f in portainer/url portainer/api-key github/portainer-pat; do [ -s "$CONF/$f" ] || die "$CONF/$f 가 없습니다."; done
# 저장소 루트 기준 경로 (Portainer 가 저장소를 받아 이 경로의 파일을 씁니다)
REPO_ROOT=$(git -C "$(dirname "$STACK_FILE")" rev-parse --show-toplevel)
COMPOSE_PATH=$(realpath --relative-to="$REPO_ROOT" "$STACK_FILE")
git -C "$REPO_ROOT" diff --quiet "origin/main" -- "$COMPOSE_PATH" 2>/dev/null \
  || echo "주의: $COMPOSE_PATH 가 원격 main 과 다릅니다. Portainer 는 원격 저장소의 파일을 씁니다(먼저 push)."

export PORTAINER_URL=$(cat "$CONF/portainer/url") PORTAINER_KEY=$(cat "$CONF/portainer/api-key") GITHUB_PAT=$(cat "$CONF/github/portainer-pat")
export STACK_FILE STACK_NAME COMPOSE_PATH REPO_URL REPO_REF REPO_USER AUTO_UPDATE ENDPOINT_NAME SECRETS_DIR=$CONF/portainer/secrets

python3 - <<'PY'
import base64, json, os, sys, urllib.error, urllib.request
import yaml

url, key = os.environ["PORTAINER_URL"].rstrip("/"), os.environ["PORTAINER_KEY"]

def api(method, path, body=None):
    req = urllib.request.Request(url + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"X-API-Key": key, "Content-Type": "application/json",
                                          # Cloudflare 가 파이썬 기본 User-Agent 를 봇으로 막으므로(error 1010) 이름을 붙입니다
                                          "User-Agent": "k8s-gitops-portainer-stack/1"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"API 오류 {method} {path}: {e.code} {e.read().decode()[:300]}")

# 1. Swarm 환경
eps = api("GET", "/api/endpoints")
name = os.environ["ENDPOINT_NAME"]
cands = [e for e in eps if (e["Name"] == name if name else True)]
ep = None
for e in cands:
    try:
        swarm = api("GET", f"/api/endpoints/{e['Id']}/docker/swarm")
        ep = e; break
    except SystemExit:
        continue
if not ep: sys.exit("Swarm 환경을 찾지 못했습니다. ENDPOINT_NAME 을 확인하세요.")
eid, swarm_id = ep["Id"], swarm["ID"]
print(f"- 환경: {ep['Name']} (id {eid}), Swarm {swarm_id[:12]}")

# 2. external secret
doc = yaml.safe_load(open(os.environ["STACK_FILE"]))
wanted = [(k, (v or {}).get("name", k)) for k, v in (doc.get("secrets") or {}).items() if (v or {}).get("external")]
have = {s["Spec"]["Name"] for s in api("GET", f"/api/endpoints/{eid}/docker/secrets")}
for key_name, sec_name in wanted:
    if sec_name in have:
        print(f"- secret {sec_name}: 있음, 건너뜀"); continue
    path = os.path.join(os.environ["SECRETS_DIR"], sec_name)
    if not os.path.isfile(path):
        sys.exit(f"secret {sec_name} 이 Portainer 에 없고 값 파일 {path} 도 없습니다.")
    data = open(path, "rb").read().strip()
    api("POST", f"/api/endpoints/{eid}/docker/secrets/create", {"Name": sec_name, "Data": base64.b64encode(data).decode()})
    print(f"- secret {sec_name}: 만듦")

# 3. 스택 등록 또는 재배포
stack_name = os.environ["STACK_NAME"]
git = {"RepositoryReferenceName": os.environ["REPO_REF"], "RepositoryAuthentication": True,
       "RepositoryUsername": os.environ["REPO_USER"], "RepositoryPassword": os.environ["GITHUB_PAT"]}
existing = [s for s in api("GET", "/api/stacks") if s["Name"] == stack_name and s.get("EndpointId") == eid]
if existing:
    sid = existing[0]["Id"]
    api("PUT", f"/api/stacks/{sid}/git/redeploy?endpointId={eid}", {**git, "Prune": True, "RepullImageAndRedeploy": False})
    print(f"- 스택 {stack_name}: 있음, 저장소의 최신 파일로 다시 배포 (id {sid})")
else:
    body = {"Name": stack_name, "SwarmID": swarm_id, "RepositoryURL": os.environ["REPO_URL"], **git,
            "ComposeFile": os.environ["COMPOSE_PATH"], "AutoUpdate": {"Interval": os.environ["AUTO_UPDATE"]}}
    s = api("POST", f"/api/stacks/create/swarm/repository?endpointId={eid}", body)
    print(f"- 스택 {stack_name}: 만듦 (id {s['Id']}, {os.environ['AUTO_UPDATE']} 마다 저장소 확인)")
PY

log "완료. Portainer 의 Stacks 에서 $STACK_NAME 을 확인합니다."
```
{: file="scripts/portainer-stack.sh" }

</details>

- **확인:** 스크립트 출력에 `secret cloudflared_nas_token: 만듦` 과 `스택 cloudflared: 만듦` 이 보이고, 터널 목록에서 `nas` 가 `Healthy` 입니다.

## 5. 클라이언트 설정과 첫 로그인

접속하는 쪽에도 cloudflared 가 있어야 합니다. SSH 가 `ProxyCommand` 로 cloudflared 를 띄우고, cloudflared 가 Access 로그인과 터널 연결을 맡습니다.

```bash
# cloudflared 설치 (사용자 디렉터리)
mkdir -p ~/.local/bin
curl -fsSL -o ~/.local/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/download/2026.9.1/cloudflared-linux-amd64
chmod +x ~/.local/bin/cloudflared
```

```text
Host ssh-cp.[DOMAIN]
  User [CP_USER]
Host ssh-edge.[DOMAIN]
  User [EDGE_USER]
Host ssh-proxmox.[DOMAIN]
  User root
Host nas-ssh.[DOMAIN]
  User [NAS_USER]
Host ssh-cp.[DOMAIN] ssh-edge.[DOMAIN] ssh-proxmox.[DOMAIN] nas-ssh.[DOMAIN]
  ProxyCommand ~/.local/bin/cloudflared access ssh --hostname %h
```
{: file="~/.ssh/config" }

처음 접속하면 cloudflared 가 로그인 주소를 출력하고 기다립니다. 이 주소는 브라우저가 있는 아무 기기에서 열어도 됩니다. 휴대폰에서 열고 이메일을 입력하면 그 주소로 일회용 PIN 이 오고, PIN 을 넣어 승인하면 터미널의 SSH 가 이어집니다. 받은 토큰은 `~/.cloudflared` 에 저장되어 세션 시간(24시간) 동안 다시 묻지 않고, 같은 계정의 다른 이름으로 접속할 때도 브라우저를 다시 열지 않습니다.

```bash
ssh ssh-cp.[DOMAIN]
```

- **확인:** 첫 접속에서 로그인 주소가 나오고, 승인 뒤 서버의 호스트 키를 확인하는 질문이 나옵니다(`yes`). 이후 `ssh nas-ssh.[DOMAIN]` 은 로그인 주소 없이 바로 NAS 셸로 들어갑니다. 공유기와 NAS 의 22번 포트는 여전히 닫혀 있습니다.

## 트러블슈팅

<details markdown="1">
<summary><code>토큰에 권한이 없습니다</code> — 권한을 넣었는데도 스크립트가 멈출 때</summary>

- **원인:** Access·터널 권한을 존 정책(리소스가 도메인)에 넣었습니다. 이 권한들은 계정 단위라 존 정책에서는 효과가 없습니다.
- **해결:** 1단계 표처럼 리소스가 계정인 정책을 따로 만들어 옮깁니다.

</details>

<details markdown="1">
<summary><code>Unable to clone git repository: … authentication required: Repository not found</code> — Portainer 스택 등록</summary>

- **원인:** GitOps 저장소가 비공개인데 스택에 Git 인증 정보가 없습니다.
- **해결:** 4단계의 `portainer-stack.sh` 로 등록합니다. 스택마다 인증 정보가 저장되고, 이후 자동 갱신도 그 정보로 합니다.

</details>

<details markdown="1">
<summary><code>error code: 1010</code> — Portainer API 호출이 거부될 때</summary>

- **원인:** Portainer 가 Cloudflare 프록시 뒤에 있으면, Cloudflare 가 파이썬 기본 User-Agent 를 봇으로 보고 막습니다.
- **해결:** 요청에 고유한 `User-Agent` 헤더를 붙입니다. 스크립트에 반영되어 있습니다.

</details>

<details markdown="1">
<summary><code>ssh: connect to host … port 22: Connection timed out</code></summary>

- **원인:** `~/.ssh/config` 에 `ProxyCommand` 가 없어 SSH 가 Cloudflare 주소의 22번으로 바로 접속합니다. 같은 이유로 웹용 이름(예: `nas.[DOMAIN]`)으로는 SSH 가 되지 않습니다. Cloudflare 프록시는 HTTP 만 넘깁니다.
- **해결:** 5단계의 Host 블록을 넣고 터널용 이름(`nas-ssh.[DOMAIN]`)으로 접속합니다.

</details>

<details markdown="1">
<summary><code>kex_exchange_identification: Connection closed by remote host</code> — NAS 만 안 될 때</summary>

- **원인:** 터널로 들어온 접속은 NAS 에게 모두 자기 주소(`::1`)에서 온 것으로 보여, 로그인 실패가 쌓이면 DSM 자동 차단이 이 주소를 막습니다.
- **해결:** 자동 차단 목록에서 `::1` 을 지우고 허용 목록에 `::1` 과 `127.0.0.1` 을 넣습니다. 자세한 NAS 설정은 [원격 NAS 백업 글](/posts/50/)에 있습니다.

</details>

## 마무리

공유기와 NAS 의 포트를 하나도 열지 않고, Cloudflare Access 로그인을 거쳐 홈랩 서버와 원격 NAS 에 SSH 로 접속하게 했습니다. 터널·DNS·Access 는 스크립트로, 커넥터는 허브의 GitOps 폴더와 NAS 의 Git 저장소 스택으로 관리하므로 새 서버에서도 같은 순서로 다시 만들 수 있습니다. 서버를 하나 더 열 때는 스크립트의 경로 변수에 이름 하나를 더해 다시 실행하고 `~/.ssh/config` 에 Host 한 줄을 더합니다.

## 참고 자료

- [Cloudflare - Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Cloudflare - Connect to SSH with client-side cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/use-cases/ssh/ssh-cloudflared-authentication/)
- [Cloudflare - Service tokens](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/)
- [Cloudflare - One-time PIN login](https://developers.cloudflare.com/cloudflare-one/identity/one-time-pin/)
- [Portainer - API documentation](https://docs.portainer.io/api/docs)
