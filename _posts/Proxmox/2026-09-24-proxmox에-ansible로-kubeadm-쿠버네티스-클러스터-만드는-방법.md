---
layout: post
title: Proxmox에 Ansible로 kubeadm 쿠버네티스 클러스터 만드는 방법
description: control plane 세 대와 worker 세 대를 Proxmox 세 노드에 하나씩 나눠 두고 API 주소를 keepalived VIP 로 받는 kubeadm 클러스터를, Ansible 플레이북 하나로 만들고 노드를 교체하고 지우는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, ansible, kubernetes, kubeadm, keepalived, longhorn, cloud-init, homelab]
permalink: /posts/46/
---

[템플릿 스크립트](/posts/33/)와 [클러스터 스크립트](/posts/32/)로 하던 일을 Ansible 플레이북으로 옮겨, CT·VM 을 만드는 모든 절차를 `proxmox-ansible` 저장소 하나에 모읍니다. 템플릿 플레이북이 Proxmox 노드마다 Ubuntu 24.04 클라우드 이미지로 VM 템플릿을 만들고, 클러스터 플레이북이 그 템플릿을 복제해 노드 VM 을 만든 뒤 [kubeadm](/posts/60/) 클러스터를 구성합니다. control plane 과 worker 를 세 Proxmox 노드에 하나씩 나눠 두어 etcd 가 control plane 3멤버가 되고 서버 한 대가 죽어도 과반이 남습니다. API 주소는 control plane 마다 둔 **keepalived** 가 VRRP 로 주인을 정해 ARP 로 알리는 VIP 로 받아 control plane 한 대가 꺼져도 같은 주소로 붙습니다. 클러스터 정의는 변수 파일에 목록으로 두고 `-e k8s_cluster=<이름>` 으로 골라, 중앙 허브와 지역 엣지를 같은 플레이북으로 만듭니다. 여러 번 실행해도 결과가 같고, 노드 교체와 삭제도 같은 플레이북으로 합니다.

1. 변수 채우기
2. 템플릿 만들기
3. 클러스터 만들기
4. 확인
5. 노드 교체
6. 클러스터 삭제

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Proxmox VE | `9.2` (세 노드) |
| Ansible | `13.1` (ansible-core `2.20`, community.proxmox `1.4`) |
| Kubernetes | `v1.37.0` (kubeadm, containerd `2.2`) |
| keepalived | `2.2.8` (Ubuntu 24.04 패키지) |
| Flannel | `v0.28.9` |
| 작성 기준일 | `2026-09-28` |

다음 항목이 준비되어 있어야 합니다.

- Proxmox 세 대의 클러스터와 Tailscale 서브넷 라우터 ([Proxmox 두 대를 클러스터로 묶고 원격 NAS에 QDevice 붙이는 방법](/posts/53/)). VM 은 원격지(tailnet)로 가는 패킷을 자기 Proxmox 노드로 보냅니다.
- `proxmox-ansible` 저장소 골격, API 토큰, 내부망 DNS 플레이북(`playbooks/lan-dns.yml`, `templates/dnsmasq-lan.conf.j2`) ([Proxmox에 Ansible로 내부망 DNS 컨테이너 만드는 방법](/posts/41/)). 클러스터 플레이북이 끝에서 내부망 DNS 플레이북을 다시 실행합니다.
- 실행 PC 의 SSH 키(`~/.ssh/id_ed25519.pub`)가 `group_vars/all.yml` 의 `ct_ssh_pubkeys` 목록에 들어 있어야 합니다. 이 키가 템플릿에 들어가 복제한 VM 에 Ansible 이 접속합니다.
- 노드마다 비어 있는 VM ID 와 고정 IP, 클러스터마다 비어 있는 [VIP](/posts/69/) 하나(서비스 VIP 를 쓰는 엣지는 하나 더). VIP 는 공유기 DHCP 가 나눠 주지 않는 주소로 고릅니다.

## 1. 변수 채우기

`group_vars/all.yml` 에 템플릿과 클러스터 값을 추가합니다. `k8s_clusters` 아래에 클러스터마다 노드 목록을 두고, 노드마다 VM 을 둘 Proxmox 노드(`pve`)와 역할(`role`)을 적습니다. `role: control-plane` 인 첫 노드에서 클러스터를 만들고 나머지 control plane 과 worker 가 합류합니다. `longhorn_disk` 가 있는 노드에는 Longhorn 이 복제 볼륨을 두는 전용 디스크를 붙이고, `longhorn_storage` 로 그 디스크를 둘 Proxmox 저장소를 고릅니다(기본 `vm_disk_storage`). NVMe 가 넉넉하지 않은 세 번째 서버의 worker 는 NAS HDD 의 NFS 저장소(`nas_vm_storage`)에 두고, `startup` 으로 NAS VM 이 뜬 뒤에 켜지게 합니다. [내부망 DNS 글](/posts/41/)에서 허브 VIP 만 넣어 둔 `k8s_clusters` 는 이 목록으로 바꿉니다.

{% raw %}
```yaml
vm_template_vmid: 9000                        # playbooks/vm-template.yml 이 노드마다 만드는 Ubuntu 클라우드 이미지 템플릿 (SSH 키·qemu-guest-agent 포함). 노드별 값은 inventory
vm_template_name: ubuntu-2404-cloud
vm_template_image_url: https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
vm_template_user: ubuntu                      # 복제한 VM 의 접속 계정 (cloud-init)
vm_snippet_storage: local                     # cloud-init vendor 스니펫을 둘 디렉터리형 스토리지
vm_disk_storage: local-lvm                    # VM 디스크를 두는 스토리지 (lvmthin 이라 포맷은 raw)
nas_vm_storage: { name: nas, server: [NAS_IP], export: [NFS_EXPORT] }   # NAS 의 NFS 저장소. longhorn_storage 가 이 이름이면 qcow2 로 만들고 ssd 표시를 붙이지 않음
vm_bridge: vmbr0
tailscale_cidr: 100.64.0.0/10                 # tailnet 주소 대역. 쿠버네티스 VM 은 이 대역을 자기 Proxmox 호스트로 보냄(k8s-cluster.yml)

# ---- k8s-cluster: kubeadm 쿠버네티스 클러스터 (허브와 지역 엣지) ----
# playbooks/k8s-cluster.yml -e k8s_cluster=<이름> 으로 k8s_clusters 의 한 클러스터를 만듭니다(기본 hub).
# 노드마다 pve(VM 을 둘 Proxmox 노드), role(control-plane|worker)을 둡니다. role 이 control-plane 인 첫 항목에서 클러스터를 만들고
# 나머지 control-plane 은 합류합니다. 세 Proxmox 노드(pve01·pve02·pve03)에 cp 와 worker 를 하나씩 둡니다. etcd 는 cp 3멤버라
# 서버 한 대가 죽어도 과반이 남습니다.
# 크기 기준: 허브는 코어 1 : 메모리 2GiB. 엣지는 IoT 전용이라 IoT 서비스가 도는 만큼만 주고 나머지는 허브에 둡니다.
#   엣지 worker-1 은 NVR(재실 감지)이 CPU 를 다 써서 6코어, worker-2 는 NVR 이 넘어올 수 있는 최소인 4코어.
#   control plane 은 etcd 가 밀리지 않게 2코어를 유지합니다(엣지는 2GiB 로 충분).
# longhorn_disk(GB): Longhorn 이 복제 볼륨을 두는 전용 디스크(scsi1, /var/lib/longhorn). 키우면 켠 채로 늘립니다(줄이지는 못함).
#   엣지는 NVR 영상 버퍼(18Gi, 2벌)까지 담으려고 40.
# longhorn_storage: 그 디스크를 둘 Proxmox 저장소(기본 vm_disk_storage). NFS(nas_vm_storage)면 qcow2 이고 ssd 표시를 붙이지 않습니다.
#   DB 는 NVMe 인 worker-1·2 에만 둡니다(배치 정책의 nodeAffinity).
# startup: Proxmox 부팅 순서(qm --startup). nas 디스크를 쓰는 worker-3 은 NAS VM(order=1, up 으로 NFS 를 기다림) 다음 order=2,
#   cp-3 은 NAS 를 기다리지 않게 order=1. 지정하지 않은 VM 은 순서 있는 VM 다음에 켭니다.
k8s_cluster_name: "{{ k8s_cluster | default('hub') }}"
kc: "{{ k8s_clusters[k8s_cluster_name] }}"   # 지금 다루는 클러스터
k8s_clusters:
  hub:                                        # 중앙 허브
    nodes:
      - { name: k8s-hub-cp-1, pve: pve01, role: control-plane, vmid: 121, ip: [HUB_CP_1_IP], cores: 2,  memory: 4096,  disk: 32G }
      - { name: k8s-hub-cp-2, pve: pve02, role: control-plane, vmid: 122, ip: [HUB_CP_2_IP], cores: 2,  memory: 4096,  disk: 32G }
      - { name: k8s-hub-cp-3, pve: pve03, role: control-plane, vmid: 125, ip: [HUB_CP_3_IP], cores: 2,  memory: 4096,  disk: 32G, startup: "order=1" }
      - { name: k8s-hub-worker-1, pve: pve01, role: worker,    vmid: 123, ip: [HUB_WORKER_1_IP], cores: 12, memory: 16384, disk: 100G, longhorn_disk: 20 }
      - { name: k8s-hub-worker-2, pve: pve02, role: worker,    vmid: 124, ip: [HUB_WORKER_2_IP], cores: 8,  memory: 16384, disk: 60G,  longhorn_disk: 20 }
      - { name: k8s-hub-worker-3, pve: pve03, role: worker,    vmid: 126, ip: [HUB_WORKER_3_IP], cores: 6,  memory: 16384, disk: 40G,  longhorn_disk: 100, longhorn_storage: nas, startup: "order=2" }
    dns_name: hub                             # 내부망 DNS 역할 이름 k8s-hub(VIP), kubectl-hub(kubectl 을 돌릴 control plane). templates/dnsmasq-lan.conf.j2
    vip: [HUB_VIP]                            # API 엔드포인트(keepalived VRRP, playbooks/tasks/keepalived.yml). control plane 중 한 대가 가짐
    vrrp_id: 100                              # keepalived virtual_router_id. 같은 LAN 의 클러스터마다 달라야 함
    control_plane_workloads: false            # control plane 에 일반 파드를 두지 않음(taint 유지)
    kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/k8s-hub.yaml"   # 실행 PC 에 저장할 kubeconfig
  daejeon:                                    # 지역 엣지. 허브 없이 혼자 돕니다
    nodes:
      - { name: k8s-dj-cp-1,     pve: pve01, role: control-plane, vmid: 131, ip: [EDGE_CP_1_IP], cores: 2, memory: 2048, disk: 32G }
      - { name: k8s-dj-cp-2,     pve: pve02, role: control-plane, vmid: 132, ip: [EDGE_CP_2_IP], cores: 2, memory: 2048, disk: 32G }
      - { name: k8s-dj-cp-3,     pve: pve03, role: control-plane, vmid: 135, ip: [EDGE_CP_3_IP], cores: 2, memory: 2048, disk: 32G, startup: "order=1" }
      - { name: k8s-dj-worker-1, pve: pve01, role: worker,        vmid: 133, ip: [EDGE_WORKER_1_IP], cores: 6, memory: 8192, disk: 40G, longhorn_disk: 40 }
      - { name: k8s-dj-worker-2, pve: pve02, role: worker,        vmid: 134, ip: [EDGE_WORKER_2_IP], cores: 4, memory: 8192, disk: 40G, longhorn_disk: 40 }
      - { name: k8s-dj-worker-3, pve: pve03, role: worker,        vmid: 136, ip: [EDGE_WORKER_3_IP], cores: 6, memory: 8192, disk: 40G, longhorn_disk: 200, longhorn_storage: nas, startup: "order=2" }
    dns_name: dj                              # 내부망 DNS 역할 이름 k8s-dj, kubectl-dj, iot-dj(서비스 VIP)
    vip: [EDGE_VIP]
    vrrp_id: 130
    service_vip: [EDGE_SERVICE_VIP]           # 서비스 VIP(keepalived 가 API VIP 와 함께 가짐). 서비스의 spec.externalIPs 와 같아야 함
    lan_dns_names: [ha-dj, z2m-dj, matter-dj, grafana-dj]   # 내부망에서 service_vip(지역 Traefik)로 답할 지역 서비스 이름
    control_plane_workloads: false
    otbr_host: true                           # OpenThread Border Router(hostNetwork)용 커널 설정
    kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/k8s-daejeon.yaml"
# 원격 etcd 멤버를 붙일 때 그 멤버가 보는 우리 쪽 주소: Proxmox 노드의 Tailscale IP(마스커레이드). 노드를 다시 설치하면 주소가 바뀌므로 고정하지 않고
# 각 Proxmox 노드에서 `tailscale ip -4` 를 읽습니다(k8s-cluster.yml 의 "Proxmox 노드 Tailscale IP" 작업). Tailscale 이 없는 노드는 빠집니다
k8s_etcd_peer_sans: "{{ groups.proxmox | map('extract', hostvars) | selectattr('pve_tailscale_ip', 'defined') | map(attribute='pve_tailscale_ip') | select | list }}"
k8s_vm_cpuunits: 1000                         # 호스트 CPU 가 모자랄 때의 몫(기본 100). 같은 호스트의 다른 CT·VM 이 CPU 를 다 써도 etcd·kubelet 이 밀리지 않게 높게 둠
k8s_vip_interface: eth0
keepalived_vips: "{{ [kc.vip] + ([kc.service_vip] if kc.service_vip is defined else []) }}"   # control plane 의 keepalived 가 함께 가질 VIP
k8s_nameservers: [[LAN_DNS_IP], [LAN_DNS_2_IP], [LAN_DNS_3_IP]]
k8s_version: v1.37                            # pkgs.k8s.io 저장소의 마이너 버전
k8s_package_version: 1.37.0-1.1               # kubelet·kubeadm·kubectl 버전, 새 클러스터의 control plane 버전(kubeadm init --kubernetes-version). kubelet 이 apiserver 보다 새로우면 안 됨
k8s_pod_cidr: 10.244.0.0/16                   # Flannel 기본값
k8s_flannel_version: v0.28.9                  # https://github.com/flannel-io/flannel/releases
```
{: file="group_vars/all.yml" }
{% endraw %}

노드는 플레이북이 실행 중에 이 목록으로 인벤토리 그룹을 만들므로 `inventory.yml` 에 적지 않아도 됩니다. 시간대 플레이북처럼 다른 플레이북에서도 노드에 접속하려면 `inventory.yml` 의 `k8s` 그룹에 같은 이름과 주소로 추가합니다. 내부망 DNS 도 이 목록으로 노드 이름(`k8s-hub-cp-1.[DOMAIN]`)과 역할 이름(`k8s-hub`, `kubectl-hub`, `iot-dj`)을 만듭니다.

- **확인:** `ansible localhost -m debug -a var=kc.vip -e k8s_cluster=daejeon` 이 엣지 VIP 를 출력합니다.

## 2. 템플릿 만들기

템플릿 플레이북은 Proxmox 노드마다 클라우드 이미지를 내려받아 VM 을 만들고 템플릿으로 바꿉니다. VM ID 는 클러스터 전체에서 하나라, 두 번째·세 번째 노드의 템플릿 번호는 inventory 의 `vm_template_vmid`(예: `9001`, `9002`)로 따로 줍니다([Proxmox 클러스터 글](/posts/53/)의 4단계). 모든 복제 VM 에 적용할 cloud-init vendor 스니펫(qemu-guest-agent 설치, SSH 호스트 키 유지)을 호스트의 스니펫 스토리지에 두고, VM 에 넣을 공개키로는 실행 PC 키와 호스트의 `authorized_keys`, 호스트 키를 합쳐 넣습니다. 같은 ID 의 템플릿이 이미 있으면 아무것도 하지 않고, 같은 ID 가 템플릿이 아닌 VM 이면 멈춥니다.

```bash
# 플레이북 내려받기
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/vm-template.yml -o playbooks/vm-template.yml
```

<details markdown="1">
<summary>playbooks/vm-template.yml 전문</summary>

{% raw %}
```yaml
# Ubuntu 24.04 클라우드 이미지로 VM 템플릿을 만듭니다. 복제한 VM 은 cloud-init 으로 계정·SSH 키·qemu-guest-agent 가 준비되어 바로 접속됩니다.
# 템플릿이 이미 있으면 아무것도 하지 않습니다. 다시 만들려면 호스트에서 qm destroy <ID> --purge 후 실행합니다.
#   ansible-playbook playbooks/vm-template.yml
---
- name: VM 템플릿
  hosts: proxmox
  gather_facts: false
  vars:
    image_path: /var/lib/vz/template/iso/{{ vm_template_image_url | basename }}
    snippet_name: ubuntu-cloud-vendor.yaml
    host_key: /root/.ssh/id_rsa             # 호스트에서 VM 으로 접속할 때 쓰는 키 (k8s-cluster.yml 등은 실행 PC 키를 씀)
  tasks:
    - name: 템플릿이 이미 있는지
      ansible.builtin.command: qm config {{ vm_template_vmid }}
      register: existing
      changed_when: false
      failed_when: false
    - name: 이미 있는 ID 가 템플릿이 아니면 중단
      ansible.builtin.assert:
        that: "'template: 1' in existing.stdout"
        fail_msg: "VM {{ vm_template_vmid }} 가 템플릿이 아닌 VM 입니다. vm_template_vmid 를 바꾸거나 그 VM 을 지우세요."
      when: existing.rc == 0

    - name: 템플릿 만들기
      when: existing.rc != 0
      block:
        - name: 스니펫 스토리지 정보
          ansible.builtin.command: pvesh get /storage/{{ vm_snippet_storage }} --output-format json
          register: storage
          changed_when: false
        - name: 스니펫 콘텐츠 허용 (없을 때만)
          ansible.builtin.command: >-
            pvesm set {{ vm_snippet_storage }} --content {{ (storage.stdout | from_json).content }},snippets
          when: "'snippets' not in (storage.stdout | from_json).content.split(',')"
        - name: cloud-init vendor 스니펫 (모든 복제 VM 에 적용)
          ansible.builtin.copy:
            dest: "{{ (storage.stdout | from_json).path }}/snippets/{{ snippet_name }}"
            mode: "0644"
            content: |
              #cloud-config
              # cloud-init 설정이 바뀌어도(호스트 DNS 변경 등) SSH 호스트 키를 유지
              ssh_deletekeys: false
              package_update: true
              packages:
                - qemu-guest-agent
              runcmd:
                - systemctl enable --now qemu-guest-agent
        - name: 호스트 키 (없을 때만)
          ansible.builtin.command: ssh-keygen -q -t rsa -b 4096 -N '' -f {{ host_key }}
          args:
            creates: "{{ host_key }}"
        - name: VM 에 넣을 공개키 (실행 PC 키 + 호스트 authorized_keys + 호스트 키)
          ansible.builtin.shell: |
            { printf '%s\n' {{ ct_ssh_pubkeys | map('quote') | join(' ') }}; cat /root/.ssh/authorized_keys 2>/dev/null; echo; cat {{ host_key }}.pub; } \
              | grep -vE '^\s*(#|$)' | awk '!seen[$0]++' > /tmp/vm-template-keys
          changed_when: false
        - name: 클라우드 이미지 내려받기
          ansible.builtin.get_url:
            url: "{{ vm_template_image_url }}"
            dest: "{{ image_path }}"
            mode: "0644"
        - name: 템플릿 VM 생성
          ansible.builtin.shell: |
            set -e
            qm create {{ vm_template_vmid }} --name {{ vm_template_name }} --ostype l26 \
              --cpu host --cores 2 --memory 2048 --balloon 0 --agent 1 \
              --net0 virtio,bridge={{ vm_bridge }} --scsihw virtio-scsi-single --serial0 socket --vga serial0
            qm set {{ vm_template_vmid }} --scsi0 {{ vm_disk_storage }}:0,import-from={{ image_path }},iothread=1,discard=on,ssd=1
            qm set {{ vm_template_vmid }} --ide2 {{ vm_disk_storage }}:cloudinit --boot order=scsi0
            qm set {{ vm_template_vmid }} --onboot 1 --ciuser {{ vm_template_user }} --sshkeys /tmp/vm-template-keys --ciupgrade 0 \
              --cicustom vendor={{ vm_snippet_storage }}:snippets/{{ snippet_name }}
            qm template {{ vm_template_vmid }}
            rm -f /tmp/vm-template-keys
    - name: 결과
      ansible.builtin.command: qm config {{ vm_template_vmid }}
      register: result
      changed_when: false
    - name: 템플릿인지
      ansible.builtin.assert:
        that: "'template: 1' in result.stdout and 'sshkeys:' in result.stdout"
```
{: file="playbooks/vm-template.yml" }
{% endraw %}

</details>

```bash
# 실행 (이미지 내려받기 포함 1~2분)
export PROXMOX_HOST=[PROXMOX_IP] PROXMOX_USER=root@pam PROXMOX_TOKEN_ID=ansible \
       PROXMOX_TOKEN_SECRET=$(cat ~/.config/proxmox/token) PROXMOX_VALIDATE_CERTS=false
ansible-playbook playbooks/vm-template.yml
```

- **확인:** `PLAY RECAP` 에 `failed=0`, 첫 번째 노드에서 `qm config 9000`, 두 번째·세 번째 노드에서 `qm config 9001`·`qm config 9002` 에 `template: 1`, `sshkeys:`, `cicustom: vendor=local:snippets/ubuntu-cloud-vendor.yaml` 이 보입니다. 한 번 더 실행하면 `changed=0` 입니다.

## 3. 클러스터 만들기

클러스터 플레이북은 아래 순서로 진행합니다.

- VM 만들기: 노드 목록을 인벤토리 그룹으로, 노드마다 정한 Proxmox 노드의 템플릿 복제, 디스크 늘리기(복제 직후 한 번), Longhorn 디스크(`scsi1`, `longhorn_storage` 의 저장소) 추가와 늘리기(`longhorn_disk` 를 키웠을 때), 코어·메모리·CPU 우선순위(`cpuunits`)·IP·DNS·부팅 순서(`startup`) 설정, 시작
- 노드 공통: 시간대, swap 끄기, 커널 모듈·설정, tailnet 경로, 엣지의 OpenThread Border Router 커널 설정, containerd 와 `k8s_package_version` 으로 고정한 kubelet·kubeadm·kubectl
- control plane 기준 노드 고르기: `admin.conf` 가 있는 control plane 을 기준으로 삼고, 클러스터가 없는데 VIP 가 이미 응답하면 멈춤
- control plane: keepalived(처음 만들 때는 init 전에), `kubeadm init --control-plane-endpoint=<VIP>:6443 --kubernetes-version=...`(처음 한 번), Flannel, etcd peer 인증서 SAN, join 명령, kubeconfig 를 실행 PC 로
- control plane 합류: 한 대씩 `kubeadm join --control-plane`, keepalived
- worker 합류: `kubeadm join`, kubelet 이 VIP 로 붙게
- Longhorn 준비: `open-iscsi`·`nfs-common`, `iscsi_tcp` 모듈, multipath 에서 `sd` 장치 제외, 전용 디스크를 ext4 로 `/var/lib/longhorn` 에 마운트, 디스크를 늘렸으면 파일시스템도 그 크기로
- etcd 리더 감시: control plane 마다 `etcd-leader-guard` 서비스. 원격 투표자를 붙인 클러스터에서 그 멤버가 etcd 리더가 되면 자기 노드로 리더를 되돌림
- 옛 노드 빼기: `retire: true` 가 붙은 노드(5단계)
- 노드 라벨: 노드마다 VM 이 있는 Proxmox 노드를 `eu4ng.com/pve` 라벨로 붙임. 이것만 다시 맞출 때는 `--tags node-labels`
- CoreDNS: 받을 수 있는 노드마다 하나씩 두고 kube-dns 가 같은 노드의 CoreDNS 를 먼저 쓰게 함. 이것만 다시 맞출 때는 `--tags dns`
- 확인: 모든 노드 Ready, 노드 수
- 내부망 DNS: `lan-dns.yml` 을 다시 실행해 노드·역할 이름을 새로 만듦

keepalived 는 control plane 마다 systemd 서비스로 뜨고, control plane 끼리 VRRP 광고를 unicast 로 주고받아 우선순위가 가장 높은 한 대가 VIP 를 가집니다. 우선순위는 모두 100 이고 `nopreempt` 라, VIP 를 가진 control plane 이 계속 가지고 있다가 그 노드의 apiserver 가 `6443` 에서 연결을 받지 않고 다른 control plane 의 apiserver 는 받으면 FAULT 상태로 VIP 를 놓아 그쪽으로 넘어갑니다. `nopreempt` 에서는 우선순위를 깎는 것만으로는 다른 노드가 가져가지 않아서, 검사 스크립트가 다른 control plane 까지 보고 판정합니다. 돌아온 노드가 VIP 를 다시 빼앗지 않아 특정 노드에 묶이지 않습니다. readyz 를 0.5초마다 불러 잰 결과(2026-10-20, control plane 3대), VIP 를 가진 노드의 keepalived 를 재시작하면 약 1초 안에, 그 노드의 apiserver 만 막으면(FAULT) 약 6.6초 뒤 다른 노드가 받았고 어느 쪽도 원래 노드로 되돌아가지 않았습니다. 쿠버네티스 API 없이 주인을 정하므로 etcd 과반을 잃어 API 가 멈춰도 살아 있는 control plane 이 VIP 를 계속 가집니다. 모든 control plane 의 apiserver 가 응답하지 않으면 검사가 성공으로 답해 VIP 를 놓지 않는 것도 같은 이유입니다. API 리스로 리더를 뽑는 방식이 이때 VIP 를 놓는 이유는 [가상 IP(VIP)와 ARP로 서버 장애를 넘기는 원리](/posts/69/)에 정리했습니다. 클러스터를 처음 만들 때는 apiserver 가 아직 없으므로 `kubeadm init` 전에 keepalived 를 켜 두고 응답은 기다리지 않습니다. 엣지처럼 `service_vip` 가 있는 클러스터는 같은 keepalived 가 서비스 VIP 도 함께 가집니다. `vrrp_id` 는 VRRP 의 `virtual_router_id` 라 같은 LAN 의 클러스터마다 다르게 둡니다. 예전에 kube-vip 으로 만든 클러스터는 첫 작업이 kube-vip static pod 를 모든 control plane 에서 먼저 내리고 keepalived 로 바꿉니다. VIP 만 다시 맞출 때는 `--tags vip` 로 실행합니다.

CoreDNS 는 kubeadm 기본값(2벌)이면 API 가 멈췄을 때 엔드포인트가 갱신되지 않아, 죽은 노드의 CoreDNS 로 가는 조회가 실패합니다. 플레이북은 CoreDNS 를 cordon 하지 않은 노드 수만큼 두고, 한 노드에 하나씩만 뜨게(`podAntiAffinity`, control plane taint 허용) 한 뒤 kube-dns Service 에 `trafficDistribution: PreferSameNode` 를 걸어 같은 노드의 CoreDNS 를 먼저 쓰게 합니다. `kubeadm upgrade` 가 이 설정을 되돌리므로 업그레이드 뒤와 cordon 한 노드를 다시 들인 뒤에 `--tags dns` 로 다시 실행합니다.

control plane 버전은 `--kubernetes-version` 으로 설치한 kubelet·kubeadm 과 같은 버전에 고정합니다. `kubeadm init` 과 `join` 은 결과 파일(`/etc/kubernetes/admin.conf`, `kubelet.conf`)이 있으면 건너뛰므로 다시 실행해도 클러스터를 새로 만들지 않습니다.

tailnet 경로는 원격지(tailnet)의 장치와 DB 복제본에 닿기 위한 것입니다. VM 은 tailnet 대역(`100.64.0.0/10`)을 자기 Proxmox 노드로 보내고, 그 노드가 Tailscale IP 로 바꿔 내보냅니다. 원격 etcd 멤버를 붙이면 그 멤버가 우리 쪽 연결을 이 주소로 보므로 `k8s_etcd_peer_sans` 를 etcd peer 인증서 SAN 에 넣어 둡니다. control plane 3멤버만 쓰는 지금 구성에서는 쓰이지 않지만, 원격 멤버를 다시 붙일 수 있게 남겨 둡니다.

etcd 리더 감시는 플레이북이 `scripts/etcd-leader-guard.sh` 를 control plane 에 복사해 systemd 서비스로 띄우는 것이라, 스크립트도 함께 내려받습니다. 리더가 `etcd-witness` 로 시작하는 이름의 멤버일 때만 움직이므로, 이 글처럼 control plane 3멤버만 둔 클러스터에서는 아무 일도 하지 않습니다. 스크립트의 내용과 필요한 이유는 [쿠버네티스 etcd 세 번째 투표자를 원격 NAS 컨테이너로 붙이는 방법](/posts/55/)에 정리했습니다.

```bash
# 플레이북 내려받기 (lan-dns.yml 과 dnsmasq 템플릿은 내부망 DNS 글에서 받은 것을 씁니다)
mkdir -p playbooks/tasks scripts templates/keepalived
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/k8s-cluster.yml -o playbooks/k8s-cluster.yml
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/etcd-leader-guard.sh -o scripts/etcd-leader-guard.sh
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/tasks/keepalived.yml -o playbooks/tasks/keepalived.yml
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/templates/keepalived/keepalived.conf.j2 -o templates/keepalived/keepalived.conf.j2
```

<details markdown="1">
<summary>playbooks/k8s-cluster.yml 전문</summary>

{% raw %}
```yaml
# kubeadm 쿠버네티스 클러스터(control plane N + worker N). group_vars 의 k8s_clusters 에서 -e k8s_cluster=<이름>(기본 hub)으로 고릅니다.
# 노드마다 정한 Proxmox 노드의 템플릿(vm-template.yml)을 복제해 VM 을 만들고, containerd·kubeadm 을 설치해 VIP(keepalived) 엔드포인트로
# 클러스터를 구성한 뒤 kubeconfig 를 실행 PC 로 가져옵니다. 허브(hub)와 지역 엣지(daejeon 등)가 같은 절차로 만들어집니다.
# etcd 는 세 Proxmox 노드에 하나씩 둔 control plane 3멤버입니다.
# VIP 없이 만든 기존 클러스터는 먼저 scripts/k8s-control-plane-endpoint.sh 로 옮깁니다. 그 다음은 Argo CD 설치·등록부터 GitOps 입니다.
#   ansible-playbook playbooks/k8s-cluster.yml [-e k8s_cluster=daejeon]                    만들기 (여러 번 실행해도 됨)
#   ansible-playbook playbooks/k8s-cluster.yml [-e k8s_cluster=...] -e k8s_state=absent    VM 삭제 (ID 와 이름이 모두 맞는 VM 만, yes 입력 후)
# 노드 교체: 새 노드를 목록에 더해 합류시킨 뒤, 옛 노드 항목에 retire: true 를 붙여 다시 실행하면 drain → (control plane 은 kubeadm reset 으로
# etcd 멤버 제거) → 노드 삭제 → VM 삭제 순으로 뺍니다. 다 빠지면 목록에서 지웁니다.
---
# etcd peer 인증서 SAN(group_vars 의 k8s_etcd_peer_sans)이 노드의 지금 Tailscale 주소를 쓰게 읽어 둡니다. 꺼진 노드는 건너뜁니다
- name: Proxmox 노드 Tailscale IP
  hosts: proxmox
  gather_facts: false
  ignore_unreachable: true
  tags: [always]
  tasks:
    - name: tailscale ip -4
      ansible.builtin.command: tailscale ip -4
      register: ts_ip
      changed_when: false
      failed_when: false
    - name: 기록
      ansible.builtin.set_fact:
        pve_tailscale_ip: "{{ ts_ip.stdout_lines[0] | default('') if ts_ip.rc == 0 else '' }}"

- name: VM 만들기
  hosts: localhost
  gather_facts: false
  vars:
    state: "{{ k8s_state | default('present') }}"
    active: "{{ kc.nodes | rejectattr('retire', 'defined') | list }}"   # retire 가 붙은 옛 노드는 만들거나 고치지 않습니다
  tasks:
    # control plane 중 누가 클러스터를 만들고(init) 누가 합류할지는 다음 플레이가 admin.conf 유무로 정합니다
    - name: 노드 목록을 인벤토리 그룹으로
      ansible.builtin.add_host:
        name: "{{ item.name }}"
        groups: "{{ ['k8s_nodes', 'k8s_control_planes' if item.role == 'control-plane' else 'k8s_workers']
                    + (['k8s_longhorn'] if item.longhorn_disk is defined else []) }}"
        ansible_host: "{{ item.ip }}"
        ansible_user: "{{ vm_template_user }}"
        pve_host_ip: "{{ hostvars[item.pve | default(proxmox_node)].ansible_host }}"   # VM 이 있는 Proxmox 노드의 IP
      loop: "{{ active }}"
      loop_control: { label: "{{ item.name }}" }
      changed_when: false
      tags: [always]                      # --tags node-labels 처럼 일부만 돌릴 때도 노드 그룹은 만듭니다
      when: state == 'present'            # 삭제할 때는 뒤의 플레이가 노드에 접속하지 않게 그룹을 비워 둡니다
    - name: 뺄 옛 노드
      ansible.builtin.add_host:
        name: "{{ item.name }}"
        groups: [k8s_retire]
        ansible_host: "{{ item.ip }}"
        ansible_user: "{{ vm_template_user }}"
        node_role: "{{ item.role }}"
        node_vmid: "{{ item.vmid }}"
        node_pve: "{{ item.pve | default(proxmox_node) }}"
      loop: "{{ kc.nodes | selectattr('retire', 'defined') | list }}"
      tags: [always]
      loop_control: { label: "{{ item.name }}" }
      changed_when: false
      when: state == 'present'

    - name: 삭제
      when: state == 'absent'
      block:
        - name: 확인 (-e k8s_confirm=yes 로 건너뜀)
          ansible.builtin.pause:
            prompt: "{{ kc.nodes | map(attribute='name') | join(', ') }} VM 과 디스크를 삭제합니다. 계속하려면 yes"
          register: confirm
          when: k8s_confirm | default('') != 'yes'
        - name: 삭제 중단
          ansible.builtin.meta: end_play
          when: k8s_confirm | default('') != 'yes' and confirm.user_input | default('') != 'yes'
        - name: 현재 VM 목록 (클러스터 전체)
          community.proxmox.proxmox_vm_info:
            type: qemu
          register: vms
        - name: VM 중지·삭제 (ID 와 이름이 모두 맞는 경우만)
          community.proxmox.proxmox_kvm:
            node: "{{ item.pve | default(proxmox_node) }}"
            vmid: "{{ item.vmid }}"
            name: "{{ item.name }}"
            state: absent
            force: true
            timeout: 120
          loop: "{{ kc.nodes }}"
          loop_control: { label: "{{ item.name }}" }
          when: vms.proxmox_vms | selectattr('vmid', 'equalto', item.vmid | int) | selectattr('name', 'equalto', item.name) | list | length > 0
        - name: 끝
          ansible.builtin.meta: end_play

    - name: 템플릿 복제 (VM 이 없을 때만. VM 을 둘 노드의 템플릿에서)
      community.proxmox.proxmox_kvm:
        node: "{{ item.pve | default(proxmox_node) }}"
        clone: "{{ vm_template_name }}"
        vmid: "{{ hostvars[item.pve | default(proxmox_node)].vm_template_vmid | default(vm_template_vmid) }}"
        newid: "{{ item.vmid }}"
        name: "{{ item.name }}"
        full: true
        storage: "{{ vm_disk_storage }}"
        format: raw
        timeout: 300
        state: present
      loop: "{{ active }}"
      loop_control: { label: "{{ item.name }}" }
      register: clones
    - name: 디스크 늘리기 (복제 직후 한 번)
      community.proxmox.proxmox_disk:
        vmid: "{{ item.item.vmid }}"
        disk: scsi0
        size: "{{ item.item.disk }}"
        state: resized
      loop: "{{ clones.results }}"
      loop_control: { label: "{{ item.item.name }}" }
      when: item.changed
    # longhorn_storage 가 NFS(nas_vm_storage)면 qcow2(파일), lvmthin 이면 raw 입니다. HDD 위 NFS 디스크에는 ssd 표시를 붙이지 않습니다
    - name: Longhorn 디스크 (scsi1, 없을 때만. 켜진 VM 에 핫플러그)
      community.proxmox.proxmox_disk:
        vmid: "{{ item.vmid }}"
        disk: scsi1
        storage: "{{ lh_storage }}"
        size: "{{ item.longhorn_disk }}"
        format: "{{ 'qcow2' if lh_storage == nas_vm_storage.name else 'raw' }}"
        discard: "on"
        ssd: "{{ lh_storage != nas_vm_storage.name }}"
        state: present
      vars:
        lh_storage: "{{ item.longhorn_storage | default(vm_disk_storage) }}"
      loop: "{{ active | selectattr('longhorn_disk', 'defined') }}"
      loop_control: { label: "{{ item.name }}" }
    - name: Longhorn 디스크 늘리기 (longhorn_disk 를 키웠을 때. 켠 채로 늘리고, 줄이지는 못함)
      community.proxmox.proxmox_disk:
        vmid: "{{ item.vmid }}"
        disk: scsi1
        size: "{{ item.longhorn_disk }}G"
        state: resized
      loop: "{{ active | selectattr('longhorn_disk', 'defined') }}"
      loop_control: { label: "{{ item.name }}" }
    - name: VM 설정 맞추기 (코어·메모리·CPU 우선순위·IP·DNS·자동 시작·부팅 순서. 모듈 특성상 매번 changed 로 보고됨. 코어·메모리는 VM 을 껐다 켜야 적용)
      community.proxmox.proxmox_kvm:
        node: "{{ item.pve | default(proxmox_node) }}"
        vmid: "{{ item.vmid }}"
        name: "{{ item.name }}"
        cores: "{{ item.cores }}"
        memory: "{{ item.memory }}"
        cpuunits: "{{ k8s_vm_cpuunits }}"
        onboot: true
        startup: "{{ item.startup | default(omit) }}"   # 부팅 순서(group_vars 의 startup 설명)
        ipconfig: { ipconfig0: "ip={{ item.ip }}/24,gw={{ ct_gateway }}" }
        nameservers: "{{ k8s_nameservers }}"
        update: true
      loop: "{{ active }}"
      loop_control: { label: "{{ item.name }}" }
    - name: VM 시작
      community.proxmox.proxmox_kvm:
        node: "{{ item.pve | default(proxmox_node) }}"
        vmid: "{{ item.vmid }}"
        name: "{{ item.name }}"
        state: started
      loop: "{{ active }}"
      loop_control: { label: "{{ item.name }}" }
    - name: SSH 열릴 때까지 대기
      ansible.builtin.wait_for:
        host: "{{ item.ip }}"
        port: 22
        timeout: 300
      loop: "{{ active }}"
      loop_control: { label: "{{ item.name }}" }

- name: 노드 공통 (containerd, kubeadm)
  hosts: k8s_nodes
  become: true
  gather_facts: false
  tasks:
    - name: cloud-init 완료 대기 (첫 부팅의 패키지 갱신)
      ansible.builtin.command: cloud-init status --wait
      changed_when: false
      failed_when: false
    - name: 시간대
      community.general.timezone:
        name: "{{ timezone }}"
    # 템플릿으로 넣은 키만으로는 키를 더한 뒤 만든 VM 과 그 전 VM 이 달라집니다. 다른 Proxmox 노드에서 복구 스크립트가 붙을 수 있게 맞춥니다
    - name: 접속 공개키 (ct_ssh_pubkeys)
      ansible.posix.authorized_key:
        user: "{{ ansible_user }}"
        key: "{{ item }}"
      loop: "{{ ct_ssh_pubkeys }}"
      loop_control: { label: "{{ item.split(' ')[-1] }}" }
    - name: swap 끄기 (fstab)
      ansible.builtin.replace:
        path: /etc/fstab
        regexp: '^([^#].*\sswap\s.*)$'
        replace: '# \1'
    - name: swap 끄기 (지금)
      ansible.builtin.command: swapoff -a
      changed_when: false
    - name: 커널 모듈 (자동 로드)
      ansible.builtin.copy:
        dest: /etc/modules-load.d/k8s.conf
        mode: "0644"
        content: "overlay\nbr_netfilter\n"
    - name: 커널 모듈 (지금)
      community.general.modprobe:
        name: "{{ item }}"
      loop: [overlay, br_netfilter]
    - name: 커널 설정
      ansible.posix.sysctl:
        name: "{{ item }}"
        value: "1"
        sysctl_file: /etc/sysctl.d/k8s.conf
      loop: [net.bridge.bridge-nf-call-iptables, net.bridge.bridge-nf-call-ip6tables, net.ipv4.ip_forward]
    # 원격지(tailnet)의 장치·DB 복제본에 닿는 경로입니다(옛 서울 NAS etcd 투표자도 이 경로였음). VM 이 있는 Proxmox 노드가 Tailscale 서브넷
    # 라우터이므로 tailnet 대역을 그 노드로 보냅니다. VM 은 자기 노드와 함께 죽고 살므로 이 경로에는 이중화가 필요 없습니다
    - name: tailnet 경로 (netplan)
      ansible.builtin.copy:
        dest: /etc/netplan/60-tailnet.yaml
        mode: "0600"
        content: |
          network:
            version: 2
            ethernets:
              eth0:
                routes:
                  - to: {{ tailscale_cidr }}
                    via: {{ pve_host_ip }}
      register: tailnet_netplan
    - name: tailnet 경로 (지금. netplan apply 대신 경로만 바꿔 네트워크를 흔들지 않음)
      ansible.builtin.shell: |
        netplan generate
        ip route replace {{ tailscale_cidr }} via {{ pve_host_ip }} dev eth0
      when: tailnet_netplan.changed
    # 지역 엣지: OpenThread Border Router 파드(hostNetwork)가 노드에 wpan0 을 만들고 eth0 로 RA 를 보냅니다
    - name: OTBR 커널 설정 (IPv6 포워딩, RA 와 경로 광고 수용)
      ansible.builtin.copy:
        dest: /etc/sysctl.d/60-otbr.conf
        mode: "0644"
        content: |
          # proxmox-ansible 의 playbooks/k8s-cluster.yml 이 만듭니다. OpenThread Border Router 파드(hostNetwork)용.
          net.ipv6.conf.all.forwarding = 1
          net.ipv6.conf.eth0.accept_ra = 2
          net.ipv6.conf.eth0.accept_ra_rt_info_max_plen = 64
      register: otbr_sysctl
      when: kc.otbr_host | default(false)
    - name: OTBR 커널 설정 적용
      ansible.builtin.command: sysctl --system
      when: otbr_sysctl is changed
    - name: tun 모듈 (OTBR 의 wpan0)
      ansible.builtin.copy:
        dest: /etc/modules-load.d/tun.conf
        mode: "0644"
        content: "tun\n"
      when: kc.otbr_host | default(false)
    - name: tun 모듈 지금 로드
      community.general.modprobe:
        name: tun
      when: kc.otbr_host | default(false)
    - name: 패키지 저장소 키
      ansible.builtin.get_url:
        url: https://pkgs.k8s.io/core:/stable:/{{ k8s_version }}/deb/Release.key
        dest: /etc/apt/keyrings/kubernetes-apt-keyring.asc
        mode: "0644"
    - name: 패키지 저장소
      ansible.builtin.copy:
        dest: /etc/apt/sources.list.d/kubernetes.list
        mode: "0644"
        content: "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.asc] https://pkgs.k8s.io/core:/stable:/{{ k8s_version }}/deb/ /\n"
    - name: containerd·kubeadm 설치 (kubelet·kubeadm·kubectl 은 k8s_package_version 으로 고정)
      ansible.builtin.apt:
        name:
          - containerd
          - kubelet={{ k8s_package_version }}
          - kubeadm={{ k8s_package_version }}
          - kubectl={{ k8s_package_version }}
        update_cache: true
        allow_change_held_packages: true
    - name: 버전 고정 (apt upgrade 로 올라가지 않게)
      ansible.builtin.dpkg_selections:
        name: "{{ item }}"
        selection: hold
      loop: [kubelet, kubeadm, kubectl]
    - name: containerd 기본 설정 (없을 때만)
      ansible.builtin.shell: mkdir -p /etc/containerd && containerd config default > /etc/containerd/config.toml
      args:
        creates: /etc/containerd/config.toml
    - name: containerd 가 systemd cgroup 을 쓰게
      ansible.builtin.replace:
        path: /etc/containerd/config.toml
        regexp: 'SystemdCgroup = false'
        replace: 'SystemdCgroup = true'
      register: cgroup
    - name: containerd 재시작
      ansible.builtin.service:
        name: containerd
        state: restarted
      when: cgroup.changed

# 이미 클러스터에 들어 있는(admin.conf 가 있는) control plane 을 기준 노드로 삼고, 나머지는 합류시킵니다.
# 첫 control plane 을 새 VM 으로 바꿀 때도 새 클러스터를 만들지 않게 하기 위해서입니다
- name: control plane 기준 노드 고르기
  hosts: k8s_control_planes
  become: true
  gather_facts: false
  tags: [always]                  # 읽기만 합니다. 뒤 플레이가 쓰는 k8s_cp 그룹을 만들므로 일부 태그만 돌릴 때도 실행
  tasks:
    - name: admin.conf 가 있는지
      ansible.builtin.stat:
        path: /etc/kubernetes/admin.conf
      register: admin_conf
    - name: 기준 노드
      ansible.builtin.set_fact:
        k8s_leader: "{{ ((ansible_play_hosts | map('extract', hostvars) | selectattr('admin_conf.stat.exists') | map(attribute='inventory_hostname') | list) + ansible_play_hosts) | first }}"
        k8s_cluster_exists: "{{ ansible_play_hosts | map('extract', hostvars) | selectattr('admin_conf.stat.exists') | list | length > 0 }}"
      run_once: true
    - name: VIP 가 이미 응답하는데 클러스터에 든 control plane 이 목록에 없으면 멈춤 (새 클러스터를 만들어 버리지 않게)
      ansible.builtin.uri:
        url: https://{{ kc.vip }}:6443/livez
        validate_certs: false
        timeout: 3
      register: vip_probe
      failed_when: vip_probe.status == 200 and not k8s_cluster_exists
      delegate_to: localhost
      become: false
      run_once: true
    - name: 기준 노드와 합류 노드 그룹
      ansible.builtin.add_host:
        name: "{{ item }}"
        groups: ["{{ 'k8s_cp' if item == k8s_leader else 'k8s_cp_join' }}"]
      loop: "{{ ansible_play_hosts }}"
      changed_when: false
      run_once: true

- name: control plane
  hosts: k8s_cp
  become: true
  gather_facts: false
  tasks:
    - name: 클러스터가 있는지
      ansible.builtin.stat:
        path: /etc/kubernetes/admin.conf
      register: admin_conf
    # 새 클러스터는 VIP 엔드포인트로 만듭니다. keepalived 는 API 없이 VIP 를 잡으므로 init 전에 켜 둡니다(apiserver 가 아직 없어 응답은 기다리지 않음)
    - name: keepalived (init 용)
      ansible.builtin.include_tasks:
        file: tasks/keepalived.yml
        apply: { tags: [vip] }
      vars: { keepalived_wait_api: false }
      when: not admin_conf.stat.exists
      tags: [vip]
    - name: kubeadm init (처음 한 번)
      ansible.builtin.command: >-
        kubeadm init --control-plane-endpoint={{ kc.vip }}:6443 --upload-certs
        --kubernetes-version=v{{ k8s_package_version.split('-')[0] }}
        --pod-network-cidr={{ k8s_pod_cidr }} --apiserver-advertise-address={{ ansible_host }}
      args:
        creates: /etc/kubernetes/admin.conf
    - name: keepalived (VIP)
      ansible.builtin.include_tasks:
        file: tasks/keepalived.yml
        apply: { tags: [vip] }
      tags: [vip]
    - name: ubuntu 계정 kubeconfig
      ansible.builtin.shell: |
        install -d -o {{ ansible_user }} -g {{ ansible_user }} /home/{{ ansible_user }}/.kube
        install -o {{ ansible_user }} -g {{ ansible_user }} -m 0600 /etc/kubernetes/admin.conf /home/{{ ansible_user }}/.kube/config
      changed_when: false
    - name: Flannel (CNI)
      ansible.builtin.command: >-
        kubectl --kubeconfig /etc/kubernetes/admin.conf apply
        -f https://github.com/flannel-io/flannel/releases/download/{{ k8s_flannel_version }}/kube-flannel.yml
      register: flannel
      changed_when: "'created' in flannel.stdout or 'configured' in flannel.stdout"
    - name: control plane 에도 워크로드 허용 (노드가 적은 지역 엣지)
      ansible.builtin.shell: |
        kubectl --kubeconfig /etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- 2>&1 | grep -v "not found" || true
      register: untaint
      changed_when: "'untainted' in untaint.stdout"
      when: kc.control_plane_workloads | default(false)
    # 원격(tailnet) etcd 멤버는 우리 쪽 연결을 NAT 뒤 주소(Proxmox 노드의 Tailscale IP)로 봅니다. 그 주소를 peer 인증서 SAN 에 넣어
    # SAN 검사를 켠 채로 연결되게 합니다. 합류하는 control plane 은 kubeadm-config 의 이 값으로 인증서를 만듭니다.
    # 지금은 원격 멤버가 없지만 원격 멤버를 다시 붙일 수 있게 둡니다
    - name: etcd peer 인증서 SAN (kubeadm-config)
      ansible.builtin.shell: |
        set -e
        export KUBECONFIG=/etc/kubernetes/admin.conf
        kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' > /tmp/cluster-config.yaml
        python3 - {{ k8s_etcd_peer_sans | join(' ') }} <<'PY'
        import sys, yaml
        c = yaml.safe_load(open("/tmp/cluster-config.yaml"))
        local = c["etcd"]["local"]
        sans = local.get("peerCertSANs") or []
        add = [x for x in sys.argv[1:] if x not in sans]
        if add:
            local["peerCertSANs"] = sans + add
            yaml.safe_dump(c, open("/tmp/cluster-config.yaml", "w"), sort_keys=False)
            print("CHANGED")
        PY
        if grep -q . /tmp/cluster-config.yaml && [ -n "$(kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | diff - /tmp/cluster-config.yaml)" ]; then
          kubectl -n kube-system create cm kubeadm-config --from-file=ClusterConfiguration=/tmp/cluster-config.yaml \
            --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts -f - >/dev/null
        fi
      register: peer_sans
      changed_when: "'CHANGED' in peer_sans.stdout"
    # etcd 는 TLS 연결마다 인증서 파일을 다시 읽으므로 재시작하지 않아도 새 인증서를 씁니다
    - name: etcd peer 인증서 (이 노드)
      ansible.builtin.shell: |
        set -e
        crt=/etc/kubernetes/pki/etcd/peer.crt
        missing=""
        for ip in {{ k8s_etcd_peer_sans | join(' ') }}; do
          openssl x509 -in $crt -noout -ext subjectAltName | grep -q "IP Address:$ip\b" || missing=1
        done
        [ -z "$missing" ] && exit 0
        { printf 'apiVersion: kubeadm.k8s.io/v1beta4\nkind: InitConfiguration\nlocalAPIEndpoint:\n  advertiseAddress: %s\nnodeRegistration:\n  name: %s\n---\n' \
            {{ ansible_host }} {{ inventory_hostname }}; cat /tmp/cluster-config.yaml; } > /tmp/kubeadm-local.yaml
        mkdir -p /root/pki-backup && cp -a $crt /etc/kubernetes/pki/etcd/peer.key /root/pki-backup/
        rm $crt /etc/kubernetes/pki/etcd/peer.key
        kubeadm init phase certs etcd-peer --config /tmp/kubeadm-local.yaml
        echo CHANGED
      register: peer_cert
      changed_when: "'CHANGED' in peer_cert.stdout"
    # control plane 합류에 쓰는 인증서 키(2시간 유효)와 join 명령
    - name: 인증서 업로드 (control plane 합류용)
      ansible.builtin.shell: kubeadm init phase upload-certs --upload-certs | tail -1
      register: cert_key
      changed_when: false
      when: groups['k8s_cp_join'] | default([]) | length > 0
    - name: join 명령 만들기
      ansible.builtin.command: kubeadm token create --print-join-command
      register: join
      changed_when: false
    - name: kubeconfig 를 실행 PC 로
      ansible.builtin.fetch:
        src: /etc/kubernetes/admin.conf
        dest: "{{ kc.kubeconfig }}"
        flat: true

- name: control plane 합류
  hosts: k8s_cp_join
  become: true
  gather_facts: false
  serial: 1                               # etcd 멤버는 한 대씩 늘립니다
  tasks:
    - name: kubeadm join --control-plane (처음 한 번)
      ansible.builtin.command: >-
        {{ hostvars[groups['k8s_cp'][0]].join.stdout }} --control-plane
        --certificate-key {{ hostvars[groups['k8s_cp'][0]].cert_key.stdout }}
        --apiserver-advertise-address {{ ansible_host }}
      args:
        creates: /etc/kubernetes/kubelet.conf
    - name: keepalived (VIP)
      ansible.builtin.include_tasks:
        file: tasks/keepalived.yml
        apply: { tags: [vip] }
      tags: [vip]
    - name: ubuntu 계정 kubeconfig
      ansible.builtin.shell: |
        install -d -o {{ ansible_user }} -g {{ ansible_user }} /home/{{ ansible_user }}/.kube
        install -o {{ ansible_user }} -g {{ ansible_user }} -m 0600 /etc/kubernetes/admin.conf /home/{{ ansible_user }}/.kube/config
      changed_when: false
    - name: control plane 에도 워크로드 허용 (합류하면 taint 가 다시 붙음)
      ansible.builtin.shell: |
        kubectl --kubeconfig /etc/kubernetes/admin.conf taint nodes {{ inventory_hostname }} node-role.kubernetes.io/control-plane:NoSchedule- 2>&1 | grep -v "not found" || true
      register: untaint
      changed_when: "'untainted' in untaint.stdout"
      when: kc.control_plane_workloads | default(false)

- name: worker 합류
  hosts: k8s_workers
  become: true
  gather_facts: false
  tasks:
    - name: kubeadm join (처음 한 번)
      ansible.builtin.command: "{{ hostvars[groups['k8s_cp'][0]].join.stdout }}"
      args:
        creates: /etc/kubernetes/kubelet.conf
    # VIP 없이 만든 클러스터에서 합류한 worker 는 첫 control plane 주소를 들고 있습니다
    - name: kubelet 이 VIP 로 붙게
      ansible.builtin.replace:
        path: /etc/kubernetes/kubelet.conf
        regexp: 'server: https://.*:6443'
        replace: 'server: https://{{ kc.vip }}:6443'
      register: kubelet_conf
    - name: kubelet 재시작
      ansible.builtin.service:
        name: kubelet
        state: restarted
      when: kubelet_conf.changed

# Longhorn 은 볼륨을 iSCSI 로 붙입니다. multipathd 가 Longhorn 장치를 가로채지 않게 sd 장치를 제외합니다
- name: Longhorn 준비 (longhorn_disk 가 있는 노드)
  hosts: k8s_longhorn
  become: true
  gather_facts: false
  vars:
    longhorn_dev: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
  tasks:
    - name: 패키지
      ansible.builtin.apt:
        name: [open-iscsi, nfs-common]
    - name: iscsid
      ansible.builtin.systemd:
        name: iscsid
        enabled: true
        state: started
    - name: iscsi_tcp 모듈 (자동 로드)
      ansible.builtin.copy:
        dest: /etc/modules-load.d/longhorn.conf
        mode: "0644"
        content: "iscsi_tcp\n"
    - name: iscsi_tcp 모듈 (지금)
      community.general.modprobe:
        name: iscsi_tcp
    - name: multipath 에서 sd 장치 제외
      ansible.builtin.blockinfile:
        path: /etc/multipath.conf
        marker: "# {mark} k8s-hub.yml: Longhorn"   # 플레이북 이름이 k8s-hub.yml 이던 때의 표식. 바꾸면 노드의 multipath.conf 에 같은 블록이 한 번 더 들어가므로 그대로 둡니다
        block: |
          blacklist {
              devnode "^sd[a-z0-9]+"
          }
      register: multipath
    - name: multipathd 재시작
      ansible.builtin.systemd:
        name: multipathd
        state: restarted
      when: multipath.changed
    - name: Longhorn 디스크가 있는지
      ansible.builtin.stat:
        path: "{{ longhorn_dev }}"
      register: longhorn_disk
      failed_when: not longhorn_disk.stat.exists
    - name: 파일시스템 (비어 있을 때만)
      community.general.filesystem:
        dev: "{{ longhorn_dev }}"
        fstype: ext4
    - name: 늘어난 디스크 크기 다시 읽기
      ansible.builtin.shell: echo 1 > /sys/class/block/$(basename $(readlink -f {{ longhorn_dev }}))/device/rescan
      changed_when: false
    - name: 파일시스템을 디스크 크기에 맞춤 (디스크를 늘렸을 때)
      community.general.filesystem:
        dev: "{{ longhorn_dev }}"
        fstype: ext4
        resizefs: true
    - name: /var/lib/longhorn 에 마운트
      ansible.posix.mount:
        path: /var/lib/longhorn
        src: "{{ longhorn_dev }}"
        fstype: ext4
        opts: defaults,discard,nofail
        state: mounted

# 옛 노드 빼기 (목록에서 retire: true). 한 대씩, 기준 control plane 의 kubectl 로 비우고 지웁니다
- name: etcd 리더 감시 (control plane. 원격 투표자가 리더가 되면 이 노드로 되돌림)
  hosts: k8s_control_planes
  become: true
  gather_facts: false
  tasks:
    - name: 패키지
      ansible.builtin.apt:
        name: [curl, jq]
    - name: 감시 스크립트
      ansible.builtin.copy:
        src: ../scripts/etcd-leader-guard.sh
        dest: /usr/local/sbin/etcd-leader-guard
        mode: "0755"
      notify: etcd-leader-guard 재시작
    - name: 서비스 유닛
      ansible.builtin.copy:
        dest: /etc/systemd/system/etcd-leader-guard.service
        mode: "0644"
        content: |
          # proxmox-ansible 의 playbooks/k8s-cluster.yml 이 만듭니다. 직접 고치지 마세요.
          [Unit]
          Description=etcd 리더가 원격 투표자(etcd-witness)로 넘어가면 이 노드로 되돌림
          After=network-online.target
          Wants=network-online.target

          [Service]
          ExecStart=/usr/local/sbin/etcd-leader-guard
          Restart=always
          RestartSec=5

          [Install]
          WantedBy=multi-user.target
      notify: etcd-leader-guard 재시작
    - name: 서비스 켜기
      ansible.builtin.systemd:
        name: etcd-leader-guard
        enabled: true
        state: started
        daemon_reload: true
  handlers:
    - name: etcd-leader-guard 재시작
      ansible.builtin.systemd:
        name: etcd-leader-guard
        state: restarted
        daemon_reload: true

- name: 옛 노드 빼기
  hosts: k8s_retire
  become: true
  gather_facts: false
  serial: 1
  vars:
    leader: "{{ groups['k8s_cp'][0] }}"
    kubectl: kubectl --kubeconfig /etc/kubernetes/admin.conf
  tasks:
    - name: 노드가 클러스터에 있는지
      ansible.builtin.command: "{{ kubectl }} get node {{ inventory_hostname }} -o name"
      delegate_to: "{{ leader }}"
      register: node_exists
      changed_when: false
      failed_when: false
    - name: 비우기 (drain)
      ansible.builtin.command: "{{ kubectl }} drain {{ inventory_hostname }} --ignore-daemonsets --delete-emptydir-data --timeout=600s"
      delegate_to: "{{ leader }}"
      when: node_exists.rc == 0
    - name: kubeadm reset (control plane 은 etcd 멤버도 제거)
      ansible.builtin.command: kubeadm reset -f
      when: node_exists.rc == 0
      failed_when: false                 # VM 이 이미 꺼져 있으면 건너뜁니다
    - name: 노드 삭제 (VIP 를 가졌던 control plane 을 뺐으면 VIP 가 넘어가는 동안 다시 시도)
      ansible.builtin.command: "{{ kubectl }} delete node {{ inventory_hostname }}"
      delegate_to: "{{ leader }}"
      register: node_delete
      until: node_delete.rc == 0
      retries: 12
      delay: 5
      when: node_exists.rc == 0
    # Longhorn 은 사라진 노드의 복제본·노드 기록을 스스로 지우지 않습니다. 복제본을 지우면 남은 노드에 바로 다시 만듭니다
    - name: Longhorn 에서 이 노드의 복제본·노드 기록 지우기
      ansible.builtin.shell: |
        {{ kubectl }} -n longhorn-system get nodes.longhorn.io {{ inventory_hostname }} >/dev/null 2>&1 || exit 0
        for r in $({{ kubectl }} -n longhorn-system get replicas.longhorn.io -o jsonpath='{range .items[?(@.spec.nodeID=="{{ inventory_hostname }}")]}{.metadata.name} {end}'); do
          {{ kubectl }} -n longhorn-system delete replicas.longhorn.io $r
        done
        {{ kubectl }} -n longhorn-system patch nodes.longhorn.io {{ inventory_hostname }} --type merge -p '{"spec":{"allowScheduling":false}}'
        {{ kubectl }} -n longhorn-system delete nodes.longhorn.io {{ inventory_hostname }} --ignore-not-found
        echo CHANGED
      delegate_to: "{{ leader }}"
      register: longhorn_cleanup
      changed_when: "'CHANGED' in longhorn_cleanup.stdout"
    # local-path 볼륨은 노드에 묶여 있어 파드가 다른 노드로 못 갑니다. 무엇을 할지(PVC 를 지우고 새로 받을지)는 앱마다 달라 알려만 줍니다
    - name: 이 노드에 묶인 local-path PVC
      ansible.builtin.shell: |
        {{ kubectl }} get pv -o jsonpath='{range .items[*]}{.spec.storageClassName} {.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]} {.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}{end}' \
          | awk '$1=="local-path" && $2=="{{ inventory_hostname }}" {print $3}'
      delegate_to: "{{ leader }}"
      register: pinned
      changed_when: false
    - name: 남은 local-path PVC (지우고 새로 받을지 정해야 함)
      ansible.builtin.debug:
        msg: "{{ pinned.stdout_lines }}"
      when: pinned.stdout_lines | length > 0
    - name: VM 삭제 (ID 와 이름이 모두 맞을 때만)
      community.proxmox.proxmox_kvm:
        node: "{{ node_pve }}"
        vmid: "{{ node_vmid }}"
        name: "{{ inventory_hostname }}"
        state: absent
        force: true
        timeout: 120
      delegate_to: localhost
      become: false

# 노드마다 VM 이 있는 Proxmox 노드를 라벨로 붙입니다. 배치 정책(k8s-gitops 의 Kyverno prefer-role-host)이
# 이 라벨로 역할별 서버(CPU 작업 pve01, GPU 작업 pve02, 그 밖 pve03)를 고릅니다. 이 플레이만: -e k8s_cluster=<이름> --tags node-labels
- name: 노드 라벨 (eu4ng.com/pve)
  hosts: k8s_cp
  become: true
  gather_facts: false
  tags: [node-labels]
  tasks:
    - name: eu4ng.com/pve = VM 이 있는 Proxmox 노드
      ansible.builtin.shell: |
        K="kubectl --kubeconfig /etc/kubernetes/admin.conf"
        cur=$($K get node {{ item.name }} -o jsonpath='{.metadata.labels.eu4ng\.com/pve}')
        [ "$cur" = "{{ item.pve | default(proxmox_node) }}" ] && exit 0
        $K label node {{ item.name }} eu4ng.com/pve={{ item.pve | default(proxmox_node) }} --overwrite
        echo CHANGED
      loop: "{{ kc.nodes | rejectattr('retire', 'defined') | list }}"
      loop_control: { label: "{{ item.name }}" }
      register: node_label
      changed_when: "'CHANGED' in node_label.stdout"

# CoreDNS 를 노드마다 하나씩 두고 kube-dns 가 같은 노드의 CoreDNS 를 먼저 쓰게 합니다. etcd 과반이 깨져 API 가 멈추면 엔드포인트가
# 갱신되지 않아, 죽은 노드의 CoreDNS 로 가는 조회가 실패합니다(2벌이면 절반). 같은 노드의 CoreDNS 는 마지막으로 받은 레코드로 계속 답합니다.
# kubeadm upgrade 가 CoreDNS 설정을 되돌리므로 업그레이드 뒤 다시 실행합니다: -e k8s_cluster=<이름> --tags dns
- name: CoreDNS 노드마다 하나
  hosts: k8s_cp
  become: true
  gather_facts: false
  tags: [dns]
  tasks:
    # cordon 한 노드는 받을 수 없으므로 빼고 셉니다(넣으면 남는 파드가 Pending 이고 롤아웃이 멈춤). 노드를 다시 들이면 다시 실행합니다
    - name: CoreDNS 를 받을 수 있는 노드 수
      ansible.builtin.shell: >-
        kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o jsonpath='{range .items[*]}{.spec.unschedulable}{"\n"}{end}'
        | grep -vc true
      register: dns_nodes
      changed_when: false
    - name: coredns Deployment (노드마다 하나, control plane 에도)
      ansible.builtin.command:
        argv:
          - kubectl
          - --kubeconfig=/etc/kubernetes/admin.conf
          - -n=kube-system
          - patch
          - deployment/coredns
          - --type=strategic
          - -p
          - "{{ patch | to_json }}"
      vars:
        patch:
          spec:
            replicas: "{{ dns_nodes.stdout | int }}"
            # 한 노드에 하나만 두므로 새 파드가 들어갈 빈 노드가 없습니다. 옛 파드를 먼저 하나씩 내립니다
            strategy: { rollingUpdate: { maxSurge: 0, maxUnavailable: 1 } }
            template:
              spec:
                affinity:
                  podAntiAffinity:
                    requiredDuringSchedulingIgnoredDuringExecution:
                      - labelSelector: { matchLabels: { k8s-app: kube-dns } }
                        topologyKey: kubernetes.io/hostname
                tolerations:
                  - { key: CriticalAddonsOnly, operator: Exists }
                  - { key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule }
      register: coredns_patch
      changed_when: "'(no change)' not in coredns_patch.stdout"
    - name: kube-dns 가 같은 노드의 CoreDNS 를 먼저 씀
      ansible.builtin.command: >-
        kubectl --kubeconfig=/etc/kubernetes/admin.conf -n kube-system patch service/kube-dns --type=merge
        -p '{"spec":{"trafficDistribution":"PreferSameNode"}}'
      register: kube_dns_patch
      changed_when: "'(no change)' not in kube_dns_patch.stdout"

- name: 확인
  hosts: k8s_cp
  become: true
  gather_facts: false
  tasks:
    - name: 모든 노드 Ready 대기
      ansible.builtin.command: kubectl --kubeconfig /etc/kubernetes/admin.conf wait --for=condition=Ready nodes --all --timeout=300s
      changed_when: false
    - name: 노드 목록
      ansible.builtin.command: kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide
      register: nodes
      changed_when: false
    - name: 결과
      ansible.builtin.debug:
        msg: "{{ nodes.stdout_lines }}"
    - name: 노드 수가 맞는지
      ansible.builtin.assert:
        that: (nodes.stdout_lines | length - 1) == (kc.nodes | rejectattr('retire', 'defined') | list | length)

# 노드 이름·주소가 바뀌었을 수 있으므로 내부망 DNS 의 호스트·역할 이름(kubectl-<클러스터> 등)을 다시 만듭니다
- import_playbook: lan-dns.yml
```
{: file="playbooks/k8s-cluster.yml" }
{% endraw %}

</details>

<details markdown="1">
<summary>playbooks/tasks/keepalived.yml 전문</summary>

{% raw %}
```yaml
# control plane 노드의 keepalived(VRRP). k8s-cluster.yml 이 include 합니다. API VIP(kc.vip)와, service_vip 가 있는 클러스터는 서비스 VIP 도 가집니다.
# kube-vip 은 리더를 쿠버네티스 API 리스로 뽑아서 etcd 과반이 깨져 API 가 멈추면 VIP 를 놓았습니다(살아 있는 노드의 서비스까지 끊김).
# keepalived 는 API 없이 control plane 끼리 VRRP unicast 로 정합니다. 우선순위는 모두 100 이고 nopreempt 라 VIP 를 가진 노드가 계속 가지며, 그 노드의
# apiserver(6443)가 응답하지 않고 다른 control plane 의 apiserver 는 응답하면 FAULT 로 VIP 를 놓아 그쪽으로 넘어갑니다(nopreempt 라 우선순위
# 감점으로는 넘어가지 않음). 모두 응답하지 않으면(과반을 잃어 apiserver 가 재시작을 반복) 검사가 성공으로 답해 살아 있는 노드가 VIP 를 계속 가집니다.
# 서비스 VIP 로 들어온 요청은 kube-proxy 가 Service 의 externalIPs 규칙으로 받습니다(k8s-gitops iot/clusters/<지역>).
- name: kube-vip 내리기 (같은 클러스터의 모든 control plane 에서 먼저. 두 방식이 한 VIP 를 동시에 갖지 않게)
  ansible.builtin.shell: |
    set -e
    M=/etc/kubernetes/manifests/kube-vip.yaml
    [ -e $M ] || [ -e /etc/kubernetes/kube-vip.conf ] || exit 0
    rm -f $M
    for i in $(seq 60); do pgrep -x kube-vip >/dev/null || break; sleep 2; done
    if pgrep -x kube-vip >/dev/null; then echo "kube-vip 이 내려가지 않음" >&2; exit 1; fi
    rm -f /etc/kubernetes/kube-vip.conf
    # kube-vip 이 내려가며 놓지 못한 VIP 를 지웁니다(keepalived 를 켜기 전이라 이 노드에 남은 것은 kube-vip 것)
    for ip in {{ keepalived_vips | join(' ') }}; do ip -4 addr del "$ip/32" dev {{ k8s_vip_interface }} 2>/dev/null || true; done
    echo CHANGED
  register: kube_vip_down
  changed_when: "'CHANGED' in kube_vip_down.stdout"
  delegate_to: "{{ item }}"
  loop: "{{ groups.k8s_control_planes }}"
  run_once: true
- name: keepalived 설치
  ansible.builtin.apt:
    name: keepalived
    state: present
- name: apiserver 검사 스크립트
  ansible.builtin.copy:
    dest: /etc/keepalived/check-apiserver.sh
    mode: "0755"
    content: |
      #!/bin/bash
      # keepalived track_script. 이 노드의 apiserver 가 6443 에서 연결을 받으면 성공입니다. 받지 못하면 다른 control plane 중
      # 하나라도 받을 때만 실패해 FAULT 로 VIP 를 놓습니다(nopreempt 라 우선순위 감점으로는 넘어가지 않음).
      # 모두 받지 못하면 성공으로 두어 누군가는 VIP 를 계속 가집니다(etcd 과반을 잃은 경우)
      timeout 1 bash -c '</dev/tcp/127.0.0.1/6443' && exit 0
      for ip in {{ kc.nodes | rejectattr('retire', 'defined') | selectattr('role', 'equalto', 'control-plane') | rejectattr('name', 'equalto', inventory_hostname) | map(attribute='ip') | join(' ') }}; do
        timeout 1 bash -c "</dev/tcp/$ip/6443" && exit 1
      done
      exit 0
- name: keepalived 설정
  ansible.builtin.template:
    src: ../templates/keepalived/keepalived.conf.j2
    dest: /etc/keepalived/keepalived.conf
    mode: "0644"
  register: keepalived_conf
- name: keepalived 켜기
  ansible.builtin.systemd:
    name: keepalived
    enabled: true
    state: "{{ 'restarted' if keepalived_conf.changed else 'started' }}"
  ignore_errors: "{{ ansible_check_mode }}"   # --check 에서는 패키지가 아직 없을 수 있음
- name: VIP 응답 대기
  ansible.builtin.uri:
    url: https://{{ kc.vip }}:6443/livez
    validate_certs: false
    return_content: true
  register: vip_live
  until: vip_live.status == 200
  retries: 60
  delay: 3
  when: not ansible_check_mode and keepalived_wait_api | default(true)
```
{: file="playbooks/tasks/keepalived.yml" }
{% endraw %}

</details>

<details markdown="1">
<summary>templates/keepalived/keepalived.conf.j2 전문</summary>

{% raw %}
```text
# {{ ansible_managed }} — proxmox-ansible playbooks/tasks/keepalived.yml
{% set me = kc.nodes | selectattr('name', 'equalto', inventory_hostname) | first %}
{% set peers = kc.nodes | rejectattr('retire', 'defined') | selectattr('role', 'equalto', 'control-plane') | rejectattr('name', 'equalto', inventory_hostname) | map(attribute='ip') | list %}
global_defs {
    router_id {{ inventory_hostname }}
    script_user root
    enable_script_security
}

# 이 노드의 apiserver 가 응답하지 않고 다른 control plane 은 응답하면 FAULT 로 VIP 를 놓습니다. 모두 응답하지 않으면 놓지 않습니다
# (검사 스크립트가 판정, 모든 control plane 이 실패해도 누군가는 가짐). weight 를 두지 않는 것은 nopreempt 라 우선순위 감점으로는 넘어가지 않기 때문입니다
vrrp_script apiserver {
    script "/etc/keepalived/check-apiserver.sh"
    interval 2
    timeout 4
    fall 3
    rise 2
}

vrrp_instance k8s_{{ k8s_cluster_name }} {
    state BACKUP
    interface {{ k8s_vip_interface }}
    virtual_router_id {{ kc.vrrp_id }}
    # 우선순위는 모두 같고 nopreempt 라, VIP 를 가진 노드가 죽거나 FAULT 일 때만 넘어가고 돌아온 노드가 다시 빼앗지 않습니다(특정 노드에 묶지 않음)
    priority 100
    nopreempt
    advert_int 1
    # 멀티캐스트 대신 상대 control plane 에 직접 보냅니다
    unicast_src_ip {{ me.ip }}
    unicast_peer {
{% for ip in peers %}
        {{ ip }}
{% endfor %}
    }
    virtual_ipaddress {
{% for ip in keepalived_vips %}
        {{ ip }}/32 dev {{ k8s_vip_interface }}
{% endfor %}
    }
    track_script {
        apiserver
    }
}
```
{: file="templates/keepalived/keepalived.conf.j2" }
{% endraw %}

</details>

> VIP 없이(`--control-plane-endpoint` 없이) 만든 클러스터에는 control plane 을 더할 수 없습니다. [클러스터 스크립트](/posts/32/)나 예전 플레이북으로 만든 클러스터라면 먼저 첫 control plane 에서 [`k8s-control-plane-endpoint.sh`](/assets/scripts/proxmox/k8s-control-plane-endpoint.sh) 를 `sudo bash k8s-control-plane-endpoint.sh [VIP] eth0` 으로 실행해 VIP 엔드포인트로 옮깁니다. 스크립트는 이 노드 하나만 둔 keepalived 로 VIP 를 띄우고(맨 위 `VRRP_ID` 를 클러스터의 `vrrp_id` 와 맞춥니다), 상대 control plane 과 worker 의 kubelet 주소는 플레이북이 맞춥니다.
{: .prompt-info }

```bash
# 실행. 2단계의 PROXMOX_* 환경변수가 필요합니다 (마지막의 내부망 DNS 플레이북도 씁니다)
ansible-playbook playbooks/k8s-cluster.yml -e k8s_cluster=hub
ansible-playbook playbooks/k8s-cluster.yml -e k8s_cluster=daejeon
```

> `VM 설정 맞추기` 태스크는 `proxmox_kvm` 모듈이 변경 여부를 비교하지 않아 실행할 때마다 `changed` 로 표시됩니다. 값이 같으면 VM 에는 아무 일도 일어나지 않습니다. 코어와 메모리를 바꾼 값은 VM 을 껐다 켜야 적용됩니다.
{: .prompt-info }

- **확인:** `결과` 태스크에 목록의 노드가 모두 `Ready` 로 보이고, `노드 수가 맞는지` 가 통과하며, `PLAY RECAP` 에 `failed=0` 입니다. 실행 PC 에 `~/.kube/k8s-hub.yaml`(엣지는 `k8s-daejeon.yaml`)이 생깁니다.

> control plane 이 두 대면 etcd 멤버도 두 개라, 한 대가 꺼지면 [과반](/posts/61/)을 잃어 API 가 멈춥니다. 그래서 Proxmox 노드마다 control plane 을 하나씩 두어 3멤버로 만듭니다. 세 번째 서버가 없을 때는 [쿠버네티스 etcd 세 번째 투표자를 원격 NAS 컨테이너로 붙이는 방법](/posts/55/)으로 세 번째 표를 채울 수 있습니다.
{: .prompt-warning }

## 4. 확인

실행 PC 로 가져온 kubeconfig 는 API 주소가 VIP 입니다.

```bash
# 노드와 CoreDNS (실행 PC 에 kubectl 이 없다면 ssh ubuntu@kubectl-hub.[DOMAIN] 에서 kubectl 만 실행)
kubectl --kubeconfig ~/.kube/k8s-hub.yaml get nodes -o wide
kubectl --kubeconfig ~/.kube/k8s-hub.yaml -n kube-system get pods -l k8s-app=kube-dns -o wide

# keepalived 와 VIP 를 가진 control plane
for h in k8s-hub-cp-1 k8s-hub-cp-2 k8s-hub-cp-3; do ssh ubuntu@$h.[DOMAIN] "systemctl is-active keepalived; ip -br addr show eth0"; done

# VIP 응답
curl -k https://[HUB_VIP]:6443/livez

# Longhorn 전용 디스크 (worker)
ssh ubuntu@k8s-hub-worker-1.[DOMAIN] findmnt /var/lib/longhorn
```

- **확인:** 노드 여섯 대가 `Ready` 이고 `VERSION` 이 `v1.37.0`, CoreDNS 파드가 노드마다 하나씩 `Running`, keepalived 가 세 control plane 에서 `active` 이고 VIP(`[HUB_VIP]/32`)는 control plane 한 대의 `eth0` 에만 보이며, `livez` 가 `ok`, `findmnt` 에 두 번째 디스크(`/dev/sdb`)가 `/var/lib/longhorn` 에 ext4 로 마운트되어 보입니다.

다음은 [쿠버네티스에 Argo CD 설치하고 GitOps로 서비스 추가하는 방법](/posts/36/)부터 이어집니다. 지역 엣지는 허브 Argo CD 에 원격 클러스터로 등록합니다([Proxmox에 Ansible로 kubeadm 엣지 클러스터 만들고 Argo CD 원격 클러스터로 등록하는 방법](/posts/42/)). Longhorn 과 DB 이중화는 [쿠버네티스에 Longhorn과 Patroni로 볼륨과 TimescaleDB 이중화하는 방법](/posts/54/)에 정리했습니다.

## 5. 노드 교체

노드를 바꿀 때는 새 노드를 목록에 더해 합류시킨 뒤, 옛 노드 항목에 `retire: true` 를 붙여 다시 실행합니다.

```yaml
      # 2. 새 노드가 합류한 뒤 옛 노드에 retire: true 를 붙이고 다시 실행해 뺍니다
      - { name: k8s-hub-cp-1, pve: pve01, role: control-plane, vmid: 121, ip: [HUB_CP_1_IP], cores: 2, memory: 4096, disk: 32G, retire: true }
      # (나머지 노드는 그대로)
      # 1. 새 노드를 목록에 더하고 실행해 합류시킵니다
      - { name: k8s-hub-cp-4, pve: pve01, role: control-plane, vmid: 127, ip: [NEW_NODE_IP], cores: 2, memory: 4096, disk: 32G }
```
{: file="group_vars/all.yml" }

```bash
# 목록을 고칠 때마다 실행
ansible-playbook playbooks/k8s-cluster.yml -e k8s_cluster=hub
```

`retire: true` 인 노드는 한 대씩 drain → `kubeadm reset`(control plane 은 etcd 멤버도 제거) → 노드 삭제 → Longhorn 의 복제본·노드 기록 삭제 → VM 삭제 순서로 빠집니다. 첫 control plane 을 바꿔도 `admin.conf` 가 있는 다른 control plane 이 기준 노드가 되므로 새 클러스터를 만들지 않습니다. 끝에서 내부망 DNS 를 다시 만들어 `kubectl-hub` 같은 역할 이름이 목록의 첫 control plane 을 따라갑니다. 다 빠지면 옛 항목을 목록에서 지웁니다.

> local-path 볼륨은 노드에 묶여 있어 파드가 다른 노드로 옮겨 가지 못합니다. 플레이북은 빼는 노드에 묶인 local-path PVC 를 `남은 local-path PVC` 태스크로 알려 주기만 하므로, PVC 를 지우고 새로 받을지 앱마다 정합니다.
{: .prompt-warning }

- **확인:** `kubectl get nodes` 와 `kubectl -n longhorn-system get nodes.longhorn.io` 에 옛 노드가 없고, 호스트의 `qm list` 에서 옛 VM 이 사라졌습니다.

## 6. 클러스터 삭제

클러스터를 지울 때는 삭제 모드로 실행합니다. `yes` 를 입력해야 진행하고, 목록의 VM ID 와 이름이 **모두** 일치하는 VM 만 지웁니다. 이름이 다른 VM 이 같은 ID 를 쓰고 있으면 건너뜁니다.

```bash
# 목록의 노드 VM 과 디스크 삭제 (템플릿은 그대로)
ansible-playbook playbooks/k8s-cluster.yml -e k8s_cluster=[CLUSTER] -e k8s_state=absent
```

> 운영 중인 클러스터를 지우면 노드의 PVC 데이터도 함께 사라집니다. 먼저 백업이 있는지 확인합니다.
{: .prompt-danger }

- **확인:** 모든 노드의 `qm list` 에서 목록의 VM 이 사라지고 다른 VM 은 그대로입니다.

## 마무리

VM 템플릿과 kubeadm 클러스터를 Ansible 플레이북 두 개로 옮겨, 새 Proxmox 서버에서도 `pve-cluster.yml` → `vm-template.yml` → `k8s-cluster.yml` 순서로 같은 클러스터를 다시 만들 수 있게 했습니다. control plane 세 대와 worker 세 대가 세 Proxmox 노드에 하나씩 나뉘어 etcd 가 3멤버이고, API 는 keepalived VIP 로 받으며, 허브와 지역 엣지를 `-e k8s_cluster` 만 바꿔 같은 플레이북으로 만들고 노드를 교체합니다.

## 참고 자료

- [Kubernetes - Creating Highly Available Clusters with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/)
- [Kubernetes - Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [Kubernetes - Installing kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Keepalived - User Guide](https://keepalived.readthedocs.io/en/latest/)
- [Kubernetes - Service: Traffic distribution](https://kubernetes.io/docs/concepts/services-networking/service/#traffic-distribution)
- [Longhorn - Installation Requirements](https://longhorn.io/docs/latest/deploy/install/#installation-requirements)
- [flannel-io/flannel](https://github.com/flannel-io/flannel)
- [community.proxmox.proxmox_kvm module](https://docs.ansible.com/ansible/latest/collections/community/proxmox/proxmox_kvm_module.html)
- [community.proxmox.proxmox_disk module](https://docs.ansible.com/ansible/latest/collections/community/proxmox/proxmox_disk_module.html)
- [Proxmox VE - Cloud-Init Support](https://pve.proxmox.com/wiki/Cloud-Init_Support)
