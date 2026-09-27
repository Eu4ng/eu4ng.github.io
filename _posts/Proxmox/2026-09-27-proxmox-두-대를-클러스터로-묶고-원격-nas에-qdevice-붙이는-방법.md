---
layout: post
title: Proxmox 두 대를 클러스터로 묶고 원격 NAS에 QDevice 붙이는 방법
description: Proxmox 서버 두 대를 클러스터로 묶고, 한 대가 꺼져도 과반이 유지되도록 원격지 Synology NAS 의 컨테이너에 세 번째 표(QDevice)를 Tailscale 로 붙이는 과정을 Ansible 플레이북 하나로 정리했습니다.
author: Eu4ng
tags: [proxmox, ansible, corosync, qdevice, tailscale, synology, homelab]
permalink: /posts/53/
---

Proxmox 서버를 한 대 더 들여 클러스터로 묶습니다. 노드가 두 대뿐이면 한 대가 꺼졌을 때 남은 노드가 [과반](/posts/64/)(2표 중 2표)을 잃어 VM 을 시작하거나 설정을 바꿀 수 없고, 정전 뒤 한 대만 켜지면 자동 시작 게스트도 뜨지 않습니다. 그래서 집 밖의 NAS 에 corosync-qnetd 컨테이너를 두고 두 노드가 Tailscale 로 붙어 세 번째 표를 받게 합니다. 두 노드는 집 LAN 을 tailnet 에 광고하는 서브넷 라우터도 맡아, 원격 NAS 와 LAN 의 VM 이 서로 닿게 합니다. 호스트 이름 정리, 클러스터 생성·합류, Tailscale 과 서브넷 라우팅, QDevice 연결까지 플레이북 하나로 진행하고, 여러 번 실행해도 결과가 같습니다. 공식 문서는 QDevice 서버를 일반 Debian 호스트에 패키지로 설치하지만, 이 글은 NAS 의 Docker(Portainer Swarm) 컨테이너에서 돌립니다.

1. Tailscale 준비
2. qnetd 이미지 만들기
3. NAS 에 qnetd 띄우기
4. 인벤토리와 변수 채우기
5. 플레이북 실행
6. 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Proxmox VE | `9.2` (두 노드 모두) |
| Ansible | `13.1` (ansible-core `2.20`, ansible.posix 포함) |
| corosync-qnetd | `3.0.3` (Debian trixie 패키지) |
| NAS | Synology `DSM 7.2`, Container Manager + Portainer(Swarm), Tailscale 패키지 |
| 작성 기준일 | `2026-09-28` |

다음 항목이 준비되어 있어야 합니다.

- `proxmox-ansible` 저장소 골격(`ansible.cfg`, `inventory.yml`, `group_vars/all.yml`)과 API 토큰 ([Proxmox에 Ansible로 내부망 DNS 컨테이너 만드는 방법](/posts/41/)의 1~2단계)
- 새 서버에 Proxmox VE 를 설치하고 실행 PC 의 SSH 키를 root 에 등록해 둡니다. 새 서버에는 VM·CT 가 없어야 합니다(게스트가 있는 노드는 합류할 수 없습니다).

```bash
# 실행 PC 에서 새 서버의 root 에 키 등록
ssh-copy-id root@[PVE02_IP]
```

- 두 서버의 스토리지 이름(`local`, `local-lvm`)이 같아야 합니다. 합류하면 스토리지 정의를 클러스터가 같이 쓰기 때문입니다.
- 컨테이너 이미지를 올릴 레지스트리(`[REGISTRY]`)와, NAS 가 그 레지스트리에서 받을 수 있는 인증

## 1. Tailscale 준비

두 Proxmox 노드와 NAS 를 같은 tailnet 에 넣습니다. 공유기 포트포워딩 없이 서로 직접 연결됩니다.

1. NAS 의 **패키지 센터**에서 **Tailscale** 을 설치하고 로그인합니다.
   패키지는 기본으로 userspace 모드라 들어오는 연결을 NAS 의 `127.0.0.1` 로 넘기기만 하고 NAS 에서 나가는 연결은 못 합니다. 나중에 NAS 에서 집으로 먼저 연결하는 서비스도 둘 수 있게 TUN 모드로 바꿉니다. DSM 은 부팅 때 `/usr/local/etc/rc.d/*.sh` 를 `start` 인자로 실행하므로 여기에 스크립트를 둡니다.
   ```bash
   # NAS 에 ssh 로 붙어 root 로 실행 (DSM 관리자 계정의 sudo)
   sudo tee /usr/local/etc/rc.d/tailscale-tun.sh >/dev/null <<'RC'
   #!/bin/sh
   [ "$1" = start ] || exit 0
   /var/packages/Tailscale/target/bin/tailscale configure-host
   /usr/syno/bin/synosystemctl restart pkgctl-Tailscale.service
   RC
   sudo chmod 0755 /usr/local/etc/rc.d/tailscale-tun.sh && sudo /usr/local/etc/rc.d/tailscale-tun.sh start

   # Proxmox 노드가 광고하는 집 LAN 경로(5단계) 받기
   sudo /var/packages/Tailscale/target/bin/tailscale set --accept-routes
   ```
2. Tailscale 관리 화면의 **Access controls** 정책에 태그 소유자와 경로 자동 승인을 추가합니다. `autoApprovers` 가 있으면 `tag:homelab` 노드가 광고하는 집 LAN 경로를 관리 화면에서 따로 승인하지 않아도 됩니다.
   ```json
   "tagOwners": {
     "tag:homelab": ["autogroup:admin"]
   },
   "autoApprovers": {
     "routes": {
       "[LAN_CIDR]": ["tag:homelab"]
     }
   },
   ```
3. **Settings** > **Keys** 에서 인증 키를 만듭니다. **Reusable** 은 켜고 **Ephemeral** 은 끄고, **Tags** 에 `tag:homelab` 을 붙입니다.
4. 실행 PC 에 키를 저장합니다(저장소에 넣지 않습니다).
   ```bash
   mkdir -p ~/.config/tailscale && (umask 077; cat > ~/.config/tailscale/authkey)   # 키 붙여 넣고 Ctrl-D
   ```

> 태그 없이 로그인한 기기는 노드 키가 180일 뒤 만료되어 QDevice 연결이 끊깁니다. NAS 처럼 사용자 계정으로 로그인한 기기는 **Machines** 에서 **Disable key expiry** 를 눌러 둡니다.
{: .prompt-warning }

- **확인:** 관리 화면의 **Machines** 에 NAS 가 보이고, NAS 에서 `ip -br addr show tailscale0` 에 Tailscale IP 가 보이며, `stat -c %a ~/.config/tailscale/authkey` 가 `600` 입니다.

## 2. qnetd 이미지 만들기

`pvecm qdevice setup` 은 QDevice 서버에 root 로 ssh 해 인증서를 만들고 서명합니다. 그래서 이미지에 corosync-qnetd 와 sshd 를 함께 넣습니다. 인증서 DB 와 ssh 호스트 키는 이미지에 넣지 않고 처음 실행할 때 볼륨에 만듭니다.

```bash
# 파일 내려받기
mkdir -p images/qnetd && cd images/qnetd
curl -fsSLO https://eu4ng.github.io/assets/files/qnetd/Dockerfile
curl -fsSLO https://eu4ng.github.io/assets/files/qnetd/entrypoint.sh

# 빌드와 푸시
docker build -t [REGISTRY]/qnetd:3.0.3-2 . && docker push [REGISTRY]/qnetd:3.0.3-2
```

<details markdown="1">
<summary>Dockerfile 전문</summary>

```dockerfile
# Proxmox 클러스터의 QDevice 서버(corosync-qnetd). 두 노드짜리 클러스터에 세 번째 표를 줍니다. 서울 NAS 에서 돌립니다(stacks/seoul/qnetd).
# pvecm qdevice setup 이 ssh(root)로 이 컨테이너에 붙어 인증서를 만들고 서명하므로 sshd 를 함께 띄웁니다.
# Proxmox VE 9 와 같은 Debian trixie 의 corosync-qnetd 를 씁니다. 태그는 QNETD_VERSION 을 씁니다 (.github/workflows/build-qnetd.yml).
ARG QNETD_VERSION=3.0.3-2
FROM debian:trixie-slim
ARG QNETD_VERSION
RUN apt-get update \
    && apt-get install -y --no-install-recommends corosync-qnetd=${QNETD_VERSION} openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    # 설치 스크립트가 만든 인증서 DB 와 ssh 호스트 키는 버립니다. 이미지에 CA 키가 들어가지 않게, 처음 실행할 때 볼륨에 만듭니다
    && rm -rf /etc/corosync/qnetd/nssdb /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```
{: file="images/qnetd/Dockerfile" }

</details>

<details markdown="1">
<summary>entrypoint.sh 전문</summary>

```bash
#!/bin/sh
# 상태(인증서 DB, ssh 호스트 키)는 /etc/corosync/qnetd 볼륨에 둡니다. 처음 실행할 때만 만듭니다.
# 환경 변수:
#   AUTHORIZED_KEYS  root 로 ssh 할 수 있는 공개키(줄바꿈으로 여러 개). Proxmox 노드들의 /root/.ssh/id_rsa.pub
#   LISTEN_ADDR      qnetd·sshd 가 받을 주소 (기본 127.0.0.1. 사설망 IP 에만 열려면 그 주소)
#   QNETD_PORT, SSH_PORT  기본 5403, 2222 (NAS 의 22 번은 DSM 이 씀)
set -eu
STATE=/etc/corosync/qnetd
LISTEN_ADDR=${LISTEN_ADDR:-127.0.0.1}
mkdir -p "$STATE/ssh" /run/corosync-qnetd

[ -f "$STATE/nssdb/cert9.db" ] || corosync-qnetd-certutil -i
[ -f "$STATE/ssh/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$STATE/ssh/ssh_host_ed25519_key"
printf '%s\n' "${AUTHORIZED_KEYS:?AUTHORIZED_KEYS 가 필요합니다}" > /etc/ssh/authorized_keys_root
chmod 0644 /etc/ssh/authorized_keys_root

/usr/sbin/sshd -o ListenAddress="$LISTEN_ADDR:${SSH_PORT:-2222}" -o HostKey="$STATE/ssh/ssh_host_ed25519_key" \
  -o PermitRootLogin=prohibit-password -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
  -o AuthorizedKeysFile=/etc/ssh/authorized_keys_root

# 인증서 DB 는 ssh 로 들어온 root 가 고치므로 qnetd 도 root 로 돌립니다(컨테이너 안에서만)
exec corosync-qnetd -f -l "$LISTEN_ADDR" -p "${QNETD_PORT:-5403}"
```
{: file="images/qnetd/entrypoint.sh" }

</details>

- **확인:** 레지스트리에 `qnetd:3.0.3-2` 태그가 보입니다.

## 3. NAS 에 qnetd 띄우기

qnetd(5403)와 sshd(2222)를 NAS 의 Tailscale IP 에만 열어 tailnet 에서만 닿고 NAS 의 LAN 에는 드러나지 않게 합니다. NAS 부팅 때 `tailscale0` 이 늦게 올라오면 바인드에 실패해 재시작되다가, 올라오면 뜹니다. 공개키 자리에는 두 Proxmox 노드의 `/root/.ssh/id_rsa.pub` 를 넣습니다(없으면 5단계 플레이북이 만들므로, 그 뒤에 넣고 스택을 다시 배포해도 됩니다).

```yaml
# 원격지 NAS(Synology, Portainer Swarm)의 corosync-qnetd. Proxmox 클러스터(두 노드)에 세 번째 표(QDevice)를 줍니다.
# 한 노드가 꺼져도 남은 노드 + 이 표로 과반이 유지됩니다. 이 컨테이너가 멈춰도 두 노드끼리 과반이라 클러스터는 그대로입니다.
# Proxmox 노드는 Tailscale 로 NAS 에 붙습니다. NAS 의 Tailscale 은 TUN 모드라 NAS 의 Tailscale IP 에만
# 열어 LAN 에는 노출하지 않습니다. 부팅 때 tailscale0 이 늦게 올라오면 바인드에 실패해 재시작되다가 올라오면 뜹니다.
# Portainer 의 Stacks 에 Git 저장소 스택 또는 웹 에디터로 등록합니다
# 연결: playbooks/pve-cluster.yml (pvecm qdevice setup, 노드의 ssh 설정에 Port 2222)
version: "3.8"
services:
  qnetd:
    image: [REGISTRY]/qnetd:3.0.3-2           # 2단계에서 빌드한 이미지
    environment:
      - LISTEN_ADDR=[NAS_TAILSCALE_IP]
      - QNETD_PORT=5403
      - SSH_PORT=2222
      # pvecm qdevice setup 이 root 로 ssh 해 인증서를 만듭니다. Proxmox 노드의 /root/.ssh/id_rsa.pub (공개키라 저장소에 둡니다)
      - |
        AUTHORIZED_KEYS=[PVE01_ROOT_PUBKEY]
        [PVE02_ROOT_PUBKEY]
    volumes:
      - qnetd-state:/etc/corosync/qnetd       # CA·서버 인증서 DB, ssh 호스트 키. 지우면 pvecm qdevice setup --force 로 다시 연결
    networks:
      - hostnet               # Swarm 은 network_mode: host 를 무시하므로 호스트 네트워크에 붙입니다
    deploy:
      replicas: 1
      restart_policy:
        condition: any

volumes:
  qnetd-state:

networks:
  hostnet:
    external: true
    name: host
```
{: file="stacks/qnetd/stack.yml" }

Portainer 의 **Stacks** > **Add stack** 에서 이 파일로 스택을 만듭니다. Swarm 은 `network_mode: host` 를 무시하므로 `host` 네트워크를 외부 네트워크로 붙였습니다.

- **확인:** 스택의 서비스가 `running` 이고, Proxmox 노드에서 Tailscale 연결 뒤(5단계) `nc -zv [NAS_TAILSCALE_IP] 5403` 이 `open` 입니다.

## 4. 인벤토리와 변수 채우기

인벤토리의 `proxmox` 그룹이 클러스터 노드이고, 호스트 이름이 곧 노드 이름입니다. `proxmox_primary` 가 클러스터를 만드는 메인 서버입니다. VM ID 는 클러스터 전체에서 하나라, 노드마다 만드는 VM 템플릿의 번호를 새 노드에서 바꿉니다.

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
```
{: file="inventory.yml" }

{% raw %}
```yaml
proxmox_domain: [DOMAIN]                      # Proxmox 호스트의 FQDN 도메인(pve01.[DOMAIN])
pve_cluster_name: homelab                     # pvecm create 로 만드는 클러스터 이름
pve_qdevice_host: [NAS_TAILSCALE_IP]          # QDevice(corosync-qnetd) 주소: NAS 의 Tailscale IP
pve_qdevice_ssh_port: 2222                    # qnetd 컨테이너의 sshd (NAS 의 22 는 DSM). pvecm qdevice setup 이 이 포트로 붙음
tailscale_lan_cidr: [LAN_CIDR]                # Proxmox 노드가 tailnet 에 광고하는 집 LAN(두 노드가 HA 서브넷 라우터). 원격 NAS 가 LAN 의 VM 에 닿는 경로
tailscale_authkey_file: "{{ lookup('env', 'HOME') }}/.config/tailscale/authkey"   # 실행 PC 의 Tailscale 재사용 인증 키(태그 tag:homelab)
```
{: file="group_vars/all.yml" }
{% endraw %}

기존 서버의 호스트 이름이 인벤토리 이름과 다르면 플레이북이 클러스터를 만들기 전에 이름을 바꿉니다. 노드 이름은 클러스터에 들어간 뒤에는 바꿀 수 없기 때문입니다. 게스트는 켜 둔 채로 바뀌고, 게스트 설정 파일을 새 노드 폴더로 옮기는 스크립트를 씁니다.

```bash
# requirements.yml 에 ansible.posix 를 추가하고 설치
ansible-galaxy collection install ansible.posix
```

- **확인:** `ansible-inventory --graph` 에 `@proxmox` 아래 두 노드와 `@proxmox_primary` 가 보입니다.

## 5. 플레이북 실행

플레이북은 여섯 플레이입니다. 노드 준비(구독 없는 apt 저장소, 호스트 이름), 클러스터 만들기, 합류, Tailscale, QDevice, 확인 순서입니다. 합류와 QDevice 는 이미 되어 있으면 건너뜁니다.

Tailscale 플레이는 로그인 뒤 두 노드를 서브넷 라우터로 만듭니다. IP 포워딩을 켜고 `tailscale set --advertise-routes` 로 집 LAN 을 광고합니다. 두 노드가 같은 대역을 광고하면 Tailscale 은 한 노드를 주 라우터로 쓰고 다른 노드를 대기로 둡니다. 원격 노드는 LAN 대역으로 가는 응답을 주 라우터로만 보내므로, VM 이 tailnet 으로 보내는 패킷은 자기 Proxmox 노드의 Tailscale IP 로 바꿔([마스커레이드](/posts/68/)) 내보냅니다. 이 규칙은 부팅 때 `tailscaled` 뒤에 적용되도록 systemd 유닛(`tailscale-lan-masquerade`)으로 둡니다.

```bash
# 플레이북과 이름 바꾸기 스크립트 내려받기
mkdir -p scripts
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/pve-cluster.yml -o playbooks/pve-cluster.yml
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/pve-rename-node.sh -o scripts/pve-rename-node.sh

# 실행
ansible-playbook playbooks/pve-cluster.yml
```

<details markdown="1">
<summary>playbooks/pve-cluster.yml 전문</summary>

{% raw %}
```yaml
# Proxmox 호스트들을 클러스터 하나로 묶습니다. inventory 의 proxmox 그룹이 노드이고, proxmox_primary 에서 클러스터를 만든 뒤 나머지가 합류합니다.
# 호스트 이름을 inventory 이름(FQDN <이름>.{{ proxmox_domain }})으로 맞추고, apt 저장소를 구독 없는 저장소로 맞춥니다.
# 노드 이름은 클러스터에 들어간 뒤에는 바꿀 수 없어, 합류 전에 scripts/pve-rename-node.sh 로 바꿉니다(게스트는 켠 채로 둬도 됩니다).
# 새 서버는 Proxmox 설치와 root ssh 키 등록(ssh-copy-id)만 해 두고 inventory 에 추가한 뒤 다시 실행합니다. 여러 번 실행해도 됩니다.
#   ansible-playbook playbooks/pve-cluster.yml
---
- name: 노드 준비
  hosts: proxmox
  gather_facts: false
  any_errors_fatal: true          # 한 노드라도 실패하면 클러스터 단계로 넘어가지 않습니다
  tasks:
    - name: 유료(enterprise) 저장소 끄기
      ansible.builtin.lineinfile:
        path: /etc/apt/sources.list.d/{{ item }}.sources
        regexp: '^Enabled:'
        line: 'Enabled: false'
      loop: [pve-enterprise, ceph]
    - name: 구독 없는 저장소
      ansible.builtin.copy:
        dest: /etc/apt/sources.list.d/proxmox.sources
        mode: "0644"
        content: |
          Types: deb
          URIs: http://download.proxmox.com/debian/pve
          Suites: trixie
          Components: pve-no-subscription
          Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg

    - name: 이름 바꾸기 스크립트
      ansible.builtin.copy:
        src: ../scripts/pve-rename-node.sh
        dest: /root/pve-rename-node.sh
        mode: "0755"
    - name: 클러스터 합류 여부
      ansible.builtin.stat:
        path: /etc/pve/corosync.conf
      register: corosync
    # pve-cluster 를 재시작하므로 ssh 가 끊겨도 끝까지 돌도록 systemd 유닛으로 실행하고 출력은 파일로 받습니다
    - name: 호스트 이름을 inventory 이름으로 (클러스터 전에만)
      ansible.builtin.shell: |
        set -e
        systemd-run --unit pve-rename-node-$(date +%s) --collect --wait \
          -p StandardOutput=file:/root/pve-rename-node.log -p StandardError=inherit \
          bash /root/pve-rename-node.sh {{ inventory_hostname }} {{ proxmox_domain }}
        cat /root/pve-rename-node.log
      register: rename
      changed_when: "'RENAME_CHANGED' in rename.stdout"
      when: not corosync.stat.exists
    - name: 이름 바꾸기 결과
      ansible.builtin.debug:
        msg: "{{ rename.stdout_lines }}"
      when: rename is changed

    - name: 노드 이름 확인
      ansible.builtin.command: hostname -f
      register: fqdn
      changed_when: false
      failed_when: fqdn.stdout != inventory_hostname ~ '.' ~ proxmox_domain
    - name: root 키 (없을 때만. 합류할 때 메인 서버에 ssh 로 붙는 데 씀)
      ansible.builtin.command: ssh-keygen -q -t rsa -b 4096 -N '' -f /root/.ssh/id_rsa
      args:
        creates: /root/.ssh/id_rsa
    - name: root 공개키
      ansible.builtin.slurp:
        src: /root/.ssh/id_rsa.pub
      register: root_pubkey

- name: 클러스터 만들기
  hosts: proxmox_primary
  gather_facts: false
  any_errors_fatal: true
  tasks:
    - name: 클러스터 만들기 (없을 때만)
      ansible.builtin.command: pvecm create {{ pve_cluster_name }} --link0 {{ ansible_host }}
      args:
        creates: /etc/pve/corosync.conf
    - name: 다른 노드의 root 키 허용 (pvecm add --use_ssh 용)
      ansible.posix.authorized_key:
        user: root
        key: "{{ hostvars[item].root_pubkey.content | b64decode }}"
        comment: "{{ item }}"
      loop: "{{ groups.proxmox | difference(groups.proxmox_primary) }}"

- name: 클러스터 합류
  hosts: proxmox:!proxmox_primary
  gather_facts: false
  serial: 1
  vars:
    primary_ip: "{{ hostvars[groups.proxmox_primary[0]].ansible_host }}"
  tasks:
    - name: 메인 서버에 클러스터가 있는지
      ansible.builtin.stat:
        path: /etc/pve/corosync.conf
      delegate_to: "{{ groups.proxmox_primary[0] }}"
      register: primary_corosync
      failed_when: not primary_corosync.stat.exists
    - name: 합류 여부
      ansible.builtin.stat:
        path: /etc/pve/corosync.conf
      register: corosync
    - name: 합류
      when: not corosync.stat.exists
      block:
        - name: 메인 서버 호스트 키 등록
          ansible.builtin.shell: |
            ssh-keygen -R {{ primary_ip }} >/dev/null 2>&1 || true
            ssh-keyscan -t ed25519,rsa {{ primary_ip }} >> /root/.ssh/known_hosts
        - name: 합류 (게스트가 없는 노드만 가능)
          ansible.builtin.command: pvecm add {{ primary_ip }} --link0 {{ ansible_host }} --use_ssh
          register: join
          failed_when: "'successfully added node' not in join.stdout"   # 실패해도 종료 코드 0 으로 끝나는 경우가 있어 출력으로 판단합니다

# 원격지(서울 NAS)의 QDevice 에 닿기 위한 사설망. 인증 키는 실행 PC 의 파일에서 읽어 명령에만 넘깁니다(로그에 남기지 않음)
- name: Tailscale
  hosts: proxmox
  gather_facts: false
  tasks:
    - name: 저장소 키
      ansible.builtin.get_url:
        url: https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg
        dest: /usr/share/keyrings/tailscale-archive-keyring.gpg
        mode: "0644"
    - name: 저장소
      ansible.builtin.copy:
        dest: /etc/apt/sources.list.d/tailscale.list
        mode: "0644"
        content: |
          deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main
    - name: 설치
      ansible.builtin.apt:
        name: tailscale
        update_cache: true
    - name: 서비스
      ansible.builtin.systemd:
        name: tailscaled
        enabled: true
        state: started
    - name: 로그인 상태
      ansible.builtin.command: tailscale status --json
      register: ts_status
      changed_when: false
      failed_when: false
    # DNS 는 LAN DNS 를 그대로 쓰고(--accept-dns=false), 다른 노드가 광고하는 경로도 받지 않습니다
    - name: 로그인 (안 돼 있을 때만)
      ansible.builtin.command: >-
        tailscale up --auth-key={{ lookup('ansible.builtin.file', tailscale_authkey_file) }}
        --hostname={{ inventory_hostname }} --accept-dns=false --accept-routes=false
      no_log: true
      when: (ts_status.stdout | default('{}') | from_json).BackendState | default('') != 'Running'
    # 두 노드가 집 LAN 을 광고해(HA 서브넷 라우터) 원격 NAS 가 LAN 의 VM 에 닿게 합니다. 경로 승인은 Tailscale 관리 화면(또는 ACL autoApprovers)
    - name: IP 포워딩
      ansible.posix.sysctl:
        name: net.ipv4.ip_forward
        value: "1"
        sysctl_file: /etc/sysctl.d/99-tailscale.conf
    - name: 집 LAN 광고
      ansible.builtin.command: tailscale set --advertise-routes={{ tailscale_lan_cidr }}
      changed_when: false
    # VM 이 tailnet 으로 보내는 패킷은 이 호스트의 Tailscale IP 로 바꿔 내보냅니다. 원격 노드는 LAN 대역을 주 라우터 한 대에서만
    # 받아들이므로, 주 라우터가 아닌 호스트의 VM 이 LAN 주소 그대로 보내면 버려집니다
    - name: LAN → tailnet 마스커레이드 (부팅 때 tailscaled 뒤에 적용)
      ansible.builtin.copy:
        dest: /etc/systemd/system/tailscale-lan-masquerade.service
        mode: "0644"
        content: |
          [Unit]
          Description=Masquerade LAN traffic leaving through tailscale0 (proxmox-ansible pve-cluster.yml)
          After=tailscaled.service
          Wants=tailscaled.service

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/bin/sh -c 'iptables -t nat -C POSTROUTING -s {{ tailscale_lan_cidr }} -o tailscale0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s {{ tailscale_lan_cidr }} -o tailscale0 -j MASQUERADE'
          ExecStop=/bin/sh -c 'iptables -t nat -D POSTROUTING -s {{ tailscale_lan_cidr }} -o tailscale0 -j MASQUERADE || true'

          [Install]
          WantedBy=multi-user.target
      register: masq_unit
    - name: 마스커레이드 켜기
      ansible.builtin.systemd:
        name: tailscale-lan-masquerade
        enabled: true
        state: "{{ 'restarted' if masq_unit is changed else 'started' }}"
        daemon_reload: "{{ masq_unit is changed }}"
    - name: Tailscale IP
      ansible.builtin.command: tailscale ip -4
      register: ts_ip
      changed_when: false
    - name: 결과
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }} {{ ts_ip.stdout }}"

# 두 노드 클러스터의 세 번째 표. 한 노드가 꺼져도 남은 노드 + QDevice 로 과반을 유지합니다
- name: QDevice
  hosts: proxmox
  gather_facts: false
  tasks:
    - name: corosync-qdevice
      ansible.builtin.apt:
        name: corosync-qdevice
    - name: qnetd 컨테이너의 ssh 포트 (pvecm qdevice setup 의 ssh·scp 가 씀)
      ansible.builtin.blockinfile:
        path: /root/.ssh/config
        create: true
        mode: "0600"
        marker: "# {mark} pve-cluster.yml: QDevice"
        block: |
          Host {{ pve_qdevice_host }}
            Port {{ pve_qdevice_ssh_port }}
            User root
            StrictHostKeyChecking accept-new
    - name: qnetd 에 ssh 가 되는지
      ansible.builtin.command: ssh -o BatchMode=yes {{ pve_qdevice_host }} corosync-qnetd-tool -s
      changed_when: false
    - name: QDevice 설정 여부
      ansible.builtin.command: grep -q 'model:\s*net' /etc/pve/corosync.conf
      register: qdevice_conf
      changed_when: false
      failed_when: false
      when: inventory_hostname in groups.proxmox_primary
    - name: QDevice 연결 (모든 노드가 온라인이어야 함)
      ansible.builtin.command: pvecm qdevice setup {{ pve_qdevice_host }}
      when: inventory_hostname in groups.proxmox_primary and qdevice_conf.rc != 0

- name: 확인
  hosts: proxmox_primary
  gather_facts: false
  tasks:
    - name: 클러스터 상태
      ansible.builtin.command: pvecm status
      register: status
      changed_when: false
    - name: 모든 노드가 들어왔고 과반인지
      ansible.builtin.assert:
        that:
          - "'Quorate:          Yes' in status.stdout"
          - "status.stdout is search('Nodes:\\s+' ~ (groups.proxmox | length) ~ '\\s')"
          - "status.stdout is search('Qdevice')"
        fail_msg: "{{ status.stdout }}"
    - name: 상태
      ansible.builtin.debug:
        msg: "{{ status.stdout_lines }}"
```
{: file="playbooks/pve-cluster.yml" }
{% endraw %}

</details>

<details markdown="1">
<summary>scripts/pve-rename-node.sh 전문</summary>

```bash
#!/usr/bin/env bash
#
# 단독(클러스터에 들어가지 않은) Proxmox 노드의 이름을 바꿉니다. 게스트는 켠 채로 둬도 됩니다.
# 실행 중인 VM·CT 프로세스는 노드 이름과 무관하고, 이 스크립트는 게스트 설정 파일만 새 노드 폴더로 옮깁니다.
# 클러스터 노드는 이름을 바꿀 수 없으므로 중단합니다. 클러스터를 만들기 전에 실행합니다(playbooks/pve-cluster.yml 이 호출).
# 이미 새 이름이면 남은 옛 폴더의 게스트 설정만 옮기고 끝냅니다. 여러 번 실행해도 됩니다.
# 옛 노드 폴더(/etc/pve/nodes/<옛 이름>)는 지우지 않습니다. 확인한 뒤 직접 지웁니다.
#
# 사용법(호스트에서 root): bash pve-rename-node.sh <새 이름> <도메인>
#   ssh 가 끊겨도 멈추지 않게 systemd-run 으로 돌리는 것을 권합니다:
#   systemd-run --unit pve-rename-node --collect bash pve-rename-node.sh pve01 example.com; journalctl -fu pve-rename-node

set -euo pipefail
log() { echo "==> $*"; }
die() { echo "[오류] $*" >&2; exit 1; }

NEW=${1:-}; DOMAIN=${2:-}
[ -n "$NEW" ] && [ -n "$DOMAIN" ] || die "사용법: bash pve-rename-node.sh <새 이름> <도메인>"
[ "$(id -u)" = 0 ] || die "root 로 실행합니다."
[ -e /etc/pve/corosync.conf ] && die "클러스터에 들어간 노드는 이름을 바꿀 수 없습니다."
OLD=$(hostname -s)
CHANGED=0

if [ "$OLD" != "$NEW" ]; then
  CHANGED=1
  BACKUP=/root/pve-rename-$(date +%Y%m%d-%H%M%S)
  log "백업: $BACKUP"
  mkdir -p "$BACKUP"
  tar -C / -czf "$BACKUP/etc-pve.tgz" etc/pve
  cp -a /var/lib/pve-cluster/config.db "$BACKUP/"
  cp -a /etc/hosts /etc/hostname "$BACKUP/"

  log "호스트 이름: $OLD → $NEW.$DOMAIN"
  IP=$(awk -v h="$OLD" '$1 !~ /^127\./ { for (i = 2; i <= NF; i++) if ($i == h) { print $1; exit } }' /etc/hosts)
  [ -n "$IP" ] || die "/etc/hosts 에서 $OLD 의 주소를 찾지 못했습니다."
  hostnamectl set-hostname "$NEW"
  awk -v h="$OLD" -v ip="$IP" -v line="$IP $NEW.$DOMAIN $NEW" '
    { hit = 0; for (i = 2; i <= NF; i++) if ($i == h) hit = 1 }
    hit && $1 == ip { print line; next } { print }' "$BACKUP/hosts" > /etc/hosts
  if command -v postconf >/dev/null; then
    postconf -e "myhostname=$NEW.$DOMAIN"
    systemctl reload postfix || true
  fi

  log "pve-cluster 재시작(새 이름으로 /etc/pve 다시 올림)"
  systemctl restart pve-cluster
  # 새 노드 폴더는 저절로 생기지 않습니다. /etc/pve 가 다시 올라오면 직접 만들고, 아래에서 게스트 설정을 옮깁니다
  for _ in $(seq 30); do mkdir -p "/etc/pve/nodes/$NEW" 2>/dev/null && break; sleep 1; done
  [ -d "/etc/pve/nodes/$NEW" ] || die "/etc/pve/nodes/$NEW 를 만들지 못했습니다."
fi

log "게스트 설정 옮기기 → /etc/pve/nodes/$NEW"
for dir in /etc/pve/nodes/*/; do
  node=$(basename "$dir")
  [ "$node" = "$NEW" ] && continue
  for sub in qemu-server lxc; do
    mkdir -p "/etc/pve/nodes/$NEW/$sub"
    for f in "$dir$sub"/*.conf; do
      [ -e "$f" ] || continue
      [ -e "/etc/pve/nodes/$NEW/$sub/$(basename "$f")" ] && die "$NEW 에 이미 $(basename "$f") 가 있습니다."
      mv "$f" "/etc/pve/nodes/$NEW/$sub/"
      echo "    $node/$sub/$(basename "$f")"
      CHANGED=1
    done
  done
  for f in host.fw config; do
    if [ -e "$dir$f" ] && [ ! -e "/etc/pve/nodes/$NEW/$f" ]; then
      mv "$dir$f" "/etc/pve/nodes/$NEW/$f"; echo "    $node/$f"; CHANGED=1
    fi
  done
  # 그래프 이력(RRD)은 노드 이름으로 저장되므로 새 이름으로 복사합니다
  for rrd in /var/lib/rrdcached/db/pve-node-* /var/lib/rrdcached/db/pve-storage-* /var/lib/rrdcached/db/pve2-node /var/lib/rrdcached/db/pve2-storage; do
    if [ -e "$rrd/$node" ] && [ ! -e "$rrd/$NEW" ]; then
      cp -a "$rrd/$node" "$rrd/$NEW"; echo "    그래프 이력 $rrd/$node"; CHANGED=1
    fi
  done
  echo "    옛 폴더 /etc/pve/nodes/$node 가 남아 있습니다. 확인 뒤 rm -r 로 지웁니다."
done

if [ "$CHANGED" = 1 ]; then
  log "인증서·서비스 갱신"
  pvecm updatecerts --force
  systemctl restart pvedaemon pveproxy pvestatd pvescheduler pve-firewall pve-ha-lrm pve-ha-crm
  echo "RENAME_CHANGED"
else
  log "이미 $NEW 입니다. 바꿀 것이 없습니다."
fi

log "결과"
pvesh get /nodes --output-format text --noborder
qm list
pct list
```
{: file="scripts/pve-rename-node.sh" }

</details>

> 합류하면 새 노드의 `/etc/pve` 가 클러스터 것으로 바뀝니다. 새 노드에만 있던 사용자, API 토큰, 스토리지 정의는 사라지고 메인 서버의 것을 같이 씁니다.
{: .prompt-warning }

- **확인:** `PLAY RECAP` 에 `failed=0` 이고, 마지막 `상태` 태스크에 `Nodes: 2` 와 `Qdevice` 가 보입니다. 한 번 더 실행하면 모든 노드가 `changed=0` 입니다.

## 6. 확인

```bash
# 표 3개(노드 2 + QDevice) 중 과반 2
ssh root@[PVE01_IP] 'pvecm status | sed -n "/Votequorum/,\$p"'

# qnetd 쪽에서 본 연결 (두 노드가 붙어 있어야 함)
ssh root@[PVE01_IP] 'ssh [NAS_TAILSCALE_IP] corosync-qnetd-tool -l'

# 마스커레이드 규칙 (두 노드 모두)
for h in [PVE01_IP] [PVE02_IP]; do ssh root@$h 'iptables -t nat -S POSTROUTING | grep tailscale0'; done
```

```bash
# NAS 에 ssh 로 붙어: 집 LAN 경로와 LAN 호스트 연결
ip route show table 52 | grep [LAN_CIDR]
timeout 3 bash -c '</dev/tcp/[PVE02_IP]/22' && echo open
```

- **확인:** `Expected votes: 3`, `Total votes: 3`, `Flags: Quorate Qdevice` 이고 멤버 목록에 `Qdevice` 가 한 줄 더 있습니다. qnetd 쪽에는 `Connected clients` 가 노드 수만큼 보입니다. 노드마다 `-A POSTROUTING -s [LAN_CIDR] -o tailscale0 -j MASQUERADE` 가 보이고, NAS 에는 `[LAN_CIDR] dev tailscale0` 경로가 있으며 LAN 호스트에 `open` 으로 연결됩니다.

QDevice 가 멈췄을 때도 확인해 둡니다. Portainer 에서 qnetd 서비스의 복제본을 0 으로 줄이면 `pvecm status` 가 `Total votes: 2` 로 바뀌지만 `Quorate` 는 유지되고, VM 을 시작·정지할 수 있습니다. 다시 1로 늘리면 인증서가 볼륨에 남아 있어 따로 설정하지 않아도 `Total votes: 3` 으로 돌아옵니다.

## 트러블슈팅

<details markdown="1">
<summary><code>/etc/pve/nodes/[새 이름] 가 생기지 않았습니다</code></summary>

- **원인:** `pve-cluster` 를 새 이름으로 다시 올려도 새 노드 폴더는 저절로 생기지 않습니다. 이 상태에서는 게스트가 계속 돌지만 `qm list` 에 보이지 않습니다.
- **해결:** 스크립트가 `/etc/pve` 가 올라온 뒤 새 노드 폴더를 직접 만들고 게스트 설정을 옮기도록 고쳤습니다. 이미 이 상태라면 같은 인자로 스크립트를 다시 실행하면 옛 폴더의 설정을 옮기고 끝납니다.

</details>

<details markdown="1">
<summary><code>pvecm add</code> 가 오류 없이 끝났는데 노드가 합류하지 않음</summary>

- **원인:** 확인하지 못했습니다. 종료 코드는 0 이었지만 `pvecm status` 에 노드가 한 대뿐이었고, 같은 명령을 다시 실행하자 합류했습니다.
- **해결:** 플레이북이 종료 코드 대신 출력의 `successfully added node` 로 성공을 판단하게 했습니다.

</details>

## 마무리

Proxmox 서버 두 대를 클러스터로 묶고 원격 NAS 의 qnetd 로 세 번째 표를 주어, 한 대가 꺼지거나 NAS 가 멈춰도 남은 쪽이 과반을 유지하게 했습니다. 두 노드는 집 LAN 을 tailnet 에 광고하는 서브넷 라우터가 되어, 원격 NAS 와 LAN 의 VM 이 Tailscale 로 서로 닿습니다. 새 서버를 더할 때는 인벤토리에 추가하고 같은 플레이북을 다시 실행합니다. 이 글은 Proxmox 관리 기능의 과반만 다룹니다. 노드마다 로컬 디스크를 쓰므로 게스트를 다른 노드로 자동으로 옮기는 Proxmox HA 는 설정하지 않았습니다.

## 참고 자료

- [Proxmox VE - Cluster Manager (Corosync External Vote Support)](https://pve.proxmox.com/wiki/Cluster_Manager#_corosync_external_vote_support)
- [corosync-qdevice (GitHub)](https://github.com/corosync/corosync-qdevice)
- [Tailscale - Auth keys](https://tailscale.com/kb/1085/auth-keys)
- [Tailscale - Subnet routers](https://tailscale.com/kb/1019/subnets)
- [Tailscale - Synology](https://tailscale.com/kb/1131/synology)
