#!/usr/bin/env bash
#
# Proxmox VE 호스트에 Ubuntu 24.04 클라우드 이미지 템플릿 VM 을 만듭니다.
# Proxmox 호스트에서 root 로 한 번만 실행합니다: bash create-template.sh

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
STORAGE=local-lvm          # VM 디스크를 둘 스토리지
BRIDGE=vmbr0               # VM 이 연결될 브리지
TEMPLATE_ID=9000           # 템플릿 VM ID (deploy-k8s.sh 의 TEMPLATE_ID 와 같아야 함)
# --------------------------------------

IMAGE_URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
IMAGE_PATH=/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img
TEMPLATE_NAME=ubuntu-2404-cloud

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
log "사전 검사"
[ "$(id -u)" -eq 0 ] || die "root 로 실행해야 합니다."
command -v qm >/dev/null || die "qm 명령이 없습니다. Proxmox VE 호스트에서 실행하세요."
pvesm status --storage "$STORAGE" >/dev/null || die "스토리지 $STORAGE 를 찾을 수 없습니다."

if qm config "$TEMPLATE_ID" >/dev/null 2>&1; then
  qm config "$TEMPLATE_ID" | grep -q '^template: 1' \
    || die "VM ID $TEMPLATE_ID 가 템플릿이 아닌 VM 으로 사용 중입니다. TEMPLATE_ID 를 바꾸세요."
  log "템플릿 $TEMPLATE_ID 가 이미 있습니다. 다시 만들려면 먼저 삭제하세요: qm destroy $TEMPLATE_ID --purge"
  exit 0
fi
pvesh get /cluster/nextid --vmid "$TEMPLATE_ID" >/dev/null 2>&1 \
  || die "VM ID $TEMPLATE_ID 가 이미 사용 중입니다. TEMPLATE_ID 를 바꾸세요."

# ---------- 2. 클라우드 이미지 내려받기 ----------
log "클라우드 이미지 준비"
if [ ! -f "$IMAGE_PATH" ]; then
  wget -q --show-progress -O "$IMAGE_PATH.part" "$IMAGE_URL"
  mv "$IMAGE_PATH.part" "$IMAGE_PATH"
fi

# ---------- 3. 템플릿 VM 생성 ----------
log "템플릿 $TEMPLATE_ID 생성"
qm create "$TEMPLATE_ID" --name "$TEMPLATE_NAME" --ostype l26 \
  --cpu host --cores 2 --memory 2048 --balloon 0 --agent 1 \
  --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-single \
  --serial0 socket --vga serial0
qm set "$TEMPLATE_ID" --scsi0 "$STORAGE:0,import-from=$IMAGE_PATH,iothread=1,discard=on,ssd=1"
qm set "$TEMPLATE_ID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0
qm template "$TEMPLATE_ID"

log "완료. 이어서 deploy-k8s.sh 를 실행합니다."
