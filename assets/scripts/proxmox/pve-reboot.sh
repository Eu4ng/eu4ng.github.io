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
# 게스트는 두 차례로 내립니다. 먼저 나머지 게스트를 모두 내리고, 그다음에 NAS(헤놀로지) 같은 마지막 게스트를 내립니다.
# NAS 를 먼저 내리면 그 NFS 저장소(nas)에 디스크를 둔 VM 이 I/O 에서 굳습니다. 마지막 게스트는 --last 또는
# /etc/default/pve-reboot 의 LAST_VMIDS(pve-cluster.yml 이 group_vars 의 xpenology.vmid 로 배포)로 정합니다.
# pve03 을 재부팅하면 NAS 가 멈추므로 다른 노드에서 nas 저장소를 쓰는 VM(docker VM 206 등)도 그동안 디스크 I/O 가 멈춥니다.
# pve03 의 worker-3 은 이 스크립트가 NAS 보다 먼저 내립니다. 다른 노드의 nas VM 은 미리 내리거나 멈춤을 감수합니다.
#
# 게스트를 내리기 전에 이 호스트에 있는 쿠버네티스 노드를 drain 합니다. 그 노드에 Patroni 주 DB(namespace timescaledb,
# 라벨 role=primary)가 있으면 먼저 다른 멤버로 switchover 합니다. drain 은 다른 호스트의 control plane 에 ssh 해서 하고
# (pve-node-rebuild.sh 와 같은 방식), 실패하면 cordon 을 풀고 중단합니다. drain 한 노드는 /var/lib/pve-reboot/drained 에
# 적고, 부팅 뒤 pve-k8s-return.service(이 스크립트의 --return)가 노드가 Ready 가 되면 uncordon 하고 CoreDNS 수를 다시
# 맞춥니다. 어느 노드를 drain 하고 어느 control plane 에 붙을지는 /etc/default/pve-reboot 의 K8S_DRAIN·K8S_KUBECTL 입니다.
# Proxmox HA 게스트는 끄지 않고 다른 노드로 옮깁니다(ha-manager crm-command migrate). 대상은 메모리가 가장 많이 남은
# 온라인 노드입니다. maintenance 모드는 풀 때 원래 노드로 되돌아가므로 쓰지 않습니다. 모두 옮겨지지 않으면(300초) 중단합니다.
#
# 사용법(호스트에서 root). 실행 중에 이 호스트의 게스트(ssh 를 건너온 CT 포함)가 내려가 세션이 끊기므로 systemd-run 으로 띄웁니다:
#   systemd-run --unit pve-reboot --collect /usr/local/sbin/pve-reboot.sh [옵션]; journalctl -fu pve-reboot
# 옵션:
#   --dry-run          무엇을 내리고 어느 경로로 재부팅(종료)할지와 sysrq 를 쓸 수 있는지만 출력
#   --poweroff         재부팅 대신 전원을 끔(하드웨어 작업용). BMC 가 없으면 다시 켜는 것은 사람이 함
#   --force-sysrq      판정과 무관하게 sysrq 로 재부팅(종료)
#   --skip <vmid>      내리지 않을 게스트(여러 번 줄 수 있음). 그 게스트는 재부팅과 함께 끊깁니다
#   --last <vmid>      다른 게스트를 모두 내린 뒤 마지막에 내릴 게스트(여러 번 줄 수 있음, LAST_VMIDS 에 더함)
#   --vm-timeout <초>  VM 종료 대기(기본 180)
#   --ct-timeout <초>  CT 종료 대기(기본 60)
#   --no-drain         drain·switchover·HA 이전을 하지 않음(장애 시험용: 노드가 갑자기 사라진 것과 같게)
#   --return           부팅 뒤 할 일만 함: drained 표식의 노드가 Ready 가 되면 uncordon, CoreDNS 수 맞추기(pve-k8s-return.service)
# 종료 코드: 0 재부팅·종료 시작(또는 dry-run, --return 완료), 1 쿼럼 없음·drain 실패 등으로 중단, 2 인자 오류
set -uo pipefail

DRY_RUN=0 FORCE_SYSRQ=0 POWEROFF=0 VM_TIMEOUT=180 CT_TIMEOUT=60 DRAIN=1 RETURN=0
DRAIN_TIMEOUT=300 HA_TIMEOUT=300 RETURN_TIMEOUT=1800 MARK=/var/lib/pve-reboot/drained
declare -A SKIP=() LAST=() HA_ID=()
# 노드별 기본값(pve-cluster.yml 이 배포). LAST_VMIDS="205" 처럼 공백으로 나눕니다.
# K8S_DRAIN="hub:k8s-hub-cp-1,k8s-hub-worker-1 daejeon:…"(이 호스트의 노드), K8S_KUBECTL="hub:192.168.0.122,192.168.0.125 …"
# (다른 호스트의 control plane, 앞에서부터 붙는 곳을 씀)
K8S_DRAIN=${K8S_DRAIN:-} K8S_KUBECTL=${K8S_KUBECTL:-} PATRONI_NS=${PATRONI_NS:-timescaledb}
[ -r /etc/default/pve-reboot ] && . /etc/default/pve-reboot
for id in ${LAST_VMIDS:-}; do LAST[$id]=1; done
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force-sysrq) FORCE_SYSRQ=1 ;;
    --poweroff) POWEROFF=1 ;;
    --skip) SKIP[$2]=1; shift ;;
    --last) LAST[$2]=1; shift ;;
    --vm-timeout) VM_TIMEOUT=$2; shift ;;
    --ct-timeout) CT_TIMEOUT=$2; shift ;;
    --no-drain) DRAIN=0 ;;
    --return) RETURN=1 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[$(date +%T)] $*"; }
run() { if [ "$DRY_RUN" = 1 ]; then log "(dry-run) $*"; else "$@"; fi; }

# ---- 쿠버네티스: 클러스터마다 다른 호스트의 control plane 에 ssh 해서 kubectl ----
SSH=(ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)   # -n: 읽는 중인 표식 파일을 ssh 가 먹지 않게
declare -A KC_HOST=()
kc_host() {   # $1 클러스터 → KC_HOST[$1] 에 붙는 control plane IP(앞에서부터, 처음 찾은 것을 기억)
  local c=$1 e ip
  [ -n "${KC_HOST[$c]:-}" ] && return 0
  for e in $K8S_KUBECTL; do
    [ "${e%%:*}" = "$c" ] || continue
    for ip in $(tr , ' ' <<< "${e#*:}"); do
      if "${SSH[@]}" "ubuntu@$ip" true 2>/dev/null; then KC_HOST[$c]=$ip; return 0; fi
    done
  done
  return 1
}
kc() {   # $1 클러스터, 나머지 kubectl 인자
  local c=$1; shift
  kc_host "$c" || { log "[$c] 붙을 control plane 이 없음(K8S_KUBECTL=$K8S_KUBECTL)"; return 1; }
  "${SSH[@]}" "ubuntu@${KC_HOST[$c]}" "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf $(printf '%q ' "$@")"
}
# 이 호스트의 노드를 "클러스터 노드" 줄로
drain_targets() { local e n; for e in $K8S_DRAIN; do for n in $(tr , ' ' <<< "${e#*:}"); do echo "${e%%:*} $n"; done; done; }
# 받을 수 있는(cordon 안 된) 노드 수만큼 CoreDNS 를 둡니다(k8s-cluster.yml --tags dns 와 같은 결과. 노드마다 하나라 cordon 한
# 노드 몫이 남으면 Pending 으로 남음)
coredns_fit() {
  local c=$1 n
  n=$(kc "$c" get nodes -o 'jsonpath={range .items[*]}{.spec.unschedulable}{"\n"}{end}' | grep -vc true) || return 1
  # dry-run 은 cordon 하지 않으므로 drain 했을 때의 수로 보여 줌
  [ "$DRY_RUN" = 1 ] && [ "$RETURN" = 0 ] && n=$((n - $(drain_targets | awk -v c="$c" '$1==c' | wc -l)))
  log "[$c] CoreDNS replicas → $n"
  run kc "$c" -n kube-system scale deployment/coredns --replicas="$n" >/dev/null
}

# ---- 부팅 뒤(--return): 표식의 노드가 Ready 가 되면 uncordon ----
if [ "$RETURN" = 1 ]; then
  [ -s "$MARK" ] || { log "drain 표식이 없어 할 일이 없습니다"; exit 0; }
  deadline=$((SECONDS + RETURN_TIMEOUT)) left=1
  while [ "$left" = 1 ] && [ $SECONDS -lt $deadline ]; do
    left=0
    for c in $(awk '{print $1}' "$MARK" | sort -u); do kc_host "$c" || true; done   # 붙을 곳을 여기서 기억(아래는 하위 셸)
    while read -r c n; do
      [ -n "$n" ] || continue
      ready=$(kc "$c" get node "$n" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      if [ "$ready" = True ]; then
        log "[$c] $n Ready → uncordon"
        if run kc "$c" uncordon "$n" >/dev/null; then
          [ "$DRY_RUN" = 0 ] && sed -i "/^$c $n\$/d" "$MARK"
          echo "$c" >> "$MARK.dns"
        else left=1; fi
      else left=1; fi
    done < <(cat "$MARK")
    [ "$left" = 1 ] && sleep 15
  done
  for c in $(sort -u "$MARK.dns" 2>/dev/null); do coredns_fit "$c" || left=1; done
  rm -f "$MARK.dns"
  if [ "$left" = 1 ]; then log "Ready 가 되지 않았거나 uncordon 하지 못한 노드: $(tr '\n' ' ' < "$MARK")"; exit 1; fi
  log "모든 노드 uncordon 완료"; exit 0
fi

# 1) 쿼럼. 클러스터 노드인데 과반이 없으면 다른 노드가 이 노드의 재부팅을 버티지 못한다
if [ -e /etc/pve/corosync.conf ]; then
  if ! pvecm status 2>/dev/null | grep -qE '^Quorate:\s+Yes'; then
    log "클러스터 쿼럼이 없어 중단합니다(pvecm status 확인)"; exit 1
  fi
  log "쿼럼 정상"
fi

# 2) 쿠버네티스 노드 drain(--no-drain 이 아니면). 주 DB 가 이 호스트의 노드에 있으면 먼저 넘긴다
if [ "$DRAIN" = 1 ] && [ -n "$K8S_DRAIN" ]; then
  mapfile -t targets < <(drain_targets)
  declare -A MINE=()
  for t in "${targets[@]}"; do MINE[$t]=1; done
  for c in $(drain_targets | awk '{print $1}' | sort -u); do
    kc_host "$c" || { log "[$c] 붙을 control plane 이 없어 중단합니다(--no-drain 으로 건너뛸 수 있음)"; exit 1; }
    # Patroni: role=primary 파드의 노드가 이번에 drain 할 노드면 switchover(후보는 drain 하지 않는 멤버)
    pods=$(kc "$c" -n "$PATRONI_NS" get pods -l role -o 'jsonpath={range .items[*]}{.metadata.name} {.spec.nodeName} {.metadata.labels.role}{"\n"}{end}' 2>/dev/null)
    leader=$(awk '$3=="primary"{print $1" "$2}' <<< "$pods")
    if [ -n "$leader" ] && [ -n "${MINE[$c ${leader#* }]:-}" ]; then
      cand=$(awk -v n="${leader#* }" '$3!="primary" && $2!=n {print $1}' <<< "$pods" | while read -r p; do
        node=$(awk -v p="$p" '$1==p{print $2}' <<< "$pods"); [ -z "${MINE[$c $node]:-}" ] && echo "$p"; done | head -1)
      [ -n "$cand" ] || { log "[$c] 주 DB ${leader% *} 를 넘길 멤버가 없어 중단합니다"; exit 1; }
      log "[$c] 주 DB ${leader% *}(${leader#* }) → $cand switchover"
      if [ "$DRY_RUN" = 0 ]; then
        kc "$c" -n "$PATRONI_NS" exec "${leader% *}" -- patronictl -c /etc/patroni/patroni.yml switchover \
          --leader "${leader% *}" --candidate "$cand" --force || { log "[$c] switchover 실패, 중단합니다"; exit 1; }
        ok=0
        for _ in $(seq 24); do
          [ "$(kc "$c" -n "$PATRONI_NS" get pod "$cand" -o 'jsonpath={.metadata.labels.role}')" = primary ] && { ok=1; break; }
          sleep 5
        done
        [ "$ok" = 1 ] || { log "[$c] 120초 안에 $cand 가 주 DB 가 되지 않아 중단합니다"; exit 1; }
        log "[$c] 주 DB: $cand"
      fi
    fi
  done
  [ "$DRY_RUN" = 0 ] && mkdir -p "$(dirname "$MARK")"
  for t in "${targets[@]}"; do
    c=${t% *} n=${t#* }
    log "[$c] $n drain(최대 ${DRAIN_TIMEOUT}초)"
    if [ "$DRY_RUN" = 1 ]; then
      # dry-run 은 볼륨을 떼지 않으므로 Longhorn instance-manager 의 PDB 가 끝까지 막습니다. 실제 drain 에서는 다른 파드가
      # 빠져 볼륨이 떨어지면 Longhorn 이 PDB 를 풉니다(그 노드에 마지막 복제본이 있으면 계속 막아 drain 이 실패하고 중단)
      kc "$c" drain "$n" --ignore-daemonsets --delete-emptydir-data --dry-run=server --timeout=15s 2>&1 \
        | grep -v 'will retry after' | sed 's/^/    /'
      continue
    fi
    grep -qx "$t" "$MARK" 2>/dev/null || echo "$t" >> "$MARK"   # cordon 전에 적어 둠(중간에 끊겨도 부팅 뒤 uncordon)
    if ! kc "$c" drain "$n" --ignore-daemonsets --delete-emptydir-data --timeout="${DRAIN_TIMEOUT}s" 2>&1 | sed 's/^/    /'; then
      log "[$c] $n drain 실패. 이번에 cordon 한 노드를 되돌리고 중단합니다"
      while read -r c2 n2; do kc "$c2" uncordon "$n2" >/dev/null && sed -i "/^$c2 $n2\$/d" "$MARK"; done < <(cat "$MARK")
      exit 1
    fi
  done
  for c in $(drain_targets | awk '{print $1}' | sort -u); do coredns_fit "$c" || log "[$c] CoreDNS 수를 맞추지 못함(계속)"; done
fi

# 3) Proxmox HA 게스트는 다른 노드로 옮긴다(--no-drain 이 아니면). 이 노드의 게스트를 내리는 루프는 HA 게스트를 건너뛴다
SELF=$(hostname -s)
for sid in $(ha-manager config 2>/dev/null | awk '/^(vm|ct):/{print $1 $2}'); do HA_ID[${sid#*:}]=1; done
# 이 노드에서 켜져 있는(started) HA 서비스. 멈춰 둔 HA 서비스는 옮기지 않음(started 가 되지 않아 기다림이 끝나지 않음)
ha_here() { ha-manager status 2>/dev/null | awk -v n="$SELF" '$1=="service" && $3=="("n"," && $4=="started)" {print $2}'; }
if [ "$DRAIN" = 1 ] && [ ${#HA_ID[@]} -gt 0 ]; then
  sids=$(ha_here)
  if [ -n "$sids" ]; then
    target=$(pvesh get /cluster/resources --type node --output-format json | jq -r --arg s "$SELF" \
      '[.[] | select(.status=="online" and .node!=$s)] | max_by(.maxmem - .mem) | .node // empty')
    [ -n "$target" ] || { log "HA 게스트를 받을 노드가 없어 중단합니다"; exit 1; }
    for sid in $sids; do log "HA $sid → $target 이전"; run ha-manager crm-command migrate "$sid" "$target"; done
    if [ "$DRY_RUN" = 0 ]; then
      ok=0
      for _ in $(seq $((HA_TIMEOUT / 5))); do
        st=$(ha-manager status 2>/dev/null)
        moved=1
        for sid in $sids; do grep -qE "^service $sid \($target, started\)" <<< "$st" || moved=0; done
        [ "$moved" = 1 ] && [ -z "$(ha_here)" ] && { ok=1; break; }
        sleep 5
      done
      [ "$ok" = 1 ] || { log "${HA_TIMEOUT}초 안에 HA 게스트가 모두 옮겨지지 않아 중단합니다(ha-manager status 확인)"; exit 1; }
      log "HA 게스트 이전 완료"
    fi
  fi
fi

# 4) 이 노드에서 켜져 있는 게스트를 내린다. 1차는 LAST 가 아닌 게스트를 동시에, 2차는 LAST 게스트를
running_vms() { qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}'; }
running_cts() { pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}'; }
shutdown_phase() {   # $1: first(LAST 제외) | last(LAST 만)
  local id pids=()
  for id in $(running_vms); do
    if [ "$1" = first ]; then [ -n "${LAST[$id]:-}" ] && continue; else [ -z "${LAST[$id]:-}" ] && continue; fi
    [ -n "${SKIP[$id]:-}" ] && { log "VM $id 건너뜀(--skip)"; continue; }
    [ -n "${HA_ID[$id]:-}" ] && { log "VM $id 건너뜀(HA 게스트)"; continue; }
    log "VM $id 종료(최대 ${VM_TIMEOUT}초)"
    if [ "$DRY_RUN" = 0 ]; then qm shutdown "$id" --timeout "$VM_TIMEOUT" >/dev/null 2>&1 & pids+=($!); fi
  done
  for id in $(running_cts); do
    if [ "$1" = first ]; then [ -n "${LAST[$id]:-}" ] && continue; else [ -z "${LAST[$id]:-}" ] && continue; fi
    [ -n "${SKIP[$id]:-}" ] && { log "CT $id 건너뜀(--skip)"; continue; }
    [ -n "${HA_ID[$id]:-}" ] && { log "CT $id 건너뜀(HA 게스트)"; continue; }
    log "CT $id 종료(최대 ${CT_TIMEOUT}초)"
    if [ "$DRY_RUN" = 0 ]; then pct shutdown "$id" --timeout "$CT_TIMEOUT" >/dev/null 2>&1 & pids+=($!); fi
  done
  [ ${#pids[@]} -gt 0 ] && wait "${pids[@]}"
  return 0
}
last_ids="${!LAST[*]}"
log "1차: 마지막 게스트(${last_ids:-없음})를 뺀 게스트 종료"
shutdown_phase first
if [ ${#LAST[@]} -gt 0 ]; then
  log "2차: 마지막 게스트 종료"
  shutdown_phase last
fi

# 5) 멈춤 판정: 아직 켜진 게스트(--skip 제외), 또는 10초 간격 두 번 모두 D 상태인 작업
hung=()
if [ "$DRY_RUN" = 0 ]; then
  for id in $(running_vms) $(running_cts); do [ -z "${SKIP[$id]:-}${HA_ID[$id]:-}" ] && hung+=("게스트 $id 가 내려가지 않음"); done
fi
d_state() { ps -eo pid=,stat=,comm= | awk '$2 ~ /^D/ {print $1":"$3}' | sort; }
first=$(d_state); sleep 10; second=$(d_state)
for p in $(comm -12 <(echo "$first") <(echo "$second")); do
  pid=${p%%:*}
  where=$(grep -m1 -oE 'amdgpu[a-z_]*|drm_[a-z_]+' "/proc/$pid/stack" 2>/dev/null || true)
  hung+=("D 상태 작업 $p${where:+ ($where)}")
done

# 6) 재부팅 또는 종료
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
