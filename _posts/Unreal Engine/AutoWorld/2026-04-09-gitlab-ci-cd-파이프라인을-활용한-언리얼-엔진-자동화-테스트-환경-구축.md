---
layout: post
title: "GitLab CI/CD 파이프라인을 활용한 언리얼 엔진 자동화 테스트 환경 구축"
date: 2026-04-09 21:34 +0900
author: Eu4ng
tags: [ue5, gitlab, ci-cd, tdd]
---

## 서론

새롭게 시작하는 언리얼 엔진 프로젝트에서는 기존의 경험을 발판 삼아 유지보수성과 작업 효율을 극대화하고자 합니다. 이를 위해 가장 먼저 **GitLab CI/CD 파이프라인**과 **TDD(테스트 주도 개발)** 방식을 도입하기로 결정했습니다.

이번 포스트에서는 수동 테스트의 번거로움을 줄이고, 코드의 안정성을 보장하기 위해 **GitLab CI/CD 파이프라인을 활용하여 언리얼 엔진 자동화 테스트 환경을 구축하는 방법**에 대해 알아보겠습니다.

## 진행 과정

### 1. 언리얼 엔진 내에서 자동화 테스트 설정

1. **테스트 코드 작성**

    먼저 간단한 테스트 코드를 작성합니다.

    ```cpp
    #include "Misc/AutomationTest.h"

    IMPLEMENT_SIMPLE_AUTOMATION_TEST(AutoWorldTest, "AutoWorld.Test",
                                    EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

    bool AutoWorldTest::RunTest(const FString& Parameters)
    {
        // Make the test pass by returning true, or fail by returning false.
        return true;
    }
    ```
    {: file="AutoWorldTest.cpp" }

2. **에디터에서 테스트 실행 및 검증**

    작성한 테스트 코드가 에디터에서 정상적으로 동작하는지 확인합니다.

    - **편집** > **플러그인** > **Testing** > **Functional Testing Editor** 플러그인을 활성화 후 재시작합니다.
    - **툴** > **테스트 자동화** 메뉴를 열어 방금 작성한 카테고리를 체크한 후 **시작** 버튼을 클릭합니다.

### 2. GitLab CI/CD 파이프라인 연동

에디터에서 테스트가 성공적으로 동작하는 것을 확인했다면, 이제 **GitLab CI/CD 파이프라인**을 통해 코드가 푸시될 때마다 자동으로 테스트가 진행되도록 프로젝트 루트 디렉토리에 `.gitlab-ci.yml` 파일을 추가하고 아래와 같이 설정해 줍니다.

**주요 설정 포인트**
- **캐시 적용:** 브랜치별로 빌드 캐시를 공유하여, 첫 빌드 이후의 파이프라인 실행 속도를 단축시킵니다.
- **테스트 결과 보존:** `artifacts`의 `when: always` 옵션을 설정하여, 테스트가 실패하더라도 원인을 분석할 수 있도록 테스트 결과를 항상 아티팩트로 저장합니다.

```yaml
stages:
  - build
  - test

image: ghcr.io/epicgames/unreal-engine:dev-slim-5.7.4

variables:
  PROJECT_NAME: "AutoWorld"
  PROJECT_PATH: "$CI_PROJECT_DIR/$PROJECT_NAME/$PROJECT_NAME.uproject"
  TEST_REPORT_PATH: "$CI_PROJECT_DIR/$PROJECT_NAME/TestResults"

cache:
  key: "$CI_COMMIT_REF_SLUG"
  fallback_keys: 
    - "develop"
  paths:
    - $PROJECT_NAME/Binaries/
    - $PROJECT_NAME/DerivedDataCache/
    - $PROJECT_NAME/Intermediate/
    - $PROJECT_NAME/Saved/

build_job:
  stage: build
  script:
    - echo "$PROJECT_NAME 프로젝트 빌드 시작..."
    - /home/ue4/UnrealEngine/Engine/Build/BatchFiles/RunUAT.sh BuildCookRun -project="$PROJECT_PATH" -targetplatform=Linux -build -nop4 -compile -ddc=InstalledNoZenLocalFallback -DDC-LocalDataCachePath="$CI_PROJECT_DIR/$PROJECT_NAME/DerivedDataCache" -BuildMachine

test_job:
  stage: test
  script:
    - echo "$PROJECT_NAME 프로젝트 자동화 테스트 시작..."
    - /home/ue4/UnrealEngine/Engine/Binaries/Linux/UnrealEditor-Cmd "$PROJECT_PATH" -ExecCmds="Automation RunTests $PROJECT_NAME; Quit" -TestExit="Automation Test Queue Empty" -unattended -NullRHI -NoUI -BuildMachine -stdout -ReportExportPath="$TEST_REPORT_PATH" -ddc=InstalledNoZenLocalFallback -DDC-LocalDataCachePath="$CI_PROJECT_DIR/$PROJECT_NAME/DerivedDataCache"
  artifacts:
    when: always
    paths:
      - $PROJECT_NAME/TestResults/
    expire_in: 1 week
```
{: file=".gitlab-ci.yml" }

성공적으로 설정을 마친 후 코드를 푸시하면, 파이프라인에서 빌드와 테스트 작업이 순차적으로 실행되는 것을 확인할 수 있습니다.

## 참고 자료

- [언리얼 엔진 명령줄 실행인자 레퍼런스](https://dev.epicgames.com/documentation/unreal-engine/unreal-engine-command-line-arguments-reference)