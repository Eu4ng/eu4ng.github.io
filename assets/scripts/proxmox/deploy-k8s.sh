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
