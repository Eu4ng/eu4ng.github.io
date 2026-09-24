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
