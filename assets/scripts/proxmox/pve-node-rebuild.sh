#!/usr/bin/env bash
#
# 디스크를 바꿔(또는 죽어서) 다시 설치한 Proxmox 노드를 원래 이름·IP·게스트로 되돌립니다. 남은 Proxmox 노드에서 root 로 실행합니다.
# 새 노드에는 Proxmox 설치와 pve-bootstrap.sh(ssh 키 등록)만 해 두면 됩니다. 범위는 메인이 아닌 노드(pve02 류)입니다.
#
# 사용법(남은 노드, root):
#   /root/proxmox-ansible/scripts/pve-node-rebuild.sh <새 노드 IP> <노드 이름> --reason disk-replaced [--yes]
#   /root/proxmox-ansible/scripts/pve-node-rebuild.sh <새 노드 IP> <노드 이름> --reason failed --fenced [--yes]
#   ... --dry-run     점검과 지울 대상 목록만 보여 주고 끝냅니다(아무것도 바꾸지 않음)
#
# 격리 근거(--reason)가 없으면 시작하지 않습니다. disk-replaced 는 옛 OS 디스크가 빠졌으므로 그 자체가 격리이고, failed(돌발 장애)는
# 옛 기계의 전원을 끊거나 디스크를 뺀 뒤 --fenced 를 줍니다. --yes 는 노드 이름 재입력만 생략하고 --fenced 를 대신하지 않습니다.
#
# 순서: 점검(preflight) → 신원 맞추기(호스트 이름·IP 를 inventory 값으로) → 옛 기록 정리(playbooks/node-rebuild.yml) →
#   기존 플레이북(pve-cluster → vm-template → lan-dns → ollama → k8s-cluster hub·daejeon → 합류 뒤 마무리 → host-metrics → timezone) → 검증 요약.
# 점검을 통과하면 systemd 유닛(pve-node-rebuild-<노드>)으로 다시 떠서 ssh 가 끊겨도 계속 돕니다. 로그는 /root/pve-rebuild/<시각>.log.
# 상태 파일 /root/pve-rebuild/<노드>.state 에 새 기계(ssh 호스트 키 지문, machine-id)와 단계별 완료를 적으므로, 실패하면 같은 명령으로
# 이어 갑니다(같은 새 기계일 때만). 정리 단계는 처음 기록한 ID 와 같은 것만 지웁니다(node-rebuild.yml 머리말).
# 새 기계의 ssh 호스트 키: 점검 때 ssh-keyscan 으로 받은 ed25519 지문을 보여 주고, pve-bootstrap.sh 가 콘솔에 보여 준 값과 같은지
# 묻습니다(--yes 로도 건너뛰지 않음). 같으면 그 키를 상태 폴더의 전용 known_hosts(<노드>.known_hosts)에 별칭 <노드>-new 로 고정하고,
# 새 기계로 가는 모든 ssh·scp·ansible 접속이 그 키로만 검증합니다(<노드>-ssh.yml 을 추가 inventory 로 넘김). 새 IP 가 옛 IP 와 같아
# /root/.ssh/known_hosts·/etc/pve/priv/known_hosts 의 옛 키와 부딪혀도 막히지 않고, IP 를 inventory 값으로 바꾼 뒤에도 같은 키로 검증됩니다.
# 시험용 고장 주입: REBUILD_FAIL_AFTER=<단계 이름> 이면 그 단계를 마친 뒤 멈춥니다.

# jq 식과 원격 명령은 일부러 작은따옴표로 넘깁니다(여기서 풀지 않음)
# shellcheck disable=SC2016

set -euo pipefail

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
STATE_DIR=/root/pve-rebuild
SSH_COMMON=(-o BatchMode=yes -o ConnectTimeout=10)
SSH=(ssh "${SSH_COMMON[@]}" -o StrictHostKeyChecking=accept-new)   # 새 기계가 아닌 곳(control plane VM, 옛 주소)
export HOME=/root ANSIBLE_DEPRECATION_WARNINGS=False ANSIBLE_CONFIG="$REPO/ansible.cfg"   # systemd 유닛 안에는 HOME 이 없음
PATH="$REPO/.venv/bin:$PATH"

log() { echo "==> $(date +%H:%M:%S) $*"; }
warn() { echo "[경고] $*"; }
die() { echo "[중단] $*" >&2; exit 1; }

usage() { sed -n '6,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

NEW_IP=""; NODE=""; REASON=""; FENCED=0; YES=0; DRY=0; IN_UNIT=0; LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reason) REASON=${2:-}; shift 2 ;;
    --fenced) FENCED=1; shift ;;
    --yes) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --in-unit) IN_UNIT=1; LOG=${2:-}; shift 2 ;;
    -h|--help) usage ;;
    -*) die "모르는 옵션: $1" ;;
    *) if [ -z "$NEW_IP" ]; then NEW_IP=$1; elif [ -z "$NODE" ]; then NODE=$1; else die "인자가 너무 많습니다: $1"; fi; shift ;;
  esac
done
[ -n "$NEW_IP" ] && [ -n "$NODE" ] || usage
[ "$(id -u)" = 0 ] || die "root 로 실행합니다."
command -v ansible-playbook >/dev/null || die "$REPO/.venv 에 ansible 이 없습니다. 작업 PC 에서 playbooks/pve-controller.yml 을 먼저 실행합니다."
command -v jq >/dev/null || die "jq 가 없습니다(pve-controller.yml 이 설치)."

SELF=$(hostname -s)
STATE=$STATE_DIR/$NODE.state
mkdir -p "$STATE_DIR"
# 새 기계 전용: 고정한 키 하나만 믿습니다. ssh 는 같은 옵션의 첫 값을 쓰므로 SSH 배열(accept-new)과 섞지 않습니다
NEW_KH=$STATE_DIR/$NODE.known_hosts
NEW_ALIAS=$NODE-new
new_opts() {
  NEW_OPTS=("${SSH_COMMON[@]}" -o UserKnownHostsFile="$NEW_KH" -o GlobalKnownHostsFile=/dev/null -o HostKeyAlias="$NEW_ALIAS"
    -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519)
  SSH_NEW=(ssh "${NEW_OPTS[@]}")
}
new_opts
NEW_INV=$STATE_DIR/$NODE-ssh.yml   # ansible 이 새 기계에 붙을 때 같은 키를 쓰게 하는 추가 inventory(대상 노드만)
INV=(-i inventory.yml -i "$NEW_INV")
cd "$REPO"

# ---- 상태 파일 ----
st() { jq -r "$1" "$STATE"; }
st_set() {   # st_set <jq 식> [--arg 이름 값]...
  local expr=$1; shift
  jq "$@" "$expr" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
step_done() { [ -f "$STATE" ] && [ "$(st ".steps[\"$1\"] // false")" = true ]; }
mark_step() {
  st_set '.steps[$s] = true' --arg s "$1"
  log "단계 완료: $1"
  if [ "${REBUILD_FAIL_AFTER:-}" = "$1" ]; then die "고장 주입(REBUILD_FAIL_AFTER=$1)으로 멈춥니다. 같은 명령으로 이어 갑니다."; fi
}

# ---- inventory·group_vars 값 (Jinja 를 풀어 한 번에) ----
vars_json() {
  ansible localhost -o -m ansible.builtin.debug -a "msg={{ {
      'self_ip': hostvars['$SELF'].ansible_host | default(''),
      'node_ip': hostvars['$NODE'].ansible_host | default(''),
      'in_proxmox': '$NODE' in groups.proxmox,
      'self_in_proxmox': '$SELF' in groups.proxmox,
      'primary': groups.proxmox_primary,
      'domain': proxmox_domain,
      'guests': (lan_dns_instances + ollama_backends + scratch_vms + (k8s_clusters.values() | map(attribute='nodes') | flatten))
                | selectattr('pve', 'eq', '$NODE') | list,
      'template': hostvars['$NODE'].vm_template_vmid | default(vm_template_vmid),
      'clusters': dict(k8s_clusters.keys() | zip(k8s_clusters.values() | map(attribute='etcd_witness_peer', default=''))),
      'kubectl': dict(k8s_clusters.keys() | zip(k8s_clusters.values() | map(attribute='nodes') | map('rejectattr', 'pve', 'eq', '$NODE')
                 | map('selectattr', 'role', 'eq', 'control-plane') | map('map', attribute='ip') | map('first') | map('default', ''))),
      'target_cps': dict(k8s_clusters.keys() | zip(k8s_clusters.values() | map(attribute='nodes') | map('selectattr', 'pve', 'eq', '$NODE')
                 | map('selectattr', 'role', 'eq', 'control-plane') | map('map', attribute='ip') | map('list'))),
      'lan_dns_ips': lan_dns_instances | selectattr('pve', 'eq', '$NODE') | map(attribute='ip') | list,
      'ollama_ips': ollama_backends | selectattr('pve', 'eq', '$NODE') | map(attribute='ip') | list,
      'token_file': pve_controller_token_file,
    } | to_json }}" 2>/dev/null | sed 's/^[^{]*=> //' | jq -r .msg
}
V=$(vars_json) || die "inventory 를 읽지 못했습니다."
[ -n "$V" ] || die "inventory 를 읽지 못했습니다."
v() { jq -r "$1" <<< "$V"; }
INV_IP=$(v .node_ip)
SELF_IP=$(v .self_ip)
DOMAIN=$(v .domain)

# ---- 새 기계 식별 ----
fingerprint() {   # <IP> → ed25519 호스트 키 지문(없으면 빈 줄)
  ssh-keyscan -T 5 -t ed25519 "$1" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | head -1
}
host_key_blobs() { ssh-keyscan -T 5 "$1" 2>/dev/null | awk '!/^#/ {print $3}'; }
machine_id() { "${SSH_NEW[@]}" "root@$1" cat /etc/machine-id 2>/dev/null; }

# pin_new_key <IP> <파일>: <IP> 의 ed25519 키를 보여 주고(실제 실행이면 콘솔 지문과 같은지 물음) 별칭으로 <파일>에 고정합니다
pin_new_key() {
  local ip=$1 file=$2 blob fp answer
  blob=$(ssh-keyscan -T 5 -t ed25519 "$ip" 2>/dev/null | awk '!/^#/ && $2 == "ssh-ed25519" {print $3; exit}')
  [ -n "$blob" ] || die "새 기계 $ip 의 ed25519 호스트 키를 받지 못했습니다."
  fp=$(echo "$NEW_ALIAS ssh-ed25519 $blob" | ssh-keygen -lf - | awk '{print $2}')
  echo "    새 기계 $ip → 노드 $NODE, 호스트 키 지문(ed25519): $fp"
  echo "    전용 known_hosts: $file (별칭 $NEW_ALIAS)"
  if [ "$DRY" = 0 ]; then
    printf '새 노드 콘솔의 pve-bootstrap.sh 끝에 나온 지문(또는 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub)과 같으면 yes 입력: '
    read -r answer < /dev/tty
    [ "$answer" = yes ] || die "지문 확인을 받지 못해 멈춥니다."
  fi
  (umask 077; echo "$NEW_ALIAS ssh-ed25519 $blob" > "$file")
}

# write_new_inventory: 대상 노드에만 고정 키 접속 옵션을 붙이는 추가 inventory. ansible.cfg 의 host_key_checking=False 는
# StrictHostKeyChecking=no 를 앞에 붙여 아래 옵션을 덮으므로 이 호스트만 host_key_checking 을 켭니다. ControlPersist 소켓을 다시 쓰면
# 호스트 키를 다시 검증하지 않으므로, 고정 키 없이 같은 주소로 열린 접속(~/.ansible/cp)과 섞이지 않게 소켓 폴더를 따로 둡니다
write_new_inventory() {
  (umask 077; cat > "$NEW_INV" <<YML
# scripts/pve-node-rebuild.sh 가 만듭니다. $NODE 로 가는 ansible 접속을 고정한 호스트 키($NEW_KH)로만 검증합니다
all:
  hosts:
    $NODE:
      ansible_host_key_checking: true
      ansible_control_path_dir: $STATE_DIR/$NODE-cp
      ansible_ssh_common_args: "-o UserKnownHostsFile=$NEW_KH -o GlobalKnownHostsFile=/dev/null -o HostKeyAlias=$NEW_ALIAS -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519"
YML
  )
}
# 저장된 접속 주소 → inventory IP → 처음 IP 순으로 찾아, 지문과 machine-id 가 저장값과 같은 주소를 돌려줍니다
find_new_machine() {
  local fp mid a
  fp=$(st .new.fingerprint); mid=$(st .new.machine_id)
  for a in "$(st .address)" "$INV_IP" "$(st .new.ip)"; do
    [ -n "$a" ] || continue
    if [ "$(fingerprint "$a")" = "$fp" ] && [ "$(machine_id "$a")" = "$mid" ]; then echo "$a"; return 0; fi
  done
  return 1
}

# ---- 점검 (처음 한 번. 하나라도 걸리면 아무것도 바꾸지 않고 멈춤) ----
preflight() {
  log "점검: $NODE ← 새 기계 $NEW_IP (실행 노드 $SELF)"
  [ "$(v .in_proxmox)" = true ] || die "$NODE 는 inventory 의 proxmox 그룹에 없습니다."
  [ "$(v .self_in_proxmox)" = true ] || die "이 노드($SELF)가 inventory 의 proxmox 그룹에 없습니다."
  [ "$NODE" != "$SELF" ] || die "실행 중인 노드 자신($SELF)은 다시 만들 수 없습니다. 다른 Proxmox 노드에서 실행합니다."
  v '.primary[]' | grep -qx "$NODE" && die "$NODE 는 메인 노드라 이 절차의 범위 밖입니다(proxmox_api_host·NFS 원본 등이 메인 노드 고정)."
  case "$REASON" in
    disk-replaced) ;;
    failed) [ "$FENCED" = 1 ] || die "--reason failed 는 옛 기계의 전원 차단·디스크 분리를 한 뒤 --fenced 를 붙여야 진행합니다." ;;
    "") die "격리 근거가 없습니다. --reason disk-replaced(옛 OS 디스크를 뺐음) 또는 --reason failed --fenced 를 줍니다." ;;
    *) die "--reason 은 disk-replaced 또는 failed 입니다." ;;
  esac

  pvecm status | grep -qE '^Quorate:\s+Yes' \
    || die "클러스터가 과반(Quorate)이 아닙니다. $NODE 가 꺼져 표가 모자라면(QDevice 없음) 이 노드에서 'pvecm expected 1' 로 과반을 만든 뒤 다시 실행합니다."
  local online
  online=$(jq -r --arg n "$NODE" '.nodelist[$n].online // "none"' /etc/pve/.members)
  [ "$online" != 1 ] || die "$NODE 가 클러스터에서 online 입니다. 옛 노드가 살아 있으면 다시 만들지 않습니다."

  # 옛 노드 격리: 옛 링 주소가 응답하지 않거나, 응답하면 옛 호스트 키가 아니고 클러스터 설정이 없어야 합니다
  local old_ip old_keys new_keys k
  old_ip=$(awk -v n="$NODE" '/^\s*node\s*\{/ {nm=""; ip=""} /name:/ {nm=$2} /ring0_addr:/ {ip=$2} nm==n && ip!="" {print ip; exit}' /etc/pve/corosync.conf)
  old_ip=${old_ip:-$INV_IP}
  old_keys=$(awk '{print $3}' "/etc/pve/nodes/$NODE/ssh_known_hosts" 2>/dev/null || true)
  [ -n "$old_keys" ] || warn "옛 호스트 키(/etc/pve/nodes/$NODE/ssh_known_hosts)가 없어 키 비교를 건너뜁니다."
  if [ "$old_ip" != "$NEW_IP" ]; then
    local resp
    resp=$(host_key_blobs "$old_ip")
    if [ -n "$resp" ]; then
      for k in $resp; do grep -qxF "$k" <<< "$old_keys" && die "옛 주소 $old_ip 에서 옛 $NODE 의 호스트 키가 응답합니다. 옛 기계가 살아 있습니다(격리 안 됨)."; done
      "${SSH[@]}" "root@$old_ip" test ! -e /etc/pve/corosync.conf 2>/dev/null \
        || die "옛 주소 $old_ip 에 다른 기계가 응답하는데 클러스터 설정이 없는지 확인하지 못했습니다(격리 안 됨)."
    fi
  fi
  new_keys=$(host_key_blobs "$NEW_IP")
  [ -n "$new_keys" ] || die "새 기계 $NEW_IP 의 ssh 가 응답하지 않습니다."
  for k in $new_keys; do grep -qxF "$k" <<< "$old_keys" && die "$NEW_IP 의 호스트 키가 옛 $NODE 와 같습니다. 새로 설치한 기계가 아닙니다(격리 안 됨)."; done
  # 새 기계 호스트 키 고정. dry-run 은 임시 파일에 두고 끝에 지웁니다
  if [ "$DRY" = 1 ]; then NEW_KH=$(mktemp "$STATE_DIR/.dry-known_hosts.XXXXXX"); new_opts; trap 'rm -f "$NEW_KH"' EXIT; fi
  pin_new_key "$NEW_IP" "$NEW_KH"
  "${SSH_NEW[@]}" "root@$NEW_IP" true 2>/dev/null || die "root@$NEW_IP 에 고정한 호스트 키·ssh 키로 붙지 못합니다. 새 노드 콘솔에서 pve-bootstrap.sh 를 실행합니다."
  "${SSH_NEW[@]}" "root@$NEW_IP" 'test ! -e /etc/pve/corosync.conf' || die "$NEW_IP 는 이미 클러스터 설정(/etc/pve/corosync.conf)이 있습니다."
  "${SSH_NEW[@]}" "root@$NEW_IP" 'command -v pveversion >/dev/null' || die "$NEW_IP 는 Proxmox 가 아닙니다."
  [ -z "$("${SSH_NEW[@]}" "root@$NEW_IP" 'qm list; pct list' 2>/dev/null)" ] || die "$NEW_IP 에 게스트가 있습니다. 합류하려면 비어 있어야 합니다."
  if [ "$INV_IP" != "$NEW_IP" ] && [ "$old_ip" != "$INV_IP" ] && [ -n "$(host_key_blobs "$INV_IP")" ]; then
    die "inventory 주소 $INV_IP 를 다른 기계가 쓰고 있습니다."
  fi

  # 실제 게스트 위치가 inventory 와 같아야 정리·재생성 대상이 맞습니다
  local actual expected
  actual=$(pvesh get /cluster/resources --type vm --output-format json | jq -r --arg n "$NODE" '[.[] | select(.node == $n) | .vmid] | sort | .[]')
  expected=$(jq -r '[.guests[].vmid, .template] | map(tonumber) | sort | .[]' <<< "$V")
  if [ "$actual" != "$expected" ]; then
    echo "실제: $(tr '\n' ' ' <<< "$actual")"; echo "예상: $(tr '\n' ' ' <<< "$expected")"
    die "$NODE 의 게스트 목록이 group_vars(pve: $NODE)·템플릿과 다릅니다. inventory 를 먼저 맞춥니다."
  fi

  # etcd 멤버를 빼려면 나머지 멤버만으로 과반이어야 합니다(원격 투표자 포함)
  local c cp t
  for c in $(jq -r '.target_cps | to_entries[] | select(.value | length > 0) | .key' <<< "$V"); do
    cp=$(jq -r --arg c "$c" '.kubectl[$c]' <<< "$V")
    [ -n "$cp" ] || die "클러스터 $c 에 $NODE 밖의 control plane 이 없습니다."
    "${SSH[@]}" "ubuntu@$cp" "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system exec etcd-\$(hostname -s) -- etcdctl \
        --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key --command-timeout=5s endpoint health --cluster 2>&1" > "$STATE_DIR/etcd-health.txt" || true
    t=$(jq -r --arg c "$c" '.target_cps[$c] | map("https://" + . + ":") | join("|")' <<< "$V")
    grep -q 'is healthy' "$STATE_DIR/etcd-health.txt" || { cat "$STATE_DIR/etcd-health.txt"; die "클러스터 $c 의 etcd 상태를 읽지 못했습니다($cp)."; }
    if grep -vE "$t" "$STATE_DIR/etcd-health.txt" | grep -qE 'is unhealthy|Failed|deadline'; then
      cat "$STATE_DIR/etcd-health.txt"
      die "클러스터 $c 에서 $NODE 의 멤버를 뺀 나머지 etcd 멤버 중 응답하지 않는 것이 있습니다(원격 투표자 경로 확인). 지금 빼면 과반을 잃습니다."
    fi
  done
  log "점검 통과"
}

show_targets() {
  log "지울 대상 (playbooks/node-rebuild.yml --check)"
  # 결과를 JSON 으로 받아야 긴 항목이 줄바꿈으로 잘리지 않습니다
  ANSIBLE_CALLBACK_RESULT_FORMAT=json ansible-playbook playbooks/node-rebuild.yml --check -e node="$NODE" ${1:+-e state="$1"} \
    > "$STATE_DIR/check.log" 2>&1 || { cat "$STATE_DIR/check.log"; die "목록 계산에 실패했습니다."; }
  python3 - "$STATE_DIR/check.log" <<'PY'
import json, re, sys
text = open(sys.argv[1]).read()
for block in re.findall(r"TASK \[지울 대상\].*?(?=\nTASK|\nPLAY)", text, re.S):
    for result in re.findall(r"=> (\{.*?\n\})", block, re.S):
        for line in json.loads(result).get("msg", []):
            print("   ", line)
PY
}

ssh_new() { "${SSH_NEW[@]}" "root@$ADDR" "$@"; }

# ---- 신원 맞추기: 호스트 이름·IP 를 inventory 값으로 ----
identity() {
  log "신원 맞추기: $ADDR → $NODE.$DOMAIN / $INV_IP"
  scp -q "${NEW_OPTS[@]}" scripts/pve-rename-node.sh "root@$ADDR:/root/pve-rename-node.sh"
  ssh_new "systemd-run --unit pve-rename-node-\$(date +%s) --collect --wait -p StandardOutput=file:/root/pve-rename-node.log \
    -p StandardError=inherit bash /root/pve-rename-node.sh $NODE $DOMAIN >/dev/null; cat /root/pve-rename-node.log"
  [ "$(ssh_new hostname -f)" = "$NODE.$DOMAIN" ] || die "호스트 이름을 $NODE.$DOMAIN 로 바꾸지 못했습니다."

  if [ "$ADDR" != "$INV_IP" ]; then
    log "IP 바꾸기: $ADDR → $INV_IP (/etc/network/interfaces, /etc/hosts)"
    local re=${ADDR//./\\.}
    ssh_new "set -e
      cp -a /etc/network/interfaces /root/interfaces.before-rebuild
      sed -i -E 's#^(\s*address\s+)$re(/[0-9]+)?(\s|\$)#\1$INV_IP\2\3#' /etc/network/interfaces
      grep -qE '^\s*address\s+${INV_IP//./\\.}(/|\s|\$)' /etc/network/interfaces
      sed -i -E 's#^$re(\s)#$INV_IP\1#' /etc/hosts
      systemd-run --on-active=2 --unit pve-rebuild-ifreload --collect sh -c 'ifreload -a; systemctl restart pve-cluster pveproxy'"
    local _
    for _ in $(seq 60); do
      sleep 5
      if [ "$(fingerprint "$INV_IP")" = "$(st .new.fingerprint)" ]; then ADDR=$INV_IP; break; fi
    done
    [ "$ADDR" = "$INV_IP" ] || die "새 기계가 $INV_IP 로 돌아오지 않았습니다. 콘솔에서 /etc/network/interfaces 를 확인합니다(백업 /root/interfaces.before-rebuild)."
  fi
  st_set '.address = $a' --arg a "$INV_IP"

  log "known_hosts 의 옛 항목 지우기 ($NODE 와 그 게스트)"
  local h
  for h in "$NODE" "$NODE.$DOMAIN" "$INV_IP" "$(st .new.ip)" $(jq -r '.guests[].ip' <<< "$V"); do
    ssh-keygen -R "$h" >/dev/null 2>&1 || true
  done
}

# ---- 플레이북 실행 ----
run_pb() {   # run_pb <단계 이름> <ansible-playbook 인자>...
  local name=$1; shift
  step_done "$name" && { log "건너뜀(완료): $name"; return 0; }
  log "실행: ansible-playbook ${INV[*]} $*"
  ansible-playbook "${INV[@]}" "$@" || die "$name 에서 실패했습니다. 원인을 고친 뒤 같은 명령으로 이어 갑니다."
  mark_step "$name"
}

playbook_env() {
  local tf; tf=$(v .token_file)
  [ -s "$tf" ] || die "API 토큰 파일 $tf 이 없습니다(pve-controller.yml 이 만듦)."
  export PROXMOX_HOST=$SELF_IP PROXMOX_USER=root@pam PROXMOX_TOKEN_ID=rebuild-$SELF PROXMOX_VALIDATE_CERTS=false
  PROXMOX_TOKEN_SECRET=$(cat "$tf"); export PROXMOX_TOKEN_SECRET
  # 브로커 계정(devices) 비밀번호는 이 노드의 host-metrics 설정(host-metrics.yml 이 넣은 값)에서 읽어 환경변수로만 넘깁니다
  if [ -z "${MQTT_PASSWORD:-}" ] && [ -r /etc/default/telegraf ]; then
    # shellcheck disable=SC1091
    MQTT_PASSWORD=$(. /etc/default/telegraf; echo "${MQTT_PASSWORD:-}"); export MQTT_PASSWORD
  fi
}

# ---- 검증 요약 ----
verify() {
  log "검증 요약"
  local ok=1 cp c w host port
  echo "--- Proxmox"
  pvecm status | grep -E 'Quorate|Total votes|Expected votes|Flags'
  pvecm status | grep -qE '^Quorate:\s+Yes' || ok=0
  local actual expected
  actual=$(pvesh get /cluster/resources --type vm --output-format json | jq -r --arg n "$NODE" '[.[] | select(.node == $n) | "\(.vmid)\(if .status then ":" + .status else "" end)"] | sort | join(" ")')
  expected=$(jq -r '[.guests[].vmid, .template] | map(tostring) | sort | join(" ")' <<< "$V")
  echo "게스트($NODE): $actual (예상 vmid: $expected)"
  local kc cpip
  for c in $(jq -r '.target_cps | to_entries[] | select(.value | length > 0) | .key' <<< "$V"); do
    kc=$(jq -r --arg c "$c" '.kubectl[$c]' <<< "$V")
    echo "--- k8s $c (kubectl: $kc)"
    "${SSH[@]}" "ubuntu@$kc" 'K="sudo kubectl --kubeconfig /etc/kubernetes/admin.conf"
      $K get nodes --no-headers | awk "{print \$1, \$2}"
      $K -n kube-system exec etcd-$(hostname -s) -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key --command-timeout=5s endpoint health --cluster 2>&1 | grep -v "^{"
      $K -n longhorn-system get volumes.longhorn.io --no-headers -o custom-columns=N:.metadata.name,R:.status.robustness 2>/dev/null | awk "\$2 != \"healthy\" {print \"Longhorn \" \$0}"
      $K -n timescaledb exec timescaledb-0 -c timescaledb -- patronictl -c /etc/patroni/patroni.yml list 2>/dev/null \
        || $K -n timescaledb exec timescaledb-1 -c timescaledb -- patronictl -c /etc/patroni/patroni.yml list 2>/dev/null' || ok=0
    w=$(jq -r --arg c "$c" '.clusters[$c]' <<< "$V")
    if [ -n "$w" ] && [ "$w" != null ]; then
      host=${w%:*}; port=${w##*:}
      for cpip in $(jq -r --arg c "$c" '.target_cps[$c][]' <<< "$V"); do
        if "${SSH[@]}" "ubuntu@$cpip" "timeout 5 bash -c '</dev/tcp/$host/$port'" 2>/dev/null; then
          echo "원격 etcd 투표자 $w: $cpip 에서 닿음"
        else
          warn "$cpip 에서 원격 etcd 투표자 $w 에 닿지 않습니다(Tailscale 경로·NAS 확인)."
        fi
      done
    fi
  done
  echo "--- 모델 서버·DNS"
  local g
  for g in $(v '.ollama_ips[]'); do
    if curl -sf -m 5 "http://$g:11434/api/version"; then echo " ← $g ollama"; else warn "$g ollama 가 응답하지 않습니다."; ok=0; fi
  done
  for g in $(v '.lan_dns_ips[]'); do
    if dig +short +time=3 +tries=2 "@$g" "$NODE.$DOMAIN" 2>/dev/null | grep -qx "$INV_IP"; then echo "$g DNS: $NODE.$DOMAIN → $INV_IP"
    else warn "$g 의 DNS 가 $NODE.$DOMAIN 를 $INV_IP 로 풀지 않습니다."; ok=0; fi
  done
  "${SSH_NEW[@]}" "root@$INV_IP" tailscale status --self --peers=false 2>/dev/null | head -2 || true
  if [ "$ok" = 1 ]; then log "검증 끝. 위 경고만 확인합니다."; else warn "검증 중 실패한 항목이 있습니다. 위 출력을 확인합니다."; fi
}

# ==== 시작 ====
if [ "$DRY" = 1 ]; then
  if step_done preflight; then
    log "상태 파일 $STATE 가 있습니다(점검 완료). 이어 갈 단계: $(st '[.steps | to_entries[] | select(.value) | .key] | join(", ")') 다음"
    show_targets "$STATE"
  else
    preflight
    show_targets
  fi
  log "dry-run: 아무것도 바꾸지 않았습니다."
  exit 0
fi

if [ "$IN_UNIT" = 0 ]; then
  if ! step_done preflight; then
    preflight
    show_targets
    if [ "$YES" = 0 ]; then
      printf '위 대상을 지우고 %s 을(를) %s 로 다시 만듭니다. 계속하려면 노드 이름(%s)을 입력: ' "$NEW_IP" "$NODE" "$NODE"
      read -r answer < /dev/tty
      [ "$answer" = "$NODE" ] || die "입력이 노드 이름과 달라 멈춥니다."
    fi
    fp=$(fingerprint "$NEW_IP"); mid=$(machine_id "$NEW_IP")
    [ -n "$fp" ] && [ -n "$mid" ] || die "새 기계의 호스트 키 지문·machine-id 를 읽지 못했습니다."
    jq -n --arg node "$NODE" --arg ip "$NEW_IP" --arg fp "$fp" --arg mid "$mid" --arg reason "$REASON" --argjson fenced "$FENCED" \
      '{node: $node, reason: $reason, fenced: ($fenced == 1), started: (now | todate), new: {ip: $ip, fingerprint: $fp, machine_id: $mid},
        address: $ip, steps: {preflight: true}, done: {}, record: {}}' > "$STATE"
    chmod 600 "$STATE"
    log "상태 파일: $STATE"
  else
    log "상태 파일 $STATE 로 이어 갑니다(완료: $(st '[.steps | to_entries[] | select(.value) | .key] | join(", ")'))."
  fi
  LOG=$STATE_DIR/$(date +%Y%m%d-%H%M%S).log
  unit=pve-node-rebuild-$NODE
  systemctl is-active -q "$unit" && die "$unit 가 이미 돌고 있습니다(journalctl -fu $unit)."
  args=("$NEW_IP" "$NODE" --reason "$REASON" --in-unit "$LOG")
  [ "$FENCED" = 1 ] && args+=(--fenced)
  systemd-run --unit "$unit" --collect -p StandardOutput="append:$LOG" -p StandardError="append:$LOG" \
    ${REBUILD_FAIL_AFTER:+--setenv=REBUILD_FAIL_AFTER=$REBUILD_FAIL_AFTER} "$(readlink -f "$0")" "${args[@]}" >/dev/null
  log "systemd 유닛 $unit 로 진행합니다. ssh 가 끊겨도 계속 돕니다. 로그: $LOG (다시 보기: tail -f $LOG)"
  sleep 1
  pid=$(systemctl show -p MainPID --value "$unit")
  if [ -n "$pid" ] && [ "$pid" != 0 ]; then tail -n +1 --pid="$pid" -F "$LOG" 2>/dev/null; fi
  sleep 1
  result=$(systemctl show -p Result --value "$unit" 2>/dev/null || echo unknown)
  [ "$result" = success ] || [ -z "$result" ] || die "유닛이 $result 로 끝났습니다. 로그 $LOG 를 보고 고친 뒤 같은 명령으로 이어 갑니다."
  exit 0
fi

# ---- systemd 유닛 안 ----
log "재구축 시작: $NODE (로그 $LOG)"
step_done preflight || die "점검이 끝나지 않은 상태 파일입니다."
[ "$(st .new.ip)" = "$NEW_IP" ] || warn "처음 실행의 새 기계 IP($(st .new.ip))와 지금 인자($NEW_IP)가 다릅니다. 저장된 기계 지문으로 찾습니다."
ADDR=$(find_new_machine) || die "저장된 새 기계(지문 $(st .new.fingerprint))를 $(st .address)·$INV_IP 에서 찾지 못했습니다. 다른 기계라면 상태 파일을 확인합니다."
log "새 기계: $ADDR (지문 일치)"

if ! step_done identity; then identity; mark_step identity; fi
[ "$ADDR" = "$INV_IP" ] || die "새 기계가 inventory 주소 $INV_IP 에 있지 않습니다."
"${SSH_NEW[@]}" "root@$INV_IP" 'test ! -e /etc/pve/corosync.conf' 2>/dev/null || step_done cleanup || die "정리 전인데 새 기계가 이미 클러스터에 들어 있습니다."

playbook_env
write_new_inventory
log "ansible 이 고정한 호스트 키로 $NODE 에 붙는지"
ansible "$NODE" "${INV[@]}" -m ansible.builtin.ping -o || die "ansible 이 고정한 호스트 키($NEW_KH)로 $NODE 에 붙지 못합니다. 플레이북을 시작하지 않습니다."
run_pb cleanup playbooks/node-rebuild.yml -e node="$NODE" -e state="$STATE"
run_pb pve-cluster playbooks/pve-cluster.yml
run_pb vm-template playbooks/vm-template.yml
run_pb lan-dns playbooks/lan-dns.yml
run_pb ollama playbooks/ollama.yml
run_pb k8s-hub playbooks/k8s-cluster.yml -e k8s_cluster=hub
run_pb k8s-daejeon playbooks/k8s-cluster.yml -e k8s_cluster=daejeon
run_pb after-join playbooks/node-rebuild.yml -e node="$NODE" -e state="$STATE" -e phase=after-join
if [ -n "${MQTT_PASSWORD:-}" ]; then
  run_pb host-metrics playbooks/host-metrics.yml
else
  warn "MQTT_PASSWORD 를 찾지 못해 host-metrics 를 건너뜁니다(MQTT_PASSWORD=... 로 같은 명령을 다시 실행)."
fi
run_pb timezone playbooks/timezone.yml --limit proxmox,lan_dns,ollama,k8s
verify
st_set '.finished = (now | todate)'
log "끝: $NODE 재구축"
