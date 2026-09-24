---
layout: post
title: Proxmox에 Ansible로 k3s 엣지 클러스터 만들고 Argo CD 원격 클러스터로 등록하는 방법
description: 허브 클러스터와 떨어져도 혼자 동작하는 엣지용 k3s VM을 Ansible 플레이북 하나로 만들고, 허브의 Argo CD에 원격 클러스터로 등록해 같은 GitOps 저장소의 프로젝트 폴더가 그 클러스터로 배포되게 하는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, ansible, k3s, kubernetes, argo-cd, gitops, edge]
permalink: /posts/42/
---

Proxmox 위에 IoT 엣지용 **k3s** 단일 노드 VM을 Ansible 플레이북으로 만들고, 기존 클러스터(허브)의 **Argo CD**에 원격 클러스터로 등록한 뒤, 저장소에 프로젝트 폴더 규칙과 ApplicationSet을 추가해 `iot/clusters/[SITE]/` 아래 폴더가 그 클러스터로 배포되게 합니다. 엣지를 허브의 워커 노드로 붙이지 않고 별도 클러스터로 두는 이유는, 허브나 회선이 끊겨도 엣지가 자체 컨트롤플레인과 DNS로 혼자 동작해야 하기 때문입니다. Argo CD 등록은 API 서버 로그인 대신 CLI의 core 모드로 쿠버네티스 API에 직접 써서 비밀번호 없이 끝냅니다.

1. 변수와 인벤토리 채우기
2. 플레이북 실행
3. Argo CD에 클러스터 등록
4. 프로젝트 폴더와 ApplicationSet 추가
5. 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Proxmox VE | `9.2` |
| Ansible | `13.1` (ansible-core `2.20`, community.proxmox `1.4`) |
| k3s | `v1.36.4+k3s1` |
| Argo CD (허브) | `v3.5.3` |
| 작성 기준일 | `2026-09-24` |

다음 항목이 준비되어 있어야 합니다.

- Ansible과 Proxmox API 토큰이 준비된 `proxmox-ansible` 저장소 ([Proxmox에 Ansible로 내부망 DNS 컨테이너 만드는 방법](/posts/41/)의 1~2단계)
- Ubuntu 클라우드 이미지 템플릿 VM ([Proxmox에서 Ubuntu 클라우드 이미지 템플릿 만드는 방법](/posts/33/)). 실행 PC의 SSH 키가 이 템플릿에 들어 있어야 Ansible이 VM에 접속합니다.
- Argo CD가 설치된 허브 클러스터와 GitOps 저장소 ([쿠버네티스에 Argo CD 설치하고 GitOps로 서비스 추가하는 방법](/posts/36/))
- 비어 있는 VM ID와 고정 IP 하나, Proxmox 호스트의 여유 메모리 4GiB

## 1. 변수와 인벤토리 채우기

`proxmox-ansible` 저장소의 `group_vars/all.yml`에 템플릿 정보와 엣지 VM 값을 추가합니다. 값은 이 파일에서만 바꾸고 플레이북은 변수만 참조합니다.

{% raw %}
```yaml
vm_template_vmid: 9000                        # create-template.sh 로 만든 Ubuntu 클라우드 이미지 템플릿 (SSH 키·qemu-guest-agent 포함)
vm_template_name: ubuntu-2404-cloud
vm_disk_storage: local-lvm                    # VM 디스크를 두는 스토리지 (lvmthin 이라 포맷은 raw)

# ---- k3s-edge: IoT 엣지 클러스터 (단일 노드 k3s VM) ----
k3s_edge_site: [SITE]                         # Argo CD 에 등록할 클러스터 이름이자 k8s-gitops 의 iot/clusters/<이름>/
k3s_edge_vmid: 103
k3s_edge_name: k3s-[SITE]
k3s_edge_ip: [EDGE_IP]
k3s_edge_cores: 4
k3s_edge_memory: 4096                         # MiB. 호스트 가용 메모리에 맞춘 값
k3s_edge_disk: 32G                            # 템플릿 디스크(3.5G)를 이 크기로 늘림. 줄일 수는 없음
k3s_edge_nameservers: [[LAN_DNS_IP], 1.1.1.1] # LAN DNS 먼저. 서버가 모두 죽어도 1.1.1.1 로 바깥 이름은 풀림
k3s_edge_version: v1.36.4+k3s1                # https://update.k3s.io/v1-release/channels/stable
k3s_edge_kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/k3s-{{ k3s_edge_site }}.yaml"   # 실행 PC 에 저장할 kubeconfig
```
{: file="group_vars/all.yml" }
{% endraw %}

`inventory.yml`에 플레이북이 만들 VM을 그룹으로 추가합니다. 템플릿의 cloud-init 계정이 `ubuntu`이므로 그 계정으로 접속합니다.

```yaml
    k3s_edge:                     # playbooks/k3s-edge.yml 이 만드는 VM
      hosts:
        k3s-[SITE]:
          ansible_host: [EDGE_IP]
          ansible_user: ubuntu
```
{: file="inventory.yml" }

- **확인:** `ansible-inventory --graph`에 `@k3s_edge` 아래 `k3s-[SITE]`가 보입니다.

## 2. 플레이북 실행

플레이북은 세 플레이입니다. Proxmox API로 템플릿을 복제해 VM을 만들고 켜기, VM 안에 k3s 설치와 kubeconfig 회수, 그리고 확인입니다. k3s는 뒤에 배포할 서비스와 포트가 겹치지 않도록 Traefik을 끄고 설치하며, 내장 local-path 프로비저너가 기본 StorageClass가 됩니다. 나중에 Thread 보더 라우터 파드가 쓸 IPv6 포워딩과 `tun` 모듈 설정도 여기서 함께 넣습니다.

```bash
# 플레이북 내려받기
curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/k3s-edge.yml -o playbooks/k3s-edge.yml
```

<details markdown="1">
<summary>playbooks/k3s-edge.yml 전문</summary>

{% raw %}
```yaml
# IoT 엣지용 k3s 단일 노드 VM. 클라우드 이미지 템플릿을 복제해 VM 을 만들고 k3s 를 설치한 뒤 kubeconfig 를 실행 PC 로 가져옵니다.
# 엣지 클러스터는 허브(Argo CD)와 떨어져도 혼자 동작해야 하므로 컨트롤플레인을 자체적으로 갖는 k3s 를 씁니다.
#   ansible-playbook playbooks/k3s-edge.yml   (PROXMOX_* 환경변수 필요, README 참고)
---
- name: k3s 엣지 VM 만들기
  hosts: localhost
  gather_facts: false
  tasks:
    - name: 템플릿 복제 (VM 이 없을 때만)
      community.proxmox.proxmox_kvm:
        node: "{{ proxmox_node }}"
        clone: "{{ vm_template_name }}"
        vmid: "{{ vm_template_vmid }}"
        newid: "{{ k3s_edge_vmid }}"
        name: "{{ k3s_edge_name }}"
        full: true
        storage: "{{ vm_disk_storage }}"
        format: raw
        timeout: 300
        state: present
      register: clone
    - name: 디스크 늘리기 (복제 직후 한 번)
      community.proxmox.proxmox_disk:
        vmid: "{{ k3s_edge_vmid }}"
        disk: scsi0
        size: "{{ k3s_edge_disk }}"
        state: resized
      when: clone.changed
    - name: VM 설정 맞추기 (코어·메모리·IP·DNS·자동 시작. 모듈 특성상 매번 changed 로 보고됨)
      community.proxmox.proxmox_kvm:
        node: "{{ proxmox_node }}"
        vmid: "{{ k3s_edge_vmid }}"
        name: "{{ k3s_edge_name }}"
        cores: "{{ k3s_edge_cores }}"
        memory: "{{ k3s_edge_memory }}"
        onboot: true
        ipconfig: { ipconfig0: "ip={{ k3s_edge_ip }}/24,gw={{ ct_gateway }}" }
        nameservers: "{{ k3s_edge_nameservers }}"
        update: true
    - name: VM 시작
      community.proxmox.proxmox_kvm:
        node: "{{ proxmox_node }}"
        vmid: "{{ k3s_edge_vmid }}"
        name: "{{ k3s_edge_name }}"
        state: started
    - name: SSH 열릴 때까지 대기
      ansible.builtin.wait_for:
        host: "{{ k3s_edge_ip }}"
        port: 22
        timeout: 300

- name: VM 안에 k3s 설치
  hosts: k3s_edge
  become: true
  gather_facts: false
  pre_tasks:
    - name: cloud-init 완료 대기 (첫 부팅의 패키지 갱신)
      ansible.builtin.command: cloud-init status --wait
      changed_when: false
      failed_when: false
  tasks:
    - name: OTBR 파드가 요구하는 커널 설정 (IPv6 포워딩, RA 와 경로 광고 수용)
      ansible.builtin.copy:
        dest: /etc/sysctl.d/60-otbr.conf
        mode: "0644"
        content: |
          # proxmox-ansible 의 playbooks/k3s-edge.yml 이 만듭니다. OpenThread Border Router 파드(hostNetwork)용.
          net.ipv4.ip_forward = 1
          net.ipv6.conf.all.forwarding = 1
          net.ipv6.conf.eth0.accept_ra = 2
          net.ipv6.conf.eth0.accept_ra_rt_info_max_plen = 64
      notify: sysctl 적용
    - name: tun 모듈 자동 로드 (OTBR 의 wpan0 인터페이스)
      ansible.builtin.copy:
        dest: /etc/modules-load.d/tun.conf
        mode: "0644"
        content: "tun\n"
    - name: tun 모듈 지금 로드
      community.general.modprobe:
        name: tun
    - name: k3s 설치 (없을 때만. Traefik 은 끄고 kubeconfig 는 읽을 수 있게)
      ansible.builtin.shell: |
        curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION={{ k3s_edge_version }} \
          INSTALL_K3S_EXEC="server --disable traefik --write-kubeconfig-mode 644" sh -
      args:
        creates: /usr/local/bin/k3s
    - name: 노드 Ready 대기
      ansible.builtin.command: k3s kubectl wait --for=condition=Ready node --all --timeout=300s
      changed_when: false
    - name: kubeconfig 읽기
      ansible.builtin.slurp:
        src: /etc/rancher/k3s/k3s.yaml
      register: kubeconfig
    - name: kubeconfig 를 실행 PC 에 저장 (server 를 VM 주소로 바꿈)
      ansible.builtin.copy:
        dest: "{{ k3s_edge_kubeconfig }}"
        mode: "0600"
        content: "{{ kubeconfig.content | b64decode | replace('https://127.0.0.1:6443', 'https://' ~ k3s_edge_ip ~ ':6443') }}"
      delegate_to: localhost
      become: false
  handlers:
    - name: sysctl 적용
      ansible.builtin.command: sysctl --system
      changed_when: false

- name: 확인
  hosts: k3s_edge
  gather_facts: false
  tasks:
    - name: 내장 local-path StorageClass 가 생길 때까지 대기 (노드 Ready 직후 몇 초 걸림)
      ansible.builtin.command: k3s kubectl get storageclass local-path -o name
      register: sc
      until: sc.rc == 0
      retries: 30
      delay: 2
      changed_when: false
    - name: 노드·스토리지클래스·커널 설정
      ansible.builtin.shell: |
        k3s kubectl get nodes -o wide | tail -n +2
        k3s kubectl get storageclass -o name
        sysctl -n net.ipv6.conf.all.forwarding net.ipv6.conf.eth0.accept_ra
        ip -6 addr show eth0 scope global | grep -c inet6
      register: check
      changed_when: false
    - name: 결과
      ansible.builtin.debug:
        msg: "{{ check.stdout_lines }}"
    - name: k3s 가 Ready 이고 local-path 가 있는지
      ansible.builtin.assert:
        that:
          - "' Ready ' in check.stdout_lines[0]"
          - "'storageclass.storage.k8s.io/local-path' in check.stdout"
        fail_msg: "k3s 노드가 Ready 가 아니거나 local-path StorageClass 가 없습니다"
```
{: file="playbooks/k3s-edge.yml" }
{% endraw %}

</details>

```bash
# 실행 (복제·첫 부팅·k3s 설치 포함 3~4분)
export PROXMOX_HOST=[PROXMOX_IP] PROXMOX_USER=root@pam PROXMOX_TOKEN_ID=ansible \
       PROXMOX_TOKEN_SECRET=$(cat ~/.config/proxmox/token) PROXMOX_VALIDATE_CERTS=false
ansible-playbook playbooks/k3s-edge.yml
```

> `VM 설정 맞추기` 태스크는 `proxmox_kvm` 모듈이 변경 여부를 비교하지 않아 실행할 때마다 `changed`로 표시됩니다. 실제로 값이 같으면 VM에는 아무 일도 일어나지 않습니다. 디스크 늘리기는 복제한 직후에만 실행되므로 두 번째 실행부터는 건너뜁니다.
{: .prompt-info }

- **확인:** 마지막 `PLAY RECAP`에 `failed=0`, 그 위 `결과` 태스크에 노드 한 줄(`Ready`, `v1.36.4+k3s1`), `storageclass.storage.k8s.io/local-path`, 커널 값 `1`과 `2`가 보입니다. 실행 PC의 `~/.kube/k3s-[SITE].yaml`이 생기고 `server:`가 `https://[EDGE_IP]:6443`입니다.

## 3. Argo CD에 클러스터 등록

허브 Argo CD가 엣지 클러스터에 배포하려면 엣지의 API 서버 주소와 자격 증명이 Argo CD의 cluster Secret으로 있어야 합니다. `argocd cluster add`가 이 일을 하는데, 대상 클러스터의 kubeconfig 컨텍스트와 Argo CD가 있는 클러스터의 접근 권한이 함께 필요합니다. 2단계에서 가져온 kubeconfig를 control plane에 복사하고, control plane에서 스크립트를 실행합니다.

```bash
# 내 PC: 엣지 kubeconfig 를 control plane 으로 복사
scp ~/.kube/k3s-[SITE].yaml ubuntu@[CP_IP]:

# control plane: 스크립트 내려받기
ssh ubuntu@[CP_IP]
wget https://eu4ng.github.io/assets/scripts/kubernetes/register-edge-cluster.sh
```

<details markdown="1">
<summary>register-edge-cluster.sh 전문</summary>

```bash
#!/usr/bin/env bash
#
# 엣지(k3s) 클러스터를 허브의 Argo CD 에 원격 클러스터로 등록합니다.
# proxmox-ansible 의 playbooks/k3s-edge.yml 이 실행 PC 에 가져온 kubeconfig 를 control plane 에 복사한 뒤,
# control plane 에서 실행합니다: bash register-edge-cluster.sh [SITE] [EDGE_KUBECONFIG]
# Argo CD API 서버에 로그인하지 않고 CLI 의 core 모드로 쿠버네티스 API 에 직접 쓰므로 비밀번호가 필요 없습니다.

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
ARGOCD_NAMESPACE=argocd
EDGE_CONTEXT=default          # 엣지 kubeconfig 의 컨텍스트 이름 (k3s 기본값)
ARGOCD_BIN=$HOME/.local/bin/argocd
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------- 1. 사전 검사 ----------
log "사전 검사"
SITE=${1:-}
EDGE_KUBECONFIG=${2:-}
[[ "$SITE" =~ ^[a-z0-9-]+$ ]] || die "사용법: bash register-edge-cluster.sh [SITE] [EDGE_KUBECONFIG]  (SITE 는 소문자·숫자·하이픈)"
[ -r "$EDGE_KUBECONFIG" ] || die "엣지 kubeconfig 파일이 없습니다: $EDGE_KUBECONFIG"
kubectl get nodes >/dev/null || die "kubectl 로 허브 클러스터에 접근할 수 없습니다."
kubectl get namespace "$ARGOCD_NAMESPACE" >/dev/null || die "네임스페이스 $ARGOCD_NAMESPACE 가 없습니다. Argo CD 를 먼저 설치하세요."
HUB_CONTEXT=$(kubectl config current-context)
kubectl --kubeconfig "$EDGE_KUBECONFIG" --context "$EDGE_CONTEXT" get nodes >/dev/null \
  || die "엣지 kubeconfig 의 컨텍스트 $EDGE_CONTEXT 로 엣지 클러스터에 접근할 수 없습니다."

# ---------- 2. argocd CLI ----------
# 서버와 같은 버전을 씁니다. 이미 그 버전이 있으면 건너뜁니다.
ARGOCD_VERSION=$(kubectl -n "$ARGOCD_NAMESPACE" get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
if [ ! -x "$ARGOCD_BIN" ] || ! "$ARGOCD_BIN" version --client --short | grep -q "$ARGOCD_VERSION"; then
  log "argocd CLI $ARGOCD_VERSION 설치"
  mkdir -p "$(dirname "$ARGOCD_BIN")"
  curl -fsSL -o "$ARGOCD_BIN" "https://github.com/argoproj/argo-cd/releases/download/$ARGOCD_VERSION/argocd-linux-amd64"
  chmod +x "$ARGOCD_BIN"
fi

# ---------- 3. kubeconfig 병합 ----------
# core 모드는 현재 컨텍스트(허브)의 네임스페이스에서 Argo CD 설정을 찾고, cluster add 는 다른 컨텍스트(엣지)를 대상으로 씁니다.
# 두 컨텍스트가 한 kubeconfig 에 있어야 하므로 임시 파일로 병합합니다. 원래 kubeconfig 는 건드리지 않습니다.
log "kubeconfig 병합"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}:$EDGE_KUBECONFIG" kubectl config view --flatten > "$TMP_DIR/kubeconfig"
export KUBECONFIG=$TMP_DIR/kubeconfig
kubectl config use-context "$HUB_CONTEXT" >/dev/null
kubectl config set-context --current --namespace="$ARGOCD_NAMESPACE" >/dev/null

# ---------- 4. 등록 ----------
# 엣지 클러스터에 ServiceAccount argocd-manager(cluster-admin)를 만들고, 그 토큰을 허브의 argocd 네임스페이스에 cluster Secret 으로 저장합니다.
# --upsert 라 다시 실행하면 같은 이름의 등록을 갱신합니다.
log "Argo CD 에 클러스터 $SITE 등록"
"$ARGOCD_BIN" --core cluster add "$EDGE_CONTEXT" --name "$SITE" --label "site=$SITE" --upsert --yes

# ---------- 5. 확인 ----------
log "등록된 클러스터"
"$ARGOCD_BIN" --core cluster list
kubectl -n "$ARGOCD_NAMESPACE" get secret -l "argocd.argoproj.io/secret-type=cluster,site=$SITE" -o name | grep -q . \
  || die "cluster Secret 이 만들어지지 않았습니다."
log "완료. k8s-gitops 의 iot/clusters/$SITE/ 아래 폴더가 이 클러스터로 배포됩니다."
```
{: file="register-edge-cluster.sh" }

</details>

```bash
# 등록 (SITE 는 1단계의 k3s_edge_site 와 같게)
bash register-edge-cluster.sh [SITE] k3s-[SITE].yaml
```

스크립트는 허브의 `argocd-server` 이미지와 같은 버전의 CLI를 `~/.local/bin`에 받고, 허브와 엣지 kubeconfig를 임시 파일로 병합한 뒤 `argocd --core cluster add`를 실행합니다. core 모드는 Argo CD API 서버 대신 쿠버네티스 API에 직접 쓰므로 `admin` 비밀번호가 필요 없습니다. 엣지 쪽에는 `kube-system` 네임스페이스에 cluster-admin 권한의 ServiceAccount `argocd-manager`가 생기고, 그 토큰이 허브 `argocd` 네임스페이스의 Secret에 저장됩니다. `--upsert`라 다시 실행해도 같은 등록을 갱신합니다.

- **확인:** 마지막 `등록된 클러스터` 표에 `https://[EDGE_IP]:6443`이 이름 `[SITE]`, 상태 `Successful`로 보이고, `kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster --show-labels`에 `site=[SITE]` 라벨이 붙은 Secret이 있습니다.

## 4. 프로젝트 폴더와 ApplicationSet 추가

기존 `services/` 폴더는 허브 클러스터로만 배포됩니다. 어느 폴더가 어느 클러스터로 가는지는 ApplicationSet이 정하므로, 프로젝트 폴더 `iot/`와 그 규칙을 저장소에 추가합니다. 허브 몫은 `iot/hub/[이름]/`, 지역별 엣지 몫은 `iot/clusters/[SITE]/[이름]/`이며, 지역 폴더의 두 번째 세그먼트가 그대로 Argo CD의 클러스터 이름이 됩니다. Argo CD를 설치할 때 만든 `services` ApplicationSet은 저장소 연결용으로 그대로 두고, 프로젝트의 ApplicationSet은 `services/argocd/` 폴더에 매니페스트로 두어 GitOps로 관리합니다.

```text
services/[이름]/              # 플랫폼 서비스 → 허브 (기존)
iot/hub/[이름]/               # IoT 의 허브 몫 → 허브. 폴더 이름 = Application = 네임스페이스
iot/edge/[이름]/              # 엣지 공통 베이스(kustomize). 직접 배포되지 않고 아래 오버레이가 참조
iot/clusters/[SITE]/[이름]/   # 지역 오버레이 → 클러스터 [SITE] 의 네임스페이스 [이름]
```

{% raw %}
```yaml
# IoT 프로젝트의 ApplicationSet 두 개. 저장소를 처음 연결하는 `services` ApplicationSet(install-argocd.sh)은 services/* 만 보므로,
# 다른 프로젝트 폴더는 이렇게 services/argocd/ 에 ApplicationSet 을 두어 GitOps 로 관리합니다. 폴더 규칙은 iot/README.md 에 있습니다.
# 원격(엣지) 클러스터는 GitOps 밖에서 등록합니다: register-edge-cluster.sh (Argo CD 에 <지역> 이름으로 등록).
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: iot-hub
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: git@github.com:[OWNER]/k8s-gitops.git
        revision: HEAD
        directories:
          - path: iot/hub/*                    # 중앙(허브) 몫. 폴더 이름 = Application = 네임스페이스
  template:
    metadata:
      name: '{{.path.basename}}'
    spec:
      project: default
      source:
        repoURL: git@github.com:[OWNER]/k8s-gitops.git
        targetRevision: HEAD
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
  syncPolicy:
    preserveResourcesOnDeletion: true
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: iot-edge
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: git@github.com:[OWNER]/k8s-gitops.git
        revision: HEAD
        directories:
          - path: iot/clusters/*/*             # iot/clusters/<지역>/<이름>/ → 클러스터 <지역> 의 네임스페이스 <이름>
  template:
    metadata:
      name: '{{index .path.segments 2}}-{{.path.basename}}'   # 예: daejeon-mosquitto
    spec:
      project: default
      source:
        repoURL: git@github.com:[OWNER]/k8s-gitops.git
        targetRevision: HEAD
        path: '{{.path.path}}'
      destination:
        name: '{{index .path.segments 2}}'   # Argo CD 에 등록한 클러스터 이름 (폴더 이름과 같아야 합니다)
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
  syncPolicy:
    preserveResourcesOnDeletion: true
```
{: file="services/argocd/applicationset-iot.yaml" }
{% endraw %}

`iot-edge`는 Git 디렉터리 생성기의 `path.segments`로 폴더 경로를 쪼개 두 번째 세그먼트를 배포 대상 클러스터 이름(`destination.name`)으로, 마지막 폴더 이름을 네임스페이스로 씁니다. Application 이름은 `[SITE]-[이름]`이 되어 여러 지역이 같은 서비스 이름을 써도 겹치지 않습니다. 폴더 규칙을 적은 `iot/README.md`를 함께 두고 push합니다.

```bash
# 커밋하고 push
git add services/argocd/applicationset-iot.yaml iot/README.md
git commit -m "feat(argocd): IoT 프로젝트용 ApplicationSet 과 iot/ 폴더 규칙 추가"
git push
```

- **확인:** `argocd` Application이 다시 sync된 뒤 control plane의 `kubectl -n argocd get applicationset`에 `services`, `iot-hub`, `iot-edge`가 보입니다. 아직 `iot/` 아래에 서비스 폴더가 없으므로 Application은 생기지 않습니다.

## 5. 확인

허브에서 등록 상태를, 엣지에서 노드와 Argo CD가 만든 계정을 봅니다.

```bash
# control plane: 등록된 클러스터
~/.local/bin/argocd --core cluster list

# 엣지 VM: 노드·StorageClass 와 Argo CD 가 만든 ServiceAccount
ssh ubuntu@[EDGE_IP] 'kubectl get nodes -o wide; kubectl get sc; kubectl -n kube-system get sa argocd-manager'
```

- **확인:** 클러스터 목록에 `[SITE]`가 `Successful`, 엣지 노드가 `Ready`, `local-path (default)` StorageClass, `argocd-manager` ServiceAccount가 보입니다. 이후 `iot/clusters/[SITE]/[이름]/` 폴더를 push하면 Argo CD 웹 UI에 `[SITE]-[이름]` Application이 생겨 엣지 클러스터로 배포됩니다.

## 트러블슈팅

<details markdown="1">
<summary><code>configmap "argocd-cm" not found</code> — <code>argocd --core</code> 실행 시</summary>

```text
{"level":"fatal","msg":"configmap \"argocd-cm\" not found"}
```

- **원인:** core 모드는 kubeconfig 현재 컨텍스트의 네임스페이스에서 Argo CD 설정을 찾습니다. 네임스페이스가 비어 있으면 `default`에서 찾다가 실패하며, `-n` 같은 네임스페이스 옵션은 없습니다.
- **해결:** 스크립트가 병합한 임시 kubeconfig에서 `kubectl config set-context --current --namespace=argocd`로 네임스페이스를 지정합니다. 원래 kubeconfig는 바뀌지 않습니다.

</details>

## 마무리

Proxmox 위에 엣지용 k3s VM을 플레이북 하나로 만들고, 허브의 Argo CD에 원격 클러스터로 등록한 뒤 프로젝트 폴더 규칙과 ApplicationSet을 저장소에 추가해, `iot/clusters/[SITE]/` 아래 폴더가 그 클러스터로 배포되는 구성을 완성했습니다. 지역이 늘면 변수와 인벤토리에 새 VM을 적어 플레이북을 돌리고 같은 스크립트로 등록한 뒤 `iot/clusters/` 아래 폴더만 추가하면 됩니다. 허브가 엣지 API 서버에 닿지 못하는 동안 Argo CD는 그 지역의 Application을 `Unknown`으로 표시하지만, 엣지에 이미 배포된 파드는 자체 컨트롤플레인으로 계속 동작합니다. 다른 건물의 엣지처럼 같은 LAN이 아니면 허브에서 엣지 API 서버(6443)로 가는 경로(VPN)가 먼저 있어야 합니다.

## 참고 자료

- [k3s - Quick-Start Guide](https://docs.k3s.io/quick-start)
- [k3s - Configuration Options](https://docs.k3s.io/installation/configuration)
- [Argo CD - Declarative Setup (Clusters)](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters)
- [Argo CD - Git Generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/)
- [Argo CD - Core Install](https://argo-cd.readthedocs.io/en/stable/operator-manual/core/)
- [community.proxmox.proxmox_kvm module](https://docs.ansible.com/ansible/latest/collections/community/proxmox/proxmox_kvm_module.html)
- [community.proxmox.proxmox_disk module](https://docs.ansible.com/ansible/latest/collections/community/proxmox/proxmox_disk_module.html)
