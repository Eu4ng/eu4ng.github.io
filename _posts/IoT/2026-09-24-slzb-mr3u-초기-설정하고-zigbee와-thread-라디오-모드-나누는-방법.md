---
layout: post
title: SLZB-MR3U 초기 설정하고 Zigbee와 Thread 라디오 모드 나누는 방법
description: 듀얼 라디오 네트워크 코디네이터 SLZB-MR3U 를 LAN 에 붙여 웹 UI 에 로그인 보호를 걸고, 한 라디오는 Zigbee 코디네이터로 다른 라디오는 원격 OTBR 용 Thread 라디오로 나눈 뒤 각 라디오의 TCP 포트를 확인하는 방법을 정리했습니다.
author: Eu4ng
tags: [iot, slzb-06, smlight, zigbee, thread, matter, coordinator]
permalink: /posts/45/
---

SMLIGHT **SLZB-MR3U** 는 Zigbee 용 CC2674P10 과 Thread 용 EFR32MG24 두 라디오를 가진 이더넷(PoE) 코디네이터입니다. 라디오마다 TCP 포트를 하나씩 열어 주므로 Zigbee2MQTT 와 OpenThread Border Router 가 서로 다른 서버(파드)에서 각자 라디오에 붙을 수 있고, USB 패스스루가 필요 없습니다. 이 글은 기기를 LAN 에 붙이고 웹 UI 에서 라디오별 모드와 포트를 정하는 데까지만 다룹니다. Zigbee2MQTT 와 OTBR 연결은 다음 글들에서 합니다.

1. 연결과 웹 UI 접속
2. 고정 IP
3. 웹 UI 로그인 보호
4. 라디오별 모드 지정
5. 포트 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| 기기 | `SLZB-MR3U` (라디오 1: EFR32MG24, 라디오 2: CC2674P10) |
| SLZB-OS | `v3.2.6` |
| 작성 기준일 | `2026-09-24` |

다음 항목이 준비되어 있어야 합니다.

- PoE 스위치 포트 또는 USB-C 전원과 LAN 케이블
- 공유기 관리 화면에 들어갈 수 있는 권한(DHCP 예약용)과 비어 있는 고정 IP 하나 (`[SLZB_IP]`)
- 내 PC 에 `nc`, `curl`

## 1. 연결과 웹 UI 접속

LAN 케이블을 꽂고 전원을 넣으면 DHCP 로 주소를 받습니다. 공유기의 DHCP 클라이언트 목록에서 호스트 이름 `SLZB-MR3U` 를 찾아 그 주소로 웹 UI 를 엽니다. 처음에는 로그인 없이 열립니다.

```bash
# 내 PC: 기기 정보 API 로 주소·펌웨어·라디오 구성 확인
curl -s http://[SLZB_IP]/ha_info | python3 -m json.tool | grep -E '"(model|sw_version|device_ip|zb_hw|zb_version|chip_index)"'
```

- **확인:** `model` 이 `SLZB-MR3U`, `radios` 아래에 `chip_index` 0(`EFR32MG24`)과 1(`CC2674P10`)이 보입니다. 브라우저에서는 **Dashboard** 에 **Radiomodule mode** 와 이더넷 상태가 보입니다.

## 2. 고정 IP

코디네이터 주소는 Zigbee2MQTT 와 OTBR 설정에 그대로 들어가므로 바뀌면 안 됩니다. 기기의 **Network** 페이지에서 DHCP 를 끄고 직접 적는 방법도 있지만, 공유기의 DHCP 예약(MAC 주소에 고정 주소 할당)으로 두면 기기를 초기화해도 같은 주소를 받습니다. `ha_info` 의 `MAC` 값을 공유기의 DHCP 예약에 등록하고 기기를 재부팅합니다.

- **확인:** `curl -s http://[SLZB_IP]/ha_info` 의 `device_ip` 가 예약한 주소이고, **Network** 페이지의 **DHCP** 가 켜진 채 IP 가 그 주소입니다.

## 3. 웹 UI 로그인 보호

웹 UI 에서 라디오 펌웨어를 바꾸고 재부팅할 수 있으므로 LAN 안에서도 로그인을 걸어 둡니다.

1. **Security** 페이지로 이동
2. **Enable web server authentication** 을 켜고 **Login** 과 **Password** 입력
3. **Save** 클릭

- **확인:** 페이지를 새로 고치면 로그인 화면이 나오고, 상단에 **Logout** 이 보입니다. `curl http://[SLZB_IP]/ha_info` 는 로그인 없이도 응답합니다(기기 정보 API 는 인증 대상이 아닙니다).

## 4. 라디오별 모드 지정

**Mode** 페이지의 **Radiomodule mode** 에서 라디오마다 역할을 고릅니다. 선택지는 **Zigbee Coordinator**, **Zigbee Router**, **Matter-over-Thread**(그 아래 **Thread to remote OTBR** 과 **Thread+OTBR**), **MultiPAN (Zigbee+Thread)** 입니다.

- 라디오 2(CC2674P10): **Zigbee Coordinator**. Z-Stack 펌웨어라 Zigbee2MQTT 의 `zstack` 어댑터로 붙습니다.
- 라디오 1(EFR32MG24): **Thread to remote OTBR**. 라디오는 RCP(Radio Co-Processor)로만 동작하고 Thread 스택과 데이터셋은 서버 쪽 OTBR 이 가집니다. 기기가 고장 나도 서버의 데이터셋으로 같은 Thread 망을 이어 갈 수 있습니다.
- **Connection mode** 는 **Ethernet connection** 으로 둡니다.

**Save** 를 누르면 기기가 해당 라디오의 펌웨어를 내려받아 다시 씁니다. SLZB-OS 가 알아서 하는 과정이라 펌웨어 파일을 구해 올리는 일은 없지만, 이 동안 인터넷이 필요하고 몇 분 걸립니다.

> **Thread+OTBR** 은 OTBR 을 기기 안에서 돌리는 모드라 서버에 OTBR 이 필요 없지만, Thread 망의 데이터셋이 기기 안에만 남습니다. 기기를 교체할 때 데이터셋을 복원하지 못하면 Thread 기기를 전부 다시 커미셔닝해야 하므로 이 글에서는 쓰지 않습니다.
{: .prompt-warning }

- **확인:** **Dashboard** 의 **Radiomodule mode** 에 라디오 1 은 Thread, 라디오 2 는 Zigbee Coordinator 로 표시됩니다.

## 5. 포트 확인

**Z2M and ZHA** 페이지의 **Serial Settings** 에 라디오별 **Socket Port** 와 **Serial Speed** 가 있습니다. 이 글의 기기는 라디오 1 이 `6638`, 라디오 2 가 `7638` 이었습니다. Zigbee 라디오의 속도는 기본 `115200`, Thread RCP 는 `460800` 으로 두고 **Enable Hardware Flow Control (RTS/CTS)** 는 끕니다. 각 포트는 클라이언트 하나만 받습니다.

```bash
# 내 PC: 두 포트가 열려 있는지
nc -zv [SLZB_IP] 7638   # Zigbee (Zigbee2MQTT 가 붙을 포트)
nc -zv [SLZB_IP] 6638   # Thread RCP (OTBR 이 붙을 포트)
```

- **확인:** 두 명령 모두 `succeeded!` 로 끝납니다. 이 값(`[SLZB_IP]`, 포트, 어댑터 `zstack`, 속도)을 Zigbee2MQTT 와 OTBR 설정에 그대로 씁니다.

## 마무리

SLZB-MR3U 를 고정 IP 로 LAN 에 붙이고 웹 UI 에 로그인 보호를 건 뒤, CC2674P10 은 Zigbee 코디네이터로, EFR32MG24 는 원격 OTBR 용 Thread 라디오로 나눠 각 라디오의 TCP 포트를 확인했습니다. 다음 글에서는 Zigbee 포트에 [Zigbee2MQTT 를 붙이고](/posts/44/), 그 다음에 Thread 포트에 [OpenThread Border Router 를 붙입니다](/posts/47/).

## 참고 자료

- [SMLIGHT - SLZB-MR3U 제품 페이지](https://smlight.tech/products/slzb-mr3u)
- [SMLIGHT - SLZB-06 series manual](https://smlight.tech/manual/slzb-06/)
- [SMLIGHT - Thread setup (network and USB connection)](https://smlight.tech/support/manuals/books/slzb-06xmrxmrxuultima-series/page/thread-setup-network-and-usb-connection)
- [Zigbee2MQTT - Adapter settings](https://www.zigbee2mqtt.io/guide/configuration/adapter-settings.html)
