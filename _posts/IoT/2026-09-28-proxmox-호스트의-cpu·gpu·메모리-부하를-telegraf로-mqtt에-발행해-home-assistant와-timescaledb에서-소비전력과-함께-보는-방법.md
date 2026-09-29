---
layout: post
title: Proxmox 호스트의 CPU·GPU·메모리 부하를 Telegraf로 MQTT에 발행해 Home Assistant와 TimescaleDB에서 소비전력과 함께 보는 방법
description: VM·CT 안에서는 보이지 않는 Proxmox 호스트 전체의 CPU·메모리·디스크·네트워크·온도·전력·iGPU 값을 호스트의 Telegraf 가 10초마다 MQTT 로 발행하고, Home Assistant 에는 발견 설정으로 센서를 만들고 TimescaleDB 에는 전력 플러그와 같은 제품 키로 기록해 부하와 벽 전력을 맞춰 보는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, ansible, telegraf, mqtt, home-assistant, timescaledb, iot, homelab]
permalink: /posts/74/
---

Proxmox 호스트에 **[Telegraf](/posts/82/)** 를 설치해 호스트 전체(VM·CT 를 합한 값)의 CPU·메모리·디스크·네트워크·온도·전력·iGPU 값을 10초마다 JSON 메시지 하나로 엣지 브로커의 `hosts/[기기 이름]` 에 발행합니다. 같은 호스트가 필드마다 **[MQTT 발견 설정](/posts/78/)**을 내므로 Home Assistant 에 센서가 자동으로 생기고, 엣지 Telegraf 가 같은 토픽을 받아 `readings` 테이블에 넣습니다. 기기 이름의 기준 칸을 그 서버가 꽂힌 전력 플러그와 같은 제품 키로 두어, DB 에서 "CPU 사용률이 얼마일 때 벽 전력이 얼마인지" 를 `anchor` 하나로 맞춰 봅니다. 설치는 [내부망 DNS 글](/posts/41/)에서 만든 Ansible 저장소에 플레이북 하나를 더해 모든 Proxmox 노드에 똑같이 합니다.

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

엣지 Telegraf 가 이름을 나눠 `room` 은 `bedroom2`, `device` 는 `host`, `anchor` 는 `server_ms_a2_1` 로 넣으므로 플러그 행과 `anchor` 가 같습니다. 실물 ID(`hw_id`)에는 메인보드 시리얼이 들어가 부품을 바꿔도 같은 이름으로 이어지고 교체 이력이 남습니다. 이름에 `/` 는 쓰지 않습니다(토픽이 두 단계가 되어 수집되지 않음).

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
host_metrics_mounts: [/]                      # 용량을 잴 마운트(호스트 루트). 호스트마다 다르면 inventory 에서 덮어씁니다
host_metrics_disks: [nvme0n1]                 # IO·온도·수명을 잴 물리 디스크(VM 디스크인 dm-* 는 뺌). 여럿이면 가장 높은 값으로 묶습니다
host_metrics_drm_card: card0                  # iGPU 의 /sys/class/drm/<카드>
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
        pve02:
          ansible_host: [PVE02_IP]
          ansible_user: root
          host_metrics_name: bedroom2-host-server_k12_1
```
{: file="inventory.yml (proxmox 그룹 부분)" }

- **확인:** `ansible-inventory --host pve01` 에 `host_metrics_name` 과 `host_metrics_broker` 가 보이고, 브로커는 `[EDGE_SERVICE_VIP]:1883` 으로 풀립니다.

## 3. 템플릿과 발견 설정 스크립트

파일 여섯 개를 저장소에 둡니다. 모두 여러 번 실행해도 결과가 같습니다.

| 파일 | 하는 일 |
| :--- | :--- |
| `templates/host-metrics/telegraf.conf.j2` | 입력(cpu, system, mem, swap, disk, diskio, temp, smart, exec) → starlark 로 부품별 대표 필드 → merge 로 10초에 메시지 하나 → MQTT |
| `templates/host-metrics/host-sysfs.sh.j2` | 기본 입력이 못 읽는 값: 코어 클럭 평균, RAPL 누적 에너지, iGPU 사용률·메모리(VRAM+GTT) |
| `scripts/host-metrics-discovery.py` | 실제 메시지를 받아 필드마다 Home Assistant 발견 설정을 맞추고, 없어진 필드의 센서는 지웁니다 |
| `scripts/host-availability.py` | 호스트 연결 상태를 `hosts/[기기 이름]/availability` 에 `online`·`offline` 으로 알리는 상주 스크립트 |
| `templates/host-metrics/host-availability.service.j2` | 위 스크립트를 Telegraf 와 함께 켜고 함께 멈추는 systemd 서비스 |
| `playbooks/host-metrics.yml` | 설치, 권한, 설정 배포, 연결 상태 서비스, 발견 설정 |

필드 이름은 `<부품>_<값>` 이고 뜻마다 이름 하나만 씁니다. 값은 `usage`(활동률 %), `used_percent`(용량 사용률 %), `used`·`total`(사용량·용량 B), `power`(W), `clock`(MHz), `temp`(°C), `load`(1분 부하 평균, 단위 없음) 입니다. `cpu_load` 를 `cpu_cores` 로 나누면 CPU 사용률이 100% 에 닿은 뒤에도 코어 수 대비 몇 배로 밀렸는지 봅니다.
목적이 발열·소비전력이라 부품마다 대표값 하나씩만 보내고, 같은 것을 여러 번 재는 값은 뺍니다. 예를 들어 Ryzen 은 k10temp 가 칩 전체의 제어 온도(Tctl)와 코어 다이별 온도(Tccd1·Tccd2)를 따로 알려 주는데, 팬·부스트가 기준으로 삼는 Tctl 만 씁니다. NVMe 도 센서가 세 개지만 대표값(Composite)만 씁니다.
메모리 모듈이나 디스크처럼 장치가 여럿인 값은 가장 높은 값 하나로 묶어 호스트끼리 같은 이름으로 비교합니다.

| 부품 | 필드 | 내용 |
| :--- | :--- | :--- |
| CPU | `cpu_usage`, `cpu_load`, `cpu_power`, `cpu_clock`, `cpu_temp` | 사용률, 1분 부하 평균, RAPL 패키지 전력(iGPU 포함), 코어 클럭 평균, k10temp Tctl |
| GPU | `gpu_usage`, `gpu_temp`, `gpu_mem_used` | 사용률, amdgpu edge 온도, VRAM+GTT 사용량(B) |
| 메모리 | `mem_used_percent`, `mem_temp`, `swap_used_percent` | 사용률, DIMM 온도(최대), 스왑 사용률 |
| 디스크 | `disk_used_percent`, `disk_usage`, `disk_temp` | 호스트 `/` 사용률, IO 사용 시간(최대), NVMe 온도(최대) |
| 시스템 | `system_uptime` | 가동 시간(초). 값이 줄면 재부팅입니다 |

거의 바뀌지 않는 값은 바뀔 때와 1시간마다 한 번만 보냅니다. 용량 부족 시기를 예측하고 장애 원인을 찾을 때 쓰는 값입니다.

| 필드 | 내용 |
| :--- | :--- |
| `cpu_cores`, `cpu_threads`, `mem_total`, `disk_total` | 사양(물리 코어, 논리 프로세서, 메모리·디스크 용량). CPU 모델·메모리 구성 같은 원문은 DB 의 제품 표(`appliance_specs`)가 맡습니다 |
| `disk_wear_percent`, `disk_health_ok` | NVMe 수명 사용률과 SMART 상태(정상 1) |

GPU 전력은 수집하지 않습니다. amdgpu 가 알리는 값을 610M 에 추론을 걸어 확인해 보니 GPU 부하를 따라가지 않았습니다. hwmon 의 PPT 는 780M 에서는 패키지 전체(`cpu_power` 와 같은 값)였고, 610M 에서는 GPU 가 놀고 CPU 가 바쁠 때가 GPU 100% 일 때보다 두 배 높았습니다. 표 형태로 여러 전력을 알리는 `gpu_metrics` 의 `average_gfx_power` 는 두 칩 모두 GPU 활동과 무관하게 수천~6만 사이를 널뛰었습니다. iGPU 전력은 RAPL 패키지 전력(`cpu_power`)에 포함되므로, GPU 활동은 `gpu_usage` 로 보고 전력은 `cpu_power` 와 플러그의 벽 전력으로 봅니다.

`gpu_mem_used` 는 BIOS 가 떼어 둔 VRAM(pve01 2GiB, pve02 512MiB)과 시스템 RAM 을 빌려 쓰는 GTT 를 합한 값입니다. iGPU 로 모델을 올리면 큰 쪽은 GTT 입니다(610M 추론 때 VRAM 2.1GB, GTT 3.4GB).

<details markdown="1">
<summary>templates/host-metrics/telegraf.conf.j2 전문</summary>

{% raw %}
```toml
# 호스트 Telegraf. proxmox-ansible playbooks/host-metrics.yml 이 templates/host-metrics/telegraf.conf.j2 에서 만듭니다(여기서 고치지 않습니다).
# 호스트 전체(VM·CT 합)의 대표값을 10초마다 모아 JSON 메시지 하나로 hosts/{{ host_metrics_name }} 에 발행합니다.
#   {"name": "host", "fields": {"cpu_usage": 3.9, "cpu_load": 2.4, "cpu_power": 29.9, "cpu_temp": 55.9, ...}, "tags": {}, "timestamp": <ms>}
# 목적은 발열·소비전력 분석과 서버 상태 파악이라 부품마다 대표값 하나씩만 냅니다(필드 이름 <부품>_<값>).
# 같은 것을 여러 번 재는 값(코어 다이별 온도, NVMe 보조 센서, 코어 전력 등)은 내지 않고, 장치가 여럿인 값(DIMM 온도, 디스크)은 가장 높은 값으로 묶습니다.
# 거의 바뀌지 않는 값(사양·수명)은 바뀔 때와 1시간마다 한 번만 냅니다.
# Home Assistant 센서는 host-metrics-discovery.py 가 이 필드들로 만들고, 엣지 Telegraf 가 같은 토픽을 받아 DB readings 에 넣습니다.
# 필드 목록을 바꾸면 scripts/host-metrics-discovery.py 의 SENSORS·SLOW_FIELDS 와 엣지 Telegraf 의 HOST_UNITS(k8s-gitops iot/edge/telegraf)도 맞춥니다.
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

[[inputs.system]]                     # 1분 부하 평균, 물리·논리 코어 수, 가동 시간

[[inputs.mem]]

[[inputs.swap]]

[[inputs.disk]]
  mount_points = {{ host_metrics_mounts | to_json }}

[[inputs.diskio]]
  devices = {{ host_metrics_disks | to_json }}
  skip_serial_number = true

[[inputs.temp]]                       # hwmon 의 온도. 아래 starlark 가 CPU(Tctl)·GPU·메모리·디스크만 고릅니다
  add_device_tag = true               # 같은 칩이 둘인 메모리(spd5118)를 주소로 나눕니다

[[inputs.smart]]
  interval = "1m"                     # 수명·상태는 느리게 바뀝니다. 아래 starlark 가 바뀔 때와 1시간마다 한 번만 내보냅니다
  use_sudo = true

[[inputs.exec]]
  commands = [["/usr/local/lib/telegraf-host-sysfs.sh"]]   # CPU 클럭, RAPL 전력, iGPU 사용률·메모리 (templates/host-metrics/host-sysfs.sh.j2)
  data_format = "influx"
  timeout = "5s"

# 입력마다 다른 측정값·태그를 host 측정값 하나의 대표 필드로 바꿉니다. 시각은 10초 단위로 내려 아래 merge 가 한 메시지로 묶게 합니다.
[[processors.starlark]]
  source = '''
BUCKET = 10 * 1000 * 1000 * 1000
SLOW_PERIOD = 3600 * 1000 * 1000 * 1000   # 사양·수명은 바뀔 때와 이 간격마다 한 번만 냅니다
# hwmon 센서 이름 → 필드. CPU 는 칩 전체의 제어 온도(Tctl)만, 디스크는 대표값(composite)만 씁니다
TEMPS = {"k10temp_tctl": "cpu_temp", "amdgpu_edge": "gpu_temp", "spd5118": "mem_temp", "nvme_composite": "disk_temp"}
MAX_FIELDS = ["mem_temp", "disk_temp", "disk_usage", "disk_wear_percent"]   # 장치가 여럿이면 가장 높은 값
MIN_FIELDS = ["disk_health_ok"]                                            # 하나라도 이상하면 0
SLOW_FIELDS = ["cpu_cores", "cpu_threads", "mem_total", "disk_total", "disk_wear_percent", "disk_health_ok"]

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

def fold(field, value, bucket):
    # 장치가 여럿인 값은 지금까지의 최대(또는 최소)를 냅니다. merge 가 같은 필드의 마지막 값을 남기므로 마지막이 곧 그 칸의 최대입니다
    if field not in MAX_FIELDS and field not in MIN_FIELDS:
        return value
    key = "fold_" + field
    prev = state.get(key)
    if prev != None and prev[0] == bucket:
        value = max([prev[1], value]) if field in MAX_FIELDS else min([prev[1], value])
    state[key] = (bucket, value)
    return value

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
        out["cpu_load"] = f.get("load1")
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
    elif n == "diskio":
        busy = rate("io_time_" + tags["name"], f["io_time"], t)      # ms/s → %
        out["disk_usage"] = min([busy / 10, 100]) if busy != None else None
    elif n == "temp":
        sensor = tags.get("sensor", "")
        field = TEMPS.get(sensor)
        if field == None and sensor.startswith("spd5118"):           # 메모리 칩은 라벨이 없어 센서 이름만 옵니다
            field = "mem_temp"
        if field != None:
            out[field] = f.get("temp")
    elif n == "smart_device":
        out["disk_wear_percent"] = f.get("percentage_used")
        ok = f.get("health_ok")
        if ok != None:
            out["disk_health_ok"] = 1.0 if ok else 0.0
    elif n == "sysfs":
        for k in ("cpu_clock", "gpu_usage", "gpu_mem_used"):
            out[k] = f.get(k)
        if "rapl_energy_uj" in f:
            w = rate("rapl", f["rapl_energy_uj"], t, f.get("rapl_max_uj", 0))
            out["cpu_power"] = w / 1e6 if w != None else None
    return out

def apply(metric):
    bucket = metric.time - metric.time % BUCKET
    m = Metric("host")
    m.time = bucket
    n = 0
    for k, v in fields_of(metric).items():
        if v == None:
            continue
        v = fold(k, float(v), bucket)
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
#   CPU 클럭: 코어별 현재 클럭의 평균(MHz)
#   RAPL: 패키지 누적 에너지(µJ)와 되돌아가는 상한. 초당 값(W)은 Telegraf starlark 가 이전 값과의 차로 구합니다. iGPU 전력도 여기 포함됩니다
#   iGPU: 사용률, 메모리 사용량(바이트) = VRAM(BIOS 가 떼어 둔 몫) + GTT(시스템 RAM 을 빌려 쓴 몫). iGPU 로 추론하면 큰 쪽은 GTT 입니다
# GPU 전력은 읽지 않습니다. amdgpu hwmon 의 PPT 는 780M 에서는 패키지 전체, 610M 에서는 GPU 부하와 무관하게 패키지 전력을 따라갔고,
# gpu_metrics 의 average_gfx_power 는 두 칩 모두 GPU 활동과 무관하게 널뛰었습니다(2026-09-28 610M 추론으로 확인).
# RAPL energy_uj 는 root 만 읽을 수 있어 telegraf 서비스에 CAP_DAC_READ_SEARCH 를 줍니다(systemd 드롭인).
fields=()
add() { [[ -n $2 ]] && fields+=("$1=$2"); }
val() { [[ -r $1 ]] && tr -d '\n' < "$1"; }

add cpu_clock "$(cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq 2>/dev/null |
  awk '{ s += $1 } END { if (NR) printf "%.0f", s / NR / 1000 }')"

zone=/sys/class/powercap/intel-rapl:0                  # 패키지 전체(코어 영역 intel-rapl:0:0 은 여기에 포함되어 따로 읽지 않습니다)
if [[ -r $zone/energy_uj ]]; then
  add rapl_energy_uj "$(val "$zone/energy_uj")"
  add rapl_max_uj "$(val "$zone/max_energy_range_uj")"
fi

gpu=/sys/class/drm/{{ host_metrics_drm_card }}/device
if [[ -d $gpu ]]; then
  add gpu_usage "$(val "$gpu/gpu_busy_percent")"
  vram=$(val "$gpu/mem_info_vram_used"); gtt=$(val "$gpu/mem_info_gtt_used")
  [[ -n $vram && -n $gtt ]] && add gpu_mem_used "$((vram + gtt))"
fi

(IFS=,; echo "sysfs ${fields[*]}")
```
{: file="templates/host-metrics/host-sysfs.sh.j2" }
{% endraw %}

</details>

발견 설정은 센서 목록을 따로 적지 않고 75초 동안 받은 메시지의 필드로 만듭니다(1시간에 한 번 오는 값도 1분에 한 번은 후보로 올라오게 해 두었습니다). 필드 표로 한국어 이름·단위·`device_class` 를 붙이고, 표에 없는 새 필드도 이름 그대로 센서로 만듭니다. `value_template` 은 필드가 빠진 메시지에서 이전 상태를 유지합니다. 모든 센서가 연결 상태 토픽 `hosts/[기기 이름]/availability` 를 따르므로 Telegraf 가 멈추거나 호스트가 끊기면 바로 `unavailable` 이 되고, `expire_after` 60초는 연결은 살아 있는데 값만 멈춘 경우를 잡습니다. 1시간에 한 번 오는 값에는 만료를 두지 않고, 창 안에 값이 오지 않아도 그 센서의 설정은 지우지 않습니다. 호스트의 파이썬과 apt 패키지 `python3-paho-mqtt` 만 씁니다.

<details markdown="1">
<summary>scripts/host-metrics-discovery.py 전문</summary>

{% raw %}
```python
#!/usr/bin/python3
"""호스트 Telegraf 가 hosts/<기기> 에 내는 필드마다 Home Assistant MQTT 발견 설정을 맞춘다.

playbooks/host-metrics.yml 이 호스트에 복사해 실행한다. 호스트의 python3 와 apt 패키지 python3-paho-mqtt 만 쓴다.
실제 메시지를 받아 그 필드로 센서 목록을 정하므로 수집 항목이 늘거나 줄어도 설정을 따로 적지 않는다.
- 필드는 --window 초 동안 받은 모든 상태 메시지의 합집합이다. 느린 필드(사양·수명)는 1분에 한 번 이상 후보로 올라오므로 창을 그보다 길게 둔다.
- 브로커에 남아 있는(retained) 설정과 비교해 내용이 다르거나 없는 것만 발행한다(다시 실행해도 같은 결과).
- 필드가 없어진 센서는 빈 retained 메시지로 지운다(HA 에서 엔티티가 사라짐). 단 느린 필드(SLOW_FIELDS)의 설정은
  창 안에 값이 안 왔을 수 있으므로 지우지 않는다.
- 모든 센서는 hosts/<기기>/availability(host-availability.py 가 내는 연결 상태)를 따른다. Telegraf 가 멈추거나 호스트가
  끊기면 HA 엔티티가 바로 "사용할 수 없음" 이 된다(expire_after 는 연결은 살아 있는데 값만 멈춘 경우를 잡는다).
엣지 Telegraf(k8s-gitops iot/edge/telegraf)는 이 설정의 unit_of_measurement 를 DB readings.unit 으로,
device 의 manufacturer·model·serial_number 를 vendor·model·hw_id 로 쓴다.
구조: 순수 함수(sensor_meta, build_configs, diff) → 브로커 함수(collect, publish) → CLI(build_parser, main).
"""

from __future__ import annotations

import argparse
import json
import logging
import os
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
}  # 엣지 Telegraf 가 이 발견 설정만 골라 단위·실물 정보를 읽는 표식
EXPIRE_AFTER = 60  # 초. 호스트나 Telegraf 가 멈추면 센서가 unavailable 이 된다

# 호스트가 바뀔 때와 1시간마다 한 번만 내는 값(사양·수명). expire_after 를 두지 않고, 창 안에 없어도 설정을 지우지 않는다
SLOW_FIELDS = (
    "cpu_cores",
    "cpu_threads",
    "mem_total",
    "disk_total",
    "disk_wear_percent",
    "disk_health_ok",
)

log = logging.getLogger(Path(__file__).stem)

PERCENT = {"unit_of_measurement": "%", "suggested_display_precision": 1}
BYTES = {"unit_of_measurement": "B", "device_class": "data_size"}
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
MHZ = {"unit_of_measurement": "MHz", "device_class": "frequency"}
DIAG = {"entity_category": "diagnostic"}

# 필드 → (이름, 속성). 필드 이름은 <부품>_<값> 이고 부품마다 대표값 하나씩이라 규칙 대신 표로 둔다.
# 단위는 엣지 Telegraf 의 HOST_UNITS(k8s-gitops iot/edge/telegraf, 필드 이름 끝으로 정하는 예비 단위)와 같아야 한다
SENSORS = {
    "cpu_usage": ("CPU 사용률", PERCENT),
    "cpu_load": ("CPU 부하 평균", {"suggested_display_precision": 2}),
    "cpu_power": ("CPU 전력", WATT),
    "cpu_clock": ("CPU 클럭", MHZ),
    "cpu_temp": ("CPU 온도", CELSIUS),
    "gpu_usage": ("GPU 사용률", PERCENT),
    "gpu_temp": ("GPU 온도", CELSIUS),
    "gpu_mem_used": ("GPU 메모리 사용량", BYTES),
    "mem_used_percent": ("메모리 사용률", PERCENT),
    "mem_temp": ("메모리 온도", CELSIUS),
    "swap_used_percent": ("스왑 사용률", PERCENT),
    "disk_used_percent": ("디스크 사용률", PERCENT),
    "disk_usage": ("디스크 사용 시간", PERCENT),
    "disk_temp": ("디스크 온도", CELSIUS),
    "system_uptime": (
        "가동 시간",
        {"unit_of_measurement": "s", "device_class": "duration"} | DIAG,
    ),
    "cpu_cores": ("CPU 코어 수", DIAG),
    "cpu_threads": ("CPU 스레드 수", DIAG),
    "mem_total": ("메모리 용량", BYTES | DIAG),
    "disk_total": ("디스크 용량", BYTES | DIAG),
    "disk_wear_percent": ("디스크 수명 사용률", PERCENT | DIAG),
    "disk_health_ok": ("디스크 상태 정상", DIAG),
}


def sensor_meta(field: str) -> dict:
    """필드 이름으로 센서 이름·단위·분류를 정한다. 표에 없는 새 필드는 이름만 필드 그대로 준다."""
    if field in SENSORS:
        name, attrs = SENSORS[field]
        return {"name": name} | attrs
    return {"name": field}


def build_configs(
    device: str,
    fields: dict[str, float],
    manufacturer: str,
    model: str,
    serial: str = "",
) -> dict[str, dict]:
    """필드마다 발견 설정(토픽 → 내용)을 만든다."""
    info = {"identifiers": [device], "name": device}
    if manufacturer:
        info["manufacturer"] = manufacturer
    if model:
        info["model"] = model
    if serial:
        info["serial_number"] = serial  # 엣지 Telegraf 가 readings.hw_id 로 쓴다
    configs = {}
    for field in sorted(fields):
        meta = sensor_meta(field)
        config = {
            "name": meta.pop("name"),
            "unique_id": f"{device}_{field}",
            "default_entity_id": f"sensor.{device}_{field}",
            "state_topic": f"{STATE_PREFIX}/{device}",
            # 필드가 빠진 메시지(느린 값이 없는 주기)는 이전 상태를 유지한다
            "value_template": (
                f"{{{{ value_json.fields['{field}'] "
                f"if '{field}' in value_json.fields else this.state }}}}"
            ),
            "state_class": "measurement",
            "availability": [
                {
                    "topic": f"{STATE_PREFIX}/{device}/availability",
                    "value_template": "{{ value_json.state }}",
                }
            ],
            "device": info,
            "origin": ORIGIN,
        }
        if field not in SLOW_FIELDS:
            # 느린 값은 1시간에 한 번만 오므로 만료를 두지 않는다
            config["expire_after"] = EXPIRE_AFTER
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
    remove = sorted(
        t
        for t in existing
        if t not in wanted and t.rsplit("/", 2)[-2] not in SLOW_FIELDS
    )
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


def collect(client, device: str, window: float) -> tuple[dict, dict]:
    """window 초 동안 받은 상태 메시지의 필드 합집합과 이 기기의 기존 발견 설정(retained)을 모은다."""
    fields: dict[str, float] = {}
    existing: dict[str, str] = {}
    config_filter = f"{DISCOVERY_PREFIX}/sensor/{device}/+/config"
    state_topic = f"{STATE_PREFIX}/{device}"

    def on_message(_client, _userdata, msg) -> None:
        if msg.topic == state_topic:
            fields.update(json.loads(msg.payload).get("fields", {}))
        elif msg.retain and msg.payload:
            existing[msg.topic] = msg.payload.decode()

    client.on_message = on_message
    client.subscribe([(config_filter, 1), (state_topic, 1)])
    deadline = time.monotonic() + window
    while time.monotonic() < deadline:
        time.sleep(0.5)
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
        "--serial",
        default="",
        help="실물 기기 ID(메인보드 시리얼). DB 의 hw_id 가 된다",
    )
    parser.add_argument(
        "--window",
        type=float,
        default=75,
        help="필드를 모을 초(기본 75. 1분에 한 번 오는 느린 값까지 받으려면 60 보다 길게 둔다)",
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
        fields, existing = collect(client, args.device, args.window)
        if not fields:
            log.error(
                "%s 초 동안 %s/%s 메시지를 받지 못했다",
                args.window,
                STATE_PREFIX,
                args.device,
            )
            return EXIT_FAILED
        wanted = build_configs(
            args.device, fields, args.manufacturer, args.model, args.serial
        )
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

호스트 Telegraf 의 MQTT 출력에는 Last Will 이 없어, Telegraf 가 멈추거나 호스트가 꺼져도 브로커가 알려 주지 않습니다. 연결 상태는 따로 상주하는 스크립트가 Zigbee2MQTT 와 같은 모양(`{"state": "online"}`)으로 `hosts/[기기 이름]/availability` 에 알립니다. 브로커에 붙을 때마다 `online` 을 유지 메시지로 내고, 서비스가 멈출 때 `offline` 을 내며, 호스트가 꺼지거나 네트워크가 끊기면 브로커가 45초쯤 뒤 Last Will 로 `offline` 을 냅니다. 서비스는 `BindsTo=telegraf.service` 로 Telegraf 에 묶여 Telegraf 가 멈추거나 죽으면 함께 멈추고, `WantedBy=telegraf.service` 로 Telegraf 와 함께 켜집니다. 비밀번호는 Telegraf 와 같은 `/etc/default/telegraf` 에서 읽습니다.

<details markdown="1">
<summary>scripts/host-availability.py 전문</summary>

```python
#!/usr/bin/python3
"""호스트 연결 상태를 hosts/<기기>/availability 에 알린다(Zigbee2MQTT 와 같은 {"state": "online"|"offline"}).

playbooks/host-metrics.yml 이 호스트에 복사하고 systemd 서비스 host-availability 로 상주시킨다. 호스트의 python3 와
apt 패키지 python3-paho-mqtt 만 쓴다. 호스트 Telegraf 의 MQTT 출력에는 Last Will 이 없어 이 서비스가 대신 알린다.
- 브로커에 붙을 때마다 online 을 retained 로 낸다.
- SIGTERM(서비스 정지. telegraf.service 에 BindsTo 로 묶여 Telegraf 가 멈추면 함께 멈춘다)을 받으면 offline 을 내고 끝낸다.
- 호스트가 꺼지거나 네트워크가 끊기면 브로커가 keepalive 의 1.5배 뒤에 Last Will 로 offline 을 낸다.
HA 발견 설정(host-metrics-discovery.py)의 availability 와 엣지 Telegraf 의 hosts/+/availability 입력이 이 토픽을 쓴다.
구조: 순수 함수(availability_topic, availability_payload) → 브로커 함수(run) → CLI(build_parser, main).
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import sys
import threading
from pathlib import Path

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2

STATE_PREFIX = "hosts"
KEEPALIVE = 30  # 초. 끊긴 뒤 약 45초 안에 브로커가 offline 을 낸다

log = logging.getLogger(Path(__file__).stem)


def availability_topic(device: str) -> str:
    """기기 연결 상태 토픽."""
    return f"{STATE_PREFIX}/{device}/availability"


def availability_payload(online: bool) -> str:
    """연결 상태 페이로드. Zigbee2MQTT 와 같은 모양이라 엣지 Telegraf 가 같은 방식으로 읽는다."""
    return json.dumps({"state": "online" if online else "offline"})


def run(
    broker: str, user: str, password: str, device: str, stop: threading.Event
) -> int:
    """stop 이 설정될 때까지 연결을 유지하며 online 을 알리고, 끝날 때 offline 을 알린다. 알린 횟수를 준다."""
    import paho.mqtt.client as mqtt  # 테스트에서 순수 함수만 쓸 때 paho 없이 불러오게 한다

    topic = availability_topic(device)
    announced = 0

    def on_connect(client, _userdata, _flags, reason_code, _properties) -> None:
        nonlocal announced
        if reason_code != 0:
            log.warning("브로커 연결 실패: %s", reason_code)
            return
        # 끊겼던 동안 브로커가 Last Will 로 offline 을 냈을 수 있으므로 붙을 때마다 알린다
        client.publish(topic, availability_payload(True), qos=1, retain=True)
        announced += 1
        log.info("online: %s", topic)

    host, _, port = broker.rpartition(":")
    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2, client_id=f"host-availability-{device}"
    )
    client.username_pw_set(user, password)
    client.will_set(topic, availability_payload(False), qos=1, retain=True)
    client.on_connect = on_connect
    client.connect_async(host, int(port), keepalive=KEEPALIVE)
    client.loop_start()
    stop.wait()
    # 정상 종료에서는 브로커가 Last Will 을 내지 않으므로 직접 알린다
    info = client.publish(topic, availability_payload(False), qos=1, retain=True)
    try:
        info.wait_for_publish(timeout=5)
        log.info("offline: %s", topic)
    except (RuntimeError, ValueError) as exc:
        log.warning("offline 발행 확인 실패: %s", exc)
    client.loop_stop()
    client.disconnect()
    return announced


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="호스트 연결 상태를 hosts/<기기>/availability 에 알린다(상주).",
        epilog=(
            "예:\n"
            "  MQTT_PASSWORD=… host-availability.py --broker <브로커 주소>:1883 "
            "--user devices --device bedroom2-host-server_ms_a2_1\n\n"
            "비밀번호: 환경 변수 MQTT_PASSWORD\n"
            "SIGTERM·SIGINT 를 받으면 offline 을 알리고 끝낸다.\n"
            '출력: 끝날 때 stdout 에 {"device", "topic", "online_announced"} JSON\n'
            "exit code: 0 정상 종료, 1 브로커 주소 오류, 2 사용법 오류"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--broker", required=True, help="호스트:포트")
    parser.add_argument("--user", required=True, help="브로커 계정")
    parser.add_argument(
        "--device", required=True, help="기기 이름(hosts/<기기> 의 <기기>)"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.INFO, format="%(levelname)s %(message)s", stream=sys.stderr
    )
    password = os.environ.get("MQTT_PASSWORD")
    if not password:
        log.error("브로커 비밀번호가 필요하다: 환경 변수 MQTT_PASSWORD 를 설정한다")
        return EXIT_USAGE
    if ":" not in args.broker:
        log.error("--broker 는 호스트:포트 형식이다: %s", args.broker)
        return EXIT_FAILED

    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    announced = run(args.broker, args.user, password, args.device, stop)
    json.dump(
        {
            "device": args.device,
            "topic": availability_topic(args.device),
            "online_announced": announced,
        },
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
```
{: file="scripts/host-availability.py" }

</details>

<details markdown="1">
<summary>templates/host-metrics/host-availability.service.j2 전문</summary>

{% raw %}
```ini
# 호스트 연결 상태 알림(scripts/host-availability.py). playbooks/host-metrics.yml 이 설치합니다.
# Telegraf 와 함께 켜지고(WantedBy) 함께 멈춥니다(BindsTo. Telegraf 가 죽어도 멈춤). 멈출 때 offline 을 알립니다.
[Unit]
Description=호스트 연결 상태를 MQTT hosts/{{ host_metrics_name }}/availability 에 알림
BindsTo=telegraf.service
After=telegraf.service network-online.target
Wants=network-online.target

[Service]
User=telegraf
EnvironmentFile=/etc/default/telegraf
ExecStart=/usr/local/lib/host-availability.py --broker {{ host_metrics_broker }} --user {{ host_metrics_mqtt_user }} --device {{ host_metrics_name }}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=telegraf.service
```
{: file="templates/host-metrics/host-availability.service.j2" }
{% endraw %}

</details>

플레이북은 InfluxData 저장소에서 엣지와 같은 버전의 Telegraf 를 설치하고 버전을 고정합니다. SMART 조회는 root 가 필요하므로 Proxmox 에 기본으로 없는 `sudo` 를 설치해 `smartctl`·`nvme` 만 허용하고, RAPL `energy_uj` 는 root 만 읽을 수 있어 서비스에 읽기 권한 검사를 건너뛰는 능력(`CAP_DAC_READ_SEARCH`) 하나만 줍니다. 센서를 새로 만들었을 때는 마지막에 Telegraf 를 한 번 더 시작합니다. 1시간에 한 번 오는 값이 발견 설정보다 먼저 발행되면 Home Assistant 가 다음 주기까지 그 센서를 비워 두기 때문입니다.

<details markdown="1">
<summary>playbooks/host-metrics.yml 전문</summary>

{% raw %}
```yaml
# Proxmox 호스트 자체(VM·CT 를 합한 호스트 전체)의 CPU·메모리·디스크·네트워크·온도·전력·GPU 값을 Telegraf 로 모아 MQTT 에 발행합니다.
# 10초마다 JSON 메시지 하나를 hosts/<host_metrics_name> 에 내고, Home Assistant MQTT 발견 설정을 만들어 센서로 보이게 합니다.
# DB 기록은 엣지 Telegraf(k8s-gitops iot/edge/telegraf)가 같은 토픽을 받아 readings 에 넣습니다.
# 연결 상태는 host-availability 서비스가 hosts/<host_metrics_name>/availability 에 알립니다(Telegraf 에는 Last Will 이 없음).
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
          - sudo                 # smart 입력이 root 로 조회(Proxmox 에는 기본으로 없음)
        update_cache: true
    - name: 버전 고정 (apt upgrade 로 엣지와 버전이 갈라지지 않게)
      ansible.builtin.dpkg_selections:
        name: telegraf
        selection: hold

    - name: sudo 허용 (SMART 조회만)
      ansible.builtin.copy:
        dest: /etc/sudoers.d/telegraf
        mode: "0440"
        validate: visudo -cf %s
        content: |
          Cmnd_Alias TELEGRAF_HOST = /usr/sbin/smartctl, /usr/sbin/nvme
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

    # 발견 설정이 availability 를 가리키기 전에 연결 상태를 먼저 알려 HA 엔티티가 잠깐 "사용할 수 없음" 이 되지 않게 합니다
    - name: 연결 상태 스크립트
      ansible.builtin.copy:
        src: ../scripts/host-availability.py
        dest: /usr/local/lib/host-availability.py
        mode: "0755"
      notify: host-availability 재시작
    - name: 연결 상태 서비스
      ansible.builtin.template:
        src: ../templates/host-metrics/host-availability.service.j2
        dest: /etc/systemd/system/host-availability.service
        mode: "0644"
      notify: host-availability 재시작
    - name: 연결 상태 서비스 켜기
      ansible.builtin.systemd:
        name: host-availability
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
    - name: host-availability 재시작
      ansible.builtin.systemd:
        name: host-availability
        state: restarted
        daemon_reload: true
  post_tasks:
    - name: 재시작 반영
      ansible.builtin.meta: flush_handlers
    # 75초 동안 메시지를 받아 필드마다 센서를 만들고, 없어진 필드의 센서는 지웁니다. 내용이 같으면 발행하지 않습니다
    # 실물 ID(hw_id)는 메인보드 시리얼입니다. 제품 시리얼은 메인보드에 값을 넣지 않은 기기가 있어(pve02 는 "Default string") 쓰지 않습니다
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
          - --serial
          - "{{ ansible_facts['board_serial'] }}"
      environment:
        MQTT_PASSWORD: "{{ mqtt_password }}"
      register: discovery
      changed_when: (discovery.stdout | from_json).changed > 0
    # 느린 값(사양·수명)은 발견 설정보다 먼저 발행되면 HA 가 다음 1시간 주기까지 unknown 으로 둡니다.
    # 센서를 새로 만든 경우에만 Telegraf 를 다시 시작해 시작 직후 한 번 내는 느린 값을 받게 합니다.
    - name: 새 센서에 느린 값 채우기 (Telegraf 재시작)
      ansible.builtin.systemd:
        name: telegraf
        state: restarted
      when: (discovery.stdout | from_json).published | length > 0
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

- **확인:** `PLAY RECAP` 에 `failed=0` 이고, 같은 명령을 한 번 더 실행하면 `changed=0` 입니다. 브로커에서 메시지를 하나 받아 보면 필드가 15개입니다(Telegraf 가 시작한 직후 한 번과 1시간마다는 사양·수명 6개가 더 붙습니다).

```bash
# 허브 control plane. E 는 엣지 kubeconfig, PW 는 telegraf 계정 비밀번호
E="--kubeconfig k8s-[SITE].yaml"
PW=$(kubectl $E -n telegraf get secret telegraf-credentials -o jsonpath='{.data.MQTT_PASSWORD}' | base64 -d)
kubectl $E -n mosquitto exec deploy/mosquitto -- mosquitto_sub -u telegraf -P "$PW" -t 'hosts/+' -C 1 -v
kubectl $E -n mosquitto exec deploy/mosquitto -- mosquitto_sub -u telegraf -P "$PW" -t 'hosts/+/availability' -C 2 -v
```

```text
hosts/bedroom2-host-server_ms_a2_1 {"fields":{"cpu_clock":4202,"cpu_load":14.56,"cpu_power":83.1,"cpu_temp":89.5,"cpu_usage":47.3,"disk_temp":54.85,"disk_usage":1.1,"disk_used_percent":14.57,"gpu_mem_used":5574176768,"gpu_temp":76,"gpu_usage":0,"mem_temp":57.25,"mem_used_percent":68.84,"swap_used_percent":5.83,"system_uptime":1358761},"name":"host","tags":{},"timestamp":1790605100000}
hosts/bedroom2-host-server_ms_a2_1/availability {"state": "online"}
hosts/bedroom2-host-server_k12_1/availability {"state": "online"}
```

- **확인:** 연결 상태는 유지 메시지라 구독하자마자 호스트마다 `online` 이 보이고(`-C` 는 호스트 수), 호스트에서 `systemctl status host-availability` 가 `active (running)` 입니다. Telegraf 를 멈추면(`systemctl stop telegraf`) 이 서비스도 함께 멈추며 `offline` 을 냅니다.

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

엣지 Telegraf 에 입력 세 개를 추가합니다. 첫 입력이 `hosts/+` 의 `fields` 를 필드별 행으로 받고, 둘째 입력이 `hosts/+/availability` 의 연결 상태를 속성 `availability` 인 행(`online` 1, `offline` 0)으로 받습니다. 셋째 입력은 발견 설정을 받아 단위(`unit_of_measurement`)와 제조사·모델·실물 ID(`serial_number` → `hw_id`)를 [Telegraf 글](/posts/43/)의 공통 starlark 에 기억시킵니다. starlark 는 `origin` 이 `host-metrics`·`nvr-occupancy`·`kma-weather` 인 발견 설정만 쓰므로 Zigbee2MQTT 의 발견 설정은 무시합니다(NVR·날씨 수집기도 같은 입력을 씁니다). Telegraf 재시작 직후에는 공통 starlark 가 발견 설정을 받을 때까지 호스트 값을 잠시 붙잡아 두고, 새 필드가 생긴 직후처럼 발견 설정이 아직 없으면 필드 이름 끝으로 단위를 정해(`HOST_UNITS`) 단위가 빈 행이 생기지 않게 합니다. 이 규칙은 발견 스크립트의 `SENSORS` 표와 같은 값이어야 합니다.

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

# 호스트 연결 상태. 호스트의 host-availability 서비스가 hosts/<기기>/availability 에 유지 메시지 {"state": "online"|"offline"} 을 냅니다.
# offline 은 Telegraf 가 멈출 때(서비스가 함께 멈춤)와 호스트가 끊길 때(Last Will)입니다. 수신 시각으로 남습니다(Zigbee2MQTT 와 같음).
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.mosquitto.svc.cluster.local:1883"]
  topics = ["hosts/+/availability"]
  username = "${MQTT_USER}"
  password = "${MQTT_PASSWORD}"
  client_id = "telegraf-hosts-availability"
  persistent_session = true
  qos = 1
  topic_tag = ""
  name_override = "readings"
  data_format = "json"
  json_string_fields = ["state"]
  [inputs.mqtt_consumer.tags]
    protocol = "mqtt"
    source = "telegraf"
    property = "availability"
  [[inputs.mqtt_consumer.topic_parsing]]
    topic = "hosts/+/availability"
    tags = "_/device/_"

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
{: file="iot/edge/telegraf/telegraf.conf (Zigbee2MQTT 제어 기록 입력 아래에 추가)" }

호스트마다 10초에 15행(하루 약 13만 행)이 늘어나므로 `readings` 의 청크와 압축을 1일로 둡니다. Telegraf 글의 `create_templates` 는 이미 1일이라 새로 만드는 테이블은 그대로 두면 되고, 그 전에 만든 테이블은 지역 DB 와 허브 DB 에 아래 SQL 을 한 번씩 실행합니다. 압축된 청크에도 INSERT·UPDATE·DELETE 는 되므로 늦게 온 버퍼나 날씨 백필은 느려질 뿐 그대로 들어갑니다.

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

- **확인:** Argo CD 의 `[SITE]-telegraf` 가 Synced·Healthy 가 된 뒤 20초쯤 지나면 두 DB 에 호스트 행이 보입니다. 단위가 빈 행은 개수·상태처럼 원래 단위가 없는 값(`cpu_load`, `cpu_cores`, `cpu_threads`, `disk_health_ok`)뿐이고, `hw_id` 에는 메인보드 시리얼이 들어갑니다. Grafana `IoT 기록` 대시보드에는 속성마다 패널이 자동으로 생깁니다.

```sql
select anchor, count(distinct property) as props, max(time) as last, min(hw_id) as hw_id,
       count(*) filter (where coalesce(unit, '') = '') as no_unit
from readings where device = 'host' and time > now() - interval '1 minute' group by 1;
```

연결 상태는 바뀔 때만 행이 생깁니다(Telegraf 가 다시 접속할 때는 유지 메시지로 한 번 더). 호스트마다 마지막 행이 `online`·`1` 이면 됩니다.

```sql
select distinct on (anchor) anchor, time, value_text, value
from readings where device = 'host' and property = 'availability' order by anchor, time desc;
```

## 7. 부하와 소비전력 맞춰 보기

플러그와 호스트는 보고 주기가 달라(플러그 5~8초, 호스트 10초) 1분이나 1시간 평균으로 맞춥니다. 세 번째 쿼리는 방에 들어간 열(플러그 전력 합)과 방 온도·바깥 기온 차·CO2 를 함께 보여, 서버 발열이 실내에 주는 영향을 봅니다.

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
-- 방에 들어간 열(침실2 플러그 전력 합)과 방 온도·바깥 기온 차·CO2. 창문이 열려 있던 시간도 함께 봅니다
-- 플러그는 제품마다 보고 주기가 달라 제품별 평균을 먼저 낸 뒤 합칩니다(시간당 평균 W = 그 시간의 Wh)
WITH plug AS (
  SELECT time_bucket('1 hour', time) AS t, anchor, avg(value) AS w
  FROM readings
  WHERE device = 'plug' AND property = 'power' AND processing = 'raw' AND time > now() - interval '7 days'
  GROUP BY 1, 2),
env AS (
  SELECT time_bucket('1 hour', time) AS t,
    avg(value) FILTER (WHERE room = 'bedroom2' AND device = 'th' AND property = 'temperature')      AS room_c,
    avg(value) FILTER (WHERE room = 'outdoor' AND property = 'temperature')                          AS outdoor_c,
    avg(value) FILTER (WHERE device = 'air_quality' AND property = 'carbon_dioxide')                 AS co2,
    avg(value) FILTER (WHERE device = 'contact' AND anchor = 'window' AND property = 'contact')      AS window_closed
  FROM readings
  WHERE processing = 'raw' AND room IN ('bedroom2', 'outdoor') AND time > now() - interval '7 days'
  GROUP BY 1)
SELECT p.t, round(sum(p.w)::numeric, 0) AS room_w, round(max(e.room_c)::numeric, 1) AS room_c,
  round((max(e.room_c) - max(e.outdoor_c))::numeric, 1) AS delta_c, round(max(e.co2)::numeric, 0) AS co2,
  round(((1 - max(e.window_closed)) * 100)::numeric, 0) AS window_open_pct
FROM plug p JOIN env e USING (t)
GROUP BY p.t ORDER BY p.t;
```

- **확인:** 첫 쿼리에서 호스트 값이 들어온 뒤의 분마다 `wall_w` 와 `cpu_pct` 가 함께 채워집니다. 창문·문 센서는 상태가 바뀔 때만 보고하므로 세 번째 쿼리의 `window_open_pct` 는 보고가 없던 시간에 비어 있습니다(직전 값이 이어진 것으로 봅니다).

## 트러블슈팅

<details markdown="1">
<summary><code>No such file or directory: b'visudo'</code></summary>

```text
[ERROR]: Task failed: Module failed: Error executing command: [Errno 2] No such file or directory: b'visudo'
```

- **원인:** Proxmox 에는 `sudo` 패키지가 기본으로 없어, sudoers 파일을 검사하는 `visudo` 도 없습니다.
- **해결:** 설치 목록에 `sudo` 를 넣었습니다. Telegraf 의 `smart` 입력이 `use_sudo = true` 로 `smartctl` 을 부릅니다.

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
<summary>amdgpu 가 알리는 GPU 전력이 GPU 부하를 따라가지 않음</summary>

- **원인:** hwmon `power1_input`·`power1_average` 의 PPT 는 칩마다 재는 범위가 다릅니다. 780M 은 패키지 전체라 RAPL 과 같은 값(약 16 W)이었고, 610M 은 GPU 100% 일 때 12 W, GPU 가 놀고 CPU 가 바쁠 때 25 W 로 패키지 전력을 따라갔습니다. `gpu_metrics`(v2.1)의 `average_gfx_power` 는 두 칩 모두 GPU 활동과 무관하게 널뛰었고 `average_cpu_power` 는 미지원(65535)이었습니다.
- **해결:** GPU 전력을 수집하지 않습니다. iGPU 전력은 `cpu_power`(RAPL 패키지)에 포함되어 있습니다.

</details>

## 마무리

Proxmox 노드마다 호스트 전체의 부하·온도·전력이 10초마다 Home Assistant 센서와 지역·허브 DB 의 `readings` 에 들어오고, 전력 플러그와 같은 `anchor` 로 부하와 벽 전력을 맞춰 볼 수 있습니다. 마운트·디스크가 다른 서버는 인벤토리에서 `host_metrics_*` 를 덮어쓰고 플레이북을 다시 실행하면, 발견 설정이 새 필드에 맞춰 센서를 더하거나 지웁니다.

## 참고 자료

- [Telegraf - Plugin directory](https://docs.influxdata.com/telegraf/v1/plugins/)
- [Telegraf - Starlark Processor](https://github.com/influxdata/telegraf/tree/master/plugins/processors/starlark)
- [Telegraf - Merge Aggregator](https://github.com/influxdata/telegraf/tree/master/plugins/aggregators/merge)
- [Telegraf - MQTT Producer Output](https://github.com/influxdata/telegraf/tree/master/plugins/outputs/mqtt)
- [Home Assistant - MQTT Discovery](https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery)
- [Linux kernel - amdgpu hwmon interfaces](https://docs.kernel.org/gpu/amdgpu/thermal.html)
- [Linux kernel - Power Capping Framework](https://docs.kernel.org/power/powercap/powercap.html)
- [TimescaleDB - Compression](https://docs.timescale.com/use-timescale/latest/compression/)
