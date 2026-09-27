---
layout: post
title: Proxmox에 Ansible로 내부망 DNS 컨테이너 만드는 방법
description: 집 안에서는 Cloudflare 를 거치지 않고 클러스터로 직접 붙도록, Proxmox 노드마다 dnsmasq 컨테이너를 하나씩 Ansible 플레이북으로 만들고 서비스·호스트·역할 이름을 내부 주소로 답하게 하는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, ansible, lxc, dnsmasq, dns, homelab]
permalink: /posts/41/
---

집 밖에서는 Cloudflare 프록시를 거쳐 `https://[서비스].[DOMAIN]` 으로 들어오지만, 같은 공유기 안에서도 그 경로를 타면 100Mbps 외부 회선을 왕복하고 인터넷이 끊기면 아예 접속이 안 됩니다. 내부망 전용 DNS 를 두어 우리가 여는 이름을 내부 주소로 답하게 하면 집 안 기기는 1Gbps 로 클러스터에 직접 붙습니다. 허브 서비스 이름은 허브 쿠버네티스의 VIP 로, 지역 엣지의 서비스 이름은 그 지역의 서비스 VIP 로 답하고, 모든 호스트·노드 이름과 역할 이름(`kubectl-hub` 등)도 답해 스크립트와 문서가 IP 대신 이름을 쓰게 합니다. DNS 는 Proxmox 호스트에 직접 깔지 않고 Proxmox 노드마다 전용 LXC 컨테이너를 하나씩 두어, 서버 한 대가 꺼져도 이름이 풀리게 합니다. 컨테이너 생성부터 dnsmasq 설정까지 Ansible 플레이북 하나로 만들어, 서버를 옮길 때 백업·복원 대신 플레이북을 다시 실행합니다.

1. Proxmox API 토큰 만들기
2. Ansible 설치와 저장소 준비
3. 변수 채우기
4. 플레이북 실행
5. 공유기 DHCP 설정
6. 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Proxmox VE | `9.2` (두 노드) |
| Ansible | `13.1` (ansible-core `2.20`, community.proxmox 포함) |
| CT 템플릿 | `debian-13-standard` |
| 공유기 | `ipTIME T5008SE` |
| 작성 기준일 | `2026-09-28` |

다음 항목이 준비되어 있어야 합니다.

- Proxmox 두 대를 묶은 클러스터 ([Proxmox 두 대를 클러스터로 묶고 원격 NAS에 QDevice 붙이는 방법](/posts/53/)). 그 글은 이 글의 1~2단계(API 토큰, 저장소 골격)를 먼저 요구하므로 1~2단계 → 그 글 → 3단계 순서로 진행합니다.
- Proxmox 호스트의 root SSH 접속과, 플레이북을 실행할 PC(리눅스)의 SSH 키(`~/.ssh/id_ed25519.pub`). 이 키가 컨테이너의 root 에 들어갑니다.
- 내부에서 직접 붙을 대상. 허브 서비스는 VIP 를 가진 control plane 의 443 포트에서 받는 Traefik 입니다([쿠버네티스 서비스를 VPN 없이 외부에서 HTTPS로 접속하는 방법](/posts/40/)). 지역 서비스는 그 지역 엣지의 서비스 VIP 에서 받는 지역 Traefik 입니다.
- 컨테이너에 줄 비어 있는 고정 IP 두 개 (`[LAN_DNS_IP]`, `[LAN_DNS_2_IP]`)

## 1. Proxmox API 토큰 만들기

Ansible 은 Proxmox API 로 컨테이너를 만듭니다. 메인 서버에서 토큰을 발급하고 값을 실행 PC 의 파일에 둡니다. 클러스터는 사용자와 토큰을 모든 노드가 같이 쓰므로 한 번만 만듭니다. 값은 발급 때 한 번만 보입니다.

```bash
# 메인 서버에서 토큰 발급 (privsep 0: root 와 같은 권한)
ssh root@[PROXMOX_IP] 'pveum user token add root@pam ansible --privsep 0'

# 실행 PC 에 값 저장 (저장소에 넣지 않습니다)
mkdir -p ~/.config/proxmox && (umask 077; cat > ~/.config/proxmox/token)   # value 붙여 넣고 Ctrl-D
```

- **확인:** `ssh root@[PROXMOX_IP] 'pveum user token list root@pam'` 에 `ansible` 이 보입니다.

## 2. Ansible 설치와 저장소 준비

플레이북을 둘 저장소를 만들고 Ansible 을 설치합니다. `community.proxmox` 컬렉션은 Ubuntu 의 `ansible` 패키지에 들어 있습니다.

```bash
# 설치
sudo apt install -y ansible python3-proxmoxer

# 저장소 골격
mkdir -p proxmox-ansible/{playbooks,templates,group_vars} && cd proxmox-ansible
```

```ini
[defaults]
inventory = inventory.yml
host_key_checking = False
interpreter_python = auto_silent
callback_result_format = yaml
retry_files_enabled = False
```
{: file="ansible.cfg" }

```yaml
collections:
  - name: community.proxmox
```
{: file="requirements.yml" }

인벤토리의 `proxmox` 그룹이 Proxmox 노드이고, `lan_dns` 그룹이 이 글에서 만드는 DNS 컨테이너입니다. 컨테이너 이름은 3단계의 `lan_dns_instances` 와 같아야 합니다.

```yaml
all:
  children:
    proxmox:                      # Proxmox 호스트(클러스터 노드). 호스트 이름이 곧 노드 이름입니다
      hosts:
        pve01:
          ansible_host: [PVE01_IP]
          ansible_user: root
        pve02:
          ansible_host: [PVE02_IP]
          ansible_user: root
          vm_template_vmid: 9001  # VMID 는 클러스터 전체에서 하나라 노드마다 템플릿 번호가 다릅니다
      children:
        proxmox_primary:          # 메인 서버. 클러스터를 만들고, 기존 CT·VM 이 있는 노드
          hosts:
            pve01:
    lan_dns:                      # playbooks/lan-dns.yml 이 만드는 CT (Proxmox 노드마다 하나, group_vars 의 lan_dns_instances)
      hosts:
        lan-dns:
          ansible_host: [LAN_DNS_IP]
          ansible_user: root
        lan-dns-2:
          ansible_host: [LAN_DNS_2_IP]
          ansible_user: root
```
{: file="inventory.yml" }

- **확인:** `ansible-inventory --graph` 에 `@proxmox` 아래 `pve01`, `pve02`(와 `@proxmox_primary`), `@lan_dns` 아래 `lan-dns`, `lan-dns-2` 가 보입니다.

## 3. 변수 채우기

값은 이 파일에서만 바꿉니다. 플레이북과 템플릿은 변수만 참조합니다. `k8s_clusters` 는 쿠버네티스 클러스터 정의이고 [Proxmox에 Ansible로 kubeadm 쿠버네티스 클러스터 만드는 방법](/posts/46/)의 1단계에서 채웁니다. 클러스터를 만들기 전에는 허브 VIP 만 둡니다.

{% raw %}
```yaml
proxmox_api_host: [PROXMOX_IP]
proxmox_node: "{{ groups.proxmox_primary[0] }}"   # CT·VM 을 만드는 노드(pvesh get /nodes 의 이름). inventory 의 proxmox_primary
ct_template_storage: local                    # CT 템플릿을 두는 스토리지
ct_disk_storage: local-lvm                    # CT 디스크를 두는 스토리지
ct_bridge: vmbr0
ct_gateway: [GATEWAY_IP]
ct_ssh_pubkey: "[SSH_PUBLIC_KEY]"             # ~/.ssh/id_ed25519.pub 의 내용
timezone: Asia/Seoul                          # 모든 호스트·CT·VM 의 시간대

# ---- lan-dns: 내부망 DNS ----
# 같은 설정의 DNS CT 를 Proxmox 노드마다 하나씩 둡니다. 공유기 DHCP 의 DNS 는 1차 lan-dns, 2차 lan-dns-2 (이름은 inventory 의 lan_dns 그룹과 같아야 함)
lan_dns_instances:
  - { name: lan-dns,   vmid: 202, ip: [LAN_DNS_IP],   pve: pve01 }
  - { name: lan-dns-2, vmid: 203, ip: [LAN_DNS_2_IP], pve: pve02 }
lan_dns_template: debian-13-standard_13.6-1_amd64.tar.zst   # pveam available --section system
lan_dns_domain: [DOMAIN]
lan_dns_names: [argocd, grafana, headlamp, proxmox, auth, ha, z2m]   # 허브 서비스 이름(lan_dns_targets 로 답함). 지역 서비스 이름은 k8s_clusters.<지역>.lan_dns_names
lan_dns_targets: ["{{ k8s_clusters.hub.vip }}"]            # 허브 control plane VIP. VIP 를 가진 control plane 의 Traefik(hostPort 443)이 받습니다
lan_dns_upstream: [1.1.1.1, 1.0.0.1]                        # 그 외 이름을 넘길 DNS
lan_dns_client_pct_vmids: [201]               # inventory 밖에서 내부망 DNS(호스트·역할 이름)를 쓸 CT(메인 서버에 있는 CT). 없으면 []

# ---- k8s-cluster: 쿠버네티스 클러스터 ----
# 노드·VIP 는 kubeadm 클러스터 글의 1단계에서 채웁니다. 그 전에는 허브 VIP 만 둡니다
k8s_clusters:
  hub: { vip: [HUB_VIP], nodes: [] }
```
{: file="group_vars/all.yml" }
{% endraw %}

dnsmasq 설정 템플릿이 답하는 이름은 다음과 같습니다. 그 밖의 이름은 `lan_dns_upstream` 으로 넘깁니다.

| 이름(`.[DOMAIN]`) | 답하는 주소 |
| :--- | :--- |
| `lan_dns_names` 의 허브 서비스(`argocd` 등) | 허브 VIP(`lan_dns_targets`) |
| `k8s_clusters.<지역>.lan_dns_names` 의 지역 서비스(`ha-dj` 등) | 그 지역의 서비스 VIP(`service_vip`) |
| inventory 의 모든 호스트와 `k8s_clusters` 의 노드(`pve01`, `lan-dns-2`, `k8s-hub-cp-1` 등) | 그 호스트의 주소 |
| `k8s-<dns_name>`(`k8s-hub` 등) | 그 클러스터의 API VIP |
| `kubectl-<dns_name>`(`kubectl-hub` 등) | 그 클러스터의 첫 control plane(`retire` 가 붙은 노드 제외) |
| `iot-<dns_name>`(`iot-dj` 등) | 그 클러스터의 LoadBalancer 서비스 VIP |

이름마다 `local=` 로 dnsmasq 가 직접 답하게 하고 `address=` 로 주소를 줍니다. `local=` 이 없으면 AAAA 처럼 `address=` 에 없는 질의를 상위로 넘겨 Cloudflare 의 IPv6 주소가 새어 나갑니다. `listen-address` 는 각 컨테이너의 주소라, 두 컨테이너가 같은 템플릿으로 같은 답을 줍니다.

{% raw %}
```text
# proxmox-ansible 의 playbooks/lan-dns.yml 이 만듭니다. 직접 고치지 마세요.
listen-address={{ ansible_host }}
bind-interfaces
no-resolv
no-hosts
cache-size=1000
{% for up in lan_dns_upstream %}
server={{ up }}
{% endfor %}
{# 와일드카드(address=/도메인/)는 쓰지 않습니다. 기존 공개 이름과 파드의 검색 도메인 조회가 깨집니다. #}
{% for name in lan_dns_names %}
local=/{{ name }}.{{ lan_dns_domain }}/
{% for ip in lan_dns_targets %}
address=/{{ name }}.{{ lan_dns_domain }}/{{ ip }}
{% endfor %}
{% endfor %}
{# 지역 서비스 이름: 그 지역의 서비스 VIP(지역 Traefik). 허브가 없어도 내부망에서 이름으로 붙습니다 #}
{% for c in k8s_clusters.values() if c.lan_dns_names is defined %}
{% for name in c.lan_dns_names %}
local=/{{ name }}.{{ lan_dns_domain }}/
address=/{{ name }}.{{ lan_dns_domain }}/{{ c.service_vip }}
{% endfor %}
{% endfor %}
{# 호스트 이름(<이름>.<도메인>): inventory 의 모든 호스트(Proxmox 노드, DNS CT, 시험 VM …)와 k8s_clusters 의 노드.
   노드를 바꾸면 k8s-cluster.yml 끝에서 이 설정을 다시 만들므로, 스크립트·문서는 IP 대신 이 이름을 씁니다. #}
{% set hosts = {} %}
{% for h in groups['all'] if hostvars[h].ansible_host is defined %}
{% set _ = hosts.update({h: hostvars[h].ansible_host}) %}
{% endfor %}
{% for c in k8s_clusters.values() %}
{% for n in c.nodes %}
{% set _ = hosts.update({n.name: n.ip}) %}
{% endfor %}
{% endfor %}
{# 역할 이름: k8s-<클러스터>(API VIP), kubectl-<클러스터>(kubectl 을 돌리는 첫 control plane), iot-<클러스터>(LoadBalancer 서비스 VIP) #}
{% for c in k8s_clusters.values() if c.dns_name is defined %}
{% set _ = hosts.update({'k8s-' ~ c.dns_name: c.vip}) %}
{% set _ = hosts.update({'kubectl-' ~ c.dns_name: (c.nodes | selectattr('role', 'eq', 'control-plane') | rejectattr('retire', 'defined') | first).ip}) %}
{% if c.service_vip is defined %}
{% set _ = hosts.update({'iot-' ~ c.dns_name: c.service_vip}) %}
{% endif %}
{% endfor %}
{% for name, ip in hosts | dictsort %}
local=/{{ name }}.{{ lan_dns_domain }}/
address=/{{ name }}.{{ lan_dns_domain }}/{{ ip }}
{% endfor %}
```
{: file="templates/dnsmasq-lan.conf.j2" }
{% endraw %}

> 와일드카드(`address=/[DOMAIN]/`)는 쓰지 않습니다. 같은 도메인의 다른 공개 이름(NAS 등)이 전부 노드로 가고, 공유기가 그 도메인을 DHCP 검색 도메인으로 주는 환경에서는 `github.com.[DOMAIN]` 같은 조회까지 노드로 풀려 클러스터 안의 외부 접속이 깨집니다.
{: .prompt-danger }

플레이북은 다섯 플레이입니다. 모든 노드에 CT 템플릿 내려받기, 노드마다 CT 만들고 켜기, CT 안에 dnsmasq 설정, 호스트에 남은 옛 dnsmasq 제거와 DNS CT 마다 조회 검사, inventory 밖의 CT(`lan_dns_client_pct_vmids`)가 두 DNS 를 쓰도록 `pct set --nameserver` 로 지정하기입니다. 여러 번 실행해도 결과가 같습니다.

```bash
# 플레이북과 템플릿 내려받기
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/lan-dns.yml -o playbooks/lan-dns.yml
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/dnsmasq-lan.conf.j2 -o templates/dnsmasq-lan.conf.j2
```

<details markdown="1">
<summary>playbooks/lan-dns.yml 전문</summary>

{% raw %}
```yaml
# 내부망 DNS 컨테이너. 밖에 여는 서비스 이름만 클러스터 노드 IP 로 답해, 집 안에서는 Cloudflare 를 거치지 않고 노드로 직접 붙게 합니다.
#   ansible-playbook playbooks/lan-dns.yml   (PROXMOX_* 환경변수 필요, README 참고)
---
- name: CT 템플릿 준비
  hosts: proxmox
  gather_facts: false
  tasks:
    - name: 템플릿 내려받기 (없을 때만)
      ansible.builtin.command: pveam download {{ ct_template_storage }} {{ lan_dns_template }}
      args:
        creates: /var/lib/vz/template/cache/{{ lan_dns_template }}

- name: lan-dns CT 만들기
  hosts: localhost
  gather_facts: false
  tasks:
    - name: CT 정의 (있으면 설정만 맞춤)
      community.proxmox.proxmox:
        node: "{{ item.pve }}"
        vmid: "{{ item.vmid }}"
        hostname: "{{ item.name }}"
        ostemplate: "{{ ct_template_storage }}:vztmpl/{{ lan_dns_template }}"
        cores: 1
        memory: 256
        swap: 0
        disk: "{{ ct_disk_storage }}:2"
        netif: { net0: "name=eth0,bridge={{ ct_bridge }},ip={{ item.ip }}/24,gw={{ ct_gateway }}" }
        nameserver: "{{ lan_dns_upstream[0] }}"
        onboot: true
        unprivileged: true
        pubkey: "{{ ct_ssh_pubkey }}"
        state: present
      loop: "{{ lan_dns_instances }}"
      loop_control: { label: "{{ item.name }}" }
    - name: CT 시작
      community.proxmox.proxmox:
        node: "{{ item.pve }}"
        vmid: "{{ item.vmid }}"
        hostname: "{{ item.name }}"
        state: started
      loop: "{{ lan_dns_instances }}"
      loop_control: { label: "{{ item.name }}" }
    - name: SSH 열릴 때까지 대기
      ansible.builtin.wait_for:
        host: "{{ item.ip }}"
        port: 22
        timeout: 120
      loop: "{{ lan_dns_instances }}"
      loop_control: { label: "{{ item.name }}" }

- name: CT 안에 dnsmasq 설정
  hosts: lan_dns
  gather_facts: false
  pre_tasks:
    - name: python3 준비 (Ansible 모듈 실행에 필요)
      ansible.builtin.raw: command -v python3 >/dev/null || (apt-get update -q && apt-get install -y -q python3)
      changed_when: false
  tasks:
    - name: 시간대
      community.general.timezone:
        name: "{{ timezone }}"
    - name: dnsmasq 설치
      ansible.builtin.apt:
        name: dnsmasq
        update_cache: true
        cache_valid_time: 3600
    - name: 설정 파일
      ansible.builtin.template:
        src: ../templates/dnsmasq-lan.conf.j2
        dest: /etc/dnsmasq.d/lan.conf
        mode: "0644"
        validate: dnsmasq --test --conf-file=%s
      notify: dnsmasq 재시작
    - name: dnsmasq 켜기
      ansible.builtin.service:
        name: dnsmasq
        enabled: true
        state: started
  handlers:
    - name: dnsmasq 재시작
      ansible.builtin.service:
        name: dnsmasq
        state: restarted

- name: 호스트 정리와 확인
  hosts: proxmox_primary
  gather_facts: false
  vars:
    first_name: "{{ lan_dns_names[0] }}.{{ lan_dns_domain }}"
  tasks:
    - name: 호스트에 직접 깔았던 옛 dnsmasq 제거
      ansible.builtin.apt:
        name: dnsmasq
        state: absent
        purge: true
    - name: 옛 설정 파일 제거
      ansible.builtin.file:
        path: /etc/dnsmasq.d/lan.conf
        state: absent
    - name: dig 준비
      ansible.builtin.apt:
        name: dnsutils
    - name: 조회 검사 (DNS CT 마다)
      ansible.builtin.shell: |
        echo "A     {{ first_name }} -> $(dig +short +time=2 @{{ item.ip }} {{ first_name }} A | tr '\n' ' ')"
        echo "AAAA  {{ first_name }} -> $(dig +short +time=2 @{{ item.ip }} {{ first_name }} AAAA | tr '\n' ' ')(비어 있어야 함)"
        echo "공개  www.{{ lan_dns_domain }} -> $(dig +short +time=2 @{{ item.ip }} www.{{ lan_dns_domain }} A | tr '\n' ' ')"
        echo "외부  github.com -> $(dig +short +time=2 @{{ item.ip }} github.com A | tr '\n' ' ')"
      register: lookup
      changed_when: false
      loop: "{{ lan_dns_instances }}"
      loop_control: { label: "{{ item.name }}" }
    - name: 결과
      ansible.builtin.debug:
        msg: "{{ item.item.name }}: {{ item.stdout_lines }}"
      loop: "{{ lookup.results }}"
      loop_control: { label: "{{ item.item.name }}" }
    - name: 노드 IP 로 답하는지
      ansible.builtin.assert:
        that: lan_dns_targets[0] in item.stdout_lines[0]
        fail_msg: "{{ item.item.name }}: {{ first_name }} 이 노드 IP 로 풀리지 않습니다"
      loop: "{{ lookup.results }}"
      loop_control: { label: "{{ item.item.name }}" }

- name: 내부망 DNS 를 쓰는 CT (inventory 밖, 호스트에서 pct 로 설정)
  hosts: proxmox_primary
  gather_facts: false
  tasks:
    # CT 의 resolv.conf 는 Proxmox 가 시작할 때 CT 설정으로 씁니다. 지금 도는 CT 에도 바로 적용되게 파일도 같은 내용으로 바꿉니다.
    # 두 DNS CT 가 모두 죽어도 바깥 이름은 풀리게 마지막에 upstream 하나를 둡니다
    - name: DNS 서버 지정
      ansible.builtin.shell: |
        want="{{ (lan_dns_instances | map(attribute='ip') | list + lan_dns_upstream[:1]) | join(' ') }}"
        [ "$(pct config {{ item }} | sed -n 's/^nameserver: //p')" = "$want" ] && exit 0
        pct set {{ item }} --nameserver "$want" --searchdomain {{ lan_dns_domain }}
        pct exec {{ item }} -- sh -c 'f=/etc/resolv.conf; { echo "search {{ lan_dns_domain }}"; for n in $0; do echo "nameserver $n"; done; } > $f.new && mv $f.new $f' "$want"
        echo CHANGED
      register: pct_dns
      changed_when: "'CHANGED' in pct_dns.stdout"
      loop: "{{ lan_dns_client_pct_vmids }}"
```
{: file="playbooks/lan-dns.yml" }
{% endraw %}

</details>

- **확인:** `ansible-playbook playbooks/lan-dns.yml --syntax-check` 가 오류 없이 끝납니다.

## 4. 플레이북 실행

토큰은 환경변수로 넘깁니다. `community.proxmox` 모듈은 `PROXMOX_HOST`, `PROXMOX_USER`, `PROXMOX_TOKEN_ID`, `PROXMOX_TOKEN_SECRET`, `PROXMOX_VALIDATE_CERTS` 를 읽습니다.

```bash
# 실행 (템플릿 내려받기 포함 2~3분)
export PROXMOX_HOST=[PROXMOX_IP] PROXMOX_USER=root@pam PROXMOX_TOKEN_ID=ansible \
       PROXMOX_TOKEN_SECRET=$(cat ~/.config/proxmox/token) PROXMOX_VALIDATE_CERTS=false
ansible-playbook playbooks/lan-dns.yml
```

[kubeadm 클러스터 플레이북](/posts/46/)은 끝에서 이 플레이북을 다시 실행합니다. 노드를 더하거나 바꾸면 노드 이름과 `kubectl-<클러스터>` 같은 역할 이름이 새 주소로 바뀝니다.

- **확인:** 마지막 `PLAY RECAP` 에 `failed=0`, 그 위 `결과` 태스크에 DNS CT 마다 네 줄이 보입니다. A 는 허브 VIP, AAAA 는 비어 있고, 공개 이름은 Cloudflare 주소, `github.com` 은 외부 주소입니다.

## 5. 공유기 DHCP 설정

기기들이 이 DNS 를 쓰도록 공유기 DHCP 가 나눠 주는 DNS 주소를 바꿉니다. ipTIME 은 **고급 설정** > **네트워크 관리** > **내부 네트워크 설정** 의 DHCP 서버 항목에 있습니다.

- **기본 DNS**: `[LAN_DNS_IP]`
- **보조 DNS**: `[LAN_DNS_2_IP]`

> 두 DNS 가 서로 다른 Proxmox 노드에 있어 한 대가 꺼져도 내부 이름이 그대로 풀립니다. 두 서버가 모두 꺼지면 집 DNS 도 멈춥니다.
{: .prompt-warning }

- **확인:** 기기의 Wi-Fi 를 껐다 켠 뒤(DHCP 갱신) 네트워크 설정에서 DNS 서버가 `[LAN_DNS_IP]`, `[LAN_DNS_2_IP]` 로 보입니다.

## 6. 확인

```bash
# 컨테이너 상태 (각 Proxmox 노드에서)
ssh root@[PVE01_IP] "pct status 202 && pct config 202 | grep -E '^(onboot|unprivileged|net0)'"
ssh root@[PVE02_IP] "pct status 203 && pct config 203 | grep -E '^(onboot|unprivileged|net0)'"

# 조회 (아무 PC 에서, 두 DNS 모두)
for dns in [LAN_DNS_IP] [LAN_DNS_2_IP]; do
  dig +short @$dns argocd.[DOMAIN]          # 허브 VIP
  dig +short @$dns argocd.[DOMAIN] AAAA     # 비어 있음
  dig +short @$dns pve02.[DOMAIN]           # pve02 주소
  dig +short @$dns github.com               # 외부 주소
done
```

- **확인:** 두 DNS 가 같은 답을 줍니다. 쿠버네티스 클러스터를 만든 뒤에는 `kubectl-hub.[DOMAIN]` 이 허브의 첫 control plane, `k8s-hub.[DOMAIN]` 이 허브 VIP, `ha-dj.[DOMAIN]` 이 지역 서비스 VIP 로 풀립니다. DHCP 를 새로 받은 기기에서 `https://argocd.[DOMAIN]` 을 열면 Cloudflare 를 거치지 않고 열리고, Traefik 액세스 로그(`kubectl -n traefik logs ds/traefik`)의 첫 열이 그 기기의 내부 IP 입니다. `lan_dns_client_pct_vmids` 의 CT 안에서는 `/etc/resolv.conf` 에 두 DNS 가 보입니다.

## 트러블슈팅

<details markdown="1">
<summary><code>The 'community.general.yaml' callback plugin has been removed</code></summary>

```text
[ERROR]: The 'community.general.yaml' callback plugin has been removed. The plugin has been superseded by the option `result_format=yaml` in callback plugin ansible.builtin.default from ansible-core 2.13 onwards.
```

- **원인:** `ansible.cfg` 에 예전 방식인 `stdout_callback = yaml` 을 적었습니다. community.general 12 에서 이 플러그인이 사라졌습니다.
- **해결:** `callback_result_format = yaml` 로 바꿨습니다. 기본 콜백이 결과만 YAML 로 보여 줍니다.

</details>

<details markdown="1">
<summary><code>An error occurred: 'name'</code> — CT 를 시작하는 태스크에서</summary>

```text
TASK [CT 시작]
fatal: [localhost]: FAILED! => msg: 'An error occurred: ''name'''
```

- **원인:** `community.proxmox.proxmox` 모듈에 `vmid` 와 `state: started` 만 주면 모듈 안에서 이름을 찾다가 실패합니다. 확인하지 못한 추정이지만 `hostname` 을 함께 주면 재현되지 않았습니다.
- **해결:** 시작 태스크에도 `hostname` 을 넣었습니다.

</details>

<details markdown="1">
<summary><code>failed to validate</code> — dnsmasq 설정 파일 템플릿 태스크에서</summary>

- **원인:** `template` 의 `validate` 에 `--conf-dir=/dev/null` 같은 옵션을 섞어 검증 명령 자체가 잘못됐습니다.
- **해결:** `validate: dnsmasq --test --conf-file=%s` 로 단순하게 바꿨습니다.

</details>

<details markdown="1">
<summary>내부 이름의 AAAA 조회에 Cloudflare 의 IPv6 주소가 나옴</summary>

- **원인:** dnsmasq 의 `address=` 는 A 만 답하고, 그 이름의 다른 타입 질의는 상위 DNS 로 넘깁니다. 공개 레코드에 AAAA 가 있으면 IPv6 를 쓰는 기기가 그쪽으로 갑니다.
- **해결:** 이름마다 `local=/이름/` 을 추가해 dnsmasq 가 그 이름을 전담하게 했습니다. `address=` 에 없는 타입은 빈 응답이 됩니다.

</details>

## 마무리

내부망 DNS 가 Proxmox 노드마다 하나씩 작은 컨테이너에서 돌고, 두 컨테이너는 플레이북 한 번으로 다시 만들 수 있습니다. 허브 서비스 이름은 허브 VIP 로, 지역 서비스 이름은 그 지역의 서비스 VIP 로, 호스트·노드·역할 이름은 각 주소로 답합니다. 서비스를 하나 더 열 때는 `lan_dns_names`(지역 서비스는 `k8s_clusters.<지역>.lan_dns_names`)에 이름을 넣고 플레이북을 다시 실행합니다.

## 참고 자료

- [community.proxmox.proxmox module – Ansible documentation](https://docs.ansible.com/ansible/latest/collections/community/proxmox/proxmox_module.html)
- [Proxmox VE Administration Guide: Linux Container](https://pve.proxmox.com/pve-docs/chapter-pct.html)
- [Proxmox VE: User Management (API Tokens)](https://pve.proxmox.com/wiki/User_Management#pveum_tokens)
- [dnsmasq man page](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)
