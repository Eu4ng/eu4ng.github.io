---
layout: post
title: Windows와 리눅스 서버에서 GitHub SSH 키와 커밋 서명 설정하는 방법
date: 2026-09-19 23:22 +0900
permalink: /posts/31/
description: 개인용 키와 서버용 키를 따로 만들어 Windows PC와 Remote SSH 리눅스 서버 양쪽에서 GitHub 인증과 커밋 서명을 설정하는 방법을 정리했습니다.
author: Eu4ng
tags: [github, ssh, git, windows, linux, remote-ssh]
---

SSH 키는 장비마다 따로 만들고, Git 설정과 확인은 Windows와 서버에서 같은 명령으로 진행합니다. 비밀키가 만든 장비 밖으로 나가지 않으므로, 서버가 유출되어도 GitHub에서 서버용 키만 삭제하면 됩니다.

| 키 | 생성 위치 | 서버 접속 | GitHub 인증 | 커밋 서명 |
| :--- | :--- | :---: | :---: | :---: |
| `[GITHUB_ID]@desktop` | Windows PC | O | O | O |
| `[GITHUB_ID]@server` | 리눅스 서버 | X | O | O |

1. SSH 키 생성 (Windows와 서버 공통)
2. 서버에 개인용 공개키 등록 (Windows)
3. GitHub에 공개키 등록
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

## 1. SSH 키 생성 (Windows와 서버 공통)

Windows PowerShell과 서버 터미널에서 각각 키를 생성합니다. 명령은 같고 키를 구분하는 주석(`-C`)만 다릅니다. 저장 위치를 묻는 질문에는 Enter를 눌러 기본 경로를 그대로 사용합니다.

```bash
# Windows PowerShell: 개인용 키 생성
ssh-keygen -t ed25519 -C "[GITHUB_ID]@desktop"

# 리눅스 서버: 서버용 키 생성
ssh-keygen -t ed25519 -C "[GITHUB_ID]@server"
```

> 비밀키(`id_ed25519`)를 가진 사람은 누구나 내 GitHub 계정으로 푸시할 수 있습니다. 비밀키는 만든 장비 밖으로 복사하지 않습니다.
{: .prompt-danger }

- **확인:** 각 장비의 `~/.ssh` 폴더에 `id_ed25519`(비밀키)와 `id_ed25519.pub`(공개키) 생성

## 2. 서버에 개인용 공개키 등록 (Windows)

PowerShell에서 개인용 공개키를 서버의 `authorized_keys`에 추가합니다. 이후 Windows에서 서버에 접속할 때 개인용 키로 인증합니다.

```bash
# 개인용 공개키를 서버의 authorized_keys에 추가
Get-Content ~\.ssh\id_ed25519.pub | ssh [USER]@[HOST] "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

- **확인:** `ssh [USER]@[HOST]` 접속 시 서버 비밀번호를 묻지 않음

## 3. GitHub에 공개키 등록

공개키 두 개를 인증용과 서명용으로 각각 한 번씩, 총 네 번 등록합니다.

```bash
# Windows PowerShell: 개인용 공개키를 클립보드에 복사
Get-Content ~\.ssh\id_ed25519.pub | Set-Clipboard

# 리눅스 서버: 서버용 공개키 출력 (출력된 한 줄을 복사)
cat ~/.ssh/id_ed25519.pub
```

1. GitHub의 **Settings** > **SSH and GPG keys**로 이동
2. **New SSH key** 클릭
3. 아래 값을 입력하고 **Add SSH key** 클릭
   - **Title**: 키 주석과 같은 이름 (`[GITHUB_ID]@desktop` 또는 `[GITHUB_ID]@server`)
   - **Key type**: `Authentication Key`
   - **Key**: 복사한 공개키 붙여넣기
4. **New SSH key**를 다시 클릭하고 **Key type**만 `Signing Key`로 바꿔 한 번 더 등록
5. 나머지 공개키도 2~4번을 반복해 등록

- **확인:** **Authentication keys**와 **Signing keys** 목록에 키가 두 개씩 표시

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
<summary><code>Permission denied (publickey)</code></summary>

```text
git@github.com: Permission denied (publickey).
```

- **원인:** 해당 장비의 공개키가 `Authentication Key`로 등록되지 않았거나, 키 파일이 `~/.ssh/id_ed25519` 경로에 없음
- **해결:** 3단계의 등록 상태와 키 파일의 이름, 위치를 확인

</details>

<details markdown="1">
<summary>커밋이 GitHub에서 <code>Unverified</code>로 표시</summary>

- **원인:** 해당 장비의 공개키가 `Signing Key`로 등록되지 않았거나, `user.email`이 GitHub 계정에 인증된 이메일과 다름
- **해결:** 3단계의 4번과 4단계의 `user.email` 값을 확인한 뒤 새 커밋을 푸시

</details>

## 마무리

개인용 키와 서버용 키를 따로 만들어 Windows PC와 리눅스 서버 양쪽에서 GitHub 인증과 커밋 서명을 설정했습니다. 새 서버를 추가할 때는 그 서버에서 1단계부터 반복하고, 서버를 폐기할 때는 GitHub에서 해당 서버용 키만 삭제하면 됩니다.

## 참고 자료

- [새 SSH 키 생성 및 ssh-agent에 추가](https://docs.github.com/ko/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent)
- [GitHub 계정에 새 SSH 키 추가](https://docs.github.com/ko/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account)
- [SSH 연결 테스트](https://docs.github.com/ko/authentication/connecting-to-github-with-ssh/testing-your-ssh-connection)
- [Git에 서명 키 알리기](https://docs.github.com/ko/authentication/managing-commit-signature-verification/telling-git-about-your-signing-key)
- [GitHub의 SSH 키 지문](https://docs.github.com/ko/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
