---
layout: post
title: Gameplay Ability 사용 방법
date: 2024-02-06 15:10 +0900
permalink: /posts/19/
author: Eu4ng
tags: [unreal-engine, ue5, gas, gameplay-ability]
---

## 주요 API

- CanActivateAbility
  - Ability 를 활성화할 수 있는 조건이 충족되었는지 확인합니다.
- TryActivateAbility
    - Ability 를 활성화할 수 있는 조건이 충족되었다면 Ability 를 활성화합니다.
    - CanActivateAbility 를 호출합니다.
    - 주로 입력 액션 이벤트가 직접 호출합니다.
- ActivateAbility
    - Ability 가 활성화되면 수행할 작업을 정의하는 곳입니다.
- CommitAbility
    - Ability 활성화를 위해 필요한 자원을 소모하고 쿨타임을 적용합니다.
    - ActivateAbility 보다 먼저 호출되어야 합니다.
- CancelAbility
    - Ability 를 취소합니다.
- EndAbility
    - Ability 를 종료합니다. Ability 내에서 반드시 호출되어야 합니다.
    - 호출되지 않는 경우 해당 Ability 가 계속 활성화인 상태로 방치됩니다. 즉, 태그가 제거되지 않습니다.
