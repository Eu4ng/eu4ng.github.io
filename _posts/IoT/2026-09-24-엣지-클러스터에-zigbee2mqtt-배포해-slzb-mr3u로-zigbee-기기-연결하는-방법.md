---
layout: post
title: 엣지 클러스터에 Zigbee2MQTT 배포해 SLZB-MR3U로 Zigbee 기기 연결하는 방법
description: 네트워크 코디네이터 SLZB-MR3U 의 Zigbee 라디오에 TCP 로 붙는 Zigbee2MQTT 를 GitOps 폴더로 엣지 클러스터에 배포하고, 기기 메시지가 브로커를 거쳐 허브 TimescaleDB 에 기기 시각 그대로 쌓이게 하는 방법을 정리했습니다.
author: Eu4ng
tags: [iot, zigbee, zigbee2mqtt, slzb-06, mqtt, kubernetes, argo-cd, gitops, edge]
permalink: /posts/44/
---

엣지 클러스터에 **Zigbee2MQTT**를 배포해 SLZB-MR3U 의 Zigbee 라디오(CC2674P10)에 TCP 로 붙이고, 기기 메시지가 `zigbee2mqtt/[기기]` 토픽으로 브로커에 올라가 [수집 파이프라인](/posts/43/)을 타고 허브 TimescaleDB 에 들어가게 합니다. Zigbee2MQTT 는 기기를 추가할 때마다 자기 설정 파일을 다시 쓰므로 설정 파일은 PVC 에 두고 첫 기동에만 시드를 복사하며, 브로커 주소나 코디네이터 주소처럼 GitOps 가 관리할 값은 환경 변수로 매 기동 덮어씁니다. 코디네이터가 USB 가 아니라 네트워크 장비라 파드에 장치 패스스루가 필요 없습니다.

1. 코디네이터 포트 확인
2. 엣지 베이스 폴더 만들기
3. 지역 오버레이 추가와 배포
4. 프런트엔드 접속과 기기 페어링
5. 허브 DB 에서 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| 엣지 Kubernetes | `v1.36` (k3s) |
| Zigbee2MQTT | `2.14.1` |
| 코디네이터 | `SLZB-MR3U` (CC2674P10, Z-Stack `20240705`, SLZB-OS `v3.2.6`) |
| 작성 기준일 | `2026-09-24` |

다음 항목이 준비되어 있어야 합니다.

- 엣지 클러스터의 Mosquitto 와 Telegraf, 허브 TimescaleDB ([엣지 Mosquitto와 Telegraf 디스크 버퍼로 중앙 TimescaleDB에 유실 없이 IoT 데이터 모으는 방법](/posts/43/)). 그 글의 시크릿 스크립트가 만든 `zigbee2mqtt-credentials` Secret(브로커 비밀번호, 프런트엔드 토큰)을 씁니다.
- Zigbee 코디네이터 모드로 설정되고 고정 IP 를 가진 SLZB-MR3U ([SLZB-MR3U 초기 설정하고 Zigbee와 Thread 라디오 모드 나누는 방법](/posts/45/))
- 페어링할 Zigbee 기기 하나

## 1. 코디네이터 포트 확인

SLZB-MR3U 는 라디오마다 TCP 포트를 하나씩 엽니다. Zigbee 라디오의 포트 번호는 웹 UI 의 **Z2M and ZHA** 페이지에서 그 라디오의 **Socket Port** 로 확인하며, 이 글의 기기는 `7638`(CC2674P10) 입니다. 포트는 클라이언트 하나만 받으므로 다른 Zigbee2MQTT 나 ZHA 가 붙어 있으면 안 됩니다.

```bash
# 내 PC: 포트가 열려 있는지
nc -zv [SLZB_IP] 7638
```

- **확인:** `Connection to [SLZB_IP] 7638 port [tcp/*] succeeded!` 가 출력됩니다.

## 2. 엣지 베이스 폴더 만들기

`iot/edge/zigbee2mqtt/` 에 시드 설정, Deployment, Service, PVC 를 둡니다. 시드 설정에는 네트워크 키처럼 첫 기동에 생성되어 파일에 남아야 하는 값만 두고, 나머지는 Deployment 의 `ZIGBEE2MQTT_CONFIG_*` 환경 변수로 넣습니다. 환경 변수 이름은 설정 키 경로를 대문자로 바꾸고 `_` 로 이은 것입니다(`mqtt.server` → `ZIGBEE2MQTT_CONFIG_MQTT_SERVER`).

```yaml
# 엣지의 Zigbee2MQTT. 네트워크 코디네이터(SLZB 등)에 TCP 로 붙어 Zigbee 기기 메시지를 브로커에 발행합니다.
# 코디네이터 주소·어댑터·채널 같은 지역 값은 오버레이(iot/clusters/<지역>/zigbee2mqtt/)가 env 로 넣습니다.
resources:
  - deployment.yaml
  - service.yaml
  - pvc.yaml
configMapGenerator:
  - name: zigbee2mqtt-seed
    files:
      - configuration.yaml
    options:
      disableNameSuffixHash: true   # 시드는 첫 기동에만 복사되므로, 내용이 바뀌어도 이름(해시)을 바꿔 Z2M 을 재기동하지 않습니다
```
{: file="iot/edge/zigbee2mqtt/kustomization.yaml" }

```yaml
# 첫 기동에 PVC 로 복사되는 시드입니다(이미 있으면 복사하지 않음). Zigbee2MQTT 가 기기를 추가할 때마다 이 파일을 다시 쓰므로 PVC 에 두어야 합니다.
# 브로커·시리얼·프런트엔드처럼 바뀔 수 있는 값은 여기 대신 Deployment 의 ZIGBEE2MQTT_CONFIG_* env 로 넣어 매 기동 덮어씁니다.
# 아래 세 키는 env 로 넣으면 안 됩니다: 첫 기동에 GENERATE 가 실제 값으로 바뀌어 파일에 저장되는데, env 가 다시 GENERATE 를 넣으면 재기동마다 망이 새로 만들어집니다.
homeassistant:
  enabled: true                  # Home Assistant 가 MQTT 디스커버리로 기기를 보게 합니다 (수집 경로와 무관)
mqtt:
  base_topic: zigbee2mqtt        # Telegraf 가 zigbee2mqtt/+ 를 구독합니다
# 기기 이름(friendly_name)은 <방>-<종류> (예: bedroom-th). 방은 이름의 첫 - 앞이므로 방 이름에는 - 를 쓰지 않습니다.
# 규칙에 맞지 않는 이름(페어링 직후의 0x…)과 retired-… 는 Telegraf 가 기록하지 않으므로 페어링하면 바로 이름을 붙입니다.
# / 는 쓰지 않습니다(토픽이 두 단계가 되어 수집되지 않음). 옮기면 이름을 새 방으로, 교체하면 새 기기에 옛 이름을 줍니다.
frontend:
  enabled: true
advanced:
  network_key: GENERATE
  pan_id: GENERATE
  ext_pan_id: GENERATE
  last_seen: ISO_8601            # 모든 메시지에 last_seen 시각을 넣어 Telegraf 가 행의 시각으로 씁니다
  log_level: info
```
{: file="iot/edge/zigbee2mqtt/configuration.yaml" }

> `network_key`, `pan_id`, `ext_pan_id` 는 시드 파일에만 `GENERATE` 로 둡니다. Zigbee2MQTT 는 첫 기동에 이 값을 실제 키로 바꿔 파일에 저장하고, 환경 변수로 받은 값도 파일에 함께 기록합니다. 환경 변수로 `GENERATE` 를 넣으면 재기동마다 새 키가 만들어져 페어링한 기기가 전부 떨어집니다.
{: .prompt-danger }

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zigbee2mqtt
spec:
  replicas: 1                # 코디네이터 포트는 클라이언트 하나만 받습니다
  strategy:
    type: Recreate           # PVC 가 ReadWriteOnce 이고, 새 파드가 코디네이터를 먼저 잡으면 옛 파드가 못 내려갑니다
  selector:
    matchLabels: { app: zigbee2mqtt }
  template:
    metadata:
      labels: { app: zigbee2mqtt }
    spec:
      # 설정 파일이 없을 때만 시드를 복사합니다. 있으면 Zigbee2MQTT 가 써 둔 네트워크 키·기기 목록을 그대로 씁니다.
      initContainers:
        - name: seed-config
          image: koenkk/zigbee2mqtt:2.14.1
          command: ["/bin/sh", "-c", "[ -f /app/data/configuration.yaml ] || cp /seed/configuration.yaml /app/data/configuration.yaml"]
          volumeMounts:
            - { name: data, mountPath: /app/data }
            - { name: seed, mountPath: /seed }
      containers:
        - name: zigbee2mqtt
          image: koenkk/zigbee2mqtt:2.14.1
          ports: [{ containerPort: 8080 }]
          env:
            - { name: TZ, value: Asia/Seoul }
            - { name: ZIGBEE2MQTT_CONFIG_MQTT_SERVER, value: mqtt://mosquitto.mosquitto.svc.cluster.local:1883 }
            - { name: ZIGBEE2MQTT_CONFIG_MQTT_USER, value: zigbee2mqtt }
            - name: ZIGBEE2MQTT_CONFIG_MQTT_PASSWORD
              valueFrom: { secretKeyRef: { name: zigbee2mqtt-credentials, key: MQTT_PASSWORD } }   # create-iot-secrets.sh
            - name: ZIGBEE2MQTT_CONFIG_FRONTEND_AUTH_TOKEN                                        # NodePort 로 LAN 에 열리므로 토큰을 요구합니다
              valueFrom: { secretKeyRef: { name: zigbee2mqtt-credentials, key: FRONTEND_AUTH_TOKEN } }
            # 지역 오버레이가 아래 값을 바꿉니다: 코디네이터 주소(tcp://IP:포트), 어댑터(zstack|ember 등), 속도, 채널
            - { name: ZIGBEE2MQTT_CONFIG_SERIAL_PORT, value: "tcp://127.0.0.1:6638" }
            - { name: ZIGBEE2MQTT_CONFIG_SERIAL_ADAPTER, value: zstack }
            - { name: ZIGBEE2MQTT_CONFIG_SERIAL_BAUDRATE, value: "115200" }
            - { name: ZIGBEE2MQTT_CONFIG_ADVANCED_CHANNEL, value: "25" }   # Thread(기본 15)·Wi-Fi 와 겹치지 않게. 바꾸면 기기를 다시 페어링해야 합니다
            - { name: ZIGBEE2MQTT_CONFIG_MQTT_INCLUDE_DEVICE_INFORMATION, value: "true" }   # 메시지에 device{ieeeAddr, model …}를 넣어 DB 에 실물 기기가 남게 합니다
            # 가용성: 기기가 죽으면 <이름>/availability 에 offline 을 알리고 HA 엔티티가 "사용할 수 없음"이 됩니다(마지막 값을 계속 보여 주지 않게).
            # 배터리 기기는 잠들어 ping 에 답하지 못하므로 active 방식을 쓸 수 없고, 제한 시간 동안 메시지가 없으면 offline 으로 봅니다(passive).
            - { name: ZIGBEE2MQTT_CONFIG_AVAILABILITY_ENABLED, value: "true" }
            - { name: ZIGBEE2MQTT_CONFIG_AVAILABILITY_PASSIVE_TIMEOUT, value: "60" }   # 분. 기본 1500. 온습도계가 값이 안 바뀌면 30분까지 조용하므로 그 두 배
            # 모든 기기의 기본 옵션입니다. 기기별로 같은 키를 주면 이 값이 가려집니다.
            #   qos 1: 기본 0 이면 Telegraf 가 QoS1 로 구독해도 전달이 QoS0 이 되어, Telegraf 가 내려간 동안 브로커가 메시지를 보관하지 않고 버립니다
            #   linkquality: HA 가 LQI 엔티티를 비활성으로 등록하지 않게 합니다(처음 등록될 때만 적용)
            - { name: ZIGBEE2MQTT_CONFIG_DEVICE_OPTIONS, value: '{"qos":1,"homeassistant":{"linkquality":{"enabled_by_default":true}}}' }
          volumeMounts:
            - { name: data, mountPath: /app/data }
          startupProbe:
            httpGet: { path: /, port: 8080 }
            periodSeconds: 5
            failureThreshold: 60   # 코디네이터 연결과 설정 마이그레이션에 시간이 걸립니다
          readinessProbe:
            httpGet: { path: /, port: 8080 }
            periodSeconds: 10
          resources:
            requests: { cpu: 100m, memory: 256Mi }   # Node 프로세스 + 프런트엔드
            limits:   { cpu: "1", memory: 512Mi }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: zigbee2mqtt-data }
        - name: seed
          configMap: { name: zigbee2mqtt-seed }
```
{: file="iot/edge/zigbee2mqtt/deployment.yaml" }

```yaml
# 프런트엔드. LAN 에서 http://[엣지 노드 IP]:30083 으로 열고 auth_token 으로 들어갑니다.
apiVersion: v1
kind: Service
metadata:
  name: zigbee2mqtt
spec:
  type: NodePort
  selector: { app: zigbee2mqtt }
  ports:
    - { port: 8080, targetPort: 8080, nodePort: 30083 }
```
{: file="iot/edge/zigbee2mqtt/service.yaml" }

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: zigbee2mqtt-data
  annotations:
    argocd.argoproj.io/sync-options: Prune=false   # 네트워크 키·기기 목록·코디네이터 백업. 잃으면 모든 기기를 다시 페어링해야 합니다
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
```
{: file="iot/edge/zigbee2mqtt/pvc.yaml" }

`configuration.yaml` 이 있으면 Zigbee2MQTT 2.x 의 첫 기동 온보딩 화면이 뜨지 않고 바로 시작합니다. `advanced.last_seen: ISO_8601` 은 모든 기기 메시지에 `last_seen` 시각을 넣어, Telegraf 가 수신 시각 대신 이 값을 행의 시각으로 쓰게 합니다.

- **확인:** 이 단계는 파일만 만듭니다.

## 3. 지역 오버레이 추가와 배포

`iot/clusters/[SITE]/zigbee2mqtt/` 에 베이스를 참조하고 코디네이터 주소만 넣는 오버레이를 만듭니다. `adapter` 는 라디오 칩에 맞춥니다. CC26xx·CC2674 계열(Z-Stack)은 `zstack`, EFR32 계열은 `ember` 입니다.

```yaml
# [SITE] 엣지의 Zigbee2MQTT. 코디네이터는 SLZB-MR3U 의 CC2674P10 라디오(네트워크 모드, 포트 7638).
resources:
  - ../../../edge/zigbee2mqtt
patches:
  - patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: zigbee2mqtt
      spec:
        template:
          spec:
            containers:
              - name: zigbee2mqtt
                env:
                  - { name: ZIGBEE2MQTT_CONFIG_SERIAL_PORT, value: "tcp://[SLZB_IP]:7638" }
                  - { name: ZIGBEE2MQTT_CONFIG_SERIAL_ADAPTER, value: zstack }     # CC2674P10 은 Z-Stack 펌웨어
                  - { name: ZIGBEE2MQTT_CONFIG_SERIAL_BAUDRATE, value: "115200" }
```
{: file="iot/clusters/[SITE]/zigbee2mqtt/kustomization.yaml" }

```bash
# 커밋하고 push
git add iot/edge/zigbee2mqtt iot/clusters/[SITE]/zigbee2mqtt
git commit -m "feat(iot): 엣지 Zigbee2MQTT 추가 (네트워크 코디네이터 SLZB-MR3U 연결)"
git push
```

Argo CD 가 저장소를 다시 읽으면 `[SITE]-zigbee2mqtt` Application 이 생깁니다. 첫 기동은 코디네이터 연결과 설정 스키마 마이그레이션에 30초쯤 걸립니다.

```bash
# control plane: 파드와 로그
E="--kubeconfig k3s-[SITE].yaml"
kubectl $E -n zigbee2mqtt get pods,pvc,svc
kubectl $E -n zigbee2mqtt logs deploy/zigbee2mqtt | grep -E 'Socket connected|Coordinator firmware|Connected to MQTT|frontend|started'
```

- **확인:** Application 이 `Synced`, `Healthy`. 로그에 `zh:zstack:znp: Socket connected`, `Coordinator firmware version: ... "type":"ZStack3x0"`, `Connected to MQTT server`, `Started frontend on port 8080`, `Zigbee2MQTT started!` 가 순서대로 보입니다. PVC 의 `configuration.yaml` 에는 `network_key` 가 숫자 배열로 바뀌어 있고 `coordinator_backup.json` 이 함께 생깁니다.

## 4. 프런트엔드 접속과 기기 페어링

내 PC 브라우저에서 `http://[EDGE_IP]:30083` 을 열고 시크릿 스크립트에 입력한 프런트엔드 토큰으로 들어갑니다. 상단의 **Permit join** 을 켠 뒤 기기를 페어링 모드로 만들면(기기마다 버튼을 몇 초 누르는 식) 목록에 나타납니다. 기기 이름(friendly name)은 토픽과 DB 의 `device` 컬럼에 그대로 쓰이므로 `<방>-<종류>` 형식의 영문 소문자로 바꿉니다(예: 온습도계 `bedroom-th`, 멀티 센서 `bedroom-multi`, 문 센서 `bedroom-door`). 종류는 측정 항목이 아니라 기기 역할이고, 같은 방에 여럿이면 `bedroom-th2` 처럼 번호를 붙입니다. 방은 이름의 첫 `-` 앞이므로 방 이름에는 `-` 를 쓰지 않습니다(`livingroom`). Telegraf 는 이 규칙에 맞는 이름만 기록하므로, 페어링 직후의 `0x…` 이름으로 보낸 값은 DB 에 남지 않습니다. 또 `include_device_information` 으로 실린 실물 기기의 IEEE 주소와 모델을 `hw_id`, `model`, `vendor` 컬럼에 넣습니다.

- 기기를 다른 방으로 옮기면 옮기는 즉시 이름을 새 방으로 바꿉니다. 바꾼 시각부터 새 방으로 기록되고, 과거 행은 옛 방으로 남습니다.
- 기기를 교체하면 옛 기기를 `retired-[기기 이름]` 으로 바꾸거나 제거하고, 새 기기에 옛 이름을 줍니다. 이름은 이어지고 `hw_id`, `model` 만 바뀝니다. `retired-` 이름의 값은 기록되지 않습니다.

> 이름에 `/` 를 넣으면 토픽이 `zigbee2mqtt/거실/온도` 처럼 두 단계가 되어 Telegraf 의 `zigbee2mqtt/+` 구독에 잡히지 않습니다.
{: .prompt-warning }

- **확인:** 기기 목록에 새 기기가 보이고, 기기 화면의 상태 값이 갱신됩니다. 브로커에서는 `zigbee2mqtt/[기기 이름]` 토픽으로 `last_seen` 이 포함된 JSON 이 올라옵니다.

```bash
# control plane: 브로커에서 기기 메시지 보기 (telegraf 계정으로 구독, Ctrl-C 로 종료)
PW=$(kubectl $E -n telegraf get secret telegraf-credentials -o jsonpath='{.data.MQTT_PASSWORD}' | base64 -d)
kubectl $E -n mosquitto run mq-sub --rm -i -q --restart=Never --image=eclipse-mosquitto:2.0.22 --env="PW=$PW" \
  --command -- mosquitto_sub -h mosquitto -u telegraf -P "$PW" -t 'zigbee2mqtt/+' -v
```

## 5. 허브 DB 에서 확인

Telegraf 는 기기 메시지의 필드 하나를 `readings` 테이블의 행 하나(`property`, `value`, `value_text`)로 넣습니다. 기기 설정값(보정값, 감도, 표시등 등)은 버립니다. 허브에서 기기별로 들어온 속성을 봅니다.

```bash
# 허브 control plane
kubectl -n timescaledb exec deploy/timescaledb -- psql -U iot -d iot \
  -c "select device, split_part(device, '-', 1) as room, hw_id, model, string_agg(distinct property, ', ') as properties, max(time)
      from readings where protocol = 'zigbee' group by 1,2,3,4 order by 1;"
```

- **확인:** `device` 에 규칙에 맞는 기기 이름만 있고 `room` 에 이름의 방, `hw_id`·`model` 에 실물 기기가 보이고 `max(time)` 이 기기가 마지막으로 보고한 시각(`last_seen`)과 같습니다. `properties` 에 기기가 보내는 측정 항목(`temperature`, `battery`, `linkquality` 등)이 보입니다.

## 마무리

Zigbee2MQTT 를 엣지 클러스터에 배포해 SLZB-MR3U 의 Zigbee 라디오에 TCP 로 붙이고, 기기 메시지가 브로커와 Telegraf 를 거쳐 허브 TimescaleDB 에 기기 시각 그대로 쌓이는 구성을 완성했습니다. 코디네이터가 고장 나면 새 기기를 같은 주소로 두기만 하면 됩니다. PVC 의 `coordinator_backup.json` 으로 Zigbee2MQTT 가 네트워크를 복원해 기기를 다시 페어링하지 않아도 됩니다. Home Assistant 를 붙이면 `homeassistant.enabled` 덕에 기기가 자동으로 나타나지만, 수집은 이 경로와 무관하게 계속됩니다.

## 참고 자료

- [Zigbee2MQTT - Configuration](https://www.zigbee2mqtt.io/guide/configuration/)
- [Zigbee2MQTT - Adapter settings](https://www.zigbee2mqtt.io/guide/configuration/adapter-settings.html)
- [Zigbee2MQTT - Frontend](https://www.zigbee2mqtt.io/guide/configuration/frontend.html)
- [Zigbee2MQTT - Docker](https://www.zigbee2mqtt.io/guide/installation/02_docker.html)
- [SMLIGHT - SLZB-06 series manual](https://smlight.tech/manual/slzb-06/)
