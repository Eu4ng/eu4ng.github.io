#!/usr/bin/env bash
#
# 지역 호스트(라즈베리파이 등 Debian)에 Docker 와 Swarm 을 올리고, GitOps 배포기인 Portainer 를 띄운 뒤 관리자와 API 토큰을 API 로 만듭니다.
# 작업 PC 에서 실행합니다(ssh 키로 대상에 접속, 대상의 sudo 는 비밀번호 없이 되어야 함). 여러 번 실행해도 결과가 같습니다.
#
# 사용법: bash scripts/pi-bootstrap.sh <프로필> <ssh 대상> <지역>
#   예: bash scripts/pi-bootstrap.sh pi pi@[PI_IP] [SITE]
# 결과(작업 PC, 권한 600): ~/.config/portainer-<프로필>/url, admin-password, api-key
# 다음 단계: bash scripts/portainer-stack.sh <프로필> swarm/<지역>/<스택>/stack.yml

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
PORTAINER_PORT=9000              # swarm/<지역>/portainer/stack.yml 의 HTTP 게시 포트
PORTAINER_ADMIN=admin
TOKEN_DESCRIPTION=project-iot    # API 토큰 이름
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
log "사전 검사"
PROFILE=${1:-}; TARGET=${2:-}; SITE=${3:-}
[[ "$PROFILE" =~ ^[a-z0-9-]+$ && -n "$TARGET" && "$SITE" =~ ^[a-z0-9-]+$ ]] \
  || die "사용법: bash scripts/pi-bootstrap.sh <프로필> <ssh 대상> <지역>"
REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
PORTAINER_STACK=$REPO_ROOT/swarm/$SITE/portainer/stack.yml
[ -f "$PORTAINER_STACK" ] || die "$PORTAINER_STACK 이 없습니다."
HOST=${TARGET#*@}
CONF=$HOME/.config/portainer-$PROFILE
mkdir -p "$CONF/secrets" && chmod 700 "$CONF" "$CONF/secrets"
ssh -o BatchMode=yes "$TARGET" 'sudo -n true' 2>/dev/null \
  || die "$TARGET 에서 sudo 가 비밀번호를 요구합니다. 한 번만: ssh -t $TARGET 'echo \"\$USER ALL=(ALL) NOPASSWD: ALL\" | sudo tee /etc/sudoers.d/010_\$USER-nopasswd && sudo chmod 440 /etc/sudoers.d/010_\$USER-nopasswd'"
command -v curl >/dev/null && command -v python3 >/dev/null || die "작업 PC 에 curl, python3 이 필요합니다."

# ---------- 2. Docker ----------
# Docker 공식 apt 저장소(Debian). 이미 있으면 설치를 건너뜁니다.
log "$TARGET: Docker"
ssh "$TARGET" 'bash -s' <<'EOF'
set -euo pipefail
if ! command -v docker >/dev/null; then
  . /etc/os-release
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
sudo systemctl enable --now docker >/dev/null
id -nG | grep -qw docker || sudo usermod -aG docker "$USER"
sudo docker version --format 'Docker {{.Server.Version}}'
EOF

# ---------- 3. Swarm ----------
log "$TARGET: Swarm"
ssh "$TARGET" "sudo docker info --format '{{.Swarm.LocalNodeState}}' | grep -qx active || sudo docker swarm init --advertise-addr $HOST >/dev/null; sudo docker node ls"

# ---------- 4. Portainer ----------
log "$TARGET: Portainer 스택"
scp -q "$PORTAINER_STACK" "$TARGET:/tmp/portainer-stack.yml"
ssh "$TARGET" 'sudo docker stack deploy -c /tmp/portainer-stack.yml portainer >/dev/null && rm /tmp/portainer-stack.yml'
URL=http://$HOST:$PORTAINER_PORT
for _ in $(seq 60); do curl -fs -o /dev/null "$URL/api/system/status" && break; sleep 5; done
curl -fs -o /dev/null "$URL/api/system/status" || die "Portainer 가 $URL 에서 응답하지 않습니다."
echo "$URL" > "$CONF/url"; chmod 600 "$CONF/url"

# ---------- 5. 관리자와 API 토큰 ----------
# 관리자는 Portainer 가 뜬 뒤 5분 안에, 시작 로그에 찍히는 설정 토큰(X-Setup-Token)을 붙여 만들어야 합니다(2.45 부터).
# 관리자가 아직 없으면 portainer 서비스를 다시 띄워 새 5분과 새 토큰을 받은 뒤 바로 만듭니다.
log "Portainer 관리자와 API 토큰"
[ -s "$CONF/admin-password" ] || (umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(24))' > "$CONF/admin-password")
SETUP_TOKEN=
if [ "$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/users/admin/check")" = 404 ]; then
  RESTARTED=$(ssh "$TARGET" 'date -u +%Y-%m-%dT%H:%M:%SZ; sudo docker service update --force --quiet portainer_portainer >/dev/null' | head -1)
  for _ in $(seq 60); do
    SETUP_TOKEN=$(ssh "$TARGET" "sudo docker service logs --raw --since $RESTARTED portainer_portainer 2>&1" | sed -n 's/.*setup_token=\([A-Za-z0-9_-]*\).*/\1/p' | tail -1)
    [ -n "$SETUP_TOKEN" ] && curl -fs -o /dev/null "$URL/api/system/status" && break
    sleep 5
  done
  [ -n "$SETUP_TOKEN" ] || die "Portainer 로그에서 설정 토큰을 찾지 못했습니다."
fi
export URL CONF PORTAINER_ADMIN TOKEN_DESCRIPTION SETUP_TOKEN
python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

url, conf = os.environ["URL"], os.environ["CONF"]
user, password = os.environ["PORTAINER_ADMIN"], open(f"{conf}/admin-password").read().strip()

def api(method, path, body=None, headers=None):
    req = urllib.request.Request(url + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300]

status, _ = api("GET", "/api/users/admin/check")
if status == 404:
    status, body = api("POST", "/api/users/admin/init", {"Username": user, "Password": password},
                       {"X-Setup-Token": os.environ["SETUP_TOKEN"]})
    if status != 200:
        sys.exit(f"관리자 초기화 실패 {status}: {body}")
    print("- 관리자 만듦")
else:
    print("- 관리자 있음")

key_file = f"{conf}/api-key"
if not (os.path.isfile(key_file) and os.path.getsize(key_file)):
    status, body = api("POST", "/api/auth", {"Username": user, "Password": password})
    if status != 200:
        sys.exit(f"로그인 실패 {status}: {body} (관리자 비밀번호가 {conf}/admin-password 와 다르면 Portainer 볼륨을 지우고 다시 시작)")
    auth = {"Authorization": f"Bearer {body['jwt']}"}
    _, me = api("GET", "/api/users/me", headers=auth)
    status, body = api("POST", f"/api/users/{me['Id']}/tokens", {"description": os.environ["TOKEN_DESCRIPTION"], "password": password}, auth)
    if status not in (200, 201):
        sys.exit(f"API 토큰 발급 실패 {status}: {body}")
    old = os.umask(0o077)
    open(key_file, "w").write(body["rawAPIKey"] + "\n")
    os.umask(old)
    print("- API 토큰 만듦")
else:
    print("- API 토큰 있음")

key = open(key_file).read().strip()
for _ in range(30):
    status, eps = api("GET", "/api/endpoints", headers={"X-API-Key": key})
    if status == 200 and eps:
        break
    import time; time.sleep(2)
if status != 200 or not eps:
    sys.exit(f"Swarm 환경이 생기지 않았습니다: {status} {eps}")
for e in eps:
    print(f"- 환경: {e['Name']} (id {e['Id']}, {e['URL']})")
PY

log "완료. 다음: bash scripts/portainer-stack.sh $PROFILE swarm/$SITE/<스택>/stack.yml"
