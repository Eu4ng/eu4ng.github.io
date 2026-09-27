#!/bin/sh
# 상태(인증서 DB, ssh 호스트 키)는 /etc/corosync/qnetd 볼륨에 둡니다. 처음 실행할 때만 만듭니다.
# 환경 변수:
#   AUTHORIZED_KEYS  root 로 ssh 할 수 있는 공개키(줄바꿈으로 여러 개). Proxmox 노드들의 /root/.ssh/id_rsa.pub
#   LISTEN_ADDR      qnetd·sshd 가 받을 주소 (기본 127.0.0.1. NAS 의 Tailscale 이 userspace 모드라 Tailscale IP 로 온 연결이 여기로 옵니다)
#   QNETD_PORT, SSH_PORT  기본 5403, 2222 (NAS 의 22 번은 DSM 이 씀)
set -eu
STATE=/etc/corosync/qnetd
LISTEN_ADDR=${LISTEN_ADDR:-127.0.0.1}
mkdir -p "$STATE/ssh" /run/corosync-qnetd

[ -f "$STATE/nssdb/cert9.db" ] || corosync-qnetd-certutil -i
[ -f "$STATE/ssh/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$STATE/ssh/ssh_host_ed25519_key"
printf '%s\n' "${AUTHORIZED_KEYS:?AUTHORIZED_KEYS 가 필요합니다}" > /etc/ssh/authorized_keys_root
chmod 0644 /etc/ssh/authorized_keys_root

/usr/sbin/sshd -o ListenAddress="$LISTEN_ADDR:${SSH_PORT:-2222}" -o HostKey="$STATE/ssh/ssh_host_ed25519_key" \
  -o PermitRootLogin=prohibit-password -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
  -o AuthorizedKeysFile=/etc/ssh/authorized_keys_root

# 인증서 DB 는 ssh 로 들어온 root 가 고치므로 qnetd 도 root 로 돌립니다(컨테이너 안에서만)
exec corosync-qnetd -f -l "$LISTEN_ADDR" -p "${QNETD_PORT:-5403}"
