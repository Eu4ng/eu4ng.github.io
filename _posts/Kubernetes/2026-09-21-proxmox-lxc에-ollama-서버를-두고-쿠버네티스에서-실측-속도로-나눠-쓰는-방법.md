---
layout: post
title: Proxmox LXC에 Ollama 서버를 두고 쿠버네티스에서 실측 속도로 나눠 쓰는 방법
description: Ollama 모델 서버를 Ansible 플레이북으로 Proxmox LXC 에 여러 대 만들고, 쿠버네티스에는 HAProxy 라우터만 GitOps 로 배포해 클러스터 안 주소 하나로 비어 있는 서버에 요청을 나누고, 어느 서버를 먼저 쓸지는 라우터가 잰 처리 속도로 정하는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, lxc, ansible, ollama, haproxy, kubernetes, argo-cd, gitops]
permalink: /posts/37/
---

모델 서버는 쿠버네티스 파드가 아니라 Proxmox 의 **LXC** 컨테이너(/posts/65/)에 Ansible 플레이북으로 만들고, 쿠버네티스에는 요청을 나눠 주는 HAProxy 라우터만 GitOps 로 배포합니다. worker VM 안에서 돌리면 모델 크기만큼 VM 메모리를 크게 잡아 두어야 하고, 한 번 잡힌 메모리는 모델을 내려도 호스트로 바로 돌아오지 않습니다(/posts/66/). LXC 는 호스트 커널 위의 프로세스라 모델을 내리면 메모리가 호스트로 돌아가고, 호스트의 iGPU 도 장치 파일 하나로 넘겨 씁니다. iGPU 가 다른 호스트의 컨테이너, LAN 의 다른 PC 처럼 속도가 다른 서버를 여러 대 두고, 라우터는 요청 하나에 서버 하나를 배정합니다(/posts/70/). 비어 있는 서버가 여럿이면 라우터가 실제 요청을 처리하며 잰 속도에 따라 빠른 서버로 더 많이 보냅니다. 그래서 동시에 서버 수만큼 요청을 처리하고, 서버 순서를 설정에 적어 두지 않아도 서버 사정이 바뀌면 분배가 따라갑니다. Ollama 공식 문서는 서버 한 대를 기준으로 하지만, 이 글은 여러 서버 앞에 HAProxy 를 두고 서버마다 동시 요청을 하나로 제한합니다.

1. 변수 채우기
2. 플레이북 실행
3. LAN 의 PC 추가와 서버 확인
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
| 작성 기준일 | `2026-10-04` |

다음 항목이 준비되어 있어야 합니다.

- `proxmox-ansible` 저장소, Proxmox API 토큰, 내부망 DNS ([Proxmox에 Ansible로 내부망 DNS 컨테이너 만드는 방법](/posts/41/)). 이 글의 플레이북은 그 글의 CT 템플릿과 변수를 쓰고, 새 CT 의 이름을 내부망 DNS 가 풉니다.
- 노드가 내부망 DNS 를 쓰는 쿠버네티스 클러스터 ([Proxmox에 Ansible로 kubeadm 쿠버네티스 클러스터 만드는 방법](/posts/46/)). 파드가 CoreDNS 를 거쳐 CT 이름(`ollama-610m.[DOMAIN]` 등)을 풉니다.
- Argo CD 가 GitOps 저장소의 `services/<이름>/` 폴더를 Application 으로 만드는 구성 ([쿠버네티스에 Argo CD 설치하고 GitOps로 서비스 추가하는 방법](/posts/36/))
- CT 마다 비어 있는 VM ID 와 고정 IP, 가장 큰 모델보다 넉넉한 메모리(여기서는 12GB)와 디스크 40GB
- iGPU CT 를 둘 Proxmox 호스트에 `/dev/dri/renderD128` (호스트에서 `ls /dev/dri` 로 확인)

## 1. 변수 채우기

`proxmox-ansible` 저장소의 `group_vars/all.yml` 에 Ollama 버전, 받아 둘 모델, 만들 CT 목록을 추가합니다. `ollama_backends` 의 항목마다 CT 하나가 생기고, `gpu: true` 인 CT 에는 그 Proxmox 호스트의 iGPU 를 넘깁니다. CT 템플릿, 스토리지, 게이트웨이, SSH 키, DNS 주소는 [내부망 DNS 글](/posts/41/)에서 채운 값을 그대로 씁니다.

```yaml
# ---- ollama: 모델 서버 LXC (playbooks/ollama.yml) ----
# 호스트의 iGPU 를 /dev/dri 로 넘겨 Vulkan 으로 돌리거나(gpu: true) CPU 로 돌립니다. VM 이 아니라 LXC 라 모델을 내리면 메모리를 호스트에 돌려줍니다.
# 클러스터의 ollama 서비스(k8s-gitops services/ollama, HAProxy)가 비어 있는 서버에 보냅니다. 어느 서버를 먼저 쓸지는 그쪽이 실측 속도로 정합니다.
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
  - { name: ollama-610m, pve: pve01, vmid: 212, ip: [OLLAMA_610M_IP], cores: 4,  memory: 12288, disk: 40, gpu: true }
  - { name: ollama-780m, pve: pve02, vmid: 213, ip: [OLLAMA_780M_IP], cores: 8,  memory: 49152, disk: 40, gpu: true }
```
{: file="group_vars/all.yml" }

inventory 에는 같은 이름으로 `ollama` 그룹을 추가합니다. 플레이북이 이 그룹의 CT 에 접속해 Ollama 를 설치하고, 내부망 DNS 가 이 이름을 CT 주소로 답합니다.

```yaml
all:
  children:
    ollama:                       # playbooks/ollama.yml 이 만드는 모델 서버 CT (group_vars 의 ollama_backends)
      hosts:
        ollama-610m:
          ansible_host: [OLLAMA_610M_IP]
          ansible_user: root
        ollama-780m:
          ansible_host: [OLLAMA_780M_IP]
          ansible_user: root
```
{: file="inventory.yml" }

- **확인:** `ansible-inventory --graph` 에 `@ollama` 아래 `ollama-610m`, `ollama-780m` 이 보입니다.

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
# 클러스터에서는 k8s-gitops services/ollama 의 HAProxy 가 이 CT 들을 <이름>.<도메인> 으로 불러 요청을 나눕니다(어느 서버를 먼저 쓸지는 그쪽이 실측 속도로 정합니다).
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

# 새 CT 이름(ollama-610m.[DOMAIN] 등)을 내부망 DNS 에 등록
ansible-playbook playbooks/lan-dns.yml
```

```bash
# 이름과 API 응답 (아무 PC 에서)
for h in ollama-610m ollama-780m; do
  curl -s http://$h.[DOMAIN]:11434/api/tags | grep -o '"name":"[^"]*"'
done
```

- **확인:** `ollama.yml` 의 마지막 `결과` 태스크에 CT 마다 받아 둔 모델 이름이 보이고, iGPU CT 줄 끝에는 `GPU: Vulkan` 이 붙습니다. 위 명령은 CT 마다 `"name":"glm-ocr:latest"`, `"name":"qwen3.5:9b"`, `"name":"gemma4:e4b"` 세 줄을 출력합니다. 호스트에서 `pct exec <CT ID> -- findmnt -n /srv/ollama-models` 가 두 CT 모두 `pve-ollama--models[/store]` 를 보여 주면 같은 저장소를 쓰는 것입니다.

## 3. LAN 의 PC 추가와 서버 확인

LAN 의 다른 PC 에서 도는 Ollama 도 같은 라우터에 넣을 수 있습니다. Windows 의 Ollama 는 기본으로 그 PC 안에서만 요청을 받으므로, PC 에서 아래를 실행한 뒤 작업 표시줄의 Ollama 를 종료하고 다시 켭니다.

```powershell
# 다른 기기에서 받도록 사용자 환경 변수 설정
setx OLLAMA_HOST 0.0.0.0:11434

# 개인 네트워크에서 11434 포트 허용 (관리자 PowerShell)
New-NetFirewallRule -DisplayName "Ollama" -Direction Inbound -Protocol TCP -LocalPort 11434 -Action Allow -Profile Private
```

라우터는 실제 요청을 처리하면서 서버 속도를 스스로 재므로 순서를 정해 줄 필요는 없습니다. 여기서는 서버가 제대로 도는지만 같은 모델과 같은 질문으로 확인합니다. 응답의 `eval_count` 를 `eval_duration`(나노초)으로 나누면 초당 토큰 수입니다. 한 번에 한 서버씩 잽니다.

```bash
# 서버마다 생성 속도 재기 (qwen3.5:9b)
for url in http://[WINPC_IP]:11434 http://ollama-780m.[DOMAIN]:11434 http://ollama-610m.[DOMAIN]:11434; do
  curl -s $url/api/generate -d '{"model":"qwen3.5:9b","prompt":"쿠버네티스를 세 문장으로 설명해 줘","stream":false}' \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print(sys.argv[1], round(r["eval_count"]/r["eval_duration"]*1e9,1), "tok/s")' $url
done
```

| 서버 | 추론 장치 | `qwen3.5:9b` 생성 속도 |
| :--- | :--- | :--- |
| 윈도우 PC | Radeon 780M | 14 tok/s |
| `ollama-780m` | Radeon 780M (iGPU) | 14.1 tok/s |
| `ollama-610m` | Radeon 610M (iGPU) | 5.1 tok/s |

- **확인:** 서버마다 `tok/s` 값이 한 줄씩 나옵니다.

## 4. 라우터 매니페스트 추가

GitOps 저장소의 `services/ollama/` 폴더에 HAProxy 설정, Deployment, Service 를 둡니다. 폴더 이름을 따라 `ollama` 네임스페이스에 배포됩니다.

HAProxy 설정의 핵심은 `backend servers` 입니다. 서버마다 `maxconn 1` 이라 요청 하나가 서버 하나를 차지하고, `balance roundrobin` 은 비어 있는 서버 가운데 가중치 비율로 다음 요청을 받을 서버를 고릅니다. 모두 바쁘면 `timeout queue` 동안 줄을 세웠다가 먼저 빈 서버로 보냅니다. `/api/version` 헬스체크가 두 번 실패한 서버는 건너뛰므로 PC 가 꺼져 있어도 요청이 멈추지 않습니다. 서버가 요청을 처리하다 실패하면(연결 실패, 빈 응답, 5xx) `retry-on` 으로 다른 서버에 다시 보내므로, 쓰는 쪽은 어느 서버가 실패했는지 몰라도 됩니다. 다시 보내려면 요청 본문 전체가 버퍼에 들어가야 해서 `tune.bufsize` 를 1MB 로 키웁니다. 서버 이름은 파드의 DNS 로 풀고(`resolvers lan`), `init-addr` 에 `none` 이 있어 풀리지 않는 서버가 있어도 HAProxy 가 뜹니다.

한 가지 예외가 있습니다. 30B 급 모델은 `backend big`(메모리가 넉넉한 서버 하나)으로만 보냅니다. iGPU 는 호스트 메모리를 그대로 쓰기 때문에 컨테이너의 메모리 한도가 모델 로드를 막아 주지 못합니다. 12GB 컨테이너의 서버에 `gemma4:31b` 를 65K 컨텍스트로 올리자 호스트 메모리 26GB 가 GPU 로 넘어가, 같은 호스트에 있던 쿠버네티스 워커 VM 이 OOM 으로 죽었습니다. `http-buffer-request` 로 요청 본문을 이미 다 받아 두므로 `req.body` 에서 `model` 필드를 정규식으로 읽어 갈 수 있습니다.

```bash
# HAProxy 설정과 가중치 프로그램 내려받기
mkdir -p services/ollama
curl -fsSL https://eu4ng.github.io/assets/files/ollama/haproxy.cfg -o services/ollama/haproxy.cfg
curl -fsSL https://eu4ng.github.io/assets/files/ollama/weights.py -o services/ollama/weights.py
curl -fsSL https://eu4ng.github.io/assets/files/ollama/metrics.py -o services/ollama/metrics.py
curl -fsSL https://eu4ng.github.io/assets/files/ollama/dashboard.json -o services/ollama/dashboard.json
```

가중치는 설정에 적지 않고 `weights.py` 가 정합니다. 라우터 파드에 함께 뜨는 이 프로그램은 5초마다 HAProxy 통계를 읽어 서버마다 요청을 처리하던 시간과 그동안 내보낸 응답 바이트를 모으고, 가장 빠른 서버를 256 으로 둔 가중치를 runtime API(`stats socket`)로 넣습니다. 속도 비율을 세제곱해서 낮추므로 속도가 3분의 1 인 서버의 가중치는 9 쯤이 되어, 빠른 서버가 비어 있는 동안에는 요청이 거의 그쪽으로 갑니다. 처리 시간이 2분에 못 미쳐 아직 속도를 모르는 서버는 256 을 받아 요청을 받아 보게 합니다.

내려받은 뒤 `haproxy.cfg` 의 `[WINPC_IP]` 와 `[DOMAIN]` 을 바꾸고, 없는 서버의 줄은 지웁니다. `server` 줄의 순서는 분배에 영향을 주지 않습니다.

어느 모델이 어느 서버에서 얼마나 쓰였는지는 `metrics.py` 가 셉니다. HAProxy 의 통계 페이지는 서버 단위 누적값뿐이고 파드가 다시 뜨면 0 으로 돌아가므로, 설정의 `log-format` 으로 요청마다 모델·서버·역할·대기열 시간·처리 시간을 key=value 한 줄로 남기고 그 로그를 UDP(`log 127.0.0.1:5514`)로 같은 파드의 `metrics` 컨테이너에도 보냅니다. `metrics.py` 는 이 줄을 받아 Prometheus 카운터·히스토그램으로 내고(`:9100/metrics`), 5초마다 서버마다 `/api/ps` 를 읽어 지금 올라간 모델과 모델이 바뀐 횟수도 냅니다. 모델 이름은 `http-buffer-request` 로 받아 둔 본문에서 `json_query` 로 꺼내 변수에 넣고(`txn.model`), 역할은 쓰는 쪽이 붙이는 `X-Wiki-Role` 헤더에서 읽습니다. HAProxy 자체 지표(서버 상태·가중치·처리 중·대기열)는 내장 익스포터(`http-request use-service prometheus-exporter`)가 통계 포트의 `/metrics` 로 냅니다. 응답에는 `X-Ollama-Server` 헤더로 처리한 서버 이름을 붙여, 쓰는 쪽이 토큰 수와 함께 기록할 수 있게 합니다 — 토큰 수·생성 속도·적재 시간은 Ollama 응답 본문에만 있어 라우터가 셀 수 없습니다.

<details markdown="1">
<summary>services/ollama/haproxy.cfg 전문</summary>

```text
# ollama 요청을 서버 하나에 하나씩 나눕니다. 서버마다 maxconn 1 이라 요청 하나가 서버 하나를 차지하고, 처리 중인 서버는 건너뜁니다.
# 모두 바쁘면 줄을 세웠다가 먼저 빈 서버로 보냅니다. 꺼진 서버는 헬스체크로 건너뜁니다.
# 빈 서버가 여럿일 때 어디로 보낼지는 가중치가 정하고, 가중치는 옆 컨테이너(weights.py)가 서버별 실제 처리 속도를 재서 계속 고칩니다.
# 그래서 이 파일의 서버 순서와 weight 값은 우선순위가 아닙니다(시작할 때의 값일 뿐입니다).
# 서버는 proxmox-ansible playbooks/ollama.yml 의 LXC 와 윈도우 PC 이고, 이름은 내부망 DNS 가 풉니다. 이 프로세스 하나가 연결 수를 세므로 replicas 는 1 입니다.
global
  log stdout format raw local0 info
  log 127.0.0.1:5514 format raw local0 info   # 같은 파드의 metrics.py 가 요청 로그를 받아 모델·서버별 지표로 셉니다(UDP, 파드 안에서만)
  hard-stop-after 115m          # soft-stop(SIGUSR1) 뒤 이 시간이 지나면 남은 연결을 끊고 끝냅니다. 파드 종료 유예(7200s)보다 짧게
  stats socket ipv4@127.0.0.1:9999 level admin   # weights.py 가 가중치를 고치는 통로(파드 안에서만 열립니다)
  maxconn 200                    # 동시 연결 상한(버퍼가 1MB 라 메모리를 제한). 실제 동시 요청은 서버 수 안팎
  tune.bufsize 1048576           # 요청 본문 전체를 버퍼에 담아야 다른 서버로 다시 보낼 수 있습니다(64K 컨텍스트 요청도 수백 KB)

resolvers lan
  parse-resolv-conf              # 파드의 resolv.conf(CoreDNS → 내부망 DNS)
  hold valid 30s

defaults
  mode http
  log global
  option dontlognull             # 준비 상태 검사처럼 요청 없이 닫힌 연결은 기록하지 않습니다
  # 요청마다 한 줄. metrics.py 가 key=value 를 읽어 모델·서버·역할별 요청 수, 대기열 시간(queue_ms), 처리 시간(total_ms - queue_ms),
  # 응답 바이트, 재시도 횟수를 Prometheus 지표로 냅니다. 키 이름을 바꾸면 metrics.py 도 같이 고칩니다.
  log-format "%tr ollama backend=%b server=%s status=%ST retries=%rc queue_ms=%Tw total_ms=%Ta bytes_in=%U bytes_out=%B model=%[var(txn.model)] role=%[var(txn.role)] client=%ci %{+Q}r"
  # 서버가 요청을 처리하다 실패하면(연결 실패, 빈 응답, 5xx) 다른 서버로 다시 보냅니다. 쓰는 쪽은 어느 서버가 실패했는지 몰라도 됩니다
  option http-buffer-request
  # 쓰는 쪽이 연결을 끊었으면(작업 취소, 시간 초과 뒤 재전송) 대기열에 남은 그 요청을 서버로 보내지 않습니다. 없으면 주인 없는 요청이
  # 30B 서버를 몇십 분 차지합니다(2026-10-07 실측)
  option abortonclose
  retries 2
  option redispatch 1
  retry-on conn-failure empty-response 500 502 503 504
  option http-server-close       # 응답이 끝나면 서버 연결을 닫아, 쉬는 keep-alive 연결이 자리를 차지하지 않게 합니다
  timeout connect 5s
  # 끊는 쪽은 라우터가 아니라 쓰는 쪽이어야 합니다(쓰는 쪽의 역할별 timeout). 라우터 상한이 그보다 짧으면 쓰는 쪽은
  # 503 을 받고 서버 장애로 오해합니다. 상한을 쓰는 쪽보다 길게 둡니다.
  timeout client 90m
  timeout server 90m             # 64K 컨텍스트 요청 하나가 수십 분 걸릴 수 있습니다(30B 요약 실측 36분)
  timeout queue 90m              # 전용 서버가 바쁠 때 줄 서는 시간

frontend ollama
  bind :11434
  # 30B 급 모델(qwen3.8:27b·gemma4:31b·muse-glimmer:30b)은 메모리가 넉넉한 서버(ollama-780m, 48GB CT)로만 보냅니다.
  # iGPU 메모리는 호스트 메모리에서 잡혀 CT 메모리 한도 밖입니다. 12GB CT 의 ollama-610m 에 gemma4:31b 를 65K 컨텍스트로 올리자
  # 호스트가 26GB 를 빼앗겨 같은 호스트의 쿠버네티스 워커 VM(24GB)이 OOM 으로 죽었습니다. 윈도우 PC(32GB)도 GPU 에 못 올려 CPU 로 느리게 돕니다.
  # 요청 본문은 http-buffer-request 로 이미 다 받아 두므로 model 필드를 볼 수 있습니다. 모델을 더하거나 서버 메모리를 늘리면 여기를 고칩니다.
  acl big_model req.body -m reg -i '"model"\s*:\s*"(qwen3\.8:27b|gemma4:31b|muse-glimmer:30b)'
  # 로그·지표용: 요청 본문의 모델 이름과 쓰는 쪽이 붙인 역할 헤더(X-Wiki-Role: summarizer 등). 없으면 비어 있습니다
  http-request set-var(txn.model) req.body,json_query('$.model')
  http-request set-var(txn.role) req.hdr(X-Wiki-Role)
  use_backend big if big_model
  default_backend servers

backend servers
  balance roundrobin              # 빈 서버 가운데 가중치 비율로 고릅니다. maxconn 에 찬 서버는 건너뜁니다
  option httpchk GET /api/version
  http-check expect status 200
  default-server check inter 5s fall 2 rise 2 maxconn 1 weight 100 resolvers lan init-addr last,libc,none
  http-response set-header X-Ollama-Server %s   # 어느 서버가 처리했는지 쓰는 쪽에 알립니다(쓰는 쪽이 토큰 수와 함께 기록할 수 있게)
  # LXC 서버도 상태 보고 에이전트(proxmox-ansible templates/ollama/ollama-agent.py, 포트 11435)가 있습니다. GPU 가 멈춰 llama-server 가
  # 커널 안(D 상태)에 걸리면 ollama 는 /api/version 에 답해 헬스체크를 통과하지만 에이전트가 drain 으로 답합니다(2026-10-06 610m, 14시간
  # 동안 호출마다 20분씩 매달렸던 일의 재발 방지). 에이전트가 없거나 답이 없으면 헬스체크만 봅니다.
  server pve02-780m ollama-780m.[DOMAIN]:11434 agent-check agent-port 11435 agent-inter 5s
  # 610m(pve01, 12GB CT)의 iGPU 는 호스트 RAM 을 쓴다. pve01 메모리 예산(VM 고정 34GB + CT·호스트 6GB + iGPU 상한 14GB = 54/60GB,
  # proxmox-ansible gtt_mb·worker-1 20GB, 2026-10-07)으로 보통 크기(gemma4:12b 약 11GB)까지 받는다. 상한을 넘으면 교착 대신 할당 실패(500)다
  server pve01-610m ollama-610m.[DOMAIN]:11434 agent-check agent-port 11435 agent-inter 5s
  # 윈도우 PC 는 사용자 데스크톱입니다. 꺼지면 헬스체크로 빠지고, PC 의 상태 보고 스크립트(windows-agent.ps1, 포트 11435)가
  # "drain" 이라고 답하면(Ollama 가 아닌 프로그램이 GPU 를 쓰는 중) 새 요청을 보내지 않습니다. 스크립트가 없거나 답이 없으면 헬스체크만 봅니다.
  # 같은 스크립트가 LXC 에이전트와 같은 상태 JSON(:11437/status, 계산 중인지)도 내서 wiki-papers 가 이 서버로 간 호출의 멈춤도 상태로 판정합니다.
  server winpc-780m [WINPC_IP]:11434 agent-check agent-port 11435 agent-inter 5s

# 30B 급 모델 전용. 서버 하나라 가중치 조정(weights.py)은 하지 않습니다. 780m 이 바쁘면 여기서 줄을 섭니다(timeout queue).
backend big
  balance roundrobin              # 빈 서버 가운데 가중치 비율로. 780m 이 비어 있으면 거의 780m 으로 간다
  option httpchk GET /api/version
  http-check expect status 200
  http-response set-header X-Ollama-Server %s
  server pve02-780m ollama-780m.[DOMAIN]:11434 check inter 5s fall 2 rise 2 maxconn 1 weight 100 resolvers lan init-addr last,libc,none
  # 윈도우 PC(32GB)는 30B 를 못 돌린다 — qwen3.8:27b 를 65K 컨텍스트로 올리면 Vulkan 이 KV 캐시 버퍼를 못 잡아 즉시 500 을 낸다
  # (실측). 메모리 기준 에이전트(11436)로는 못 막는다(여유 메모리가 아니라 장치 메모리 한도 문제). 컨텍스트를 줄이거나 CPU 전용으로
  # 올릴 방법이 서버 단위 설정으로 생기기 전까지는 넣지 않는다.
  # server winpc-780m [WINPC_IP]:11434 check inter 5s fall 2 rise 2 maxconn 1 weight 40 agent-check agent-port 11436 agent-inter 5s

# 통계 페이지(/)와 Prometheus 지표(/metrics — 서버별 상태·가중치·처리 중·대기열·응답 코드. ServiceMonitor 가 긁습니다).
# 준비 상태 검사가 5초마다 오므로 이 frontend 는 기록하지 않습니다.
frontend stats
  bind :8404
  no log
  stats enable
  stats uri /
  stats refresh 5s
  http-request use-service prometheus-exporter if { path /metrics }
```
{: file="services/ollama/haproxy.cfg" }

</details>

<details markdown="1">
<summary>services/ollama/weights.py 전문</summary>

```python
#!/usr/bin/env python3
"""HAProxy 서버 가중치를 실제 처리 속도에 맞춰 계속 고친다.

라우터(haproxy.cfg)는 빈 서버 가운데 가중치 비율로 요청을 보낸다. 이 프로그램은 HAProxy 통계에서 서버마다
"요청을 처리하던 시간"과 "그동안 내보낸 응답 바이트"를 모아 속도(바이트/초)를 구하고, 가장 빠른 서버를 256 으로 둔
가중치를 runtime API 로 넣는다. 서버 순서를 설정이나 문서에 적지 않아도 서버 사정이 바뀌면 가중치가 따라간다.
아직 충분히 재지 못한 서버는 가장 높은 가중치를 줘서 요청을 받아 재 볼 수 있게 한다.
"""

from __future__ import annotations

import argparse
import csv
import json
import logging
import socket
import sys
import time

EXIT_OK = 0
EXIT_FAIL = 1
MAX_WEIGHT = 256

log = logging.getLogger("weights")


def parse_stat(text: str, backend: str) -> dict[str, dict[str, int]]:
    """`show stat` CSV 에서 그 백엔드의 서버별 현재 연결 수(scur)와 누적 응답 바이트(bout)를 뽑는다."""
    rows = csv.DictReader(text.lstrip("# ").splitlines())
    servers: dict[str, dict[str, int]] = {}
    for row in rows:
        if row.get("pxname") != backend or row.get("svname") in {"FRONTEND", "BACKEND"}:
            continue
        servers[row["svname"]] = {
            "scur": int(row.get("scur") or 0),
            "bout": int(row.get("bout") or 0),
            "weight": int(row.get("weight") or 0),
        }
    return servers


class Meter:
    """서버 하나의 속도. 오래된 측정은 처리 시간 기준 반감기로 흐려진다(쉬는 동안에는 흐려지지 않는다)."""

    def __init__(self, half_life: float) -> None:
        self.half_life = half_life
        self.busy = 0.0
        self.sent = 0.0
        self.last_bout: int | None = None

    def update(self, scur: int, bout: int, elapsed: float) -> None:
        delta = 0 if self.last_bout is None else bout - self.last_bout
        self.last_bout = bout
        delta = max(delta, 0)  # HAProxy 가 다시 시작해 누적값이 0 부터 다시 센다
        if scur <= 0 and delta == 0:
            return
        keep = 0.5 ** (elapsed / self.half_life)
        self.busy = self.busy * keep + elapsed
        self.sent = self.sent * keep + delta

    def speed(self, min_busy: float) -> float | None:
        """바이트/초. 처리 시간이 min_busy 초에 못 미치면 아직 모른다(None)."""
        if self.busy < min_busy or self.sent <= 0:
            return None
        return self.sent / self.busy


def weights(speeds: dict[str, float | None], exponent: float) -> dict[str, int]:
    """가장 빠른 서버를 256 으로 두고 속도 비율의 거듭제곱으로 낮춘다. 속도를 모르는 서버는 256."""
    known = [s for s in speeds.values() if s is not None]
    best = max(known, default=None)
    result = {}
    for name, speed in speeds.items():
        if speed is None or best is None:
            result[name] = MAX_WEIGHT
        else:
            result[name] = max(1, round(MAX_WEIGHT * (speed / best) ** exponent))
    return result


def command(address: tuple[str, int], line: str, timeout: float = 5.0) -> str:
    """runtime API 에 명령 하나를 보내고 답을 받는다."""
    with socket.create_connection(address, timeout=timeout) as sock:
        sock.sendall(line.encode() + b"\n")
        chunks = []
        while chunk := sock.recv(65536):
            chunks.append(chunk)
    return b"".join(chunks).decode()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="HAProxy 서버 가중치를 서버별 실제 처리 속도(응답 바이트/처리 시간)에 맞춰 계속 고친다.",
        epilog=(
            "예:\n"
            "  python3 weights.py --socket 127.0.0.1:9999 --backend servers\n"
            "  python3 weights.py --once --dry-run      # 한 번 읽고 넣을 가중치만 출력\n\n"
            '출력: 가중치를 바꿀 때마다 stdout 에 JSON 한 줄 {"weights": {...}, "speeds": {...}}\n'
            "exit code: 0 정상 종료(--once), 1 runtime API 에 연결 실패(--once)"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--socket",
        default="127.0.0.1:9999",
        help="HAProxy runtime API 주소 (기본 127.0.0.1:9999)",
    )
    parser.add_argument(
        "--backend", default="servers", help="가중치를 고칠 백엔드 이름 (기본 servers)"
    )
    parser.add_argument(
        "--interval", type=float, default=5.0, help="통계를 읽는 간격(초, 기본 5)"
    )
    parser.add_argument(
        "--half-life",
        type=float,
        default=1800.0,
        help="측정이 절반으로 흐려지는 처리 시간(초, 기본 1800)",
    )
    parser.add_argument(
        "--min-busy",
        type=float,
        default=120.0,
        help="속도를 믿기 시작하는 처리 시간(초, 기본 120)",
    )
    parser.add_argument(
        "--exponent",
        type=float,
        default=3.0,
        help="속도 비율에 거는 거듭제곱. 클수록 빠른 서버에 몰린다 (기본 3)",
    )
    parser.add_argument("--once", action="store_true", help="한 번만 읽고 끝낸다")
    parser.add_argument(
        "--dry-run", action="store_true", help="가중치를 넣지 않고 출력만 한다"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(message)s")
    host, _, port = args.socket.rpartition(":")
    address = (host, int(port))
    meters: dict[str, Meter] = {}
    applied: dict[str, int] = {}
    last = time.monotonic()
    while True:
        try:
            stat = parse_stat(command(address, "show stat"), args.backend)
        except OSError as exc:
            log.warning("runtime API 에 연결하지 못했다: %s", exc)
            if args.once:
                return EXIT_FAIL
            time.sleep(args.interval)
            continue
        now = time.monotonic()
        for name, row in stat.items():
            meters.setdefault(name, Meter(args.half_life)).update(
                row["scur"], row["bout"], now - last
            )
        last = now
        speeds = {name: meters[name].speed(args.min_busy) for name in stat}
        wanted = weights(speeds, args.exponent)
        changed = {
            n: w for n, w in wanted.items() if applied.get(n, stat[n]["weight"]) != w
        }
        if changed or args.once:
            if not args.dry_run:
                try:
                    for name, weight in changed.items():
                        command(address, f"set weight {args.backend}/{name} {weight}")
                    applied.update(changed)
                except OSError as exc:
                    log.warning("가중치를 넣지 못했다: %s", exc)
            rounded = {n: None if s is None else round(s, 1) for n, s in speeds.items()}
            print(
                json.dumps({"weights": wanted, "speeds": rounded}, ensure_ascii=False),
                flush=True,
            )
        if args.once:
            return EXIT_OK
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
```
{: file="services/ollama/weights.py" }

</details>

<details markdown="1">
<summary>services/ollama/metrics.py 전문</summary>

```python
#!/usr/bin/env python3
"""ollama 라우터의 요청 로그와 모델 서버의 상태를 Prometheus 지표로 낸다.

라우터(haproxy.cfg)는 요청마다 `log-format` 의 한 줄(key=value: backend, server, status, queue_ms, total_ms, bytes_out, model, role …)을
UDP 로 이 프로그램에 보낸다. HAProxy 자체 익스포터는 서버 단위까지만 세므로, "어느 모델이 어느 서버에서 얼마나" 는 여기서 센다.
그리고 HAProxy runtime API(`show stat`)로 서버 주소를 알아내 서버마다 `/api/ps` 를 읽어 지금 올라간 모델·크기를 내고, 올라간
모델이 바뀐 횟수(교체)를 센다 — 라우터를 거치지 않은 직접 호출도 "모델이 올라감" 수준으로는 잡힌다.
윈도우 PC 의 상태 보고 에이전트(windows-agent.ps1)에 `stats` 를 보내면 여유 메모리·GPU 사용률을 JSON 으로 답하므로 그것도 낸다.
표준 라이브러리만 쓴다(라우터 파드의 python:alpine 이미지).
"""

from __future__ import annotations

import argparse
import csv
import json
import logging
import socket
import sys
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EXIT_OK = 0
EXIT_FAIL = 1
# 처리 시간(초) 버킷. 30B 요약 한 건이 36분까지 걸렸다(2026-10-06)
DURATION_BUCKETS = (5, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600)
QUEUE_BUCKETS = (1, 10, 30, 60, 300, 600, 1200, 1800, 3600)

log = logging.getLogger("metrics")


def _label_str(labels: dict[str, str]) -> str:
    if not labels:
        return ""
    body = ",".join(
        f'{k}="{str(v).replace(chr(92), chr(92) * 2).replace(chr(34), chr(92) + chr(34))}"'
        for k, v in labels.items()
    )
    return "{" + body + "}"


class Registry:
    """카운터·게이지·히스토그램을 들고 Prometheus 텍스트 형식으로 쓴다. 스레드 여럿이 쓰므로 잠근다."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._counters: dict[str, dict[tuple, float]] = {}
        self._gauges: dict[str, dict[tuple, float]] = {}
        self._hists: dict[str, dict[tuple, list[float]]] = {}
        self._meta: dict[str, tuple[str, str, tuple[str, ...], tuple[float, ...]]] = {}

    def declare(
        self,
        name: str,
        kind: str,
        help_text: str,
        labels: tuple[str, ...],
        buckets: tuple[float, ...] = (),
    ) -> None:
        self._meta[name] = (kind, help_text, labels, buckets)
        {"counter": self._counters, "gauge": self._gauges, "histogram": self._hists}[
            kind
        ].setdefault(name, {})

    def _key(self, name: str, labels: dict[str, str]) -> tuple:
        return tuple(str(labels.get(k, "")) for k in self._meta[name][2])

    def inc(self, name: str, labels: dict[str, str], value: float = 1.0) -> None:
        with self._lock:
            store = self._counters[name]
            store[self._key(name, labels)] = (
                store.get(self._key(name, labels), 0.0) + value
            )

    def set(self, name: str, labels: dict[str, str], value: float) -> None:
        with self._lock:
            self._gauges[name][self._key(name, labels)] = value

    def clear_gauge(self, name: str, prefix: dict[str, str]) -> None:
        """앞쪽 라벨이 prefix 와 같은 게이지를 모두 지운다(서버의 모델 목록을 새로 쓸 때)."""
        with self._lock:
            want = tuple(str(v) for v in prefix.values())
            store = self._gauges[name]
            for key in [k for k in store if k[: len(want)] == want]:
                del store[key]

    def observe(self, name: str, labels: dict[str, str], value: float) -> None:
        buckets = self._meta[name][3]
        with self._lock:
            row = self._hists[name].setdefault(
                self._key(name, labels), [0.0] * (len(buckets) + 3)
            )  # 버킷들, +Inf, sum, count
            for i, bound in enumerate(buckets):
                if value <= bound:
                    row[i] += 1
            row[len(buckets)] += 1
            row[len(buckets) + 1] += value
            row[len(buckets) + 2] += 1

    def render(self) -> str:
        lines: list[str] = []
        with self._lock:
            for name, (kind, help_text, label_names, buckets) in self._meta.items():
                lines.append(f"# HELP {name} {help_text}")
                lines.append(f"# TYPE {name} {kind}")
                if kind == "histogram":
                    for key, row in sorted(self._hists[name].items()):
                        base = dict(zip(label_names, key))
                        for i, bound in enumerate(buckets):
                            lines.append(
                                f"{name}_bucket{_label_str({**base, 'le': _fmt(bound)})} {_fmt(row[i])}"
                            )
                        lines.append(
                            f"{name}_bucket{_label_str({**base, 'le': '+Inf'})} {_fmt(row[len(buckets)])}"
                        )
                        lines.append(
                            f"{name}_sum{_label_str(base)} {_fmt(row[len(buckets) + 1])}"
                        )
                        lines.append(
                            f"{name}_count{_label_str(base)} {_fmt(row[len(buckets) + 2])}"
                        )
                    continue
                store = (
                    self._counters[name] if kind == "counter" else self._gauges[name]
                )
                for key, value in sorted(store.items()):
                    lines.append(
                        f"{name}{_label_str(dict(zip(label_names, key)))} {_fmt(value)}"
                    )
        return "\n".join(lines) + "\n"


def _fmt(value: float) -> str:
    return str(int(value)) if float(value).is_integer() else repr(float(value))


def build_registry() -> Registry:
    reg = Registry()
    reg.declare(
        "ollama_requests_total",
        "counter",
        "라우터를 거친 요청 수",
        ("backend", "server", "model", "role", "status"),
    )
    reg.declare(
        "ollama_request_duration_seconds",
        "histogram",
        "서버가 요청을 처리한 시간(대기열 제외)",
        ("backend", "server", "model", "role"),
        DURATION_BUCKETS,
    )
    reg.declare(
        "ollama_queue_duration_seconds",
        "histogram",
        "라우터 대기열에서 기다린 시간",
        ("backend", "model", "role"),
        QUEUE_BUCKETS,
    )
    reg.declare(
        "ollama_response_bytes_total",
        "counter",
        "서버가 내보낸 응답 바이트",
        ("backend", "server", "model", "role"),
    )
    reg.declare(
        "ollama_retries_total",
        "counter",
        "다른 서버로 다시 보낸 횟수",
        ("backend", "server"),
    )
    reg.declare("ollama_log_lines_total", "counter", "받은 로그 줄 수", ("result",))
    reg.declare(
        "ollama_loaded_model_bytes",
        "gauge",
        "서버에 지금 올라간 모델의 크기(/api/ps size)",
        ("server", "model"),
    )
    reg.declare(
        "ollama_loaded_model_vram_bytes",
        "gauge",
        "서버에 지금 올라간 모델이 GPU 에 올린 크기(/api/ps size_vram)",
        ("server", "model"),
    )
    reg.declare(
        "ollama_model_loads_total",
        "counter",
        "서버에 모델이 새로 올라간 횟수(교체 포함)",
        ("server", "model"),
    )
    reg.declare("ollama_server_up", "gauge", "/api/ps 에 답했으면 1", ("server",))
    reg.declare(
        "ollama_agent_free_gb",
        "gauge",
        "상태 보고 에이전트가 답한, Ollama 가 쓸 수 있는 메모리(GB)",
        ("server", "port"),
    )
    reg.declare(
        "ollama_agent_other_gpu_percent",
        "gauge",
        "상태 보고 에이전트가 답한, Ollama 가 아닌 프로세스의 GPU 사용률 합(%)",
        ("server", "port"),
    )
    reg.declare(
        "ollama_agent_drain",
        "gauge",
        "상태 보고 에이전트가 drain 이라 답했으면 1",
        ("server", "port"),
    )
    reg.declare(
        "ollama_agent_up",
        "gauge",
        "상태 보고 에이전트가 답했으면 1",
        ("server", "port"),
    )
    return reg


def parse_log_line(line: str) -> dict[str, str] | None:
    """haproxy.cfg 의 log-format 한 줄에서 key=value 를 뽑는다. 라우터 요청 로그가 아니면 None."""
    marker = " ollama "
    at = line.find(marker)
    if at < 0:
        return None
    fields: dict[str, str] = {}
    for token in line[at + len(marker) :].split(" "):
        if token.startswith('"'):
            break  # 요청 줄(%{+Q}r)부터는 보지 않는다
        key, sep, value = token.partition("=")
        if sep:
            fields[key] = value
    return fields if "server" in fields and "status" in fields else None


def record(reg: Registry, fields: dict[str, str]) -> bool:
    """로그 한 줄을 지표에 더한다. 숫자가 깨진 줄은 거짓."""
    try:
        queue_ms = max(int(fields.get("queue_ms", "0")), 0)  # 끊긴 요청은 -1
        total_ms = max(int(fields.get("total_ms", "0")), 0)
        bytes_out = int(fields.get("bytes_out", "0"))
        retries = max(int(fields.get("retries", "0")), 0)
    except ValueError:
        return False
    server = fields["server"] or "-"
    labels = {
        "backend": fields.get("backend", "-") or "-",
        "server": server,
        "model": fields.get("model") or "-",
        "role": fields.get("role") or "-",
    }
    reg.inc("ollama_requests_total", {**labels, "status": fields["status"]})
    reg.inc("ollama_response_bytes_total", labels, bytes_out)
    if retries:
        reg.inc("ollama_retries_total", labels, retries)
    reg.observe("ollama_queue_duration_seconds", labels, queue_ms / 1000)
    if server != "<NOSRV>" and fields["status"].startswith("2"):
        # 처리 시간은 끝까지 간 요청만 센다. 끊긴 요청(-1, 5xx)은 요청 수와 상태로만 남긴다
        reg.observe(
            "ollama_request_duration_seconds",
            labels,
            max(total_ms - queue_ms, 0) / 1000,
        )
    return True


def serve_logs(reg: Registry, bind: tuple[str, int], stop: threading.Event) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(bind)
    sock.settimeout(1.0)
    while not stop.is_set():
        try:
            data, _ = sock.recvfrom(65535)
        except TimeoutError:
            continue
        for line in data.decode("utf-8", "replace").splitlines():
            fields = parse_log_line(line)
            if fields is None:
                reg.inc("ollama_log_lines_total", {"result": "ignored"})
            elif record(reg, fields):
                reg.inc("ollama_log_lines_total", {"result": "parsed"})
            else:
                reg.inc("ollama_log_lines_total", {"result": "invalid"})


def runtime_command(address: tuple[str, int], line: str, timeout: float = 5.0) -> str:
    """HAProxy runtime API 에 명령 하나를 보내고 답을 받는다."""
    with socket.create_connection(address, timeout=timeout) as sock:
        sock.sendall(line.encode() + b"\n")
        chunks = []
        while chunk := sock.recv(65536):
            chunks.append(chunk)
    return b"".join(chunks).decode()


def server_addresses(stat_csv: str) -> dict[str, str]:
    """`show stat` CSV 에서 서버 이름 → host:port. 여러 백엔드에 같은 이름이 있으면 하나로 본다."""
    rows = csv.DictReader(stat_csv.lstrip("# ").splitlines())
    found: dict[str, str] = {}
    for row in rows:
        name, addr = row.get("svname"), row.get("addr") or ""
        if name in {"FRONTEND", "BACKEND"} or not name or ":" not in addr:
            continue
        found.setdefault(name, addr)
    return found


def loaded_models(ps: dict) -> dict[str, tuple[int, int]]:
    """/api/ps 응답에서 모델 → (size, size_vram)."""
    out: dict[str, tuple[int, int]] = {}
    for item in ps.get("models") or []:
        name = item.get("model") or item.get("name")
        if name:
            out[name] = (int(item.get("size") or 0), int(item.get("size_vram") or 0))
    return out


class ModelWatcher:
    """서버마다 올라간 모델을 추적하고, 새로 올라간 모델을 교체로 센다."""

    def __init__(self, reg: Registry) -> None:
        self.reg = reg
        self.seen: dict[str, set[str]] = {}

    def update(self, server: str, models: dict[str, tuple[int, int]] | None) -> None:
        self.reg.set("ollama_server_up", {"server": server}, 0 if models is None else 1)
        if models is None:
            return
        before = self.seen.get(server)
        for model in models:
            if before is not None and model not in before:
                self.reg.inc(
                    "ollama_model_loads_total", {"server": server, "model": model}
                )
        self.seen[server] = set(models)
        self.reg.clear_gauge("ollama_loaded_model_bytes", {"server": server})
        self.reg.clear_gauge("ollama_loaded_model_vram_bytes", {"server": server})
        for model, (size, vram) in models.items():
            self.reg.set(
                "ollama_loaded_model_bytes", {"server": server, "model": model}, size
            )
            self.reg.set(
                "ollama_loaded_model_vram_bytes",
                {"server": server, "model": model},
                vram,
            )


def fetch_ps(addr: str, timeout: float) -> dict[str, tuple[int, int]] | None:
    try:
        with urllib.request.urlopen(f"http://{addr}/api/ps", timeout=timeout) as resp:
            return loaded_models(json.load(resp))
    except (OSError, ValueError):
        return None


def query_agent(address: tuple[str, int], timeout: float) -> dict | None:
    """windows-agent.ps1 에 stats 를 보내 JSON 한 줄을 받는다. 옛 에이전트는 ready/drain 만 답한다."""
    try:
        with socket.create_connection(address, timeout=timeout) as sock:
            sock.sendall(b"stats\n")
            data = b""
            while b"\n" not in data and len(data) < 4096:
                chunk = sock.recv(1024)
                if not chunk:
                    break
                data += chunk
    except OSError:
        return None
    line = data.decode("utf-8", "replace").strip()
    if line.startswith("{"):
        try:
            return json.loads(line)
        except ValueError:
            return None
    return {"state": line.split()[0]} if line else None


def poll_servers(
    reg: Registry, args: argparse.Namespace, stop: threading.Event
) -> None:
    runtime = args.socket.rpartition(":")
    address = (runtime[0], int(runtime[2]))
    watcher = ModelWatcher(reg)
    agents = dict(item.split("=", 1) for item in args.agent)
    while not stop.is_set():
        try:
            servers = server_addresses(runtime_command(address, "show stat"))
        except OSError as exc:
            log.warning("runtime API 에 연결하지 못했다: %s", exc)
            servers = {}
        for name, addr in servers.items():
            watcher.update(name, fetch_ps(addr, args.timeout))
        for name, target in agents.items():
            host, _, port = target.rpartition(":")
            reply = query_agent((host, int(port)), args.timeout)
            labels = {"server": name, "port": port}
            reg.set("ollama_agent_up", labels, 0 if reply is None else 1)
            if reply is None:
                continue
            reg.set(
                "ollama_agent_drain", labels, 1 if reply.get("state") == "drain" else 0
            )
            for key, metric in (
                ("free_gb", "ollama_agent_free_gb"),
                ("other_gpu_percent", "ollama_agent_other_gpu_percent"),
            ):
                if isinstance(reply.get(key), (int, float)):
                    reg.set(metric, labels, float(reply[key]))
        stop.wait(args.interval)


def make_handler(reg: Registry):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path.split("?")[0] != "/metrics":
                self.send_response(404)
                self.end_headers()
                return
            body = reg.render().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(
            self, *_: object
        ) -> None:  # 긁을 때마다 찍히는 접근 로그를 끈다
            return

    return Handler


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="ollama 라우터의 요청 로그(UDP)와 모델 서버의 /api/ps 를 Prometheus 지표로 낸다.",
        epilog=(
            "예:\n"
            "  python3 metrics.py --socket 127.0.0.1:9999 --agent winpc-780m=192.168.0.15:11436\n"
            "  python3 metrics.py --once                 # 서버 상태를 한 번 읽고 지표 텍스트를 stdout 에 낸다\n\n"
            "exit code: 0 정상, 1 runtime API 에 연결 실패(--once)"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--socket",
        default="127.0.0.1:9999",
        help="HAProxy runtime API 주소 (기본 127.0.0.1:9999)",
    )
    parser.add_argument(
        "--log-port",
        type=int,
        default=5514,
        help="HAProxy 로그를 받을 UDP 포트 (기본 5514)",
    )
    parser.add_argument(
        "--port", type=int, default=9100, help="/metrics 를 열 포트 (기본 9100)"
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=5.0,
        help="서버 /api/ps 를 읽는 간격(초, 기본 5)",
    )
    parser.add_argument(
        "--timeout", type=float, default=3.0, help="서버·에이전트 응답 상한(초, 기본 3)"
    )
    parser.add_argument(
        "--agent",
        action="append",
        default=[],
        metavar="SERVER=HOST:PORT",
        help="상태 보고 에이전트(windows-agent.ps1) 주소. 여러 번 줄 수 있다",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="서버 상태를 한 번 읽고 지표를 출력한 뒤 끝낸다",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(message)s")
    reg = build_registry()
    stop = threading.Event()
    if args.once:
        runtime = args.socket.rpartition(":")
        try:
            servers = server_addresses(
                runtime_command((runtime[0], int(runtime[2])), "show stat")
            )
        except OSError as exc:
            log.error("runtime API 에 연결하지 못했다: %s", exc)
            return EXIT_FAIL
        watcher = ModelWatcher(reg)
        for name, addr in servers.items():
            watcher.update(name, fetch_ps(addr, args.timeout))
        print(reg.render(), end="")
        return EXIT_OK
    threading.Thread(
        target=serve_logs, args=(reg, ("0.0.0.0", args.log_port), stop), daemon=True
    ).start()
    threading.Thread(target=poll_servers, args=(reg, args, stop), daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(reg))
    log.info("로그 UDP :%d, /metrics :%d", args.log_port, args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
```
{: file="services/ollama/metrics.py" }

</details>

라우터는 한 프로세스가 서버마다 연결 수를 세므로 `replicas` 는 1 입니다. 두 개로 늘리면 각자 따로 세어 한 서버에 요청이 겹칩니다. `weights` 컨테이너는 같은 ConfigMap 의 `weights.py` 를 실행하고, 파드 안에서만 열리는 9999 포트로 HAProxy 에 가중치를 넣습니다. `metrics` 컨테이너는 같은 ConfigMap 의 `metrics.py` 를 실행합니다. `--agent` 는 윈도우 PC 의 상태 보고 스크립트 주소로, 그 스크립트는 `stats` 를 받으면 여유 메모리를 JSON 으로 답합니다(라우터의 agent-check 에는 전처럼 ready/drain 만 답합니다).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama-router
spec:
  replicas: 1                # 서버마다 동시 요청 1개(maxconn 1)를 이 프로세스가 셉니다. 늘리면 한 서버에 요청이 겹칩니다
  # 설정이 바뀌어 파드를 갈 때 진행 중인 요청(수십 분짜리 추론)을 끊지 않습니다. haproxy 이미지는 STOPSIGNAL 이 SIGUSR1(soft-stop)이라
  # 새 연결만 거부하고 기존 요청은 끝까지 보냅니다 — 종료 유예를 요청 상한보다 길게 두고(hard-stop-after 는 haproxy.cfg), 새 파드를
  # 먼저 띄웁니다(RollingUpdate). 겹치는 동안은 두 프로세스가 따로 세어 한 서버에 요청이 2개 갈 수 있지만, ollama 는
  # OLLAMA_NUM_PARALLEL=1 이라 서버 안에서 줄을 섭니다. 2026-10-06 Recreate 로 두 번 재시작하며 논문 5편의 호출이 끊겼습니다.
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  selector:
    matchLabels: { app: ollama-router }
  template:
    metadata:
      labels: { app: ollama-router }
    spec:
      priorityClassName: optional             # 자리가 모자라면 먼저 내보냄(iot/shared/priority-classes)
      terminationGracePeriodSeconds: 7200     # soft-stop 뒤 기존 요청이 끝날 때까지. haproxy.cfg 의 hard-stop-after 보다 길어야 합니다
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
        - name: weights                      # 서버별 실제 처리 속도를 재서 HAProxy 가중치를 고칩니다(weights.py)
          image: python:3.13-alpine
          command: ["python3", "-u", "/app/weights.py", "--socket", "127.0.0.1:9999", "--backend", "servers"]
          volumeMounts:
            - { name: config, mountPath: /app }
          resources:
            requests: { cpu: 5m, memory: 24Mi }
            limits:   { cpu: 100m, memory: 64Mi }
        - name: metrics                      # 요청 로그(UDP 5514)와 서버 /api/ps 를 모델·서버별 Prometheus 지표로(metrics.py). ServiceMonitor 가 :9100 을 긁습니다
          image: python:3.13-alpine
          command: ["python3", "-u", "/app/metrics.py", "--socket", "127.0.0.1:9999",
                    "--agent", "winpc-780m=[WINPC_IP]:11436"]   # 윈도우 PC 의 30B 용 에이전트(여유 메모리 보고)
          ports:
            - { name: metrics, containerPort: 9100 }
          volumeMounts:
            - { name: config, mountPath: /app }
          readinessProbe:
            httpGet: { path: /metrics, port: 9100 }
            periodSeconds: 10
          resources:
            requests: { cpu: 5m, memory: 24Mi }
            limits:   { cpu: 100m, memory: 64Mi }
      volumes:
        - name: config
          configMap: { name: ollama-router }
```
{: file="services/ollama/deployment.yaml" }

라우터는 수십 분짜리 요청을 받으므로 **설정을 바꿀 때 진행 중인 요청을 끊지 않아야** 합니다. 처음에는 `Recreate` 였는데, 설정을 두 번 바꾸는 사이 처리 중이던 논문 다섯 편의 호출이 끊겼습니다. 공식 haproxy 이미지는 `STOPSIGNAL` 이 `SIGUSR1`(soft-stop) 이라, 종료 신호를 받으면 새 연결만 거부하고 쥐고 있던 요청은 끝까지 보냅니다. 그래서 종료 유예(`terminationGracePeriodSeconds`)를 요청 상한보다 길게 두고, `hard-stop-after` 로 그 안에서 마무리하게 하며, `RollingUpdate` 로 새 파드를 먼저 띄웁니다. 준비 상태 검사가 통계 포트를 보므로 soft-stop 으로 포트가 닫히면 옛 파드는 Service 에서 바로 빠집니다.

`priorityClassName: optional` 은 서버 한 대가 죽어 남은 worker 에 자리가 모자랄 때 이 파드를 가장 먼저 내보내게 합니다. 등급은 [쿠버네티스에 Longhorn과 Patroni로 볼륨과 TimescaleDB 이중화하는 방법](/posts/54/)의 6단계에서 만들고, 등급이 없으면 파드가 만들어지지 않습니다.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ollama
  labels: { app: ollama-router }   # servicemonitor.yaml 이 이 라벨로 고릅니다
spec:
  # 요청을 빈 서버 하나에 하나씩 보내는 라우터(haproxy.cfg). 동시에 서버 수만큼 처리하고, 어느 서버가 받을지는 라우터가 정합니다
  selector: { app: ollama-router }
  ports:
    - { name: ollama, port: 11434, targetPort: 11434 }
    - { name: stats, port: 8404, targetPort: 8404 }      # 통계 페이지(/)와 HAProxy 지표(/metrics)
    - { name: metrics, port: 9100, targetPort: 9100 }    # 모델·서버별 지표(metrics.py)
```
{: file="services/ollama/service.yaml" }

클라이언트는 어느 서버가 요청을 받는지 알 필요가 없습니다. 라우터 주소 하나만 쓰고, 서버를 늘리거나 바꿀 때도 라우터 설정만 고칩니다.

`configMapGenerator` 는 `haproxy.cfg`·`weights.py`·`metrics.py` 가 바뀌면 ConfigMap 이름 끝의 해시를 바꿔, 라우터 파드가 새 설정으로 다시 만들어지게 합니다. 대시보드 ConfigMap 은 라벨 `grafana_dashboard: "1"` 로 Grafana sidecar 가 불러오므로 이름을 고정합니다(해시가 바뀌면 옛 파일을 지우고 새로 읽는 사이 대시보드가 잠시 사라집니다).

```yaml
# 모델 서버는 클러스터 밖의 LXC(proxmox-ansible playbooks/ollama.yml)와 윈도우 PC 이고, 여기는 라우터만 둡니다. 빈 서버 가운데 어디로 보낼지는 실측 속도로 정합니다(weights.py).
resources:
  - deployment.yaml
  - service.yaml
  - servicemonitor.yaml   # Prometheus 수집(HAProxy 익스포터 + metrics.py). Grafana 대시보드는 dashboard.json
configMapGenerator:
  - name: ollama-router
    files:
      - haproxy.cfg
      - weights.py
      - metrics.py
  - name: grafana-dashboard-ollama   # 허브 Grafana 의 sidecar 가 라벨로 불러옵니다(iot/shared/dashboards 와 같은 방식)
    files:
      - dashboard.json
    options:
      labels: { grafana_dashboard: "1" }
      disableNameSuffixHash: true
```
{: file="services/ollama/kustomization.yaml" }

Prometheus 가 두 지표를 긁도록 ServiceMonitor 를 둡니다. kube-prometheus-stack 은 기본으로 `release: <릴리스 이름>` 라벨이 붙은 ServiceMonitor 만 고르므로([쿠버네티스에 Prometheus와 Grafana 배포해 자원 사용량 대시보드 만드는 방법](/posts/39/)의 릴리스 이름이 `monitoring`) 라벨을 맞춥니다. Service 에도 선택자가 고를 라벨(`app: ollama-router`)이 있어야 합니다.

```yaml
# 허브 Prometheus(services/monitoring)가 라우터 지표를 긁게 합니다. 두 곳을 긁습니다:
#   :8404/metrics  HAProxy 내장 익스포터 — 서버별 상태(UP/DOWN/DRAIN)·가중치·처리 중·대기열·응답 코드
#   :9100/metrics  metrics.py — 모델·서버·역할별 요청 수·처리 시간·대기열 시간, 서버에 올라간 모델, 윈도우 PC 여유 메모리
# kube-prometheus-stack 은 기본으로 `release: monitoring` 라벨이 붙은 ServiceMonitor 만 고릅니다(네임스페이스는 가리지 않음).
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ollama-router
  labels: { release: monitoring }
spec:
  selector:
    matchLabels: { app: ollama-router }
  endpoints:
    - { port: stats, path: /metrics, interval: 15s }
    - { port: metrics, path: /metrics, interval: 15s }
```
{: file="services/ollama/servicemonitor.yaml" }

`dashboard.json` 은 Grafana 대시보드 **Ollama 사용 현황**입니다. 라우터 지표(서버 상태·가중치·처리 중·대기열, 모델×서버 요청 수·처리 시간·대기열 시간, 올라간 모델·교체 횟수, 윈도우 PC 여유 메모리)에 더해, 쓰는 쪽이 적는 `llm_calls` 테이블(역할·모델·서버별 토큰 수·생성 속도·적재 시간)과 호스트·플러그 기록(메모리·GPU 메모리·벽 전력·토큰당 에너지)을 TimescaleDB 데이터소스로 함께 보입니다. TimescaleDB 가 없으면 그 패널들은 비어 있을 뿐 나머지는 동작합니다.

> 이 글의 이전 판처럼 Ollama 를 파드로 배포해 두었다면, 모델을 담던 PVC 는 `Prune=false` 라 매니페스트를 지워도 남습니다. 라우터가 동작하는 것을 확인한 뒤 `kubectl -n ollama delete pvc ollama-models` 로 지웁니다.
{: .prompt-info }

```bash
# 커밋하고 push
git add services/ollama
git commit -m "feat(ollama): 실측 속도로 서버를 고르는 HAProxy 라우터 추가"
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
curl -s "http://$IP:8404/;csv" | cut -d, -f1,2,3,5,7,18,37 | grep servers
```

```text
servers,pve02-780m,0,0,1,UP,L7OK
servers,pve01-610m,0,0,1,UP,L7OK
servers,winpc-780m,0,0,1,UP,L7OK
servers,BACKEND,0,0,20,UP,
```

라우터를 거쳐 API 를 부르고, 어느 서버가 받았는지 라우터 로그의 `servers/<서버>` 로 확인합니다.

```bash
# 라우터를 거쳐 모델 목록 받기
curl -s http://$IP:11434/api/tags | grep -o '"name":"[^"]*"'

# 요청을 받은 서버
kubectl -n ollama logs deploy/ollama-router -c haproxy | grep servers/
```

```text
10.244.7.0:44870 [...] ollama servers/pve02-780m 0/0/0/2/2 200 2414 - - ---- 1/1/0/0/0 0/0 "GET /api/tags HTTP/1.1"
```

동시에 요청 세 개를 보내면 세 서버가 하나씩 나눠 받습니다.

```bash
# 요청 세 개를 동시에 보내기
for i in 1 2 3; do
  curl -s http://$IP:11434/api/generate -d '{"model":"qwen3.5:9b","prompt":"안녕","stream":false}' -o /dev/null &
done; wait

# 요청을 받은 서버
kubectl -n ollama logs deploy/ollama-router -c haproxy --since=10m | grep api/generate
```

가중치 프로그램은 가중치를 바꿀 때마다 한 줄을 남깁니다. `speeds` 는 서버별로 잰 속도(바이트/초)이고, 아직 재지 못한 서버는 `null` 입니다.

```bash
# 지금 가중치와 잰 속도
kubectl -n ollama logs deploy/ollama-router -c weights --tail=1
```

```text
{"weights": {"pve02-780m": 256, "pve01-610m": 256, "winpc-780m": 256}, "speeds": {"pve02-780m": null, "pve01-610m": null, "winpc-780m": null}}
```

지표는 두 포트에서 확인합니다. 방금 보낸 요청이 모델·서버별 카운터에 잡혀 있어야 합니다.

```bash
# HAProxy 익스포터: 서버 상태
curl -s http://$IP:8404/metrics | grep 'haproxy_server_status{.*state="UP"} 1'

# metrics.py: 모델·서버별 요청 수, 올라간 모델
curl -s http://$IP:9100/metrics | grep -E '^ollama_(requests_total|loaded_model_bytes)'
```

```text
ollama_requests_total{backend="servers",server="pve02-780m",model="qwen3.5:9b",role="-",status="200"} 3
ollama_loaded_model_bytes{server="pve02-780m",model="qwen3.5:9b"} 7012345678
```

Grafana 에서 **Ollama 사용 현황** 대시보드를 엽니다. Prometheus 의 *Targets* 에 `ollama` 의 두 엔드포인트가 UP 이면 라우터 패널에 값이 들어옵니다.

클러스터 안의 클라이언트는 `http://ollama.ollama.svc.cluster.local:11434` 하나로 모든 서버를 씁니다.

- **확인:** 통계의 모든 서버가 `UP`, `L7OK` 이고 `slim` 이 1 입니다. 동시에 보낸 세 요청은 `servers/pve02-780m`, `servers/winpc-780m`, `servers/pve01-610m` 으로 모두 다른 서버에 남습니다. 가중치 로그에 서버 이름이 모두 보입니다.

## 마무리

Ollama 모델 서버를 Proxmox LXC 에 플레이북으로 만들고, 클러스터 안에서는 `ollama` Service 주소 하나로 비어 있는 서버에 요청을 나누고, 어느 서버를 먼저 쓸지는 라우터가 잰 속도로 정하는 구성을 완성했습니다. 동시에 서버 수만큼 요청을 처리하고, 나머지는 줄을 섰다가 먼저 빈 서버로 갑니다. 서버를 더할 때는 `ollama_backends` 와 inventory 에 CT 를 넣어 두 플레이북을 다시 실행하고, `haproxy.cfg` 에 `server` 줄을 넣습니다. 순서나 가중치는 정하지 않아도 됩니다.

## 참고 자료

- [Ollama FAQ](https://docs.ollama.com/faq)
- [Ollama GPU 지원](https://docs.ollama.com/gpu)
- [Ollama API](https://docs.ollama.com/api)
- [HAProxy 3.2 Configuration Manual](https://docs.haproxy.org/3.2/configuration.html)
- [Proxmox VE Administration Guide: Linux Container](https://pve.proxmox.com/pve-docs/chapter-pct.html)
- [community.proxmox.proxmox module – Ansible documentation](https://docs.ansible.com/ansible/latest/collections/community/proxmox/proxmox_module.html)
