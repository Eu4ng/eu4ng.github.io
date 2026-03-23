---
layout: post
title: Docker 로 GitLab 서버 설치하는 방법
date: 2024-02-09 20:52 +0900
author: Eu4ng
categories: [GitLab]
tags: [git-lab]
---

## 방법

### 1. 이미지 다운로드

`gitlab/gitlab-ee` 이미지를 다운로드하시면 됩니다.

### 2. 컨테이너 설정 및 생성

`gitlab/gitlab-ee` 이미지에서 사용하는 볼륨은 세 개입니다.

- /var/opt/gitlab
- /var/log/gitlab
- /etc/gitlab

마운트 설정 및 기타 설정을 진행한 후 컨테이너를 실행합니다.

### 3. GitLab 비밀번호 변경

Docker 를 윈도우로 설치한 경우에는 PowerShell 로 접속해야 합니다.

```sh
# docker 컨테이너 접속
docker exec -it 컨테이너-이름 /bin/bash

# gitlab 콘솔 접속
gitlab-rails console

# root 계정 접근
user = User.find_by(username: 'root')

# root 비밀번호 변경
user.password = 'reset_password' # 8 글자 이상만 가능
user.save

# true 가 출력되야 성공
```



## 참고

- [Rails console / GitLab](https://docs.gitlab.com/ee/administration/operations/rails_console.html)
- [[Docker] 도커 컨테이너에 깃랩(Gitlab) 설치 - 오늘의 기록](https://gksdudrb922.tistory.com/214)
- [[Docker for Windows] GitLab & Admin 관리자 계정 설정법](https://forgiveall.tistory.com/552)