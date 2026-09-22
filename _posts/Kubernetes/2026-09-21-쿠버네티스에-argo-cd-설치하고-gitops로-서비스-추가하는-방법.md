---
layout: post
title: 쿠버네티스에 Argo CD 설치하고 GitOps로 서비스 추가하는 방법
description: 스크립트 하나로 Argo CD를 설치하고 GitHub 저장소를 연결해, 저장소에 폴더를 추가하고 push하는 것만으로 쿠버네티스에 서비스가 배포되는 GitOps 구성을 만드는 방법을 정리했습니다.
author: Eu4ng
tags: [kubernetes, argo-cd, gitops, helm, github]
permalink: /posts/36/
---

GitHub에 매니페스트 저장소를 만들고, control plane에서 스크립트를 실행해 **Argo CD**를 설치하고 저장소를 연결한 뒤, 저장소에 폴더를 추가해 첫 서비스를 배포합니다. 공식 문서처럼 서비스마다 Application을 만들지 않고, 저장소의 `services/` 아래 폴더마다 Application을 자동으로 만들어 주는 **ApplicationSet**을 등록하므로 이후에는 폴더를 추가하고 push하는 것이 서비스 추가의 전부입니다.

1. GitOps 저장소 만들기
2. 스크립트 내려받기
3. 스크립트 실행
4. 첫 서비스 추가

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Kubernetes | `v1.37` |
| Helm | `4.3` |
| Argo CD | `v3.5 (Helm 차트 10.9.2)` |
| 작성 기준일 | `2026-09-21` |

다음 항목이 준비되어 있어야 합니다.

- `kubectl`로 접근할 수 있는 쿠버네티스 클러스터 (만드는 방법은 [Proxmox에 kubeadm으로 쿠버네티스 클러스터 설치하는 방법](/posts/32/) 참고)
- 클러스터 노드에서 인터넷으로 나가는 HTTPS(443)와 SSH(22) 연결
- 내 PC에 `git`과 GitHub CLI

```bash
# GitHub CLI 설치 후 로그인
sudo apt install gh
gh auth login
```

## 1. GitOps 저장소 만들기

클러스터에 배포할 매니페스트를 모아 둘 GitHub 저장소를 만듭니다. 매니페스트는 클러스터의 상태 그 자체이므로 비공개 저장소로 만듭니다.

```bash
# 비공개 저장소를 만들고 내 PC에 복제
gh repo create [OWNER]/k8s-gitops --private --clone
```

저장소는 아래 규칙으로 씁니다. 폴더 이름이 Argo CD의 Application 이름이자 배포되는 네임스페이스가 됩니다.

```text
services/[이름]/   # 폴더 하나가 서비스 하나. 일반 매니페스트(*.yaml), kustomization.yaml, 또는 Chart.yaml(Helm)
```

- **확인:** 내 PC에 빈 `k8s-gitops` 폴더 생성

## 2. 스크립트 내려받기

control plane에 SSH로 접속해 스크립트를 내려받습니다.

```bash
# control plane 접속 후 설치 스크립트 내려받기
ssh ubuntu@[CP_IP]
wget https://eu4ng.github.io/assets/scripts/kubernetes/install-argocd.sh
```

<details markdown="1">
<summary>스크립트 전문 보기</summary>

{% raw %}
```bash
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
# 폴더의 내용이 일반 매니페스트, kustomization.yaml, Chart.yaml(Helm) 중 무엇인지는 Argo CD 가 알아서 판단합니다.
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
          - ServerSideApply=true   # kube-prometheus-stack 처럼 CRD 가 큰 차트도 적용되게 합니다
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
```
{: file="install-argocd.sh" }
{% endraw %}

</details>

- **확인:** 현재 폴더에 `install-argocd.sh` 파일 생성

## 3. 스크립트 실행

1단계에서 만든 저장소의 SSH 주소를 인자로 넘겨 실행합니다.

```bash
# Argo CD 설치와 저장소 연결
bash install-argocd.sh git@github.com:[OWNER]/k8s-gitops.git
```

스크립트를 실행하면 아래 작업이 순서대로 진행됩니다.

1. Helm이 없으면 설치
2. Argo CD를 `argocd` 네임스페이스에 설치하고 웹 UI를 NodePort `30081`로 개방
3. 저장소를 읽을 SSH 키를 만들고 공개 키를 출력한 뒤 대기
4. Enter를 누르면 저장소 연결 정보를 Secret으로 저장하고 ApplicationSet 등록

3단계에서 공개 키가 출력되면, GitHub 저장소의 **Settings** > **Deploy keys** > **Add deploy key**에서 **Key**에 붙여 넣고 **Add key**를 클릭합니다. **Allow write access**는 체크하지 않습니다. Argo CD는 저장소를 읽기만 하므로 이 저장소 하나에만 유효한 읽기 전용 키로 충분하며, 액세스 토큰과 달리 만료되지 않습니다. 등록한 뒤 터미널로 돌아와 Enter를 누릅니다.

- **확인:** 마지막에 접속 주소와 `admin` 비밀번호가 출력되고, 브라우저에서 `http://[NODE_IP]:30081`에 로그인하면 빈 **Applications** 화면 표시

## 4. 첫 서비스 추가

첫 서비스로 **local-path-provisioner**를 배포합니다. kubeadm으로 만든 클러스터에는 StorageClass가 없어 PVC를 쓰는 서비스를 올릴 수 없으므로, 노드의 디스크를 PV로 내어 주는 이 프로비저너를 기본 StorageClass로 등록합니다. 내 PC의 저장소 폴더에서 공식 매니페스트를 내려받고, 기본 StorageClass로 지정하는 `kustomization.yaml`을 함께 둡니다.

```bash
# 서비스 폴더를 만들고 공식 매니페스트 내려받기
cd k8s-gitops
mkdir -p services/local-path-storage
wget -O services/local-path-storage/local-path-storage.yaml \
  https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
```

```yaml
resources:
  - local-path-storage.yaml

patches:
  # local-path 를 기본 StorageClass 로 지정해 storageClassName 이 없는 PVC 도 붙게 합니다.
  - patch: |
      apiVersion: storage.k8s.io/v1
      kind: StorageClass
      metadata:
        name: local-path
        annotations:
          storageclass.kubernetes.io/is-default-class: "true"
```
{: file="services/local-path-storage/kustomization.yaml" }

폴더 이름이 곧 네임스페이스이므로, 매니페스트에 네임스페이스가 없으면 폴더 이름의 네임스페이스가 만들어져 그곳에 배포됩니다. 이 매니페스트는 `local-path-storage` 네임스페이스를 직접 만들기 때문에 폴더 이름을 그에 맞췄습니다.

```bash
# 커밋하고 push
git add services
git commit -m "feat: local-path-provisioner 를 기본 StorageClass 로 추가"
git push
```

> Argo CD는 저장소를 3분마다 확인하므로 push 후 반영까지 시간이 걸립니다. 바로 반영하려면 웹 UI의 **Refresh**를 클릭합니다.
{: .prompt-info }

- **확인:** 웹 UI에 `local-path-storage` Application이 생겨 **Synced**, **Healthy**로 표시되고, control plane의 `kubectl get sc`에 `local-path (default)` 표시

## 마무리

스크립트 하나로 Argo CD를 설치하고 저장소를 연결해, `services/` 아래에 폴더를 추가하고 push하면 몇 분 안에 클러스터에 배포되는 구성을 완성했습니다. 이후 서비스는 4단계만 반복하면 되고, 매니페스트를 고쳐 push하면 그대로 반영되며 UI에서 손으로 바꾼 부분도 저장소 내용으로 되돌아갑니다. 폴더를 지우면 Application은 사라지지만 배포된 자원은 남도록 설정했으므로, 서비스를 완전히 걷어낼 때는 네임스페이스를 직접 삭제합니다. 웹 UI는 HTTP로 열려 있으니 로컬 네트워크 안에서만 쓰고, 첫 로그인 뒤 **User Info**에서 비밀번호를 바꿉니다.

다음 글에서는 이 구성 위에 [Ollama 서버](/posts/37/)와 [MinerU 파싱 서버](/posts/38/)를 추가합니다.

## 참고 자료

- [Argo CD - Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/)
- [Argo CD - Git Generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/)
- [Argo CD - Private Repositories](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/)
- [argoproj/argo-helm - argo-cd](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
- [rancher/local-path-provisioner](https://github.com/rancher/local-path-provisioner)
- [GitHub Docs - Managing deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)
