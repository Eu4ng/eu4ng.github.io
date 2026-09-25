---
layout: post
title: 엣지 Mosquitto와 Telegraf 디스크 버퍼로 중앙 TimescaleDB에 유실 없이 IoT 데이터 모으는 방법
description: 지역(엣지) 클러스터의 MQTT 브로커와 Telegraf 가 기기 데이터를 받아 허브의 TimescaleDB 로 보내고, 허브가 끊긴 동안은 디스크 버퍼에 쌓았다가 원래 시각 그대로 밀어 넣는 허브-스포크 수집 파이프라인을 GitOps 로 만드는 방법을 정리했습니다.
author: Eu4ng
tags: [iot, mqtt, mosquitto, telegraf, timescaledb, postgresql, grafana, kubernetes, argo-cd, gitops, edge]
permalink: /posts/43/
---

허브 클러스터에 **TimescaleDB**를 두고, 엣지 클러스터에 **Mosquitto**(MQTT 브로커)와 **Telegraf**(수집기)를 두어 기기 메시지가 `엣지 브로커 → 엣지 Telegraf → 허브 TimescaleDB`로 흐르게 합니다. Telegraf 는 디스크 버퍼를 켜서 허브가 안 닿는 동안 파드가 재시작되더라도 데이터를 잃지 않고, 페이로드의 시각을 써서 뒤늦게 도착해도 원래 시각으로 적재됩니다. 모든 기기 값은 수집기와 관계없이 `readings` 테이블 하나에 "행 하나 = 기기 하나의 속성 하나" 로 넣고, 지역·프로토콜·수집기·기기를 컬럼으로 두어 여러 지역과 여러 종류의 기기가 한 테이블에 섞여도 구분되도록 했습니다. 매니페스트는 [이전 글](/posts/42/)에서 만든 `iot/` 폴더 규칙(`iot/hub/`, `iot/edge/`, `iot/clusters/[SITE]/`)을 따릅니다.

1. 비밀 값 만들기
2. 허브: TimescaleDB 와 Grafana 데이터소스
3. 엣지: Mosquitto 와 Telegraf 베이스
4. 지역 오버레이 추가와 배포
5. 테스트 메시지로 확인
6. Grafana 대시보드로 기록 보기
7. 단절 드릴

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| 허브 Kubernetes | `v1.37` (kubeadm) |
| 엣지 Kubernetes | `v1.36` (k3s) |
| Argo CD | `v3.5.3` |
| eclipse-mosquitto | `2.0.22` |
| telegraf | `1.40.1` |
| timescale/timescaledb | `2.30.1-pg17` |
| Grafana | `13.2` (kube-prometheus-stack `91.4.1`) |
| 작성 기준일 | `2026-09-24` |

다음 항목이 준비되어 있어야 합니다.

- Argo CD 에 원격 클러스터로 등록된 엣지 클러스터와 `iot/` 폴더 규칙, ApplicationSet `iot-hub`·`iot-edge` ([Proxmox에 Ansible로 k3s 엣지 클러스터 만들고 Argo CD 원격 클러스터로 등록하는 방법](/posts/42/))
- 허브의 kube-prometheus-stack(Grafana) ([쿠버네티스에 Prometheus와 Grafana 배포해 자원 사용량 대시보드 만드는 방법](/posts/39/))
- control plane 에 엣지 kubeconfig 파일(`k3s-[SITE].yaml`)
- 허브 노드에 TimescaleDB 20Gi, 엣지 노드에 버퍼 2Gi 를 둘 디스크

## 1. 비밀 값 만들기

DB 비밀번호와 브로커 계정은 GitOps 저장소에 넣지 않고 두 클러스터에 Secret 으로 미리 만듭니다. 스크립트가 허브에는 TimescaleDB 비밀번호와 Grafana 읽기 계정 비밀번호를, 엣지에는 브로커 계정 파일(`mosquitto_passwd` 해시)과 클라이언트 자격 증명을 만듭니다. 브로커 계정은 `zigbee2mqtt`, `telegraf`, `homeassistant`, `devices`(ESPHome 같은 LAN 기기용) 네 개이고, 해시 파일은 control plane 에 docker 가 없으므로 엣지에서 일회용 파드로 만듭니다.

```bash
# control plane 에서 스크립트 내려받기
wget https://eu4ng.github.io/assets/scripts/iot/create-iot-secrets.sh
```

<details markdown="1">
<summary>create-iot-secrets.sh 전문</summary>

```bash
#!/usr/bin/env bash
#
# IoT 스택이 쓰는 비밀 값(Secret)을 허브와 엣지 클러스터에 만듭니다. GitOps 저장소에는 비밀 값을 넣지 않으므로 폴더를 push 하기 전에 실행합니다.
# 허브에 kubectl 로 접근할 수 있고 엣지 kubeconfig 가 있는 곳(control plane)에서 실행합니다: bash create-iot-secrets.sh [EDGE_KUBECONFIG]
# 비밀번호는 실행 중에 입력받습니다. 이미 있는 Secret 은 건너뜁니다(비밀번호를 바꾸려면 Secret 을 지우고 다시 실행).

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
MOSQUITTO_IMAGE=eclipse-mosquitto:2.0.22   # 계정 파일(해시)을 만들 때 쓰는 이미지. 배포하는 버전과 맞춥니다
MQTT_USERS=(zigbee2mqtt telegraf homeassistant devices)   # 브로커 계정. devices 는 ESPHome 같은 LAN 기기용
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# 네임스페이스는 Argo CD 가 만들기 전에 미리 만들어도 그대로 씁니다.
# ensure_ns <kubectl 옵션...> <ns>
ensure_ns() { kubectl "${@:1:$#-1}" create namespace "${@: -1}" --dry-run=client -o yaml | kubectl "${@:1:$#-1}" apply -f - >/dev/null; }
# secret_exists <kubectl 옵션...> <ns> <name>
secret_exists() { kubectl "${@:1:$#-2}" -n "${@: -2:1}" get secret "${@: -1}" >/dev/null 2>&1; }

# ---------- 1. 사전 검사 ----------
log "사전 검사"
EDGE_KUBECONFIG=${1:-}
[ -r "$EDGE_KUBECONFIG" ] || die "사용법: bash create-iot-secrets.sh [EDGE_KUBECONFIG]"
kubectl get nodes >/dev/null || die "kubectl 로 허브 클러스터에 접근할 수 없습니다."
HUB=()                                   # 허브: 현재 kubeconfig
EDGE=(--kubeconfig "$EDGE_KUBECONFIG")   # 엣지
kubectl "${EDGE[@]}" get nodes >/dev/null || die "엣지 kubeconfig 로 엣지 클러스터에 접근할 수 없습니다."

# ---------- 2. 비밀번호 입력 ----------
log "비밀번호 입력 (화면에 표시되지 않음)"
read -rsp "TimescaleDB iot(소유자, Telegraf 가 씀): " PG_PASSWORD; echo
read -rsp "TimescaleDB grafana(읽기 전용): " GRAFANA_PASSWORD; echo
declare -A MQTT_PASSWORD
for u in "${MQTT_USERS[@]}"; do read -rsp "MQTT 계정 $u: " MQTT_PASSWORD[$u]; echo; done
read -rsp "Zigbee2MQTT 프런트엔드 토큰: " Z2M_TOKEN; echo
for v in PG_PASSWORD GRAFANA_PASSWORD Z2M_TOKEN; do [ -n "${!v}" ] || die "$v 가 비어 있습니다."; done

# ---------- 3. 허브 ----------
log "허브: timescaledb-credentials, grafana-timescale"
for ns in timescaledb monitoring; do ensure_ns "${HUB[@]}" "$ns"; done
if secret_exists "${HUB[@]}" timescaledb timescaledb-credentials; then echo "  timescaledb/timescaledb-credentials 있음, 건너뜀"; else
  kubectl "${HUB[@]}" -n timescaledb create secret generic timescaledb-credentials \
    --from-literal=POSTGRES_PASSWORD="$PG_PASSWORD" --from-literal=GRAFANA_PASSWORD="$GRAFANA_PASSWORD"
fi
if secret_exists "${HUB[@]}" monitoring grafana-timescale; then echo "  monitoring/grafana-timescale 있음, 건너뜀"; else
  kubectl "${HUB[@]}" -n monitoring create secret generic grafana-timescale --from-literal=TIMESCALE_PASSWORD="$GRAFANA_PASSWORD"
fi

# ---------- 4. 엣지: 브로커 계정 파일 ----------
# mosquitto_passwd 가 만드는 해시 파일을 그대로 Secret 에 넣습니다. control plane 에 docker 가 없으므로 엣지에서 일회용 파드로 만듭니다.
log "엣지: mosquitto-passwd"
for ns in mosquitto zigbee2mqtt telegraf; do ensure_ns "${EDGE[@]}" "$ns"; done
if secret_exists "${EDGE[@]}" mosquitto mosquitto-passwd; then echo "  mosquitto/mosquitto-passwd 있음, 건너뜀"; else
  # mosquitto_passwd 는 파일 권한 경고를 표준 출력에 찍으므로, 미리 권한을 좁히고 출력은 버린 뒤 파일만 읽습니다.
  env_args=(); cmd=": > /tmp/passwd; chmod 600 /tmp/passwd"
  for u in "${MQTT_USERS[@]}"; do env_args+=(--env="PW_$u=${MQTT_PASSWORD[$u]}"); cmd+="; mosquitto_passwd -b /tmp/passwd $u \"\$PW_$u\" >/dev/null 2>&1"; done
  cmd+="; cat /tmp/passwd"
  passwd_file=$(kubectl "${EDGE[@]}" -n mosquitto run mosquitto-passwd --rm -i -q --restart=Never --image="$MOSQUITTO_IMAGE" \
    "${env_args[@]}" --command -- sh -c "$cmd")
  [ "$(printf '%s\n' "$passwd_file" | grep -cE '^[A-Za-z0-9_-]+:\$7\$')" -eq "${#MQTT_USERS[@]}" ] \
    && [ "$(printf '%s\n' "$passwd_file" | wc -l)" -eq "${#MQTT_USERS[@]}" ] || die "계정 파일 생성에 실패했습니다: $passwd_file"
  kubectl "${EDGE[@]}" -n mosquitto create secret generic mosquitto-passwd --from-file=passwd=<(printf '%s\n' "$passwd_file")
fi

# ---------- 5. 엣지: 클라이언트 계정 ----------
log "엣지: zigbee2mqtt-credentials, telegraf-credentials"
if secret_exists "${EDGE[@]}" zigbee2mqtt zigbee2mqtt-credentials; then echo "  zigbee2mqtt/zigbee2mqtt-credentials 있음, 건너뜀"; else
  kubectl "${EDGE[@]}" -n zigbee2mqtt create secret generic zigbee2mqtt-credentials \
    --from-literal=MQTT_PASSWORD="${MQTT_PASSWORD[zigbee2mqtt]}" --from-literal=FRONTEND_AUTH_TOKEN="$Z2M_TOKEN"
fi
if secret_exists "${EDGE[@]}" telegraf telegraf-credentials; then echo "  telegraf/telegraf-credentials 있음, 건너뜀"; else
  kubectl "${EDGE[@]}" -n telegraf create secret generic telegraf-credentials \
    --from-literal=MQTT_USER=telegraf --from-literal=MQTT_PASSWORD="${MQTT_PASSWORD[telegraf]}" --from-literal=HUB_PG_PASSWORD="$PG_PASSWORD"
fi

unset PG_PASSWORD GRAFANA_PASSWORD MQTT_PASSWORD Z2M_TOKEN passwd_file
log "완료. homeassistant 계정 비밀번호는 Home Assistant 의 MQTT 통합 화면에서, devices 계정은 LAN 기기 설정에서 직접 입력합니다."
```
{: file="create-iot-secrets.sh" }

</details>

```bash
# 비밀번호 7개를 입력받아 Secret 생성 (이미 있는 Secret 은 건너뜀)
bash create-iot-secrets.sh k3s-[SITE].yaml
```

> 비밀번호는 다른 곳에 안전하게 적어 둡니다. `homeassistant` 계정은 뒤에 Home Assistant 의 MQTT 통합 화면에서, `devices` 계정은 LAN 기기 설정에서 직접 입력하고, TimescaleDB 비밀번호는 Secret 을 지우고 다시 만들어도 이미 초기화된 DB 에는 반영되지 않습니다.
{: .prompt-warning }

- **확인:** 허브 `kubectl -n timescaledb get secret timescaledb-credentials`, `kubectl -n monitoring get secret grafana-timescale`, 엣지 `kubectl --kubeconfig k3s-[SITE].yaml get secret -A | grep -E 'mosquitto-passwd|credentials'` 에 Secret 5개가 보입니다.

## 2. 허브: TimescaleDB 와 Grafana 데이터소스

`iot/hub/timescaledb/` 폴더에 Deployment, Service, PVC 와 첫 기동에만 실행되는 초기화 스크립트를 둡니다. 초기화 스크립트는 Grafana 용 읽기 전용 role 을 만들고, Telegraf 가 나중에 만들 테이블도 읽을 수 있게 기본 권한을 겁니다. Service 는 엣지 Telegraf 가 노드 IP 로 붙도록 NodePort 로 엽니다.

```yaml
# 중앙 시계열 저장소. 모든 지역의 엣지 Telegraf 가 여기로 씁니다. initdb 스크립트는 PGDATA 가 비어 있는 첫 기동에만 실행됩니다.
resources:
  - deployment.yaml
  - service.yaml
  - pvc.yaml
configMapGenerator:
  - name: timescaledb-initdb
    files:
      - initdb/10-iot.sh
```
{: file="iot/hub/timescaledb/kustomization.yaml" }

```bash
#!/bin/sh
# 첫 기동에 한 번 실행됩니다(PGDATA 가 비어 있을 때). 이후 바꿔도 반영되지 않으니 psql 로 직접 고칩니다.
# Telegraf 는 DB 소유자 iot 로 쓰고(테이블·컬럼을 만들어야 함), Grafana 는 읽기 전용 role grafana 로 봅니다.
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOSQL
  CREATE EXTENSION IF NOT EXISTS timescaledb;
  CREATE ROLE grafana LOGIN PASSWORD '$GRAFANA_PASSWORD';
  GRANT CONNECT ON DATABASE $POSTGRES_DB TO grafana;
  GRANT USAGE ON SCHEMA public TO grafana;
  ALTER DEFAULT PRIVILEGES FOR ROLE $POSTGRES_USER IN SCHEMA public GRANT SELECT ON TABLES TO grafana;
EOSQL
```
{: file="iot/hub/timescaledb/initdb/10-iot.sh" }

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: timescaledb
spec:
  replicas: 1
  strategy:
    type: Recreate           # PVC 가 ReadWriteOnce 라 새 파드와 겹쳐 뜨면 안 됩니다
  selector:
    matchLabels: { app: timescaledb }
  template:
    metadata:
      labels: { app: timescaledb }
    spec:
      containers:
        - name: timescaledb
          image: timescale/timescaledb:2.30.1-pg17
          ports: [{ containerPort: 5432 }]
          envFrom:
            - secretRef: { name: timescaledb-credentials }   # POSTGRES_PASSWORD, GRAFANA_PASSWORD. GitOps 밖에서 만듭니다 (create-iot-secrets.sh)
          env:
            - { name: POSTGRES_DB, value: iot }
            - { name: POSTGRES_USER, value: iot }
            - { name: PGDATA, value: /var/lib/postgresql/data/pgdata }   # 마운트 지점 바로 아래는 lost+found 가 있어 initdb 가 거부합니다
            - { name: TS_TUNE_MEMORY, value: 1GB }      # timescaledb-tune 이 노드 전체 메모리(40GiB)를 보고 shared_buffers 를 잡는 것을 막습니다
            - { name: TS_TUNE_NUM_CPUS, value: "2" }
            - { name: TIMESCALEDB_TELEMETRY, value: "off" }
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
            - { name: initdb, mountPath: /docker-entrypoint-initdb.d }
          readinessProbe:
            exec: { command: ["pg_isready", "-h", "127.0.0.1", "-U", "iot", "-d", "iot"] }   # initdb 중의 임시 서버는 소켓만 열어 TCP 검사에 안 잡힙니다
            periodSeconds: 10
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits:   { cpu: "2", memory: 2Gi }        # TS_TUNE_MEMORY=1GB 기준 shared_buffers 256MB + 연결 몇 개
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: timescaledb-data }
        - name: initdb
          configMap: { name: timescaledb-initdb, defaultMode: 0755 }
```
{: file="iot/hub/timescaledb/deployment.yaml" }

```yaml
# 엣지 클러스터의 Telegraf 가 노드 IP:30432 로 씁니다. 지금은 같은 LAN, 다른 지역이 생기면 VPN 너머에서 같은 포트로 옵니다.
apiVersion: v1
kind: Service
metadata:
  name: timescaledb
spec:
  type: NodePort
  selector: { app: timescaledb }
  ports:
    - { port: 5432, targetPort: 5432, nodePort: 30432 }
```
{: file="iot/hub/timescaledb/service.yaml" }

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: timescaledb-data
  annotations:
    argocd.argoproj.io/sync-options: Prune=false   # 매니페스트를 지워도 모은 데이터는 남깁니다
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 20Gi          # 압축 전 기준 수년치 센서 데이터. local-path 라 크기는 참고값이고, 이 필드는 만든 뒤 바꿀 수 없습니다.
```
{: file="iot/hub/timescaledb/pvc.yaml" }

`TS_TUNE_MEMORY` 는 꼭 넣습니다. 이미지의 `timescaledb-tune` 이 컨테이너 한도가 아니라 노드 전체 메모리를 보고 `shared_buffers` 를 잡기 때문에, 없으면 2Gi 한도를 바로 넘겨 파드가 죽습니다.

Grafana 는 기존 `services/monitoring/values.yaml` 에 데이터소스를 추가합니다. 비밀번호는 Secret 을 컨테이너 env 로 넣고 프로비저닝 파일에서 `$TIMESCALE_PASSWORD` 로 참조합니다. Grafana 가 파일을 읽을 때 env 로 채워 주므로 값이 저장소에 남지 않습니다.

```yaml
    envFromSecret: grafana-timescale             # TIMESCALE_PASSWORD. IoT 중앙 DB 읽기 비밀번호, GitOps 밖에서 만듭니다 (create-iot-secrets.sh)
    additionalDataSources:                       # 프로비저닝 파일의 $VAR 는 Grafana 가 읽을 때 컨테이너 env 로 채웁니다
      - name: TimescaleDB
        uid: timescaledb
        type: grafana-postgresql-datasource
        access: proxy
        url: timescaledb.timescaledb.svc.cluster.local:5432   # iot/hub/timescaledb
        user: grafana
        secureJsonData: { password: "$TIMESCALE_PASSWORD" }
        jsonData: { database: iot, sslmode: disable, timescaledb: true, postgresVersion: 1700 }
        editable: false
```
{: file="services/monitoring/values.yaml (kube-prometheus-stack.grafana 아래에 추가)" }

- **확인:** 이 단계는 파일만 만듭니다. push 는 4단계에서 한 번에 합니다.

## 3. 엣지: Mosquitto 와 Telegraf 베이스

엣지 서비스는 `iot/edge/[이름]/` 에 공통 베이스를 두고 지역 오버레이가 참조합니다. 설정 파일은 kustomize 의 `configMapGenerator` 로 넣어, 파일을 고치면 ConfigMap 이름의 해시가 바뀌어 파드가 자동으로 다시 뜹니다.

Mosquitto 는 계정 없는 접속을 막고 persistence 를 켭니다. Service 는 `LoadBalancer` 로 두면 k3s 의 servicelb 가 엣지 노드 IP 의 1883 을 그대로 열어 주어 LAN 기기가 표준 포트로 붙습니다.

```yaml
# 엣지의 MQTT 브로커. 지역 오버레이(iot/clusters/<지역>/mosquitto/)가 이 폴더를 참조합니다.
resources:
  - deployment.yaml
  - service.yaml
  - pvc.yaml
configMapGenerator:
  - name: mosquitto-config
    files:
      - mosquitto.conf
```
{: file="iot/edge/mosquitto/kustomization.yaml" }

```text
# 계정 없는 접속은 막습니다. 계정 파일(passwd)은 Secret mosquitto-passwd 로 GitOps 밖에서 만듭니다 (create-iot-secrets.sh).
listener 1883 0.0.0.0
allow_anonymous false
password_file /mosquitto/config/passwd
persistence true                       # 유지(retained) 메시지와 구독자 세션을 재시작 뒤에도 보존합니다
persistence_location /mosquitto/data/
autosave_interval 300
max_queued_messages 100000             # 구독자(Telegraf)가 잠시 없을 때 계정별로 보관할 QoS1 메시지 수. 기본 1000 은 몇 분이면 찹니다
log_dest stdout
log_type error
log_type warning
log_type notice
```
{: file="iot/edge/mosquitto/mosquitto.conf" }

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mosquitto
spec:
  replicas: 1
  strategy:
    type: Recreate           # PVC 가 ReadWriteOnce 이고 LoadBalancer 포트도 하나입니다
  selector:
    matchLabels: { app: mosquitto }
  template:
    metadata:
      labels: { app: mosquitto }
    spec:
      securityContext:
        fsGroup: 1883        # 이미지의 mosquitto 계정(uid 1883)이 Secret 으로 마운트한 passwd 를 읽게 합니다
      containers:
        - name: mosquitto
          image: eclipse-mosquitto:2.0.22
          ports: [{ containerPort: 1883 }]
          volumeMounts:
            - { name: config, mountPath: /mosquitto/config/mosquitto.conf, subPath: mosquitto.conf }
            - { name: passwd, mountPath: /mosquitto/config/passwd, subPath: passwd }
            - { name: data, mountPath: /mosquitto/data }
          readinessProbe:
            tcpSocket: { port: 1883 }
            periodSeconds: 10
          resources:
            requests: { cpu: 50m, memory: 64Mi }    # 기기 수십 대, 초당 수 건이면 수십 MiB 입니다
            limits:   { cpu: 500m, memory: 256Mi }
      volumes:
        - name: config
          configMap: { name: mosquitto-config }
        - name: passwd
          secret: { secretName: mosquitto-passwd, defaultMode: 0440 }   # 2.x 는 다른 사용자가 읽을 수 있는 계정 파일을 경고합니다
        - name: data
          persistentVolumeClaim: { claimName: mosquitto-data }
```
{: file="iot/edge/mosquitto/deployment.yaml" }

```yaml
# k3s 의 servicelb 가 노드 IP 의 1883 을 그대로 열어 줍니다. LAN 의 기기(ESPHome 등)와 디버깅용 mosquitto_sub 이 표준 포트로 붙습니다.
apiVersion: v1
kind: Service
metadata:
  name: mosquitto
spec:
  type: LoadBalancer
  selector: { app: mosquitto }
  ports:
    - { port: 1883, targetPort: 1883 }
```
{: file="iot/edge/mosquitto/service.yaml" }

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mosquitto-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi           # 유지 메시지와 세션. 지워져도 기기가 다시 보내므로 Prune=false 를 붙이지 않습니다
```
{: file="iot/edge/mosquitto/pvc.yaml" }

Telegraf 설정 하나를 모든 지역이 공유합니다. 지역 이름과 허브 DB 주소는 env 로 받고, 계정은 Secret 에서 env 로 받아 설정 안의 `${VAR}` 에 채웁니다. 핵심은 세 가지입니다. `buffer_strategy = "disk"` 로 허브에 못 보낸 데이터를 PVC 에 쌓고, `json_time_key` 로 페이로드의 `last_seen` 을 행의 시각으로 쓰며, `startup_error_behavior = "retry"` 로 허브가 안 닿는 상태에서 파드가 떠도 종료하지 않게 합니다. 마지막 설정이 없으면 기본 동작이 "연결 실패 시 종료" 라서, 허브 단절 중 파드가 재시작되면 버퍼링조차 못 하고 크래시 루프에 빠집니다.

입력은 `name_override = "readings"` 로 모두 같은 테이블에 보내고, starlark 프로세서가 메시지의 필드 하나를 행 하나로 쪼갭니다. Zigbee2MQTT 메시지 `{"temperature": 21.5, "humidity": 40}` 은 `property` 가 `temperature`, `humidity` 인 두 행이 됩니다. 수집기마다 다른 메시지 모양은 입력 블록과 이 프로세서에서만 흡수하므로, 나중에 Zigbee2MQTT 를 다른 수집기로 바꿔도 입력 블록만 새로 쓰면 되고 테이블과 대시보드는 그대로입니다.

{% raw %}
```toml
# 엣지 Telegraf. env 는 Secret telegraf-credentials(MQTT_USER, MQTT_PASSWORD, HUB_PG_PASSWORD)와 오버레이(SITE, HUB_PG_HOST, HUB_PG_PORT)가 넣습니다.
[global_tags]
  site = "${SITE}"                    # 모든 행에 지역 이름. 허브에서 지역이 섞여도 구분됩니다

[agent]
  interval = "10s"                    # 입력이 push 라 수집 주기는 의미 없고 flush 주기만 유효합니다
  flush_interval = "10s"
  metric_batch_size = 1000
  metric_buffer_limit = 500000        # 출력별 상한(건). 허브가 안 닿는 동안 이만큼 디스크에 쌓고, 넘치면 오래된 것부터 버립니다
  buffer_strategy = "disk"            # 파드가 재시작해도 버퍼가 남습니다
  buffer_directory = "/var/lib/telegraf/buffer"
  omit_hostname = true                # 파드 이름이 태그로 붙지 않게 합니다
  skip_processors_after_aggregators = true   # 집계기를 쓰지 않습니다 (1.40 기본값 변경 경고를 없앰)

# 모든 기기 값은 테이블 readings 하나에 "행 하나 = 기기 하나의 속성 하나" 로 들어갑니다.
# 수집기(Zigbee2MQTT, Home Assistant …)마다 다른 메시지 모양은 입력과 아래 starlark 에서만 흡수하므로, 수집기를 바꿔도 입력 블록만 새로 쓰면 됩니다.
#   컬럼 순서: time, site, room, device, property, value, value_text, protocol, source, vendor, model, hw_id, node (아래 create_templates)
#   기기 이름 <방>-<종류>[번호] 는 첫 - 에서 나눠 room(방)과 device(종류[번호])에 넣습니다. device 는 방마다 겹칠 수 있고 실물 식별은 hw_id 가 맡습니다
#   필드(컬럼): value(숫자. on/off·true/false 는 1/0), value_text(문자열 원문)

# Zigbee2MQTT 기기 메시지. 한 단계(+)만 구독하면 bridge/#, <기기>/set|get|availability 는 자연히 빠집니다 (friendly_name 에 / 를 쓰지 않는 전제).
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.mosquitto.svc.cluster.local:1883"]
  topics = ["zigbee2mqtt/+"]
  username = "${MQTT_USER}"
  password = "${MQTT_PASSWORD}"
  client_id = "telegraf-zigbee"
  persistent_session = true           # Telegraf 가 잠깐 내려가도 브로커가 QoS1 메시지를 보관합니다
  qos = 1
  topic_tag = ""
  name_override = "readings"
  data_format = "json"
  json_string_fields = ["*"]          # 기본은 숫자만 저장. 문자열(state)·불리언(contact, presence)도 받습니다
  json_time_key = "last_seen"         # 기기 시각(Zigbee2MQTT advanced.last_seen: ISO_8601). 수신 시각 대신 써서 지연 도착해도 시각이 맞습니다
  json_time_format = "2006-01-02T15:04:05Z07:00"   # RFC 3339. 소수점 초가 있어도 파싱됩니다
  # Zigbee2MQTT mqtt.include_device_information 이 넣는 device{…} 는 device_<키> 로 펼쳐집니다. 실물 식별에 필요한 것만 태그로 남깁니다
  tag_keys = ["device_ieeeAddr", "device_model", "device_manufacturerName"]
  # 측정값이 아닌 기기 설정(보정값, 감도, 표시등 …)과 펌웨어 업데이트 정보는 버립니다
  fieldexclude = ["device_*", "update_*", "*_calibration", "fading_time", "motion_detection_sensitivity",
                  "illuminance_interval", "indicator", "temperature_unit"]
  [inputs.mqtt_consumer.tags]
    protocol = "zigbee"
    source = "z2m"
  [[inputs.mqtt_consumer.topic_parsing]]
    topic = "zigbee2mqtt/+"
    tags = "_/device"                 # friendly_name → device 컬럼
  [inputs.mqtt_consumer.tagdrop]
    device = ["bridge"]

# 필드 하나를 행 하나로 쪼개고 값을 value(숫자)와 value_text(문자열)로 나눕니다. 실물 기기 태그 이름도 여기서 통일합니다.
# 메시지에 property 태그가 있으면(HA) 그 값이 속성 이름이고, 없으면(Zigbee2MQTT) 필드 이름이 속성 이름입니다.
[[processors.starlark]]
  namepass = ["readings"]
  order = 1
  source = '''
HW_TAGS = {"device_ieeeAddr": "hw_id", "serial": "hw_id", "device_model": "model", "device_manufacturerName": "vendor"}
ON_OFF = {"on": 1.0, "off": 0.0, "true": 1.0, "false": 0.0}
NAME_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789-"

def valid_name(name):
    # <방>-<종류>[번호] 영문 소문자·숫자. 페어링 직후 이름(0x…)과 HA 기본 이름(공백·대문자), 교체한 옛 기기(retired-…)는 기록하지 않습니다
    i = name.find("-")
    if i <= 0 or name.endswith("-") or name.startswith("retired-"):
        return False
    return all([c in NAME_CHARS for c in name.elems()])

def is_number(s):
    if not s or s.count(".") > 1:
        return False
    body = s[1:] if s[0] in "+-" else s
    return len(body) > 0 and all([c in "0123456789." for c in body.elems()]) and body != "."

def apply(metric):
    tags = {}
    for k, v in metric.tags.items():
        if v != "":
            tags[HW_TAGS.get(k, k)] = v
    if not valid_name(tags.get("device", "")):
        return []                     # 이름이 없거나(옛 형식의 유지 메시지 등) 이름 규칙에 맞지 않는 기기는 버립니다
    name = tags["device"]
    i = name.find("-")
    tags["room"] = name[:i]           # bedroom2-air-quality → room bedroom2, device air-quality
    tags["device"] = name[i + 1:]
    prop = tags.pop("property", None)
    out = []
    for k, v in metric.fields.items():
        m = Metric(metric.name)
        m.time = metric.time
        for tk, tv in tags.items():
            m.tags[tk] = tv
        m.tags["property"] = prop or k
        if type(v) == "bool":
            m.fields["value"] = 1.0 if v else 0.0
            m.fields["value_text"] = "true" if v else "false"
        elif type(v) in ("int", "float"):
            m.fields["value"] = float(v)
        else:
            s = str(v).strip()
            if s == "":
                continue                  # 값이 없는 필드는 버립니다
            if is_number(s):
                m.fields["value"] = float(s)
            else:
                m.fields["value_text"] = s
                if s.lower() in ON_OFF:
                    m.fields["value"] = ON_OFF[s.lower()]
        out.append(m)
    return out
'''

# 허브 TimescaleDB. 태그를 외래 키 테이블로 빼지 않고 컬럼으로 두어 지역 간 병합과 중복 제거가 쉽게 합니다.
# 테이블은 컬럼 순서를 정해 두려고 직접 만들고, 이후 새 태그는 Telegraf 가 끝에 컬럼으로 붙입니다.
# 압축은 시계열 하나(site, room, device, property)끼리 묶어 값이 비슷한 것끼리 모이게 합니다.
[[outputs.postgresql]]
  connection = "host=${HUB_PG_HOST} port=${HUB_PG_PORT} user=iot password=${HUB_PG_PASSWORD} dbname=iot sslmode=disable connect_timeout=10"
  startup_error_behavior = "retry"    # 허브가 안 닿는 상태로 파드가 떠도 종료하지 않고 버퍼에 쌓으며 연결을 재시도합니다 (기본값은 종료)
  tags_as_foreign_keys = false
  timestamp_column_type = "timestamp with time zone"
  create_templates = [
    '''CREATE TABLE {{ .table }} (time timestamptz NOT NULL, site text, room text, device text, property text, value double precision, value_text text,
        protocol text, source text, vendor text, model text, hw_id text, node text)''',
    '''SELECT create_hypertable({{ .table|quoteLiteral }}, 'time', chunk_time_interval => INTERVAL '7d')''',
    '''ALTER TABLE {{ .table }} SET (timescaledb.compress, timescaledb.compress_segmentby = 'site, room, device, property', timescaledb.compress_orderby = 'time DESC')''',
    '''SELECT add_compression_policy({{ .table|quoteLiteral }}, INTERVAL '30d')''',
  ]

# readinessProbe 용. 검사 항목이 없으므로 프로세스가 살아 있으면 200 을 돌려줍니다.
[[outputs.health]]
  service_address = "http://:8888"
  namepass = ["__none__"]
```
{: file="iot/edge/telegraf/telegraf.conf" }
{% endraw %}

```yaml
# 엣지 수집기. 브로커의 기기 메시지를 받아 허브 TimescaleDB 로 보내고, 허브가 안 닿으면 디스크 버퍼(PVC)에 쌓았다가 밀어 넣습니다.
# 지역 값(site 이름, 허브 DB 주소)은 오버레이가 env 로 넣습니다. 로컬 DB 티어 같은 추가 출력은 오버레이가 telegraf-site ConfigMap 을 교체해 *.conf 로 넣습니다.
resources:
  - deployment.yaml
  - pvc.yaml
configMapGenerator:
  - name: telegraf-config
    files:
      - telegraf.conf
  - name: telegraf-site           # 자리 표시. 오버레이가 behavior: replace 로 site.d/*.conf 를 넣습니다 (없으면 그대로 비어 있음)
    literals:
      - README=지역 오버레이가 추가 출력(*.conf)을 넣는 자리입니다
```
{: file="iot/edge/telegraf/kustomization.yaml" }

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: telegraf
spec:
  replicas: 1
  strategy:
    type: Recreate           # 디스크 버퍼 PVC 가 ReadWriteOnce 입니다
  selector:
    matchLabels: { app: telegraf }
  template:
    metadata:
      labels: { app: telegraf }
    spec:
      securityContext:
        runAsUser: 999       # 이미지 엔트리포인트를 거치지 않고 telegraf 를 바로 실행하므로 root 로 뜨지 않게 계정을 지정합니다
        runAsGroup: 999
        fsGroup: 999         # 버퍼 PVC 를 이 계정이 쓸 수 있게 합니다
      containers:
        - name: telegraf
          image: telegraf:1.40.1-alpine
          command: ["telegraf", "--config", "/etc/telegraf/telegraf.conf", "--config-directory", "/etc/telegraf/site.d"]
          envFrom:
            - secretRef: { name: telegraf-credentials }   # MQTT_USER, MQTT_PASSWORD, HUB_PG_PASSWORD. GitOps 밖에서 만듭니다 (create-iot-secrets.sh)
          env:
            # 지역 오버레이(iot/clusters/<지역>/telegraf/)가 아래 값을 patch 로 바꿉니다.
            - { name: SITE, value: unknown }
            - { name: HUB_PG_HOST, value: 127.0.0.1 }
            - { name: HUB_PG_PORT, value: "30432" }
          ports: [{ containerPort: 8888 }]
          volumeMounts:
            - { name: config, mountPath: /etc/telegraf/telegraf.conf, subPath: telegraf.conf }
            - { name: site, mountPath: /etc/telegraf/site.d }
            - { name: buffer, mountPath: /var/lib/telegraf/buffer }
          readinessProbe:
            httpGet: { path: /, port: 8888 }
            periodSeconds: 10
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 384Mi }    # 버퍼 색인과 배치 1,000건을 메모리에 들고 있을 때의 상한
      volumes:
        - name: config
          configMap: { name: telegraf-config }
        - name: site
          configMap: { name: telegraf-site }
        - name: buffer
          persistentVolumeClaim: { claimName: telegraf-buffer }
```
{: file="iot/edge/telegraf/deployment.yaml" }

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: telegraf-buffer
  annotations:
    argocd.argoproj.io/sync-options: Prune=false   # 허브로 아직 못 보낸 데이터가 들어 있을 수 있습니다
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi           # metric_buffer_limit 500,000건 × 수백 바이트 ≈ 수백 MB 에 여유를 둔 값
```
{: file="iot/edge/telegraf/pvc.yaml" }

`tags_as_foreign_keys = false` 라 태그가 모두 본 테이블의 컬럼이 됩니다. 행 하나만 봐도 어느 지역의 어느 기기인지 알 수 있어 나중에 지역별 로컬 DB 와 병합하거나 중복을 걸러 내기 쉽습니다. 테이블은 첫 메시지가 올 때 Telegraf 가 `create_templates` 대로 만들고(하이퍼테이블, 7일 청크, 30일 뒤 압축), 새 태그가 보이면 끝에 컬럼을 추가합니다. 컬럼 순서를 정해 두려고 `CREATE TABLE` 에 컬럼을 직접 적었으며, 아래 표가 그 순서입니다.

| 컬럼 | 예 | 내용 |
|---|---|---|
| `time` | `2026-09-25 15:51:04+00` | 기록 시각. Zigbee 는 기기 시각(`last_seen`), Matter 는 수신 시각 |
| `site` | `daejeon` | 지역 |
| `room` | `bedroom2` | 방. 기기 이름 `<방>-<종류>[번호]` 의 첫 `-` 앞 |
| `device` | `motion2` | 기기 종류와 번호. 이름의 첫 `-` 뒤라 방마다 겹칠 수 있고, 실물 식별은 `hw_id` 가 맡습니다 |
| `property` | `temperature`, `presence` | 측정 항목 |
| `value` | `26.3`, `1` | 숫자 값. `on`/`off`, `true`/`false` 는 1/0 |
| `value_text` | `ON`, `false` | 문자열 원문 |
| `protocol` | `zigbee`, `matter` | 기기 통신 방식 |
| `source` | `z2m`, `hass` | 수집기. 수집기를 바꿔도 `protocol` 은 그대로입니다 |
| `vendor`, `model` | `HOBEIAN`, `ZG-204ZV` | 실물 기기의 제조사와 모델 |
| `hw_id` | `0xa4c138f95fdbf3ad` | 실물 기기의 고유 ID. Zigbee 는 IEEE 주소, Matter 는 시리얼 |
| `node` | `CFEE358179DBE7B6-0000000000000001` | Matter 노드 ID (Matter 만) |

기기 이름이 `<방>-<종류>[번호]` 규칙(영문 소문자·숫자)에 맞지 않으면 starlark 가 그 메시지를 버립니다. 페어링 직후 Zigbee 기기의 `0x…` 이름, 이름을 정하기 전 Matter 기기의 HA 기본 이름, 교체한 옛 기기의 `retired-…` 이름이 여기에 걸리므로 기기를 추가하면 바로 이름을 붙입니다.

압축은 `site, room, device, property` 가 같은 행끼리 묶습니다. 묶음 하나가 시계열 하나(예: 한 기기의 온도)가 되어 값이 비슷한 것끼리 모이므로 압축이 잘 되고, 조회할 때도 필요한 묶음만 풉니다.

- **확인:** 이 단계도 파일만 만듭니다.

## 4. 지역 오버레이 추가와 배포

`iot/clusters/[SITE]/` 아래에 서비스별 폴더를 만들어 베이스를 참조하고 지역 값만 넣습니다. Mosquitto 는 베이스 그대로이고, Telegraf 는 `SITE` 와 `HUB_PG_HOST` 를 패치합니다. 폴더 하나가 `[SITE]-[이름]` Application 이 되어 엣지 클러스터의 같은 이름 네임스페이스에 배포됩니다.

```yaml
# [SITE] 엣지의 MQTT 브로커. 베이스 그대로 씁니다.
resources:
  - ../../../edge/mosquitto
```
{: file="iot/clusters/[SITE]/mosquitto/kustomization.yaml" }

```yaml
# [SITE] 엣지의 수집기. 저장 티어는 "버퍼만"(허브 DB 로만 보내고 로컬 DB 없음)이라 베이스에 지역 값만 넣습니다.
resources:
  - ../../../edge/telegraf
patches:
  - patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: telegraf
      spec:
        template:
          spec:
            containers:
              - name: telegraf
                env:
                  - { name: SITE, value: [SITE] }
                  - { name: HUB_PG_HOST, value: [HUB_NODE_IP] }   # 허브 control plane. NodePort 30432 는 어느 노드 IP 로도 들어갑니다
```
{: file="iot/clusters/[SITE]/telegraf/kustomization.yaml" }

```bash
# 커밋하고 push (허브 몫과 엣지 몫을 함께)
git add iot services/monitoring/values.yaml
git commit -m "feat(iot): 중앙 TimescaleDB 와 엣지 Mosquitto·Telegraf 수집 파이프라인 추가"
git push
```

Argo CD 가 저장소를 다시 읽으면(최대 3분) `timescaledb`, `[SITE]-mosquitto`, `[SITE]-telegraf` Application 이 생기고 `monitoring` 이 다시 sync 됩니다. 허브 DB 가 뜨기 전에 엣지 Telegraf 가 먼저 뜨면 연결 실패 로그가 잠깐 찍히지만, 재시도 설정 덕에 DB 가 준비되는 대로 붙습니다.

- **확인:** control plane 에서 `kubectl -n argocd get applications` 에 세 Application 이 `Synced`, `Healthy`. 허브 `kubectl -n timescaledb exec deploy/timescaledb -- psql -U iot -d iot -c '\du' -c 'show shared_buffers'` 에 role `grafana` 와 `128MB` 안팎의 값. 엣지 `kubectl --kubeconfig k3s-[SITE].yaml -n mosquitto get svc` 의 `EXTERNAL-IP` 가 엣지 노드 IP. Grafana 데이터소스 상태는 아래 명령으로 봅니다.

```bash
# control plane: Grafana 데이터소스 연결 상태 (admin 비밀번호는 grafana-admin Secret)
GP=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s -u "admin:$GP" http://127.0.0.1:30082/api/datasources/uid/timescaledb/health
```

응답이 `{"message":"Database Connection OK","status":"OK"}` 이면 됩니다.

## 5. 테스트 메시지로 확인

아직 Zigbee 기기가 없으니 브로커에 기기 메시지 모양의 JSON 을 직접 발행해 끝까지 흐르는지 봅니다. 익명 발행은 거부되어야 하고, `telegraf` 계정으로 발행한 메시지는 `last_seen` 시각으로 허브 테이블에 들어가야 합니다. 명령은 엣지에서 일회용 파드로 실행합니다.

```bash
# control plane. E 는 엣지 kubeconfig, PW 는 telegraf 계정 비밀번호
E="--kubeconfig k3s-[SITE].yaml"
PW=$(kubectl $E -n telegraf get secret telegraf-credentials -o jsonpath='{.data.MQTT_PASSWORD}' | base64 -d)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 익명 발행: 실패해야 정상
kubectl $E -n mosquitto run mq-anon --rm -i -q --restart=Never --image=eclipse-mosquitto:2.0.22 \
  --command -- mosquitto_pub -h mosquitto -t zigbee2mqtt/test -m '{}'

# telegraf 계정으로 기기 메시지 모양 발행 (엣지 노드 IP 의 1883 으로)
kubectl $E -n mosquitto run mq-pub --rm -i -q --restart=Never --image=eclipse-mosquitto:2.0.22 --env="PW=$PW" \
  --command -- mosquitto_pub -h [EDGE_IP] -u telegraf -P "$PW" -q 1 -t zigbee2mqtt/test_sensor \
  -m "{\"temperature\":21.5,\"humidity\":40,\"contact\":true,\"state\":\"ON\",\"last_seen\":\"$TS\"}"

# 20초쯤 뒤 허브에서 조회
kubectl -n timescaledb exec deploy/timescaledb -- psql -U iot -d iot \
  -c 'select hypertable_name from timescaledb_information.hypertables;' \
  -c 'select time, site, protocol, device, property, value, value_text from readings order by time desc, property limit 4;'
```

- **확인:** 익명 발행은 `Connection error: Connection Refused: not authorised` 로 끝납니다. 조회에 하이퍼테이블 `readings` 와 메시지 하나가 쪼개진 네 행(`contact`, `humidity`, `state`, `temperature`)이 보이고, `time` 이 발행한 `TS` 와 같고 `site` 가 `[SITE]`, `protocol` 이 `zigbee`, `device` 가 `test_sensor` 입니다. `true` 는 `value` 1 과 `value_text` `true`, `ON` 은 `value` 1 과 `value_text` `ON` 으로 들어갑니다.

## 6. Grafana 대시보드로 기록 보기

SQL 을 쓰지 않고 웹에서 기록을 보도록 Grafana 대시보드를 함께 배포합니다. kube-prometheus-stack 의 Grafana 에는 `grafana_dashboard: "1"` 라벨이 붙은 ConfigMap 을 모든 네임스페이스에서 찾아 불러오는 sidecar 가 기본으로 켜져 있습니다. 그래서 대시보드 JSON 을 `iot/hub/timescaledb/` 폴더에 두고 `configMapGenerator` 로 라벨을 붙이기만 하면 됩니다.

```bash
# 저장소 루트에서 대시보드 JSON 내려받기
mkdir -p iot/hub/timescaledb/dashboards
wget -O iot/hub/timescaledb/dashboards/iot.json https://eu4ng.github.io/assets/files/iot/grafana-dashboard-iot.json
```

```yaml
# 중앙 시계열 저장소. 모든 지역의 엣지 Telegraf 가 여기로 씁니다. initdb 스크립트는 PGDATA 가 비어 있는 첫 기동에만 실행됩니다.
resources:
  - deployment.yaml
  - service.yaml
  - pvc.yaml
configMapGenerator:
  - name: timescaledb-initdb
    files:
      - initdb/10-iot.sh
  # Grafana 대시보드. sidecar 가 모든 네임스페이스에서 이 라벨의 ConfigMap 을 찾아 불러옵니다(kube-prometheus-stack 기본값)
  - name: grafana-dashboard-iot
    files:
      - dashboards/iot.json
    options:
      labels: { grafana_dashboard: "1" }
      disableNameSuffixHash: true   # 이름이 바뀌면 sidecar 가 옛 파일을 지우고 새로 불러오는 사이 대시보드가 잠시 사라집니다
```
{: file="iot/hub/timescaledb/kustomization.yaml" }

대시보드(uid `iot-records`)는 2단계에서 만든 `TimescaleDB` 데이터소스로 읽기 전용 조회만 합니다. 위쪽의 **지역**, **프로토콜**, **방**, **기기**, **속성** 변수로 범위를 좁히고, 오른쪽 위 시간 범위가 모든 패널에 적용됩니다.

| 패널 | 내용 |
|---|---|
| 기기별 최신 값 | 기기마다 속성별 마지막 값(온도, 습도, 재실, 닫힘, 조도, CO2, PM2.5, 배터리, LQI) |
| 온도, 습도, 조도, 배터리, 링크 품질, CO2, 미세먼지 | 기기별 시계열. Zigbee 와 Matter 기기가 한 그래프에 함께 그려집니다 |
| 재실, 닫힘 (문·창문) | 켜짐/꺼짐 구간 타임라인 |
| 선택한 속성 | **속성** 변수로 고른 속성의 시계열 |
| 실물 기기 | 실물 ID(`hw_id`)별 프로토콜, 수집기, 모델, 제조사, 지금 이름과 거쳐 간 이름 |
| 최근 기록 | `readings` 테이블의 원본 행 최근 200개 |

```bash
# 커밋하고 push
git add iot/hub/timescaledb
git commit -m "feat(iot): 허브 TimescaleDB 기록을 보는 Grafana 대시보드 추가"
git push
```

- **확인:** `kubectl -n timescaledb get cm -l grafana_dashboard=1` 에 `grafana-dashboard-iot` 가 보입니다. Grafana(`http://[HUB_NODE_IP]:30082`)의 **Dashboards** 에 **IoT 기록** 이 생기고, 5단계에서 발행한 `test_sensor` 가 **기기별 최신 값** 표와 **온도**, **습도** 패널에 나타납니다.

## 7. 단절 드릴

허브가 끊긴 상황을 만들어 버퍼가 실제로 동작하는지 봅니다. 엣지 노드에서 파드가 허브 DB 포트로 나가는 패킷을 막고, 그 동안 메시지를 여러 건 발행하고, 도중에 Telegraf 파드까지 지운 뒤, 차단을 풀고 허브에 무엇이 들어왔는지 확인합니다.

```bash
# 엣지 노드: 파드 → 허브 DB 차단 (파드 트래픽은 FORWARD 체인을 지납니다)
sudo iptables -I FORWARD 1 -d [HUB_NODE_IP] -p tcp --dport 30432 -j REJECT --reject-with tcp-reset
```

```bash
# control plane: 8초 간격으로 8건 발행하는 파드 시작
kubectl $E -n mosquitto run mq-drill --restart=Never --image=eclipse-mosquitto:2.0.22 --env="PW=$PW" --command -- sh -c '
  for i in 1 2 3 4 5 6 7 8; do
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mosquitto_pub -h mosquitto -u telegraf -P "$PW" -q 1 -t zigbee2mqtt/drill_sensor -m "{\"temperature\":$i,\"last_seen\":\"$ts\"}" && echo "sent $i $ts"
    sleep 8
  done'

# 30초쯤 뒤: 차단 중에 Telegraf 파드 삭제 → 새 파드가 종료되지 않고 재시도 중인지
kubectl $E -n telegraf delete pod -l app=telegraf
sleep 25; kubectl $E -n telegraf get pods; kubectl $E -n telegraf logs deploy/telegraf | grep -E 'not connected|retrying' | tail -2

# 발행이 끝난 뒤(약 70초) 발행 기록
kubectl $E -n mosquitto logs mq-drill
```

```bash
# 엣지 노드: 차단 해제
sudo iptables -D FORWARD -d [HUB_NODE_IP] -p tcp --dport 30432 -j REJECT --reject-with tcp-reset
```

```bash
# control plane: 40초쯤 뒤 허브 조회
kubectl -n timescaledb exec deploy/timescaledb -- psql -U iot -d iot \
  -c "select count(*), min(time), max(time) from readings where device='drill_sensor';" \
  -c "select time, value from readings where device='drill_sensor' and property='temperature' order by time;"
kubectl $E -n mosquitto delete pod mq-drill
```

- **확인:** 차단 중 새로 뜬 Telegraf 파드가 `Running` 으로 유지되고 로그에 `Error writing to outputs.postgresql: not connected` 가 반복됩니다. 차단을 풀면 8건이 모두 발행 시각 그대로 들어옵니다. 이 글을 쓰며 실행했을 때는 파드를 지운 순간에 처리 중이던 4번 메시지가 두 번 들어와 9행이 됐습니다. 브로커의 QoS 1 은 "최소 한 번" 전달이라 파드 교체 시점에 한 건이 중복될 수 있으며, 조회할 때 `select distinct on (time, site, device, property) ...` 로 걸러 냅니다.

> 로그에 `Using disk-write-through buffer strategy ... this is an experimental feature` 경고가 남습니다. 문서에는 정식 옵션으로 적혀 있지만 구현은 아직 실험 표시가 붙어 있습니다. 위 드릴처럼 파드 재시작과 재연결을 한 번 직접 확인해 두는 것이 좋습니다.
{: .prompt-warning }

## 마무리

엣지의 Mosquitto 와 Telegraf, 허브의 TimescaleDB 와 Grafana 데이터소스·대시보드를 GitOps 폴더로 배포해, 기기 메시지가 엣지에서 허브로 모이고 허브가 끊긴 동안은 엣지 디스크에 쌓였다가 원래 시각으로 들어가는 파이프라인을 완성했습니다. 지역을 추가할 때는 `iot/clusters/[SITE]/` 아래에 같은 오버레이 두 개를 만들고 시크릿 스크립트를 그 엣지에 실행하면 됩니다. 로컬에도 DB 를 두는 지역은 `telegraf-site` ConfigMap 을 오버레이에서 교체해 두 번째 출력을 넣는 자리를 남겨 두었습니다. 다음 글에서는 이 브로커에 Zigbee2MQTT 를 붙여 실제 Zigbee 기기 데이터를 흘립니다.

## 참고 자료

- [Telegraf - Configuration (agent, buffer_strategy)](https://docs.influxdata.com/telegraf/v1/configuration/agent/)
- [Telegraf - MQTT Consumer Input Plugin](https://github.com/influxdata/telegraf/tree/master/plugins/inputs/mqtt_consumer)
- [Telegraf - JSON Parser](https://github.com/influxdata/telegraf/tree/master/plugins/parsers/json)
- [Telegraf - PostgreSQL Output Plugin](https://github.com/influxdata/telegraf/tree/master/plugins/outputs/postgresql)
- [TimescaleDB - Docker image (timescaledb-tune 환경 변수)](https://github.com/timescale/timescaledb-docker)
- [TimescaleDB - Hypertables](https://docs.timescale.com/use-timescale/latest/hypertables/)
- [Eclipse Mosquitto - mosquitto.conf](https://mosquitto.org/man/mosquitto-conf-5.html)
- [Grafana - Provision data sources](https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources)
- [Grafana Helm chart - Sidecar for dashboards](https://github.com/grafana/helm-charts/tree/main/charts/grafana#sidecar-for-dashboards)
- [Grafana - PostgreSQL data source (매크로와 템플릿 변수)](https://grafana.com/docs/grafana/latest/datasources/postgres/)
- [k3s - Networking (ServiceLB)](https://docs.k3s.io/networking/networking-services)
- [Kustomize - configMapGenerator](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/configmapgenerator/)
