#!/usr/bin/env bash
#
# --control-plane-endpoint 없이 만든 kubeadm 클러스터에 VIP 엔드포인트를 들입니다. 컨트롤 플레인을 여러 대로 늘리기 전에 한 번 실행합니다.
# 첫 control plane 에서 root 로 실행합니다. 여러 번 실행해도 됩니다(이미 된 단계는 건너뜀).
#   1. etcd 스냅샷 (되돌리기용, /var/lib/etcd/snapshot-<시각>.db)
#   2. kube-vip static pod (ARP 로 VIP 를 control plane 중 한 대가 가짐)
#   3. kubeadm-config: controlPlaneEndpoint, apiserver certSANs, 노드 장애 시 파드 재배치 30초
#   4. apiserver 인증서 재발급(VIP 를 SAN 에 추가)과 static pod 매니페스트 반영
#   5. kubeconfig·kube-proxy·cluster-info 의 API 주소를 VIP 로 (control plane 의 kubelet·controller-manager·scheduler 는 로컬 apiserver 유지)
# worker 의 kubelet.conf 는 이 스크립트가 바꾸지 않습니다. 끝에 출력하는 명령을 각 worker 에서 실행합니다(playbooks/k8s-cluster.yml 이 처리).
#
# 사용법: sudo bash k8s-control-plane-endpoint.sh <VIP> [인터페이스] [추가 SAN ...]
#   예: sudo bash k8s-control-plane-endpoint.sh [VIP] eth0 [EXTRA_SAN]

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
KUBE_VIP_VERSION=v1.2.4           # https://github.com/kube-vip/kube-vip/releases
# --------------------------------------

log() { echo "==> $*"; }
die() { echo "[오류] $*" >&2; exit 1; }
trap 'echo "[오류] ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

VIP=${1:-}; IFACE=${2:-eth0}; shift $(( $# >= 2 ? 2 : $# )); EXTRA_SANS=("$@")
[ -n "$VIP" ] || die "사용법: sudo bash k8s-control-plane-endpoint.sh <VIP> [인터페이스] [추가 SAN ...]"
[ "$(id -u)" = 0 ] || die "root 로 실행합니다."
[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ] || die "control plane 노드에서 실행합니다."
export KUBECONFIG=/etc/kubernetes/super-admin.conf
K=/etc/kubernetes
NODE_IP=$(sed -n 's/.*--advertise-address=\(.*\)/\1/p' $K/manifests/kube-apiserver.yaml)
NODE_NAME=$(hostname)
[ -n "$NODE_IP" ] || die "apiserver 매니페스트에서 advertise-address 를 찾지 못했습니다."

wait_api() {  # $1: 주소
  for _ in $(seq 90); do curl -sk --max-time 2 "https://$1:6443/livez" | grep -q ok && return 0; sleep 2; done
  die "https://$1:6443 이 응답하지 않습니다."
}

# ---------- 1. etcd 스냅샷 ----------
if ! ls /var/lib/etcd/snapshot-*.db >/dev/null 2>&1; then
  log "etcd 스냅샷"
  SNAP=/var/lib/etcd/snapshot-$(date +%Y%m%d-%H%M%S).db
  kubectl -n kube-system exec "etcd-$NODE_NAME" -- etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=$K/pki/etcd/ca.crt --cert=$K/pki/etcd/server.crt --key=$K/pki/etcd/server.key snapshot save "$SNAP"
else
  log "etcd 스냅샷: 이미 있음 ($(ls /var/lib/etcd/snapshot-*.db | tail -1))"
fi

# ---------- 2. kube-vip ----------
# kube-vip 은 리더 선출에 API 가 필요한데, VIP 는 kube-vip 이 띄우므로 자기 노드의 apiserver 로 붙는 kubeconfig 를 따로 줍니다
log "kube-vip ($KUBE_VIP_VERSION, $VIP on $IFACE)"
sed "s#server: https://.*:6443#server: https://$NODE_IP:6443#" $K/admin.conf > $K/kube-vip.conf.new
chmod 0600 $K/kube-vip.conf.new && mv $K/kube-vip.conf.new $K/kube-vip.conf
IMG=ghcr.io/kube-vip/kube-vip:$KUBE_VIP_VERSION
ctr -n k8s.io image pull "$IMG" >/dev/null
ctr -n k8s.io run --rm --net-host "$IMG" kube-vip-manifest-$$ /kube-vip manifest pod \
  --interface "$IFACE" --address "$VIP" --controlplane --arp --leaderElection \
  --k8sConfigPath $K/kube-vip.conf > /tmp/kube-vip.yaml
grep -q "path: $K/kube-vip.conf" /tmp/kube-vip.yaml || die "kube-vip 매니페스트가 kube-vip.conf 를 마운트하지 않습니다: /tmp/kube-vip.yaml"
if ! cmp -s /tmp/kube-vip.yaml $K/manifests/kube-vip.yaml; then mv /tmp/kube-vip.yaml $K/manifests/kube-vip.yaml; else rm /tmp/kube-vip.yaml; fi
wait_api "$VIP"

# ---------- 3. kubeadm-config ----------
log "kubeadm-config"
kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' > /tmp/cluster-config.yaml
python3 - "$VIP" "$NODE_IP" "${EXTRA_SANS[@]}" <<'PY'
import sys, yaml
vip, node_ip, extra = sys.argv[1], sys.argv[2], sys.argv[3:]
c = yaml.safe_load(open("/tmp/cluster-config.yaml"))
c["controlPlaneEndpoint"] = f"{vip}:6443"
api = c.setdefault("apiServer", {}) or {}
c["apiServer"] = api
sans = api.get("certSANs") or []
for s in [vip, node_ip, *extra]:
    if s not in sans: sans.append(s)
api["certSANs"] = sans
def set_args(section, pairs):
    args = [a for a in (section.get("extraArgs") or []) if a["name"] not in pairs]
    args += [{"name": k, "value": v} for k, v in pairs.items()]
    section["extraArgs"] = args
# 노드가 죽으면 기본 5분 뒤에 파드를 옮깁니다. 30초로 줄입니다
set_args(api, {"default-not-ready-toleration-seconds": "30", "default-unreachable-toleration-seconds": "30"})
yaml.safe_dump(c, open("/tmp/cluster-config.yaml", "w"), sort_keys=False)
PY
kubectl -n kube-system create cm kubeadm-config --from-file=ClusterConfiguration=/tmp/cluster-config.yaml \
  --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts -f - >/dev/null

# ---------- 4. apiserver 인증서와 매니페스트 ----------
cat > /tmp/kubeadm-local.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $NODE_IP
nodeRegistration:
  name: $NODE_NAME
---
$(cat /tmp/cluster-config.yaml)
EOF
if ! openssl x509 -in $K/pki/apiserver.crt -noout -ext subjectAltName | grep -q "IP Address:$VIP\b"; then
  log "apiserver 인증서 재발급"
  mkdir -p /root/pki-backup && cp -a $K/pki/apiserver.crt $K/pki/apiserver.key /root/pki-backup/
  rm $K/pki/apiserver.crt $K/pki/apiserver.key
  kubeadm init phase certs apiserver --config /tmp/kubeadm-local.yaml
fi
add_flag() {  # $1: 매니페스트, $2: --플래그=값
  grep -q -- "- ${2%%=*}=" "$1" && return 0
  sed -i "0,/^    - $(basename "$1" .yaml)$/s##&\n    - $2#" "$1"
  echo "    $2 → $(basename "$1")"
}
log "static pod 매니페스트"
BEFORE=$(sha256sum < $K/manifests/kube-apiserver.yaml)
add_flag $K/manifests/kube-apiserver.yaml --default-not-ready-toleration-seconds=30
add_flag $K/manifests/kube-apiserver.yaml --default-unreachable-toleration-seconds=30
# 매니페스트가 바뀌면 kubelet 이 apiserver 를 다시 띄우며 새 인증서를 읽습니다. 옛 apiserver 가 내려갈 때까지 기다립니다
[ "$BEFORE" = "$(sha256sum < $K/manifests/kube-apiserver.yaml)" ] || sleep 30
wait_api "$NODE_IP"; wait_api "$VIP"
echo | openssl s_client -connect "$VIP:6443" 2>/dev/null | openssl x509 -noout -ext subjectAltName | grep -q "IP Address:$VIP" \
  || die "VIP 로 받은 인증서에 $VIP 가 없습니다. apiserver 가 옛 인증서를 쓰고 있으면 매니페스트를 잠시 빼 두었다가 되돌려 다시 띄웁니다."

# ---------- 5. API 주소를 VIP 로 ----------
log "kubeconfig·kube-proxy·cluster-info → https://$VIP:6443"
for f in $K/admin.conf $K/super-admin.conf /home/*/.kube/config /root/.kube/config; do
  [ -f "$f" ] && sed -i "s#server: https://.*:6443#server: https://$VIP:6443#" "$f"
done
for cm in "kube-system kube-proxy kubeconfig.conf" "kube-public cluster-info kubeconfig"; do
  set -- $cm
  cur=$(kubectl -n "$1" get cm "$2" -o jsonpath="{.data.${3//./\\.}}")
  new=$(echo "$cur" | sed "s#server: https://.*:6443#server: https://$VIP:6443#")
  if [ "$cur" != "$new" ]; then
    kubectl -n "$1" get cm "$2" -o json | python3 -c "
import json,sys; d=json.load(sys.stdin); d['data']['$3']=sys.argv[1]; print(json.dumps(d))" "$new" | kubectl replace -f - >/dev/null
    [ "$2" = kube-proxy ] && kubectl -n kube-system rollout restart ds kube-proxy >/dev/null
    echo "    $1/$2"
  fi
done

log "완료. worker 에서 실행: sudo sed -i 's#server: https://.*:6443#server: https://$VIP:6443#' /etc/kubernetes/kubelet.conf && sudo systemctl restart kubelet"
