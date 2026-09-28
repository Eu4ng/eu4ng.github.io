---
layout: post
title: ipTIME C500GS 로컬 NVR 구축하고 전수 감지로 재실자 데이터 수집하는 방법
description: 외부 인터넷을 차단한 ipTIME C500GS 카메라로 엣지 쿠버네티스에서 무인코딩 녹화, YOLOv8 추적 검수 영상, Home Assistant 재실자 센서를 만드는 방법을 정리했습니다.
author: Eu4ng
tags: [iot, nvr, kubernetes, computer-vision, home-assistant, mqtt, timescaledb, argo-cd, gitops]
permalink: /posts/76/
---

ipTIME C500GS IP 카메라를 공유기 방화벽으로 외부 인터넷과 완전히 차단한 상태에서 로컬 NVR을 구축하고, 영상에서 재실자 수·위치·속도를 뽑아 호스트 센서와 같은 방식의 MQTT 센서로 Home Assistant 와 TimescaleDB 에 넣습니다. 움직임이 있을 때만 동작하는 모션 기반 감지기(Frigate 등)와 달리 초당 10프레임을 움직임과 무관하게 추적하므로, 잠든 사람처럼 오래 움직이지 않는 재실자도 놓치지 않습니다. 추적 결과는 초록 박스를 그린 검수 영상으로도 남겨 알고리즘이 제대로 동작하는지 눈으로 확인합니다.

1. 카메라 네트워크 차단 및 RTSP 설정
2. 워커 노드 NVR 전용 디스크 마운트
3. 방 기하 설정
4. NVR Secret 생성
5. NVR 서비스 및 수집기 GitOps 배포
6. 배포와 수집 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 / 사양 |
| :--- | :--- |
| IP 카메라 | ipTIME C500GS (5MP, H.265, Wi-Fi) |
| 엣지 Kubernetes | `v1.37` (kubeadm, k8s-dj-worker-1: 6 vCPU / 8GiB) |
| 스트리밍 중계기 | `alexxit/go2rtc:latest` |
| 수집기 / 딥러닝 | `ultralytics/ultralytics:latest-cpu` (YOLOv8n + ByteTrack, PyAV) |
| 시계열 DB | TimescaleDB `2.30.1-pg17` |
| 녹화 저장소 | Proxmox SCSI passthrough 디스크 500GB (`/mnt/nvr`) |
| 작성 기준일 | `2026-09-29` |

다음 항목이 준비되어 있어야 합니다.

- 공유기(ipTIME 등)에서 카메라 IP를 고정 할당하고 외부 인터넷 트래픽을 차단할 수 있는 환경
- 대전 엣지 클러스터, TimescaleDB, Home Assistant(MQTT 통합) ([지역 엣지에 TimescaleDB와 Grafana를 두어 인터넷 없이도 기록하고 보는 방법](/posts/56/))
- 엣지 Mosquitto 브로커와 Telegraf 파이프라인 ([엣지 Mosquitto와 Telegraf 디스크 버퍼로 중앙 TimescaleDB에 유실 없이 IoT 데이터 모으는 방법](/posts/43/))
- 서울 원격 NAS 와 연결된 Tailscale 사설망

## 1. 카메라 네트워크 차단 및 RTSP 설정

카메라 초기 설정은 모바일 앱으로 Wi-Fi를 연결한 뒤 진행합니다. 설정이 끝나면 앱이나 외부 클라우드를 통한 영상 유출을 방지하기 위해 공유기에서 카메라를 인터넷과 격리합니다.

공유기 설정 페이지(**고급 설정** > **네트워크 관리** > **DHCP 서버 설정**)에서 카메라 MAC 주소를 확인하고 IP(예: `192.168.0.40`)를 수동 고정 등록합니다.

그 다음 **보안 기능** > **인터넷/WiFi 사용제한**에서 규칙을 추가합니다:
- **제약 방향**: 내부 <-> 외부 전체 차단
- **내부 IP**: `192.168.0.40`
- **외부 IP / 포트**: 전체 범위

카메라 앱 설정에서 **RTSP/ONVIF** 기능을 켜고 사용자 이름(`admin`)과 RTSP 비밀번호를 지정합니다. 이 카메라는 Digest 인증(realm `HIipCamera`)을 사용하며 주 스트림(`/onvif1`)은 5MP(2880x1620, H.265 20fps), 보조 스트림(`/onvif2`)은 360p(640x360, H.265 20fps)를 제공합니다.

- **확인:** LAN 안의 PC에서 RTSP 요청을 보냈을 때 Digest 401 응답과 정상 인증이 이루어지는지 확인합니다.

```bash
# LAN 안의 PC에서 RTSP 포트 응답 확인
nc -zv 192.168.0.40 554
```

## 2. 워커 노드 NVR 전용 디스크 마운트

영상 녹화 데이터가 시스템 디스크나 Longhorn 분산 스토리지에 부담을 주지 않도록, Proxmox VM에 500GB SCSI 디스크를 추가하고 `/mnt/nvr`에 마운트합니다.

Ansible 인벤토리 `proxmox-ansible`의 `group_vars/all.yml`에서 워커 노드 사양을 증설하고 전용 디스크를 정의합니다:

{% raw %}
```yaml
# group_vars/all.yml
- { name: k8s-dj-worker-1, pve: pve01, role: worker, vmid: 133, ip: 192.168.0.133, cores: 6, memory: 8192, disk: 40G, longhorn_disk: 20, nvr_disk: 500 }
```
{: file="group_vars/all.yml" }
{% endraw %}

`playbooks/k8s-cluster.yml`의 NVR 디스크 생성 및 포맷·마운트 태스크를 거쳐 실행합니다:

```bash
ansible-playbook playbooks/k8s-cluster.yml -e k8s_cluster=daejeon
```

- **확인:** 워커 노드에서 `/mnt/nvr` 마운트와 용량을 확인합니다.

```bash
ssh ubuntu@192.168.0.133 "df -h /mnt/nvr"
```

## 3. 방 기하 설정

원본(raw)은 녹화 영상이고, 재실자 값은 모두 영상에서 계산한 값(derived)입니다. 위치는 사람 박스 아래 가운데(발 위치)의 화면 비율 좌표(`u`, `v`, 왼쪽 위 0 ~ 오른쪽 아래 1)와, 이를 방 바닥 좌표(m)·속도(m/s)로 바꾼 값 두 가지로 남깁니다. 화면 좌표와 녹화 원본이 남으므로 기하 설정이나 알고리즘을 바꾸면 다시 계산할 수 있습니다.

계산에는 화면 속 바닥 기준점 4개 이상이 필요합니다. 카메라 프레임을 한 장 뽑아 방 모서리, 침대 다리, 문틀 아래처럼 바닥에 닿은 점을 고르고, 그 점의 화면 비율 좌표와 줄자로 잰 방 바닥 좌표를 짝지어 적습니다.

```bash
# 카메라 프레임 한 장을 이미지로 저장
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl --kubeconfig ~/k8s-daejeon.yaml -n nvr exec deploy/nvr -c recorder -- ffmpeg -v error -rtsp_transport tcp -i rtsp://localhost:8554/main -frames:v 1 -f image2 -c:v mjpeg pipe:1" > frame.jpg
```

```json
{
  "room": "bedroom2",
  "width_m": [ROOM_WIDTH_M],
  "depth_m": [ROOM_DEPTH_M],
  "origin": "[원점 모서리와 x·y 축 방향 설명]",
  "camera": {"x_m": [CAMERA_X_M], "y_m": [CAMERA_Y_M], "height_m": [CAMERA_HEIGHT_M]},
  "points": [
    {"label": "[기준점 이름]", "image": [[U], [V]], "floor": [[X_M], [Y_M]]}
  ]
}
```
{: file="iot/edge/nvr/room-geometry.json" }

수집기는 기준점으로 최소제곱 호모그래피를 구하고 로그에 기준점별 재투영 오차(m)를 남깁니다. 기준점이 4개보다 적으면 계산값을 내지 않습니다.

> 발 위치가 바닥에 있다고 보는 계산이라 침대에 누워 있거나 의자에 앉은 사람은 실제 위치와 어긋납니다. 카메라 가까이 서서 박스 아래가 화면 끝에 닿으면 발이 보이지 않으므로 계산값을 내지 않습니다.
{: .prompt-warning }

- **확인:** 배포 후 수집기 로그에 `방 기하 반영, 기준점 재투영 오차(m)` 가 나오고 오차가 작은지 확인합니다.

## 4. NVR Secret 생성

카메라 RTSP 비밀번호, MQTT 인증 비밀번호, 서울 NAS rsync용 SSH 키를 담은 Secret을 엣지 클러스터 `nvr` 네임스페이스에 생성합니다. 수집기는 DB 에 직접 쓰지 않으므로 DB 비밀번호는 넣지 않습니다.

```bash
# 허브 control plane 에서 실행
bash assets/scripts/iot/create-nvr-secrets.sh ~/k8s-daejeon.yaml
```

<details markdown="1">
<summary><code>create-nvr-secrets.sh</code> 전문</summary>

```bash
#!/usr/bin/env bash
#
# NVR(go2rtc, recorder, occupancy 수집기, archive)이 쓰는 Secret(nvr/nvr-credentials, nvr/backup-ssh)을 엣지 클러스터에 만듭니다.
# GitOps 저장소에는 비밀 값을 넣지 않으므로 매니페스트를 push 하기 전에 실행합니다.
# 허브에 kubectl 로 접근할 수 있고 엣지 kubeconfig 가 있는 곳(control plane)에서 실행합니다: bash create-nvr-secrets.sh [EDGE_KUBECONFIG]
# 카메라 RTSP 비밀번호는 환경 변수 CAMERA_RTSP_PASSWORD 가 있으면 그것을, 없으면 실행 중에 입력받습니다.
# MQTT 비밀번호는 환경 변수 MQTT_PASSWORD 가 있으면 그것을, 없으면 엣지 telegraf-credentials 에서 가져옵니다.
# 수집기는 DB 에 직접 쓰지 않으므로(MQTT → Telegraf → readings) DB 비밀번호는 넣지 않습니다.
# NAS rsync 용 SSH 키(backup-ssh)는 엣지 backup 네임스페이스에서 복사합니다.

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
NAMESPACE=nvr
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

log "완료"
```
{: file="assets/scripts/iot/create-nvr-secrets.sh" }
</details>

- **확인:** 엣지 클러스터 `nvr` 네임스페이스에 Secret 2개가 있는지 확인합니다.

```bash
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl --kubeconfig ~/k8s-daejeon.yaml -n nvr get secrets"
```

## 5. NVR 서비스 및 수집기 GitOps 배포

NVR 파드는 한 파드 안에 세 가지 컨테이너가 협력하는 구조입니다:
1. **`go2rtc`**: 카메라에 RTSP 세션을 딱 1개만 맺고, 로컬 `:8554`로 스트림을 분배합니다. 저가형 IP 카메라의 동시 연결 수 한계 문제를 원천 차단합니다.
2. **`recorder`**: `ffmpeg`를 사용해 `rtsp://localhost:8554/main` 스트림을 재인코딩 없이 10분 단위 조각으로 저장합니다 (`/mnt/nvr/rec/%Y-%m-%d/%H-%M-%S.mp4`).
3. **`occupancy`**: 주 스트림(5MP 20fps)을 PyAV 로 디코딩해 초당 10프레임을 1280x720 으로 받아 YOLOv8n + ByteTrack 으로 추적합니다.
   - 사람마다 칸(`occupant1`, `occupant2` …)을 배정하고 1초마다 `nvr/bedroom2-camera`(감지 결과)와 `nvr/bedroom2-camera/derived`(방 좌표로 바꾼 값)에 `{"fields": {...}, "timestamp": <ms>}` 를 발행합니다. Home Assistant 발견 설정도 함께 내므로 HA 에 기기 `bedroom2-camera` 와 센서가 자동으로 생기고, 엣지 Telegraf 가 같은 토픽을 받아 `readings` 에 넣습니다.
   - 칸은 동시에 감지된 최대 인원만큼 생기고, 사람이 없는 칸의 **감지** 센서는 `감지되지 않음` 이 됩니다.
   - 추적한 프레임마다 초록 박스와 칸·추적 ID·신뢰도·좌표·시각을 그린 **검수 영상**을 `/mnt/nvr/review/<날짜>/` 에 10분 조각으로 저장합니다.

GitOps 저장소(`k8s-gitops`)의 `iot/edge/nvr/`에 베이스 매니페스트와 스크립트를 두고, `iot/clusters/daejeon/nvr/`에 오버레이를 둡니다.

{% raw %}
```yaml
# iot/edge/nvr/go2rtc.yaml
log:
  level: info

api:
  listen: ":1984"

rtsp:
  listen: ":8554"

streams:
  main:
    - "rtsp://admin:${RTSP_PASSWORD}@192.168.0.40:554/onvif1"
```
{: file="iot/edge/nvr/go2rtc.yaml" }
{% endraw %}

발행 주기, 칸을 비우는 시간, 속도를 구하는 시간 창, 초당 추적 프레임 수는 `iot/edge/nvr/collector-settings.json` 에 둡니다. 이 파일과 `room-geometry.json` 은 이름에 해시를 붙이지 않은 ConfigMap 이라, 값을 고쳐 push 하면 파드가 재시작하지 않고(녹화가 끊기지 않고) 1~2분 뒤 수집기가 다시 읽습니다.

```json
{
  "publish_interval_s": 1.0,
  "slot_release_s": 10,
  "speed_window_s": 2.0,
  "track_fps": 10
}
```
{: file="iot/edge/nvr/collector-settings.json" }

매일 새벽 04:00에 실행되는 `nvr-daily-archive` CronJob 은 전일 10분 조각을 재인코딩 없이 녹화가 이어진 구간마다 하나로 합칩니다. 끊김 없는 날은 `00-00-00_24-00-00.mp4` 하나가 되고, 조각 사이가 5초 넘게 비면 그 자리에서 나뉘므로 파일 이름의 시각 사이가 녹화가 끊긴 구간입니다. 이미 합친 구간 파일도 다시 읽어 이어지는 조각과 합치므로, 녹화 중인 날을 `MERGE_ONLY=1` 로 미리 합쳐도 됩니다. 원본은 720p 로 바꿔, 검수 영상은 그대로 서울 NAS(`/volume3/nvr/daejeon/`, `/volume3/nvr/daejeon-review/`)로 보내고 로컬 30일/NAS 365일 초과분을 정리합니다.

GitOps 저장소에 커밋하고 push하면 Argo CD `iot-edge` ApplicationSet이 새 폴더를 감지해 자동으로 `daejeon-nvr` 애플리케이션을 생성하고 엣지 클러스터에 배포합니다.

- **확인:** Argo CD 앱 동기화 및 파드 기동 상태를 확인합니다.

```bash
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl -n argocd get app daejeon-nvr"
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl --kubeconfig ~/k8s-daejeon.yaml -n nvr get pods"
```

## 6. 배포와 수집 확인

배포가 끝나면 녹화, MQTT 센서, 검수 영상, 일일 합치기를 차례로 확인합니다.

워커 노드의 `/mnt/nvr/rec/` 아래에 오늘 날짜 폴더가 생기고 10분 간격으로 H.265 원본 MP4 파일이 쌓이는지 봅니다.

```bash
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl --kubeconfig ~/k8s-daejeon.yaml -n nvr exec deploy/nvr -c recorder -- ls -lh /mnt/nvr/rec/$(date +%Y-%m-%d)"
```

- **확인:** `ffprobe` 로 검사했을 때 원본 해상도(2880x1620, hevc, hvc1 태그)가 그대로 유지되어 있어야 합니다.

수집기 로그의 1분 통계에서 추적 프레임 수가 목표를 따라가는지 봅니다.

```bash
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl --kubeconfig ~/k8s-daejeon.yaml -n nvr logs deploy/nvr -c occupancy | grep '1분:'"
```

- **확인:** `추적 600프레임(목표 10fps …)`, `밀려 버린 프레임 0` 처럼 나옵니다. 밀려 버린 프레임이 많으면 `track_fps` 를 낮춥니다.

재실자 값이 Telegraf 를 거쳐 `readings` 에 들어오는지 쿼리합니다.

```bash
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl --kubeconfig ~/k8s-daejeon.yaml -n timescaledb exec timescaledb-0 -- psql -U iot -d iot -c \"SELECT property, processing, unit, hw_id, count(*) FROM readings WHERE source='nvr' AND time > now() - interval '5 minutes' GROUP BY 1, 2, 3, 4 ORDER BY 1;\""
```

- **확인:** `occupant_count`, `occupant1_detected` 가 `derived` 로 1초마다 들어오고 `hw_id` 에 카메라 MAC 이 붙습니다. 사람이 감지되면 `occupant1_u`·`occupant1_v` 가, 방 기하 설정 뒤에는 `occupant1_x_m`·`occupant1_speed_mps` 가 들어옵니다.

- **확인:** Home Assistant 의 **설정** > **기기 및 서비스** > **MQTT** 에 기기 `bedroom2-camera` 가 생기고, `재실자 수`, `재실자1 감지`(감지됨 / 감지되지 않음), 좌표·속도 센서가 보입니다.

검수 영상 조각이 생겼는지 보고, 프레임 한 장을 뽑아 박스를 눈으로 확인합니다.

```bash
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl --kubeconfig ~/k8s-daejeon.yaml -n nvr exec deploy/nvr -c recorder -- ls -lh /mnt/nvr/review/$(date +%Y-%m-%d)"
```

- **확인:** 1280x720 H.264 조각이 10분마다 생기고, 사람이 있는 프레임에 초록 박스와 `#칸 id 신뢰도` 라벨, 왼쪽 위에 시각과 인원이 보입니다.

다음 날 04:00 이후 전날 폴더가 구간 파일로 합쳐졌는지 봅니다.

```bash
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl --kubeconfig ~/k8s-daejeon.yaml -n nvr logs job/\$(kubectl --kubeconfig ~/k8s-daejeon.yaml -n nvr get jobs -o name | tail -1 | cut -d/ -f2)"
```

- **확인:** 로그 끝에 `구간:` 과 `끊김:` 목록이 나오고, 전날 폴더에는 `<시작>_<끝>.mp4` 파일만 남습니다. 파일이 여러 개면 이름의 시각 사이가 녹화가 끊긴 구간입니다.
