#!/usr/bin/env bash
#
# Home Assistant 에 IoT 스택용 통합(MQTT, Matter, OpenThread Border Router)을 API 로 추가합니다. 웹 UI 의
# "기기 및 서비스 > 통합구성요소 추가" 와 같은 설정 흐름(config flow)을 순서대로 밟습니다. 이미 있는 통합은 건너뜁니다.
# 역방향 프록시(허브 Traefik) 뒤에서 접속받도록 HA 의 HTTP 설정(프록시 신뢰, 로그인 실패 차단)도 API 로 바꿉니다.
# 중앙 HA 에서는 MQTT·Matter·OTBR 을 비우고 REMOTES 에 지역 HA 를 적으면 Remote Home Assistant 로 지역 엔티티를 모읍니다.
# HA 에 접속할 수 있는 곳에서 실행합니다: bash setup-home-assistant.sh [HA_URL]   (예: http://[EDGE_IP]:8123)
# 준비: HA 프로필 > 보안 > 장기 액세스 토큰 에서 토큰을 만들어 엣지 클러스터 Secret 에 넣어 둡니다(아래 HA_TOKEN_SECRET).
#       kubectl 로 그 Secret 을 읽을 수 없으면 실행 중 토큰을 입력받습니다. MQTT 비밀번호는 실행 중 입력받습니다.

set -euo pipefail

# ---------- 환경에 맞게 수정 ----------
MQTT_BROKER=mosquitto.mosquitto.svc.cluster.local   # HA 가 hostNetwork + ClusterFirstWithHostNet 이라 클러스터 이름이 풀립니다
MQTT_PORT=1883
MQTT_USER=homeassistant
MATTER_URL=ws://127.0.0.1:5580/ws                   # 같은 노드의 hostNetwork 파드(matter-server)
OTBR_URL=http://127.0.0.1:8081                      # 같은 노드의 hostNetwork 파드(otbr). OTBR 이 없으면 비워 둡니다
# Cloudflare 프록시 대역(https://www.cloudflare.com/ips-v4). 밖에서 Cloudflare 를 거쳐 오면 이 대역까지 신뢰해야 HA 가 실제 접속자 IP 를 보고,
# 로그인 실패 차단도 Cloudflare 주소가 아니라 그 접속자에게 겁니다.
CLOUDFLARE_IPV4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
TRUSTED_PROXIES="[HUB_NODE_IP_1] [HUB_NODE_IP_2] $CLOUDFLARE_IPV4"   # HA 앞 역방향 프록시 주소(허브 파드 요청은 허브 노드 주소로 들어옴)와 Cloudflare. 비우면 HTTP 설정 생략
LOGIN_ATTEMPTS=5                                    # 로그인 실패가 이 횟수면 그 IP 를 차단
HA_TOKEN_SECRET=home-assistant/ha-api-token         # 토큰을 담은 Secret (네임스페이스/이름, 키 token)
KUBECTL="kubectl --kubeconfig $HOME/k3s-[SITE].yaml"   # 이 HA 가 있는 클러스터에 접근하는 kubectl
# 중앙 HA 전용: 모아 볼 지역 HA. "엔티티접두사|주소:포트|지역클러스터 kubeconfig|표시이름접두사" 를 공백으로 구분.
# 지역 HA 의 토큰은 그 클러스터의 HA_TOKEN_SECRET 에서 읽습니다. 지역 HA 에도 Remote Home Assistant 가 설치돼 있어야 합니다.
REMOTES=""                                          # 예: "dj_|[EDGE_IP]:8123|$HOME/k3s-[SITE].yaml|대전 "
# --------------------------------------

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }
die() { echo -e "\033[1;31m[오류]\033[0m $*" >&2; exit 1; }
trap 'echo -e "\033[1;31m[오류]\033[0m ${LINENO}번째 줄에서 중단되었습니다." >&2' ERR

# ---------- 1. 사전 검사 ----------
log "사전 검사"
HA_URL=${1:-}
[[ "$HA_URL" =~ ^https?:// ]] || die "사용법: bash setup-home-assistant.sh [HA_URL]"
command -v python3 >/dev/null || die "python3 이 필요합니다."
HA_TOKEN=$($KUBECTL -n "${HA_TOKEN_SECRET%%/*}" get secret "${HA_TOKEN_SECRET#*/}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
if [ -n "$HA_TOKEN" ]; then echo "HA 토큰: Secret $HA_TOKEN_SECRET 에서 읽음"; else read -rsp "HA 장기 액세스 토큰: " HA_TOKEN; echo; fi
MQTT_PASSWORD=""
[ -z "$MQTT_BROKER" ] || { read -rsp "MQTT 비밀번호 ($MQTT_USER): " MQTT_PASSWORD; echo; [ -n "$MQTT_PASSWORD" ] || die "MQTT 비밀번호가 비어 있습니다."; }
[ -n "$HA_TOKEN" ] || die "HA 토큰이 비어 있습니다."
# 지역 HA 토큰을 각 클러스터에서 읽어 JSON 으로 넘깁니다.
REMOTES_JSON="[]"
for r in $REMOTES; do
  IFS='|' read -r prefix hostport kcfg fname <<<"$r"
  rt=$(kubectl --kubeconfig "$kcfg" -n "${HA_TOKEN_SECRET%%/*}" get secret "${HA_TOKEN_SECRET#*/}" -o jsonpath='{.data.token}' | base64 -d)
  [ -n "$rt" ] || die "지역 HA 토큰을 읽지 못했습니다: $kcfg"
  REMOTES_JSON=$(python3 -c 'import json,sys; l=json.loads(sys.argv[1]); h,p=sys.argv[3].rsplit(":",1); l.append({"prefix":sys.argv[2],"host":h,"port":int(p),"token":sys.argv[4],"fname":sys.argv[5]}); print(json.dumps(l))' "$REMOTES_JSON" "$prefix" "$hostport" "$rt" "${fname:-}")
done
export HA_URL HA_TOKEN MQTT_BROKER MQTT_PORT MQTT_USER MQTT_PASSWORD MATTER_URL OTBR_URL TRUSTED_PROXIES LOGIN_ATTEMPTS REMOTES_JSON

# ---------- 2. 통합 추가 ----------
# 설정 흐름은 단계마다 폼(data_schema)을 돌려줍니다. 폼의 필드 이름을 보고 아는 값을 채워 다음 단계로 넘기고,
# 메뉴 단계는 지정한 항목을 고르며, create_entry 가 나오면 끝입니다. 모르는 폼이 나오면 흐름을 취소하고 멈춥니다.
python3 - <<'PY'
import json, os, sys, urllib.request, urllib.error

url, token = os.environ["HA_URL"].rstrip("/"), os.environ["HA_TOKEN"]

def api(method, path, body=None):
    req = urllib.request.Request(url + path, method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"API 오류 {method} {path}: {e.code} {e.read().decode()[:300]}")

try:
    api("GET", "/api/")
except SystemExit:
    sys.exit("토큰이 거부됐습니다. HA 주소와 장기 액세스 토큰을 확인하세요.")

entries = {e["domain"] for e in api("GET", "/api/config/config_entries/entry")}

# 도메인별로 폼 필드에 넣을 값과 메뉴에서 고를 항목
values = {
    "mqtt": {"broker": os.environ["MQTT_BROKER"], "port": int(os.environ["MQTT_PORT"]),
             "username": os.environ["MQTT_USER"], "password": os.environ["MQTT_PASSWORD"]},
    "matter": {"url": os.environ["MATTER_URL"]},
    "otbr": {"url": os.environ["OTBR_URL"]},
}
menus = {"mqtt": "broker"}          # MQTT 첫 단계가 메뉴일 때: 브로커 직접 입력
skips = {"matter": {"install_addon": False, "use_addon": False}}   # 애드온(HAOS 전용) 대신 기존 서버 사용

for domain in ["mqtt", "matter", "otbr"]:
    if not (values[domain].get("url") if domain != "mqtt" else values[domain]["broker"]):
        print(f"- {domain}: 주소가 비어 있어 건너뜀"); continue
    if domain in entries:
        print(f"- {domain}: 이미 있음, 건너뜀"); continue
    step = api("POST", "/api/config/config_entries/flow", {"handler": domain, "show_advanced_options": False})
    for _ in range(6):
        t = step.get("type")
        if t == "create_entry":
            print(f"- {domain}: 추가됨 ({step.get('title')})"); break
        if t == "abort":
            sys.exit(f"{domain}: 중단됨 - {step.get('reason')}")
        if t == "menu":
            choice = menus.get(domain) or step["menu_options"][0]
            step = api("POST", f"/api/config/config_entries/flow/{step['flow_id']}", {"next_step_id": choice}); continue
        if t == "form":
            fields = [f["name"] for f in step.get("data_schema", [])]
            data = {}
            for f in step.get("data_schema", []):
                n = f["name"]
                if n in values[domain]: data[n] = values[domain][n]
                elif n in skips.get(domain, {}): data[n] = skips[domain][n]
                elif f.get("type") == "expandable":   # 접힌 "고급 설정" 섹션: 기본값을 쓰고, 기본값 없는 필수 항목은 꺼 둔 상태로
                    sec = {}
                    for x in f.get("schema", []):
                        sel = x.get("selector", {})
                        if "default" in x: sec[x["name"]] = x["default"]
                        elif x.get("required") and "boolean" in sel: sec[x["name"]] = False
                        elif x.get("required") and "select" in sel:
                            o = sel["select"]["options"][0]; sec[x["name"]] = o["value"] if isinstance(o, dict) else o
                    data[n] = sec
                elif f.get("required") and "default" not in f:
                    api("DELETE", f"/api/config/config_entries/flow/{step['flow_id']}")
                    sys.exit(f"{domain}: 모르는 필수 필드 {n} (단계 {step.get('step_id')}, 필드 {fields})")
            if step.get("errors"):
                api("DELETE", f"/api/config/config_entries/flow/{step['flow_id']}")
                sys.exit(f"{domain}: 입력 오류 {step['errors']}")
            step = api("POST", f"/api/config/config_entries/flow/{step['flow_id']}", data); continue
        sys.exit(f"{domain}: 예상하지 못한 단계 {t}")
    else:
        sys.exit(f"{domain}: 단계가 끝나지 않습니다")

# 지역 HA 연결 (중앙 HA). 같은 지역을 이미 연결했으면 흐름이 already_configured 로 끝나므로 건너뜁니다.
def run_flow(step, answer, path):
    for _ in range(8):
        t = step.get("type")
        if t in ("create_entry", "abort"): return step
        if t != "form": sys.exit(f"예상하지 못한 단계 {t}")
        step = api("POST", f"{path}/{step['flow_id']}", answer(step))
    sys.exit("단계가 끝나지 않습니다")
for rm in json.loads(os.environ.get("REMOTES_JSON") or "[]"):
    def conn(step):
        if step.get("step_id") == "user": return {"type": "Add a remote node"}
        d = {f["name"]: f.get("default") for f in step.get("data_schema", [])}
        return {"host": rm["host"], "port": rm["port"], "access_token": rm["token"],
                "max_message_size": d.get("max_message_size"), "secure": False, "verify_ssl": False}
    r = run_flow(api("POST", "/api/config/config_entries/flow", {"handler": "remote_homeassistant"}), conn, "/api/config/config_entries/flow")
    if r["type"] == "abort":
        print(f"- 원격 {rm['host']}: {r.get('reason')}, 건너뜀"); continue
    eid = r["result"]["entry_id"]
    # 옵션: 엔티티·표시 이름·서비스 접두사로 지역을 구분합니다. 이후 단계(필터 등)는 기본값.
    def opts(step):
        if step.get("step_id") == "init":
            return {"entity_prefix": rm["prefix"], "entity_friendly_name_prefix": rm["fname"], "service_prefix": rm["prefix"].rstrip("_")}
        return {f["name"]: f["default"] for f in step.get("data_schema", []) if "default" in f}
    run_flow(api("POST", "/api/config/config_entries/options/flow", {"handler": eid}), opts, "/api/config/config_entries/options/flow")
    print(f"- 원격 {rm['host']}: 추가됨 (엔티티 접두사 {rm['prefix']})")

print("\n통합 상태:")
for e in api("GET", "/api/config/config_entries/entry"):
    if e["domain"] in ("mqtt", "matter", "otbr", "thread", "remote_homeassistant"):
        print(f"  {e['domain']:7} {e['state']:12} {e['title']}")
PY

# ---------- 3. Thread 기본 네트워크와 HTTP 설정 (WebSocket API) ----------
# Thread: OTBR 이 만든 데이터셋을 HA 의 기본(preferred) 네트워크로 지정합니다. 휴대폰 앱의 "Thread 자격 증명 동기화"가 이 망을 넘겨받습니다.
# HTTP: HA 2026 부터 HTTP 설정은 YAML 이 아니라 저장소(.storage/http)에 있고 WebSocket API 로 바꿉니다.
# 새 설정은 "pending" 으로 저장되고 HA 가 재시작해 적용합니다. 동작을 확인하고 promote 해야 확정되며, 하지 않으면 5분 뒤 되돌아갑니다.
log "Thread 기본 네트워크, HTTP 설정(프록시 신뢰: ${TRUSTED_PROXIES:-없음}, 로그인 실패 $LOGIN_ATTEMPTS 회 차단)"
python3 - <<'PY'
import base64, json, os, socket, sys, time, urllib.parse, urllib.request

url, token = os.environ["HA_URL"].rstrip("/"), os.environ["HA_TOKEN"]
want = {"use_x_forwarded_for": True, "trusted_proxies": os.environ["TRUSTED_PROXIES"].split(),
        "ip_ban_enabled": True, "login_attempts_threshold": int(os.environ["LOGIN_ATTEMPTS"])}

class WS:  # 표준 라이브러리만 쓰는 최소 WebSocket 클라이언트 (텍스트 프레임)
    def __init__(self):
        u = urllib.parse.urlparse(url)
        self.s = socket.create_connection((u.hostname, u.port or 80), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET /api/websocket HTTP/1.1\r\nHost: {u.netloc}\r\nUpgrade: websocket\r\n"
                        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = b""
        while b"\r\n\r\n" not in resp: resp += self.s.recv(1)
        if b" 101 " not in resp.split(b"\r\n")[0]: sys.exit("WebSocket 연결 실패: " + resp.decode(errors="replace")[:200])
        self.n = 0
        assert self.recv()["type"] == "auth_required"
        self.send({"type": "auth", "access_token": token})
        if self.recv()["type"] != "auth_ok": sys.exit("WebSocket 인증 실패")
    def _read(self, k):
        b = b""
        while len(b) < k:
            c = self.s.recv(k - len(b))
            if not c: raise ConnectionError("closed")
            b += c
        return b
    def recv(self):
        h = self._read(2); ln = h[1] & 0x7F
        if ln == 126: ln = int.from_bytes(self._read(2), "big")
        elif ln == 127: ln = int.from_bytes(self._read(8), "big")
        return json.loads(self._read(ln))
    def send(self, obj):
        d = json.dumps(obj).encode(); m = os.urandom(4); ln = len(d)
        hdr = bytes([0x81]) + (bytes([0x80 | ln]) if ln < 126 else bytes([0x80 | 126]) + ln.to_bytes(2, "big") if ln < 65536 else bytes([0x80 | 127]) + ln.to_bytes(8, "big"))
        self.s.sendall(hdr + m + bytes(b ^ m[i % 4] for i, b in enumerate(d)))
    def call(self, **cmd):
        self.n += 1; cmd["id"] = self.n; self.send(cmd)
        while True:
            r = self.recv()
            if r.get("id") == self.n and r.get("type") == "result":
                if not r["success"]: sys.exit(f"{cmd['type']} 실패: {r.get('error')}")
                return r.get("result")

try:
    ds = WS().call(type="thread/list_datasets")["datasets"]
except SystemExit:
    ds = []   # Thread 통합이 없는 HA(중앙 HA 등)
otbr = [d for d in ds if d.get("source") == "otbr"]
if len(otbr) == 1 and not otbr[0].get("preferred"):
    WS().call(type="thread/set_preferred_dataset", dataset_id=otbr[0]["dataset_id"])
    print(f"- Thread: {otbr[0]['network_name']} (채널 {otbr[0]['channel']}) 을 기본 네트워크로 지정")
elif otbr:
    print(f"- Thread: 기본 네트워크 {[d['network_name'] for d in ds if d.get('preferred')]}, 건너뜀")
else:
    print("- Thread: OTBR 데이터셋이 없어 건너뜀")

if not want["trusted_proxies"]: sys.exit(0)
norm = lambda v: [p if "/" in p else p + ("/128" if ":" in p else "/32") for p in v]
want["trusted_proxies"] = norm(want["trusted_proxies"])
cur = WS().call(type="http/config")
base = dict(cur["pending"] or cur["stable"] or cur["default"])
for k in ("created_at", "error", "error_message"): base.pop(k, None)
if all(base.get(k) == v for k, v in want.items()) and cur["pending"] is None:
    print("- 이미 같은 설정, 건너뜀"); sys.exit(0)
# 같은 설정이 pending 으로 이미 적용돼 돌고 있으면 확정만 합니다. pending 이 남아 있어도 되돌려진 상태(stable 로 동작)면 다시 넣습니다.
if not (cur["pending"] and cur["active_config_type"] == "pending" and all(base.get(k) == v for k, v in want.items())):
    base.update(want)
    r = WS().call(type="http/config/configure", config=base)
    print(f"- pending 으로 저장, 재시작: {r.get('restart')}")
# 재시작 뒤 다시 붙을 때까지 대기
for _ in range(90):
    time.sleep(5)
    try:
        c = WS().call(type="http/config")
        if c["active_config_type"] == "pending": break
    except Exception: pass
else: sys.exit("HA 가 pending 설정으로 다시 뜨지 않았습니다. HA 로그를 확인하세요 (5분 뒤 이전 설정으로 되돌아갑니다).")
WS().call(type="http/config/promote")
s = WS().call(type="http/config")["stable"]
print("- 확정:", {k: s.get(k) for k in want})
PY

unset HA_TOKEN MQTT_PASSWORD
log "완료. 상태가 loaded 가 아니면 HA 로그를 확인합니다."
