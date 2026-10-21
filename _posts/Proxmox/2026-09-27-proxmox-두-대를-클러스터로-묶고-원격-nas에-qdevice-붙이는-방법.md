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
7. 노드 디스크 교체·재구축

> 서버가 세 대가 되면 노드마다 한 표씩 세 표라, 한 대가 꺼져도 남은 두 대가 과반(3표 중 2표)입니다. 이때는 QDevice 없이 인벤토리의 `proxmox` 그룹에 세 번째 노드(템플릿 번호 `vm_template_vmid: 9002`)를 더하고 `pve_qdevice_host` 를 비워(`""`) 같은 플레이북을 다시 실행합니다. 플레이북은 모든 노드가 online 일 때 남은 QDevice 설정을 지웁니다.
{: .prompt-info }

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

인벤토리의 `proxmox` 그룹이 클러스터 노드이고, 호스트 이름이 곧 노드 이름입니다. 특정 노드를 메인으로 고정하지 않습니다. 클러스터가 아직 없으면 `cluster_bootstrap_node` 가 만들고, 있으면 과반 쪽 노드에 합류하며, 클러스터 전체 작업을 하는 기준 노드는 플레이북이 고릅니다(5단계). VM ID 는 클러스터 전체에서 하나라, 노드마다 만드는 VM 템플릿의 번호를 새 노드에서 바꿉니다.

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
```
{: file="inventory.yml" }

{% raw %}
```yaml
# 기준 노드: 클러스터 전체 작업을 하는 노드(playbooks/main-node.yml 이 살아 있는 과반 쪽 노드로 고름). 그 플레이를 import 하지 않은
# 플레이북에서는 inventory 의 첫 노드입니다. 노드 이름은 pvesh get /nodes 의 이름
proxmox_node: "{{ (groups.pve_main | default(groups.proxmox))[0] }}"
proxmox_api_host: "{{ hostvars[proxmox_node].ansible_host }}"
cluster_bootstrap_node: pve01                 # 클러스터가 아직 없을 때만 여기서 pvecm create. 있으면 과반 쪽 노드에 합류(pve-cluster.yml)
proxmox_domain: [DOMAIN]                      # Proxmox 호스트의 FQDN 도메인(pve01.[DOMAIN])
pve_cluster_name: homelab                     # pvecm create 로 만드는 클러스터 이름
pve_qdevice_host: [NAS_TAILSCALE_IP]          # QDevice(corosync-qnetd) 주소: NAS 의 Tailscale IP
pve_qdevice_ssh_port: 2222                    # qnetd 컨테이너의 sshd (NAS 의 22 는 DSM). pvecm qdevice setup 이 이 포트로 붙음
tailscale_lan_cidr: [LAN_CIDR]                # Proxmox 노드가 tailnet 에 광고하는 집 LAN(두 노드가 HA 서브넷 라우터). 원격 NAS 가 LAN 의 VM 에 닿는 경로
tailscale_authkey_file: "{{ lookup('env', 'HOME') }}/.config/tailscale/authkey"   # 실행 PC 의 Tailscale 재사용 인증 키(태그 tag:homelab)
# 모든 노드가 다른 노드를 다시 만들 수 있게 준비합니다(playbooks/pve-controller.yml, 7단계)
pve_controller_repo: git@github.com:[GITHUB_USER]/proxmox-ansible.git   # 노드마다 받는 이 저장소
pve_controller_dir: /root/proxmox-ansible     # 각 노드의 저장소 사본. 가상 환경은 그 안의 .venv
pve_controller_key_source: "{{ proxmox_node }}"   # GitHub 계정 키의 원본 파일이 있는 노드(/root/.ssh/id_ed25519)
pve_controller_pip: [ansible-core==2.20.1, proxmoxer==2.2.0, requests]   # 실행 PC 와 같은 버전
pve_controller_token_file: /root/.config/proxmox/token   # 노드별 API 토큰 root@pam!rebuild-<노드> 의 secret
# 호스트 재부팅 스크립트(scripts/pve-reboot.sh)가 다른 게스트를 모두 내린 뒤 마지막에 내릴 NAS VM. 그 VM 이 있는 노드의 /etc/default/pve-reboot 에
# LAST_VMIDS 로 들어갑니다. NAS VM 이 없으면 { vmid: "", pve: "" }
xpenology: { vmid: [NAS_VMID], pve: [NAS_NODE] }
github_ssh_host_key: "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"   # https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
```
{: file="group_vars/all.yml" }
{% endraw %}

기존 서버의 호스트 이름이 인벤토리 이름과 다르면 플레이북이 클러스터를 만들기 전에 이름을 바꿉니다. 노드 이름은 클러스터에 들어간 뒤에는 바꿀 수 없기 때문입니다. 게스트는 켜 둔 채로 바뀌고, 게스트 설정 파일을 새 노드 폴더로 옮기는 스크립트를 씁니다.

requirements.yml 에 `ansible.posix` 를 더하고 버전을 고정합니다. 7단계의 재구축은 남은 노드에서 이 저장소로 플레이북을 돌리므로, 버전을 고정하지 않으면 노드마다 받은 날의 최신판이 깔려 같은 플레이북이 다르게 돌 수 있습니다.

```yaml
# 버전을 고정합니다. 올릴 때는 실행 PC 에서 먼저 돌려 본 뒤 여기와 group_vars 의 pve_controller_pip 을 함께 고칩니다
collections:
  - name: community.proxmox
    version: 1.4.0
  - name: community.general
    version: 12.1.0
  - name: ansible.posix
    version: 2.1.0
```
{: file="requirements.yml" }

```bash
ansible-galaxy collection install -r requirements.yml
```

- **확인:** `ansible-inventory --graph` 에 `@proxmox` 아래 두 노드가 보입니다.

## 5. 플레이북 실행

플레이북은 여섯 플레이와 중간에 불러오는 `main-node.yml`, 마지막에 불러오는 `pve-controller.yml` 입니다. 노드 준비(구독 없는 apt 저장소, 호스트 이름, CPU 절전 정책), 클러스터 만들기, 합류, (`main-node.yml`), Tailscale, QDevice, 확인 순서이고, `pve-controller.yml` 은 모든 노드를 다른 노드를 다시 만들 수 있는 노드로 준비합니다(7단계). 클러스터가 없을 때만 `cluster_bootstrap_node` 에서 만들고, 있으면 과반 쪽 노드에 합류합니다. 합류와 QDevice 는 이미 되어 있으면 건너뜁니다. Tailscale 로그인에 실패하면 한 노드라도 거기서 멈추고, 다시 실행하면 이어 갑니다. CPU 절전 정책은 부팅 때 도는 systemd 유닛(`cpu-epp`)으로, amd-pstate-epp 의 governor 를 `powersave`, EPP 를 `balance_power` 로 둡니다. 한가할 때 클럭이 내려가 유휴 전력이 줄고, 부하가 와도 클럭을 덜 공격적으로 올려 발열과 팬 소음이 줄어듭니다(처음에는 `balance_performance` 였는데, 16코어 노드가 부하에 95 °C 까지 올라 팬이 시끄러워 낮췄습니다)(값은 `group_vars/all.yml` 의 `pve_cpu_governor`·`pve_cpu_epp`).

Tailscale 플레이는 로그인 뒤 두 노드를 서브넷 라우터로 만듭니다. IP 포워딩을 켜고 `tailscale set --advertise-routes` 로 집 LAN 을 광고합니다. 두 노드가 같은 대역을 광고하면 Tailscale 은 한 노드를 주 라우터로 쓰고 다른 노드를 대기로 둡니다. 원격 노드는 LAN 대역으로 가는 응답을 주 라우터로만 보내므로, VM 이 tailnet 으로 보내는 패킷은 자기 Proxmox 노드의 Tailscale IP 로 바꿔([마스커레이드](/posts/68/)) 내보냅니다. 이 규칙은 부팅 때 `tailscaled` 뒤에 적용되도록 systemd 유닛(`tailscale-lan-masquerade`)으로 둡니다.

```bash
# 플레이북과 이름 바꾸기·재부팅 스크립트 내려받기
mkdir -p scripts
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/main-node.yml -o playbooks/main-node.yml
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/pve-cluster.yml -o playbooks/pve-cluster.yml
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/pve-controller.yml -o playbooks/pve-controller.yml
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/pve-rename-node.sh -o scripts/pve-rename-node.sh
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/pve-reboot.sh -o scripts/pve-reboot.sh

# 실행
ansible-playbook playbooks/pve-cluster.yml
```

<details markdown="1">
<summary>playbooks/pve-cluster.yml 전문</summary>

{% raw %}
```yaml
# Proxmox 호스트들을 클러스터 하나로 묶습니다. inventory 의 proxmox 그룹이 노드이고, 클러스터가 없으면
# cluster_bootstrap_node 에서 만들고 나머지는 과반 쪽 노드에 합류합니다.
# 호스트 이름을 inventory 이름(FQDN <이름>.{{ proxmox_domain }})으로 맞추고, apt 저장소를 구독 없는 저장소로 맞춥니다.
# 노드 이름은 클러스터에 들어간 뒤에는 바꿀 수 없어, 합류 전에 scripts/pve-rename-node.sh 로 바꿉니다(게스트는 켠 채로 둬도 됩니다).
# 호스트 CPU 주파수 정책(cpu-epp.service: governor·EPP, 값은 group_vars 의 pve_cpu_*)과 재부팅 스크립트도 둡니다.
# 새 서버는 Proxmox 설치와 root ssh 키 등록(ssh-copy-id)만 해 두고 inventory 에 추가한 뒤 다시 실행합니다. 여러 번 실행해도 됩니다.
# 같은 이름의 노드를 다시 설치했으면(디스크 교체) 먼저 남은 노드에서 scripts/pve-node-rebuild.sh 로 옛 기록을 지웁니다(그 스크립트가 이 플레이북도 부름).
# 끝에서 pve-controller.yml 을 불러 모든 노드가 다른 노드를 복구할 수 있게 합니다.
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
    # 호스트 재부팅은 이 스크립트로 한다(멈춘 게스트가 있으면 sysrq 로). 사용법은 스크립트 머리말
    - name: 재부팅 스크립트
      ansible.builtin.copy:
        src: ../scripts/pve-reboot.sh
        dest: /usr/local/sbin/pve-reboot.sh
        mode: "0755"
    # 다른 게스트를 모두 내린 뒤 마지막에 내릴 게스트(NAS). NFS 저장소에 디스크를 둔 VM 이 NAS 보다 먼저 내려가게 합니다
    - name: 재부팅 스크립트 기본값 (마지막에 내릴 게스트)
      ansible.builtin.copy:
        dest: /etc/default/pve-reboot
        mode: "0644"
        content: |
          # proxmox-ansible pve-cluster.yml (group_vars 의 xpenology.vmid, k8s_clusters). scripts/pve-reboot.sh 가 읽음
          LAST_VMIDS="{{ xpenology.vmid if xpenology.pve == inventory_hostname else '' }}"
          # 이 호스트의 쿠버네티스 노드(재부팅 전에 drain) "클러스터:노드,노드"
          K8S_DRAIN="{% for c, k in k8s_clusters.items() %}{% set mine = k.nodes | selectattr('pve', 'eq', inventory_hostname) | map(attribute='name') | list %}{% if mine %}{{ c }}:{{ mine | join(',') }} {% endif %}{% endfor %}"
          # kubectl 을 돌릴 다른 호스트의 control plane "클러스터:IP,IP"(앞에서부터 붙는 곳)
          K8S_KUBECTL="{% for c, k in k8s_clusters.items() %}{% set cps = k.nodes | rejectattr('pve', 'eq', inventory_hostname) | selectattr('role', 'eq', 'control-plane') | map(attribute='ip') | list %}{% if cps %}{{ c }}:{{ cps | join(',') }} {% endif %}{% endfor %}"
    # 부팅 뒤 pve-reboot.sh 가 drain 한 노드를 Ready 가 되면 uncordon 하고 CoreDNS 수를 맞춥니다(표식이 없으면 바로 끝남).
    # HA 게스트는 되돌리지 않습니다(nofailback). worker-3 은 NAS 를 기다려 약 6분 뒤 켜지므로 30분까지 기다립니다
    - name: 재부팅 뒤 쿠버네티스 노드 복귀 유닛
      ansible.builtin.copy:
        dest: /etc/systemd/system/pve-k8s-return.service
        mode: "0644"
        content: |
          [Unit]
          Description=Uncordon k8s nodes drained by pve-reboot.sh (proxmox-ansible pve-cluster.yml)
          Wants=network-online.target
          After=network-online.target pve-guests.service

          [Service]
          Type=oneshot
          ExecStart=/usr/local/sbin/pve-reboot.sh --return
          TimeoutStartSec=35min

          [Install]
          WantedBy=multi-user.target
      register: k8s_return_unit
    - name: 재부팅 뒤 쿠버네티스 노드 복귀 켜기
      ansible.builtin.systemd:
        name: pve-k8s-return.service
        enabled: true
        daemon_reload: "{{ k8s_return_unit is changed }}"
    # governor 를 먼저 바꿔야 EPP 를 고를 수 있습니다(performance governor 에서는 EPP 가 performance 하나뿐)
    - name: CPU 주파수 정책 (부팅 때 적용)
      ansible.builtin.copy:
        dest: /etc/systemd/system/cpu-epp.service
        mode: "0644"
        content: |
          [Unit]
          Description=CPU governor {{ pve_cpu_governor }} + EPP {{ pve_cpu_epp }} for idle power (proxmox-ansible pve-cluster.yml)
          After=multi-user.target

          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/bin/sh -c 'for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do echo {{ pve_cpu_governor }} > $c/scaling_governor; [ -w $c/energy_performance_preference ] && echo {{ pve_cpu_epp }} > $c/energy_performance_preference; done; true'

          [Install]
          WantedBy=multi-user.target
      register: cpu_epp_unit
    - name: CPU 주파수 정책 켜기
      ansible.builtin.systemd:
        name: cpu-epp
        enabled: true
        state: "{{ 'restarted' if cpu_epp_unit is changed else 'started' }}"
        daemon_reload: "{{ cpu_epp_unit is changed }}"
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
    - name: root 키 (없을 때만. 합류할 때 기준 노드에 ssh 로 붙는 데 씀)
      ansible.builtin.command: ssh-keygen -q -t rsa -b 4096 -N '' -f /root/.ssh/id_rsa
      args:
        creates: /root/.ssh/id_rsa
    - name: root 공개키
      ansible.builtin.slurp:
        src: /root/.ssh/id_rsa.pub
      register: root_pubkey

# 클러스터가 아직 없으면 cluster_bootstrap_node 에서 만들고, 있으면 과반 쪽 노드(기준 노드가 그중이면 기준 노드)에 합류합니다.
# 특정 노드에 묶지 않아 어느 노드를 다시 설치해도 남은 노드로 다시 붙습니다(옛 기록은 scripts/pve-node-rebuild.sh 가 먼저 지움).
- name: 클러스터 만들기
  hosts: proxmox
  gather_facts: false
  any_errors_fatal: true
  tasks:
    - name: 과반 여부 (클러스터에 든 노드만)
      ansible.builtin.command: pvecm status
      register: pvecm
      changed_when: false
      failed_when: false
      check_mode: false   # 읽기만 하므로 --check 에서도 실행
      when: corosync.stat.exists
    - name: 합류 기준 노드 정하기
      ansible.builtin.set_fact:
        cluster_anchor: >-
          {%- set ns = namespace(members=[], quorate=[]) -%}
          {%- for h in ansible_play_hosts -%}
          {%- if hostvars[h].corosync.stat.exists -%}
          {%- set ns.members = ns.members + [h] -%}
          {%- if (hostvars[h].pvecm.stdout | default('')) is search('Quorate:\s+Yes') -%}{%- set ns.quorate = ns.quorate + [h] -%}{%- endif -%}
          {%- endif -%}
          {%- endfor -%}
          {%- if not ns.members -%}{{ cluster_bootstrap_node }}
          {%- elif proxmox_node in ns.quorate -%}{{ proxmox_node }}
          {%- else -%}{{ ns.quorate | first | default('') }}{%- endif -%}
      run_once: true
    - name: 과반 쪽 노드가 없으면 멈춤
      ansible.builtin.assert:
        that: cluster_anchor | length > 0
        fail_msg: 클러스터에 든 노드는 있는데 과반(Quorate)인 노드가 없습니다. 남은 노드에서 pvecm status 를 확인합니다.
      run_once: true
    - name: 클러스터 만들기 (클러스터가 아직 없을 때만, cluster_bootstrap_node 에서)
      ansible.builtin.command: pvecm create {{ pve_cluster_name }} --link0 {{ ansible_host }}
      args:
        creates: /etc/pve/corosync.conf
      when: inventory_hostname == cluster_anchor and not corosync.stat.exists
    - name: 합류할 노드의 root 키 허용 (pvecm add --use_ssh 용, 기준 노드에서)
      ansible.posix.authorized_key:
        user: root
        key: "{{ hostvars[item].root_pubkey.content | b64decode }}"
        comment: "{{ item }}"
      loop: "{{ ansible_play_hosts | difference([cluster_anchor]) }}"
      when: inventory_hostname == cluster_anchor and not hostvars[item].corosync.stat.exists

- name: 클러스터 합류
  hosts: proxmox
  gather_facts: false
  serial: 1
  vars:
    anchor_ip: "{{ hostvars[cluster_anchor].ansible_host }}"
  tasks:
    - name: 기준 노드에 클러스터가 있는지
      ansible.builtin.stat:
        path: /etc/pve/corosync.conf
      delegate_to: "{{ cluster_anchor }}"
      register: anchor_corosync
      failed_when: not anchor_corosync.stat.exists
    - name: 합류 여부
      ansible.builtin.stat:
        path: /etc/pve/corosync.conf
      register: corosync
    - name: 합류
      when: not corosync.stat.exists
      block:
        # 네트워크로 받지 않고(ssh-keyscan) 기준 노드에서 직접 읽은 키를 넣습니다. 합류(pvecm add --use_ssh)가 이 키로 기준 노드를 검증합니다
        - name: 기준 노드 호스트 키 읽기
          ansible.builtin.slurp:
            src: /etc/ssh/ssh_host_ed25519_key.pub
          delegate_to: "{{ cluster_anchor }}"
          register: anchor_host_key
        - name: 기준 노드 호스트 키 등록
          ansible.builtin.known_hosts:
            path: /root/.ssh/known_hosts
            name: "{{ anchor_ip }}"
            key: "{{ anchor_ip }} {{ (anchor_host_key.content | b64decode).split()[:2] | join(' ') }}"
        - name: 합류 (게스트가 없는 노드만 가능)
          ansible.builtin.command: pvecm add {{ anchor_ip }} --link0 {{ ansible_host }} --use_ssh
          register: join
          failed_when: "'successfully added node' not in join.stdout"   # 실패해도 종료 코드 0 으로 끝나는 경우가 있어 출력으로 판단합니다
        # 같은 이름으로 다시 들어온 노드는 옛 인증서·호스트 키 기록과 새 것이 섞이지 않게 클러스터 전체 인증서 목록을 다시 만듭니다
        - name: 인증서·호스트 키 목록 갱신
          ansible.builtin.command: pvecm updatecerts

# 여기부터 클러스터 전체 작업은 살아 있는 과반 쪽 기준 노드에서 합니다
- import_playbook: main-node.yml

# 원격지(서울 NAS)의 QDevice 에 닿기 위한 사설망. 인증 키는 실행 PC 의 파일에서 읽어 명령에만 넘깁니다(로그에 남기지 않음)
# 지금은 QDevice·원격 etcd 투표자가 Tailscale 주소라 필수 경로입니다. 한 노드라도 실패하면 멈추고, 다시 실행하면 이어 갑니다
- name: Tailscale
  hosts: proxmox
  gather_facts: false
  any_errors_fatal: true
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
      when: (ts_status.stdout | default('{}') | from_json).BackendState | default('') != 'Running'
      block:
        - name: 인증 키 파일이 있는지
          ansible.builtin.stat:
            path: "{{ tailscale_authkey_file }}"
          delegate_to: localhost
          register: ts_key
        - name: 인증 키가 없으면 멈춤
          ansible.builtin.fail:
            msg: "Tailscale 인증 키가 없습니다. 재사용 키(tag:homelab)를 {{ tailscale_authkey_file }} (600)에 넣고 다시 실행합니다."
          when: not ts_key.stat.exists
        - name: tailscale up
          ansible.builtin.command: >-
            tailscale up --auth-key={{ lookup('ansible.builtin.file', tailscale_authkey_file) }}
            --hostname={{ inventory_hostname }} --accept-dns=false --accept-routes=false --timeout=60s
          no_log: true
      rescue:
        - name: 로그인 실패
          ansible.builtin.fail:
            msg: >-
              {{ inventory_hostname }} 의 Tailscale 로그인에 실패했습니다. 인증 키가 만료·폐기됐으면 새 재사용 키(tag:homelab)를
              {{ tailscale_authkey_file }} 에 넣고 같은 명령을 다시 실행합니다(출력은 키가 들어 있어 숨김).
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
    # 경로 검사는 경고만 냅니다. 다른 노드가 살아 있으면 그쪽 경로로 동작하기 때문입니다
    - name: tailnet 상태
      ansible.builtin.command: tailscale status --json
      register: ts_now
      changed_when: false
    - name: 장치 이름·경로 승인 경고
      ansible.builtin.debug:
        msg: "{{ item.msg }}"
      when: item.when
      loop:
        - when: "{{ ts_self.DNSName.split('.')[0] != inventory_hostname }}"
          msg: >-
            [경고] tailnet 장치 이름이 {{ ts_self.DNSName.split('.')[0] }} 입니다. 같은 이름의 옛 장치({{ inventory_hostname }})가 남아 있으면
            Tailscale 관리 화면에서 옛 장치를 지우고 이 장치 이름을 {{ inventory_hostname }} 으로 바꿉니다.
        - when: "{{ tailscale_lan_cidr not in ts_self.AllowedIPs | default([]) }}"
          msg: >-
            [경고] 광고한 경로 {{ tailscale_lan_cidr }} 가 아직 승인되지 않았습니다(Tailscale 관리 화면 → 이 장치 → Subnet routes).
            다른 노드의 경로가 승인돼 있는 동안은 그쪽으로 동작합니다.
      loop_control: { label: "{{ item.msg[:40] }}" }
      vars:
        ts_self: "{{ (ts_now.stdout | from_json).Self }}"
    - name: qnetd(5403/tcp)에 닿는지
      ansible.builtin.shell: timeout 5 bash -c '</dev/tcp/{{ pve_qdevice_host }}/5403'
      register: qnetd_port
      changed_when: false
      failed_when: false
      when: pve_qdevice_host | length > 0
    - name: qnetd 경고
      ansible.builtin.debug:
        msg: "[경고] {{ inventory_hostname }} 에서 qnetd {{ pve_qdevice_host }}:5403 에 닿지 않습니다. 서울 NAS 의 Tailscale·qnetd 컨테이너를 확인합니다."
      when: pve_qdevice_host | length > 0 and qnetd_port.rc != 0

# 두 노드 클러스터의 세 번째 표. 한 노드가 꺼져도 남은 노드 + QDevice 로 과반을 유지합니다.
# pvecm qdevice setup 은 설정이 이미 있으면 거부하고, qdevice remove 는 모든 노드가 online 이어야 하므로 상태에 따라 나눕니다.
#   설정 없음 → setup / 있고 모든 노드에서 corosync-qdevice 가 돎 → 그대로 / 있는데 어느 노드에서 안 돎 → 모두 online 이면 remove 뒤 setup,
#   offline 노드가 있으면 멈춤(같은 이름 노드를 다시 넣을 때는 scripts/pve-node-rebuild.sh 가 미리 remove 해 둡니다)
# pve_qdevice_host 가 비면 QDevice 를 두지 않습니다: 설정이 있고 모든 노드가 online 이면 remove, offline 노드가 있으면 경고만 냅니다.
- name: QDevice
  hosts: proxmox
  gather_facts: false
  any_errors_fatal: true
  vars:
    primary: "{{ proxmox_node }}"
  tasks:
    - name: corosync-qdevice
      ansible.builtin.apt:
        name: corosync-qdevice
    - name: qnetd 컨테이너의 ssh 포트 (pvecm qdevice setup 의 ssh·scp 가 씀. QDevice 를 안 두면 블록을 지움)
      ansible.builtin.blockinfile:
        path: /root/.ssh/config
        create: true
        mode: "0600"
        marker: "# {mark} pve-cluster.yml: QDevice"
        state: "{{ 'present' if pve_qdevice_host | length > 0 else 'absent' }}"
        block: |
          Host {{ pve_qdevice_host }}
            Port {{ pve_qdevice_ssh_port }}
            User root
            StrictHostKeyChecking accept-new
    - name: 이 노드의 corosync-qdevice
      ansible.builtin.command: systemctl is-active corosync-qdevice
      register: qdevice_active
      changed_when: false
      failed_when: false
    - name: QDevice 설정 여부와 노드 online 상태
      ansible.builtin.shell: |
        grep -q 'model:\s*net' /etc/pve/corosync.conf && echo conf=yes || echo conf=no
        cat /etc/pve/.members
      register: qdevice_state
      changed_when: false
      when: inventory_hostname == primary
    - name: 할 일 정하기
      ansible.builtin.set_fact:
        qdevice_action: >-
          {%- set conf = 'conf=yes' in qdevice_state.stdout_lines -%}
          {%- set members = (qdevice_state.stdout_lines[1:] | join('\n') | from_json).nodelist -%}
          {%- set all_online = members.values() | map(attribute='online') | min == 1 -%}
          {%- set all_active = ansible_play_hosts_all | map('extract', hostvars, ['qdevice_active', 'stdout']) | unique | list == ['active'] -%}
          {%- if pve_qdevice_host | length == 0 -%}{{ ('remove' if all_online else 'remove-blocked') if conf else 'none' }}
          {%- elif not conf -%}setup
          {%- elif all_active -%}keep
          {%- elif all_online -%}reset
          {%- else -%}blocked{%- endif -%}
      when: inventory_hostname == primary
    - name: offline 노드가 있으면 멈춤
      ansible.builtin.fail:
        msg: >-
          QDevice 설정은 있는데 corosync-qdevice 가 돌지 않는 노드가 있고, offline 노드가 있어 qdevice remove 를 할 수 없습니다.
          같은 이름의 노드를 다시 설치했으면 남은 노드에서 scripts/pve-node-rebuild.sh 를 먼저 실행합니다.
      when: inventory_hostname == primary and qdevice_action == 'blocked'
    # remove 하기 전에 setup 이 될지(qnetd 에 ssh) 먼저 봅니다. 닿지 않는데 지우면 세 번째 표를 잃은 채로 끝납니다
    - name: qnetd 에 ssh 가 되는지 (setup 하는 노드에서만)
      ansible.builtin.command: ssh -o BatchMode=yes -o ConnectTimeout=10 {{ pve_qdevice_host }} corosync-qnetd-tool -s
      changed_when: false
      when: inventory_hostname == primary and qdevice_action in ['setup', 'reset']
    - name: QDevice 다시 설정하기 전에 지우기 (또는 QDevice 를 안 두게 되어 지우기)
      ansible.builtin.command: pvecm qdevice remove
      when: inventory_hostname == primary and qdevice_action in ['reset', 'remove']
    - name: 지울 QDevice 가 남음 경고
      ansible.builtin.debug:
        msg: "[경고] pve_qdevice_host 가 비었는데 QDevice 설정이 남아 있고, offline 노드가 있어 지금은 지울 수 없습니다. 모든 노드가 online 일 때 다시 실행합니다."
      when: inventory_hostname == primary and qdevice_action == 'remove-blocked'
    - name: QDevice 연결 (모든 노드가 온라인이어야 함)
      ansible.builtin.command: pvecm qdevice setup {{ pve_qdevice_host }}
      when: inventory_hostname == primary and qdevice_action in ['setup', 'reset']

- name: 확인
  hosts: pve_main
  gather_facts: false
  tasks:
    - name: 클러스터 상태
      ansible.builtin.command: pvecm status
      register: status
      changed_when: false
    - name: 모든 노드가 들어왔고 과반인지 (QDevice 는 pve_qdevice_host 가 있을 때만 있어야 하고, 비면 없어야 함)
      ansible.builtin.assert:
        that:
          - "'Quorate:          Yes' in status.stdout"
          - "status.stdout is search('Nodes:\\s+' ~ (groups.proxmox | length) ~ '\\s')"
          # 설정된 표(votes N)로 봅니다. qdevice remove 뒤에도 corosync 를 다시 띄울 때까지 'Qdevice (votes 0)' 줄이 남습니다
          - "(status.stdout is search('Qdevice \\(votes [1-9]')) == (pve_qdevice_host | length > 0)"
        fail_msg: "{{ status.stdout }}"
    - name: 상태
      ansible.builtin.debug:
        msg: "{{ status.stdout_lines }}"
    # 설정은 있어도 qnetd 에 닿지 않으면 표가 0 입니다. 이 상태에서 노드 하나가 꺼지면 과반을 잃습니다
    - name: QDevice 표 경고
      ansible.builtin.debug:
        msg: "[경고] QDevice 가 표를 내지 않습니다(qnetd {{ pve_qdevice_host }} 연결 확인). 지금 노드 하나가 꺼지면 과반을 잃습니다."
      when: pve_qdevice_host | length > 0 and status.stdout is search('0x00000000\\s+0\\s+Qdevice')

# 모든 노드가 다른 노드를 복구할 수 있게(저장소·ansible·토큰·키). 복구로 새로 들어온 노드도 여기서 같이 준비됩니다
- import_playbook: pve-controller.yml
```
{: file="playbooks/pve-cluster.yml" }
{% endraw %}

</details>

`main-node.yml` 은 클러스터 전체 작업(저장소 등록, 확인, QDevice 등)을 할 기준 노드를 고르는 플레이입니다. 특정 노드에 묶지 않아 어느 노드가 죽어도 남은 노드로 플레이북이 돕니다. `pve-cluster.yml` 을 비롯한 다른 플레이북이 `import_playbook` 으로 불러 쓰고, 고른 노드는 그룹 `pve_main` 과 변수 `proxmox_node` 가 됩니다. 고르는 순서는 다음과 같습니다.

1. 환경 변수 `PVE_MAIN` 이 있으면 그 노드
2. 없으면 플레이북을 실행하는 노드(노드에서 직접 돌릴 때)
3. 그것도 아니면(다른 PC) 인벤토리 순서에서 처음으로 과반 쪽(`Quorate: Yes`)인 노드

고른 노드가 과반 쪽이 아니거나 닿지 않으면 멈춥니다. 다른 노드를 쓰려면 `PVE_MAIN=<노드>` 로 실행합니다. 이 플레이북만 실행하면 고른 노드를 보여 줍니다.

```bash
ansible-playbook playbooks/main-node.yml
```

<details markdown="1">
<summary>playbooks/main-node.yml 전문</summary>

{% raw %}
```yaml
# 클러스터 전체 작업(저장소 등록, 확인, QDevice 등)을 할 기준 노드를 고릅니다. 특정 노드에 묶지 않아 어느 노드가 죽어도
# 남은 노드로 플레이북이 돕니다. 다른 플레이북이 맨 앞에서 import 하고, 고른 노드는 그룹 pve_main 과 변수 proxmox_node 가 됩니다.
#   - 환경 변수 PVE_MAIN 이 있으면 그 노드
#   - 없으면 플레이북을 실행하는 노드(노드에서 직접 돌릴 때, scripts/pve-node-rebuild.sh 등)
#   - 그것도 아니면(다른 PC) inventory 순서에서 처음으로 과반 쪽(Quorate: Yes)인 노드
# 고른 노드가 과반 쪽이 아니면 멈춥니다. 직접 실행하면 고른 노드만 보여 줍니다: ansible-playbook playbooks/main-node.yml
---
- name: 기준 노드 고르기
  hosts: localhost
  gather_facts: false
  vars:
    pinned: "{{ lookup('ansible.builtin.env', 'PVE_MAIN') or (groups.proxmox | select('eq', lookup('ansible.builtin.pipe', 'hostname -s')) | first | default('')) }}"
  tasks:
    - name: 노드마다 과반 쪽인지
      ansible.builtin.command: pvecm status
      delegate_to: "{{ item }}"
      loop: "{{ [pinned] if pinned else groups.proxmox }}"
      register: quorum
      changed_when: false
      failed_when: false
      ignore_unreachable: true
      check_mode: false   # 읽기만 하므로 --check 에서도 실행
    - name: 고르기
      ansible.builtin.set_fact:
        pve_main: >-
          {{ quorum.results | rejectattr('unreachable', 'defined') | selectattr('stdout', 'defined')
             | selectattr('stdout', 'search', 'Quorate:\s+Yes') | map(attribute='item') | first | default('') }}
    - name: 과반 쪽 노드가 없으면 멈춤
      ansible.builtin.assert:
        that: pve_main | length > 0
        fail_msg: >-
          {{ (pinned ~ ' 이 과반 쪽이 아니거나 닿지 않습니다') if pinned else '과반 쪽인 노드가 없습니다' }}.
          다른 노드를 쓰려면 PVE_MAIN=<노드> 로 실행합니다.
    - name: 그룹 pve_main
      ansible.builtin.add_host:
        name: "{{ pve_main }}"
        groups: [pve_main]
      changed_when: false
    - name: 기준 노드
      ansible.builtin.debug:
        msg: "기준 노드 {{ pve_main }}{{ ' (PVE_MAIN·실행 노드)' if pinned else '' }}"
```
{: file="playbooks/main-node.yml" }
{% endraw %}

</details>

플레이북은 재부팅 스크립트를 각 노드의 `/usr/local/sbin/pve-reboot.sh` 에 둡니다. 호스트를 재부팅하거나 하드웨어 작업으로 끌 때는 일반 `reboot`·`poweroff` 대신 이 스크립트를 씁니다. 게스트를 두 차례로 먼저 내리고(나머지 게스트를 모두 내린 뒤 NAS VM 을 마지막에), 내려가지 않는 게스트가 있으면 sysrq 로 즉시 재부팅하거나 끕니다. NAS 를 먼저 내리면 그 NFS 저장소에 디스크를 둔 VM 이 I/O 에서 굳기 때문입니다. 마지막에 내릴 게스트는 플레이북이 `xpenology` 변수로 배포하는 `/etc/default/pve-reboot` 의 `LAST_VMIDS` 이고, 실행할 때 `--last <vmid>` 로 더할 수 있습니다. NAS 가 있는 노드를 재부팅하면 다른 노드에서 그 NFS 저장소를 쓰는 VM 도 그동안 디스크 I/O 가 멈추므로, 그런 VM 은 미리 내리거나 멈춤을 감수합니다.

게스트를 내리기 전에 그 호스트에 있는 쿠버네티스 노드를 drain 합니다. 노드가 갑자기 꺼지면 StatefulSet 파드는 Terminating 으로 묶여 다른 노드로 넘어가지 못하기 때문입니다. 스크립트는 다른 호스트의 control plane 에 ssh 해서 kubectl 을 돌립니다. 어느 노드를 drain 하고 어느 control plane 에 붙을지는 플레이북이 `k8s_clusters` 변수로 만든 `/etc/default/pve-reboot` 의 `K8S_DRAIN`·`K8S_KUBECTL` 입니다. 순서는 이렇습니다.

1. 그 노드에 Patroni 주 DB(네임스페이스 `timescaledb` 의 `role=primary` 파드)가 있으면 drain 하지 않는 멤버로 switchover 하고, 새 주 DB 가 될 때까지 기다립니다.
2. `kubectl drain --ignore-daemonsets --delete-emptydir-data --timeout=300s` 로 노드를 비웁니다. 실패하면 cordon 을 되돌리고 재부팅하지 않고 끝냅니다.
3. drain 한 노드를 `/var/lib/pve-reboot/drained` 에 적어 둡니다. 부팅 뒤 `pve-k8s-return.service`(`pve-reboot.sh --return`)가 노드가 Ready 가 되면 uncordon 하고, 노드마다 하나씩 두는 CoreDNS 의 수를 다시 맞춥니다.
4. Proxmox HA 에 등록한 게스트는 끄지 않고, 메모리가 가장 많이 남은 노드로 `ha-manager crm-command migrate` 합니다. 이때 keep-apart 규칙(HA resource-affinity negative)으로 떨어뜨려 둔 상대 게스트가 started 로 있는 노드와, 같은 차례에 상대에게 고른 노드는 대상에서 뺍니다. maintenance 모드는 풀 때 게스트가 원래 노드로 되돌아가므로 쓰지 않습니다.
5. Ceph 가 있으면 게스트를 내리기 전에 `ceph osd set noout` 으로 이 노드의 OSD 가 빠진 동안 다른 OSD 로 다시 복제하지 않게 하고, 부팅 뒤 `--return` 이 노드 복귀를 기다린 다음 noout 을 끕니다. pve03 은 iSCSI VG 를 끄기 전에 그 VG 위의 Ceph OSD 를 먼저 멈춥니다.

장애 시험처럼 노드가 갑자기 사라진 상황을 만들 때는 `--no-drain` 으로 이 단계를 건너뜁니다.

```bash
# 판정만 보기
/usr/local/sbin/pve-reboot.sh --dry-run

# 재부팅(실행 중 세션이 끊기므로 systemd-run 으로 띄움). 끌 때는 --poweroff
systemd-run --unit pve-reboot --collect /usr/local/sbin/pve-reboot.sh
journalctl -fu pve-reboot
```

- **확인:** `--dry-run` 이 넘길 주 DB, drain 으로 옮길 파드(서버 dry-run), 옮길 HA 게스트, 내릴 게스트 목록과 재부팅 경로(일반 또는 sysrq)를 출력합니다. dry-run 은 볼륨을 떼지 않으므로 Longhorn 볼륨이 붙은 노드는 instance-manager 의 PodDisruptionBudget 에서 15초 뒤 멈춘 것으로 나옵니다. 실제 drain 에서는 볼륨이 떨어지면 Longhorn 이 그 PDB 를 풉니다.

<details markdown="1">
<summary>scripts/pve-reboot.sh 전문</summary>

```bash
#!/usr/bin/env bash
#
# 이 Proxmox 노드를 재부팅하거나 끕니다(--poweroff). 게스트를 먼저 내리고, 내려가지 않는 게스트나 커널에서 굳은(D 상태)
# 작업이 있으면 일반 재부팅·종료 대신 sysrq 로 즉시 재부팅하거나 끕니다.
#
# 왜: 일반 reboot 는 게스트 종료 → 서비스 정지 → 커널의 장치 정리 순서로 가는데, 멈춘 GPU 드라이버(amdgpu 교착)를 쥔
# 프로세스가 있으면 그 CT 는 끝내 내려가지 않고(pve-guests 180초, lxc.service 90초 시간 초과) 마지막 장치 정리에서 커널이
# 굳어 전원이 켜진 채 응답하지 않습니다. BMC 가 없고 watchdog 이 softdog 뿐인 서버는
# 스스로 리셋되지 않아 전원을 뽑아야 합니다. sysrq b 는 장치 정리를 건너뛰고 바로 재부팅합니다. 게스트는 이미 내렸으므로 잃는 것은
# 내려가지 않던 게스트뿐입니다. 메모리 증설 같은 하드웨어 작업으로 끌 때(--poweroff)도 같은 이유로 sysrq o 를 씁니다.
# sysrq o 는 커널이 전원 끄기를 지원할 때만 실제로 끕니다. 꺼졌는지는 접속 단절이 아니라 전력(스마트 플러그)이나 현장에서
# 확인합니다.
#
# 게스트는 두 차례로 내립니다. 먼저 나머지 게스트를 모두 내리고, 그다음에 NAS(헤놀로지) 같은 마지막 게스트를 내립니다.
# NAS 를 먼저 내리면 그 NFS 저장소(nas)에 디스크를 둔 VM 이 I/O 에서 굳습니다. 마지막 게스트는 --last 또는
# /etc/default/pve-reboot 의 LAST_VMIDS(pve-cluster.yml 이 group_vars 의 xpenology.vmid 로 배포)로 정합니다.
# pve03 을 재부팅하면 NAS 가 멈추므로 다른 노드에서 nas 저장소를 쓰는 VM(docker VM 206 등)도 그동안 디스크 I/O 가 멈춥니다.
# pve03 의 worker-3 은 이 스크립트가 NAS 보다 먼저 내리고, 그 디스크가 있는 iSCSI VG(/etc/default/nas-iscsi)의 Ceph OSD 를 멈추고 VG 를 끄고 로그아웃한 뒤 NAS 를
# 내립니다. 다른 노드의 nas VM 은 미리 내리거나 멈춤을 감수합니다.
#
# 게스트를 내리기 전에 이 호스트에 있는 쿠버네티스 노드를 drain 합니다. 그 노드에 Patroni 주 DB(namespace timescaledb,
# 라벨 role=primary)가 있으면 먼저 다른 멤버로 switchover 합니다. drain 은 다른 호스트의 control plane 에 ssh 해서 하고
# (pve-node-rebuild.sh 와 같은 방식), 실패하면 cordon 을 풀고 중단합니다. drain 한 노드는 /var/lib/pve-reboot/drained 에
# 적고, 부팅 뒤 pve-k8s-return.service(이 스크립트의 --return)가 노드가 Ready 가 되면 uncordon 하고 CoreDNS 수를 다시
# 맞춥니다. 어느 노드를 drain 하고 어느 control plane 에 붙을지는 /etc/default/pve-reboot 의 K8S_DRAIN·K8S_KUBECTL 입니다.
# Proxmox HA 게스트는 끄지 않고 다른 노드로 옮깁니다(ha-manager crm-command migrate). 대상은 keep-apart(HA resource-affinity
# negative) 상대가 있는 노드를 뺀 것 중 메모리가 가장 많이 남은
# 온라인 노드입니다. maintenance 모드는 풀 때 원래 노드로 되돌아가므로 쓰지 않습니다. 모두 옮겨지지 않으면(300초) 중단합니다.
#
# 사용법(호스트에서 root). 실행 중에 이 호스트의 게스트(ssh 를 건너온 CT 포함)가 내려가 세션이 끊기므로 systemd-run 으로 띄웁니다:
#   systemd-run --unit pve-reboot --collect /usr/local/sbin/pve-reboot.sh [옵션]; journalctl -fu pve-reboot
# 옵션:
#   --dry-run          무엇을 내리고 어느 경로로 재부팅(종료)할지와 sysrq 를 쓸 수 있는지만 출력
#   --poweroff         재부팅 대신 전원을 끔(하드웨어 작업용). BMC 가 없으면 다시 켜는 것은 사람이 함
#   --force-sysrq      판정과 무관하게 sysrq 로 재부팅(종료)
#   --skip <vmid>      내리지 않을 게스트(여러 번 줄 수 있음). 그 게스트는 재부팅과 함께 끊깁니다
#   --last <vmid>      다른 게스트를 모두 내린 뒤 마지막에 내릴 게스트(여러 번 줄 수 있음, LAST_VMIDS 에 더함)
#   --vm-timeout <초>  VM 종료 대기(기본 180)
#   --ct-timeout <초>  CT 종료 대기(기본 60)
#   --no-drain         drain·switchover·HA 이전을 하지 않음(장애 시험용: 노드가 갑자기 사라진 것과 같게)
#   --return           부팅 뒤 할 일만 함: drained 표식의 노드가 Ready 가 되면 uncordon, CoreDNS 수 맞추기, Ceph noout 끄기(pve-k8s-return.service)
# 종료 코드: 0 재부팅·종료 시작(또는 dry-run, --return 완료), 1 쿼럼 없음·drain 실패 등으로 중단, 2 인자 오류
set -uo pipefail

DRY_RUN=0 FORCE_SYSRQ=0 POWEROFF=0 VM_TIMEOUT=180 CT_TIMEOUT=60 DRAIN=1 RETURN=0
DRAIN_TIMEOUT=300 HA_TIMEOUT=300 RETURN_TIMEOUT=1800 MARK=/var/lib/pve-reboot/drained
declare -A SKIP=() LAST=() HA_ID=()
# 노드별 기본값(pve-cluster.yml 이 배포). LAST_VMIDS="205" 처럼 공백으로 나눕니다.
# K8S_DRAIN="hub:k8s-hub-cp-1,k8s-hub-worker-1 daejeon:…"(이 호스트의 노드), K8S_KUBECTL="hub:[CP1_IP],[CP2_IP] …"
# (다른 호스트의 control plane, 앞에서부터 붙는 곳을 씀)
K8S_DRAIN=${K8S_DRAIN:-} K8S_KUBECTL=${K8S_KUBECTL:-} PATRONI_NS=${PATRONI_NS:-timescaledb}
[ -r /etc/default/pve-reboot ] && . /etc/default/pve-reboot
for id in ${LAST_VMIDS:-}; do LAST[$id]=1; done
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force-sysrq) FORCE_SYSRQ=1 ;;
    --poweroff) POWEROFF=1 ;;
    --skip) SKIP[$2]=1; shift ;;
    --last) LAST[$2]=1; shift ;;
    --vm-timeout) VM_TIMEOUT=$2; shift ;;
    --ct-timeout) CT_TIMEOUT=$2; shift ;;
    --no-drain) DRAIN=0 ;;
    --return) RETURN=1 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[$(date +%T)] $*"; }
run() { if [ "$DRY_RUN" = 1 ]; then log "(dry-run) $*"; else "$@"; fi; }

# ---- 쿠버네티스: 클러스터마다 다른 호스트의 control plane 에 ssh 해서 kubectl ----
SSH=(ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)   # -n: 읽는 중인 표식 파일을 ssh 가 먹지 않게
declare -A KC_HOST=()
kc_host() {   # $1 클러스터 → KC_HOST[$1] 에 붙는 control plane IP(앞에서부터, 처음 찾은 것을 기억)
  local c=$1 e ip
  [ -n "${KC_HOST[$c]:-}" ] && return 0
  for e in $K8S_KUBECTL; do
    [ "${e%%:*}" = "$c" ] || continue
    for ip in $(tr , ' ' <<< "${e#*:}"); do
      if "${SSH[@]}" "ubuntu@$ip" true 2>/dev/null; then KC_HOST[$c]=$ip; return 0; fi
    done
  done
  return 1
}
kc() {   # $1 클러스터, 나머지 kubectl 인자
  local c=$1; shift
  kc_host "$c" || { log "[$c] 붙을 control plane 이 없음(K8S_KUBECTL=$K8S_KUBECTL)"; return 1; }
  "${SSH[@]}" "ubuntu@${KC_HOST[$c]}" "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf $(printf '%q ' "$@")"
}
# 이 호스트의 노드를 "클러스터 노드" 줄로
drain_targets() { local e n; for e in $K8S_DRAIN; do for n in $(tr , ' ' <<< "${e#*:}"); do echo "${e%%:*} $n"; done; done; }
# 받을 수 있는(cordon 안 된) 노드 수만큼 CoreDNS 를 둡니다(k8s-cluster.yml --tags dns 와 같은 결과. 노드마다 하나라 cordon 한
# 노드 몫이 남으면 Pending 으로 남음)
coredns_fit() {
  local c=$1 n
  n=$(kc "$c" get nodes -o 'jsonpath={range .items[*]}{.spec.unschedulable}{"\n"}{end}' | grep -vc true) || return 1
  # dry-run 은 cordon 하지 않으므로 drain 했을 때의 수로 보여 줌
  [ "$DRY_RUN" = 1 ] && [ "$RETURN" = 0 ] && n=$((n - $(drain_targets | awk -v c="$c" '$1==c' | wc -l)))
  log "[$c] CoreDNS replicas → $n"
  run kc "$c" -n kube-system scale deployment/coredns --replicas="$n" >/dev/null
}

# ---- 부팅 뒤(--return): 표식의 노드가 Ready 가 되면 uncordon ----
# 재부팅 전에 켠 Ceph noout 을 끈다. 노드 복귀를 기다린 뒤에 부른다(pve03 은 그사이 nas-iscsi-start 가 OSD 를 켬)
unset_noout() {
  if [ -f /etc/pve/ceph.conf ] && command -v ceph >/dev/null && ceph osd dump 2>/dev/null | grep -q '^flags.*noout'; then
    log "Ceph noout 끄기"; run ceph osd unset noout >/dev/null 2>&1 || log "noout 을 끄지 못함(ceph osd unset noout)"
  fi
}
if [ "$RETURN" = 1 ]; then
  [ -s "$MARK" ] || { log "drain 표식이 없어 할 일이 없습니다"; unset_noout; exit 0; }
  deadline=$((SECONDS + RETURN_TIMEOUT)) left=1
  while [ "$left" = 1 ] && [ $SECONDS -lt $deadline ]; do
    left=0
    for c in $(awk '{print $1}' "$MARK" | sort -u); do kc_host "$c" || true; done   # 붙을 곳을 여기서 기억(아래는 하위 셸)
    while read -r c n; do
      [ -n "$n" ] || continue
      ready=$(kc "$c" get node "$n" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      if [ "$ready" = True ]; then
        log "[$c] $n Ready → uncordon"
        if run kc "$c" uncordon "$n" >/dev/null; then
          [ "$DRY_RUN" = 0 ] && sed -i "/^$c $n\$/d" "$MARK"
          echo "$c" >> "$MARK.dns"
        else left=1; fi
      else left=1; fi
    done < <(cat "$MARK")
    [ "$left" = 1 ] && sleep 15
  done
  for c in $(sort -u "$MARK.dns" 2>/dev/null); do coredns_fit "$c" || left=1; done
  rm -f "$MARK.dns"
  unset_noout
  if [ "$left" = 1 ]; then log "Ready 가 되지 않았거나 uncordon 하지 못한 노드: $(tr '\n' ' ' < "$MARK")"; exit 1; fi
  log "모든 노드 uncordon 완료"; exit 0
fi

# 1) 쿼럼. 클러스터 노드인데 과반이 없으면 다른 노드가 이 노드의 재부팅을 버티지 못한다
if [ -e /etc/pve/corosync.conf ]; then
  if ! pvecm status 2>/dev/null | grep -qE '^Quorate:\s+Yes'; then
    log "클러스터 쿼럼이 없어 중단합니다(pvecm status 확인)"; exit 1
  fi
  log "쿼럼 정상"
fi

# 2) 쿠버네티스 노드 drain(--no-drain 이 아니면). 주 DB 가 이 호스트의 노드에 있으면 먼저 넘긴다
if [ "$DRAIN" = 1 ] && [ -n "$K8S_DRAIN" ]; then
  mapfile -t targets < <(drain_targets)
  declare -A MINE=()
  for t in "${targets[@]}"; do MINE[$t]=1; done
  for c in $(drain_targets | awk '{print $1}' | sort -u); do
    kc_host "$c" || { log "[$c] 붙을 control plane 이 없어 중단합니다(--no-drain 으로 건너뛸 수 있음)"; exit 1; }
    # Patroni: role=primary 파드의 노드가 이번에 drain 할 노드면 switchover(후보는 drain 하지 않는 멤버)
    pods=$(kc "$c" -n "$PATRONI_NS" get pods -l role -o 'jsonpath={range .items[*]}{.metadata.name} {.spec.nodeName} {.metadata.labels.role}{"\n"}{end}' 2>/dev/null)
    leader=$(awk '$3=="primary"{print $1" "$2}' <<< "$pods")
    if [ -n "$leader" ] && [ -n "${MINE[$c ${leader#* }]:-}" ]; then
      cand=$(awk -v n="${leader#* }" '$3!="primary" && $2!=n {print $1}' <<< "$pods" | while read -r p; do
        node=$(awk -v p="$p" '$1==p{print $2}' <<< "$pods"); [ -z "${MINE[$c $node]:-}" ] && echo "$p"; done | head -1)
      [ -n "$cand" ] || { log "[$c] 주 DB ${leader% *} 를 넘길 멤버가 없어 중단합니다"; exit 1; }
      log "[$c] 주 DB ${leader% *}(${leader#* }) → $cand switchover"
      if [ "$DRY_RUN" = 0 ]; then
        kc "$c" -n "$PATRONI_NS" exec "${leader% *}" -- patronictl -c /etc/patroni/patroni.yml switchover \
          --leader "${leader% *}" --candidate "$cand" --force || { log "[$c] switchover 실패, 중단합니다"; exit 1; }
        ok=0
        for _ in $(seq 24); do
          [ "$(kc "$c" -n "$PATRONI_NS" get pod "$cand" -o 'jsonpath={.metadata.labels.role}')" = primary ] && { ok=1; break; }
          sleep 5
        done
        [ "$ok" = 1 ] || { log "[$c] 120초 안에 $cand 가 주 DB 가 되지 않아 중단합니다"; exit 1; }
        log "[$c] 주 DB: $cand"
      fi
    fi
  done
  [ "$DRY_RUN" = 0 ] && mkdir -p "$(dirname "$MARK")"
  for t in "${targets[@]}"; do
    c=${t% *} n=${t#* }
    log "[$c] $n drain(최대 ${DRAIN_TIMEOUT}초)"
    if [ "$DRY_RUN" = 1 ]; then
      # dry-run 은 볼륨을 떼지 않으므로 Longhorn instance-manager 의 PDB 가 끝까지 막습니다. 실제 drain 에서는 다른 파드가
      # 빠져 볼륨이 떨어지면 Longhorn 이 PDB 를 풉니다(그 노드에 마지막 복제본이 있으면 계속 막아 drain 이 실패하고 중단)
      kc "$c" drain "$n" --ignore-daemonsets --delete-emptydir-data --dry-run=server --timeout=15s 2>&1 \
        | grep -v 'will retry after' | sed 's/^/    /'
      continue
    fi
    grep -qx "$t" "$MARK" 2>/dev/null || echo "$t" >> "$MARK"   # cordon 전에 적어 둠(중간에 끊겨도 부팅 뒤 uncordon)
    if ! kc "$c" drain "$n" --ignore-daemonsets --delete-emptydir-data --timeout="${DRAIN_TIMEOUT}s" 2>&1 | sed 's/^/    /'; then
      log "[$c] $n drain 실패. 이번에 cordon 한 노드를 되돌리고 중단합니다"
      while read -r c2 n2; do kc "$c2" uncordon "$n2" >/dev/null && sed -i "/^$c2 $n2\$/d" "$MARK"; done < <(cat "$MARK")
      exit 1
    fi
  done
  for c in $(drain_targets | awk '{print $1}' | sort -u); do coredns_fit "$c" || log "[$c] CoreDNS 수를 맞추지 못함(계속)"; done
fi

# 3) Proxmox HA 게스트는 다른 노드로 옮긴다(--no-drain 이 아니면). 이 노드의 게스트를 내리는 루프는 HA 게스트를 건너뛴다
SELF=$(hostname -s)
for sid in $(ha-manager config 2>/dev/null | awk '/^(vm|ct):/{print $1 $2}'); do HA_ID[${sid#*:}]=1; done
# 이 노드에서 켜져 있는(started) HA 서비스. 멈춰 둔 HA 서비스는 옮기지 않음(started 가 되지 않아 기다림이 끝나지 않음)
ha_here() { ha-manager status 2>/dev/null | awk -v n="$SELF" '$1=="service" && $3=="("n"," && $4=="started)" {print $2}'; }
# keep-apart(resource-affinity negative, 켜진 규칙) 상대 서비스
ha_apart() {
  ha-manager rules config --output-format json 2>/dev/null | jq -r --arg s "$1" '.[]
    | select(.type == "resource-affinity" and .affinity == "negative" and ((.disable // 0) | tostring) != "1" and ((.enabled // 1) | tostring) != "0")
    | (.resources | split(",")) | select(index($s)) | .[] | select(. != $s)' | sort -u
}
# 서비스가 started 로 있는 노드
ha_node_of() { ha-manager status 2>/dev/null | awk -v s="$1" '$1=="service" && $2==s && $4=="started)" {gsub(/[(,]/, "", $3); print $3}'; }
if [ "$DRAIN" = 1 ] && [ ${#HA_ID[@]} -gt 0 ]; then
  sids=$(ha_here)
  if [ -n "$sids" ]; then
    declare -A DEST
    for sid in $sids; do
      # 메모리가 가장 많이 남은 온라인 노드. keep-apart 상대가 started 인 노드와 이번에 상대를 보낼 노드는 뺀다
      excl=$SELF
      for p in $(ha_apart "$sid"); do excl="$excl ${DEST[$p]:-} $(ha_node_of "$p")"; done
      target=$(pvesh get /cluster/resources --type node --output-format json | jq -r --arg x "$excl" \
        '($x | split(" ")) as $ex | [.[] | select(.status=="online" and (.node | IN($ex[]) | not))] | max_by(.maxmem - .mem) | .node // empty')
      [ -n "$target" ] || { log "HA $sid 를 받을 노드가 없어 중단합니다(뺀 노드: $excl)"; exit 1; }
      DEST[$sid]=$target
      log "HA $sid → $target 이전"; run ha-manager crm-command migrate "$sid" "$target"
    done
    if [ "$DRY_RUN" = 0 ]; then
      ok=0
      for _ in $(seq $((HA_TIMEOUT / 5))); do
        st=$(ha-manager status 2>/dev/null)
        moved=1
        for sid in $sids; do grep -qE "^service $sid \(${DEST[$sid]}, started\)" <<< "$st" || moved=0; done
        [ "$moved" = 1 ] && [ -z "$(ha_here)" ] && { ok=1; break; }
        sleep 5
      done
      [ "$ok" = 1 ] || { log "${HA_TIMEOUT}초 안에 HA 게스트가 모두 옮겨지지 않아 중단합니다(ha-manager status 확인)"; exit 1; }
      log "HA 게스트 이전 완료"
    fi
  fi
fi

# 4) 이 노드에서 켜져 있는 게스트를 내린다. 1차는 LAST 가 아닌 게스트를 동시에, 2차는 LAST 게스트를
running_vms() { qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}'; }
running_cts() { pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}'; }
shutdown_phase() {   # $1: first(LAST 제외) | last(LAST 만)
  local id pids=()
  for id in $(running_vms); do
    if [ "$1" = first ]; then [ -n "${LAST[$id]:-}" ] && continue; else [ -z "${LAST[$id]:-}" ] && continue; fi
    [ -n "${SKIP[$id]:-}" ] && { log "VM $id 건너뜀(--skip)"; continue; }
    [ -n "${HA_ID[$id]:-}" ] && { log "VM $id 건너뜀(HA 게스트)"; continue; }
    log "VM $id 종료(최대 ${VM_TIMEOUT}초)"
    if [ "$DRY_RUN" = 0 ]; then qm shutdown "$id" --timeout "$VM_TIMEOUT" >/dev/null 2>&1 & pids+=($!); fi
  done
  for id in $(running_cts); do
    if [ "$1" = first ]; then [ -n "${LAST[$id]:-}" ] && continue; else [ -z "${LAST[$id]:-}" ] && continue; fi
    [ -n "${SKIP[$id]:-}" ] && { log "CT $id 건너뜀(--skip)"; continue; }
    [ -n "${HA_ID[$id]:-}" ] && { log "CT $id 건너뜀(HA 게스트)"; continue; }
    log "CT $id 종료(최대 ${CT_TIMEOUT}초)"
    if [ "$DRY_RUN" = 0 ]; then pct shutdown "$id" --timeout "$CT_TIMEOUT" >/dev/null 2>&1 & pids+=($!); fi
  done
  [ ${#pids[@]} -gt 0 ] && wait "${pids[@]}"
  return 0
}
# Ceph 가 있으면 이 노드의 OSD 가 빠진 동안 다른 OSD 로 다시 복제하지 않게 noout 을 켠다(부팅 뒤 --return 이 끔)
if [ -f /etc/pve/ceph.conf ] && command -v ceph >/dev/null; then
  log "Ceph noout 켜기"; run ceph osd set noout >/dev/null 2>&1 || log "noout 을 켜지 못함(계속)"
fi
last_ids="${!LAST[*]}"
log "1차: 마지막 게스트(${last_ids:-없음})를 뺀 게스트 종료"
shutdown_phase first
# NAS 의 iSCSI LUN 위 VG(nas-iscsi.yml)는 NAS 를 내리기 전에 끄고 로그아웃한다. 먼저 내리지 않으면 I/O 가 D 상태로 굳는다
if [ -r /etc/default/nas-iscsi ]; then
  (
    . /etc/default/nas-iscsi
    if iscsiadm -m session 2>/dev/null | grep -q " $TARGET "; then
      log "NAS iSCSI 정리: VG $VG 끄기, $TARGET 로그아웃"
      # 그 VG 위의 Ceph OSD 가 LV 를 쥐고 있으면 VG 를 끌 수 없다
      if command -v ceph-volume >/dev/null; then
        for i in $(ceph-volume lvm list --format json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(" ".join(k for k, v in d.items() if any(x.get("vg_name") == sys.argv[1] for x in v)))' "$VG"); do
          log "Ceph OSD $i 종료"; run systemctl stop "ceph-osd@$i"
        done
      fi
      run vgchange -an "$VG" >/dev/null || log "VG $VG 를 끄지 못함(쓰는 디스크가 남았는지 확인)"
      run iscsiadm -m node -T "$TARGET" -p "$PORTAL" --logout >/dev/null
    fi
  )
fi
if [ ${#LAST[@]} -gt 0 ]; then
  log "2차: 마지막 게스트 종료"
  shutdown_phase last
fi

# 5) 멈춤 판정: 아직 켜진 게스트(--skip 제외), 또는 10초 간격 두 번 모두 D 상태인 작업
hung=()
if [ "$DRY_RUN" = 0 ]; then
  for id in $(running_vms) $(running_cts); do [ -z "${SKIP[$id]:-}${HA_ID[$id]:-}" ] && hung+=("게스트 $id 가 내려가지 않음"); done
fi
d_state() { ps -eo pid=,stat=,comm= | awk '$2 ~ /^D/ {print $1":"$3}' | sort; }
first=$(d_state); sleep 10; second=$(d_state)
for p in $(comm -12 <(echo "$first") <(echo "$second")); do
  pid=${p%%:*}
  where=$(grep -m1 -oE 'amdgpu[a-z_]*|drm_[a-z_]+' "/proc/$pid/stack" 2>/dev/null || true)
  hung+=("D 상태 작업 $p${where:+ ($where)}")
done

# 6) 재부팅 또는 종료
if [ "$POWEROFF" = 1 ]; then ACT="종료" KEY=o UNIT=poweroff; else ACT="재부팅" KEY=b UNIT=reboot; fi
log "동작: $ACT"
if [ "$DRY_RUN" = 1 ]; then
  # 스크립트가 쓰는 경로는 /proc/sysrq-trigger 다. root 가 이 파일에 쓰는 호출은 kernel.sysrq 값과 무관하게 동작한다
  # (kernel.sysrq 는 키보드 호출에만 적용). 그래서 판정은 이 파일의 존재와 쓰기 권한으로 하고, kernel.sysrq 는 참고로만 낸다
  if [ -e /proc/sysrq-trigger ] && [ -w /proc/sysrq-trigger ]; then sysrq_ok="사용 가능"; else sysrq_ok="사용 불가"; fi
  log "sysrq: /proc/sysrq-trigger $sysrq_ok (참고: kernel.sysrq=$(cat /proc/sys/kernel/sysrq 2>/dev/null || echo '?'))"
fi
if [ "$FORCE_SYSRQ" = 1 ] || [ ${#hung[@]} -gt 0 ]; then
  for h in "${hung[@]}"; do log "멈춤: $h"; done
  log "일반 방식은 장치 정리에서 굳을 수 있어 sysrq 로 즉시 ${ACT}합니다"
  run sysctl -qw kernel.sysrq=1
  run sync
  if [ "$DRY_RUN" = 0 ]; then
    echo s > /proc/sysrq-trigger; sleep 3      # 디스크에 쓰기
    echo u > /proc/sysrq-trigger; sleep 3      # 파일시스템 읽기 전용으로
    echo $KEY > /proc/sysrq-trigger            # 즉시 재부팅(b) 또는 전원 끄기(o)
  else
    log "(dry-run) echo s/u/$KEY > /proc/sysrq-trigger"
  fi
else
  log "멈춘 것이 없어 일반 ${ACT}합니다"
  run systemctl $UNIT
fi
```
{: file="scripts/pve-reboot.sh" }

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

> 합류하면 새 노드의 `/etc/pve` 가 클러스터 것으로 바뀝니다. 새 노드에만 있던 사용자, API 토큰, 스토리지 정의는 사라지고 합류한 기준 노드의 것을 같이 씁니다.
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

## 7. 노드 디스크 교체·재구축

어느 노드든(예: pve02) OS 디스크를 바꾸거나 기계가 죽어 Proxmox 를 다시 설치했을 때, 남은 노드(예: pve01)에서 스크립트 하나로 원래 이름·IP·게스트·쿠버네티스 노드로 되돌립니다. 스크립트를 실행하는 노드 자신은 다시 만들 수 없고, 그 노드가 기준 노드가 되어 API 주소·키 원본·저장소 등록을 맡습니다(`main-node.yml`).

시작하려면 남은 노드가 Proxmox 과반이고 남은 etcd 멤버가 과반이어야 합니다. 노드 세 대에 control plane 을 하나씩 둔 구성(etcd 3멤버)이면 한 대를 다시 만들 때 남은 두 노드가 Proxmox 과반(3표 중 2표)이고 남은 etcd 두 멤버가 과반(3 중 2)이므로, `pvecm expected` 도 etcd 멤버를 미리 빼는 것도 필요 없습니다. 옛 control plane 의 etcd 멤버는 정리 단계(`node-rebuild.yml`)가 지웁니다. 두 노드 구성이면 원격 NAS 의 qnetd 와 etcd 세 번째 투표자([쿠버네티스 etcd 세 번째 투표자를 원격 NAS 컨테이너로 붙이는 방법](/posts/55/))가 그 표를 채우므로 둘이 살아 있어야 합니다.

두 노드 구성에서 qnetd 와 투표자가 없을 때 계획된 교체라면, 옛 노드를 끄기 전에 그 노드에 있는 control plane 의 etcd 멤버를 빼 두고(남은 멤버 하나로 과반), 끈 뒤 남은 노드에서 `pvecm expected 1` 로 과반을 만든 다음 시작합니다. 합류하면 표가 2 로 돌아오므로 `expected` 는 따로 되돌리지 않습니다. 멤버를 빼지 못하고 껐거나, 세 노드 구성에서 두 노드가 함께 죽어 etcd 과반을 잃었다면 두 쿠버네티스 API 가 모두 멈춥니다. 남은 노드에서 `pvecm expected 1` 로 Proxmox 과반을 만들고, 남은 control plane 마다 `/etc/kubernetes/manifests/etcd.yaml` 을 밖으로 옮겨 etcd 를 멈추고, `/var/lib/etcd` 를 복사해 둔 뒤, etcd 명령에 `--force-new-cluster` 한 줄을 넣은 매니페스트로 띄워 멤버가 자기 하나이고 healthy 인지 보고, 원래 매니페스트로 되돌립니다. 그동안 워커의 파드는 계속 돕니다. `pve_qdevice_host` 를 비우면 `pve-cluster.yml` 은 QDevice 를 두지 않고, 남은 QDevice 설정은 모든 노드가 online 일 때 지웁니다.

재구축에 쓰는 변수를 `group_vars/all.yml` 에 더합니다. `ct_ssh_pubkeys` 에는 [내부망 DNS 글](/posts/41/)의 실행 PC 키와 함께, 노드가 저장소를 받고 게스트에 접속할 GitHub 계정 공개키를 넣습니다. `pve-controller.yml` 은 주석이 `eu4ng@server` 로 끝나는 줄을 이 키로 찾으므로, 키 주석을 바꾸면 플레이북의 검색어도 같이 바꿉니다.

{% raw %}
```yaml
ct_ssh_pubkeys:                               # CT root·VM 접속 계정에 넣는 공개키. server: Proxmox 노드의 /root/.ssh/id_ed25519(pve-controller.yml)
  - "[DESKTOP_SSH_PUBLIC_KEY]"
  - "ssh-ed25519 [SERVER_SSH_PUBLIC_KEY] eu4ng@server"
# 같은 이름 노드를 다시 만들 때 지우고 새로 받을 PVC(복제본이 모두 그 노드에 있던 것만). Patroni 멤버라 다른 멤버가 Leader 일 때만 지웁니다
node_rebuild_recreate_pvcs:
  daejeon: [timescaledb/pgdata-timescaledb-0, timescaledb/pgdata-timescaledb-1]
node_rebuild_patroni: { namespace: timescaledb, container: timescaledb, config: /etc/patroni/patroni.yml }   # 위 PVC 의 Patroni(멤버 이름 = 파드 이름)
# 원격 etcd 투표자를 붙인 클러스터만: 기존 클러스터 항목에 투표자 peer 주소를 더하면 재구축 뒤 그 경로도 확인합니다
# k8s_clusters:
#   hub:
#     etcd_witness_peer: "[NAS_TAILSCALE_IP]:2380"
```
{: file="group_vars/all.yml" }
{% endraw %}

스크립트와 정리 플레이북은 저장소의 `scripts/`·`playbooks/` 에 둡니다. 5단계를 다시 실행하면 `pve-controller.yml` 이 모든 노드의 `/root/proxmox-ansible` 에 이 저장소를 받아 둡니다.

```bash
# 재구축 스크립트와 정리 플레이북 내려받기
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/pve-node-rebuild.sh -o scripts/pve-node-rebuild.sh
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/node-rebuild.yml -o playbooks/node-rebuild.yml
chmod +x scripts/pve-node-rebuild.sh
```

디스크를 바꾼 뒤에는 아래 세 가지만 합니다.

1. 새 디스크에 Proxmox VE 를 설치합니다. IP 와 이름은 아무것이나 써도 스크립트가 inventory 값으로 맞춥니다.
2. 새 노드 콘솔에서 GitHub 계정 공개키를 root 에 넣습니다. 끝에 이 노드의 IP, ssh 호스트 키 지문(ed25519), 다음 명령을 보여 줍니다. 지문은 3번에서 대조하므로 적어 둡니다.

   ```bash
   # 새 노드 콘솔(root)
   curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/pve-bootstrap.sh | bash
   ```

3. 남은 노드에서 재구축 스크립트를 실행합니다. 먼저 `--dry-run` 으로 점검 결과와 지울 대상만 봅니다.

   ```bash
   # pve01 에서: 점검과 지울 대상만 보기
   /root/proxmox-ansible/scripts/pve-node-rebuild.sh [NEW_IP] pve02 --reason disk-replaced --dry-run

   # 재구축
   /root/proxmox-ansible/scripts/pve-node-rebuild.sh [NEW_IP] pve02 --reason disk-replaced
   ```

   스크립트는 새 기계의 호스트 키 지문을 보여 주고 콘솔에 나온 값과 같은지 묻습니다(`--yes` 로도 건너뛰지 않음). `yes` 를 입력하면 그 키를 상태 폴더의 `<노드>.known_hosts` 에 고정하고, 새 기계로 가는 ssh·scp·ansible 접속은 그 키로만 검증합니다.

   디스크를 바꾼 것이 아니라 기계가 갑자기 죽었다면, 옛 기계의 전원이나 디스크를 끊은 뒤 `--reason failed --fenced` 로 실행합니다.

<details markdown="1">
<summary>scripts/pve-bootstrap.sh 전문</summary>

```bash
#!/usr/bin/env bash
#
# 새로 설치한 Proxmox 노드의 콘솔에서 한 번 실행합니다. GitHub 계정(eu4ng)에 등록된 ssh 공개키를 root 의
# authorized_keys 에 더해, 남은 Proxmox 노드(복구 스크립트)와 작업 PC 가 바로 접속할 수 있게 합니다.
# 비밀값은 없고, 이미 있는 줄은 다시 넣지 않습니다(여러 번 실행해도 됨). 끝에 이 노드의 IP, 호스트 키 지문, 다음에 할 명령을 보여 줍니다.
# 복구 스크립트는 점검 때 받은 이 노드의 호스트 키 지문을 보여 주고 콘솔 값과 같은지 묻습니다. 끝에 나온 지문을 적어 둡니다.
#
# 사용법(새 노드 콘솔, root):
#   curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/pve-bootstrap.sh | bash
#   GITHUB_USER=<계정> 으로 다른 계정의 키를 받을 수 있습니다.

set -euo pipefail
die() { echo "[오류] $*" >&2; exit 1; }

GITHUB_USER=${GITHUB_USER:-eu4ng}
[ "$(id -u)" = 0 ] || die "root 로 실행합니다."

keys=$(curl -fsSL --retry 3 "https://github.com/${GITHUB_USER}.keys") || die "https://github.com/${GITHUB_USER}.keys 를 받지 못했습니다(네트워크·DNS 확인)."
[ -n "$keys" ] || die "${GITHUB_USER} 계정에 등록된 공개키가 없습니다."

# Proxmox 는 클러스터에 들어가면 /root/.ssh/authorized_keys 를 /etc/pve/priv/authorized_keys 로 바꿉니다. 링크면 링크 대상에 씁니다
umask 077
mkdir -p /root/.ssh
f=/root/.ssh/authorized_keys
touch "$f"
added=0
while IFS= read -r k; do
  [ -n "$k" ] || continue
  if ! grep -qF "$k" "$f"; then
    printf '%s %s@github\n' "$k" "$GITHUB_USER" >> "$f"
    added=$((added + 1))
  fi
done <<< "$keys"
[ -L "$f" ] || chmod 600 "$f"
echo "==> 공개키 $(grep -c . <<< "$keys")개 중 ${added}개를 더했습니다($f)."

# 기본 경로의 출발 주소(LAN). 첫 global 주소는 Tailscale 주소일 수 있습니다
ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')
echo "==> 이 노드: $(hostname -f) ${ip:-<IP 를 찾지 못함>}"
echo "==> 호스트 키 지문(ed25519, 복구 스크립트가 보여 주는 값과 대조): $(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')"
echo
echo "다음: 남은 Proxmox 노드에서 이 노드를 원래 이름으로 다시 만듭니다."
echo "  /root/proxmox-ansible/scripts/pve-node-rebuild.sh ${ip:-<이 노드 IP>} <노드 이름> --reason disk-replaced"
```
{: file="scripts/pve-bootstrap.sh" }

</details>

스크립트가 하는 일은 다음과 같습니다.

- **점검:** 과반이 있는지, 옛 노드가 offline 인지, 옛 기계가 격리됐는지(옛 링 주소가 응답하지 않거나, 다른 호스트 키를 가진 기계에 `corosync.conf` 가 없음), 새 기계의 호스트 키 지문이 콘솔 값과 같은지, 새 기계가 게스트 없는 빈 Proxmox 인지, 남은 etcd 멤버가 건강한지 봅니다. 하나라도 어긋나면 시작하지 않습니다.
- **계속 실행:** 점검을 통과하면 systemd 유닛 `pve-node-rebuild-<노드>` 로 다시 떠서 ssh 가 끊겨도 계속합니다. 로그는 `/root/pve-rebuild/<시각>.log` 입니다.
- **순서:** 신원 맞추기(호스트 이름·IP 를 inventory 값으로) → `node-rebuild.yml`(옛 기록 정리) → `pve-cluster` → `vm-template` → `lan-dns` → `ollama` → `k8s-cluster`(클러스터마다) → 합류 뒤 마무리(local-path 경로 권한, Patroni 멤버 reinit) → 호스트 지표·시간대 → 검증 요약입니다.
- **이어 가기:** 상태 파일 `/root/pve-rebuild/<노드>.state` 에 새 기계의 호스트 키 지문·machine-id 와 끝낸 단계를 적습니다. 실패하면 원인을 고친 뒤 같은 명령으로 이어 가고, 다른 기계로는 이어 가지 않습니다.
- **정리 범위:** 처음 실행할 때 지울 대상의 ID(etcd 멤버 ID, Node·PVC UID, Longhorn 노드·복제본, 옛 root 키·호스트 키 줄)를 상태 파일에 적고, 다시 실행하면 그 ID 와 같은 것만 지웁니다. 다시 만든 etcd 멤버와 Node 는 ID 가 달라 지우지 않습니다. 이미 없는 대상(Node 를 지운 뒤 Longhorn 이 먼저 지운 노드 기록 등)은 완료로 치고, 조회가 다른 이유로 실패하면 멈추며, 지운 뒤에는 다시 조회해 없어진 것을 확인한 다음에만 완료를 적습니다.
- **노드 준비:** `pve-cluster.yml` 끝의 `pve-controller.yml` 이 모든 노드에 저장소와 가상 환경(ansible·proxmoxer·컬렉션), 노드별 API 토큰 `root@pam!rebuild-<노드>`, GitHub 계정 키, 실행 PC 의 Tailscale 인증 키를 둡니다. 재구축으로 들어온 노드도 같이 준비되어, 다음에는 그 노드가 다른 노드를 다시 만들 수 있습니다.

스크립트는 이 저장소의 다른 플레이북(`host-metrics.yml`, `timezone.yml` 등)과 클러스터 이름(`hub`, `daejeon`)을 그대로 부르므로, 구성이 다르면 스크립트의 플레이북 목록을 맞춰 고칩니다.

> 저장소를 받고 게스트에 접속하려고 같은 GitHub 계정 키를 모든 Proxmox 노드에 둡니다. 노드 하나가 뚫리면 GitHub 계정(모든 저장소 쓰기 권한)과 이 키를 받는 모든 VM·CT 가 함께 노출됩니다. 줄이려면 노드마다 키를 따로 만들어 `ct_ssh_pubkeys` 에 각각 넣고, 저장소는 계정 키 대신 이 저장소 전용 읽기 전용 deploy key 로 받게 `pve_controller_repo` 와 키 경로를 바꿉니다.
{: .prompt-danger }

- **확인:** 마지막 `검증 요약` 에 `Quorate: Yes`, 재구축한 노드의 게스트 목록이 예상 vmid 와 같고, 쿠버네티스 노드가 `Ready`, etcd 멤버가 모두 `is healthy` 로 보입니다. 끝에 `끝: pve02 재구축` 이 출력됩니다.

<details markdown="1">
<summary>scripts/pve-node-rebuild.sh·playbooks/node-rebuild.yml·playbooks/pve-controller.yml</summary>

세 파일은 길어 전문 대신 링크로 둡니다.

- [scripts/pve-node-rebuild.sh](/assets/scripts/proxmox/pve-node-rebuild.sh)
- [playbooks/node-rebuild.yml](/assets/scripts/proxmox/node-rebuild.yml)
- [playbooks/pve-controller.yml](/assets/scripts/proxmox/pve-controller.yml)

</details>

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

Proxmox 서버 두 대를 클러스터로 묶고 원격 NAS 의 qnetd 로 세 번째 표를 주어, 한 대가 꺼지거나 NAS 가 멈춰도 남은 쪽이 과반을 유지하게 했습니다. 두 노드는 집 LAN 을 tailnet 에 광고하는 서브넷 라우터가 되어, 원격 NAS 와 LAN 의 VM 이 Tailscale 로 서로 닿습니다. 새 서버를 더할 때는 인벤토리에 추가하고 같은 플레이북을 다시 실행합니다. 노드의 디스크를 바꾸면 남은 노드에서 재구축 스크립트 하나로 원래 상태로 되돌립니다. 이 글은 Proxmox 관리 기능의 과반만 다룹니다. 노드마다 로컬 디스크를 쓰므로 게스트를 다른 노드로 자동으로 옮기는 Proxmox HA 는 설정하지 않았습니다.

## 참고 자료

- [Proxmox VE - Cluster Manager (Corosync External Vote Support)](https://pve.proxmox.com/wiki/Cluster_Manager#_corosync_external_vote_support)
- [corosync-qdevice (GitHub)](https://github.com/corosync/corosync-qdevice)
- [Tailscale - Auth keys](https://tailscale.com/kb/1085/auth-keys)
- [Tailscale - Subnet routers](https://tailscale.com/kb/1019/subnets)
- [Tailscale - Synology](https://tailscale.com/kb/1131/synology)
