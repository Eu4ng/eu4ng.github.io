---
layout: post
title: 기상청 API허브 1분 자료를 TimescaleDB에 바깥 날씨로 모으고 빈 구간 백필하는 방법
description: 기상청 API허브의 지상관측 매분자료(ASOS·AWS)를 지역(엣지) 쿠버네티스의 작은 수집기로 1분마다 받아 지역 DB 와 허브 DB 에서 실내 센서와 같은 readings 테이블에 원본 값으로 넣고, 매시간 DB 마다 빈 분을 찾아 다시 받으며 기상청에도 없는 분은 7일 뒤 영구 결측으로 확정하는 방법을 정리했습니다.
author: Eu4ng
tags: [iot, weather, kma, timescaledb, postgresql, kubernetes, argo-cd, gitops]
permalink: /posts/52/
---

기상청 **API허브**의 지상관측 매분자료를 지역(엣지) 클러스터의 수집기 파드가 받아, 실내 센서 값이 쌓이는 지역 TimescaleDB 와 허브 TimescaleDB 의 `readings` 테이블에 바깥 날씨 행으로 넣습니다. 관측 지점 하나가 기기 하나처럼 `outdoor-weather-<지점 이름>` 으로 들어가므로 실내 온습도와 같은 쿼리·대시보드로 비교할 수 있습니다. 수집기는 1분마다 최근 15분을 한 번 받아 두 DB 에 넣고, 매시간 DB 마다 빈 분을 찾아 그 구간만 다시 받습니다. 그래서 인터넷이나 허브가 끊겼던 동안의 날씨도 닿는 대로 채워집니다. 처음 뜰 때는 그 지역 센서가 처음 기록된 시각까지 거슬러 올라가 채웁니다.

1. 인증키 발급과 활용신청
2. 관측 지점 고르기
3. 인증키 Secret 만들기
4. 수집기 매니페스트 추가
5. 배포와 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| 허브 Kubernetes | `v1.37` (kubeadm) |
| 엣지 Kubernetes | `v1.37` (kubeadm) |
| Argo CD | `v3.5.3` |
| timescale/timescaledb | `2.30.1-pg17` |
| 기상청 API허브 API | 지상관측 AWS 매분자료(`nph-aws2_min`) |
| 작성 기준일 | `2026-09-26` |

다음 항목이 준비되어 있어야 합니다.

- 두 DB 의 `readings` 테이블과 ApplicationSet `iot-edge` ([엣지 Mosquitto와 Telegraf 디스크 버퍼로 중앙 TimescaleDB에 유실 없이 IoT 데이터 모으는 방법](/posts/43/))
- 지역 TimescaleDB ([지역 엣지에 TimescaleDB와 Grafana를 두어 인터넷 없이도 기록하고 보는 방법](/posts/56/))
- `readings` 에 원본·가공 구분 컬럼 `processing` 이 있어야 합니다(같은 글의 테이블 정의)
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

## 3. 인증키 Secret 만들기

인증키와 DB 비밀번호는 GitOps 저장소에 넣지 않고 엣지 클러스터에 Secret `weather/weather-credentials` 로 미리 만듭니다. 스크립트가 인증키를 입력받아(환경 변수 `KMA_AUTH_KEY` 가 있으면 그 값) 매분자료를 한 번 받아 본 뒤 Secret 을 만들고, DB 비밀번호는 허브와 지역의 TimescaleDB Secret 에서 복사합니다.

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
# 수집기는 지역마다 엣지에서 돌며 지역 DB 와 허브 DB 에 함께 넣습니다.
# 허브에 kubectl 로 접근할 수 있고 엣지 kubeconfig 가 있는 곳(control plane)에서 실행합니다: bash create-weather-secret.sh [EDGE_KUBECONFIG]
# 인증키는 환경 변수 KMA_AUTH_KEY 가 있으면 그것을, 없으면 실행 중에 입력받습니다(값을 표준입력으로 넘겨도 됩니다).
# DB 비밀번호는 허브·지역의 timescaledb/timescaledb-credentials 에서 복사합니다. 이미 있으면 건너뜁니다(바꾸려면 Secret 을 지우고 다시 실행).

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
NAMESPACE=weather                  # iot/clusters/<지역>/weather 폴더 이름 = 네임스페이스
DB_SECRET=timescaledb/timescaledb-credentials   # POSTGRES_PASSWORD 를 가진 Secret (<네임스페이스>/<이름>, 허브·지역 같은 이름)
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
if kubectl "${EDGE[@]}" -n "$NAMESPACE" get secret weather-credentials >/dev/null 2>&1; then
  echo "  엣지 $NAMESPACE/weather-credentials 있음, 건너뜀"; exit 0
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
printf 'KMA_AUTH_KEY=%s\nPGPASSWORD_LOCAL=%s\nPGPASSWORD_HUB=%s\n' "$KMA_AUTH_KEY" "$PG_LOCAL" "$PG_HUB" \
  | kubectl "${EDGE[@]}" -n "$NAMESPACE" create secret generic weather-credentials --from-env-file=/dev/stdin

unset KMA_AUTH_KEY PG_HUB PG_LOCAL
log "완료"
```
{: file="create-weather-secret.sh" }

</details>

```bash
# 인증키를 입력받아 엣지에 Secret 생성 (이미 있으면 건너뜀)
bash create-weather-secret.sh k8s-[SITE].yaml
```

- **확인:** `kubectl --kubeconfig k8s-[SITE].yaml -n weather get secret weather-credentials` 에 키 3개(`KMA_AUTH_KEY`, `PGPASSWORD_LOCAL`, `PGPASSWORD_HUB`)를 가진 Secret 이 보입니다. 인증키가 틀렸거나 활용신청이 안 되어 있으면 `API 응답이 올바르지 않습니다` 로 멈춥니다.

## 4. 수집기 매니페스트 추가

GitOps 저장소에 엣지 공통 베이스 `iot/edge/weather/` 와 지역 오버레이 `iot/clusters/daejeon/weather/` 를 만듭니다. 오버레이 폴더가 `daejeon-weather` Application 이 되어 엣지 클러스터의 `weather` 네임스페이스에 배포됩니다. 수집기는 셸 스크립트 하나이고, 이미지는 `timescale/timescaledb` 를 씁니다. 이 이미지에 `psql` 과 HTTPS 를 받을 수 있는 `wget` 이 들어 있어 따로 이미지를 만들 필요가 없습니다.

```yaml
# 바깥 날씨. 기상청 API허브 지상관측 매분자료를 1분마다 받아 지역 DB 와 허브 DB 의 readings 에 room=outdoor, device=weather, processing=raw 로 넣고,
# 매시간 DB 마다 빈 분을 백필합니다. 지역마다 자기 지점을 받으므로 인터넷이 끊기면 그동안의 날씨는 인터넷이 돌아온 뒤 백필로 채워집니다.
# 인증키와 DB 비밀번호는 Secret weather-credentials 로 GitOps 밖에서 만듭니다 (create-weather-secret.sh).
resources:
  - deployment.yaml
configMapGenerator:
  - name: weather-collect
    files:
      - collect.sh
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
    type: Recreate           # 두 파드가 같은 구간을 함께 받으면 행이 겹칩니다
  selector:
    matchLabels: { app: weather }
  template:
    metadata:
      labels: { app: weather }
    spec:
      securityContext:
        runAsUser: 70        # 이미지의 postgres 계정
        runAsNonRoot: true
      containers:
        - name: collect
          image: timescale/timescaledb:2.30.1-pg17   # psql 과 HTTPS 되는 wget 이 들어 있습니다
          command: ["sh", "/scripts/collect.sh"]
          envFrom:
            # KMA_AUTH_KEY(기상청 API허브 인증키), PGPASSWORD_LOCAL·PGPASSWORD_HUB(DB 계정 iot). GitOps 밖에서 만듭니다 (create-weather-secret.sh)
            - secretRef: { name: weather-credentials }
          env:
            # 지역 오버레이(iot/clusters/<지역>/weather/)가 STATIONS 와 DB_HUB 를 patch 로 넣습니다.
            # STATIONS: <지역>:<지점번호>:<model>:<anchor>, 여러 개는 공백으로. anchor(기준) 는 지점 이름(영문)입니다
            - { name: STATIONS, value: "" }
            - { name: DB_LOCAL, value: "timescaledb.timescaledb.svc.cluster.local:5432" }   # 지역 DB(iot/edge/timescaledb)
            - { name: DB_HUB, value: "" }                                                  # 허브 DB. 비우면 지역 DB 에만 넣습니다
            - { name: MISSING_FINAL_DAYS, value: "7" }   # 기상청도 값이 없는 분이 이 일수가 지나도 비어 있으면 영구 결측으로 보고 더 요청하지 않습니다
            - { name: BACKFILL_DAYS, value: "8" }        # 매시간 빈 분을 찾는 범위. 확정 기간보다 길게 둡니다(시작 직후 한 번은 센서 첫 기록부터 전체)
            - { name: PGUSER, value: iot }
            - { name: PGDATABASE, value: iot }
          volumeMounts:
            - { name: scripts, mountPath: /scripts }
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { cpu: 200m, memory: 128Mi }
      volumes:
        - name: scripts
          configMap: { name: weather-collect }
```
{: file="iot/edge/weather/deployment.yaml" }

지점과 허브 DB 주소는 지역 오버레이가 넣습니다. 지역 DB 는 같은 클러스터의 Service 이름이라 베이스에 적어 두었고, `DB_HUB` 를 비우면 지역 DB 에만 넣습니다.

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

지점은 env `STATIONS` 에 `<지역>:<지점번호>:<model>:<anchor>` 로 적습니다. 다른 지역을 추가하면 그 지역의 오버레이에 그 지역 지점을 적고, 수집기는 그 지역 센서가 처음 기록된 시각부터 채웁니다.

<details markdown="1">
<summary>collect.sh 전문</summary>

```bash
#!/bin/sh
# 기상청 API허브 지상관측 매분자료(ASOS·AWS 지점 모두)를 받아 지역 DB 와 허브 DB 의 readings 에 원본(processing=raw)으로 넣습니다.
#   실시간: 1분마다 지점별 최근 LIVE_MINUTES 분을 한 번 받아 모든 DB 에 넣습니다. 늦게 올라온 분도 이 안이면 다음 주기에 들어옵니다.
#   백필:   DB 마다 따로, 시작 직후 한 번은 그 지역 센서의 첫 기록부터, 이후 BACKFILL_EVERY 분마다 최근 BACKFILL_DAYS 일에서 빈 분을 찾아
#           그 구간만 다시 받아 그 DB 에 넣습니다. 허브가 끊겼던 동안 빠진 분도 이렇게 채워집니다(기상청이 값을 가진 동안).
#   결측:   기상청도 값이 없다고 답한 분은 그 DB 의 weather_missing 에 남기고, 그 분이 MISSING_FINAL_DAYS 일 지나도 비어 있으면 영구 결측으로 보고 더 요청하지 않습니다.
# 이미 있는 행은 넣지 않으므로 같은 구간을 여러 번 받아도 겹치지 않습니다. 한 DB 가 안 닿아도 다른 DB 는 계속 받습니다.
# env: STATIONS("<지역>:<지점번호>:<model>:<anchor> …"), KMA_AUTH_KEY, DB_LOCAL·DB_HUB("<호스트>:<포트>", 비우면 그 DB 는 안 씀),
#      PGPASSWORD_LOCAL·PGPASSWORD_HUB, PGUSER, PGDATABASE
set -u
API=https://apihub.kma.go.kr/api/typ01/cgi-bin/url/nph-aws2_min
LIVE_MINUTES=${LIVE_MINUTES:-15}
BACKFILL_EVERY=${BACKFILL_EVERY:-60}
BACKFILL_DAYS=${BACKFILL_DAYS:-8}
BACKFILL_MAX_CALLS=${BACKFILL_MAX_CALLS:-50}   # 한 번의 백필에서 지점별 요청 수 상한. 긴 구간은 요청 하나가 수십 초 걸립니다
MISSING_FINAL_DAYS=${MISSING_FINAL_DAYS:-7}
ROWS=/tmp/weather-rows.csv
DBS=""
[ -n "${DB_LOCAL:-}" ] && DBS="$DBS local"
[ -n "${DB_HUB:-}" ] && DBS="$DBS hub"

log() { echo "$(date -u +%FT%TZ) $*"; }
sql() { psql -X -q -t -A -F ' ' -v ON_ERROR_STOP=1 "$@"; }

# use_db <local|hub>: psql 이 붙을 DB 를 고릅니다
use_db() {
  case $1 in
    local) addr=$DB_LOCAL; PGPASSWORD=${PGPASSWORD_LOCAL:-} ;;
    hub)   addr=$DB_HUB;   PGPASSWORD=${PGPASSWORD_HUB:-} ;;
  esac
  PGHOST=${addr%:*} PGPORT=${addr##*:}
  export PGHOST PGPORT PGPASSWORD
}

# prepare <db>: 결측 기록 테이블을 만듭니다. 한 번 성공한 DB 는 다시 하지 않습니다(DB 가 처음부터 안 닿아도 닿을 때 만듭니다)
READY=""
prepare() {
  case " $READY " in *" $1 "*) return 0 ;; esac
  use_db "$1"
  sql <<'SQL' || { log "$1: weather_missing 테이블을 만들지 못했습니다"; return 1; }
SET client_min_messages = warning;   -- 이미 있을 때의 NOTICE 를 로그에 남기지 않습니다
CREATE TABLE IF NOT EXISTS weather_missing (
  site text NOT NULL, hw_id text NOT NULL, time timestamptz NOT NULL,   -- 기상청도 값이 없다고 답한 분(지점 번호 hw_id)
  checked_at timestamptz NOT NULL,                                       -- 마지막으로 다시 받아 본 시각. time 에서 MISSING_FINAL_DAYS 일 지나면 확정
  PRIMARY KEY (site, hw_id, time)
);
SQL
  READY="$READY $1"
}

# fetch <지역> <지점> <model> <anchor> <tm1> <tm2> <DB…>  (KST YYYYMMDDHHMI, 최대 6시간): 한 번 받아 주어진 DB 들에 넣습니다
fetch() {
  site=$1 stn=$2 model=$3 anchor=$4 tm1=$5 tm2=$6; shift 6
  body=$(wget -q -T 60 -O- "$API?tm1=$tm1&tm2=$tm2&stn=$stn&disp=1&help=0&authKey=$KMA_AUTH_KEY") || { log "$site:$stn $tm1~$tm2 요청 실패"; return 1; }
  case $body in '#START7777'*) ;; *) log "$site:$stn 응답 오류: $(echo "$body" | head -c 200)"; return 1 ;; esac

  # 한 줄(한 분)에서 필요한 열만 골라 행 여러 개로 나눕니다. -50 이하는 결측이라 버립니다. 표준 출력에는 응답에 있던 분의 수를 냅니다
  # 열: 1 시각, 2 지점, 3 WD1, 4 WS1, 6 WSS, 9 TA, 12 RN-60m, 14 RN-DAY, 15 HM, 16 PA, 18 TD
  lines=$(echo "$body" | awk -F, -v site="$site" -v stn="$stn" -v model="$model" -v anchor="$anchor" -v out="$ROWS" '
    BEGIN {
      n = split("9 15 16 18 3 4 6 12 14", col, " ")
      split("temperature humidity pressure dew_point wind_direction wind_speed wind_gust_speed precipitation_1h precipitation_day", prop, " ")
      split("°C % hPa °C ° m/s m/s mm mm", unit, " ")
      printf "" > out
    }
    /^#/ || $2 != stn { next }
    {
      lines++
      t = sprintf("%s-%s-%s %s:%s:00+09", substr($1,1,4), substr($1,5,2), substr($1,7,2), substr($1,9,2), substr($1,11,2))
      for (i = 1; i <= n; i++) {
        v = $(col[i]) + 0
        if (v > -50) printf "%s,%s,outdoor,weather,%s,%s,raw,%s,%s,http,kma,KMA,%s,%s\n", t, site, anchor, prop[i], v, unit[i], model, stn > out
      }
    }
    END { print lines + 0 }')
  for db in "$@"; do store "$db"; done
}

# store <db>: 받은 행을 한 DB 에 넣습니다(fetch 가 부름. site·stn·tm1·tm2·lines 를 이어받음)
store() {
  prepare "$1" || return 1
  use_db "$1"
  # 한 트랜잭션: 없는 행만 넣고, 값이 들어온 분은 결측 기록에서 지우고, 응답에 줄이 있었는데 값이 없는 분은 결측으로 남깁니다.
  # 줄이 하나도 없는 응답은 API 일시 오류일 수 있어 결측으로 남기지 않습니다. 아직 올라오지 않았을 최근 LIVE_MINUTES 분도 남기지 않습니다.
  result=$(sql -v site="$site" -v stn="$stn" -v tm1="$tm1" -v tm2="$tm2" -v lines="$lines" -v live="$LIVE_MINUTES" <<'SQL'
SET TIME ZONE 'Asia/Seoul';
BEGIN;
CREATE TEMP TABLE t (LIKE readings) ON COMMIT DROP;
\copy t (time, site, room, device, anchor, property, processing, value, unit, protocol, source, vendor, model, hw_id) from '/tmp/weather-rows.csv' with (format csv)
WITH ins AS (
  INSERT INTO readings SELECT t.* FROM t
  WHERE NOT EXISTS (SELECT 1 FROM readings r WHERE r.time = t.time AND r.site = t.site AND r.source = 'kma' AND r.hw_id = t.hw_id
                      AND r.property = t.property AND r.processing = 'raw')
  RETURNING time
) SELECT count(DISTINCT time), count(*) FROM ins;
DELETE FROM weather_missing WHERE site = :'site' AND hw_id = :'stn' AND time IN (SELECT time FROM t);
WITH miss AS (
  INSERT INTO weather_missing (site, hw_id, time, checked_at)
  SELECT :'site', :'stn', m, now()
  FROM generate_series(to_timestamp(:'tm1', 'YYYYMMDDHH24MI'), to_timestamp(:'tm2', 'YYYYMMDDHH24MI'), interval '1 minute') m
  WHERE :lines > 0 AND m < now() - make_interval(mins => :live)
    AND NOT EXISTS (SELECT 1 FROM t WHERE t.time = m)
    AND NOT EXISTS (SELECT 1 FROM readings r WHERE r.time = m AND r.site = :'site' AND r.source = 'kma' AND r.hw_id = :'stn')
  ON CONFLICT (site, hw_id, time) DO UPDATE SET checked_at = excluded.checked_at
  RETURNING 1
) SELECT count(*) FROM miss;
COMMIT;
SQL
  ) || { log "$1: $site:$stn $tm1~$tm2 DB 쓰기 실패"; return 1; }
  set -- "$1" $result   # DB, 넣은 분 수, 넣은 행 수, 결측으로 남긴 분 수
  [ "$3" -eq 0 ] && [ "$4" -eq 0 ] || log "$1: $site:$stn $tm1~$tm2 ${2}분 ${3}행 넣음, 결측 ${4}분"
}

# gaps <db> <지역> <지점> <검사 일수>: 그 DB 에서 백필할 구간을 한 줄에 하나씩(KST tm1 tm2, 6시간 이하) 냅니다.
# 대상은 그 지역 센서의 첫 기록(분 내림)부터 최근 LIVE_MINUTES 분 전까지 가운데, 날씨 행이 없고 결측 기록으로도 쉬지 않는 분입니다.
# 결측 기록은 확정(MISSING_FINAL_DAYS 일 뒤에도 비어 있음)이면 영원히, 아니면 재확인 간격(하루 안의 분은 약 1시간, 그 뒤는 약 하루) 동안 쉽니다.
gaps() {
  prepare "$1" || return 1
  use_db "$1"
  sql -v site="$2" -v stn="$3" -v days="$4" -v live="$LIVE_MINUTES" -v final="$MISSING_FINAL_DAYS" -v max="$BACKFILL_MAX_CALLS" <<'SQL'
SET TIME ZONE 'Asia/Seoul';
WITH bounds AS (
  SELECT greatest(date_trunc('minute', min(time)), date_trunc('minute', now()) - make_interval(days => :days)) AS s
  FROM readings WHERE site = :'site' AND source <> 'kma'
  HAVING min(time) IS NOT NULL   -- 그 지역 센서 기록이 아직 없으면 받지 않습니다(greatest 는 NULL 을 무시해 먼 과거부터 받게 됩니다)
), todo AS (
  SELECT m FROM bounds, generate_series(s, date_trunc('minute', now()) - make_interval(mins => :live), interval '1 minute') m
  WHERE NOT EXISTS (SELECT 1 FROM readings r WHERE r.time = m AND r.site = :'site' AND r.source = 'kma' AND r.hw_id = :'stn')
    AND NOT EXISTS (SELECT 1 FROM weather_missing w WHERE w.site = :'site' AND w.hw_id = :'stn' AND w.time = m
                      AND (w.checked_at - w.time >= make_interval(days => :final)
                           OR w.checked_at > now() - CASE WHEN now() - w.time < interval '1 day' THEN interval '50 minutes' ELSE interval '23 hours' END))
), island AS (
  SELECT min(m) a, max(m) b FROM (SELECT m, m - (row_number() OVER (ORDER BY m)) * interval '1 minute' g FROM todo) x GROUP BY g
)
SELECT to_char(c, 'YYYYMMDDHH24MI'), to_char(least(c + interval '6 hours' - interval '1 minute', b), 'YYYYMMDDHH24MI')
FROM island, generate_series(a, b, interval '6 hours') c
ORDER BY c LIMIT :max;
SQL
}

backfill() {
  days=$1
  for db in $DBS; do
    for s in $STATIONS; do
      IFS=: read -r site stn model anchor <<EOS
$s
EOS
      ranges=$(gaps "$db" "$site" "$stn" "$days") || { log "$db: $site:$stn 빈 구간 조회 실패"; continue; }
      [ -n "$ranges" ] || continue
      log "$db: $site:$stn 백필 $(echo "$ranges" | wc -l)구간"
      echo "$ranges" | while read -r tm1 tm2; do fetch "$site" "$stn" "$model" "$anchor" "$tm1" "$tm2" "$db"; done
    done
  done
}

[ -n "$DBS" ] || { log "DB_LOCAL, DB_HUB 가 모두 비어 있습니다"; exit 1; }
log "대상 DB:$DBS, 지점: $STATIONS"
trap 'exit 0' TERM
backfill 36500   # 시작 직후: 센서 첫 기록부터 전체
next=$(( $(date +%s) + BACKFILL_EVERY * 60 ))
while :; do
  # 최근 LIVE_MINUTES 분(KST, 분 단위). DB 가 안 닿아도 받을 수 있게 셸에서 계산합니다
  now=$(( $(date +%s) / 60 * 60 ))
  tm1=$(TZ=Asia/Seoul date -d "@$(( now - LIVE_MINUTES * 60 ))" +%Y%m%d%H%M)
  tm2=$(TZ=Asia/Seoul date -d "@$(( now - 60 ))" +%Y%m%d%H%M)
  for s in $STATIONS; do
    IFS=: read -r site stn model anchor <<EOS
$s
EOS
    fetch "$site" "$stn" "$model" "$anchor" "$tm1" "$tm2" $DBS
  done
  if [ "$(date +%s)" -ge "$next" ]; then
    backfill "$BACKFILL_DAYS"
    next=$(( $(date +%s) + BACKFILL_EVERY * 60 ))
  fi
  sleep 60 & wait $!
done
```
{: file="iot/edge/weather/collect.sh" }

</details>

스크립트가 기상청 API 의 동작에 맞춰 처리하는 부분은 다음과 같습니다.

- **아직 안 올라온 분:** 반영까지 1~3분 걸리고, 그 전에는 모든 값이 `-99.9` 인 줄로 옵니다. `-50` 이하 값은 버리므로 행이 생기지 않고, 다음 주기에 다시 받습니다.
- **중복:** 넣기 전에 같은 지점·시각·항목의 원본 행이 있는지 보고 없는 행만 넣습니다. 같은 구간을 여러 번 받아도 겹치지 않습니다.
- **두 DB:** 실시간 구간은 한 번 받아 지역 DB 와 허브 DB 에 차례로 넣습니다. 조회 구간을 DB 가 아니라 셸에서 계산하므로 DB 가 안 닿아도 받고, 한 DB 에 쓰지 못해도 다른 DB 에는 넣습니다.
- **긴 구간:** 한 번에 최대 24시간까지 받을 수 있지만, 긴 구간은 응답이 수십 초씩 걸려 6시간씩 끊어 받습니다.
- **빈 분 백필:** 매시간 DB 마다 최근 8일에서 원본 행이 없는 분을 찾아 연속 구간으로 묶어 다시 받고 그 DB 에만 넣습니다. 허브가 끊겼던 동안 허브 DB 에 빠진 분도 이렇게 채워집니다.
- **영구 결측:** 응답에 줄은 있는데 값이 없는 분은 그 DB 의 `weather_missing` 테이블에 남깁니다. 하루 안의 분은 약 1시간마다, 그 뒤로는 약 하루마다 다시 확인하고, 7일이 지나도 비어 있으면 영구 결측으로 보고 더 요청하지 않습니다. 줄이 하나도 없는 응답은 API 일시 오류일 수 있어 결측으로 남기지 않습니다.

```bash
# 커밋하고 push
git add iot/edge/weather iot/clusters/daejeon/weather
git commit -m "feat(iot): 기상청 1분 자료를 readings 에 넣는 바깥 날씨 수집기 추가"
git push
```

- **확인:** 이 단계는 push 까지입니다. 배포는 다음 단계에서 확인합니다.

## 5. 배포와 확인

Argo CD 가 저장소를 다시 읽으면(최대 3분) `daejeon-weather` Application 이 생기고 엣지에 파드가 뜹니다. 파드는 시작하자마자 DB 마다 그 지역 센서의 첫 기록부터 지금까지 빈 분을 채운 뒤 1분 주기로 돕니다.

```bash
# 허브 control plane: 수집기 로그
E="--kubeconfig k8s-[SITE].yaml"
kubectl $E -n weather logs deploy/weather
```

```text
2026-09-27T14:18:07Z 대상 DB: local hub, 지점: daejeon:133:ASOS:daejeon daejeon:648:AWS:jangdong
2026-09-27T14:18:08Z local: daejeon:133 202609272303~202609272317 7분 63행 넣음, 결측 0분
2026-09-27T14:18:08Z hub: daejeon:133 202609272303~202609272317 2분 18행 넣음, 결측 0분
...
2026-09-27T15:05:08Z local: daejeon:648 202609272349~202609280003 1분 9행 넣음, 결측 0분
2026-09-27T15:05:08Z hub: daejeon:648 202609272349~202609280003 1분 9행 넣음, 결측 0분
```

```bash
# 지점별 적재 범위와 중복: 지역 DB, 허브 DB 순서 (주 DB 파드는 Patroni 가 role=primary 라벨을 붙임)
Q1="select anchor, hw_id, count(distinct time) minutes, min(time) at time zone 'Asia/Seoul' first_kst, max(time) at time zone 'Asia/Seoul' last_kst
    from readings where source = 'kma' group by 1, 2;"
Q2="select count(*) dup from (select time, hw_id, property from readings where source = 'kma' group by 1, 2, 3 having count(*) > 1) d;"
kubectl $E -n timescaledb exec $(kubectl $E -n timescaledb get pod -l role=primary -o name) -- psql -U iot -d iot -c "$Q1" -c "$Q2"
kubectl -n timescaledb exec $(kubectl -n timescaledb get pod -l role=primary -o name) -- psql -U iot -d iot -c "$Q1" -c "$Q2"
```

- **확인:** Application `daejeon-weather` 가 `Synced`, `Healthy` 입니다. 로그에 `local:`, `hub:` 로 DB 마다 백필 구간과 1분마다 `1분 9행 넣음` 이 찍힙니다. 기상청이 가끔 `504 Gateway Timeout` 으로 답하면 `요청 실패` 가 찍히고, 그 분은 다음 주기의 최근 15분 안에서 다시 받습니다. 두 DB 의 조회에 두 지점이 보이고, `first_kst` 가 그 지역 센서의 첫 기록 분, `last_kst` 가 지금보다 1~3분 전이며, `dup` 은 0 입니다. 허브 Grafana 와 지역 Grafana 의 **IoT 기록** 대시보드에서는 **temperature**·**humidity** 패널에 `room` 이 `outdoor` 인 두 지점(`daejeon`, `jangdong`)의 시리즈가 실내 센서와 함께 그려집니다.

## 마무리

기상청 API허브 매분자료를 받아 지역 TimescaleDB 와 허브 TimescaleDB 의 `readings` 에 바깥 날씨 원본 행으로 넣는 수집기를 지역 엣지에 GitOps 로 배포했습니다. 1분마다 최근 15분을 받고, 매시간 DB 마다 빈 분을 백필하며, 기상청에도 없는 분은 7일 뒤 영구 결측으로 확정해 같은 구간을 끝없이 다시 요청하지 않습니다. 지점을 바꿀 때는 지역 오버레이의 `STATIONS` 한 줄만 고치고, 다른 지역을 추가할 때는 그 지역의 오버레이를 만들고 Secret 스크립트를 그 엣지에 실행합니다.

## 참고 자료

- [기상청 API허브 - 이용안내](https://apihub.kma.go.kr/apiInfo.do)
- [기상청 API허브 - 지상관측 AWS 매분자료](https://apihub.kma.go.kr/apiList.do?seqApi=2&seqApiSub=239)
- [PostgreSQL - psql (\\copy, 변수 치환)](https://www.postgresql.org/docs/17/app-psql.html)
- [PostgreSQL - INSERT (ON CONFLICT)](https://www.postgresql.org/docs/17/sql-insert.html)
- [TimescaleDB - Hypertables](https://docs.timescale.com/use-timescale/latest/hypertables/)
