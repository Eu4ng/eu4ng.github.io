#!/usr/bin/env bash
#
# 엣지(k3s) 클러스터를 허브의 Argo CD 에 원격 클러스터로 등록합니다.
# proxmox-ansible 의 playbooks/k3s-edge.yml 이 실행 PC 에 가져온 kubeconfig 를 control plane 에 복사한 뒤,
# control plane 에서 실행합니다: bash register-edge-cluster.sh [SITE] [EDGE_KUBECONFIG]
# Argo CD API 서버에 로그인하지 않고 CLI 의 core 모드로 쿠버네티스 API 에 직접 쓰므로 비밀번호가 필요 없습니다.

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
ARGOCD_NAMESPACE=argocd
EDGE_CONTEXT=default          # 엣지 kubeconfig 의 컨텍스트 이름 (k3s 기본값)
ARGOCD_BIN=$HOME/.local/bin/argocd
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------- 1. 사전 검사 ----------
log "사전 검사"
SITE=${1:-}
EDGE_KUBECONFIG=${2:-}
[[ "$SITE" =~ ^[a-z0-9-]+$ ]] || die "사용법: bash register-edge-cluster.sh [SITE] [EDGE_KUBECONFIG]  (SITE 는 소문자·숫자·하이픈)"
[ -r "$EDGE_KUBECONFIG" ] || die "엣지 kubeconfig 파일이 없습니다: $EDGE_KUBECONFIG"
kubectl get nodes >/dev/null || die "kubectl 로 허브 클러스터에 접근할 수 없습니다."
kubectl get namespace "$ARGOCD_NAMESPACE" >/dev/null || die "네임스페이스 $ARGOCD_NAMESPACE 가 없습니다. Argo CD 를 먼저 설치하세요."
HUB_CONTEXT=$(kubectl config current-context)
kubectl --kubeconfig "$EDGE_KUBECONFIG" --context "$EDGE_CONTEXT" get nodes >/dev/null \
  || die "엣지 kubeconfig 의 컨텍스트 $EDGE_CONTEXT 로 엣지 클러스터에 접근할 수 없습니다."

# ---------- 2. argocd CLI ----------
# 서버와 같은 버전을 씁니다. 이미 그 버전이 있으면 건너뜁니다.
ARGOCD_VERSION=$(kubectl -n "$ARGOCD_NAMESPACE" get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')
if [ ! -x "$ARGOCD_BIN" ] || ! "$ARGOCD_BIN" version --client --short | grep -q "$ARGOCD_VERSION"; then
  log "argocd CLI $ARGOCD_VERSION 설치"
  mkdir -p "$(dirname "$ARGOCD_BIN")"
  curl -fsSL -o "$ARGOCD_BIN" "https://github.com/argoproj/argo-cd/releases/download/$ARGOCD_VERSION/argocd-linux-amd64"
  chmod +x "$ARGOCD_BIN"
fi

# ---------- 3. kubeconfig 병합 ----------
# core 모드는 현재 컨텍스트(허브)의 네임스페이스에서 Argo CD 설정을 찾고, cluster add 는 다른 컨텍스트(엣지)를 대상으로 씁니다.
# 두 컨텍스트가 한 kubeconfig 에 있어야 하므로 임시 파일로 병합합니다. 원래 kubeconfig 는 건드리지 않습니다.
log "kubeconfig 병합"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}:$EDGE_KUBECONFIG" kubectl config view --flatten > "$TMP_DIR/kubeconfig"
export KUBECONFIG=$TMP_DIR/kubeconfig
kubectl config use-context "$HUB_CONTEXT" >/dev/null
kubectl config set-context --current --namespace="$ARGOCD_NAMESPACE" >/dev/null

# ---------- 4. 등록 ----------
# 엣지 클러스터에 ServiceAccount argocd-manager(cluster-admin)를 만들고, 그 토큰을 허브의 argocd 네임스페이스에 cluster Secret 으로 저장합니다.
# --upsert 라 다시 실행하면 같은 이름의 등록을 갱신합니다.
log "Argo CD 에 클러스터 $SITE 등록"
"$ARGOCD_BIN" --core cluster add "$EDGE_CONTEXT" --name "$SITE" --label "site=$SITE" --upsert --yes

# ---------- 5. 확인 ----------
log "등록된 클러스터"
"$ARGOCD_BIN" --core cluster list
kubectl -n "$ARGOCD_NAMESPACE" get secret -l "argocd.argoproj.io/secret-type=cluster,site=$SITE" -o name | grep -q . \
  || die "cluster Secret 이 만들어지지 않았습니다."
log "완료. k8s-gitops 의 iot/clusters/$SITE/ 아래 폴더가 이 클러스터로 배포됩니다."
