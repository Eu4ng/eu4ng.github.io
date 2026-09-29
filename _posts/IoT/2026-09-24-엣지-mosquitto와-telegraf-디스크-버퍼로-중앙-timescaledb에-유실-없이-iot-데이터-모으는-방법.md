---
layout: post
title: 엣지 Mosquitto와 Telegraf 디스크 버퍼로 중앙 TimescaleDB에 유실 없이 IoT 데이터 모으는 방법
description: 지역(엣지) 클러스터의 MQTT 브로커와 Telegraf 가 기기 데이터를 받아 지역 TimescaleDB 와 허브 TimescaleDB 에 함께 쓰고, DB 가 끊긴 동안은 디스크 버퍼에 쌓았다가 원래 시각 그대로 밀어 넣는 허브-스포크 수집 파이프라인을 GitOps 로 만드는 방법을 정리했습니다.
author: Eu4ng
tags: [iot, mqtt, mosquitto, telegraf, timescaledb, postgresql, grafana, kubernetes, argo-cd, gitops, edge]
permalink: /posts/43/
---

허브 클러스터와 엣지 클러스터에 각각 **TimescaleDB**를 두고, 엣지 클러스터에 **Mosquitto**(MQTT 브로커)와 **Telegraf**(수집기)를 두어 기기 메시지가 `엣지 브로커 → 엣지 Telegraf → 지역 TimescaleDB, 허브 TimescaleDB`로 흐르게 합니다. Telegraf 는 같은 행을 지역 DB(첫 번째 출력)와 허브 DB(두 번째 출력)에 쓰므로 [허브나 인터넷이 끊겨도](/posts/62/) 지역에서는 기록이 이어집니다. 출력마다 디스크 버퍼를 따로 두어 한쪽 DB 가 안 닿는 동안 파드가 재시작되더라도 데이터를 잃지 않고, 페이로드의 시각을 써서 뒤늦게 도착해도 원래 시각으로 적재됩니다. 모든 기기 값은 수집기와 관계없이 `readings` 테이블 하나에 "행 하나 = 기기 하나의 속성 하나" 로 넣고, 지역·프로토콜·수집기·기기를 컬럼으로 두어 여러 지역과 여러 종류의 기기가 한 테이블에 섞여도 구분되도록 했습니다. 기기로 간 제어 명령은 `events` 테이블에 따로 남깁니다. 매니페스트는 [이전 글](/posts/42/)에서 만든 `iot/` 폴더 규칙(`iot/hub/`, `iot/edge/`, `iot/clusters/[SITE]/`)을 따릅니다.

1. 비밀 값 만들기
2. 허브: Grafana 데이터소스
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
| 엣지 Kubernetes | `v1.37` (kubeadm, 기본 StorageClass Longhorn) |
| Argo CD | `v3.5.3` |
| eclipse-mosquitto | `2.0.22` |
| telegraf | `1.40.1` |
| timescale/timescaledb-ha | `pg17.11-ts2.30.1` (Patroni) |
| Grafana | `13.2` (kube-prometheus-stack `91.4.1`) |
| 작성 기준일 | `2026-09-24` |

다음 항목이 준비되어 있어야 합니다.

- Argo CD 에 원격 클러스터로 등록된 엣지 클러스터와 `iot/` 폴더 규칙, ApplicationSet `iot-hub`·`iot-edge` ([Proxmox에 Ansible로 kubeadm 엣지 클러스터 만들고 Argo CD 원격 클러스터로 등록하는 방법](/posts/42/))
- 허브 DB(`iot/hub/timescaledb`, TimescaleDB Patroni 클러스터) ([쿠버네티스에 Longhorn과 Patroni로 볼륨과 TimescaleDB 이중화하는 방법](/posts/54/)). 두 DB 가 쓰는 `iot`·`grafana` 계정 비밀번호 Secret 은 이 글 1단계 스크립트가 만듭니다(이미 있으면 건너뜀).
- 지역 DB(`iot/clusters/[SITE]/timescaledb`) ([지역 엣지에 TimescaleDB와 Grafana를 두어 인터넷 없이도 기록하고 보는 방법](/posts/56/)). 지역 DB 보다 Telegraf 를 먼저 배포하면 지역 DB 몫은 디스크 버퍼에 쌓였다가 DB 가 뜨면 들어갑니다.
- 허브의 kube-prometheus-stack(Grafana) ([쿠버네티스에 Prometheus와 Grafana 배포해 자원 사용량 대시보드 만드는 방법](/posts/39/))
- 허브 control plane 에 엣지 kubeconfig 파일(`k8s-[SITE].yaml`)
- 엣지의 서비스 VIP(`[EDGE_SERVICE_VIP]`, kube-vip 가 LoadBalancer Service 에 붙이는 LAN 주소)와 허브 control plane VIP(`[HUB_VIP]`)

## 1. 비밀 값 만들기

DB 비밀번호와 브로커 계정은 GitOps 저장소에 넣지 않고 두 클러스터에 Secret 으로 미리 만듭니다. 스크립트가 허브에는 TimescaleDB 비밀번호와 Grafana 읽기 계정 비밀번호를, 엣지에는 브로커 계정 파일(`mosquitto_passwd` 해시)과 클라이언트 자격 증명, 지역 DB·지역 Grafana 의 Secret 을 만듭니다. DB 계정 비밀번호는 허브 DB 와 지역 DB 가 같습니다. 브로커 계정은 `zigbee2mqtt`, `telegraf`, `homeassistant`, `devices`(ESPHome·서버의 Telegraf 같은 LAN 기기용) 네 개이고, 해시 파일은 control plane 에 docker 가 없으므로 엣지에서 일회용 파드로 만듭니다.

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
# 엣지에는 지역 DB(TimescaleDB)와 지역 Grafana 도 있습니다. DB 계정(iot, grafana)의 비밀번호는 허브 DB 와 지역 DB 가 같습니다.
# 허브에 kubectl 로 접근할 수 있고 엣지 kubeconfig 가 있는 곳(control plane)에서 실행합니다: bash create-iot-secrets.sh [EDGE_KUBECONFIG]
# 비밀번호는 실행 중에 입력받습니다. 이미 있는 Secret 은 건너뜁니다(비밀번호를 바꾸려면 Secret 을 지우고 다시 실행).
# 엣지 Grafana 관리자 계정은 허브의 monitoring/grafana-admin 을 복사합니다(Prometheus·Grafana 글에서 만듦).

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
MOSQUITTO_IMAGE=eclipse-mosquitto:2.0.22   # 계정 파일(해시)을 만들 때 쓰는 이미지. 배포하는 버전과 맞춥니다
MQTT_USERS=(zigbee2mqtt telegraf homeassistant devices)   # 브로커 계정. devices 는 ESPHome·서버의 Telegraf 같은 LAN 기기용
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
    --from-literal=MQTT_USER=telegraf --from-literal=MQTT_PASSWORD="${MQTT_PASSWORD[telegraf]}" \
    --from-literal=HUB_PG_PASSWORD="$PG_PASSWORD" --from-literal=LOCAL_PG_PASSWORD="$PG_PASSWORD"
fi
# 지역 DB 가 생기기 전에 만든 Secret 에는 LOCAL_PG_PASSWORD 가 없으므로 그 키만 더합니다
if [ -z "$(kubectl "${EDGE[@]}" -n telegraf get secret telegraf-credentials -o jsonpath='{.data.LOCAL_PG_PASSWORD}')" ]; then
  printf '{"stringData":{"LOCAL_PG_PASSWORD":"%s"}}' "$PG_PASSWORD" \
    | kubectl "${EDGE[@]}" -n telegraf patch secret telegraf-credentials --type merge --patch-file=/dev/stdin >/dev/null
  echo "  telegraf/telegraf-credentials 에 LOCAL_PG_PASSWORD 추가"
fi

# ---------- 6. 엣지: 지역 DB·Grafana ----------
log "엣지: timescaledb-credentials, grafana-timescale, grafana-admin"
for ns in timescaledb grafana; do ensure_ns "${EDGE[@]}" "$ns"; done
if secret_exists "${EDGE[@]}" timescaledb timescaledb-credentials; then echo "  timescaledb/timescaledb-credentials 있음, 건너뜀"; else
  kubectl "${EDGE[@]}" -n timescaledb create secret generic timescaledb-credentials \
    --from-literal=POSTGRES_PASSWORD="$PG_PASSWORD" --from-literal=GRAFANA_PASSWORD="$GRAFANA_PASSWORD"
fi
if secret_exists "${EDGE[@]}" grafana grafana-timescale; then echo "  grafana/grafana-timescale 있음, 건너뜀"; else
  kubectl "${EDGE[@]}" -n grafana create secret generic grafana-timescale --from-literal=TIMESCALE_PASSWORD="$GRAFANA_PASSWORD"
fi
if secret_exists "${EDGE[@]}" grafana grafana-admin; then echo "  grafana/grafana-admin 있음, 건너뜀"; else
  kubectl "${HUB[@]}" -n monitoring get secret grafana-admin -o json | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": d["type"],
                  "metadata": {"name": "grafana-admin", "namespace": "grafana"}, "data": d["data"]}))' \
    | kubectl "${EDGE[@]}" apply -f - >/dev/null
  echo "  grafana/grafana-admin: 허브 monitoring/grafana-admin 복사"
fi

unset PG_PASSWORD GRAFANA_PASSWORD MQTT_PASSWORD Z2M_TOKEN passwd_file
log "완료. homeassistant 계정 비밀번호는 Home Assistant 의 MQTT 통합 화면에서, devices 계정은 LAN 기기 설정에서 직접 입력합니다."
```
{: file="create-iot-secrets.sh" }

</details>

```bash
# 비밀번호 7개를 입력받아 Secret 생성 (이미 있는 Secret 은 건너뜀)
bash create-iot-secrets.sh k8s-[SITE].yaml
```

> 비밀번호는 다른 곳에 안전하게 적어 둡니다. `homeassistant` 계정은 뒤에 Home Assistant 의 MQTT 통합 화면에서, `devices` 계정은 LAN 기기 설정에서 직접 입력하고, TimescaleDB 비밀번호는 Secret 을 지우고 다시 만들어도 이미 초기화된 DB 에는 반영되지 않습니다.
{: .prompt-warning }

- **확인:** 허브 `kubectl -n timescaledb get secret timescaledb-credentials`, `kubectl -n monitoring get secret grafana-timescale` 에 Secret 2개, 엣지 `kubectl --kubeconfig k8s-[SITE].yaml get secret -A | grep -E 'mosquitto-passwd|-credentials|grafana-' | grep -v backup` 에 `mosquitto-passwd`, `zigbee2mqtt-credentials`, `telegraf-credentials`, `timescaledb-credentials`, `grafana-timescale`, `grafana-admin` 6개가 보입니다.

## 2. 허브: Grafana 데이터소스

허브 DB 는 selector 가 없는 Service `timescaledb` 로 접속합니다. Patroni 가 이 Service 의 Endpoints 에 지금 주 DB 의 주소를 적으므로, 주 DB 가 바뀌어도 클러스터 안에서는 `timescaledb.timescaledb.svc.cluster.local:5432`, 엣지에서는 NodePort `[HUB_VIP]:30432` 로 그대로 붙습니다. Grafana 용 읽기 전용 role `grafana` 와 Telegraf 가 나중에 만들 테이블까지 읽을 수 있는 기본 권한은 DB 를 처음 만들 때 Patroni 의 bootstrap 스크립트가 걸어 둡니다.

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

Mosquitto 는 계정 없는 접속을 막고 persistence 를 켭니다. Service 는 `LoadBalancer` 로 두고 지역 오버레이가 서비스 VIP 를 지정하면, 엣지의 kube-vip 가 그 VIP 의 1883 을 열어 주어 LAN 기기가 표준 포트로 붙습니다.

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
# LAN 의 기기(ESPHome, 서버의 Telegraf 등)와 디버깅용 mosquitto_sub 이 [엣지 VIP]:1883 표준 포트로 붙습니다. VIP 는 지역 오버레이가 kube-vip.io/loadbalancerIPs 로 줍니다.
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

Telegraf 설정 하나를 모든 지역이 공유합니다. 지역 이름과 허브 DB 주소는 env 로 받고, 계정은 Secret 에서 env 로 받아 설정 안의 `${VAR}` 에 채웁니다. 지역 DB 주소는 같은 클러스터의 Service 이름이라 베이스에 적어 둡니다. 출력은 테이블마다 두 개씩, 지역 DB 가 먼저이고 허브 DB 가 두 번째이며 테이블 정의(`create_templates`)는 같습니다. 핵심은 세 가지입니다. `buffer_strategy = "disk"` 로 DB 에 못 보낸 데이터를 출력마다 PVC 에 쌓고, `json_time_key` 로 페이로드의 `last_seen` 을 행의 시각으로 쓰며, `startup_error_behavior = "retry"` 로 DB 가 안 닿는 상태에서 파드가 떠도 종료하지 않게 합니다. 마지막 설정이 없으면 기본 동작이 "연결 실패 시 종료" 라서, 허브 단절 중 파드가 재시작되면 버퍼링조차 못 하고 크래시 루프에 빠집니다.

입력은 `name_override = "readings"` 로 모두 같은 테이블에 보내고, starlark 프로세서가 메시지의 필드 하나를 행 하나로 쪼갭니다. Zigbee2MQTT 메시지 `{"temperature": 21.5, "humidity": 40}` 은 `property` 가 `temperature`, `humidity` 인 두 행이 됩니다. 수집기마다 다른 메시지 모양은 입력 블록과 이 프로세서에서만 흡수하므로, 나중에 Zigbee2MQTT 를 다른 수집기로 바꿔도 입력 블록만 새로 쓰면 되고 테이블과 대시보드는 그대로입니다.

수집은 **모두 수집**이 기본입니다. 감도·보정값 같은 기기 설정과 펌웨어 업데이트 정보도 측정값과 똑같이 행으로 남깁니다. 설정이 바뀌면 같은 상황에서도 값이 달라지기 때문입니다. 메시지마다 같은 값이 반복되는 기기 정보(`device{…}`)만 버리고, 대신 기기 정의(`bridge/devices`)에서 값이 바뀔 때만 `device_software_build_id` 같은 행으로 남깁니다. 기기로 간 명령(`zigbee2mqtt/[기기]/set`)은 `name_override = "events"` 로 `events` 테이블용 출력이 받습니다. Home Assistant 가 재발행한 Matter 기기 상태와 제어 기록을 받는 입력 두 개(`hass/…`)는 [Home Assistant 글](/posts/48/)에서, 서버·PC 자체의 부하·연결 상태와 발견 설정을 받는 입력 세 개(`hosts/…`, `homeassistant/…/config`)는 [호스트 부하 글](/posts/74/)에서 추가하므로 아래 파일에서는 빠져 있습니다. NVR 재실자(`nvr/…`)와 바깥 날씨(`weather/…`) 입력도 빠져 있으며, 각각 [NVR 글](/posts/76/)과 [날씨 글](/posts/52/)의 수집기가 내는 토픽을 받습니다. starlark 의 발견 설정 처리(`host_sensors`)는 그 입력이 없으면 쓰이지 않습니다.

브리지 연결 상태 입력(`zigbee2mqtt/bridge/state`, `homeassistant/status`)은 들어 있습니다. Zigbee2MQTT 나 Home Assistant 자체가 끊기면 그 아래 기기 값이 멈추지만 기기마다 `offline` 이 오지 않으므로, starlark(`bridge_status`)가 기억해 둔 기기마다 `availability` 가 `offline` 인 행을 만듭니다. Zigbee 기기는 기기 정의(`bridge/devices`)에서 배우므로 이 파일만으로 동작하고, Matter 기기는 `hass/…` 입력으로 받은 기기만 기억하므로 Home Assistant 글의 입력을 더하기 전에는 `homeassistant/status` 가 행을 만들지 않습니다.

{% raw %}
```toml
# 엣지 Telegraf. env 는 Secret telegraf-credentials(MQTT_USER, MQTT_PASSWORD, LOCAL_PG_PASSWORD, HUB_PG_PASSWORD)와
# 베이스·오버레이(SITE, LOCAL_PG_HOST, HUB_PG_HOST, HUB_PG_PORT)가 넣습니다.
# 같은 행을 지역 DB(첫 번째, 지역 Grafana 가 봄)와 허브 DB(두 번째, 모든 지역을 모아 봄)에 씁니다. 출력마다 디스크 버퍼가 따로 있어
# 한쪽이 끊겨도 다른 쪽은 계속 받고, 끊긴 쪽은 다시 닿으면 쌓인 것부터 채웁니다.
[global_tags]
  site = "${SITE}"                    # 모든 행에 지역 이름. 허브에서 지역이 섞여도 구분됩니다
  processing = "raw"                  # 기기가 보낸 값 그대로입니다. 보정(corrected)·계산(derived) 값은 허브의 가공 스크립트가 새 행으로 넣습니다

[agent]
  interval = "10s"                    # 입력이 push 라 수집 주기는 의미 없고 flush 주기만 유효합니다
  flush_interval = "10s"
  metric_batch_size = 1000
  metric_buffer_limit = 500000        # 출력별 상한(건). DB 가 안 닿는 동안 이만큼 디스크에 쌓고, 넘치면 오래된 것부터 버립니다
  buffer_strategy = "disk"            # 파드가 재시작해도 버퍼가 남습니다
  buffer_directory = "/var/lib/telegraf/buffer"
  omit_hostname = true                # 파드 이름이 태그로 붙지 않게 합니다
  skip_processors_after_aggregators = true   # 집계기를 쓰지 않습니다 (1.40 기본값 변경 경고를 없앰)

# 모든 기기 값은 테이블 readings 하나에 "행 하나 = 기기 하나의 속성 하나" 로 들어갑니다.
# 수집기(Zigbee2MQTT, Home Assistant …)마다 다른 메시지 모양은 입력과 아래 starlark 에서만 흡수하므로, 수집기를 바꿔도 입력 블록만 새로 쓰면 됩니다.
#   컬럼 순서: time, site, room, device, anchor, property, processing, value, unit, value_text, protocol, source, vendor, model, hw_id, node (아래 create_templates)
#   기기 이름 <방>-<종류>[-<기준>][번호] 는 - 에서 나눠 room(방), device(종류), anchor(기준, 없으면 비움)에 넣습니다. 번호는 마지막 칸에 붙어 들어갑니다.
#   device 는 방마다 겹칠 수 있고 실물 식별은 hw_id 가 맡습니다
#   필드(컬럼): value(숫자. on/off·true/false·online/offline 은 1/0), value_text(문자열 원문)
#   기기 연결 상태는 property 가 availability 인 행입니다(value_text online/offline, value 1/0). Zigbee2MQTT·호스트·NVR·날씨 수집기가 기기마다 알리고,
#   Zigbee2MQTT 브리지나 Home Assistant 자체가 끊기면 그 아래 기기 모두의 offline 행을 여기서 만듭니다(아래 bridge_status).
#   대시보드는 온라인인 동안 마지막 값이 유지된 것으로, offline 부터 다음 값까지는 공백으로 그립니다
#   processing 은 원본(raw)·보정(corrected)·계산(derived) 구분입니다. 이 Telegraf 는 raw 만 넣고, 원본 행은 고치지 않습니다
#   unit 은 기기 정의의 단위입니다(Zigbee2MQTT bridge/devices 의 exposes, HA 의 unit_of_measurement). 단위가 없는 값(presence 등)은 비어 있습니다
#   exposes 에 빠진 속성은 아래 Z2M_EXTRA_UNITS 로 채웁니다. 재시작 직후 기기 정의보다 먼저 온 메시지는 unit 이 비어 들어가고,
#   DB 작업 dedup_readings 가 같은 시계열의 단위로 채웁니다(iot/hub/timescaledb/migrations/2026-09-28-readings-dedup-job.sql)

# Zigbee2MQTT 기기 메시지. 한 단계(+)만 구독하면 bridge/#, <기기>/set|get|availability 는 자연히 빠집니다 (friendly_name 에 / 를 쓰지 않는 전제). availability 는 아래 입력이 받습니다.
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
  # 기기 설정(보정값, 감도, 표시등 …)과 펌웨어 업데이트(update_state, update_installed_version …)도 값과 똑같이 기록합니다.
  # 감도·보정이 바뀌면 같은 상황에서도 값이 달라지므로 그 이력이 필요합니다.
  # device{…} 는 메시지마다 같은 값이 반복되므로 여기서 버리고, 아래 기기 정의 입력이 바뀔 때만 device_<키> 행으로 남깁니다
  fieldexclude = ["device_*"]
  [inputs.mqtt_consumer.tags]
    protocol = "zigbee"
    source = "z2m"
  [[inputs.mqtt_consumer.topic_parsing]]
    topic = "zigbee2mqtt/+"
    tags = "_/device"                 # friendly_name → device 컬럼
  [inputs.mqtt_consumer.tagdrop]
    device = ["bridge"]

# Zigbee2MQTT 기기 정의(유지 메시지). 아래 starlark 가 기기·속성별 단위와 실물 정보(IEEE 주소, 모델, 제조사)를 기억해 두고
# 기기 메시지에 unit 으로, 연결 상태 메시지에 hw_id·model·vendor 로 붙입니다.
# 기기 정보(software_build_id, date_code, power_source, network_address …)는 기억해 둔 값과 달라진 것만 device_<키> 행으로 남깁니다(시각은 수신 시각).
# Telegraf 가 재시작하면 기억이 비므로 그때 한 번은 모두 다시 들어옵니다.
# 기기를 추가하거나 이름을 바꾸면 Zigbee2MQTT 가 다시 발행합니다. Telegraf 재시작 직후 이보다 먼저 온 메시지 몇 개는 이 값들이 비어 들어가고,
# DB 작업 dedup_readings 가 1시간 안에 같은 시계열의 값으로 채웁니다.
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.mosquitto.svc.cluster.local:1883"]
  topics = ["zigbee2mqtt/bridge/devices"]
  username = "${MQTT_USER}"
  password = "${MQTT_PASSWORD}"
  client_id = "telegraf-z2m-devices"
  qos = 1
  topic_tag = ""
  name_override = "z2m_devices"
  data_format = "value"
  data_type = "string"                # JSON 전체를 문자열 필드 value 하나로 받아 starlark 가 풉니다

# Zigbee2MQTT 기기 연결 상태(유지 메시지 {"state": "online"|"offline"}). 속성 availability 인 행 하나가 됩니다.
# 기기 시각이 없어 수신 시각으로 남습니다. offline 은 마지막 메시지에서 제한 시간(availability timeout)이 지난 시각입니다.
# 유지 메시지라 Telegraf 가 다시 접속하면 지금 상태가 한 번 더 들어옵니다. 기기 정보가 없어 hw_id·model·vendor 는 starlark 가 기기 정의에서 채웁니다.
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.mosquitto.svc.cluster.local:1883"]
  topics = ["zigbee2mqtt/+/availability"]
  username = "${MQTT_USER}"
  password = "${MQTT_PASSWORD}"
  client_id = "telegraf-z2m-availability"
  persistent_session = true
  qos = 1
  topic_tag = ""
  name_override = "readings"
  data_format = "json"
  json_string_fields = ["state"]
  [inputs.mqtt_consumer.tags]
    protocol = "zigbee"
    source = "z2m"
    property = "availability"
  [[inputs.mqtt_consumer.topic_parsing]]
    topic = "zigbee2mqtt/+/availability"
    tags = "_/device/_"

# Zigbee2MQTT 브리지와 Home Assistant 자신의 연결 상태. 둘이 끊기면 그 아래 기기 값이 멈추지만 기기마다 offline 이 오지 않으므로,
# 아래 starlark(bridge_status)가 기억해 둔 기기마다 availability 행을 만듭니다.
#   zigbee2mqtt/bridge/state  유지 메시지 {"state": "online"|"offline"}. offline 은 Z2M 의 Last Will 입니다.
#                             다시 online 이 되면 Z2M 이 기기마다 availability 를 다시 알리므로 여기서는 offline 만 만듭니다
#   homeassistant/status      HA MQTT 통합의 birth(online)·Last Will(offline). 유지 메시지가 아닙니다. Matter 기기는 HA 를 거쳐서만 오므로
#                             offline 과 다시 online 을 모두 만듭니다
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.mosquitto.svc.cluster.local:1883"]
  topics = ["zigbee2mqtt/bridge/state", "homeassistant/status"]
  username = "${MQTT_USER}"
  password = "${MQTT_PASSWORD}"
  client_id = "telegraf-bridge-status"
  persistent_session = true
  qos = 1
  topic_tag = "topic"
  name_override = "bridge_status"
  data_format = "value"
  data_type = "string"

# Zigbee2MQTT 로 간 명령(zigbee2mqtt/<기기>/set). HA 를 거치지 않은 MQTT 명령까지 남습니다. 명령의 필드 하나(state, brightness …)가 행 하나이고,
# property 는 필드 이름, action 은 보낸 값입니다. 보낸 쪽을 알 수 없어 origin 은 mqtt, 시각은 수신 시각입니다.
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.mosquitto.svc.cluster.local:1883"]
  topics = ["zigbee2mqtt/+/set"]
  username = "${MQTT_USER}"
  password = "${MQTT_PASSWORD}"
  client_id = "telegraf-z2m-set"
  persistent_session = true
  qos = 1
  topic_tag = ""
  name_override = "events"
  data_format = "json"
  json_string_fields = ["*"]
  [inputs.mqtt_consumer.tags]
    protocol = "zigbee"
    source = "z2m"
    origin = "mqtt"
  [[inputs.mqtt_consumer.topic_parsing]]
    topic = "zigbee2mqtt/+/set"
    tags = "_/device/_"

# 필드 하나를 행 하나로 쪼개고 값을 value(숫자)와 value_text(문자열)로 나눕니다. 실물 기기 태그 이름도 여기서 통일합니다.
# 메시지에 property 태그가 있으면(HA) 그 값이 속성 이름이고, 없으면(Zigbee2MQTT) 필드 이름이 속성 이름입니다.
# 단위는 HA 메시지에는 unit 태그로 실려 오고, Zigbee2MQTT 는 기기 정의(z2m_devices)에서, 호스트는 발견 설정(host_sensors)에서 기억해 둔 값을 붙입니다.
# 호스트는 발견 설정이 아직 없으면 필드 이름 끝으로 정합니다(HOST_UNITS).
# Zigbee2MQTT 연결 상태 메시지처럼 실물 정보가 없는 메시지에도 기기 정의에서 기억해 둔 hw_id·model·vendor 를 붙입니다.
# 기기 정의에서는 기기 정보가 바뀐 것만 device_<키> 행으로 냅니다. 제어 기록(events)은 이름만 나누고 필드는 그대로 둡니다(z2m set 은 필드마다 행).
[[processors.starlark]]
  namepass = ["readings", "z2m_devices", "events", "host_sensors", "bridge_status"]
  order = 1
  source = '''
load("json.star", "json")
load("time.star", "time")

HW_TAGS = {"device_ieeeAddr": "hw_id", "serial": "hw_id", "device_model": "model", "device_manufacturerName": "vendor"}
ON_OFF = {"on": 1.0, "off": 0.0, "true": 1.0, "false": 0.0, "online": 1.0, "offline": 0.0}
NAME_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789_"
DEVICE_INFO_SKIP = ["friendly_name", "ieee_address"]   # 이미 device·hw_id 컬럼에 들어가는 값

def valid_name(name):
    # <방>-<종류>[-<기준>][번호]. 칸은 - 로 나누고 칸 안의 단어는 _ 로 잇는 영문 소문자·숫자입니다.
    # 페어링 직후 이름(0x…)과 HA 기본 이름(공백·대문자), 교체한 옛 기기(retired-…)는 기록하지 않습니다
    parts = name.split("-")
    if len(parts) not in (2, 3) or parts[0] == "retired":
        return False
    return all([p != "" and all([c in NAME_CHARS for c in p.elems()]) for p in parts])

def split_name(tags):
    # bedroom2-th-door → room bedroom2, device th, anchor door
    parts = tags["device"].split("-")
    tags["room"] = parts[0]
    tags["device"] = parts[1]
    if len(parts) == 3:
        tags["anchor"] = parts[2]

def is_number(s):
    if not s or s.count(".") > 1:
        return False
    body = s[1:] if s[0] in "+-" else s
    return len(body) > 0 and all([c in "0123456789." for c in body.elems()]) and body != "."

def set_value(m, v, keep_text=False):
    # 값을 value(숫자)와 value_text(문자열)로 나눕니다. 값이 비어 있으면 False 를 돌려줍니다
    # keep_text 면 숫자로 읽히는 문자열도 value_text 에 원문을 남깁니다(펌웨어 빌드 ID 0129… 의 앞자리 0 등)
    if type(v) == "bool":
        m.fields["value"] = 1.0 if v else 0.0
        m.fields["value_text"] = "true" if v else "false"
    elif type(v) in ("int", "float"):
        m.fields["value"] = float(v)
    else:
        s = str(v).strip()
        if s == "":
            return False
        if is_number(s):
            m.fields["value"] = float(s)
            if keep_text:
                m.fields["value_text"] = s
        else:
            m.fields["value_text"] = s
            if s.lower() in ON_OFF:
                m.fields["value"] = ON_OFF[s.lower()]
    return True

def clean_tags(metric):
    tags = {}
    for k, v in metric.tags.items():
        if v != "":
            tags[HW_TAGS.get(k, k)] = v
    return tags

# 기기 정의(exposes)에 없지만 기기가 보내는 속성의 단위(모델별). exposes 에 있으면 그쪽이 우선입니다.
# voltage 는 플러그가 V, 전지 센서가 mV 라 속성 이름만으로 정하지 않고 모델마다 적습니다
Z2M_EXTRA_UNITS = {"KKZ-DO021": {"voltage": "mV"}}

def collect_units(expose, units):
    # exposes 는 features 안에 다시 exposes 가 들어 있을 수 있습니다(light, climate 등)
    if expose.get("property") and expose.get("unit"):
        units[expose["property"]] = expose["unit"]
    for f in expose.get("features", []):
        collect_units(f, units)

def remember_devices(metric):
    # 태그 값은 기기 메시지의 device{…}와 같게 맞춥니다: model 은 기기 정의의 모델, vendor 는 기기가 알리는 제조사
    units, hw = {}, {}
    seen = state.get("device_info", {})
    out = []
    for d in json.decode(metric.fields["value"]):
        name = d.get("friendly_name", "")
        definition = d.get("definition") or {}
        u = {}
        for e in definition.get("exposes", []):
            collect_units(e, u)
        for k, v in Z2M_EXTRA_UNITS.get(definition.get("model") or "", {}).items():
            if k not in u:
                u[k] = v
        units[name] = u
        hw[name] = {"hw_id": d.get("ieee_address") or "", "model": definition.get("model") or "", "vendor": d.get("manufacturer") or ""}
        info = {}
        for k, v in d.items():
            if k not in DEVICE_INFO_SKIP and type(v) not in ("dict", "list"):
                info[k] = v
        old = seen.get(name, {})
        seen[name] = info
        if not valid_name(name):
            continue
        for k, v in info.items():
            if k in old and old[k] == v:
                continue
            m = Metric("readings")
            m.time = metric.time
            tags = clean_tags(metric)
            tags.update({"device": name, "protocol": "zigbee", "source": "z2m", "property": "device_" + k})
            for tk, tv in hw[name].items():
                if tv != "":
                    tags[tk] = tv
            split_name(tags)
            for tk, tv in tags.items():
                m.tags[tk] = tv
            if set_value(m, v, keep_text=True):
                out.append(m)
    state["device_info"] = seen
    state["units"] = units
    state["hw"] = hw
    return out

# 호스트 값(source telegraf)의 예비 단위. 발견 설정에서 배운 단위가 우선이고, 설정이 아직 오지 않았을 때(새 필드가 생긴 직후, Telegraf 재시작 직후)
# 필드 이름 끝으로 정합니다. 필드 이름은 <부품>_<값> 규칙이고, 값은 proxmox-ansible scripts/host-metrics-discovery.py 의 SENSORS 표와 같아야 합니다.
# _percent 를 _used 보다 먼저 봅니다(mem_used_percent 가 B 로 잡히지 않게). 여기 없는 끝(_load, _cores, _threads, _ok)은 단위가 없습니다
HOST_UNITS = [("_percent", "%"), ("_usage", "%"), ("_temp", "°C"), ("_power", "W"), ("_clock", "MHz"),
              ("_used", "B"), ("_total", "B"), ("_uptime", "s")]

def host_unit(field):
    for end, unit in HOST_UNITS:
        if field.endswith(end):
            return unit
    return ""

# 발견 설정 origin → 그 값을 내는 입력의 source 태그
SENSOR_ORIGINS = {"host-metrics": "telegraf", "nvr-occupancy": "nvr", "kma-weather": "kma"}

def remember_host_sensor(metric):
    # homeassistant/<구성요소>/<기기>/<필드>/config 중 호스트 Telegraf·NVR·날씨 수집기가 낸 것만. 빈 메시지는 센서가 지워진 것입니다
    raw = metric.fields.get("value", "")
    if not raw:
        return []
    c = json.decode(raw)
    source = SENSOR_ORIGINS.get((c.get("origin") or {}).get("name"))
    if not source:
        return []
    state.setdefault("sensors_seen", {}).setdefault(source, now())
    device = (c.get("device") or {}).get("name", "")
    field = c.get("unique_id", "")[len(device) + 1:]
    units = state.setdefault("host_units", {}).setdefault(source + "/" + device, {})
    if c.get("unit_of_measurement"):
        units[field] = c["unit_of_measurement"]
    d = c.get("device") or {}
    # serial_number 는 호스트의 메인보드 시리얼, 카메라의 MAC 주소, 날씨의 기상청 지점 번호입니다. 다른 기기의 IEEE 주소·Matter 시리얼과 같은 자리(hw_id)에 넣어 실물 교체 이력이 남습니다
    state.setdefault("host_hw", {})[source + "/" + device] = {"vendor": d.get("manufacturer") or "", "model": d.get("model") or "",
                                                              "hw_id": d.get("serial_number") or ""}
    return []

# 브리지(Zigbee2MQTT, Home Assistant) 토픽 → 그 아래 기기 행의 source·protocol
BRIDGES = {"zigbee2mqtt/bridge/state": ("z2m", "zigbee"), "homeassistant/status": ("hass", "matter")}

def bridge_devices(source):
    # 기억해 둔 기기 이름 → 실물 정보. z2m 은 기기 정의(bridge/devices), hass 는 지금까지 받은 hass 기기 행에서 배웁니다
    if source == "z2m":
        return state.get("hw", {})
    return state.get("hass_devices", {})

def bridge_status(metric):
    # 브리지가 offline 이 되면(또는 HA 가 다시 online 이 되면) 그 아래 기기마다 availability 행을 만듭니다. 상태가 그대로면 만들지 않습니다
    source, protocol = BRIDGES.get(metric.tags.get("topic", ""), (None, None))
    raw = metric.fields.get("value", "").strip()
    if not source or not raw:
        return []
    status = (json.decode(raw).get("state", "") if raw.startswith("{") else raw).lower()
    last = state.setdefault("bridge_state", {})
    previous = last.get(source)
    last[source] = status
    if status == previous or status not in ("online", "offline"):
        return []
    if status == "online" and (source == "z2m" or previous == None):
        return []                     # Z2M 은 기기마다 다시 알리고, 처음 받은 online 은 바뀐 것이 아닙니다
    base = clean_tags(metric)
    base.pop("topic", None)
    out = []
    for name, hw in bridge_devices(source).items():
        if not valid_name(name):
            continue
        m = Metric("readings")
        m.time = metric.time
        tags = dict(base)
        tags.update({"device": name, "protocol": protocol, "source": source, "property": "availability"})
        for k, v in hw.items():
            if v != "":
                tags[k] = v
        split_name(tags)
        for k, v in tags.items():
            m.tags[k] = v
        set_value(m, status)
        out.append(m)
    return out

def event(metric):
    tags = clean_tags(metric)
    if "device" in tags:
        if not valid_name(tags["device"]):
            return []                 # 이름 규칙에 맞지 않는 기기로 간 명령은 readings 와 같이 버립니다
        split_name(tags)
    if tags.get("source") == "z2m" and "hw_id" not in tags:
        for k, v in state.get("hw", {}).get(metric.tags.get("device", ""), {}).items():
            if v != "":
                tags[k] = v
    for k in list(metric.tags.keys()):
        metric.tags.pop(k)
    for k, v in tags.items():
        metric.tags[k] = v
    if tags.get("source") != "z2m":
        return metric
    out = []                          # z2m set: {"state": "ON", "brightness": 120} → 필드마다 행(property=필드, action=값)
    for k, v in metric.fields.items():
        m = Metric("events")
        m.time = metric.time
        for tk, tv in tags.items():
            m.tags[tk] = tv
        m.tags["property"] = k
        m.fields["action"] = str(int(v)) if type(v) == "float" and v == int(v) else str(v)
        out.append(m)
    return out

# 기동 직후 붙잡아 두기. 단위·실물 정보는 유지 메시지(Zigbee2MQTT bridge/devices, 호스트·NVR 의 HA 발견 설정)에서 배워 메모리에 두므로
# Telegraf 가 재시작하면 비어 있고, 입력마다 MQTT 클라이언트가 달라 기기 값이 이 메시지보다 먼저 올 수 있습니다(도착 순서는 보장되지 않습니다).
# 그래서 배운 정보가 필요한 수집기(LEARNED_SOURCES)의 값은 정보가 갖춰질 때까지 원본 사본을 붙잡아 두었다가 그때 행으로 만듭니다.
#   z2m: bridge/devices 를 한 번 받으면 모든 기기가 갖춰집니다
#   telegraf·nvr: 발견 설정은 필드마다 따로 오고 끝났다는 신호가 없어, 그 수집기의 것을 처음 받은 뒤 SETTLE_SECONDS 가 지나면 갖춰진 것으로 봅니다
#   (유지 메시지라 구독하자마자 한꺼번에 옵니다)
# 어느 경우든 기동 뒤 WARMUP_SECONDS 가 지나면 모두 내보냅니다(정보가 끝내 오지 않아도 값은 잃지 않습니다). 붙잡은 원본은 브로커에 전달 완료로 알리므로,
# 이 사이에 Telegraf 가 죽으면 붙잡은 값은 잃습니다(정상 종료·재시작 직후 몇 초 사이만 해당). 기동 직후가 아닌 때 새 기기·필드가 생겨 빈 값이 들어가면
# DB 작업 dedup_readings 가 같은 시계열의 값으로 채웁니다(iot/hub/timescaledb/migrations/2026-09-28-readings-dedup-job.sql).
LEARNED_SOURCES = ["z2m", "telegraf", "nvr", "kma"]
WARMUP_SECONDS = 30
SETTLE_SECONDS = 5
HOLD_LIMIT = 100000                   # 붙잡는 메시지 상한. 넘으면 기다리지 않고 바로 내보냅니다(브로커가 쌓아 둔 메시지가 한꺼번에 올 때)

def now():
    return time.now().unix

def learned_ready(source):
    started = state.setdefault("started", now())
    if now() - started >= WARMUP_SECONDS:
        return True
    if source == "z2m":
        return "units" in state
    first = state.get("sensors_seen", {}).get(source)
    return first != None and now() - first >= SETTLE_SECONDS

def must_hold(metric):
    if metric.name == "bridge_status":
        source = BRIDGES.get(metric.tags.get("topic", ""), ("", ""))[0]   # 기기 목록을 배운 뒤에 기기마다 행을 만듭니다
    elif metric.name in ("readings", "events"):
        source = metric.tags.get("source", "")
    else:
        return False
    return source in LEARNED_SOURCES and not learned_ready(source) and len(state.get("held", [])) < HOLD_LIMIT

def release():
    held = state.get("held", [])
    if not held:
        return []
    out, keep = [], []
    for m in held:
        source = BRIDGES.get(m.tags.get("topic", ""), ("", ""))[0] if m.name == "bridge_status" else m.tags.get("source", "")
        if learned_ready(source) or len(held) >= HOLD_LIMIT:
            out.extend(as_list(shape(m)))
        else:
            keep.append(m)
    state["held"] = keep
    return out

def as_list(r):
    if r == None:
        return []
    return r if type(r) == "list" else [r]

def apply(metric):
    state.setdefault("started", now())
    if must_hold(metric):
        state.setdefault("held", []).append(deepcopy(metric))   # 추적 정보가 없는 사본. 원본은 전달 완료로 처리됩니다
        return release()
    return as_list(shape(metric)) + release()

def shape(metric):
    if metric.name == "z2m_devices":
        return remember_devices(metric)
    if metric.name == "host_sensors":
        return remember_host_sensor(metric)
    if metric.name == "events":
        return event(metric)
    if metric.name == "bridge_status":
        return bridge_status(metric)
    tags = clean_tags(metric)
    if not valid_name(tags.get("device", "")):
        return []                     # 이름이 없거나(옛 형식의 유지 메시지 등) 이름 규칙에 맞지 않는 기기는 버립니다
    name = tags["device"]
    learned = tags.get("source") in ("telegraf", "nvr", "kma")    # 발견 설정에서 단위·실물 정보를 배운 기기
    if learned:
        units = state.get("host_units", {}).get(tags["source"] + "/" + name, {})
        for k, v in state.get("host_hw", {}).get(tags["source"] + "/" + name, {}).items():
            if v != "":
                tags[k] = v
    else:
        units = state.get("units", {}).get(name, {})
    if tags.get("source") == "z2m" and "hw_id" not in tags:
        for k, v in state.get("hw", {}).get(name, {}).items():
            if v != "":
                tags[k] = v
    if tags.get("source") == "hass":   # HA 가 끊길 때 기기마다 offline 행을 만들려고 기억합니다(bridge_status)
        state.setdefault("hass_devices", {})[name] = {k: tags.get(k, "") for k in ("hw_id", "model", "vendor", "node")}
    split_name(tags)
    prop = tags.pop("property", None)
    out = []
    for k, v in metric.fields.items():
        m = Metric(metric.name)
        m.time = metric.time
        for tk, tv in tags.items():
            m.tags[tk] = tv
        m.tags["property"] = prop or k
        if "unit" not in tags and units.get(m.tags["property"]):
            m.tags["unit"] = units[m.tags["property"]]
        elif "unit" not in tags and tags.get("source") == "telegraf" and host_unit(m.tags["property"]):
            m.tags["unit"] = host_unit(m.tags["property"])
        if set_value(m, v):
            out.append(m)
    return out
'''

# 지역 TimescaleDB(iot/edge/timescaledb). 아래 허브 출력과 테이블 정의가 같습니다(두 곳을 함께 고칩니다).
[[outputs.postgresql]]
  namepass = ["readings"]
  connection = "host=${LOCAL_PG_HOST} port=5432 user=iot password=${LOCAL_PG_PASSWORD} dbname=iot sslmode=disable connect_timeout=10"
  startup_error_behavior = "retry"    # DB 가 안 닿는 상태로 파드가 떠도 종료하지 않고 버퍼에 쌓으며 연결을 재시도합니다 (기본값은 종료)
  tags_as_foreign_keys = false
  timestamp_column_type = "timestamp with time zone"
  create_templates = [
    '''CREATE TABLE {{ .table }} (time timestamptz NOT NULL, site text, room text, device text, anchor text, property text,
        processing text NOT NULL CHECK (processing IN ('raw', 'corrected', 'derived')), value double precision, unit text, value_text text,
        protocol text, source text, vendor text, model text, hw_id text, node text)''',
    '''SELECT create_hypertable({{ .table|quoteLiteral }}, 'time', chunk_time_interval => INTERVAL '1d')''',
    '''ALTER TABLE {{ .table }} SET (timescaledb.compress, timescaledb.compress_segmentby = 'site, room, device, anchor, property, processing', timescaledb.compress_orderby = 'time DESC')''',
    '''SELECT add_compression_policy({{ .table|quoteLiteral }}, INTERVAL '1d')''',
    '''CREATE INDEX ON {{ .table }} (property, time DESC)''',   # 대시보드가 속성 하나씩 읽습니다(migrations/2026-09-30-readings-property-index.sql)
  ]

[[outputs.postgresql]]
  namepass = ["events"]
  tagexclude = ["processing"]
  connection = "host=${LOCAL_PG_HOST} port=5432 user=iot password=${LOCAL_PG_PASSWORD} dbname=iot sslmode=disable connect_timeout=10"
  startup_error_behavior = "retry"
  tags_as_foreign_keys = false
  timestamp_column_type = "timestamp with time zone"
  create_templates = [
    '''CREATE TABLE {{ .table }} (time timestamptz NOT NULL, site text, room text, device text, anchor text, property text,
        action text, data text, origin text, actor text, context_id text, parent_id text,
        protocol text, source text, vendor text, model text, hw_id text, node text)''',
    '''SELECT create_hypertable({{ .table|quoteLiteral }}, 'time', chunk_time_interval => INTERVAL '7d')''',
    '''ALTER TABLE {{ .table }} SET (timescaledb.compress, timescaledb.compress_segmentby = 'site, room, device, anchor, property', timescaledb.compress_orderby = 'time DESC')''',
    '''SELECT add_compression_policy({{ .table|quoteLiteral }}, INTERVAL '30d')''',
  ]

# 허브 TimescaleDB(두 번째 출력). 태그를 외래 키 테이블로 빼지 않고 컬럼으로 두어 지역 간 병합과 중복 제거가 쉽게 합니다.
# 테이블은 컬럼 순서를 정해 두려고 직접 만들고, 이후 새 태그는 Telegraf 가 끝에 컬럼으로 붙입니다.
# 압축은 시계열 하나(site, room, device, anchor, property, processing)끼리 묶어 값이 비슷한 것끼리 모이게 합니다.
# 청크와 압축은 1일 단위입니다. 호스트 값(hosts/+)이 호스트마다 10초에 100여 행이라, 압축 전 데이터가 하루치 넘게 쌓이지 않게 합니다.
# 압축된 청크에도 INSERT·UPDATE·DELETE 는 되므로(늦게 온 버퍼, 날씨 백필, 보정) 느려질 뿐 막히지 않습니다.
# 이미 있는 테이블은 iot/hub/timescaledb/migrations/2026-09-28-readings-compress-1d.sql 과 2026-09-30-readings-property-index.sql 로 바꿉니다(지역·허브 DB 모두).
[[outputs.postgresql]]
  namepass = ["readings"]
  connection = "host=${HUB_PG_HOST} port=${HUB_PG_PORT} user=iot password=${HUB_PG_PASSWORD} dbname=iot sslmode=disable connect_timeout=10"
  startup_error_behavior = "retry"    # 허브가 안 닿는 상태로 파드가 떠도 종료하지 않고 버퍼에 쌓으며 연결을 재시도합니다 (기본값은 종료)
  tags_as_foreign_keys = false
  timestamp_column_type = "timestamp with time zone"
  create_templates = [
    '''CREATE TABLE {{ .table }} (time timestamptz NOT NULL, site text, room text, device text, anchor text, property text,
        processing text NOT NULL CHECK (processing IN ('raw', 'corrected', 'derived')), value double precision, unit text, value_text text,
        protocol text, source text, vendor text, model text, hw_id text, node text)''',
    '''SELECT create_hypertable({{ .table|quoteLiteral }}, 'time', chunk_time_interval => INTERVAL '1d')''',
    '''ALTER TABLE {{ .table }} SET (timescaledb.compress, timescaledb.compress_segmentby = 'site, room, device, anchor, property, processing', timescaledb.compress_orderby = 'time DESC')''',
    '''SELECT add_compression_policy({{ .table|quoteLiteral }}, INTERVAL '1d')''',
    '''CREATE INDEX ON {{ .table }} (property, time DESC)''',   # 대시보드가 속성 하나씩 읽습니다(migrations/2026-09-30-readings-property-index.sql)
  ]

# 허브 TimescaleDB 의 제어 기록 테이블 events. "행 하나 = 기기 하나에 간 명령 하나"(또는 자동화·스크립트 실행 하나)이고 값을 가공하지 않으므로 processing 이 없습니다.
#   컬럼: time, site, room, device, anchor, property, action(switch.turn_off, ON …), data(서비스 데이터 JSON), origin(user|automation|system|mqtt),
#         actor(사람 이름, automation.…), context_id, parent_id(HA context. 자동화 실행 행과 그 자동화가 보낸 명령이 context_id 로 이어집니다), protocol, source, vendor, model, hw_id, node
[[outputs.postgresql]]
  namepass = ["events"]
  tagexclude = ["processing"]
  connection = "host=${HUB_PG_HOST} port=${HUB_PG_PORT} user=iot password=${HUB_PG_PASSWORD} dbname=iot sslmode=disable connect_timeout=10"
  startup_error_behavior = "retry"
  tags_as_foreign_keys = false
  timestamp_column_type = "timestamp with time zone"
  create_templates = [
    '''CREATE TABLE {{ .table }} (time timestamptz NOT NULL, site text, room text, device text, anchor text, property text,
        action text, data text, origin text, actor text, context_id text, parent_id text,
        protocol text, source text, vendor text, model text, hw_id text, node text)''',
    '''SELECT create_hypertable({{ .table|quoteLiteral }}, 'time', chunk_time_interval => INTERVAL '7d')''',
    '''ALTER TABLE {{ .table }} SET (timescaledb.compress, timescaledb.compress_segmentby = 'site, room, device, anchor, property', timescaledb.compress_orderby = 'time DESC')''',
    '''SELECT add_compression_policy({{ .table|quoteLiteral }}, INTERVAL '30d')''',
  ]

# readinessProbe 용. 검사 항목이 없으므로 프로세스가 살아 있으면 200 을 돌려줍니다.
[[outputs.health]]
  service_address = "http://:8888"
  namepass = ["__none__"]
```
{: file="iot/edge/telegraf/telegraf.conf (Home Assistant·호스트·NVR·날씨 입력 제외)" }
{% endraw %}

```yaml
# 엣지 수집기. 브로커의 기기 메시지를 받아 지역 TimescaleDB 와 허브 TimescaleDB 에 쓰고, 안 닿는 쪽은 디스크 버퍼(PVC)에 쌓았다가 밀어 넣습니다.
# 지역 값(site 이름, 허브 DB 주소)은 오버레이가 env 로 넣습니다. 그 밖의 추가 출력은 오버레이가 telegraf-site ConfigMap 을 교체해 *.conf 로 넣습니다.
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
            - secretRef: { name: telegraf-credentials }   # MQTT_USER, MQTT_PASSWORD, LOCAL_PG_PASSWORD, HUB_PG_PASSWORD. GitOps 밖에서 만듭니다 (create-iot-secrets.sh)
          env:
            - { name: LOCAL_PG_HOST, value: timescaledb.timescaledb.svc.cluster.local }   # 지역 DB(iot/edge/timescaledb)
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

`tags_as_foreign_keys = false` 라 태그가 모두 본 테이블의 컬럼이 됩니다. 행 하나만 봐도 어느 지역의 어느 기기인지 알 수 있어 지역 DB 와 허브 DB 를 서로 채우거나 비교하고 중복을 걸러 내기 쉽습니다. 테이블은 첫 메시지가 올 때 Telegraf 가 DB 마다 `create_templates` 대로 만들고(하이퍼테이블. `readings` 는 1일 청크·1일 뒤 압축, `events` 는 7일 청크·30일 뒤 압축), 새 태그가 보이면 끝에 컬럼을 추가합니다. 컬럼 순서를 정해 두려고 `CREATE TABLE` 에 컬럼을 직접 적었으며, 아래 표가 그 순서입니다.

| 컬럼 | 예 | 내용 |
|---|---|---|
| `time` | `2026-09-25 15:51:04+00` | 기록 시각. Zigbee 는 기기 시각(`last_seen`, 연결 상태만 수신 시각), Matter 는 HA 가 상태를 바꾼 시각(`last_changed`) |
| `site` | `daejeon` | 지역 |
| `room` | `bedroom2` | 방. 기기 이름 `<방>-<종류>[-<기준>][번호]` 의 첫 칸 |
| `device` | `th`, `motion2`, `plug` | 기기 종류. 기준이 없으면 번호까지 들어갑니다. 방마다 겹칠 수 있고, 실물 식별은 `hw_id` 가 맡습니다 |
| `anchor` | `door`, `ceil`, `server_ms_a2_1` | 기준. 센서는 방 안에서 둔 자리, 플러그는 꽂은 제품입니다. 이름에 기준 칸이 없으면 비어 있습니다 |
| `property` | `temperature`, `presence`, `availability` | 측정 항목. `availability` 는 기기 연결 상태(`online`/`offline`)로, 기기 시각이 없어 수신 시각으로 남습니다. Zigbee·호스트·NVR·날씨 기기는 기기가 알리는 값이고, 브리지(Zigbee2MQTT·Home Assistant)가 `offline` 이 되면 그 아래 기기마다 `offline` 행이 생깁니다 |
| `processing` | `raw` | 원본(`raw`)·보정(`corrected`)·계산(`derived`) 구분. 이 Telegraf 가 넣는 행은 모두 `raw` 입니다 |
| `value` | `26.3`, `1` | 숫자 값. `on`/`off`, `true`/`false`, `online`/`offline` 은 1/0 |
| `unit` | `°C`, `mV`, `μg/m³` | 단위. Zigbee 는 Zigbee2MQTT 기기 정의(`bridge/devices`), Matter 는 HA 의 `unit_of_measurement` 에서 가져옵니다. 단위가 없는 값(`presence` 등)은 비어 있습니다. 기기 정의에 빠진 속성은 starlark 의 `Z2M_EXTRA_UNITS` 에 모델별로 적습니다 |
| `value_text` | `ON`, `false` | 문자열 원문 |
| `protocol` | `zigbee`, `matter` | 기기 통신 방식 |
| `source` | `z2m`, `hass` | 수집기. 수집기를 바꿔도 `protocol` 은 그대로입니다 |
| `vendor`, `model` | `HOBEIAN`, `ZG-204ZV` | 실물 기기의 제조사와 모델 |
| `hw_id` | `0xa4c138f95fdbf3ad` | 실물 기기의 고유 ID. Zigbee 는 IEEE 주소, Matter 는 시리얼 |
| `node` | `CFEE358179DBE7B6-0000000000000001` | Matter 노드 ID (Matter 만) |

기기 이름이 `<방>-<종류>[-<기준>][번호]` 규칙(칸은 `-` 로 나누고 칸 안의 단어는 `_` 로 잇는 영문 소문자·숫자)에 맞지 않으면 starlark 가 그 메시지를 버립니다. 페어링 직후 Zigbee 기기의 `0x…` 이름, 이름을 정하기 전 Matter 기기의 HA 기본 이름, 교체한 옛 기기의 `retired-…` 이름이 여기에 걸리므로 기기를 추가하면 바로 이름을 붙입니다.

`processing` 은 값이 원본인지 가공한 것인지 나눕니다. 원본 행은 고치지 않고, 센서 편차를 보정한 값이나 평균처럼 계산한 값은 같은 시각·속성에 `corrected`·`derived` 행으로 따로 넣습니다. 그래서 `where processing = 'raw'` 로 원본만, `<> 'raw'` 로 가공 값만 뽑을 수 있습니다. 기본값 없이 `NOT NULL` 과 `CHECK` 제약을 걸어, 가공 스크립트가 구분을 빠뜨리거나 다른 값을 넣으면 INSERT 가 실패합니다.

압축은 `site, room, device, anchor, property, processing` 이 같은 행끼리 묶습니다. 묶음 하나가 시계열 하나(예: 한 기기의 온도)가 되어 값이 비슷한 것끼리 모이므로 압축이 잘 되고, 조회할 때도 필요한 묶음만 풉니다. 청크와 압축은 1일 단위라 압축 전 데이터가 하루치를 넘지 않습니다. 압축된 청크에도 INSERT·UPDATE·DELETE 는 되므로 늦게 도착한 버퍼나 보정은 느려질 뿐 그대로 들어갑니다. 대시보드는 속성 하나씩 읽으므로 `(property, time DESC)` 인덱스를 함께 만들어, 압축 전 청크에서도 그 속성의 행만 읽게 합니다.

Telegraf 가 재시작하면 브로커가 유지 메시지(Zigbee2MQTT 기기 상태 등)를 다시 보내고, 메시지에 실린 원래 시각으로 같은 행이 한 번 더 저장됩니다. MQTT 는 구독할 때마다 유지 메시지를 보내므로 재수신 자체는 막을 수 없고, Telegraf 의 postgresql 출력은 `ON CONFLICT` 를 지원하지 않아 유니크 인덱스를 걸면 배치가 통째로 실패합니다. 그래서 저장한 뒤 정리합니다. 두 DB 에 아래 SQL 을 한 번씩 실행하면 TimescaleDB 작업 `dedup_readings` 가 1시간마다 압축 전 청크에서 같은 `(time, site, room, device, anchor, property, processing)` 를 하나만 남기고 지웁니다. 지우기 전에는 비어 있는 `unit`·`hw_id`·`model`·`vendor` 를 같은 시계열의 최근 25시간 값이 하나뿐일 때 그 값으로 채웁니다. Telegraf 는 단위와 실물 정보를 유지 메시지(`bridge/devices`)에서 배워 메모리에 두기 때문에, 재시작 직후에는 starlark 가 기기 정의가 올 때까지 값을 잠시 붙잡아 두어 빈 행을 막습니다. 채우기는 그 뒤에도 빈 값이 들어가는 경우(기동 직후가 아닌 때 새 기기가 생긴 경우 등)를 위한 것입니다. DB 안에서 도는 작업이라 자격 증명이 필요 없고, Patroni 가 주 DB 를 옮겨도 새 주 DB 에서 이어 돕니다.

<details markdown="1">
<summary>iot/hub/timescaledb/migrations/2026-09-28-readings-dedup-job.sql 전문</summary>

```sql
-- readings 의 빈 unit·hw_id·model·vendor 를 채우고 중복 행을 지우는 1시간 주기 TimescaleDB 작업(dedup_readings)을 만듭니다. 허브 DB 와 지역 DB 모두에 실행합니다(다시 실행해도 결과가 같습니다).
-- 중복이 생기는 까닭: 엣지 Telegraf 가 재시작하면 브로커가 유지(retained) 메시지(Zigbee2MQTT 기기 상태, HA 재발행 상태)를 다시 보내고,
-- 메시지에 실린 원래 시각으로 같은 행이 또 저장됩니다. MQTT 는 구독할 때마다 유지 메시지를 보내므로 재수신 자체는 막을 수 없고,
-- Telegraf 의 postgresql 출력은 ON CONFLICT 를 지원하지 않아 유니크 인덱스를 걸면 배치가 통째로 실패합니다. 그래서 저장한 뒤 정리합니다.
-- events 는 유지 메시지가 아니라(제어 명령·자동화 실행) 대상이 아닙니다.
-- CronJob 이 아니라 DB 작업으로 두어 자격 증명이 필요 없고, Patroni 가 주 DB 를 옮겨도 새 주 DB 에서 이어 돕니다(압축 정책과 같은 방식).
--   허브: kubectl -n timescaledb exec -i timescaledb-0 -- psql -h timescaledb -U iot -d iot -v ON_ERROR_STOP=1 < 2026-09-28-readings-dedup-job.sql
--   지역: kubectl --kubeconfig ~/k8s-<지역>.yaml -n timescaledb exec -i <주 DB 파드> -- psql -U iot -d iot -v ON_ERROR_STOP=1 < 2026-09-28-readings-dedup-job.sql

-- 같은 이유로 재시작 직후에는 Zigbee2MQTT 기기 정의(bridge/devices)보다 먼저 처리된 메시지가 unit·hw_id·model·vendor 없이 들어갑니다
-- (Telegraf 가 기기 정의를 메모리에 기억해 붙이므로 재시작하면 비어 있습니다). 쌍이 없는 유일한 행도 있어 지우기만으로는 남습니다.
-- 그래서 먼저 채웁니다: 시계열 (site, room, device, anchor, property, processing) 의 최근 25시간 다른 행에 빈 값이 아닌 값이 정확히 하나면 그 값으로 채웁니다
-- (기준값은 청크 경계와 상관없이 하이퍼테이블에서 구합니다). 25시간 이전 행은 2026-09-29-readings-fill-empty.sql 이 한 번 채웠습니다.
-- 단위가 원래 없는 속성(presence 등)은 어느 행에도 값이 없어 그대로 둡니다. 이 파일을 다시 실행하면 작업 내용이 갱신됩니다.
-- 이어서 같은 (time, site, room, device, anchor, property, processing) 가 여럿이면 하나만 남깁니다. 단위·값이 채워진 행이 남습니다.
-- 청크 테이블에 직접 실행합니다. 하이퍼테이블 전체에서는 ctid 가 유일하지 않지만 청크 하나는 일반 테이블이라 안전합니다.
-- PARTITION BY 는 NULL 을 한 묶음으로 보므로 anchor 가 없는 기기(bedroom2-th 등)도 정리됩니다.
-- 압축된 청크는 건드리지 않습니다(압축은 1일 뒤라 1시간마다 도는 이 작업에는 늘 여유가 있습니다). 청크 안에서도 최근 25시간만 봅니다.
CREATE OR REPLACE PROCEDURE dedup_readings(job_id int, config jsonb)
LANGUAGE plpgsql AS $$
DECLARE
  c record;
  n bigint;
  total bigint := 0;
  filled bigint := 0;
  col text;
BEGIN
  FOR c IN
    SELECT chunk_schema, chunk_name FROM timescaledb_information.chunks
    WHERE hypertable_name = 'readings' AND NOT is_compressed AND range_end > now() - interval '25 hours'
  LOOP
    FOREACH col IN ARRAY ARRAY['unit', 'hw_id', 'model', 'vendor'] LOOP
      EXECUTE format($q$
        UPDATE %1$I.%2$I r SET %3$I = k.v
        FROM (SELECT site, room, device, anchor, property, processing, min(%3$I) AS v
              FROM readings WHERE time > now() - interval '25 hours' AND coalesce(%3$I, '') <> ''
              GROUP BY 1, 2, 3, 4, 5, 6 HAVING count(DISTINCT %3$I) = 1) k
        WHERE r.time > now() - interval '25 hours' AND coalesce(r.%3$I, '') = ''
          AND r.site IS NOT DISTINCT FROM k.site AND r.room IS NOT DISTINCT FROM k.room AND r.device IS NOT DISTINCT FROM k.device
          AND r.anchor IS NOT DISTINCT FROM k.anchor AND r.property IS NOT DISTINCT FROM k.property AND r.processing = k.processing$q$,
        c.chunk_schema, c.chunk_name, col);
      GET DIAGNOSTICS n = ROW_COUNT;
      filled := filled + n;
    END LOOP;
    EXECUTE format($q$
      DELETE FROM %1$I.%2$I WHERE ctid IN (
        SELECT ctid FROM (
          SELECT ctid, row_number() OVER (
            PARTITION BY time, site, room, device, anchor, property, processing
            ORDER BY (coalesce(unit, '') <> '') DESC, (value IS NOT NULL) DESC, ctid) AS rn
          FROM %1$I.%2$I WHERE time > now() - interval '25 hours') t
        WHERE rn > 1)$q$, c.chunk_schema, c.chunk_name);
    GET DIAGNOSTICS n = ROW_COUNT;
    total := total + n;
  END LOOP;
  RAISE NOTICE 'dedup_readings: % 칸 채움, % 행 삭제', filled, total;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = 'dedup_readings') THEN
    PERFORM add_job('dedup_readings', INTERVAL '1 hour');
  END IF;
END
$$;

-- 지금 쌓인 중복을 한 번 지웁니다
CALL dedup_readings(0, NULL);

-- 확인: 작업이 1시간 주기로 있고, 최근 25시간에 중복 묶음과 빈 값·채운 값으로 갈라진 시계열이 없어야 합니다(모두 0)
SELECT job_id, schedule_interval, next_start FROM timescaledb_information.jobs WHERE proc_name = 'dedup_readings';
SELECT count(*) AS dup_groups FROM (
  SELECT 1 FROM readings WHERE time > now() - interval '25 hours'
  GROUP BY time, site, room, device, anchor, property, processing HAVING count(*) > 1) x;
SELECT count(*) AS split_series FROM (
  SELECT 1 FROM readings WHERE time > now() - interval '25 hours'
  GROUP BY site, room, device, anchor, property, processing
  HAVING (bool_or(coalesce(unit, '') = '') AND bool_or(coalesce(unit, '') <> ''))
      OR (bool_or(coalesce(hw_id, '') = '') AND bool_or(coalesce(hw_id, '') <> ''))) x;
```
{: file="iot/hub/timescaledb/migrations/2026-09-28-readings-dedup-job.sql" }

</details>

`events` 테이블은 "행 하나 = 기기 하나에 간 명령 하나" 입니다. 이 글에서는 Zigbee 명령만 들어오고, [Home Assistant 글](/posts/48/)에서 HA 로 제어한 명령과 자동화 실행이 누가 했는지와 함께 들어옵니다. 기기 컬럼은 `readings` 와 같아 명령 직후의 전력 변화처럼 두 테이블을 조인해 볼 수 있습니다. 값을 가공하지 않으므로 `processing` 은 없습니다.

| 컬럼 | 예 | 내용 |
|---|---|---|
| `time`, `site`, `room`, `device`, `anchor`, `property` | `bedroom2`, `plug`, `outlet` | `readings` 와 같습니다. Zigbee 명령은 수신 시각이고 `property` 는 명령의 필드 이름입니다 |
| `action` | `ON`, `switch.turn_off` | Zigbee 명령은 보낸 값, HA 명령은 서비스 이름 |
| `data` | `{"brightness": 120}` | HA 서비스 데이터 JSON |
| `origin`, `actor` | `mqtt`, `user`, `automation` | 누가 보냈는지. Zigbee 명령은 보낸 쪽을 알 수 없어 `mqtt` 입니다 |
| `context_id`, `parent_id` | | HA context. 자동화 실행 행과 그 자동화가 보낸 명령을 잇습니다 |
| `protocol`, `source`, `vendor`, `model`, `hw_id`, `node` | | `readings` 와 같습니다 |

- **확인:** 이 단계도 파일만 만듭니다.

## 4. 지역 오버레이 추가와 배포

`iot/clusters/[SITE]/` 아래에 서비스별 폴더를 만들어 베이스를 참조하고 지역 값만 넣습니다. Mosquitto 는 Service 에 서비스 VIP 를 붙이고, Telegraf 는 `SITE` 와 `HUB_PG_HOST` 를 패치합니다. 폴더 하나가 `[SITE]-[이름]` Application 이 되어 엣지 클러스터의 같은 이름 네임스페이스에 배포됩니다.

```yaml
# [SITE] 엣지의 MQTT 브로커. 베이스 그대로 씁니다.
resources:
  - ../../../edge/mosquitto
patches:
  # [SITE] 엣지의 서비스 VIP(kube-vip). HA·Z2M·Matter·Mosquitto 가 포트만 달리해 같은 주소를 씁니다(LAN 기기·허브가 이 주소로 붙음)
  - patch: |
      apiVersion: v1
      kind: Service
      metadata:
        name: mosquitto
        annotations:
          kube-vip.io/loadbalancerIPs: "[EDGE_SERVICE_VIP]"
```
{: file="iot/clusters/[SITE]/mosquitto/kustomization.yaml" }

```yaml
# [SITE] 엣지의 수집기. 지역 DB([SITE]/timescaledb)와 허브 DB 에 씁니다. 베이스에 지역 값만 넣습니다.
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
                  - { name: HUB_PG_HOST, value: [HUB_VIP] }   # 허브 control plane VIP. NodePort 30432 가 Patroni 의 주 DB 로 넘깁니다
```
{: file="iot/clusters/[SITE]/telegraf/kustomization.yaml" }

```bash
# 커밋하고 push (허브 몫과 엣지 몫을 함께)
git add iot services/monitoring/values.yaml
git commit -m "feat(iot): 엣지 Mosquitto·Telegraf 수집 파이프라인 추가"
git push
```

Argo CD 가 저장소를 다시 읽으면(최대 3분) `[SITE]-mosquitto`, `[SITE]-telegraf` Application 이 생기고 `monitoring` 이 다시 sync 됩니다. DB 가 준비되기 전에 엣지 Telegraf 가 먼저 뜨면 연결 실패 로그가 잠깐 찍히지만, 재시도 설정 덕에 DB 가 준비되는 대로 붙습니다.

- **확인:** 허브 control plane 에서 `kubectl -n argocd get applications` 에 두 Application 이 `Synced`, `Healthy`. 엣지 `kubectl --kubeconfig k8s-[SITE].yaml -n mosquitto get svc` 의 `EXTERNAL-IP` 가 `[EDGE_SERVICE_VIP]`. Grafana 데이터소스 상태는 아래 명령으로 봅니다.

```bash
# 허브 control plane: Grafana 데이터소스 연결 상태 (admin 비밀번호는 grafana-admin Secret)
GP=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s -u "admin:$GP" http://127.0.0.1:30082/api/datasources/uid/timescaledb/health
```

응답이 `{"message":"Database Connection OK","status":"OK"}` 이면 됩니다.

## 5. 테스트 메시지로 확인

아직 Zigbee 기기가 없으니 브로커에 기기 메시지 모양의 JSON 을 직접 발행해 끝까지 흐르는지 봅니다. 익명 발행은 거부되어야 하고, `telegraf` 계정으로 발행한 메시지는 `last_seen` 시각으로 지역 DB 와 허브 DB 의 테이블에 함께 들어가야 합니다. 기기 이름은 규칙(`<방>-<종류>`)에 맞아야 기록되므로 `test-th` 로 보냅니다. 명령은 엣지에서 일회용 파드로 실행합니다.

```bash
# 허브 control plane. E 는 엣지 kubeconfig, PW 는 telegraf 계정 비밀번호
E="--kubeconfig k8s-[SITE].yaml"
PW=$(kubectl $E -n telegraf get secret telegraf-credentials -o jsonpath='{.data.MQTT_PASSWORD}' | base64 -d)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 익명 발행: 실패해야 정상
kubectl $E -n mosquitto run mq-anon --rm -i -q --restart=Never --image=eclipse-mosquitto:2.0.22 \
  --command -- mosquitto_pub -h mosquitto -t zigbee2mqtt/test -m '{}'

# telegraf 계정으로 기기 메시지 모양 발행 (서비스 VIP 의 1883 으로)
kubectl $E -n mosquitto run mq-pub --rm -i -q --restart=Never --image=eclipse-mosquitto:2.0.22 --env="PW=$PW" \
  --command -- mosquitto_pub -h [EDGE_SERVICE_VIP] -u telegraf -P "$PW" -q 1 -t zigbee2mqtt/test-th \
  -m "{\"temperature\":21.5,\"humidity\":40,\"contact\":true,\"state\":\"ON\",\"last_seen\":\"$TS\"}"
```

```bash
# 20초쯤 뒤 지역 DB 와 허브 DB 에서 조회 (주 DB 파드는 Patroni 가 role=primary 라벨을 붙임)
Q='select time, site, protocol, room, device, property, value, value_text from readings where room = '"'test'"' order by time desc, property limit 4;'
kubectl $E -n timescaledb exec $(kubectl $E -n timescaledb get pod -l role=primary -o name) -- psql -U iot -d iot -c "$Q"
kubectl -n timescaledb exec $(kubectl -n timescaledb get pod -l role=primary -o name) -- psql -U iot -d iot -c "$Q"
```

- **확인:** 익명 발행은 `Connection error: Connection Refused: not authorised` 로 끝납니다. 두 DB 의 조회에 메시지 하나가 쪼개진 같은 네 행(`contact`, `humidity`, `state`, `temperature`)이 보이고, `time` 이 발행한 `TS` 와 같고 `site` 가 `[SITE]`, `protocol` 이 `zigbee`, `room` 이 `test`, `device` 가 `th` 입니다. `true` 는 `value` 1 과 `value_text` `true`, `ON` 은 `value` 1 과 `value_text` `ON` 으로 들어갑니다.

## 6. Grafana 대시보드로 기록 보기

SQL 을 쓰지 않고 웹에서 기록을 보도록 Grafana 대시보드를 함께 배포합니다. kube-prometheus-stack 의 Grafana 에는 `grafana_dashboard: "1"` 라벨이 붙은 ConfigMap 을 모든 네임스페이스에서 찾아 불러오는 sidecar 가 기본으로 켜져 있습니다. 대시보드 JSON 은 허브 Grafana 와 지역 Grafana(`iot/edge/grafana`)가 함께 쓰므로 `iot/shared/dashboards/` 에 두고 `configMapGenerator` 로 라벨을 붙인 뒤, 허브 DB 폴더가 이 폴더를 가져다 씁니다.

```bash
# 저장소 루트에서 대시보드 JSON 내려받기
mkdir -p iot/shared/dashboards
wget -O iot/shared/dashboards/iot.json https://eu4ng.github.io/assets/files/iot/grafana-dashboard-iot.json
```

```yaml
# IoT 대시보드 원본. 허브 Grafana(iot/hub/timescaledb 가 포함, kube-prometheus-stack sidecar 가 라벨로 읽음)와
# 지역 Grafana(iot/edge/grafana 가 포함, 파일로 마운트)가 같은 파일을 씁니다. 이 폴더는 Application 이 아니라 두 곳이 가져다 쓰는 재료입니다.
configMapGenerator:
  - name: grafana-dashboard-iot
    files:
      - iot.json
    options:
      labels: { grafana_dashboard: "1" }
      disableNameSuffixHash: true   # 이름이 바뀌면 sidecar 가 옛 파일을 지우고 새로 불러오는 사이 대시보드가 잠시 사라집니다
```
{: file="iot/shared/dashboards/kustomization.yaml" }

허브 DB 폴더의 `kustomization.yaml` 에는 `resources` 에 `../../shared/dashboards` 한 줄을 더합니다. 대시보드 ConfigMap 이 `timescaledb` 네임스페이스에 만들어집니다.

```yaml
# 중앙 시계열 저장소. 모든 지역의 엣지 Telegraf 가 여기로 씁니다.
# Patroni 클러스터: worker 두 대의 StatefulSet 멤버 + 서울 NAS 멤버(stacks/seoul/timescaledb). 주 DB 하나에 나머지가 스트리밍 복제로 따라갑니다.
resources:
  - service.yaml
  - patroni-rbac.yaml
  - patroni-statefulset.yaml
  # Grafana 대시보드(원본 iot/shared/dashboards/iot.json). sidecar 가 모든 네임스페이스에서 라벨 grafana_dashboard 의 ConfigMap 을 불러옵니다
  - ../../shared/dashboards
configMapGenerator:
  - name: timescaledb-patroni
    files:
      - patroni/patroni.yml
      - patroni/post-bootstrap.sh
```
{: file="iot/hub/timescaledb/kustomization.yaml" }

대시보드(uid `iot-records`)는 2단계의 `TimescaleDB` 데이터소스로 읽기 전용 조회만 합니다. DB 에 잘 저장되는지 확인하는 용도라 컬럼을 가공하지 않고 `SELECT *` 로 그대로 보여 주며, 컬럼이 늘거나 줄면 표에 바로 반영됩니다. 위쪽의 `site`, `processing`, `room`, `device`, `property` 변수로 범위를 좁히고, 오른쪽 위 시간 범위가 모든 패널에 적용됩니다. 서버·PC 자체의 값([호스트 부하 글](/posts/74/))도 다른 기기처럼 속성마다 패널이 자동으로 생기므로 `device`·`property` 변수로 좁혀 봅니다.

| 패널 | 내용 |
|---|---|
| readings 컬럼 | `information_schema` 에서 읽은 `readings` 의 지금 컬럼(순서, 이름, 형식, NULL 허용) |
| 청크 | `readings` 하이퍼테이블의 청크(1일)와 압축 여부 |
| 기기·속성별 최신 행 | `site`·`room`·`device`·`anchor`·`property`·`processing` 마다 마지막 행의 모든 컬럼 |
| 최근 행 | 가장 최근에 저장된 500행의 모든 컬럼 |
| 미세먼지 | 이름이 `pm` 으로 시작하는 속성(`pm1`, `pm25`, `pm10` …)을 한 그래프에. 그리는 규칙은 아래 숫자 패널과 같습니다 |
| 숫자 속성마다 하나씩 (`temperature`, `humidity` …) | 숫자 값이 있는 속성마다 자동으로 생기는 시계열. 패널 제목이 속성 이름입니다. 평균 없이 DB 값만 그리고, 값은 다음 기록까지 유지된 것으로 봅니다. 기기 연결 상태가 `offline` 이 되거나 같은 속성이 `unavailable`·`unknown` 이면 다음 값까지 비웁니다. 범위 시작 전 1일 안의 마지막 값은 범위 시작부터, 마지막 값은 지금까지 잇습니다 |
| 상태 속성마다 하나씩 (`presence`, `contact`, `availability` …) | 문자열·두 값 상태 속성마다 자동으로 생기는 상태 타임라인. 기기마다 한 줄이고 켜짐·참·온라인은 노랑, 꺼짐·거짓·오프라인은 회색입니다. 기기 연결 상태가 `offline` 이 된 뒤 다음 값까지는 빈 칸입니다 |

```bash
# 커밋하고 push
git add iot/shared/dashboards iot/hub/timescaledb/kustomization.yaml
git commit -m "feat(iot): 허브 TimescaleDB 기록을 보는 Grafana 대시보드 추가"
git push
```

- **확인:** `kubectl -n timescaledb get cm -l grafana_dashboard=1` 에 `grafana-dashboard-iot` 가 보입니다. Grafana(`http://[HUB_VIP]:30082`)의 **Dashboards** 에 **IoT 기록** 이 생기고, 5단계에서 발행한 `test-th` 가 **기기·속성별 최신 행** 표와 **temperature**, **humidity** 패널에 나타납니다.

## 7. 단절 드릴

허브가 끊긴 상황을 만들어 버퍼가 실제로 동작하는지 봅니다. 엣지 worker 에서 파드가 허브 DB 포트로 나가는 패킷을 막고, 그 동안 메시지를 여러 건 발행하고, 도중에 Telegraf 파드까지 지운 뒤, 차단을 풀고 두 DB 에 무엇이 들어왔는지 확인합니다. 지운 Telegraf 파드가 다른 worker 에 다시 뜰 수 있으므로 차단은 worker 두 대에 모두 겁니다.

```bash
# 엣지 worker 두 대 모두: 파드 → 허브 DB 차단 (파드 트래픽은 FORWARD 체인을 지납니다)
sudo iptables -I FORWARD 1 -d [HUB_VIP] -p tcp --dport 30432 -j REJECT --reject-with tcp-reset
```

```bash
# 허브 control plane: 8초 간격으로 8건 발행하는 파드 시작
kubectl $E -n mosquitto run mq-drill --restart=Never --image=eclipse-mosquitto:2.0.22 --env="PW=$PW" --command -- sh -c '
  for i in 1 2 3 4 5 6 7 8; do
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mosquitto_pub -h mosquitto -u telegraf -P "$PW" -q 1 -t zigbee2mqtt/drill-th -m "{\"temperature\":$i,\"last_seen\":\"$ts\"}" && echo "sent $i $ts"
    sleep 8
  done'

# 30초쯤 뒤: 차단 중에 Telegraf 파드 삭제 → 새 파드가 종료되지 않고 재시도 중인지
kubectl $E -n telegraf delete pod -l app=telegraf
sleep 25; kubectl $E -n telegraf get pods; kubectl $E -n telegraf logs deploy/telegraf | grep -E 'not connected|retrying' | tail -2

# 발행이 끝난 뒤(약 70초) 발행 기록
kubectl $E -n mosquitto logs mq-drill
```

```bash
# 허브 control plane: 차단 중 지역 DB 조회
Q="select count(*), min(time), max(time) from readings where room='drill' and property='temperature';"
kubectl $E -n timescaledb exec $(kubectl $E -n timescaledb get pod -l role=primary -o name) -- psql -U iot -d iot -c "$Q"
```

```bash
# 엣지 worker 두 대 모두: 차단 해제
sudo iptables -D FORWARD -d [HUB_VIP] -p tcp --dport 30432 -j REJECT --reject-with tcp-reset
```

```bash
# 허브 control plane: 40초쯤 뒤 허브 DB 조회
kubectl -n timescaledb exec $(kubectl -n timescaledb get pod -l role=primary -o name) -- psql -U iot -d iot -c "$Q" \
  -c "select time, value from readings where room='drill' and property='temperature' order by time;"
kubectl $E -n mosquitto delete pod mq-drill
```

- **확인:** 차단 중 새로 뜬 Telegraf 파드가 `Running` 으로 유지되고 로그에 `Error writing to outputs.postgresql: not connected` 가 반복됩니다. 지역 DB 에는 차단 중에도 발행한 만큼 들어오고, 허브 DB 에는 차단을 풀면 8건이 모두 발행 시각 그대로 들어옵니다. 이 글을 쓰며 실행했을 때는 파드를 지운 순간에 처리 중이던 4번 메시지가 두 번 들어와 9행이 됐습니다. 브로커의 QoS 1 은 "최소 한 번" 전달이라 파드 교체 시점에 한 건이 중복될 수 있으며, 조회할 때 `select distinct on (time, site, room, device, anchor, property) ...` 로 걸러 냅니다.

> 로그에 `Using disk-write-through buffer strategy ... this is an experimental feature` 경고가 남습니다. 문서에는 정식 옵션으로 적혀 있지만 구현은 아직 실험 표시가 붙어 있습니다. 위 드릴처럼 파드 재시작과 재연결을 한 번 직접 확인해 두는 것이 좋습니다.
{: .prompt-warning }

## 마무리

엣지의 Mosquitto 와 Telegraf, 허브의 Grafana 데이터소스·대시보드를 GitOps 폴더로 배포해, 기기 메시지가 지역 DB 와 허브 DB 에 함께 쌓이고 한쪽 DB 가 끊긴 동안은 엣지 디스크에 쌓였다가 원래 시각으로 들어가는 파이프라인을 완성했습니다. 지역을 추가할 때는 `iot/clusters/[SITE]/` 아래에 지역 DB 와 같은 오버레이 두 개를 만들고 시크릿 스크립트를 그 엣지에 실행하면 됩니다. 다음 글에서는 이 브로커에 Zigbee2MQTT 를 붙여 실제 Zigbee 기기 데이터를 흘립니다.

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
- [kube-vip - Kubernetes Services (LoadBalancer)](https://kube-vip.io/docs/usage/kubernetes-services/)
- [Kustomize - configMapGenerator](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/configmapgenerator/)
