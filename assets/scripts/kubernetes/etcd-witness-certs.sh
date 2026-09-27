#!/usr/bin/env bash
#
# 서울 NAS 의 etcd 투표자(stacks/seoul/etcd-witness, etcd-witness-<지역>)가 쓸 인증서를 그 클러스터의 etcd CA 로 발급합니다.
# 첫 control plane 에 ssh 해 그 노드의 /etc/kubernetes/pki/etcd/ca.{crt,key} 로 서명하고, 결과를 portainer-stack.sh 가 읽는
# ~/.config/portainer/secrets/ 에 둡니다(권한 600, 저장소 밖). CA 키는 노드 밖으로 나오지 않습니다.
#
# SAN 에는 투표자의 Tailscale IP 와, 투표자가 집 LAN 의 멤버에 붙을 때 거치는 NAT 주소(Tailscale 서브넷 라우터인 Proxmox 노드의
# LAN IP)를 넣습니다. etcd 는 peer 연결의 원격 주소를 상대 인증서 SAN 과 대조하므로, NAT 뒤 주소도 SAN 에 있어야 합니다.
#
# 인증서는 VALID_DAYS 동안 유효합니다. 갱신할 때는 SUFFIX 를 바꿔 다시 실행하고(Swarm secret 은 고칠 수 없어 새 이름으로 만듦)
# stack.yml 의 secret 이름을 같은 SUFFIX 로 바꿔 다시 배포합니다.
#
# 사용법: bash scripts/etcd-witness-certs.sh [SUFFIX] [CLUSTER]      (기본 SUFFIX: v1, CLUSTER: hub. 지역 엣지는 daejeon 등)

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
declare -A CONTROL_PLANES=(                         # 클러스터마다 etcd CA 가 있는 control plane
  [hub]=ubuntu@[CONTROL_PLANE_IP]
  [daejeon]=ubuntu@[EDGE_CONTROL_PLANE_IP]
)
WITNESS_IP=[NAS_TAILSCALE_IP]                       # 서울 NAS 의 Tailscale IP
NAT_IPS="[PVE01_IP] [PVE02_IP]"                     # NAS → 집 LAN 연결이 SNAT 되는 주소(서브넷 라우터의 LAN IP)
VALID_DAYS=3650
# --------------------------------------

SUFFIX=${1:-v1}
CLUSTER=${2:-hub}
CONTROL_PLANE=${CONTROL_PLANES[$CLUSTER]:?"알 수 없는 클러스터: $CLUSTER"}
PREFIX=etcd_witness$([ "$CLUSTER" = hub ] || echo "_$CLUSTER")   # Swarm secret 이름 앞부분 (허브는 etcd_witness)
OUT=$HOME/.config/portainer/secrets
log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

names=(${PREFIX}_ca_$SUFFIX ${PREFIX}_peer_crt_$SUFFIX ${PREFIX}_peer_key_$SUFFIX ${PREFIX}_server_crt_$SUFFIX ${PREFIX}_server_key_$SUFFIX)
if [ -s "$OUT/${names[1]}" ]; then log "이미 있음: $OUT/${names[1]} (새로 만들려면 다른 SUFFIX)"; exit 0; fi
mkdir -p "$OUT" && chmod 700 "$OUT"

# ---------- 1. control plane 에서 발급 ----------
log "발급 ($CONTROL_PLANE, $VALID_DAYS 일)"
peer_sans="IP:$WITNESS_IP"; for ip in $NAT_IPS; do peer_sans="$peer_sans,IP:$ip"; done
bundle=$(ssh "$CONTROL_PLANE" "sudo -n bash -s" <<EOF
set -euo pipefail
d=\$(mktemp -d); trap 'rm -rf \$d' EXIT; cd \$d
CA=/etc/kubernetes/pki/etcd
issue() {  # \$1 이름, \$2 CN, \$3 SAN
  openssl req -new -newkey rsa:2048 -nodes -keyout \$1.key -subj "/CN=\$2" -out \$1.csr 2>/dev/null
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth,clientAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\n' "\$3" > \$1.ext
  openssl x509 -req -in \$1.csr -CA \$CA/ca.crt -CAkey \$CA/ca.key -CAcreateserial -days $VALID_DAYS -extfile \$1.ext -out \$1.crt 2>/dev/null
}
issue peer etcd-witness-$CLUSTER "$peer_sans"
issue server etcd-witness-$CLUSTER "IP:127.0.0.1,IP:$WITNESS_IP,DNS:localhost"
for f in \$CA/ca.crt peer.crt peer.key server.crt server.key; do echo "-----FILE \$(basename \$f)"; cat \$f; done
EOF
)

# ---------- 2. 파일로 저장 ----------
log "저장 → $OUT"
umask 077
BUNDLE=$bundle python3 - "$OUT" "$SUFFIX" "$PREFIX" <<'PY'
import os, sys, re
out, suffix, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
data = os.environ["BUNDLE"]
parts = dict(re.findall(r"-----FILE (\S+)\n(.*?)(?=-----FILE |\Z)", data, re.S))
m = {"ca.crt": "ca", "peer.crt": "peer_crt", "peer.key": "peer_key", "server.crt": "server_crt", "server.key": "server_key"}
for src, dst in m.items():
    path = f"{out}/{prefix}_{dst}_{suffix}"
    open(path, "w").write(parts[src])
    print("   ", path)
PY
openssl x509 -in "$OUT/${PREFIX}_peer_crt_$SUFFIX" -noout -subject -enddate -ext subjectAltName | sed 's/^/    /'
log "완료. stack.yml 의 secret 이름(${PREFIX}_*_$SUFFIX)을 확인하고 bash scripts/portainer-stack.sh stacks/seoul/etcd-witness$([ "$CLUSTER" = hub ] || echo "-$CLUSTER")/stack.yml 로 배포합니다."
