---
layout: post
title: GitLab에서 GitHub 프로젝트 가져오기
date: 2026-04-04 07:11 +0900
permalink: /posts/23/
author: Eu4ng
tags: [gitlab, github, omniauth, docker]
---

## 작성 계기

사설 GitLab 서버를 운영하다 보면 GitHub에 있는 프로젝트를 가져오거나, GitHub 계정으로 간편하게 로그인하고 싶은 경우가 있습니다. 이 글에서는 Docker로 설치된 GitLab에서 GitHub OmniAuth를 구성하여 프로젝트 가져오기 기능을 활성화하는 방법을 정리합니다.

## 방법

### 1. GitLab 서버 설정

먼저 GitLab 관리자 계정으로 로그인하여 가져오기 소스를 활성화해야 합니다.

1. **운영자 영역** > **설정** > **일반**으로 이동합니다.
2. **가져오기 및 내보내기 설정** 섹션을 확장합니다.
3. **소스 가져오기** 항목에서 `GitHub`을 체크하고 저장합니다.

### 2. GitHub OAuth App 생성

GitLab 서버가 GitHub 데이터에 접근할 수 있도록 GitHub에서 OAuth App을 생성해야 합니다.

1. GitHub 홈페이지의 **Settings** > **Developer Settings** > **OAuth Apps**에서 **New OAuth App**을 클릭합니다.
2. 아래 예시를 참고하여 설정합니다.
   - **Application name**: `GitLab Self-Managed`
   - **Homepage URL**: `https://gitlab.example.com`
   - **Authorization callback URL**: `https://gitlab.example.com/users/auth`

생성 후 발급되는 **Client ID**와 **Client secrets**을 안전한 곳에 복사해 둡니다.

### 3. Docker Compose 설정 (OmniAuth)

이제 GitLab Docker Compose 파일에 발급받은 **Client ID**와 **Client secrets**을 등록합니다. 보안을 위해 **Docker secrets** 방식을 사용합니다.

- `external_url`: HTTPS 환경이라면 반드시 `https`로 설정합니다.
- `nginx/letsencrypt`: 역방향 프록시를 사용 중이라면 GitLab 내부의 자동 SSL 기능을 비활성화해야 합니다.
- `omniauth_auto_link_user`: 기존 이메일이 일치할 경우 자동으로 계정을 연동합니다.

```yaml
services:
  gitlab:
    image: 'gitlab/gitlab-ee:latest'
    container_name: gitlab
    restart: always
    hostname: 'gitlab.example.com'
    shm_size: '16g'
    environment:
      GITLAB_TIMEZONE: Asia/Seoul
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://gitlab.example.com'
        
        # 역방향 프록시 사용 시 필수 설정
        nginx['listen_port'] = 80
        nginx['listen_https'] = false
        letsencrypt['enable'] = false
        
        # OmniAuth 설정
        gitlab_rails['omniauth_enabled'] = true
        gitlab_rails['omniauth_auto_link_user'] = ['github']
        gitlab_rails['omniauth_allow_single_sign_on'] = ['github']
        gitlab_rails['omniauth_block_auto_created_users'] = false
        gitlab_rails['omniauth_providers'] = [
          {
            name: "github",
            # Docker secrets에서 키 읽기 (Ruby 문법)
            app_id: File.read('/run/secrets/github_app_id').strip,
            app_secret: File.read('/run/secrets/github_app_secret').strip,
            args: { scope: "user:email,repo" }
          }
        ]
    secrets:
      - source: gitlab_self-managed_client_id
        target: github_app_id
      - source: gitlab_self-managed_client_secrets
        target: github_app_secret
    ports:
      - "11000:80"
      - "11001:443"
      - "11002:22"
    volumes:
      - '/volume1/docker/gitlab/config:/etc/gitlab'
      - '/volume1/docker/gitlab/logs:/var/log/gitlab'
      - '/volume1/docker/gitlab/data:/var/opt/gitlab'

secrets:
  gitlab_self-managed_client_id:
    external: true
  gitlab_self-managed_client_secrets:
    external: true
```
{: file="docker-compose.yml" }

## 트러블 슈팅

### `redirect_uri` 관련 오류
- **오류 메시지:** The redirect_uri is not associated with this application.
- **원인:** GitLab의 `external_url`과 GitHub의 `Authorization callback URL`이 불일치합니다.
- **해결:** `external_url`을 `http`에서 `https`로 변경하여 `Authorization callback URL`과 일치시켰습니다.

### 이메일 중복 오류 (422 Error)
- **오류 메시지:** 422: GitHub 인증을 사용한 로그인에 실패했습니다. Email은(는) 이미 존재합니다.
- **원인:** GitLab 계정의 이메일과 GitHub 계정의 이메일이 동일합니다.
- **해결:** `gitlab_rails['omniauth_auto_link_user'] = ['github']` 설정을 추가하여 자동 연동을 활성화했습니다.

## 참고 자료

- [Use GitHub as an OAuth 2.0 authentication provider](https://docs.gitlab.com/integration/github/)
- [OmniAuth \| GitLab Docs](https://docs.gitlab.com/ee/integration/omniauth.html)