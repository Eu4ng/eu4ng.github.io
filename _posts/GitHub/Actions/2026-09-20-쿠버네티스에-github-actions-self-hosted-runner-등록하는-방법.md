---
layout: post
title: 쿠버네티스에 GitHub Actions Self-hosted Runner 등록하는 방법
description: 스크립트 하나로 Actions Runner Controller를 설치해, 워크플로우가 실행될 때만 러너 파드가 만들어지는 self-hosted runner를 쿠버네티스에 등록하는 방법을 정리했습니다.
author: Eu4ng
tags: [github, actions, self-hosted-runner, kubernetes, helm]
---

GitHub에서 액세스 토큰을 발급하고, control plane에서 스크립트를 실행해 GitHub 공식 도구인 **Actions Runner Controller**(ARC)를 설치한 뒤, 워크플로우의 `runs-on`에 러너 이름을 지정해 실행합니다. 클러스터 안의 listener 파드가 GitHub로 나가는 HTTPS 연결을 열어 작업을 받아 오므로, 로컬 네트워크 전용 클러스터에서도 포트포워딩, 도메인, SSL 인증서 없이 동작합니다.

1. 액세스 토큰 발급
2. 스크립트 내려받기
3. 스크립트 실행
4. 워크플로우에서 실행

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Kubernetes | `v1.37` |
| Helm | `4.3` |
| Actions Runner Controller | `0.14.2 (Helm 차트)` |
| 작성 기준일 | `2026-09-20` |

다음 항목이 준비되어 있어야 합니다.

- `kubectl`로 접근할 수 있는 쿠버네티스 클러스터 (만드는 방법은 [Proxmox에 kubeadm으로 쿠버네티스 클러스터 설치하는 방법](/posts/32/) 참고)
- 클러스터 노드에서 인터넷으로 나가는 HTTPS(443) 연결
- 러너를 등록할 저장소 또는 조직의 관리자 권한

## 1. 액세스 토큰 발급

ARC가 러너를 등록할 때 사용할 fine-grained 토큰을 발급합니다.

1. GitHub 우측 상단 프로필 > **Settings** > **Developer settings** > **Personal access tokens** > **Fine-grained tokens**로 이동
2. **Generate new token** 클릭
3. **Resource owner**에서 러너를 등록할 계정 또는 조직 선택
4. **Repository access**에서 **Only select repositories**를 고르고 러너를 등록할 저장소 선택 (조직 러너는 **All repositories**)
5. **Permissions**에서 아래 표의 권한을 추가한 뒤 **Generate token** 클릭

| 러너 범위 | 필요한 권한 |
| :--- | :--- |
| 저장소 | Repository permissions의 `Administration: Read and write` |
| 조직 | Repository permissions의 `Administration: Read-only`, Organization permissions의 `Self-hosted runners: Read and write` |

- **확인:** `github_pat_`로 시작하는 토큰이 표시되며, 이 화면을 벗어나면 다시 볼 수 없으므로 복사해 둠

## 2. 스크립트 내려받기

control plane에 SSH로 접속해 스크립트를 내려받습니다.

```bash
# control plane 접속 후 설치 스크립트 내려받기
ssh ubuntu@[CP_IP]
wget https://eu4ng.github.io/assets/scripts/kubernetes/install-arc.sh
```

<details markdown="1">
<summary>스크립트 전문 보기</summary>

```bash
#!/usr/bin/env bash
#
# 쿠버네티스 클러스터에 Actions Runner Controller(ARC)를 Helm 으로 설치하고 GitHub Actions self-hosted runner 를 등록합니다.
# kubectl 로 클러스터에 접근할 수 있는 곳(예: control plane)에서 실행합니다: bash install-arc.sh [GITHUB_CONFIG_URL]
#   저장소 러너: https://github.com/[OWNER]/[REPO]
#   조직 러너:   https://github.com/[ORG]

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
RUNNER_NAME=arc-runner-set   # 워크플로우의 runs-on 에 적을 이름
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
[[ "$GITHUB_CONFIG_URL" == https://github.com/* ]] || die "사용법: bash install-arc.sh https://github.com/[OWNER]/[REPO]"
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
log "러너 스케일 셋 설치 ($GITHUB_CONFIG_URL)"
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
```
{: file="install-arc.sh" }

</details>

- **확인:** 현재 폴더에 `install-arc.sh` 파일 생성

## 3. 스크립트 실행

러너를 등록할 주소를 인자로 넘겨 실행하고, 토큰을 묻는 프롬프트에 1단계의 토큰을 붙여 넣습니다. 입력한 토큰은 화면에 표시되지 않습니다.

```bash
# 저장소 러너: https://github.com/[OWNER]/[REPO]
# 조직 러너:   https://github.com/[ORG]
bash install-arc.sh [GITHUB_CONFIG_URL]
```

스크립트를 실행하면 아래 작업이 순서대로 진행됩니다.

1. Helm이 없으면 설치
2. ARC 컨트롤러를 `arc-systems` 네임스페이스에 설치
3. 토큰을 `arc-runners` 네임스페이스의 Secret으로 저장
4. 러너 스케일 셋 `arc-runner-set`을 설치하고, GitHub에 등록되어 listener 파드가 실행될 때까지 대기

> 러너 스케일 셋의 이름이 곧 워크플로우의 `runs-on`에 적는 이름입니다. 바꾸려면 실행하기 전에 스크립트 맨 위의 `RUNNER_NAME`을 고칩니다.
{: .prompt-warning }

- **확인:** 마지막에 `runs-on: arc-runner-set`이 출력되고, GitHub 저장소(또는 조직)의 **Settings** > **Actions** > **Runners**에 `arc-runner-set` 표시

## 4. 워크플로우에서 실행

저장소에 아래 워크플로우를 추가하고, **Actions** 탭에서 **ARC Test** > **Run workflow**로 실행합니다. 러너 파드에 Docker 데몬이 함께 실행되므로 `docker` 명령과 컨테이너 액션도 그대로 쓸 수 있습니다.

```yaml
name: ARC Test

on:
  workflow_dispatch:

jobs:
  test:
    runs-on: arc-runner-set
    steps:
      - run: docker version
```
{: file=".github/workflows/arc-test.yml" }

워크플로우가 실행되는 동안 control plane에서 러너 파드를 확인합니다.

```bash
# 러너 파드가 생겼다가 사라지는 과정 지켜보기
kubectl get pods -n arc-runners -w
```

- **확인:** 작업이 시작되면 `arc-runner-set-`으로 시작하는 파드가 만들어지고, 워크플로우가 성공한 뒤 파드가 삭제됨

## 마무리

스크립트 하나로 ARC를 설치해, 평소에는 러너가 없다가 워크플로우가 실행될 때만 러너 파드가 만들어지는 구성을 완성했습니다. Docker를 쓰기 위해 러너 파드가 특권(privileged) 모드로 실행되므로 신뢰할 수 있는 저장소에만 연결해야 합니다. 또한 ARC는 Helm으로 CRD를 업그레이드할 수 없어, 버전을 올릴 때는 러너 스케일 셋과 컨트롤러를 제거한 뒤 다시 설치해야 합니다.

## 참고 자료

- [Quickstart for Actions Runner Controller](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/quickstart)
- [Deploying runner scale sets with Actions Runner Controller](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)
- [Authenticating ARC to the GitHub API](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/authenticate-to-the-api)
- [Actions Runner Controller release 0.14.0](https://github.blog/changelog/2026-03-19-actions-runner-controller-release-0-14-0/)
- [actions/actions-runner-controller](https://github.com/actions/actions-runner-controller)
