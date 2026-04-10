---
layout: post
title: GameplayEffect 사용 방법
date: 2024-02-05 21:24 +0900
permalink: /posts/15/
author: Eu4ng
tags: [unreal-engine, ue5, gas, gameplay-effect]
---

## 사용 방법

1. MakeOutgoingSpec
2. ApplyGameplayEffectSpec

```c++
FGameplayEffectSpecHandle GameplayEffectSpecHandle = MakeOutgoingSpec(DefaultEffect, 1, MakeEffectContext());
if(GameplayEffectSpecHandle.IsValid())
{
  ApplyGameplayEffectSpecToSelf(*GameplayEffectSpecHandle.Data.Get());
}
```
{: file="UMyAbilitySystemComponent.cpp"}

## 개념

### FGameplayEffectContext

- GameplayEffectSpec 의 Instigator 와 TargetData 정보를 가지고 있습니다.
- ModifierMagnitudeCalculations / GameplayEffectExecutionCalculations, AttributeSets, and GameplayCues 간에 임의의 데이터를 전송하기 적합한 구조체입니다.
