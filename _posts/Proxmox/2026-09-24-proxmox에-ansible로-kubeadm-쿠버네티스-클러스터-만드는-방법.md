---
layout: post
title: Proxmox에 Ansible로 kubeadm 쿠버네티스 클러스터 만드는 방법
description: control plane 두 대와 worker 두 대를 Proxmox 두 노드에 나눠 두고 API 주소를 kube-vip VIP 로 받는 kubeadm 클러스터를, Ansible 플레이북 하나로 만들고 노드를 교체하고 지우는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, ansible, kubernetes, kubeadm, kube-vip, longhorn, cloud-init, homelab]
permalink: /posts/46/
---

[템플릿 스크립트](/posts/33/)와 [클러스터 스크립트](/posts/32/)로 하던 일을 Ansible 플레이북으로 옮겨, CT·VM 을 만드는 모든 절차를 `proxmox-ansible` 저장소 하나에 모읍니다. 템플릿 플레이북이 Proxmox 노드마다 Ubuntu 24.04 클라우드 이미지로 VM 템플릿을 만들고, 클러스터 플레이북이 그 템플릿을 복제해 노드 VM 을 만든 뒤 [kubeadm](/posts/60/) 클러스터를 구성합니다. control plane 과 worker 를 두 대씩 두 Proxmox 노드에 나눠 두고, API 주소는 **kube-vip** 이 ARP 로 띄우는 VIP 로 받아 control plane 한 대가 꺼져도 같은 주소로 붙습니다. 클러스터 정의는 변수 파일에 목록으로 두고 `-e k8s_cluster=<이름>` 으로 골라, 중앙 허브와 지역 엣지를 같은 플레이북으로 만듭니다. 여러 번 실행해도 결과가 같고, 노드 교체와 삭제도 같은 플레이북으로 합니다.

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
| Proxmox VE | `9.2` (두 노드) |
| Ansible | `13.1` (ansible-core `2.20`, community.proxmox `1.4`) |
| Kubernetes | `v1.37.0` (kubeadm, containerd `2.2`) |
| kube-vip | `v1.2.4` |
| Flannel | `v0.28.9` |
| 작성 기준일 | `2026-09-28` |

다음 항목이 준비되어 있어야 합니다.

- Proxmox 두 대의 클러스터와 Tailscale 서브넷 라우터 ([Proxmox 두 대를 클러스터로 묶고 원격 NAS에 QDevice 붙이는 방법](/posts/53/)). VM 은 원격지(tailnet)로 가는 패킷을 자기 Proxmox 노드로 보냅니다.
- `proxmox-ansible` 저장소 골격, API 토큰, 내부망 DNS 플레이북(`playbooks/lan-dns.yml`, `templates/dnsmasq-lan.conf.j2`) ([Proxmox에 Ansible로 내부망 DNS 컨테이너 만드는 방법](/posts/41/)). 클러스터 플레이북이 끝에서 내부망 DNS 플레이북을 다시 실행합니다.
- 실행 PC 의 SSH 키(`~/.ssh/id_ed25519.pub`)가 `group_vars/all.yml` 의 `ct_ssh_pubkey` 에 들어 있어야 합니다. 이 키가 템플릿에 들어가 복제한 VM 에 Ansible 이 접속합니다.
- 노드마다 비어 있는 VM ID 와 고정 IP, 클러스터마다 비어 있는 [VIP](/posts/69/) 하나(LoadBalancer 서비스를 받을 엣지는 서비스 VIP 하나 더). VIP 는 공유기 DHCP 가 나눠 주지 않는 주소로 고릅니다.

## 1. 변수 채우기

`group_vars/all.yml` 에 템플릿과 클러스터 값을 추가합니다. `k8s_clusters` 아래에 클러스터마다 노드 목록을 두고, 노드마다 VM 을 둘 Proxmox 노드(`pve`)와 역할(`role`)을 적습니다. `role: control-plane` 인 첫 노드에서 클러스터를 만들고 나머지 control plane 과 worker 가 합류합니다. `longhorn_disk` 가 있는 노드에는 Longhorn 이 복제 볼륨을 두는 전용 디스크를 붙입니다. [내부망 DNS 글](/posts/41/)에서 허브 VIP 만 넣어 둔 `k8s_clusters` 는 이 목록으로 바꿉니다.

{% raw %}
```yaml
vm_template_vmid: 9000                        # playbooks/vm-template.yml 이 노드마다 만드는 Ubuntu 클라우드 이미지 템플릿 (SSH 키·qemu-guest-agent 포함). 노드별 값은 inventory
vm_template_name: ubuntu-2404-cloud
vm_template_image_url: https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
vm_template_user: ubuntu                      # 복제한 VM 의 접속 계정 (cloud-init)
vm_snippet_storage: local                     # cloud-init vendor 스니펫을 둘 디렉터리형 스토리지
vm_disk_storage: local-lvm                    # VM 디스크를 두는 스토리지 (lvmthin 이라 포맷은 raw)
vm_bridge: vmbr0
tailscale_cidr: 100.64.0.0/10                 # tailnet 주소 대역. 쿠버네티스 VM 은 이 대역을 자기 Proxmox 호스트로 보냄(k8s-cluster.yml)

# ---- k8s-cluster: kubeadm 쿠버네티스 클러스터 (허브와 지역 엣지) ----
# playbooks/k8s-cluster.yml -e k8s_cluster=<이름> 으로 k8s_clusters 의 한 클러스터를 만듭니다(기본 hub).
# 노드마다 pve(VM 을 둘 Proxmox 노드), role(control-plane|worker)을 둡니다. role 이 control-plane 인 첫 항목에서 클러스터를 만들고
# 나머지 control-plane 은 합류합니다. 두 Proxmox 노드에 나눠 한 대가 죽어도 버티고, etcd 세 번째 멤버는 원격 NAS 컨테이너가 맡습니다.
# longhorn_disk(GB): Longhorn 이 복제 볼륨을 두는 전용 디스크(scsi1, /var/lib/longhorn).
k8s_cluster_name: "{{ k8s_cluster | default('hub') }}"
kc: "{{ k8s_clusters[k8s_cluster_name] }}"   # 지금 다루는 클러스터
k8s_clusters:
  hub:                                        # 중앙 허브
    nodes:
      - { name: k8s-hub-cp-1, pve: pve01, role: control-plane, vmid: 121, ip: [HUB_CP_1_IP], cores: 2,  memory: 4096,  disk: 32G }
      - { name: k8s-hub-cp-2, pve: pve02, role: control-plane, vmid: 122, ip: [HUB_CP_2_IP], cores: 2,  memory: 2560,  disk: 32G }
      - { name: k8s-hub-worker-1, pve: pve01, role: worker,    vmid: 123, ip: [HUB_WORKER_1_IP], cores: 24, memory: 24576, disk: 100G, longhorn_disk: 20 }
      - { name: k8s-hub-worker-2, pve: pve02, role: worker,    vmid: 124, ip: [HUB_WORKER_2_IP], cores: 8,  memory: 5120,  disk: 60G,  longhorn_disk: 20 }
    dns_name: hub                             # 내부망 DNS 역할 이름 k8s-hub(VIP), kubectl-hub(kubectl 을 돌릴 control plane). templates/dnsmasq-lan.conf.j2
    vip: [HUB_VIP]                            # API 엔드포인트(kube-vip, ARP). control plane 중 한 대가 가짐
    control_plane_workloads: false            # control plane 에 일반 파드를 두지 않음(taint 유지)
    kube_vip_services: false
    kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/k8s-hub.yaml"   # 실행 PC 에 저장할 kubeconfig
  daejeon:                                    # 지역 엣지. 허브 없이 혼자 돕니다
    nodes:
      - { name: k8s-dj-cp-1,     pve: pve01, role: control-plane, vmid: 131, ip: [EDGE_CP_1_IP], cores: 2, memory: 2560, disk: 32G }
      - { name: k8s-dj-cp-2,     pve: pve02, role: control-plane, vmid: 132, ip: [EDGE_CP_2_IP], cores: 2, memory: 2048, disk: 32G }
      - { name: k8s-dj-worker-1, pve: pve01, role: worker,        vmid: 133, ip: [EDGE_WORKER_1_IP], cores: 4, memory: 4096, disk: 40G, longhorn_disk: 20 }
      - { name: k8s-dj-worker-2, pve: pve02, role: worker,        vmid: 134, ip: [EDGE_WORKER_2_IP], cores: 2, memory: 3584, disk: 40G, longhorn_disk: 20 }
    dns_name: dj                              # 내부망 DNS 역할 이름 k8s-dj, kubectl-dj, iot-dj(서비스 VIP)
    vip: [EDGE_VIP]
    service_vip: [EDGE_SERVICE_VIP]           # LoadBalancer 서비스 VIP. 서비스의 kube-vip.io/loadbalancerIPs 와 같아야 함
    lan_dns_names: [ha-dj, z2m-dj, matter-dj, grafana-dj]   # 내부망에서 service_vip(지역 Traefik)로 답할 지역 서비스 이름
    control_plane_workloads: false
    kube_vip_services: true                   # LoadBalancer Service 에 VIP 를 줌(service_vip)
    otbr_host: true                           # OpenThread Border Router(hostNetwork)용 커널 설정
    kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/k8s-daejeon.yaml"
k8s_etcd_peer_sans: [[PVE01_TAILSCALE_IP], [PVE02_TAILSCALE_IP]]   # 원격 etcd 멤버(NAS)가 보는 우리 쪽 주소: Proxmox 노드의 Tailscale IP(마스커레이드)
k8s_vip_interface: eth0
k8s_kube_vip_version: v1.2.4                  # https://github.com/kube-vip/kube-vip/releases
k8s_nameservers: [[LAN_DNS_IP], [LAN_DNS_2_IP]]
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

템플릿 플레이북은 Proxmox 노드마다 클라우드 이미지를 내려받아 VM 을 만들고 템플릿으로 바꿉니다. VM ID 는 클러스터 전체에서 하나라, 두 번째 노드의 템플릿 번호는 inventory 의 `vm_template_vmid`(예: `9001`)로 따로 줍니다([Proxmox 클러스터 글](/posts/53/)의 4단계). 모든 복제 VM 에 적용할 cloud-init vendor 스니펫(qemu-guest-agent 설치, SSH 호스트 키 유지)을 호스트의 스니펫 스토리지에 두고, VM 에 넣을 공개키로는 실행 PC 키와 호스트의 `authorized_keys`, 호스트 키를 합쳐 넣습니다. 같은 ID 의 템플릿이 이미 있으면 아무것도 하지 않고, 같은 ID 가 템플릿이 아닌 VM 이면 멈춥니다.

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
            { echo '{{ ct_ssh_pubkey }}'; cat /root/.ssh/authorized_keys 2>/dev/null; echo; cat {{ host_key }}.pub; } \
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

- **확인:** `PLAY RECAP` 에 `failed=0`, 첫 번째 노드에서 `qm config 9000`, 두 번째 노드에서 `qm config 9001` 에 `template: 1`, `sshkeys:`, `cicustom: vendor=local:snippets/ubuntu-cloud-vendor.yaml` 이 보입니다. 한 번 더 실행하면 `changed=0` 입니다.

## 3. 클러스터 만들기

클러스터 플레이북은 아래 순서로 진행합니다.

- VM 만들기: 노드 목록을 인벤토리 그룹으로, 노드마다 정한 Proxmox 노드의 템플릿 복제, 디스크 늘리기(복제 직후 한 번), Longhorn 디스크(`scsi1`) 추가, 코어·메모리·IP·DNS 설정, 시작
- 노드 공통: 시간대, swap 끄기, 커널 모듈·설정, tailnet 경로, 엣지의 OpenThread Border Router 커널 설정, containerd 와 `k8s_package_version` 으로 고정한 kubelet·kubeadm·kubectl
- control plane 기준 노드 고르기: `admin.conf` 가 있는 control plane 을 기준으로 삼고, 클러스터가 없는데 VIP 가 이미 응답하면 멈춤
- control plane: kube-vip, `kubeadm init --control-plane-endpoint=<VIP>:6443 --kubernetes-version=...`(처음 한 번), Flannel, etcd peer 인증서 SAN, join 명령, kubeconfig 를 실행 PC 로
- control plane 합류: 한 대씩 `kubeadm join --control-plane`, kube-vip
- worker 합류: `kubeadm join`, kubelet 이 VIP 로 붙게
- Longhorn 준비: `open-iscsi`·`nfs-common`, `iscsi_tcp` 모듈, multipath 에서 `sd` 장치 제외, 전용 디스크를 ext4 로 `/var/lib/longhorn` 에 마운트
- 옛 노드 빼기: `retire: true` 가 붙은 노드(5단계)
- 확인: 모든 노드 Ready, 노드 수
- 내부망 DNS: `lan-dns.yml` 을 다시 실행해 노드·역할 이름을 새로 만듦

kube-vip 은 control plane 마다 static pod 로 뜨고, 리더로 뽑힌 한 대가 VIP 를 ARP 로 알립니다. 클러스터를 처음 만들 때는 `admin.conf` 에 아직 권한이 없어 `super-admin.conf` 로 붙습니다. 엣지처럼 `kube_vip_services: true` 인 클러스터는 LoadBalancer 서비스의 VIP 도 같은 리더가 가집니다. control plane 버전은 `--kubernetes-version` 으로 설치한 kubelet·kubeadm 과 같은 버전에 고정합니다. `kubeadm init` 과 `join` 은 결과 파일(`/etc/kubernetes/admin.conf`, `kubelet.conf`)이 있으면 건너뛰므로 다시 실행해도 클러스터를 새로 만들지 않습니다.

tailnet 경로는 원격 NAS 에 둔 etcd 세 번째 투표자와 DB 복제본에 닿기 위한 것입니다. VM 은 tailnet 대역(`100.64.0.0/10`)을 자기 Proxmox 노드로 보내고, 그 노드가 Tailscale IP 로 바꿔 내보냅니다. 원격 etcd 멤버는 우리 쪽 연결을 이 주소로 보므로 `k8s_etcd_peer_sans` 를 etcd peer 인증서 SAN 에 넣습니다.

```bash
# 플레이북 내려받기 (lan-dns.yml 과 dnsmasq 템플릿은 내부망 DNS 글에서 받은 것을 씁니다)
mkdir -p playbooks/tasks
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/k8s-cluster.yml -o playbooks/k8s-cluster.yml
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/tasks/kube-vip.yml -o playbooks/tasks/kube-vip.yml
```

<details markdown="1">
<summary>playbooks/k8s-cluster.yml 전문</summary>

{% raw %}
```yaml
# kubeadm 쿠버네티스 클러스터(control plane N + worker N). group_vars 의 k8s_clusters 에서 -e k8s_cluster=<이름>(기본 hub)으로 고릅니다.
# 노드마다 정한 Proxmox 노드의 템플릿(vm-template.yml)을 복제해 VM 을 만들고, containerd·kubeadm 을 설치해 VIP(kube-vip) 엔드포인트로
# 클러스터를 구성한 뒤 kubeconfig 를 실행 PC 로 가져옵니다. 허브(hub)와 지역 엣지(daejeon 등)가 같은 절차로 만들어집니다.
# etcd 세 번째 멤버(서울 NAS)는 k8s-gitops 의 scripts/etcd-witness-certs.sh 와 stacks/seoul/etcd-witness* 로 붙입니다.
# VIP 없이 만든 기존 클러스터는 먼저 scripts/k8s-control-plane-endpoint.sh 로 옮깁니다. 그 다음은 Argo CD 설치·등록부터 GitOps 입니다.
#   ansible-playbook playbooks/k8s-cluster.yml [-e k8s_cluster=daejeon]                    만들기 (여러 번 실행해도 됨)
#   ansible-playbook playbooks/k8s-cluster.yml [-e k8s_cluster=...] -e k8s_state=absent    VM 삭제 (ID 와 이름이 모두 맞는 VM 만, yes 입력 후)
# 노드 교체: 새 노드를 목록에 더해 합류시킨 뒤, 옛 노드 항목에 retire: true 를 붙여 다시 실행하면 drain → (control plane 은 kubeadm reset 으로
# etcd 멤버 제거) → 노드 삭제 → VM 삭제 순으로 뺍니다. 다 빠지면 목록에서 지웁니다.
---
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
    - name: Longhorn 디스크 (scsi1, 없을 때만. 켜진 VM 에 핫플러그)
      community.proxmox.proxmox_disk:
        vmid: "{{ item.vmid }}"
        disk: scsi1
        storage: "{{ vm_disk_storage }}"
        size: "{{ item.longhorn_disk }}"
        format: raw
        discard: "on"
        ssd: true
        state: present
      loop: "{{ active | selectattr('longhorn_disk', 'defined') }}"
      loop_control: { label: "{{ item.name }}" }
    - name: VM 설정 맞추기 (코어·메모리·IP·DNS·자동 시작. 모듈 특성상 매번 changed 로 보고됨)
      community.proxmox.proxmox_kvm:
        node: "{{ item.pve | default(proxmox_node) }}"
        vmid: "{{ item.vmid }}"
        name: "{{ item.name }}"
        cores: "{{ item.cores }}"
        memory: "{{ item.memory }}"
        onboot: true
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
    # 원격지(서울 NAS)의 etcd 투표자·DB 복제본은 tailnet 에 있습니다. VM 이 있는 Proxmox 노드가 Tailscale 서브넷 라우터이므로
    # tailnet 대역을 그 노드로 보냅니다. VM 은 자기 노드와 함께 죽고 살므로 이 경로에는 이중화가 필요 없습니다
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
    # 새 클러스터는 VIP 엔드포인트로 만듭니다. kube-vip 은 init 중에는 super-admin.conf 로 로컬 apiserver 에 붙어 VIP 를 잡습니다
    - name: kube-vip (init 용)
      ansible.builtin.include_tasks: tasks/kube-vip.yml
      vars: { kube_vip_kubeconfig: /etc/kubernetes/super-admin.conf }
      when: not admin_conf.stat.exists
    - name: kubeadm init (처음 한 번)
      ansible.builtin.command: >-
        kubeadm init --control-plane-endpoint={{ kc.vip }}:6443 --upload-certs
        --kubernetes-version=v{{ k8s_package_version.split('-')[0] }}
        --pod-network-cidr={{ k8s_pod_cidr }} --apiserver-advertise-address={{ ansible_host }}
      args:
        creates: /etc/kubernetes/admin.conf
    - name: kube-vip
      ansible.builtin.include_tasks: tasks/kube-vip.yml
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
    # 원격 etcd 멤버는 우리 쪽 연결을 NAT 뒤 주소(Proxmox 노드의 Tailscale IP)로 봅니다. 그 주소를 peer 인증서 SAN 에 넣어
    # SAN 검사를 켠 채로 연결되게 합니다. 합류하는 control plane 은 kubeadm-config 의 이 값으로 인증서를 만듭니다
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
    - name: kube-vip
      ansible.builtin.include_tasks: tasks/kube-vip.yml
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
    - name: /var/lib/longhorn 에 마운트
      ansible.posix.mount:
        path: /var/lib/longhorn
        src: "{{ longhorn_dev }}"
        fstype: ext4
        opts: defaults,discard,nofail
        state: mounted

# 옛 노드 빼기 (목록에서 retire: true). 한 대씩, 기준 control plane 의 kubectl 로 비우고 지웁니다
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
<summary>playbooks/tasks/kube-vip.yml 전문</summary>

{% raw %}
```yaml
# control plane 노드의 kube-vip static pod. k8s-cluster.yml 이 include 합니다. kube_vip_services 가 켜진 클러스터는 LoadBalancer Service 에도 VIP 를 줍니다.
# 서비스 VIP 는 control plane VIP 와 같은 리더 한 대가 모두 가집니다(--servicesElection 을 쓰지 않음). 서비스마다 리더를 뽑으면 여러 서비스가
# 한 IP 를 나눠 쓸 때 그 IP 가 두 노드에 동시에 붙어 ARP 가 엇갈리고 연결이 끊깁니다.
# kube-vip 은 매니페스트의 hostAliases(kubernetes → 127.0.0.1)로 자기 노드의 apiserver 에 붙어 리더를 뽑고, 리더가 VIP 를 ARP 로 알립니다.
# kube_vip_kubeconfig: 기본은 admin.conf 사본(kube-vip.conf). 클러스터를 처음 만들 때만 super-admin.conf
- name: kube-vip 용 kubeconfig (admin.conf 사본, API 주소는 이 노드의 apiserver)
  ansible.builtin.shell: |
    set -e
    umask 077
    sed "s#server: https://.*:6443#server: https://{{ ansible_host }}:6443#" /etc/kubernetes/admin.conf > /etc/kubernetes/kube-vip.conf.new
    if cmp -s /etc/kubernetes/kube-vip.conf.new /etc/kubernetes/kube-vip.conf; then rm /etc/kubernetes/kube-vip.conf.new
    else mv /etc/kubernetes/kube-vip.conf.new /etc/kubernetes/kube-vip.conf; echo CHANGED; fi
  register: kube_vip_conf
  changed_when: "'CHANGED' in kube_vip_conf.stdout"
  when: kube_vip_kubeconfig is not defined
- name: kube-vip 매니페스트 만들기
  ansible.builtin.shell: |
    set -e
    IMG=ghcr.io/kube-vip/kube-vip:{{ k8s_kube_vip_version }}
    ctr -n k8s.io image pull "$IMG" >/dev/null
    ctr -n k8s.io run --rm --net-host "$IMG" kube-vip-manifest-$$ /kube-vip manifest pod \
      --interface {{ k8s_vip_interface }} --address {{ kc.vip }} --controlplane --arp --leaderElection \
      {{ '--services' if kc.kube_vip_services | default(false) else '' }} \
      --k8sConfigPath {{ kube_vip_kubeconfig | default('/etc/kubernetes/kube-vip.conf') }} </dev/null
  register: kube_vip_manifest
  changed_when: false
- name: kube-vip static pod
  ansible.builtin.copy:
    dest: /etc/kubernetes/manifests/kube-vip.yaml
    content: "{{ kube_vip_manifest.stdout }}\n"
    mode: "0600"
- name: VIP 응답 대기
  ansible.builtin.uri:
    url: https://{{ kc.vip }}:6443/livez
    validate_certs: false
    return_content: true
  register: vip_live
  until: vip_live.status == 200
  retries: 60
  delay: 3
  when: kube_vip_kubeconfig is not defined
```
{: file="playbooks/tasks/kube-vip.yml" }
{% endraw %}

</details>

> VIP 없이(`--control-plane-endpoint` 없이) 만든 클러스터에는 control plane 을 더할 수 없습니다. [클러스터 스크립트](/posts/32/)나 예전 플레이북으로 만든 클러스터라면 먼저 첫 control plane 에서 [`k8s-control-plane-endpoint.sh`](/assets/scripts/proxmox/k8s-control-plane-endpoint.sh) 를 `sudo bash k8s-control-plane-endpoint.sh [VIP] eth0` 으로 실행해 VIP 엔드포인트로 옮깁니다. worker 의 kubelet 주소는 플레이북이 VIP 로 바꿉니다.
{: .prompt-info }

```bash
# 실행. 2단계의 PROXMOX_* 환경변수가 필요합니다 (마지막의 내부망 DNS 플레이북도 씁니다)
ansible-playbook playbooks/k8s-cluster.yml -e k8s_cluster=hub
ansible-playbook playbooks/k8s-cluster.yml -e k8s_cluster=daejeon
```

> `VM 설정 맞추기` 태스크는 `proxmox_kvm` 모듈이 변경 여부를 비교하지 않아 실행할 때마다 `changed` 로 표시됩니다. 값이 같으면 VM 에는 아무 일도 일어나지 않습니다.
{: .prompt-info }

- **확인:** `결과` 태스크에 목록의 노드가 모두 `Ready` 로 보이고, `노드 수가 맞는지` 가 통과하며, `PLAY RECAP` 에 `failed=0` 입니다. 실행 PC 에 `~/.kube/k8s-hub.yaml`(엣지는 `k8s-daejeon.yaml`)이 생깁니다.

> control plane 이 두 대면 etcd 멤버도 두 개라, 한 대가 꺼지면 [과반](/posts/61/)을 잃어 API 가 멈춥니다. 세 번째 투표자는 [쿠버네티스 etcd 세 번째 투표자를 원격 NAS 컨테이너로 붙이는 방법](/posts/55/)으로 붙입니다.
{: .prompt-warning }

## 4. 확인

실행 PC 로 가져온 kubeconfig 는 API 주소가 VIP 입니다.

```bash
# 노드와 kube-vip (실행 PC 에 kubectl 이 없다면 ssh ubuntu@kubectl-hub.[DOMAIN] 에서 kubectl 만 실행)
kubectl --kubeconfig ~/.kube/k8s-hub.yaml get nodes -o wide
kubectl --kubeconfig ~/.kube/k8s-hub.yaml -n kube-system get pods -o wide | grep kube-vip

# VIP 응답
curl -k https://[HUB_VIP]:6443/livez

# Longhorn 전용 디스크 (worker)
ssh ubuntu@k8s-hub-worker-1.[DOMAIN] findmnt /var/lib/longhorn
```

- **확인:** 노드 네 대가 `Ready` 이고 `VERSION` 이 `v1.37.0`, kube-vip 파드가 control plane 마다 `Running`, `livez` 가 `ok`, `findmnt` 에 두 번째 디스크(`/dev/sdb`)가 `/var/lib/longhorn` 에 ext4 로 마운트되어 보입니다.

다음은 [쿠버네티스에 Argo CD 설치하고 GitOps로 서비스 추가하는 방법](/posts/36/)부터 이어집니다. 지역 엣지는 허브 Argo CD 에 원격 클러스터로 등록합니다([Proxmox에 Ansible로 kubeadm 엣지 클러스터 만들고 Argo CD 원격 클러스터로 등록하는 방법](/posts/42/)). Longhorn 과 DB 이중화는 [쿠버네티스에 Longhorn과 Patroni로 볼륨과 TimescaleDB 이중화하는 방법](/posts/54/)에 정리했습니다.

## 5. 노드 교체

노드를 바꿀 때는 새 노드를 목록에 더해 합류시킨 뒤, 옛 노드 항목에 `retire: true` 를 붙여 다시 실행합니다.

```yaml
      # 2. 새 노드가 합류한 뒤 옛 노드에 retire: true 를 붙이고 다시 실행해 뺍니다
      - { name: k8s-hub-cp-1, pve: pve01, role: control-plane, vmid: 121, ip: [HUB_CP_1_IP], cores: 2, memory: 4096, disk: 32G, retire: true }
      # (나머지 노드는 그대로)
      # 1. 새 노드를 목록에 더하고 실행해 합류시킵니다
      - { name: k8s-hub-cp-3, pve: pve01, role: control-plane, vmid: 125, ip: [NEW_NODE_IP], cores: 2, memory: 4096, disk: 32G }
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

- **확인:** 두 노드의 `qm list` 에서 목록의 VM 이 사라지고 다른 VM 은 그대로입니다.

## 마무리

VM 템플릿과 kubeadm 클러스터를 Ansible 플레이북 두 개로 옮겨, 새 Proxmox 서버에서도 `pve-cluster.yml` → `vm-template.yml` → `k8s-cluster.yml` 순서로 같은 클러스터를 다시 만들 수 있게 했습니다. control plane 두 대와 worker 두 대가 두 Proxmox 노드에 나뉘어 있고, API 는 kube-vip VIP 로 받으며, 허브와 지역 엣지를 `-e k8s_cluster` 만 바꿔 같은 플레이북으로 만들고 노드를 교체합니다.

## 참고 자료

- [Kubernetes - Creating Highly Available Clusters with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/)
- [Kubernetes - Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [Kubernetes - Installing kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [kube-vip - Static Pods](https://kube-vip.io/docs/installation/static/)
- [Longhorn - Installation Requirements](https://longhorn.io/docs/latest/deploy/install/#installation-requirements)
- [flannel-io/flannel](https://github.com/flannel-io/flannel)
- [community.proxmox.proxmox_kvm module](https://docs.ansible.com/ansible/latest/collections/community/proxmox/proxmox_kvm_module.html)
- [community.proxmox.proxmox_disk module](https://docs.ansible.com/ansible/latest/collections/community/proxmox/proxmox_disk_module.html)
- [Proxmox VE - Cloud-Init Support](https://pve.proxmox.com/wiki/Cloud-Init_Support)
