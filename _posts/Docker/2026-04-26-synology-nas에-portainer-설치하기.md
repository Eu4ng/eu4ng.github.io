---
layout: post
title: Synology NAS에 Portainer 설치하기
date: 2026-04-26 22:23 +0900
author: Eu4ng
tags: []
---

## 개요

**Synology NAS**에 **Portainer**를 설치하는 과정에 대해 정리한 문서입니다.

## 서론

**Docker**를 활용한 서비스를 구축하다보니 **Docker Compose**가 아닌 **Docker Swarm** 모드를 사용해야하는 경우가 생깁니다. 하지만 **Synology NAS**의 **Container Manager**는 **Docker Swarm**을 지원하지 않고 기능이 부족하여 **Portainer**를 설치하여 사용하고자 합니다.

## 환경 설정

> 이미 설정되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info}

### 1. Synology NAS에 Docker 설치

**Synology NAS**의 **패키지 센터**에서는 **Docker** 대신 **Container Manager**라는 이름으로 제공됩니다.

- **패키지 센터**: `Container Manager` 설치
- **제어판** > **공유 폴더**: `docker` 공유 폴더 생성

### 2. 역방향 프록시 설정

아래 예시를 참고하여 설정해주시면 됩니다.

- **제어판** > **로그인 포털** > **고급** > **역방향 프록시**
  - **역방향 프록시 이름**: `Portainer`
  - **소스**
    - **프로토콜**: `HTTPS`
    - **호스트 이름**: `portainer.example.com`
    - **포트**: `443`
    - **HSTS 활성화**: `활성화`
  - **대상**
    - **프로토콜**: `HTTPS`
    - **호스트 이름**: `localhost`
    - **포트**: `9443`

### 2. Synology NAS 터미널 활성화

**Container Manager**의 프로젝트는 **Docker Compose** 방식으로 배포됩니다. **Docker Swarm** 방식으로 배포하기 위해서는 터미널 접속이 필요합니다.

- **제어판** > **터미널 및 SNMP**: `SSH 서비스 활성화`
- [PuTTY](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html) 다운로드 및 설치
- **PuTTY**로 **Synology NAS**에 **SSH** 접속

### 3. Docker Swarm 활성화

- **Docker Swarm** 매니저 노드로 설정합니다.

  ```bash
  docker swarm init --advertise-addr [IP_ADDRESS]
  ```

- **Docker Swarm** 워커 노드를 추가하려면 매니저 노드에서 아래 명령어를 실행하여 토큰을 얻은 후 워커 노드에 접속하여 실행합니다.

  ```bash
  # 매니저 노드에서 실행
  docker swarm join-token worker

  # 워커 노드에서 실행
  docker swarm join --token [WORKER_TOKEN] [MANAGER_IP]
  ```

## Portainer 설치

### 1. Portainer 스택 배포

- **Synology NAS** > **docker** 공유 폴더: `portainer`, `portainer/data` 폴더 생성
- 아래 내용을 `portainer` 폴더에 **docker-compose.yml** 파일로 저장합니다.

  ```yaml
  services:
    portainer-ce:
      image: portainer/portainer-ce:latest
      ports:
        - '8000:8000' # HTTP
        - '9443:9443' # HTTPS
        - '9000:9000' # Agent
      volumes:
        - '/var/run/docker.sock:/var/run/docker.sock'
        - '/volume1/docker/portainer/data:/data'
      networks:
        - agent_network
      deploy:
        placement:
          constraints: [node.role == manager]

  networks:
    agent_network:
      driver: overlay
      attachable: true
  ```
  {: file="docker-compose.yml"}
- `portainer` 스택 배포

  ```bash
  sudo -i

  cd /volume1/docker/portainer

  docker stack deploy -c docker-compose.yml portainer
  ```

### 2. Portainer Agent 스택 배포

- **Portainer** 접속 후 아래 내용을 `portainer-agent` 스택으로 배포합니다.

  ```yaml
  services:
    agent:
      image: portainer/agent:latest
      environment:
        - AGENT_CLUSTER_ADDR=tasks.agent
      ports:
        - '9001:9001'
      volumes:
        - '/var/run/docker.sock:/var/run/docker.sock'
        - '/var/lib/docker/volumes:/var/lib/docker/volumes'
      networks:
        agent_network:
          aliases:
            - agent
      deploy:
        mode: global
        placement:
          constraints: [node.platform.os == linux]

  networks:
    agent_network:
      driver: overlay
      attachable: true
  ```
  {: file="docker-compose.yml" }