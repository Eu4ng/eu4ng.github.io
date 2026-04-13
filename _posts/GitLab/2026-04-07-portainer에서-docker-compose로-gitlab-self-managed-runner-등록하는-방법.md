---
layout: post
title: Portainer에서 Docker Compose로 GitLab Self-managed Runner 등록하는 방법
date: 2026-04-07 12:46 +0900
permalink: /posts/24/
author: Eu4ng
tags: [gitlab, docker, portainer]
---

## 서론

사설 **GitLab** 서버를 구축한 후 **CI/CD** 파이프라인을 운영하기 위해서는 **Self-managed Runner** 등록이 필수적입니다.

공식 문서에서는 **CLI** 명령어를 통한 수동 등록 방식이 소개되어 있지만, 저는 **Portainer**와 **Docker Compose**를 활용하여 더 간편하게 설정하는 방법에 대해 소개하고자 합니다.

## 방법

### 1. GitLab 서버 설정: 토큰 발급

가장 먼저 **Runner**를 등록하기 위한 토큰을 발급받아야 합니다. 여기서는 모든 프로젝트에서 공용으로 사용할 수 있는 **Instance Runner**를 기준으로 설명합니다.

1. **운영자 영역** > **CI/CD** > **Runners** 메뉴로 이동
2. **인스턴스 러너 생성** 클릭
3. **태그없는 작업 실행** 체크 후 **러너 만들기** 클릭
4. `runner authentication token`을 안전한 곳에 메모합니다.

### 2. Portainer 설정: Docker Secret 등록

토큰은 민감한 정보이므로 **Docker Compose** 파일에 하드코딩하는 대신 **Docker Secret**을 사용하는 것을 권장드립니다.

1. **Portainer** 대시보드에서 **Secrets** > **Add secret** 클릭
2. 다음과 같이 입력:
   - **Name**: gitlab_runner_instance_alpine_token
   - **Secret**: `runner authentication token`
3. **Create the secret**을 눌러 저장

### 3. Docker Compose 작성 및 배포

마지막으로 **Runner** 등록 및 실행을 위한 **Docker Compose** 파일 작성 후 배포를 진행합니다.

1. 본인의 환경에 맞게 아래 **Docker Compose** 파일을 수정
2. **Portainer** 대시보드에서 **Stacks** > **Add stack** 클릭
3. **Docker Compose** 파일 등록
4. **Deploy the stack** 클릭

```yaml
services:
  gitlab-runner:
    image: 'gitlab/gitlab-runner:alpine'
    container_name: gitlab-runner-alpine
    restart: always
    volumes:
      - '/var/run/docker.sock:/var/run/docker.sock'
      - '/volume1/docker/gitlab-runner/alpine:/etc/gitlab-runner'
    environment:
      - GITLAB_URL=https://gitlab.example.com
      - EXECUTOR=docker
      - DOCKER_IMAGE=alpine:latest
      - CONCURRENT=2
    secrets:
      - source: gitlab_runner_instance_alpine_token
        target: token
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        if [ ! -f /etc/gitlab-runner/config.toml ]; then
          echo 'Registering new GitLab Runner...'

          gitlab-runner register \
            --non-interactive \
            --url $$GITLAB_URL \
            --token $$(cat /run/secrets/token) \
            --executor $$EXECUTOR \
            --docker-image $$DOCKER_IMAGE

          sed -i "s/^concurrent = .*/concurrent = $$CONCURRENT/" /etc/gitlab-runner/config.toml
        else
          echo 'Runner is already registered.'
        fi

        exec gitlab-runner run --user=gitlab-runner --working-directory=/home/gitlab-runner

secrets:
  gitlab_runner_instance_alpine_token:
    external: true
```
{: file="docker-compose.yml" }

## 트러블슈팅

### `config.toml` 파일이 생성되지 않는 오류

- **오류 메시지:** `ERROR: Failed to load config stat /etc/gitlab-runner/config.toml: no such file or directory`
- **원인:** `gitlab-runner register` 명령어 수행 과정에서 오류가 발생하여 `config.toml` 파일이 생성되지 않았습니다.
- **해결:** `--run-untagged`나 `--locked`와 같은 레거시 옵션이 포함되어 있을 때 등록에 실패할 수 있습니다. 이 경우 해당 옵션들을 제거하고 다시 시도해 보세요.

## 참고 자료

- [Registering runners \| GitLab Docs](https://docs.gitlab.com/runner/register/)
- [GitLab Runner commands \| GitLab Docs](https://docs.gitlab.com/runner/commands/)