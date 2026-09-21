# AGENTS.md

Chirpy 테마를 쓰는 Jekyll 블로그(eu4ng.github.io)다. 글은 `_posts/카테고리/` 아래 마크다운 파일이고,
`develop` 브랜치에 커밋하면 PR 로 `main` 에 병합될 때 GitHub Pages 로 배포된다.

## 게시글 작업

게시글을 새로 쓰거나 고칠 때는 [`.agents/skills/blog-post/SKILL.md`](.agents/skills/blog-post/SKILL.md)
를 읽고 그 규칙과 절차를 따른다. 템플릿 선택, 파일 위치와 front matter, 제목 구조와 문체, 코드 블록
표기, 설치 스크립트 작성 방식, 발행 전 검증이 모두 거기에 있다.

## 발행 전 검증

push 전에 저장소 루트에서 순서대로 실행한다. 3번이 `finished successfully` 를 낼 때까지 push 하지 않는다.

```bash
python3 scripts/add_permalinks.py
JEKYLL_ENV=production bundle exec jekyll b -d /tmp/_site
bundle exec htmlproofer /tmp/_site --disable-external \
  --ignore-urls "/^http:\/\/127.0.0.1/,/^http:\/\/0.0.0.0/,/^http:\/\/localhost/"
```

## 저장소 규칙

- 커밋 메시지는 Conventional Commits 를 따른다 (`commitlint.config.js`, husky `commit-msg` 훅이 검사한다).
- 특정 도구 전용 폴더나 파일(`.claude/` 등)과 심볼릭 링크는 저장소에 만들지 않는다.
