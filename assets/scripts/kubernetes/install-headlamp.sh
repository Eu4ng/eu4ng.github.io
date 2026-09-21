#!/usr/bin/env bash
#
# 쿠버네티스 클러스터에 Headlamp 대시보드를 Helm 으로 설치하고 로그인 토큰을 출력합니다.
# kubectl 로 클러스터에 접근할 수 있는 곳(예: control plane)에서 실행합니다: bash install-headlamp.sh

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
NODEPORT=30080             # 브라우저로 접속할 포트 (30000-32767)
NAMESPACE=headlamp
# --------------------------------------

HELM_INSTALL_URL=https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
CHART_REPO=https://kubernetes-sigs.github.io/headlamp/
TOKEN_SECRET=headlamp-admin-token

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
log "사전 검사"
kubectl get nodes >/dev/null || die "kubectl 로 클러스터에 접근할 수 없습니다."

# ---------- 2. Helm ----------
if ! command -v helm >/dev/null; then
  log "Helm 설치"
  curl -fsSL "$HELM_INSTALL_URL" | sudo bash
fi

# ---------- 3. Headlamp ----------
# 차트가 ServiceAccount(headlamp)와 cluster-admin 권한을 함께 만듭니다.
log "Headlamp 설치"
helm repo add headlamp "$CHART_REPO" --force-update
helm repo update headlamp
helm upgrade --install headlamp headlamp/headlamp \
  --namespace "$NAMESPACE" --create-namespace \
  --set service.type=NodePort --set service.nodePort="$NODEPORT" \
  --wait --timeout 5m

# ---------- 4. 로그인 토큰 ----------
# 만료되지 않는 ServiceAccount 토큰을 Secret 으로 만듭니다.
log "로그인 토큰 생성"
kubectl apply -f - <<TOKEN
apiVersion: v1
kind: Secret
metadata:
  name: $TOKEN_SECRET
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/service-account.name: headlamp
type: kubernetes.io/service-account-token
TOKEN

token=
for _ in $(seq 1 30); do
  token=$(kubectl get secret "$TOKEN_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)
  [ -z "$token" ] || break
  sleep 1
done
[ -n "$token" ] || die "토큰이 생성되지 않았습니다."

node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
log "완료. 브라우저에서 접속한 뒤 아래 토큰으로 로그인합니다."
echo "  http://$node_ip:$NODEPORT"
echo
echo "$token"
