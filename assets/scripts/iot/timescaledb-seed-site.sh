#!/usr/bin/env bash
#
# 허브 DB 에 있는 한 지역의 기록(readings, events)을 그 지역 DB(iot/edge/timescaledb)로 채웁니다. 여러 번 실행해도 됩니다.
# 지역 DB 를 새로 만들었을 때(지역 DB 가 생기기 전의 기록, 지역 DB 를 다시 만든 경우) 실행합니다.
# 지역 DB 에 이미 있는 행(모든 컬럼이 같은 행)은 넣지 않습니다. 테이블이 아직 없으면(Telegraf 가 아직 안 만듦) 그 테이블은 건너뜁니다.
#
# 사용법: bash scripts/timescaledb-seed-site.sh <SITE> <EDGE_KUBECONFIG>
#   EDGE_KUBECONFIG 는 허브 kubectl 호스트 기준 경로. 예: bash scripts/timescaledb-seed-site.sh daejeon /home/ubuntu/k8s-daejeon.yaml

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
KUBECTL_HOST=ubuntu@[CONTROL_PLANE_IP]      # 허브 kubectl 을 실행하는 곳(내부망 DNS 의 역할 이름)
TABLES="readings events"
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
SITE=${1:-}; EDGE_KUBECONFIG=${2:-}
[[ "$SITE" =~ ^[a-z0-9-]+$ && -n "$EDGE_KUBECONFIG" ]] || die "사용법: bash scripts/timescaledb-seed-site.sh <SITE> <EDGE_KUBECONFIG>"

# 주 DB 파드(Patroni 가 role=primary 라벨을 붙임)
primary() { ssh "$KUBECTL_HOST" "kubectl $1 -n timescaledb get pod -l role=primary -o jsonpath='{.items[0].metadata.name}'"; }
HUB_POD=$(primary "") ; EDGE_POD=$(primary "--kubeconfig $EDGE_KUBECONFIG")
[ -n "$HUB_POD" ] && [ -n "$EDGE_POD" ] || die "주 DB 파드를 찾지 못했습니다 (허브: '$HUB_POD', 지역: '$EDGE_POD')"
HUB_PSQL="kubectl -n timescaledb exec -i $HUB_POD -c timescaledb -- psql -X -q -v ON_ERROR_STOP=1 -U postgres -d iot"
EDGE_PSQL="kubectl --kubeconfig $EDGE_KUBECONFIG -n timescaledb exec -i $EDGE_POD -- psql -X -q -v ON_ERROR_STOP=1 -U postgres -d iot"
echo "허브 $HUB_POD → 지역 $EDGE_POD ($SITE)"

for t in $TABLES; do
  log "$t"
  # 두 DB 에 모두 있는 컬럼만, 지역 테이블의 순서로 옮깁니다(Telegraf 가 나중에 붙인 컬럼이 한쪽에만 있을 수 있음)
  q="SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$t'"
  edge_cols=$(ssh "$KUBECTL_HOST" "$EDGE_PSQL -At" <<<"$q")
  hub_cols=$(ssh "$KUBECTL_HOST" "$HUB_PSQL -At" <<<"$q")
  [ -n "$edge_cols" ] || { echo "  지역 DB 에 $t 가 아직 없어 건너뜁니다(Telegraf 가 첫 행을 쓸 때 만듭니다)"; continue; }
  cols=$(python3 -c 'import sys; h=set(sys.argv[2].split(",")); print(",".join(c for c in sys.argv[1].split(",") if c in h))' "$edge_cols" "$hub_cols")
  before=$(ssh "$KUBECTL_HOST" "$EDGE_PSQL -At" <<<"SELECT count(*) FROM $t WHERE site = '$SITE'")
  # 허브에서 COPY TO STDOUT 으로 받은 행을 지역의 임시 테이블에 COPY FROM STDIN 으로 넣고, 지역에 없는 행만 옮깁니다.
  # EXCEPT 는 NULL 끼리도 같다고 보므로 비어 있는 태그 컬럼이 있어도 같은 행을 걸러 냅니다.
  {
    echo "BEGIN; CREATE TEMP TABLE s AS SELECT $cols FROM $t WITH NO DATA; COPY s FROM STDIN;"
    ssh "$KUBECTL_HOST" "$HUB_PSQL" <<<"COPY (SELECT $cols FROM $t WHERE site = '$SITE') TO STDOUT"
    echo '\.'
    echo "INSERT INTO $t ($cols) SELECT * FROM s EXCEPT SELECT $cols FROM $t WHERE site = '$SITE' AND time >= (SELECT min(time) FROM s); COMMIT;"
  } | ssh "$KUBECTL_HOST" "$EDGE_PSQL"
  after=$(ssh "$KUBECTL_HOST" "$EDGE_PSQL -At" <<<"SELECT count(*) FROM $t WHERE site = '$SITE'")
  hub=$(ssh "$KUBECTL_HOST" "$HUB_PSQL -At" <<<"SELECT count(*) FROM $t WHERE site = '$SITE'")
  echo "  지역 $before → $after 행 (허브 $hub 행)"
done
log "완료"
