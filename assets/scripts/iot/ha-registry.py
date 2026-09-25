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
#   --rename-matter              matter 엔티티 ID 를 <기기 이름>_<측정 항목(device_class 등)> 영문으로 바꿉니다. 표시 이름(온도 등)은 그대로입니다
#                                예) sensor.cimsil2_bedroom2_air_quality_ondo → sensor.bedroom2_air_quality_temperature. 기록은 HA 가 새 ID 로 옮깁니다
#   --assign-areas               Zigbee·Matter 기기를 이름(<방>-<종류>[번호])의 방에 해당하는 영역으로 옮깁니다. 영역이 없으면 만듭니다
#                                예) bedroom2-th → 침실2 (방 코드는 영역 별칭으로 붙습니다). ROOMS 에 없는 방은 코드 그대로(garage)를 이름으로 씁니다
import asyncio, getpass, os, re, sys

import aiohttp

URL = os.environ.get("HA_URL", "ws://127.0.0.1:8123/api/websocket")

# --assign-areas 의 방 코드 → 영역 이름. 뒤에 붙은 번호는 그대로 이어 붙입니다 (bedroom2 → 침실2)
ROOMS = {
    "livingroom": "거실", "kitchen": "주방", "bedroom": "침실", "room": "방", "office": "서재", "bathroom": "욕실",
    "laundry": "세탁실", "dressroom": "드레스룸", "utility": "다용도실", "entrance": "현관", "balcony": "베란다",
}


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

        if "--rename-matter" in args:
            # 한국어 HA 는 엔티티 이름(온도)을 로마자(ondo)로, 방 이름까지 붙여 ID 를 만듭니다. 방은 기기 이름(<방>-<종류>)에 이미 있습니다
            devs = {d["id"]: d.get("name_by_user") or d.get("name") for d in await call(type="config/device_registry/list")}
            ids = [e["entity_id"] for e in ents if e["platform"] == "matter"]
            full = await call(type="config/entity_registry/get_entries", entity_ids=ids) if ids else {}
            taken = {e["entity_id"] for e in ents}
            slug = lambda s: re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")
            for eid, e in full.items():
                name = devs.get(e and e["device_id"])
                if not name:
                    continue
                # 측정 항목: device_class(enum 같은 일반 값 제외) → translation_key → 영문 원래 이름
                dc = e.get("original_device_class")
                on = e.get("original_name") or ""
                what = (dc if dc and dc != "enum" else None) or e.get("translation_key") or (slug(on) if on.isascii() else "")
                if not what:
                    print(f"건너뜀 {eid}: 측정 항목을 알 수 없습니다")
                    continue
                new = f"{eid.split('.', 1)[0]}.{slug(name)}_{what}"
                if new == eid:
                    continue
                if new in taken:
                    print(f"건너뜀 {eid}: {new} 가 이미 있습니다")
                    continue
                print(f"{tag}이름 변경 {eid} → {new}")
                if not dry:
                    await call(type="config/entity_registry/update", entity_id=eid, new_entity_id=new)
                taken.add(new)

        if "--assign-areas" in args:
            # 방은 기기 이름의 첫 - 앞입니다. 이름이 원본이므로 손으로 고른 영역도 이름에 맞춰 바꿉니다
            areas = await call(type="config/area_registry/list")
            label = {a["area_id"]: a["name"] for a in areas}
            find = {k: a["area_id"] for a in areas for k in [a["area_id"], a["name"], *a.get("aliases", [])]}
            for d in await call(type="config/device_registry/list"):
                # 이름 규칙은 Zigbee2MQTT(mqtt)·Matter 기기에만 있습니다. 휴대폰(mobile_app) 등은 건너뜁니다
                if not {i[0] for i in d["identifiers"]} & {"mqtt", "matter"}:
                    continue
                name = d.get("name_by_user") or d.get("name") or ""
                m = re.match(r"([a-z0-9]+)-", name)
                if not m or m.group(1) == "retired":
                    continue
                room = m.group(1)
                r = re.fullmatch(r"([a-z]+)(\d*)", room)
                want = ROOMS[r.group(1)] + r.group(2) if r and r.group(1) in ROOMS else room
                aid = find.get(room) or find.get(want)
                if not aid:
                    print(f"{tag}영역 생성 {want} (별칭 {room})")
                    a = {"area_id": want, "name": want} if dry else await call(type="config/area_registry/create", name=want, aliases=[room])
                    aid = find[room] = find[want] = a["area_id"]
                    label[aid] = a["name"]
                if d["area_id"] == aid:
                    continue
                print(f"{tag}영역 지정 {name}: {label.get(d['area_id'], '없음')} → {label[aid]}")
                if not dry:
                    await call(type="config/device_registry/update", device_id=d["id"], area_id=aid)

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
