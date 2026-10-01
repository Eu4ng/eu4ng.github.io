---
layout: post
title: Proxmox LXC에 Ollama 서버를 두고 쿠버네티스에서 빠른 서버부터 나눠 쓰는 방법
description: Ollama 모델 서버를 Ansible 플레이북으로 Proxmox LXC 에 여러 대 만들고, 쿠버네티스에는 HAProxy 라우터만 GitOps 로 배포해 클러스터 안 주소 하나로 비어 있는 서버 가운데 빠른 서버부터 요청을 채우는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, lxc, ansible, ollama, haproxy, kubernetes, argo-cd, gitops]
permalink: /posts/37/
---

모델 서버는 쿠버네티스 파드가 아니라 Proxmox 의 **LXC** 컨테이너(/posts/65/)에 Ansible 플레이북으로 만들고, 쿠버네티스에는 요청을 나눠 주는 HAProxy 라우터만 GitOps 로 배포합니다. worker VM 안에서 돌리면 모델 크기만큼 VM 메모리를 크게 잡아 두어야 하고, 한 번 잡힌 메모리는 모델을 내려도 호스트로 바로 돌아오지 않습니다(/posts/66/). LXC 는 호스트 커널 위의 프로세스라 모델을 내리면 메모리가 호스트로 돌아가고, 호스트의 iGPU 도 장치 파일 하나로 넘겨 씁니다. CPU 로 도는 컨테이너, iGPU 로 도는 컨테이너, LAN 의 다른 PC 처럼 속도가 다른 서버를 여러 대 두고, 라우터는 요청 하나에 서버 하나를 배정하되 비어 있는 서버 가운데 가장 빠른 서버부터 채웁니다(/posts/70/). 그래서 동시에 서버 수만큼 요청을 처리하고, 요청이 하나뿐이면 늘 가장 빠른 서버가 받습니다. Ollama 공식 문서는 서버 한 대를 기준으로 하지만, 이 글은 여러 서버 앞에 HAProxy 를 두고 서버마다 동시 요청을 하나로 제한합니다.

1. 변수 채우기
2. 플레이북 실행
3. 서버 속도 재기
4. 라우터 매니페스트 추가
5. 배포 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Proxmox VE | `9.2` |
| Ansible | `13.1` (ansible-core `2.20`, community.proxmox `1.4`) |
| CT 템플릿 | `debian-13-standard` |
| Ollama | `0.34.4` |
| 모델 | `gemma4:e4b (9.6GB)`, `qwen3.5:9b (6.6GB)`, `glm-ocr (2.2GB)` |
| Kubernetes | `v1.37` |
| Argo CD | `v3.5` |
| HAProxy | `3.2.24` |
| 작성 기준일 | `2026-10-01` |

다음 항목이 준비되어 있어야 합니다.

- `proxmox-ansible` 저장소, Proxmox API 토큰, 내부망 DNS ([Proxmox에 Ansible로 내부망 DNS 컨테이너 만드는 방법](/posts/41/)). 이 글의 플레이북은 그 글의 CT 템플릿과 변수를 쓰고, 새 CT 의 이름을 내부망 DNS 가 풉니다.
- 노드가 내부망 DNS 를 쓰는 쿠버네티스 클러스터 ([Proxmox에 Ansible로 kubeadm 쿠버네티스 클러스터 만드는 방법](/posts/46/)). 파드가 CoreDNS 를 거쳐 CT 이름(`ollama-cpu.[DOMAIN]` 등)을 풉니다.
- Argo CD 가 GitOps 저장소의 `services/<이름>/` 폴더를 Application 으로 만드는 구성 ([쿠버네티스에 Argo CD 설치하고 GitOps로 서비스 추가하는 방법](/posts/36/))
- CT 마다 비어 있는 VM ID 와 고정 IP, 가장 큰 모델보다 넉넉한 메모리(여기서는 12GB)와 디스크 40GB
- iGPU CT 를 둘 Proxmox 호스트에 `/dev/dri/renderD128` (호스트에서 `ls /dev/dri` 로 확인)

## 1. 변수 채우기

`proxmox-ansible` 저장소의 `group_vars/all.yml` 에 Ollama 버전, 받아 둘 모델, 만들 CT 목록을 추가합니다. `ollama_backends` 의 항목마다 CT 하나가 생기고, `gpu: true` 인 CT 에는 그 Proxmox 호스트의 iGPU 를 넘깁니다. CT 템플릿, 스토리지, 게이트웨이, SSH 키, DNS 주소는 [내부망 DNS 글](/posts/41/)에서 채운 값을 그대로 씁니다.

```yaml
# ---- ollama: 모델 서버 LXC (playbooks/ollama.yml) ----
# 호스트의 iGPU 를 /dev/dri 로 넘겨 Vulkan 으로 돌리거나(gpu: true) CPU 로 돌립니다. VM 이 아니라 LXC 라 모델을 내리면 메모리를 호스트에 돌려줍니다.
# 클러스터의 ollama 서비스(k8s-gitops services/ollama, HAProxy)가 빠른 순서로 비어 있는 서버에 보냅니다. 순서는 그쪽 haproxy.cfg 에 둡니다.
ollama_version: 0.34.4                        # https://github.com/ollama/ollama/releases (iGPU Vulkan 은 OLLAMA_VULKAN=1·OLLAMA_IGPU_ENABLE=1)
ollama_models: [gemma4:e4b, qwen3.5:9b, glm-ocr]   # 모든 백엔드가 쓸 모델(glm-ocr: wiki-papers 의 표·수식 판독)
# 모델 저장소는 같은 Proxmox 호스트의 CT 끼리 공유합니다. 호스트의 thin LV(pve/ollama-models, Proxmox 가 관리하지 않아 GUI 에 안 보임)를
# 호스트의 ollama_models_dir 에 붙이고, 그 안의 store 폴더를 CT 마다 같은 경로로 바인드 마운트합니다. 모델은 호스트마다 한 번만 받습니다.
# - OLLAMA_NOPRUNE=1: Ollama 는 시작할 때 manifest 가 가리키지 않는 blob 과 받는 중인 파일을 지웁니다. 공유 폴더에서는 한 CT 가 받는
#   중에 다른 CT 의 ollama 가 재시작되면 그 모델이 깨지므로 끕니다(옛 blob 은 ollama rm 으로 지웁니다).
# - 바인드 마운트가 있는 CT 는 스냅샷(pct snapshot)과 다른 노드로의 이전이 안 되고, vzdump 백업에서 모델이 빠집니다(다시 받으면 된다).
# - 같은 저장소의 metadata/ 를 함께 쓰므로 ollama_version 은 모든 CT 가 같아야 합니다(이 변수 하나라 늘 같습니다).
ollama_models_dir: /srv/ollama-models         # 호스트 마운트 위치이자 CT 안의 경로(OLLAMA_MODELS)
ollama_models_lv_size: 100g                   # thin LV 라 실제로 쓴 만큼만 차지합니다
ollama_backends:                              # 메모리: 9B 모델 약 7GB + 64K 컨텍스트 KV 약 2GB. inventory 의 ollama 그룹과 이름이 같아야 함
  - { name: ollama-cpu,  pve: pve01, vmid: 211, ip: [OLLAMA_CPU_IP],  cores: 24, memory: 12288, disk: 40, gpu: false }
  - { name: ollama-610m, pve: pve01, vmid: 212, ip: [OLLAMA_IGPU_IP], cores: 4,  memory: 12288, disk: 40, gpu: true }
```
{: file="group_vars/all.yml" }

inventory 에는 같은 이름으로 `ollama` 그룹을 추가합니다. 플레이북이 이 그룹의 CT 에 접속해 Ollama 를 설치하고, 내부망 DNS 가 이 이름을 CT 주소로 답합니다.

```yaml
all:
  children:
    ollama:                       # playbooks/ollama.yml 이 만드는 모델 서버 CT (group_vars 의 ollama_backends)
      hosts:
        ollama-cpu:
          ansible_host: [OLLAMA_CPU_IP]
          ansible_user: root
        ollama-610m:
          ansible_host: [OLLAMA_IGPU_IP]
          ansible_user: root
```
{: file="inventory.yml" }

- **확인:** `ansible-inventory --graph` 에 `@ollama` 아래 `ollama-cpu`, `ollama-610m` 이 보입니다.

## 2. 플레이북 실행

플레이북은 CT 를 정의하고, `gpu: true` 인 CT 에 `/dev/dri/renderD128` 을 넘기고, CT 가 있는 Proxmox 호스트에 모델 저장소를 만들어 CT 마다 바인드 마운트한 뒤, CT 를 켜고 Ollama 를 설치하고 모델을 받습니다. 모델 저장소는 호스트의 thin LV 하나(`pve/ollama-models`)를 `/srv/ollama-models` 에 붙이고 그 안의 `store` 폴더를 같은 호스트의 CT 들이 함께 쓰므로, 모델은 호스트마다 한 번만 받고 디스크도 한 벌만 씁니다. 비특권 CT 의 root 는 호스트에서 uid 100000 이라 `store` 폴더를 그 소유로 만듭니다. Ollama 는 시작할 때 쓰지 않는 blob 과 받는 중인 파일을 지우는데, 함께 쓰는 폴더에서는 다른 CT 가 받는 중인 모델을 깨뜨리므로 `OLLAMA_NOPRUNE=1` 로 끕니다. 바인드 마운트가 있는 CT 는 스냅샷과 다른 노드로의 이전이 안 됩니다. Ollama 는 서비스 설정으로 LAN 에서 요청을 받고(`OLLAMA_HOST=0.0.0.0:11434`), 한 번에 모델 하나(`OLLAMA_MAX_LOADED_MODELS=1`)와 요청 하나(`OLLAMA_NUM_PARALLEL=1`)만 다룹니다. 라우터가 서버마다 요청을 하나씩만 보내는 것과 짝을 이룹니다. AMD iGPU 는 ROCm 지원 밖이라 iGPU CT 는 `mesa-vulkan-drivers` 를 깔고 Vulkan 으로 돌립니다(`OLLAMA_VULKAN=1`, `OLLAMA_IGPU_ENABLE=1`). Vulkan 의 flash attention 에서 `gemma4:e4b` 가 약 750토큰이 넘는 프롬프트마다 죽어 iGPU CT 는 flash attention 을 끕니다(`OLLAMA_FLASH_ATTENTION=0`). 이미 설치된 버전과 받아 둔 모델은 건너뛰므로 여러 번 실행해도 결과가 같습니다.

```bash
# 플레이북 내려받기
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/ollama.yml -o playbooks/ollama.yml
```

<details markdown="1">
<summary>playbooks/ollama.yml 전문</summary>

{% raw %}
```yaml
# 모델 서버(Ollama) LXC. group_vars 의 ollama_backends 마다 CT 하나를 만들고 Ollama 를 설치해 모델을 받아 둡니다.
# gpu: true 인 CT 는 그 Proxmox 호스트의 iGPU(/dev/dri/renderD128)를 넘겨 Vulkan 으로 추론합니다(AMD iGPU 는 ROCm 지원 밖).
# 클러스터에서는 k8s-gitops services/ollama 의 HAProxy 가 이 CT 들을 <이름>.<도메인> 으로 불러 빠른 순서로 나눕니다.
# 모델 저장소는 같은 호스트의 CT 끼리 공유합니다(호스트의 thin LV 를 ollama_models_dir 에 붙이고 CT 마다 바인드 마운트). 모델은 호스트마다
# 한 번만 받고, 공유 폴더에서 다른 CT 의 받는 중인 파일을 지우지 않게 OLLAMA_NOPRUNE=1 로 돕니다(group_vars 의 설명 참고).
#   ansible-playbook playbooks/ollama.yml                          (PROXMOX_* 환경변수 필요, README 참고)
#   ansible-playbook playbooks/ollama.yml -e ollama_pull_models=false   (모델을 받지 않음. 다른 곳의 모델 파일을 옮겨 넣을 때)
---
- name: Ollama CT 정의
  hosts: localhost
  gather_facts: false
  tasks:
    - name: CT 정의 (있으면 설정만 맞춤)
      community.proxmox.proxmox:
        node: "{{ item.pve }}"
        vmid: "{{ item.vmid }}"
        hostname: "{{ item.name }}"
        ostemplate: "{{ ct_template_storage }}:vztmpl/{{ lan_dns_template }}"
        cores: "{{ item.cores }}"
        memory: "{{ item.memory }}"
        swap: 0
        disk: "{{ ct_disk_storage }}:{{ item.disk }}"
        netif: { net0: "name=eth0,bridge={{ ct_bridge }},ip={{ item.ip }}/24,gw={{ ct_gateway }}" }
        nameserver: "{{ (lan_dns_instances | map(attribute='ip') | list) | join(' ') }}"
        searchdomain: "{{ lan_dns_domain }}"
        features: [nesting=1]
        onboot: true
        unprivileged: true
        pubkey: "{{ ct_ssh_pubkey }}"
        state: present
      loop: "{{ ollama_backends }}"
      loop_control: { label: "{{ item.name }}" }

- name: iGPU 넘기기
  hosts: proxmox
  gather_facts: false
  tasks:
    # 장치는 CT 가 시작할 때 붙으므로, 새로 넣었으면 돌고 있는 CT 를 다시 시작합니다
    - name: /dev/dri/renderD128 (gpu CT 만)
      ansible.builtin.shell: |
        pct config {{ item.vmid }} | grep -q '^dev0: /dev/dri/renderD128' && exit 0
        pct set {{ item.vmid }} --dev0 /dev/dri/renderD128,gid=993
        pct status {{ item.vmid }} | grep -q running && pct reboot {{ item.vmid }}
        echo CHANGED
      register: dri
      changed_when: "'CHANGED' in dri.stdout"
      loop: "{{ ollama_backends | selectattr('pve', 'eq', inventory_hostname) | selectattr('gpu') }}"
      loop_control: { label: "{{ item.name }}" }

- name: 모델 저장소 (호스트마다 하나, 그 호스트의 CT 가 함께 씀)
  hosts: proxmox
  gather_facts: false
  vars:
    backends_here: "{{ ollama_backends | selectattr('pve', 'eq', inventory_hostname) | list }}"
  tasks:
    - name: thin LV (pve/ollama-models)
      community.general.lvol:
        vg: pve
        lv: ollama-models
        thinpool: data
        size: "{{ ollama_models_lv_size }}"
        shrink: false          # 손으로 늘린 뒤 다시 실행해도 줄이지 않습니다
      when: backends_here | length > 0
    - name: ext4 (처음 한 번)
      community.general.filesystem:
        fstype: ext4
        dev: /dev/pve/ollama-models
      when: backends_here | length > 0 and not ansible_check_mode   # check 모드에서는 LV 가 아직 없다
    # nofail 을 쓰지 않습니다. 마운트가 안 되면 아래 store 폴더가 없어 CT 가 시작하지 못하고(라우터가 건너뜀),
    # 호스트 루트에 모델을 받는 일이 없습니다
    - name: 마운트 (fstab)
      ansible.posix.mount:
        path: "{{ ollama_models_dir }}"
        src: /dev/pve/ollama-models
        fstype: ext4
        opts: defaults
        state: mounted
      register: models_mount
      when: backends_here | length > 0
    - name: systemd 가 바뀐 fstab 을 읽게
      ansible.builtin.systemd:
        daemon_reload: true
      when: models_mount is changed
    - name: store 폴더 (CT 의 root 가 쓰도록 비특권 CT 의 uid 100000 소유)
      ansible.builtin.file:
        path: "{{ ollama_models_dir }}/store"
        state: directory
        owner: "100000"
        group: "100000"
        mode: "0755"
      when: backends_here | length > 0
    # 새 경로에 붙이므로(옛 /var/lib/ollama/models 를 가리지 않음) 실행 중인 CT 에도 재부팅 없이 바로 붙습니다
    - name: CT 에 바인드 마운트
      ansible.builtin.shell: |
        pct config {{ item.vmid }} | grep -q '^mp0: {{ ollama_models_dir }}/store,' && exit 0
        pct set {{ item.vmid }} --mp0 {{ ollama_models_dir }}/store,mp={{ ollama_models_dir }}
        echo CHANGED
      register: bind
      changed_when: "'CHANGED' in bind.stdout"
      loop: "{{ backends_here }}"
      loop_control: { label: "{{ item.name }}" }

- name: Ollama CT 시작
  hosts: localhost
  gather_facts: false
  tasks:
    - name: CT 시작
      community.proxmox.proxmox:
        node: "{{ item.pve }}"
        vmid: "{{ item.vmid }}"
        hostname: "{{ item.name }}"
        state: started
      loop: "{{ ollama_backends }}"
      loop_control: { label: "{{ item.name }}" }
    - name: SSH 열릴 때까지 대기
      ansible.builtin.wait_for:
        host: "{{ item.ip }}"
        port: 22
        timeout: 120
      loop: "{{ ollama_backends }}"
      loop_control: { label: "{{ item.name }}" }

- name: Ollama 설치와 모델
  hosts: ollama
  gather_facts: false
  vars:
    backend: "{{ ollama_backends | selectattr('name', 'eq', inventory_hostname) | first }}"
    ollama_pull_models: true
  pre_tasks:
    - name: python3 준비 (Ansible 모듈 실행에 필요)
      ansible.builtin.raw: command -v python3 >/dev/null || (apt-get update -q && apt-get install -y -q python3)
      changed_when: false
  tasks:
    - name: 시간대
      community.general.timezone:
        name: "{{ timezone }}"
    - name: 패키지 (gpu CT 는 Vulkan 드라이버 RADV 포함)
      ansible.builtin.apt:
        name: "{{ ['curl', 'ca-certificates', 'zstd'] + (['mesa-vulkan-drivers'] if backend.gpu else []) }}"
        update_cache: true
        cache_valid_time: 3600
    - name: Ollama 설치 (버전이 다를 때만)
      ansible.builtin.shell: |
        [ -x /usr/local/bin/ollama ] && /usr/local/bin/ollama -v 2>/dev/null | grep -q "{{ ollama_version }}" && exit 0
        curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION={{ ollama_version }} sh >/tmp/ollama-install.log 2>&1
        echo CHANGED
      register: install
      changed_when: "'CHANGED' in install.stdout"
    # 설치 스크립트의 서비스 계정(ollama) 대신 root 로 돕니다. 비특권 CT 라 호스트에서는 일반 계정이고, 넘긴 GPU 장치를 그룹 설정 없이 씁니다
    - name: 서비스 설정 폴더
      ansible.builtin.file:
        path: /etc/systemd/system/ollama.service.d
        state: directory
        mode: "0755"
    - name: 서비스 설정
      ansible.builtin.copy:
        dest: /etc/systemd/system/ollama.service.d/override.conf
        mode: "0644"
        content: |
          [Service]
          User=root
          Group=root
          Environment=OLLAMA_HOST=0.0.0.0:11434
          Environment=OLLAMA_MODELS={{ ollama_models_dir }}
          Environment=OLLAMA_NOPRUNE=1
          Environment=OLLAMA_KEEP_ALIVE=30m
          Environment=OLLAMA_MAX_LOADED_MODELS=1
          Environment=OLLAMA_NUM_PARALLEL=1
          {% if backend.gpu %}
          Environment=OLLAMA_VULKAN=1
          Environment=OLLAMA_IGPU_ENABLE=1
          # Vulkan(RADV, Radeon 610M)의 flash attention 에서 gemma4:e4b 가 약 750토큰을 넘는 프롬프트마다
          # llama-server 가 'free(): invalid pointer' 로 죽는다(qwen3.5:9b 는 정상). 끄면 gemma4 프롬프트 처리는 82 -> 61~66 tok/s,
          # qwen3.5:9b 는 26 -> 33 tok/s 로 오히려 빨라졌다(2026-09-29, ollama 0.34.4).
          Environment=OLLAMA_FLASH_ATTENTION=0
          {% endif %}
      register: override
    - name: 모델 폴더 (호스트 저장소의 바인드 마운트)
      ansible.builtin.file:
        path: "{{ ollama_models_dir }}"
        state: directory
        mode: "0755"
    - name: 서비스 다시 읽기·시작
      ansible.builtin.systemd:
        name: ollama
        daemon_reload: true
        enabled: true
        state: "{{ 'restarted' if (override.changed or install.changed) else 'started' }}"
    - name: API 응답 대기
      ansible.builtin.uri:
        url: http://127.0.0.1:11434/api/version
      register: api
      until: api.status == 200
      retries: 30
      delay: 2
    - name: 모델 받기 (없는 것만)
      ansible.builtin.shell: |
        ollama list | awk 'NR>1{print $1}' | grep -qxF -e "{{ item }}" -e "{{ item }}:latest" && exit 0   # 태그 없이 적은 모델은 :latest 로 나온다
        ollama pull {{ item }} >/dev/null && echo CHANGED
      register: pull
      changed_when: "'CHANGED' in pull.stdout"
      loop: "{{ ollama_models }}"
      when: ollama_pull_models | bool
      throttle: 1              # 저장소를 함께 쓰는 CT 가 동시에 받지 않게 차례로. 뒤의 CT 는 이미 있어 건너뜁니다
    - name: 확인 (GPU CT 는 Vulkan 장치를 찾았는지)
      ansible.builtin.shell: |
        ollama list | awk 'NR>1{print $1}' | tr '\n' ' '
        {% if backend.gpu %}journalctl -u ollama -b --no-pager | grep -q 'library=Vulkan' && echo "GPU: Vulkan"{% endif %}
      register: check
      changed_when: false
    - name: 결과
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }}: {{ check.stdout_lines | join(' / ') }}"
```
{: file="playbooks/ollama.yml" }
{% endraw %}

</details>

플레이북을 실행한 뒤 내부망 DNS 플레이북을 다시 실행해 새 CT 이름을 등록합니다. 모델은 호스트마다 한 번 받으므로(CT 가 차례로 돌며 이미 있는 모델은 건너뜀) 회선 속도에 따라 처음 한 번 시간이 걸립니다.

```bash
# 모델 서버 CT 만들기
export PROXMOX_HOST=[PROXMOX_IP] PROXMOX_USER=root@pam PROXMOX_TOKEN_ID=ansible \
       PROXMOX_TOKEN_SECRET=$(cat ~/.config/proxmox/token) PROXMOX_VALIDATE_CERTS=false
ansible-playbook playbooks/ollama.yml

# 새 CT 이름(ollama-cpu.[DOMAIN] 등)을 내부망 DNS 에 등록
ansible-playbook playbooks/lan-dns.yml
```

```bash
# 이름과 API 응답 (아무 PC 에서)
for h in ollama-cpu ollama-610m; do
  curl -s http://$h.[DOMAIN]:11434/api/tags | grep -o '"name":"[^"]*"'
done
```

- **확인:** `ollama.yml` 의 마지막 `결과` 태스크에 CT 마다 받아 둔 모델 이름이 보이고, iGPU CT 줄 끝에는 `GPU: Vulkan` 이 붙습니다. 위 명령은 CT 마다 `"name":"glm-ocr:latest"`, `"name":"qwen3.5:9b"`, `"name":"gemma4:e4b"` 세 줄을 출력합니다. 호스트에서 `pct exec <CT ID> -- findmnt -n /srv/ollama-models` 가 두 CT 모두 `pve-ollama--models[/store]` 를 보여 주면 같은 저장소를 쓰는 것입니다.

## 3. 서버 속도 재기

라우터는 위에 적힌 서버부터 채우므로, 같은 모델과 같은 질문으로 서버마다 생성 속도를 재서 빠른 순서를 정합니다. 응답의 `eval_count` 를 `eval_duration`(나노초)으로 나누면 초당 토큰 수입니다. 한 번에 한 서버씩 잽니다.

LAN 의 다른 PC 에서 도는 Ollama 도 같은 목록에 넣을 수 있습니다. Windows 의 Ollama 는 기본으로 그 PC 안에서만 요청을 받으므로, PC 에서 아래를 실행한 뒤 작업 표시줄의 Ollama 를 종료하고 다시 켭니다.

```powershell
# 다른 기기에서 받도록 사용자 환경 변수 설정
setx OLLAMA_HOST 0.0.0.0:11434

# 개인 네트워크에서 11434 포트 허용 (관리자 PowerShell)
New-NetFirewallRule -DisplayName "Ollama" -Direction Inbound -Protocol TCP -LocalPort 11434 -Action Allow -Profile Private
```

```bash
# 서버마다 생성 속도 재기 (qwen3.5:9b)
for url in http://[WINPC_IP]:11434 http://ollama-cpu.[DOMAIN]:11434 http://ollama-610m.[DOMAIN]:11434; do
  curl -s $url/api/generate -d '{"model":"qwen3.5:9b","prompt":"쿠버네티스를 세 문장으로 설명해 줘","stream":false}' \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print(sys.argv[1], round(r["eval_count"]/r["eval_duration"]*1e9,1), "tok/s")' $url
done
```

| 서버 | 추론 장치 | `qwen3.5:9b` 생성 속도 |
| :--- | :--- | :--- |
| 윈도우 PC | Radeon 780M | 14 tok/s |
| `ollama-cpu` | CPU 24코어 | 8.5 tok/s |
| `ollama-610m` | Radeon 610M (iGPU) | 4.7 tok/s (`ollama-cpu` 와 동시에 돌 때) |

> 같은 호스트의 CPU CT 와 iGPU CT 는 [메모리 대역폭](/posts/63/)을 나눠 쓰므로 동시에 돌면 둘 다 느려집니다. 순서를 정할 때는 한 대씩 잰 값을 쓰고, 두 CT 가 함께 돌 때 얼마나 느려지는지도 따로 확인합니다.
{: .prompt-warning }

- **확인:** 서버마다 `tok/s` 값이 한 줄씩 나옵니다. 이 값이 큰 순서가 4단계 `haproxy.cfg` 의 `server` 줄 순서입니다.

## 4. 라우터 매니페스트 추가

GitOps 저장소의 `services/ollama/` 폴더에 HAProxy 설정, Deployment, Service 를 둡니다. 폴더 이름을 따라 `ollama` 네임스페이스에 배포됩니다.

HAProxy 설정의 핵심은 `backend by-speed` 입니다. `balance first` 는 위에 적힌 서버부터 연결을 채우고, 서버마다 `maxconn 1` 이라 요청 하나가 서버 하나를 차지합니다. 비어 있는 서버 가운데 가장 위의 서버가 다음 요청을 받고, 모두 바쁘면 `timeout queue` 동안 줄을 세웠다가 먼저 빈 서버로 보냅니다. `/api/version` 헬스체크가 두 번 실패한 서버는 건너뛰므로 PC 가 꺼져 있어도 요청이 멈추지 않습니다. 서버가 요청을 처리하다 실패하면(연결 실패, 빈 응답, 5xx) `retry-on` 으로 다른 서버에 다시 보내므로, 쓰는 쪽은 어느 서버가 실패했는지 몰라도 됩니다. 다시 보내려면 요청 본문 전체가 버퍼에 들어가야 해서 `tune.bufsize` 를 1MB 로 키웁니다. 서버 이름은 파드의 DNS 로 풀고(`resolvers lan`), `init-addr` 에 `none` 이 있어 풀리지 않는 서버가 있어도 HAProxy 가 뜹니다.

```bash
# HAProxy 설정 내려받기
mkdir -p services/ollama
curl -fsSL https://eu4ng.github.io/assets/files/ollama/haproxy.cfg -o services/ollama/haproxy.cfg
```

내려받은 뒤 `backend by-speed` 의 `server` 줄을 3단계에서 잰 빠른 순서대로 맞춥니다. `[WINPC_IP]` 와 `[DOMAIN]` 을 바꾸고, 없는 서버의 줄은 지웁니다.

<details markdown="1">
<summary>services/ollama/haproxy.cfg 전문</summary>

```text
# ollama 요청을 빠른 서버부터 채웁니다. balance first + 서버마다 maxconn 1 이라 요청 하나가 서버 하나를 차지하고,
# 비어 있는 서버 가운데 위에 적힌 것이 받습니다. 모두 바쁘면 줄을 세웠다가 먼저 빈 서버로 보냅니다. 꺼진 서버는 헬스체크로 건너뜁니다.
# 순서는 측정한 생성 속도 순입니다(qwen3.5:9b): 윈도우 PC 780M 14 tok/s > pve01 CPU 8.5 tok/s > pve01 610M(CPU 보다 약 40% 느림).
# CPU·610M 은 proxmox-ansible playbooks/ollama.yml 의 LXC 이고, 이름은 내부망 DNS 가 풉니다. 이 프로세스 하나가 연결 수를 세므로 replicas 는 1 입니다.
global
  log stdout format raw local0 info
  maxconn 200                    # 동시 연결 상한(버퍼가 1MB 라 메모리를 제한). 실제 동시 요청은 서버 수 안팎
  tune.bufsize 1048576           # 요청 본문 전체를 버퍼에 담아야 다른 서버로 다시 보낼 수 있습니다(64K 컨텍스트 요청도 수백 KB)

resolvers lan
  parse-resolv-conf              # 파드의 resolv.conf(CoreDNS → 내부망 DNS)
  hold valid 30s

defaults
  mode http
  log global
  option httplog
  option dontlognull              # 준비 상태 검사처럼 요청 없이 닫힌 연결은 기록하지 않습니다
  # 서버가 요청을 처리하다 실패하면(연결 실패, 빈 응답, 5xx) 다른 서버로 다시 보냅니다. 쓰는 쪽은 어느 서버가 실패했는지 몰라도 됩니다
  option http-buffer-request
  retries 2
  option redispatch 1
  retry-on conn-failure empty-response 500 502 503 504
  option http-server-close       # 응답이 끝나면 서버 연결을 닫아, 쉬는 keep-alive 연결이 자리를 차지하지 않게 합니다
  timeout connect 5s
  timeout client 60m
  timeout server 60m             # 64K 컨텍스트 재검토는 요청 하나가 수십 분 걸릴 수 있습니다
  timeout queue 60m

frontend ollama
  bind :11434
  default_backend by-speed

backend by-speed
  balance first
  option httpchk GET /api/version
  http-check expect status 200
  default-server check inter 5s fall 2 rise 2 maxconn 1 resolvers lan init-addr last,libc,none
  server winpc-780m [WINPC_IP]:11434          # 윈도우 PC(Radeon 780M). PC 가 꺼지면 헬스체크로 빠집니다
  # server pve02-780m ollama-780m.[DOMAIN]:11434   # pve02 메모리를 늘려 LXC 를 만든 뒤 여기(두 번째)에 넣습니다
  server pve01-cpu ollama-cpu.[DOMAIN]:11434
  server pve01-610m ollama-610m.[DOMAIN]:11434

frontend stats
  bind :8404
  stats enable
  stats uri /
  stats refresh 5s
```
{: file="services/ollama/haproxy.cfg" }

</details>

라우터는 한 프로세스가 서버마다 연결 수를 세므로 `replicas` 는 1 입니다. 두 개로 늘리면 각자 따로 세어 한 서버에 요청이 겹칩니다.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama-router
spec:
  replicas: 1                # 서버마다 동시 요청 1개(maxconn 1)를 이 프로세스가 셉니다. 늘리면 한 서버에 요청이 겹칩니다
  strategy:
    type: Recreate
  selector:
    matchLabels: { app: ollama-router }
  template:
    metadata:
      labels: { app: ollama-router }
    spec:
      containers:
        - name: haproxy
          image: haproxy:3.2.24-alpine
          ports:
            - { name: ollama, containerPort: 11434 }
            - { name: stats, containerPort: 8404 }
          volumeMounts:
            - { name: config, mountPath: /usr/local/etc/haproxy }
          readinessProbe:
            httpGet: { path: /, port: 8404 }   # 통계 페이지. 11434 로 찌르면 요청 없는 연결이 오류로 남습니다
            periodSeconds: 5
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { cpu: 500m, memory: 256Mi }   # 재시도용 요청 버퍼(연결마다 1MB)
      volumes:
        - name: config
          configMap: { name: ollama-router }
```
{: file="services/ollama/deployment.yaml" }

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ollama
spec:
  # 빠른 서버부터 채우는 라우터(haproxy.cfg). 윈도우 PC 780M → pve01 CPU → pve01 610M 순서, 동시에 서버 수만큼 처리합니다
  selector: { app: ollama-router }
  ports:
    - { name: ollama, port: 11434, targetPort: 11434 }
    - { name: stats, port: 8404, targetPort: 8404 }
```
{: file="services/ollama/service.yaml" }

클라이언트는 어느 서버(GPU·CPU)가 요청을 받는지 알 필요가 없습니다. 라우터 주소 하나만 쓰고, 서버를 늘리거나 바꿀 때도 라우터 설정만 고칩니다.

`configMapGenerator` 는 `haproxy.cfg` 가 바뀌면 ConfigMap 이름 끝의 해시를 바꿔, 라우터 파드가 새 설정으로 다시 만들어지게 합니다.

```yaml
# 모델 서버는 클러스터 밖의 LXC(proxmox-ansible playbooks/ollama.yml)와 윈도우 PC 이고, 여기는 빠른 서버부터 채우는 라우터만 둡니다.
resources:
  - deployment.yaml
  - service.yaml
configMapGenerator:
  - name: ollama-router
    files:
      - haproxy.cfg
```
{: file="services/ollama/kustomization.yaml" }

> 이 글의 이전 판처럼 Ollama 를 파드로 배포해 두었다면, 모델을 담던 PVC 는 `Prune=false` 라 매니페스트를 지워도 남습니다. 라우터가 동작하는 것을 확인한 뒤 `kubectl -n ollama delete pvc ollama-models` 로 지웁니다.
{: .prompt-info }

```bash
# 커밋하고 push
git add services/ollama
git commit -m "feat(ollama): 빠른 서버부터 채우는 HAProxy 라우터 추가"
git push
```

- **확인:** 몇 분 안에 Argo CD 웹 UI 의 `ollama` Application 이 **Synced**, **Healthy** 로 표시됩니다.

## 5. 배포 확인

control plane 에서 라우터 파드와 서버 상태를 봅니다. 라우터 통계는 Service 의 8404 포트에 있고, 주소 끝에 `;csv` 를 붙이면 표 대신 CSV 로 나옵니다. 아래 명령은 그중 백엔드 이름, 서버 이름, 대기 중인 요청(`qcur`), 처리 중인 요청(`scur`), 동시 요청 상한(`slim`), 상태, 헬스체크 결과 열만 보여 줍니다.

```bash
# 라우터 파드
kubectl -n ollama get pods

# 서버 상태 (라우터 통계)
IP=$(kubectl -n ollama get svc ollama -o jsonpath='{.spec.clusterIP}')
curl -s "http://$IP:8404/;csv" | cut -d, -f1,2,3,5,7,18,37 | grep by-speed
```

```text
by-speed,winpc-780m,0,0,1,UP,L7OK
by-speed,pve01-cpu,0,0,1,UP,L7OK
by-speed,pve01-610m,0,0,1,UP,L7OK
by-speed,BACKEND,0,0,26210,UP,
```

라우터를 거쳐 API 를 부르고, 어느 서버가 받았는지 라우터 로그의 `by-speed/<서버>` 로 확인합니다. 요청이 하나뿐이면 늘 첫 서버가 받습니다.

```bash
# 라우터를 거쳐 모델 목록 받기
curl -s http://$IP:11434/api/tags | grep -o '"name":"[^"]*"'

# 요청을 받은 서버
kubectl -n ollama logs deploy/ollama-router | grep by-speed
```

```text
10.244.7.0:52926 [...] ollama by-speed/winpc-780m 0/0/3/6/9 200 1901 - - ---- 1/1/0/0/0 0/0 "GET /api/tags HTTP/1.1"
```

동시에 요청 세 개를 보내면 세 서버가 하나씩 나눠 받습니다.

```bash
# 요청 세 개를 동시에 보내기
for i in 1 2 3; do
  curl -s http://$IP:11434/api/generate -d '{"model":"qwen3.5:9b","prompt":"안녕","stream":false}' -o /dev/null &
done; wait

# 요청을 받은 서버
kubectl -n ollama logs deploy/ollama-router --since=10m | grep api/generate
```

클러스터 안의 클라이언트는 `http://ollama.ollama.svc.cluster.local:11434` 하나로 모든 서버를 씁니다.

- **확인:** 통계의 모든 서버가 `UP`, `L7OK` 이고 `slim` 이 1 입니다. 모델 목록 요청은 로그에 `by-speed/` 뒤 첫 서버 이름으로 남고, 동시에 보낸 세 요청은 `by-speed/winpc-780m`, `by-speed/pve01-cpu`, `by-speed/pve01-610m` 으로 모두 다른 서버에 남습니다.

## 마무리

Ollama 모델 서버를 Proxmox LXC 에 플레이북으로 만들고, 클러스터 안에서는 `ollama` Service 주소 하나로 비어 있는 서버 가운데 빠른 서버부터 요청을 채우는 구성을 완성했습니다. 동시에 서버 수만큼 요청을 처리하고, 나머지는 줄을 섰다가 먼저 빈 서버로 갑니다. 서버를 더할 때는 `ollama_backends` 와 inventory 에 CT 를 넣어 두 플레이북을 다시 실행하고, 잰 속도 순서에 맞춰 `haproxy.cfg` 에 `server` 줄을 넣습니다.

## 참고 자료

- [Ollama FAQ](https://docs.ollama.com/faq)
- [Ollama GPU 지원](https://docs.ollama.com/gpu)
- [Ollama API](https://docs.ollama.com/api)
- [HAProxy 3.2 Configuration Manual](https://docs.haproxy.org/3.2/configuration.html)
- [Proxmox VE Administration Guide: Linux Container](https://pve.proxmox.com/pve-docs/chapter-pct.html)
- [community.proxmox.proxmox module – Ansible documentation](https://docs.ansible.com/ansible/latest/collections/community/proxmox/proxmox_module.html)
