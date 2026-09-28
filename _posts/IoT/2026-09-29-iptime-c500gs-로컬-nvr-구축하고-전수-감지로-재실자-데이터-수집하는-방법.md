---
layout: post
title: ipTIME C500GS 로컬 NVR 구축하고 전수 감지로 재실자 데이터 수집하는 방법
description: 외부 인터넷을 차단한 ipTIME C500GS 카메라로 엣지 쿠버네티스에서 무부하 세그먼트 녹화와 YOLOv8 전수 추론 재실자 데이터를 수집하는 방법을 정리했습니다.
author: Eu4ng
tags: [iot, nvr, kubernetes, computer-vision, timescaledb, argo-cd, gitops]
permalink: /posts/76/
---

ipTIME C500GS IP 카메라를 공유기 방화벽으로 외부 인터넷과 완전히 차단한 상태에서 로컬 NVR을 구축하고, 영상에서 재실자 수·좌표·속도를 실시간 추출해 홈랩 TimescaleDB 파이프라인에 적재합니다. 움직임이 있을 때만 동작하는 모션 기반 감지기(Frigate 등)는 한 번 추적이 끊기면 정지한 사람을 다시 잡지 못하지만, 이 구성은 2초마다 프레임 전체를 전수 추론하므로 잠든 사람처럼 오래 움직이지 않는 재실자도 매 주기 놓치지 않고 감지합니다.

1. 카메라 네트워크 차단 및 RTSP 설정
2. 워커 노드 NVR 전용 디스크 마운트
3. occupancy 하이퍼테이블 마이그레이션
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
| 수집기 / 딥러닝 | `ultralytics/ultralytics:latest-cpu` (YOLOv8n + ByteTrack) |
| 시계열 DB | TimescaleDB `2.30.1-pg17` |
| 녹화 저장소 | Proxmox SCSI passthrough 디스크 500GB (`/mnt/nvr`) |
| 작성 기준일 | `2026-09-29` |

다음 항목이 준비되어 있어야 합니다.

- 공유기(ipTIME 등)에서 카메라 IP를 고정 할당하고 외부 인터넷 트래픽을 차단할 수 있는 환경
- 대전 엣지 클러스터 및 TimescaleDB ([지역 엣지에 TimescaleDB와 Grafana를 두어 인터넷 없이도 기록하고 보는 방법](/posts/56/))
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

## 3. occupancy 하이퍼테이블 마이그레이션

재실자의 실시간 공간 좌표(x, y)와 속도를 저장하기 위해 TimescaleDB에 `occupancy` 테이블을 생성하고 일 단위 압축 정책을 설정합니다.

{% raw %}
```sql
-- iot/hub/timescaledb/migrations/2026-09-28-occupancy.sql
BEGIN;

CREATE TABLE IF NOT EXISTS occupancy (
    time timestamptz NOT NULL,
    site text NOT NULL,
    room text NOT NULL,
    device text NOT NULL,
    track_id integer NOT NULL,
    x_m double precision,
    y_m double precision,
    speed_mps double precision,
    confidence double precision
);

SELECT create_hypertable('occupancy', 'time', chunk_time_interval => INTERVAL '1d', if_not_exists => TRUE);

ALTER TABLE occupancy SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'site, room, device, track_id',
    timescaledb.compress_orderby = 'time DESC'
);

SELECT add_compression_policy('occupancy', INTERVAL '1d', if_not_exists => TRUE);

COMMIT;
```
{: file="iot/hub/timescaledb/migrations/2026-09-28-occupancy.sql" }
{% endraw %}

지역 DB와 허브 DB의 primary 파드에 마이그레이션 SQL을 적용합니다:

```bash
# 대전 엣지 TimescaleDB 적용
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl --kubeconfig ~/k8s-daejeon.yaml -n timescaledb exec -i timescaledb-0 -- psql -U iot -d iot -v ON_ERROR_STOP=1" < iot/hub/timescaledb/migrations/2026-09-28-occupancy.sql

# 중앙 허브 TimescaleDB 적용
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl -n timescaledb exec -i timescaledb-1 -- psql -U iot -d iot -v ON_ERROR_STOP=1" < iot/hub/timescaledb/migrations/2026-09-28-occupancy.sql
```

- **확인:** 두 DB에서 `\d occupancy` 로 하이퍼테이블 구조가 생성되었는지 확인합니다.

## 4. NVR Secret 생성

카메라 RTSP 비밀번호, MQTT 인증 비밀번호, TimescaleDB 접속 비밀번호, 그리고 서울 NAS rsync용 SSH 키를 담은 Secret을 엣지 클러스터 `nvr` 네임스페이스에 생성합니다.

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

set -euo pipefail

NAMESPACE=nvr
DB_SECRET=timescaledb/timescaledb-credentials
TELEGRAF_SECRET=telegraf/telegraf-credentials
BACKUP_SECRET=backup/backup-ssh

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

log "사전 검사"
EDGE_KUBECONFIG=${1:-}
[ -r "$EDGE_KUBECONFIG" ] || die "사용법: bash create-nvr-secrets.sh [EDGE_KUBECONFIG]"
EDGE=(--kubeconfig "$EDGE_KUBECONFIG")
kubectl get nodes >/dev/null || die "kubectl 로 허브 클러스터에 접근할 수 없습니다."
kubectl "${EDGE[@]}" get nodes >/dev/null || die "엣지 kubeconfig 로 엣지 클러스터에 접근할 수 없습니다."

kubectl "${EDGE[@]}" create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl "${EDGE[@]}" apply -f - >/dev/null

if kubectl "${EDGE[@]}" -n "$NAMESPACE" get secret nvr-credentials >/dev/null 2>&1; then
  echo "  엣지 $NAMESPACE/nvr-credentials 있음, 건너뜀"
else
  log "비밀값 조회"
  db_password() { kubectl "$@" -n "${DB_SECRET%%/*}" get secret "${DB_SECRET##*/}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; }
  PG_HUB=$(db_password) || true
  PG_LOCAL=$(db_password "${EDGE[@]}") || true
  [ -n "$PG_HUB" ] || die "허브 $DB_SECRET 에서 POSTGRES_PASSWORD 를 읽지 못했습니다."
  [ -n "$PG_LOCAL" ] || die "엣지 $DB_SECRET 에서 POSTGRES_PASSWORD 를 읽지 못했습니다."

  MQTT_PASSWORD=${MQTT_PASSWORD:-}
  if [ -z "$MQTT_PASSWORD" ]; then
    MQTT_PASSWORD=$(kubectl "${EDGE[@]}" -n "${TELEGRAF_SECRET%%/*}" get secret "${TELEGRAF_SECRET##*/}" -o jsonpath='{.data.MQTT_PASSWORD}' | base64 -d) || true
  fi
  [ -n "$MQTT_PASSWORD" ] || die "MQTT 비밀번호를 찾지 못했습니다."

  CAMERA_RTSP_PASSWORD=${CAMERA_RTSP_PASSWORD:-}
  if [ -z "$CAMERA_RTSP_PASSWORD" ]; then
    log "카메라 RTSP 비밀번호 입력 (화면에 표시되지 않음)"
    read -rsp "CAMERA_RTSP_PASSWORD: " CAMERA_RTSP_PASSWORD; echo
    [ -n "$CAMERA_RTSP_PASSWORD" ] || die "카메라 RTSP 비밀번호가 비어 있습니다."
  fi

  log "엣지 $NAMESPACE/nvr-credentials 생성"
  printf 'RTSP_PASSWORD=%s\nMQTT_PASSWORD=%s\nPGPASSWORD_LOCAL=%s\nPGPASSWORD_HUB=%s\n' \
    "$CAMERA_RTSP_PASSWORD" "$MQTT_PASSWORD" "$PG_LOCAL" "$PG_HUB" \
    | kubectl "${EDGE[@]}" -n "$NAMESPACE" create secret generic nvr-credentials --from-env-file=/dev/stdin
  unset CAMERA_RTSP_PASSWORD MQTT_PASSWORD PG_HUB PG_LOCAL
fi

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
2. **`recorder`**: `ffmpeg`를 사용해 `rtsp://localhost:8554/main` 스트림을 재인코딩 없이 10분 단위 세그먼트로 무부하 copy 저장합니다 (`/mnt/nvr/rec/%Y-%m-%d/%H-%M-%S.mp4`).
3. **`occupancy`**: `ultralytics/ultralytics:latest-cpu` 컨테이너에서 2초마다 프레임을 캡처해 YOLOv8n + ByteTrack으로 전체 인원을 감지합니다. 프레임 이미지는 메모리에서만 처리하고 즉시 버립니다.

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

그리고 매일 새벽 04:00에 실행되는 `nvr-daily-archive` CronJob을 통해, 전일 영상의 해상도가 1080p(로컬)/720p(NAS)를 초과할 때만 선택적으로 트랜스코딩하여 서울 원격 NAS로 rsync 이관하고 로컬 30일/NAS 365일 초과분을 정리합니다.

GitOps 저장소에 커밋하고 push하면 Argo CD `iot-edge` ApplicationSet이 새 폴더를 감지해 자동으로 `daejeon-nvr` 애플리케이션을 생성하고 엣지 클러스터에 배포합니다.

- **확인:** Argo CD 앱 동기화 및 파드 기동 상태를 확인합니다.

```bash
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl -n argocd get app daejeon-nvr"
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl --kubeconfig ~/k8s-daejeon.yaml -n nvr get pods"
```

## 6. 배포와 수집 확인

배포가 완료되면 세 가지 핵심 지표가 정상 동작하는지 확인합니다.

### 1) 무인코딩 세그먼트 녹화 파일 생성 확인

워커 노드의 `/mnt/nvr/rec/` 아래에 오늘 날짜 폴더가 생성되고 10분 간격으로 H.265 원본 MP4 파일이 쌓이는지 확인합니다:

```bash
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl --kubeconfig ~/k8s-daejeon.yaml -n nvr exec deploy/nvr -c recorder -- ls -lh /mnt/nvr/rec/$(date +%Y-%m-%d)"
```

- **확인:** `ffprobe`로 검사했을 때 원본 해상도(2880x1620, hevc, hvc1 태그)가 그대로 유지되어 있어야 합니다.

### 2) Telegraf 파이프라인의 occupant_count 적재 확인

수집기가 `nvr/bedroom2-camera/occupant_count`로 발행한 재실자 수가 Telegraf를 거쳐 `readings` 테이블에 실시간으로 들어오는지 쿼리합니다:

```bash
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl --kubeconfig ~/k8s-daejeon.yaml -n timescaledb exec timescaledb-0 -- psql -U iot -d iot -c \"SELECT time, site, room, device, property, value FROM readings WHERE property='occupant_count' ORDER BY time DESC LIMIT 5;\""
```

- **확인:** 2초 주기로 `room=bedroom2`, `device=camera`, `property=occupant_count`, `processing=derived` 행이 출력됩니다.

### 3) occupancy 하이퍼테이블 좌표 적재 확인

사람이 감지되면 바닥 접점(u, v)이 호모그래피 평면 변환을 거쳐 실제 방 바닥 기준 좌표(m)와 속도(m/s)로 `occupancy` 테이블에 이중 적재됩니다:

```bash
ssh ubuntu@kubectl-hub.eu4ng.com "kubectl --kubeconfig ~/k8s-daejeon.yaml -n timescaledb exec timescaledb-0 -- psql -U iot -d iot -c \"SELECT time, site, room, track_id, x_m, y_m, speed_mps, confidence FROM occupancy ORDER BY time DESC LIMIT 5;\""
```

- **확인:** `track_id`별로 이동 속도와 좌표가 기록되며, 중앙 허브 TimescaleDB(`kubectl -n timescaledb exec timescaledb-1`)에서도 동일하게 복제 적재되는 것을 볼 수 있습니다.
