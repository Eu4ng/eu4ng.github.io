---
layout: post
title: AttributeSet 사용 방법
date: 2024-02-05 15:15 +0900
author: Eu4ng
categories: [Unreal Engine, GAS]
tags: [unreal-engine, ue5, gas, attribute-set]
---

## AttributeSet 클래스 작성

> AttributeSet 은 블루프린트가 아닌 C++ 에서만 작성이 가능합니다.
{: .prompt-tip}

주로 `FGameplayAttributeData` 와 여러 매크로를 사용하여 작성됩니다.

자세한 설명은 [공식 문서](https://docs.unrealengine.com/5.3/ko/gameplay-attributes-and-attribute-sets-for-the-gameplay-ability-system-in-unreal-engine/)를 참고하시고 여기서는 간단하게 체력 프로퍼티만 있는 예제로 보여드리겠습니다.

*예시*

```c++
// Fill out your copyright notice in the Description page of Project Settings.

#pragma once

#include "CoreMinimal.h"
#include "UObject/Object.h"
#include "AbilitySystemComponent.h"
#include "AttributeSet.h"
#include "AWAttributeSetBase.generated.h"

#define ATTRIBUTE_ACCESSORS(ClassName, PropertyName) \
  GAMEPLAYATTRIBUTE_PROPERTY_GETTER(ClassName, PropertyName) \
  GAMEPLAYATTRIBUTE_VALUE_GETTER(PropertyName) \
  GAMEPLAYATTRIBUTE_VALUE_SETTER(PropertyName) \
  GAMEPLAYATTRIBUTE_VALUE_INITTER(PropertyName)

/**
 * 체력 관련 요소만 존재하는 기본 AttributeSet 클래스입니다.
 */
UCLASS()
class AUTOWORLD_API UAWAttributeSetBase : public UAttributeSet
{
  GENERATED_BODY()

public:
  // 체력
  UPROPERTY(BlueprintReadOnly, Category = "Health", ReplicatedUsing = OnRep_Health)
  FGameplayAttributeData Health;
  ATTRIBUTE_ACCESSORS(UAWAttributeSetBase, Health)

  // 최대 체력
  UPROPERTY(BlueprintReadOnly, Category = "Health", ReplicatedUsing = OnRep_MaxHealth)
  FGameplayAttributeData MaxHealth;
  ATTRIBUTE_ACCESSORS(UAWAttributeSetBase, MaxHealth)

public:
  // 초기값 설정
  UAWAttributeSetBase();

  virtual void GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const override;

  // 체력 변화 콜백
  UFUNCTION()
  virtual void OnRep_Health(const FGameplayAttributeData& OldHealth);

  // 최대 체력 변화 콜백
  UFUNCTION()
  virtual void OnRep_MaxHealth(const FGameplayAttributeData& OldMaxHealth);
};
```
{: file="AWAttributeSetBase.h"}

```c++
// Fill out your copyright notice in the Description page of Project Settings.


#include "AWAttributeSetBase.h"

#include "Net/UnrealNetwork.h"

UAWAttributeSetBase::UAWAttributeSetBase()
{
}

void UAWAttributeSetBase::GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const
{
  Super::GetLifetimeReplicatedProps(OutLifetimeProps);

  DOREPLIFETIME_CONDITION_NOTIFY(UAWAttributeSetBase, Health, COND_None, REPNOTIFY_Always);
  DOREPLIFETIME_CONDITION_NOTIFY(UAWAttributeSetBase, MaxHealth, COND_None, REPNOTIFY_Always);
}

void UAWAttributeSetBase::OnRep_Health(const FGameplayAttributeData& OldHealth)
{
  GAMEPLAYATTRIBUTE_REPNOTIFY(UAWAttributeSetBase, Health, OldHealth)
}

void UAWAttributeSetBase::OnRep_MaxHealth(const FGameplayAttributeData& OldMaxHealth)
{
  GAMEPLAYATTRIBUTE_REPNOTIFY(UAWAttributeSetBase, MaxHealth, OldMaxHealth)
}
```
{: file="AWAttributeSetBase.cpp"}

## AttributeSet 등록 방법

> 결론부터 말씀드리자면 C++ 로 AttributeSet 등록을 진행하고 초기화는 Gameplay Effect 를 사용하는 것이 좋을 것 같습니다.
{: .prompt-tip}

AttributeSet 을 만들었으면 이를 AbilitySystemComponent 에 등록해 주어야 합니다.

C++ 에서 등록 및 초기화를 모두 진행하는 방법과 블루프린트에서 데이터 테이블을 통해 등록 및 초기화를 진행한 다음 C++ 에서 포인터만 참조하는 방법이 있습니다.

### C++
1. 액터의 생성자에서 AbiliySystemComponent 를 DefaultSubobject로 생성합니다.
2. 액터의 생성자에서 AttributeSet 을 DefaultSubobject로 생성합니다.
   - 이 때 AbiliySystemComponent 에 AttributeSet 이 자동으로 등록됩니다.
3. AttributeSet 의 초기화 함수를 통해 초기화를 진행합니다.

*예시*
```c++
private:
  UPROPERTY(VisibleDefaultsOnly, BlueprintReadOnly, Category = "Abilities", meta = (AllowPrivateAccess = true))
  UAbilitySystemComponent* AbilitySystem;

  UPROPERTY(BlueprintReadOnly, Category = "Abilities", meta = (AllowPrivateAccess = true))
  UMyAttributeSet* AttributeSet;
```
{: file="MyCharacterBase.h"}

```c++
AMyCharacterBase::AMyCharacterBase()
{
  // AbilitySystem 컴포넌트 부착
  AbilitySystem = CreateDefaultSubobject<UAbilitySystemComponent>("AbilitySystem");
  
  // AttributeSet 생성 및 AbilitySystem 에 자동 등록
  AttributeSet = CreateDefaultSubobject<UAWAttributeSetBase>("AttributeSetBase");
  
  // AttributeSet 초기화
  AttributeSet->InitHealth(200);
}
```
{: file="MyCharacterBase.cpp"}

### 블루프린트 및 데이터 테이블

1. 액터 블루프린트에서 AttributeSet 클래스 및 데이터 테이블 설정
    - AbilitySystemComponent > 디테일 > Attribute Test > Default Starting Data
    - 데이터 테이블은 AttributeMetaData 로 생성
      - 기본적으로 Base Value 만 사용됩니다. (UAttributeSet::InitFromMetaDataTable 참고)
2. 액터의 PreInitializeComponent ~ Begin Play 이벤트 중 원하는 곳에서 AttributeSet 참조
    - AbilitySystemComponent 의 OnRegister 이벤트에서 GetOrCreateAttributeSubobject 가 호출되기 때문입니다.
    - 이 경우 AttributeSet 에 const 키워드가 추가됩니다. 

*예시*
```c++
private:
  UPROPERTY(VisibleDefaultsOnly, BlueprintReadOnly, Category = "Abilities", meta = (AllowPrivateAccess = true))
  UAbilitySystemComponent* AbilitySystem;

  UPROPERTY(BlueprintReadOnly, Category = "Abilities", meta = (AllowPrivateAccess = true))
  const UMyAttributeSet* AttributeSet;
```
{: file="MyCharacterBase.h"}

```c++
AMyCharacterBase::AMyCharacterBase()
{
  // AbilitySystem 컴포넌트 부착
  AbilitySystem = CreateDefaultSubobject<UAbilitySystemComponent>("AbilitySystem");
}

AMyCharacterBase::BeginPlay()
{
  // AttributeSet 참조
  AttributeSet = AbilitySystem->GetSet<UMyAttributeSet>();
}
```
{: file="MyCharacterBase.cpp"}

### 커스텀

앞서 이야기했듯이 AbilitySystemComponent 의 Default Starting Data 는 Base Value 만 사용합니다. 
그러나 `UAttributeSet::InitFromMetaDataTable` 는 오버라이드가 가능하기 때문에 `FAttributeMetaData` 의 MinValue, MaxValue 역시 사용할 수 있습니다.

하지만 최소, 최대 값은 초기화 단계뿐 아니라 모든 경우에서 Clamp 하는 것이 일반적이기 때문에 저는 굳이 이 방법을 사용하지는 않을 것 같습니다.

## 메모

- 하나의 프로젝트에서 AttributeSet 을 여러 개 사용할 수는 있지만 하나의 클래스에 여러 AttributeSet 을 동시에 사용하는 것은 적절하지 않습니다.
    - 서브 클래스의 경우 여러 개를 사용하지 말라는 이야기 같습니다. 제가 살펴봤을 때 API 자체는 여러 AttributeSet 을 다룰 수 있는 것으로 보입니다.
    - UAbilitySystemComponent::GetAttributeSubobject 참고
- 총기 보유 탄약과 같이 아이템에 저장되는 프로퍼티는 Attribute 대신 일반 변수를 사용하는 것을 권장합니다.
- Base Value 와 Current Value 의 차이점은 용도입니다.
  - Base Value: 데미지처럼 영구적으로 값을 변경하는 경우
  - Current Value: 버프처럼 일시적으로 값을 변경하는 경우
- 콘솔 명령어
    - showdebug abilitysystem
    - AbilitySystem.DebugAttribute (Base, Current)
- NetUpdateFrequency = 100 추천

## 참고

- [게임플레이 어트리뷰트 및 게임플레이 이펙트 / 언리얼 엔진 5.2 문서](https://docs.unrealengine.com/5.2/ko/gameplay-attributes-and-gameplay-effects-for-the-gameplay-ability-system-in-unreal-engine/)
- [How to create Attribute Sets using Unreal Gameplay Ability System / 에픽 게임즈 커뮤니티](https://dev.epicgames.com/community/learning/tutorials/zrEb/unreal-engine-how-to-create-attribute-sets-using-unreal-gameplay-ability-system)
- [게임플레이 어트리뷰트 및 어트리뷰트 세트 / 언리얼 엔진 5.3 문서](https://docs.unrealengine.com/5.3/ko/gameplay-attributes-and-attribute-sets-for-the-gameplay-ability-system-in-unreal-engine/)
- [GASDocumentation / GitHub](https://github.com/tranek/GASDocumentation?tab=readme-ov-file#concepts-as)
