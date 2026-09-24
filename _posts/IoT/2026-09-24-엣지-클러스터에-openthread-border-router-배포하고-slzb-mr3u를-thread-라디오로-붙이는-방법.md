---
layout: post
title: 엣지 클러스터에 OpenThread Border Router 배포하고 SLZB-MR3U를 Thread 라디오로 붙이는 방법
description: SLZB-MR3U 의 Thread 라디오를 네트워크 RCP 로 두고, 공식 OpenThread Border Router 이미지에 socat 을 얹어 엣지 쿠버네티스 파드로 띄운 뒤, Home Assistant 에 연결해 Thread 망을 만들고 라디오를 바꿔도 망이 유지되게 하는 방법을 정리했습니다.
author: Eu4ng
tags: [iot, thread, matter, openthread, otbr, slzb-06, home-assistant, kubernetes, argo-cd, gitops, edge]
permalink: /posts/47/
---

Thread 기기(Matter over Thread)를 LAN 과 잇는 **OpenThread Border Router**(OTBR)를 엣지 클러스터의 파드로 띄웁니다. 라디오는 SLZB-MR3U 의 EFR32MG24 로, 기기 안에서 OTBR 을 돌리는 대신 라디오(RCP)로만 쓰고 TCP 포트로 파드와 연결합니다. 이렇게 하면 Thread 망의 데이터셋(네트워크 키, 채널 등)이 기기가 아니라 클러스터 볼륨에 남아서, SLZB 를 바꾸더라도 새 기기를 같은 주소에 두기만 하면 기기를 다시 등록하지 않고 망이 이어집니다. 공식 OTBR 이미지는 USB 시리얼 라디오를 전제로 해서, OpenThread 가 자식 프로세스를 시리얼처럼 쓰는 `forkpty` 방식으로 socat 을 띄워 TCP 를 연결합니다.

1. 라디오 모드와 포트 확인
2. OTBR 이미지 만들기
3. 엣지 베이스와 지역 오버레이
4. Home Assistant 에 연결해 Thread 망 만들기
5. 확인과 교체 드릴

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| 엣지 Kubernetes | `v1.36` (k3s) |
| OpenThread Border Router | `openthread/border-router:sha-9802eb8` (Thread 1.4) |
| 라디오 | `SLZB-MR3U` EFR32MG24, RCP 펌웨어 `SL-OPENTHREAD/2.7.2.0` |
| Home Assistant | `2026.9.3` |
| 작성 기준일 | `2026-09-24` |

다음 항목이 준비되어 있어야 합니다.

- IPv6 포워딩과 `tun` 모듈이 설정된 엣지 노드 ([Proxmox에 Ansible로 k3s 엣지 클러스터 만들고 Argo CD 원격 클러스터로 등록하는 방법](/posts/42/)의 플레이북이 넣습니다)
- 라디오 하나가 "Thread to remote OTBR" 모드인 SLZB-MR3U ([SLZB-MR3U 초기 설정하고 Zigbee와 Thread 라디오 모드 나누는 방법](/posts/45/))
- 엣지 클러스터의 Home Assistant 와 통합 설정 스크립트 ([엣지 클러스터에 Home Assistant와 Matter 서버 배포하고 API로 통합 설정하는 방법](/posts/48/))
- GHCR 비공개 이미지를 받을 pull Secret(`ghcr-pull`) 과 이미지를 빌드할 GitHub Actions

## 1. 라디오 모드와 포트 확인

Thread 라디오가 RCP 모드인지 기기 정보 API 로 확인합니다. `zb_type` 이 `2` 이면 Thread RCP 입니다(0 은 Zigbee 코디네이터, 8 은 기기 안에서 OTBR 을 돌리는 모드).

```bash
# 내 PC: 라디오별 모드와 펌웨어, Thread 라디오 포트
curl -s http://[SLZB_IP]/ha_info | python3 -c 'import sys,json; [print(r["chip_index"], r["zb_hw"], "type", r["zb_type"], "fw", r["zb_version"]) for r in json.load(sys.stdin)["Info"]["radios"]]'
nc -zv [SLZB_IP] 6638
```

- **확인:** Thread 라디오 줄이 `type 2`, 포트 6638 이 열려 있습니다. 이 포트는 클라이언트 하나만 받으므로 다른 OTBR 이 붙어 있으면 안 됩니다.

## 2. OTBR 이미지 만들기

공식 이미지는 `OT_RCP_DEVICE` 환경 변수를 라디오 주소(RadioURL)로 씁니다. 라디오가 USB 가 아니므로 `spinel+hdlc+forkpty://` 로 socat 을 띄워 TCP 를 시리얼처럼 연결하는데, 공식 이미지에 socat 이 없어 한 줄을 얹은 이미지를 만듭니다. 태그는 공식 이미지 태그를 그대로 씁니다.

```dockerfile
# OpenThread Border Router 공식 이미지에 socat 만 얹은 이미지. 라디오(RCP)가 USB 가 아니라 네트워크(SLZB 의 TCP 포트)에 있을 때 씁니다.
# OpenThread 의 RadioURL spinel+hdlc+forkpty:// 가 socat 을 자식 프로세스로 띄워 TCP 를 시리얼처럼 쓰므로 엔트리포인트는 그대로입니다.
# 태그는 아래 OTBR_TAG 를 씁니다 (.github/workflows/build-otbr.yml). 공식 이미지는 커밋마다 sha-<7자리> 태그로 게시됩니다.
ARG OTBR_TAG=sha-9802eb8
FROM openthread/border-router:${OTBR_TAG}
RUN apt-get update \
    && apt-get install -y --no-install-recommends socat \
    && rm -rf /var/lib/apt/lists/*
```
{: file="images/otbr/Dockerfile" }

{% raw %}
```yaml
name: build-otbr

on:
  push:
    branches: [main]
    paths: [images/otbr/**]
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # 이미지 이름은 소문자여야 하고, 태그는 Dockerfile 의 공식 OTBR 이미지 태그를 그대로 씁니다.
      - name: 이미지 이름과 태그 정하기
        id: meta
        run: |
          owner=$(echo "${{ github.repository_owner }}" | tr '[:upper:]' '[:lower:]')
          tag=$(sed -n 's/^ARG OTBR_TAG=//p' images/otbr/Dockerfile)
          echo "image=ghcr.io/$owner/otbr:$tag" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/build-push-action@v6
        with:
          context: images/otbr
          push: true
          tags: ${{ steps.meta.outputs.image }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```
{: file=".github/workflows/build-otbr.yml" }
{% endraw %}

```bash
# 커밋하고 push → Actions 가 ghcr.io/[OWNER]/otbr:sha-9802eb8 로 빌드
git add images/otbr .github/workflows/build-otbr.yml
git commit -m "feat(iot): 네트워크 RCP 용 OpenThread Border Router 이미지 추가"
git push
```

- **확인:** `gh run list --workflow build-otbr --limit 1` 이 `completed success` 이고, GitHub 의 **Packages** 에 `otbr` 이 보입니다.

## 3. 엣지 베이스와 지역 오버레이

OTBR 은 노드에 `wpan0` 인터페이스를 만들고 LAN 쪽(`eth0`)으로 Thread 망 경로를 광고해야 하므로 `hostNetwork` 와 `privileged` 로 띄웁니다. 호스트의 ip6tables 에 Thread 망 필터 규칙도 넣습니다. 데이터셋과 기기 등록 정보는 `/data`(볼륨)에 남습니다. REST API(8081)는 Home Assistant 가 붙도록 모든 주소에서 열고, 웹 화면(8080)은 노드 안에서만 엽니다.

```yaml
# 엣지의 Thread 보더 라우터(OpenThread Border Router). SLZB 의 Thread 라디오(RCP, TCP 포트)에 socat 으로 붙습니다.
# Thread 망의 데이터셋·SRP 등록·라우터 상태가 PVC 에 남으므로 라디오를 교체해도 기기 재커미셔닝이 없습니다.
# 라디오 주소는 오버레이(iot/clusters/<지역>/otbr/)가 OT_RCP_DEVICE 로 넣습니다.
resources:
  - deployment.yaml
  - pvc.yaml
```
{: file="iot/edge/otbr/kustomization.yaml" }

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otbr
spec:
  replicas: 1                # 라디오 포트는 클라이언트 하나만 받습니다
  strategy:
    type: Recreate
  selector:
    matchLabels: { app: otbr }
  template:
    metadata:
      labels: { app: otbr }
    spec:
      hostNetwork: true                    # wpan0 인터페이스를 노드에 만들고 eth0 로 RA 를 보내 LAN 이 Thread 망 경로를 배우게 합니다
      dnsPolicy: ClusterFirstWithHostNet
      imagePullSecrets:
        - name: ghcr-pull                  # 비공개 GHCR 패키지. kubectl create secret docker-registry 로 미리 만듭니다 (허브의 것과 같은 토큰)
      containers:
        - name: otbr
          image: ghcr.io/eu4ng/otbr:sha-9802eb8   # images/otbr (공식 openthread/border-router + socat)
          securityContext:
            privileged: true               # TUN 장치, ip6tables/ipset 규칙, 커널 라우팅 설정이 필요합니다
          env:
            - { name: OT_INFRA_IF, value: eth0 }           # 노드의 LAN 인터페이스 (기본값은 wlan0)
            - { name: OT_THREAD_IF, value: wpan0 }
            - { name: OT_REST_LISTEN_ADDR, value: "0.0.0.0" }   # HA 의 OTBR 통합과 확인용 curl 이 노드 IP:8081 로 붙습니다
            - { name: OT_REST_LISTEN_PORT, value: "8081" }
            - { name: OT_WEB_LISTEN_ADDR, value: "127.0.0.1" }  # 웹 UI(8080)는 노드 안에서만
            - { name: OT_LOG_LEVEL, value: "5" }               # 5 = notice. 기본 7(debug) 은 너무 많습니다
            # 지역 오버레이가 아래 값을 바꿉니다. socat 이 TCP 를 시리얼처럼 이어 주고, 끊기면 종료되어 파드가 다시 뜹니다.
            - { name: OT_RCP_DEVICE, value: "spinel+hdlc+forkpty:///usr/bin/socat?forkpty-arg=-&forkpty-arg=tcp:127.0.0.1:6638" }
          ports:
            - { containerPort: 8081 }
          volumeMounts:
            - { name: data, mountPath: /data }                 # 이미지가 /data/thread 를 /var/lib/thread 로 링크합니다
            - { name: tun, mountPath: /dev/net/tun }
          startupProbe:
            httpGet: { path: /node/state, port: 8081 }
            periodSeconds: 5
            failureThreshold: 60
          readinessProbe:
            httpGet: { path: /node/state, port: 8081 }
            periodSeconds: 10
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: otbr-data }
        - name: tun
          hostPath: { path: /dev/net/tun, type: CharDevice }
```
{: file="iot/edge/otbr/deployment.yaml" }

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: otbr-data
  annotations:
    argocd.argoproj.io/sync-options: Prune=false   # Thread 네트워크 데이터셋(키·PAN ID·채널)과 SRP 등록. 잃으면 Thread 기기를 전부 다시 커미셔닝해야 합니다
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
```
{: file="iot/edge/otbr/pvc.yaml" }

지역 오버레이는 라디오 주소만 바꿉니다.

```yaml
# 지역 엣지의 Thread 보더 라우터. 라디오는 SLZB-MR3U 의 EFR32MG24("Thread to remote OTBR" 모드, 포트 6638).
resources:
  - ../../../edge/otbr
patches:
  - patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: otbr
      spec:
        template:
          spec:
            containers:
              - name: otbr
                env:
                  - { name: OT_RCP_DEVICE, value: "spinel+hdlc+forkpty:///usr/bin/socat?forkpty-arg=-&forkpty-arg=tcp:[SLZB_IP]:6638" }
```
{: file="iot/clusters/[SITE]/otbr/kustomization.yaml" }

이미지가 비공개라 엣지의 `otbr` 네임스페이스에도 pull Secret 이 필요합니다. 허브에 있는 것을 그대로 복사합니다.

```bash
# control plane: 허브의 ghcr-pull 을 엣지 otbr 네임스페이스로 복사
E="--kubeconfig ~/k3s-[SITE].yaml"
kubectl $E create namespace otbr --dry-run=client -o yaml | kubectl $E apply -f -
kubectl -n mineru get secret ghcr-pull -o json \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps({"apiVersion":"v1","kind":"Secret","type":d["type"],"metadata":{"name":"ghcr-pull","namespace":"otbr"},"data":d["data"]}))' \
  | kubectl $E apply -f -

# 커밋하고 push
git add iot/edge/otbr iot/clusters/[SITE]/otbr
git commit -m "feat(iot): 엣지에 OpenThread Border Router 추가"
git push
```

- **확인:** Argo CD 의 `[SITE]-otbr` 가 `Synced`, `Healthy`. 파드 로그에 `Radio URL: spinel+hdlc+forkpty:///usr/bin/socat?…` 와 `RCP => … Reset info` 가 보이면 라디오와 통신한 것입니다. `curl http://[EDGE_IP]:8081/node/state` 는 아직 데이터셋이 없어 `"disabled"` 입니다.

```bash
# 라디오 펌웨어 버전 (RCP 와 통신하는지)
kubectl $E -n otbr exec deploy/otbr -- ot-ctl rcp version
```

## 4. Home Assistant 에 연결해 Thread 망 만들기

HA 의 OpenThread Border Router 통합을 추가하면, 데이터셋이 없는 OTBR 에 HA 가 새 Thread 망(`ha-thread-xxxx`)을 만들어 넣고 켭니다. [통합 설정 스크립트](/posts/48/)가 이 통합을 추가하고 HA 의 **기본 Thread 네트워크**로 지정까지 하므로, 스크립트의 `OTBR_URL` 을 `http://127.0.0.1:8081`(HA 와 OTBR 모두 호스트 네트워크) 로 두고 다시 실행합니다. 이미 된 단계는 건너뜁니다.

```bash
# control plane
bash setup-home-assistant.sh http://[EDGE_IP]:8123
```

기본 네트워크 지정이 중요합니다. 휴대폰의 Home Assistant 앱으로 Thread 기기를 등록할 때 앱이 HA 의 기본 Thread 망 자격 증명을 받아 기기에 넘기기 때문입니다. 집에 다른 제조사의 Thread 보더 라우터(스마트 TV, 스피커 등)가 있어도 망이 다르면 서로 간섭하지 않습니다.

- **확인:** 스크립트 출력에 `otbr: 추가됨`, `Thread: ha-thread-xxxx (채널 15) 을 기본 네트워크로 지정` 이 보이고, `curl http://[EDGE_IP]:8081/node/state` 가 `"leader"` 입니다.

## 5. 확인과 교체 드릴

```bash
# 엣지 노드: Thread 인터페이스와 LAN 에 광고된 경로
ip -br addr show wpan0
ip -6 route | grep wpan0

# 데이터셋 (16진수 TLV)
curl -s -H 'Accept: text/plain' http://[EDGE_IP]:8081/node/dataset/active
```

- **확인:** `wpan0` 에 `fd..` 로 시작하는 Thread 망 주소들이 보이고 경로 표에 `dev wpan0` 경로가 있습니다. 데이터셋이 출력됩니다. Zigbee 와 같은 2.4GHz 를 쓰므로 채널이 겹치지 않는지 봅니다. 이 글의 구성은 Thread 15, Zigbee 25 입니다.

OTBR 파드를 지워 새로 뜨게 하고 같은 망으로 돌아오는지 봅니다. 볼륨의 데이터셋을 다시 쓰므로 리더로 복귀해야 합니다.

```bash
# 교체 드릴: 파드 삭제 → 재생성 → 같은 데이터셋으로 leader 복귀
before=$(curl -s -H 'Accept: text/plain' http://[EDGE_IP]:8081/node/dataset/active)
kubectl $E -n otbr delete pod -l app=otbr
kubectl $E -n otbr rollout status deploy/otbr
sleep 20; curl -s http://[EDGE_IP]:8081/node/state
[ "$before" = "$(curl -s -H 'Accept: text/plain' http://[EDGE_IP]:8081/node/dataset/active)" ] && echo "데이터셋 같음"
```

- **확인:** 이 글을 쓰며 실행했을 때 약 15초 만에 `"leader"` 로 돌아왔고 데이터셋이 같았습니다. SLZB 를 새 기기로 바꿀 때도 같은 원리로, 새 기기를 "Thread to remote OTBR" 모드로 같은 주소에 두면 OTBR 이 볼륨의 데이터셋으로 망을 다시 엽니다.

## 트러블슈팅

<details markdown="1">
<summary><code>Init() at spinel_driver.cpp:87: Failure</code></summary>

```text
[C] Platform------: Init() at spinel_driver.cpp:87: Failure
otbr-agent exited with code 1
```

- **원인:** 라디오가 RCP 펌웨어가 아닙니다. 이 글을 쓰며 Zigbee 모드인 라디오에 붙였을 때 이 오류가 났습니다.
- **해결:** SLZB 웹 UI 의 **Mode** 에서 해당 라디오를 **Thread to remote OTBR** 로 바꾼 뒤 파드를 다시 띄웁니다. 1단계의 `zb_type` 이 `2` 인지 먼저 봅니다.

</details>

## 마무리

SLZB-MR3U 의 Thread 라디오를 RCP 로 두고 엣지 클러스터의 OTBR 파드로 Thread 망을 만들어, 데이터셋이 클러스터 볼륨에 남고 라디오를 바꿔도 망이 이어지는 보더 라우터를 구성했습니다. 이제 Home Assistant 앱으로 Matter over Thread 기기를 등록할 수 있습니다. 볼륨에는 Zigbee 네트워크 키, Matter 패브릭, Thread 데이터셋처럼 다시 만들 수 없는 상태가 모여 있으므로 원격 백업을 함께 두는 것이 좋습니다.

## 참고 자료

- [OpenThread - Border Router](https://openthread.io/guides/border-router)
- [openthread/ot-br-posix - Docker](https://github.com/openthread/ot-br-posix/tree/main/etc/docker/border-router)
- [OpenThread - POSIX platform (RadioURL)](https://github.com/openthread/openthread/blob/main/src/posix/README.md)
- [Home Assistant - OpenThread Border Router](https://www.home-assistant.io/integrations/otbr/)
- [Home Assistant - Thread](https://www.home-assistant.io/integrations/thread/)
- [SMLIGHT - Thread setup (network and USB connection)](https://smlight.tech/support/manuals/books/slzb-06xmrxmrxuultima-series/page/thread-setup-network-and-usb-connection)
