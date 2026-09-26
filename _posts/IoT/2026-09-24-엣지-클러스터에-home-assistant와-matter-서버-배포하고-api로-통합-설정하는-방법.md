---
layout: post
title: 엣지 클러스터에 Home Assistant와 Matter 서버 배포하고 API로 통합 설정하는 방법
description: 엣지 k3s 클러스터에 Home Assistant 와 Matter 서버(matterjs-server)를 GitOps 폴더로 배포하고, MQTT·Matter·OpenThread Border Router 통합과 역방향 프록시 설정을 웹 화면 대신 API 스크립트로 넣은 뒤, Matter 기기 상태를 허브 TimescaleDB 로 모으는 방법을 정리했습니다.
author: Eu4ng
tags: [iot, home-assistant, matter, thread, mqtt, telegraf, kubernetes, argo-cd, gitops, edge]
permalink: /posts/48/
---

엣지 클러스터에 **Home Assistant**(HA)와 **matterjs-server**(Matter 컨트롤러)를 배포하고, HA 의 통합 설정을 스크립트로 넣은 뒤 밖에서 `ha-[SITE_CODE].[DOMAIN]` 으로 엽니다. HA 는 Matter 기기 등록 화면과 제어·자동화 대시보드로만 쓰고 수집 경로에는 두지 않습니다. Zigbee 는 [Zigbee2MQTT](/posts/44/)가 브로커로 바로 보내고, Matter 기기 상태와 HA 에서 내린 기기 제어 기록만 HA 자동화가 브로커로 발행해 [수집 파이프라인](/posts/43/)을 탑니다. 통합 추가, Thread 기본 네트워크 지정, 역방향 프록시 신뢰 설정은 모두 HA API 로 하므로 새 서버에서도 같은 명령 한 번이면 됩니다.

1. 매니페스트 추가와 배포
2. 온보딩과 장기 액세스 토큰
3. 통합 설정 스크립트 실행
4. Matter 상태와 제어 기록을 수집 파이프라인에 연결
5. 밖에서 열기와 2단계 인증
6. 확인

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| 엣지 Kubernetes | `v1.36` (k3s) |
| Home Assistant | `2026.9.3` |
| matterjs-server | `1.4.0` |
| telegraf | `1.40.1` |
| 작성 기준일 | `2026-09-24` |

다음 항목이 준비되어 있어야 합니다.

- 엣지 클러스터의 Mosquitto·Telegraf 와 허브 TimescaleDB, 시크릿 스크립트가 만든 브로커 계정 `homeassistant` ([엣지 Mosquitto와 Telegraf 디스크 버퍼로 중앙 TimescaleDB에 유실 없이 IoT 데이터 모으는 방법](/posts/43/))
- 허브 Traefik 과 oauth2-proxy 로 서비스를 밖에 여는 구성 ([쿠버네티스 서비스를 VPN 없이 외부에서 HTTPS로 접속하는 방법](/posts/40/))
- Thread 기기를 쓸 경우 엣지 클러스터의 OpenThread Border Router. 없으면 3단계에서 `OTBR_URL` 을 비웁니다.

## 1. 매니페스트 추가와 배포

HA 와 Matter 서버는 기기 탐색(mDNS)과 IPv6 로 LAN 의 기기와 직접 통신해야 해서 `hostNetwork` 로 띄웁니다. 파드 네트워크(Flannel)는 IPv4 만 다루기 때문입니다. HA 는 `configuration.yaml` 을 스스로 만들고 고치므로 PVC 에 두고, initContainer 가 자동화 파일을 복사하고 그 파일을 읽는 줄만 한 번 덧붙입니다. 파일에는 자동화가 두 개 있습니다. `matter_statestream` 은 **Matter 통합에 속한 엔티티**(`integration_entities('matter')`)의 상태나 속성이 바뀔 때 발행하고, `control_events` 는 기기로 간 명령과 자동화 실행을 누가 했는지와 함께 발행합니다(4단계). Zigbee 기기도 HA 에 보이지만 MQTT 통합 소속이고 이미 Zigbee2MQTT 경로로 수집되므로 걸리지 않습니다. 기기 이름과 무관하게 거르므로 Matter 기기를 등록할 때 이름 규칙을 지킬 필요가 없습니다.

> HA 의 `mqtt_statestream` 도 같은 토픽 형식으로 발행하지만 도메인·엔티티 이름으로만 거를 수 있고 통합 단위로는 거르지 못합니다. 그래서 `matter_*` 같은 이름 규칙이 필요해지고, 기기 이름에서 자동으로 만들어진 엔티티는 빠집니다.
{: .prompt-info }

```yaml
# 엣지의 Home Assistant. Matter 커미셔닝 UI 와 제어·자동화 대시보드로만 쓰고, 수집 경로에는 두지 않습니다.
# Matter 통합의 엔티티 상태·속성과 기기 제어 기록을 자동화(matter-statestream.yaml)로 브로커에 발행해 Telegraf 가 받게 합니다 (initContainer 가 /config 로 복사하고 configuration.yaml 에 include 를 한 번 덧붙임).
resources:
  - deployment.yaml
  - pvc.yaml
configMapGenerator:
  - name: home-assistant-seed
    files:
      - matter-statestream.yaml
```
{: file="iot/edge/home-assistant/kustomization.yaml" }

{% raw %}
```yaml
# HA 에서 허브 DB 로 보낼 것을 MQTT 로 발행하는 자동화 두 개입니다. initContainer 가 매 기동 /config 로 복사합니다.
# 수집 원칙은 "기본은 모두 수집" 이고, 빼는 것은 중복(Zigbee 기기 상태는 zigbee2mqtt/ 토픽으로 따로 수집)과 수집 자동화 자신의 실행뿐입니다.
#
# 1) matter_statestream: Matter 통합 엔티티의 상태와 속성(readings 테이블)
#    mqtt_statestream 은 통합 단위로 거르지 못해 엔티티 이름 규칙이 필요했으므로, 소속 통합(integration_entities)으로 거르는 자동화로 대신합니다.
#    상태가 바뀌면 hass/<도메인>/<엔티티>/state, 속성(펌웨어 버전 등)이 바뀌면 바뀐 속성마다 hass/<도메인>/<엔티티>/attr/<속성> 에 발행합니다.
#    값은 JSON 입니다. Telegraf 가 Zigbee 와 같은 테이블(readings)에 "기기 하나의 속성 하나" 로 넣도록 값(state)에 다음을 붙입니다:
#      device(HA 기기 이름, <방>-<종류>[-<기준>][번호]), property(엔티티 ID 에서 기기 이름을 뗀 측정 항목, 예: pm25. 속성은 <측정 항목>_<속성>)
#      unit(엔티티의 unit_of_measurement, 예: µg/m³. 속성은 비움), node(패브릭-노드 ID, 다시 커미셔닝하면 바뀜), serial(기기 시리얼, 바뀌지 않음), model, vendor
#      time(상태는 바뀐 시각 last_changed, 속성은 last_updated. UTC RFC 3339). Telegraf 가 수신 시각 대신 써서, 늦게 도착하거나 유지 메시지로 다시 와도 시각이 맞습니다
#
# 2) control_events: 기기 제어 기록(events 테이블). 사람이 제어했는지 자동화가 제어했는지를 남겨 자동화의 효과(에너지 절감 등)를 평가합니다.
#    call_service: Matter·MQTT(=Zigbee) 통합 엔티티로 간 서비스 호출마다 hass/events/call_service 에 발행합니다 (scene·script 안의 호출 포함)
#      action(<도메인>.<서비스>), data(대상을 뺀 서비스 데이터 JSON), origin/actor(아래), context_id, parent_id
#      origin: user(context 에 사용자 있음, actor 는 person 이름), automation(자동화·스크립트, actor 는 그 entity_id. 못 찾으면 비움), system(그 밖)
#    automation_triggered, script_started: 자동화·스크립트가 실행될 때마다 hass/events/run 에 발행합니다. 자동화가 보낸 명령과 context_id 가 같습니다
#    명령 없이 상태만 바뀐 것(기기 버튼 조작)은 events 에 없고 readings 의 상태 행으로만 남습니다.
- id: matter_statestream
  alias: Matter 상태를 MQTT 로 재발행
  mode: parallel
  max: 100
  triggers:
    - trigger: event
      event_type: state_changed
  conditions:
    - condition: template
      value_template: >-
        {{ trigger.event.data.new_state is not none
           and trigger.event.data.entity_id in integration_entities('matter') }}
  actions:
    - variables:
        info: >-
          {%- set entity = trigger.event.data.entity_id %}
          {%- set did = device_id(entity) %}
          {%- set ids = (device_attr(did, 'identifiers') or []) | map('last') | select('match', 'deviceid_') | list %}
          {%- set name = device_attr(did, 'name_by_user') or device_attr(did, 'name') or '' %}
          {%- set object_id = entity.split('.')[1] %}
          {%- set prefix = (name | slugify) ~ '_' %}
          {{ {'device': name or object_id,
              'property': object_id[prefix | length:] if name and object_id.startswith(prefix) else object_id,
              'node': ids[0][9:] | replace('-MatterNodeDevice', '') if ids else '',
              'serial': device_attr(did, 'serial_number') or '',
              'model': device_attr(did, 'model') or '',
              'vendor': device_attr(did, 'manufacturer') or ''} }}
        # 속성 이름이 StrEnum(update 의 auto_update 등)일 수 있어 ~ '' 로 순수 문자열로 바꿔야 목록으로 넘어갑니다 (| string 은 str 하위 타입을 그대로 둠)
        changed_attributes: >-
          {%- set old = trigger.event.data.old_state %}
          {%- set ns = namespace(keys=[]) %}
          {%- for k, v in trigger.event.data.new_state.attributes.items() %}
            {%- if old is none or k not in old.attributes or old.attributes[k] != v %}
              {%- set ns.keys = ns.keys + [k ~ ''] %}
            {%- endif %}
          {%- endfor %}
          {{ ns.keys }}
    - if:
        - condition: template
          value_template: >-
            {{ trigger.event.data.old_state is none
               or trigger.event.data.old_state.state != trigger.event.data.new_state.state }}
      then:
        - action: mqtt.publish
          data:
            topic: "hass/{{ trigger.event.data.entity_id | replace('.', '/') }}/state"
            payload: >-
              {{ dict(info,
                      state=trigger.event.data.new_state.state,
                      time=trigger.event.data.new_state.last_changed.isoformat(),
                      unit=state_attr(trigger.event.data.entity_id, 'unit_of_measurement') or '') | to_json }}
            qos: 1
            retain: true
    - repeat:
        for_each: "{{ changed_attributes }}"
        sequence:
          - action: mqtt.publish
            data:
              topic: "hass/{{ trigger.event.data.entity_id | replace('.', '/') }}/attr/{{ repeat.item }}"
              payload: >-
                {%- set v = trigger.event.data.new_state.attributes[repeat.item] %}
                {{ dict(info,
                        property=info.property ~ '_' ~ repeat.item,
                        state='' if v is none else (v if v is string else v | to_json),
                        time=trigger.event.data.new_state.last_updated.isoformat(),
                        unit='') | to_json }}
              qos: 1
              retain: true

- id: control_events
  alias: 기기 제어 기록을 MQTT 로 발행
  mode: parallel
  max: 100
  triggers:
    - trigger: event
      event_type: call_service
      id: call
    - trigger: event
      event_type: automation_triggered
      id: run
    - trigger: event
      event_type: script_started
      id: run
  # 조건보다 먼저 계산됩니다. call_service 는 HA 안의 모든 호출(mqtt.publish 포함)에 걸리므로 대상 기기가 없는 호출은 조건에서 버립니다.
  variables:
    targets: >-
      {%- if trigger.id == 'call' %}
        {%- set sd = trigger.event.data.service_data or {} %}
        {%- set ns = namespace(direct=[], expanded=[]) %}
        {%- for key in ['entity_id', 'device_id', 'area_id', 'label_id', 'floor_id'] %}
          {%- set v = sd.get(key, []) %}
          {%- for x in ([v] if v is string else v) %}
            {%- if key == 'entity_id' %}{% set ns.direct = ns.direct + [x] %}
            {%- elif key == 'device_id' %}{% set ns.expanded = ns.expanded + device_entities(x) %}
            {%- elif key == 'area_id' %}{% set ns.expanded = ns.expanded + area_entities(x) %}
            {%- elif key == 'label_id' %}{% set ns.expanded = ns.expanded + label_entities(x) %}
            {%- else %}{% for a in floor_areas(x) %}{% set ns.expanded = ns.expanded + area_entities(a) %}{% endfor %}
            {%- endif %}
          {%- endfor %}
        {%- endfor %}
        {%- set domain = trigger.event.data.domain %}
        {%- set expanded = ns.expanded if domain == 'homeassistant' else ns.expanded | select('match', domain ~ '\\.') | list %}
        {%- set watched = integration_entities('matter') + integration_entities('mqtt') %}
        {{ (ns.direct + expanded) | select('in', watched) | unique | list }}
      {%- else %}[]{% endif %}
    own: >-
      {{ states.automation | selectattr('attributes.id', 'in', ['matter_statestream', 'control_events'])
         | map(attribute='entity_id') | list }}
  conditions:
    - condition: template
      value_template: >-
        {{ (trigger.id == 'call' and targets | count > 0)
           or (trigger.id == 'run' and trigger.event.data.entity_id not in own) }}
  actions:
    - variables:
        common: >-
          {%- set c = trigger.event.context %}
          {%- set runner = (states.automation | list) + (states.script | list) %}
          {%- set by = runner | selectattr('context.id', 'eq', c.id) | map(attribute='entity_id') | first | default('') %}
          {%- if c.user_id %}
            {%- set origin = 'user' %}
            {%- set actor = states.person | selectattr('attributes.user_id', 'eq', c.user_id) | map(attribute='name') | first | default(c.user_id) %}
          {%- elif trigger.id == 'run' %}
            {%- set origin, actor = 'automation', trigger.event.data.entity_id %}
          {%- elif by or c.parent_id %}
            {%- set origin, actor = 'automation', by %}
          {%- else %}
            {%- set origin, actor = 'system', '' %}
          {%- endif %}
          {{ {'time': trigger.event.time_fired.isoformat(), 'origin': origin, 'actor': actor,
              'context_id': c.id, 'parent_id': c.parent_id or ''} }}
    - if:
        - condition: template
          value_template: "{{ trigger.id == 'run' }}"
      then:
        - action: mqtt.publish
          data:
            topic: hass/events/run
            payload: >-
              {{ dict(common,
                      action=trigger.event.event_type,
                      data={'name': trigger.event.data.name,
                            'source': trigger.event.data.source | default('')} | to_json) | to_json }}
            qos: 1
      else:
        - repeat:
            for_each: "{{ targets }}"
            sequence:
              - action: mqtt.publish
                data:
                  topic: hass/events/call_service
                  payload: >-
                    {%- set entity = repeat.item %}
                    {%- set did = device_id(entity) %}
                    {%- set idents = (device_attr(did, 'identifiers') or []) | map('last') | list %}
                    {%- set nodes = idents | select('match', 'deviceid_') | list %}
                    {%- set ieee = idents | select('match', 'zigbee2mqtt_0x') | list %}
                    {%- set name = device_attr(did, 'name_by_user') or device_attr(did, 'name') or '' %}
                    {%- set object_id = entity.split('.')[1] %}
                    {%- set prefix = (name | slugify) ~ '_' %}
                    {%- set sd = trigger.event.data.service_data or {} %}
                    {%- set rest = sd.items() | rejectattr('0', 'in', ['entity_id', 'device_id', 'area_id', 'label_id', 'floor_id']) | list %}
                    {{ dict(common,
                            device=name or object_id,
                            property=object_id[prefix | length:] if name and object_id.startswith(prefix) else object_id,
                            protocol='matter' if entity in integration_entities('matter') else 'zigbee',
                            node=nodes[0][9:] | replace('-MatterNodeDevice', '') if nodes else '',
                            serial=device_attr(did, 'serial_number') or (ieee[0][12:] if ieee else ''),
                            model=device_attr(did, 'model') or '',
                            vendor=device_attr(did, 'manufacturer') or '',
                            action=trigger.event.data.domain ~ '.' ~ trigger.event.data.service,
                            data=dict(rest) | to_json) | to_json }}
                  qos: 1
```
{: file="iot/edge/home-assistant/matter-statestream.yaml" }
{% endraw %}

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: home-assistant
spec:
  replicas: 1
  strategy:
    type: Recreate           # PVC 가 ReadWriteOnce 이고 호스트 포트 8123 도 하나입니다
  selector:
    matchLabels: { app: home-assistant }
  template:
    metadata:
      labels: { app: home-assistant }
    spec:
      hostNetwork: true                    # 기기 탐색(mDNS·SSDP)과 Matter 서버·OTBR 접근을 노드 네트워크에서 직접 합니다
      dnsPolicy: ClusterFirstWithHostNet   # hostNetwork 에서도 mosquitto.mosquitto.svc 같은 클러스터 이름을 풉니다
      # 첫 기동에 HA 가 만든 configuration.yaml 에 Matter 재발행 자동화 include 가 없으면 덧붙입니다. 파일이 아직 없으면(최초 기동) 건너뛰고 다음 기동에 붙입니다.
      # 자동화 파일은 매 기동 복사해 이 저장소의 수정이 재기동으로 반영됩니다.
      # 프록시 신뢰(http)는 HA 2026 부터 YAML 이 아니라 .storage 에서 관리하므로 setup-home-assistant.sh 가 API 로 설정합니다.
      initContainers:
        - name: seed-config
          image: ghcr.io/home-assistant/home-assistant:2026.9.3
          command:
            - /bin/sh
            - -c
            - |
              f=/config/configuration.yaml
              [ -f $f ] || exit 0
              cp /seed/matter-statestream.yaml /config/matter-statestream.yaml
              grep -q '^automation matter:' $f || printf '\n# --- iot/edge/home-assistant 가 덧붙인 설정. Matter 통합 엔티티 상태를 MQTT 로 재발행합니다 (자동화는 initContainer 가 복사) ---\nautomation matter: !include matter-statestream.yaml\n' >> $f
          volumeMounts:
            - { name: config, mountPath: /config }
            - { name: seed, mountPath: /seed }
      containers:
        - name: home-assistant
          image: ghcr.io/home-assistant/home-assistant:2026.9.3
          env:
            - { name: TZ, value: Asia/Seoul }
          ports: [{ containerPort: 8123 }]
          volumeMounts:
            - { name: config, mountPath: /config }
          startupProbe:
            httpGet: { path: /, port: 8123 }
            periodSeconds: 5
            failureThreshold: 60   # 첫 기동은 프런트엔드 준비에 1~2분 걸립니다
          readinessProbe:
            httpGet: { path: /, port: 8123 }
            periodSeconds: 10
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits:   { cpu: "2", memory: 1536Mi }   # 통합 몇 개면 400~800MiB. 엣지 노드(4GiB)에서 다른 파드 몫을 남깁니다
      volumes:
        - name: config
          persistentVolumeClaim: { claimName: home-assistant-config }
        - name: seed
          configMap: { name: home-assistant-seed }
```
{: file="iot/edge/home-assistant/deployment.yaml" }

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: home-assistant-config
  annotations:
    argocd.argoproj.io/sync-options: Prune=false   # 통합 설정(.storage), 자동화, recorder DB. 지우면 처음부터 다시 설정해야 합니다
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
```
{: file="iot/edge/home-assistant/pvc.yaml" }

Matter 서버는 패브릭(기기 인증서)을 PVC 에 보관합니다. HA 와 따로 두어 HA 를 지우거나 다시 만들어도 등록한 Matter 기기는 그대로입니다. `PRODUCTION_MODE` 는 5단계에서 대시보드를 역방향 프록시 뒤에서 열 때 같은 주소의 WebSocket 으로 붙게 합니다.

```yaml
# 엣지의 Matter 컨트롤러(matterjs-server). Home Assistant 가 이 서버의 WebSocket 으로 Matter 기기를 커미셔닝·제어합니다.
# 패브릭(기기 인증서)이 PVC 에 있으므로 HA 를 지워도 기기는 그대로입니다. Thread 보더 라우터는 iot/edge/otbr 에 따로 있습니다.
resources:
  - deployment.yaml
  - pvc.yaml
```
{: file="iot/edge/matter/kustomization.yaml" }

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: matter-server
spec:
  replicas: 1
  strategy:
    type: Recreate           # PVC 가 ReadWriteOnce 이고 호스트 포트 5580 도 하나입니다
  selector:
    matchLabels: { app: matter-server }
  template:
    metadata:
      labels: { app: matter-server }
    spec:
      hostNetwork: true                    # Matter 기기 탐색(mDNS)과 IPv6 통신은 노드의 네트워크에서 직접 해야 합니다 (파드 네트워크는 IPv4 뿐)
      dnsPolicy: ClusterFirstWithHostNet
      securityContext:
        runAsUser: 1000                    # 이미지가 비특권 계정(1000)으로 돕니다
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: matter-server
          image: ghcr.io/matter-js/matterjs-server:1.4.0
          env:
            - { name: STORAGE_PATH, value: /data }
            - { name: PRIMARY_INTERFACE, value: eth0 }   # 노드의 LAN 인터페이스. 링크 로컬 주소와 mDNS 를 여기로 묶습니다
            - { name: LOG_LEVEL, value: info }
            - { name: PRODUCTION_MODE, value: "true" }  # 대시보드를 프록시(matter-[SITE_CODE].[DOMAIN]) 뒤에서 열 때 같은 주소의 /ws 로 붙게 합니다
          ports: [{ containerPort: 5580 }]               # WebSocket /ws 와 대시보드. HA 는 같은 노드라 ws://127.0.0.1:5580/ws 로 붙습니다
          volumeMounts:
            - { name: data, mountPath: /data }
          startupProbe:
            httpGet: { path: /health, port: 5580 }
            periodSeconds: 5
            failureThreshold: 60
          readinessProbe:
            httpGet: { path: /health, port: 5580 }
            periodSeconds: 10
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits:   { cpu: "1", memory: 768Mi }        # Node.js 힙. 기기 수십 대까지는 이 안에서 돕니다
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: matter-server-data }
```
{: file="iot/edge/matter/deployment.yaml" }

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: matter-server-data
  annotations:
    argocd.argoproj.io/sync-options: Prune=false   # Matter 패브릭 인증서와 기기 목록. 잃으면 모든 Matter 기기를 다시 커미셔닝해야 합니다
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
```
{: file="iot/edge/matter/pvc.yaml" }

지역 오버레이는 두 폴더 모두 베이스를 그대로 참조합니다.

```yaml
resources:
  - ../../../edge/home-assistant
```
{: file="iot/clusters/[SITE]/home-assistant/kustomization.yaml" }

```yaml
resources:
  - ../../../edge/matter
```
{: file="iot/clusters/[SITE]/matter/kustomization.yaml" }

```bash
# 커밋하고 push
git add iot/edge/home-assistant iot/edge/matter iot/clusters/[SITE]/home-assistant iot/clusters/[SITE]/matter
git commit -m "feat(iot): 엣지 Home Assistant 와 Matter 컨트롤러(matterjs-server) 추가"
git push
```

- **확인:** Argo CD 에 `[SITE]-home-assistant`, `[SITE]-matter` 가 `Synced`, `Healthy`. `curl http://[EDGE_IP]:5580/health` 가 `{"version":"1.4.0","node_count":0}` 처럼 응답하고, `http://[EDGE_IP]:8123` 에 HA 첫 화면이 열립니다.

## 2. 온보딩과 장기 액세스 토큰

브라우저로 `http://[EDGE_IP]:8123` 을 열어 소유자 계정을 만들고 위치·단위 화면을 마칩니다. 이후 설정은 API 로 하므로 관리자 권한의 **장기 액세스 토큰**이 필요합니다. HA 의 왼쪽 아래 사용자 이름을 눌러 프로필로 들어가 **보안** 탭의 **장기 액세스 토큰**에서 토큰을 만들고, 값은 한 번만 보이니 바로 엣지 클러스터 Secret 에 넣습니다.

```bash
# control plane. 붙여 넣은 토큰은 화면에 보이지 않습니다
read -rsp "HA 장기 토큰: " T; echo; echo "입력 길이: ${#T}"
[ -n "$T" ] && printf '%s' "$T" | kubectl --kubeconfig ~/k3s-[SITE].yaml -n home-assistant \
  create secret generic ha-api-token --from-file=token=/dev/stdin
unset T
```

> `입력 길이` 가 0 이면 입력이 들어가지 않은 것입니다. 이 상태로 Secret 을 만들면 값이 빈 채로 생기고, 다시 만들 때 `already exists` 오류가 납니다. 이때는 `kubectl ... delete secret ha-api-token` 뒤 다시 실행합니다.
{: .prompt-warning }

- **확인:** `kubectl --kubeconfig ~/k3s-[SITE].yaml -n home-assistant get secret ha-api-token -o jsonpath='{.data.token}' | base64 -d | wc -c` 가 0 이 아닌 값(180 안팎)입니다.

## 3. 통합 설정 스크립트 실행

스크립트는 세 가지를 합니다. 웹 화면의 **기기 및 서비스 > 통합구성요소 추가** 와 같은 설정 흐름으로 MQTT·Matter·OpenThread Border Router 통합을 추가하고, OTBR 이 만든 Thread 데이터셋을 HA 의 기본 네트워크로 지정하고, 역방향 프록시 신뢰와 로그인 실패 차단을 켭니다. 여러 번 실행해도 이미 된 부분은 건너뜁니다.

HA 2026 부터는 역방향 프록시 설정(`http:`)을 `configuration.yaml` 이 아니라 HA 내부 저장소에서 관리합니다. 첫 기동 때 YAML 을 한 번 옮기고 나면 YAML 의 `http:` 는 무시되므로, 스크립트가 WebSocket API(`http/config/configure`)로 새 설정을 넣습니다. HA 는 새 설정을 "대기(pending)" 상태로 두고 재시작해 적용하며, 정상적으로 다시 뜬 것을 확인하고 확정(`http/config/promote`)해야 남습니다. 확정하지 않으면 5분 뒤 이전 설정으로 되돌아가므로 잘못된 설정으로 HA 에 못 들어가는 일이 없습니다.

변수 블록의 `REMOTES` 는 여러 지역 HA 를 모아 보는 중앙 HA 에서만 씁니다([중앙 Home Assistant로 여러 지역 Home Assistant 모아 보는 방법](/posts/49/)). 지역 HA 에서는 비워 둡니다.

```bash
# control plane 에서 스크립트 내려받기
wget https://eu4ng.github.io/assets/scripts/iot/setup-home-assistant.sh
```

<details markdown="1">
<summary>setup-home-assistant.sh 전문</summary>

```bash
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
        while b"\r\n\r\n" not in resp:
            c = self.s.recv(1)
            if not c: raise ConnectionError("closed")   # 닫힌 소켓의 recv 는 b"" 를 곧바로 돌려줘 무한 루프가 됩니다
            resp += c
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
```
{: file="setup-home-assistant.sh" }

</details>

스크립트 위쪽의 `TRUSTED_PROXIES` 에 HA 앞에 올 역방향 프록시의 주소를 넣습니다. 5단계처럼 허브 Traefik 을 거치면 허브 파드의 요청이 허브 노드 주소로 바뀌어 엣지에 도착하므로 허브 노드 IP 들을 적습니다. 밖에서 오는 요청은 그 앞에 Cloudflare 를 거치므로, 기본값처럼 스크립트의 Cloudflare 대역(`$CLOUDFLARE_IPV4`)도 남겨 둡니다. 빼면 HA 가 Cloudflare 주소를 접속자로 보고 로그인 실패 차단도 그 주소에 겁니다. `KUBECTL` 에는 엣지 kubeconfig 를 적습니다.

```bash
# 실행. MQTT 비밀번호(homeassistant 계정)는 실행 중 입력합니다
bash setup-home-assistant.sh http://[EDGE_IP]:8123
```

- **확인:** 마지막에 `통합 상태` 표에 `mqtt`, `matter`, `otbr`, `thread` 가 모두 `loaded`, 그 아래에 `Thread: … 을 기본 네트워크로 지정` 과 `확정: {'use_x_forwarded_for': True, …}` 가 보입니다. HTTP 설정 단계에서 HA 가 한 번 재시작하므로 30초쯤 걸립니다. 다시 실행하면 모든 줄이 `건너뜀` 입니다.

## 4. Matter 상태와 제어 기록을 수집 파이프라인에 연결

1단계의 `matter_statestream` 은 Matter 엔티티 상태가 바뀔 때마다 `hass/[도메인]/[엔티티]/state` 토픽에 JSON 을 발행합니다. `state` 는 상태값(`21.5`, `on`, `off`, `unavailable`)이고, 나머지는 Zigbee 기기와 같은 `readings` 테이블에 넣기 위한 기기 이름·측정 항목과 HA 기기 레지스트리에서 가져온 실물 기기 정보입니다. 수집은 모두 수집이 기본이라 식별 버튼(`button`), 펌웨어(`update`), 전원 복구 설정(`select`) 엔티티도 발행합니다. 엔티티 속성은 바뀐 것만 `hass/[도메인]/[엔티티]/attr/[속성]` 에 같은 모양으로 발행하고 `property` 는 `[측정 항목]_[속성]` 입니다. 그래서 펌웨어 버전은 `firmware_installed_version` 행으로 남습니다.

| 키 | 예 | 내용 |
|---|---|---|
| `time` | `2026-09-26T03:12:45.123456+00:00` | 상태가 바뀐 시각(`last_changed`, 속성은 `last_updated`). Telegraf 가 수신 시각 대신 이 값을 기록 시각으로 써서, 브로커에 쌓였다가 늦게 도착한 값도 시각이 맞습니다 |
| `device` | `bedroom2-air_quality` | HA 기기 이름. Zigbee 기기처럼 `<방>-<종류>[-<기준>][번호]` 로 지어야 기록되고, DB 에는 `room`(`bedroom2`), `device`(`air_quality`), `anchor`(기준이 있을 때)로 나뉘어 들어갑니다 |
| `property` | `pm25` | 엔티티 ID 에서 기기 이름을 뗀 측정 항목 |
| `unit` | `μg/m³` | 엔티티의 단위(`unit_of_measurement`). 단위가 없는 엔티티는 빈 값입니다 |
| `node` | `CFEE358179DBE7B6-0000000000000001` | 패브릭 ID 와 노드 ID. 기기를 다시 커미셔닝하면 바뀝니다 |
| `serial` | `602EPDJ02346` | 기기 시리얼. Zigbee 의 IEEE 주소처럼 바뀌지 않습니다. `hw_id` 컬럼으로 들어갑니다 |
| `model`, `vendor` | `LG Air Quality Sensor`, `LG Electronics` | 모델과 제조사 |

`control_events` 는 HA 의 `call_service` 이벤트 가운데 Matter·MQTT(Zigbee) 통합 엔티티로 간 호출을 `hass/events/call_service` 에, 자동화·스크립트 실행을 `hass/events/run` 에 발행합니다. 자동화가 에너지를 얼마나 아꼈는지처럼 제어 주체별로 평가하려면 명령마다 누가 보냈는지가 있어야 하기 때문입니다. HA 는 명령마다 context 를 붙이는데, 앱·UI 에서 사람이 보냈으면 `user_id` 가 있어 `origin` 이 `user`, `actor` 가 그 사람의 `person` 이름이 됩니다. 자동화·스크립트가 보냈으면 그 실행과 context 가 같아 `origin` 이 `automation`, `actor` 가 `automation.…` 입니다. 기기 버튼으로 직접 조작한 것은 명령이 없으므로 events 에 행이 없고 readings 의 상태 행으로만 남습니다. 수집 자동화 자신의 실행은 기록하지 않습니다. 빼지 않으면 상태가 바뀔 때마다 행이 생기고 `control_events` 가 자기 실행에 다시 걸려 끝없이 돕니다.

| 키 | 예 | 내용 |
|---|---|---|
| `action` | `switch.turn_off`, `button.press` | 서비스 이름. 실행 행은 `automation_triggered`·`script_started` |
| `data` | `{"brightness": 120}` | 대상을 뺀 서비스 데이터 JSON. 실행 행은 자동화 이름과 트리거 설명 |
| `origin`, `actor` | `user`·`eu4ng`, `automation`·`automation.night_off` | 누가 보냈는지. 둘 다 없으면 `system` |
| `context_id`, `parent_id` | `01M3EPCBAYEHP7BH5K7FJWERAE` | HA context. 자동화 실행 행과 그 자동화가 보낸 명령이 `context_id` 로 이어집니다 |
| `device`, `property`, `protocol`, `serial` … | `bedroom2-plug-charger_qh_z19`, `outlet` | 상태 발행과 같은 기기 정보. `protocol` 은 `matter`·`zigbee` 입니다 |

Telegraf 에 두 입력을 Zigbee2MQTT 입력 바로 아래에 추가합니다. 상태·속성 입력은 JSON 의 기기 정보를 태그로 받고 `time` 을 기록 시각으로 쓰며 `protocol = "matter"`, `source = "hass"` 를 붙입니다. `state` 를 `value`(숫자, `on`/`off` 는 1/0)와 `value_text` 로 나누는 일은 [Telegraf 글](/posts/43/)에서 둔 공통 starlark 프로세서가 그대로 맡습니다. 제어 기록 입력은 `name_override = "events"` 로 그 글의 두 번째 출력을 거쳐 `events` 테이블에 들어갑니다.

{% raw %}
```toml
# Home Assistant 가 재발행한 Matter 기기 상태와 속성. 토픽 hass/<도메인>/<엔티티>/state, hass/<도메인>/<엔티티>/attr/<속성>, 값은 JSON
#   {"state": "21.5"|"on"|"unavailable", "time", "device", "property", "unit", "node", "serial", "model", "vendor"}
# 속성은 바뀔 때만 오고 property 가 <측정 항목>_<속성>(예: firmware_installed_version)입니다.
# HA 자동화가 Matter 통합 소속 엔티티만 발행하므로 Zigbee 기기와 중복되지 않습니다.
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.mosquitto.svc.cluster.local:1883"]
  topics = ["hass/+/+/state", "hass/+/+/attr/+"]
  username = "${MQTT_USER}"
  password = "${MQTT_PASSWORD}"
  client_id = "telegraf-hass"
  persistent_session = true
  qos = 1
  topic_tag = ""
  name_override = "readings"
  data_format = "json"
  json_string_fields = ["state"]      # 상태는 숫자·문자가 섞여 있어 문자열로 받고 아래 starlark 가 나눕니다
  json_time_key = "time"              # 상태가 바뀐 시각(HA last_changed). 수신 시각 대신 써서 지연 도착해도 시각이 맞습니다
  json_time_format = "2006-01-02T15:04:05Z07:00"   # RFC 3339. 소수점 초가 있어도 파싱됩니다
  tag_keys = ["device", "property", "unit", "node", "serial", "model", "vendor"]
  [inputs.mqtt_consumer.tags]
    protocol = "matter"
    source = "hass"

# 기기 제어 기록(events 테이블). HA 자동화 control_events 가 발행합니다. 유지 메시지가 아니라 한 번씩만 옵니다.
#   hass/events/call_service: Matter·Zigbee 기기로 간 서비스 호출 하나 = 행 하나
#     {"time", "device", "property", "protocol", "node", "serial", "model", "vendor", "action": "switch.turn_off", "data": "{…}",
#      "origin": "user"|"automation"|"system", "actor": "사람 이름"|"automation.…", "context_id", "parent_id"}
#   hass/events/run: 자동화·스크립트 실행. device 가 비어 있고 action 은 automation_triggered|script_started, actor 는 그 entity_id 입니다
[[inputs.mqtt_consumer]]
  servers = ["tcp://mosquitto.mosquitto.svc.cluster.local:1883"]
  topics = ["hass/events/+"]
  username = "${MQTT_USER}"
  password = "${MQTT_PASSWORD}"
  client_id = "telegraf-hass-events"
  persistent_session = true
  qos = 1
  topic_tag = ""
  name_override = "events"
  data_format = "json"
  json_string_fields = ["action", "data", "context_id", "parent_id"]
  json_time_key = "time"              # 이벤트가 난 시각(HA time_fired)
  json_time_format = "2006-01-02T15:04:05Z07:00"
  tag_keys = ["device", "property", "protocol", "origin", "actor", "node", "serial", "model", "vendor"]
  [inputs.mqtt_consumer.tags]
    source = "hass"
```
{: file="iot/edge/telegraf/telegraf.conf (추가 부분)" }
{% endraw %}

```bash
# 커밋하고 push
git add iot/edge/telegraf/telegraf.conf
git commit -m "feat(iot): Telegraf 에 Home Assistant 재발행(Matter 기기)과 제어 기록 입력 추가"
git push
```

Telegraf 는 기기 이름이 `<방>-<종류>[-<기준>][번호]` 규칙(칸은 `-` 로 나누고 칸 안의 단어는 `_` 로 잇는 영문 소문자·숫자)에 맞는 값만 기록하므로, 등록 직후의 기본 이름(`Air Quality Sensor` 등)으로 보낸 값은 DB 에 남지 않습니다. Matter 기기를 하나 등록하고 이름을 규칙대로 바꾼 뒤 **개발자 도구** > **상태** 에서 그 기기의 센서 엔티티 상태를 임의 값으로 바꿔 보면, 실제 값이 바뀔 때까지 기다리지 않고 경로 전체를 확인할 수 있습니다. 스마트 플러그는 종류를 `plug` 로 두고 기준 칸에 꽂은 제품을 적습니다(`bedroom2-plug-monitor_27gp850`). 다른 제품을 꽂으면 기준 칸만 바꾸면 되고, 과거 행은 옛 제품으로 남습니다.

- **확인:** 허브에서 `kubectl -n timescaledb exec deploy/timescaledb -- psql -U iot -d iot -c "select time, site, room, device, anchor, property, value, value_text, hw_id, node from readings where protocol = 'matter' order by time desc limit 5;"` 에 `site` 가 `[SITE]`, `room`·`device`·`anchor` 가 HA 기기 이름을 나눈 방·종류·기준, `property` 가 측정 항목인 행이 보이고, 숫자 상태는 `value`, `on` 은 `value` 1 과 `value_text` `on` 으로 들어갑니다. `hw_id` 에는 시리얼, `node` 에는 노드 ID 가 들어갑니다. Telegraf 가 다시 붙을 때 브로커가 유지 메시지를 다시 보내므로 재시작 직후 각 엔티티의 마지막 값이 원래 시각으로 한 번 더 들어올 수 있습니다. HA 앱에서 플러그를 껐다 켜면 `select time, anchor, property, action, origin, actor from events order by time desc limit 2;` 에 `switch.turn_off`·`switch.turn_on` 두 행이 `origin` `user`, `actor` 에 사람 이름으로 보이고, readings 에는 0.1초쯤 뒤 같은 플러그의 `outlet` 상태 행이 보입니다.

> `property` 는 엔티티 ID 에서 기기 이름을 떼어 만듭니다. 한국어 HA 는 기기 이름을 바꾸고 방을 지정할 때 엔티티 ID 를 `방 + 기기 이름 + 엔티티 이름` 의 로마자로 다시 만듭니다(`sensor.cimsil2_bedroom2_air_quality_ondo`). 기기를 등록하고 이름을 정한 직후 [중앙 HA 글](/posts/49/)의 `ha-registry.py --rename-matter --assign-areas` 를 실행해 `sensor.bedroom2_air_quality_temperature` 처럼 영문 ID 로 맞추고 영역도 이름의 방으로 지정합니다. 영문 ID 여야 `property` 가 `temperature` 처럼 깔끔하게 남습니다. 화면의 표시 이름은 한국어 그대로입니다. 엔티티 ID 가 바뀌어도 `hw_id`(시리얼)는 그대로이므로, 옛 ID 로 쌓인 기록도 `hw_id` 로 같은 기기에 묶어 볼 수 있습니다.
{: .prompt-tip }

## 5. 밖에서 열기와 2단계 인증

지역 서비스는 `<서비스>-<지역약자>.[DOMAIN]` 으로 엽니다. 무료 Cloudflare 인증서가 한 단계 하위 도메인만 덮기 때문에 `ha.[SITE].[DOMAIN]` 같은 계층 대신 평면 이름을 씁니다. 엣지 노드는 허브와 같은 LAN 에 있으므로 허브 Traefik 이 엣지 노드 주소로 중계합니다. Zigbee2MQTT 와 Matter 대시보드는 다른 관리 화면처럼 밖에서 Google 로그인(oauth2-proxy)을 거치게 하고, HA 는 휴대폰 앱이 로그인 페이지 리디렉트를 처리하지 못하므로 oauth2-proxy 없이 HA 자체 로그인과 2단계 인증으로 보호합니다.

```yaml
# 지역 엣지 클러스터(k3s, [EDGE_IP])의 웹 UI 를 허브 Traefik 뒤에 둡니다. 허브와 엣지가 같은 LAN 이라 노드 주소로 바로 붙습니다.
# 엣지 쪽 포트: HA·Matter 는 hostNetwork, Z2M 은 NodePort 30083. (EndpointSlice 는 Argo CD 가 무시하므로 ExternalName 을 씁니다)
apiVersion: v1
kind: Service
metadata:
  name: ha
spec:
  type: ExternalName
  externalName: [EDGE_IP]
  ports:
    - { name: http, port: 8123 }
---
apiVersion: v1
kind: Service
metadata:
  name: z2m
spec:
  type: ExternalName
  externalName: [EDGE_IP]
  ports:
    - { name: http, port: 30083 }
---
apiVersion: v1
kind: Service
metadata:
  name: matter
spec:
  type: ExternalName
  externalName: [EDGE_IP]
  ports:
    - { name: http, port: 5580 }
```
{: file="iot/hub/edge-web-[SITE]/services.yaml" }

```yaml
# 지역 서비스 이름은 <서비스>-<지역약자>.[DOMAIN] (예: 대전 dj). 내부망은 Google 로그인 없이, 외부는 Google 로그인(oauth2-proxy) 뒤에 둡니다.
# HA 는 휴대폰 앱이 로그인 페이지 리디렉트를 처리하지 못하므로 oauth2-proxy 없이 HA 자체 로그인 + 2단계 인증(OTP)으로 보호합니다.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: z2m-[SITE_CODE]
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`z2m-[SITE_CODE].[DOMAIN]`) && ClientIP(`[LAN_CIDR]`)   # 내부망: Z2M 토큰만
      kind: Rule
      priority: 20
      services:
        - { name: z2m, port: 30083 }
    - match: Host(`z2m-[SITE_CODE].[DOMAIN]`)                                    # 외부: Google 로그인 뒤 Z2M 토큰
      kind: Rule
      priority: 10
      middlewares:
        - { name: forward-auth, namespace: oauth2-proxy }
      services:
        - { name: z2m, port: 30083 }
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: matter-[SITE_CODE]
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`matter-[SITE_CODE].[DOMAIN]`) && ClientIP(`[LAN_CIDR]`)   # 내부망: 무인증 (Matter 대시보드는 자체 로그인이 없습니다)
      kind: Rule
      priority: 20
      services:
        - { name: matter, port: 5580 }
    - match: Host(`matter-[SITE_CODE].[DOMAIN]`)                                    # 외부: Google 로그인
      kind: Rule
      priority: 10
      middlewares:
        - { name: forward-auth, namespace: oauth2-proxy }
      services:
        - { name: matter, port: 5580 }
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: ha-[SITE_CODE]
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`ha-[SITE_CODE].[DOMAIN]`)                                        # 내부·외부 모두 HA 로그인 + OTP
      kind: Rule
      services:
        - { name: ha, port: 8123 }
```
{: file="iot/hub/edge-web-[SITE]/ingressroutes.yaml" }

`iot/hub/` 아래 폴더는 허브에 배포됩니다. 이름을 밖에서 찾을 수 있게 DDNS 목록(`services/cloudflare-ddns` 의 `DOMAINS`)과 내부망 DNS(`lan_dns_names`)에 `ha-[SITE_CODE]`, `z2m-[SITE_CODE]`, `matter-[SITE_CODE]` 를 추가합니다. 방법은 [외부 접속 글](/posts/40/)과 [내부망 DNS 글](/posts/41/)의 서비스 추가 절차와 같습니다.

2단계 인증은 HA 프로필의 **보안** 탭에서 **다단계 인증 모듈**의 **인증 앱**을 켜고, 화면의 QR 코드를 Google OTP 같은 TOTP 인증 앱으로 찍어 등록합니다. 코드는 휴대폰 시계로 만들어지므로 인터넷이 끊겨도 집 안에서 로그인할 수 있습니다.

> HA 는 2단계 인증의 백업 코드를 주지 않습니다. 인증 앱의 클라우드 백업을 켜 두거나 두 번째 기기에도 등록해 둡니다. 잠겼을 때는 HA 설정 볼륨의 `.storage` 에서 해당 사용자의 다단계 인증 모듈을 끄고 다시 시작해야 합니다.
{: .prompt-danger }

HA 휴대폰 앱에서는 **내부 URL** 을 `http://[EDGE_IP]:8123`(집 Wi-Fi 에서), **외부 URL** 을 `https://ha-[SITE_CODE].[DOMAIN]` 으로 두면 인터넷이 끊겨도 집 안에서는 앱이 계속 동작합니다.

- **확인:** 휴대폰 데이터망에서 `https://ha-[SITE_CODE].[DOMAIN]` 이 HA 로그인 화면을, `https://z2m-[SITE_CODE].[DOMAIN]` 과 `https://matter-[SITE_CODE].[DOMAIN]` 이 Google 로그인 화면을 보여 줍니다. 허브에서 `curl -s -o /dev/null -w "%{http_code}" https://ha-[SITE_CODE].[DOMAIN]/` 가 `200` 입니다. 프록시 설정이 없으면 여기서 `400` 이 나오고 HA 로그에 `A request from a reverse proxy was received … not set-up for reverse proxies` 가 남습니다.

## 6. 확인

```bash
# 엣지 kubeconfig 로 HA 로그의 오류와 통합 상태
E="--kubeconfig ~/k3s-[SITE].yaml"
kubectl $E -n home-assistant logs deploy/home-assistant | grep -E "automation|reverse proxy" | tail -3

# Thread 보더 라우터 상태 (OTBR 을 쓰는 경우)
curl -s http://[EDGE_IP]:8081/node/state
```

- **확인:** HA 로그에 자동화 설정 오류나 reverse proxy 오류가 없고, **설정 > 자동화 및 장면** 에 `Matter 상태를 MQTT 로 재발행` 과 `기기 제어 기록을 MQTT 로 발행` 이 보입니다. OTBR 상태는 `"leader"` 입니다. HA 의 **설정 > 기기 및 서비스**에 MQTT 아래 Zigbee2MQTT 브리지와 기기들이 자동으로 보입니다.

## 트러블슈팅

<details markdown="1">
<summary><code>required key not provided at 'other_settings.set_client_cert'</code> — MQTT 통합 추가 중</summary>

- **원인:** MQTT 설정 폼에 접힌 "고급 설정" 섹션(`other_settings`)이 필수로 들어 있고, 그 안의 인증서 사용 여부 항목들이 기본값 없이 필수입니다. 빈 객체를 보내면 거부됩니다.
- **해결:** 섹션 안의 항목을 기본값으로 채우고, 기본값 없는 필수 항목은 체크박스는 `false`, 선택 목록은 첫 항목(`off`)으로 보냅니다. 스크립트에 반영되어 있습니다.

</details>

<details markdown="1">
<summary><code>400: Bad Request</code> — 역방향 프록시 뒤에서 HA 를 열 때</summary>

- **원인:** HA 가 프록시에서 온 요청(`X-Forwarded-For` 포함)을 신뢰하지 않습니다. HA 2026 에서는 `configuration.yaml` 에 `http:` 블록을 넣어도 무시됩니다(첫 기동 때 이미 내부 저장소로 옮겨졌기 때문입니다).
- **해결:** 3단계 스크립트가 WebSocket API 로 `use_x_forwarded_for` 와 `trusted_proxies` 를 넣고 재시작 뒤 확정합니다.

</details>

<details markdown="1">
<summary><code>Login attempt or request with invalid authentication from 172.69.…</code> — 로그의 접속자가 Cloudflare 주소일 때</summary>

- **원인:** HA 가 앞단 Traefik 만 신뢰하고 그 앞의 Cloudflare 는 신뢰하지 않아, `X-Forwarded-For` 를 따라가다 Cloudflare 주소에서 멈춥니다. 이 상태에서는 로그인 실패 차단이 실제 접속자가 아니라 Cloudflare 주소에 걸려, 같은 Cloudflare 경로로 들어오는 다른 접속까지 막힐 수 있습니다.
- **해결:** `TRUSTED_PROXIES` 에 스크립트의 `$CLOUDFLARE_IPV4` 를 함께 넣고 다시 실행합니다. 이후 로그에는 접속자의 공인 IP 가 찍힙니다.

</details>

## 마무리

엣지 클러스터에 HA 와 Matter 서버를 배포하고, 통합 추가와 Thread 기본 네트워크 지정, 역방향 프록시 설정을 API 스크립트로 넣어, Matter 기기 상태가 Zigbee 와 같은 경로로 허브 DB 에 모이게 했습니다. HA 는 설정과 대시보드만 맡으므로 HA 가 멈춰도 Zigbee 수집은 계속되고, Matter 패브릭은 별도 볼륨에 있어 HA 를 다시 만들어도 기기를 다시 등록하지 않습니다. Thread 보더 라우터는 [다음 글](/posts/47/)에서 다룹니다.

## 참고 자료

- [Home Assistant - Matter](https://www.home-assistant.io/integrations/matter/)
- [Home Assistant - Templating (integration_entities)](https://www.home-assistant.io/docs/configuration/templating/)
- [Home Assistant - MQTT (Publish action)](https://www.home-assistant.io/integrations/mqtt/)
- [Home Assistant - HTTP](https://www.home-assistant.io/integrations/http/)
- [Home Assistant - Multi-factor authentication](https://www.home-assistant.io/docs/authentication/multi-factor-auth/)
- [Home Assistant - WebSocket API](https://developers.home-assistant.io/docs/api/websocket/)
- [matter-js/matterjs-server - Docker](https://github.com/matter-js/matterjs-server/blob/main/docs/docker.md)
- [Telegraf - Starlark Processor](https://github.com/influxdata/telegraf/tree/master/plugins/processors/starlark)
