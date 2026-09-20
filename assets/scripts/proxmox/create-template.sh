#!/usr/bin/env bash
#
# Proxmox VE 호스트에 Ubuntu 24.04 클라우드 이미지 템플릿 VM 을 만듭니다.
# 템플릿에는 접속 계정, SSH 공개키, qemu-guest-agent 설치가 들어 있어 복제한 VM 에 바로 접속할 수 있습니다.
# Proxmox 호스트에서 root 로 한 번만 실행합니다: bash create-template.sh

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
STORAGE=local-lvm          # VM 디스크를 둘 스토리지
BRIDGE=vmbr0               # VM 이 연결될 브리지
TEMPLATE_ID=9000           # 템플릿 VM ID
CI_USER=ubuntu             # VM 접속 계정
SNIPPET_STORAGE=local      # cloud-init 스니펫을 둘 디렉터리형 스토리지
# --------------------------------------

IMAGE_URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
IMAGE_PATH=/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img
TEMPLATE_NAME=ubuntu-2404-cloud
SNIPPET_NAME=ubuntu-cloud-vendor.yaml
AUTHORIZED_KEYS=/root/.ssh/authorized_keys
HOST_KEY=/root/.ssh/id_rsa

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
storage_field() { pvesh get "/storage/$SNIPPET_STORAGE" --output-format json | perl -MJSON -e 'print decode_json(join "", <STDIN>)->{$ARGV[0]} // ""' "$1"; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
log "사전 검사"
[ "$(id -u)" -eq 0 ] || die "root 로 실행해야 합니다."
command -v qm >/dev/null || die "qm 명령이 없습니다. Proxmox VE 호스트에서 실행하세요."
[ -s "$AUTHORIZED_KEYS" ] || die "$AUTHORIZED_KEYS 가 비어 있습니다. 내 PC 의 공개키를 먼저 등록하세요."
pvesm status --storage "$STORAGE" >/dev/null || die "스토리지 $STORAGE 를 찾을 수 없습니다."

if qm config "$TEMPLATE_ID" >/dev/null 2>&1; then
  qm config "$TEMPLATE_ID" | grep -q '^template: 1' \
    || die "VM ID $TEMPLATE_ID 가 템플릿이 아닌 VM 입니다. 이 스크립트가 중간에 실패해 남은 VM 이면 qm destroy $TEMPLATE_ID --purge 후 다시 실행하고, 아니면 TEMPLATE_ID 를 바꾸세요."
  log "템플릿 $TEMPLATE_ID 가 이미 있습니다. 다시 만들려면 먼저 삭제하세요: qm destroy $TEMPLATE_ID --purge"
  exit 0
fi
pvesh get /cluster/nextid --vmid "$TEMPLATE_ID" >/dev/null 2>&1 \
  || die "VM ID $TEMPLATE_ID 가 이미 사용 중입니다. TEMPLATE_ID 를 바꾸세요."

# ---------- 2. cloud-init 스니펫 ----------
# Proxmox 가 만드는 계정, SSH 키 설정에 더해 모든 복제 VM 에 적용할 내용입니다.
log "cloud-init 스니펫 준비"
snippet_dir=$(storage_field path)
[ -n "$snippet_dir" ] || die "$SNIPPET_STORAGE 는 디렉터리형 스토리지가 아닙니다. SNIPPET_STORAGE 를 바꾸세요."
content=$(storage_field content)
if [[ ",$content," != *,snippets,* ]]; then
  log "$SNIPPET_STORAGE 스토리지에 snippets 콘텐츠 추가 (기존: $content)"
  pvesm set "$SNIPPET_STORAGE" --content "$content,snippets"
fi
mkdir -p "$snippet_dir/snippets"
cat > "$snippet_dir/snippets/$SNIPPET_NAME" <<'SNIPPET'
#cloud-config
# cloud-init 설정이 바뀌어도(호스트 DNS 변경 등) SSH 호스트 키를 유지
ssh_deletekeys: false
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
SNIPPET

# ---------- 3. VM 에 넣을 공개키 ----------
# authorized_keys: 내 PC 에서 VM 으로 접속하는 용도
# 호스트 공개키: Proxmox 호스트의 스크립트가 VM 에 접속해 설정하는 용도
log "공개키 준비"
[ -f "$HOST_KEY" ] || ssh-keygen -q -t rsa -b 4096 -N '' -f "$HOST_KEY"
KEYS_FILE=$(mktemp)
trap 'rm -f "$KEYS_FILE"' EXIT
{ cat "$AUTHORIZED_KEYS"; echo; cat "$HOST_KEY.pub"; } | grep -vE '^\s*(#|$)' | awk '!seen[$0]++' > "$KEYS_FILE"

# ---------- 4. 클라우드 이미지 ----------
log "클라우드 이미지 준비"
if [ ! -f "$IMAGE_PATH" ]; then
  wget -q --show-progress -O "$IMAGE_PATH.part" "$IMAGE_URL"
  mv "$IMAGE_PATH.part" "$IMAGE_PATH"
fi

# ---------- 5. 템플릿 VM ----------
log "템플릿 $TEMPLATE_ID 생성"
qm create "$TEMPLATE_ID" --name "$TEMPLATE_NAME" --ostype l26 \
  --cpu host --cores 2 --memory 2048 --balloon 0 --agent 1 \
  --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-single \
  --serial0 socket --vga serial0
qm set "$TEMPLATE_ID" --scsi0 "$STORAGE:0,import-from=$IMAGE_PATH,iothread=1,discard=on,ssd=1"
qm set "$TEMPLATE_ID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0
qm set "$TEMPLATE_ID" --ciuser "$CI_USER" --sshkeys "$KEYS_FILE" --ciupgrade 0 \
  --cicustom "vendor=$SNIPPET_STORAGE:snippets/$SNIPPET_NAME"
qm template "$TEMPLATE_ID"

log "완료. 복제: qm clone $TEMPLATE_ID [VM_ID] --name [NAME] --full"
