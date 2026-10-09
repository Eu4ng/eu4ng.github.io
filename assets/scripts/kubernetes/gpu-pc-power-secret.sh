#!/usr/bin/env bash
#
# GPU 데스크톱 전원 컨트롤러(services/ollama/power.py)의 토큰 둘을 만들어 필요한 곳에 넣습니다. 여러 번 실행해도 됩니다.
#   - control-token: 컨트롤러 → PC 에이전트(windows-agent.ps1 -AutoPower, 제어 포트 /auto·/release·/hint)
#   - demand-token : 클라이언트 → 컨트롤러(수요 신고 :9112 /demand, 워크플로 자리 임대 /reserve·/lease)
# 넣는 곳:
#   - 원본 ~/.config/gpu-pc-power/tokens.env (없으면 무작위로 만들어 적음)
#   - 쿠버네티스 Secret ollama/gpu-pc-power (키 control-token, demand-token)
#   - PC 의 C:\ProgramData\<에이전트 작업 이름>\token (SYSTEM·Administrators 만 읽기, ssh 가 될 때만)
# 토큰을 바꾸려면 tokens.env 에서 그 줄을 지우고 다시 실행합니다(PC 에이전트는 시작할 때 토큰을 읽으므로 예약 작업을 다시 시작합니다).
#
# 사용법: bash gpu-pc-power-secret.sh   (kubectl 이 되는 PC 에서. PC 는 OpenSSH, 기본 셸 PowerShell)

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
KUBECTL=(kubectl)                    # 원격이면 예: (ssh [CONTROL_PLANE] kubectl)
PC=[PC_USER]@[GPUPC_IP]              # GPU 데스크톱(OpenSSH, 관리자 계정)
AGENT_TASK=ollama-agent              # windows-agent.ps1 -TaskName
# --------------------------------------

ENV_FILE=$HOME/.config/gpu-pc-power/tokens.env
log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR
umask 077
mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"

# ---------- 1. 토큰 ----------
log "토큰 ($ENV_FILE)"
for key in GPU_PC_CONTROL_TOKEN GPU_PC_DEMAND_TOKEN; do
  if ! grep -q "^$key=" "$ENV_FILE"; then
    echo "$key=$(python3 -c 'import secrets; print(secrets.token_hex(32))')" >> "$ENV_FILE"; echo "    $key: 만듦"
  else echo "    $key: 있음"; fi
done
CONTROL=$(. "$ENV_FILE"; echo "$GPU_PC_CONTROL_TOKEN")
DEMAND=$(. "$ENV_FILE"; echo "$GPU_PC_DEMAND_TOKEN")
[ -n "$CONTROL" ] && [ -n "$DEMAND" ] || die "토큰이 비어 있습니다"

# ---------- 2. 쿠버네티스 Secret ----------
log "Secret ollama/gpu-pc-power"
# 값이 인자·기록에 남지 않게 매니페스트를 stdin 으로 넘긴다(토큰은 hex 라 따옴표가 필요 없다)
printf 'apiVersion: v1\nkind: Secret\nmetadata: {name: gpu-pc-power, namespace: ollama}\ntype: Opaque\nstringData:\n  control-token: "%s"\n  demand-token: "%s"\n' \
  "$CONTROL" "$DEMAND" | "${KUBECTL[@]}" apply -f -

# ---------- 3. PC 의 에이전트 토큰 ----------
log "PC 의 에이전트 토큰 ($PC)"
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$PC" 'exit 0' 2>/dev/null; then
  # 기본 셸이 PowerShell 이다. 토큰은 stdin 으로 넘기고, 파일은 SYSTEM·Administrators 만 읽게 한다
  printf '%s' "$CONTROL" | ssh "$PC" "\$d='C:\\ProgramData\\$AGENT_TASK'; New-Item -ItemType Directory -Force -Path \$d | Out-Null; \$f=Join-Path \$d 'token'; [Console]::In.ReadToEnd() | Set-Content -NoNewline -Encoding ASCII -Path \$f; icacls \$f /inheritance:r /grant 'SYSTEM:F' /grant 'Administrators:F' | Out-Null; Stop-ScheduledTask -TaskName $AGENT_TASK -ErrorAction SilentlyContinue; Start-ScheduledTask -TaskName $AGENT_TASK -ErrorAction SilentlyContinue; 'ok'"
else
  echo "    PC 에 ssh 가 되지 않아 건너뜁니다(PC 가 켜진 뒤 다시 실행)"
fi
echo "끝. 수요를 신고할 클라이언트에는 GPU_PC_DEMAND_TOKEN 을 넘깁니다."
