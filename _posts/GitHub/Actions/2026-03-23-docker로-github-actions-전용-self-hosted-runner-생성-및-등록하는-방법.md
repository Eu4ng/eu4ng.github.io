---
layout: post
title: Docker로 Github Actions 전용 Self-hosted Runner 생성 및 등록하는 방법
date: 2026-03-23 23:08 +0900
author: Eu4ng
tags: [git-hub, actions, self-hosted-runner]
---

## Dockerfile

```dockerfile
FROM ubuntu:22.04

RUN  apt-get clean
RUN  apt-get update

RUN apt-get install --reinstall tar

RUN apt-get update && \
    apt-get install -y \
    curl \
    tar \
    gzip \
    jq \
    git \
    libicu-dev

RUN  mkdir -p /actions-runner

COPY start.sh /actions-runner/start.sh

RUN chmod +x /actions-runner/start.sh

RUN useradd -m runner

RUN chown -R runner:runner /actions-runner

USER runner
WORKDIR /actions-runner

RUN curl -o actions-runner-linux-x64-2.317.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.317.0/actions-runner-linux-x64-2.317.0.tar.gz
RUN echo "9e883d210df8c6028aff475475a457d380353f9d01877d51cc01a17b2a91161d  actions-runner-linux-x64-2.317.0.tar.gz" | shasum -a 256 -c

RUN tar xzf ./actions-runner-linux-x64-2.317.0.tar.gz

RUN ls -la /actions-runner

# ENTRYPOINT 설정
ENTRYPOINT ["/actions-runner/start.sh"]
```

## start.sh

> API에 조직 url과 Fine-grained personal access token을 입력해주어야 합니다.
{: .prompt-danger }

```bash
#!/bin/bash

response=$(curl -L -X POST -H "Accept: application/vnd.github+json" -H "Authorization: Bearer <token>" -H "X-GitHub-Api-Version: 2022-11-28" https://api.github.com/orgs/<corp>/actions/runners/registration-token)

token=$(echo $response | jq -r '.token')

echo $token
./config.sh --url https://github.com/looko-corp --token $token

./run.sh
```

## docker-compose.yml

```yaml
version: '3.8'

services:
  actions-runner-1:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: actions-runner-container-1
    environment:
      - DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true
    entrypoint: ["/actions-runner/start.sh"]
    user: runner
    working_dir: /actions-runner

  actions-runner-2:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: actions-runner-container-2
    environment:
      - DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true
    entrypoint: ["/actions-runner/start.sh"]
    user: runner
    working_dir: /actions-runner
```