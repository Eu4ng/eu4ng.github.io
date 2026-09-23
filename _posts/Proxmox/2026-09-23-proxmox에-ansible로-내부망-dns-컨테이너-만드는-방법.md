---
layout: post
title: Proxmox에 Ansible로 내부망 DNS 컨테이너 만드는 방법
description: 집 안에서는 Cloudflare 를 거치지 않고 클러스터로 직접 붙도록, Proxmox 위에 dnsmasq 컨테이너를 Ansible 플레이북 하나로 만들고 새 서버에서도 같은 상태를 재현하는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, ansible, lxc, dnsmasq, dns, homelab]
permalink: /posts/41/
---

집 밖에서는 Cloudflare 프록시를 거쳐 `https://[서비스].[DOMAIN]` 으로 들어오지만, 같은 공유기 안에서도 그 경로를 타면 100Mbps 외부 회선을 왕복하고 인터넷이 끊기면 아예 접속이 안 됩니다. 내부망 전용 DNS 를 두어 우리가 여는 이름만 클러스터 노드 IP 로 답하게 하면 집 안 기기는 1Gbps 로 노드에 직접 붙습니다. 이 DNS 를 Proxmox 호스트에 직접 깔지 않고 전용 LXC 컨테이너에 두고, 컨테이너 생성부터 dnsmasq 설정까지 Ansible 플레이북 하나로 만듭니다. 서버를 옮길 때 백업·복원 대신 플레이북을 다시 실행해 같은 상태를 만들기 위해서입니다.

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
| Proxmox VE | `9.2` |
| Ansible | `13.1` (ansible-core `2.20`, community.proxmox 포함) |
| CT 템플릿 | `debian-13-standard` |
| 공유기 | `ipTIME T5008SE` |
| 작성 기준일 | `2026-09-23` |

다음 항목이 준비되어 있어야 합니다.

- Proxmox 호스트의 root SSH 접속과, 플레이북을 실행할 PC(리눅스)의 SSH 키(`~/.ssh/id_ed25519.pub`). 이 키가 컨테이너의 root 에 들어갑니다.
- 내부에서 직접 붙을 대상. 이 글에서는 노드의 443 포트에서 받는 Traefik 입니다 ([쿠버네티스 서비스를 VPN 없이 외부에서 HTTPS로 접속하는 방법](/posts/40/) 참고).
- 컨테이너에 줄 비어 있는 고정 IP 하나 (`[LAN_DNS_IP]`, 예를 들어 공유기 대역의 53번)

## 1. Proxmox API 토큰 만들기

Ansible 은 Proxmox API 로 컨테이너를 만듭니다. 호스트에서 토큰을 발급하고 값을 실행 PC 의 파일에 둡니다. 값은 발급 때 한 번만 보입니다.

```bash
# 호스트에서 토큰 발급 (privsep 0: root 와 같은 권한)
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

```yaml
all:
  children:
    proxmox:                      # Proxmox 호스트
      hosts:
        server:
          ansible_host: [PROXMOX_IP]
          ansible_user: root
    lan_dns:                      # playbooks/lan-dns.yml 이 만드는 CT
      hosts:
        lan-dns:
          ansible_host: [LAN_DNS_IP]
          ansible_user: root
```
{: file="inventory.yml" }

- **확인:** `ansible-inventory --graph` 에 `@proxmox` 아래 `server`, `@lan_dns` 아래 `lan-dns` 가 보입니다.

## 3. 변수 채우기

값은 이 파일에서만 바꿉니다. 플레이북과 템플릿은 변수만 참조합니다.

```yaml
proxmox_api_host: [PROXMOX_IP]
proxmox_node: server                          # pvesh get /nodes 의 노드 이름
ct_template_storage: local                    # CT 템플릿을 두는 스토리지
ct_disk_storage: local-lvm                    # CT 디스크를 두는 스토리지
ct_bridge: vmbr0
ct_gateway: [GATEWAY_IP]
ct_ssh_pubkey: "[SSH_PUBLIC_KEY]"             # ~/.ssh/id_ed25519.pub 의 내용

# ---- lan-dns: 내부망 DNS ----
lan_dns_vmid: 202
lan_dns_hostname: lan-dns
lan_dns_ip: [LAN_DNS_IP]
lan_dns_template: debian-13-standard_13.6-1_amd64.tar.zst   # pveam available --section system
lan_dns_domain: [DOMAIN]
lan_dns_names: [argocd, grafana, headlamp, proxmox, auth]   # 밖에 여는 서비스 이름
lan_dns_targets: [[NODE_IP_1], [NODE_IP_2]]                 # Traefik 이 443 으로 떠 있는 노드
lan_dns_upstream: [1.1.1.1, 1.0.0.1]                        # 그 외 이름을 넘길 DNS
```
{: file="group_vars/all.yml" }

dnsmasq 설정 템플릿입니다. 이름마다 `local=` 로 dnsmasq 가 직접 답하게 하고 `address=` 로 노드 IP 를 줍니다. `local=` 이 없으면 AAAA 처럼 `address=` 에 없는 질의를 상위로 넘겨 Cloudflare 의 IPv6 주소가 새어 나갑니다.

{% raw %}
```text
# proxmox-ansible 의 playbooks/lan-dns.yml 이 만듭니다. 직접 고치지 마세요.
listen-address={{ lan_dns_ip }}
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
```
{: file="templates/dnsmasq-lan.conf.j2" }
{% endraw %}

> 와일드카드(`address=/[DOMAIN]/`)는 쓰지 않습니다. 같은 도메인의 다른 공개 이름(NAS 등)이 전부 노드로 가고, 공유기가 그 도메인을 DHCP 검색 도메인으로 주는 환경에서는 `github.com.[DOMAIN]` 같은 조회까지 노드로 풀려 클러스터 안의 외부 접속이 깨집니다.
{: .prompt-danger }

플레이북은 네 플레이입니다. 템플릿 내려받기, CT 만들고 켜기, CT 안에 dnsmasq 설정, 호스트에 남은 옛 dnsmasq 제거와 조회 검사입니다. 여러 번 실행해도 결과가 같습니다.

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
        node: "{{ proxmox_node }}"
        vmid: "{{ lan_dns_vmid }}"
        hostname: "{{ lan_dns_hostname }}"
        ostemplate: "{{ ct_template_storage }}:vztmpl/{{ lan_dns_template }}"
        cores: 1
        memory: 256
        swap: 0
        disk: "{{ ct_disk_storage }}:2"
        netif: { net0: "name=eth0,bridge={{ ct_bridge }},ip={{ lan_dns_ip }}/24,gw={{ ct_gateway }}" }
        nameserver: "{{ lan_dns_upstream[0] }}"
        onboot: true
        unprivileged: true
        pubkey: "{{ ct_ssh_pubkey }}"
        state: present
    - name: CT 시작
      community.proxmox.proxmox:
        node: "{{ proxmox_node }}"
        vmid: "{{ lan_dns_vmid }}"
        hostname: "{{ lan_dns_hostname }}"
        state: started
    - name: SSH 열릴 때까지 대기
      ansible.builtin.wait_for:
        host: "{{ lan_dns_ip }}"
        port: 22
        timeout: 120

- name: CT 안에 dnsmasq 설정
  hosts: lan_dns
  gather_facts: false
  pre_tasks:
    - name: python3 준비 (Ansible 모듈 실행에 필요)
      ansible.builtin.raw: command -v python3 >/dev/null || (apt-get update -q && apt-get install -y -q python3)
      changed_when: false
  tasks:
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
  hosts: proxmox
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
    - name: 조회 검사
      ansible.builtin.shell: |
        echo "A     {{ first_name }} -> $(dig +short +time=2 @{{ lan_dns_ip }} {{ first_name }} A | tr '\n' ' ')"
        echo "AAAA  {{ first_name }} -> $(dig +short +time=2 @{{ lan_dns_ip }} {{ first_name }} AAAA | tr '\n' ' ')(비어 있어야 함)"
        echo "공개  www.{{ lan_dns_domain }} -> $(dig +short +time=2 @{{ lan_dns_ip }} www.{{ lan_dns_domain }} A | tr '\n' ' ')"
        echo "외부  github.com -> $(dig +short +time=2 @{{ lan_dns_ip }} github.com A | tr '\n' ' ')"
      register: lookup
      changed_when: false
    - name: 결과
      ansible.builtin.debug:
        msg: "{{ lookup.stdout_lines }}"
    - name: 노드 IP 로 답하는지
      ansible.builtin.assert:
        that: lan_dns_targets[0] in lookup.stdout_lines[0]
        fail_msg: "{{ first_name }} 이 노드 IP 로 풀리지 않습니다"
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

- **확인:** 마지막 `PLAY RECAP` 에 `failed=0`, 그 위 `결과` 태스크에 네 줄이 보입니다. A 는 노드 IP 두 개, AAAA 는 비어 있고, 공개 이름은 Cloudflare 주소, `github.com` 은 외부 주소입니다. 한 번 더 실행하면 모든 호스트가 `changed=0` 입니다.

## 5. 공유기 DHCP 설정

기기들이 이 DNS 를 쓰도록 공유기 DHCP 가 나눠 주는 DNS 주소를 바꿉니다. ipTIME 은 **고급 설정** > **네트워크 관리** > **내부 네트워크 설정** 의 DHCP 서버 항목에 있습니다.

- **기본 DNS**: `[LAN_DNS_IP]`
- **보조 DNS**: `1.1.1.1`

> 보조 DNS 를 외부로 두면 Proxmox 까지 꺼져도 집 인터넷은 유지됩니다. 대신 일부 기기는 가끔 보조 DNS 에 먼저 물어 내부 이름이 Cloudflare 경로로 풀릴 때가 있습니다. 접속은 되고 속도만 달라집니다. 이 흔들림이 싫으면 보조도 우리 DNS(두 번째 컨테이너)로 두되, 그때는 서버가 모두 죽으면 집 DNS 도 멈춥니다.
{: .prompt-warning }

- **확인:** 기기의 Wi-Fi 를 껐다 켠 뒤(DHCP 갱신) 네트워크 설정에서 DNS 서버가 `[LAN_DNS_IP]` 로 보입니다.

## 6. 확인

```bash
# 컨테이너 상태 (호스트에서)
pct status 202 && pct config 202 | grep -E '^(onboot|unprivileged|net0)'

# 조회 (아무 PC 에서)
dig +short @[LAN_DNS_IP] argocd.[DOMAIN]          # 노드 IP 두 개
dig +short @[LAN_DNS_IP] argocd.[DOMAIN] AAAA     # 비어 있음
dig +short @[LAN_DNS_IP] github.com               # 외부 주소
```

- **확인:** DHCP 를 새로 받은 기기에서 `https://argocd.[DOMAIN]` 을 열면 Cloudflare 를 거치지 않고 열립니다. Traefik 액세스 로그(`kubectl -n traefik logs ds/traefik`)의 첫 열이 그 기기의 내부 IP 입니다.

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

내부망 DNS 가 Proxmox 위의 작은 컨테이너에서 돌고, 그 컨테이너는 플레이북 한 번으로 다시 만들 수 있습니다. 서비스를 하나 더 열 때는 `lan_dns_names` 에 이름을 넣고 플레이북을 다시 실행하면 됩니다. 같은 저장소에 VM 배포까지 옮기면 Proxmox 를 설치한 새 서버에서 전체를 재현하는 흐름이 완성됩니다.

## 참고 자료

- [community.proxmox.proxmox module – Ansible documentation](https://docs.ansible.com/ansible/latest/collections/community/proxmox/proxmox_module.html)
- [Proxmox VE Administration Guide: Linux Container](https://pve.proxmox.com/pve-docs/chapter-pct.html)
- [Proxmox VE: User Management (API Tokens)](https://pve.proxmox.com/wiki/User_Management#pveum_tokens)
- [dnsmasq man page](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)
