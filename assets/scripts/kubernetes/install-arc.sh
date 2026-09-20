#!/usr/bin/env bash
#
# 쿠버네티스 클러스터에 Actions Runner Controller(ARC)를 Helm 으로 설치하고 GitHub Actions self-hosted runner 를 등록합니다.
# kubectl 로 클러스터에 접근할 수 있는 곳(예: control plane)에서 실행합니다: bash install-arc.sh [GITHUB_CONFIG_URL] [RUNNER_NAME]
#   개인 계정: https://github.com/[OWNER]/[REPO]
#   조직 계정: https://github.com/[ORG]
# RUNNER_NAME 을 생략하면 아래 기본값을 씁니다. 저장소를 추가할 때는 이름을 바꿔 다시 실행합니다.

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
RUNNER_NAME=arc-runner-set   # 워크플로우의 runs-on 에 적을 이름 (두 번째 인자의 기본값)
ARC_VERSION=0.14.2           # 두 Helm 차트의 버전
# --------------------------------------

HELM_INSTALL_URL=https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
CHART_BASE=oci://ghcr.io/actions/actions-runner-controller-charts
CONTROLLER_NS=arc-systems
RUNNER_NS=arc-runners
TOKEN_SECRET=arc-github-token

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
log "사전 검사"
GITHUB_CONFIG_URL=${1:-}
RUNNER_NAME=${2:-$RUNNER_NAME}
[[ "$GITHUB_CONFIG_URL" == https://github.com/* ]] || die "사용법: bash install-arc.sh https://github.com/[OWNER]/[REPO] [RUNNER_NAME]"
kubectl get nodes >/dev/null || die "kubectl 로 클러스터에 접근할 수 없습니다."

# ---------- 2. 액세스 토큰 ----------
# 토큰이 화면과 셸 기록에 남지 않도록 입력받습니다. 환경 변수 GITHUB_PAT 가 있으면 그 값을 씁니다.
if [ -z "${GITHUB_PAT:-}" ]; then
  read -rsp "GitHub 액세스 토큰: " GITHUB_PAT
  echo
fi
[ -n "$GITHUB_PAT" ] || die "토큰이 비어 있습니다."

# ---------- 3. Helm ----------
if ! command -v helm >/dev/null; then
  log "Helm 설치"
  curl -fsSL "$HELM_INSTALL_URL" | sudo bash
fi

# ---------- 4. ARC 컨트롤러 ----------
log "ARC 컨트롤러 설치"
helm upgrade --install arc "$CHART_BASE/gha-runner-scale-set-controller" \
  --namespace "$CONTROLLER_NS" --create-namespace \
  --version "$ARC_VERSION" \
  --wait --timeout 5m

# ---------- 5. 토큰 Secret ----------
# 토큰을 Helm 값으로 넘기지 않고 Secret 으로 분리합니다. 다시 실행하면 새 토큰으로 교체됩니다.
log "토큰 Secret 생성"
kubectl create namespace "$RUNNER_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic "$TOKEN_SECRET" --namespace "$RUNNER_NS" \
  --from-literal=github_token="$GITHUB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------- 6. 러너 스케일 셋 ----------
# dind: 러너 파드에 Docker 데몬을 함께 띄워 워크플로우에서 docker 명령과 컨테이너 액션을 쓸 수 있게 합니다.
log "러너 스케일 셋 설치 ($RUNNER_NAME, $GITHUB_CONFIG_URL)"
helm upgrade --install "$RUNNER_NAME" "$CHART_BASE/gha-runner-scale-set" \
  --namespace "$RUNNER_NS" \
  --version "$ARC_VERSION" \
  --set githubConfigUrl="$GITHUB_CONFIG_URL" \
  --set githubConfigSecret="$TOKEN_SECRET" \
  --set containerMode.type=dind

# ---------- 7. listener 확인 ----------
# GitHub 에 등록되면 컨트롤러가 listener 파드를 만듭니다. 토큰이나 URL 이 틀리면 만들어지지 않습니다.
log "listener 파드 대기"
phase=
for _ in $(seq 1 60); do
  listener=$(kubectl get pods -n "$CONTROLLER_NS" -o name | grep -- "/$RUNNER_NAME-.*-listener" | head -n 1 || true)
  [ -z "$listener" ] || phase=$(kubectl get "$listener" -n "$CONTROLLER_NS" -o jsonpath='{.status.phase}')
  [ "$phase" != Running ] || break
  sleep 2
done
[ "$phase" = Running ] || die "러너가 등록되지 않았습니다. 토큰 권한과 URL 을 확인합니다: kubectl logs -n $CONTROLLER_NS deploy/arc-gha-rs-controller"

log "완료. 워크플로우에서 아래와 같이 지정합니다."
echo "  runs-on: $RUNNER_NAME"
