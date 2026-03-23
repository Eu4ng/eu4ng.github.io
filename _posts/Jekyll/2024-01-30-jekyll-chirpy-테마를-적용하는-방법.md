---
layout: post
title: Jekyll Chirpy 테마를 적용하는 방법
date: 2024-01-30 17:56 +0900
author:
categories: [Jekyll, Chirpy]
tags: [jekyll, chirpy]
---

## 개요

### 소개

GitHub 블로그 제작 시 Jekyll Chirpy 테마를 적용하는 방법입니다. 다른 블로그에서는 보통 `jekyll-theme-chirpy` 저장소를 `fork` 해서 사용하는 방법이 일반적입니다. 그러나 저처럼 윈도우를 사용하는 경우에는 `chirpy-starter` 템플릿 저장소를 이용하는 것이 더 쉬운 방법이라고 생각합니다.

### 요약

1. [chirpy-starter](https://github.com/cotes2020/chirpy-starter) 저장소 템플릿 사용
2. [jekyll-theme-chirpy](https://github.com/cotes2020/jekyll-theme-chirpy) 저장소 일부 복제
  - _layouts
  - _javascript
  - _includes
  - _data/authors.yml
  - _posts (선택)

---

## 방법

### 1. chirpy-starter 저장소 템플릿 사용

먼저 `chirpy-starter` 저장소 템플릿을 사용하여 `GITHUB_USERNAME.github.io` 저장소를 생성합니다.

로컬 기기에서 블로그 화면을 테스트하기 위해서는 저장소를 Clone 한 뒤 해당 폴더에서 아래 콘솔 명령어를 차례대로 입력합니다. 로컬 기기에는 [Ruby](https://rubyinstaller.org/) 가 미리 설치되어 있어야 합니다.

> bundler 설치

```bash
gem install bundler
```

> 필요한 번들을 설치합니다.

```bash
bundle
```

> 로컬 웹서버 가동

```bash
jekyll serve
```

만약 템플릿을 직접 사용하는 대신 수동으로 복제해서 사용하고 싶으신 경우에는 폴더 째로 붙여넣으신 다음 `assets/lib` git 서브 모듈 역시 추가하셔야 합니다.

### 2. jekyll-theme-chirpy 저장소 일부 복제

1 번 과정을 끝마치면 빈 블로그만 보이게 됩니다. 기본 템플릿을 적용하기 위해서는 `jekyll-theme-chirpy` 저장소의 일부 폴더 및 파일들을 복제해서 사용하면 됩니다. 복제 대상 목록은 아래와 같습니다.

```
_layouts
_javascript
_includes
_data/authors.yml
_posts (선택)
```

`_posts` 의 경우 Jekyll Chirpy 테마 사용법에 관한 게시글들이 들어있습니다. 굳이 가져오지 않아도 상관 없지만 저는 유용한 글들이라 생각하여 그대로 가져왔습니다. 단, `Getting Started` 와 `Text and Typography` 게시글의 경우 이미지를 `chirpy-img.netlify.app` CDN 서버에서 가져오고 있기 때문에 추후 본인의 CDN 서버로 연결 시 링크가 깨지는 현상에 대비하여 미리 수동으로 이미지 링크 주소를 변경해주면 됩니다.

*예시*

```md
![Build source](/posts/20180809/pages-source-light.png) # 기존
![Build source](https://chirpy-img.netlify.app/posts/20180809/pages-source-light.png) # 수정
```

---

## 참고

- [chirpy-starter / GitHub](https://github.com/cotes2020/chirpy-starter)
- [Jekyll Chirpy 테마 사용하여 블로그 만들기 / 블로그](https://www.irgroup.org/posts/jekyll-chirpy/)
