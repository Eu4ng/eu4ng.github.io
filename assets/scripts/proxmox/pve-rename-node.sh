#!/usr/bin/env bash
#
# 단독(클러스터에 들어가지 않은) Proxmox 노드의 이름을 바꿉니다. 게스트는 켠 채로 둬도 됩니다.
# 실행 중인 VM·CT 프로세스는 노드 이름과 무관하고, 이 스크립트는 게스트 설정 파일만 새 노드 폴더로 옮깁니다.
# 클러스터 노드는 이름을 바꿀 수 없으므로 중단합니다. 클러스터를 만들기 전에 실행합니다(playbooks/pve-cluster.yml 이 호출).
# 이미 새 이름이면 남은 옛 폴더의 게스트 설정만 옮기고 끝냅니다. 여러 번 실행해도 됩니다.
# 옛 노드 폴더(/etc/pve/nodes/<옛 이름>)는 지우지 않습니다. 확인한 뒤 직접 지웁니다.
#
# 사용법(호스트에서 root): bash pve-rename-node.sh <새 이름> <도메인>
#   ssh 가 끊겨도 멈추지 않게 systemd-run 으로 돌리는 것을 권합니다:
#   systemd-run --unit pve-rename-node --collect bash pve-rename-node.sh pve01 example.com; journalctl -fu pve-rename-node

set -euo pipefail
log() { echo "==> $*"; }
die() { echo "[오류] $*" >&2; exit 1; }

NEW=${1:-}; DOMAIN=${2:-}
[ -n "$NEW" ] && [ -n "$DOMAIN" ] || die "사용법: bash pve-rename-node.sh <새 이름> <도메인>"
[ "$(id -u)" = 0 ] || die "root 로 실행합니다."
[ -e /etc/pve/corosync.conf ] && die "클러스터에 들어간 노드는 이름을 바꿀 수 없습니다."
OLD=$(hostname -s)
CHANGED=0

if [ "$OLD" != "$NEW" ]; then
  CHANGED=1
  BACKUP=/root/pve-rename-$(date +%Y%m%d-%H%M%S)
  log "백업: $BACKUP"
  mkdir -p "$BACKUP"
  tar -C / -czf "$BACKUP/etc-pve.tgz" etc/pve
  cp -a /var/lib/pve-cluster/config.db "$BACKUP/"
  cp -a /etc/hosts /etc/hostname "$BACKUP/"

  log "호스트 이름: $OLD → $NEW.$DOMAIN"
  IP=$(awk -v h="$OLD" '$1 !~ /^127\./ { for (i = 2; i <= NF; i++) if ($i == h) { print $1; exit } }' /etc/hosts)
  [ -n "$IP" ] || die "/etc/hosts 에서 $OLD 의 주소를 찾지 못했습니다."
  hostnamectl set-hostname "$NEW"
  awk -v h="$OLD" -v ip="$IP" -v line="$IP $NEW.$DOMAIN $NEW" '
    { hit = 0; for (i = 2; i <= NF; i++) if ($i == h) hit = 1 }
    hit && $1 == ip { print line; next } { print }' "$BACKUP/hosts" > /etc/hosts
  if command -v postconf >/dev/null; then
    postconf -e "myhostname=$NEW.$DOMAIN"
    systemctl reload postfix || true
  fi

  log "pve-cluster 재시작(새 이름으로 /etc/pve 다시 올림)"
  systemctl restart pve-cluster
  # 새 노드 폴더는 저절로 생기지 않습니다. /etc/pve 가 다시 올라오면 직접 만들고, 아래에서 게스트 설정을 옮깁니다
  for _ in $(seq 30); do mkdir -p "/etc/pve/nodes/$NEW" 2>/dev/null && break; sleep 1; done
  [ -d "/etc/pve/nodes/$NEW" ] || die "/etc/pve/nodes/$NEW 를 만들지 못했습니다."
fi

log "게스트 설정 옮기기 → /etc/pve/nodes/$NEW"
for dir in /etc/pve/nodes/*/; do
  node=$(basename "$dir")
  [ "$node" = "$NEW" ] && continue
  for sub in qemu-server lxc; do
    mkdir -p "/etc/pve/nodes/$NEW/$sub"
    for f in "$dir$sub"/*.conf; do
      [ -e "$f" ] || continue
      [ -e "/etc/pve/nodes/$NEW/$sub/$(basename "$f")" ] && die "$NEW 에 이미 $(basename "$f") 가 있습니다."
      mv "$f" "/etc/pve/nodes/$NEW/$sub/"
      echo "    $node/$sub/$(basename "$f")"
      CHANGED=1
    done
  done
  for f in host.fw config; do
    if [ -e "$dir$f" ] && [ ! -e "/etc/pve/nodes/$NEW/$f" ]; then
      mv "$dir$f" "/etc/pve/nodes/$NEW/$f"; echo "    $node/$f"; CHANGED=1
    fi
  done
  # 그래프 이력(RRD)은 노드 이름으로 저장되므로 새 이름으로 복사합니다
  for rrd in /var/lib/rrdcached/db/pve-node-* /var/lib/rrdcached/db/pve-storage-* /var/lib/rrdcached/db/pve2-node /var/lib/rrdcached/db/pve2-storage; do
    if [ -e "$rrd/$node" ] && [ ! -e "$rrd/$NEW" ]; then
      cp -a "$rrd/$node" "$rrd/$NEW"; echo "    그래프 이력 $rrd/$node"; CHANGED=1
    fi
  done
  echo "    옛 폴더 /etc/pve/nodes/$node 가 남아 있습니다. 확인 뒤 rm -r 로 지웁니다."
done

if [ "$CHANGED" = 1 ]; then
  log "인증서·서비스 갱신"
  pvecm updatecerts --force
  systemctl restart pvedaemon pveproxy pvestatd pvescheduler pve-firewall pve-ha-lrm pve-ha-crm
  echo "RENAME_CHANGED"
else
  log "이미 $NEW 입니다. 바꿀 것이 없습니다."
fi

log "결과"
pvesh get /nodes --output-format text --noborder
qm list
pct list
