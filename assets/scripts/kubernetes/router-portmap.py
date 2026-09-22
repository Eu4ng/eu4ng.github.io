#!/usr/bin/env python3
"""공유기(UPnP IGD)에 외부 노출용 포트포워딩을 겁니다. 표준 라이브러리만 씁니다.

    WAN 443 -> <이 호스트>:443 (Traefik websecure hostPort)
    WAN 80  -> <이 호스트>:80  (Traefik web hostPort)

MiniUPnPd 는 요청한 호스트만 내부 클라이언트로 허용하는 것이 보통이라, 트래픽을 받을 노드에서 실행합니다:

    ssh ubuntu@[CONTROL_PLANE_IP] python3 - < router-portmap.py            # 걸기 (이미 있으면 그대로 둠)
    ssh ubuntu@[CONTROL_PLANE_IP] python3 - --delete < router-portmap.py   # 지우기

임대 0(영구)으로 걸지만 공유기 재부팅·펌웨어 업데이트 뒤에는 사라질 수 있습니다. 외부 접속이 안 되면 먼저 다시 실행합니다.
공유기에서 UPnP 가 꺼져 있으면 관리 화면에서 위 두 개를 수동으로 겁니다.
"""
import re
import socket
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

MAPPINGS = [  # (외부 포트, 내부 포트, 설명)
    (443, 443, "k8s traefik https"),
    (80, 80, "k8s traefik http"),
]
PROTOCOL = "TCP"
LEASE = 0  # 0 = 영구
SSDP_ADDR = ("239.255.255.250", 1900)
DEVICE_NS = "{urn:schemas-upnp-org:device-1-0}"


def die(msg):
    sys.exit(f"[오류] {msg}")


def discover():
    """SSDP 로 IGD 의 설명 URL 을 찾습니다. 설명 URL 의 포트는 공유기가 재부팅될 때 바뀔 수 있어 매번 찾습니다."""
    msg = (
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n"
        "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
    ).encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.settimeout(3)
    s.sendto(msg, SSDP_ADDR)
    try:
        while True:
            data, addr = s.recvfrom(4096)
            m = re.search(r"(?im)^location:\s*(\S+)", data.decode(errors="replace"))
            if m:
                return m.group(1), addr[0]
    except socket.timeout:
        die("공유기가 UPnP 에 응답하지 않습니다. 공유기 관리 화면에서 UPnP 를 켜거나 포트포워딩을 수동으로 거세요.")


def local_ip_toward(host):
    """공유기로 나가는 인터페이스의 주소 = 이 호스트가 내부 클라이언트로 등록할 IP."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect((host, 1900))
    return s.getsockname()[0]


class IGD:
    def __init__(self, location):
        self.base = re.match(r"(https?://[^/]+)", location).group(1)
        root = ET.fromstring(urllib.request.urlopen(location, timeout=5).read())
        name = root.find(f".//{DEVICE_NS}friendlyName")
        self.name = name.text if name is not None else "?"
        for svc in root.iter(f"{DEVICE_NS}service"):
            stype = svc.find(f"{DEVICE_NS}serviceType").text
            if "WANIPConnection" in stype or "WANPPPConnection" in stype:
                self.stype = stype
                self.control = svc.find(f"{DEVICE_NS}controlURL").text
                return
        die("IGD 에 WANIPConnection/WANPPPConnection 서비스가 없습니다.")

    def call(self, action, **args):
        """SOAP 호출. 성공하면 결과 dict, UPnP 오류면 (errorCode, errorDescription) 을 담은 UPnPError."""
        body = "".join(f"<{k}>{v}</{k}>" for k, v in args.items())
        envelope = (
            '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            f'<u:{action} xmlns:u="{self.stype}">{body}</u:{action}></s:Body></s:Envelope>'
        )
        req = urllib.request.Request(
            self.base + self.control, data=envelope.encode(),
            headers={"Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": f'"{self.stype}#{action}"'},
        )
        try:
            text = urllib.request.urlopen(req, timeout=5).read().decode(errors="replace")
        except urllib.error.HTTPError as e:
            text = e.read().decode(errors="replace")
            code = re.search(r"<errorCode>(\d+)</errorCode>", text)
            desc = re.search(r"<errorDescription>(.*?)</errorDescription>", text)
            raise UPnPError(int(code.group(1)) if code else e.code, desc.group(1) if desc else text[:120])
        return {m.group(1): m.group(2) for m in re.finditer(r"<(New\w+)>(.*?)</\1>", text)}


class UPnPError(Exception):
    def __init__(self, code, desc):
        super().__init__(f"{code} {desc}")
        self.code = code


def list_mappings(igd):
    rows = []
    for i in range(256):
        try:
            r = igd.call("GetGenericPortMappingEntry", NewPortMappingIndex=i)
        except UPnPError:
            break
        rows.append(r)
    return rows


def main():
    delete = "--delete" in sys.argv[1:]
    location, router_ip = discover()
    igd = IGD(location)
    host = local_ip_toward(router_ip)
    print(f"공유기: {igd.name} ({router_ip}), 외부 IP: {igd.call('GetExternalIPAddress').get('NewExternalIPAddress')}")
    print(f"내부 호스트: {host}\n")

    for ext, internal, desc in MAPPINGS:
        key = dict(NewRemoteHost="", NewExternalPort=ext, NewProtocol=PROTOCOL)
        try:
            cur = igd.call("GetSpecificPortMappingEntry", **key)
        except UPnPError as e:
            cur = None if e.code in (714, 402, 501) else die(f"{PROTOCOL} {ext} 조회 실패: {e}")  # 714 = NoSuchEntryInArray

        if delete:
            if cur is None:
                print(f"{PROTOCOL} {ext}: 없음")
                continue
            igd.call("DeletePortMapping", **key)
            print(f"{PROTOCOL} {ext}: 삭제")
            continue

        if cur is not None:
            if cur.get("NewInternalClient") == host and cur.get("NewInternalPort") == str(internal):
                print(f"{PROTOCOL} {ext} -> {host}:{internal}: 이미 있음 (lease {cur.get('NewLeaseDuration')})")
                continue
            if cur.get("NewPortMappingDescription") != desc:
                die(f"{PROTOCOL} {ext} 이 이미 {cur.get('NewInternalClient')}:{cur.get('NewInternalPort')} "
                    f"('{cur.get('NewPortMappingDescription')}') 로 걸려 있습니다. 공유기 관리 화면에서 지우고 다시 실행하세요.")
            # 이 스크립트가 예전에 건 매핑(같은 설명)이면 내부 포트가 바뀐 것이므로 지우고 다시 겁니다.
            igd.call("DeletePortMapping", **key)
            print(f"{PROTOCOL} {ext} -> {cur.get('NewInternalClient')}:{cur.get('NewInternalPort')}: 옛 매핑 삭제")
        try:
            igd.call("AddPortMapping", **key, NewInternalPort=internal, NewInternalClient=host,
                     NewEnabled=1, NewPortMappingDescription=desc, NewLeaseDuration=LEASE)
        except UPnPError as e:
            die(f"{PROTOCOL} {ext} 추가 실패: {e}")
        print(f"{PROTOCOL} {ext} -> {host}:{internal}: 추가")

    print("\n현재 매핑:")
    for r in list_mappings(igd):
        print(f"  {r.get('NewProtocol')} {r.get('NewExternalPort'):>5} -> {r.get('NewInternalClient')}:{r.get('NewInternalPort'):<5} "
              f"lease={r.get('NewLeaseDuration')} '{r.get('NewPortMappingDescription')}'")


if __name__ == "__main__":
    main()
