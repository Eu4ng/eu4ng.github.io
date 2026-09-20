---
layout: post
title: Proxmox에 kubeadm으로 쿠버네티스 클러스터 설치하는 방법
date: 2026-09-20 10:03 +0900
permalink: /posts/32/
description: Proxmox 호스트에서 스크립트 하나로 템플릿 복제부터 kubeadm 클러스터 구성까지 끝내고, 설정을 바꿀 때는 노드만 지우고 다시 배포하는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, kubernetes, kubeadm, cloud-init, ssh]
---

Proxmox 호스트에서 스크립트를 한 번 실행해 control plane 1대와 worker 1대로 이루어진 쿠버네티스 클러스터를 만듭니다. VM은 미리 만들어 둔 Ubuntu 템플릿을 복제해서 만들기 때문에, 설정을 바꿔 다시 배포할 때도 같은 스크립트만 다시 실행하면 됩니다.

1. 스크립트 내려받기
2. 변수 수정
3. 스크립트 실행
4. 내 PC에서 접속
5. 노드를 지우고 다시 배포

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
- 접속 계정과 SSH 공개키가 들어 있는 Ubuntu 템플릿 (만드는 방법은 [Proxmox에서 Ubuntu 클라우드 이미지 템플릿 만드는 방법](/posts/33/) 참고)
- 같은 대역에서 사용하지 않는 고정 IP 2개 (control plane, worker)

## 1. 스크립트 내려받기

Proxmox 호스트의 root 셸에서 스크립트를 내려받습니다.

```bash
# 배포 스크립트 내려받기
wget https://eu4ng.github.io/assets/scripts/proxmox/deploy-k8s.sh
```

<details markdown="1">
<summary>스크립트 전문 보기</summary>

```bash
#!/usr/bin/env bash
#
# create-template.sh 로 만든 템플릿 VM 을 복제해 kubeadm 쿠버네티스 클러스터(control plane 1 + worker N)를 만듭니다.
# Proxmox 호스트에서 root 로 실행합니다.
#   bash deploy-k8s.sh           클러스터 배포
#   bash deploy-k8s.sh destroy   배포한 노드 VM 삭제 (템플릿은 그대로)

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
TEMPLATE_ID=9000           # create-template.sh 로 만든 템플릿 VM ID
CP_ID=201                  # control plane VM ID (worker 는 +1 씩 증가)
WORKER_COUNT=1             # worker 수
ONBOOT=1                   # 1 이면 Proxmox 호스트가 부팅할 때 노드도 자동 시작

IP_PREFIX=192.168.0        # 노드 IP 앞 세 자리
IP_START=201               # control plane IP 끝자리 (worker 는 +1 씩 증가)
CIDR=24
GATEWAY=192.168.0.1
DNS=                       # 비워 두면 Proxmox 호스트의 DNS 를 따라감 (값을 넣으면 VM 에 고정)

CP_CORES=4
CP_MEMORY=8192             # MiB
CP_DISK=32G
WORKER_CORES=16
WORKER_MEMORY=32768        # MiB
WORKER_DISK=100G

K8S_VERSION=v1.37          # pkgs.k8s.io 저장소의 마이너 버전
POD_CIDR=10.244.0.0/16     # Flannel 기본값
# --------------------------------------

FLANNEL_URL=https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
HOST_KEY=/root/.ssh/id_rsa
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
vm_ssh() { local ip=$1; shift; ssh -i "$HOST_KEY" "${SSH_OPTS[@]}" "$CI_USER@$ip" "$@"; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# 노드 목록: 첫 번째가 control plane
NODE_IDS=() NODE_IPS=() NODE_NAMES=()
for i in $(seq 0 "$WORKER_COUNT"); do
  NODE_IDS+=("$((CP_ID + i))")
  NODE_IPS+=("$IP_PREFIX.$((IP_START + i))")
  if [ "$i" -eq 0 ]; then NODE_NAMES+=(k8s-cp); else NODE_NAMES+=("k8s-worker-$i"); fi
done
CP_IP=${NODE_IPS[0]}

[ "$(id -u)" -eq 0 ] || die "root 로 실행해야 합니다."
command -v qm >/dev/null || die "qm 명령이 없습니다. Proxmox VE 호스트에서 실행하세요."

# ---------- destroy: 노드 VM 삭제 ----------
# VM ID 와 이름이 모두 일치하는 VM 만 삭제합니다.
if [ "${1:-}" = destroy ]; then
  log "삭제 대상 확인"
  targets=()
  for i in "${!NODE_IDS[@]}"; do
    id=${NODE_IDS[$i]} name=${NODE_NAMES[$i]}
    if ! qm config "$id" >/dev/null 2>&1; then
      echo "  $id: VM 없음, 건너뜀"
      continue
    fi
    actual=$(qm config "$id" | awk '/^name: /{print $2}')
    if [ "$actual" != "$name" ]; then
      echo "  $id: 이름이 $actual 이라 건너뜀 (예상한 이름: $name)"
      continue
    fi
    echo "  $id: $name 삭제 예정"
    targets+=("$id")
  done
  [ "${#targets[@]}" -gt 0 ] || { log "삭제할 노드 VM 이 없습니다."; exit 0; }

  read -r -p "위 VM 과 디스크를 모두 삭제합니다. 계속하려면 y 를 입력하세요: " answer
  [ "$answer" = y ] || die "취소했습니다."
  for id in "${targets[@]}"; do
    log "VM $id 삭제"
    qm stop "$id"
    qm destroy "$id" --purge
  done
  log "완료. 템플릿 $TEMPLATE_ID 는 그대로 두었습니다."
  exit 0
fi
[ -z "${1:-}" ] || die "알 수 없는 인자: $1 (사용법: bash deploy-k8s.sh [destroy])"

# ---------- 1. 사전 검사 ----------
log "사전 검사"
template_conf=$(qm config "$TEMPLATE_ID" 2>/dev/null) || true
grep -q '^template: 1' <<<"$template_conf" \
  || die "템플릿 $TEMPLATE_ID 이 없습니다. create-template.sh 를 먼저 실행하세요."
grep -q '^sshkeys:' <<<"$template_conf" && [ -f "$HOST_KEY" ] \
  || die "템플릿 $TEMPLATE_ID 에 SSH 키가 없습니다. create-template.sh 로 템플릿을 다시 만드세요."
CI_USER=$(awk '/^ciuser:/{print $2}' <<<"$template_conf")
[ -n "$CI_USER" ] || die "템플릿 $TEMPLATE_ID 에 접속 계정이 없습니다. create-template.sh 로 템플릿을 다시 만드세요."
for i in "${!NODE_IDS[@]}"; do
  pvesh get /cluster/nextid --vmid "${NODE_IDS[$i]}" >/dev/null 2>&1 \
    || die "VM ID ${NODE_IDS[$i]} 가 이미 사용 중입니다. CP_ID 를 바꾸거나 bash deploy-k8s.sh destroy 로 기존 노드를 삭제하세요."
  ! ping -c 1 -W 1 "${NODE_IPS[$i]}" >/dev/null 2>&1 \
    || die "IP ${NODE_IPS[$i]} 가 이미 사용 중입니다. IP_START 를 바꾸세요."
done

# ---------- 2. 노드 VM ----------
# 접속 계정, SSH 키, qemu-guest-agent 는 템플릿에서 물려받습니다.
for i in "${!NODE_IDS[@]}"; do
  id=${NODE_IDS[$i]} ip=${NODE_IPS[$i]} name=${NODE_NAMES[$i]}
  if [ "$i" -eq 0 ]; then cores=$CP_CORES memory=$CP_MEMORY disk=$CP_DISK
  else cores=$WORKER_CORES memory=$WORKER_MEMORY disk=$WORKER_DISK; fi

  log "VM $id ($name, $ip) 생성"
  net_args=(--ipconfig0 "ip=$ip/$CIDR,gw=$GATEWAY")
  [ -z "$DNS" ] || net_args+=(--nameserver "$DNS")
  qm clone "$TEMPLATE_ID" "$id" --name "$name" --full
  qm config "$id" | grep -q '^sshkeys:' || die "VM $id 가 템플릿의 SSH 키를 물려받지 못했습니다."
  qm set "$id" --cores "$cores" --memory "$memory" --onboot "$ONBOOT" "${net_args[@]}"
  qm resize "$id" scsi0 "$disk"
  qm start "$id"
done

# ---------- 3. SSH 대기 ----------
for ip in "${NODE_IPS[@]}"; do
  log "$ip SSH 대기"
  for try in $(seq 1 60); do
    vm_ssh "$ip" true 2>/dev/null && break
    [ "$try" -lt 60 ] || die "$ip 에 5분 동안 SSH 로 접속하지 못했습니다. 네트워크 값을 확인하고, 템플릿을 만든 뒤 호스트 SSH 키가 바뀌었다면 템플릿을 다시 만드세요."
    sleep 5
  done
  vm_ssh "$ip" "cloud-init status --wait" >/dev/null || true
done

# ---------- 4. 노드 공통 설정 ----------
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
apt-get install -yq containerd apt-transport-https ca-certificates curl gpg

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

# ---------- 5. 클러스터 구성 ----------
log "control plane 초기화 ($CP_IP)"
vm_ssh "$CP_IP" "sudo kubeadm init --pod-network-cidr=$POD_CIDR --apiserver-advertise-address=$CP_IP"
vm_ssh "$CP_IP" 'mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown "$(id -u):$(id -g)" ~/.kube/config'
vm_ssh "$CP_IP" "kubectl apply -f $FLANNEL_URL"

JOIN_COMMAND=$(vm_ssh "$CP_IP" "sudo kubeadm token create --print-join-command")
for ip in "${NODE_IPS[@]:1}"; do
  log "worker 합류 ($ip)"
  vm_ssh "$ip" "sudo $JOIN_COMMAND"
done

# ---------- 6. 마무리 ----------
log "노드 Ready 대기"
vm_ssh "$CP_IP" "kubectl wait --for=condition=Ready nodes --all --timeout=300s"
vm_ssh "$CP_IP" "kubectl get nodes -o wide"

log "완료. 내 PC 에서 아래 명령으로 접속합니다."
for i in "${!NODE_IPS[@]}"; do
  echo "  ssh $CI_USER@${NODE_IPS[$i]}   # ${NODE_NAMES[$i]}"
done
```
{: file="deploy-k8s.sh" }

</details>

- **확인:** 현재 폴더에 `deploy-k8s.sh` 파일 생성

## 2. 변수 수정

스크립트 맨 위의 변수를 내 환경에 맞게 고칩니다. 네트워크 값은 반드시 확인하고, 나머지는 기본값을 그대로 써도 됩니다.

```bash
# 스크립트 상단의 변수 수정
nano deploy-k8s.sh
```

| 변수 | 기본값 | 설명 |
| :--- | :--- | :--- |
| `TEMPLATE_ID` | `9000` | 복제할 템플릿 VM ID |
| `IP_PREFIX` | `192.168.0` | 노드 IP의 앞 세 자리 |
| `IP_START` | `201` | control plane IP의 끝자리, worker는 1씩 증가 |
| `GATEWAY` | `192.168.0.1` | 게이트웨이(공유기) 주소 |
| `DNS` | (비움) | 비워 두면 Proxmox 호스트의 DNS를 따라감 |
| `CP_ID` | `201` | control plane VM ID, worker는 1씩 증가 |
| `WORKER_COUNT` | `1` | worker 수 |
| `ONBOOT` | `1` | `1`이면 Proxmox 호스트가 부팅할 때 노드도 자동 시작 |
| `CP_CORES`, `CP_MEMORY`, `CP_DISK` | `4`, `8192`, `32G` | control plane 자원 |
| `WORKER_CORES`, `WORKER_MEMORY`, `WORKER_DISK` | `16`, `32768`, `100G` | worker 자원 |

> 자원 기본값은 16코어 32스레드, RAM 64GB 호스트를 기준으로 worker 한 대에 자원을 몰아 준 값입니다. 모든 VM의 메모리 합이 호스트의 남은 메모리를 넘지 않게 조정합니다.
{: .prompt-warning }

- **확인:** `IP_PREFIX`, `GATEWAY` 값이 내 네트워크와 일치하고, 사용할 IP가 비어 있음

## 3. 스크립트 실행

스크립트를 실행하면 아래 작업이 순서대로 진행됩니다.

```bash
# 클러스터 배포
bash deploy-k8s.sh
```

1. 템플릿이 있는지, VM ID와 IP가 비어 있는지 검사
2. 템플릿을 복제해 `k8s-cp`, `k8s-worker-1` VM을 만들고 고정 IP 설정 후 시작
3. 각 VM에 containerd, kubelet, kubeadm, kubectl 설치
4. control plane에서 `kubeadm init` 실행 후 Flannel 적용
5. worker에서 `kubeadm join` 실행

`DNS`를 비워 둔 경우, 나중에 Proxmox 호스트의 DNS를 바꾸면 VM을 Proxmox에서 정지했다가 시작할 때 새 값이 반영됩니다.

- **확인:** 마지막에 출력되는 노드 목록에서 두 노드의 `STATUS`가 모두 `Ready`

## 4. 내 PC에서 접속

내 PC의 터미널에서 control plane에 접속해 클러스터 상태를 확인합니다. 계정과 키는 템플릿에 넣어 둔 것을 그대로 쓰므로 비밀번호 없이 접속됩니다.

```bash
# control plane 접속 후 노드 확인
ssh ubuntu@[CP_IP]
kubectl get nodes
```

- **확인:** 비밀번호를 묻지 않고 접속되며 `k8s-cp`, `k8s-worker-1`이 `Ready`로 표시

## 5. 노드를 지우고 다시 배포

IP, 자원, 쿠버네티스 버전처럼 배포 후에는 바꾸기 어려운 설정을 바꿀 때는 노드를 지우고 다시 배포합니다. 템플릿은 그대로 씁니다.

```bash
# 노드 VM 삭제 (삭제 대상을 보여 준 뒤 y 를 입력해야 진행)
bash deploy-k8s.sh destroy

# 변수 수정 후 다시 배포
nano deploy-k8s.sh
bash deploy-k8s.sh
```

> `destroy`는 노드 VM과 디스크를 모두 삭제하므로 클러스터 안의 데이터도 함께 사라집니다. VM ID와 이름(`k8s-cp`, `k8s-worker-N`)이 모두 일치하는 VM만 삭제하며, `CP_ID`나 `WORKER_COUNT`를 바꾸려면 바꾸기 전에 먼저 실행합니다.
{: .prompt-danger }

- **확인:** Proxmox 웹 UI에서 기존 노드 VM이 사라지고, 다시 배포한 뒤 두 노드가 `Ready`

## 트러블슈팅

<details markdown="1">
<summary><code>템플릿 ... 이 없습니다</code> 또는 <code>템플릿 ... 에 SSH 키가 없습니다</code></summary>

- **원인:** 템플릿을 만들지 않았거나 `TEMPLATE_ID`가 다름, 또는 계정과 SSH 키가 없는 템플릿임
- **해결:** [Proxmox에서 Ubuntu 클라우드 이미지 템플릿 만드는 방법](/posts/33/)대로 템플릿을 만들고 `TEMPLATE_ID`를 같은 값으로 맞춤

</details>

<details markdown="1">
<summary><code>VM ID ... 가 이미 사용 중입니다</code> 또는 <code>IP ... 가 이미 사용 중입니다</code></summary>

- **원인:** 같은 ID의 VM이나 컨테이너가 이미 있거나, 해당 IP가 ping에 응답함
- **해결:** 이전에 배포한 노드라면 `bash deploy-k8s.sh destroy`로 삭제하고, 다른 VM이나 장비라면 `CP_ID` 또는 `IP_START` 값을 비어 있는 번호로 변경

</details>

<details markdown="1">
<summary><code>5분 동안 SSH 로 접속하지 못했습니다</code></summary>

- **원인:** `IP_PREFIX`, `GATEWAY` 값이 실제 네트워크와 다르거나, 템플릿을 만든 뒤 Proxmox 호스트의 SSH 키가 바뀜
- **해결:** `bash deploy-k8s.sh destroy`로 노드를 삭제하고, 값을 고치거나 템플릿을 다시 만든 뒤 다시 실행

</details>

<details markdown="1">
<summary>다시 배포한 뒤 내 PC에서 <code>REMOTE HOST IDENTIFICATION HAS CHANGED!</code></summary>

- **원인:** 같은 IP에 새 VM이 만들어져 SSH 호스트 키가 바뀜
- **해결:** 내 PC에서 `ssh-keygen -R [CP_IP]`로 이전 호스트 키를 지우고 다시 접속

</details>

<details markdown="1">
<summary>VM 안에서 도메인 이름을 찾지 못함</summary>

- **원인:** Proxmox 호스트의 DNS가 `127.0.0.1` 같은 로컬 주소라 VM에서는 쓸 수 없음 (추정)
- **해결:** `deploy-k8s.sh`의 `DNS`에 사용할 DNS 주소를 직접 지정해 다시 배포

</details>

## 마무리

템플릿을 복제하는 스크립트 하나로 VM 생성부터 kubeadm 클러스터 구성까지 마치고, 내 PC에서 바로 접속했습니다. control plane이 한 대뿐인 구성이므로 고가용성이 필요한 운영 환경보다는 개인 서버와 학습 용도에 적합합니다. 웹 대시보드가 필요하다면 [쿠버네티스에 Headlamp 대시보드 설치하는 방법](/posts/34/)으로 이어서 진행합니다.

## 참고 자료

- [kubeadm 설치하기](https://kubernetes.io/ko/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [kubeadm으로 클러스터 구성하기](https://kubernetes.io/ko/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [컨테이너 런타임](https://kubernetes.io/ko/docs/setup/production-environment/container-runtimes/)
- [flannel-io/flannel](https://github.com/flannel-io/flannel)
