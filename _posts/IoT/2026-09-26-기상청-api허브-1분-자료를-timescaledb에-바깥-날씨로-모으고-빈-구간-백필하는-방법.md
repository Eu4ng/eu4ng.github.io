---
layout: post
title: 기상청 API허브 1분 자료를 TimescaleDB에 바깥 날씨로 모으고 빈 구간 백필하는 방법
description: 기상청 API허브의 지상관측 매분자료(ASOS·AWS)를 지역(엣지) 쿠버네티스의 작은 수집기로 1분마다 받아 지점마다 MQTT 센서로 내고, 엣지 Telegraf 가 지역 DB 와 허브 DB 에서 실내 센서와 같은 readings 테이블에 원본 값으로 넣으며, 매시간 DB 마다 빈 분을 찾아 직접 다시 받고 기상청에도 없는 분은 7일 뒤 영구 결측으로 확정하는 방법을 정리했습니다.
author: Eu4ng
tags: [iot, weather, kma, mqtt, telegraf, home-assistant, timescaledb, postgresql, kubernetes, argo-cd, gitops]
permalink: /posts/52/
---

기상청 **API허브**의 지상관측 매분자료를 지역(엣지) 클러스터의 수집기 파드가 받아, 관측 지점마다 센서 하나(`outdoor-weather-<지점 이름>`)로 다룹니다. 수집기가 1분마다 최근 15분을 받아 새 분만 [MQTT](/posts/80/) `weather/<기기>` 에 내면, 엣지 [Telegraf](/posts/82/) 가 실내 센서 값이 쌓이는 지역 TimescaleDB 와 허브 TimescaleDB 의 `readings` 테이블에 바깥 날씨 행으로 넣고 Home Assistant 는 [발견 설정](/posts/78/)으로 센서를 만듭니다. 그래서 실내 온습도와 같은 쿼리·대시보드로 비교할 수 있습니다. 기상청 API 가 그 지점 자료를 정상으로 돌려주는지는 기기 연결 상태(`availability`)로 알립니다. 매시간 DB 마다 빈 분을 찾아 그 구간만 다시 받아 DB 에 직접 넣으므로 수집기나 인터넷·허브가 끊겼던 동안의 날씨도 닿는 대로 채워지고, 처음 뜰 때는 그 지역 센서가 처음 기록된 시각까지 거슬러 올라가 채웁니다.

1. 인증키 발급과 활용신청
2. 관측 지점 고르기
3. Secret 만들기
4. 엣지 Telegraf 에 날씨 입력 추가
5. 수집기 매니페스트 추가
6. 배포와 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| 허브 Kubernetes | `v1.37` (kubeadm) |
| 엣지 Kubernetes | `v1.37` (kubeadm) |
| Argo CD | `v3.5.3` |
| telegraf | `1.40.1` (엣지) |
| python | `3.13-slim` (수집기 이미지, paho-mqtt 2, psycopg 3) |
| 기상청 API허브 API | 지상관측 AWS 매분자료(`nph-aws2_min`) |
| 작성 기준일 | `2026-09-26` |

다음 항목이 준비되어 있어야 합니다.

- 엣지 Mosquitto·Telegraf, 두 DB 의 `readings` 테이블과 ApplicationSet `iot-edge` ([엣지 Mosquitto와 Telegraf 디스크 버퍼로 중앙 TimescaleDB에 유실 없이 IoT 데이터 모으는 방법](/posts/43/))
- 지역 TimescaleDB ([지역 엣지에 TimescaleDB와 Grafana를 두어 인터넷 없이도 기록하고 보는 방법](/posts/56/))
- `readings` 에 원본·가공 구분 컬럼 `processing` 이 있어야 합니다(같은 글의 테이블 정의)
- 지역 Home Assistant 의 MQTT 통합과 `ha-registry.py` ([엣지 클러스터에 Home Assistant와 Matter 서버 배포하고 API로 통합 설정하는 방법](/posts/48/))
- 허브 control plane 에 엣지 kubeconfig 파일(`k8s-[SITE].yaml`)

## 1. 인증키 발급과 활용신청

[기상청 API허브](https://apihub.kma.go.kr/)에 가입하면 인증키(`authKey`)가 발급되고, 로그인한 뒤 마이페이지에서 확인할 수 있습니다. 일반회원은 자동 승인되며 무료이고, 하루 20,000건까지 호출할 수 있습니다. 공공데이터포털(data.go.kr)의 서비스키와는 다른 키입니다.

API 목록의 **지상관측** 에서 **AWS 매분자료** 를 찾아 활용신청합니다. 이 API 하나에 ASOS(종관기상관측) 지점과 AWS(방재기상관측) 지점이 모두 들어 있고, 기간 조회(`tm1`~`tm2`)도 같은 API 라 따로 신청할 것이 없습니다.

- **확인:** 브라우저에서 아래 주소를 열면 `#START7777` 로 시작하는 표가 나옵니다. `help=1` 이면 열 설명이 함께 나옵니다.

```text
https://apihub.kma.go.kr/api/typ01/cgi-bin/url/nph-aws2_min?stn=133&disp=0&help=1&authKey=[AUTH_KEY]
```

## 2. 관측 지점 고르기

지점 정보 API 로 지점 번호, 위경도, 주소를 받아 가장 가까운 지점을 고릅니다. 아래 명령은 대전 근처(위도 36.18~36.50, 경도 127.24~127.56)의 지점만 추립니다. 응답이 EUC-KR 이라 `iconv` 로 바꿉니다.

```bash
# 지점번호 경도 위도 이름 주소
curl -s "https://apihub.kma.go.kr/api/typ01/url/stn_inf.php?inf=AWS&stn=&help=0&authKey=[AUTH_KEY]" \
  | iconv -f euc-kr -t utf-8 \
  | awk '$1+0>0 && $3>36.18 && $3<36.50 && $2>127.24 && $2<127.56 {print $1, $2, $3, $9, $(NF-1), $NF}' | sort -u -k1,1n
```

이 글에서는 대표 지점인 `133` 대전(ASOS, 유성구 구성동)과, 수집 장소에서 가장 가까운 `648` 장동(AWS, 대덕구 장동)을 함께 받습니다. 지점마다 `readings` 에 아래처럼 들어갑니다.

| 컬럼 | 133 대전 | 648 장동 |
|---|---|---|
| `site` | `daejeon` | `daejeon` |
| `room` / `device` / `anchor` | `outdoor` / `weather` / `daejeon` | `outdoor` / `weather` / `jangdong` |
| `processing` | `raw` | `raw` |
| `protocol` / `source` / `vendor` | `http` / `kma` / `KMA` | `http` / `kma` / `KMA` |
| `model` / `hw_id` | `ASOS` / `133` | `AWS` / `648` |

기기 이름 규칙 `<방>-<종류>[-<기준>]` 에 맞춰 기준 칸에 지점 이름을 넣었고, 지점 번호는 실물 기기의 고유 ID 자리인 `hw_id` 에 넣었습니다. 기상청이 준 값 그대로이므로 `processing` 은 모두 `raw` 입니다.

받는 항목은 매분자료의 열 가운데 9개입니다.

| API 열 | `property` | `unit` | 값 |
|---|---|---|---|
| `TA` | `temperature` | °C | 1분 평균 기온 |
| `HM` | `humidity` | % | 1분 평균 상대습도 |
| `PA` | `pressure` | hPa | 1분 평균 현지기압 |
| `TD` | `dew_point` | °C | 이슬점온도(기상청 계산값) |
| `WD1` | `wind_direction` | ° | 1분 평균 풍향 |
| `WS1` | `wind_speed` | m/s | 1분 평균 풍속 |
| `WSS` | `wind_gust_speed` | m/s | 최대 순간 풍속 |
| `RN-60m` | `precipitation_1h` | mm | 60분 누적 강수량 |
| `RN-DAY` | `precipitation_day` | mm | 일 누적 강수량 |

`time` 은 조회한 시각이 아니라 관측한 분(KST, 초 00)입니다. 같은 분을 나중에 다시 받아도 같은 행이 됩니다.

## 3. Secret 만들기

인증키와 DB·브로커 비밀번호는 GitOps 저장소에 넣지 않고 엣지 클러스터에 Secret `weather/weather-credentials` 로 미리 만듭니다. 스크립트가 인증키를 입력받아(환경 변수 `KMA_AUTH_KEY` 가 있으면 그 값) 매분자료를 한 번 받아 본 뒤 Secret 을 만듭니다. DB 비밀번호는 허브와 지역의 TimescaleDB Secret 에서, 브로커 비밀번호는 엣지 Telegraf 의 Secret(계정 `telegraf`)에서 복사합니다. Secret 이 이미 있으면 빠진 `MQTT_PASSWORD` 만 더합니다.

```bash
# 허브 control plane 에서 스크립트 내려받기
wget https://eu4ng.github.io/assets/scripts/iot/create-weather-secret.sh
```

<details markdown="1">
<summary>create-weather-secret.sh 전문</summary>

```bash
#!/usr/bin/env bash
#
# 바깥 날씨 수집기가 쓰는 Secret(weather/weather-credentials)을 엣지 클러스터에 만듭니다. GitOps 저장소에는 비밀 값을 넣지 않으므로 폴더를 push 하기 전에 실행합니다.
# 수집기는 지역마다 엣지에서 돌며 새 값을 MQTT 로 내고(엣지 Telegraf 가 두 DB 에 넣음), 빠진 분은 지역 DB 와 허브 DB 에 직접 백필합니다.
# 허브에 kubectl 로 접근할 수 있고 엣지 kubeconfig 가 있는 곳(control plane)에서 실행합니다: bash create-weather-secret.sh [EDGE_KUBECONFIG]
# 인증키는 환경 변수 KMA_AUTH_KEY 가 있으면 그것을, 없으면 실행 중에 입력받습니다(값을 표준입력으로 넘겨도 됩니다).
# DB 비밀번호는 허브·지역의 timescaledb/timescaledb-credentials 에서, 브로커 비밀번호(계정 telegraf)는 엣지 telegraf/telegraf-credentials 에서 복사합니다.
# 이미 있으면 빠진 키(MQTT_PASSWORD)만 더합니다(값을 바꾸려면 Secret 을 지우고 다시 실행).

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
NAMESPACE=weather                  # iot/clusters/<지역>/weather 폴더 이름 = 네임스페이스
DB_SECRET=timescaledb/timescaledb-credentials   # POSTGRES_PASSWORD 를 가진 Secret (<네임스페이스>/<이름>, 허브·지역 같은 이름)
MQTT_SECRET=telegraf/telegraf-credentials       # MQTT_PASSWORD 를 가진 엣지 Secret (<네임스페이스>/<이름>)
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
log "사전 검사"
EDGE_KUBECONFIG=${1:-}
[ -r "$EDGE_KUBECONFIG" ] || die "사용법: bash create-weather-secret.sh [EDGE_KUBECONFIG]"
EDGE=(--kubeconfig "$EDGE_KUBECONFIG")
kubectl get nodes >/dev/null || die "kubectl 로 허브 클러스터에 접근할 수 없습니다."
kubectl "${EDGE[@]}" get nodes >/dev/null || die "엣지 kubeconfig 로 엣지 클러스터에 접근할 수 없습니다."
MQTT_PW=$(kubectl "${EDGE[@]}" -n "${MQTT_SECRET%%/*}" get secret "${MQTT_SECRET##*/}" -o jsonpath='{.data.MQTT_PASSWORD}' | base64 -d) || true
[ -n "$MQTT_PW" ] || die "엣지 $MQTT_SECRET 에서 MQTT_PASSWORD 를 읽지 못했습니다(create-iot-secrets.sh 를 먼저 실행)."
if kubectl "${EDGE[@]}" -n "$NAMESPACE" get secret weather-credentials >/dev/null 2>&1; then
  if [ -n "$(kubectl "${EDGE[@]}" -n "$NAMESPACE" get secret weather-credentials -o jsonpath='{.data.MQTT_PASSWORD}')" ]; then
    echo "  엣지 $NAMESPACE/weather-credentials 있음, 건너뜀"
  else
    # 값이 명령 인자에 남지 않게 표준입력으로 patch 합니다
    printf '{"data":{"MQTT_PASSWORD":"%s"}}' "$(printf '%s' "$MQTT_PW" | base64 -w0)" \
      | kubectl "${EDGE[@]}" -n "$NAMESPACE" patch secret weather-credentials --type merge --patch-file /dev/stdin >/dev/null
    echo "  엣지 $NAMESPACE/weather-credentials 에 MQTT_PASSWORD 추가"
  fi
  unset MQTT_PW; exit 0
fi
db_password() { kubectl "$@" -n "${DB_SECRET%%/*}" get secret "${DB_SECRET##*/}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; }
PG_HUB=$(db_password) || true; PG_LOCAL=$(db_password "${EDGE[@]}") || true
[ -n "$PG_HUB" ] || die "허브 $DB_SECRET 에서 POSTGRES_PASSWORD 를 읽지 못했습니다."
[ -n "$PG_LOCAL" ] || die "엣지 $DB_SECRET 에서 POSTGRES_PASSWORD 를 읽지 못했습니다(create-iot-secrets.sh 를 먼저 실행)."

# ---------- 2. 인증키 ----------
KMA_AUTH_KEY=${KMA_AUTH_KEY:-}
if [ -n "$KMA_AUTH_KEY" ]; then echo "  인증키: 환경 변수 KMA_AUTH_KEY"; else
  log "기상청 API허브 인증키 입력 (화면에 표시되지 않음)"
  read -rsp "authKey: " KMA_AUTH_KEY; echo
  [ -n "$KMA_AUTH_KEY" ] || die "인증키가 비어 있습니다."
fi
# 인증키와 매분자료 활용신청이 유효한지 한 분만 받아 봅니다
curl -fsS -m 60 "https://apihub.kma.go.kr/api/typ01/cgi-bin/url/nph-aws2_min?stn=133&disp=1&help=0&authKey=$KMA_AUTH_KEY" \
  | head -1 | grep -q '^#START7777' || die "API 응답이 올바르지 않습니다. 인증키와 '지상관측 > AWS 매분자료' 활용신청을 확인하세요."

# ---------- 3. Secret 만들기 ----------
log "엣지 $NAMESPACE/weather-credentials"
kubectl "${EDGE[@]}" create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl "${EDGE[@]}" apply -f - >/dev/null
printf 'KMA_AUTH_KEY=%s\nPGPASSWORD_LOCAL=%s\nPGPASSWORD_HUB=%s\nMQTT_PASSWORD=%s\n' "$KMA_AUTH_KEY" "$PG_LOCAL" "$PG_HUB" "$MQTT_PW" \
  | kubectl "${EDGE[@]}" -n "$NAMESPACE" create secret generic weather-credentials --from-env-file=/dev/stdin

unset KMA_AUTH_KEY PG_HUB PG_LOCAL MQTT_PW
log "완료"
```
{: file="create-weather-secret.sh" }

</details>

```bash
# 인증키를 입력받아 엣지에 Secret 생성 (이미 있으면 MQTT_PASSWORD 만 더함)
bash create-weather-secret.sh k8s-[SITE].yaml
```

- **확인:** `kubectl --kubeconfig k8s-[SITE].yaml -n weather describe secret weather-credentials` 에 키 4개(`KMA_AUTH_KEY`, `PGPASSWORD_LOCAL`, `PGPASSWORD_HUB`, `MQTT_PASSWORD`)가 보입니다. 인증키가 틀렸거나 활용신청이 안 되어 있으면 `API 응답이 올바르지 않습니다` 로 멈춥니다.

## 4. 엣지 Telegraf 에 날씨 입력 추가

수집기는 지점마다 토픽 두 개를 냅니다. `weather/[기기 이름]` 은 호스트 값과 같은 모양(`{"fields": {...}, "timestamp": <관측 시각 ms>}`)이고, `weather/[기기 이름]/availability` 는 Zigbee2MQTT 와 같은 연결 상태(`{"state": "online"}`)입니다. 엣지 Telegraf 에 이 두 토픽을 받는 입력을 더합니다. 단위와 제조사·모델·지점 번호(`hw_id`)는 수집기가 내는 Home Assistant 발견 설정(`origin` 이 `kma-weather`)에서 [Telegraf 글](/posts/43/)의 공통 starlark 가 배워 붙입니다. starlark 에는 날씨(`kma`) 처리가 이미 들어 있고, 발견 설정을 받는 입력은 [호스트 부하 글](/posts/74/)에서 추가하므로 아직 없으면 함께 더합니다.

```toml
# 호스트·NVR·날씨 값의 단위와 실물 정보. 세 수집기가 필드마다 Home Assistant 발견 설정(유지 메시지)을 내므로, 아래 starlark 가
# origin 이 host-metrics·nvr-occupancy·kma-weather 인 것만 골라 unit_of_measurement 와 device.manufacturer·model·serial_number 를 기억해 두고
# 그 기기 행에 unit·vendor·model·hw_id 로 붙입니다. NVR 의 감지 여부(occupant<N>_detected)는 binary_sensor 라 그 토픽도 받습니다.
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.mosquitto.svc.cluster.local:1883"]
  topics = ["homeassistant/sensor/+/+/config", "homeassistant/binary_sensor/+/+/config"]
  username = "${MQTT_USER}"
  password = "${MQTT_PASSWORD}"
  client_id = "telegraf-host-sensors"
  qos = 1
  topic_tag = ""
  name_override = "host_sensors"
  data_format = "value"
  data_type = "string"
```
{: file="iot/edge/telegraf/telegraf.conf (발견 설정 입력. 호스트 부하 글에서 추가했다면 건너뜀)" }

```toml
# 바깥 날씨(k8s-gitops iot/edge/weather). 수집기가 기상청 지상관측 매분자료를 지점마다 weather/<기기> 에 호스트와 같은 모양
# {"fields": {"temperature": 21.3, ...}, "timestamp": <관측 시각 ms>} 으로 냅니다. 기기 이름은 outdoor-weather-<지점 이름>입니다.
# 단위와 실물 정보(vendor KMA, model ASOS·AWS, hw_id 지점 번호)는 수집기가 내는 HA 발견 설정(origin kma-weather)에서 붙습니다.
# 수집기가 끊겼던 동안 빠진 분은 수집기가 DB 마다 직접 채웁니다(백필).
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.mosquitto.svc.cluster.local:1883"]
  topics = ["weather/+"]
  username = "${MQTT_USER}"
  password = "${MQTT_PASSWORD}"
  client_id = "telegraf-weather"
  persistent_session = true
  qos = 1
  topic_tag = ""
  name_override = "readings"
  data_format = "json_v2"
  [[inputs.mqtt_consumer.json_v2]]
    timestamp_path = "timestamp"      # 기상청 관측 시각(분)
    timestamp_format = "unix_ms"
    [[inputs.mqtt_consumer.json_v2.object]]
      path = "fields"
  [inputs.mqtt_consumer.tags]
    protocol = "http"
    source = "kma"
  [[inputs.mqtt_consumer.topic_parsing]]
    topic = "weather/+"
    tags = "_/device"

# 날씨 지점 연결 상태. online 은 기상청 API 가 그 지점 자료를 정상으로 돌려줄 때, offline 은 요청이 실패할 때·수집기가 멈출 때·끊길 때(Last Will)입니다.
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.mosquitto.svc.cluster.local:1883"]
  topics = ["weather/+/availability"]
  username = "${MQTT_USER}"
  password = "${MQTT_PASSWORD}"
  client_id = "telegraf-weather-availability"
  persistent_session = true
  qos = 1
  topic_tag = ""
  name_override = "readings"
  data_format = "json"
  json_string_fields = ["state"]
  [inputs.mqtt_consumer.tags]
    protocol = "http"
    source = "kma"
    property = "availability"
  [[inputs.mqtt_consumer.topic_parsing]]
    topic = "weather/+/availability"
    tags = "_/device/_"
```
{: file="iot/edge/telegraf/telegraf.conf (Zigbee2MQTT 제어 기록 입력 아래에 추가)" }

- **확인:** 이 단계는 파일 수정까지입니다. 다음 단계에서 수집기와 함께 push 합니다.

## 5. 수집기 매니페스트 추가

GitOps 저장소에 엣지 공통 베이스 `iot/edge/weather/` 와 지역 오버레이 `iot/clusters/daejeon/weather/` 를 만듭니다. 오버레이 폴더가 `daejeon-weather` Application 이 되어 엣지 클러스터의 `weather` 네임스페이스에 배포됩니다. 수집기는 파이썬 파일 두 개로, `collect.py` 가 기상청 API·MQTT·DB 를 다루고 `weather_core.py` 가 응답 읽기·페이로드·발견 설정·백필 SQL 같은 순수 로직을 맡습니다. 두 파일을 ConfigMap 으로 넣고 이미지는 `python:3.13-slim` 을 그대로 씁니다. 시작할 때 `paho-mqtt` 와 `psycopg` 를 빈 폴더(`/deps`)에 받으므로 따로 이미지를 만들 필요가 없습니다.

```yaml
# 바깥 날씨. 기상청 API허브 지상관측 매분자료를 지점마다 센서 하나(outdoor-weather-<지점 이름>)로 다룹니다.
# 1분마다 새 분을 MQTT weather/<기기> 에 내면 엣지 Telegraf 가 지역 DB 와 허브 DB 의 readings 에 room=outdoor, device=weather, processing=raw 로 넣고,
# Home Assistant 는 발견 설정으로 센서를 만듭니다. 연결 상태는 weather/<기기>/availability 입니다.
# 매시간 DB 마다 빈 분을 직접 백필합니다. 지역마다 자기 지점을 받으므로 인터넷이 끊기면 그동안의 날씨는 인터넷이 돌아온 뒤 백필로 채워집니다.
# 인증키, DB·브로커 비밀번호는 Secret weather-credentials 로 GitOps 밖에서 만듭니다 (create-weather-secret.sh).
resources:
  - deployment.yaml
configMapGenerator:
  - name: weather-collect
    files:
      - collect.py
      - weather_core.py
```
{: file="iot/edge/weather/kustomization.yaml" }

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: weather
spec:
  replicas: 1
  strategy:
    type: Recreate           # 두 파드가 같은 지점의 MQTT 연결(client_id)과 백필을 함께 쓰지 않게 합니다
  selector:
    matchLabels: { app: weather }
  template:
    metadata:
      labels: { app: weather }
    spec:
      securityContext:
        runAsUser: 1000
        runAsNonRoot: true
      containers:
        - name: collect
          image: python:3.13-slim
          command: ["sh", "-c"]
          args:
            # 패키지는 시작할 때 빈 폴더(/deps)에 받습니다(NVR 수집기와 같은 방식)
            - "pip install -q --no-cache-dir --disable-pip-version-check --target /deps 'paho-mqtt>=2,<3' 'psycopg[binary]>=3.2,<4' && exec python3 /app/collect.py"
          envFrom:
            # KMA_AUTH_KEY(기상청 API허브 인증키), PGPASSWORD_LOCAL·PGPASSWORD_HUB(DB 계정 iot), MQTT_PASSWORD(브로커 계정 telegraf).
            # GitOps 밖에서 만듭니다 (create-weather-secret.sh)
            - secretRef: { name: weather-credentials }
          env:
            # 지역 오버레이(iot/clusters/<지역>/weather/)가 STATIONS 와 DB_HUB 를 patch 로 넣습니다.
            # STATIONS: <지역>:<지점번호>:<model>:<anchor>, 여러 개는 공백으로. anchor(기준) 는 지점 이름(영문)이고 기기 이름은 outdoor-weather-<anchor> 입니다
            - { name: STATIONS, value: "" }
            - { name: DB_LOCAL, value: "timescaledb.timescaledb.svc.cluster.local:5432" }   # 지역 DB(iot/edge/timescaledb). 백필과 시작할 때 마지막 분 조회
            - { name: DB_HUB, value: "" }                                                  # 허브 DB. 비우면 허브는 백필하지 않습니다(실시간 값은 Telegraf 가 넣음)
            - { name: MQTT_BROKER, value: "mosquitto.mosquitto.svc.cluster.local" }
            - { name: MQTT_USER, value: "telegraf" }
            - { name: MISSING_FINAL_DAYS, value: "7" }   # 기상청도 값이 없는 분이 이 일수가 지나도 비어 있으면 영구 결측으로 보고 더 요청하지 않습니다
            - { name: BACKFILL_DAYS, value: "8" }        # 매시간 빈 분을 찾는 범위. 확정 기간보다 길게 둡니다(시작 직후 한 번은 센서 첫 기록부터 전체)
            - { name: PGUSER, value: iot }
            - { name: PGDATABASE, value: iot }
            - { name: PYTHONPATH, value: /deps }
            - { name: PYTHONUNBUFFERED, value: "1" }
            - { name: HOME, value: /tmp }
          volumeMounts:
            - { name: app, mountPath: /app }
            - { name: deps, mountPath: /deps }
            - { name: tmp, mountPath: /tmp }
          resources:
            requests: { cpu: 10m, memory: 48Mi }
            limits:   { cpu: 500m, memory: 256Mi }   # 시작할 때 pip 가 잠깐 씁니다
      terminationGracePeriodSeconds: 70              # 요청 제한 시간(60초) 안에 끝내고 offline 을 알립니다
      volumes:
        - name: app
          configMap: { name: weather-collect }
        - name: deps
          emptyDir: {}
        - name: tmp
          emptyDir: {}
```
{: file="iot/edge/weather/deployment.yaml" }

지점과 허브 DB 주소는 지역 오버레이가 넣습니다. 지역 DB 는 같은 클러스터의 Service 이름이라 베이스에 적어 두었습니다. 실시간 값은 엣지 Telegraf 가 두 DB 에 넣으므로, `DB_HUB` 를 비우면 허브 DB 의 백필만 하지 않습니다.

```yaml
# 대전 엣지의 바깥 날씨. 지점과 허브 DB 주소만 넣습니다.
resources:
  - ../../../edge/weather
patches:
  - patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: weather
      spec:
        template:
          spec:
            containers:
              - name: collect
                env:
                  # 133 대전(ASOS, 유성구 구성동), 648 장동(AWS, 대덕구 장동)
                  - { name: STATIONS, value: "daejeon:133:ASOS:daejeon daejeon:648:AWS:jangdong" }
                  - { name: DB_HUB, value: "[HUB_VIP]:30432" }   # 허브 control plane VIP. NodePort 30432 가 Patroni 의 주 DB 로 넘깁니다
```
{: file="iot/clusters/daejeon/weather/kustomization.yaml" }

지점은 env `STATIONS` 에 `<지역>:<지점번호>:<model>:<anchor>` 로 적고, 기기 이름은 `outdoor-weather-<anchor>` 가 됩니다. 다른 지역을 추가하면 그 지역의 오버레이에 그 지역 지점을 적고, 수집기는 그 지역 센서가 처음 기록된 시각부터 채웁니다.

<details markdown="1">
<summary>collect.py 전문</summary>

```python
#!/usr/bin/env python3
"""
바깥 날씨 수집기. 기상청 API허브 지상관측 매분자료(ASOS·AWS 지점 모두)를 지점마다 센서 하나로 다룹니다.

- 실시간: 1분마다 지점별 최근 LIVE_MINUTES 분을 받아, 아직 내지 않은 분만 MQTT weather/<기기> 에 관측 시각으로 냅니다.
  엣지 Telegraf 가 받아 지역 DB 와 허브 DB 의 readings 에 원본(processing=raw)으로 넣고, Home Assistant 는 발견 설정으로 센서를 만듭니다.
  늦게 올라온 분도 이 안이면 다음 주기에 나갑니다. 시작할 때는 지역 DB 의 마지막 분 뒤부터 냅니다.
- 연결 상태: 지점마다 MQTT 연결을 따로 두고 weather/<기기>/availability 에 retained 로 냅니다. 기상청 API 가 그 지점 자료를 정상으로
  돌려주면 online, 요청이 실패하거나 응답이 비정상이면 offline, 수집기가 멈추면 offline, 끊기면 브로커가 Last Will 로 offline 을 냅니다.
- 백필: DB 마다 따로, 시작 직후 한 번은 그 지역 센서의 첫 기록부터, 이후 BACKFILL_EVERY 분마다 최근 BACKFILL_DAYS 일에서 빈 분을 찾아
  그 구간만 다시 받아 그 DB 에 직접 넣습니다(없는 행만). 수집기나 허브가 끊겼던 동안 빠진 분이 이렇게 채워집니다(기상청이 값을 가진 동안).
- 결측: 기상청도 값이 없다고 답한 분은 그 DB 의 weather_missing 에 남기고, MISSING_FINAL_DAYS 일 지나도 비어 있으면 더 요청하지 않습니다.

env: STATIONS("<지역>:<지점번호>:<model>:<지점 이름> …"), KMA_AUTH_KEY, DB_LOCAL·DB_HUB("<호스트>:<포트>", 비우면 그 DB 는 백필 안 함),
     PGPASSWORD_LOCAL·PGPASSWORD_HUB, PGUSER, PGDATABASE, MQTT_BROKER, MQTT_PORT, MQTT_USER, MQTT_PASSWORD
"""

import json
import logging
import os
import signal
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import paho.mqtt.client as mqtt
import psycopg
from weather_core import (
    GAPS_SQL,
    INSERT_SQL,
    LAST_MINUTE_SQL,
    MISSING_SQL,
    PREPARE_SQL,
    STATE_PREFIX,
    STORE_COLUMNS,
    Station,
    availability_payload,
    availability_topic,
    build_discovery,
    count_lines,
    live_window,
    parse_minutes,
    parse_stations,
    payload,
    rows,
    unpublished,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", datefmt="%Y-%m-%dT%H:%M:%S%z")
log = logging.getLogger("weather")

API = "https://apihub.kma.go.kr/api/typ01/cgi-bin/url/nph-aws2_min"
LIVE_MINUTES = int(os.getenv("LIVE_MINUTES", "15"))
BACKFILL_EVERY = int(os.getenv("BACKFILL_EVERY", "60"))
BACKFILL_DAYS = int(os.getenv("BACKFILL_DAYS", "8"))
BACKFILL_MAX_CALLS = int(os.getenv("BACKFILL_MAX_CALLS", "50"))  # 한 번의 백필에서 지점별 요청 수 상한
MISSING_FINAL_DAYS = int(os.getenv("MISSING_FINAL_DAYS", "7"))
MQTT_BROKER = os.getenv("MQTT_BROKER", "mosquitto.mosquitto.svc.cluster.local")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_USER = os.getenv("MQTT_USER", "telegraf")

stop = threading.Event()


def fetch(stn: str, tm1: str, tm2: str) -> str | None:
    """매분자료 한 구간(KST, 최대 6시간)을 받는다. 요청이 실패하면 None."""
    query = urllib.parse.urlencode(
        {"tm1": tm1, "tm2": tm2, "stn": stn, "disp": 1, "help": 0, "authKey": os.environ["KMA_AUTH_KEY"]}
    )
    try:
        with urllib.request.urlopen(f"{API}?{query}", timeout=60) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        log.warning("%s %s~%s 요청 실패: %s", stn, tm1, tm2, exc)
        return None


def db_conninfo(which: str) -> str | None:
    """local·hub DB 접속 정보. 주소가 비어 있으면 None(그 DB 는 쓰지 않음)."""
    addr = os.getenv("DB_LOCAL" if which == "local" else "DB_HUB", "")
    if not addr:
        return None
    host, port = addr.rsplit(":", 1)
    return psycopg.conninfo.make_conninfo(
        host=host,
        port=port,
        user=os.getenv("PGUSER", "iot"),
        dbname=os.getenv("PGDATABASE", "iot"),
        password=os.getenv("PGPASSWORD_LOCAL" if which == "local" else "PGPASSWORD_HUB", ""),
        connect_timeout=10,
        options="-c TimeZone=Asia/Seoul",  # to_timestamp('YYYYMMDDHH24MI') 가 KST 로 읽히게
    )


class Sensor:
    """지점 하나 = MQTT 연결 하나. Last Will 은 연결마다 하나라서 지점마다 따로 연결한다."""

    def __init__(self, station: Station) -> None:
        self.station = station
        self.online: bool | None = None
        self.published: set[datetime] = set()
        self.floor: datetime | None = None
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"weather-{station.device}")
        client.username_pw_set(MQTT_USER, os.getenv("MQTT_PASSWORD", ""))
        client.will_set(availability_topic(station.device), availability_payload(False), qos=1, retain=True)
        client.on_connect = self._on_connect
        client.connect_async(MQTT_BROKER, MQTT_PORT, keepalive=60)
        client.loop_start()
        self.client = client

    def _on_connect(self, client, _userdata, _flags, reason_code, _properties) -> None:
        if reason_code != 0:
            log.warning("%s MQTT 연결 실패: %s", self.station.device, reason_code)
            return
        log.info("%s MQTT 연결", self.station.device)
        for topic, config in build_discovery(self.station).items():
            client.publish(topic, json.dumps(config, ensure_ascii=False), qos=1, retain=True)
        if self.online is not None:
            # 끊겼던 동안 브로커가 Last Will 로 offline 을 냈으므로 지금 상태를 다시 알린다
            client.publish(
                availability_topic(self.station.device), availability_payload(self.online), qos=1, retain=True
            )

    def set_online(self, online: bool) -> None:
        """연결 상태가 바뀌었을 때만 retained 로 알린다."""
        if online == self.online:
            return
        self.online = online
        self.client.publish(availability_topic(self.station.device), availability_payload(online), qos=1, retain=True)
        log.info("%s 연결 상태: %s", self.station.device, "online" if online else "offline")

    def live(self, now: datetime) -> None:
        """최근 LIVE_MINUTES 분을 받아 새 분만 낸다."""
        tm1, tm2 = live_window(now, LIVE_MINUTES)
        body = fetch(self.station.stn, tm1, tm2)
        minutes = parse_minutes(body, self.station.stn) if body is not None else None
        if minutes is None:
            if body is not None:
                log.warning("%s 응답 오류: %s", self.station.device, body[:200])
            self.set_online(False)
            return
        self.set_online(True)
        topic = f"{STATE_PREFIX}/{self.station.device}"
        new = unpublished(minutes, self.published, self.floor)
        for minute in new:
            self.client.publish(topic, payload(minute, minutes[minute]), qos=1)
            self.published.add(minute)
        oldest = min(minutes) if minutes else None
        if oldest is not None:
            self.published = {m for m in self.published if m >= oldest}  # 받는 구간 밖으로 밀려난 분은 잊는다

    def close(self) -> None:
        """offline 을 알린 뒤 끊는다. 정상 종료에서는 브로커가 Last Will 을 내지 않는다."""
        info = self.client.publish(
            availability_topic(self.station.device), availability_payload(False), qos=1, retain=True
        )
        try:
            info.wait_for_publish(timeout=5)
        except (RuntimeError, ValueError) as exc:
            log.warning("%s offline 발행 확인 실패: %s", self.station.device, exc)
        self.client.loop_stop()
        self.client.disconnect()


def last_minute(station: Station) -> datetime | None:
    """지역 DB 에 이미 있는 그 지점의 마지막 관측 분. DB 가 안 닿으면 None(최근 구간을 다시 내고 DB 중복 정리 작업이 지움)."""
    info = db_conninfo("local")
    if info is None:
        return None
    try:
        with psycopg.connect(info) as conn:
            return conn.execute(LAST_MINUTE_SQL, {"site": station.site, "stn": station.stn}).fetchone()[0]
    except psycopg.Error as exc:
        log.warning("%s 지역 DB 의 마지막 분 조회 실패: %s", station.device, exc)
        return None


def store(which: str, station: Station, tm1: str, tm2: str, body: str) -> None:
    """백필: 받은 구간을 한 DB 에 없는 행만 넣고 결측 기록을 맞춘다(한 트랜잭션)."""
    minutes = parse_minutes(body, station.stn) or {}
    lines = count_lines(body, station.stn)
    params = {"site": station.site, "stn": station.stn, "tm1": tm1, "tm2": tm2, "lines": lines, "live": LIVE_MINUTES}
    with psycopg.connect(db_conninfo(which)) as conn, conn.cursor() as cur:
        cur.execute("CREATE TEMP TABLE t (LIKE readings) ON COMMIT DROP")
        with cur.copy(f"COPY t ({STORE_COLUMNS}) FROM STDIN") as copy:
            for row in rows(station, minutes):
                copy.write_row(row)
        n_minutes, n_rows = cur.execute(INSERT_SQL).fetchone()
        n_missing = cur.execute(MISSING_SQL, params).fetchone()[0]
    if n_rows or n_missing:
        log.info(
            "%s: %s %s~%s %d분 %d행 넣음, 결측 %d분", which, station.device, tm1, tm2, n_minutes, n_rows, n_missing
        )


def backfill(stations: list[Station], days: int) -> None:
    """DB 마다 빈 분을 찾아 그 구간만 다시 받아 넣는다. 한 DB 가 안 닿아도 다른 DB 는 계속한다."""
    for which in ("local", "hub"):
        info = db_conninfo(which)
        if info is None:
            continue
        for station in stations:
            if stop.is_set():
                return
            params = {"site": station.site, "stn": station.stn, "days": days, "live": LIVE_MINUTES}
            params |= {"final": MISSING_FINAL_DAYS, "max": BACKFILL_MAX_CALLS}
            try:
                with psycopg.connect(info) as conn:
                    conn.execute(PREPARE_SQL)
                    ranges = conn.execute(GAPS_SQL, params).fetchall()
            except psycopg.Error as exc:
                log.warning("%s: %s 빈 구간 조회 실패: %s", which, station.device, exc)
                continue
            if ranges:
                log.info("%s: %s 백필 %d구간", which, station.device, len(ranges))
            for tm1, tm2 in ranges:
                if stop.is_set():
                    return
                body = fetch(station.stn, tm1, tm2)
                if body is None or parse_minutes(body, station.stn) is None:
                    continue
                try:
                    store(which, station, tm1, tm2, body)
                except psycopg.Error as exc:
                    log.warning("%s: %s %s~%s DB 쓰기 실패: %s", which, station.device, tm1, tm2, exc)


def main() -> int:
    """실시간 발행과 백필을 멈출 때까지 반복한다."""
    try:
        stations = parse_stations(os.getenv("STATIONS", ""))
    except ValueError as exc:
        log.error("%s", exc)
        return 2
    if not stations or not os.getenv("KMA_AUTH_KEY"):
        log.error("STATIONS 와 KMA_AUTH_KEY 가 필요합니다")
        return 2
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    log.info(
        "지점: %s, 백필 DB: %s",
        " ".join(s.device for s in stations),
        " ".join(w for w in ("local", "hub") if db_conninfo(w)) or "없음",
    )
    sensors = [Sensor(s) for s in stations]
    for sensor in sensors:
        sensor.floor = last_minute(sensor.station)

    next_backfill = 0.0
    days = 36500  # 시작 직후: 센서 첫 기록부터 전체
    while not stop.is_set():
        started = time.time()
        now = datetime.now(timezone.utc)
        for sensor in sensors:
            sensor.live(now)
        if time.time() >= next_backfill:
            backfill(stations, days)
            days = BACKFILL_DAYS
            next_backfill = time.time() + BACKFILL_EVERY * 60
        stop.wait(max(1.0, 60 - (time.time() - started)))

    log.info("종료 신호: offline 을 알리고 끝냅니다")
    for sensor in sensors:
        sensor.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
```
{: file="iot/edge/weather/collect.py" }

</details>

<details markdown="1">
<summary>weather_core.py 전문</summary>

{% raw %}
```python
"""날씨 수집기의 순수 로직: 기상청 응답 읽기, MQTT 페이로드, Home Assistant 발견 설정, 백필 SQL.

paho·psycopg 를 import 하지 않아 수집기 이미지 밖에서도 테스트할 수 있다(test_weather_core.py).
- 지점 하나가 기기 하나(outdoor-weather-<지점 이름>)다. 호스트·NVR 처럼 weather/<기기> 에 {"fields": {...}, "timestamp": <ms>} 를 내고
  엣지 Telegraf 가 받아 지역·허브 DB 의 readings 에 넣는다.
- 발견 설정: 엣지 Telegraf 가 origin 으로 골라 unit·vendor(KMA)·model(ASOS·AWS)·hw_id(지점 번호, serial_number)를 붙인다.
- 연결 상태: weather/<기기>/availability 에 retained {"state": "online"|"offline"}. 기상청 API 가 그 지점 자료를 정상으로 돌려주면 online.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))
DISCOVERY_PREFIX = "homeassistant"
STATE_PREFIX = "weather"
ORIGIN = {"name": "kma-weather"}  # 엣지 Telegraf 가 이 발견 설정만 골라 단위·실물 정보를 읽는 표식
VENDOR = "KMA"
MISSING_BELOW = -50  # 기상청 매분자료에서 -50 이하는 결측(-99.9 등)


@dataclass(frozen=True)
class Field:
    """매분자료 한 열 = readings 속성 하나."""

    column: int  # 0부터 센 열 번호(응답의 쉼표 구분)
    prop: str
    unit: str
    name: str  # HA 엔티티 이름
    device_class: str | None


# 열: 0 시각, 1 지점, 2 WD1, 3 WS1, 5 WSS, 8 TA, 11 RN-60m, 13 RN-DAY, 14 HM, 15 PA, 17 TD
FIELDS = [
    Field(8, "temperature", "°C", "기온", "temperature"),
    Field(14, "humidity", "%", "습도", "humidity"),
    Field(15, "pressure", "hPa", "기압", "atmospheric_pressure"),
    Field(17, "dew_point", "°C", "이슬점", "temperature"),
    Field(2, "wind_direction", "°", "풍향", None),
    Field(3, "wind_speed", "m/s", "풍속", "wind_speed"),
    Field(5, "wind_gust_speed", "m/s", "순간 최대 풍속", "wind_speed"),
    Field(11, "precipitation_1h", "mm", "1시간 강수량", "precipitation"),
    Field(13, "precipitation_day", "mm", "일 강수량", "precipitation"),
]


@dataclass(frozen=True)
class Station:
    """STATIONS 의 한 항목 <지역>:<지점 번호>:<model>:<지점 이름>."""

    site: str
    stn: str
    model: str
    anchor: str

    @property
    def device(self) -> str:
        """readings 의 기기 이름. Telegraf 가 room outdoor, device weather, anchor 지점 이름으로 나눈다."""
        return f"outdoor-weather-{self.anchor}"


def parse_stations(text: str) -> list[Station]:
    """공백으로 나눈 STATIONS 값을 읽는다. 형식이 틀린 항목이 있으면 ValueError."""
    out = []
    for item in text.split():
        parts = item.split(":")
        if len(parts) != 4 or not all(parts):
            raise ValueError(f"STATIONS 항목 형식이 <지역>:<지점>:<model>:<지점 이름> 이 아닙니다: {item}")
        out.append(Station(*parts))
    return out


def parse_minutes(body: str, stn: str) -> dict[datetime, dict[str, float]] | None:
    """매분자료 응답을 분(KST) → {속성: 값} 으로 읽는다. 응답이 정상이 아니면 None.

    결측(-50 이하)과 숫자가 아닌 칸은 빼고, 값이 하나도 없는 분도 뺀다.
    """
    if not body.startswith("#START7777"):
        return None
    out: dict[datetime, dict[str, float]] = {}
    for line in body.splitlines():
        if not line or line.startswith("#"):
            continue
        cols = [c.strip() for c in line.split(",")]
        if len(cols) < 2 or cols[1] != stn:
            continue
        try:
            minute = datetime.strptime(cols[0], "%Y%m%d%H%M").replace(tzinfo=KST)
        except ValueError:
            continue
        values = {}
        for f in FIELDS:
            try:
                v = float(cols[f.column])
            except (IndexError, ValueError):
                continue
            if v > MISSING_BELOW:
                values[f.prop] = v
        if values:
            out[minute] = values
    return out


def count_lines(body: str, stn: str) -> int:
    """응답에 그 지점 줄(분)이 몇 개 있는지 센다. 값이 모두 결측인 분도 센다(결측 기록 판단용)."""
    return sum(
        1
        for line in body.splitlines()
        if line and not line.startswith("#") and len(line.split(",")) > 1 and line.split(",")[1].strip() == stn
    )


def kst_minute(t: datetime) -> str:
    """API 인자 형식(KST YYYYMMDDHHMI)."""
    return t.astimezone(KST).strftime("%Y%m%d%H%M")


def live_window(now: datetime, minutes: int) -> tuple[str, str]:
    """실시간으로 받을 구간: 지금(분 내림) 기준 minutes 분 전부터 1분 전까지."""
    end = now.replace(second=0, microsecond=0)
    return kst_minute(end - timedelta(minutes=minutes)), kst_minute(end - timedelta(minutes=1))


def payload(minute: datetime, values: dict[str, float]) -> str:
    """weather/<기기> 페이로드. 호스트·NVR 과 같은 모양이라 엣지 Telegraf 가 json_v2 로 읽는다."""
    return json.dumps({"fields": values, "timestamp": int(minute.timestamp() * 1000)})


def availability_topic(device: str) -> str:
    """기기 연결 상태 토픽. Zigbee2MQTT 의 <기기>/availability 와 같은 자리다."""
    return f"{STATE_PREFIX}/{device}/availability"


def availability_payload(online: bool) -> str:
    """연결 상태 페이로드. Zigbee2MQTT 와 같은 모양이다."""
    return json.dumps({"state": "online" if online else "offline"})


def build_discovery(station: Station) -> dict[str, dict]:
    """지점 하나의 속성마다 HA 센서 발견 설정(토픽 → 내용)을 만든다."""
    device = station.device
    info = {
        "identifiers": [device],
        "name": device,
        "manufacturer": VENDOR,
        "model": station.model,
        "serial_number": station.stn,  # 엣지 Telegraf 가 readings.hw_id 로 쓴다
    }
    configs = {}
    for f in FIELDS:
        config = {
            "name": f.name,
            "unique_id": f"{device}_{f.prop}",
            "default_entity_id": f"sensor.{device.replace('-', '_')}_{f.prop}",
            "state_topic": f"{STATE_PREFIX}/{device}",
            # 결측인 분은 필드가 없다 → None 이면 HA 가 상태를 비운다(마지막 값이 남지 않음)
            "value_template": f"{{{{ value_json.fields['{f.prop}'] if '{f.prop}' in value_json.fields else None }}}}",
            "unit_of_measurement": f.unit,
            "state_class": "measurement",
            "availability": [
                {
                    "topic": availability_topic(device),
                    "value_template": "{{ value_json.state }}",
                }
            ],
            "device": info,
            "origin": ORIGIN,
        }
        if f.device_class:
            config["device_class"] = f.device_class
        if f.device_class == "wind_speed":
            config["suggested_unit_of_measurement"] = f.unit  # HA 가 km/h 로 바꿔 보이지 않게 DB 와 같은 m/s 로 둔다
        configs[f"{DISCOVERY_PREFIX}/sensor/{device}/{f.prop}/config"] = config
    return configs


def rows(station: Station, minutes: dict[datetime, dict[str, float]]) -> list[tuple]:
    """백필로 DB 에 직접 넣을 readings 행(STORE_COLUMNS 순서). Telegraf 가 넣는 행과 같은 값이다."""
    unit = {f.prop: f.unit for f in FIELDS}
    out = []
    for minute in sorted(minutes):
        for prop, value in minutes[minute].items():
            out.append(
                (
                    minute,
                    station.site,
                    "outdoor",
                    "weather",
                    station.anchor,
                    prop,
                    "raw",
                    value,
                    unit[prop],
                    "http",
                    "kma",
                    VENDOR,
                    station.model,
                    station.stn,
                )
            )
    return out


def unpublished(
    minutes: dict[datetime, dict[str, float]],
    published: set[datetime],
    floor: datetime | None,
) -> list:
    """아직 발행하지 않은 분을 시각 순으로 고른다. floor 이하(시작할 때 DB 에 이미 있던 분)는 건너뛴다."""
    return sorted(m for m in minutes if m not in published and (floor is None or m > floor))


STORE_COLUMNS = (
    "time, site, room, device, anchor, property, processing, value, unit, protocol, source, vendor, model, hw_id"
)

PREPARE_SQL = """
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS weather_missing (
  site text NOT NULL, hw_id text NOT NULL, time timestamptz NOT NULL,   -- 기상청도 값이 없다고 답한 분(지점 번호 hw_id)
  checked_at timestamptz NOT NULL,                                       -- 마지막으로 다시 받아 본 시각. time 에서 MISSING_FINAL_DAYS 일 지나면 확정
  PRIMARY KEY (site, hw_id, time)
);
"""

# 없는 행만 넣습니다(이미 있는 분은 건너뜀). availability 행도 source kma·hw_id 지점이라 속성까지 비교합니다
INSERT_SQL = """
WITH ins AS (
  INSERT INTO readings SELECT t.* FROM t
  WHERE NOT EXISTS (SELECT 1 FROM readings r WHERE r.time = t.time AND r.site = t.site AND r.source = 'kma' AND r.hw_id = t.hw_id
                      AND r.property = t.property AND r.processing = 'raw')
  RETURNING time
) SELECT count(DISTINCT time), count(*) FROM ins
"""

# 값이 들어온 분은 결측 기록에서 지우고, 응답에 줄이 있었는데 값이 없는 분은 결측으로 남깁니다.
# 줄이 하나도 없는 응답은 API 일시 오류일 수 있어 결측으로 남기지 않습니다. 아직 올라오지 않았을 최근 live 분도 남기지 않습니다.
MISSING_SQL = """
WITH gone AS (
  DELETE FROM weather_missing WHERE site = %(site)s AND hw_id = %(stn)s AND time IN (SELECT time FROM t)
), miss AS (
  INSERT INTO weather_missing (site, hw_id, time, checked_at)
  SELECT %(site)s, %(stn)s, m, now()
  FROM generate_series(to_timestamp(%(tm1)s, 'YYYYMMDDHH24MI'), to_timestamp(%(tm2)s, 'YYYYMMDDHH24MI'), interval '1 minute') m
  WHERE %(lines)s > 0 AND m < now() - make_interval(mins => %(live)s)
    AND NOT EXISTS (SELECT 1 FROM t WHERE t.time = m)
    AND NOT EXISTS (SELECT 1 FROM readings r WHERE r.time = m AND r.site = %(site)s AND r.source = 'kma' AND r.hw_id = %(stn)s
                      AND r.property <> 'availability')
  ON CONFLICT (site, hw_id, time) DO UPDATE SET checked_at = excluded.checked_at
  RETURNING 1
) SELECT count(*) FROM miss
"""

# 그 DB 에서 백필할 구간(KST tm1 tm2, 6시간 이하). 대상은 그 지역 센서의 첫 기록(분 내림)부터 최근 live 분 전까지 가운데,
# 날씨 행이 없고 결측 기록으로도 쉬지 않는 분입니다. 결측 기록은 확정(final 일 뒤에도 비어 있음)이면 영원히, 아니면 재확인 간격
# (하루 안의 분은 약 1시간, 그 뒤는 약 하루) 동안 쉽니다.
GAPS_SQL = """
WITH bounds AS (
  SELECT greatest(date_trunc('minute', min(time)), date_trunc('minute', now()) - make_interval(days => %(days)s)) AS s
  FROM readings WHERE site = %(site)s AND source <> 'kma'
  HAVING min(time) IS NOT NULL   -- 그 지역 센서 기록이 아직 없으면 받지 않습니다(greatest 는 NULL 을 무시해 먼 과거부터 받게 됩니다)
), todo AS (
  SELECT m FROM bounds, generate_series(s, date_trunc('minute', now()) - make_interval(mins => %(live)s), interval '1 minute') m
  WHERE NOT EXISTS (SELECT 1 FROM readings r WHERE r.time = m AND r.site = %(site)s AND r.source = 'kma' AND r.hw_id = %(stn)s
                      AND r.property <> 'availability')
    AND NOT EXISTS (SELECT 1 FROM weather_missing w WHERE w.site = %(site)s AND w.hw_id = %(stn)s AND w.time = m
                      AND (w.checked_at - w.time >= make_interval(days => %(final)s)
                           OR w.checked_at > now() - CASE WHEN now() - w.time < interval '1 day' THEN interval '50 minutes'
                                                          ELSE interval '23 hours' END))
), island AS (
  SELECT min(m) a, max(m) b FROM (SELECT m, m - (row_number() OVER (ORDER BY m)) * interval '1 minute' g FROM todo) x GROUP BY g
)
SELECT to_char(c, 'YYYYMMDDHH24MI'), to_char(least(c + interval '6 hours' - interval '1 minute', b), 'YYYYMMDDHH24MI')
FROM island, generate_series(a, b, interval '6 hours') c
ORDER BY c LIMIT %(max)s
"""

# 시작할 때 지점별로 이미 DB 에 있는 마지막 관측 분. 그 뒤부터 발행해 재시작 때 같은 분을 다시 내지 않습니다
LAST_MINUTE_SQL = """
SELECT max(time) FROM readings
WHERE time > now() - interval '1 day' AND site = %(site)s AND source = 'kma' AND hw_id = %(stn)s AND property <> 'availability'
"""
```
{: file="iot/edge/weather/weather_core.py" }
{% endraw %}

</details>

수집기가 기상청 API 와 MQTT·DB 에 맞춰 처리하는 부분은 다음과 같습니다.

- **실시간 발행:** 1분마다 지점별 최근 15분을 받아 아직 내지 않은 분만 관측 시각으로 발행합니다. 시작할 때는 지역 DB 에 있는 그 지점의 마지막 분 뒤부터 내므로 재시작해도 같은 분을 다시 내지 않습니다. DB 에 쓰는 일은 엣지 Telegraf 가 맡으므로 허브가 끊겨도 Telegraf 의 디스크 버퍼가 받아 두었다가 채웁니다.
- **아직 안 올라온 분:** 반영까지 1~3분 걸리고, 그 전에는 모든 값이 `-99.9` 인 줄로 옵니다. `-50` 이하 값은 버리므로 값이 하나도 없는 분은 발행하지 않고, 최근 15분 안에 있는 동안 다음 주기에 다시 받아 냅니다.
- **Home Assistant 센서:** 지점마다 속성 9개의 발견 설정을 유지 메시지로 냅니다. 결측인 분은 필드가 빠지므로 센서 상태가 비워지고, 풍속은 HA 가 km/h 로 바꿔 보이지 않게 DB 와 같은 m/s 를 표시 단위로 줍니다.
- **연결 상태:** Last Will 은 MQTT 연결마다 하나라서 지점마다 연결을 따로 둡니다. 기상청 API 가 그 지점 자료를 정상으로 돌려주면 `online`, 요청이 실패하거나 응답이 비정상이면 `offline` 이고, 수집기가 멈출 때 `offline` 을 내며 끊기면 브로커가 Last Will 로 `offline` 을 냅니다. HA 센서는 `사용할 수 없음` 이 되고 DB 에는 속성 `availability` 행이 남습니다.
- **빈 분 백필:** 매시간 DB 마다 최근 8일에서 날씨 원본 행이 없는 분(연결 상태 행은 세지 않음)을 찾아 연속 구간으로 묶어 다시 받고, 그 DB 에 없는 행만 직접 넣습니다. 수집기나 허브가 끊겼던 동안 빠진 분이 이렇게 채워집니다. 긴 구간은 응답이 수십 초씩 걸려 6시간씩 끊어 받습니다.
- **영구 결측:** 응답에 줄은 있는데 값이 없는 분은 그 DB 의 `weather_missing` 테이블에 남깁니다. 하루 안의 분은 약 1시간마다, 그 뒤로는 약 하루마다 다시 확인하고, 7일이 지나도 비어 있으면 영구 결측으로 보고 더 요청하지 않습니다. 줄이 하나도 없는 응답은 API 일시 오류일 수 있어 결측으로 남기지 않습니다.

```bash
# 커밋하고 push (Telegraf 입력과 수집기를 함께)
git add iot/edge/telegraf/telegraf.conf iot/edge/weather iot/clusters/daejeon/weather
git commit -m "feat(iot): 기상청 1분 자료를 MQTT 센서로 내는 바깥 날씨 수집기 추가"
git push
```

- **확인:** 이 단계는 push 까지입니다. 배포는 다음 단계에서 확인합니다.

## 6. 배포와 확인

Argo CD 가 저장소를 다시 읽으면(최대 3분) `[SITE]-telegraf` 가 새 설정으로 다시 뜨고, `daejeon-weather` Application 이 생겨 엣지에 파드가 뜹니다. 파드는 패키지를 받은 뒤 지점마다 브로커에 붙어 발견 설정을 내고 새 분을 발행하기 시작합니다. 이어서 DB 마다 그 지역 센서의 첫 기록부터 지금까지 빈 분을 채운 뒤 1분 주기로 돕니다.

```bash
# 허브 control plane: 수집기 로그와 브로커의 날씨 메시지
E="--kubeconfig k8s-[SITE].yaml"
kubectl $E -n weather logs deploy/weather
PW=$(kubectl $E -n telegraf get secret telegraf-credentials -o jsonpath='{.data.MQTT_PASSWORD}' | base64 -d)
kubectl $E -n mosquitto exec deploy/mosquitto -- mosquitto_sub -u telegraf -P "$PW" -t 'weather/+/availability' -C 2 -v
kubectl $E -n mosquitto exec deploy/mosquitto -- mosquitto_sub -u telegraf -P "$PW" -t 'weather/+' -C 1 -v
```

- **확인:** Application `daejeon-weather` 가 `Synced`, `Healthy` 입니다. 로그 첫머리에 `지점: outdoor-weather-daejeon outdoor-weather-jangdong, 백필 DB: local hub` 가 보이고, 지점마다 `MQTT 연결` 과 `연결 상태: online` 이 찍힙니다. 빈 분이 있으면 `local:`, `hub:` 로 DB 마다 `백필 N구간` 과 `N분 N행 넣음, 결측 N분` 이 찍힙니다. 연결 상태 구독에는 두 지점의 `{"state": "online"}` 이, 날씨 구독에는 1분 안에 `{"fields": {"temperature": …}, "timestamp": …}` 모양의 메시지가 나옵니다. 기상청이 가끔 `504 Gateway Timeout` 으로 답하면 `요청 실패` 와 `연결 상태: offline` 이 찍히고, 다음 주기에 받으면 `online` 으로 돌아오며 그 분은 최근 15분 안에서 다시 받습니다.

```bash
# 지점별 적재 범위·중복·연결 상태: 지역 DB, 허브 DB 순서 (주 DB 파드는 Patroni 가 role=primary 라벨을 붙임)
Q1="select anchor, hw_id, count(distinct time) minutes, min(time) at time zone 'Asia/Seoul' first_kst, max(time) at time zone 'Asia/Seoul' last_kst
    from readings where source = 'kma' and property <> 'availability' group by 1, 2;"
Q2="select count(*) dup from (select time, hw_id, property from readings where source = 'kma' group by 1, 2, 3 having count(*) > 1) d;"
Q3="select distinct on (anchor) anchor, time at time zone 'Asia/Seoul' kst, value_text, value
    from readings where source = 'kma' and property = 'availability' order by anchor, time desc;"
kubectl $E -n timescaledb exec $(kubectl $E -n timescaledb get pod -l role=primary -o name) -- psql -U iot -d iot -c "$Q1" -c "$Q2" -c "$Q3"
kubectl -n timescaledb exec $(kubectl -n timescaledb get pod -l role=primary -o name) -- psql -U iot -d iot -c "$Q1" -c "$Q2" -c "$Q3"
```

- **확인:** 두 DB 의 조회에 두 지점이 보이고, `first_kst` 가 그 지역 센서의 첫 기록 분, `last_kst` 가 지금보다 1~3분 전이며, `dup` 은 0 입니다. 연결 상태는 지점마다 마지막 행이 `online`·`1` 입니다. 지역 HA 의 **설정** > **기기 및 서비스** > **MQTT** 에 기기 `outdoor-weather-daejeon`, `outdoor-weather-jangdong` 이 생기고 센서가 9개씩 보입니다. 영역은 [호스트 부하 글](/posts/74/) 5단계와 같은 `ha-registry.py --assign-areas` 로 배정하며, 방 칸 `outdoor` 는 `실외` 영역이 됩니다. 허브 Grafana 와 지역 Grafana 의 **IoT 기록** 대시보드에서는 **temperature**·**humidity** 패널에 `room` 이 `outdoor` 인 두 지점(`daejeon`, `jangdong`)의 시리즈가 실내 센서와 함께 그려집니다.

## 마무리

기상청 API허브 매분자료를 지점마다 MQTT 센서로 내는 수집기를 지역 엣지에 GitOps 로 배포했습니다. 새 분은 엣지 Telegraf 가 지역 TimescaleDB 와 허브 TimescaleDB 의 `readings` 에 바깥 날씨 원본 행으로 넣고, Home Assistant 에는 지점마다 센서와 연결 상태가 생깁니다. 매시간 DB 마다 빈 분을 직접 백필하며, 기상청에도 없는 분은 7일 뒤 영구 결측으로 확정해 같은 구간을 끝없이 다시 요청하지 않습니다. 지점을 바꿀 때는 지역 오버레이의 `STATIONS` 한 줄만 고치고, 다른 지역을 추가할 때는 그 지역의 오버레이를 만들고 Secret 스크립트를 그 엣지에 실행합니다.

## 참고 자료

- [기상청 API허브 - 이용안내](https://apihub.kma.go.kr/apiInfo.do)
- [기상청 API허브 - 지상관측 AWS 매분자료](https://apihub.kma.go.kr/apiList.do?seqApi=2&seqApiSub=239)
- [Home Assistant - MQTT Discovery](https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery)
- [PostgreSQL - INSERT (ON CONFLICT)](https://www.postgresql.org/docs/17/sql-insert.html)
- [psycopg 3 - Using COPY TO and COPY FROM](https://www.psycopg.org/psycopg3/docs/basic/copy.html)
- [TimescaleDB - Hypertables](https://docs.timescale.com/use-timescale/latest/hypertables/)
