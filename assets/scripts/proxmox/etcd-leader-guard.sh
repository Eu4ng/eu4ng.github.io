#!/usr/bin/env bash
#
# etcd 리더가 원격 투표자(etcd-witness*, 서울 NAS)이면 이 노드로 리더를 옮깁니다. control plane 노드마다 서비스로 돕니다
# (playbooks/k8s-cluster.yml 이 설치). 원격 투표자는 표만 보태는 멤버인데 etcd 에는 리더가 되지 못하게 하는 설정이 없습니다.
# 선거 대기 시간을 최대값으로 둔 것(k8s-gitops stacks/seoul/etcd-witness*)이 뚫렸을 때의 안전망입니다.
# API 서버가 멈춰도 돌아야 하므로 쿠버네티스 밖에서, etcd 의 HTTP API 를 curl 로 부릅니다(노드에 etcdctl 이 없음).
#
# 사용법: etcd-leader-guard.sh [--once]      --once 는 한 번만 확인하고 끝냅니다. 없으면 INTERVAL 초마다 반복합니다.
# 필요: curl, jq, /etc/kubernetes/pki/etcd 의 인증서(root)

set -uo pipefail

PKI=${PKI:-/etc/kubernetes/pki/etcd}
LOCAL=${LOCAL:-https://127.0.0.1:2379}
WITNESS_PREFIX=${WITNESS_PREFIX:-etcd-witness}
INTERVAL=${INTERVAL:-30}

api() {  # URL, 본문, [시간 제한(초)]
  curl -sS --fail -m "${3:-5}" --cacert "$PKI/ca.crt" --cert "$PKI/healthcheck-client.crt" --key "$PKI/healthcheck-client.key" \
    -X POST "$1" -d "$2"
}

check() {
  local status leader me members name url
  status=$(api "$LOCAL/v3/maintenance/status" '{}' 2>/dev/null) || return 0   # 이 노드의 etcd 가 응답하지 않으면 할 일이 없음
  leader=$(jq -r '.leader // "0"' <<<"$status")
  me=$(jq -r '.header.member_id' <<<"$status")
  [ "$leader" != 0 ] && [ "$leader" != "$me" ] || return 0                     # 리더가 없거나(선거 중) 이 노드가 리더
  # linearizable=false: 리더가 멈춰 있어도 이 노드가 아는 멤버 목록으로 답합니다
  members=$(api "$LOCAL/v3/cluster/member/list" '{"linearizable":false}') || return 1
  name=$(jq -r --arg id "$leader" '.members[] | select(.ID == $id) | .name' <<<"$members")
  case "$name" in "$WITNESS_PREFIX"*) ;; *) return 0 ;; esac
  url=$(jq -r --arg id "$leader" '.members[] | select(.ID == $id) | .clientURLs[0]' <<<"$members")
  echo "리더가 원격 투표자 $name 입니다. 이 노드로 옮깁니다."
  # 리더를 옮기는 요청은 지금 리더가 받아야 합니다. 다른 control plane 이 먼저 옮겼으면 실패하지만 다음 확인에서 걸러집니다
  if api "$url/v3/maintenance/transfer-leadership" "{\"targetID\":\"$me\"}" 20 >/dev/null; then
    echo "리더를 옮겼습니다."
  else
    echo "리더를 옮기지 못했습니다. 다음 확인 때 다시 시도합니다." >&2
    return 1
  fi
}

if [ "${1:-}" = --once ]; then
  check
  exit
fi
while true; do
  check || true
  sleep "$INTERVAL"
done
