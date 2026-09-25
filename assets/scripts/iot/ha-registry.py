# Home Assistant 엔티티·방 레지스트리를 WebSocket API 로 정리합니다. aiohttp 가 있는 HA 파드 안에서 실행합니다.
#   kubectl -n home-assistant exec -i <HA 파드> -c home-assistant -- env HA_TOKEN=<토큰> python3 - <작업> [--dry-run] < scripts/ha-registry.py
# 토큰은 대상 HA 의 장기 액세스 토큰(관리자)입니다. HA_TOKEN 이 없으면 입력받습니다. 저장소·파일에 남기지 않습니다.
#
# 작업(여러 개 가능):
#   --enable-platform <플랫폼>   통합이 꺼 둔(disabled_by=integration) 엔티티를 켭니다. 사용자가 끈 것(user)은 두고요. 예) mqtt
#   --delete-empty-areas         기기·엔티티가 하나도 없는 방을 지웁니다 (중앙 HA 의 온보딩 기본 방)
#   --prune-remote-orphans       Remote Home Assistant 엔티티 중 원격에서 사라져 상태가 없는 것을 지웁니다 (지역에서 이름을 바꾼 잔재).
#                                연결된 엔티티가 하나도 없는 지역(지역 HA 가 내려감)은 건너뜁니다
#   --rename-ieee                엔티티 ID 가 IEEE 주소(0x…)로 남은 mqtt 엔티티를 기기 이름으로 바꿉니다
#                                예) sensor.0xa4c138f95fdbf3ad_linkquality → sensor.bedroom2_motion_linkquality. 기록은 HA 가 새 ID 로 옮깁니다
import asyncio, getpass, os, re, sys

import aiohttp

URL = os.environ.get("HA_URL", "ws://127.0.0.1:8123/api/websocket")


async def main(args):
    dry = "--dry-run" in args
    token = os.environ.get("HA_TOKEN") or getpass.getpass("HA 장기 액세스 토큰: ")
    async with aiohttp.ClientSession() as s, s.ws_connect(URL) as ws:
        await ws.receive_json()
        await ws.send_json({"type": "auth", "access_token": token})
        if (await ws.receive_json())["type"] != "auth_ok":
            sys.exit("인증 실패: 토큰을 확인하세요")
        n = 0

        async def call(**msg):
            nonlocal n
            n += 1
            await ws.send_json({"id": n, **msg})
            while True:
                r = await ws.receive_json()
                if r.get("id") == n:
                    if not r["success"]:
                        raise RuntimeError(f"{msg['type']}: {r['error']}")
                    return r["result"]

        ents = await call(type="config/entity_registry/list")
        tag = "[dry-run] " if dry else ""

        if "--enable-platform" in args:
            plat = args[args.index("--enable-platform") + 1]
            for e in ents:
                if e["platform"] == plat and e["disabled_by"] == "integration":
                    print(f"{tag}활성화 {e['entity_id']}")
                    if not dry:
                        await call(type="config/entity_registry/update", entity_id=e["entity_id"], disabled_by=None)

        if "--delete-empty-areas" in args:
            devs = await call(type="config/device_registry/list")
            used = {e["area_id"] for e in ents} | {d["area_id"] for d in devs}
            for a in await call(type="config/area_registry/list"):
                if a["area_id"] not in used:
                    print(f"{tag}방 삭제 {a['name']} ({a['area_id']})")
                    if not dry:
                        await call(type="config/area_registry/delete", area_id=a["area_id"])

        if "--rename-ieee" in args:
            devs = {d["id"]: d.get("name_by_user") or d.get("name") for d in await call(type="config/device_registry/list")}
            taken = {e["entity_id"] for e in ents}
            for e in ents:
                domain, obj = e["entity_id"].split(".", 1)
                m = re.match(r"0x[0-9a-f]{16}(_.+)?$", obj)
                name = devs.get(e["device_id"])
                if e["platform"] != "mqtt" or not m or not name:
                    continue
                new = f"{domain}.{re.sub(r'[^a-z0-9]+', '_', name.lower()).strip('_')}{m.group(1) or ''}"
                if new in taken:
                    print(f"건너뜀 {e['entity_id']}: {new} 가 이미 있습니다")
                    continue
                print(f"{tag}이름 변경 {e['entity_id']} → {new}")
                if not dry:
                    await call(type="config/entity_registry/update", entity_id=e["entity_id"], new_entity_id=new)
                taken.add(new)

        if "--prune-remote-orphans" in args:
            # 통합이 더는 제공하지 않는 엔티티는 상태가 없거나, HA 가 자리만 채운 restored 상태(unavailable)로 남습니다
            live = {st["entity_id"] for st in await call(type="get_states") if not st["attributes"].get("restored")}
            # 지역 HA 가 내려가 있으면 그 지역 엔티티가 모두 상태 없음으로 보이므로, 살아 있는 엔티티가 하나도 없는 지역은 건너뜁니다
            up = {e["config_entry_id"] for e in ents if e["platform"] == "remote_homeassistant" and e["entity_id"] in live}
            for e in ents:
                if e["platform"] != "remote_homeassistant" or e["entity_id"] in live:
                    continue
                if e["config_entry_id"] not in up:
                    print(f"건너뜀 {e['entity_id']}: 이 지역에 연결된 엔티티가 없습니다(지역 HA 가 내려가 있을 수 있음)")
                else:
                    print(f"{tag}엔티티 삭제 {e['entity_id']}")
                    if not dry:
                        await call(type="config/entity_registry/remove", entity_id=e["entity_id"])


asyncio.run(main(sys.argv[1:]))
