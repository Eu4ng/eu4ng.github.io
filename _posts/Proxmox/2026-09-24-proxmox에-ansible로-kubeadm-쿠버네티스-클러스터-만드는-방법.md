---
layout: post
title: Proxmox에 Ansible로 kubeadm 쿠버네티스 클러스터 만드는 방법
description: Ubuntu 클라우드 이미지 템플릿과 kubeadm 클러스터(control plane 1 + worker N)를 Ansible 플레이북 두 개로 만들어, 새 Proxmox 서버에서도 같은 클러스터를 명령 한 줄로 다시 만들고 필요 없으면 지우는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, ansible, kubernetes, kubeadm, cloud-init, homelab]
permalink: /posts/46/
---

[템플릿 스크립트](/posts/33/)와 [클러스터 스크립트](/posts/32/)로 하던 일을 Ansible 플레이북으로 옮겨, CT·VM 을 만드는 모든 절차를 `proxmox-ansible` 저장소 하나에 모읍니다. 템플릿 플레이북이 Ubuntu 24.04 클라우드 이미지로 VM 템플릿을 만들고, 클러스터 플레이북이 그 템플릿을 복제해 노드 VM 을 만든 뒤 containerd·kubeadm 설치, `kubeadm init`, Flannel, worker 합류까지 진행합니다. 두 플레이북 모두 여러 번 실행해도 결과가 같아서, 서버를 옮길 때는 Proxmox 설치와 API 토큰 준비 뒤 플레이북을 차례로 실행하기만 하면 됩니다.

1. 변수 채우기
2. 템플릿 만들기
3. 클러스터 만들기
4. 확인
5. 노드 추가와 삭제

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Proxmox VE | `9.2` |
| Ansible | `13.1` (ansible-core `2.20`, community.proxmox `1.4`) |
| Kubernetes | `v1.37` (kubeadm, containerd `2.2`) |
| Flannel | `v0.28.9` |
| 작성 기준일 | `2026-09-24` |

다음 항목이 준비되어 있어야 합니다.

- Ansible, Proxmox API 토큰, `proxmox-ansible` 저장소 골격(`ansible.cfg`, `inventory.yml`, `group_vars/all.yml`) ([Proxmox에 Ansible로 내부망 DNS 컨테이너 만드는 방법](/posts/41/)의 1~2단계)
- 실행 PC 의 SSH 키(`~/.ssh/id_ed25519.pub`)가 `group_vars/all.yml` 의 `ct_ssh_pubkey` 에 들어 있어야 합니다. 이 키가 템플릿에 들어가 복제한 VM 에 Ansible 이 접속합니다.
- 노드마다 비어 있는 VM ID 와 고정 IP, 노드 사양만큼의 호스트 메모리

## 1. 변수 채우기

`group_vars/all.yml` 에 템플릿과 클러스터 값을 추가합니다. `k8s_hub_nodes` 의 첫 항목이 control plane 이고 나머지가 worker 입니다.

{% raw %}
```yaml
vm_template_vmid: 9000                        # playbooks/vm-template.yml 이 만드는 Ubuntu 클라우드 이미지 템플릿 (SSH 키·qemu-guest-agent 포함)
vm_template_name: ubuntu-2404-cloud
vm_template_image_url: https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
vm_template_user: ubuntu                      # 복제한 VM 의 접속 계정 (cloud-init)
vm_snippet_storage: local                     # cloud-init vendor 스니펫을 둘 디렉터리형 스토리지
vm_disk_storage: local-lvm                    # VM 디스크를 두는 스토리지 (lvmthin 이라 포맷은 raw)
vm_bridge: vmbr0
timezone: Asia/Seoul                          # VM 의 시간대

# ---- k8s-hub: 허브 쿠버네티스 클러스터 (kubeadm, control plane 1 + worker N) ----
# 첫 항목이 control plane 입니다. 노드를 늘리려면 항목을 추가하고 플레이북을 다시 실행합니다(이미 있는 VM 은 설정만 맞춤).
k8s_hub_nodes:
  - { name: k8s-cp,       vmid: 101, ip: [CP_IP],     cores: 4,  memory: 8192,  disk: 32G }
  - { name: k8s-worker-1, vmid: 102, ip: [WORKER_IP], cores: 24, memory: 40960, disk: 100G }
k8s_hub_nameservers: [[LAN_DNS_IP], 1.1.1.1]
k8s_hub_version: v1.37                        # pkgs.k8s.io 저장소의 마이너 버전
k8s_hub_pod_cidr: 10.244.0.0/16               # Flannel 기본값
k8s_hub_flannel_version: v0.28.9              # https://github.com/flannel-io/flannel/releases
k8s_hub_kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/k8s-hub.yaml"   # 실행 PC 에 저장할 kubeconfig
```
{: file="group_vars/all.yml" }
{% endraw %}

노드는 플레이북이 실행 중에 이 목록으로 인벤토리 그룹을 만들므로 `inventory.yml` 에 따로 적지 않아도 됩니다. 다른 플레이북(시간대 등)에서도 노드에 접속하려면 `inventory.yml` 에 같은 이름과 주소로 추가합니다.

- **확인:** `ansible-inventory --graph` 가 오류 없이 끝납니다.

## 2. 템플릿 만들기

템플릿 플레이북은 클라우드 이미지를 내려받아 VM 을 만들고 템플릿으로 바꿉니다. 모든 복제 VM 에 적용할 cloud-init vendor 스니펫(qemu-guest-agent 설치, SSH 호스트 키 유지)을 호스트의 스니펫 스토리지에 두고, VM 에 넣을 공개키로는 실행 PC 키와 호스트의 `authorized_keys`, 호스트 키를 합쳐 넣습니다. 같은 ID 의 템플릿이 이미 있으면 아무것도 하지 않고, 같은 ID 가 템플릿이 아닌 VM 이면 멈춥니다.

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
    host_key: /root/.ssh/id_rsa             # 호스트에서 VM 으로 접속할 때 쓰는 키 (k3s-edge 등은 실행 PC 키를 씀)
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
              --cpu host --cores 2 --memory 2048 --agent 1 \
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

- **확인:** `PLAY RECAP` 에 `failed=0`, 호스트에서 `qm config 9000` 에 `template: 1`, `sshkeys:`, `cicustom: vendor=local:snippets/ubuntu-cloud-vendor.yaml` 이 보입니다. 한 번 더 실행하면 `changed=0` 입니다.

## 3. 클러스터 만들기

클러스터 플레이북은 다섯 플레이입니다.

- VM 만들기: 템플릿 복제, 디스크 늘리기(복제 직후 한 번), 코어·메모리·IP·DNS 설정, 시작, SSH 대기
- 노드 공통: 시간대, swap 끄기, 커널 모듈·설정, pkgs.k8s.io 저장소, containerd·kubelet·kubeadm·kubectl 설치와 버전 고정, containerd 의 systemd cgroup
- control plane: `kubeadm init`(처음 한 번), Flannel, join 명령 만들기, kubeconfig 를 실행 PC 로
- worker 합류: `kubeadm join`(처음 한 번)
- 확인: 모든 노드 Ready 대기

`kubeadm init` 과 `join` 은 결과 파일(`/etc/kubernetes/admin.conf`, `kubelet.conf`)이 있으면 건너뛰므로 다시 실행해도 클러스터를 새로 만들지 않습니다.

```bash
# 플레이북 내려받기
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/k8s-hub.yml -o playbooks/k8s-hub.yml
```

<details markdown="1">
<summary>playbooks/k8s-hub.yml 전문</summary>

{% raw %}
```yaml
# 허브 쿠버네티스 클러스터(kubeadm, control plane 1 + worker N). 템플릿(vm-template.yml)을 복제해 VM 을 만들고
# containerd·kubeadm 을 설치해 클러스터를 구성한 뒤 kubeconfig 를 실행 PC 로 가져옵니다. 그 다음은 Argo CD 설치(install-argocd.sh)부터 GitOps 입니다.
#   ansible-playbook playbooks/k8s-hub.yml                   만들기 (여러 번 실행해도 됨)
#   ansible-playbook playbooks/k8s-hub.yml -e k8s_hub_state=absent   VM 삭제 (ID 와 이름이 모두 맞는 VM 만, yes 입력 후)
---
- name: VM 만들기
  hosts: localhost
  gather_facts: false
  vars:
    state: "{{ k8s_hub_state | default('present') }}"
  tasks:
    - name: 노드 목록을 인벤토리 그룹으로
      ansible.builtin.add_host:
        name: "{{ item.name }}"
        groups: [k8s_hub_nodes, "{{ 'k8s_hub_cp' if idx == 0 else 'k8s_hub_workers' }}"]
        ansible_host: "{{ item.ip }}"
        ansible_user: "{{ vm_template_user }}"
      loop: "{{ k8s_hub_nodes }}"
      loop_control: { index_var: idx, label: "{{ item.name }}" }
      changed_when: false
      when: state == 'present'            # 삭제할 때는 뒤의 플레이가 노드에 접속하지 않게 그룹을 비워 둡니다

    - name: 삭제
      when: state == 'absent'
      block:
        - name: 확인 (-e k8s_hub_confirm=yes 로 건너뜀)
          ansible.builtin.pause:
            prompt: "{{ k8s_hub_nodes | map(attribute='name') | join(', ') }} VM 과 디스크를 삭제합니다. 계속하려면 yes"
          register: confirm
          when: k8s_hub_confirm | default('') != 'yes'
        - name: 삭제 중단
          ansible.builtin.meta: end_play
          when: k8s_hub_confirm | default('') != 'yes' and confirm.user_input | default('') != 'yes'
        - name: 현재 VM 목록
          community.proxmox.proxmox_vm_info:
            node: "{{ proxmox_node }}"
            type: qemu
          register: vms
        - name: VM 중지·삭제 (ID 와 이름이 모두 맞는 경우만)
          community.proxmox.proxmox_kvm:
            node: "{{ proxmox_node }}"
            vmid: "{{ item.vmid }}"
            name: "{{ item.name }}"
            state: absent
            force: true
            timeout: 120
          loop: "{{ k8s_hub_nodes }}"
          loop_control: { label: "{{ item.name }}" }
          when: vms.proxmox_vms | selectattr('vmid', 'equalto', item.vmid | int) | selectattr('name', 'equalto', item.name) | list | length > 0
        - name: 끝
          ansible.builtin.meta: end_play

    - name: 템플릿 복제 (VM 이 없을 때만)
      community.proxmox.proxmox_kvm:
        node: "{{ proxmox_node }}"
        clone: "{{ vm_template_name }}"
        vmid: "{{ vm_template_vmid }}"
        newid: "{{ item.vmid }}"
        name: "{{ item.name }}"
        full: true
        storage: "{{ vm_disk_storage }}"
        format: raw
        timeout: 300
        state: present
      loop: "{{ k8s_hub_nodes }}"
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
    - name: VM 설정 맞추기 (코어·메모리·IP·DNS·자동 시작. 모듈 특성상 매번 changed 로 보고됨)
      community.proxmox.proxmox_kvm:
        node: "{{ proxmox_node }}"
        vmid: "{{ item.vmid }}"
        name: "{{ item.name }}"
        cores: "{{ item.cores }}"
        memory: "{{ item.memory }}"
        onboot: true
        ipconfig: { ipconfig0: "ip={{ item.ip }}/24,gw={{ ct_gateway }}" }
        nameservers: "{{ k8s_hub_nameservers }}"
        update: true
      loop: "{{ k8s_hub_nodes }}"
      loop_control: { label: "{{ item.name }}" }
    - name: VM 시작
      community.proxmox.proxmox_kvm:
        node: "{{ proxmox_node }}"
        vmid: "{{ item.vmid }}"
        name: "{{ item.name }}"
        state: started
      loop: "{{ k8s_hub_nodes }}"
      loop_control: { label: "{{ item.name }}" }
    - name: SSH 열릴 때까지 대기
      ansible.builtin.wait_for:
        host: "{{ item.ip }}"
        port: 22
        timeout: 300
      loop: "{{ k8s_hub_nodes }}"
      loop_control: { label: "{{ item.name }}" }

- name: 노드 공통 (containerd, kubeadm)
  hosts: k8s_hub_nodes
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
    - name: 패키지 저장소 키
      ansible.builtin.get_url:
        url: https://pkgs.k8s.io/core:/stable:/{{ k8s_hub_version }}/deb/Release.key
        dest: /etc/apt/keyrings/kubernetes-apt-keyring.asc
        mode: "0644"
    - name: 패키지 저장소
      ansible.builtin.copy:
        dest: /etc/apt/sources.list.d/kubernetes.list
        mode: "0644"
        content: "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.asc] https://pkgs.k8s.io/core:/stable:/{{ k8s_hub_version }}/deb/ /\n"
    - name: containerd·kubeadm 설치
      ansible.builtin.apt:
        name: [containerd, kubelet, kubeadm, kubectl]
        update_cache: true
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

- name: control plane
  hosts: k8s_hub_cp
  become: true
  gather_facts: false
  tasks:
    - name: kubeadm init (처음 한 번)
      ansible.builtin.command: >-
        kubeadm init --pod-network-cidr={{ k8s_hub_pod_cidr }} --apiserver-advertise-address={{ ansible_host }}
      args:
        creates: /etc/kubernetes/admin.conf
    - name: ubuntu 계정 kubeconfig
      ansible.builtin.shell: |
        install -d -o {{ ansible_user }} -g {{ ansible_user }} /home/{{ ansible_user }}/.kube
        install -o {{ ansible_user }} -g {{ ansible_user }} -m 0600 /etc/kubernetes/admin.conf /home/{{ ansible_user }}/.kube/config
      changed_when: false
    - name: Flannel (CNI)
      ansible.builtin.command: >-
        kubectl --kubeconfig /etc/kubernetes/admin.conf apply
        -f https://github.com/flannel-io/flannel/releases/download/{{ k8s_hub_flannel_version }}/kube-flannel.yml
      register: flannel
      changed_when: "'created' in flannel.stdout or 'configured' in flannel.stdout"
    - name: join 명령 만들기
      ansible.builtin.command: kubeadm token create --print-join-command
      register: join
      changed_when: false
    - name: kubeconfig 를 실행 PC 로
      ansible.builtin.fetch:
        src: /etc/kubernetes/admin.conf
        dest: "{{ k8s_hub_kubeconfig }}"
        flat: true

- name: worker 합류
  hosts: k8s_hub_workers
  become: true
  gather_facts: false
  tasks:
    - name: kubeadm join (처음 한 번)
      ansible.builtin.command: "{{ hostvars[groups['k8s_hub_cp'][0]].join.stdout }}"
      args:
        creates: /etc/kubernetes/kubelet.conf

- name: 확인
  hosts: k8s_hub_cp
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
        that: (nodes.stdout_lines | length - 1) == (k8s_hub_nodes | length)
```
{: file="playbooks/k8s-hub.yml" }
{% endraw %}

</details>

```bash
# 실행 (노드 2대 기준 6~8분). 2단계의 PROXMOX_* 환경변수가 필요합니다
ansible-playbook playbooks/k8s-hub.yml
```

> `VM 설정 맞추기` 태스크는 `proxmox_kvm` 모듈이 변경 여부를 비교하지 않아 실행할 때마다 `changed` 로 표시됩니다. 값이 같으면 VM 에는 아무 일도 일어나지 않습니다.
{: .prompt-info }

- **확인:** 마지막 `결과` 태스크에 모든 노드가 `Ready` 로 보이고 `PLAY RECAP` 에 `failed=0` 입니다. 이 글을 쓰며 별도 VM ID 로 노드 2대(2코어, 2GiB)를 만들었을 때 약 7분 걸렸고, 다시 실행하자 노드 쪽은 모두 `changed=0` 이었습니다.

## 4. 확인

실행 PC 로 가져온 kubeconfig 로 클러스터를 봅니다.

```bash
# 실행 PC 에 kubectl 이 없다면 control plane 에서 같은 명령을 실행합니다
kubectl --kubeconfig ~/.kube/k8s-hub.yaml get nodes -o wide
kubectl --kubeconfig ~/.kube/k8s-hub.yaml -n kube-flannel get pods
```

- **확인:** 노드마다 `Ready`, `VERSION` 이 `v1.37.x`, Flannel 파드가 노드 수만큼 `Running` 입니다. 다음은 [쿠버네티스에 Argo CD 설치하고 GitOps로 서비스 추가하는 방법](/posts/36/)부터 이어집니다. Argo CD 가 설치되면 나머지 서비스는 GitOps 저장소가 다시 배포합니다.

## 5. 노드 추가와 삭제

worker 를 늘릴 때는 `k8s_hub_nodes` 에 항목을 추가하고 같은 명령을 다시 실행합니다. 기존 노드는 이미 합류한 상태라 건너뛰고 새 노드만 만들어 합류합니다.

클러스터를 지울 때는 삭제 모드로 실행합니다. `yes` 를 입력해야 진행하고, 목록의 VM ID 와 이름이 **모두** 일치하는 VM 만 지웁니다. 이름이 다른 VM 이 같은 ID 를 쓰고 있으면 건너뜁니다.

```bash
# 목록의 노드 VM 과 디스크 삭제 (템플릿은 그대로)
ansible-playbook playbooks/k8s-hub.yml -e k8s_hub_state=absent
```

> 운영 중인 클러스터를 지우면 노드의 PVC 데이터도 함께 사라집니다. 먼저 백업이 있는지 확인합니다.
{: .prompt-danger }

- **확인:** 호스트의 `qm list` 에서 목록의 VM 이 사라지고 다른 VM 은 그대로입니다.

## 마무리

VM 템플릿과 kubeadm 클러스터를 Ansible 플레이북 두 개로 옮겨, 새 Proxmox 서버에서도 `vm-template.yml` → `k8s-hub.yml` 순서로 같은 클러스터를 다시 만들 수 있게 했습니다. 내부망 DNS 와 [엣지 k3s 클러스터](/posts/42/)도 같은 저장소의 플레이북이므로, 서버를 옮길 때 Proxmox 쪽 작업은 이 저장소만 따라가면 됩니다. 클러스터 안의 서비스는 Argo CD 가 GitOps 저장소에서 다시 배포하고, 기기 설정이나 DB 처럼 코드로 다시 만들 수 없는 상태는 백업에서 복원해야 합니다.

## 참고 자료

- [Kubernetes - Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [Kubernetes - Installing kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [flannel-io/flannel](https://github.com/flannel-io/flannel)
- [community.proxmox.proxmox_kvm module](https://docs.ansible.com/ansible/latest/collections/community/proxmox/proxmox_kvm_module.html)
- [community.proxmox.proxmox_vm_info module](https://docs.ansible.com/ansible/latest/collections/community/proxmox/proxmox_vm_info_module.html)
- [Proxmox VE - Cloud-Init Support](https://pve.proxmox.com/wiki/Cloud-Init_Support)
