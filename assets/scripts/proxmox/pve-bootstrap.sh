#!/usr/bin/env bash
#
# 새로 설치한 Proxmox 노드의 콘솔에서 한 번 실행합니다. GitHub 계정(eu4ng)에 등록된 ssh 공개키를 root 의
# authorized_keys 에 더해, 남은 Proxmox 노드(복구 스크립트)와 작업 PC 가 바로 접속할 수 있게 합니다.
# 비밀값은 없고, 이미 있는 줄은 다시 넣지 않습니다(여러 번 실행해도 됨). 끝에 이 노드의 IP, 호스트 키 지문, 다음에 할 명령을 보여 줍니다.
# 복구 스크립트는 점검 때 받은 이 노드의 호스트 키 지문을 보여 주고 콘솔 값과 같은지 묻습니다. 끝에 나온 지문을 적어 둡니다.
#
# 사용법(새 노드 콘솔, root):
#   curl -fsSL https://eu4ng.github.io/assets/scripts/proxmox/pve-bootstrap.sh | bash
#   GITHUB_USER=<계정> 으로 다른 계정의 키를 받을 수 있습니다.

set -euo pipefail
die() { echo "[오류] $*" >&2; exit 1; }

GITHUB_USER=${GITHUB_USER:-eu4ng}
[ "$(id -u)" = 0 ] || die "root 로 실행합니다."

keys=$(curl -fsSL --retry 3 "https://github.com/${GITHUB_USER}.keys") || die "https://github.com/${GITHUB_USER}.keys 를 받지 못했습니다(네트워크·DNS 확인)."
[ -n "$keys" ] || die "${GITHUB_USER} 계정에 등록된 공개키가 없습니다."

# Proxmox 는 클러스터에 들어가면 /root/.ssh/authorized_keys 를 /etc/pve/priv/authorized_keys 로 바꿉니다. 링크면 링크 대상에 씁니다
umask 077
mkdir -p /root/.ssh
f=/root/.ssh/authorized_keys
touch "$f"
added=0
while IFS= read -r k; do
  [ -n "$k" ] || continue
  if ! grep -qF "$k" "$f"; then
    printf '%s %s@github\n' "$k" "$GITHUB_USER" >> "$f"
    added=$((added + 1))
  fi
done <<< "$keys"
[ -L "$f" ] || chmod 600 "$f"
echo "==> 공개키 $(grep -c . <<< "$keys")개 중 ${added}개를 더했습니다($f)."

# 기본 경로의 출발 주소(LAN). 첫 global 주소는 Tailscale 주소일 수 있습니다
ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')
echo "==> 이 노드: $(hostname -f) ${ip:-<IP 를 찾지 못함>}"
echo "==> 호스트 키 지문(ed25519, 복구 스크립트가 보여 주는 값과 대조): $(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')"
echo
echo "다음: 남은 Proxmox 노드에서 이 노드를 원래 이름으로 다시 만듭니다."
echo "  /root/proxmox-ansible/scripts/pve-node-rebuild.sh ${ip:-<이 노드 IP>} <노드 이름> --reason disk-replaced"
