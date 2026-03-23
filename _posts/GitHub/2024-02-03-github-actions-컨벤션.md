---
layout: post
title: GitHub Actions 컨벤션
date: 2024-02-03 21:27 +0900
author: Eu4ng
categories: [GitHub, Actions]
tags: [git-hub, actions, workflow, convention]
---

## 작성 계기

> GitHub Actions 은 Workflow, Jobs, Steps, Action 으로 구성되어 있습니다. 
> 그런데 참고하는 예제마다 각 구성 요소들의 이름 규칙이 상이하기 때문에 한번 정리해보려고 합니다.
{: .prompt-info}

## Workflow 명명 규칙

저는 [GitHub Actions 설명서 / GitHub Docs](https://docs.github.com/ko/actions) 의 예제를 기준으로 삼았습니다.

- 파일: 소문자 및 하이픈(-) 사용 (lower-case)
- Workflow: 보조 단어를 제외한 모든 단어는 대문자 사용 (Sentence Case)
- Jobs: 소문자 및 하이픈(-) 사용 (lower-case)
- Steps: 첫 글자만 대문자 사용 (Capitalization)

### 예제

*check-dist.yml*
```yaml
name: Check dist

on:
  push:
    branches:
      - main
    paths-ignore:
      - '**.md'
  pull_request:
    paths-ignore:
      - '**.md'
  workflow_dispatch:

jobs:
  check-dist:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v3

      - name: Set Node.js 20.x
        uses: actions/setup-node@v1
        with:
          node-version: 20.x

      - name: Install dependencies
        run: npm ci

      - name: Rebuild the index.js file
        run: npm run build

      - name: Compare the expected and actual dist/ directories
        run: |
          if [ "$(git diff --ignore-space-at-eol dist/ | wc -l)" -gt "0" ]; then
            echo "Detected uncommitted changes after build.  See status below:"
            git diff
            exit 1
          fi

      # If dist/ was different than expected, upload the expected version as an artifact
      - uses: actions/upload-artifact@v2
        if: ${{ failure() && steps.diff.conclusion == 'failure' }}
        with:
          name: dist
          path: dist/
```
