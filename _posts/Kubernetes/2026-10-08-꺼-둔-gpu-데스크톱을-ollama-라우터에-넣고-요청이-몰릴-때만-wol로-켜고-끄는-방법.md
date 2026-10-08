---
layout: post
title: 꺼 둔 GPU 데스크톱을 Ollama 라우터에 넣고 요청이 몰릴 때만 WOL로 켜고 끄는 방법
description: 유휴 전력이 큰 GPU 데스크톱을 Ollama 라우터의 서버로 넣되 평소에는 꺼 두고, 보통 모델 요청이 동시에 몰릴 때만 쿠버네티스의 전원 컨트롤러가 Wake-on-LAN 으로 켜고, 수요가 줄면 PC 가 스스로 꺼지게 만드는 방법을 정리했습니다.
author: Eu4ng
tags: [ollama, haproxy, kubernetes, wake-on-lan, windows, gitops]
permalink: /posts/86/
---

[Proxmox LXC에 Ollama 서버를 두고 쿠버네티스에서 실측 속도로 나눠 쓰는 방법](/posts/37/)의 라우터에 GPU 가 좋은 Windows 데스크톱을 서버로 더합니다. 데스크톱은 켜 두기만 해도 100W 넘게 쓰므로 평소에는 꺼 두고, 클러스터의 전원 컨트롤러가 라우터 통계와 클라이언트의 신고를 보고 보통 모델 요청이 동시에 2건 이상 60초 이어질 때만 Wake-on-LAN(WOL)으로 켭니다. 요청이 1건 이하로 5분 이어지면 컨트롤러가 PC 의 상태 에이전트에 내려도 된다고 알리고, 에이전트는 처리 중인 일이 끝나고 아무도 PC 를 쓰지 않을 때만 스스로 종료합니다. 사람이 쓴 흔적(콘솔 입력, 원격 데스크톱 세션)이 있는 부팅은 끄지 않습니다.

1. PC 준비
2. 상태 에이전트 설치
3. 토큰 만들기
4. 라우터와 전원 컨트롤러 매니페스트 추가
5. 동작 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| PC | Windows 11 Pro, NVIDIA GPU(VRAM 16GB) |
| Ollama | `0.35.1` |
| 라우터 | HAProxy `3.2` ([Ollama 라우터 글](/posts/37/)) |
| 쿠버네티스 | kubeadm, flannel, Argo CD |
| 작성 기준일 | `2026-10-08` |

다음 항목이 준비되어 있어야 합니다.

- [Ollama 라우터 글](/posts/37/)의 `services/ollama/` 매니페스트와 동작하는 라우터
- 메인보드와 NIC 에서 Wake-on-LAN 이 켜진 PC(전원 차단 상태에서 켜지는지 미리 확인)
- 쿠버네티스 노드와 PC 가 같은 LAN(같은 브로드캐스트 영역)에 있어야 합니다. 매직 패킷은 라우터를 넘지 않습니다.

## 1. PC 준비

WOL 로 켜진 PC 는 로그인 화면에 머물러 있으므로, Ollama 를 로그인 없이 도는 서버로 바꿉니다. Windows 용 Ollama 는 기본으로 로그인할 때 트레이 앱이 서버를 띄웁니다. 아래를 PC 의 관리자 PowerShell 에서 실행합니다.

```powershell
# 1) 원격 관리용 OpenSSH 서버와 빠른 시작 끄기(빠른 시작이 켜져 있으면 완전 종료 상태에서 WOL 이 막히는 경우가 많습니다)
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic; Start-Service sshd
New-NetFirewallRule -DisplayName sshd-lan -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress LocalSubnet -Action Allow
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -PropertyType String -Force
powercfg /h off

# 2) Ollama 서버를 시스템 범위 설정으로, 부팅 때 SYSTEM 계정으로 띄우기
$exe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
$vars = @{ OLLAMA_HOST = '0.0.0.0:11434'; OLLAMA_MODELS = 'D:\ollama\models'; OLLAMA_KEEP_ALIVE = '30m';
           OLLAMA_MAX_LOADED_MODELS = '1'; OLLAMA_NUM_PARALLEL = '2'; OLLAMA_FLASH_ATTENTION = '1' }
foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $vars[$k], 'Machine') }
New-Item -ItemType Directory -Force -Path D:\ollama\models | Out-Null
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName ollama-serve -Action (New-ScheduledTaskAction -Execute $exe -Argument serve) `
  -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal (New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest) -Settings $settings -Force
New-NetFirewallRule -DisplayName ollama-lan -Direction Inbound -Protocol TCP -LocalPort 11434 -RemoteAddress LocalSubnet -Action Allow

# 3) 트레이 앱의 로그인 자동 시작 끄기(로그인할 때 서버가 하나 더 떠 11434 를 다투지 않게)
Move-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk" $env:USERPROFILE -ErrorAction SilentlyContinue
Get-Process 'ollama app', ollama -ErrorAction SilentlyContinue | Stop-Process -Force
Start-ScheduledTask -TaskName ollama-serve
```

라우터로 보내는 모델을 이 서버에 받습니다. 이미 다른 서버에 있는 모델은 그 서버의 모델 폴더(`manifests/`, `blobs/`)를 그대로 복사해도 됩니다.

```bash
# 라우터가 보내는 모델 받기 (아무 PC 에서)
for m in gemma4:12b qwen3.5:9b; do curl -s http://[GPUPC_IP]:11434/api/pull -d "{\"model\":\"$m\",\"stream\":false}"; echo; done
```

`OLLAMA_NUM_PARALLEL` 은 VRAM 에 맞춥니다. 모델 가중치가 VRAM 을 넘으면 Ollama 는 실패하지 않고 남는 레이어를 CPU 로 돌리는데, 이때 생성 속도는 CPU 쪽이 정합니다. 16GB GPU 에서 30B 급 모델(17~20GB)은 생성이 iGPU 서버보다 느렸으므로 이 글에서는 PC 에 보통 모델만 보냅니다.

- **확인:** PC 를 재부팅하고 로그인하지 않은 채 다른 PC 에서 `curl http://[GPUPC_IP]:11434/api/version` 이 응답합니다. 로그인한 뒤에도 `Get-NetTCPConnection -LocalPort 11434 -State Listen` 의 프로세스가 하나뿐입니다.

## 2. 상태 에이전트 설치

PC 의 상태 에이전트 `windows-agent.ps1` 은 라우터의 `agent-check`(포트 11435)에 `ready`/`drain` 으로 답하고, `-AutoPower` 를 주면 전원 컨트롤러의 제어(포트 11438)를 받아 스스로 종료합니다. 끄는 조건은 아래가 모두 60초 이어질 때입니다.

- 컨트롤러가 켠 부팅(`/auto`)이고 컨트롤러가 내려도 된다고 알림(`/release`)
- 이 부팅에서 사람의 흔적이 없음: 원격 데스크톱 세션, 또는 부팅 뒤 콘솔의 키보드·마우스 입력
- 지금 들어와 있는 연결이 없음: SSH·SMB 같은 다른 포트의 연결, 11434 의 추론 연결
- 러너가 계산 중이 아님

비밀번호 없는 계정은 부팅할 때 Windows 가 자동으로 로그인하므로, 콘솔 세션이 있다는 것만으로는 사람이 있다고 보지 않습니다. 로그인 때 사용자 세션에서 도는 입력 보고 작업(`ollama-agent-input`)이 마지막 입력 시각을 적고, 부팅 뒤 2분이 지나서 들어온 입력이 있으면 사람이 있었다고 봅니다.

```powershell
# 에이전트 내려받아 설치 (관리자 PowerShell). -AllowFrom 에는 쿠버네티스 노드 주소를 모두 적습니다(컨트롤러가 hostNetwork 로 돕니다)
Invoke-WebRequest https://eu4ng.github.io/assets/files/ollama/windows-agent.ps1 -OutFile $env:TEMP\windows-agent.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\windows-agent.ps1 -Install -AutoPower -ControlPort 11438 -AllowFrom [NODE_IP_1],[NODE_IP_2],[NODE_IP_3]
```

- **확인:** `curl http://[GPUPC_IP]:11437/status` 의 JSON 에 `boot_id`, `user_seen`, `auto_boot` 가 보입니다. 지금 PC 앞에서 마우스를 움직였다면 `user_seen` 이 `true` 입니다.

## 3. 토큰 만들기

컨트롤러가 PC 에이전트를 제어할 때 쓰는 토큰과, 클라이언트가 컨트롤러에 수요를 신고할 때 쓰는 토큰을 만들어 쿠버네티스 Secret 과 PC 에 넣습니다. 비밀값이라 GitOps 저장소 밖에서 만듭니다.

```bash
# 내려받아 맨 위 변수를 고친 뒤 실행 (kubectl 이 되는 PC 에서)
curl -fsSLO https://eu4ng.github.io/assets/scripts/kubernetes/gpu-pc-power-secret.sh
bash gpu-pc-power-secret.sh
```

<details markdown="1">
<summary>gpu-pc-power-secret.sh 전문</summary>

```bash
#!/usr/bin/env bash
#
# GPU 데스크톱 전원 컨트롤러(services/ollama/power.py)의 토큰 둘을 만들어 필요한 곳에 넣습니다. 여러 번 실행해도 됩니다.
#   - control-token: 컨트롤러 → PC 에이전트(windows-agent.ps1 -AutoPower, 제어 포트 /auto·/release·/hint)
#   - demand-token : 클라이언트 → 컨트롤러(수요 신고 :9112 /demand)
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
```
{: file="gpu-pc-power-secret.sh" }

</details>

- **확인:** `kubectl -n ollama get secret gpu-pc-power` 가 보이고, 스크립트의 마지막 단계가 `ok` 를 출력합니다.

## 4. 라우터와 전원 컨트롤러 매니페스트 추가

라우터의 `backend servers` 에 PC 를 넣습니다. `OLLAMA_NUM_PARALLEL=2` 라 `maxconn 2` 이고, 꺼져 있는 동안은 헬스체크로 빠집니다. 추론 전에 `/api/tags` 로 모델을 확인하는 클라이언트가 있으면, 서버가 모두 바쁠 때 그 요청이 추론 자리를 기다리지 않게 모델 확인 요청을 `backend meta` 로 따로 보냅니다. 두 부분은 [라우터 글](/posts/37/)의 `haproxy.cfg` 에 이미 들어 있으니 `[GPUPC_IP]` 만 바꿉니다.

```text
  server pc-custom [GPUPC_IP]:11434 maxconn 2 agent-check agent-port 11435 agent-inter 5s
```
{: file="services/ollama/haproxy.cfg" }

전원 컨트롤러 `power.py` 는 10초마다 라우터 파드 전부(롤링 업데이트 중 종료되는 파드 포함)의 통계를 합쳐 보통 모델의 동시 요청(처리 중 + 대기)을 셉니다. 2건 이상이 60초 이어지면 매직 패킷을 보내고(쿨다운 10분), 그 뒤 켜진 부팅을 에이전트에 `/auto` 로 확정합니다. 1건 이하가 5분 이어지면 `/release` 를 보냅니다. 매직 패킷은 LAN 브로드캐스트라 파드 네트워크에서는 나가지 않으므로 `hostNetwork` 로 돌립니다.

```bash
# 전원 컨트롤러 내려받기
curl -fsSL https://eu4ng.github.io/assets/files/ollama/power.py -o services/ollama/power.py
curl -fsSL https://eu4ng.github.io/assets/files/ollama/power-deployment.yaml -o services/ollama/power-deployment.yaml
```

`power-deployment.yaml` 의 `[GPUPC_IP]`, `[GPUPC_MAC]`, `[LAN_BROADCAST]`(예: `192.168.1.255`)와 `[ROUTER_MODELS]`(라우터로 보내는 모델 목록)를 바꿉니다. `--models` 와 `--meta-servers` 는 모델 확인 서버(`backend meta`)가 모든 모델을 가졌는지 1분마다 검사해 지표 `ollama_meta_missing_models` 로 내는 데 씁니다.

<details markdown="1">
<summary>services/ollama/power-deployment.yaml 전문</summary>

```yaml
# GPU 데스크톱 전원 컨트롤러(power.py). 보통 모델의 동시 요청이 2건 이상 60초 이어질 때만 PC 를 WOL 로 켜고,
# 1건 이하가 5분 이어지면 PC 에이전트에 release 를 보낸다.
# 끄는 것은 PC 에이전트(windows-agent.ps1 -AutoPower)가 사용자·연결·계산을 보고 스스로 한다.
# hostNetwork: 매직 패킷을 LAN 브로드캐스트로 내보내야 한다(파드 네트워크에서는 LAN 으로 나가지 않는다). 그래서 노드 포트 9111(지표)·
# 9112(수요 신고)를 잡는다 — 겹치지 않게 Recreate. 수요 신고는 토큰과 출발지(파드 대역)로 막는다.
# 토큰: Secret gpu-pc-power(gpu-pc-power-secret.sh). WOL 을 보낸 시각은 ConfigMap gpu-pc-power-state 에 남긴다
# (저장소에 선언하지 않는다 — 운전 상태라 selfHeal 이 되돌리면 안 된다. 없으면 컨트롤러가 만든다).
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gpu-pc-power
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: gpu-pc-power
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [list]                 # 라우터 파드 전부(종료 중 포함)의 통계를 합산
  - apiGroups: [""]
    resources: [configmaps]
    verbs: [create]               # 상태 ConfigMap 이 없을 때(create 는 이름으로 제한할 수 없다)
  - apiGroups: [""]
    resources: [configmaps]
    resourceNames: [gpu-pc-power-state]
    verbs: [get, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gpu-pc-power
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: gpu-pc-power }
subjects:
  - { kind: ServiceAccount, name: gpu-pc-power }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-pc-power
spec:
  replicas: 1
  strategy: { type: Recreate }    # hostNetwork 포트를 두 파드가 동시에 잡지 못한다
  selector:
    matchLabels: { app: gpu-pc-power }
  template:
    metadata:
      labels: { app: gpu-pc-power }
    spec:
      serviceAccountName: gpu-pc-power
      priorityClassName: optional
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet   # hostNetwork 에서도 Service 이름(kubernetes.default.svc)을 푼다
      containers:
        - name: power
          image: python:3.13-alpine
          command:
            - python3
            - -u
            - /app/power.py
            - --pc-server=pc-custom
            - --agent-host=[GPUPC_IP]
            - --mac=[GPUPC_MAC]
            - --wol-target=[LAN_BROADCAST]:9      # LAN 서브넷 브로드캐스트
            - --wol-target=255.255.255.255:9
            # meta backend(모델 확인) 서버가 모두 가져야 할 라우터 모델. 모델을 더하면 여기와 haproxy.cfg 의 ACL 도 고친다
            - --models=[ROUTER_MODELS]       # 예: gemma4:12b,qwen3.5:9b,gemma4:31b
            - --meta-servers=pve02-780m,pve01-610m
            # 30B(backend big)는 받지 않는다(--serve-big 없음). 16GB GPU 에서는 30B 가중치가 VRAM 을 넘어 생성이 iGPU 서버보다 느렸다
          env:
            - name: GPU_PC_CONTROL_TOKEN
              valueFrom: { secretKeyRef: { name: gpu-pc-power, key: control-token } }
            - name: GPU_PC_DEMAND_TOKEN
              valueFrom: { secretKeyRef: { name: gpu-pc-power, key: demand-token } }
          ports:
            - { name: metrics, containerPort: 9111 }
            - { name: demand, containerPort: 9112 }
          readinessProbe:
            httpGet: { path: /healthz, port: 9111 }
            periodSeconds: 10
          volumeMounts:
            - { name: config, mountPath: /app }
          resources:
            requests: { cpu: 5m, memory: 24Mi }
            limits:   { cpu: 100m, memory: 64Mi }
      volumes:
        - name: config
          configMap: { name: gpu-pc-power }
---
apiVersion: v1
kind: Service
metadata:
  name: gpu-pc-power
  labels: { app: gpu-pc-power }   # power-servicemonitor 가 이 라벨로 고른다
spec:
  selector: { app: gpu-pc-power }
  ports:
    - { name: metrics, port: 9111, targetPort: 9111 }
    - { name: demand, port: 9112, targetPort: 9112 }   # wiki-papers 의 수요 신고(power_url)
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: gpu-pc-power
  labels: { release: monitoring }
spec:
  selector:
    matchLabels: { app: gpu-pc-power }
  endpoints:
    - { port: metrics, path: /metrics, interval: 15s }
```
{: file="services/ollama/power-deployment.yaml" }

</details>

`kustomization.yaml` 에 매니페스트와 ConfigMap 을 더합니다. `power.py` 는 라우터 ConfigMap 과 따로 둡니다. 같은 ConfigMap 에 넣으면 컨트롤러만 고쳐도 해시가 바뀌어 라우터가 재시작됩니다.

```yaml
resources:
  - deployment.yaml
  - service.yaml
  - servicemonitor.yaml
  - power-deployment.yaml     # 추가
configMapGenerator:
  - name: ollama-router
    files:
      - haproxy.cfg
      - weights.py
      - metrics.py
  - name: gpu-pc-power         # 추가
    files:
      - power.py
```
{: file="services/ollama/kustomization.yaml" }

클라이언트가 서버 자리가 빌 때까지 라우터에 보내지 않고 기다린다면, 그 요청은 라우터 통계에 보이지 않습니다. 그런 클라이언트는 기다리는 동안 컨트롤러에 신고합니다. `POST http://gpu-pc-power.ollama.svc:9112/demand` 에 `Authorization: Bearer [DEMAND_TOKEN]` 과 `{"id": "<요청마다 고유>", "backend": "servers"}` 를 15초마다 보내고, 라우터로 보내기 직전에 `DELETE /demand/<id>` 합니다. 신고는 60초 안에 갱신하지 않으면 사라집니다.

```bash
# 커밋하고 push
git add services/ollama
git commit -m "feat(ollama): GPU 데스크톱을 서버로 넣고 전원 컨트롤러 추가"
git push
```

- **확인:** Argo CD 의 `ollama` Application 이 **Synced**, **Healthy** 이고, `kubectl -n ollama logs deploy/gpu-pc-power` 에 `시작: PC [GPUPC_IP](pc-custom)` 가 보입니다.

## 5. 동작 확인

PC 를 끄고 보통 모델 요청을 동시에 여러 건 보내 켜지는지, 요청이 끝나면 스스로 꺼지는지 봅니다. 확인하는 동안 PC 에 SSH 로 붙어 있으면 '사용 중'이라 종료가 미뤄지므로 상태는 HTTP 로만 봅니다.

```bash
# PC 끄기 (원격으로)
ssh [PC_USER]@[GPUPC_IP] 'shutdown /s /t 5'

# 보통 모델 요청 3건을 4분 동안 계속 보내기 (클러스터 안에서)
for i in 1 2 3; do (end=$(( $(date +%s) + 240 )); while [ $(date +%s) -lt $end ]; do
  curl -s -o /dev/null -w "%header{x-ollama-server} %{time_total}s\n" http://ollama.ollama.svc:11434/api/chat \
    -d '{"model":"gemma4:12b","stream":false,"messages":[{"role":"user","content":"긴 글을 써라"}],"options":{"num_predict":1000}}'
done) & done; wait

# 컨트롤러 판단과 PC 상태
kubectl -n ollama logs deploy/gpu-pc-power --since=15m
curl -s http://[GPUPC_IP]:11437/status
```

- **확인:**
  - 컨트롤러 로그에 `"actions": [["save", ...], ["wol"]]` 가 찍히고 1~2분 뒤 PC 가 켜져 `PC 에이전트 /auto → 200` 이 이어집니다.
  - 요청 응답의 서버 이름에 `pc-custom` 이 나옵니다.
  - 요청이 끝나고 5분 뒤 상태 JSON 의 `released` 가 `true`, 이어서 `shutdown_at` 이 채워지고 1분 뒤 PC 가 꺼집니다.
  - 컨트롤러 지표 `curl http://[NODE_IP]:9111/metrics` 의 `gpu_pc_state` 가 `off → waking → auto → released → off` 로 바뀝니다.

## 트러블슈팅

<details markdown="1">
<summary>WOL 로 켰는데 <code>auto_boot</code> 가 false 이고 꺼지지 않음</summary>

- **원인:** 그 부팅에 사람의 흔적이 남았습니다(`user_seen: true`). 원격 데스크톱 세션이 있었거나, 부팅 뒤 콘솔 입력이 들어왔습니다. 입력 보고 작업이 없던 예전 에이전트는 자동 로그인 세션만으로도 사람이 있다고 봤습니다.
- **해결:** 상태 JSON 의 `sessions`, `other_inbound` 를 봅니다. 에이전트를 최신으로 다시 설치하고, 다음 부팅부터 다시 확인합니다. 한 번 사람이 있었던 부팅은 끝까지 끄지 않는 것이 의도된 동작입니다.

</details>

<details markdown="1">
<summary><code>released</code> 가 true 인데 꺼지지 않음</summary>

- **원인:** 들어와 있는 연결(`other_inbound`의 SSH·SMB, `ollama_connections`)이 있거나 러너가 계산 중입니다. ansible 같은 도구는 SSH 연결을 60초쯤 열어 둡니다.
- **해결:** 연결이 끊기면 60초 뒤 `shutdown_at` 이 채워집니다. 그동안 새 요청이 오거나 사람이 쓰면 종료를 취소합니다.

</details>

## 마무리

GPU 데스크톱을 Ollama 라우터의 서버로 넣고, 평소에는 꺼 둔 채 보통 모델 요청이 동시에 몰릴 때만 쿠버네티스의 전원 컨트롤러가 WOL 로 켜고, 수요가 줄면 PC 가 스스로 꺼지는 구성을 완성했습니다. 사람이 쓴 흔적이 있는 부팅은 끄지 않고, 관리용 연결은 연결된 동안만 종료를 막습니다. 켜는 기준(동시 2건·60초)과 끄는 유예(5분)는 `power.py` 의 `Config` 에서 바꿉니다.

## 참고 자료

- [Ollama FAQ](https://docs.ollama.com/faq)
- [HAProxy 3.2 Configuration Manual: agent-check](https://docs.haproxy.org/3.2/configuration.html#5.2-agent-check)
- [Microsoft Learn: Wake on LAN (WOL) behavior in Windows](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/wake-on-lan-feature)
- [Microsoft Learn: Get started with OpenSSH for Windows](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse)
- [Kubernetes: Pod hostNetwork](https://kubernetes.io/docs/concepts/workloads/pods/#pod-networking)
