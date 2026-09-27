---
layout: post
title: Proxmox 호스트의 CPU·GPU·메모리 부하를 Telegraf로 MQTT에 발행해 Home Assistant와 TimescaleDB에서 소비전력과 함께 보는 방법
description: VM·CT 안에서는 보이지 않는 Proxmox 호스트 전체의 CPU·메모리·디스크·네트워크·온도·전력·iGPU 값을 호스트의 Telegraf 가 10초마다 MQTT 로 발행하고, Home Assistant 에는 발견 설정으로 센서를 만들고 TimescaleDB 에는 전력 플러그와 같은 제품 키로 기록해 부하와 벽 전력을 맞춰 보는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, ansible, telegraf, mqtt, home-assistant, timescaledb, iot, homelab]
permalink: /posts/74/
---

Proxmox 호스트에 **Telegraf** 를 설치해 호스트 전체(VM·CT 를 합한 값)의 CPU·메모리·디스크·네트워크·온도·전력·iGPU 값을 10초마다 JSON 메시지 하나로 엣지 브로커의 `hosts/[기기 이름]` 에 발행합니다. 같은 호스트가 필드마다 **MQTT 발견 설정**을 내므로 Home Assistant 에 센서가 자동으로 생기고, 엣지 Telegraf 가 같은 토픽을 받아 `readings` 테이블에 넣습니다. 기기 이름의 기준 칸을 그 서버가 꽂힌 전력 플러그와 같은 제품 키로 두어, DB 에서 "CPU 사용률이 얼마일 때 벽 전력이 얼마인지" 를 `anchor` 하나로 맞춰 봅니다. 설치는 [내부망 DNS 글](/posts/41/)에서 만든 Ansible 저장소에 플레이북 하나를 더해 모든 Proxmox 노드에 똑같이 합니다.

1. 기기 이름 정하기
2. 변수와 인벤토리
3. 템플릿과 발견 설정 스크립트
4. 플레이북 실행
5. Home Assistant 영역 배정
6. 엣지 Telegraf 에 호스트 입력 추가
7. 부하와 소비전력 맞춰 보기

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Proxmox VE | `9.2` (Debian 13, 두 노드) |
| 서버 | Minisforum MS-A2(Ryzen 9 9955HX, Radeon 610M), GMKtec NucBox K12(Ryzen 7 H 255, Radeon 780M) |
| Ansible | `13.1` (ansible-core `2.20`) |
| telegraf | `1.40.1` (호스트·엣지 같은 버전) |
| Home Assistant | `2026.9.3` |
| timescale/timescaledb-ha | `pg17.11-ts2.30.1` |
| 작성 기준일 | `2026-09-28` |

다음 항목이 준비되어 있어야 합니다.

- Ansible 저장소(`ansible.cfg`, `inventory.yml` 의 `proxmox` 그룹, `group_vars/all.yml`)와 Proxmox 호스트의 root SSH 접속 ([Proxmox에 Ansible로 내부망 DNS 컨테이너 만드는 방법](/posts/41/)의 2단계)
- 엣지 Mosquitto·Telegraf 와 지역·허브 TimescaleDB, 브로커 계정 `devices` 의 비밀번호 ([엣지 Mosquitto와 Telegraf 디스크 버퍼로 중앙 TimescaleDB에 유실 없이 IoT 데이터 모으는 방법](/posts/43/))
- 지역 Home Assistant 의 MQTT 통합과 `ha-registry.py` ([엣지 클러스터에 Home Assistant와 Matter 서버 배포하고 API로 통합 설정하는 방법](/posts/48/))
- 서버마다 전력 측정 플러그(선택). 이름이 `<방>-plug-<제품 키>` 이면 7단계에서 부하와 벽 전력을 맞춰 볼 수 있습니다

## 1. 기기 이름 정하기

호스트 값도 다른 기기처럼 `<방>-<종류>-<기준>` 이름으로 들어갑니다. 종류는 `host`, 기준은 그 서버가 꽂힌 플러그의 기준 칸(제품 키)과 같게 둡니다.

| Proxmox 노드 | 플러그 이름 | 호스트 기기 이름 |
| :--- | :--- | :--- |
| `pve01` | `bedroom2-plug-server_ms_a2_1` | `bedroom2-host-server_ms_a2_1` |
| `pve02` | `bedroom2-plug-server_k12_1` | `bedroom2-host-server_k12_1` |

엣지 Telegraf 가 이름을 나눠 `room` 은 `bedroom2`, `device` 는 `host`, `anchor` 는 `server_ms_a2_1` 로 넣으므로 플러그 행과 `anchor` 가 같습니다. 이름에 `/` 는 쓰지 않습니다(토픽이 두 단계가 되어 수집되지 않음).

## 2. 변수와 인벤토리

호스트마다 다른 값은 인벤토리에, 공통 값은 `group_vars/all.yml` 에 둡니다. 브로커 주소는 이름 대신 엣지 서비스 VIP 를 씁니다. Proxmox 호스트의 DNS 는 외부(1.1.1.1)라 내부 이름(`iot-dj.[DOMAIN]`)이 풀리지 않습니다.

{% raw %}
```yaml
# ---- host-metrics: Proxmox 호스트 자체의 부하·온도·전력을 MQTT 로 발행 (playbooks/host-metrics.yml) ----
# 호스트 전체(VM·CT 합)의 값을 Telegraf 가 10초마다 JSON 메시지 하나로 hosts/<기기 이름> 에 냅니다. 기기 이름은 inventory 의 host_metrics_name.
# 지역 Home Assistant 는 발견 설정으로 센서를 만들고, 엣지 Telegraf(k8s-gitops iot/edge/telegraf)는 DB readings 에 넣습니다.
host_metrics_telegraf_version: 1.40.1-1       # 엣지 Telegraf(k8s-gitops iot/edge/telegraf) 와 같은 버전. apt-cache madison telegraf
host_metrics_broker: "{{ k8s_clusters.[SITE].service_vip }}:1883"   # 엣지 Mosquitto(서비스 VIP). Proxmox 호스트는 내부망 DNS 를 쓰지 않아(1.1.1.1) 이름 대신 주소
host_metrics_mqtt_user: devices               # LAN 기기용 브로커 계정. 비밀번호는 실행할 때 MQTT_PASSWORD 환경변수로 넘깁니다(~/.config/iot/secrets.env 의 MQTT_DEVICES)
host_metrics_mounts: [/, /boot/efi]           # 용량을 잴 마운트. 호스트마다 다르면 inventory 에서 덮어씁니다
host_metrics_disks: [nvme0n1]                 # IO 를 잴 디스크(VM 디스크인 dm-* 는 뺌)
host_metrics_interfaces: [nic0, vmbr0, tailscale0]   # 트래픽을 잴 인터페이스(VM 탭·veth 는 뺌)
host_metrics_lvm_volumes: [data]              # 사용률을 잴 LVM 논리 볼륨(thin 풀)
host_metrics_drm_card: card0                  # iGPU 의 /sys/class/drm/<카드>
host_metrics_gpu_ppt_scale: 0.000001          # amdgpu PPT(power1_average, 없으면 power1_input) → W. 커널 문서대로 µW. 다르게 나오는 칩은 inventory 에서 덮어씁니다
```
{: file="group_vars/all.yml (추가 부분)" }
{% endraw %}

```yaml
    proxmox:
      hosts:
        pve01:
          ansible_host: [PVE01_IP]
          ansible_user: root
          host_metrics_name: bedroom2-host-server_ms_a2_1   # <방>-host-<제품 키>. 제품 키는 전력 플러그 이름의 기준 칸과 같습니다
          host_metrics_gpu_ppt_scale: 0.001   # 610M(Granite Ridge)의 PPT 는 1 W 단위 mW 로 나옵니다(GPU 부하 12000, 유휴 5000~6000)
        pve02:
          ansible_host: [PVE02_IP]
          ansible_user: root
          host_metrics_name: bedroom2-host-server_k12_1
```
{: file="inventory.yml (proxmox 그룹 부분)" }

`host_metrics_gpu_ppt_scale` 은 amdgpu 가 알리는 PPT 를 W 로 바꾸는 배율입니다. 커널 문서의 단위는 µW 지만 610M(Granite Ridge)은 1 W 단위의 mW 로 나와 따로 줍니다. 새 서버는 GPU 에 부하를 걸고 `power1_input` 이 RAPL 패키지 전력과 함께 움직이는 크기인지 보고 정합니다.

- **확인:** `ansible-inventory --host pve01` 에 `host_metrics_name` 과 `host_metrics_broker` 가 보이고, 브로커는 `[EDGE_SERVICE_VIP]:1883` 으로 풀립니다.

## 3. 템플릿과 발견 설정 스크립트

파일 네 개를 저장소에 둡니다. 모두 여러 번 실행해도 결과가 같습니다.

| 파일 | 하는 일 |
| :--- | :--- |
| `templates/host-metrics/telegraf.conf.j2` | 입력(cpu, system, processes, kernel, mem, swap, disk, diskio, net, temp, lvm, smart, exec) → starlark 로 평탄한 필드 이름과 초당 값 → merge 로 10초에 메시지 하나 → MQTT |
| `templates/host-metrics/host-sysfs.sh.j2` | 기본 입력이 못 읽는 값: 코어 클럭 평균·최대, RAPL 누적 에너지, iGPU 사용률·VRAM·GTT·클럭·PPT·전압 |
| `scripts/host-metrics-discovery.py` | 실제 메시지를 받아 필드마다 Home Assistant 발견 설정을 맞추고, 없어진 필드의 센서는 지웁니다 |
| `playbooks/host-metrics.yml` | 설치, 권한, 설정 배포, 발견 설정 |

필드 이름은 `<분류>_<대상>_<값>` 입니다. 누적 카운터(바이트·횟수·에너지)는 호스트의 starlark 가 이전 값과의 차로 초당 값(`_rate`, W)을 만들어 보냅니다. 코어별 사용률·클럭은 코어 수만큼 행이 늘어 보내지 않고 전체 사용률과 평균·최대 클럭만 둡니다.

| 분류 | 필드 예 |
| :--- | :--- |
| CPU | `cpu_usage`, `cpu_user`, `cpu_system`, `cpu_guest`(VM 이 쓴 몫), `cpu_iowait`, `cpu_clock_avg`, `cpu_clock_max`, `cpu_power`(RAPL 패키지), `cpu_core_power` |
| 부하 | `load1`, `load5`, `load15`, `uptime`, `processes_total`, `processes_zombies`, `kernel_context_switches_rate` |
| 메모리 | `mem_total`, `mem_used`, `mem_available`, `mem_cached`, `mem_used_percent`, `swap_used_percent`, `swap_in_rate` |
| 디스크 | `disk_root_used_percent`, `lvm_data_used_percent`, `diskio_nvme0n1_write_rate`, `diskio_nvme0n1_busy_percent`, `smart_nvme0_wear_percent`, `smart_nvme0_written` |
| 네트워크 | `net_nic0_rx_rate`, `net_vmbr0_tx_rate`, `net_nic0_errors_rate`, `net_nic0_link_speed` |
| 온도 | `temp_cpu_tctl`, `temp_cpu_ccd1`, `temp_gpu`, `temp_nvme0`, `temp_ram_1`, `temp_nic` |
| GPU | `gpu_usage`, `gpu_video_usage`, `gpu_clock`, `gpu_mem_clock`, `gpu_power`, `gpu_vram_used_percent`, `gpu_gtt_used` |

<details markdown="1">
<summary>templates/host-metrics/telegraf.conf.j2 전문</summary>

{% raw %}
```toml
# 호스트 Telegraf. proxmox-ansible playbooks/host-metrics.yml 이 templates/host-metrics/telegraf.conf.j2 에서 만듭니다(여기서 고치지 않습니다).
# 호스트 전체(VM·CT 합)의 값을 10초마다 모아 JSON 메시지 하나로 hosts/{{ host_metrics_name }} 에 발행합니다.
#   {"name": "host", "fields": {"cpu_usage": 3.9, "mem_used": 41422155776, ...}, "tags": {}, "timestamp": <ms>}
# 필드 이름은 <분류>_<대상>_<값> 이고 누적 카운터(바이트·횟수·에너지)는 아래 starlark 가 초당 값(_rate, W)으로 바꿉니다.
# Home Assistant 센서는 host-metrics-discovery.py 가 이 필드들로 만들고, 엣지 Telegraf 가 같은 토픽을 받아 DB readings 에 넣습니다.
[agent]
  interval = "10s"
  round_interval = true
  flush_interval = "10s"
  metric_buffer_limit = 50000         # 브로커가 안 닿는 동안 쌓을 메시지 수(10초에 하나라 약 5일)
  buffer_strategy = "disk"            # 재시작해도 못 보낸 메시지가 남습니다
  buffer_directory = "/var/lib/telegraf/buffer"
  omit_hostname = true                # 기기는 토픽이 가리킵니다
  skip_processors_after_aggregators = true

[[inputs.cpu]]
  percpu = false
  totalcpu = true
  report_active = true                # usage_active = 100 - idle

[[inputs.system]]                     # load, 코어 수, 가동 시간

[[inputs.processes]]

[[inputs.kernel]]                     # 컨텍스트 스위치·인터럽트·fork 누적 횟수

[[inputs.mem]]

[[inputs.swap]]

[[inputs.disk]]
  mount_points = {{ host_metrics_mounts | to_json }}

[[inputs.diskio]]
  devices = {{ host_metrics_disks | to_json }}
  skip_serial_number = true

[[inputs.net]]
  interfaces = {{ host_metrics_interfaces | to_json }}

[[inputs.temp]]                       # hwmon 의 모든 온도(CPU, GPU, NVMe, 메모리 DIMM, NIC …)
  add_device_tag = true               # 같은 칩이 둘인 메모리(spd5118)를 주소로 나눕니다

[[inputs.lvm]]
  use_sudo = true
  [inputs.lvm.tagpass]
    name = {{ host_metrics_lvm_volumes | to_json }}

[[inputs.smart]]
  use_sudo = true
  attributes = true                   # 누적 읽기·쓰기량(Data_Units_*)은 속성에만 있습니다

[[inputs.exec]]
  commands = [["/usr/local/lib/telegraf-host-sysfs.sh"]]   # CPU 클럭, RAPL 전력, iGPU (templates/host-metrics/host-sysfs.sh.j2)
  data_format = "influx"
  timeout = "5s"

# 입력마다 다른 측정값·태그를 host 측정값 하나의 평탄한 필드로 바꿉니다. 시각은 10초 단위로 내려 아래 merge 가 한 메시지로 묶게 합니다.
[[processors.starlark]]
  source = '''
BUCKET = 10 * 1000 * 1000 * 1000
KEEP = {
    "cpu": {"usage_active": "cpu_usage", "usage_user": "cpu_user", "usage_system": "cpu_system", "usage_guest": "cpu_guest",
            "usage_iowait": "cpu_iowait"},
    "system": {"load1": "load1", "load5": "load5", "load15": "load15", "n_cpus": "cpu_threads", "n_physical_cpus": "cpu_cores", "uptime": "uptime"},
    "processes": {"total": "processes_total", "running": "processes_running", "sleeping": "processes_sleeping", "blocked": "processes_blocked",
                  "zombies": "processes_zombies", "total_threads": "processes_threads"},
    "mem": {"total": "mem_total", "used": "mem_used", "available": "mem_available", "free": "mem_free", "cached": "mem_cached",
            "buffered": "mem_buffered", "shared": "mem_shared", "slab": "mem_slab", "committed_as": "mem_committed", "used_percent": "mem_used_percent"},
    "swap": {"total": "swap_total", "used": "swap_used", "used_percent": "swap_used_percent"},
    "smart_device": {"percentage_used": "wear_percent", "available_spare": "available_spare", "media_errors": "media_errors",
                     "error_log_entries": "error_log_entries", "critical_warning": "critical_warning", "unsafe_shutdowns": "unsafe_shutdowns",
                     "power_on_hours": "power_on_hours", "power_cycle_count": "power_cycles", "health_ok": "health_ok"},
    "sysfs": {"cpu_clock_avg": "cpu_clock_avg", "cpu_clock_max": "cpu_clock_max", "gpu_busy": "gpu_usage", "gpu_vcn_busy": "gpu_video_usage",
              "gpu_vram_total": "gpu_vram_total", "gpu_vram_used": "gpu_vram_used", "gpu_gtt_total": "gpu_gtt_total", "gpu_gtt_used": "gpu_gtt_used",
              "gpu_sclk": "gpu_clock", "gpu_mclk": "gpu_mem_clock", "gpu_ppt": "gpu_power", "gpu_vddgfx_mv": "gpu_vddgfx", "gpu_vddnb_mv": "gpu_vddnb"},
}
TEMP_CHIPS = {"k10temp": "cpu", "amdgpu": "gpu", "r8169": "nic", "mt7921": "wifi", "acpitz": "acpi"}

def slug(s):
    out = ""
    for c in s.lower().elems():
        out += c if c.isalnum() else "_"
    return out.strip("_")

def rate(key, value, t, wrap=0):
    # 누적값 → 초당 값. 첫 값이거나 카운터가 줄었으면(재부팅) 비웁니다. wrap 은 되돌아가는 상한(RAPL)
    prev = state.get(key)
    state[key] = (value, t)
    if prev == None:
        return None
    dv = value - prev[0]
    dt = (t - prev[1]) / 1e9
    if dv < 0 and wrap > 0:
        dv += wrap
    if dt <= 0 or dv < 0:
        return None
    return dv / dt

def temp_name(sensor, device):
    chip, _, label = sensor.partition("_")
    if chip == "nvme":                           # nvme_composite, nvme_sensor_1 (device nvme0)
        return "temp_" + device + ("" if label == "composite" else "_" + label.replace("_", ""))
    if chip == "spd5118":                        # 메모리 DIMM. 주소 0-0050, 0-0051 → 1, 2
        return "temp_ram_" + str(int(device.split("-")[-1], 16) - 0x50 + 1)
    if chip == "amdgpu" and label == "edge":
        return "temp_gpu"
    if chip in TEMP_CHIPS:
        return "temp_" + TEMP_CHIPS[chip] + ("_" + slug(label.replace("tccd", "ccd")) if label and chip in ("k10temp", "amdgpu") else "")
    return "temp_" + slug(sensor)

def fields_of(metric):
    n, f, tags, t = metric.name, metric.fields, metric.tags, metric.time
    out = {}
    for k, name in KEEP.get(n, {}).items():
        if k in f:
            out[name] = f[k]
    if n == "cpu":
        out["cpu_irq"] = f.get("usage_irq", 0) + f.get("usage_softirq", 0)
    elif n == "kernel":
        for k, name in (("context_switches", "context_switches"), ("interrupts", "interrupts"), ("processes_forked", "forks")):
            out["kernel_" + name + "_rate"] = rate("kernel_" + k, f[k], t)
    elif n == "swap" and "in" in f:
        out["swap_in_rate"] = rate("swap_in", f["in"], t)
        out["swap_out_rate"] = rate("swap_out", f["out"], t)
    elif n == "disk":
        p = "disk_" + (slug(tags["path"]) or "root") + "_"
        for k in ("total", "used", "free", "used_percent"):
            out[p + k] = f[k]
        if f.get("inodes_total", 0) > 0:
            out[p + "inodes_used_percent"] = f["inodes_used_percent"]
    elif n == "diskio":
        p = "diskio_" + tags["name"] + "_"
        out[p + "read_rate"] = rate(p + "read_bytes", f["read_bytes"], t)
        out[p + "write_rate"] = rate(p + "write_bytes", f["write_bytes"], t)
        out[p + "read_iops"] = rate(p + "reads", f["reads"], t)
        out[p + "write_iops"] = rate(p + "writes", f["writes"], t)
        busy = rate(p + "io_time", f["io_time"], t)   # ms/s
        out[p + "busy_percent"] = min(busy / 10, 100) if busy != None else None
    elif n == "net":
        p = "net_" + tags["interface"] + "_"
        out[p + "rx_rate"] = rate(p + "rx", f["bytes_recv"], t)
        out[p + "tx_rate"] = rate(p + "tx", f["bytes_sent"], t)
        out[p + "rx_packets_rate"] = rate(p + "rx_packets", f["packets_recv"], t)
        out[p + "tx_packets_rate"] = rate(p + "tx_packets", f["packets_sent"], t)
        out[p + "errors_rate"] = rate(p + "errors", f["err_in"] + f["err_out"], t)
        out[p + "drops_rate"] = rate(p + "drops", f["drop_in"] + f["drop_out"], t)
        if f.get("speed", -1) > 0:
            out[p + "link_speed"] = f["speed"]
    elif n == "temp":
        out[temp_name(tags.get("sensor", ""), tags.get("device", ""))] = f["temp"]
    elif n == "lvm_logical_vol":
        p = "lvm_" + slug(tags["name"]) + "_"
        out[p + "size"] = f["size"]
        out[p + "used_percent"] = f["data_percent"]
        out[p + "meta_used_percent"] = f["metadata_percent"]
    elif n == "smart_device":
        out = {"smart_" + tags["device"] + "_" + k: v for k, v in out.items()}
    elif n == "smart_attribute":
        units = {"Data_Units_Read": "read", "Data_Units_Written": "written"}   # NVMe 데이터 단위 = 512,000 바이트
        if tags.get("name") in units:
            out["smart_" + tags["device"] + "_" + units[tags["name"]]] = f["raw_value"] * 512000
    elif n == "sysfs":
        for zone, name in (("package", "cpu_power"), ("core", "cpu_core_power")):
            k = "rapl_" + zone + "_energy_uj"
            if k in f:
                w = rate(k, f[k], t, f.get("rapl_" + zone + "_max_uj", 0))
                out[name] = w / 1e6 if w != None else None
        for m in ("vram", "gtt"):
            if f.get("gpu_" + m + "_total", 0) > 0 and "gpu_" + m + "_used" in f:
                out["gpu_" + m + "_used_percent"] = 100.0 * f["gpu_" + m + "_used"] / f["gpu_" + m + "_total"]
    return out

def apply(metric):
    out = fields_of(metric)
    m = Metric("host")
    m.time = metric.time - metric.time % BUCKET
    n = 0
    for k, v in out.items():
        if v == None:
            continue
        m.fields[k] = float(v) if type(v) != "bool" else (1.0 if v else 0.0)
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
  password = "${MQTT_PASSWORD}"       # /etc/default/telegraf
  client_id = "telegraf-{{ host_metrics_name }}"
  topic = "hosts/{{ host_metrics_name }}"
  layout = "non-batch"                # 메트릭 하나 = 메시지 하나
  qos = 1
  data_format = "json"
  json_timestamp_units = "1ms"
```
{: file="templates/host-metrics/telegraf.conf.j2" }
{% endraw %}

</details>

<details markdown="1">
<summary>templates/host-metrics/host-sysfs.sh.j2 전문</summary>

{% raw %}
```bash
#!/bin/bash
# Telegraf 기본 입력이 읽지 못하는 호스트 값을 InfluxDB line protocol 한 줄(측정값 sysfs)로 냅니다. inputs.exec 가 10초마다 부릅니다.
# proxmox-ansible templates/host-metrics/host-sysfs.sh.j2 에서 만듭니다.
#   CPU 클럭: 코어별 현재 클럭의 평균·최대(MHz)
#   RAPL: 패키지·코어 누적 에너지(µJ)와 되돌아가는 상한. 초당 값(W)은 Telegraf starlark 가 이전 값과의 차로 구합니다
#   iGPU: 사용률, 영상 엔진(VCN) 사용률, VRAM·GTT 전체·사용(바이트), PPT(W), 코어·메모리 클럭(MHz), 전압(mV)
#     PPT 는 amdgpu hwmon power1 입니다. 커널 문서의 단위는 µW 지만 칩마다 다르게 나와 호스트 변수 host_metrics_gpu_ppt_scale 로 W 로 바꿉니다
#     (pve02 780M 은 µW 이고 SoC 전체라 power1_average 가 RAPL 패키지와 거의 같습니다. pve01 610M(Granite Ridge)은 power1_input 만 있고
#     1 W 단위 mW 로 나오며 GPU 부하에 따라 움직입니다. 2026-09-28 GPU 부하·RAPL·벽 전력과 비교해 확인)
# RAPL energy_uj 는 root 만 읽을 수 있어 telegraf 서비스에 CAP_DAC_READ_SEARCH 를 줍니다(systemd 드롭인).
fields=()
add() { [[ -n $2 ]] && fields+=("$1=$2"); }
val() { [[ -r $1 ]] && tr -d '\n' < "$1"; }

read -r clock_avg clock_max < <(cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq 2>/dev/null |
  awk '{ s += $1; if ($1 > m) m = $1 } END { if (NR) printf "%.0f %.0f\n", s / NR / 1000, m / 1000 }')
add cpu_clock_avg "$clock_avg"
add cpu_clock_max "$clock_max"

for zone in /sys/class/powercap/intel-rapl:0 /sys/class/powercap/intel-rapl:0:0; do
  [[ -r $zone/energy_uj ]] || continue
  name=$(val "$zone/name"); name=${name%%-*}          # package-0 → package, core
  add "rapl_${name}_energy_uj" "$(val "$zone/energy_uj")"
  add "rapl_${name}_max_uj" "$(val "$zone/max_energy_range_uj")"
done

gpu=/sys/class/drm/{{ host_metrics_drm_card }}/device
if [[ -d $gpu ]]; then
  add gpu_busy "$(val "$gpu/gpu_busy_percent")"
  add gpu_vcn_busy "$(val "$gpu/vcn_busy_percent")"
  for m in vram gtt; do
    add "gpu_${m}_total" "$(val "$gpu/mem_info_${m}_total")"
    add "gpu_${m}_used" "$(val "$gpu/mem_info_${m}_used")"
  done
  add gpu_mclk "$(awk '/\*/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "$gpu/pp_dpm_mclk" 2>/dev/null)"
  for hw in "$gpu"/hwmon/hwmon*; do                    # hwmon 번호는 부팅마다 바뀔 수 있어 카드 아래에서 찾습니다
    ppt=$(val "$hw/power1_average"); [[ -n $ppt ]] || ppt=$(val "$hw/power1_input")   # average 가 있으면(780M) 그것을. input 은 순간값이라 크게 튑니다
    [[ -n $ppt ]] && add gpu_ppt "$(awk -v v="$ppt" 'BEGIN { printf "%.3f", v * {{ host_metrics_gpu_ppt_scale }} }')"
    sclk=$(val "$hw/freq1_input"); [[ -n $sclk ]] && add gpu_sclk "$((sclk / 1000000))"
    for i in 0 1; do
      label=$(val "$hw/in${i}_label")
      [[ -n $label ]] && add "gpu_${label}_mv" "$(val "$hw/in${i}_input")"
    done
  done
fi

(IFS=,; echo "sysfs ${fields[*]}")
```
{: file="templates/host-metrics/host-sysfs.sh.j2" }
{% endraw %}

</details>

발견 설정은 센서 목록을 따로 적지 않고 실제 메시지의 필드로 만듭니다. 필드 이름의 규칙표로 한국어 이름·단위·`device_class` 를 붙이고, 규칙에 없는 새 필드도 이름 그대로 센서로 만듭니다. `value_template` 은 필드가 빠진 메시지(Telegraf 재시작 직후 첫 메시지에는 초당 값이 없음)에서 이전 상태를 유지하고, `expire_after` 60초로 호스트가 멈추면 센서가 `unavailable` 이 됩니다. 호스트의 파이썬과 apt 패키지 `python3-paho-mqtt` 만 씁니다.

<details markdown="1">
<summary>scripts/host-metrics-discovery.py 전문</summary>

{% raw %}
```python
#!/usr/bin/python3
"""호스트 Telegraf 가 hosts/<기기> 에 내는 필드마다 Home Assistant MQTT 발견 설정을 맞춘다.

playbooks/host-metrics.yml 이 호스트에 복사해 실행한다. 호스트의 python3 와 apt 패키지 python3-paho-mqtt 만 쓴다.
실제 메시지를 받아 그 필드로 센서 목록을 정하므로 수집 항목이 늘거나 줄어도 설정을 따로 적지 않는다.
- 브로커에 남아 있는(retained) 설정과 비교해 내용이 다르거나 없는 것만 발행한다(다시 실행해도 같은 결과).
- 필드가 없어진 센서는 빈 retained 메시지로 지운다(HA 에서 엔티티가 사라짐).
엣지 Telegraf(k8s-gitops iot/edge/telegraf)는 이 설정의 unit_of_measurement 를 DB readings.unit 으로 쓴다.
구조: 순수 함수(sensor_meta, build_configs, diff) → 브로커 함수(collect, publish) → CLI(build_parser, main).
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
import time
from pathlib import Path

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2

DISCOVERY_PREFIX = "homeassistant"
STATE_PREFIX = "hosts"
ORIGIN = {
    "name": "host-metrics"
}  # 엣지 Telegraf 가 이 발견 설정만 골라 단위를 읽는 표식
EXPIRE_AFTER = 60  # 초. 호스트나 Telegraf 가 멈추면 센서가 unavailable 이 된다

log = logging.getLogger(Path(__file__).stem)

PERCENT = {"unit_of_measurement": "%", "suggested_display_precision": 1}
BYTES = {"unit_of_measurement": "B", "device_class": "data_size"}
BYTES_RATE = {"unit_of_measurement": "B/s", "device_class": "data_rate"}
PER_SECOND = {"unit_of_measurement": "/s", "suggested_display_precision": 0}
MHZ = {"unit_of_measurement": "MHz", "device_class": "frequency"}
WATT = {
    "unit_of_measurement": "W",
    "device_class": "power",
    "suggested_display_precision": 1,
}
CELSIUS = {
    "unit_of_measurement": "°C",
    "device_class": "temperature",
    "suggested_display_precision": 1,
}
DIAG = {"entity_category": "diagnostic"}

WORDS = {
    "user": "사용자",
    "system": "시스템",
    "guest": "게스트(VM)",
    "iowait": "IO 대기",
    "irq": "인터럽트",
    "avg": "평균",
    "max": "최대",
    "total": "전체",
    "used": "사용",
    "available": "가용",
    "free": "여유",
    "cached": "캐시",
    "buffered": "버퍼",
    "shared": "공유",
    "slab": "slab",
    "committed": "커밋",
    "running": "실행",
    "sleeping": "대기",
    "blocked": "IO 막힘",
    "zombies": "좀비",
    "threads": "스레드",
    "read": "읽기",
    "write": "쓰기",
    "rx": "수신",
    "tx": "송신",
    "in": "인",
    "out": "아웃",
    "vram": "VRAM",
    "gtt": "GTT",
    "context_switches": "컨텍스트 스위치",
    "interrupts": "인터럽트",
    "forks": "fork",
}
TEMP_WORDS = {
    "cpu": "CPU",
    "gpu": "GPU",
    "ram": "RAM",
    "nic": "NIC",
    "wifi": "Wi-Fi",
    "acpi": "ACPI",
    "tctl": "Tctl",
    "ccd1": "CCD1",
    "ccd2": "CCD2",
}
SMART = {
    "wear_percent": ("수명 사용률", PERCENT),
    "available_spare": ("예비 공간", {"unit_of_measurement": "%"} | DIAG),
    "media_errors": ("미디어 오류", DIAG),
    "error_log_entries": ("오류 로그", DIAG),
    "critical_warning": ("경고 비트", DIAG),
    "unsafe_shutdowns": ("비정상 종료", DIAG),
    "power_on_hours": (
        "전원 켜진 시간",
        {"unit_of_measurement": "h", "device_class": "duration"} | DIAG,
    ),
    "power_cycles": ("전원 켠 횟수", DIAG),
    "health_ok": ("상태 정상", DIAG),
    "read": ("누적 읽기", BYTES | {"state_class": "total_increasing"} | DIAG),
    "written": ("누적 쓰기", BYTES | {"state_class": "total_increasing"} | DIAG),
}


def _w(key: str) -> str:
    return WORDS.get(key, key)


def _mount(slug: str) -> str:
    return "/" if slug == "root" else "/" + slug.replace("_", "/")


# (패턴, 이름 함수, 속성). 위에서부터 처음 맞는 규칙을 쓴다
RULES: list[tuple[str, object, dict]] = [
    (r"cpu_usage", lambda m: "CPU 사용률", PERCENT),
    (r"cpu_(user|system|guest|iowait|irq)", lambda m: f"CPU {_w(m[1])}", PERCENT),
    (r"cpu_clock_(avg|max)", lambda m: f"CPU 클럭 {_w(m[1])}", MHZ),
    (r"cpu_power", lambda m: "CPU 패키지 전력", WATT),
    (r"cpu_core_power", lambda m: "CPU 코어 전력", WATT),
    (r"cpu_threads", lambda m: "CPU 스레드 수", DIAG),
    (r"cpu_cores", lambda m: "CPU 코어 수", DIAG),
    (r"load(1|5|15)", lambda m: f"부하 {m[1]}분", {"suggested_display_precision": 2}),
    (
        r"uptime",
        lambda m: "가동 시간",
        {"unit_of_measurement": "s", "device_class": "duration"} | DIAG,
    ),
    (r"processes_total", lambda m: "프로세스 수", {}),
    (r"processes_(\w+)", lambda m: f"프로세스 {_w(m[1])}", {}),
    (r"kernel_(\w+)_rate", lambda m: _w(m[1]), PER_SECOND),
    (r"(mem|swap)_used_percent", lambda m: f"{_mem(m[1])} 사용률", PERCENT),
    (r"(mem|swap)_(in|out)_rate", lambda m: f"{_mem(m[1])} {_w(m[2])}", BYTES_RATE),
    (r"(mem|swap)_total", lambda m: f"{_mem(m[1])} 전체", BYTES | DIAG),
    (r"(mem|swap)_(\w+)", lambda m: f"{_mem(m[1])} {_w(m[2])}", BYTES),
    (
        r"disk_(\w+)_inodes_used_percent",
        lambda m: f"디스크 {_mount(m[1])} inode 사용률",
        PERCENT | DIAG,
    ),
    (r"disk_(\w+)_used_percent", lambda m: f"디스크 {_mount(m[1])} 사용률", PERCENT),
    (r"disk_(\w+)_total", lambda m: f"디스크 {_mount(m[1])} 전체", BYTES | DIAG),
    (r"disk_(\w+)_(used|free)", lambda m: f"디스크 {_mount(m[1])} {_w(m[2])}", BYTES),
    (
        r"lvm_(\w+)_meta_used_percent",
        lambda m: f"LVM {m[1]} 메타데이터 사용률",
        PERCENT,
    ),
    (r"lvm_(\w+)_used_percent", lambda m: f"LVM {m[1]} 사용률", PERCENT),
    (r"lvm_(\w+)_size", lambda m: f"LVM {m[1]} 크기", BYTES | DIAG),
    (r"diskio_(\w+?)_(read|write)_rate", lambda m: f"{m[1]} {_w(m[2])}", BYTES_RATE),
    (
        r"diskio_(\w+?)_(read|write)_iops",
        lambda m: f"{m[1]} {_w(m[2])} IOPS",
        {"unit_of_measurement": "IOPS", "suggested_display_precision": 0},
    ),
    (r"diskio_(\w+?)_busy_percent", lambda m: f"{m[1]} 사용 시간", PERCENT),
    (r"net_(\w+?)_(rx|tx)_rate", lambda m: f"{m[1]} {_w(m[2])}", BYTES_RATE),
    (
        r"net_(\w+?)_(rx|tx)_packets_rate",
        lambda m: f"{m[1]} {_w(m[2])} 패킷",
        {"unit_of_measurement": "packets/s", "suggested_display_precision": 0},
    ),
    (r"net_(\w+?)_errors_rate", lambda m: f"{m[1]} 오류", PER_SECOND | DIAG),
    (r"net_(\w+?)_drops_rate", lambda m: f"{m[1]} 드롭", PER_SECOND | DIAG),
    (
        r"net_(\w+?)_link_speed",
        lambda m: f"{m[1]} 링크 속도",
        {"unit_of_measurement": "Mbit/s", "device_class": "data_rate"} | DIAG,
    ),
    (
        r"temp_(\w+)",
        lambda m: "온도 " + " ".join(TEMP_WORDS.get(p, p) for p in m[1].split("_")),
        CELSIUS,
    ),
    (r"gpu_usage", lambda m: "GPU 사용률", PERCENT),
    (r"gpu_video_usage", lambda m: "GPU 영상 엔진 사용률", PERCENT),
    (r"gpu_clock", lambda m: "GPU 클럭", MHZ),
    (r"gpu_mem_clock", lambda m: "GPU 메모리 클럭", MHZ),
    (r"gpu_power", lambda m: "GPU PPT 전력", WATT),
    (r"gpu_(vram|gtt)_used_percent", lambda m: f"GPU {_w(m[1])} 사용률", PERCENT),
    (r"gpu_(vram|gtt)_total", lambda m: f"GPU {_w(m[1])} 전체", BYTES | DIAG),
    (r"gpu_(vram|gtt)_used", lambda m: f"GPU {_w(m[1])} 사용", BYTES),
    (
        r"gpu_(vdd\w+)",
        lambda m: f"GPU 전압 {m[1]}",
        {"unit_of_measurement": "mV", "device_class": "voltage"} | DIAG,
    ),
]


def _mem(kind: str) -> str:
    return "메모리" if kind == "mem" else "스왑"


def sensor_meta(field: str) -> dict:
    """필드 이름으로 센서 이름·단위·분류를 정한다. 규칙에 없는 필드는 이름만 필드 그대로 준다."""
    m = re.fullmatch(r"smart_([a-z0-9]+)_(\w+)", field)
    if m and m[2] in SMART:
        label, attrs = SMART[m[2]]
        return {"name": f"{m[1]} {label}"} | attrs
    for pattern, name, attrs in RULES:
        m = re.fullmatch(pattern, field)
        if m:
            return {"name": name(m)} | attrs
    return {"name": field}


def build_configs(
    device: str, fields: dict[str, float], manufacturer: str, model: str
) -> dict[str, dict]:
    """필드마다 발견 설정(토픽 → 내용)을 만든다."""
    configs = {}
    for field in sorted(fields):
        meta = sensor_meta(field)
        config = {
            "name": meta.pop("name"),
            "unique_id": f"{device}_{field}",
            "default_entity_id": f"sensor.{device}_{field}",
            "state_topic": f"{STATE_PREFIX}/{device}",
            # 필드가 빠진 메시지(재시작 직후의 초당 값)는 이전 상태를 유지한다
            "value_template": (
                f"{{{{ value_json.fields['{field}'] "
                f"if '{field}' in value_json.fields else this.state }}}}"
            ),
            "state_class": "measurement",
            "expire_after": EXPIRE_AFTER,
            "device": {
                "identifiers": [device],
                "name": device,
                "manufacturer": manufacturer,
                "model": model,
            },
            "origin": ORIGIN,
        }
        config.update(meta)
        configs[f"{DISCOVERY_PREFIX}/sensor/{device}/{field}/config"] = config
    return configs


def diff(
    existing: dict[str, str], wanted: dict[str, dict]
) -> tuple[dict[str, dict], list[str]]:
    """브로커에 있는 설정(원문)과 원하는 설정을 비교해 발행할 것과 지울 토픽을 준다."""
    publish = {}
    for topic, config in wanted.items():
        try:
            same = json.loads(existing.get(topic, "")) == config
        except json.JSONDecodeError:
            same = False
        if not same:
            publish[topic] = config
    remove = sorted(t for t in existing if t not in wanted)
    return publish, remove


def connect(broker: str, user: str, password: str, client_id: str):
    """브로커에 붙은 paho 클라이언트를 준다(백그라운드 루프 시작)."""
    import paho.mqtt.client as mqtt  # 테스트에서 순수 함수만 쓸 때 paho 없이 불러오게 한다

    host, _, port = broker.rpartition(":")
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=client_id)
    client.username_pw_set(user, password)
    client.connect(host, int(port), keepalive=30)
    client.loop_start()
    return client


def collect(client, device: str, samples: int, timeout: float) -> tuple[dict, dict]:
    """상태 메시지 samples 개의 필드 합집합과 이 기기의 기존 발견 설정(retained)을 모은다."""
    fields: dict[str, float] = {}
    existing: dict[str, str] = {}
    received = 0
    config_filter = f"{DISCOVERY_PREFIX}/sensor/{device}/+/config"
    state_topic = f"{STATE_PREFIX}/{device}"

    def on_message(_client, _userdata, msg) -> None:
        nonlocal received
        if msg.topic == state_topic:
            fields.update(json.loads(msg.payload).get("fields", {}))
            received += 1
        elif msg.retain and msg.payload:
            existing[msg.topic] = msg.payload.decode()

    client.on_message = on_message
    client.subscribe([(config_filter, 1), (state_topic, 1)])
    deadline = time.monotonic() + timeout
    while received < samples and time.monotonic() < deadline:
        time.sleep(0.2)
    return fields, existing


def publish(client, topics: dict[str, str]) -> None:
    """retained 로 발행하고 브로커가 받을 때까지 기다린다."""
    for topic, payload in topics.items():
        client.publish(topic, payload, qos=1, retain=True).wait_for_publish(10)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="호스트 Telegraf 필드마다 Home Assistant MQTT 발견 설정을 맞춘다.",
        epilog=(
            "예:\n"
            "  MQTT_PASSWORD=… host-metrics-discovery.py --broker <브로커 주소>:1883 "
            "--user devices --device bedroom2-host-server_ms_a2_1 --dry-run\n\n"
            "비밀번호: 환경 변수 MQTT_PASSWORD\n"
            '출력: stdout 에 {"device", "fields", "published", "removed", "changed", "dry_run"} JSON\n'
            "exit code: 0 성공, 1 상태 메시지를 받지 못함·브로커 오류, 2 사용법 오류"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--broker", required=True, help="호스트:포트")
    parser.add_argument("--user", required=True, help="브로커 계정")
    parser.add_argument(
        "--device", required=True, help="기기 이름(hosts/<기기> 의 <기기>)"
    )
    parser.add_argument("--manufacturer", default="", help="HA 기기 제조사")
    parser.add_argument("--model", default="", help="HA 기기 모델")
    parser.add_argument(
        "--samples",
        type=int,
        default=2,
        help="필드를 모을 상태 메시지 수(기본 2. 재시작 직후 첫 메시지에는 초당 값이 없음)",
    )
    parser.add_argument(
        "--timeout", type=float, default=45, help="상태 메시지를 기다릴 초"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="발행하지 않고 할 일만 출력한다"
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="진단을 자세히 출력한다"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(message)s",
        stream=sys.stderr,
    )
    password = os.environ.get("MQTT_PASSWORD")
    if not password:
        log.error("브로커 비밀번호가 필요하다: 환경 변수 MQTT_PASSWORD 를 설정한다")
        return EXIT_USAGE

    try:
        client = connect(
            args.broker, args.user, password, f"host-metrics-discovery-{args.device}"
        )
    except OSError as exc:
        log.error("브로커 접속 실패: %s", exc)
        return EXIT_FAILED
    try:
        fields, existing = collect(client, args.device, args.samples, args.timeout)
        if not fields:
            log.error(
                "%s 초 동안 %s/%s 메시지를 받지 못했다",
                args.timeout,
                STATE_PREFIX,
                args.device,
            )
            return EXIT_FAILED
        wanted = build_configs(args.device, fields, args.manufacturer, args.model)
        to_publish, to_remove = diff(existing, wanted)
        if not args.dry_run:
            publish(
                client,
                {t: json.dumps(c, ensure_ascii=False) for t, c in to_publish.items()}
                | {t: "" for t in to_remove},
            )
    finally:
        client.loop_stop()
        client.disconnect()

    changed = len(to_publish) + len(to_remove)
    json.dump(
        {
            "device": args.device,
            "fields": len(fields),
            "published": sorted(t.split("/")[3] for t in to_publish),
            "removed": [t.split("/")[3] for t in to_remove],
            "changed": changed,
            "dry_run": args.dry_run,
        },
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")
    log.info(
        "필드 %d개, 발행 %d, 삭제 %d", len(fields), len(to_publish), len(to_remove)
    )
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
```
{: file="scripts/host-metrics-discovery.py" }
{% endraw %}

</details>

플레이북은 InfluxData 저장소에서 엣지와 같은 버전의 Telegraf 를 설치하고 버전을 고정합니다. SMART·LVM 조회는 root 가 필요하므로 Proxmox 에 기본으로 없는 `sudo` 를 설치해 그 명령만 허용하고, RAPL `energy_uj` 는 root 만 읽을 수 있어 서비스에 읽기 권한 검사를 건너뛰는 능력(`CAP_DAC_READ_SEARCH`) 하나만 줍니다.

<details markdown="1">
<summary>playbooks/host-metrics.yml 전문</summary>

{% raw %}
```yaml
# Proxmox 호스트 자체(VM·CT 를 합한 호스트 전체)의 CPU·메모리·디스크·네트워크·온도·전력·GPU 값을 Telegraf 로 모아 MQTT 에 발행합니다.
# 10초마다 JSON 메시지 하나를 hosts/<host_metrics_name> 에 내고, Home Assistant MQTT 발견 설정을 만들어 센서로 보이게 합니다.
# DB 기록은 엣지 Telegraf(k8s-gitops iot/edge/telegraf)가 같은 토픽을 받아 readings 에 넣습니다.
#   MQTT_PASSWORD=$(. ~/.config/iot/secrets.env; echo "$MQTT_DEVICES") ansible-playbook playbooks/host-metrics.yml [--limit pve01]
# 수집 항목이 바뀌면(디스크·인터페이스 추가, 설정 변경) 다시 실행합니다. 발견 설정은 실제 메시지의 필드로 다시 맞춥니다.
---
- name: 호스트 Telegraf
  hosts: proxmox
  gather_facts: true
  vars:
    mqtt_password: "{{ lookup('env', 'MQTT_PASSWORD') }}"
  pre_tasks:
    - name: 비밀번호 확인
      ansible.builtin.assert:
        that: mqtt_password | length > 0
        fail_msg: MQTT_PASSWORD 환경변수가 비어 있습니다(브로커 계정 {{ host_metrics_mqtt_user }} 의 비밀번호)
      run_once: true
      delegate_to: localhost
    - name: 기기 이름 확인
      ansible.builtin.assert:
        that: host_metrics_name is defined
        fail_msg: inventory 에 host_metrics_name 이 없습니다
  tasks:
    - name: 저장소 키
      ansible.builtin.get_url:
        url: https://repos.influxdata.com/influxdata-archive.key
        dest: /usr/share/keyrings/influxdata-archive.asc
        mode: "0644"
    - name: 저장소
      ansible.builtin.copy:
        dest: /etc/apt/sources.list.d/influxdata.list
        mode: "0644"
        content: |
          deb [signed-by=/usr/share/keyrings/influxdata-archive.asc] https://repos.influxdata.com/debian stable main
    - name: 설치
      ansible.builtin.apt:
        name:
          - telegraf={{ host_metrics_telegraf_version }}
          - smartmontools        # inputs.smart
          - nvme-cli             # inputs.smart 의 NVMe 추가 속성
          - python3-paho-mqtt    # 발견 설정 스크립트
          - sudo                 # smart·lvm 입력이 root 로 조회(Proxmox 에는 기본으로 없음)
        update_cache: true
    - name: 버전 고정 (apt upgrade 로 엣지와 버전이 갈라지지 않게)
      ansible.builtin.dpkg_selections:
        name: telegraf
        selection: hold

    - name: sudo 허용 (smartctl·nvme·LVM 조회만)
      ansible.builtin.copy:
        dest: /etc/sudoers.d/telegraf
        mode: "0440"
        validate: visudo -cf %s
        content: |
          Cmnd_Alias TELEGRAF_HOST = /usr/sbin/smartctl, /usr/sbin/nvme, /usr/sbin/pvs, /usr/sbin/vgs, /usr/sbin/lvs
          telegraf ALL=(root) NOPASSWD: TELEGRAF_HOST
          Defaults!TELEGRAF_HOST !logfile, !syslog, !pam_session
    - name: 비밀번호 (서비스 환경변수)
      ansible.builtin.copy:
        dest: /etc/default/telegraf
        mode: "0600"
        content: |
          MQTT_PASSWORD={{ mqtt_password }}
      no_log: true
      notify: telegraf 재시작
    - name: systemd 드롭인 폴더
      ansible.builtin.file:
        path: /etc/systemd/system/telegraf.service.d
        state: directory
        mode: "0755"
    - name: systemd 드롭인 (RAPL energy_uj 는 root 만 읽을 수 있어 읽기 권한 검사를 건너뛰는 능력만 줍니다)
      ansible.builtin.copy:
        dest: /etc/systemd/system/telegraf.service.d/host-metrics.conf
        mode: "0644"
        content: |
          [Service]
          AmbientCapabilities=CAP_DAC_READ_SEARCH
      notify: telegraf 재시작
    - name: sysfs 스크립트
      ansible.builtin.template:
        src: ../templates/host-metrics/host-sysfs.sh.j2
        dest: /usr/local/lib/telegraf-host-sysfs.sh
        mode: "0755"
    - name: 디스크 버퍼 폴더
      ansible.builtin.file:
        path: /var/lib/telegraf/buffer
        state: directory
        owner: telegraf
        group: telegraf
        mode: "0750"
    - name: 설정
      ansible.builtin.template:
        src: ../templates/host-metrics/telegraf.conf.j2
        dest: /etc/telegraf/telegraf.conf
        mode: "0644"
        validate: telegraf --config %s --test --test-wait 0 --quiet --input-filter system
      notify: telegraf 재시작
    - name: 기본 설정 폴더의 예제 비우기 (패키지가 넣는 telegraf.d 는 쓰지 않음)
      ansible.builtin.find:
        paths: /etc/telegraf/telegraf.d
        patterns: "*.conf"
      register: extra_conf
    - name: telegraf.d 설정이 없어야 함
      ansible.builtin.assert:
        that: extra_conf.matched == 0
        fail_msg: /etc/telegraf/telegraf.d 에 설정이 있습니다. 이 플레이북은 telegraf.conf 하나만 씁니다
    - name: 서비스
      ansible.builtin.systemd:
        name: telegraf
        enabled: true
        state: started
        daemon_reload: true

    - name: 발견 설정 스크립트
      ansible.builtin.copy:
        src: ../scripts/host-metrics-discovery.py
        dest: /usr/local/lib/host-metrics-discovery.py
        mode: "0755"
  handlers:
    - name: telegraf 재시작
      ansible.builtin.systemd:
        name: telegraf
        state: restarted
        daemon_reload: true
  post_tasks:
    - name: 재시작 반영
      ansible.builtin.meta: flush_handlers
    # 실제 메시지를 하나 받아 필드마다 센서를 만들고, 없어진 필드의 센서는 지웁니다. 내용이 같으면 발행하지 않습니다
    - name: Home Assistant 발견 설정
      ansible.builtin.command:
        argv:
          - /usr/local/lib/host-metrics-discovery.py
          - --broker
          - "{{ host_metrics_broker }}"
          - --user
          - "{{ host_metrics_mqtt_user }}"
          - --device
          - "{{ host_metrics_name }}"
          - --manufacturer
          - "{{ ansible_facts['system_vendor'] }}"
          - --model
          - "{{ ansible_facts['product_name'] }}"
      environment:
        MQTT_PASSWORD: "{{ mqtt_password }}"
      register: discovery
      changed_when: (discovery.stdout | from_json).changed > 0
```
{: file="playbooks/host-metrics.yml" }
{% endraw %}

</details>

- **확인:** `ansible-playbook playbooks/host-metrics.yml --syntax-check` 가 오류 없이 끝납니다.

## 4. 플레이북 실행

브로커 계정 `devices` 의 비밀번호를 환경변수로 넘깁니다. 한 대에 먼저 적용해 보고 나머지에 적용합니다.

```bash
# devices 계정 비밀번호를 입력받아 넘깁니다
read -rsp "MQTT 계정 devices: " MQTT_PASSWORD; echo; export MQTT_PASSWORD
ansible-playbook playbooks/host-metrics.yml --limit pve01
ansible-playbook playbooks/host-metrics.yml
```

- **확인:** `PLAY RECAP` 에 `failed=0` 이고, 같은 명령을 한 번 더 실행하면 `changed=0` 입니다. 브로커에서 메시지를 하나 받아 보면 필드가 100개 남짓입니다.

```bash
# 허브 control plane. E 는 엣지 kubeconfig, PW 는 telegraf 계정 비밀번호
E="--kubeconfig k8s-[SITE].yaml"
PW=$(kubectl $E -n telegraf get secret telegraf-credentials -o jsonpath='{.data.MQTT_PASSWORD}' | base64 -d)
kubectl $E -n mosquitto exec deploy/mosquitto -- mosquitto_sub -u telegraf -P "$PW" -t 'hosts/#' -C 1 -v
```

```text
hosts/bedroom2-host-server_ms_a2_1 {"fields":{"cpu_clock_avg":4130,"cpu_clock_max":4235,"cpu_core_power":2.17,"cpu_cores":16,"cpu_guest":3.77, …},"name":"host","tags":{},"timestamp":1790528080000}
```

## 5. Home Assistant 영역 배정

발견 설정이 들어오면 지역 HA 의 MQTT 통합에 기기 `bedroom2-host-server_ms_a2_1` 과 센서(`sensor.bedroom2_host_server_ms_a2_1_cpu_usage` 등)가 생깁니다. 영역은 다른 기기처럼 이름의 방 칸으로 배정합니다. `ha-registry.py --assign-areas` 는 MQTT 기기도 다루므로 그대로 씁니다.

```bash
# 허브 control plane. 지역 HA 파드 안에서 실행 (dry-run → 실행 → 다시 dry-run)
K="kubectl --kubeconfig k8s-[SITE].yaml -n home-assistant"
T=$($K get secret ha-api-token -o jsonpath="{.data.token}" | base64 -d)
$K exec -i deploy/home-assistant -c home-assistant -- env HA_TOKEN="$T" python3 - --assign-areas --dry-run < ha-registry.py
$K exec -i deploy/home-assistant -c home-assistant -- env HA_TOKEN="$T" python3 - --assign-areas < ha-registry.py
```

- **확인:** 첫 명령에 `[dry-run] 영역 지정 bedroom2-host-server_ms_a2_1: 없음 → 침실2` 가 보이고, 실행 뒤 다시 dry-run 하면 아무것도 나오지 않습니다. 개발자 도구의 상태에서 센서들이 10초마다 갱신되고, 중앙 HA 를 쓰면 `sensor.[지역 접두어]_bedroom2_host_…` 로 같은 센서가 보입니다.

## 6. 엣지 Telegraf 에 호스트 입력 추가

엣지 Telegraf 에 입력 두 개를 추가합니다. 첫 입력이 `hosts/+` 의 `fields` 를 필드별 행으로 받고, 둘째 입력이 호스트의 발견 설정을 받아 단위(`unit_of_measurement`)와 제조사·모델을 [Telegraf 글](/posts/43/)의 공통 starlark 에 기억시킵니다. starlark 는 `origin` 이 `host-metrics` 인 발견 설정만 쓰므로 Zigbee2MQTT 의 발견 설정은 무시합니다.

```toml
# 서버·PC 자체가 잰 값(CPU·메모리·디스크·네트워크·온도·전력·GPU). 호스트의 Telegraf 가 10초마다 hosts/<기기> 에 JSON 하나로 냅니다
#   {"name": "host", "fields": {"cpu_usage": 3.9, "mem_used": 41422155776, ...}, "tags": {}, "timestamp": <ms>}
# 기기 이름은 <방>-host-<제품 키>(bedroom2-host-server_ms_a2_1)이고, 필드 하나가 행 하나(property = 필드 이름)가 됩니다.
# 호스트 쪽 설정은 proxmox-ansible playbooks/host-metrics.yml 에 있습니다.
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.mosquitto.svc.cluster.local:1883"]
  topics = ["hosts/+"]
  username = "${MQTT_USER}"
  password = "${MQTT_PASSWORD}"
  client_id = "telegraf-hosts"
  persistent_session = true
  qos = 1
  topic_tag = ""
  name_override = "readings"
  data_format = "json_v2"
  [[inputs.mqtt_consumer.json_v2]]
    timestamp_path = "timestamp"      # 호스트가 잰 시각(10초 단위). 지연 도착해도 시각이 맞습니다
    timestamp_format = "unix_ms"
    [[inputs.mqtt_consumer.json_v2.object]]
      path = "fields"
  [inputs.mqtt_consumer.tags]
    protocol = "mqtt"
    source = "telegraf"
  [[inputs.mqtt_consumer.topic_parsing]]
    topic = "hosts/+"
    tags = "_/device"

# 호스트 값의 단위와 실물 정보. 호스트가 필드마다 Home Assistant 발견 설정(유지 메시지)을 내므로, 아래 starlark 가
# origin 이 host-metrics 인 것만 골라 unit_of_measurement 와 device.manufacturer·model 을 기억해 두고 호스트 행에 unit·vendor·model 로 붙입니다.
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.mosquitto.svc.cluster.local:1883"]
  topics = ["homeassistant/sensor/+/+/config"]
  username = "${MQTT_USER}"
  password = "${MQTT_PASSWORD}"
  client_id = "telegraf-host-sensors"
  qos = 1
  topic_tag = ""
  name_override = "host_sensors"
  data_format = "value"
  data_type = "string"
```
{: file="iot/edge/telegraf/telegraf.conf (Zigbee2MQTT 제어 기록 입력 아래에 추가)" }

호스트마다 10초에 100여 행(하루 약 120만 행)이 늘어나므로 `readings` 의 청크와 압축을 1일로 둡니다. Telegraf 글의 `create_templates` 는 이미 1일이라 새로 만드는 테이블은 그대로 두면 되고, 그 전에 만든 테이블은 지역 DB 와 허브 DB 에 아래 SQL 을 한 번씩 실행합니다. 압축된 청크에도 INSERT·UPDATE·DELETE 는 되므로 늦게 온 버퍼나 날씨 백필은 느려질 뿐 그대로 들어갑니다.

```sql
-- readings 의 청크 간격과 압축 시점을 7일·30일에서 1일·1일로 줄입니다. 허브 DB 와 지역 DB 모두에 한 번 실행합니다(다시 실행해도 결과가 같습니다).
-- 호스트 값(엣지 Telegraf 의 hosts/+ 입력)이 호스트마다 10초에 100여 행(하루 약 120만 행)이라, 압축 전 데이터가 하루치 넘게 쌓이지 않게 합니다.
-- 청크 간격은 새로 만드는 청크부터 적용되므로 지금 쓰고 있는 7일 청크는 그 끝까지 그대로 쓰고, 끝난 다음 날 압축됩니다.
-- 압축된 청크에도 INSERT·UPDATE·DELETE 는 됩니다(늦게 온 버퍼, 날씨 백필, 보정). 예전 마이그레이션의 "압축되기 전(30일 안)에 실행" 은
-- 이제 "1일 안" 이고, 지나서 실행하면 느려질 뿐입니다. 엣지 Telegraf 의 create_templates 도 같은 값입니다.
--   허브: kubectl -n timescaledb exec -i timescaledb-0 -- psql -h timescaledb -U iot -d iot -v ON_ERROR_STOP=1 < 2026-09-28-readings-compress-1d.sql
--   지역: kubectl --kubeconfig ~/k8s-<지역>.yaml -n timescaledb exec -i <주 DB 파드> -- psql -U iot -d iot -v ON_ERROR_STOP=1 < 2026-09-28-readings-compress-1d.sql
SELECT set_chunk_time_interval('readings', INTERVAL '1 day');
SELECT remove_compression_policy('readings', if_exists => true);
SELECT add_compression_policy('readings', INTERVAL '1 day');

-- 확인: 청크 간격 1 day, 압축 정책 compress_after 1 day
SELECT d.time_interval FROM timescaledb_information.dimensions d WHERE d.hypertable_name = 'readings';
SELECT config FROM timescaledb_information.jobs WHERE proc_name = 'policy_compression' AND hypertable_name = 'readings';
```
{: file="iot/hub/timescaledb/migrations/2026-09-28-readings-compress-1d.sql" }

```bash
git add iot/edge/telegraf/telegraf.conf iot/hub/timescaledb/migrations/2026-09-28-readings-compress-1d.sql
git commit -m "feat(iot): 서버·PC 호스트 값(hosts/+)을 readings 에 기록"
git push
```

- **확인:** Argo CD 의 `[SITE]-telegraf` 가 Synced·Healthy 가 된 뒤 20초쯤 지나면 두 DB 에 호스트 행이 보입니다. 단위가 빈 행은 개수·부하처럼 원래 단위가 없는 값(`load1`, `processes_total` 등)뿐입니다. Grafana `IoT 기록` 대시보드에서는 `device` 변수에서 `host` 를 고르면 호스트 속성마다 패널이 나옵니다.

```sql
select anchor, count(distinct property) as props, max(time) as last,
       count(*) filter (where coalesce(unit, '') = '') as no_unit
from readings where device = 'host' and time > now() - interval '1 minute' group by 1;
```

## 7. 부하와 소비전력 맞춰 보기

플러그와 호스트는 보고 주기가 달라(플러그 5~8초, 호스트 10초) 1분 평균으로 맞춥니다.

```sql
-- 1분 평균으로 맞춘 벽 전력(플러그)과 호스트 부하
SELECT time_bucket('1 minute', time) AS t,
  avg(value) FILTER (WHERE device = 'plug' AND property = 'power')     AS wall_w,
  avg(value) FILTER (WHERE device = 'host' AND property = 'cpu_usage') AS cpu_pct,
  avg(value) FILTER (WHERE device = 'host' AND property = 'cpu_power') AS cpu_w,
  avg(value) FILTER (WHERE device = 'host' AND property = 'gpu_usage') AS gpu_pct
FROM readings
WHERE anchor = 'server_ms_a2_1' AND processing = 'raw' AND time > now() - interval '1 day'
GROUP BY 1 ORDER BY 1;
-- CPU 사용률 10% 구간별 평균 벽 전력
WITH m AS (
  SELECT time_bucket('1 minute', time) AS t,
    avg(value) FILTER (WHERE device = 'plug' AND property = 'power')     AS wall_w,
    avg(value) FILTER (WHERE device = 'host' AND property = 'cpu_usage') AS cpu_pct
  FROM readings
  WHERE anchor = 'server_ms_a2_1' AND processing = 'raw' AND time > now() - interval '7 days'
  GROUP BY 1)
SELECT floor(cpu_pct / 10) * 10 AS cpu_from, count(*) AS minutes, round(avg(wall_w)::numeric, 1) AS wall_w
FROM m WHERE wall_w IS NOT NULL AND cpu_pct IS NOT NULL GROUP BY 1 ORDER BY 1;
```

> `gpu_power` 는 amdgpu 가 알리는 PPT 라 칩마다 뜻이 다릅니다. 780M 은 SoC 전체 전력이라 `cpu_power`(RAPL 패키지)와 거의 같고, 610M(Granite Ridge)은 1 W 단위로 GPU 부하를 따라 움직입니다. 서버끼리 비교할 때는 플러그의 벽 전력과 `cpu_power` 를 씁니다.
{: .prompt-warning }

- **확인:** 첫 쿼리에서 호스트 값이 들어온 뒤의 분마다 `wall_w` 와 `cpu_pct` 가 함께 채워집니다.

## 트러블슈팅

<details markdown="1">
<summary><code>No such file or directory: b'visudo'</code></summary>

```text
[ERROR]: Task failed: Module failed: Error executing command: [Errno 2] No such file or directory: b'visudo'
```

- **원인:** Proxmox 에는 `sudo` 패키지가 기본으로 없어, sudoers 파일을 검사하는 `visudo` 도 없습니다.
- **해결:** 설치 목록에 `sudo` 를 넣었습니다. Telegraf 의 `smart`·`lvm` 입력이 `use_sudo = true` 로 이 명령들을 부릅니다.

</details>

<details markdown="1">
<summary><code>lookup iot-dj... on 1.1.1.1:53: no such host</code></summary>

```text
E! [agent] Failed to connect to [outputs.mqtt], retrying in 15s, error was "network Error : dial tcp: lookup iot-dj.[DOMAIN] on 1.1.1.1:53: no such host"
```

- **원인:** Proxmox 호스트는 외부 DNS 를 써서 내부망 이름이 풀리지 않습니다.
- **해결:** 브로커 주소를 `k8s_clusters.[SITE].service_vip` 변수로 두었습니다.

</details>

<details markdown="1">
<summary><code>gpu_power</code> 가 벽 전력보다 크거나 0.01 W 처럼 작게 나옴</summary>

- **원인:** amdgpu 의 `power1_input` 은 칩마다 단위와 뜻이 다릅니다. 780M 의 `power1_input` 은 순간값이라 18~37 W 로 튀었고(같은 때 `power1_average` 와 RAPL 은 약 16 W), 610M 은 µW 로 읽으면 0.012 W 였습니다.
- **해결:** `power1_average` 가 있으면 그것을 쓰고, 없으면 `power1_input` 에 호스트별 배율(`host_metrics_gpu_ppt_scale`)을 곱합니다.

</details>

## 마무리

Proxmox 노드마다 호스트 전체의 부하·온도·전력이 10초마다 Home Assistant 센서와 지역·허브 DB 의 `readings` 에 들어오고, 전력 플러그와 같은 `anchor` 로 부하와 벽 전력을 맞춰 볼 수 있습니다. 디스크·인터페이스가 다른 서버는 인벤토리에서 `host_metrics_*` 를 덮어쓰고 플레이북을 다시 실행하면, 발견 설정이 새 필드에 맞춰 센서를 더하거나 지웁니다.

## 참고 자료

- [Telegraf - Plugin directory](https://docs.influxdata.com/telegraf/v1/plugins/)
- [Telegraf - Starlark Processor](https://github.com/influxdata/telegraf/tree/master/plugins/processors/starlark)
- [Telegraf - Merge Aggregator](https://github.com/influxdata/telegraf/tree/master/plugins/aggregators/merge)
- [Telegraf - MQTT Producer Output](https://github.com/influxdata/telegraf/tree/master/plugins/outputs/mqtt)
- [Home Assistant - MQTT Discovery](https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery)
- [Linux kernel - amdgpu hwmon interfaces](https://docs.kernel.org/gpu/amdgpu/thermal.html)
- [Linux kernel - Power Capping Framework](https://docs.kernel.org/power/powercap/powercap.html)
- [TimescaleDB - Compression](https://docs.timescale.com/use-timescale/latest/compression/)
