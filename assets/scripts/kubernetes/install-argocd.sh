#!/usr/bin/env bash
#
# 쿠버네티스 클러스터에 Argo CD 를 Helm 으로 설치하고 GitOps 저장소를 연결합니다.
# 저장소의 services/ 아래 폴더마다 Application 을 자동으로 만드는 ApplicationSet 을 함께 등록합니다.
# kubectl 로 클러스터에 접근할 수 있는 곳(예: control plane)에서 실행합니다: bash install-argocd.sh git@github.com:[OWNER]/[REPO].git

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
ARGOCD_CHART_VERSION=10.9.2  # Argo CD Helm 차트 버전 (Argo CD v3.5)
NODEPORT=30081               # 브라우저로 접속할 포트 (30000-32767)
NAMESPACE=argocd
SERVICES_DIR=services        # 저장소에서 서비스 폴더를 모아 두는 디렉터리
# --------------------------------------

HELM_INSTALL_URL=https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
CHART_REPO=https://argoproj.github.io/argo-helm
REPO_SECRET=gitops-repo

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------- 1. 사전 검사 ----------
log "사전 검사"
REPO_URL=${1:-}
[[ "$REPO_URL" =~ ^git@github\.com:[^/]+/[^/]+\.git$ ]] || die "사용법: bash install-argocd.sh git@github.com:[OWNER]/[REPO].git"
kubectl get nodes >/dev/null || die "kubectl 로 클러스터에 접근할 수 없습니다."
command -v ssh-keygen >/dev/null || die "ssh-keygen 이 필요합니다."

# ---------- 2. Helm ----------
if ! command -v helm >/dev/null; then
  log "Helm 설치"
  curl -fsSL "$HELM_INSTALL_URL" | sudo bash
fi

# ---------- 3. Argo CD ----------
# 클러스터 밖에 TLS 를 둘 계획이 없으므로 HTTP(NodePort)로 열고, 쓰지 않는 Dex(SSO)와 알림은 끕니다.
log "Argo CD 설치"
helm repo add argo "$CHART_REPO" --force-update
helm repo update argo
cat > "$TMP_DIR/values.yaml" <<VALUES
configs:
  params:
    server.insecure: true
server:
  service:
    type: NodePort
    nodePortHttp: $NODEPORT
dex:
  enabled: false
notifications:
  enabled: false
VALUES
helm upgrade --install argocd argo/argo-cd \
  --namespace "$NAMESPACE" --create-namespace \
  --version "$ARGOCD_CHART_VERSION" \
  -f "$TMP_DIR/values.yaml" \
  --wait --timeout 10m

# ---------- 4. 저장소 연결 ----------
# 저장소 읽기 전용 Deploy key 로 인증합니다. 이미 연결돼 있으면 키를 바꾸지 않습니다.
if kubectl get secret "$REPO_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  log "저장소 연결 유지 (Secret $REPO_SECRET 이 이미 있습니다)"
else
  log "Deploy key 생성"
  ssh-keygen -t ed25519 -N "" -C "argocd@$(hostname)" -f "$TMP_DIR/deploy_key" -q
  echo
  echo "아래 공개 키를 GitHub 저장소의 Deploy keys 에 읽기 전용으로 등록합니다."
  echo
  cat "$TMP_DIR/deploy_key.pub"
  echo
  read -r -p "등록했으면 Enter 를 누르세요: "
  kubectl create secret generic "$REPO_SECRET" -n "$NAMESPACE" \
    --from-literal=type=git \
    --from-literal=url="$REPO_URL" \
    --from-file=sshPrivateKey="$TMP_DIR/deploy_key"
  kubectl label secret "$REPO_SECRET" -n "$NAMESPACE" argocd.argoproj.io/secret-type=repository
fi

# ---------- 5. ApplicationSet ----------
# services/ 아래 폴더마다 Application 을 만듭니다. 폴더 이름이 Application 이름이자 네임스페이스입니다.
# 폴더를 지워도 배포된 자원(네임스페이스, PVC)은 남깁니다.
log "ApplicationSet 등록"
kubectl apply -f - <<APPSET
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: services
  namespace: $NAMESPACE
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: $REPO_URL
        revision: HEAD
        directories:
          - path: $SERVICES_DIR/*
  template:
    metadata:
      name: '{{.path.basename}}'
    spec:
      project: default
      source:
        repoURL: $REPO_URL
        targetRevision: HEAD
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
  syncPolicy:
    preserveResourcesOnDeletion: true
APPSET

# ---------- 6. 접속 정보 ----------
node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
password=$(kubectl get secret argocd-initial-admin-secret -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
log "완료. 브라우저에서 접속한 뒤 admin 계정으로 로그인합니다."
echo "  http://$node_ip:$NODEPORT"
echo
echo "$password"
echo
echo "저장소의 $SERVICES_DIR/[이름]/ 폴더에 매니페스트를 넣고 push 하면 배포됩니다."
