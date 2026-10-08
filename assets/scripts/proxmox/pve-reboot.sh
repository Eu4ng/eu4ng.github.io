#!/usr/bin/env bash
#
# 이 Proxmox 노드를 재부팅하거나 끕니다(--poweroff). 게스트를 먼저 내리고, 내려가지 않는 게스트나 커널에서 굳은(D 상태)
# 작업이 있으면 일반 재부팅·종료 대신 sysrq 로 즉시 재부팅하거나 끕니다.
#
# 왜: 일반 reboot 는 게스트 종료 → 서비스 정지 → 커널의 장치 정리 순서로 가는데, 멈춘 GPU 드라이버(amdgpu 교착)를 쥔
# 프로세스가 있으면 그 CT 는 끝내 내려가지 않고(pve-guests 180초, lxc.service 90초 시간 초과) 마지막 장치 정리에서 커널이
# 굳어 전원이 켜진 채 응답하지 않습니다. BMC 가 없고 watchdog 이 softdog 뿐인 서버는
# 스스로 리셋되지 않아 전원을 뽑아야 합니다. sysrq b 는 장치 정리를 건너뛰고 바로 재부팅합니다. 게스트는 이미 내렸으므로 잃는 것은
# 내려가지 않던 게스트뿐입니다. 메모리 증설 같은 하드웨어 작업으로 끌 때(--poweroff)도 같은 이유로 sysrq o 를 씁니다.
# sysrq o 는 커널이 전원 끄기를 지원할 때만 실제로 끕니다. 꺼졌는지는 접속 단절이 아니라 전력(스마트 플러그)이나 현장에서
# 확인합니다.
#
# 사용법(호스트에서 root). 실행 중에 이 호스트의 게스트(ssh 를 건너온 CT 포함)가 내려가 세션이 끊기므로 systemd-run 으로 띄웁니다:
#   systemd-run --unit pve-reboot --collect /usr/local/sbin/pve-reboot.sh [옵션]; journalctl -fu pve-reboot
# 옵션:
#   --dry-run          무엇을 내리고 어느 경로로 재부팅(종료)할지와 sysrq 를 쓸 수 있는지만 출력
#   --poweroff         재부팅 대신 전원을 끔(하드웨어 작업용). BMC 가 없으면 다시 켜는 것은 사람이 함
#   --force-sysrq      판정과 무관하게 sysrq 로 재부팅(종료)
#   --skip <vmid>      내리지 않을 게스트(여러 번 줄 수 있음). 그 게스트는 재부팅과 함께 끊깁니다
#   --vm-timeout <초>  VM 종료 대기(기본 180)
#   --ct-timeout <초>  CT 종료 대기(기본 60)
# 종료 코드: 0 재부팅·종료 시작(또는 dry-run), 1 쿼럼 없음 등으로 중단, 2 인자 오류
set -uo pipefail

DRY_RUN=0 FORCE_SYSRQ=0 POWEROFF=0 VM_TIMEOUT=180 CT_TIMEOUT=60
declare -A SKIP=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force-sysrq) FORCE_SYSRQ=1 ;;
    --poweroff) POWEROFF=1 ;;
    --skip) SKIP[$2]=1; shift ;;
    --vm-timeout) VM_TIMEOUT=$2; shift ;;
    --ct-timeout) CT_TIMEOUT=$2; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[$(date +%T)] $*"; }
run() { if [ "$DRY_RUN" = 1 ]; then log "(dry-run) $*"; else "$@"; fi; }

# 1) 쿼럼. 클러스터 노드인데 과반이 없으면 다른 노드가 이 노드의 재부팅을 버티지 못한다
if [ -e /etc/pve/corosync.conf ]; then
  if ! pvecm status 2>/dev/null | grep -qE '^Quorate:\s+Yes'; then
    log "클러스터 쿼럼이 없어 중단합니다(pvecm status 확인)"; exit 1
  fi
  log "쿼럼 정상"
fi

# 2) 이 노드에서 켜져 있는 게스트를 동시에 내린다
running_vms() { qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}'; }
running_cts() { pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}'; }
pids=()
for id in $(running_vms); do
  [ -n "${SKIP[$id]:-}" ] && { log "VM $id 건너뜀(--skip)"; continue; }
  log "VM $id 종료(최대 ${VM_TIMEOUT}초)"
  if [ "$DRY_RUN" = 0 ]; then qm shutdown "$id" --timeout "$VM_TIMEOUT" >/dev/null 2>&1 & pids+=($!); fi
done
for id in $(running_cts); do
  [ -n "${SKIP[$id]:-}" ] && { log "CT $id 건너뜀(--skip)"; continue; }
  log "CT $id 종료(최대 ${CT_TIMEOUT}초)"
  if [ "$DRY_RUN" = 0 ]; then pct shutdown "$id" --timeout "$CT_TIMEOUT" >/dev/null 2>&1 & pids+=($!); fi
done
[ ${#pids[@]} -gt 0 ] && wait "${pids[@]}"

# 3) 멈춤 판정: 아직 켜진 게스트(--skip 제외), 또는 10초 간격 두 번 모두 D 상태인 작업
hung=()
if [ "$DRY_RUN" = 0 ]; then
  for id in $(running_vms) $(running_cts); do [ -z "${SKIP[$id]:-}" ] && hung+=("게스트 $id 가 내려가지 않음"); done
fi
d_state() { ps -eo pid=,stat=,comm= | awk '$2 ~ /^D/ {print $1":"$3}' | sort; }
first=$(d_state); sleep 10; second=$(d_state)
for p in $(comm -12 <(echo "$first") <(echo "$second")); do
  pid=${p%%:*}
  where=$(grep -m1 -oE 'amdgpu[a-z_]*|drm_[a-z_]+' "/proc/$pid/stack" 2>/dev/null || true)
  hung+=("D 상태 작업 $p${where:+ ($where)}")
done

# 4) 재부팅 또는 종료
if [ "$POWEROFF" = 1 ]; then ACT="종료" KEY=o UNIT=poweroff; else ACT="재부팅" KEY=b UNIT=reboot; fi
log "동작: $ACT"
if [ "$DRY_RUN" = 1 ]; then
  # 스크립트가 쓰는 경로는 /proc/sysrq-trigger 다. root 가 이 파일에 쓰는 호출은 kernel.sysrq 값과 무관하게 동작한다
  # (kernel.sysrq 는 키보드 호출에만 적용). 그래서 판정은 이 파일의 존재와 쓰기 권한으로 하고, kernel.sysrq 는 참고로만 낸다
  if [ -e /proc/sysrq-trigger ] && [ -w /proc/sysrq-trigger ]; then sysrq_ok="사용 가능"; else sysrq_ok="사용 불가"; fi
  log "sysrq: /proc/sysrq-trigger $sysrq_ok (참고: kernel.sysrq=$(cat /proc/sys/kernel/sysrq 2>/dev/null || echo '?'))"
fi
if [ "$FORCE_SYSRQ" = 1 ] || [ ${#hung[@]} -gt 0 ]; then
  for h in "${hung[@]}"; do log "멈춤: $h"; done
  log "일반 방식은 장치 정리에서 굳을 수 있어 sysrq 로 즉시 ${ACT}합니다"
  run sysctl -qw kernel.sysrq=1
  run sync
  if [ "$DRY_RUN" = 0 ]; then
    echo s > /proc/sysrq-trigger; sleep 3      # 디스크에 쓰기
    echo u > /proc/sysrq-trigger; sleep 3      # 파일시스템 읽기 전용으로
    echo $KEY > /proc/sysrq-trigger            # 즉시 재부팅(b) 또는 전원 끄기(o)
  else
    log "(dry-run) echo s/u/$KEY > /proc/sysrq-trigger"
  fi
else
  log "멈춘 것이 없어 일반 ${ACT}합니다"
  run systemctl $UNIT
fi
