---
layout: post
title: 쿠버네티스에 GitHub Actions Self-hosted Runner 등록하는 방법
description: 스크립트 하나로 Actions Runner Controller를 설치해, 워크플로우가 실행될 때만 러너 파드가 만들어지는 self-hosted runner를 쿠버네티스에 등록하는 방법을 정리했습니다.
author: Eu4ng
tags: [github, actions, self-hosted-runner, kubernetes, helm]
---

GitHub에서 액세스 토큰을 발급하고, control plane에서 스크립트를 실행해 GitHub 공식 도구인 **Actions Runner Controller**(ARC)를 설치한 뒤, 워크플로우의 `runs-on`에 러너 이름을 지정해 실행합니다. 러너는 CPU와 메모리가 다른 `arc-linux-low`, `arc-linux-medium`, `arc-linux-high` 세 종류가 설치되며, 작업의 무게에 맞춰 골라 씁니다. 클러스터 안의 listener 파드가 GitHub로 나가는 HTTPS 연결을 열어 작업을 받아 오므로, 로컬 네트워크 전용 클러스터에서도 포트포워딩, 도메인, SSL 인증서 없이 동작합니다.

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

- `kubectl`로 접근할 수 있는 쿠버네티스 클러스터 (v1.34 이상, 만드는 방법은 [Proxmox에 kubeadm으로 쿠버네티스 클러스터 설치하는 방법](/posts/32/) 참고)
- 클러스터 노드에서 인터넷으로 나가는 HTTPS(443) 연결
- 러너를 등록할 개인 계정의 저장소 또는 조직 계정의 관리자 권한

## 1. 액세스 토큰 발급

ARC가 러너를 등록할 때 사용할 fine-grained 토큰을 발급합니다.

1. GitHub 우측 상단 프로필 > **Settings** > **Developer settings** > **Personal access tokens** > **Fine-grained tokens**로 이동
2. **Generate new token** 클릭
3. **Token name**에 용도를 알 수 있는 이름 입력 (예: `k8s-arc-runner`)
4. **Resource owner**에서 러너를 등록할 개인 계정 또는 조직 계정 선택
5. **Repository access**에서 **All repositories** 선택
6. **Permissions**의 **Add permissions**에서 아래 표의 권한을 추가하고 접근 수준을 표와 같이 변경
7. **Generate token** 클릭

| Resource owner | 탭 | 권한 | 접근 수준 |
| :--- | :--- | :--- | :--- |
| 개인 계정 | **Repositories** | Administration | Read and write |
| 조직 계정 | **Repositories** | Administration | Read-only |
| 조직 계정 | **Organizations** | Self-hosted runners | Read and write |

`Metadata: Read-only`는 자동으로 추가되는 필수 권한이므로 그대로 둡니다. 개인 계정에는 계정 단위 러너가 없어 저장소 단위로만 등록할 수 있습니다. 여러 저장소에서 쓰려면 저장소마다 3단계를 주소만 바꿔 반복합니다.

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
#   개인 계정: https://github.com/[OWNER]/[REPO]
#   조직 계정: https://github.com/[ORG]

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
ARC_VERSION=0.14.2           # 두 Helm 차트의 버전
# 러너 종류: "이름 CPU 메모리 [CPU상한 메모리상한]". 줄을 추가·수정·삭제한 뒤 스크립트를 다시 실행하면 그대로 반영됩니다.
# CPU 와 메모리는 러너 파드 하나가 보장받는 자원이며, 상한을 생략하면 보장값과 같습니다. 가장 큰 worker 의 사양보다 작아야 합니다.
RUNNERS=(
  "arc-linux-low     2  4Gi"
  "arc-linux-medium  4  8Gi"
  "arc-linux-high    8 16Gi"
)
# --------------------------------------

HELM_INSTALL_URL=https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
CHART_BASE=oci://ghcr.io/actions/actions-runner-controller-charts
CONTROLLER_NS=arc-systems
TOKEN_SECRET=arc-github-token

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR
TEMPLATE_VALUES=$(mktemp)
trap 'rm -f "$TEMPLATE_VALUES"' EXIT

# ---------- 1. 사전 검사 ----------
log "사전 검사"
GITHUB_CONFIG_URL=${1:-}
GITHUB_CONFIG_URL=${GITHUB_CONFIG_URL%/}
[[ "$GITHUB_CONFIG_URL" == https://github.com/?* ]] || die "사용법: bash install-arc.sh https://github.com/[OWNER]/[REPO]"
kubectl get nodes >/dev/null || die "kubectl 로 클러스터에 접근할 수 없습니다."

# 러너 목록 형식 검사
[ "${#RUNNERS[@]}" -gt 0 ] || die "RUNNERS 가 비어 있습니다."
for runner in "${RUNNERS[@]}"; do
  read -r name cpu mem cpu_limit mem_limit extra <<<"$runner"
  { [ -n "${mem:-}" ] && [ -z "${extra:-}" ] && { [ -z "${cpu_limit:-}" ] || [ -n "${mem_limit:-}" ]; }; } \
    || die "RUNNERS 의 각 줄은 \"이름 CPU 메모리\" 또는 \"이름 CPU 메모리 CPU상한 메모리상한\" 이어야 합니다: $runner"
  [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#name} -le 45 ]] \
    || die "러너 이름은 소문자, 숫자, 하이픈으로 45자 이하여야 합니다: $name"
done

# 저장소(또는 조직)마다 네임스페이스를 나눠, 모든 저장소에서 같은 러너 이름을 쓸 수 있게 합니다.
slug=$(basename "$GITHUB_CONFIG_URL" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//' | cut -c1-51 | sed -E 's/-+$//')
[ -n "$slug" ] || die "주소에서 저장소 또는 조직 이름을 찾을 수 없습니다: $GITHUB_CONFIG_URL"
RUNNER_NS=arc-runners-$slug

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
log "토큰 Secret 생성 ($RUNNER_NS)"
kubectl create namespace "$RUNNER_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic "$TOKEN_SECRET" --namespace "$RUNNER_NS" \
  --from-literal=github_token="$GITHUB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------- 6. 목록에서 빠진 러너 제거 ----------
names=" "
for runner in "${RUNNERS[@]}"; do
  read -r name _ <<<"$runner"
  names+="$name "
done
for release in $(helm list --namespace "$RUNNER_NS" --short); do
  [[ "$names" != *" $release "* ]] || continue
  log "목록에 없는 러너 제거 ($release)"
  helm uninstall "$release" --namespace "$RUNNER_NS" --wait
done

# ---------- 7. 러너 스케일 셋 ----------
# 러너 파드에 Docker 데몬(dind)을 함께 띄워 워크플로우에서 docker 명령과 컨테이너를 쓸 수 있게 합니다.
# 차트의 containerMode.type=dind 가 만드는 파드 템플릿과 같으며, dind 의 실행 부분만 다릅니다.
# dind 는 기본값으로 작업 컨테이너를 파드 밖(노드의 /docker cgroup)에 만들어 자원 상한이 걸리지 않으므로,
# --cgroup-parent 로 이 파드의 cgroup 아래에 만들게 합니다.
cat > "$TEMPLATE_VALUES" <<'VALUES'
template:
  spec:
    initContainers:
      - name: init-dind-externals
        image: ghcr.io/actions/actions-runner:latest
        command: ["cp", "-r", "/home/runner/externals/.", "/home/runner/tmpDir/"]
        volumeMounts:
          - name: dind-externals
            mountPath: /home/runner/tmpDir
      - name: dind
        image: docker:dind
        command: ["sh", "-c"]
        args:
          - |
            pod_cgroup=$(dirname "$(sed -n 's/^0:://p' /proc/self/cgroup)")
            case "$pod_cgroup" in /?*) set -- --cgroup-parent="$pod_cgroup/docker" ;; esac
            exec dockerd-entrypoint.sh dockerd --host=unix:///var/run/docker.sock --group="$DOCKER_GROUP_GID" "$@"
        env:
          - name: DOCKER_GROUP_GID
            value: "123"
        securityContext:
          privileged: true
        restartPolicy: Always
        startupProbe:
          exec:
            command: ["docker", "info"]
          initialDelaySeconds: 0
          failureThreshold: 24
          periodSeconds: 5
        volumeMounts:
          - name: work
            mountPath: /home/runner/_work
          - name: dind-sock
            mountPath: /var/run
          - name: dind-externals
            mountPath: /home/runner/externals
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
        command: ["/home/runner/run.sh"]
        env:
          - name: DOCKER_HOST
            value: unix:///var/run/docker.sock
          - name: RUNNER_WAIT_FOR_DOCKER_IN_SECONDS
            value: "120"
        volumeMounts:
          - name: work
            mountPath: /home/runner/_work
          - name: dind-sock
            mountPath: /var/run
    volumes:
      - name: work
        emptyDir: {}
      - name: dind-sock
        emptyDir: {}
      - name: dind-externals
        emptyDir: {}
VALUES

# 자원은 파드 단위(쿠버네티스 1.34 이상)로 지정해 러너, Docker 데몬, 작업 컨테이너가 한 예산을 같이 씁니다.
for runner in "${RUNNERS[@]}"; do
  read -r name cpu mem cpu_limit mem_limit <<<"$runner"
  log "러너 스케일 셋 설치 ($name: CPU $cpu, 메모리 $mem)"
  helm upgrade --install "$name" "$CHART_BASE/gha-runner-scale-set" \
    --namespace "$RUNNER_NS" \
    --version "$ARC_VERSION" \
    --set githubConfigUrl="$GITHUB_CONFIG_URL" \
    --set githubConfigSecret="$TOKEN_SECRET" \
    --values "$TEMPLATE_VALUES" \
    --set-string template.spec.resources.requests.cpu="$cpu" \
    --set-string template.spec.resources.requests.memory="$mem" \
    --set-string template.spec.resources.limits.cpu="${cpu_limit:-$cpu}" \
    --set-string template.spec.resources.limits.memory="${mem_limit:-$mem}"

  applied=$(kubectl get autoscalingrunnerset "$name" -n "$RUNNER_NS" -o jsonpath='{.spec.template.spec.resources.limits.cpu}')
  [ -n "$applied" ] || die "$name 에 자원 설정이 적용되지 않았습니다. 쿠버네티스 1.34 이상인지 확인합니다."
  kubectl get autoscalingrunnerset "$name" -n "$RUNNER_NS" -o jsonpath='{.spec.template.spec.initContainers[*].args}' | grep -q cgroup-parent \
    || die "$name 의 Docker 데몬 설정이 적용되지 않았습니다."
done

# ---------- 8. listener 확인 ----------
# GitHub 에 등록되면 컨트롤러가 러너마다 listener 파드를 만듭니다. 토큰이나 URL 이 틀리면 만들어지지 않습니다.
log "listener 파드 대기"
for runner in "${RUNNERS[@]}"; do
  read -r name _ <<<"$runner"
  selector="actions.github.com/scale-set-name=$name,actions.github.com/scale-set-namespace=$RUNNER_NS"
  phase=
  for _ in $(seq 1 60); do
    phase=$(kubectl get pods -n "$CONTROLLER_NS" -l "$selector" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    [ "$phase" != Running ] || break
    sleep 2
  done
  [ "$phase" = Running ] || die "$name 러너가 등록되지 않았습니다. 토큰 권한과 URL 을 확인합니다: kubectl logs -n $CONTROLLER_NS deploy/arc-gha-rs-controller"
done

log "완료. 워크플로우의 runs-on 에 아래 이름을 지정합니다. (네임스페이스: $RUNNER_NS)"
for runner in "${RUNNERS[@]}"; do
  read -r name cpu mem _ <<<"$runner"
  printf '  runs-on: %-20s # CPU %s, 메모리 %s\n' "$name" "$cpu" "$mem"
done
```
{: file="install-arc.sh" }

</details>

- **확인:** 현재 폴더에 `install-arc.sh` 파일 생성

## 3. 스크립트 실행

러너를 연결할 GitHub 주소 `[GITHUB_CONFIG_URL]`을 인자로 넘겨 실행하고, 토큰을 묻는 프롬프트에 1단계의 토큰을 붙여 넣습니다. 입력한 토큰은 화면에 표시되지 않습니다.

```bash
# ARC 와 러너 설치
bash install-arc.sh [GITHUB_CONFIG_URL]
```

| Resource owner | `[GITHUB_CONFIG_URL]` | 러너를 쓸 수 있는 범위 |
| :--- | :--- | :--- |
| 개인 계정 | `https://github.com/[OWNER]/[REPO]` | 해당 저장소 |
| 조직 계정 | `https://github.com/[ORG]` | 조직의 모든 저장소 |

브라우저 주소창에 보이는 저장소(또는 조직) 주소와 같습니다. 스크립트를 실행하면 아래 작업이 순서대로 진행됩니다.

1. Helm이 없으면 설치
2. ARC 컨트롤러를 `arc-systems` 네임스페이스에 설치
3. 토큰을 `arc-runners-[저장소 또는 조직 이름]` 네임스페이스의 Secret으로 저장
4. 아래 표의 러너 세 종류를 설치하고, GitHub에 등록되어 listener 파드가 실행될 때까지 대기

| `runs-on` | CPU | 메모리 |
| :--- | :--- | :--- |
| `arc-linux-low` | 2 | 4Gi |
| `arc-linux-medium` | 4 | 8Gi |
| `arc-linux-high` | 8 | 16Gi |

러너 파드 하나가 쓰는 자원이며, 이 값만큼 보장받고 그 이상은 쓰지 못합니다. 워크플로우의 `container`와 `docker` 명령으로 실행한 컨테이너에도 같은 상한이 적용됩니다. 종류와 값은 스크립트 맨 위의 `RUNNERS` 목록에서 줄을 추가, 수정, 삭제하고 다시 실행하면 바뀝니다.

> 자원이 들어갈 노드가 없으면 러너 파드는 `Pending` 상태로 대기하고 워크플로우도 시작되지 않습니다. 가장 큰 worker의 사양보다 작게 잡습니다.
{: .prompt-warning }

- **확인:** 마지막에 세 러너의 이름과 자원이 출력되고, GitHub 저장소(조직 계정은 조직)의 **Settings** > **Actions** > **Runners**에 러너 세 개 표시

## 4. 워크플로우에서 실행

저장소에 아래 워크플로우를 추가하고, **Actions** 탭에서 **ARC Test** > **Run workflow**로 실행합니다. 러너 종류마다 2개씩 작업 6개가 동시에 시작되어, 프로세스 8개로 같은 양의 CPU 연산을 하고 걸린 시간을 출력합니다. 러너 이미지에는 git과 docker 정도만 들어 있으므로, 필요한 도구는 `container`에 이미지를 지정해 준비합니다.

{% raw %}
```yaml
name: ARC Test

on:
  workflow_dispatch:

jobs:
  benchmark:
    strategy:
      matrix:
        runner: [arc-linux-low, arc-linux-medium, arc-linux-high]
        run: [1, 2]
    runs-on: ${{ matrix.runner }}
    container: python:3.13-slim
    steps:
      - name: 프로세스 8개로 같은 양의 CPU 연산 실행
        shell: python
        run: |
          import multiprocessing as mp, time

          def work(_):
              return sum(i * i for i in range(200_000_000))

          if __name__ == "__main__":
              start = time.perf_counter()
              with mp.Pool(8) as pool:
                  pool.map(work, range(8))
              print(f"걸린 시간: {time.perf_counter() - start:.1f}초")
```
{: file=".github/workflows/arc-test.yml" }
{% endraw %}

워크플로우가 실행되는 동안 control plane에서 러너 파드를 확인합니다.

```bash
# 러너 파드가 생겼다가 사라지는 과정 지켜보기
kubectl get pods -n arc-runners-[REPO] -w
```

- **확인:** 걸린 시간이 `high`, `medium`, `low` 순으로 약 1 : 2 : 4이고 같은 종류의 두 작업은 비슷함. 자원이 모자란 파드는 `Pending`으로 대기하다가 앞 작업이 끝나면 시작되고, 워크플로우가 끝나면 파드가 모두 삭제됨

## 마무리

스크립트 하나로 ARC를 설치해, 평소에는 러너가 없다가 워크플로우가 실행될 때만 정해진 크기의 러너 파드가 만들어지는 구성을 완성했습니다. Docker를 쓰기 위해 러너 파드가 특권(privileged) 모드로 실행되므로 신뢰할 수 있는 저장소에만 연결해야 합니다. 또한 ARC는 Helm으로 CRD를 업그레이드할 수 없어, 버전을 올릴 때는 러너 스케일 셋과 컨트롤러를 제거한 뒤 다시 설치해야 합니다.

## 참고 자료

- [Quickstart for Actions Runner Controller](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/quickstart)
- [Deploying runner scale sets with Actions Runner Controller](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)
- [Authenticating ARC to the GitHub API](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/authenticate-to-the-api)
- [Actions Runner Controller release 0.14.0](https://github.blog/changelog/2026-03-19-actions-runner-controller-release-0-14-0/)
- [actions/actions-runner-controller](https://github.com/actions/actions-runner-controller)
