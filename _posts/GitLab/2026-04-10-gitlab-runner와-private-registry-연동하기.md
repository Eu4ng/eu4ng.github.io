---
layout: post
title: GitLab Runner와 Private Registry 연동하기
date: 2026-04-10 14:44 +0900
permalink: /posts/26/
author: Eu4ng
tags: [gitlab, runner, docker, registry, ghcr]
---

## 서론

**Docker Executor**를 사용하는 **GitLab Self-managed Runner**를 운영하다 보면, **Docker Hub** 이미지 외에 인증이 필요한 **Private Registry**의 이미지가 필요한 순간이 생깁니다. 저의 경우 **언리얼 엔진(Unreal Engine)**의 공식 이미지를 사용하기 위해 **GitHub Container Registry(GHCR)** 로그인이 필수적이었습니다.

이 포스트에서는 `DOCKER_AUTH_CONFIG` 변수를 설정함으로써 **GitLab Self-managed Runner**가 **Private Registry**의 이미지를 가져오는 방법에 대해 알아보겠습니다.

## 방법

### 1. GitHub 개인 액세스 토큰(PAT) 발급

먼저 **GitHub Container Registry**에 접근할 수 있는 권한을 가진 토큰이 필요합니다.

1. **GitHub** 홈페이지의 **Settings** > **Developer Settings** > **Personal access tokens** > **Tokens (classic)**로 이동합니다.
2. **Generate new token (classic)**을 클릭합니다.
3. 토큰 이름을 입력하고, **read:packages** 혹은 **write:packages** 권한을 선택합니다.
4. **Generate token**을 클릭합니다.
5. 발급된 토큰을 복사합니다.

### 2. 개인 엑세스 토큰 Base64 인코딩

GitLab의 인증 설정에는 `사용자ID:토큰` 형식을 **Base64**로 인코딩한 문자열이 들어갑니다. 별도의 도구 없이 브라우저의 개발자 도구를 활용해 간편하게 만들 수 있습니다.

1. 크롬 등 브라우저에서 **F12**를 눌러 개발자 도구를 엽니다.
2. **Console** 탭에서 아래 명령어를 본인의 정보에 맞게 입력합니다.
```javascript
btoa("GitHub_ID:GitHub_TOKEN")
```
3. 출력된 인코딩 결과값(예: `R3U0bm...`)을 복사합니다.

> 개발자 도구 콘솔 창에 명령어 붙여넣기가 막혀있는 경우, `allow pasting`을 먼저 입력해줍니다.

### 3. GitLab CI/CD 변수 등록

이제 GitLab 서버로 돌아와 인증 정보를 변수로 등록합니다. 이 설정은 **운영자**, **그룹**, 또는 개별 **프로젝트** 단위로 적용할 수 있습니다.

1. **운영자 영역** > **설정** > **CI/CD** > **변수**로 이동합니다.
2. **변수 추가**를 클릭하고 다음과 같이 입력합니다.
  - 공개범위: `표시`
  - 플래그: `보호 변수` 비활성화
  - 키: `DOCKER_AUTH_CONFIG`
  - 값: 아래 JSON 형식에서 `BASE64_ENCODED_TOKEN` 자리에 위에서 복사한 문자열을 입력합니다.
   ```json
   {
     "auths": {
       "https://ghcr.io": {
         "auth": "BASE64_ENCODED_TOKEN"
       }
     }
   }
   ```
3. **변수 추가**를 클릭하여 저장합니다.

## 요약 및 결론

지금까지 `DOCKER_AUTH_CONFIG` 변수를 설정함으로써 **GitLab Self-managed Runner**가 **Private Registry**의 이미지를 가져오는 방법에 대해 알아보았습니다. 이 방법은 **GHCR**뿐만 아니라 다른 사설 레지스트리도 **JSON** 형식만 맞춰주면 동일하게 적용 가능합니다.

## 참고 자료

- [CI/CD variables \| GitLab Docs](https://docs.gitlab.com/ci/variables/)
- [Authenticate with registry in Docker-in-Docker \| GitLab Docs](https://docs.gitlab.com/ci/docker/authenticate_registry/)