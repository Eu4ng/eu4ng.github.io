---
layout: post
title: Docker로 GitLab 서버 설치하는 방법
date: 2024-02-09 20:52 +0900
author: Eu4ng
tags: [git-lab, docker]
---

## 1. Docker 이미지 선택

GitLab의 공식 Docker 이미지는 **CE(Community Edition)**와 **EE(Enterprise Edition)** 두 가지 버전이 있습니다.

- **CE**: 완전 무료 버전
- **EE**: 기본은 유료이나 무료 플랜을 포함하며, 유료 기능을 활성화할 수 있는 버전

두 버전은 기능상 차이가 있지만, 나중에 CE에서 EE로 업그레이드하려면 번거로운 마이그레이션 과정이 필요합니다. 따라서 처음부터 **EE** 버전을 설치하여 사용하는 것을 권장합니다.

[Docker Hub](https://hub.docker.com/r/gitlab/gitlab-ee)에서 `gitlab/gitlab-ee` 이미지를 다운로드하시면 됩니다.

## 2. Docker Compose 설정

설정의 간편함을 위해 **Docker Compose**를 사용합니다. 저는 **Docker**에 **Portainer**를 설치한 뒤, **Stacks** 기능을 통해 배포를 진행했습니다. 본인의 환경(폴더 경로 등)에 맞춰 일부 수정하여 사용하시기 바랍니다.

```yaml
services:
  gitlab:
    image: 'gitlab/gitlab-ee:latest'
    container_name: gitlab
    restart: always
    hostname: 'gitlab.example.com'
    shm_size: '8g'
    environment:
      GITLAB_TIMEZONE: Asia/Seoul
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://gitlab.example.com'
    ports:
      - "11000:80"
      - "11001:443"
      - "11002:22"
    volumes:
      - '/docker/gitlab/config:/etc/gitlab'
      - '/docker/gitlab/logs:/var/log/gitlab'
      - '/docker/gitlab/data:/var/opt/gitlab'
```
{: file="docker-compose.yml" }

## 3. GitLab 로그인 및 비밀번호 변경

GitLab 설치가 완료된 후 웹 브라우저로 첫 접속 시, 관리자 계정 생성 화면이 나타나면 비밀번호를 설정하면 됩니다. 만약 로그인 화면이 먼저 나타난다면 아래의 초기 비밀번호 확인 방법이나 수동 변경 방법을 시도해 보시기 바랍니다.

### root 계정 초기 비밀번호 확인 방법
```sh
docker exec -it gitlab grep 'Password:' /etc/gitlab/initial_root_password
```

### root 계정 비밀번호 수동 변경 방법
위 방법으로 비밀번호를 찾을 수 없거나 로그인이 되지 않는다면, 아래 명령어를 통해 직접 변경할 수 있습니다.

```sh
# 1. 도커 컨테이너 접속
docker exec -it gitlab /bin/bash

# 2. GitLab 콘솔 접속 (사양에 따라 약 2~4분 정도 소요)
# gitlab(prod)> 프롬프트가 뜰 때까지 기다려야 합니다.
gitlab-rails console

# 3. root 계정 생성 여부 확인 (1이 출력되어야 정상)
User.count

# 4. root 계정 정보 불러오기 및 비밀번호 변경
user = User.find_by(username: 'root')
user.password = 'NewPassword123!'
user.password_confirmation = 'NewPassword123!'

# 5. 변경 사항 저장 (true가 출력되어야 성공)
user.save!
```

## 4. 트러블슈팅

### root 계정 생성 누락 이슈

#### 문제
- RAM 24GB 환경에서 GitLab 설치 중 컨테이너가 **Exit Code 137** 오류와 함께 수차례 강제 종료 및 재시작됨.
- 정상 구동 후 웹 UI 접속은 가능하나, `root` 계정 로그인이 불가능하고 Rails 콘솔에서도 `User.find_by(username: 'root')`가 `nil`을 반환함.

#### 원인 분석
- **CPU 부하**: 초기 데이터베이스 생성 단계에서 CPU 사용량이 급증하여 시스템 리소스 보호 차원에서 프로세스가 강제 종료된 것으로 추정.
- **초기 데이터 구성 단계 누락**: 재시작 과정에서 테이블 생성은 완료되었으나, 초기 데이터 구성 단계가 누락되어 데이터베이스에 사용자가 0명인 상태로 서비스가 시작되는 것으로 추정.

#### 해결 방법
`gitlab-rake`를 사용하여 수동으로 초기 데이터 구성을 진행합니다.

```bash
docker exec -it gitlab gitlab-rake db:seed_fu
```

#### 결과
명령어 실행 후 누락되었던 초기 데이터 구성이 완료되며, 웹 브라우저 재접속 시 정상적으로 관리자 비밀번호 설정 화면이 나타납니다.

## 참고

- [Rails console / GitLab](https://docs.gitlab.com/ee/administration/operations/rails_console.html)
- [[Docker] 도커 컨테이너에 깃랩(Gitlab) 설치 - 오늘의 기록](https://gksdudrb922.tistory.com/214)
- [[Docker for Windows] GitLab & Admin 관리자 계정 설정법](https://forgiveall.tistory.com/552)
- [Gitlab CE , EE - Mancheol's SQL Blog - 티스토리](https://manshei.tistory.com/146)
- [[GitLab] 초기 패스워드 확인 및 변경 방법](https://velog.io/@rectangle714/GitLab-%EC%B4%88%EA%B8%B0-%ED%8C%A8%EC%8A%A4%EC%9B%8C%EB%93%9C-%ED%99%95%EC%9D%B8-%EB%B0%8F-%EB%B3%80%EA%B2%BD-%EB%B0%A9%EB%B2%95)