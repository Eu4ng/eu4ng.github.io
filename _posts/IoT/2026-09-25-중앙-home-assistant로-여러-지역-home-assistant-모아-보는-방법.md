---
layout: post
title: 중앙 Home Assistant로 여러 지역 Home Assistant 모아 보는 방법
description: 허브 쿠버네티스 클러스터에 기기 없는 중앙 Home Assistant 를 띄우고, 커뮤니티 통합 Remote Home Assistant 로 지역마다 따로 도는 Home Assistant 의 엔티티를 한 화면에 모아 보고 제어하는 방법을 정리했습니다.
author: Eu4ng
tags: [iot, home-assistant, kubernetes, argo-cd, gitops, edge]
permalink: /posts/49/
---

지역마다 엣지 클러스터의 Home Assistant(HA)가 기기와 자동화를 맡고, 허브에는 기기를 붙이지 않은 **중앙 HA** 를 하나 둡니다. 중앙 HA 는 **Remote Home Assistant** 통합으로 각 지역 HA 의 WebSocket API 에 붙어 엔티티를 가져오고, 중앙에서 누른 스위치는 원래 지역 HA 로 전달됩니다. 지역 HA 는 `ha-[SITE_CODE].[DOMAIN]`, 중앙 HA 는 `ha.[DOMAIN]` 으로 엽니다. 이 통합은 보통 HACS 로 설치하지만, 여기서는 initContainer 가 릴리스 버전을 고정해 설치하고 연결 설정도 API 스크립트로 넣습니다.

1. 지역 HA 에 Remote Home Assistant 설치
2. 중앙 HA 배포
3. 온보딩과 장기 액세스 토큰
4. 지역 연결과 프록시 설정
5. 2단계 인증과 휴대폰 앱
6. 지역 대시보드
7. 방과 잔재 엔티티 정리
8. 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| 허브 Kubernetes | `v1.37` (kubeadm) |
| 엣지 Kubernetes | `v1.36` (k3s) |
| Home Assistant | `2026.9.3` |
| Remote Home Assistant | `4.6` |
| 작성 기준일 | `2026-09-25` |

다음 항목이 준비되어 있어야 합니다.

- 지역 엣지 클러스터의 HA 와 그 클러스터 Secret `home-assistant/ha-api-token` ([엣지 클러스터에 Home Assistant와 Matter 서버 배포하고 API로 통합 설정하는 방법](/posts/48/))
- control plane 의 엣지 kubeconfig `~/k3s-[SITE].yaml` ([Proxmox에 Ansible로 k3s 엣지 클러스터 만들고 Argo CD 원격 클러스터로 등록하는 방법](/posts/42/))
- 허브 Traefik 으로 서비스를 밖에 여는 구성과 내부망 DNS ([외부 접속 글](/posts/40/), [내부망 DNS 글](/posts/41/))

## 1. 지역 HA 에 Remote Home Assistant 설치

Remote Home Assistant 는 중앙(main)과 지역(remote) HA 양쪽에 모두 설치해야 하고, 지역 쪽 `configuration.yaml` 에는 빈 `remote_homeassistant:` 블록이 있어야 합니다. 지역 HA 매니페스트에 설치 스크립트와 설정 조각을 더하고, initContainer 가 둘 다 처리하게 합니다. 설치 스크립트는 인터넷이 끊겨 내려받지 못해도 경고만 남기고 HA 기동을 막지 않습니다.

```python
# Remote Home Assistant(HACS 커뮤니티 통합)를 /config/custom_components 에 설치합니다. 버전이 같으면 건너뜁니다.
# 중앙 HA 가 지역 HA 를 모아 보려면 양쪽 모두에 설치돼 있어야 합니다. 인터넷이 없어 받지 못해도 HA 기동을 막지 않습니다.
import io, json, os, shutil, sys, tarfile, urllib.request

ver = os.environ.get("REMOTE_HA_VERSION", "4.6")
dst = "/config/custom_components/remote_homeassistant"
try:
    cur = json.load(open(os.path.join(dst, "manifest.json")))["version"]
except Exception:
    cur = None
if cur == ver:
    print(f"remote_homeassistant {ver}: 이미 설치됨"); sys.exit(0)
url = f"https://codeload.github.com/custom-components/remote_homeassistant/tar.gz/refs/tags/{ver}"
try:
    data = urllib.request.urlopen(url, timeout=60).read()
except Exception as e:
    print(f"경고: {url} 를 받지 못했습니다({e}). 현재 버전({cur}) 그대로 둡니다."); sys.exit(0)
tmp = dst + ".new"
shutil.rmtree(tmp, ignore_errors=True)
with tarfile.open(fileobj=io.BytesIO(data)) as tar:
    for m in tar.getmembers():
        parts = m.name.split("/", 1)
        if len(parts) == 2 and parts[1].startswith("custom_components/remote_homeassistant/") and m.isfile():
            rel = parts[1][len("custom_components/remote_homeassistant/"):]
            os.makedirs(os.path.join(tmp, os.path.dirname(rel)), exist_ok=True)
            with open(os.path.join(tmp, rel), "wb") as f:
                f.write(tar.extractfile(m).read())
shutil.rmtree(dst, ignore_errors=True)
os.makedirs(os.path.dirname(dst), exist_ok=True)
os.rename(tmp, dst)
print(f"remote_homeassistant {ver}: 설치함 (이전 {cur})")
```
{: file="iot/edge/home-assistant/install-remote.py" }

```yaml
# --- iot/edge/home-assistant 가 덧붙인 설정. 중앙 HA(Remote Home Assistant)가 이 HA 에 붙을 수 있게 합니다 (원격 쪽 필수) ---
remote_homeassistant:
  instances:
```
{: file="iot/edge/home-assistant/remote.yaml" }

```yaml
# 엣지의 Home Assistant. Matter 커미셔닝 UI 와 제어·자동화 대시보드로만 쓰고, 수집 경로에는 두지 않습니다.
# Matter 통합의 엔티티 상태만 자동화(matter-statestream.yaml)로 브로커에 재발행해 Telegraf 가 받게 합니다 (initContainer 가 /config 로 복사하고 configuration.yaml 에 include 를 한 번 덧붙임).
resources:
  - deployment.yaml
  - pvc.yaml
configMapGenerator:
  - name: home-assistant-seed
    files:
      - matter-statestream.yaml
      - remote.yaml
      - install-remote.py
```
{: file="iot/edge/home-assistant/kustomization.yaml" }

`deployment.yaml` 의 initContainer 는 아래처럼 설치 스크립트를 먼저 실행하고, 설정 블록이 없을 때만 덧붙입니다.

```yaml
initContainers:
  - name: seed-config
    image: ghcr.io/home-assistant/home-assistant:2026.9.3
    command:
      - /bin/sh
      - -c
      - |
        python3 /seed/install-remote.py
        f=/config/configuration.yaml
        [ -f $f ] || exit 0
        cp /seed/matter-statestream.yaml /config/matter-statestream.yaml
        grep -q '^automation matter:' $f || printf '\n# --- iot/edge/home-assistant 가 덧붙인 설정. Matter 통합 엔티티 상태를 MQTT 로 재발행합니다 (자동화는 initContainer 가 복사) ---\nautomation matter: !include matter-statestream.yaml\n' >> $f
        grep -q '^remote_homeassistant:' $f || cat /seed/remote.yaml >> $f
    env:
      - { name: REMOTE_HA_VERSION, value: "4.6" }   # custom-components/remote_homeassistant 태그
    volumeMounts:
      - { name: config, mountPath: /config }
      - { name: seed, mountPath: /seed }
```
{: file="iot/edge/home-assistant/deployment.yaml" }

- **확인:** push 뒤 지역 HA 파드가 다시 뜨고, initContainer 로그에 `remote_homeassistant 4.6: 설치함` 이 보입니다.

```bash
kubectl --kubeconfig ~/k3s-[SITE].yaml -n home-assistant logs deploy/home-assistant -c seed-config
```

## 2. 중앙 HA 배포

중앙 HA 는 기기 탐색이 필요 없어 `hostNetwork` 없이 일반 파드로 띄웁니다. `iot/hub/` 아래 폴더는 허브 Argo CD 의 ApplicationSet 이 허브에 배포합니다. 설치 스크립트는 1단계와 같은 파일을 복사해 둡니다.

```yaml
# 중앙 Home Assistant(ha.[DOMAIN]). 기기는 붙이지 않고, Remote Home Assistant 로 각 지역 HA 의 엔티티를 모아 봅니다.
# 기기 연결과 자동화는 계속 지역 HA 가 맡으므로, 중앙이 멈추거나 WAN 이 끊겨도 지역은 그대로 동작합니다.
resources:
  - deployment.yaml
  - service.yaml
  - pvc.yaml
  - ingressroute.yaml
configMapGenerator:
  - name: home-assistant-seed
    files:
      - install-remote.py      # iot/edge/home-assistant 와 같은 파일
```
{: file="iot/hub/home-assistant/kustomization.yaml" }

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: home-assistant
spec:
  replicas: 1
  strategy:
    type: Recreate           # PVC 가 ReadWriteOnce 입니다
  selector:
    matchLabels: { app: home-assistant }
  template:
    metadata:
      labels: { app: home-assistant }
    spec:
      # 기기 탐색이 필요 없어 hostNetwork 를 쓰지 않습니다. 지역 HA 에는 노드 주소·도메인으로 붙습니다.
      initContainers:
        - name: install-remote
          image: ghcr.io/home-assistant/home-assistant:2026.9.3
          command: ["python3", "/seed/install-remote.py"]
          env:
            - { name: REMOTE_HA_VERSION, value: "4.6" }   # custom-components/remote_homeassistant 태그. 지역 HA 와 같은 버전
          volumeMounts:
            - { name: config, mountPath: /config }
            - { name: seed, mountPath: /seed }
      containers:
        - name: home-assistant
          image: ghcr.io/home-assistant/home-assistant:2026.9.3
          env:
            - { name: TZ, value: Asia/Seoul }
          ports: [{ containerPort: 8123 }]
          volumeMounts:
            - { name: config, mountPath: /config }
          startupProbe:
            httpGet: { path: /, port: 8123 }
            periodSeconds: 5
            failureThreshold: 60
          readinessProbe:
            httpGet: { path: /, port: 8123 }
            periodSeconds: 10
          resources:
            requests: { cpu: 100m, memory: 384Mi }
            limits:   { cpu: "2", memory: 1Gi }   # 기기 없이 원격 엔티티만 들고 있어 지역 HA 보다 가볍습니다
      volumes:
        - name: config
          persistentVolumeClaim: { claimName: home-assistant-config }
        - name: seed
          configMap: { name: home-assistant-seed }
```
{: file="iot/hub/home-assistant/deployment.yaml" }

```yaml
apiVersion: v1
kind: Service
metadata:
  name: home-assistant
spec:
  selector: { app: home-assistant }
  ports:
    - { port: 8123, targetPort: 8123 }
```
{: file="iot/hub/home-assistant/service.yaml" }

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: home-assistant-config
  annotations:
    argocd.argoproj.io/sync-options: Prune=false   # 사용자·원격 연결 설정·대시보드. 지우면 다시 설정해야 합니다
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi
```
{: file="iot/hub/home-assistant/pvc.yaml" }

```yaml
# 중앙 HA. 휴대폰 앱이 로그인 페이지 리디렉트를 처리하지 못하므로 oauth2-proxy 없이 HA 자체 로그인 + 2단계 인증(OTP)으로 보호합니다.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: home-assistant
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`ha.[DOMAIN]`)
      kind: Rule
      services:
        - { name: home-assistant, port: 8123 }
```
{: file="iot/hub/home-assistant/ingressroute.yaml" }

밖에서 이름을 찾을 수 있게 DDNS 목록(`services/cloudflare-ddns` 의 `DOMAINS`)에 `ha.[DOMAIN]` 을, 내부망 DNS(`lan_dns_names`)에 `ha` 를 추가합니다. 방법은 [외부 접속 글](/posts/40/)과 [내부망 DNS 글](/posts/41/)의 서비스 추가 절차와 같습니다.

- **확인:** Argo CD 에 `home-assistant` Application 이 `Synced`, `Healthy` 이고, initContainer 로그에 `remote_homeassistant 4.6: 설치함` 이 보입니다.

## 3. 온보딩과 장기 액세스 토큰

이 단계에서는 `https://ha.[DOMAIN]` 이 아직 `400` 을 돌려줍니다. 중앙 HA 가 Traefik 을 거친 요청을 신뢰하도록 하는 설정은 4단계에서 넣기 때문입니다. 그래서 온보딩은 control plane 의 포트 포워딩으로 합니다.

```bash
# control plane. 같은 LAN 의 브라우저에서 http://[CONTROL_PLANE_IP]:8123 으로 엽니다. 온보딩이 끝나면 Ctrl+C
kubectl -n home-assistant port-forward --address 0.0.0.0 svc/home-assistant 8123:8123
```

소유자 계정을 만들고 위치·단위 화면을 마친 뒤, 프로필의 **보안** 탭에서 **장기 액세스 토큰**을 만들어 허브 Secret 에 넣습니다. 지역 HA 때와 같은 명령에서 kubeconfig 만 뺍니다.

```bash
# control plane. 붙여 넣은 토큰은 화면에 보이지 않습니다
read -rsp "중앙 HA 장기 토큰: " T; echo; echo "입력 길이: ${#T}"
[ -n "$T" ] && printf '%s' "$T" | kubectl -n home-assistant \
  create secret generic ha-api-token --from-file=token=/dev/stdin
unset T
```

- **확인:** `kubectl -n home-assistant get secret ha-api-token -o jsonpath='{.data.token}' | base64 -d | wc -c` 가 0 이 아닌 값(180 안팎)입니다.

## 4. 지역 연결과 프록시 설정

[지역 HA 글](/posts/48/)의 `setup-home-assistant.sh` 를 중앙 HA 에도 씁니다. 변수 블록에서 MQTT·Matter·OTBR 주소를 비우면 그 통합은 건너뛰고, `REMOTES` 에 적은 지역마다 Remote Home Assistant 연결을 추가합니다. 지역 HA 토큰은 그 지역 클러스터의 Secret 에서 읽습니다. 엔티티 접두사(`[SITE_CODE]_`)는 지역마다 달라야 하며, 여러 지역에 같은 이름의 엔티티가 있어도 충돌하지 않게 합니다. 서비스 이름에도 같은 접두사가 붙습니다.

중앙 HA 앞의 프록시는 같은 클러스터의 Traefik 파드이므로 `TRUSTED_PROXIES` 에는 허브의 파드 대역을 넣습니다. kubeadm 에 Flannel 기본값을 썼다면 `10.244.0.0/16` 입니다. 밖에서 오는 요청은 그 앞에 Cloudflare 를 거치므로 스크립트의 Cloudflare 대역(`$CLOUDFLARE_IPV4`)도 함께 넣습니다. 빼면 HA 가 Cloudflare 주소를 접속자로 보고 로그인 실패 차단도 그 주소에 겁니다.

```bash
# control plane 에서 스크립트 내려받기
wget https://eu4ng.github.io/assets/scripts/iot/setup-home-assistant.sh
```

```bash
# 중앙 HA 용으로 바꾸는 변수 (나머지는 그대로)
MQTT_BROKER=
MATTER_URL=
OTBR_URL=
TRUSTED_PROXIES="[POD_CIDR] $CLOUDFLARE_IPV4"
KUBECTL="kubectl"
REMOTES="[SITE_CODE]_|[EDGE_IP]:8123|$HOME/k3s-[SITE].yaml|[SITE_NAME] "
```
{: file="setup-home-assistant.sh" }

```bash
# control plane. 서비스 주소로 붙습니다(포트 포워딩은 스크립트가 HA 를 재시작할 때 끊깁니다)
bash setup-home-assistant.sh http://$(kubectl -n home-assistant get svc home-assistant -o jsonpath='{.spec.clusterIP}'):8123
```

<details markdown="1">
<summary>setup-home-assistant.sh 전문</summary>

```bash
#!/usr/bin/env bash
#
# Home Assistant 에 IoT 스택용 통합(MQTT, Matter, OpenThread Border Router)을 API 로 추가합니다. 웹 UI 의
# "기기 및 서비스 > 통합구성요소 추가" 와 같은 설정 흐름(config flow)을 순서대로 밟습니다. 이미 있는 통합은 건너뜁니다.
# 역방향 프록시(허브 Traefik) 뒤에서 접속받도록 HA 의 HTTP 설정(프록시 신뢰, 로그인 실패 차단)도 API 로 바꿉니다.
# 중앙 HA 에서는 MQTT·Matter·OTBR 을 비우고 REMOTES 에 지역 HA 를 적으면 Remote Home Assistant 로 지역 엔티티를 모읍니다.
# HA 에 접속할 수 있는 곳에서 실행합니다: bash setup-home-assistant.sh [HA_URL]   (예: http://[EDGE_IP]:8123)
# 준비: HA 프로필 > 보안 > 장기 액세스 토큰 에서 토큰을 만들어 엣지 클러스터 Secret 에 넣어 둡니다(아래 HA_TOKEN_SECRET).
#       kubectl 로 그 Secret 을 읽을 수 없으면 실행 중 토큰을 입력받습니다. MQTT 비밀번호는 실행 중 입력받습니다.

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
MQTT_BROKER=mosquitto.mosquitto.svc.cluster.local   # HA 가 hostNetwork + ClusterFirstWithHostNet 이라 클러스터 이름이 풀립니다
MQTT_PORT=1883
MQTT_USER=homeassistant
MATTER_URL=ws://127.0.0.1:5580/ws                   # 같은 노드의 hostNetwork 파드(matter-server)
OTBR_URL=http://127.0.0.1:8081                      # 같은 노드의 hostNetwork 파드(otbr). OTBR 이 없으면 비워 둡니다
# Cloudflare 프록시 대역(https://www.cloudflare.com/ips-v4). 밖에서 Cloudflare 를 거쳐 오면 이 대역까지 신뢰해야 HA 가 실제 접속자 IP 를 보고,
# 로그인 실패 차단도 Cloudflare 주소가 아니라 그 접속자에게 겁니다.
CLOUDFLARE_IPV4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
TRUSTED_PROXIES="[HUB_NODE_IP_1] [HUB_NODE_IP_2] $CLOUDFLARE_IPV4"   # HA 앞 역방향 프록시 주소(허브 파드 요청은 허브 노드 주소로 들어옴)와 Cloudflare. 비우면 HTTP 설정 생략
LOGIN_ATTEMPTS=5                                    # 로그인 실패가 이 횟수면 그 IP 를 차단
HA_TOKEN_SECRET=home-assistant/ha-api-token         # 토큰을 담은 Secret (네임스페이스/이름, 키 token)
KUBECTL="kubectl --kubeconfig $HOME/k3s-[SITE].yaml"   # 이 HA 가 있는 클러스터에 접근하는 kubectl
# 중앙 HA 전용: 모아 볼 지역 HA. "엔티티접두사|주소:포트|지역클러스터 kubeconfig|표시이름접두사" 를 공백으로 구분.
# 지역 HA 의 토큰은 그 클러스터의 HA_TOKEN_SECRET 에서 읽습니다. 지역 HA 에도 Remote Home Assistant 가 설치돼 있어야 합니다.
REMOTES=""                                          # 예: "dj_|[EDGE_IP]:8123|$HOME/k3s-[SITE].yaml|대전 "
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
log "사전 검사"
HA_URL=${1:-}
[[ "$HA_URL" =~ ^https?:// ]] || die "사용법: bash setup-home-assistant.sh [HA_URL]"
command -v python3 >/dev/null || die "python3 이 필요합니다."
HA_TOKEN=$($KUBECTL -n "${HA_TOKEN_SECRET%%/*}" get secret "${HA_TOKEN_SECRET#*/}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
if [ -n "$HA_TOKEN" ]; then echo "HA 토큰: Secret $HA_TOKEN_SECRET 에서 읽음"; else read -rsp "HA 장기 액세스 토큰: " HA_TOKEN; echo; fi
MQTT_PASSWORD=""
[ -z "$MQTT_BROKER" ] || { read -rsp "MQTT 비밀번호 ($MQTT_USER): " MQTT_PASSWORD; echo; [ -n "$MQTT_PASSWORD" ] || die "MQTT 비밀번호가 비어 있습니다."; }
[ -n "$HA_TOKEN" ] || die "HA 토큰이 비어 있습니다."
# 지역 HA 토큰을 각 클러스터에서 읽어 JSON 으로 넘깁니다.
REMOTES_JSON="[]"
for r in $REMOTES; do
  IFS='|' read -r prefix hostport kcfg fname <<<"$r"
  rt=$(kubectl --kubeconfig "$kcfg" -n "${HA_TOKEN_SECRET%%/*}" get secret "${HA_TOKEN_SECRET#*/}" -o jsonpath='{.data.token}' | base64 -d)
  [ -n "$rt" ] || die "지역 HA 토큰을 읽지 못했습니다: $kcfg"
  REMOTES_JSON=$(python3 -c 'import json,sys; l=json.loads(sys.argv[1]); h,p=sys.argv[3].rsplit(":",1); l.append({"prefix":sys.argv[2],"host":h,"port":int(p),"token":sys.argv[4],"fname":sys.argv[5]}); print(json.dumps(l))' "$REMOTES_JSON" "$prefix" "$hostport" "$rt" "${fname:-}")
done
export HA_URL HA_TOKEN MQTT_BROKER MQTT_PORT MQTT_USER MQTT_PASSWORD MATTER_URL OTBR_URL TRUSTED_PROXIES LOGIN_ATTEMPTS REMOTES_JSON

# ---------- 2. 통합 추가 ----------
# 설정 흐름은 단계마다 폼(data_schema)을 돌려줍니다. 폼의 필드 이름을 보고 아는 값을 채워 다음 단계로 넘기고,
# 메뉴 단계는 지정한 항목을 고르며, create_entry 가 나오면 끝입니다. 모르는 폼이 나오면 흐름을 취소하고 멈춥니다.
python3 - <<'PY'
import json, os, sys, urllib.request, urllib.error

url, token = os.environ["HA_URL"].rstrip("/"), os.environ["HA_TOKEN"]

def api(method, path, body=None):
    req = urllib.request.Request(url + path, method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"API 오류 {method} {path}: {e.code} {e.read().decode()[:300]}")

try:
    api("GET", "/api/")
except SystemExit:
    sys.exit("토큰이 거부됐습니다. HA 주소와 장기 액세스 토큰을 확인하세요.")

entries = {e["domain"] for e in api("GET", "/api/config/config_entries/entry")}

# 도메인별로 폼 필드에 넣을 값과 메뉴에서 고를 항목
values = {
    "mqtt": {"broker": os.environ["MQTT_BROKER"], "port": int(os.environ["MQTT_PORT"]),
             "username": os.environ["MQTT_USER"], "password": os.environ["MQTT_PASSWORD"]},
    "matter": {"url": os.environ["MATTER_URL"]},
    "otbr": {"url": os.environ["OTBR_URL"]},
}
menus = {"mqtt": "broker"}          # MQTT 첫 단계가 메뉴일 때: 브로커 직접 입력
skips = {"matter": {"install_addon": False, "use_addon": False}}   # 애드온(HAOS 전용) 대신 기존 서버 사용

for domain in ["mqtt", "matter", "otbr"]:
    if not (values[domain].get("url") if domain != "mqtt" else values[domain]["broker"]):
        print(f"- {domain}: 주소가 비어 있어 건너뜀"); continue
    if domain in entries:
        print(f"- {domain}: 이미 있음, 건너뜀"); continue
    step = api("POST", "/api/config/config_entries/flow", {"handler": domain, "show_advanced_options": False})
    for _ in range(6):
        t = step.get("type")
        if t == "create_entry":
            print(f"- {domain}: 추가됨 ({step.get('title')})"); break
        if t == "abort":
            sys.exit(f"{domain}: 중단됨 - {step.get('reason')}")
        if t == "menu":
            choice = menus.get(domain) or step["menu_options"][0]
            step = api("POST", f"/api/config/config_entries/flow/{step['flow_id']}", {"next_step_id": choice}); continue
        if t == "form":
            fields = [f["name"] for f in step.get("data_schema", [])]
            data = {}
            for f in step.get("data_schema", []):
                n = f["name"]
                if n in values[domain]: data[n] = values[domain][n]
                elif n in skips.get(domain, {}): data[n] = skips[domain][n]
                elif f.get("type") == "expandable":   # 접힌 "고급 설정" 섹션: 기본값을 쓰고, 기본값 없는 필수 항목은 꺼 둔 상태로
                    sec = {}
                    for x in f.get("schema", []):
                        sel = x.get("selector", {})
                        if "default" in x: sec[x["name"]] = x["default"]
                        elif x.get("required") and "boolean" in sel: sec[x["name"]] = False
                        elif x.get("required") and "select" in sel:
                            o = sel["select"]["options"][0]; sec[x["name"]] = o["value"] if isinstance(o, dict) else o
                    data[n] = sec
                elif f.get("required") and "default" not in f:
                    api("DELETE", f"/api/config/config_entries/flow/{step['flow_id']}")
                    sys.exit(f"{domain}: 모르는 필수 필드 {n} (단계 {step.get('step_id')}, 필드 {fields})")
            if step.get("errors"):
                api("DELETE", f"/api/config/config_entries/flow/{step['flow_id']}")
                sys.exit(f"{domain}: 입력 오류 {step['errors']}")
            step = api("POST", f"/api/config/config_entries/flow/{step['flow_id']}", data); continue
        sys.exit(f"{domain}: 예상하지 못한 단계 {t}")
    else:
        sys.exit(f"{domain}: 단계가 끝나지 않습니다")

# 지역 HA 연결 (중앙 HA). 같은 지역을 이미 연결했으면 흐름이 already_configured 로 끝나므로 건너뜁니다.
def run_flow(step, answer, path):
    for _ in range(8):
        t = step.get("type")
        if t in ("create_entry", "abort"): return step
        if t != "form": sys.exit(f"예상하지 못한 단계 {t}")
        step = api("POST", f"{path}/{step['flow_id']}", answer(step))
    sys.exit("단계가 끝나지 않습니다")
for rm in json.loads(os.environ.get("REMOTES_JSON") or "[]"):
    def conn(step):
        if step.get("step_id") == "user": return {"type": "Add a remote node"}
        d = {f["name"]: f.get("default") for f in step.get("data_schema", [])}
        return {"host": rm["host"], "port": rm["port"], "access_token": rm["token"],
                "max_message_size": d.get("max_message_size"), "secure": False, "verify_ssl": False}
    r = run_flow(api("POST", "/api/config/config_entries/flow", {"handler": "remote_homeassistant"}), conn, "/api/config/config_entries/flow")
    if r["type"] == "abort":
        print(f"- 원격 {rm['host']}: {r.get('reason')}, 건너뜀"); continue
    eid = r["result"]["entry_id"]
    # 옵션: 엔티티·표시 이름·서비스 접두사로 지역을 구분합니다. 이후 단계(필터 등)는 기본값.
    def opts(step):
        if step.get("step_id") == "init":
            return {"entity_prefix": rm["prefix"], "entity_friendly_name_prefix": rm["fname"], "service_prefix": rm["prefix"].rstrip("_")}
        return {f["name"]: f["default"] for f in step.get("data_schema", []) if "default" in f}
    run_flow(api("POST", "/api/config/config_entries/options/flow", {"handler": eid}), opts, "/api/config/config_entries/options/flow")
    print(f"- 원격 {rm['host']}: 추가됨 (엔티티 접두사 {rm['prefix']})")

print("\n통합 상태:")
for e in api("GET", "/api/config/config_entries/entry"):
    if e["domain"] in ("mqtt", "matter", "otbr", "thread", "remote_homeassistant"):
        print(f"  {e['domain']:7} {e['state']:12} {e['title']}")
PY

# ---------- 3. Thread 기본 네트워크와 HTTP 설정 (WebSocket API) ----------
# Thread: OTBR 이 만든 데이터셋을 HA 의 기본(preferred) 네트워크로 지정합니다. 휴대폰 앱의 "Thread 자격 증명 동기화"가 이 망을 넘겨받습니다.
# HTTP: HA 2026 부터 HTTP 설정은 YAML 이 아니라 저장소(.storage/http)에 있고 WebSocket API 로 바꿉니다.
# 새 설정은 "pending" 으로 저장되고 HA 가 재시작해 적용합니다. 동작을 확인하고 promote 해야 확정되며, 하지 않으면 5분 뒤 되돌아갑니다.
log "Thread 기본 네트워크, HTTP 설정(프록시 신뢰: ${TRUSTED_PROXIES:-없음}, 로그인 실패 $LOGIN_ATTEMPTS 회 차단)"
python3 - <<'PY'
import base64, json, os, socket, sys, time, urllib.parse, urllib.request

url, token = os.environ["HA_URL"].rstrip("/"), os.environ["HA_TOKEN"]
want = {"use_x_forwarded_for": True, "trusted_proxies": os.environ["TRUSTED_PROXIES"].split(),
        "ip_ban_enabled": True, "login_attempts_threshold": int(os.environ["LOGIN_ATTEMPTS"])}

class WS:  # 표준 라이브러리만 쓰는 최소 WebSocket 클라이언트 (텍스트 프레임)
    def __init__(self):
        u = urllib.parse.urlparse(url)
        self.s = socket.create_connection((u.hostname, u.port or 80), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET /api/websocket HTTP/1.1\r\nHost: {u.netloc}\r\nUpgrade: websocket\r\n"
                        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            c = self.s.recv(1)
            if not c: raise ConnectionError("closed")   # 닫힌 소켓의 recv 는 b"" 를 곧바로 돌려줘 무한 루프가 됩니다
            resp += c
        if b" 101 " not in resp.split(b"\r\n")[0]: sys.exit("WebSocket 연결 실패: " + resp.decode(errors="replace")[:200])
        self.n = 0
        assert self.recv()["type"] == "auth_required"
        self.send({"type": "auth", "access_token": token})
        if self.recv()["type"] != "auth_ok": sys.exit("WebSocket 인증 실패")
    def _read(self, k):
        b = b""
        while len(b) < k:
            c = self.s.recv(k - len(b))
            if not c: raise ConnectionError("closed")
            b += c
        return b
    def recv(self):
        h = self._read(2); ln = h[1] & 0x7F
        if ln == 126: ln = int.from_bytes(self._read(2), "big")
        elif ln == 127: ln = int.from_bytes(self._read(8), "big")
        return json.loads(self._read(ln))
    def send(self, obj):
        d = json.dumps(obj).encode(); m = os.urandom(4); ln = len(d)
        hdr = bytes([0x81]) + (bytes([0x80 | ln]) if ln < 126 else bytes([0x80 | 126]) + ln.to_bytes(2, "big") if ln < 65536 else bytes([0x80 | 127]) + ln.to_bytes(8, "big"))
        self.s.sendall(hdr + m + bytes(b ^ m[i % 4] for i, b in enumerate(d)))
    def call(self, **cmd):
        self.n += 1; cmd["id"] = self.n; self.send(cmd)
        while True:
            r = self.recv()
            if r.get("id") == self.n and r.get("type") == "result":
                if not r["success"]: sys.exit(f"{cmd['type']} 실패: {r.get('error')}")
                return r.get("result")

try:
    ds = WS().call(type="thread/list_datasets")["datasets"]
except SystemExit:
    ds = []   # Thread 통합이 없는 HA(중앙 HA 등)
otbr = [d for d in ds if d.get("source") == "otbr"]
if len(otbr) == 1 and not otbr[0].get("preferred"):
    WS().call(type="thread/set_preferred_dataset", dataset_id=otbr[0]["dataset_id"])
    print(f"- Thread: {otbr[0]['network_name']} (채널 {otbr[0]['channel']}) 을 기본 네트워크로 지정")
elif otbr:
    print(f"- Thread: 기본 네트워크 {[d['network_name'] for d in ds if d.get('preferred')]}, 건너뜀")
else:
    print("- Thread: OTBR 데이터셋이 없어 건너뜀")

if not want["trusted_proxies"]: sys.exit(0)
norm = lambda v: [p if "/" in p else p + ("/128" if ":" in p else "/32") for p in v]
want["trusted_proxies"] = norm(want["trusted_proxies"])
cur = WS().call(type="http/config")
base = dict(cur["pending"] or cur["stable"] or cur["default"])
for k in ("created_at", "error", "error_message"): base.pop(k, None)
if all(base.get(k) == v for k, v in want.items()) and cur["pending"] is None:
    print("- 이미 같은 설정, 건너뜀"); sys.exit(0)
# 같은 설정이 pending 으로 이미 적용돼 돌고 있으면 확정만 합니다. pending 이 남아 있어도 되돌려진 상태(stable 로 동작)면 다시 넣습니다.
if not (cur["pending"] and cur["active_config_type"] == "pending" and all(base.get(k) == v for k, v in want.items())):
    base.update(want)
    r = WS().call(type="http/config/configure", config=base)
    print(f"- pending 으로 저장, 재시작: {r.get('restart')}")
# 재시작 뒤 다시 붙을 때까지 대기
for _ in range(90):
    time.sleep(5)
    try:
        c = WS().call(type="http/config")
        if c["active_config_type"] == "pending": break
    except Exception: pass
else: sys.exit("HA 가 pending 설정으로 다시 뜨지 않았습니다. HA 로그를 확인하세요 (5분 뒤 이전 설정으로 되돌아갑니다).")
WS().call(type="http/config/promote")
s = WS().call(type="http/config")["stable"]
print("- 확정:", {k: s.get(k) for k in want})
PY

unset HA_TOKEN MQTT_PASSWORD
log "완료. 상태가 loaded 가 아니면 HA 로그를 확인합니다."
```
{: file="setup-home-assistant.sh" }

</details>

스크립트는 HTTP 설정을 넣고 HA 를 재시작한 뒤, 다시 뜬 것을 확인하고 확정합니다. 다시 실행하면 이미 연결한 지역은 `already_configured` 로 건너뜁니다.

- **확인:** 출력의 통합 상태에 `remote_homeassistant loaded` 가 지역마다 한 줄씩 있고, 마지막에 `- 확정:` 과 함께 `trusted_proxies` 가 보입니다. 이제 `https://ha.[DOMAIN]` 이 로그인 화면을 보여 줍니다.

## 5. 2단계 인증과 휴대폰 앱

중앙 HA 도 휴대폰 앱으로 붙으므로 oauth2-proxy 를 두지 않고 HA 로그인과 2단계 인증으로 보호합니다. 프로필의 **보안** 탭에서 **다단계 인증 모듈**의 **인증 앱**을 켜고, QR 코드를 Google OTP 같은 TOTP 인증 앱으로 찍어 등록합니다. 휴대폰 앱에서는 서버를 하나 더 추가해 주소를 `https://ha.[DOMAIN]` 으로 둡니다.

> HA 는 2단계 인증의 백업 코드를 주지 않습니다. 인증 앱의 클라우드 백업을 켜 두거나 두 번째 기기에도 등록해 둡니다.
{: .prompt-danger }

- **확인:** 휴대폰 데이터망에서 `https://ha.[DOMAIN]` 에 로그인하면 OTP 코드를 묻고, 로그인 뒤 지역 엔티티가 보입니다.

## 6. 지역 대시보드

Remote Home Assistant 는 지역 HA 의 엔티티 상태만 복제하고 기기와 방(area)은 가져오지 않습니다. 그래서 중앙 HA 의 기록 화면이나 기본 대시보드에서는 지역의 방 단위로 고를 수 없습니다. 중앙에는 방을 만들지 않고, 사이드바에 **지역** 대시보드를 따로 둡니다. 탭 하나가 지역이고, 탭 안의 카드 하나가 방입니다. 카드는 커뮤니티 카드 **auto-entities** 가 템플릿으로 만듭니다. 방은 기기 이름 규칙 `<방>-<종류>[번호]`(예: `bedroom2-th2`)에서 자르므로, 기기를 추가하거나 이름을 바꿔 방을 옮겨도 YAML 을 고치지 않아도 됩니다.

- 방 카드에는 현재 값과 24시간 기록 그래프가 함께 나옵니다. 그래프는 단위별로 나뉘고, 재실·문은 타임라인으로 그려집니다.
- 맨 위 **주의** 카드에는 오프라인 기기, 배터리 20% 미만, LQI 50 미만, Zigbee2MQTT 브리지 끊김만 모입니다. 해당하는 게 없으면 카드가 숨습니다.

auto-entities 도 Remote Home Assistant 처럼 initContainer 가 버전을 고정해 받습니다.

```python
# auto-entities(커뮤니티 대시보드 카드)를 /config/www/community 에 받습니다. 버전이 같으면 건너뜁니다.
# lovelace.yaml 이 /local/community/... 로 리소스를 등록하고, dashboards/regions.yaml 이 이 카드로 방 카드를 자동으로 만듭니다.
# 인터넷이 없어 받지 못해도 HA 기동을 막지 않습니다.
import os, sys, urllib.request

ver = os.environ.get("AUTO_ENTITIES_VERSION", "1.16.1")
dst = "/config/www/community/lovelace-auto-entities"
stamp = os.path.join(dst, "VERSION")
try:
    cur = open(stamp).read().strip()
except Exception:
    cur = None
if cur == ver:
    print(f"auto-entities {ver}: 이미 설치됨"); sys.exit(0)
url = f"https://raw.githubusercontent.com/thomasloven/lovelace-auto-entities/v{ver}/auto-entities.js"
try:
    data = urllib.request.urlopen(url, timeout=60).read()
except Exception as e:
    print(f"경고: {url} 를 받지 못했습니다({e}). 현재 버전({cur}) 그대로 둡니다."); sys.exit(0)
os.makedirs(dst, exist_ok=True)
with open(os.path.join(dst, "auto-entities.js.new"), "wb") as f:
    f.write(data)
os.replace(os.path.join(dst, "auto-entities.js.new"), os.path.join(dst, "auto-entities.js"))
open(stamp, "w").write(ver)
print(f"auto-entities {ver}: 설치함 (이전 {cur})")
```
{: file="iot/hub/home-assistant/install-frontend.py" }

`configuration.yaml` 에 한 번 덧붙이는 대시보드 등록입니다. 대시보드 키에는 `-` 가 있어야 합니다.

```yaml
# --- iot/hub/home-assistant 가 덧붙인 설정. 지역 대시보드(dashboards/regions.yaml)와 그 카드(auto-entities)를 등록합니다 ---
# 리소스를 YAML 로 관리하므로 UI 의 리소스 편집은 막힙니다. 카드 추가는 install-frontend.py 와 여기에 함께 넣습니다.
lovelace:
  resource_mode: yaml
  resources:
    - { url: /local/community/lovelace-auto-entities/auto-entities.js?v=1.16.1, type: module }   # install-frontend.py 의 버전과 맞춥니다
  dashboards:
    dashboard-regions:           # 대시보드 키에는 - 가 있어야 합니다
      mode: yaml
      filename: dashboards/regions.yaml
      title: 지역
      icon: mdi:map-marker
      show_in_sidebar: true
```
{: file="iot/hub/home-assistant/lovelace.yaml" }

대시보드 원본입니다. `[SITE_NAME]` 은 4단계 `REMOTES` 의 마지막 칸(엔티티 표시 이름 접두사), `[SITE]` 는 탭 주소입니다. 지역을 추가할 때는 탭 하나를 복사해 이 두 값만 바꿉니다.

{% raw %}
```yaml
# 지역 대시보드(사이드바 "지역"). 탭 = 지역, 탭 안의 카드 = 방. initContainer 가 기동마다 /config/dashboards/regions.yaml 로 덮어쓰므로 여기가 원본입니다.
# 중앙 HA 에는 방·기기가 없으므로(Remote Home Assistant 는 엔티티만 복제) 방은 이름 규칙에서 자릅니다:
#   엔티티 friendly_name = <지역 접두사><방>-<종류>[번호] <항목>  예) "[SITE_NAME]bedroom2-th2 온도"  (iot/README.md 의 기기 이름 규칙)
# 기기 추가·방 이동(이름 변경)·새 방은 YAML 수정 없이 반영됩니다. 규칙에 없는 종류를 쓰면 아래 두 정규식의 (th|multi|door|motion) 에 추가합니다.
# 지역 추가: 탭 하나를 복사해 title·path 와 템플릿의 region(Remote Home Assistant 의 entity_friendly_name_prefix)을 바꿉니다.
# 기록 그래프는 중앙 HA 레코더(기본 10일 보관)에서 그립니다. 그보다 긴 기간은 Grafana(허브 TimescaleDB)에서 봅니다.
title: 지역
views:
  - title: "[SITE_NAME]"
    path: "[SITE]"
    icon: mdi:home-city
    cards:
      # 주의: 오프라인(가용성 60분 초과·지역 연결 끊김), 배터리 20% 미만, LQI 50 미만, Zigbee2MQTT 브리지 끊김. 해당이 없으면 숨습니다.
      - type: custom:auto-entities
        show_empty: false
        card:
          type: entities
          title: 주의
        filter:
          template: |
            {%- set region = '[SITE_NAME]' -%}
            {%- set ns = namespace(rows=[]) -%}
            {%- for s in (states.sensor | list) + (states.binary_sensor | list) -%}
              {%- set fn = s.attributes.friendly_name | default('', true) -%}
              {%- set label = fn[region | length:] if fn.startswith(region) else '' -%}
              {%- set dev = label.split(' ')[0] -%}
              {%- set reason = '' -%}
              {%- if dev is match('[a-z0-9]+-(th|multi|door|motion)[0-9]*$') -%}
                {%- if s.state == 'unavailable' -%}{%- set reason = '오프라인' -%}
                {%- elif s.attributes.device_class == 'battery' and s.state | int(100) < 20 -%}{%- set reason = '배터리 ' ~ s.state ~ '%' -%}
                {%- elif s.attributes.unit_of_measurement == 'lqi' and s.state | int(255) < 50 -%}{%- set reason = '신호 약함 ' ~ s.state -%}
                {%- endif -%}
              {%- elif label.startswith('Zigbee2MQTT Bridge') and s.attributes.device_class == 'connectivity' and s.state != 'on' -%}
                {%- set reason = '브리지 끊김' -%}
              {%- endif -%}
              {%- if reason -%}
                {%- set ns.rows = ns.rows + [{'entity': s.entity_id, 'name': label ~ ' — ' ~ reason}] -%}
              {%- endif -%}
            {%- endfor -%}
            {{ ns.rows | sort(attribute='name') | tojson }}
      # 방마다 현재 값 카드와 24시간 기록 그래프(단위별로 나뉘고 재실·문은 타임라인)를 한 묶음으로 둡니다.
      # 상태 항목(온도·습도·조도·재실·문)만 보이고, 배터리·전압·LQI 같은 진단값은 위 주의 카드에서만 봅니다.
      - type: custom:auto-entities
        card_param: cards
        card:
          type: grid
          columns: 1                 # 그래프가 좁아지지 않게 방 하나가 한 줄을 씁니다
          square: false
        filter:
          template: |
            {%- set region = '[SITE_NAME]' -%}
            {%- set shown = ['temperature', 'humidity', 'illuminance', 'occupancy', 'motion', 'presence', 'door', 'window', 'opening'] -%}
            {%- set ns = namespace(rows=[], cards=[]) -%}
            {%- for s in (states.sensor | list) + (states.binary_sensor | list) -%}
              {%- set fn = s.attributes.friendly_name | default('', true) -%}
              {%- set label = fn[region | length:] if fn.startswith(region) else '' -%}
              {%- set dev = label.split(' ')[0] -%}
              {%- if dev is match('[a-z0-9]+-(th|multi|door|motion)[0-9]*$') and s.attributes.device_class | default('', true) in shown -%}
                {%- set ns.rows = ns.rows + [{'room': dev.split('-')[0], 'row': {'entity': s.entity_id, 'name': label}}] -%}
              {%- endif -%}
            {%- endfor -%}
            {%- for room in ns.rows | map(attribute='room') | unique | sort -%}
              {%- set ents = ns.rows | selectattr('room', 'eq', room) | map(attribute='row') | sort(attribute='name') | list -%}
              {%- set ns.cards = ns.cards + [{'type': 'vertical-stack', 'cards': [
                    {'type': 'entities', 'title': room, 'entities': ents},
                    {'type': 'history-graph', 'hours_to_show': 24, 'entities': ents}]}] -%}
            {%- endfor -%}
            {{ ns.cards | tojson }}
```
{: file="iot/hub/home-assistant/regions.yaml" }
{% endraw %}

2단계의 `kustomization.yaml` 에 세 파일을 추가합니다.

```yaml
# 중앙 Home Assistant(ha.[DOMAIN]). 기기·방은 두지 않고, Remote Home Assistant 로 각 지역 HA 의 엔티티를 모아 "지역" 대시보드(regions.yaml)로 봅니다.
# 기기 연결과 자동화는 계속 지역 HA 가 맡으므로, 중앙이 멈추거나 WAN 이 끊겨도 지역은 그대로 동작합니다.
resources:
  - deployment.yaml
  - service.yaml
  - pvc.yaml
  - ingressroute.yaml
configMapGenerator:
  - name: home-assistant-seed
    files:
      - install-remote.py      # iot/edge/home-assistant 와 같은 파일
      - install-frontend.py    # 대시보드 카드(auto-entities)
      - lovelace.yaml          # configuration.yaml 에 한 번 덧붙이는 대시보드 등록
      - regions.yaml           # 지역 대시보드 원본
```
{: file="iot/hub/home-assistant/kustomization.yaml" }

`deployment.yaml` 의 initContainer 를 아래처럼 바꿉니다. 대시보드 파일은 기동할 때마다 저장소 내용으로 덮어쓰고, 설정 블록은 없을 때만 덧붙입니다.

```yaml
# 기기 탐색이 필요 없어 hostNetwork 를 쓰지 않습니다. 지역 HA 에는 노드 주소·도메인으로 붙습니다.
# Remote Home Assistant 와 auto-entities 를 받고, 지역 대시보드를 기동마다 저장소 내용으로 덮어씁니다.
# 대시보드 등록(lovelace 블록)은 HA 가 만든 configuration.yaml 에 없을 때만 덧붙입니다. 파일이 아직 없으면(최초 기동) 다음 기동에 붙입니다.
initContainers:
  - name: install-remote
    image: ghcr.io/home-assistant/home-assistant:2026.9.3
    command:
      - /bin/sh
      - -c
      - |
        python3 /seed/install-remote.py
        python3 /seed/install-frontend.py
        mkdir -p /config/dashboards && cp /seed/regions.yaml /config/dashboards/regions.yaml
        f=/config/configuration.yaml
        [ -f $f ] || exit 0
        grep -q '^lovelace:' $f || cat /seed/lovelace.yaml >> $f
    env:
      - { name: REMOTE_HA_VERSION, value: "4.6" }   # custom-components/remote_homeassistant 태그. 지역 HA 와 같은 버전
      - { name: AUTO_ENTITIES_VERSION, value: "1.16.1" }   # thomasloven/lovelace-auto-entities 태그. lovelace.yaml 의 ?v= 와 맞춥니다
    volumeMounts:
      - { name: config, mountPath: /config }
      - { name: seed, mountPath: /seed }
```
{: file="iot/hub/home-assistant/deployment.yaml" }

- **확인:** push 뒤 initContainer 로그에 `auto-entities 1.16.1: 설치함` 이 보이고, 사이드바의 **지역** 을 열면 지역 탭 안에 방 카드와 기록 그래프가 나옵니다.

## 7. 방과 잔재 엔티티 정리

두 가지를 정리합니다. 하나는 중앙 HA 를 온보딩할 때 자동으로 생긴 빈 방(거실·주방·침실 등)입니다. 다른 하나는 지역에서 사라진 엔티티로, 이름에 `_2` 가 붙은 중복본이나 기기 이름을 바꾸기 전의 ID 가 값 없이 중앙 레지스트리에 남은 것입니다. HA 파드 안에서 WebSocket API 로 정리하는 스크립트를 씁니다. 토큰은 3단계의 Secret 에서 읽어 넘기므로 화면에 찍히지 않습니다.

```bash
# control plane 에서 스크립트 내려받기
wget https://eu4ng.github.io/assets/scripts/iot/ha-registry.py
```

<details markdown="1">
<summary>ha-registry.py 전문</summary>

```python
# Home Assistant 엔티티·방 레지스트리를 WebSocket API 로 정리합니다. aiohttp 가 있는 HA 파드 안에서 실행합니다.
#   kubectl -n home-assistant exec -i <HA 파드> -c home-assistant -- env HA_TOKEN=<토큰> python3 - <작업> [--dry-run] < scripts/ha-registry.py
# 토큰은 대상 HA 의 장기 액세스 토큰(관리자)입니다. HA_TOKEN 이 없으면 입력받습니다. 저장소·파일에 남기지 않습니다.
#
# 작업(여러 개 가능):
#   --enable-platform <플랫폼>   통합이 꺼 둔(disabled_by=integration) 엔티티를 켭니다. 사용자가 끈 것(user)은 두고요. 예) mqtt
#   --delete-empty-areas         기기·엔티티가 하나도 없는 방을 지웁니다 (중앙 HA 의 온보딩 기본 방)
#   --prune-remote-orphans       Remote Home Assistant 엔티티 중 원격에서 사라져 상태가 없는 것을 지웁니다 (지역에서 이름을 바꾼 잔재).
#                                연결된 엔티티가 하나도 없는 지역(지역 HA 가 내려감)은 건너뜁니다
#   --rename-ieee                엔티티 ID 가 IEEE 주소(0x…)로 남은 mqtt 엔티티를 기기 이름으로 바꿉니다
#                                예) sensor.0xa4c138f95fdbf3ad_linkquality → sensor.bedroom2_motion_linkquality. 기록은 HA 가 새 ID 로 옮깁니다
#   --rename-matter              matter 엔티티 ID 를 <기기 이름>_<측정 항목(device_class 등)> 영문으로 바꿉니다. 표시 이름(온도 등)은 그대로입니다
#                                예) sensor.cimsil2_bedroom2_air_quality_ondo → sensor.bedroom2_air_quality_temperature. 기록은 HA 가 새 ID 로 옮깁니다
#   --assign-areas               Zigbee·Matter 기기를 이름(<방>-<종류>[번호])의 방에 해당하는 영역으로 옮깁니다. 영역이 없으면 만듭니다
#                                예) bedroom2-th → 침실2 (방 코드는 영역 별칭으로 붙습니다). ROOMS 에 없는 방은 코드 그대로(garage)를 이름으로 씁니다
import asyncio, getpass, os, re, sys

import aiohttp

URL = os.environ.get("HA_URL", "ws://127.0.0.1:8123/api/websocket")

# --assign-areas 의 방 코드 → 영역 이름. 뒤에 붙은 번호는 그대로 이어 붙입니다 (bedroom2 → 침실2)
ROOMS = {
    "livingroom": "거실", "kitchen": "주방", "bedroom": "침실", "room": "방", "office": "서재", "bathroom": "욕실",
    "laundry": "세탁실", "dressroom": "드레스룸", "utility": "다용도실", "entrance": "현관", "balcony": "베란다",
}


async def main(args):
    dry = "--dry-run" in args
    token = os.environ.get("HA_TOKEN") or getpass.getpass("HA 장기 액세스 토큰: ")
    async with aiohttp.ClientSession() as s, s.ws_connect(URL) as ws:
        await ws.receive_json()
        await ws.send_json({"type": "auth", "access_token": token})
        if (await ws.receive_json())["type"] != "auth_ok":
            sys.exit("인증 실패: 토큰을 확인하세요")
        n = 0

        async def call(**msg):
            nonlocal n
            n += 1
            await ws.send_json({"id": n, **msg})
            while True:
                r = await ws.receive_json()
                if r.get("id") == n:
                    if not r["success"]:
                        raise RuntimeError(f"{msg['type']}: {r['error']}")
                    return r["result"]

        ents = await call(type="config/entity_registry/list")
        tag = "[dry-run] " if dry else ""

        if "--enable-platform" in args:
            plat = args[args.index("--enable-platform") + 1]
            for e in ents:
                if e["platform"] == plat and e["disabled_by"] == "integration":
                    print(f"{tag}활성화 {e['entity_id']}")
                    if not dry:
                        await call(type="config/entity_registry/update", entity_id=e["entity_id"], disabled_by=None)

        if "--delete-empty-areas" in args:
            devs = await call(type="config/device_registry/list")
            used = {e["area_id"] for e in ents} | {d["area_id"] for d in devs}
            for a in await call(type="config/area_registry/list"):
                if a["area_id"] not in used:
                    print(f"{tag}방 삭제 {a['name']} ({a['area_id']})")
                    if not dry:
                        await call(type="config/area_registry/delete", area_id=a["area_id"])

        if "--rename-ieee" in args:
            devs = {d["id"]: d.get("name_by_user") or d.get("name") for d in await call(type="config/device_registry/list")}
            taken = {e["entity_id"] for e in ents}
            for e in ents:
                domain, obj = e["entity_id"].split(".", 1)
                m = re.match(r"0x[0-9a-f]{16}(_.+)?$", obj)
                name = devs.get(e["device_id"])
                if e["platform"] != "mqtt" or not m or not name:
                    continue
                new = f"{domain}.{re.sub(r'[^a-z0-9]+', '_', name.lower()).strip('_')}{m.group(1) or ''}"
                if new in taken:
                    print(f"건너뜀 {e['entity_id']}: {new} 가 이미 있습니다")
                    continue
                print(f"{tag}이름 변경 {e['entity_id']} → {new}")
                if not dry:
                    await call(type="config/entity_registry/update", entity_id=e["entity_id"], new_entity_id=new)
                taken.add(new)

        if "--rename-matter" in args:
            # 한국어 HA 는 엔티티 이름(온도)을 로마자(ondo)로, 방 이름까지 붙여 ID 를 만듭니다. 방은 기기 이름(<방>-<종류>)에 이미 있습니다
            devs = {d["id"]: d.get("name_by_user") or d.get("name") for d in await call(type="config/device_registry/list")}
            ids = [e["entity_id"] for e in ents if e["platform"] == "matter"]
            full = await call(type="config/entity_registry/get_entries", entity_ids=ids) if ids else {}
            taken = {e["entity_id"] for e in ents}
            slug = lambda s: re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")
            for eid, e in full.items():
                name = devs.get(e and e["device_id"])
                if not name:
                    continue
                # 측정 항목: device_class(enum 같은 일반 값 제외) → translation_key → 영문 원래 이름
                dc = e.get("original_device_class")
                on = e.get("original_name") or ""
                what = (dc if dc and dc != "enum" else None) or e.get("translation_key") or (slug(on) if on.isascii() else "")
                if not what:
                    print(f"건너뜀 {eid}: 측정 항목을 알 수 없습니다")
                    continue
                new = f"{eid.split('.', 1)[0]}.{slug(name)}_{what}"
                if new == eid:
                    continue
                if new in taken:
                    print(f"건너뜀 {eid}: {new} 가 이미 있습니다")
                    continue
                print(f"{tag}이름 변경 {eid} → {new}")
                if not dry:
                    await call(type="config/entity_registry/update", entity_id=eid, new_entity_id=new)
                taken.add(new)

        if "--assign-areas" in args:
            # 방은 기기 이름의 첫 - 앞입니다. 이름이 원본이므로 손으로 고른 영역도 이름에 맞춰 바꿉니다
            areas = await call(type="config/area_registry/list")
            label = {a["area_id"]: a["name"] for a in areas}
            find = {k: a["area_id"] for a in areas for k in [a["area_id"], a["name"], *a.get("aliases", [])]}
            for d in await call(type="config/device_registry/list"):
                # 이름 규칙은 Zigbee2MQTT(mqtt)·Matter 기기에만 있습니다. 휴대폰(mobile_app) 등은 건너뜁니다
                if not {i[0] for i in d["identifiers"]} & {"mqtt", "matter"}:
                    continue
                name = d.get("name_by_user") or d.get("name") or ""
                m = re.match(r"([a-z0-9]+)-", name)
                if not m or m.group(1) == "retired":
                    continue
                room = m.group(1)
                r = re.fullmatch(r"([a-z]+)(\d*)", room)
                want = ROOMS[r.group(1)] + r.group(2) if r and r.group(1) in ROOMS else room
                aid = find.get(room) or find.get(want)
                if not aid:
                    print(f"{tag}영역 생성 {want} (별칭 {room})")
                    a = {"area_id": want, "name": want} if dry else await call(type="config/area_registry/create", name=want, aliases=[room])
                    aid = find[room] = find[want] = a["area_id"]
                    label[aid] = a["name"]
                if d["area_id"] == aid:
                    continue
                print(f"{tag}영역 지정 {name}: {label.get(d['area_id'], '없음')} → {label[aid]}")
                if not dry:
                    await call(type="config/device_registry/update", device_id=d["id"], area_id=aid)

        if "--prune-remote-orphans" in args:
            # 통합이 더는 제공하지 않는 엔티티는 상태가 없거나, HA 가 자리만 채운 restored 상태(unavailable)로 남습니다
            live = {st["entity_id"] for st in await call(type="get_states") if not st["attributes"].get("restored")}
            # 지역 HA 가 내려가 있으면 그 지역 엔티티가 모두 상태 없음으로 보이므로, 살아 있는 엔티티가 하나도 없는 지역은 건너뜁니다
            up = {e["config_entry_id"] for e in ents if e["platform"] == "remote_homeassistant" and e["entity_id"] in live}
            for e in ents:
                if e["platform"] != "remote_homeassistant" or e["entity_id"] in live:
                    continue
                if e["config_entry_id"] not in up:
                    print(f"건너뜀 {e['entity_id']}: 이 지역에 연결된 엔티티가 없습니다(지역 HA 가 내려가 있을 수 있음)")
                else:
                    print(f"{tag}엔티티 삭제 {e['entity_id']}")
                    if not dry:
                        await call(type="config/entity_registry/remove", entity_id=e["entity_id"])


asyncio.run(main(sys.argv[1:]))
```
{: file="ha-registry.py" }

</details>

```bash
# control plane. 중앙 HA: 먼저 --dry-run 으로 대상을 확인하고, 괜찮으면 빼고 다시 실행합니다
T=$(kubectl -n home-assistant get secret ha-api-token -o jsonpath='{.data.token}' | base64 -d)
kubectl -n home-assistant exec -i deploy/home-assistant -c home-assistant -- \
  env HA_TOKEN="$T" python3 - --delete-empty-areas --prune-remote-orphans --dry-run < ha-registry.py
unset T
```

지역 HA 에서는 Zigbee2MQTT 가 꺼 둔 채 등록한 진단 엔티티(LQI 등)를 켜고, 페어링 직후 IEEE 주소(`0x…`)로 잡힌 엔티티 ID 를 기기 이름으로 바꿉니다. Matter 기기는 한국어 HA 가 엔티티 이름(`온도`)을 로마자로 옮기고 방 이름까지 붙여 `sensor.cimsil2_bedroom2_air_quality_ondo` 같은 ID 를 만드므로, `--rename-matter` 로 `sensor.bedroom2_air_quality_temperature` 처럼 기기 이름과 측정 항목의 영문으로 바꿉니다. 표시 이름은 한국어 그대로이고, 허브 DB 의 `hass.device` 에는 바꾼 ID 가 들어갑니다. `--assign-areas` 는 Zigbee·Matter 기기를 이름의 방 부분(`bedroom2-th` 의 `bedroom2`)에 맞는 영역으로 옮깁니다. 방 코드는 스크립트의 `ROOMS` 로 한국어 영역 이름(`침실2`)이 되고, 그 영역이 없으면 방 코드를 별칭으로 붙여 새로 만듭니다. 그래서 기기를 추가하거나 다른 방으로 옮길 때는 이름만 바꾸고 이 명령을 실행하면 됩니다. 이름을 바꾸면 중앙에는 새 ID 가 올라오고 옛 ID 는 잔재가 되므로, 새 엔티티가 보인 뒤 위의 중앙 명령을 한 번 더 실행합니다.

```bash
# control plane. 지역 HA
K="kubectl --kubeconfig $HOME/k3s-[SITE].yaml -n home-assistant"
T=$($K get secret ha-api-token -o jsonpath='{.data.token}' | base64 -d)
$K exec -i deploy/home-assistant -c home-assistant -- \
  env HA_TOKEN="$T" python3 - --enable-platform mqtt --rename-ieee --rename-matter --assign-areas --dry-run < ha-registry.py
unset T
```

> 지역 HA 가 내려가 있으면 그 지역 엔티티가 모두 상태가 없는 것으로 보입니다. 이때 `--prune-remote-orphans` 가 전부 지우지 않도록, 연결된 엔티티가 하나도 없는 지역은 `건너뜀` 으로 표시하고 두게 했습니다. 이 표시가 나오면 지역 HA 가 다시 뜬 뒤 실행합니다.
{: .prompt-warning }

- **확인:** `--dry-run` 없이 실행한 출력에 `방 삭제`, `엔티티 삭제`, `활성화`, `이름 변경`, `영역 지정` 줄이 나오고, 다시 `--dry-run` 으로 실행하면 아무것도 나오지 않습니다.

## 8. 확인

```bash
# control plane. 중앙 HA 에 들어온 지역 엔티티
T=$(kubectl -n home-assistant get secret ha-api-token -o jsonpath='{.data.token}' | base64 -d)
curl -s -H "Authorization: Bearer $T" https://ha.[DOMAIN]/api/states \
  | python3 -c 'import sys, json; print(sorted(s["entity_id"] for s in json.load(sys.stdin) if ".[SITE_CODE]_" in s["entity_id"]))'
unset T
```

- **확인:** `binary_sensor.[SITE_CODE]_zigbee2mqtt_bridge_connection_state` 처럼 접두사가 붙은 지역 엔티티가 나옵니다. 중앙 화면에서 지역 스위치를 켜면 지역 HA 에서도 같은 엔티티가 켜집니다.
- **확인:** 지역 HA 를 재시작하면(`kubectl --kubeconfig ~/k3s-[SITE].yaml -n home-assistant rollout restart deploy/home-assistant`) 중앙에서 그 지역 엔티티가 사라졌다가, 지역 HA 가 다시 뜨면 곧 돌아옵니다. 지역 HA 는 중앙 HA 와 상관없이 기기와 자동화를 계속 처리합니다.

## 트러블슈팅

<details markdown="1">
<summary><code>400: Bad Request</code> — 온보딩 전에 ha.[DOMAIN] 을 열 때</summary>

- **원인:** 중앙 HA 가 아직 Traefik 에서 온 요청(`X-Forwarded-For` 포함)을 신뢰하지 않습니다. HA 2026 에서는 `configuration.yaml` 의 `http:` 블록이 무시되고 HTTP 설정을 내부 저장소에서 관리합니다.
- **해결:** 온보딩은 3단계처럼 포트 포워딩으로 하고, 4단계 스크립트가 API 로 `trusted_proxies` 를 넣게 합니다.

</details>

<details markdown="1">
<summary><code>Login attempt or request with invalid authentication from 172.69.…</code> — 로그의 접속자가 Cloudflare 주소일 때</summary>

- **원인:** HA 가 앞단 Traefik 만 신뢰하고 그 앞의 Cloudflare 는 신뢰하지 않아, `X-Forwarded-For` 를 따라가다 Cloudflare 주소에서 멈춥니다. 이 상태에서는 로그인 실패 차단이 실제 접속자가 아니라 Cloudflare 주소에 걸려, 같은 Cloudflare 경로로 들어오는 다른 접속까지 막힐 수 있습니다.
- **해결:** `TRUSTED_PROXIES` 에 스크립트의 `$CLOUDFLARE_IPV4` 를 함께 넣고 다시 실행합니다. 이후 로그에는 접속자의 공인 IP 가 찍힙니다.

</details>

<details markdown="1">
<summary>기록의 대상 추가 > 기기 에 지역 HA 이름 하나만 보이고 지역의 기기·방이 없을 때</summary>

- **원인:** Remote Home Assistant 는 지역 HA 의 엔티티 상태만 복제합니다. 기기와 방은 가져오지 않고, 지역 HA 전체를 나타내는 기기 하나만 중앙에 만듭니다.
- **해결:** 방 단위 기록은 6단계의 지역 대시보드에서 봅니다. 기록 화면에서는 **대상 추가 > 엔티티** 를 고르고 `[SITE_CODE]_` 나 지역 이름으로 검색합니다.

</details>

## 마무리

허브에 기기 없는 중앙 HA 를 두고 Remote Home Assistant 로 지역 HA 의 엔티티를 모아, `ha.[DOMAIN]` 한 곳에서 모든 지역을 보고 제어하게 했습니다. 기기와 자동화는 계속 지역 HA 가 맡으므로 중앙 HA 가 멈추거나 지역의 인터넷이 끊겨도 지역은 그대로 동작하고, 중앙에서는 연결이 끊긴 지역의 엔티티만 빠집니다. 사이드바의 **지역** 대시보드는 기기 이름 규칙으로 방을 자동으로 나눠, 지역·방별 현재 값과 기록을 따로 손대지 않고 보여 줍니다. 새 지역은 1단계 매니페스트를 그 지역 폴더에 두고 `REMOTES` 에 한 줄을 더해 스크립트를 다시 실행하면 붙습니다.

## 참고 자료

- [custom-components/remote_homeassistant](https://github.com/custom-components/remote_homeassistant)
- [Home Assistant - HTTP](https://www.home-assistant.io/integrations/http/)
- [Home Assistant - Multi-factor authentication](https://www.home-assistant.io/docs/authentication/multi-factor-auth/)
- [Home Assistant - Authentication API](https://developers.home-assistant.io/docs/auth_api/)
- [Home Assistant - Dashboards (YAML mode)](https://www.home-assistant.io/dashboards/dashboards/)
- [Home Assistant - History graph card](https://www.home-assistant.io/dashboards/history-graph/)
- [Home Assistant - WebSocket API](https://developers.home-assistant.io/docs/api/websocket/)
- [thomasloven/lovelace-auto-entities](https://github.com/thomasloven/lovelace-auto-entities)
