---
layout: post
title: 쿠버네티스에 Longhorn과 Patroni로 볼륨과 TimescaleDB 이중화하는 방법
description: 서버 한 대가 죽어도 서비스가 다른 서버에서 같은 데이터로 뜨도록, 작은 파일 볼륨은 Longhorn 으로 worker 두 대에 2벌 복제하고 TimescaleDB 는 Patroni 로 worker 두 대와 원격 NAS 에 스트리밍 복제하는 방법을 정리했습니다.
author: Eu4ng
tags: [kubernetes, longhorn, patroni, timescaledb, postgresql, high-availability, argo-cd, gitops, synology, portainer]
permalink: /posts/54/
---

local-path 볼륨은 한 노드의 디스크에만 있어서 그 서버가 죽으면 파드가 다른 노드에서 떠도 데이터가 없습니다. 이중화는 데이터 종류에 따라 둘로 나눕니다. Home Assistant 설정이나 Grafana 데이터처럼 작은 파일은 [Longhorn 이 블록 단위로](/posts/72/) 두 worker 에 복제하고, 노드가 죽으면 파드를 다른 worker 로 옮깁니다. TimescaleDB 는 Longhorn 에 올리지 않고 Patroni 로 DB 자체를 복제합니다. 멤버마다 자기 노드의 로컬 디스크에 전체 데이터를 두고, Patroni 가 주 DB 하나를 고르면 나머지는 [스트리밍 복제](/posts/73/)로 따라갑니다. 세 번째 멤버는 원격지 NAS 컨테이너에 둡니다. 기존 단일 DB 의 데이터는 `pg_dump`·`pg_restore` 로 옮깁니다.

1. worker 에 Longhorn 디스크 준비
2. Longhorn 배포
3. 앱 볼륨을 Longhorn 으로 옮기기
4. Patroni 권한과 비밀값 만들기
5. 기존 DB 쓰기 멈추고 덤프
6. Patroni 멤버 배포
7. 덤프 복원
8. NAS 멤버 붙이기
9. 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Kubernetes | `v1.37.0` (kubeadm, control plane 2대 + worker 2대, Argo CD) |
| Longhorn | `1.12.1` (Helm 차트) |
| TimescaleDB | `timescale/timescaledb-ha:pg17.11-ts2.30.1` (PostgreSQL 17, TimescaleDB 2.30.1, Patroni 4.1.5) |
| NAS | Synology `DSM 7.2`, Portainer CE `2.39` (Docker Swarm), Tailscale 패키지(TUN 모드) |
| 작성 기준일 | `2026-09-27` |

다음 항목이 준비되어 있어야 합니다.

- worker 두 대를 서로 다른 Proxmox 서버에 둔 kubeadm 클러스터와 그 플레이북 ([Proxmox에 Ansible로 kubeadm 쿠버네티스 클러스터 만드는 방법](/posts/46/))
- GitOps 저장소의 `services/`, `iot/hub/` 폴더를 배포하는 Argo CD ([쿠버네티스에 Argo CD 설치하고 GitOps로 서비스 추가하는 방법](/posts/36/))
- `timescaledb-credentials` Secret(블로그 `create-iot-secrets.sh`, [엣지 Mosquitto와 Telegraf 디스크 버퍼로 중앙 TimescaleDB에 유실 없이 IoT 데이터 모으는 방법](/posts/43/)의 준비 단계). 예전처럼 단일 Deployment 로 띄운 허브 DB 가 있으면 5·7단계에서 옮기고, 허브 DB 를 처음 만든다면 5·7단계와 `IOT_LOGIN=NOLOGIN` 은 건너뜁니다
- Longhorn 으로 옮길 앱: Grafana ([쿠버네티스에 Prometheus와 Grafana 배포해 자원 사용량 대시보드 만드는 방법](/posts/39/)), 중앙 Home Assistant ([중앙 Home Assistant로 여러 지역 Home Assistant 모아 보는 방법](/posts/49/))
- NAS 가 집 LAN 의 노드와 API VIP 에 닿는 Tailscale 서브넷 경로 ([Proxmox 두 대를 클러스터로 묶고 원격 NAS에 QDevice 붙이는 방법](/posts/53/))와, worker VM 이 tailnet 대역을 자기 Proxmox 호스트로 보내는 경로(위 kubeadm 글의 플레이북)
- GitOps 저장소의 스택 파일을 Portainer 에 등록하는 `scripts/portainer-stack.sh` ([Cloudflare Tunnel로 포트 열지 않고 홈랩 서버와 원격 NAS에 SSH 접속하는 방법](/posts/51/)의 4단계)

## 1. worker 에 Longhorn 디스크 준비

Longhorn 복제본은 OS 디스크와 나눈 전용 디스크(`scsi1`)의 `/var/lib/longhorn` 에 둡니다. 클러스터 변수의 worker 항목에 `longhorn_disk`(GB)를 붙이면, 플레이북이 VM 에 디스크를 핫플러그하고 Longhorn 이 쓰는 iSCSI(`open-iscsi`, `iscsi_tcp`)를 준비한 뒤 디스크를 포맷해 마운트합니다. Ubuntu 의 multipathd 가 Longhorn 장치를 가로채지 않게 `sd` 장치를 multipath 에서 뺍니다.

```yaml
k8s_clusters:
  hub:
    nodes:
      # ... control plane 항목
      - { name: k8s-hub-worker-1, pve: pve01, role: worker, vmid: 123, ip: [WORKER1_IP], cores: 24, memory: 40960, disk: 100G, longhorn_disk: 20 }
      - { name: k8s-hub-worker-2, pve: pve02, role: worker, vmid: 124, ip: [WORKER2_IP], cores: 8,  memory: 5120,  disk: 60G,  longhorn_disk: 20 }
```
{: file="group_vars/all.yml" }

```bash
# proxmox-ansible 저장소 루트에서
ansible-playbook playbooks/k8s-cluster.yml -e k8s_cluster=hub
```

<details markdown="1">
<summary>playbooks/k8s-cluster.yml 의 Longhorn 디스크·준비 작업</summary>

{% raw %}
```yaml
    - name: Longhorn 디스크 (scsi1, 없을 때만. 켜진 VM 에 핫플러그)
      community.proxmox.proxmox_disk:
        vmid: "{{ item.vmid }}"
        disk: scsi1
        storage: "{{ vm_disk_storage }}"
        size: "{{ item.longhorn_disk }}"
        format: raw
        discard: "on"
        ssd: true
        state: present
      loop: "{{ active | selectattr('longhorn_disk', 'defined') }}"
      loop_control: { label: "{{ item.name }}" }
```
{: file="playbooks/k8s-cluster.yml (VM 만들기 플레이)" }

```yaml
# Longhorn 은 볼륨을 iSCSI 로 붙입니다. multipathd 가 Longhorn 장치를 가로채지 않게 sd 장치를 제외합니다
- name: Longhorn 준비 (longhorn_disk 가 있는 노드)
  hosts: k8s_longhorn
  become: true
  gather_facts: false
  vars:
    longhorn_dev: /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
  tasks:
    - name: 패키지
      ansible.builtin.apt:
        name: [open-iscsi, nfs-common]
    - name: iscsid
      ansible.builtin.systemd:
        name: iscsid
        enabled: true
        state: started
    - name: iscsi_tcp 모듈 (자동 로드)
      ansible.builtin.copy:
        dest: /etc/modules-load.d/longhorn.conf
        mode: "0644"
        content: "iscsi_tcp\n"
    - name: iscsi_tcp 모듈 (지금)
      community.general.modprobe:
        name: iscsi_tcp
    - name: multipath 에서 sd 장치 제외
      ansible.builtin.blockinfile:
        path: /etc/multipath.conf
        marker: "# {mark} k8s-hub.yml: Longhorn"   # 플레이북 이름이 k8s-hub.yml 이던 때의 표식. 바꾸면 노드의 multipath.conf 에 같은 블록이 한 번 더 들어가므로 그대로 둡니다
        block: |
          blacklist {
              devnode "^sd[a-z0-9]+"
          }
      register: multipath
    - name: multipathd 재시작
      ansible.builtin.systemd:
        name: multipathd
        state: restarted
      when: multipath.changed
    - name: Longhorn 디스크가 있는지
      ansible.builtin.stat:
        path: "{{ longhorn_dev }}"
      register: longhorn_disk
      failed_when: not longhorn_disk.stat.exists
    - name: 파일시스템 (비어 있을 때만)
      community.general.filesystem:
        dev: "{{ longhorn_dev }}"
        fstype: ext4
    - name: /var/lib/longhorn 에 마운트
      ansible.posix.mount:
        path: /var/lib/longhorn
        src: "{{ longhorn_dev }}"
        fstype: ext4
        opts: defaults,discard,nofail
        state: mounted
```
{: file="playbooks/k8s-cluster.yml (Longhorn 준비 플레이)" }
{% endraw %}

</details>

- **확인:** 각 worker 에서 `findmnt /var/lib/longhorn` 에 ext4 로 마운트된 장치가 보이고, `systemctl is-active iscsid` 가 `active` 입니다.

## 2. Longhorn 배포

`services/longhorn-system/` 에 공식 차트를 의존성으로 두는 차트를 만듭니다. 기본 StorageClass 는 local-path 로 두고, 복제가 필요한 PVC 만 `storageClassName: longhorn` 을 적습니다. worker 가 두 대라 복제본은 2벌이고, `nodeDownPodDeletionPolicy` 로 노드가 죽으면 그 노드의 파드를 지워 다른 worker 에서 볼륨을 붙여 다시 뜨게 합니다. 기본값은 파드가 `Terminating` 에 멈춰 볼륨이 풀리지 않습니다.

```yaml
# 복제 블록 스토리지. 볼륨을 두 서버(pve01·pve02)의 worker 에 2벌씩 두어, 한 서버가 죽어도 파드가 다른 worker 에서 같은 데이터로 뜹니다.
# 유실되면 안 되는 작은 파일 데이터(Home Assistant 설정, Grafana)에 씁니다. DB 는 DB 자체 복제(Patroni)로 따로 이중화합니다.
# 복제본은 worker 의 전용 디스크(/var/lib/longhorn, proxmox-ansible k8s-cluster.yml 의 longhorn_disk)에 둡니다.
# control plane 은 taint 가 있어 Longhorn 이 뜨지 않으므로 볼륨을 쓰는 파드는 worker 에서만 뜹니다.
apiVersion: v2
name: longhorn-system
version: 0.1.0
dependencies:
  - name: longhorn
    version: 1.12.1
    repository: https://charts.longhorn.io
```
{: file="services/longhorn-system/Chart.yaml" }

```yaml
longhorn:
  persistence:
    defaultClass: false                          # 기본 StorageClass 는 local-path 로 둡니다. 복제가 필요한 PVC 만 storageClassName: longhorn
    defaultClassReplicaCount: 2                  # worker 가 두 대(서버마다 한 대)
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
  csi:                                           # CSI 보조 컨트롤러는 기본 3개씩입니다. worker 가 두 대라 2개면 충분합니다
    attacherReplicaCount: 2
    provisionerReplicaCount: 2
    resizerReplicaCount: 2
    snapshotterReplicaCount: 2
```
{: file="services/longhorn-system/values.yaml" }

```bash
git add services/longhorn-system
git commit -m "feat(longhorn-system): 두 worker 에 2벌 복제하는 Longhorn 스토리지 추가"
git push
```

- **확인:** `kubectl -n argocd get application longhorn-system` 이 `Synced`, `Healthy` 이고, `kubectl -n longhorn-system get nodes.longhorn.io` 에 두 worker 가 `READY` `True`, `kubectl get sc` 에 `longhorn` 이 보이며 `(default)` 는 여전히 `local-path` 입니다.

## 3. 앱 볼륨을 Longhorn 으로 옮기기

StorageClass 는 PVC 를 만든 뒤에 바꿀 수 없으므로 이름이 다른 새 PVC 를 만들고 데이터를 복사합니다. 복사하는 동안 앱은 0개로 내립니다. PVC 에는 `Prune=false` 를 달아 저장소에서 실수로 지워도 Argo CD 가 볼륨을 지우지 않게 합니다.

```yaml
# 복제 볼륨(Longhorn, 서버 두 대에 2벌). 서버 한 대가 죽어도 다른 worker 에서 같은 설정으로 다시 뜹니다
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: home-assistant-config-lh
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 2Gi
```
{: file="iot/hub/home-assistant/pvc.yaml (기존 PVC 아래에 추가)" }

```yaml
# Grafana 데이터(직접 만든 대시보드·설정)의 복제 볼륨(Longhorn, 서버 두 대에 2벌). values 의 grafana.persistence.existingClaim 으로 씁니다
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-data-lh
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 2Gi
```
{: file="services/monitoring/templates/grafana-pvc.yaml" }

먼저 위 두 파일을 추가하고, Home Assistant Deployment 의 `replicas` 와 Grafana values 의 `kube-prometheus-stack.grafana.replicas` 를 `0` 으로 바꿔 push 합니다. 파드가 내려가면 앱마다 옛 PVC 와 새 PVC 를 함께 붙인 임시 파드로 복사합니다. 옛 PVC 이름은 `kubectl -n [NAMESPACE] get pvc` 로 확인합니다.

```bash
# control plane 에서. home-assistant 와 monitoring 네임스페이스에서 한 번씩 실행
NS=[NAMESPACE]; OLD=[OLD_PVC]; NEW=[NEW_PVC]
kubectl -n $NS apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: { name: pvc-copy }
spec:
  restartPolicy: Never
  containers:
    - name: copy
      image: busybox:1.37
      command: [sh, -c, "cp -a /old/. /new/ && du -sh /old /new"]
      volumeMounts: [{ name: old, mountPath: /old }, { name: new, mountPath: /new }]
  volumes:
    - { name: old, persistentVolumeClaim: { claimName: $OLD } }
    - { name: new, persistentVolumeClaim: { claimName: $NEW } }
EOF
kubectl -n $NS wait --for=jsonpath='{.status.phase}'=Succeeded pod/pvc-copy --timeout=5m
kubectl -n $NS logs pvc-copy && kubectl -n $NS delete pod pvc-copy
```

복사가 끝나면 앱이 새 PVC 를 쓰게 바꾸고 `replicas` 를 되돌려 push 합니다. Home Assistant 는 Deployment 볼륨의 `claimName` 을 `home-assistant-config-lh` 로, Grafana 는 values 를 아래처럼 바꿉니다. ReadWriteOnce 볼륨이라 새 파드가 뜨기 전에 옛 파드를 먼저 내려야 합니다.

```yaml
    persistence: { enabled: true, existingClaim: grafana-data-lh }   # 직접 만든 대시보드와 설정. Longhorn 복제 볼륨(templates/grafana-pvc.yaml)
    deploymentStrategy: { type: RollingUpdate, rollingUpdate: { maxSurge: 0, maxUnavailable: 1 } }   # ReadWriteOnce 볼륨이라 옛 파드를 먼저 내립니다(Recreate 는 기존 rollingUpdate 필드와 충돌)
```
{: file="services/monitoring/values.yaml (kube-prometheus-stack.grafana 아래)" }

- **확인:** 두 앱이 `Running` 이고 옛 설정·대시보드가 그대로 보입니다. `kubectl -n longhorn-system get volumes.longhorn.io` 에 볼륨 두 개가 `attached`, `healthy` 이고, `kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=VOLUME:.spec.volumeName,NODE:.spec.nodeID` 에 볼륨마다 두 worker 가 하나씩 보입니다.

## 4. Patroni 권한과 비밀값 만들기

Patroni 는 etcd 같은 별도 저장소 대신 쿠버네티스를 DCS(리더 선출·설정 저장)로 씁니다. 주 DB 주소는 Patroni 가 Service 이름과 같은 Endpoints 에 직접 쓰고, 멤버 상태는 멤버 이름과 같은 Pod 의 주석에 적습니다. 권한은 이 네임스페이스 안으로 한정하고, 클러스터 밖의 NAS 멤버는 따로 만든 ServiceAccount 토큰으로 API 에 붙습니다.

```yaml
# Patroni 가 쿠버네티스를 DCS(리더 선출·설정 저장)로 씁니다. 권한은 이 네임스페이스 안으로만 한정합니다.
# patroni: 허브의 StatefulSet 멤버, patroni-nas: 서울 NAS 멤버(토큰으로 VIP 에 붙음, scripts/timescaledb-ha-secrets.sh 가 kubeconfig 로 만듦)
apiVersion: v1
kind: ServiceAccount
metadata: { name: patroni }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: patroni-nas }
---
apiVersion: v1
kind: Secret
metadata:
  name: patroni-nas-token
  annotations: { kubernetes.io/service-account.name: patroni-nas }
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: patroni }
rules:
  - apiGroups: [""]
    resources: [endpoints]
    verbs: [get, list, watch, create, update, patch, delete, deletecollection]
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, watch, patch, update]
  - apiGroups: [""]
    resources: [services]
    verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: patroni }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: patroni }
subjects:
  - { kind: ServiceAccount, name: patroni }
  - { kind: ServiceAccount, name: patroni-nas }
```
{: file="iot/hub/timescaledb/patroni-rbac.yaml" }

`iot/hub/timescaledb/kustomization.yaml` 의 `resources` 에 `patroni-rbac.yaml` 을 더해 push 하고, 동기화되면 비밀값 스크립트를 실행합니다. 스크립트는 superuser·replication 비밀번호를 만들어 허브 Secret `timescaledb-patroni` 에 넣고, NAS 멤버가 쓸 비밀번호와 kubeconfig 를 `~/.config/portainer/secrets/` 에 둡니다. 끝으로 NAS 멤버 자리의 Pod `nas` 를 만듭니다. 어느 노드에도 스케줄되지 않는 Pod 라 실행되지 않고, Argo CD 가 `Pending` Pod 를 계속 `Progressing` 으로 보므로 저장소가 아니라 스크립트에서 만듭니다.

```bash
# GitOps 저장소 루트에서 스크립트 내려받기
curl -fsSL https://eu4ng.github.io/assets/scripts/kubernetes/timescaledb-ha-secrets.sh -o scripts/timescaledb-ha-secrets.sh

# 맨 위 "환경에 맞게 수정" 블록의 KUBECTL, API_SERVER 를 고친 뒤 실행 (SUFFIX v1)
bash scripts/timescaledb-ha-secrets.sh v1
```

<details markdown="1">
<summary>scripts/timescaledb-ha-secrets.sh 전문</summary>

```bash
#!/usr/bin/env bash
#
# TimescaleDB Patroni 클러스터(iot/hub/timescaledb, stacks/seoul/timescaledb)의 비밀값을 만듭니다. 여러 번 실행해도 됩니다.
#   - Patroni superuser(postgres)·replication(replicator) 비밀번호: ~/.config/iot/secrets.env 에 없으면 무작위로 만들어 적습니다
#   - 허브 timescaledb/timescaledb-patroni Secret (PATRONI_SUPERUSER_PASSWORD, PATRONI_REPLICATION_PASSWORD)
#   - 서울 NAS 멤버용 파일(~/.config/portainer/secrets/, portainer-stack.sh 가 Swarm secret 으로 만듦):
#       timescaledb_superuser_password_<SUFFIX>, timescaledb_replication_password_<SUFFIX>,
#       timescaledb_kubeconfig_<SUFFIX>  (ServiceAccount patroni-nas 토큰. timescaledb 네임스페이스 안에서만 권한이 있음)
#   - 지역 DB(iot/edge/timescaledb)의 timescaledb/timescaledb-patroni Secret (EDGE_KUBECONFIG 를 준 지역마다, 허브와 같은 값)
# 허브의 iot·grafana 비밀번호(timescaledb-credentials)는 blog 의 create-iot-secrets.sh 가 만든 것을 그대로 씁니다.
#
# 사용법: bash scripts/timescaledb-ha-secrets.sh [SUFFIX] [EDGE_KUBECONFIG ...]
#   SUFFIX 기본값 v1(값을 바꿀 때는 새 SUFFIX 로). EDGE_KUBECONFIG 는 허브 kubectl 호스트 기준 경로(예: /home/ubuntu/k8s-daejeon.yaml)

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
KUBECTL=(ssh ubuntu@[CONTROL_PLANE_IP] kubectl)      # 허브 kubectl (내부망 DNS 의 역할 이름. 노드를 바꿔도 그대로)
API_SERVER=https://[API_VIP]:6443             # NAS 가 붙을 API 주소(VIP, Tailscale 서브넷 경로로 닿음)
# --------------------------------------

SUFFIX=${1:-v1}
EDGE_KUBECONFIGS=("${@:2}")
ENV_FILE=$HOME/.config/iot/secrets.env
OUT=$HOME/.config/portainer/secrets
log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR
umask 077
mkdir -p "$(dirname "$ENV_FILE")" "$OUT"

# ---------- 1. 비밀번호 ----------
log "비밀번호 ($ENV_FILE)"
touch "$ENV_FILE"
for v in PATRONI_SUPERUSER_PASSWORD PATRONI_REPLICATION_PASSWORD; do
  if ! grep -q "^$v=" "$ENV_FILE"; then
    echo "$v=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')" >> "$ENV_FILE"; echo "    $v: 만듦"
  else echo "    $v: 있음"; fi
done
set -a; . "$ENV_FILE"; set +a

# ---------- 2. 허브 Secret ----------
log "허브 timescaledb/timescaledb-patroni"
"${KUBECTL[@]}" create namespace timescaledb --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null
# 값은 표준입력으로 넘겨 명령줄·기록에 남기지 않습니다
printf 'PATRONI_SUPERUSER_PASSWORD=%s\nPATRONI_REPLICATION_PASSWORD=%s\n' "$PATRONI_SUPERUSER_PASSWORD" "$PATRONI_REPLICATION_PASSWORD" \
  | "${KUBECTL[@]}" -n timescaledb create secret generic timescaledb-patroni --from-env-file=/dev/stdin --dry-run=client -o yaml \
  | "${KUBECTL[@]}" apply -f - >/dev/null

# ---------- 2-1. 지역 DB Secret ----------
for k in "${EDGE_KUBECONFIGS[@]}"; do
  log "지역 timescaledb/timescaledb-patroni ($k)"
  E=("${KUBECTL[@]}" --kubeconfig "$k")
  "${E[@]}" create namespace timescaledb --dry-run=client -o yaml | "${E[@]}" apply -f - >/dev/null
  printf 'PATRONI_SUPERUSER_PASSWORD=%s\nPATRONI_REPLICATION_PASSWORD=%s\n' "$PATRONI_SUPERUSER_PASSWORD" "$PATRONI_REPLICATION_PASSWORD" \
    | "${E[@]}" -n timescaledb create secret generic timescaledb-patroni --from-env-file=/dev/stdin --dry-run=client -o yaml \
    | "${E[@]}" apply -f - >/dev/null
done

# ---------- 3. NAS 멤버 파일 ----------
log "NAS 멤버 파일 → $OUT"
printf '%s' "$PATRONI_SUPERUSER_PASSWORD" > "$OUT/timescaledb_superuser_password_$SUFFIX"
printf '%s' "$PATRONI_REPLICATION_PASSWORD" > "$OUT/timescaledb_replication_password_$SUFFIX"
# ServiceAccount 토큰은 iot/hub/timescaledb/patroni-rbac.yaml 의 Secret 에 컨트롤러가 채웁니다(Argo CD 동기화 뒤)
# jsonpath 는 ssh 너머에서 따옴표·역슬래시가 풀리므로 JSON 으로 받아 여기서 꺼냅니다
SA_JSON=$("${KUBECTL[@]}" -n timescaledb get secret patroni-nas-token -o json 2>/dev/null || echo '{}')
TOKEN=$(python3 -c 'import sys,json,base64; d=json.loads(sys.stdin.read()).get("data",{}); print(base64.b64decode(d.get("token","")).decode())' <<<"$SA_JSON")
CA=$(python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("data",{}).get("ca.crt",""))' <<<"$SA_JSON")
[ -n "$TOKEN" ] && [ -n "$CA" ] || die "timescaledb/patroni-nas-token 에 토큰·CA 가 없습니다. iot/hub/timescaledb 가 동기화된 뒤 다시 실행합니다."
cat > "$OUT/timescaledb_kubeconfig_$SUFFIX" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: hub
    cluster: { server: $API_SERVER, certificate-authority-data: $CA }
users:
  - name: patroni-nas
    user: { token: $TOKEN }
contexts:
  - name: hub
    context: { cluster: hub, user: patroni-nas, namespace: timescaledb }
current-context: hub
EOF
ls -1 "$OUT" | grep "timescaledb_.*_$SUFFIX" | sed 's/^/    /'

# ---------- 4. NAS 멤버의 자리표시 Pod ----------
# Patroni 의 쿠버네티스 DCS 는 멤버 상태를 "멤버 이름과 같은 Pod" 의 주석에 적습니다. NAS 멤버는 클러스터 밖이라 Pod 가 없으므로
# 어느 노드에도 스케줄되지 않는 Pod(nas)를 둡니다. 실행되지 않아 자원을 쓰지 않고, 노드가 죽어도 영향이 없습니다.
# Argo CD 는 Pending Pod 를 계속 Progressing 으로 보므로 저장소가 아니라 여기서 만듭니다.
log "NAS 멤버 자리표시 Pod (timescaledb/nas)"
"${KUBECTL[@]}" apply -f - >/dev/null <<'POD'
apiVersion: v1
kind: Pod
metadata:
  name: nas
  namespace: timescaledb
  labels: { application: patroni, cluster-name: timescaledb }
spec:
  nodeSelector: { patroni.placeholder/never-schedule: "true" }
  containers:
    - { name: placeholder, image: registry.k8s.io/pause:3.10 }
POD
log "완료."
```
{: file="scripts/timescaledb-ha-secrets.sh" }

</details>

- **확인:** `kubectl -n timescaledb get secret timescaledb-patroni patroni-nas-token` 에 두 Secret 이 보이고, `kubectl -n timescaledb get pod nas` 가 `Pending`, `ls ~/.config/portainer/secrets/ | grep timescaledb` 에 `_v1` 로 끝나는 파일 세 개가 보입니다.

## 5. 기존 DB 쓰기 멈추고 덤프

옮길 단일 DB 가 없으면 이 단계와 7단계를 건너뜁니다.

덤프하는 동안 새 행이 들어오지 않게 Service 가 기존 DB 를 가리키지 않도록 selector 에 없는 라벨을 더합니다. 엣지 Telegraf 는 연결이 끊기면 디스크 버퍼에 쌓아 두었다가 새 DB 가 뜨면 보냅니다.

```yaml
  selector: { app: timescaledb, migrating: "true" }   # Patroni 로 옮기는 동안 쓰기를 막습니다(Telegraf 는 디스크 버퍼에 쌓음)
```
{: file="iot/hub/timescaledb/service.yaml (spec 아래)" }

push 해 동기화되면 기존 DB 에서 덤프를 받고, 비교할 행 수를 적어 둡니다.

```bash
# control plane 에서
kubectl -n timescaledb get endpoints timescaledb          # ENDPOINTS 가 <none> 이어야 합니다
kubectl -n timescaledb exec deploy/timescaledb -- pg_dump -U iot -d iot -Fc > ~/iot.dump
kubectl -n timescaledb exec deploy/timescaledb -- psql -U iot -d iot -Atc "SELECT count(*) FROM readings"
```

> `pg_dump` 가 TimescaleDB 내부 카탈로그 테이블에 대해 `circular foreign-key constraints` 경고를 낼 수 있습니다. TimescaleDB 문서에 따르면 무시해도 됩니다.
{: .prompt-info }

- **확인:** `ls -lh ~/iot.dump` 의 크기가 0 보다 크고, `kubectl -n timescaledb exec -i deploy/timescaledb -- pg_restore -l < ~/iot.dump | grep -c 'TABLE DATA'` 가 0 보다 큽니다.

## 6. Patroni 멤버 배포

StatefulSet 멤버 두 개를 worker 마다 하나씩 띄웁니다. 멤버는 `hostNetwork` 로 노드 IP 의 5432·8008 에 열어, 파드 대역에 닿지 못하는 NAS 멤버가 Tailscale 서브넷 경로로 직접 붙게 합니다. 데이터는 노드의 local-path 볼륨에 둡니다. 복제는 DB 가 하므로 Longhorn 을 쓰지 않습니다.

Patroni 설정의 요점은 아래와 같습니다.

- `scope` 가 곧 Service·Endpoints 이름이고, `kubernetes.ports` 의 이름이 Service 포트 이름과 같아야 합니다.
- `synchronous_mode` 와 `synchronous_node_count: 1` 로 쓰기는 대기 복제본 하나가 받아야 완료됩니다. `sync_priority` 가 높은 worker 멤버를 먼저 고르고, 없으면 NAS 멤버가 동기 복제본이 됩니다. `synchronous_mode_strict: false` 라 둘 다 없으면 쓰기를 멈추지 않고 비동기로 씁니다.
- `failover_priority` 로 주 DB 가 죽으면 worker 멤버(2)를 NAS 멤버(1)보다 먼저 올립니다.
- `authentication` 에 `rewind` 계정은 적지 않습니다. 이름만 적고 비밀번호를 주지 않았더니 타임라인이 갈라진 복제본이 `pg_rewind` 로 주 DB 에 붙을 때 `no password supplied` 로 실패해 스스로 따라붙지 못했습니다. 적지 않으면 superuser 계정으로 `pg_rewind` 합니다. NAS 멤버의 스택 파일(8단계)도 같습니다.
- `post_bootstrap` 스크립트는 클러스터를 처음 만들 때 한 번 실행되어 role 과 DB 를 만듭니다. 복원 전에 Telegraf 가 먼저 붙어 테이블을 만들지 않게, `IOT_LOGIN=NOLOGIN` 을 주면 `iot` role 을 로그인할 수 없게 만듭니다.

```yaml
# Patroni 설정(허브 멤버). 서울 NAS 멤버는 stacks/seoul/timescaledb/stack.yml 에 같은 내용을 둡니다(bootstrap·tags 만 다름).
# 멤버 이름·주소는 환경 변수(PATRONI_NAME, PATRONI_KUBERNETES_POD_IP, *_CONNECT_ADDRESS)로 채웁니다.
scope: timescaledb                # 주 DB 를 가리키는 Service·Endpoints 이름. Patroni 가 Endpoints 에 주 DB 주소를 씁니다
kubernetes:
  use_endpoints: true
  labels: { application: patroni, cluster-name: timescaledb }
  ports: [{ name: postgresql, port: 5432 }]
restapi:
  listen: 0.0.0.0:8008
bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    # 쓰기는 대기 복제본 하나가 받아야 완료됩니다(sync_priority 가 높은 worker 먼저, 없으면 NAS). 둘 다 없으면 멈추지 않고 비동기로 씁니다
    synchronous_mode: true
    synchronous_node_count: 1
    synchronous_mode_strict: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        shared_preload_libraries: timescaledb
        timescaledb.telemetry_level: "off"
        timescaledb.max_background_workers: 8
        max_worker_processes: 16
        max_connections: 100
        shared_buffers: 256MB
        effective_cache_size: 1GB
        wal_level: replica
        wal_log_hints: "on"
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        max_slot_wal_keep_size: 4GB   # 오래 끊긴 복제본(예: NAS)이 주 DB 디스크를 채우지 않게. 넘으면 그 복제본은 다시 받아야 합니다
        timezone: UTC
        log_timezone: UTC
  initdb: [{ encoding: UTF8 }, { locale: C.UTF-8 }, data-checksums]
  post_bootstrap: /etc/patroni/post-bootstrap.sh
postgresql:
  listen: 0.0.0.0:5432
  data_dir: /home/postgres/pgdata/data
  pgpass: /tmp/pgpass
  authentication:                 # 비밀번호는 PATRONI_SUPERUSER_PASSWORD, PATRONI_REPLICATION_PASSWORD
    superuser: { username: postgres }
    replication: { username: replicator }       # rewind 계정은 따로 적지 않습니다. 적으면 비밀번호도 따로 줘야 하고, 없으면 superuser 로 pg_rewind 합니다
  pg_hba:
    - local all all trust
    - host replication replicator 0.0.0.0/0 scram-sha-256
    - host all all 0.0.0.0/0 scram-sha-256
tags:
  failover_priority: 2            # 주 DB 가 죽으면 worker 멤버를 NAS(1)보다 먼저 올립니다
  sync_priority: 2
```
{: file="iot/hub/timescaledb/patroni/patroni.yml" }

```bash
#!/bin/sh
# 새 클러스터를 처음 만들 때 한 번 실행됩니다(Patroni bootstrap.post_bootstrap). $1 은 superuser 접속 문자열입니다.
# Telegraf 는 DB 소유자 iot 로 쓰고(테이블·컬럼을 만들어야 함), Grafana 는 읽기 전용 role grafana 로 봅니다.
# IOT_LOGIN=NOLOGIN 이면 iot 가 로그인하지 못하게 만듭니다(기존 DB 를 복원하기 전에 Telegraf 가 먼저 테이블을 만들지 않게).
set -e
psql -v ON_ERROR_STOP=1 "$1" <<EOSQL
  CREATE ROLE iot SUPERUSER ${IOT_LOGIN:-LOGIN} PASSWORD '$IOT_PASSWORD';
  CREATE DATABASE iot OWNER iot;
  CREATE ROLE grafana LOGIN PASSWORD '$GRAFANA_PASSWORD';
  \connect iot
  CREATE EXTENSION IF NOT EXISTS timescaledb;
  GRANT CONNECT ON DATABASE iot TO grafana;
  GRANT USAGE ON SCHEMA public TO grafana;
  ALTER DEFAULT PRIVILEGES FOR ROLE iot IN SCHEMA public GRANT SELECT ON TABLES TO grafana;
EOSQL
```
{: file="iot/hub/timescaledb/patroni/post-bootstrap.sh" }

StatefulSet 에는 복원하는 동안만 `IOT_LOGIN=NOLOGIN` 을 넣습니다. `priorityClassName: essential` 과 `tolerations` 는 서버 한 대가 죽었을 때를 위한 설정입니다. 남은 worker 에 자리가 모자라면 등급이 높은 파드가 낮은 파드를 내보내고 뜨고, 죽은 노드를 기본 300초 대신 30초만 기다린 뒤 다른 노드에서 다시 띄웁니다. 등급은 아래 파일로 먼저 만듭니다. 등급이 없으면 그 이름을 쓰는 파드가 만들어지지 않습니다. 허브는 `services/priority-classes/`, 지역 엣지는 `iot/clusters/[SITE]/priority-classes/` 폴더가 같은 정의를 참조합니다.

```yaml
# 서버 한 대가 죽어 남은 워커에 자리가 모자랄 때 누구를 먼저 살릴지 정합니다. 허브(services/priority-classes)와
# 지역(iot/clusters/<지역>/priority-classes)이 같은 파일을 씁니다.
#   essential: IoT 수집·제어·기록과 거기에 들어가는 길(접속, 인증). 자리가 없으면 아래 등급의 파드를 내보내고 뜹니다.
#   (없음, 0): 그 밖의 서비스.
#   optional:  없어도 IoT 가 도는 무거운 서비스(MinerU, 모델 서버 라우터). 가장 먼저 자리를 내줍니다.
# 스케줄러는 메모리·CPU 요청(requests)으로 자리를 계산하므로 essential 워크로드에는 요청을 꼭 적습니다.
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: essential
value: 1000000                    # Longhorn(longhorn-critical 10억)·시스템 파드보다는 낮습니다
description: 서버 한 대가 죽어도 유지해야 하는 IoT 서비스
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: optional
value: -1000
description: 자리가 모자라면 가장 먼저 내보내는 서비스
```
{: file="iot/shared/priority-classes/priorityclass.yaml" }

```yaml
# 허브와 지역 오버레이가 폴더째 참조합니다(kustomize 는 폴더 밖의 파일을 직접 읽지 못합니다).
resources:
  - priorityclass.yaml
```
{: file="iot/shared/priority-classes/kustomization.yaml" }

```yaml
# 허브의 파드 우선순위 등급(essential, optional). 정의는 지역과 같이 씁니다.
resources:
  - ../../iot/shared/priority-classes
```
{: file="services/priority-classes/kustomization.yaml" }

```yaml
# 대전 엣지의 파드 우선순위 등급(essential, optional). 정의는 허브와 같이 씁니다.
resources:
  - ../../../shared/priority-classes
```
{: file="iot/clusters/[SITE]/priority-classes/kustomization.yaml" }

```yaml
# TimescaleDB 허브 멤버 두 개(worker 마다 하나). 서울 NAS 의 세 번째 멤버(stacks/seoul/timescaledb)와 함께 Patroni 가 주 DB 하나를 고르고
# 나머지는 스트리밍 복제로 따라갑니다. 각 멤버는 자기 노드의 로컬 디스크(local-path)에 전체 데이터를 가집니다(복제는 DB 가 함).
# hostNetwork 로 노드 IP:5432·8008 에 열어, NAS 멤버가 Tailscale 서브넷 경로로 직접 붙습니다.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: timescaledb
spec:
  replicas: 2
  serviceName: timescaledb-config
  podManagementPolicy: Parallel
  selector:
    matchLabels: { application: patroni, cluster-name: timescaledb }
  template:
    metadata:
      labels: { application: patroni, cluster-name: timescaledb }
    spec:
      priorityClassName: essential             # 서버 한 대가 죽어도 유지(iot/shared/priority-classes)
      tolerations:                              # 노드가 죽으면 30초 뒤 다른 노드에서 다시 띄웁니다(기본 300초)
        - { key: node.kubernetes.io/not-ready, operator: Exists, effect: NoExecute, tolerationSeconds: 30 }
        - { key: node.kubernetes.io/unreachable, operator: Exists, effect: NoExecute, tolerationSeconds: 30 }
      serviceAccountName: patroni
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      securityContext: { fsGroup: 1000 }
      affinity:
        podAntiAffinity:                            # 서버마다 하나
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector: { matchLabels: { application: patroni, cluster-name: timescaledb } }
              topologyKey: kubernetes.io/hostname
      terminationGracePeriodSeconds: 30
      containers:
        - name: timescaledb
          image: timescale/timescaledb-ha:pg17.11-ts2.30.1
          command: [patroni, /etc/patroni/patroni.yml]
          ports:
            - { name: postgresql, containerPort: 5432 }
            - { name: patroni, containerPort: 8008 }
          env:
            - { name: POD_IP, valueFrom: { fieldRef: { fieldPath: status.podIP } } }   # hostNetwork 라 노드 IP
            - { name: PATRONI_NAME, valueFrom: { fieldRef: { fieldPath: metadata.name } } }
            - { name: PATRONI_KUBERNETES_NAMESPACE, valueFrom: { fieldRef: { fieldPath: metadata.namespace } } }
            - { name: PATRONI_KUBERNETES_POD_IP, value: $(POD_IP) }
            - { name: PATRONI_RESTAPI_CONNECT_ADDRESS, value: $(POD_IP):8008 }
            - { name: PATRONI_POSTGRESQL_CONNECT_ADDRESS, value: $(POD_IP):5432 }
            - { name: PATRONI_SUPERUSER_PASSWORD, valueFrom: { secretKeyRef: { name: timescaledb-patroni, key: PATRONI_SUPERUSER_PASSWORD } } }
            - { name: PATRONI_REPLICATION_PASSWORD, valueFrom: { secretKeyRef: { name: timescaledb-patroni, key: PATRONI_REPLICATION_PASSWORD } } }
            # post-bootstrap.sh 가 만드는 role 의 비밀번호 (blog create-iot-secrets.sh)
            - { name: IOT_PASSWORD, valueFrom: { secretKeyRef: { name: timescaledb-credentials, key: POSTGRES_PASSWORD } } }
            - { name: GRAFANA_PASSWORD, valueFrom: { secretKeyRef: { name: timescaledb-credentials, key: GRAFANA_PASSWORD } } }
            - { name: IOT_LOGIN, value: NOLOGIN }    # 기존 DB 를 복원하는 동안만. 복원 뒤 ALTER ROLE iot LOGIN 하고 이 줄을 지웁니다
          volumeMounts:
            - { name: pgdata, mountPath: /home/postgres/pgdata }
            - { name: config, mountPath: /etc/patroni }
          readinessProbe:
            httpGet: { path: /readiness, port: 8008 }
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /liveness, port: 8008 }
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits:   { cpu: "2", memory: 2Gi }
      volumes:
        - name: config
          configMap: { name: timescaledb-patroni, defaultMode: 0755 }
  volumeClaimTemplates:                             # API 서버가 채우는 값(kind·volumeMode·status)까지 적어 Argo CD 가 차이로 보지 않게 합니다
    - apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: pgdata
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: local-path                # 노드 로컬 디스크. 이중화는 DB 복제가 맡습니다
        volumeMode: Filesystem
        resources: { requests: { storage: 20Gi } }
      status: { phase: Pending }
```
{: file="iot/hub/timescaledb/patroni-statefulset.yaml" }

Service 에서는 selector 를 지웁니다. selector 가 없으면 쿠버네티스가 Endpoints 를 관리하지 않고, Patroni 가 지금 주 DB 의 주소를 씁니다. 주 DB 가 NAS 로 넘어가면 NAS 의 Tailscale IP 가 들어가고, 클러스터 안의 접속(`timescaledb.timescaledb.svc.cluster.local`)과 NodePort 모두 그 주소로 갑니다.

```yaml
# 주 DB 로 가는 주소. selector 가 없고 Patroni(patroni-statefulset.yaml, stacks/seoul/timescaledb)가 Endpoints 에 지금 주 DB 의 주소를 씁니다.
# 주 DB 가 서울 NAS 로 넘어가면 NAS 의 Tailscale IP 가 들어갑니다. 이름은 Patroni scope 와 같아야 합니다.
# 엣지 클러스터의 Telegraf 가 노드 IP:30432 로 씁니다.
apiVersion: v1
kind: Service
metadata:
  name: timescaledb
spec:
  type: NodePort
  ports:
    - { name: postgresql, port: 5432, targetPort: 5432, nodePort: 30432 }   # 이름은 Patroni kubernetes.ports 와 같아야 합니다
```
{: file="iot/hub/timescaledb/service.yaml" }

기존 Deployment 는 `replicas: 0` 으로 내리고, 옛 PVC 는 복원을 확인할 때까지 남겨 둡니다.

```yaml
resources:
  - deployment.yaml            # 옛 단일 DB. replicas: 0 으로 내려 두고, 확인 뒤 pvc.yaml·initdb 와 함께 지웁니다
  - pvc.yaml
  - service.yaml
  - patroni-rbac.yaml
  - patroni-statefulset.yaml
configMapGenerator:
  - name: timescaledb-patroni
    files:
      - patroni/patroni.yml
      - patroni/post-bootstrap.sh
  - name: timescaledb-initdb
    files:
      - initdb/10-iot.sh
```
{: file="iot/hub/timescaledb/kustomization.yaml" }

```bash
git add iot/hub/timescaledb
git commit -m "feat(iot): TimescaleDB 를 worker 두 대의 Patroni 클러스터로 전환"
git push
```

- **확인:** `kubectl -n timescaledb get pods -L role` 에 `timescaledb-0`, `timescaledb-1` 이 서로 다른 worker 에서 `1/1` 이고 하나가 `primary`, 하나가 `replica` 입니다. `kubectl -n timescaledb get endpoints timescaledb` 에 주 DB 노드의 `IP:5432` 가 보입니다. 이 시점의 Telegraf 로그에는 `role "iot" is not permitted to log in` 이 찍히고, 행은 버퍼에 쌓입니다.

## 7. 덤프 복원

TimescaleDB 는 복원 전후에 `timescaledb_pre_restore()`·`timescaledb_post_restore()` 를 불러야 합니다. 덤프를 받은 DB 와 복원할 DB 의 TimescaleDB 버전이 같아야 합니다(여기서는 둘 다 2.30.1). 객체 소유자인 `iot` role 은 post-bootstrap 이 이미 만들었으므로 소유자 그대로 복원됩니다.

```bash
# control plane 에서. Patroni 가 주 DB 파드에 role=primary 라벨을 붙입니다
P=$(kubectl -n timescaledb get pod -l role=primary -o jsonpath='{.items[0].metadata.name}')
PSQL="kubectl -n timescaledb exec -i $P -c timescaledb -- psql -U postgres -d iot -v ON_ERROR_STOP=1"

$PSQL -c "SELECT timescaledb_pre_restore();"
kubectl -n timescaledb exec -i $P -c timescaledb -- pg_restore -U postgres -d iot < ~/iot.dump
$PSQL -c "SELECT timescaledb_post_restore();"
$PSQL -Atc "SELECT count(*) FROM readings"   # 5단계에서 적은 행 수와 비교

# Telegraf 가 다시 쓰게 로그인 허용
$PSQL -c "ALTER ROLE iot LOGIN;"
```

복원이 끝나면 StatefulSet 의 `IOT_LOGIN` 줄을 지워 push 합니다. post-bootstrap 은 처음 한 번만 실행되므로 이미 만든 role 에는 영향이 없습니다. env 가 바뀌어 파드가 하나씩 다시 뜨고, 주 DB 파드가 내려갈 때 동기 복제본이 주 DB 를 넘겨받습니다.

- **확인:** 복원한 행 수가 덤프 전과 같거나(버퍼가 벌써 들어왔다면) 더 많고, 몇 분 안에 `$PSQL -Atc "SELECT max(time) FROM readings"` 가 현재 시각에 가까워집니다. 옛 Deployment·PVC·initdb 는 이 확인 뒤에 저장소에서 지웁니다.

## 8. NAS 멤버 붙이기

NAS 멤버는 같은 이미지로 Portainer Swarm 스택에서 돌립니다. DCS 는 허브 쿠버네티스라 4단계의 kubeconfig 로 API VIP 에 붙고, 멤버 이름은 자리표시 Pod 이름(`nas`)과 같아야 합니다. 평소에는 대기 복제본이고, worker 대기 복제본이 없으면 동기 복제본이 되며, 허브 멤버가 모두 없을 때만 주 DB 가 됩니다. 허브 멤버가 주 DB 를 만든 뒤에 띄웁니다. 그 전에 뜨면 NAS 멤버가 새 클러스터를 만들어 버립니다.

```yaml
# 원격지 NAS(Synology, Portainer Swarm)의 TimescaleDB 세 번째 멤버(Patroni). 허브 worker 두 대의 멤버(iot/hub/timescaledb)와 같은 클러스터입니다.
# 평소에는 스트리밍 복제로 전체 데이터를 따라가는 대기 복제본이고, 허브 멤버가 모두 없으면 주 DB 로 올라갑니다(failover_priority 1).
# worker 대기 복제본이 없을 때는 이 멤버가 동기 복제본이 되어 쓰기 유실을 막습니다(sync_priority 1).
# Patroni 의 DCS 는 허브 쿠버네티스입니다. ServiceAccount patroni-nas 의 kubeconfig(timescaledb 네임스페이스 권한만)로 VIP 에 붙습니다.
# NAS 의 Tailscale(TUN 모드) IP 에만 엽니다. 허브는 Tailscale 서브넷 경로로 이 주소에 붙습니다.
# 준비: bash scripts/timescaledb-ha-secrets.sh  (비밀번호·kubeconfig 파일, 자리표시 Pod timescaledb/nas)
# 등록: 허브 멤버가 주 DB 를 만든 뒤에 bash scripts/portainer-stack.sh stacks/[REGION]/timescaledb/stack.yml
#       (먼저 뜨면 새 클러스터를 만들어 버리므로 순서를 지킵니다)
version: "3.8"
services:
  timescaledb:
    image: timescale/timescaledb-ha:pg17.11-ts2.30.1   # 허브 멤버와 같은 이미지
    environment:
      - KUBECONFIG=/run/secrets/timescaledb_kubeconfig_v1
      - PATRONI_NAME=nas                               # 자리표시 Pod 이름과 같아야 합니다
      - PATRONI_KUBERNETES_NAMESPACE=timescaledb
      - PATRONI_KUBERNETES_POD_IP=[NAS_TAILSCALE_IP]   # NAS 의 Tailscale IP
      - PATRONI_RESTAPI_CONNECT_ADDRESS=[NAS_TAILSCALE_IP]:8008
      - PATRONI_POSTGRESQL_CONNECT_ADDRESS=[NAS_TAILSCALE_IP]:5432
    command:
      - sh
      - -c
      - |
        export PATRONI_SUPERUSER_PASSWORD="$$(cat /run/secrets/timescaledb_superuser_password_v1)"
        export PATRONI_REPLICATION_PASSWORD="$$(cat /run/secrets/timescaledb_replication_password_v1)"
        cat > /tmp/patroni.yml <<'YML'
        scope: timescaledb
        kubernetes:
          context: hub
          use_endpoints: true
          labels: { application: patroni, cluster-name: timescaledb }
          ports: [{ name: postgresql, port: 5432 }]
        restapi:
          listen: [NAS_TAILSCALE_IP]:8008
        postgresql:
          listen: [NAS_TAILSCALE_IP]:5432
          data_dir: /home/postgres/pgdata/data
          pgpass: /tmp/pgpass
          authentication:
            superuser: { username: postgres }
            replication: { username: replicator }
          pg_hba:
            - local all all trust
            - host replication replicator 0.0.0.0/0 scram-sha-256
            - host all all 0.0.0.0/0 scram-sha-256
        tags:
          failover_priority: 1
          sync_priority: 1
        YML
        exec patroni /tmp/patroni.yml
    secrets:
      - timescaledb_kubeconfig_v1
      - timescaledb_superuser_password_v1
      - timescaledb_replication_password_v1
    volumes:
      - timescaledb-nas-data:/home/postgres/pgdata     # 이미지의 디렉터리 소유자(postgres)로 볼륨이 만들어집니다
    networks:
      - hostnet               # Swarm 은 network_mode: host 를 무시하므로 호스트 네트워크에 붙입니다
    deploy:
      replicas: 1
      restart_policy:
        condition: any

secrets:                      # scripts/timescaledb-ha-secrets.sh 가 만든 파일로 portainer-stack.sh 가 만듭니다. 바꿀 때는 새 이름(_v2)으로
  timescaledb_kubeconfig_v1: { external: true }
  timescaledb_superuser_password_v1: { external: true }
  timescaledb_replication_password_v1: { external: true }

volumes:
  timescaledb-nas-data:

networks:
  hostnet:
    external: true
    name: host
```
{: file="stacks/[REGION]/timescaledb/stack.yml" }

```bash
# GitOps 저장소 루트에서. Portainer 는 원격 저장소의 파일을 읽으므로 먼저 push 합니다
git add stacks/[REGION]/timescaledb scripts/timescaledb-ha-secrets.sh
git commit -m "feat(stacks): 원격 NAS 에 TimescaleDB 세 번째 멤버 추가"
git push
bash scripts/portainer-stack.sh stacks/[REGION]/timescaledb/stack.yml
```

- **확인:** 스크립트가 secret 세 개와 스택을 `만듦` 으로 출력하고, 전체 데이터를 받아 오는 동안 기다린 뒤 9단계의 `patronictl list` 에 `nas` 가 `streaming` 으로 보입니다.

## 9. 확인

세 멤버의 역할과 복제 지연을 봅니다.

```bash
# control plane 에서
kubectl -n timescaledb exec timescaledb-0 -c timescaledb -- patronictl -c /etc/patroni/patroni.yml list
kubectl -n timescaledb get endpoints timescaledb
```

```text
+ Cluster: timescaledb (7690127583634878496) -------+-----------+----+-------------+-----+------------+-----+----------------------+
| Member        | Host               | Role         | State     | TL | Receive LSN | Lag | Replay LSN | Lag | Tags                 |
+---------------+--------------------+--------------+-----------+----+-------------+-----+------------+-----+----------------------+
| nas           | [NAS_TAILSCALE_IP] | Replica      | streaming |  6 |  0/1C1B5E60 |   0 | 0/1C1B5E60 |   0 | failover_priority: 1 |
|               |                    |              |           |    |             |     |            |     | sync_priority: 1     |
+---------------+--------------------+--------------+-----------+----+-------------+-----+------------+-----+----------------------+
| timescaledb-0 | [WORKER2_IP]       | Leader       | running   |  6 |             |     |            |     | failover_priority: 2 |
|               |                    |              |           |    |             |     |            |     | sync_priority: 2     |
+---------------+--------------------+--------------+-----------+----+-------------+-----+------------+-----+----------------------+
| timescaledb-1 | [WORKER1_IP]       | Sync Standby | streaming |  6 |  0/1C1B5E60 |   0 | 0/1C1B5E60 |   0 | failover_priority: 2 |
|               |                    |              |           |    |             |     |            |     | sync_priority: 2     |
+---------------+--------------------+--------------+-----------+----+-------------+-----+------------+-----+----------------------+
```

주 DB 파드를 지워 넘어가는지 시험합니다. 이름은 위 출력의 `Leader` 입니다.

```bash
# control plane 에서
kubectl -n timescaledb delete pod [LEADER_POD]
kubectl -n timescaledb exec [OTHER_POD] -c timescaledb -- patronictl -c /etc/patroni/patroni.yml list
kubectl -n timescaledb get endpoints timescaledb
```

- **확인:** 평소에는 worker 멤버 하나가 `Leader`, 다른 하나가 `Sync Standby`, `nas` 가 `Replica` 이고 `Lag` 이 0 에 가깝습니다. 주 DB 파드를 지우면 `Sync Standby` 였던 worker 멤버가 `Leader` 가 되고 `TL` 이 1 늘며, Endpoints 가 그 노드의 주소로 바뀝니다. 지운 파드는 다시 떠 대기 복제본으로 돌아옵니다.

## 마무리

작은 파일 볼륨은 Longhorn 으로 두 worker 에 2벌씩 복제해 노드가 죽으면 파드가 다른 worker 에서 같은 데이터로 뜨게 했고, TimescaleDB 는 Patroni 로 worker 두 대와 원격 NAS 에 스트리밍 복제해 주 DB 가 죽으면 동기 복제본이 이어받게 했습니다. 접속 주소는 selector 없는 Service 하나라 주 DB 가 바뀌어도 Grafana 와 엣지 Telegraf 설정을 고치지 않습니다. Longhorn 복제본은 같은 집의 두 서버에만 있으므로 원격 백업은 따로 둡니다.

## 참고 자료

- [Longhorn Documentation](https://longhorn.io/docs/1.12.1/)
- [Longhorn Settings Reference: Pod Deletion Policy When Node is Down](https://longhorn.io/docs/1.12.1/references/settings/#pod-deletion-policy-when-node-is-down)
- [Longhorn Installation Requirements](https://longhorn.io/docs/1.12.1/deploy/install/#installation-requirements)
- [Patroni: Kubernetes](https://patroni.readthedocs.io/en/latest/kubernetes.html)
- [Patroni: Replication modes](https://patroni.readthedocs.io/en/latest/replication_modes.html)
- [Patroni: YAML Configuration Settings (tags)](https://patroni.readthedocs.io/en/latest/yaml_configuration.html)
- [TimescaleDB: Logical backups with pg_dump and pg_restore](https://docs.timescale.com/self-hosted/latest/backup-and-restore/logical-backup/)
