---
layout: post
title: Windows PC의 CPU·GPU 온도와 전력을 Telegraf로 MQTT에 발행해 Proxmox 호스트와 같은 방식으로 보는 방법
description: Windows 데스크톱의 CPU·메모리·디스크·네트워크 부하와 CPU·GPU·메모리·디스크 온도, CPU·GPU 전력을 Proxmox 호스트와 같은 토픽·필드 이름으로 MQTT 에 발행해, Home Assistant 센서와 TimescaleDB 기록을 서버와 똑같이 쓰는 방법을 정리했습니다.
author: Eu4ng
tags: [windows, ansible, telegraf, mqtt, home-assistant, timescaledb, librehardwaremonitor, iot, homelab]
permalink: /posts/87/
---

[Proxmox 호스트의 부하를 Telegraf 로 MQTT 에 발행하는 방법](/posts/74/)과 같은 토픽(`hosts/[기기 이름]`)·필드 이름·발견 설정·연결 상태로 Windows PC 의 값을 냅니다. 그래서 Home Assistant 센서, 엣지 Telegraf 의 DB 적재, 전력 플러그와 맞춰 보는 쿼리를 서버와 그대로 씁니다. 리눅스는 커널(hwmon·RAPL)이 CPU 온도와 패키지 전력을 주지만 Windows 는 하드웨어 접근 드라이버가 필요하므로, **LibreHardwareMonitor** 라이브러리와 서명된 **PawnIO** 드라이버로 읽는 상주 스크립트가 값을 파일로 쓰고 Telegraf 가 그 파일을 읽습니다. 설치는 같은 Ansible 저장소에 Windows 용 플레이북 하나를 더해 OpenSSH 로 합니다.

1. PC 준비
2. 변수와 인벤토리
3. 센서 스크립트·Telegraf 설정·플레이북
4. 플레이북 실행

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| PC | Windows 11 Pro (Ryzen 7 7800X3D + RTX 4080, Ryzen 7 8845HS + Radeon 780M) |
| Telegraf | `1.40.1` (서버·엣지와 같은 버전) |
| LibreHardwareMonitor | `0.9.6` (.NET Framework 4.7.2 빌드) |
| PawnIO | `2.2.0` |
| Python | `3.13.15` 내장형(embeddable) + paho-mqtt `2.1.0` |
| Ansible | `ansible.windows` 3.3, `community.windows` 3.1 |
| 작성 기준일 | `2026-10-08` |

다음 항목이 준비되어 있어야 합니다.

- [Proxmox 호스트 글](/posts/74/)의 Ansible 저장소, 발견 설정·연결 상태 스크립트, 엣지 Telegraf 의 `hosts/+` 입력
- 제어 PC 에 Windows 모듈 컬렉션

```bash
# Windows 모듈 컬렉션 설치 (제어 PC)
ansible-galaxy collection install ansible.windows community.windows
```

## 1. PC 준비

Ansible 은 OpenSSH 로 붙고 기본 셸을 PowerShell 로 씁니다. PC 의 관리자 PowerShell 에서 한 번 실행합니다.

```powershell
# OpenSSH 서버, LAN 에서 22 허용, 기본 셸 PowerShell, 제어 PC 의 공개 키 등록
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic; Start-Service sshd
New-NetFirewallRule -DisplayName sshd-lan -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress LocalSubnet -Action Allow
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -PropertyType String -Force
Set-Content -Path C:\ProgramData\ssh\administrators_authorized_keys -Value '[PUBLIC_KEY]' -Encoding ascii
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
```

> 관리자 계정은 `~/.ssh/authorized_keys` 가 아니라 `C:\ProgramData\ssh\administrators_authorized_keys` 를 봅니다. 파일 권한이 SYSTEM·Administrators 만이 아니면 키를 무시합니다.
{: .prompt-warning }

- **확인:** 제어 PC 에서 `ansible -i '[PC_IP],' all -u [PC_USER] -e ansible_connection=ssh -e ansible_shell_type=powershell -m ansible.windows.win_ping` 이 `pong` 을 냅니다.

## 2. 변수와 인벤토리

설치 파일은 제어 PC 캐시에 받아 sha256 을 확인한 뒤 PC 로 복사합니다. 버전을 올리면 이름·주소·sha256 을 함께 고칩니다.

{% raw %}
```yaml
# ---- windows-host-metrics: Windows PC 의 부하·온도·전력을 같은 방식으로 발행 (playbooks/windows-host-metrics.yml) ----
# 서버와 같은 Telegraf·토픽·필드·발견 설정·연결 상태를 쓰고, CPU 온도·전력 등은 LibreHardwareMonitor(PawnIO 드라이버)로 읽습니다.
# 설치 파일은 제어 PC 의 캐시에 받아(sha256 확인) PC 로 복사합니다. 버전을 올리면 이름·주소·sha256 을 함께 고칩니다.
windows_host_metrics_telegraf_version: "{{ host_metrics_telegraf_version | regex_replace('-[0-9]+$', '') }}"   # 서버·엣지와 같은 버전
windows_host_metrics_dir: 'C:\Program Files\host-metrics'      # Telegraf·내장형 Python·스크립트
windows_host_metrics_data: 'C:\ProgramData\host-metrics'       # 센서 줄·디스크 버퍼·비밀번호 파일(SYSTEM·Administrators 만)
windows_host_metrics_lhm_dir: 'C:\Program Files\LibreHardwareMonitor'
windows_host_metrics_cache: "{{ lookup('env', 'HOME') }}/.cache/windows-host-metrics"
windows_host_metrics_files:
  telegraf:
    name: "telegraf-{{ windows_host_metrics_telegraf_version }}_windows_amd64.zip"
    url: "https://dl.influxdata.com/telegraf/releases/telegraf-{{ windows_host_metrics_telegraf_version }}_windows_amd64.zip"
    sha256: cabe07907628afc17ce8c58a1c27b3a55a838b1fb9418b2c05e9342e6e8af8d9
  lhm:                                        # LibreHardwareMonitor .NET Framework 4.7.2 빌드(Windows PowerShell 5.1 에서 불러옴)
    name: LibreHardwareMonitor-0.9.6.zip
    url: https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.6/LibreHardwareMonitor.zip
    sha256: 086d9f1b5a99e643edc2cfaaac16051685b551e4c5ac0b32a57c58c0e529c001
  pawnio:                                     # LibreHardwareMonitor 가 CPU 온도·전력을 읽는 서명된 드라이버. -install -silent
    name: PawnIO_setup-2.2.0.exe
    url: https://github.com/namazso/PawnIO.Setup/releases/download/2.2.0/PawnIO_setup.exe
    sha256: 1f519a22e47187f70a1379a48ca604981c4fcf694f4e65b734aaa74a9fba3032
    version: 2.2.0.0                          # 설치된 버전(레지스트리 DisplayVersion)이 다르면 지우고 다시 설치
  python:                                     # 연결 상태·발견 설정 스크립트용 내장형 Python(설치기·PATH 변경 없음)
    name: python-3.13.15-embed-amd64.zip
    url: https://www.python.org/ftp/python/3.13.15/python-3.13.15-embed-amd64.zip
    sha256: d1f04d990aee1253d8569e8e5104e30fa9f5fa830899f14843448872d936a2cf
  paho:
    name: paho_mqtt-2.1.0-py3-none-any.whl
    url: https://files.pythonhosted.org/packages/c4/cb/00451c3cf31790287768bb12c6bec834f5d292eaf3022afc88e14b8afc94/paho_mqtt-2.1.0-py3-none-any.whl
    sha256: 6db9ba9b34ed5bc6b6e3812718c7e06e2fd7444540df2455d2c51bd58808feee
```
{: file="group_vars/all.yml (추가 부분)" }
{% endraw %}

인벤토리 파일에 적은 그룹 변수는 `group_vars/all.yml` 보다 우선순위가 낮아 덮이므로, Windows 만의 값은 그룹 변수 파일로 둡니다.

```yaml
# 사용자 Windows PC(inventory 의 windows_pcs). group_vars/all.yml 의 서버용 값을 덮어씁니다.
ansible_user: eu4ng
ansible_connection: ssh
ansible_shell_type: powershell        # OpenSSH 기본 셸이 PowerShell(HKLM\SOFTWARE\OpenSSH 의 DefaultShell)
host_metrics_mounts: ['C:']           # 시스템 드라이브. Telegraf 는 C: 로 거르고 path 태그에는 \C: 로 적습니다
host_metrics_ping_skip: []            # host_metrics_ping 가운데 재지 않을 구간(PC 마다 inventory 에서)
```
{: file="group_vars/windows_pcs.yml" }

```yaml
    windows_pcs:                  # 사용자 Windows PC. playbooks/windows-host-metrics.yml 이 부하·온도·전력을 서버와 같은 방식으로 발행합니다
      # 접속·수집 값은 group_vars/windows_pcs.yml(인벤토리의 그룹 변수는 group_vars/all.yml 보다 우선순위가 낮아 덮인다)
      hosts:
        pc-gpu:                   # 외장 GPU 데스크톱
          ansible_host: [GPUPC_IP]
          host_metrics_name: [방]-host-[GPUPC 제품 키]
          host_metrics_nic: 이더넷          # Get-NetAdapter -Physical 의 Name
          host_metrics_ping_skip: [nas]     # 그 PC 에서 닿지 않는 구간은 뺀다
        pc-mini:                  # iGPU 미니 PC
          ansible_host: [MINIPC_IP]
          host_metrics_name: [방]-host-[MINIPC 제품 키]
          host_metrics_nic: Wi-Fi
```
{: file="inventory.yml (windows_pcs 그룹 부분)" }

- **확인:** `ansible-inventory --host pc-gpu` 의 `host_metrics_mounts` 가 `["C:"]` 입니다.

## 3. 센서 스크립트·Telegraf 설정·플레이북

센서 스크립트는 예약 작업(부팅 때, SYSTEM)으로 상주하며 10초마다 서버와 같은 이름의 필드를 한 줄로 씁니다. 드라이버를 쓰는 라이브러리는 한 번 열어 두고 계속 읽어야 싸므로, Telegraf 가 매번 프로세스를 띄우는 `inputs.exec` 대신 파일을 거칩니다. 외장 GPU 가 있으면 `gpu_power` 도 내고, iGPU 전력은 서버처럼 `cpu_power`(패키지)에 포함합니다. 파일은 PowerShell 5.1 이 한국어 주석을 깨뜨리지 않게 UTF-8 BOM 으로 저장합니다.

<details markdown="1">
<summary>scripts/windows-sensors.ps1 전문</summary>

```powershell
# Windows PC 의 CPU·메모리·GPU·디스크 센서 값을 LibreHardwareMonitor 라이브러리로 읽어, 10초마다 InfluxDB line protocol 한 줄(측정값 sensors)로
# 파일에 씁니다. Telegraf(templates/host-metrics/windows-telegraf.conf.j2)의 inputs.file 이 그 파일을 읽어 서버와 같은 필드로 냅니다.
# playbooks/windows-host-metrics.yml 이 C:\Program Files\host-metrics 에 복사하고 예약 작업(부팅 때, SYSTEM)으로 상주시킵니다.
#
# 리눅스 서버는 커널(hwmon·RAPL)이 주는 값을 Telegraf 가 바로 읽지만, Windows 는 CPU 온도·패키지 전력에 하드웨어 접근 드라이버가
# 필요합니다(LibreHardwareMonitor 가 쓰는 PawnIO, 플레이북이 설치). 드라이버를 쓰는 라이브러리는 한 번 열어 두고 계속 읽어야 싸므로,
# Telegraf 가 10초마다 프로세스를 띄우는 inputs.exec 대신 상주 스크립트가 파일을 갱신합니다.
#
# 필드(서버와 같은 이름, k8s-gitops iot/README.md "호스트 값"):
#   cpu_temp(°C, AMD Tctl/Tdie·Intel Package)  cpu_power(W, 패키지)  cpu_clock(MHz, 코어 평균)  mem_temp(°C, DIMM 중 최고)
#   gpu_usage(%)  gpu_mem_used(B)  gpu_temp(°C)  gpu_power(W, 외장 GPU 만 — iGPU 전력은 cpu_power 에 포함)
#   disk_temp(°C, 드라이브 중 최고)  disk_usage(%, 드라이브 중 최고 활동률)  disk_wear_percent(%, NVMe 수명 사용률 최고)  disk_health_ok(1/0)
#   sampled_at(epoch 초) — Telegraf 가 30초보다 오래된 줄(이 스크립트가 멈춤)은 버립니다
# 외장 GPU(NVIDIA·AMD 외장)가 있으면 그것을, 없으면 iGPU 를 씁니다.
param(
    [string]$LibDir = 'C:\Program Files\LibreHardwareMonitor',
    [string]$Out = 'C:\ProgramData\host-metrics\sensors.influx',
    [int]$IntervalSeconds = 10,
    [switch]$Once        # 한 번 읽어 화면에 낸다(설치 확인용)
)
$ErrorActionPreference = 'Stop'

# 같은 폴더의 의존 DLL 은 LoadFrom 이 알아서 찾는다(AssemblyResolve 처리기를 PowerShell 로 걸면 재귀로 스택이 넘친다)
[void][Reflection.Assembly]::LoadFrom((Join-Path $LibDir 'LibreHardwareMonitorLib.dll'))
$computer = New-Object LibreHardwareMonitor.Hardware.Computer
$computer.IsCpuEnabled = $true
$computer.IsGpuEnabled = $true
$computer.IsMemoryEnabled = $true
$computer.IsStorageEnabled = $true
$computer.Open()
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function Get-Sensors($hw) {
    # 하드웨어 하나(와 하위 하드웨어)를 갱신하고 센서를 돌려준다
    $hw.Update()
    foreach ($s in $hw.Sensors) { $s }
    foreach ($sub in $hw.SubHardware) { Get-Sensors $sub }
}

function Pick($sensors, [string]$type, [string[]]$names) {
    # 이름 후보 순서대로 첫 값
    foreach ($n in $names) {
        $s = $sensors | Where-Object { "$($_.SensorType)" -eq $type -and $_.Name -eq $n -and $null -ne $_.Value } | Select-Object -First 1
        if ($s) { return [double]$s.Value }
    }
    return $null
}

function MaxOf($sensors, [string]$type, [string]$like) {
    $v = @($sensors | Where-Object { "$($_.SensorType)" -eq $type -and $_.Name -like $like -and $null -ne $_.Value } | ForEach-Object { [double]$_.Value })
    if ($v.Count) { return ($v | Measure-Object -Maximum).Maximum }
    return $null
}

function Read-Fields {
    $f = [ordered]@{}
    foreach ($hw in $computer.Hardware) {
        $sensors = @(Get-Sensors $hw)
        switch ("$($hw.HardwareType)") {
            'Cpu' {
                $f.cpu_temp = Pick $sensors 'Temperature' @('Core (Tctl/Tdie)', 'Core (Tctl)', 'CPU Package', 'Core Average')
                $f.cpu_power = Pick $sensors 'Power' @('Package', 'CPU Package')
                $f.cpu_clock = Pick $sensors 'Clock' @('Cores (Average)')
                if ($null -eq $f.cpu_clock) {
                    $c = @($sensors | Where-Object { "$($_.SensorType)" -eq 'Clock' -and $_.Name -like 'Core #*' -and $_.Value } | ForEach-Object { [double]$_.Value })
                    if ($c.Count) { $f.cpu_clock = ($c | Measure-Object -Average).Average }
                }
            }
            'Memory' {
                $t = MaxOf $sensors 'Temperature' 'DIMM #*'
                if ($null -ne $t -and ($null -eq $f.mem_temp -or $t -gt $f.mem_temp)) { $f.mem_temp = $t }
            }
            'Storage' {
                $t = Pick $sensors 'Temperature' @('Composite Temperature', 'Temperature')
                if ($null -ne $t -and ($null -eq $f.disk_temp -or $t -gt $f.disk_temp)) { $f.disk_temp = $t }
                $a = Pick $sensors 'Load' @('Total Activity')
                if ($null -ne $a -and ($null -eq $f.disk_usage -or $a -gt $f.disk_usage)) { $f.disk_usage = $a }
                $w = Pick $sensors 'Level' @('Percentage Used')
                if ($null -ne $w -and ($null -eq $f.disk_wear_percent -or $w -gt $f.disk_wear_percent)) { $f.disk_wear_percent = $w }
                $spare = Pick $sensors 'Level' @('Available Spare')
                $limit = Pick $sensors 'Level' @('Available Spare Threshold')
                if ($null -ne $spare -and $null -ne $limit) {
                    $ok = if ($spare -gt $limit) { 1 } else { 0 }
                    if ($null -eq $f.disk_health_ok -or $ok -lt $f.disk_health_ok) { $f.disk_health_ok = $ok }
                }
            }
            { $_ -in 'GpuNvidia', 'GpuAmd', 'GpuIntel' } {
                # 외장 GPU 를 우선한다(이미 외장 값을 넣었으면 iGPU 는 건너뜀). NVIDIA 는 늘 외장, AMD·Intel 은 공유 메모리만 크면 iGPU 로 본다
                $dedicatedMb = Pick $sensors 'SmallData' @('GPU Memory Total', 'D3D Dedicated Memory Total')
                $integrated = "$($hw.HardwareType)" -ne 'GpuNvidia' -and ($null -eq $dedicatedMb -or $dedicatedMb -le 4096)
                if ($f.Contains('gpu_discrete') -and $integrated) { break }
                $usage = Pick $sensors 'Load' @('GPU Core')
                if ($null -eq $usage) {
                    $loads = @($sensors | Where-Object { "$($_.SensorType)" -eq 'Load' -and ($_.Name -like 'D3D 3D*' -or $_.Name -like 'D3D Compute*') } | ForEach-Object { [double]$_.Value })
                    if ($loads.Count) { $usage = ($loads | Measure-Object -Maximum).Maximum }
                }
                $memMb = if ($integrated) {
                    $d = Pick $sensors 'SmallData' @('D3D Dedicated Memory Used'); $s = Pick $sensors 'SmallData' @('D3D Shared Memory Used')
                    if ($null -ne $d -or $null -ne $s) { [double]$d + [double]$s } else { $null }   # 서버의 VRAM + GTT 와 같은 뜻
                } else { Pick $sensors 'SmallData' @('GPU Memory Used', 'D3D Dedicated Memory Used') }
                $f.gpu_usage = $usage
                $f.gpu_mem_used = if ($null -ne $memMb) { $memMb * 1MB } else { $null }
                $f.gpu_temp = Pick $sensors 'Temperature' @('GPU Core', 'GPU Hot Spot')
                $f.gpu_power = if ($integrated) { $null } else { Pick $sensors 'Power' @('GPU Package', 'GPU Power') }
                if (-not $integrated) { $f.gpu_discrete = 1 }
            }
        }
    }
    $f.Remove('gpu_discrete')
    $f.sampled_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return $f
}

function Format-Line($f) {
    $parts = foreach ($k in $f.Keys) {
        if ($null -eq $f[$k]) { continue }
        if ($k -eq 'sampled_at') { "$k=$($f[$k])i" } else { [string]::Format($inv, '{0}={1:0.###}', $k, [double]$f[$k]) }
    }
    return 'sensors ' + ($parts -join ',')
}

if ($Once) {
    Read-Fields | Out-Null          # 첫 읽기는 활동률·클럭이 0 이거나 튄다
    Start-Sleep -Seconds 2
    Format-Line (Read-Fields)
    $computer.Close()
    exit 0
}

New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
$tmp = "$Out.tmp"
try {
    while ($true) {
        try {
            $line = Format-Line (Read-Fields)
            # 쓰다 만 파일을 Telegraf 가 읽지 않게 임시 파일에 쓰고 바꿔 넣는다
            [IO.File]::WriteAllText($tmp, $line + "`n", [Text.Encoding]::ASCII)
            Move-Item -Force $tmp $Out
        } catch {
            # 한 번 실패해도 계속 돈다. 오래 실패하면 sampled_at 이 낡아 Telegraf 가 버린다
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    $computer.Close()
}
```
{: file="scripts/windows-sensors.ps1" }

</details>

Telegraf 설정은 서버 설정과 같은 구조입니다. CPU 사용률·메모리·페이지 파일·디스크 용량·네트워크·ping 은 내장 입력을 쓰고, 센서 줄은 `inputs.file` 로 읽어 30초보다 낡았으면 버립니다. Windows 에는 부하 평균이 없어 `cpu_load` 는 내지 않습니다. `ping.exe` 출력은 언어마다 달라 `method = "native"` 로 보냅니다.

<details markdown="1">
<summary>templates/host-metrics/windows-telegraf.conf.j2 전문</summary>

{% raw %}
```toml
# Windows PC Telegraf. proxmox-ansible playbooks/windows-host-metrics.yml 이 templates/host-metrics/windows-telegraf.conf.j2 에서 만듭니다(여기서 고치지 않습니다).
# Proxmox 호스트(templates/host-metrics/telegraf.conf.j2)와 같은 모양으로, 10초마다 JSON 메시지 하나를 hosts/{{ host_metrics_name }} 에 발행합니다.
#   {"name": "host", "fields": {"cpu_usage": 3.9, "cpu_power": 29.9, "cpu_temp": 55.9, ...}, "tags": {}, "timestamp": <ms>}
# 필드 이름과 뜻은 서버와 같습니다. 다른 점:
#   - CPU 온도·전력·클럭, 메모리·디스크 온도, 디스크 활동률·수명, GPU 값은 리눅스 hwmon·RAPL·sysfs 대신 상주 스크립트
#     scripts/windows-sensors.ps1(LibreHardwareMonitor)이 C:\ProgramData\host-metrics\sensors.influx 에 쓰는 줄을 읽습니다.
#   - cpu_load(부하 평균)는 Windows 에 없어 내지 않습니다.
#   - gpu_power 는 외장 GPU 가 있는 PC 만 냅니다(iGPU 전력은 서버처럼 cpu_power 에 포함).
# Home Assistant 센서는 host-metrics-discovery.py 가 이 필드들로 만들고, 엣지 Telegraf 가 같은 토픽을 받아 DB readings 에 넣습니다.
# 필드 목록을 바꾸면 scripts/host-metrics-discovery.py 의 SENSORS·SLOW_FIELDS 와 엣지 Telegraf 의 HOST_UNITS(k8s-gitops iot/edge/telegraf)도 맞춥니다.
[agent]
  interval = "10s"
  round_interval = true
  flush_interval = "10s"
  metric_buffer_limit = 50000         # 브로커가 안 닿는 동안 쌓을 메시지 수(10초에 하나라 약 5일)
  buffer_strategy = "disk"            # 재시작해도 못 보낸 메시지가 남습니다
  buffer_directory = "{{ windows_host_metrics_data | replace('\\', '/') }}/buffer"
  omit_hostname = true                # 기기는 토픽이 가리킵니다
  skip_processors_after_aggregators = true

[[inputs.cpu]]
  percpu = false
  totalcpu = true
  report_active = true                # usage_active = 100 - idle

[[inputs.system]]                     # 물리·논리 코어 수, 가동 시간(부하 평균은 Windows 에서 늘 0 이라 쓰지 않음)

[[inputs.mem]]

[[inputs.swap]]                       # Windows 페이지 파일

[[inputs.disk]]
  mount_points = {{ host_metrics_mounts | to_json }}

[[inputs.net]]                        # 물리 NIC 의 누적 송수신량. 아래 starlark 가 초당 Mbit 로 바꿉니다
  interfaces = {{ [host_metrics_nic] | to_json }}

{% set pings = host_metrics_ping | dict2items | rejectattr('key', 'in', host_metrics_ping_skip) | items2dict %}
[[inputs.ping]]                       # 구간별 손실(서버와 같은 구간, host_metrics_ping_skip 은 뺌). Windows ping.exe 출력은 언어마다 달라 Go 로 직접 보냅니다
  urls = {{ pings.values() | list | to_json }}
  method = "native"
  count = 5
  ping_interval = 1.0
  deadline = 8

[[inputs.file]]                       # scripts/windows-sensors.ps1 이 10초마다 바꿔 넣는 센서 한 줄(측정값 sensors)
  files = [{{ (windows_host_metrics_data + '\\sensors.influx') | replace('\\', '/') | to_json }}]
  data_format = "influx"

# 입력마다 다른 측정값·태그를 host 측정값 하나의 대표 필드로 바꿉니다. 시각은 10초 단위로 내려 아래 merge 가 한 메시지로 묶게 합니다.
[[processors.starlark]]
  source = '''
BUCKET = 10 * 1000 * 1000 * 1000
SLOW_PERIOD = 3600 * 1000 * 1000 * 1000   # 사양·수명은 바뀔 때와 이 간격마다 한 번만 냅니다
SENSORS_MAX_AGE = 30                       # 초. 센서 스크립트가 멈춰 줄이 낡으면 버립니다
# 센서 스크립트가 내는 필드(이름이 서버와 같음)
SENSOR_FIELDS = ["cpu_temp", "cpu_power", "cpu_clock", "mem_temp", "gpu_usage", "gpu_mem_used", "gpu_temp", "gpu_power",
                 "disk_temp", "disk_usage", "disk_wear_percent", "disk_health_ok"]
# ping 대상 주소 → 구간 이름. 필드는 net_<구간>_loss(%), 집 밖 구간은 net_<구간>_latency(ms)도 냅니다
PINGS = {{ dict(pings.values() | zip(pings.keys())) | to_json }}
PING_LATENCY = {{ host_metrics_ping_latency | to_json }}
SLOW_FIELDS = ["cpu_cores", "cpu_threads", "mem_total", "disk_total", "disk_wear_percent", "disk_health_ok"]

def rate(key, value, t):
    # 누적값 → 초당 값. 첫 값이거나 카운터가 줄었으면(재부팅) 비웁니다
    prev = state.get(key)
    state[key] = (value, t)
    if prev == None:
        return None
    dv = value - prev[0]
    dt = (t - prev[1]) / 1e9
    if dt <= 0 or dv < 0:
        return None
    return dv / dt

def slow(field, value, t):
    # 값이 바뀌었거나 마지막으로 낸 뒤 SLOW_PERIOD 가 지났을 때만 냅니다
    key = "slow_" + field
    prev = state.get(key)
    if prev != None and prev[0] == value and t - prev[1] < SLOW_PERIOD:
        return None
    state[key] = (value, t)
    return value

def fields_of(metric):
    n, f, tags, t = metric.name, metric.fields, metric.tags, metric.time
    out = {}
    if n == "cpu":
        out["cpu_usage"] = f.get("usage_active")
    elif n == "system":
        out["system_uptime"] = f.get("uptime")
        out["cpu_cores"] = f.get("n_physical_cpus")
        out["cpu_threads"] = f.get("n_cpus")
    elif n == "mem":
        out["mem_used_percent"] = f.get("used_percent")
        out["mem_total"] = f.get("total")
    elif n == "swap":
        out["swap_used_percent"] = f.get("used_percent")
    elif n == "disk":
        out["disk_used_percent"] = f.get("used_percent")
        out["disk_total"] = f.get("total")
    elif n == "net":
        for k, src in (("net_rx_rate", "bytes_recv"), ("net_tx_rate", "bytes_sent")):
            r = rate(k, f[src], t)                                    # B/s → Mbit/s
            out[k] = r * 8 / 1e6 if r != None else None
    elif n == "ping":
        hop = PINGS.get(tags.get("url", ""))
        if hop != None:
            out["net_" + hop + "_loss"] = f.get("percent_packet_loss")
            if hop in PING_LATENCY:
                out["net_" + hop + "_latency"] = f.get("average_response_ms")   # 전부 잃으면 값이 없습니다
    elif n == "sensors":
        sampled = f.get("sampled_at")
        if sampled == None or t / 1e9 - sampled > SENSORS_MAX_AGE:
            return out
        for k in SENSOR_FIELDS:
            out[k] = f.get(k)
    return out

def apply(metric):
    bucket = metric.time - metric.time % BUCKET
    m = Metric("host")
    m.time = bucket
    n = 0
    for k, v in fields_of(metric).items():
        if v == None:
            continue
        v = float(v)
        if k in SLOW_FIELDS:
            v = slow(k, v, metric.time)
            if v == None:
                continue
        m.fields[k] = v
        n += 1
    return m if n else None
'''

# 같은 10초 칸의 host 필드를 메시지 하나로 합칩니다
[[aggregators.merge]]
  period = "10s"
  grace = "10s"
  drop_original = true

[[outputs.mqtt]]
  servers = ["tcp://{{ host_metrics_broker }}"]
  username = "{{ host_metrics_mqtt_user }}"
  password = "${MQTT_PASSWORD}"       # 서비스 환경 변수(레지스트리 HKLM\SYSTEM\CurrentControlSet\Services\telegraf 의 Environment)
  client_id = "telegraf-{{ host_metrics_name }}"
  topic = "hosts/{{ host_metrics_name }}"
  layout = "non-batch"                # 메트릭 하나 = 메시지 하나
  qos = 1
  data_format = "json"
  json_timestamp_units = "1ms"
```
{: file="templates/host-metrics/windows-telegraf.conf.j2" }
{% endraw %}

</details>

연결 상태는 서버의 `host-availability.py` 를 그대로 쓰되, Windows 에는 systemd 의 `BindsTo` 가 없어 `--follow-service telegraf` 로 Telegraf 서비스 상태를 10초마다 따라가고, 예약 작업은 환경 변수를 줄 수 없어 비밀번호를 `--password-file` 로 읽습니다([Proxmox 호스트 글](/posts/74/)의 스크립트에 들어 있습니다). Python 은 설치기나 PATH 변경 없이 내장형 zip 을 풀어 씁니다.

<details markdown="1">
<summary>playbooks/windows-host-metrics.yml 전문</summary>

{% raw %}
```yaml
# 사용자 Windows PC(inventory 의 windows_pcs)의 CPU·메모리·디스크·네트워크·온도·전력·GPU 값을 Proxmox 호스트(playbooks/host-metrics.yml)와
# 같은 방식으로 MQTT 에 발행합니다: 10초마다 JSON 메시지 하나를 hosts/<host_metrics_name> 에, 연결 상태는 hosts/<기기>/availability 에.
# Home Assistant 발견 설정을 만들고, DB 기록은 엣지 Telegraf(k8s-gitops iot/edge/telegraf)가 같은 토픽을 받아 readings 에 넣습니다.
#   - Telegraf for Windows(서버·엣지와 같은 버전) 서비스: CPU 사용률·메모리·디스크 용량·네트워크·ping 은 내장 입력
#   - scripts/windows-sensors.ps1(예약 작업, SYSTEM 상주): LibreHardwareMonitor + PawnIO 드라이버로 CPU 온도·전력·클럭,
#     메모리·디스크 온도, 디스크 활동률·수명, GPU 값을 파일로 내고 Telegraf 가 읽습니다(리눅스의 hwmon·RAPL 대신)
#   - scripts/host-availability.py(예약 작업, 내장형 Python): Telegraf 서비스 상태를 따라 online/offline 을 알리고, PC 가 꺼지면
#     브로커가 Last Will 로 offline 을 냅니다(서버의 systemd BindsTo 대신 --follow-service)
#   - 끝에서 scripts/host-metrics-discovery.py 가 받은 필드마다 HA 센서를 맞춥니다(PC 의 내장형 Python 으로 실행)
# 접속은 OpenSSH(기본 셸 PowerShell). 설치 파일은 제어 PC 캐시(windows_host_metrics_cache)에 받아 sha256 을 확인한 뒤 복사합니다.
#   MQTT_PASSWORD=$(. ~/.config/iot/secrets.env; echo "$MQTT_DEVICES") ansible-playbook playbooks/windows-host-metrics.yml [--limit pc-k8-plus]
# 꺼져 있는 PC(조립 PC 는 평소 꺼 둠)는 접속 실패로 건너뜁니다. 켜진 뒤 --limit 으로 다시 실행합니다.
---
- name: Windows PC Telegraf
  hosts: windows_pcs
  gather_facts: false
  vars:
    mqtt_password: "{{ lookup('env', 'MQTT_PASSWORD') }}"
    whm_dir: "{{ windows_host_metrics_dir }}"
    whm_data: "{{ windows_host_metrics_data }}"
    whm_files: "{{ windows_host_metrics_files }}"
    whm_installers: "{{ windows_host_metrics_data }}\\installers"
    python_exe: "{{ windows_host_metrics_dir }}\\python\\python.exe"
  pre_tasks:
    - name: 비밀번호 확인
      ansible.builtin.assert:
        that: mqtt_password | length > 0
        fail_msg: MQTT_PASSWORD 환경변수가 비어 있습니다(브로커 계정 {{ host_metrics_mqtt_user }} 의 비밀번호)
      run_once: true
      delegate_to: localhost
    - name: 설치 파일 받기 (제어 PC 캐시, sha256 확인)
      ansible.builtin.get_url:
        url: "{{ item.value.url }}"
        dest: "{{ windows_host_metrics_cache }}/{{ item.value.name }}"
        checksum: "sha256:{{ item.value.sha256 }}"
        mode: "0644"
      loop: "{{ whm_files | dict2items }}"
      loop_control:
        label: "{{ item.value.name }}"
      run_once: true
      delegate_to: localhost
  tasks:
    - name: 폴더
      ansible.windows.win_file:
        path: "{{ item }}"
        state: directory
      loop:
        - "{{ whm_dir }}"
        - "{{ whm_data }}"
        - "{{ whm_data }}\\buffer"
        - "{{ whm_installers }}"
        - "{{ windows_host_metrics_lhm_dir }}"
    - name: 데이터 폴더는 SYSTEM·Administrators 만 (비밀번호 파일이 있음)
      ansible.windows.win_shell: |
        $acl = Get-Acl '{{ whm_data }}'
        if (-not $acl.AreAccessRulesProtected) {
          icacls '{{ whm_data }}' /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
          'CHANGED'
        }
      register: r
      changed_when: "'CHANGED' in r.stdout"
    - name: 설치 파일 복사
      ansible.windows.win_copy:
        src: "{{ windows_host_metrics_cache }}/{{ item.value.name }}"
        dest: "{{ whm_installers }}\\{{ item.value.name }}"
      loop: "{{ whm_files | dict2items }}"
      loop_control:
        label: "{{ item.value.name }}"

    # ---- PawnIO(드라이버)와 LibreHardwareMonitor
    - name: PawnIO 드라이버 (같은 버전이 없을 때만, 다른 버전은 지우고 다시)
      ansible.windows.win_shell: |
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO'
        $have = (Get-ItemProperty $key -ErrorAction SilentlyContinue).DisplayVersion
        if ($have -eq '{{ whm_files.pawnio.version }}') { exit 0 }
        $setup = '{{ whm_installers }}\{{ whm_files.pawnio.name }}'
        if ($have) { Start-Process $setup -ArgumentList '-uninstall', '-silent' -Wait }
        $p = Start-Process $setup -ArgumentList '-install', '-silent' -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "PawnIO 설치 실패: $($p.ExitCode)" }
        'CHANGED'
      register: r
      changed_when: "'CHANGED' in r.stdout"
    - name: LibreHardwareMonitor (zip 이 바뀌었을 때만 풀기)
      ansible.windows.win_shell: |
        $marker = '{{ windows_host_metrics_lhm_dir }}\.installed'
        if ((Test-Path $marker) -and (Get-Content $marker) -eq '{{ whm_files.lhm.sha256 }}') { exit 0 }
        Stop-ScheduledTask -TaskName host-sensors -ErrorAction SilentlyContinue
        Expand-Archive -Force '{{ whm_installers }}\{{ whm_files.lhm.name }}' -DestinationPath '{{ windows_host_metrics_lhm_dir }}'
        Set-Content -Path $marker -Value '{{ whm_files.lhm.sha256 }}'
        'CHANGED'
      register: r
      changed_when: "'CHANGED' in r.stdout"
      notify: host-sensors 재시작
    - name: 센서 스크립트
      ansible.windows.win_copy:
        src: ../scripts/windows-sensors.ps1
        dest: "{{ whm_dir }}\\windows-sensors.ps1"
      notify: host-sensors 재시작
    - name: 센서 예약 작업 (부팅 때, SYSTEM, 죽으면 1분 뒤 다시)
      community.windows.win_scheduled_task:
        name: host-sensors
        description: CPU·메모리·GPU·디스크 센서를 LibreHardwareMonitor 로 읽어 Telegraf 에 넘김(proxmox-ansible windows-host-metrics.yml)
        actions:
          - path: powershell.exe
            arguments: >-
              -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{{ whm_dir }}\windows-sensors.ps1"
              -LibDir "{{ windows_host_metrics_lhm_dir }}" -Out "{{ whm_data }}\sensors.influx"
        triggers:
          - type: boot
        username: SYSTEM
        run_level: highest
        execution_time_limit: PT0S
        restart_count: 999
        restart_interval: PT1M
        disallow_start_if_on_batteries: false
        stop_if_going_on_batteries: false
        state: present
      notify: host-sensors 재시작

    # ---- Telegraf
    - name: Telegraf (버전이 다를 때만 바꿔 넣기)
      ansible.windows.win_shell: |
        $exe = '{{ whm_dir }}\telegraf.exe'
        if ((Test-Path $exe) -and ((& $exe --version) -match 'Telegraf {{ windows_host_metrics_telegraf_version }} ')) { exit 0 }
        Stop-Service telegraf -ErrorAction SilentlyContinue
        $tmp = '{{ whm_installers }}\telegraf'
        Expand-Archive -Force '{{ whm_installers }}\{{ whm_files.telegraf.name }}' -DestinationPath $tmp
        Copy-Item -Force (Get-ChildItem $tmp -Recurse -Filter telegraf.exe | Select-Object -First 1).FullName $exe
        Remove-Item -Recurse -Force $tmp
        'CHANGED'
      register: r
      changed_when: "'CHANGED' in r.stdout"
      notify: telegraf 재시작
    - name: Telegraf 설정
      ansible.windows.win_template:
        src: ../templates/host-metrics/windows-telegraf.conf.j2
        dest: "{{ whm_dir }}\\telegraf.conf"
      notify: telegraf 재시작
    - name: Telegraf 설정 검사
      ansible.windows.win_command: '"{{ whm_dir }}\telegraf.exe" --config "{{ whm_dir }}\telegraf.conf" --test --test-wait 0 --quiet --input-filter system'
      changed_when: false
    - name: Telegraf 서비스 등록 (없을 때만)
      ansible.windows.win_shell: |
        if (Get-Service telegraf -ErrorAction SilentlyContinue) { exit 0 }
        & '{{ whm_dir }}\telegraf.exe' --service install --service-name telegraf --config '{{ whm_dir }}\telegraf.conf'
        'CHANGED'
      register: r
      changed_when: "'CHANGED' in r.stdout"
    - name: Telegraf 서비스 비밀번호 (서비스 환경변수)
      ansible.windows.win_regedit:
        path: HKLM:\SYSTEM\CurrentControlSet\Services\telegraf
        name: Environment
        type: multistring
        data: ["MQTT_PASSWORD={{ mqtt_password }}"]
      no_log: true
      notify: telegraf 재시작
    - name: Telegraf 서비스 (자동 시작, 죽으면 다시)
      ansible.windows.win_service:
        name: telegraf
        start_mode: auto
        state: started
        failure_actions:
          - type: restart
            delay_ms: 30000
        failure_reset_period_sec: 86400

    # ---- 연결 상태(내장형 Python)
    - name: 내장형 Python (zip 이 바뀌었을 때만)
      ansible.windows.win_shell: |
        $py = '{{ whm_dir }}\python'
        $marker = "$py\.installed"
        $want = '{{ whm_files.python.sha256 }} {{ whm_files.paho.sha256 }}'
        if ((Test-Path $marker) -and (Get-Content $marker) -eq $want) { exit 0 }
        Stop-ScheduledTask -TaskName host-availability -ErrorAction SilentlyContinue
        if (Test-Path $py) { Remove-Item -Recurse -Force $py }
        Expand-Archive -Force '{{ whm_installers }}\{{ whm_files.python.name }}' -DestinationPath $py
        # 휠은 zip 이다. 순수 Python 이라 Lib\site-packages 에 풀기만 하면 된다
        $site = "$py\Lib\site-packages"
        New-Item -ItemType Directory -Force -Path $site | Out-Null
        Copy-Item '{{ whm_installers }}\{{ whm_files.paho.name }}' "$env:TEMP\paho.zip" -Force
        Expand-Archive -Force "$env:TEMP\paho.zip" -DestinationPath $site
        Remove-Item "$env:TEMP\paho.zip"
        # 내장형은 ._pth 에 적힌 경로만 본다
        $pth = Get-ChildItem $py -Filter 'python*._pth' | Select-Object -First 1
        Add-Content -Path $pth.FullName -Value 'Lib\site-packages'
        Set-Content -Path $marker -Value $want
        'CHANGED'
      register: r
      changed_when: "'CHANGED' in r.stdout"
      notify: host-availability 재시작
    - name: 연결 상태·발견 설정 스크립트
      ansible.windows.win_copy:
        src: "../scripts/{{ item }}"
        dest: "{{ whm_dir }}\\{{ item }}"
      loop: [host-availability.py, host-metrics-discovery.py]
      notify: host-availability 재시작
    - name: 브로커 비밀번호 파일 (연결 상태 예약 작업용)
      ansible.windows.win_copy:
        content: "{{ mqtt_password }}"
        dest: "{{ whm_data }}\\mqtt-password"
      no_log: true
      notify: host-availability 재시작
    - name: 연결 상태 예약 작업 (부팅 때, SYSTEM, Telegraf 서비스를 따라감)
      community.windows.win_scheduled_task:
        name: host-availability
        description: hosts/{{ host_metrics_name }}/availability 에 연결 상태 알림(proxmox-ansible windows-host-metrics.yml)
        actions:
          - path: "{{ python_exe }}"
            arguments: >-
              "{{ whm_dir }}\host-availability.py" --broker {{ host_metrics_broker }} --user {{ host_metrics_mqtt_user }}
              --device {{ host_metrics_name }} --password-file "{{ whm_data }}\mqtt-password" --follow-service telegraf
        triggers:
          - type: boot
        username: SYSTEM
        run_level: highest
        execution_time_limit: PT0S
        restart_count: 999
        restart_interval: PT1M
        disallow_start_if_on_batteries: false
        stop_if_going_on_batteries: false
        state: present
      notify: host-availability 재시작
    - name: 예약 작업 실행 중인지 (설치 직후·재부팅 전)
      ansible.windows.win_shell: |
        foreach ($t in 'host-sensors', 'host-availability') {
          if ((Get-ScheduledTask -TaskName $t).State -ne 'Running') { Start-ScheduledTask -TaskName $t; "CHANGED $t" }
        }
      register: r
      changed_when: "'CHANGED' in r.stdout"

    - name: 기기 정보 (HA 기기 제조사·모델, 실물 ID)
      ansible.windows.win_shell: |
        $b = Get-CimInstance Win32_BaseBoard
        $p = Get-CimInstance Win32_ComputerSystemProduct
        # 메인보드 시리얼이 비었거나 "Default string" 이면 SMBIOS UUID 를 실물 ID 로 쓴다
        $serial = if ($b.SerialNumber -and $b.SerialNumber -notmatch 'Default|To be filled|^0+$') { $b.SerialNumber.Trim() } else { $p.UUID }
        [ordered]@{ manufacturer = "$($b.Manufacturer)".Trim(); model = "$($b.Product)".Trim(); serial = "$serial" } | ConvertTo-Json -Compress
      register: board
      changed_when: false
  handlers:
    - name: telegraf 재시작
      ansible.windows.win_service:
        name: telegraf
        state: restarted
    - name: host-sensors 재시작
      ansible.windows.win_shell: |
        Stop-ScheduledTask -TaskName host-sensors -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName host-sensors
    - name: host-availability 재시작
      ansible.windows.win_shell: |
        Stop-ScheduledTask -TaskName host-availability -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName host-availability
  post_tasks:
    - name: 재시작 반영
      ansible.builtin.meta: flush_handlers
    # 75초 동안 메시지를 받아 필드마다 센서를 만들고, 없어진 필드의 센서는 지웁니다. 내용이 같으면 발행하지 않습니다(서버와 같음)
    - name: Home Assistant 발견 설정
      ansible.windows.win_command:
        argv:
          - "{{ python_exe }}"
          - "{{ whm_dir }}\\host-metrics-discovery.py"
          - --broker
          - "{{ host_metrics_broker }}"
          - --user
          - "{{ host_metrics_mqtt_user }}"
          - --device
          - "{{ host_metrics_name }}"
          - --manufacturer
          - "{{ (board.stdout | from_json).manufacturer }}"
          - --model
          - "{{ (board.stdout | from_json).model }}"
          - --serial
          - "{{ (board.stdout | from_json).serial }}"
      environment:
        MQTT_PASSWORD: "{{ mqtt_password }}"
      register: discovery
      changed_when: (discovery.stdout | from_json).changed > 0
    # 느린 값(사양·수명)은 발견 설정보다 먼저 발행되면 HA 가 다음 1시간 주기까지 unknown 으로 둡니다(서버와 같음)
    - name: 새 센서에 느린 값 채우기 (Telegraf 재시작)
      ansible.windows.win_service:
        name: telegraf
        state: restarted
      when: (discovery.stdout | from_json).published | length > 0
```
{: file="playbooks/windows-host-metrics.yml" }
{% endraw %}

</details>

- **확인:** `ansible-playbook --syntax-check playbooks/windows-host-metrics.yml` 이 오류 없이 끝납니다.

## 4. 플레이북 실행

```bash
# 실행 (브로커 비밀번호는 환경 변수로)
MQTT_PASSWORD='[MQTT_PASSWORD]' ansible-playbook playbooks/windows-host-metrics.yml

# 한 번 더 실행해 바뀐 것이 없는지 확인
MQTT_PASSWORD='[MQTT_PASSWORD]' ansible-playbook playbooks/windows-host-metrics.yml
```

- **확인:**
  - 두 번째 실행의 `PLAY RECAP` 이 `changed=0` 입니다.
  - `mosquitto_sub -t 'hosts/[기기 이름]' -C 1` 에 `cpu_temp`·`cpu_power`·`mem_temp`·`disk_temp`·`gpu_usage` 같은 필드가 서버와 같은 이름으로 나옵니다.
  - `hosts/[기기 이름]/availability` 가 `{"state": "online"}` 이고, PC 를 끄면 1분 안에 `offline` 이 됩니다.
  - Home Assistant 에 `sensor.[기기 이름]_cpu_temp` 같은 센서가 생기고, DB `readings` 에 `device = 'host'` 행이 서버와 같은 단위로 쌓입니다.

## 트러블슈팅

<details markdown="1">
<summary>디스크 용량(<code>disk_used_percent</code>)이 나오지 않음</summary>

- **원인:** Telegraf 는 Windows 에서 `mount_points` 를 `C:` 로 비교하고, 출력의 `path` 태그에는 `\C:` 로 적습니다. 태그 값을 그대로 넣으면 걸러져 아무것도 나오지 않습니다.
- **해결:** `host_metrics_mounts: ['C:']` 로 둡니다.

</details>

<details markdown="1">
<summary>LibreHardwareMonitor 를 불러올 때 <code>Process is terminated due to StackOverflowException</code></summary>

- **원인:** 의존 DLL 을 찾으려고 PowerShell 스크립트 블록을 `AssemblyResolve` 처리기로 걸면 처리기 안에서 다시 어셈블리를 찾느라 재귀합니다.
- **해결:** 처리기를 걸지 않고 `[Reflection.Assembly]::LoadFrom()` 으로 불러옵니다. `LoadFrom` 은 같은 폴더의 의존 DLL 을 알아서 찾습니다.

</details>

<details markdown="1">
<summary>ping 구간 손실이 늘 100%</summary>

- **원인:** 그 PC 에서는 그 대상으로 가는 길이 없습니다(예: Tailscale 이 없는 PC 에서 Tailscale 주소).
- **해결:** 인벤토리의 그 PC 에 `host_metrics_ping_skip: [구간 이름]` 을 둡니다. 다음 실행에서 발견 설정이 그 센서를 지웁니다.

</details>

## 마무리

Windows PC 의 부하·온도·전력을 Proxmox 호스트와 같은 토픽·필드 이름·발견 설정·연결 상태로 발행해, Home Assistant 센서와 TimescaleDB 기록, 전력 플러그와 맞춰 보는 쿼리를 서버와 똑같이 쓰는 구성을 완성했습니다. PC 를 더할 때는 인벤토리에 넣고 플레이북을 `--limit` 으로 다시 실행합니다. 꺼져 있는 PC 는 접속 실패로 건너뛰므로 켜진 뒤 다시 실행합니다.

## 참고 자료

- [Telegraf: Windows](https://docs.influxdata.com/telegraf/v1/install/#windows)
- [Telegraf inputs.file](https://github.com/influxdata/telegraf/blob/master/plugins/inputs/file/README.md)
- [Telegraf inputs.ping](https://github.com/influxdata/telegraf/blob/master/plugins/inputs/ping/README.md)
- [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)
- [PawnIO](https://github.com/namazso/PawnIO.Setup)
- [Python: Using Python on Windows — The embeddable package](https://docs.python.org/3/using/windows.html#the-embeddable-package)
- [Ansible: Windows Remote Management over SSH](https://docs.ansible.com/ansible/latest/os_guide/windows_ssh.html)
