---
layout: post
title: Windows와 리눅스 서버에서 GitHub SSH 키와 커밋 서명 설정하는 방법
date: 2026-09-19 23:22 +0900
permalink: /posts/31/
description: Windows에서 만든 SSH 키 하나로 Windows PC와 Remote SSH 리눅스 서버 양쪽에서 GitHub 인증과 커밋 서명을 설정하는 방법을 정리했습니다.
author: Eu4ng
tags: [github, ssh, git, windows, linux, remote-ssh]
---

키를 만들고 옮기는 일은 Windows에서 한 번만 하고, Git 설정과 확인은 Windows와 서버에서 같은 명령으로 진행합니다.

1. SSH 키 생성 (Windows)
2. GitHub에 공개키 등록
3. 서버로 키 전송 (Windows)
4. Git 설정 (Windows와 서버 공통)
5. 연결과 서명 확인 (Windows와 서버 공통)

## 사전 준비

> 이미 준비되어 있는 경우 건너뛰셔도 됩니다.
{: .prompt-info }

아래 환경을 기준으로 작성했습니다.

| 항목 | 버전 |
| :--- | :--- |
| Windows PC | `Windows 11` |
| 리눅스 서버 | `Ubuntu 26.04` |
| Git | `2.34 이상` |
| 작성 기준일 | `2026-09-19` |

다음 항목이 준비되어 있어야 합니다.

- GitHub 계정
- 리눅스 서버의 SSH 접속 정보 (`[USER]@[HOST]`)
- Windows PC에 Git 설치 (OpenSSH 클라이언트는 Windows에 기본 포함)

```bash
# Windows PowerShell
winget install --id Git.Git -e
```

- 리눅스 서버에 Git과 OpenSSH 클라이언트 설치

```bash
# 리눅스 서버
sudo apt update
sudo apt install -y git openssh-client
```

## 1. SSH 키 생성 (Windows)

PowerShell에서 키를 생성합니다. 저장 위치를 묻는 질문에는 Enter를 눌러 기본 경로를 그대로 사용합니다.

```bash
# Ed25519 키 생성
ssh-keygen -t ed25519 -C "[EMAIL]"
```

- **확인:** `C:\Users\[USER]\.ssh` 폴더에 `id_ed25519`(비밀키)와 `id_ed25519.pub`(공개키) 생성

## 2. GitHub에 공개키 등록

같은 공개키를 인증용과 서명용으로 각각 한 번씩, 총 두 번 등록합니다.

```bash
# 공개키를 클립보드에 복사
Get-Content ~\.ssh\id_ed25519.pub | Set-Clipboard
```

1. GitHub의 **Settings** > **SSH and GPG keys**로 이동
2. **New SSH key** 클릭
3. 아래 값을 입력하고 **Add SSH key** 클릭
   - **Title**: 키를 구분할 이름
   - **Key type**: `Authentication Key`
   - **Key**: 복사한 공개키 붙여넣기
4. **New SSH key**를 다시 클릭하고 **Key type**만 `Signing Key`로 바꿔 한 번 더 등록

- **확인:** **Authentication keys**와 **Signing keys** 목록에 키가 하나씩 표시

## 3. 서버로 키 전송 (Windows)

PowerShell에서 서버에 `.ssh` 폴더를 만들고 키 파일 두 개를 복사한 뒤, 비밀키 권한을 소유자 전용으로 바꿉니다.

```bash
# 서버에 .ssh 폴더 생성
ssh [USER]@[HOST] "mkdir -p ~/.ssh && chmod 700 ~/.ssh"

# 비밀키와 공개키 전송
scp $env:USERPROFILE\.ssh\id_ed25519 $env:USERPROFILE\.ssh\id_ed25519.pub [USER]@[HOST]:~/.ssh/

# 비밀키 권한 설정
ssh [USER]@[HOST] "chmod 600 ~/.ssh/id_ed25519"
```

> 비밀키를 가진 사람은 누구나 내 GitHub 계정으로 푸시할 수 있습니다. 본인만 사용하는 서버에만 복사합니다.
{: .prompt-danger }

- **확인:** 서버에서 `ls -l ~/.ssh` 실행 시 `id_ed25519`의 권한이 `-rw-------`로 표시

## 4. Git 설정 (Windows와 서버 공통)

아래 명령을 Windows PowerShell과 서버 터미널에서 각각 똑같이 실행합니다. GPG 키를 따로 만들지 않고 SSH 키로 커밋에 서명하는 설정입니다.

```bash
# 사용자 정보
git config --global user.name "[NAME]"
git config --global user.email "[EMAIL]"

# SSH 키로 커밋 서명
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global commit.gpgsign true
```

> `user.email`은 GitHub 계정에 인증된 이메일과 같아야 커밋에 **Verified** 배지가 붙습니다.
{: .prompt-warning }

- **확인:** `git config --global --list` 출력에 위 다섯 항목이 표시

## 5. 연결과 서명 확인 (Windows와 서버 공통)

Windows와 서버에서 각각 GitHub 연결을 확인합니다. 처음 접속할 때 지문을 묻는 질문이 나오면, 표시된 지문이 `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`인지 확인한 뒤 `yes`를 입력합니다.

```bash
# GitHub SSH 연결 확인
ssh -T git@github.com
```

- **확인:** `Hi [GITHUB_ID]! You've successfully authenticated, but GitHub does not provide shell access.` 출력

이어서 본인 저장소에서 서명된 커밋을 만들어 푸시합니다.

```bash
# 저장소 복제 후 빈 커밋 푸시
git clone git@github.com:[GITHUB_ID]/[REPOSITORY].git
cd [REPOSITORY]
git commit --allow-empty -m "test: 커밋 서명 확인"
git push
```

- **확인:** GitHub 저장소의 커밋 목록에서 해당 커밋 옆에 **Verified** 배지 표시

## 트러블슈팅

<details markdown="1">
<summary><code>Permissions 0644 for '...' are too open</code></summary>

```text
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@         WARNING: UNPROTECTED PRIVATE KEY FILE!          @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
Permissions 0644 for '/home/[USER]/.ssh/id_ed25519' are too open.
```

- **원인:** 서버로 복사한 비밀키를 다른 사용자도 읽을 수 있는 상태
- **해결:** 서버에서 `chmod 600 ~/.ssh/id_ed25519` 실행

</details>

<details markdown="1">
<summary><code>Permission denied (publickey)</code></summary>

```text
git@github.com: Permission denied (publickey).
```

- **원인:** 공개키가 `Authentication Key`로 등록되지 않았거나, 키 파일이 `~/.ssh/id_ed25519` 경로에 없음
- **해결:** 2단계의 등록 상태와 키 파일의 이름, 위치를 확인

</details>

<details markdown="1">
<summary>커밋이 GitHub에서 <code>Unverified</code>로 표시</summary>

- **원인:** 공개키가 `Signing Key`로 등록되지 않았거나, `user.email`이 GitHub 계정에 인증된 이메일과 다름
- **해결:** 2단계의 4번과 4단계의 `user.email` 값을 확인한 뒤 새 커밋을 푸시

</details>

## 마무리

SSH 키 하나로 Windows PC와 리눅스 서버 양쪽에서 GitHub 인증과 커밋 서명을 설정했습니다. 이후 새 서버를 추가할 때는 3단계부터 반복하면 됩니다.

## 참고 자료

- [새 SSH 키 생성 및 ssh-agent에 추가](https://docs.github.com/ko/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent)
- [GitHub 계정에 새 SSH 키 추가](https://docs.github.com/ko/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account)
- [SSH 연결 테스트](https://docs.github.com/ko/authentication/connecting-to-github-with-ssh/testing-your-ssh-connection)
- [Git에 서명 키 알리기](https://docs.github.com/ko/authentication/managing-commit-signature-verification/telling-git-about-your-signing-key)
- [GitHub의 SSH 키 지문](https://docs.github.com/ko/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
