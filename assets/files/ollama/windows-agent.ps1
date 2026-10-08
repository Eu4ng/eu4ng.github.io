# 윈도우 PC 의 상태를 라우터(HAProxy agent-check)와 쓰는 쪽(wiki-papers)에 알려 주는 스크립트입니다.
# 라우터가 5초마다 이 포트에 접속하면 한 줄로 답합니다.
#   ready  - 요청을 보내도 됩니다
#   drain  - Ollama 가 아닌 프로그램(게임 등)이 GPU 를 쓰고 있거나, 모델을 올릴 메모리가 모자라니 새 요청을 보내지 마세요
#            (처리 중인 요청은 끝까지 갑니다)
# 이 스크립트가 꺼져 있으면 라우터는 헬스체크(Ollama 응답 여부)만 봅니다.
#
# 상태 JSON(-StatusPort, 기본 11437, HTTP GET /status)도 냅니다. LXC 모델 서버의 에이전트(proxmox-ansible templates/ollama/ollama-agent.py)와
# 같은 형식이라, wiki-papers 의 ollama 공급자(config.toml [providers.ollama] status_hosts)가 호출이 조용할 때 "지금 계산 중인가"를 묻습니다.
#   {"state","working","runners":[{"pid","name","state","cpu_percent"}],"gpu_busy_percent","stuck":[],"ollama_alive","sampled_at"}
#   working = 러너 CPU(코어 하나 = 100%) 또는 Ollama 프로세스의 GPU 사용률이 5% 를 넘음. 윈도우에는 D 상태가 없어 stuck 은 늘 빈 목록입니다.
#   러너(llama-server)는 GPU 의 Compute 엔진을 씁니다(2026-10-07 실측: 생성 중 Compute 96%, 러너 CPU 32%; 쉴 때 둘 다 0).
#
# 라우터의 backend 마다 조건이 다르면 포트를 달리해 둘을 띄웁니다(-TaskName 으로 예약 작업 이름도 가릅니다). 상태 JSON 은 PC 에 하나면 되므로
# 두 번째 작업은 -StatusPort 0 으로 끕니다(같은 포트를 둘이 잡으면 뒤의 것이 뜨지 못합니다). 예:
#   작은 모델용(기본): 포트 11435, 메모리 기준 없음, 상태 JSON 11437
#   30B 모델용:        powershell -ExecutionPolicy Bypass -File .\windows-agent.ps1 -Install -Port 11436 -MinFreeGB 22 -TaskName ollama-agent-big -StatusPort 0
#     → 사람이 PC 를 써서 여유 메모리(Ollama 가 이미 쥔 메모리는 여유로 침)가 22GB 아래면 drain. 20GB 모델이 스왑으로 가는 것을 막습니다.
#
# 이 파일은 UTF-8 BOM 으로 저장합니다. BOM 이 없으면 윈도우 PowerShell 5.1 이 한국어 윈도우에서 CP949 로 읽어, 한국어 주석이 다음 줄을
# 삼킵니다(2026-10-07 확인: param 의 HoldSeconds 가 앞 줄 주석에 먹혀 사라져 GPU 사용 뒤 drain 유지가 꺼져 있었다).
#
# 설치(관리자 PowerShell 에서 한 번):
#   powershell -ExecutionPolicy Bypass -File .\windows-agent.ps1 -Install
#     → C:\ProgramData\ollama-agent 에 복사하고, 부팅 때 시작하는 예약 작업과 방화벽 규칙(TCP 11435, 11437 인바운드)을 만들고 바로 시작합니다.
# 제거:
#   powershell -ExecutionPolicy Bypass -File .\windows-agent.ps1 -Uninstall            (-TaskName 을 줬으면 같이)
# 지금 상태만 보기(설치 없이):
#   powershell -ExecutionPolicy Bypass -File .\windows-agent.ps1 -Check               (-MinFreeGB 를 주면 메모리도 봅니다)
#
# 자동 전원(-AutoPower, 조립 PC 용): 허브의 컨트롤러(services/ollama/power.py)가 LLM 수요가 있을 때 WOL 로 이 PC 를 켜고,
# 제어 포트(-ControlPort)로 알려 준다.
#   POST /auto {boot_id}     이번 부팅을 '자동 켜짐'으로 표시(지금 부팅이고, 이번 부팅에 사용자가 없었을 때만. 아니면 409)
#   POST /release {boot_id}  자동 켜짐이고 사용자가 없으면 drain 하고, 일이 끝나면 스스로 종료한다
#   POST /hint {...}         5초마다. 라우터 통계의 PC 처리 중(backend 별)과 30B 대기. -ExclusiveModels 의 두 포트 drain 에 쓴다
# 요청마다 Authorization: Bearer <토큰>(C:\ProgramData\<TaskName>\token, scripts/gpu-pc-power-secret.sh 가 넣는다)이 맞아야 한다.
# 끄는 조건: 자동 켜짐 + release + 사용자 없음 + 11434 로 들어온 연결 0 + 계산 중 아님이 30초 → shutdown /s /t 30.
# 안전망: 컨트롤러 연락(/hint)이 10분 없고 일 없이 10분이면 스스로 release 한다(컨트롤러가 죽어도 PC 가 계속 켜져 있지 않게).
# 카운트다운 중 사용자·새 연결·/auto 가 오면 shutdown /a 로 취소한다. 사용자가 한 번이라도 있었던 부팅은 끄지 않는다.
# 사람의 흔적 = 원격 세션(RDP, 연결 끊긴 세션 포함) 또는 콘솔에 사람이 입력한 흔적. 한 번이라도 있으면 그 부팅은 끄지 않는다.
# 들어온 연결(SSH, RDP 로그인 전, SMB 등)은 연결돼 있는 동안만 끄기를 막는다(관리 작업이 PC 를 영영 켜 두지 않게). 콘솔 세션이 있다는 것만으로는 사용자로 보지 않는다 — 비밀번호 없는 계정은 부팅 때
#          Windows 가 자동으로 로그인해(조립 PC, 2026-10-08) WOL 로 켜도 콘솔 세션이 생긴다. 그래서 로그인 때 사용자 세션에서
#          도는 입력 보고 작업(-ReportInput, 예약 작업 <TaskName>-input)이 마지막 키보드·마우스 입력 시각을 파일에 적고,
#          부팅 뒤 InputGraceSeconds 가 지나서 들어온 입력이 있으면 사용자로 본다(Parsec 같은 원격 조작도 콘솔 입력으로 잡힌다).
# 설치 예: powershell -ExecutionPolicy Bypass -File .\windows-agent.ps1 -Install -AutoPower -BigPort 11436 -ControlPort 11438 -AllowFrom [NODE_IP_1],[NODE_IP_2]
param(
    [int]$Port = 11435,
    [int]$StatusPort = 11437,
    [double]$Threshold = 30,
    [int]$HoldSeconds = 120,
    [double]$MinFreeGB = 0,
    [string]$TaskName = 'ollama-agent',
    [switch]$AutoPower,
    [int]$BigPort = 0,
    [int]$ControlPort = 0,
    [switch]$ExclusiveModels,
    [string[]]$AllowFrom = @(),
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Check,
    [switch]$ReportInput
)
# 파라미터 뜻
#   Port        agent-check 포트(ready/drain 한 단어, "stats" 를 보내면 JSON 한 줄)
#   StatusPort  상태 JSON(HTTP) 포트. 0 이면 띄우지 않습니다
#   Threshold   Ollama 가 아닌 프로세스의 GPU 3D 사용률 합(%)이 이 값을 넘으면 사용 중으로 봅니다
#   HoldSeconds 사용 중으로 본 뒤 이 시간 동안은 계속 drain 으로 답합니다(로딩 화면처럼 잠깐 내려가는 구간)
#   MinFreeGB   0 이면 메모리를 보지 않습니다. 양수면 여유 메모리(+ Ollama 가 쥔 메모리)가 이 값(GB) 아래일 때 drain
#   AutoPower   자동 전원(위 설명). BigPort(30B backend 용 agent-check, 0 이면 없음)·ControlPort 와 함께 씁니다
#   ExclusiveModels  30B 와 보통 모델을 함께 올릴 수 없는 GPU. 컨트롤러 힌트로 두 포트를 서로 drain 합니다
#   AllowFrom   제어 포트에 붙을 수 있는 주소(허브 워커). 방화벽 규칙과 코드에서 둘 다 확인합니다

# -File 로 부르면(예약 작업) -AllowFrom a,b 가 배열이 아니라 문자열 하나로 들어온다. 쉼표로 나눠 둔다
$AllowFrom = @($AllowFrom | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$InstallDir = Join-Path $env:ProgramData $TaskName
$SampleSeconds = 5        # GPU·러너 CPU 를 재는 간격(LXC 에이전트와 같음)
$WorkingPercent = 5.0     # 러너 CPU 또는 Ollama GPU 사용률이 이보다 크면 계산 중

function Get-OllamaProcesses {
    return @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like 'ollama*' -or $_.ProcessName -like 'llama*' })
}

function Get-GpuUsage {
    # 성능 카운터 이름은 윈도우 언어에 따라 바뀌므로, 언어와 무관한 CIM 클래스로 읽습니다.
    # Name 예: pid_1234_luid_0x00000000_0x0000C3F2_phys_0_eng_0_engtype_3D
    # Other  = Ollama 가 아닌 프로세스의 3D 엔진 사용률 합(게임 등 사람이 쓰는 프로그램)
    # Ollama = Ollama 프로세스(llama-server 포함)의 모든 엔진 사용률 합(러너는 Compute 엔진을 씁니다), 100 이 상한
    $ollama = @(Get-OllamaProcesses | ForEach-Object { $_.Id })
    $other = 0.0
    $mine = 0.0
    Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.Name -match '^pid_(\d+)_') {
                if ($ollama -contains [int]$Matches[1]) {
                    $mine += [double]$_.UtilizationPercentage
                } elseif ($_.Name -like '*engtype_3D*') {
                    $other += [double]$_.UtilizationPercentage
                }
            }
        }
    return @{ Other = $other; Ollama = [Math]::Min($mine, 100.0) }
}

function Get-FreeGBForOllama {
    # 지금 비어 있는 메모리 + Ollama 가 이미 쥔 메모리(모델을 바꿔 올리면 돌려받는다). 사람이 쓰는 프로그램이 차지한 만큼만 뺀 셈이다.
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $free = if ($os) { [double]$os.FreePhysicalMemory * 1KB } else { 0 }
    $ollama = (Get-OllamaProcesses | Measure-Object -Property WorkingSet64 -Sum).Sum
    return ($free + [double]$ollama) / 1GB
}

$script:cpuLast = @{}    # pid -> @(누적 CPU 초, 잰 시각)
function Get-Runners {
    # Ollama 프로세스(트레이 앱 제외)마다 지난번 잰 뒤의 CPU 사용률(%, 코어 하나 = 100). 처음 보는 프로세스는 0 입니다.
    $now = Get-Date
    $seen = @{}
    foreach ($p in Get-OllamaProcesses) {
        if ($p.ProcessName -eq 'ollama app') { continue }
        try { $cpu = $p.TotalProcessorTime.TotalSeconds } catch { continue }
        $prev = $script:cpuLast[$p.Id]
        $percent = 0.0
        if ($prev) {
            $elapsed = [Math]::Max(($now - $prev[1]).TotalSeconds, 0.001)
            $percent = [Math]::Round(($cpu - $prev[0]) / $elapsed * 100, 1)
        }
        $script:cpuLast[$p.Id] = @($cpu, $now)
        $seen[$p.Id] = $true
        [ordered]@{ pid = $p.Id; name = $p.ProcessName; state = 'R'; cpu_percent = $percent }
    }
    foreach ($id in @($script:cpuLast.Keys)) {
        if (-not $seen.ContainsKey($id)) { $script:cpuLast.Remove($id) }
    }
}

function Test-OllamaAlive {
    # IPv6 루프백을 먼저 봅니다. Ollama 는 [::]:11434 에서 듣는데, PC 의 VS Code 가 원격 SSH 포트 전달로 127.0.0.1:11434 를 따로 잡으면
    # IPv4 루프백은 Ollama 가 아니라 그쪽으로 갑니다(2026-10-07 확인, 시간 초과).
    foreach ($uri in 'http://[::1]:11434/api/version', 'http://127.0.0.1:11434/api/version') {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 3
            if ($r.StatusCode -eq 200) { return $true }
        } catch {
            continue
        }
    }
    return $false
}

function Test-Working($runners, $gpuOllama) {
    $cpuMax = ($runners | ForEach-Object { $_.cpu_percent } | Measure-Object -Maximum).Maximum
    return (([double]$cpuMax) -gt $WorkingPercent) -or ($gpuOllama -gt $WorkingPercent)
}

# ---- 자동 전원(-AutoPower)

function Get-BootId {
    # 이번 부팅 시각(UTC epoch 초). 컨트롤러가 WOL 을 보낸 시각과 맞대 '내가 켠 부팅'인지 정한다
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    return [DateTimeOffset]::new($os.LastBootUpTime).ToUnixTimeSeconds()
}

function Get-AgentPorts {
    return @(11434, $Port, $BigPort, $StatusPort, $ControlPort) | Where-Object { $_ -gt 0 }
}

function Get-Inbound {
    # 이 PC 의 대기 포트로 들어온 ESTABLISHED 연결(루프백 제외). Ollama(11434) 와 그 밖(사람이 쓰는 것)으로 나눈다
    $listen = @{}
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object { $listen[[int]$_.LocalPort] = $true }
    $ollama = 0
    $other = @()
    $agentPorts = Get-AgentPorts
    Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $listen.ContainsKey([int]$_.LocalPort) -and $_.RemoteAddress -notmatch '^(127\.|::1$|::ffff:127\.)' } |
        ForEach-Object {
            if ($_.LocalPort -eq 11434) { $ollama++ }
            elseif ($agentPorts -notcontains [int]$_.LocalPort) { $other += "$($_.LocalPort)<-$($_.RemoteAddress)" }
        }
    return @{ Ollama = $ollama; Other = $other }
}

function Get-Sessions {
    # 대화형 세션 "<사용자>:<세션 이름>"(콘솔은 console, RDP 는 rdp-tcp#N, 연결 끊긴 세션은 disc). 아무도 없으면 빈 목록
    $lines = @(& query user 2>$null)
    return @($lines | Select-Object -Skip 1 | ForEach-Object {
        $cols = $_.Trim().TrimStart('>') -split '\s+'
        if (-not $cols[0]) { return }
        # 연결 끊긴 세션은 세션 이름 칸이 비어 두 번째 칸이 ID(숫자)다
        $name = if ($cols.Count -gt 1 -and $cols[1] -notmatch '^\d+$') { $cols[1] } else { 'disc' }
        "$($cols[0]):$name"
    })
}

$script:inputFile = Join-Path (Join-Path $env:ProgramData $TaskName) 'input.txt'
$InputGraceSeconds = 120   # 자동 로그인 직후의 시작 프로그램 소동은 입력으로 치지 않는다

function Get-LastInput {
    # 입력 보고 작업이 적은 마지막 입력 시각(UTC epoch 초). 없으면 0
    try { return [long](Get-Content -Raw -Path $script:inputFile -ErrorAction Stop).Trim() } catch { return 0 }
}

function Test-HumanSeen($sessions, [long]$bootId) {
    # 사람의 흔적: 원격 세션(콘솔이 아닌 것, 연결 끊긴 세션 포함) 또는 부팅 뒤 콘솔 입력. 한 번이라도 있으면 그 부팅은 끄지 않는다
    $remote = @($sessions | Where-Object { $_ -notmatch ':console$' })
    return ($remote.Count -gt 0) -or ((Get-LastInput) -gt ($bootId + $InputGraceSeconds))
}

function Test-UserPresent($sessions, $inbound, [long]$bootId) {
    # 지금 사용 중인가: 사람의 흔적이나 들어온 연결(SSH·SMB 등). 들어온 연결은 연결돼 있는 동안만 끄기를 막는다 —
    # 관리 작업(ansible·ssh)이 자동으로 켠 PC 를 영영 켜 두지 않게(2026-10-08 시험에서 ssh 한 번으로 그 부팅이 사용자 부팅이 됐다)
    return (Test-HumanSeen $sessions $bootId) -or ($inbound.Other.Count -gt 0)
}

$script:powerFile = Join-Path (Join-Path $env:ProgramData $TaskName) 'power.json'
function Read-Power([long]$bootId) {
    # 이번 부팅의 표시만 믿는다. 다른 부팅의 파일이면 새로 시작한다
    try {
        $saved = Get-Content -Raw -Path $script:powerFile -ErrorAction Stop | ConvertFrom-Json
        if ([long]$saved.boot_id -eq $bootId) {
            return @{ boot_id = $bootId; auto_boot = [bool]$saved.auto_boot; user_seen = [bool]$saved.user_seen; released = [bool]$saved.released }
        }
    } catch { }
    return @{ boot_id = $bootId; auto_boot = $false; user_seen = $false; released = $false }
}

function Save-Power($p) {
    ConvertTo-Json -Compress -InputObject $p | Set-Content -Path $script:powerFile -Encoding ASCII
}

function Read-Token {
    try { return (Get-Content -Raw -Path (Join-Path (Join-Path $env:ProgramData $TaskName) 'token') -ErrorAction Stop).Trim() } catch { return '' }
}

if ($ReportInput) {
    # 사용자 세션에서 돈다(로그인 때 시작하는 예약 작업). 마지막 키보드·마우스 입력 시각을 5초마다 파일에 적는다
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class LastInput {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static uint IdleMilliseconds() {
        var info = new LASTINPUTINFO(); info.cbSize = (uint)Marshal.SizeOf(info);
        GetLastInputInfo(ref info); return unchecked((uint)Environment.TickCount - info.dwTime);
    }
}
'@
    $last = 0
    while ($true) {
        $at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]([LastInput]::IdleMilliseconds() / 1000)
        if ($at -ne $last) {
            try { Set-Content -Path $script:inputFile -Value $at -Encoding ASCII -ErrorAction Stop; $last = $at } catch { }
        }
        Start-Sleep -Seconds 5
    }
}

if ($Check) {
    [void](Get-Runners)
    Start-Sleep -Seconds 1
    $runners = @(Get-Runners)
    $gpu = Get-GpuUsage
    $freeGB = Get-FreeGBForOllama
    $low = ($MinFreeGB -gt 0) -and ($freeGB -lt $MinFreeGB)
    $state = if (($gpu.Other -gt $Threshold) -or $low) { 'drain' } else { 'ready' }
    $working = Test-Working $runners $gpu.Ollama
    Write-Output ("{0} (Ollama 가 아닌 프로세스의 GPU 3D 사용률 합: {1:N0}%, 기준 {2}%; Ollama 가 쓸 수 있는 메모리 {3:N1}GB, 기준 {4}GB)" -f $state, $gpu.Other, $Threshold, $freeGB, $MinFreeGB)
    Write-Output ("working={0} (Ollama GPU {1:N0}%, 러너 CPU {2}; HoldSeconds {3}, StatusPort {4})" -f $working, $gpu.Ollama,
        (($runners | ForEach-Object { '{0}={1}%' -f $_.name, $_.cpu_percent }) -join ' '), $HoldSeconds, $StatusPort)
    if ($AutoPower) {
        $bootId = Get-BootId
        $inbound = Get-Inbound
        $sessions = Get-Sessions
        $p = Read-Power $bootId
        Write-Output ("boot_id={0} auto_boot={1} user_seen={2} released={3} 세션=[{4}] Ollama 연결={5} 그 밖의 들어온 연결=[{6}] 토큰={7} 마지막 입력={8} 사용자={9}" -f
            $bootId, $p.auto_boot, $p.user_seen, $p.released, ($sessions -join ','), $inbound.Ollama, ($inbound.Other -join ','),
            $(if (Read-Token) { '있음' } else { '없음' }), (Get-LastInput), (Test-UserPresent $sessions $inbound $bootId))
    }
    exit 0
}

if ($Uninstall) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName $TaskName -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "$TaskName-status" -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "$TaskName-big" -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "$TaskName-control" -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "$TaskName-input" -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
    Write-Output '제거했습니다.'
    exit 0
}

if ($Install) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $target = Join-Path $InstallDir 'windows-agent.ps1'
    Copy-Item -Force $PSCommandPath $target
    $extra = ''
    if ($AutoPower) {
        if ($ControlPort -le 0) { Write-Error '-AutoPower 에는 -ControlPort 가 필요합니다'; exit 2 }
        $extra = " -AutoPower -BigPort $BigPort -ControlPort $ControlPort"
        if ($ExclusiveModels) { $extra += ' -ExclusiveModels' }
        if ($AllowFrom.Count -gt 0) { $extra += " -AllowFrom $($AllowFrom -join ',')" }
    }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`" -Port $Port -StatusPort $StatusPort -Threshold $Threshold -HoldSeconds $HoldSeconds -MinFreeGB $MinFreeGB -TaskName $TaskName$extra"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    if (-not (Get-NetFirewallRule -DisplayName $TaskName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $TaskName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
    }
    if (($StatusPort -gt 0) -and -not (Get-NetFirewallRule -DisplayName "$TaskName-status" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "$TaskName-status" -Direction Inbound -Protocol TCP -LocalPort $StatusPort -Action Allow | Out-Null
    }
    if ($AutoPower) {
        # 입력 보고 작업: 어느 사용자든 로그인할 때 그 세션에서 창 없이 돈다. 결과 파일은 사용자 권한으로 쓸 수 있게 둔다
        $inputFile = Join-Path $InstallDir 'input.txt'
        if (-not (Test-Path $inputFile)) { Set-Content -Path $inputFile -Value 0 -Encoding ASCII }
        icacls $inputFile /grant '*S-1-5-32-545:M' | Out-Null   # BUILTIN\Users(언어와 무관하게 SID 로)
        $inputAction = New-ScheduledTaskAction -Execute 'conhost.exe' `
            -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$target`" -ReportInput -TaskName $TaskName"
        $inputTrigger = New-ScheduledTaskTrigger -AtLogOn
        $inputPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
        Register-ScheduledTask -TaskName "$TaskName-input" -Action $inputAction -Trigger $inputTrigger -Principal $inputPrincipal -Settings $settings -Force | Out-Null
        # 다시 설치하면 규칙을 새 값으로 바꾼다. agent-check·상태는 같은 서브넷(LocalSubnet)에서, 제어는 -AllowFrom(쿠버네티스 노드)에서만
        foreach ($rule in "$TaskName", "$TaskName-status", "$TaskName-big", "$TaskName-control") {
            Remove-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
        }
        New-NetFirewallRule -DisplayName $TaskName -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress LocalSubnet -Action Allow | Out-Null
        if ($StatusPort -gt 0) {
            New-NetFirewallRule -DisplayName "$TaskName-status" -Direction Inbound -Protocol TCP -LocalPort $StatusPort -RemoteAddress LocalSubnet -Action Allow | Out-Null
        }
        if ($BigPort -gt 0) {
            New-NetFirewallRule -DisplayName "$TaskName-big" -Direction Inbound -Protocol TCP -LocalPort $BigPort -RemoteAddress LocalSubnet -Action Allow | Out-Null
        }
        $remote = if ($AllowFrom.Count -gt 0) { $AllowFrom } else { @('LocalSubnet') }
        New-NetFirewallRule -DisplayName "$TaskName-control" -Direction Inbound -Protocol TCP -LocalPort $ControlPort -RemoteAddress $remote -Action Allow | Out-Null
    }
    Start-ScheduledTask -TaskName $TaskName
    Write-Output "설치했습니다. 예약 작업 '$TaskName', 방화벽 TCP $Port(+ 상태 $StatusPort) 인바운드. 확인: Test-NetConnection localhost -Port $Port"
    exit 0
}

# ---- 서버
# agent-check 포트: 접속마다 지금 상태를 한 줄로 답합니다.
#   라우터(HAProxy agent-check)는 아무것도 보내지 않고 답만 읽습니다 → ready/drain 한 단어.
#   라우터 파드의 지표 수집기(metrics.py)는 "stats" 한 줄을 먼저 보냅니다 → 상태와 여유 메모리·GPU 사용률을 JSON 한 줄로 답합니다
#   (HAProxy 가 모르는 단어를 어떻게 다루는지 문서에 보장이 없어, 같은 포트에서 요청이 있을 때만 다른 형식으로 답합니다).
#   -BigPort 는 30B backend 용 agent-check 입니다(-AutoPower). 같은 프로세스가 답해 상태를 한 곳에서만 가집니다.
# 상태 포트: 요청 내용과 상관없이 HTTP 200 과 상태 JSON 으로 답합니다.
# 제어 포트(-AutoPower): 컨트롤러의 /auto·/release·/hint.
# 리스너를 한 스레드에서 번갈아 보고, SampleSeconds 마다 GPU·메모리·러너 CPU(와 자동 전원 상태)를 잽니다. 답은 마지막으로 잰 값으로 합니다.
function New-Listener([int]$p) {
    if ($p -le 0) { return $null }
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $p)
    $l.Start()
    return $l
}
$listener = New-Listener $Port
$statusListener = New-Listener $StatusPort
$bigListener = if ($AutoPower) { New-Listener $BigPort } else { $null }
$controlListener = if ($AutoPower) { New-Listener $ControlPort } else { $null }
$busyUntil = [DateTime]::MinValue
$nextSample = [DateTime]::MinValue
$current = $null
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# 자동 전원 상태
$bootId = if ($AutoPower) { Get-BootId } else { 0 }
$power = if ($AutoPower) { Read-Power $bootId } else { $null }
$hint = $null
$lastHint = Get-Date              # 안전망은 에이전트가 뜬 뒤부터 센다
$idleSince = $null                # 끄기 조건이 맞기 시작한 때
$netIdleSince = $null             # 자동 켜짐이고 일이 없기 시작한 때(안전망)
$shutdownAt = $null
$token = if ($AutoPower) { Read-Token } else { '' }
$userPresent = $false
$inbound = @{ Ollama = 0; Other = @() }
$sessions = @()

function Read-Request($stream, [int]$waitMs) {
    $deadline = (Get-Date).AddMilliseconds($waitMs)
    while (-not $stream.DataAvailable -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 10 }
    if (-not $stream.DataAvailable) { return '' }
    $buf = New-Object byte[] 4096
    $n = $stream.Read($buf, 0, $buf.Length)
    return [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
}

function Read-Http($stream) {
    # 머리와 본문(Content-Length 만큼)을 다 읽는다. 2초 안에 안 오면 받은 만큼만
    $deadline = (Get-Date).AddSeconds(2)
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 8192
    while ((Get-Date) -lt $deadline) {
        if ($stream.DataAvailable) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
            $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
            $split = $text.IndexOf("`r`n`r`n")
            if ($split -ge 0) {
                $head = $text.Substring(0, $split)
                $len = if ($head -match '(?im)^Content-Length:\s*(\d+)') { [int]$Matches[1] } else { 0 }
                if ([System.Text.Encoding]::UTF8.GetByteCount($text.Substring($split + 4)) -ge $len) {
                    return @{ Head = $head; Body = $text.Substring($split + 4) }
                }
            }
        } else {
            Start-Sleep -Milliseconds 10
        }
    }
    $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    $split = $text.IndexOf("`r`n`r`n")
    if ($split -lt 0) { return @{ Head = $text; Body = '' } }
    return @{ Head = $text.Substring(0, $split); Body = $text.Substring($split + 4) }
}

function Send-Json($client, [int]$code, $obj) {
    $stream = $client.GetStream()
    $reason = @{ 200 = 'OK'; 400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'; 404 = 'Not Found'; 409 = 'Conflict' }[$code]
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -Depth 4 -InputObject $obj))
    $head = [System.Text.Encoding]::ASCII.GetBytes(
        "HTTP/1.1 $code $reason`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n")
    $stream.Write($head, 0, $head.Length)
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $stream.Flush()
    $client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send)
}

function Stop-Shutdown([string]$why) {
    if ($script:shutdownAt) {
        & shutdown.exe /a 2>$null | Out-Null
        $script:shutdownAt = $null
    }
    $script:idleSince = $null
}

function Get-CheckState([string]$which) {
    # agent-check 의 답. which: servers(Port) 또는 big(BigPort)
    if (-not $current) { return 'ready' }
    if ($current.State -eq 'drain') { return 'drain' }
    if ($AutoPower -and $power.released) { return 'drain' }
    if ($AutoPower -and $ExclusiveModels -and $hint -and ((Get-Date) - $lastHint).TotalSeconds -le 30) {
        # 30B 와 보통 모델을 함께 못 올리는 GPU: 30B 가 기다리거나 돌면 보통 요청을, 보통 요청이 돌면 30B 를 받지 않는다
        if ($which -eq 'servers' -and ($hint.big_pending -or [int]$hint.pc_big_active -gt 0)) { return 'drain' }
        if ($which -eq 'big' -and [int]$hint.pc_servers_active -gt 0) { return 'drain' }
    }
    return 'ready'
}

function Update-Power {
    # SampleSeconds 마다: 사용자·연결을 보고, 끄기 조건과 안전망을 판정한다
    $script:sessions = Get-Sessions
    $script:inbound = Get-Inbound
    $script:userPresent = Test-UserPresent $sessions $inbound $bootId
    if ((Test-HumanSeen $sessions $bootId) -and -not $power.user_seen) {
        # 사람이 한 번이라도 있었던 부팅은 끝까지 끄지 않는다
        $power.user_seen = $true
        $power.auto_boot = $false
        $power.released = $false
        Save-Power $power
    }
    $idle = $power.auto_boot -and -not $userPresent -and ($inbound.Ollama -eq 0) -and -not $current.Working
    # 안전망: 컨트롤러 연락이 10분 없고 일 없이 10분이면 스스로 release
    if ($power.auto_boot -and -not $power.released -and $idle) {
        if (-not $script:netIdleSince) { $script:netIdleSince = Get-Date }
        if (((Get-Date) - $lastHint).TotalMinutes -ge 10 -and ((Get-Date) - $netIdleSince).TotalMinutes -ge 10) {
            $power.released = $true
            Save-Power $power
        }
    } else {
        $script:netIdleSince = $null
    }
    if ($power.auto_boot -and $power.released -and $idle) {
        if (-not $script:idleSince) { $script:idleSince = Get-Date }
        if (-not $shutdownAt -and ((Get-Date) - $idleSince).TotalSeconds -ge 30) {
            & shutdown.exe /s /t 30 /c "LLM 작업이 끝나 자동으로 종료합니다(ollama-agent). 취소: shutdown /a" 2>$null | Out-Null
            $script:shutdownAt = (Get-Date).AddSeconds(30)
        }
    } else {
        Stop-Shutdown 'not idle'
    }
}

function Invoke-Control($client) {
    $req = Read-Http $client.GetStream()
    $remote = $client.Client.RemoteEndPoint.Address
    if ($remote.IsIPv4MappedToIPv6) { $remote = $remote.MapToIPv4() }
    if ($AllowFrom.Count -gt 0 -and $AllowFrom -notcontains $remote.ToString()) { Send-Json $client 403 @{ error = 'forbidden' }; return }
    if (-not $token -or $req.Head -notmatch "(?im)^Authorization:\s*Bearer\s+$([regex]::Escape($token))\s*$") {
        Send-Json $client 401 @{ error = 'unauthorized' }; return
    }
    $first = ($req.Head -split "`r`n")[0]
    try { $body = if ($req.Body) { $req.Body | ConvertFrom-Json } else { $null } } catch { Send-Json $client 400 @{ error = 'json' }; return }
    switch -Regex ($first) {
        '^POST /hint ' {
            $script:hint = $body
            $script:lastHint = Get-Date
            Send-Json $client 200 @{ ok = $true }
        }
        '^POST /auto ' {
            if ([long]$body.boot_id -ne $bootId -or $power.user_seen -or $userPresent) {
                Send-Json $client 409 @{ error = 'not this boot or user seen'; boot_id = $bootId; user_seen = $power.user_seen }
            } else {
                $power.auto_boot = $true
                $power.released = $false
                Save-Power $power
                Stop-Shutdown 'auto'
                Send-Json $client 200 @{ ok = $true }
            }
        }
        '^POST /release ' {
            if ([long]$body.boot_id -ne $bootId -or -not $power.auto_boot -or $userPresent) {
                Send-Json $client 409 @{ error = 'not auto boot or user present' }
            } else {
                $power.released = $true
                Save-Power $power
                Send-Json $client 200 @{ ok = $true }
            }
        }
        default { Send-Json $client 404 @{ error = 'not found' } }
    }
}

function Invoke-Check($l, [string]$which) {
    $client = $l.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        # 라우터는 보내는 것이 없으므로 300ms 만 기다린다(agent-inter 5s 에 비해 작다)
        $request = (Read-Request $stream 300).Trim()
        $state = Get-CheckState $which
        $reply = if ($request -eq 'stats') {
            [string]::Format($inv, '{{"state":"{0}","free_gb":{1:F1},"other_gpu_percent":{2:F0},"min_free_gb":{3}}}',
                $state, $current.FreeGB, $current.Other, $MinFreeGB)
        } else { $state }
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("$reply`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch {
        # 답하지 못해도 계속 듣습니다. 라우터는 답이 없으면 헬스체크만 봅니다
    } finally {
        $client.Close()
    }
}

try {
    while ($true) {
        if ((Get-Date) -ge $nextSample) {
            $gpu = Get-GpuUsage
            if ($gpu.Other -gt $Threshold) {
                $busyUntil = (Get-Date).AddSeconds($HoldSeconds)
            }
            # 메모리는 붙잡아 두지 않고 그때그때 본다(프로그램을 닫으면 바로 ready). GPU 사용은 로딩 구간이 있어 HoldSeconds 동안 붙잡는다
            $freeGB = Get-FreeGBForOllama
            $low = ($MinFreeGB -gt 0) -and ($freeGB -lt $MinFreeGB)
            $runners = @(Get-Runners)
            $current = @{
                State   = if (((Get-Date) -lt $busyUntil) -or $low) { 'drain' } else { 'ready' }
                FreeGB  = $freeGB
                Other   = $gpu.Other
                Ollama  = $gpu.Ollama
                Runners = $runners
                Working = Test-Working $runners $gpu.Ollama
                Alive   = if ($statusListener) { Test-OllamaAlive } else { $null }
                At      = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            }
            if ($AutoPower) {
                try { Update-Power } catch { }
            }
            $nextSample = (Get-Date).AddSeconds($SampleSeconds)
        }

        if ($listener.Pending()) { Invoke-Check $listener 'servers' }
        if ($bigListener -and $bigListener.Pending()) { Invoke-Check $bigListener 'big' }

        if ($controlListener -and $controlListener.Pending()) {
            $client = $controlListener.AcceptTcpClient()
            try { Invoke-Control $client } catch { } finally { $client.Close() }
        }

        if ($statusListener -and $statusListener.Pending()) {
            $client = $statusListener.AcceptTcpClient()
            try {
                [void](Read-Request $client.GetStream() 1000)
                $status = [ordered]@{
                    state            = Get-CheckState 'servers'
                    working          = [bool]$current.Working
                    runners          = @($current.Runners)
                    gpu_busy_percent = [int][Math]::Round($current.Ollama)
                    stuck            = @()
                    ollama_alive     = [bool]$current.Alive
                    sampled_at       = $current.At
                }
                if ($AutoPower) {
                    $status.boot_id = $bootId
                    $status.auto_boot = [bool]$power.auto_boot
                    $status.user_seen = [bool]$power.user_seen
                    $status.released = [bool]$power.released
                    $status.user_present = [bool]$userPresent
                    $status.sessions = @($sessions)
                    $status.other_inbound = @($inbound.Other)
                    $status.ollama_connections = [int]$inbound.Ollama
                    $status.shutdown_at = if ($shutdownAt) { [DateTimeOffset]::new($shutdownAt).ToUnixTimeSeconds() } else { $null }
                    $status.last_hint_at = [DateTimeOffset]::new($lastHint).ToUnixTimeSeconds()
                    $status.big_state = Get-CheckState 'big'
                }
                Send-Json $client 200 $status
            } catch {
                # 답하지 못해도 계속 듣습니다. 쓰는 쪽은 답이 없으면 상태를 모르는 것으로 두고 시간 상한으로 봅니다
            } finally {
                $client.Close()
            }
        }

        Start-Sleep -Milliseconds 20
    }
} finally {
    foreach ($l in $listener, $statusListener, $bigListener, $controlListener) { if ($l) { $l.Stop() } }
}
