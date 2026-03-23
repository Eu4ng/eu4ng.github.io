---
layout: post
title: FObjectInitializer 로 DefaultSubobject 교체하는 방법
date: 2024-02-06 00:00 +0900
author: Eu4ng
categories: [Unreal Engine]
tags: [unreal-engine, ue5, objectInitializer]
---

## 작성 계기

> 정말 간단한 내용이었지만 착각으로 인해 엄청난 삽질을 하여 나중에 다시 실수하는 일을 방지하고자 기록으로 남깁니다.
{: .prompt-info}

## FObjectInitializer::SetDefaultSubobjectClass
> Sets the class to use for a subobject defined in a base class, the class must be a subclass of the class used by the base class.

부모 클래스의 생성자에서 설정된 DefaultSubobject 의 클래스를 자식 클래스의 생성자에서 변경해주는 함수입니다.
단, 변경하고자 하는 클래스는 기존에 설정된 클래스의 서브 클래스여야 합니다.

위 내용에서 제가 착각한 부분은 바로 서브 클래스의 대상이었습니다.

저는 DefaultSubobject 를 저장할 변수의 클래스를 기준으로 아무 서브 클래스를 사용하여 덮어쓰기가 가능하다고 생각했는데 `CreateDefaultSubObject<T>` 에서 `T` 를 기준으로 하는 것이었습니다.

예제로 살펴보겠습니다.

### 올바른 예

```c++
// Character.h
TObjectPtr<UCharacterMovementComponent> CharacterMovement;
...
ACharacter(const FObjectInitializer& ObjectInitializer = FObjectInitializer::Get());

// Character.cpp
ACharacter::ACharacter(const FObjectInitializer& ObjectInitializer)
: Super(ObjectInitializer)
{
  ...
  CharacterMovement = CreateDefaultSubobject<UCharacterMovementComponent>(ACharacter::CharacterMovementComponentName);
  ...
}
```

```c++
// TestCharacter.h
ATestCharacter(const FObjectInitializer& ObjectInitializer = FObjectInitializer::Get());

// TestCharacter.cpp
// UTestCharacterMovementComponent : UCharacterMovementComponent
ATestCharacter::ATestCharacter(const FObjectInitializer& ObjectInitializer)
: Super(ObjectInitializer.SetDefaultSubobjectClass<UTestCharacterMovementComponent>(ACharacter::CharacterMovementComponentName))
{
}
```

이 경우 `UTestCharacterMovementComponent` 는 `UCharacterMovementComponent` 의 서브 클래스이므로 확인해보시면 `UTestCharacterMovementComponent` 로 교체된 것을 보실 수 있습니다.

### 잘못된 예

```c++
// Parent.h
TObjectPtr<UPrimitiveComponent> Primitive;
...
AParent(const FObjectInitializer& ObjectInitializer = FObjectInitializer::Get());

// Parent.cpp
AParent::AParent(const FObjectInitializer& ObjectInitializer)
: Super(ObjectInitializer)
{
  Primitive = CreateDefaultSubobject<USphereComponent>(TEXT("Primitive"));
}
```

```c++
// Child.h
AChild(const FObjectInitializer& ObjectInitializer = FObjectInitializer::Get());

// Child.cpp
AChild::AChild(const FObjectInitializer& ObjectInitializer)
: Super(ObjectInitializer.SetDefaultSubobjectClass<UBoxComponent>(TEXT("Primitive"))
{
}
```

이 경우 `USphereComponent`, `UBoxComponent` 는 `UPrimitiveComponent` 의 서브 클래스이므로 이 역시 교체가 될 것이라 기대하였습니다. 
Primitive 컴포넌트가 Parent 에서는 Sphere, Child 에서는 Box 로 설정되어 있을 것이라고 말이죠... 그러나 결과는 Parent, Child 둘 다 Sphere 로 설정되어 있었습니다.

Primitive 변수 타입을 `UPrimitiveComponent` 설정하였지만 Parent 에서 생성을 `USphereComponent` 로 했기 때문에 서브 클래스를 따지는 기준은 `UPrimitiveComponent` 가 아니라
`USphereComponent` 가 되는 것이고 `UBoxComponent` 는 `USphereComponent` 의 서브 클래스가 아니기 때문에 무시된 것이었습니다...

처음엔 아무 생각 없이 `SetDefaultSubobjectClass` 는 부모 클래스에서 생성된 서브 오브젝트를 제거하고 자식 클래스에서 설정된 클래스 새로운 서브 오브젝트를 생성할 것이라고 믿었습니다.

그런데 다시 생각해보면 그건 어마어마한 낭비일뿐더러 부모 클래스에서 설정한 값들이 날아가기 때문에 재생성이 아니라 생성된 서브 오브젝트를 확장하는 방식으로 동작하는 것이 맞는 것 같습니다.

나중에 기회가 되면 좀 더 깊게 들어가 실제 관련 코드까지 살펴보면 좋을 것 같습니다.

> FObjectInitializer 에는 DoNotCreateDefaultSubobject 처럼 다른 유용한 기능들도 포함되어 있습니다만, 글이 길어졌으므로 나중에 따로 다루도록 하겠습니다.
{: .prompt-tip}

## 참고

- [UE4Cookery CPP001: Injecting subobjects with FObjectInitializer](https://www.gamedeveloper.com/programming/ue4cookery-cpp001-injecting-subobjects-with-fobjectinitializer)
