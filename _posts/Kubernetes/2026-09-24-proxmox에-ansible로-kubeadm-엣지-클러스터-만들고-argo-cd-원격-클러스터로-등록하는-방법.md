---
layout: post
title: Proxmox에 Ansible로 kubeadm 엣지 클러스터 만들고 Argo CD 원격 클러스터로 등록하는 방법
description: 허브와 같은 kubeadm 플레이북으로 지역 엣지 클러스터(control plane 2 + worker 2, API VIP, 서비스 VIP)를 만들고, etcd 세 번째 투표자와 Longhorn 기본 StorageClass 를 붙인 뒤 허브의 Argo CD 에 원격 클러스터로 등록해 GitOps 저장소의 지역 폴더가 그 클러스터로 배포되게 하는 방법을 정리했습니다.
author: Eu4ng
tags: [proxmox, ansible, kubeadm, kubernetes, kube-vip, longhorn, argo-cd, gitops, edge]
permalink: /posts/42/
---

허브 클러스터를 만든 플레이북 `k8s-cluster.yml` 에 지역 하나를 더 적어 **지역 엣지 클러스터**를 만들고, 허브의 **Argo CD** 에 원격 클러스터로 등록합니다. 엣지를 허브의 worker 로 붙이지 않고 별도 클러스터로 두는 이유는, [허브나 인터넷이 끊겨도](/posts/62/) 지역 안의 수집·제어가 자체 control plane 으로 계속 돌아야 하기 때문입니다. 엣지는 control plane 두 대와 worker 두 대를 두 Proxmox 노드에 나눠 두고, etcd 세 번째 투표자를 원격 NAS 컨테이너로 붙여 서버 한 대가 죽어도 버티게 합니다. Argo CD 등록은 API 서버 로그인 대신 CLI 의 core 모드로 쿠버네티스 API 에 직접 써서 비밀번호 없이 끝냅니다.

1. 지역 클러스터 값 추가
2. 플레이북 실행
3. etcd 세 번째 투표자 붙이기
4. Argo CD 에 클러스터 등록
5. 지역 폴더 규칙과 ApplicationSet 추가
6. Longhorn 을 기본 StorageClass 로 배포

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Proxmox VE | `9.2` (노드 2대 클러스터) |
| Ansible | `13.1` (ansible-core `2.20`, community.proxmox `1.4`) |
| Kubernetes | `v1.37.0` (kubeadm, containerd `2.2`) |
| kube-vip | `v1.2.4` |
| Longhorn | `1.12.1` (Helm 차트) |
| Argo CD (허브) | `v3.5.3` |
| 작성 기준일 | `2026-09-27` |

다음 항목이 준비되어 있어야 합니다.

- 두 노드로 묶은 Proxmox 클러스터 ([Proxmox 두 대를 클러스터로 묶고 원격 NAS에 QDevice 붙이는 방법](/posts/53/))
- `proxmox-ansible` 저장소의 `vm-template.yml`·`k8s-cluster.yml` 과 그 플레이북으로 만든 허브 클러스터 ([Proxmox에 Ansible로 kubeadm 쿠버네티스 클러스터 만드는 방법](/posts/46/)). 이 글은 같은 플레이북에 지역을 하나 더 적어 실행하므로 플레이북 전문은 그 글을 봅니다.
- Argo CD 가 설치된 허브 클러스터와 GitOps 저장소 ([쿠버네티스에 Argo CD 설치하고 GitOps로 서비스 추가하는 방법](/posts/36/))
- 엣지용으로 비어 있는 VM ID 4개, 노드 고정 IP 4개, 노드가 쓰지 않는 IP 2개(API VIP, 서비스 VIP)

## 1. 지역 클러스터 값 추가

`group_vars/all.yml` 의 `k8s_clusters` 아래에 지역을 하나 추가합니다. 키 이름(`[SITE]`)이 플레이북의 `-e k8s_cluster=[SITE]` 값이자, 뒤에서 Argo CD 에 등록할 클러스터 이름과 GitOps 저장소의 `iot/clusters/[SITE]/` 폴더 이름이 됩니다.

{% raw %}
```yaml
k8s_clusters:
  hub:
    # ... (허브 클러스터 값)
  [SITE]:                                     # 지역 엣지. 허브 없이 혼자 돕니다(k8s-gitops iot/clusters/[SITE]/)
    nodes:
      - { name: k8s-[SITE_SHORT]-cp-1,     pve: pve01, role: control-plane, vmid: 131, ip: [EDGE_CP1_IP], cores: 2, memory: 2560, disk: 32G }
      - { name: k8s-[SITE_SHORT]-cp-2,     pve: pve02, role: control-plane, vmid: 132, ip: [EDGE_CP2_IP], cores: 2, memory: 2048, disk: 32G }
      - { name: k8s-[SITE_SHORT]-worker-1, pve: pve01, role: worker,        vmid: 133, ip: [EDGE_WORKER1_IP], cores: 4, memory: 4096, disk: 40G, longhorn_disk: 20 }
      - { name: k8s-[SITE_SHORT]-worker-2, pve: pve02, role: worker,        vmid: 134, ip: [EDGE_WORKER2_IP], cores: 2, memory: 3584, disk: 40G, longhorn_disk: 20 }
    dns_name: [SITE_SHORT]                    # 내부망 DNS 역할 이름 k8s-[SITE_SHORT](API VIP), kubectl-[SITE_SHORT], iot-[SITE_SHORT](서비스 VIP)
    vip: [EDGE_API_VIP]                       # API 엔드포인트(kube-vip, ARP). control plane 중 한 대가 가짐
    service_vip: [EDGE_SERVICE_VIP]           # LoadBalancer 서비스 VIP. k8s-gitops iot/clusters/[SITE] 의 kube-vip.io/loadbalancerIPs 와 같아야 함
    lan_dns_names: [ha-[SITE_SHORT], z2m-[SITE_SHORT], matter-[SITE_SHORT], grafana-[SITE_SHORT]]   # 내부망에서 service_vip 로 답할 지역 서비스 이름
    control_plane_workloads: false
    kube_vip_services: true                   # LoadBalancer Service 에 VIP 를 줌(service_vip)
    otbr_host: true                           # OpenThread Border Router(hostNetwork)용 커널 설정
    kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/k8s-[SITE].yaml"
```
{: file="group_vars/all.yml" }
{% endraw %}

- `pve`: VM 을 둘 Proxmox 노드입니다. control plane 과 worker 를 한 대씩 두 노드에 나눠, 어느 서버가 죽어도 control plane 과 worker 가 하나씩 남게 합니다.
- `longhorn_disk`: worker 에 붙는 Longhorn 전용 디스크(GB, `scsi1`, `/var/lib/longhorn`)입니다. 6단계의 Longhorn 이 이 디스크에 볼륨을 두 벌씩 둡니다.
- `service_vip`: 지역의 LoadBalancer Service(Home Assistant, Zigbee2MQTT, Mosquitto, Grafana 등)가 포트만 달리해 함께 쓰는 주소입니다. 각 서비스는 GitOps 저장소의 지역 오버레이에서 `kube-vip.io/loadbalancerIPs` 주석으로 이 주소를 받습니다.
- `lan_dns_names`: 내부망 DNS 가 이 지역의 서비스 VIP 로 답할 이름입니다. 그 이름을 받는 지역 인그레스는 [지역 엣지에 TimescaleDB와 Grafana를 두어 인터넷 없이도 기록하고 보는 방법](/posts/56/)에서 만듭니다.

> 서비스 VIP 는 kube-vip 의 `--services` 만 켜고 `--servicesElection` 은 쓰지 않습니다. 플레이북(`playbooks/tasks/kube-vip.yml`)도 그렇게 만듭니다. 서비스별 선출을 켜면 서비스마다 리더를 따로 뽑아, 여러 서비스가 한 IP 를 나눠 쓸 때 그 IP 가 두 노드에 동시에 붙습니다. [ARP 응답이 엇갈려](/posts/69/) 서비스 VIP 로 가는 연결이 간헐적으로 끊깁니다.
{: .prompt-warning }

- **확인:** `ansible-inventory --graph` 가 오류 없이 끝나고, `ansible localhost -m debug -a "var=k8s_clusters.[SITE].vip"` 이 `[EDGE_API_VIP]` 를 출력합니다.

## 2. 플레이북 실행

허브와 같은 플레이북을 지역 이름만 바꿔 실행합니다. 플레이북은 노드마다 `pve` 에 적은 Proxmox 노드의 템플릿을 복제해 VM 을 만들고, 첫 control plane 에서 API VIP 를 엔드포인트로 `kubeadm init` 을 한 뒤 두 번째 control plane 과 worker 를 합류시킵니다. 허브와 다른 점은 값에서 켠 것들입니다.

- `kube_vip_services: true`: control plane 의 kube-vip static pod 가 `--services` 로 떠서 LoadBalancer Service 에 서비스 VIP 를 붙입니다. API VIP 와 같은 리더 한 대가 가집니다.
- `longhorn_disk`: worker 에 전용 디스크를 붙이고 `open-iscsi`, `iscsi_tcp` 모듈, multipath 예외를 설정해 마운트합니다.
- `otbr_host: true`: IPv6 포워딩, RA 수용, `tun` 모듈을 설정합니다.
- 마지막에 `lan-dns.yml` 을 다시 실행해 새 노드 이름과 역할 이름(`k8s-[SITE_SHORT]`, `kubectl-[SITE_SHORT]`, `iot-[SITE_SHORT]`), `lan_dns_names` 를 내부망 DNS 에 넣습니다.

```bash
# 실행 (노드 4대 기준 10분 안팎). PROXMOX_* 환경변수는 kubeadm 플레이북 글과 같습니다
export PROXMOX_HOST=[PROXMOX_IP] PROXMOX_USER=root@pam PROXMOX_TOKEN_ID=ansible \
       PROXMOX_TOKEN_SECRET=$(cat ~/.config/proxmox/token) PROXMOX_VALIDATE_CERTS=false
ansible-playbook playbooks/k8s-cluster.yml -e k8s_cluster=[SITE]
```

> `kubeadm init` 은 API VIP 가 이미 응답하는데 목록의 control plane 중 클러스터에 든 노드가 없으면 멈춥니다. 다른 클러스터가 같은 VIP 를 쓰고 있을 때 새 클러스터를 만들어 버리지 않기 위해서입니다. 이 경우 `vip` 값을 확인합니다.
{: .prompt-info }

- **확인:** 마지막 `결과` 태스크에 노드 4대가 `Ready` 로 보이고 `PLAY RECAP` 에 `failed=0` 입니다. 실행 PC 에 `~/.kube/k8s-[SITE].yaml` 이 생기고 그 `server:` 가 `https://[EDGE_API_VIP]:6443` 입니다.

## 3. etcd 세 번째 투표자 붙이기

control plane 이 두 대면 etcd 멤버도 두 개라, 서버 한 대가 죽으면 [과반](/posts/61/)(2표 중 2표)을 잃어 API 서버가 멈춥니다. 원격 NAS 에 etcd 컨테이너를 세 번째 투표자로 두어 3표 중 2표가 남게 합니다. 투표자는 클러스터마다 따로 두며, 허브 투표자와 같은 NAS 에 둘 때는 포트만 바꿉니다(예: 허브 `2379/2380`, 지역 `12379/12380`). 인터넷이 끊겨도 지역의 두 control plane 끼리 과반이라 엣지는 계속 돕니다.

붙이는 방법은 [쿠버네티스 etcd 세 번째 투표자를 원격 NAS 컨테이너로 붙이는 방법](/posts/55/)을 따르되, 인증서를 만들 때 클러스터 인자에 지역 이름(`[SITE]`)을 주고 멤버 추가·승격은 지역의 첫 control plane 에서 실행합니다.

```bash
# 지역 첫 control plane 에서 etcd 멤버 목록 보기
kubectl -n kube-system exec etcd-k8s-[SITE_SHORT]-cp-1 -- etcdctl \
  --cacert /etc/kubernetes/pki/etcd/ca.crt --cert /etc/kubernetes/pki/etcd/server.crt --key /etc/kubernetes/pki/etcd/server.key \
  member list -w table
```

- **확인:** 멤버 세 개(`k8s-[SITE_SHORT]-cp-1`, `k8s-[SITE_SHORT]-cp-2`, 원격 투표자)가 모두 `started` 이고 `IS LEARNER` 가 `false` 입니다.

## 4. Argo CD 에 클러스터 등록

허브 Argo CD 가 엣지에 배포하려면 엣지의 API 서버 주소와 자격 증명이 Argo CD 의 cluster Secret 으로 있어야 합니다. `argocd cluster add` 가 이 일을 하는데, 대상 클러스터의 kubeconfig 컨텍스트와 Argo CD 가 있는 클러스터의 접근 권한이 한 kubeconfig 안에 함께 필요합니다. 2단계에서 가져온 kubeconfig 를 허브 control plane 에 복사하고, 그곳에서 스크립트를 실행합니다.

```bash
# 실행 PC: 엣지 kubeconfig 를 허브 control plane 으로 복사
scp ~/.kube/k8s-[SITE].yaml ubuntu@[HUB_CP_IP]:

# 허브 control plane: 스크립트 내려받기
ssh ubuntu@[HUB_CP_IP]
wget https://eu4ng.github.io/assets/scripts/kubernetes/register-edge-cluster.sh
```

<details markdown="1">
<summary>register-edge-cluster.sh 전문</summary>

```bash
#!/usr/bin/env bash
#
# 엣지 클러스터를 허브의 Argo CD 에 원격 클러스터로 등록합니다.
# proxmox-ansible 의 playbooks/k8s-cluster.yml 이 실행 PC 에 가져온 엣지 kubeconfig 를 허브 control plane 에 복사한 뒤,
# control plane 에서 실행합니다: bash register-edge-cluster.sh [SITE] [EDGE_KUBECONFIG]
# Argo CD API 서버에 로그인하지 않고 CLI 의 core 모드로 쿠버네티스 API 에 직접 쓰므로 비밀번호가 필요 없습니다.

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
ARGOCD_NAMESPACE=argocd
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
# kubeadm 클러스터끼리는 kubeconfig 의 클러스터·사용자·컨텍스트 이름이 같아(kubernetes, kubernetes-admin) 병합하면 한쪽이 가려집니다.
# 엣지 kubeconfig 를 지역 이름으로 바꾼 사본을 만들어 씁니다. 원래 파일은 건드리지 않습니다.
python3 - "$EDGE_KUBECONFIG" "$SITE" "$TMP_DIR/edge.yaml" <<'PY'
import sys, yaml
src, site, dst = sys.argv[1:]
c = yaml.safe_load(open(src))
ctx = next(x for x in c["contexts"] if x["name"] == c["current-context"])
cl = next(x for x in c["clusters"] if x["name"] == ctx["context"]["cluster"])
us = next(x for x in c["users"] if x["name"] == ctx["context"]["user"])
cl["name"], us["name"] = f"{site}-cluster", f"{site}-admin"
out = {"apiVersion": "v1", "kind": "Config", "clusters": [cl], "users": [us],
       "contexts": [{"name": site, "context": {"cluster": cl["name"], "user": us["name"]}}], "current-context": site}
yaml.safe_dump(out, open(dst, "w"))
PY
chmod 600 "$TMP_DIR/edge.yaml"
EDGE_KUBECONFIG=$TMP_DIR/edge.yaml
EDGE_CONTEXT=$SITE
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
```
{: file="register-edge-cluster.sh" }

</details>

```bash
# 등록 (SITE 는 1단계의 k8s_clusters 키와 같게)
bash register-edge-cluster.sh [SITE] k8s-[SITE].yaml
```

kubeadm 으로 만든 클러스터끼리는 kubeconfig 의 클러스터·사용자·컨텍스트 이름이 모두 `kubernetes`, `kubernetes-admin` 으로 같아서, 그대로 병합하면 한쪽이 가려집니다. 스크립트는 엣지 kubeconfig 를 지역 이름으로 바꾼 사본을 임시 폴더에 만들어 허브 kubeconfig 와 병합하고, 허브의 `argocd-server` 와 같은 버전의 CLI 로 `argocd --core cluster add` 를 실행합니다. 엣지의 `kube-system` 에는 cluster-admin 권한의 ServiceAccount `argocd-manager` 가 생기고, 그 토큰이 허브 `argocd` 네임스페이스의 Secret 에 `site=[SITE]` 라벨과 함께 저장됩니다. 원래 kubeconfig 파일은 바뀌지 않고, `--upsert` 라 다시 실행해도 같은 등록을 갱신합니다.

- **확인:** 마지막 `등록된 클러스터` 표에 `https://[EDGE_API_VIP]:6443` 이 이름 `[SITE]` 로 보입니다. 아직 Application 이 없으면 상태가 `Unknown` 일 수 있습니다. `kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster --show-labels` 에 `site=[SITE]` 라벨이 붙은 Secret 이 있습니다.

## 5. 지역 폴더 규칙과 ApplicationSet 추가

기존 `services/` 폴더는 허브로만 배포됩니다. 어느 폴더가 어느 클러스터로 가는지는 [ApplicationSet](/posts/58/) 이 정하므로, 프로젝트 폴더 `iot/` 와 그 규칙을 저장소에 추가합니다. 지역 폴더의 두 번째 세그먼트가 그대로 Argo CD 의 클러스터 이름이 되므로, 4단계에서 등록한 이름과 폴더 이름이 같아야 합니다. 저장소를 처음 연결할 때 만든 `services` ApplicationSet 은 그대로 두고, 프로젝트의 ApplicationSet 은 `services/argocd/` 폴더에 매니페스트로 두어 GitOps 로 관리합니다.

```text
services/[이름]/              # 플랫폼 서비스 → 허브 (기존)
iot/hub/[이름]/               # IoT 의 허브 몫 → 허브. 폴더 이름 = Application = 네임스페이스
iot/edge/[이름]/              # 엣지 공통 베이스(kustomize). 직접 배포되지 않고 아래 오버레이가 참조
iot/clusters/[SITE]/[이름]/   # 지역 폴더 → 클러스터 [SITE] 의 네임스페이스 [이름]. 오버레이 또는 Helm 폴더(Chart.yaml)
iot/shared/[이름]/            # 허브와 엣지가 함께 가져다 쓰는 재료(대시보드 등). 직접 배포되지 않음
```

{% raw %}
```yaml
# IoT 프로젝트의 ApplicationSet 두 개. 저장소를 처음 연결하는 `services` ApplicationSet(install-argocd.sh)은 services/* 만 보므로,
# 다른 프로젝트 폴더는 이렇게 services/argocd/ 에 ApplicationSet 을 두어 GitOps 로 관리합니다. 폴더 규칙은 iot/README.md 에 있습니다.
# 원격(엣지) 클러스터는 GitOps 밖에서 등록합니다: register-edge-cluster.sh (Argo CD 에 <지역> 이름으로 등록).
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: iot-hub
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: git@github.com:[OWNER]/k8s-gitops.git
        revision: HEAD
        directories:
          - path: iot/hub/*                    # 중앙(허브) 몫. 폴더 이름 = Application = 네임스페이스
  template:
    metadata:
      name: '{{.path.basename}}'
    spec:
      project: default
      source:
        repoURL: git@github.com:[OWNER]/k8s-gitops.git
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
          - ServerSideApply=true
  syncPolicy:
    preserveResourcesOnDeletion: true
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: iot-edge
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: git@github.com:[OWNER]/k8s-gitops.git
        revision: HEAD
        directories:
          - path: iot/clusters/*/*             # iot/clusters/<지역>/<이름>/ → 클러스터 <지역> 의 네임스페이스 <이름>
  template:
    metadata:
      name: '{{index .path.segments 2}}-{{.path.basename}}'   # 예: daejeon-mosquitto
    spec:
      project: default
      source:
        repoURL: git@github.com:[OWNER]/k8s-gitops.git
        targetRevision: HEAD
        path: '{{.path.path}}'
      destination:
        name: '{{index .path.segments 2}}'   # Argo CD 에 등록한 클러스터 이름 (폴더 이름과 같아야 합니다)
        namespace: '{{.path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
  syncPolicy:
    preserveResourcesOnDeletion: true
```
{: file="services/argocd/applicationset-iot.yaml" }
{% endraw %}

`iot-edge` 는 Git 디렉터리 생성기의 `path.segments` 로 폴더 경로를 쪼개 두 번째 세그먼트를 배포 대상 클러스터 이름(`destination.name`)으로, 마지막 폴더 이름을 네임스페이스로 씁니다. Application 이름은 `[SITE]-[이름]` 이 되어 여러 지역이 같은 서비스 이름을 써도 겹치지 않습니다. 폴더 규칙을 적은 `iot/README.md` 를 함께 두고 push 합니다.

```bash
# 커밋하고 push
git add services/argocd/applicationset-iot.yaml iot/README.md
git commit -m "feat(argocd): IoT 프로젝트용 ApplicationSet 과 iot/ 폴더 규칙 추가"
git push
```

- **확인:** `argocd` Application 이 다시 sync 된 뒤 허브 control plane 의 `kubectl -n argocd get applicationset` 에 `services`, `iot-hub`, `iot-edge` 가 보입니다. 아직 `iot/clusters/[SITE]/` 아래에 폴더가 없으므로 지역 Application 은 생기지 않습니다.

## 6. Longhorn 을 기본 StorageClass 로 배포

엣지의 PVC(Home Assistant 설정, Zigbee2MQTT·Matter 페어링 정보, Mosquitto, Telegraf 버퍼 등)는 서버 한 대가 죽어도 다른 노드에서 같은 데이터로 떠야 하므로, worker 두 대의 전용 디스크에 두 벌씩 두는 Longhorn 을 기본 StorageClass 로 둡니다. 지역 폴더에 첫 Application 으로 Longhorn Helm 폴더를 추가합니다. 허브와 같은 차트·버전이고, Longhorn 자체의 설정은 [쿠버네티스에 Longhorn과 Patroni로 볼륨과 TimescaleDB 이중화하는 방법](/posts/54/)을 봅니다. 엣지에서는 기본 StorageClass 로 둔다는 점만 다릅니다.

```yaml
apiVersion: v2
name: [SITE]-longhorn-system
version: 0.1.0
dependencies:
  - name: longhorn
    version: 1.12.1
    repository: https://charts.longhorn.io
```
{: file="iot/clusters/[SITE]/longhorn-system/Chart.yaml" }

```yaml
longhorn:
  persistence:
    defaultClass: true                           # 엣지의 기본 StorageClass. storageClassName 이 없는 PVC 가 모두 여기로 옵니다
    defaultClassReplicaCount: 2                  # 엣지 노드가 두 대(서버마다 한 대)
    reclaimPolicy: Retain                        # PVC 를 지워도 볼륨 데이터는 남깁니다
  defaultSettings:
    defaultReplicaCount: '{"v1":"2","v2":"2"}'
    # 노드가 죽으면 그 노드의 파드를 지워 다른 노드에서 볼륨을 붙여 다시 뜨게 합니다(기본값은 파드가 Terminating 에 멈춤)
    nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod
    storageReservedPercentageForDefaultDisk: 5   # 전용 디스크라 예약을 크게 둘 필요가 없습니다(기본 30)
    storageMinimalAvailablePercentage: 10
  preUpgradeChecker:
    jobEnabled: false                            # Helm hook Job 을 Argo CD 가 동기화마다 다시 돌리지 않게 합니다
  longhornUI:
    replicas: 1
  csi:                                           # CSI 보조 컨트롤러는 기본 3개씩입니다. 노드가 두 대라 2개면 충분합니다
    attacherReplicaCount: 2
    provisionerReplicaCount: 2
    resizerReplicaCount: 2
    snapshotterReplicaCount: 2
```
{: file="iot/clusters/[SITE]/longhorn-system/values.yaml" }

```bash
# 커밋하고 push
git add iot/clusters/[SITE]/longhorn-system
git commit -m "feat(iot): [SITE] 엣지에 Longhorn 기본 StorageClass 추가"
git push
```

- **확인:** Argo CD 에 `[SITE]-longhorn-system` Application 이 생겨 `Synced`·`Healthy` 가 되고, 엣지에서 아래 명령을 실행하면 `longhorn (default)` StorageClass 와 worker 두 대의 Longhorn 노드가 `READY True` 로 보입니다.

```bash
# 허브 control plane 에서 엣지 확인
kubectl --kubeconfig k8s-[SITE].yaml get sc
kubectl --kubeconfig k8s-[SITE].yaml -n longhorn-system get nodes.longhorn.io
```

## 트러블슈팅

<details markdown="1">
<summary><code>configmap "argocd-cm" not found</code> — <code>argocd --core</code> 실행 시</summary>

```text
{"level":"fatal","msg":"configmap \"argocd-cm\" not found"}
```

- **원인:** core 모드는 kubeconfig 현재 컨텍스트의 네임스페이스에서 Argo CD 설정을 찾습니다. 네임스페이스가 비어 있으면 `default` 에서 찾다가 실패하며, `-n` 같은 네임스페이스 옵션은 없습니다.
- **해결:** 스크립트가 병합한 임시 kubeconfig 에서 `kubectl config set-context --current --namespace=argocd` 로 네임스페이스를 지정합니다. 스크립트 밖에서 `argocd --core` 를 직접 실행할 때도 같은 설정이 필요합니다.

</details>

## 마무리

허브와 같은 플레이북으로 control plane 2 + worker 2 의 지역 엣지 클러스터를 만들고, etcd 세 번째 투표자와 Longhorn 기본 StorageClass 를 붙인 뒤 허브의 Argo CD 에 원격 클러스터로 등록해, `iot/clusters/[SITE]/` 아래 폴더가 그 클러스터로 배포되는 구성을 완성했습니다. 지역이 늘면 `k8s_clusters` 에 지역을 추가해 플레이북을 돌리고, 같은 스크립트로 등록한 뒤 `iot/clusters/` 아래 폴더만 추가하면 됩니다. 허브가 엣지 API 서버에 닿지 못하는 동안 Argo CD 는 그 지역의 Application 을 `Unknown` 으로 표시하지만, 엣지에 이미 배포된 파드는 자체 control plane 으로 계속 동작합니다.

## 참고 자료

- [Kubernetes - Creating Highly Available Clusters with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/)
- [kube-vip - Static Pods](https://kube-vip.io/docs/installation/static/)
- [kube-vip - Kubernetes Services](https://kube-vip.io/docs/usage/kubernetes-services/)
- [Longhorn - Settings Reference](https://longhorn.io/docs/1.12.1/references/settings/)
- [Argo CD - Declarative Setup (Clusters)](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters)
- [Argo CD - Git Generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/)
- [Argo CD - Core Install](https://argo-cd.readthedocs.io/en/stable/operator-manual/core/)
