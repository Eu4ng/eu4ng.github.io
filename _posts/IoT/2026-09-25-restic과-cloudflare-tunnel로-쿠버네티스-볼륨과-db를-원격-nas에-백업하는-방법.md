---
layout: post
title: restic과 Cloudflare Tunnel로 쿠버네티스 볼륨과 DB를 원격 NAS에 백업하는 방법
description: 허브와 엣지 쿠버네티스 클러스터의 로컬 볼륨과 TimescaleDB 를 매일 restic 스냅샷으로 원격 Synology NAS 에 올리고, NAS 의 포트를 열지 않도록 SFTP 를 Cloudflare Tunnel 로 거치게 한 뒤, 일회용 파드로 복원 연습까지 하는 방법을 정리했습니다.
author: Eu4ng
tags: [backup, restic, cloudflare, kubernetes, argo-cd, gitops, synology, iot]
permalink: /posts/50/
---

허브와 엣지 클러스터의 볼륨 디렉터리와 TimescaleDB 를 매일 **restic** 스냅샷으로 원격 NAS 에 올립니다. Zigbee 네트워크 키, Matter 패브릭, Thread 데이터셋, Home Assistant 설정은 코드로 다시 만들 수 없어서 클러스터 밖에 사본이 있어야 합니다. restic 은 SFTP 로 NAS 에 저장하고, SFTP 는 Cloudflare Tunnel(`cloudflared access ssh`)과 Access 서비스 토큰을 거치므로 NAS 의 공인 IP 나 포트를 열지 않습니다. 두 클러스터가 저장소 하나를 함께 쓰고, 스냅샷의 호스트 이름으로 클러스터를 구분합니다.

1. NAS 준비
2. 백업 이미지 만들기
3. 비밀 값 만들기
4. CronJob 추가
5. 첫 백업
6. 복원 연습

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| 허브 Kubernetes | `v1.37` (kubeadm, local-path-provisioner) |
| 엣지 Kubernetes | `v1.36` (k3s 내장 local-path) |
| restic | `0.19.1` |
| cloudflared | `2026.9.1` |
| NAS | Synology DSM 7 |
| 작성 기준일 | `2026-09-25` |

다음 항목이 준비되어 있어야 합니다.

- `nas-ssh.[DOMAIN]` 을 NAS 의 SSH 로 잇는 Cloudflare Tunnel 과, 허브 Secret `backup/cloudflare-access` 에 들어 있는 Access 서비스 토큰 ([Cloudflare Tunnel로 포트 열지 않고 홈랩 서버와 원격 NAS에 SSH 접속하는 방법](/posts/51/))
- 엣지 클러스터와 허브 TimescaleDB ([엣지 Mosquitto와 Telegraf 디스크 버퍼로 중앙 TimescaleDB에 유실 없이 IoT 데이터 모으는 방법](/posts/43/)), control plane 의 엣지 kubeconfig `~/k3s-[SITE].yaml` ([Proxmox에 Ansible로 k3s 엣지 클러스터 만들고 Argo CD 원격 클러스터로 등록하는 방법](/posts/42/))
- 허브 `mineru` 네임스페이스에 있는 GHCR pull Secret `ghcr-pull` 과, 이미지를 빌드할 GitHub Actions ([쿠버네티스에 MinerU 파싱 서버 배포하는 방법](/posts/38/))

## 1. NAS 준비

DSM 에서 아래를 맞춥니다. 메뉴 위치는 DSM 버전에 따라 다를 수 있습니다.

- **SSH 서비스**를 켜고 포트를 `22` 로 둡니다. 터널이 `localhost:22` 로 붙습니다.
- **SFTP 서비스**를 켜고 포트를 SSH 와 같은 `22` 로 둡니다. 포트가 다르면 22번 접속에서 SFTP 가 열리지 않습니다.
- **사용자 홈 서비스**를 켜고, 백업 계정의 `~/.ssh/authorized_keys` 에 백업에 쓸 SSH 공개키를 넣습니다. 터미널 접속에 쓰는 서버용 키를 그대로 써도 됩니다.
- **자동 차단**의 허용 목록에 `127.0.0.1` 과 `::1` 을 넣습니다. 터널로 들어온 접속은 모두 NAS 자신의 주소에서 온 것으로 보여서, 로그인에 몇 번 실패하면 백업 경로 전체가 막힙니다.
- 공유 폴더 안에 저장소 폴더를 만듭니다. 이 글은 공유 폴더 `backup` 의 `k8s` 폴더를 씁니다. SFTP 에서는 공유 폴더가 루트 바로 아래에 보이므로 저장소 경로는 `/backup/k8s` 입니다.

- **확인:** 서비스 토큰을 환경 변수로 주고 SFTP 에 로그인하면 `/backup/k8s` 가 보입니다.

```bash
# 서비스 토큰과 SSH 키가 있는 곳 (cloudflared 필요)
read -rsp "서비스 토큰 ID: " TUNNEL_SERVICE_TOKEN_ID; echo
read -rsp "서비스 토큰 Secret: " TUNNEL_SERVICE_TOKEN_SECRET; echo
export TUNNEL_SERVICE_TOKEN_ID TUNNEL_SERVICE_TOKEN_SECRET
echo "ls -l /backup" | sftp -b - -o ProxyCommand="cloudflared access ssh --hostname %h" [NAS_USER]@nas-ssh.[DOMAIN]
unset TUNNEL_SERVICE_TOKEN_ID TUNNEL_SERVICE_TOKEN_SECRET
```

## 2. 백업 이미지 만들기

postgres 이미지에 restic, cloudflared, OpenSSH 클라이언트를 더한 이미지 하나로 두 클러스터가 모두 백업합니다. postgres 이미지를 바탕으로 한 것은 허브에서 TimescaleDB 를 서버와 같은 메이저 버전의 `pg_dump` 로 받기 위해서입니다. 스크립트는 환경 변수만 보고, 볼륨 디렉터리는 파일 스냅샷으로, DB 는 `pg_dump` 출력을 파일 없이 바로 스냅샷으로 올립니다.

```dockerfile
# 쿠버네티스 상태 백업 이미지. restic 으로 암호화·중복 제거된 스냅샷을 원격 NAS(SFTP)에 올립니다.
# SFTP 는 Cloudflare Tunnel(cloudflared access ssh)을 거치므로 NAS 의 공인 IP·포트를 열지 않습니다.
# postgres 이미지를 바탕으로 해 TimescaleDB 를 pg_dump 로 받을 수 있습니다(서버와 같은 메이저 17).
# 태그는 BACKUP_VERSION 을 씁니다 (.github/workflows/build-backup.yml).
ARG BACKUP_VERSION=1
FROM postgres:17.11-alpine3.24
ARG RESTIC_VERSION=0.19.1
ARG CLOUDFLARED_VERSION=2026.9.1
RUN apk add --no-cache openssh-client bzip2 ca-certificates \
    && wget -qO- https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2 \
       | bunzip2 > /usr/local/bin/restic \
    && wget -qO /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64 \
    && chmod +x /usr/local/bin/restic /usr/local/bin/cloudflared \
    && restic version && cloudflared --version
COPY --chmod=0755 backup.sh /usr/local/bin/backup.sh
USER 70:70
ENTRYPOINT ["/usr/local/bin/backup.sh"]
```
{: file="images/backup/Dockerfile" }

```bash
#!/bin/sh
# 환경 변수로 동작합니다. 필수: RESTIC_REPOSITORY(sftp:<user>@<host>:<path>), RESTIC_PASSWORD, RESTIC_HOST(스냅샷 구분 이름),
#   TUNNEL_SERVICE_TOKEN_ID / TUNNEL_SERVICE_TOKEN_SECRET(Cloudflare Access 서비스 토큰), /secrets/ssh/id_ed25519, /secrets/ssh/known_hosts
# 선택: BACKUP_PATHS(공백 구분 디렉터리), PGHOST·PGUSER·PGPASSWORD·PGDATABASE(있으면 pg_dump 를 스냅샷으로),
#   KEEP_DAILY·KEEP_WEEKLY·KEEP_MONTHLY(기본 7·4·6)
set -eu

export HOME=/tmp
# RESTIC_REPOSITORY=sftp:<user>@<host>:<path> 에서 <user>@<host> 만 떼어 냅니다.
user_host=${RESTIC_REPOSITORY#sftp:}; user_host=${user_host%%:*}
# restic 이 SFTP 서버를 띄울 명령. ProxyCommand 가 Cloudflare Access 서비스 토큰(TUNNEL_SERVICE_TOKEN_*)으로 터널에 붙습니다.
SFTP_CMD="ssh -i /secrets/ssh/id_ed25519 -o UserKnownHostsFile=/secrets/ssh/known_hosts -o StrictHostKeyChecking=yes"
SFTP_CMD="$SFTP_CMD -o ServerAliveInterval=60 -o ServerAliveCountMax=240"
SFTP_CMD="$SFTP_CMD -o 'ProxyCommand=cloudflared access ssh --hostname %h' $user_host -s sftp"

r() { restic -o sftp.command="$SFTP_CMD" "$@"; }

echo "== 저장소 확인: $RESTIC_REPOSITORY"
if ! r cat config >/dev/null 2>&1; then
  echo "저장소가 없어 만듭니다"
  r init
fi

if [ -n "${BACKUP_PATHS:-}" ]; then
  echo "== 파일 백업: $BACKUP_PATHS"
  # shellcheck disable=SC2086
  r backup --host "$RESTIC_HOST" --tag files $BACKUP_PATHS
fi

if [ -n "${PGHOST:-}" ]; then
  echo "== DB 백업: $PGDATABASE@$PGHOST"
  pg_dump -Fc | r backup --host "$RESTIC_HOST" --tag db --stdin --stdin-filename "$PGDATABASE.dump"
fi

echo "== 보존 정책"
r forget --host "$RESTIC_HOST" --prune \
  --keep-daily "${KEEP_DAILY:-7}" --keep-weekly "${KEEP_WEEKLY:-4}" --keep-monthly "${KEEP_MONTHLY:-6}"
r snapshots --host "$RESTIC_HOST" --latest 3
```
{: file="images/backup/backup.sh" }

{% raw %}
```yaml
name: build-backup

on:
  push:
    branches: [main]
    paths: [images/backup/**]
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # 이미지 이름은 소문자여야 하고, 태그는 Dockerfile 의 BACKUP_VERSION 을 씁니다.
      - name: 이미지 이름과 태그 정하기
        id: meta
        run: |
          owner=$(echo "${{ github.repository_owner }}" | tr '[:upper:]' '[:lower:]')
          tag=$(sed -n 's/^ARG BACKUP_VERSION=//p' images/backup/Dockerfile)
          echo "image=ghcr.io/$owner/backup:$tag" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/build-push-action@v6
        with:
          context: images/backup
          push: true
          tags: ${{ steps.meta.outputs.image }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```
{: file=".github/workflows/build-backup.yml" }
{% endraw %}

```bash
git add images/backup .github/workflows/build-backup.yml
git commit -m "feat(backup): restic 백업 이미지 추가"
git push
```

- **확인:** `gh run list --workflow build-backup --limit 1` 이 `completed success` 이고, GitHub 의 **Packages** 에 `backup` 이 보입니다.

## 3. 비밀 값 만들기

스크립트가 서비스 토큰으로 NAS 에 SFTP 로그인해 NAS 의 호스트 키를 받고, 두 클러스터의 `backup` 네임스페이스에 Secret 두 개를 만듭니다. `backup-credentials` 는 저장소 주소, restic 비밀번호, 서비스 토큰을 담고 이미 있으면 건너뜁니다. `backup-ssh` 는 SSH 개인 키와 호스트 키를 담고 매번 덮어쓰므로, 키를 바꿀 때는 새 키로 다시 실행하면 됩니다. 허브에는 TimescaleDB 비밀번호도 넣습니다.

```bash
# control plane (kubectl 과 SSH 개인 키가 있는 곳)
wget https://eu4ng.github.io/assets/scripts/iot/create-backup-secrets.sh
bash create-backup-secrets.sh [NAS_USER] /backup/k8s ~/k3s-[SITE].yaml ~/.ssh/id_ed25519
```

<details markdown="1">
<summary>create-backup-secrets.sh 전문</summary>

```bash
#!/usr/bin/env bash
#
# 원격 NAS 백업(restic + SFTP, Cloudflare Tunnel 경유)에 필요한 비밀 값을 허브와 엣지 클러스터의 backup 네임스페이스에 만듭니다.
# 허브에 kubectl 로 접근할 수 있는 곳에서 실행합니다: bash create-backup-secrets.sh [NAS_USER] [REPO_PATH] [EDGE_KUBECONFIG] [SSH_KEY]
#   예: bash create-backup-secrets.sh [NAS_USER] /backup/k8s k3s-[SITE].yaml ~/.ssh/id_ed25519
# SSH_KEY 는 NAS 에 이미 등록된 개인 키입니다(터미널 접속에 쓰는 서버용 키를 그대로 씁니다). 키를 바꿀 때는 새 키로 다시 실행하면 두 클러스터의 키가 교체됩니다.
# 앞서 cloudflare-tunnel-setup.sh 가 허브에 backup/cloudflare-access(서비스 토큰)를 만들어 두어야 합니다. backup-credentials 는 이미 있으면 건너뜁니다(비밀번호 유지).

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
NAS_HOST=nas-ssh.[DOMAIN]                   # Cloudflare Tunnel 로 연 NAS 의 SSH 이름
CLOUDFLARED=$HOME/.local/bin/cloudflared
CLOUDFLARED_VERSION=2026.9.1
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---------- 1. 사전 검사 ----------
log "사전 검사"
NAS_USER=${1:-}; REPO_PATH=${2:-}; EDGE_KUBECONFIG=${3:-}; SSH_KEY=${4:-$HOME/.ssh/id_ed25519}
[ -n "$NAS_USER" ] && [[ "$REPO_PATH" == /* ]] && [ -r "$EDGE_KUBECONFIG" ] && [ -r "$SSH_KEY" ] \
  || die "사용법: bash create-backup-secrets.sh [NAS_USER] [REPO_PATH] [EDGE_KUBECONFIG] [SSH_KEY]"
HUB=(kubectl); EDGE=(kubectl --kubeconfig "$EDGE_KUBECONFIG")
"${HUB[@]}" -n backup get secret cloudflare-access >/dev/null || die "허브에 backup/cloudflare-access 가 없습니다. cloudflare-tunnel-setup.sh 를 먼저 실행하세요."
"${EDGE[@]}" get nodes >/dev/null || die "엣지 kubeconfig 로 접근할 수 없습니다."
if [ ! -x "$CLOUDFLARED" ]; then
  mkdir -p "$(dirname "$CLOUDFLARED")"
  curl -fsSL -o "$CLOUDFLARED" "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-amd64"
  chmod +x "$CLOUDFLARED"
fi
TOKEN_ID=$("${HUB[@]}" -n backup get secret cloudflare-access -o jsonpath='{.data.CF_ACCESS_CLIENT_ID}' | base64 -d)
TOKEN_SECRET=$("${HUB[@]}" -n backup get secret cloudflare-access -o jsonpath='{.data.CF_ACCESS_CLIENT_SECRET}' | base64 -d)

# ---------- 2. NAS 호스트 키와 로그인 확인 ----------
# 백업 파드는 StrictHostKeyChecking=yes 로 접속하므로 NAS 의 호스트 키를 받아 두고, 그 키로 SFTP 에 로그인되는지 확인합니다.
log "NAS 접속 확인 ($NAS_USER@$NAS_HOST)"
# 서비스 토큰은 명령줄(ps 에 보임) 대신 cloudflared 가 읽는 환경 변수로 넘깁니다.
echo "pwd" | TUNNEL_SERVICE_TOKEN_ID=$TOKEN_ID TUNNEL_SERVICE_TOKEN_SECRET=$TOKEN_SECRET sftp -b - -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$TMP/known_hosts" \
    -o ConnectTimeout=20 -o ProxyCommand="$CLOUDFLARED access ssh --hostname %h" "$NAS_USER@$NAS_HOST" >/dev/null 2>"$TMP/sftp.err" \
  || die "SFTP 로그인 실패: $(tail -1 "$TMP/sftp.err"). 이 키($(ssh-keygen -lf "$SSH_KEY" | cut -d' ' -f2))가 NAS 의 $NAS_USER 계정에 등록돼 있는지, NAS 의 SSH·SFTP 가 켜져 있는지 확인하세요."
cut -d' ' -f2- "$TMP/known_hosts" | sed 's/^/  호스트 키: /'

# ---------- 3. restic 저장소 비밀번호 ----------
# 저장소 하나를 두 클러스터가 함께 쓰므로 비밀번호도 하나입니다. 허브에 있으면 그것을 씁니다.
RESTIC_PASSWORD=$("${HUB[@]}" -n backup get secret backup-credentials -o jsonpath='{.data.RESTIC_PASSWORD}' 2>/dev/null | base64 -d || true)
NEW_PASSWORD=no
if [ -z "$RESTIC_PASSWORD" ]; then RESTIC_PASSWORD=$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-32); NEW_PASSWORD=yes; fi

# ---------- 4. 클러스터별 Secret ----------
# backup-credentials(환경 변수)는 없을 때만 만들고, backup-ssh(키·known_hosts)는 항상 덮어써 키 교체를 재실행으로 끝냅니다.
make_secrets() {
  local name=$1; shift
  "$@" get ns backup >/dev/null 2>&1 || "$@" create ns backup >/dev/null
  if ! "$@" -n backup get secret backup-credentials >/dev/null 2>&1; then
    "$@" -n backup create secret generic backup-credentials \
      --from-literal=RESTIC_REPOSITORY="sftp:$NAS_USER@$NAS_HOST:$REPO_PATH" \
      --from-literal=RESTIC_PASSWORD="$RESTIC_PASSWORD" \
      --from-literal=TUNNEL_SERVICE_TOKEN_ID="$TOKEN_ID" \
      --from-literal=TUNNEL_SERVICE_TOKEN_SECRET="$TOKEN_SECRET" >/dev/null
    echo "  $name: backup-credentials 만듦"
  else echo "  $name: backup-credentials 있음, 건너뜀"; fi
  "$@" -n backup create secret generic backup-ssh --from-file=id_ed25519="$SSH_KEY" --from-file=known_hosts="$TMP/known_hosts" \
    --dry-run=client -o yaml | "$@" apply -f - >/dev/null
  echo "  $name: backup-ssh 적용 ($(ssh-keygen -lf "$SSH_KEY" | cut -d' ' -f2))"
}
log "허브 Secret"; make_secrets hub "${HUB[@]}"
log "엣지 Secret"; make_secrets edge "${EDGE[@]}"
# 허브는 TimescaleDB 를 pg_dump 로 받으므로 DB 비밀번호를 같은 Secret 에 넣습니다.
PGPASS=$("${HUB[@]}" -n timescaledb get secret timescaledb-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
printf '{"stringData":{"PGPASSWORD":"%s"}}' "$PGPASS" \
  | "${HUB[@]}" -n backup patch secret backup-credentials --type merge --patch-file=/dev/stdin >/dev/null

# ---------- 5. 안내 ----------
log "완료"
if [ "$NEW_PASSWORD" = yes ]; then
  echo "restic 저장소 비밀번호입니다. 잃으면 백업을 열 수 없으니 비밀번호 관리자에 보관합니다(다시 보려면 Secret backup/backup-credentials)."
  echo "$RESTIC_PASSWORD"
fi
```
{: file="create-backup-secrets.sh" }

</details>

> 처음 실행하면 마지막에 restic 저장소 비밀번호가 한 번 출력됩니다. 이 비밀번호를 잃으면 백업을 열 수 없고, 클러스터를 통째로 잃으면 Secret 에서도 다시 볼 수 없습니다. 비밀번호 관리자에 따로 보관합니다.
{: .prompt-danger }

이미지가 비공개라 엣지의 `backup` 네임스페이스에도 pull Secret 이 필요합니다. 허브에 있는 것을 복사합니다.

```bash
# control plane: 허브의 ghcr-pull 을 허브·엣지 backup 네임스페이스로 복사
for k in "" "--kubeconfig $HOME/k3s-[SITE].yaml"; do
  kubectl -n mineru get secret ghcr-pull -o json \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps({"apiVersion":"v1","kind":"Secret","type":d["type"],"metadata":{"name":"ghcr-pull","namespace":"backup"},"data":d["data"]}))' \
    | kubectl $k apply -f -
done
```

- **확인:** 스크립트 출력에 `hub: backup-ssh 적용`, `edge: backup-ssh 적용` 과 키 지문이 보이고, 두 클러스터 모두 `kubectl -n backup get secret` 에 `backup-credentials`, `backup-ssh`, `ghcr-pull` 이 있습니다.

## 4. CronJob 추가

엣지는 k3s 내장 local-path 가 볼륨을 두는 디렉터리 전체를 읽기 전용으로 마운트해 올립니다. 새 서비스가 볼륨을 만들어도 목록을 고칠 필요가 없습니다. 볼륨마다 소유자가 달라 root 로 읽습니다. 엣지 공통 매니페스트는 `iot/edge/backup/` 에 두고, 지역 폴더의 오버레이가 스냅샷 호스트 이름을 `edge-[SITE]` 로 바꿉니다.

```yaml
# 엣지의 상태 백업. local-path 볼륨 디렉터리 전체(Zigbee 네트워크 키, Matter 패브릭, Thread 데이터셋, HA 설정, 브로커)를
# 매일 restic 스냅샷으로 원격 NAS 에 올립니다. 코드로 다시 만들 수 없는 것들입니다. 비밀 값은 create-backup-secrets.sh 가 만듭니다.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup
spec:
  schedule: "30 3 * * *"                 # 매일 03:30 (노드 시간대)
  timeZone: Asia/Seoul
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: Never
          imagePullSecrets:
            - name: ghcr-pull
          securityContext:
            runAsUser: 0                 # 볼륨 디렉터리마다 소유자가 달라 읽으려면 root 여야 합니다(읽기 전용 마운트)
          containers:
            - name: backup
              image: ghcr.io/[OWNER]/backup:1
              envFrom:
                - secretRef: { name: backup-credentials }   # RESTIC_REPOSITORY, RESTIC_PASSWORD, TUNNEL_SERVICE_TOKEN_*
              env:
                - { name: RESTIC_HOST, value: edge }        # 오버레이가 edge-<지역> 으로 바꿉니다
                - { name: BACKUP_PATHS, value: /data }
              volumeMounts:
                - { name: data, mountPath: /data, readOnly: true }
                - { name: ssh, mountPath: /secrets/ssh, readOnly: true }
              resources:
                requests: { cpu: 50m, memory: 128Mi }
                limits: { memory: 512Mi }
          volumes:
            - name: data
              hostPath: { path: /var/lib/rancher/k3s/storage, type: Directory }   # k3s 내장 local-path 의 볼륨 디렉터리
            - name: ssh
              secret: { secretName: backup-ssh, defaultMode: 0400 }
```
{: file="iot/edge/backup/cronjob.yaml" }

```yaml
resources:
  - cronjob.yaml
```
{: file="iot/edge/backup/kustomization.yaml" }

```yaml
# 대전 엣지의 상태 백업. 스냅샷 이름(host)을 지역으로 구분합니다.
resources:
  - ../../../edge/backup
patches:
  - patch: |
      apiVersion: batch/v1
      kind: CronJob
      metadata:
        name: backup
      spec:
        jobTemplate:
          spec:
            template:
              spec:
                containers:
                  - name: backup
                    env:
                      - { name: RESTIC_HOST, value: edge-[SITE] }
```
{: file="iot/clusters/[SITE]/backup/kustomization.yaml" }

허브는 TimescaleDB 를 `pg_dump` 로 받고, 파일은 Grafana 볼륨만 올립니다. Prometheus 데이터나 모델 캐시처럼 다시 만들 수 있는 볼륨은 넣지 않습니다. 엣지 백업과 저장소 잠금이 겹치지 않게 15분 늦게 돌립니다.

```yaml
# 허브의 상태 백업. TimescaleDB 는 파일 대신 pg_dump 로, Grafana 는 볼륨 디렉터리를 restic 스냅샷으로 원격 NAS 에 올립니다.
# Prometheus·모델 캐시처럼 다시 만들 수 있는 볼륨은 넣지 않습니다. 비밀 값은 create-backup-secrets.sh 가 만듭니다.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup
spec:
  schedule: "45 3 * * *"                 # 매일 03:45 (엣지 백업과 겹치지 않게)
  timeZone: Asia/Seoul
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: Never
          nodeSelector:
            kubernetes.io/hostname: k8s-worker-1   # local-path 볼륨이 있는 노드
          imagePullSecrets:
            - name: ghcr-pull
          securityContext:
            runAsUser: 0                 # 볼륨 디렉터리를 읽으려면 root 여야 합니다(읽기 전용 마운트)
          containers:
            - name: backup
              image: ghcr.io/[OWNER]/backup:1
              envFrom:
                - secretRef: { name: backup-credentials }   # RESTIC_*, TUNNEL_SERVICE_TOKEN_*, PGPASSWORD
              env:
                - { name: RESTIC_HOST, value: hub }
                - { name: PGHOST, value: timescaledb.timescaledb.svc.cluster.local }
                - { name: PGUSER, value: iot }
                - { name: PGDATABASE, value: iot }
                - { name: BACKUP_PATHS, value: "/volumes/*_monitoring_monitoring-grafana" }   # 셸이 펼칩니다
              volumeMounts:
                - { name: volumes, mountPath: /volumes, readOnly: true }
                - { name: ssh, mountPath: /secrets/ssh, readOnly: true }
              resources:
                requests: { cpu: 50m, memory: 128Mi }
                limits: { memory: 1Gi }
          volumes:
            - name: volumes
              hostPath: { path: /opt/local-path-provisioner, type: Directory }
            - name: ssh
              secret: { secretName: backup-ssh, defaultMode: 0400 }
```
{: file="services/backup/cronjob.yaml" }

```bash
git add iot/edge/backup iot/clusters/[SITE]/backup services/backup
git commit -m "feat(backup): 엣지·허브 원격 백업 CronJob 추가"
git push
```

- **확인:** Argo CD 에 `[SITE]-backup` 과 `backup` Application 이 `Synced`, `Healthy` 입니다.

## 5. 첫 백업

CronJob 을 기다리지 않고 Job 을 바로 만들어 확인합니다. 처음 실행한 쪽이 저장소를 만들므로, 엣지가 끝난 뒤 허브를 실행합니다.

```bash
# control plane
E="--kubeconfig $HOME/k3s-[SITE].yaml"
kubectl $E -n backup create job backup-first --from=cronjob/backup
kubectl $E -n backup wait --for=condition=complete --timeout=900s job/backup-first
kubectl $E -n backup logs job/backup-first | tail -5

kubectl -n backup create job backup-first --from=cronjob/backup
kubectl -n backup wait --for=condition=complete --timeout=900s job/backup-first
kubectl -n backup logs job/backup-first | tail -8
```

- **확인:** 엣지 로그에 `저장소가 없어 만듭니다` 와 `snapshot … saved` 가 나오고, 허브 로그의 스냅샷 목록에 `files` 와 `db` 태그 스냅샷이 하나씩 있습니다.

## 6. 복원 연습

백업은 복원해 봐야 믿을 수 있습니다. 운영 볼륨과 DB 는 건드리지 않고, 파드 안의 임시 디렉터리와 일회용 TimescaleDB 에만 복원합니다. 엣지 스냅샷은 저장소가 같으므로 허브에서 복원해도 됩니다.

```yaml
# 복원 연습. 운영 볼륨·DB 는 건드리지 않고, 파드 안의 임시 디렉터리와 일회용 TimescaleDB 에만 복원합니다.
# 허브의 backup 네임스페이스에서 실행합니다(백업 Secret 을 그대로 씁니다). 끝나면 파드를 지웁니다.
apiVersion: v1
kind: Pod
metadata:
  name: restore-drill
  namespace: backup
spec:
  restartPolicy: Never
  imagePullSecrets: [{ name: ghcr-pull }]
  containers:
    - name: db                                   # 일회용 DB. 운영과 같은 이미지
      image: timescale/timescaledb:2.30.1-pg17
      env:
        - { name: POSTGRES_USER, value: iot }
        - { name: POSTGRES_PASSWORD, value: drill }
        - { name: POSTGRES_DB, value: postgres }
    - name: drill
      image: ghcr.io/[OWNER]/backup:1
      securityContext: { runAsUser: 0 }          # 0400 으로 마운트된 SSH 키를 읽으려면 root 여야 합니다
      envFrom: [{ secretRef: { name: backup-credentials } }]
      env:
        - { name: PGHOST, value: 127.0.0.1 }
        - { name: PGUSER, value: iot }
        - { name: PGPASSWORD, value: drill }
      volumeMounts:
        - { name: ssh, mountPath: /secrets/ssh, readOnly: true }
      command: ["/bin/sh", "-c"]
      args:
        - |
          export HOME=/tmp
          uh=${RESTIC_REPOSITORY#sftp:}; uh=${uh%%:*}
          C="ssh -i /secrets/ssh/id_ed25519 -o UserKnownHostsFile=/secrets/ssh/known_hosts -o StrictHostKeyChecking=yes -o 'ProxyCommand=cloudflared access ssh --hostname %h' $uh -s sftp"
          r() { restic -o sftp.command="$C" "$@" 2>/dev/null; }
          echo "== 스냅샷"; r snapshots
          echo "== 엣지 파일 복원"; r restore latest --host edge-[SITE] --tag files --target /restore | tail -1
          for d in /restore/data/*; do echo "  $(find "$d" -type f | wc -l) 파일  $(basename "$d")"; done
          echo "== DB 복원"; until pg_isready -q; do sleep 2; done; sleep 3
          r dump latest --host hub --tag db /iot.dump > /restore/iot.dump
          psql -d postgres -qc "create database iot"
          psql -d iot -qc "create extension if not exists timescaledb" -c "select timescaledb_pre_restore()" >/dev/null
          pg_restore -d iot --no-owner --no-privileges /restore/iot.dump; echo "  pg_restore 종료 코드 $?"
          psql -d iot -qc "select timescaledb_post_restore()" >/dev/null
          psql -d iot -Atc "select '  하이퍼테이블 ' || hypertable_name from timescaledb_information.hypertables"
  volumes:
    - name: ssh
      secret: { secretName: backup-ssh, defaultMode: 0400 }
```
{: file="restore-drill.yaml" }

```bash
# control plane. 끝나면 로그를 보고 파드를 지웁니다
kubectl apply -f restore-drill.yaml
# 컨테이너가 뜰 때까지 기다렸다가 끝날 때까지 로그를 따라갑니다
until kubectl -n backup logs -f restore-drill -c drill 2>/dev/null; do sleep 5; done
kubectl -n backup delete pod restore-drill
```

- **확인:** 엣지 복원에서 볼륨마다 파일 수가 나오고, `pg_restore 종료 코드 0` 뒤에 운영 DB 와 같은 하이퍼테이블 이름이 나옵니다. 복원한 `coordinator_backup.json` 의 `sha256sum` 이 엣지 노드의 원본과 같으면 파일 내용까지 맞는 것입니다.

실제로 되살릴 때는 같은 방법으로 받은 파일을 새 PVC 디렉터리에 복사하고, DB 는 `timescaledb_pre_restore()` 와 `timescaledb_post_restore()` 사이에서 `pg_restore` 합니다.

## 트러블슈팅

<details markdown="1">
<summary><code>kex_exchange_identification: Connection closed by remote host</code></summary>

- **원인:** DSM 자동 차단이 `::1` 을 막았습니다. 터널로 들어온 접속은 모두 NAS 자신의 주소에서 온 것으로 보이므로, 등록되지 않은 키로 몇 번 실패하면 모든 터널 SSH 가 막힙니다. cloudflared 로그에는 오류가 남지 않습니다.
- **해결:** 자동 차단 목록에서 `::1`(또는 `127.0.0.1`)을 지우고 허용 목록에 넣습니다.

</details>

<details markdown="1">
<summary><code>subsystem request failed on channel 0</code></summary>

- **원인:** DSM 의 SFTP 포트가 SSH 포트와 다릅니다. 이때 22번 접속에서는 셸은 되지만 SFTP 는 열리지 않습니다.
- **해결:** SFTP 포트를 `22` 로 바꿉니다.

</details>

<details markdown="1">
<summary><code>No ED25519 host key is known for nas-ssh… Host key verification failed</code></summary>

- **원인:** 백업 이미지의 기본 사용자는 postgres(UID 70)인데, `backup-ssh` Secret 은 0400(root 만 읽기)으로 마운트됩니다. 호스트 키 파일을 읽지 못해 알 수 없는 호스트로 판단합니다.
- **해결:** 파드나 컨테이너에 `securityContext.runAsUser: 0` 을 줍니다. CronJob 과 복원 연습 매니페스트에 들어 있습니다.

</details>

<details markdown="1">
<summary><code>pg_restore: error: could not execute query: ERROR:  role "grafana" does not exist</code></summary>

- **원인:** 덤프에는 테이블 권한(GRANT)이 들어 있지만 역할(role)은 DB 서버 전체의 것이라 `pg_dump` 에 들어가지 않습니다. 새 서버에 그 역할이 없으면 권한 부여만 실패합니다.
- **해결:** 복원 연습에서는 `--no-privileges` 로 권한을 건너뜁니다. 실제로 되살릴 때는 역할을 먼저 만들고 복원합니다.

</details>

## 마무리

허브와 엣지 클러스터의 다시 만들 수 없는 상태를 매일 restic 스냅샷으로 원격 NAS 에 올리고, 일회용 파드로 복원까지 확인했습니다. NAS 쪽에는 공인 포트가 열려 있지 않고, 경로는 Cloudflare Access 서비스 토큰과 SSH 키 두 가지로 보호됩니다. 스냅샷은 일 7개, 주 4개, 월 6개를 남깁니다. 새 지역은 `iot/clusters/<지역>/backup` 오버레이를 추가하고 그 클러스터로 비밀 스크립트를 다시 실행하면 같은 저장소에 붙습니다.

## 참고 자료

- [restic - Preparing a new repository (SFTP)](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#sftp)
- [restic - Restoring from backup](https://restic.readthedocs.io/en/stable/050_restore.html)
- [Cloudflare - Connect to SSH with client-side cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/use-cases/ssh/ssh-cloudflared-authentication/)
- [Cloudflare - Service tokens](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/)
- [Timescale - Logical backups with pg_dump and pg_restore](https://docs.timescale.com/self-hosted/latest/backup-and-restore/logical-backup/)
