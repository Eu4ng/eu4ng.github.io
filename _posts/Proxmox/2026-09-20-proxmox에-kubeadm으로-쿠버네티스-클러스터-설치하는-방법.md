---
layout: post
title: Proxmox에 kubeadm으로 쿠버네티스 클러스터 설치하는 방법
date: 2026-09-20 10:03 +0900
permalink: /posts/32/
description: Proxmox 호스트에서 스크립트 하나로 Ubuntu VM 생성부터 kubeadm 클러스터 구성까지 끝내고, 내 PC에서 SSH로 바로 접속하는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, kubernetes, kubeadm, cloud-init, ssh]
---

Proxmox 호스트에서 스크립트를 한 번 실행해 control plane 1대와 worker 1대로 이루어진 쿠버네티스 클러스터를 만듭니다. 스크립트가 Proxmox의 `authorized_keys`를 VM에 그대로 넣어 주므로, Proxmox에 SSH로 접속하던 PC라면 추가 설정 없이 쿠버네티스 VM에도 접속할 수 있습니다.

1. 스크립트 내려받기
2. 변수 수정
3. 스크립트 실행
4. 내 PC에서 접속

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Proxmox VE | `9` |
| VM 운영체제 | `Ubuntu 24.04 (클라우드 이미지)` |
| Kubernetes | `v1.37` |
| 컨테이너 런타임 | `containerd 2.2` |
| CNI | `Flannel` |
| 작성 기준일 | `2026-09-20` |

다음 항목이 준비되어 있어야 합니다.

- Proxmox 호스트의 root 셸 (웹 UI의 **Shell** 또는 SSH)
- Proxmox 호스트의 `/root/.ssh/authorized_keys`에 내 PC의 공개키 등록 (등록 방법은 [Windows와 리눅스 서버에서 GitHub SSH 키와 커밋 서명 설정하는 방법](/posts/31/)의 2단계 참고)
- 같은 대역에서 사용하지 않는 고정 IP 2개 (control plane, worker)

## 1. 스크립트 내려받기

Proxmox 호스트의 root 셸에서 스크립트를 내려받습니다.

```bash
# 설치 스크립트 내려받기
wget https://eu4ng.github.io/assets/scripts/k8s-proxmox.sh
```

<details markdown="1">
<summary>스크립트 전문 보기</summary>

```bash
#!/usr/bin/env bash
#
# Proxmox VE 호스트에 kubeadm 쿠버네티스 클러스터(control plane 1 + worker N)를 만듭니다.
# Proxmox 호스트에서 root 로 실행합니다: bash k8s-proxmox.sh

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
STORAGE=local-lvm          # VM 디스크를 둘 스토리지
BRIDGE=vmbr0               # VM 이 연결될 브리지
TEMPLATE_ID=9000           # 클라우드 이미지 템플릿 VM ID
CP_ID=201                  # control plane VM ID (worker 는 +1 씩 증가)
WORKER_COUNT=1             # worker 수

IP_PREFIX=192.168.0        # 노드 IP 앞 세 자리
IP_START=201               # control plane IP 끝자리 (worker 는 +1 씩 증가)
CIDR=24
GATEWAY=192.168.0.1
DNS=1.1.1.1

CP_CORES=4
CP_MEMORY=8192             # MiB
CP_DISK=32G
WORKER_CORES=16
WORKER_MEMORY=32768        # MiB
WORKER_DISK=100G

CI_USER=ubuntu             # VM 접속 계정
K8S_VERSION=v1.37          # pkgs.k8s.io 저장소의 마이너 버전
POD_CIDR=10.244.0.0/16     # Flannel 기본값
# --------------------------------------

IMAGE_URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
IMAGE_PATH=/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img
TEMPLATE_NAME=ubuntu-2404-cloud
FLANNEL_URL=https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
AUTHORIZED_KEYS=/root/.ssh/authorized_keys
HOST_KEY=/root/.ssh/id_rsa
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
vm_ssh() { local ip=$1; shift; ssh "${SSH_OPTS[@]}" "$CI_USER@$ip" "$@"; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# 노드 목록: 첫 번째가 control plane
NODE_IDS=() NODE_IPS=() NODE_NAMES=()
for i in $(seq 0 "$WORKER_COUNT"); do
  NODE_IDS+=("$((CP_ID + i))")
  NODE_IPS+=("$IP_PREFIX.$((IP_START + i))")
  if [ "$i" -eq 0 ]; then NODE_NAMES+=(k8s-cp); else NODE_NAMES+=("k8s-worker-$i"); fi
done
CP_IP=${NODE_IPS[0]}

# ---------- 1. 사전 검사 ----------
log "사전 검사"
[ "$(id -u)" -eq 0 ] || die "root 로 실행해야 합니다."
command -v qm >/dev/null || die "qm 명령이 없습니다. Proxmox VE 호스트에서 실행하세요."
[ -s "$AUTHORIZED_KEYS" ] || die "$AUTHORIZED_KEYS 가 비어 있습니다. 내 PC 의 공개키를 먼저 등록하세요."
pvesm status --storage "$STORAGE" >/dev/null || die "스토리지 $STORAGE 를 찾을 수 없습니다."
for i in "${!NODE_IDS[@]}"; do
  pvesh get /cluster/nextid --vmid "${NODE_IDS[$i]}" >/dev/null 2>&1 \
    || die "VM ID ${NODE_IDS[$i]} 가 이미 사용 중입니다. CP_ID 를 바꾸세요."
  ! ping -c 1 -W 1 "${NODE_IPS[$i]}" >/dev/null 2>&1 \
    || die "IP ${NODE_IPS[$i]} 가 이미 사용 중입니다. IP_START 를 바꾸세요."
done

# ---------- 2. VM 에 넣을 공개키 준비 ----------
# authorized_keys: 내 PC 에서 VM 으로 접속하는 용도
# 호스트 공개키: 이 스크립트가 VM 에 접속해 설정하는 용도
log "공개키 준비"
[ -f "$HOST_KEY" ] || ssh-keygen -q -t rsa -b 4096 -N '' -f "$HOST_KEY"
KEYS_FILE=$(mktemp)
{ cat "$AUTHORIZED_KEYS"; echo; cat "$HOST_KEY.pub"; } | grep -vE '^\s*(#|$)' | awk '!seen[$0]++' > "$KEYS_FILE"

# ---------- 3. 템플릿 VM ----------
if qm config "$TEMPLATE_ID" >/dev/null 2>&1; then
  qm config "$TEMPLATE_ID" | grep -q '^template: 1' \
    || die "VM ID $TEMPLATE_ID 가 템플릿이 아닌 VM 으로 사용 중입니다. TEMPLATE_ID 를 바꾸세요."
  log "기존 템플릿 $TEMPLATE_ID 재사용"
else
  log "템플릿 $TEMPLATE_ID 생성"
  [ -f "$IMAGE_PATH" ] || wget -q --show-progress -O "$IMAGE_PATH" "$IMAGE_URL"
  qm create "$TEMPLATE_ID" --name "$TEMPLATE_NAME" --ostype l26 \
    --cpu host --cores 2 --memory 2048 --balloon 0 --agent 1 \
    --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-single \
    --serial0 socket --vga serial0
  qm set "$TEMPLATE_ID" --scsi0 "$STORAGE:0,import-from=$IMAGE_PATH,iothread=1,discard=on,ssd=1"
  qm set "$TEMPLATE_ID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0
  qm template "$TEMPLATE_ID"
fi

# ---------- 4. 노드 VM ----------
for i in "${!NODE_IDS[@]}"; do
  id=${NODE_IDS[$i]} ip=${NODE_IPS[$i]} name=${NODE_NAMES[$i]}
  if [ "$i" -eq 0 ]; then cores=$CP_CORES memory=$CP_MEMORY disk=$CP_DISK
  else cores=$WORKER_CORES memory=$WORKER_MEMORY disk=$WORKER_DISK; fi

  log "VM $id ($name, $ip) 생성"
  qm clone "$TEMPLATE_ID" "$id" --name "$name" --full
  qm set "$id" --cores "$cores" --memory "$memory" \
    --ciuser "$CI_USER" --sshkeys "$KEYS_FILE" --ciupgrade 0 \
    --ipconfig0 "ip=$ip/$CIDR,gw=$GATEWAY" --nameserver "$DNS"
  qm resize "$id" scsi0 "$disk"
  qm start "$id"
done
rm -f "$KEYS_FILE"

# ---------- 5. SSH 대기 ----------
for ip in "${NODE_IPS[@]}"; do
  log "$ip SSH 대기"
  for try in $(seq 1 60); do
    vm_ssh "$ip" true 2>/dev/null && break
    [ "$try" -lt 60 ] || die "$ip 에 5분 동안 SSH 로 접속하지 못했습니다."
    sleep 5
  done
  vm_ssh "$ip" "cloud-init status --wait" >/dev/null || true
done

# ---------- 6. 노드 공통 설정 ----------
for ip in "${NODE_IPS[@]}"; do
  log "$ip containerd, kubeadm 설치"
  vm_ssh "$ip" "sudo bash -s -- $K8S_VERSION" <<'NODE_SETUP'
set -euo pipefail
K8S_VERSION=$1
export DEBIAN_FRONTEND=noninteractive

swapoff -a
sed -i '/\sswap\s/d' /etc/fstab

printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf <<SYSCTL
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
SYSCTL
sysctl --system >/dev/null

apt-get update -q
apt-get install -yq containerd qemu-guest-agent apt-transport-https ca-certificates curl gpg
systemctl enable --now qemu-guest-agent

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml
systemctl restart containerd

mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -q
apt-get install -yq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
NODE_SETUP
done

# ---------- 7. 클러스터 구성 ----------
log "control plane 초기화 ($CP_IP)"
vm_ssh "$CP_IP" "sudo kubeadm init --pod-network-cidr=$POD_CIDR --apiserver-advertise-address=$CP_IP"
vm_ssh "$CP_IP" 'mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown "$(id -u):$(id -g)" ~/.kube/config'
vm_ssh "$CP_IP" "kubectl apply -f $FLANNEL_URL"

JOIN_COMMAND=$(vm_ssh "$CP_IP" "sudo kubeadm token create --print-join-command")
for ip in "${NODE_IPS[@]:1}"; do
  log "worker 합류 ($ip)"
  vm_ssh "$ip" "sudo $JOIN_COMMAND"
done

# ---------- 8. 마무리 ----------
log "노드 Ready 대기"
vm_ssh "$CP_IP" "kubectl wait --for=condition=Ready nodes --all --timeout=300s"
vm_ssh "$CP_IP" "kubectl get nodes -o wide"

log "완료. 내 PC 에서 아래 명령으로 접속합니다."
for i in "${!NODE_IPS[@]}"; do
  echo "  ssh $CI_USER@${NODE_IPS[$i]}   # ${NODE_NAMES[$i]}"
done
```
{: file="k8s-proxmox.sh" }

</details>

- **확인:** 현재 폴더에 `k8s-proxmox.sh` 파일 생성

## 2. 변수 수정

스크립트 맨 위의 변수를 내 환경에 맞게 고칩니다. 스토리지와 네트워크 값은 반드시 확인하고, 나머지는 기본값을 그대로 써도 됩니다.

```bash
# 스크립트 상단의 변수 수정
nano k8s-proxmox.sh
```

| 변수 | 기본값 | 설명 |
| :--- | :--- | :--- |
| `STORAGE` | `local-lvm` | VM 디스크를 둘 스토리지 |
| `BRIDGE` | `vmbr0` | VM이 연결될 브리지 |
| `IP_PREFIX` | `192.168.0` | 노드 IP의 앞 세 자리 |
| `IP_START` | `201` | control plane IP의 끝자리, worker는 1씩 증가 |
| `GATEWAY` | `192.168.0.1` | 게이트웨이(공유기) 주소 |
| `CP_ID` | `201` | control plane VM ID, worker는 1씩 증가 |
| `TEMPLATE_ID` | `9000` | 클라우드 이미지 템플릿 VM ID |
| `WORKER_COUNT` | `1` | worker 수 |
| `CP_CORES`, `CP_MEMORY`, `CP_DISK` | `4`, `8192`, `32G` | control plane 자원 |
| `WORKER_CORES`, `WORKER_MEMORY`, `WORKER_DISK` | `16`, `32768`, `100G` | worker 자원 |

> 자원 기본값은 16코어 32스레드, RAM 64GB 호스트를 기준으로 worker 한 대에 자원을 몰아 준 값입니다. 모든 VM의 메모리 합이 호스트의 남은 메모리를 넘지 않게 조정합니다.
{: .prompt-warning }

- **확인:** `STORAGE`, `BRIDGE` 값이 Proxmox 웹 UI의 스토리지, 네트워크 이름과 일치

## 3. 스크립트 실행

스크립트를 실행하면 아래 작업이 순서대로 진행됩니다.

```bash
# 클러스터 생성
bash k8s-proxmox.sh
```

1. VM ID와 IP가 비어 있는지 검사
2. Proxmox의 `authorized_keys`와 호스트 공개키를 VM에 넣을 키 목록으로 준비
3. Ubuntu 24.04 클라우드 이미지로 템플릿 VM 생성
4. 템플릿을 복제해 `k8s-cp`, `k8s-worker-1` VM을 만들고 고정 IP 설정 후 시작
5. 각 VM에 containerd, kubelet, kubeadm, kubectl 설치
6. control plane에서 `kubeadm init` 실행 후 Flannel 적용
7. worker에서 `kubeadm join` 실행

- **확인:** 마지막에 출력되는 노드 목록에서 두 노드의 `STATUS`가 모두 `Ready`

## 4. 내 PC에서 접속

내 PC의 터미널에서 control plane에 접속해 클러스터 상태를 확인합니다. 계정은 `ubuntu`이고 비밀번호 없이 키로 인증합니다.

```bash
# control plane 접속 후 노드 확인
ssh ubuntu@[CP_IP]
kubectl get nodes
```

- **확인:** 비밀번호를 묻지 않고 접속되며 `k8s-cp`, `k8s-worker-1`이 `Ready`로 표시

## 트러블슈팅

<details markdown="1">
<summary><code>VM ID ... 가 이미 사용 중입니다</code> 또는 <code>IP ... 가 이미 사용 중입니다</code></summary>

- **원인:** 같은 ID의 VM이나 컨테이너가 이미 있거나, 해당 IP가 ping에 응답함
- **해결:** `CP_ID` 또는 `IP_START` 값을 비어 있는 번호로 변경

</details>

<details markdown="1">
<summary><code>5분 동안 SSH 로 접속하지 못했습니다</code></summary>

- **원인:** `BRIDGE`, `IP_PREFIX`, `GATEWAY` 값이 실제 네트워크와 달라 VM이 네트워크에 연결되지 않음
- **해결:** 값을 고친 뒤 아래 항목대로 VM을 삭제하고 다시 실행

</details>

<details markdown="1">
<summary>중간에 실패해 처음부터 다시 실행하고 싶을 때</summary>

- **원인:** 스크립트는 이미 있는 VM ID를 덮어쓰지 않고 중단함
- **해결:** 만들어진 노드 VM을 삭제한 뒤 다시 실행 (템플릿은 재사용되므로 그대로 둠)

```bash
# 노드 VM 삭제 (VM ID 는 CP_ID 부터 worker 수만큼)
qm stop 201 && qm destroy 201 --purge
qm stop 202 && qm destroy 202 --purge
```

</details>

## 마무리

Proxmox 호스트에서 스크립트 하나로 VM 생성부터 kubeadm 클러스터 구성까지 마치고, Proxmox에 등록해 둔 키로 내 PC에서 바로 접속했습니다. control plane이 한 대뿐인 구성이므로 고가용성이 필요한 운영 환경보다는 개인 서버와 학습 용도에 적합합니다.

## 참고 자료

- [kubeadm 설치하기](https://kubernetes.io/ko/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [kubeadm으로 클러스터 구성하기](https://kubernetes.io/ko/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [컨테이너 런타임](https://kubernetes.io/ko/docs/setup/production-environment/container-runtimes/)
- [Cloud-Init Support - Proxmox VE](https://pve.proxmox.com/wiki/Cloud-Init_Support)
- [flannel-io/flannel](https://github.com/flannel-io/flannel)
