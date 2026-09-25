---
layout: post
title: Proxmox에서 Ubuntu 클라우드 이미지 템플릿 만드는 방법
date: 2026-09-20 10:46 +0900
permalink: /posts/33/
description: 접속 계정과 SSH 공개키, QEMU 게스트 에이전트가 미리 들어 있어 복제하자마자 내 PC에서 SSH로 접속할 수 있는 Ubuntu 템플릿을 스크립트로 만드는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, ubuntu, cloud-init, template, ssh]
---

Proxmox 호스트에서 스크립트를 한 번 실행해 Ubuntu 24.04 클라우드 이미지 템플릿을 만듭니다. 스크립트가 Proxmox의 `authorized_keys`를 템플릿에 넣어 두므로, Proxmox에 SSH로 접속하던 PC라면 템플릿을 복제한 VM에도 추가 설정 없이 접속할 수 있습니다.

> 같은 템플릿을 Ansible 플레이북으로 만드는 방법은 [Proxmox에 Ansible로 kubeadm 쿠버네티스 클러스터 만드는 방법](/posts/46/)의 2단계에 정리했습니다.
{: .prompt-info }

1. 스크립트 내려받기
2. 변수 수정
3. 스크립트 실행
4. 복제해서 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Proxmox VE | `9` |
| VM 운영체제 | `Ubuntu 24.04 (클라우드 이미지)` |
| 작성 기준일 | `2026-09-20` |

다음 항목이 준비되어 있어야 합니다.

- Proxmox 호스트의 root 셸 (웹 UI의 **Shell** 또는 SSH)
- Proxmox 호스트의 `/root/.ssh/authorized_keys`에 내 PC의 공개키 등록 (등록 방법은 [Windows와 리눅스 서버에서 GitHub SSH 키와 커밋 서명 설정하는 방법](/posts/31/)의 2단계 참고)

## 1. 스크립트 내려받기

Proxmox 호스트의 root 셸에서 스크립트를 내려받습니다.

```bash
# 템플릿 생성 스크립트 내려받기
wget https://eu4ng.github.io/assets/scripts/proxmox/create-template.sh
```

<details markdown="1">
<summary>스크립트 전문 보기</summary>

```bash
#!/usr/bin/env bash
#
# Proxmox VE 호스트에 Ubuntu 24.04 클라우드 이미지 템플릿 VM 을 만듭니다.
# 템플릿에는 접속 계정, SSH 공개키, qemu-guest-agent 설치, 부팅 시 자동 시작이 들어 있어 복제한 VM 에 바로 접속할 수 있습니다.
# Proxmox 호스트에서 root 로 한 번만 실행합니다: bash create-template.sh

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
STORAGE=local-lvm          # VM 디스크를 둘 스토리지
BRIDGE=vmbr0               # VM 이 연결될 브리지
TEMPLATE_ID=9000           # 템플릿 VM ID
CI_USER=ubuntu             # VM 접속 계정
ONBOOT=1                   # 1 이면 Proxmox 호스트가 부팅할 때 복제한 VM 도 자동 시작
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
  --cpu host --cores 2 --memory 2048 --agent 1 \
  --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-single \
  --serial0 socket --vga serial0
qm set "$TEMPLATE_ID" --scsi0 "$STORAGE:0,import-from=$IMAGE_PATH,iothread=1,discard=on,ssd=1"
qm set "$TEMPLATE_ID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0
qm set "$TEMPLATE_ID" --onboot "$ONBOOT" --ciuser "$CI_USER" --sshkeys "$KEYS_FILE" --ciupgrade 0 \
  --cicustom "vendor=$SNIPPET_STORAGE:snippets/$SNIPPET_NAME"
qm template "$TEMPLATE_ID"

log "완료. 복제: qm clone $TEMPLATE_ID [VM_ID] --name [NAME] --full"
```
{: file="create-template.sh" }

</details>

- **확인:** 현재 폴더에 `create-template.sh` 파일 생성

## 2. 변수 수정

스크립트 맨 위의 변수를 내 환경에 맞게 고칩니다.

```bash
# 스크립트 상단의 변수 수정
nano create-template.sh
```

| 변수 | 기본값 | 설명 |
| :--- | :--- | :--- |
| `STORAGE` | `local-lvm` | VM 디스크를 둘 스토리지 |
| `BRIDGE` | `vmbr0` | VM이 연결될 브리지 |
| `TEMPLATE_ID` | `9000` | 템플릿 VM ID |
| `CI_USER` | `ubuntu` | VM 접속 계정 |
| `ONBOOT` | `1` | `1`이면 Proxmox 호스트가 부팅할 때 복제한 VM도 자동 시작 |
| `SNIPPET_STORAGE` | `local` | cloud-init 스니펫을 둘 디렉터리형 스토리지 |

- **확인:** `STORAGE`, `BRIDGE` 값이 Proxmox 웹 UI의 스토리지, 네트워크 이름과 일치

## 3. 스크립트 실행

스크립트를 실행하면 아래 작업이 순서대로 진행됩니다.

```bash
# 템플릿 생성
bash create-template.sh
```

1. `SNIPPET_STORAGE`에 스니펫 콘텐츠가 꺼져 있으면 켜고, 모든 복제 VM에 적용할 cloud-init 스니펫 저장 (QEMU 게스트 에이전트 설치, SSH 호스트 키 유지)
2. Proxmox의 `authorized_keys`와 호스트 공개키를 VM에 넣을 키 목록으로 준비
3. Ubuntu 24.04 클라우드 이미지를 내려받아 템플릿 VM 생성
4. 템플릿에 접속 계정, 공개키, 스니펫, 부팅 시 자동 시작 설정

`ONBOOT`을 `1`로 두면 이 템플릿을 복제한 모든 VM이 Proxmox 호스트가 부팅할 때 함께 켜집니다. 특정 VM만 끄려면 `qm set [VM_ID] --onboot 0`을 실행합니다.

메모리 balloon 장치는 Proxmox 기본값대로 켜 둡니다. 최소 메모리를 따로 정하지 않으므로 VM 메모리가 줄어들지는 않고, 게스트가 비운 메모리만 호스트로 돌려줍니다(free page reporting). `--balloon 0`으로 장치를 끄면 게스트가 한 번 쓴 메모리가 VM을 끌 때까지 호스트에 잡혀 있어, 게스트 안은 한가해도 호스트 메모리가 가득 찹니다.

> 이 템플릿을 복제한 VM은 Proxmox의 `authorized_keys`에 있는 모든 키와 Proxmox 호스트의 root 키로 접속할 수 있습니다. 키는 템플릿을 만든 시점의 값으로 고정되므로, `authorized_keys`를 바꿨다면 템플릿을 지우고 다시 만듭니다.
{: .prompt-warning }

- **확인:** Proxmox 웹 UI의 VM 목록에 `9000 (ubuntu-2404-cloud)` 템플릿이 표시되고, **Cloud-Init** 탭에 사용자와 SSH 공개키 표시

## 4. 복제해서 확인

템플릿을 복제해 고정 IP를 지정하고 시작한 뒤, 내 PC에서 접속되는지 확인합니다.

```bash
# Proxmox 호스트: 템플릿 복제 후 시작
qm clone 9000 [VM_ID] --name [VM_NAME] --full
qm set [VM_ID] --ipconfig0 ip=[VM_IP]/24,gw=[GATEWAY]
qm start [VM_ID]
```

```bash
# 내 PC: 1~2분 뒤 접속
ssh ubuntu@[VM_IP]
```

- **확인:** 비밀번호를 묻지 않고 접속되며, Proxmox 웹 UI의 VM **Summary**에 IP 주소 표시

## 트러블슈팅

<details markdown="1">
<summary><code>템플릿 ... 가 이미 있습니다</code></summary>

- **원인:** 같은 ID의 템플릿이 이미 있어 스크립트가 아무것도 바꾸지 않고 종료함
- **해결:** 다시 만들려면 템플릿을 삭제한 뒤 스크립트를 다시 실행 (이미 복제한 VM에는 영향 없음)

```bash
# 템플릿 삭제
qm destroy 9000 --purge
```

</details>

<details markdown="1">
<summary>VM 안에서는 메모리가 비어 있는데 호스트에서는 VM 메모리가 전부 사용 중으로 보임</summary>

- **원인:** `balloon: 0`으로 만든 VM이라 게스트가 비운 메모리를 호스트에 돌려주지 못함 (`qm config [VM_ID]`에 `balloon: 0` 표시)
- **해결:** balloon 최소값을 VM 메모리와 같게 지정하고 VM을 껐다 켬. 장치가 새로 붙어야 하므로 게스트 안에서 재부팅하는 것으로는 반영되지 않음

```bash
# balloon 장치 켜기 (최소값 = VM 메모리, MiB)
qm set [VM_ID] --balloon [MEMORY_MB]
qm shutdown [VM_ID] && qm start [VM_ID]
```

</details>

## 마무리

계정과 SSH 공개키, QEMU 게스트 에이전트가 미리 들어 있는 Ubuntu 템플릿을 만들어, 복제한 VM에 내 PC에서 바로 접속했습니다. 이 템플릿으로 쿠버네티스 클러스터를 만드는 방법은 [Proxmox에 kubeadm으로 쿠버네티스 클러스터 설치하는 방법](/posts/32/)에서 이어집니다.

## 참고 자료

- [Cloud-Init Support - Proxmox VE](https://pve.proxmox.com/wiki/Cloud-Init_Support)
- [Ubuntu Cloud Images](https://cloud-images.ubuntu.com/)
