---
layout: post
title: 쿠버네티스에 Prometheus와 Grafana 배포해 자원 사용량 대시보드 만드는 방법
description: GitOps 저장소에 Helm 차트 폴더 하나를 추가해 kube-prometheus-stack과 metrics-server를 배포하고, Grafana에서 클러스터·노드·파드의 CPU·메모리 추이를 며칠 단위로 보는 방법을 정리했습니다.
author: Eu4ng
tags: [kubernetes, prometheus, grafana, metrics-server, argo-cd, gitops, helm]
permalink: /posts/39/
---

GitOps 저장소에 **kube-prometheus-stack**과 **metrics-server**를 의존 차트로 적은 폴더를 추가하고 push해 배포한 뒤, Grafana에서 자원 사용량 대시보드를 봅니다. Headlamp는 노드 사용량을 현재값으로만 보여 주고 며칠치 추이는 워크로드 화면에만 있어, 클러스터와 노드 단위 추이까지 한 화면에서 보려면 Grafana가 필요합니다. 공식 문서의 `helm install` 대신 폴더에 `Chart.yaml`과 `values.yaml`만 두면 Argo CD가 의존 차트를 직접 내려받아 렌더링하므로, 이전 글에서 만든 GitOps 구성을 그대로 씁니다.

1. ApplicationSet에 Server-Side Apply 켜기
2. Grafana 관리자 비밀번호 Secret 만들기
3. 차트 폴더 추가
4. 배포 확인
5. Grafana에서 사용량 보기

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Kubernetes | `v1.37` |
| Argo CD | `v3.5` |
| kube-prometheus-stack | `91.4.1 (Prometheus v3.14, Grafana 13.2.2)` |
| metrics-server | `0.9.0 (Helm 차트 3.14.0)` |
| 작성 기준일 | `2026-09-22` |

다음 항목이 준비되어 있어야 합니다.

- Argo CD와 기본 StorageClass가 있는 클러스터 ([쿠버네티스에 Argo CD 설치하고 GitOps로 서비스 추가하는 방법](/posts/36/) 참고)
- Prometheus 지표 20Gi와 Grafana 설정 2Gi를 둘 노드 디스크

## 1. ApplicationSet에 Server-Side Apply 켜기

kube-prometheus-stack의 CRD는 `kubectl apply`가 기록하는 annotation 한도(262144바이트)를 넘어 client-side apply가 실패합니다. control plane에서 ApplicationSet의 sync 옵션에 Server-Side Apply를 추가합니다. Argo CD 글의 설치 스크립트에도 반영해 두었으므로 그 글대로 새로 설치했다면 이미 켜져 있습니다.

```bash
# 모든 Application 에 Server-Side Apply 적용
kubectl patch applicationset services -n argocd --type json \
  -p '[{"op":"add","path":"/spec/template/spec/syncPolicy/syncOptions/-","value":"ServerSideApply=true"}]'
```

- **확인:** `kubectl get applicationset services -n argocd -o yaml`의 `syncOptions`에 `ServerSideApply=true` 표시

## 2. Grafana 관리자 비밀번호 Secret 만들기

Grafana 차트는 비밀번호를 지정하지 않으면 렌더링할 때마다 무작위 비밀번호를 새로 만들기 때문에 Argo CD가 sync할 때마다 Secret이 바뀝니다. control plane에서 비밀번호를 입력받아 `monitoring` 네임스페이스에 Secret을 미리 만듭니다. 네임스페이스는 Argo CD가 만들기 전에 미리 만들어도 그대로 씁니다.

```bash
# 비밀번호를 입력받아 (화면에 표시되지 않음) Grafana 관리자 Secret 생성
read -rsp "Grafana admin 비밀번호: " GRAFANA_PASSWORD; echo
kubectl create namespace monitoring
kubectl create secret generic grafana-admin -n monitoring \
  --from-literal=admin-user=admin --from-literal=admin-password="$GRAFANA_PASSWORD"
unset GRAFANA_PASSWORD
```

- **확인:** `kubectl get secret grafana-admin -n monitoring`에 `Opaque` 타입 Secret 표시

## 3. 차트 폴더 추가

GitOps 저장소의 `services/monitoring/` 폴더에 `Chart.yaml`과 `values.yaml`을 넣습니다. Argo CD는 폴더에 `Chart.yaml`이 있으면 Helm 차트로 인식하고, 의존 차트를 `helm dependency build`로 내려받아 렌더링합니다. 폴더 이름을 따라 `monitoring` 네임스페이스에 배포됩니다.

```yaml
# 자원 사용량 모니터링. Argo CD 가 Chart.yaml 을 보고 Helm 으로 렌더링하며 의존 차트를 직접 내려받습니다.
apiVersion: v2
name: monitoring
version: 0.1.0
dependencies:
  - name: kube-prometheus-stack    # Prometheus Operator + Prometheus + Grafana + node-exporter + kube-state-metrics
    version: 91.4.1
    repository: https://prometheus-community.github.io/helm-charts
  - name: metrics-server           # kubectl top, Headlamp 현재값, HPA 가 쓰는 metrics.k8s.io API
    version: 3.14.0
    repository: https://kubernetes-sigs.github.io/metrics-server/
```
{: file="services/monitoring/Chart.yaml" }

```yaml
kube-prometheus-stack:
  # kubeadm 은 controller-manager·scheduler·etcd·kube-proxy 지표를 127.0.0.1 에만 열어 수집할 수 없으므로 끕니다.
  kubeControllerManager: { enabled: false }
  kubeScheduler: { enabled: false }
  kubeEtcd: { enabled: false }
  kubeProxy: { enabled: false }
  alertmanager: { enabled: false }               # 알림을 보낼 곳이 없습니다
  prometheusOperator:
    admissionWebhooks: { enabled: false }        # 인증서 생성 Job 과 caBundle 패치가 Argo CD 와 계속 어긋나므로 끕니다
    tls: { enabled: false }                      # webhook 을 끄면 함께 꺼야 operator 가 인증서 Secret 을 찾지 않습니다
  prometheus:
    prometheusSpec:
      retention: 15d
      storageSpec:                               # 기본값은 emptyDir 라 파드가 다시 뜨면 지표가 사라집니다
        volumeClaimTemplate:
          spec:
            accessModes: [ReadWriteOnce]
            resources: { requests: { storage: 20Gi } }
  grafana:
    admin: { existingSecret: grafana-admin }     # 차트가 만드는 무작위 비밀번호는 sync 마다 바뀌므로 미리 만든 Secret 을 씁니다
    service: { type: NodePort, nodePort: 30082 }
    persistence: { enabled: true, size: 2Gi }    # 직접 만든 대시보드와 설정을 보존합니다
metrics-server:
  args: [--kubelet-insecure-tls]                 # kubeadm 의 kubelet 인증서는 자체 서명입니다
```
{: file="services/monitoring/values.yaml" }

값은 의존 차트 이름 아래에 그 차트의 values를 그대로 적습니다. kubeadm 클러스터는 controller-manager, scheduler, etcd, kube-proxy의 지표 포트를 `127.0.0.1`에만 열어 두므로 수집 대상에서 빼지 않으면 Prometheus에 실패한 대상이 계속 남습니다. Prometheus 저장소는 기본값이 `emptyDir`라 PVC를 지정해야 파드가 다시 떠도 지표가 남고, `retention`이 보관 기간입니다. metrics-server는 kubeadm의 kubelet 인증서가 자체 서명이라 `--kubelet-insecure-tls` 없이는 노드 지표를 읽지 못합니다.

```bash
# 커밋하고 push
git add services/monitoring
git commit -m "feat: monitoring 서비스 추가"
git push
```

- **확인:** 몇 분 안에 Argo CD 웹 UI에 `monitoring` Application이 생기고 **Progressing**으로 표시

## 4. 배포 확인

control plane에서 파드가 모두 `Running`이 될 때까지 지켜봅니다. 이미지를 내려받는 시간이 필요하며, 파드 7개가 약 3분 안에 준비되었습니다.

```bash
# 파드 상태 지켜보기
kubectl get pods -n monitoring -w

# metrics-server 동작 확인
kubectl top nodes
```

> Argo CD 웹 UI에서 `monitoring` Application이 **Synced**, **Healthy**로 표시된 뒤 10분 이상 **OutOfSync**로 되돌아가지 않는지 확인합니다. Helm 차트가 렌더링할 때마다 값이 바뀌는 자원이 있으면 self-heal이 반복되며, 이 글의 values는 그런 자원을 끄거나 미리 만든 Secret으로 대체했습니다.
{: .prompt-warning }

- **확인:** `kubectl top nodes`에 두 노드의 CPU·메모리 사용량과 백분율 표시. `kubectl get pvc -n monitoring`에 Prometheus 20Gi와 Grafana 2Gi PVC가 `Bound`. Headlamp의 클러스터 개요에 CPU·메모리 사용량 게이지 표시

## 5. Grafana에서 사용량 보기

내 PC의 브라우저에서 `http://[NODE_IP]:30082`에 접속해 `admin`과 2단계에서 입력한 비밀번호로 로그인합니다. kube-prometheus-stack이 대시보드를 함께 넣어 주므로 따로 만들 것이 없습니다.

1. 왼쪽 메뉴의 **Dashboards** 클릭
2. 아래 대시보드를 엽니다
   - **Kubernetes / Compute Resources / Cluster**: 클러스터 전체와 네임스페이스별 CPU·메모리
   - **Node Exporter / Nodes**: 노드별 CPU·메모리·디스크·네트워크
   - **Kubernetes / Compute Resources / Pod**: 파드 하나의 CPU·메모리와 요청·상한 대비
3. 오른쪽 위의 시간 범위에서 `Last 7 days`처럼 구간 선택

> Grafana와 Headlamp 모두 암호화되지 않은 HTTP로 열려 있고 Prometheus는 클러스터의 모든 지표를 담고 있습니다. 신뢰할 수 있는 내부 네트워크에서만 사용하고 포트를 외부에 열지 않습니다.
{: .prompt-danger }

- **확인:** 각 대시보드에 그래프가 그려지고, 시간 범위를 넓히면 Prometheus가 배포된 시점부터의 추이 표시

## 마무리

GitOps 저장소에 폴더 하나를 추가해 Prometheus, Grafana, metrics-server를 배포하고, Grafana에서 클러스터·노드·파드의 사용량 추이를 보는 구성을 완성했습니다. Argo CD는 `Chart.yaml`만 있으면 Helm 차트도 일반 매니페스트와 같은 방식으로 받아 주므로, 이후 Helm으로 배포하는 서비스도 같은 폴더 규칙으로 추가할 수 있습니다. Headlamp는 Prometheus를 자동으로 찾아 Pod와 Deployment 상세 화면에 CPU·메모리·네트워크·디스크 그래프를 붙이지만, 노드와 클러스터 단위 추이는 Grafana에서만 볼 수 있습니다.

## 참고 자료

- [kube-prometheus-stack Helm 차트](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [metrics-server Helm 차트](https://github.com/kubernetes-sigs/metrics-server/tree/master/charts/metrics-server)
- [Argo CD - Helm](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/)
- [Argo CD - Sync Options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/)
- [Headlamp - Prometheus 플러그인](https://github.com/headlamp-k8s/plugins/tree/main/prometheus)
