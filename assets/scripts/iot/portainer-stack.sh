#!/usr/bin/env bash
#
# 이 저장소의 Swarm 스택 파일(swarm/<지역>/<이름>/stack.yml)을 그 지역 Portainer 에 "Git 저장소 스택"으로 등록하거나 다시 배포합니다.
# 원본은 k8s-gitops 의 scripts/portainer-stack.sh 이고, 지역(Portainer)이 여럿이라 설정 폴더를 프로필로 고르게 바꿨습니다.
# Portainer Community Edition 은 Git 인증 정보를 저장해 두는 기능이 없어, 스택마다 폼에 토큰을 넣는 대신 이 스크립트가 API 로 등록합니다.
# 스택 파일이 external secret 을 쓰면 값 파일에서 Swarm secret 을 먼저 만듭니다(이미 있으면 건너뜀). 여러 번 실행해도 됩니다.
#
# 사용법: bash scripts/portainer-stack.sh <프로필> <stack.yml 경로> [스택 이름]     (스택 이름 기본값: 폴더 이름)
# 준비(저장소 밖, 권한 600):
#   ~/.config/portainer-<프로필>/url, api-key   scripts/pi-bootstrap.sh 가 만듭니다
#   ~/.config/github/project-iot-pat           GitHub fine-grained 토큰 (이 저장소만, Contents: Read-only)
#   ~/.config/portainer-<프로필>/secrets/<이름>  external secret 의 값 (스택이 쓰는 것만)
# 필요: curl, python3(PyYAML)

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
REPO_URL=https://github.com/[OWNER]/project-iot
REPO_REF=refs/heads/main
REPO_USER=[OWNER]
AUTO_UPDATE=5m                           # Portainer 가 저장소를 확인하는 주기 (GitOps updates)
ENDPOINT_NAME=                           # Portainer 환경 이름. 비우면 첫 Swarm 환경
# --------------------------------------

CONF=$HOME/.config
log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

PROFILE=${1:-}
STACK_FILE=${2:-}
[[ "$PROFILE" =~ ^[a-z0-9-]+$ && -f "$STACK_FILE" ]] || die "사용법: bash scripts/portainer-stack.sh <프로필> <stack.yml 경로> [스택 이름]"
STACK_NAME=${3:-$(basename "$(dirname "$STACK_FILE")")}
PCONF=$CONF/portainer-$PROFILE
for f in $PCONF/url $PCONF/api-key $CONF/github/project-iot-pat; do [ -s "$f" ] || die "$f 가 없습니다."; done
# 저장소 루트 기준 경로 (Portainer 가 저장소를 받아 이 경로의 파일을 씁니다)
REPO_ROOT=$(git -C "$(dirname "$STACK_FILE")" rev-parse --show-toplevel)
COMPOSE_PATH=$(realpath --relative-to="$REPO_ROOT" "$STACK_FILE")
git -C "$REPO_ROOT" diff --quiet "origin/main" -- "$COMPOSE_PATH" 2>/dev/null \
  || echo "주의: $COMPOSE_PATH 가 원격 main 과 다릅니다. Portainer 는 원격 저장소의 파일을 씁니다(먼저 push)."

export PORTAINER_URL=$(cat "$PCONF/url") PORTAINER_KEY=$(cat "$PCONF/api-key") GITHUB_PAT=$(cat "$CONF/github/project-iot-pat")
export STACK_FILE STACK_NAME COMPOSE_PATH REPO_URL REPO_REF REPO_USER AUTO_UPDATE ENDPOINT_NAME SECRETS_DIR=$PCONF/secrets

python3 - <<'PY'
import base64, json, os, sys, urllib.error, urllib.request
import yaml

url, key = os.environ["PORTAINER_URL"].rstrip("/"), os.environ["PORTAINER_KEY"]

def api(method, path, body=None):
    req = urllib.request.Request(url + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"X-API-Key": key, "Content-Type": "application/json",
                                          # Cloudflare 가 파이썬 기본 User-Agent 를 봇으로 막으므로(error 1010) 이름을 붙입니다
                                          "User-Agent": "project-iot-portainer-stack/1"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"API 오류 {method} {path}: {e.code} {e.read().decode()[:300]}")

# 1. Swarm 환경
eps = api("GET", "/api/endpoints")
name = os.environ["ENDPOINT_NAME"]
cands = [e for e in eps if (e["Name"] == name if name else True)]
ep = None
for e in cands:
    try:
        swarm = api("GET", f"/api/endpoints/{e['Id']}/docker/swarm")
        ep = e; break
    except SystemExit:
        continue
if not ep: sys.exit("Swarm 환경을 찾지 못했습니다. ENDPOINT_NAME 을 확인하세요.")
eid, swarm_id = ep["Id"], swarm["ID"]
print(f"- 환경: {ep['Name']} (id {eid}), Swarm {swarm_id[:12]}")

# 2. external secret
doc = yaml.safe_load(open(os.environ["STACK_FILE"]))
wanted = [(k, (v or {}).get("name", k)) for k, v in (doc.get("secrets") or {}).items() if (v or {}).get("external")]
have = {s["Spec"]["Name"] for s in api("GET", f"/api/endpoints/{eid}/docker/secrets")}
for key_name, sec_name in wanted:
    if sec_name in have:
        print(f"- secret {sec_name}: 있음, 건너뜀"); continue
    path = os.path.join(os.environ["SECRETS_DIR"], sec_name)
    if not os.path.isfile(path):
        sys.exit(f"secret {sec_name} 이 Portainer 에 없고 값 파일 {path} 도 없습니다.")
    data = open(path, "rb").read().strip()
    api("POST", f"/api/endpoints/{eid}/docker/secrets/create", {"Name": sec_name, "Data": base64.b64encode(data).decode()})
    print(f"- secret {sec_name}: 만듦")

# 3. 스택 등록 또는 재배포
stack_name = os.environ["STACK_NAME"]
git = {"RepositoryReferenceName": os.environ["REPO_REF"], "RepositoryAuthentication": True,
       "RepositoryUsername": os.environ["REPO_USER"], "RepositoryPassword": os.environ["GITHUB_PAT"]}
existing = [s for s in api("GET", "/api/stacks") if s["Name"] == stack_name and s.get("EndpointId") == eid]
if existing:
    sid = existing[0]["Id"]
    api("PUT", f"/api/stacks/{sid}/git/redeploy?endpointId={eid}", {**git, "Prune": True, "RepullImageAndRedeploy": False})
    print(f"- 스택 {stack_name}: 있음, 저장소의 최신 파일로 다시 배포 (id {sid})")
else:
    body = {"Name": stack_name, "SwarmID": swarm_id, "RepositoryURL": os.environ["REPO_URL"], **git,
            "ComposeFile": os.environ["COMPOSE_PATH"], "AutoUpdate": {"Interval": os.environ["AUTO_UPDATE"]}}
    s = api("POST", f"/api/stacks/create/swarm/repository?endpointId={eid}", body)
    sid = s["Id"]
    print(f"- 스택 {stack_name}: 만듦 (id {sid})")

# 4. 자동 반영 주기
# Portainer 2.44 부터 저장소 확인 주기는 스택이 아니라 스택이 가리키는 Git Source 에 둡니다. 스택의 AutoUpdate.Interval 만
# 주면 Source 는 주기 없이 만들어져 자동 반영이 일어나지 않습니다. 그보다 옛 버전(Source 가 없음)은 스택 설정으로 충분합니다.
source_id = api("GET", f"/api/stacks/{sid}").get("GitSourceId")
if source_id:
    api("PUT", f"/api/gitops/sources/{source_id}", {"interval": os.environ["AUTO_UPDATE"]})
    print(f"- Git Source {source_id}: {os.environ['AUTO_UPDATE']} 마다 저장소 확인")
else:
    print(f"- 스택 설정으로 {os.environ['AUTO_UPDATE']} 마다 저장소 확인 (Git Source 없는 버전)")
PY

log "완료. Portainer 의 Stacks 에서 $STACK_NAME 을 확인합니다."
