/*****************************************************************************
 *
 *  PROJECT:     Multi Theft Auto
 *  LICENSE:     See LICENSE in the top level directory
 *  FILE:        game_sa/CPedSA.cpp
 *  PURPOSE:     Ped entity
 *
 *  Multi Theft Auto is available from https://www.multitheftauto.com/
 *
 *****************************************************************************/

#include "StdInc.h"
#include "CGameSA.h"
#include "CEventDamageSA.h"
#include "CPedSA.h"
#include "CPedModelInfoSA.h"
#include "CPedDamageResponseCalculatorSA.h"
#include "CPlayerInfoSA.h"
#include "CStatsSA.h"
#include "TaskAttackSA.h"
#include "CTaskManagerSA.h"
#include "CTaskManagementSystemSA.h"
#include "CTasksSA.h"
#include "CProjectileInfoSA.h"
#include "CWeaponStatManagerSA.h"
#include "CFireManagerSA.h"
#include "gamesa_renderware.h"
#include <core/CCoreInterface.h>
#include <multiplayer/CMultiplayer.h>

extern CCoreInterface* g_pCore;
extern CGameSA*        pGame;

static bool g_onlyUpdateRotations = false;

CPedSA::~CPedSA()
{
    // Make sure this ped is not refed in the flame shot info array
    auto* info = reinterpret_cast<CFlameShotInfo*>(ARRAY_CFlameShotInfo);
    for (std::size_t i = 0; i < MAX_FLAME_SHOT_INFOS; i++, info++)
    {
        if (info->pInstigator != m_pInterface)
            continue;

        info->pInstigator = nullptr;
        info->ucFlag1 = 0;
    }
}

// used to init weapons at the moment, called by CPlayerPedSA when its been constructed
// can't use constructor as thats called before the interface pointer has been set the the aforementioned constructor

// TODO Reimplement weapons and PedIK for SA
void CPedSA::Init()
{
    CPedSAInterface* pedInterface = GetPedInterface();

    m_pedIntelligence = std::make_unique<CPedIntelligenceSA>(pedInterface->pPedIntelligence, this);

    m_pedSound = std::make_unique<CPedSoundSA>(&pedInterface->pedSound);
    m_defaultVoiceType = m_pedSound->GetVoiceTypeID();
    m_defaultVoiceID = m_pedSound->GetVoiceID();

    for (std::size_t i = 0; i < WEAPONSLOT_MAX; i++)
        m_weapons[i] = std::make_unique<CWeaponSA>(&(pedInterface->Weapons[i]), this, static_cast<eWeaponSlot>(i));

#ifdef PedIK_SA
    this->m_pPedIK = new Cm_pPedIKSA(&(pedInterface->m_pPedIK));
#endif
}

void CPedSA::SetModelIndex(std::uint32_t modelIndex)
{
    // char __thiscall CPed::SetModelIndex(void *this, int a2)
    ((char(__thiscall*)(CEntitySAInterface*, int))FUNC_SetModelIndex)(m_pInterface, modelIndex);

    // Also set the voice gender
    CModelInfo* mi = pGame->GetModelInfo(modelIndex);
    if (!mi)
        return;

    CPedModelInfoSAInterface* modelInfo = static_cast<CPedModelInfoSAInterface*>(mi->GetInterface());
    if (!modelInfo)
        return;

    std::uint32_t type = modelInfo->pedType;
    GetPedInterface()->pedSound.m_bIsFemale = type == 5 || type == 22;
}

SPedCreatedByState CPedSA::GetCreatedByState() const
{
    const auto* pedInterface = GetPedInterface();
    const auto* intelligence = pedInterface->pPedIntelligence;
    return {
        static_cast<ePedCreatedBy>(pedInterface->createdBy),
        intelligence->hearingRange,
        intelligence->seeingRange,
        intelligence->numPedsToScan,
        intelligence->decisionMakerRadius,
    };
}

void CPedSA::SetCreatedBy(ePedCreatedBy createdBy)
{
    // Use GTA's native setter because CREATE_CHAR also resets the decision
    // maker and applies mission-specific perception ranges.
    ((void(__thiscall*)(CPedSAInterface*, ePedCreatedBy))FUNC_SetCharCreatedBy)(GetPedInterface(), createdBy);
}

void CPedSA::RestoreCreatedByState(const SPedCreatedByState& state)
{
    SetCreatedBy(state.createdBy);

    // The native setter does not undo mission perception/scanner changes when
    // returning to PED_GAME, so restore the exact pre-claim AI state.
    auto* intelligence = GetPedInterface()->pPedIntelligence;
    intelligence->hearingRange = state.hearingRange;
    intelligence->seeingRange = state.seeingRange;
    intelligence->numPedsToScan = state.numPedsToScan;
    intelligence->decisionMakerRadius = state.decisionMakerRadius;
}

bool CPedSA::AddNativeGunAimedAtEvent(CPed* aimingPed)
{
    constexpr std::uintptr_t FUNC_CEventGunAimedAt_Constructor = 0x4B0700;
    constexpr std::uintptr_t FUNC_CEventGunAimedAt_Destructor = 0x4B07B0;
    constexpr std::uintptr_t FUNC_CEventGroup_Add = 0x4AB420;
    constexpr std::size_t    EVENT_GUN_AIMED_AT_SIZE = 0x18;

    auto* targetInterface = GetPedInterface();
    auto* sourceInterface = aimingPed ? aimingPed->GetPedInterface() : nullptr;
    if (!targetInterface || !targetInterface->pPedIntelligence || !sourceInterface || targetInterface == sourceInterface)
        return false;

    // The server already synchronizes player targeting. Recreate only the
    // missing owner-side event and let GTA clone, validate and select its
    // stock response exactly as it does for a locally targeted ambient ped.
    alignas(void*) std::byte eventStorage[EVENT_GUN_AIMED_AT_SIZE]{};
    using EventConstructor = void*(__thiscall*)(void*, CPedSAInterface*);
    using EventDestructor = void(__thiscall*)(void*);
    using AddEvent = void*(__thiscall*)(void*, void*, bool);

    reinterpret_cast<EventConstructor>(FUNC_CEventGunAimedAt_Constructor)(eventStorage, sourceInterface);
    void* const accepted = reinterpret_cast<AddEvent>(FUNC_CEventGroup_Add)(targetInterface->pPedIntelligence->eventGroup, eventStorage, false);
    reinterpret_cast<EventDestructor>(FUNC_CEventGunAimedAt_Destructor)(eventStorage);
    return accepted != nullptr;
}

int CPedSA::GetNativeCurrentEventType() const
{
    constexpr std::uintptr_t FUNC_CEventHandler_GetCurrentEventType = 0x4B8CC0;
    const auto*              pedInterface = GetPedInterface();
    const auto*              intelligence = pedInterface ? pedInterface->pPedIntelligence : nullptr;
    if (!intelligence)
        return -1;

    using GetCurrentEventType = int(__thiscall*)(const void*);
    return reinterpret_cast<GetCurrentEventType>(FUNC_CEventHandler_GetCurrentEventType)(intelligence->eventHandler);
}

namespace
{
    // This is a semantic snapshot, never a native pointer/memory snapshot. The
    // layouts/constructors below were checked against compact 1.0. Replaying event
    // 7 would redraw flee versus reclaim; event 17 rejects actors already on foot.
    template <typename T>
    T VehicleTaskField(const unsigned char* task, unsigned offset)
    {
        return *reinterpret_cast<const T*>(task + offset);
    }

    bool CaptureVehicleTask(CTask* task, std::vector<SPedNativeVehicleTask>& result, unsigned depth)
    {
        if (!task)
            return true;
        if (depth >= 16 || result.size() >= 8)
            return false;
        const int   type = task->GetTaskType();
        const auto* raw = reinterpret_cast<const unsigned char*>(task->GetInterface());
        if (!raw)
            return false;
        if (type == TASK_COMPLEX_SEQUENCE)
        {
            const int index = VehicleTaskField<int>(raw, 0xC);
            if (index < 0 || index >= 8)
                return false;
            for (int i = index; i < 8; ++i)
            {
                auto*  nativeTask = VehicleTaskField<CTaskSAInterface*>(raw, 0x10 + i * 4);
                CTask* next = i == index && task->GetSubTask() ? task->GetSubTask() : pGame->GetTaskManagementSystem()->GetTask(nativeTask);
                if (!CaptureVehicleTask(next, result, depth + 1))
                    return false;
            }
            return true;
        }
        // Cosmetic preambles may finish locally; they must not restart a fight or
        // obscure the remaining steal action after a change of synchronizer.
        if (type == TASK_SIMPLE_PAUSE || type == TASK_SIMPLE_ACHIEVE_HEADING || type == TASK_SIMPLE_SHAKE_FIST || type == TASK_NONE)
            return true;
        if ((type == TASK_COMPLEX_LEAVE_CAR_AND_FLEE || type == TASK_COMPLEX_SCREAM_IN_CAR_THEN_LEAVE) && task->GetSubTask())
        {
            const int childType = task->GetSubTask()->GetTaskType();
            if (childType == TASK_COMPLEX_SMART_FLEE_POINT || childType == TASK_COMPLEX_LEAVE_CAR_AND_FLEE)
                return CaptureVehicleTask(task->GetSubTask(), result, depth + 1);
        }
        SPedNativeVehicleTask d{};
        d.type = type;
        unsigned   pedOffset = 0, vehicleOffset = 0;
        const auto integer = [&](unsigned offset) { return static_cast<double>(VehicleTaskField<int>(raw, offset)); };
        const auto number = [&](unsigned offset) { return static_cast<double>(VehicleTaskField<float>(raw, offset)); };
        switch (type)
        {
            case TASK_COMPLEX_SMART_FLEE_ENTITY:
                pedOffset = 0xC;
                d.values = {integer(0x1C), number(0x20), double(raw[0x24] != 0), integer(0x28), number(0x2C)};
                break;
            case TASK_COMPLEX_SMART_FLEE_POINT:
                d.values = {number(0x18), number(0x1C), number(0x20), double(raw[0x24] != 0), integer(0x28), number(0x2C)};
                break;
            case TASK_COMPLEX_KILL_PED_ON_FOOT:
                pedOffset = 0x10;
                d.values = {integer(0x28), integer(0x14), integer(0x18), integer(0x1C), double(raw[0x20])};
                break;
            case TASK_COMPLEX_STEAL_CAR:
                vehicleOffset = 0xC;
                break;
            case TASK_COMPLEX_ENTER_CAR_AS_DRIVER:
                vehicleOffset = 0xC;
                d.values[0] = integer(0x24);
                break;
            case TASK_COMPLEX_ENTER_CAR_AS_PASSENGER:
                vehicleOffset = 0xC;
                d.values = {integer(0x1C), double((raw[0x10] & 8) != 0), integer(0x24)};
                break;
            case TASK_COMPLEX_DRAG_PED_FROM_CAR:
                pedOffset = 0x50;
                d.values[0] = integer(0x20);
                break;
            case TASK_COMPLEX_LEAVE_CAR:
                vehicleOffset = 0xC;
                d.values = {integer(0x10), integer(0x14), double(raw[0x18] != 0), double(raw[0x19] != 0)};
                break;
            case TASK_COMPLEX_DESTROY_CAR:
                vehicleOffset = 0x10;
                d.values = {integer(0x14), integer(0x18), integer(0x1C)};
                break;
            case TASK_COMPLEX_LEAVE_CAR_AND_FLEE:
                vehicleOffset = 0xC;
                d.values = {number(0x14), number(0x18), number(0x1C), integer(0x10), integer(0x20), double(raw[0x24] != 0)};
                break;
            case TASK_COMPLEX_LEAVE_CAR_AND_WANDER:
                vehicleOffset = 0xC;
                d.values = {integer(0x10), integer(0x14), double(raw[0x18] != 0)};
                break;
            case TASK_COMPLEX_SCREAM_IN_CAR_THEN_LEAVE:
                vehicleOffset = 0xC;
                d.values[0] = integer(0x10);
                break;
            default:
                // In particular do not turn an unknown active response into a
                // successful empty snapshot, which would silently forget intent.
                return false;
        }
        if (pedOffset)
        {
            auto* entry = pGame->GetPools()->GetPed(VehicleTaskField<DWORD*>(raw, pedOffset));
            if (!entry)
                return false;
            d.target = entry->pEntity;
        }
        if (vehicleOffset)
        {
            auto* entry = pGame->GetPools()->GetVehicle(VehicleTaskField<DWORD*>(raw, vehicleOffset));
            if (!entry)
                return false;
            d.vehicle = entry->pEntity;
        }
        result.push_back(d);
        return true;
    }

    template <typename... Args>
    void* ConstructVehicleTask(std::uintptr_t address, unsigned size, Args... args)
    {
        void* storage = reinterpret_cast<void*(__cdecl*)(unsigned)>(FUNC_CTask__Operator_New)(size);
        if (!storage)
            return nullptr;
        return reinterpret_cast<void*(__thiscall*)(void*, Args...)>(address)(storage, args...);
    }

    void DeleteVehicleTask(void* task)
    {
        if (task)
            reinterpret_cast<void(__thiscall*)(void*, unsigned)>(*reinterpret_cast<DWORD**>(task)[0])(task, 1);
    }

    void* RestoreVehicleTask(const SPedNativeVehicleTask& d)
    {
        const auto& v = d.values;
        // Every scalar is transported as a number. Bound before all integer casts
        // and native calls, even for locally invoked Lua functions.
        for (double value : v)
            if (!std::isfinite(value) || value < -1000000 || value > 100000000)
                return nullptr;
        void*         target = d.target ? d.target->GetInterface() : nullptr;
        void*         vehicle = d.vehicle ? d.vehicle->GetInterface() : nullptr;
        const CVector point(static_cast<float>(v[0]), static_cast<float>(v[1]), static_cast<float>(v[2]));
        switch (d.type)
        {
            case TASK_COMPLEX_SMART_FLEE_ENTITY:
                if (target && v[0] >= -1 && v[1] > 0 && v[3] >= 0 && v[4] >= 0)
                    return ConstructVehicleTask(0x65C430, 0x40, target, v[2] != 0, float(v[1]), int(v[0]), int(v[3]), float(v[4]));
                break;
            case TASK_COMPLEX_SMART_FLEE_POINT:
                if (v[4] >= -1 && v[5] > 0)
                    return ConstructVehicleTask(0x65BD20, 0x44, &point, v[3] != 0, float(v[5]), int(v[4]));
                break;
            case TASK_COMPLEX_KILL_PED_ON_FOOT:
                if (target && v[4] >= 0 && v[4] <= 255)
                    return ConstructVehicleTask(0x620E30, 0x38, target, int(v[0]), int(v[1]), int(v[2]), int(v[3]), static_cast<unsigned char>(v[4]));
                break;
            case TASK_COMPLEX_STEAL_CAR:
                if (vehicle)
                    return ConstructVehicleTask(0x63B7D0, 0x20, vehicle);
                break;
            case TASK_COMPLEX_ENTER_CAR_AS_DRIVER:
            case TASK_COMPLEX_ENTER_CAR_AS_PASSENGER:
                if (vehicle)
                {
                    const double movement = d.type == TASK_COMPLEX_ENTER_CAR_AS_DRIVER ? v[0] : v[2];
                    if (movement < 0 || movement > 7 || (d.type == TASK_COMPLEX_ENTER_CAR_AS_PASSENGER && (v[0] < -1 || v[0] > 7)))
                        break;
                    void* task = d.type == TASK_COMPLEX_ENTER_CAR_AS_DRIVER ? ConstructVehicleTask(0x6402F0, 0x50, vehicle)
                                                                            : ConstructVehicleTask(0x640340, 0x50, vehicle, int(v[0]), v[1] != 0);
                    if (task)
                        *reinterpret_cast<int*>(static_cast<unsigned char*>(task) + 0x24) = int(movement);
                    return task;
                }
                break;
            case TASK_COMPLEX_DRAG_PED_FROM_CAR:
                if (target && v[0] >= 0)
                    return ConstructVehicleTask(0x640430, 0x54, target, int(v[0]));
                break;
            case TASK_COMPLEX_LEAVE_CAR:
                if (vehicle && v[0] >= 0 && v[0] <= 255 && v[1] >= 0)
                    return ConstructVehicleTask(0x63B8C0, 0x34, vehicle, int(v[0]), int(v[1]), v[2] != 0, v[3] != 0);
                break;
            case TASK_COMPLEX_DESTROY_CAR:
                if (vehicle)
                    return ConstructVehicleTask(0x621C00, 0x20, vehicle, int(v[0]), int(v[1]), int(v[2]));
                break;
            case TASK_COMPLEX_LEAVE_CAR_AND_FLEE:
                if (vehicle && v[3] >= 0 && v[3] <= 255 && v[4] >= 0)
                    return ConstructVehicleTask(0x63BF90, 0x28, vehicle, &point, int(v[3]), int(v[4]), v[5] != 0);
                break;
            case TASK_COMPLEX_LEAVE_CAR_AND_WANDER:
                if (vehicle && v[0] >= 0 && v[0] <= 255 && v[1] >= 0)
                    return ConstructVehicleTask(0x63BDD0, 0x1C, vehicle, int(v[0]), int(v[1]), v[2] != 0);
                break;
            case TASK_COMPLEX_SCREAM_IN_CAR_THEN_LEAVE:
                if (vehicle && v[0] >= 0 && v[0] <= 255)
                    return ConstructVehicleTask(0x63C240, 0x20, vehicle, int(v[0]));
                break;
        }
        return nullptr;
    }
}

bool CPedSA::GetNativeVehicleResponse(std::vector<SPedNativeVehicleTask>& tasks) const
{
    tasks.clear();
    auto* intelligence = GetPedIntelligence();
    auto* manager = intelligence ? intelligence->GetTaskManager() : nullptr;
    if (!manager)
        return false;
    // A temporary avoidance/hit animation overlays the persistent reaction.
    // Preserve the durable objective instead of replacing it with that overlay.
    CTask* task = manager->GetTask(TASK_PRIORITY_EVENT_RESPONSE_NONTEMP);
    if (!task)
        task = manager->GetTask(TASK_PRIORITY_EVENT_RESPONSE_TEMP);
    if (!CaptureVehicleTask(task, tasks, 0))
    {
        tasks.clear();
        return false;
    }
    return true;
}

bool CPedSA::RestoreNativeVehicleResponse(const std::vector<SPedNativeVehicleTask>& tasks)
{
    auto* intelligence = GetPedIntelligence();
    auto* manager = intelligence ? static_cast<CTaskManagerSA*>(intelligence->GetTaskManager()) : nullptr;
    if (!manager || tasks.empty() || tasks.size() > 8)
        return false;
    // A freshly selected native response takes precedence over a network
    // snapshot. Never abort a new collision/damage response to replay history.
    if (manager->GetTask(TASK_PRIORITY_EVENT_RESPONSE_TEMP) || manager->GetTask(TASK_PRIORITY_EVENT_RESPONSE_NONTEMP))
        return false;
    void* sequence = ConstructVehicleTask(0x632BD0, 0x40);
    if (!sequence)
        return false;
    for (const auto& description : tasks)
    {
        // A last snapshot can predate an exit by one network tick. Scream's
        // first subtask has no on-foot guard and would install CAR_DRIVE.
        if (description.type == TASK_COMPLEX_SCREAM_IN_CAR_THEN_LEAVE && (!description.vehicle || GetVehicle() != description.vehicle))
        {
            DeleteVehicleTask(sequence);
            return false;
        }
        void* task = RestoreVehicleTask(description);
        if (!task)
        {
            DeleteVehicleTask(sequence);
            return false;
        }
        if (!reinterpret_cast<bool(__thiscall*)(void*, void*)>(0x632D10)(sequence, task))
        {
            // AddTask owns (and deletes) a rejected child.
            DeleteVehicleTask(sequence);
            return false;
        }
    }
    reinterpret_cast<void(__thiscall*)(void*, void*, int, bool)>(FUNC_SetTask)(manager->GetInterface(), sequence, TASK_PRIORITY_EVENT_RESPONSE_NONTEMP, false);
    return true;
}

bool CPedSA::AddNativeDamageResponseEvent(CPed* attackingPed, eWeaponType weaponType, ePedPieceTypes hitZone)
{
    constexpr std::uintptr_t FUNC_CEventGroup_Add = 0x4AB420;

    auto* targetInterface = GetPedInterface();
    auto* sourceInterface = attackingPed ? attackingPed->GetPedInterface() : nullptr;
    if (!targetInterface || !targetInterface->pPedIntelligence || !sourceInterface || targetInterface == sourceInterface)
        return false;

    // Group combat can already have installed a fight task against this exact
    // attacker by the time the cross-owner damage fallback arrives. Feeding a
    // second personality event into that in-flight native response makes
    // CEventHandler urgently abort the fight-control tree. GTA's compact task
    // pipeline is not safe under that artificial duplicate. Preserve
    // retargeting and first-hit reactions, but suppress the redundant event
    // once the same fight target is already authoritative on this managed
    // ambient group member.
    if (IsNativeAmbientGroupActive())
    {
        auto* const taskManager = GetPedIntelligence()->GetTaskManager();
        auto* const attackTask = taskManager ? taskManager->GetTaskSecondary(TASK_SECONDARY_ATTACK) : nullptr;
        if (attackTask && attackTask->GetTaskType() == TASK_SIMPLE_FIGHT)
        {
            const auto* const fightTask = reinterpret_cast<const CTaskSimpleFightSAInterface*>(attackTask->GetInterface());
            if (fightTask && reinterpret_cast<const void*>(fightTask->m_pTargetEntity) == sourceInterface)
                return false;
        }
    }

    CEventDamageSA event(attackingPed, pGame->GetSystemTime(), weaponType, hitZone, 0, false, targetInterface->pVehicle != nullptr);
    auto*          eventInterface = event.GetInterface();

    // Cross-owner damage has already passed through MTA's authoritative health
    // pipeline. Keep the input event eligible for CEventGroup's stock damage
    // admission rule, including when the decision maker chooses TASK_NONE.
    // Once GTA has cloned it, mark only the stored event as personality-only so
    // CEventHandler skips ProcessDamage without losing the native AI decision.
    eventInterface->damageResponseData.fDamageHealth = 0.0f;
    eventInterface->damageResponseData.fDamageArmor = 0.0f;
    eventInterface->damageResponseData.bHealthZero = false;
    eventInterface->damageResponseData.bForceDeath = false;
    eventInterface->damageResponseData.bDamageCalculated = true;
    eventInterface->damageResponseData.bCheckIfAffectsPed = false;

    // MTA's bullet-sync admission hook must distinguish this behavior-only
    // replay from a real firearm hit. The marker is event- and victim-scoped,
    // follows GTA's synchronous clones, and is erased by the damage-event
    // destructor hook.
    CMultiplayer* const multiplayer = g_pCore ? g_pCore->GetMultiplayer() : nullptr;
    if (!multiplayer)
        return false;
    multiplayer->RegisterNativeBehaviorOnlyDamageEvent(eventInterface, targetInterface);

    using AddEvent = void*(__thiscall*)(void*, void*, bool);
    auto* const accepted = reinterpret_cast<CEventDamageSAInterface*>(
        reinterpret_cast<AddEvent>(FUNC_CEventGroup_Add)(targetInterface->pPedIntelligence->eventGroup, eventInterface, false));
    if (!accepted)
        return false;

    accepted->bAddToEventGroup = false;
    return true;
}

bool CPedSA::AddNativeDamageEvent(CPed* attackingPed, eWeaponType weaponType, ePedPieceTypes hitZone, int damageFactor, unsigned char direction)
{
    constexpr std::uintptr_t FUNC_CEventGroup_Add = 0x4AB420;

    auto* targetInterface = GetPedInterface();
    auto* sourceInterface = attackingPed ? attackingPed->GetPedInterface() : nullptr;
    if (!targetInterface || !targetInterface->pPedIntelligence || !sourceInterface || targetInterface == sourceInterface)
        return false;

    if (damageFactor <= 0 || damageFactor > 10000 || direction > 3)
        return false;

    const float previousHealth = GetHealth();
    const float previousArmor = GetArmor();

    // CWeapon::GenerateDamageEvent computes CPedDamageResponse before the
    // event enters CEventGroup. Repeat that ordering on the authoritative
    // victim: the transported value is the exact pre-calculator melee factor,
    // while health, armour, ped stats and death rules remain local GTA state.
    CEventDamageSA event(attackingPed, pGame->GetSystemTime(), weaponType, hitZone, direction, false, targetInterface->pVehicle != nullptr);
    if (!event.AffectsPed(this))
        return false;

    CPedDamageResponseCalculatorSA damageCalculator(attackingPed, static_cast<float>(damageFactor), weaponType, hitZone, false);
    damageCalculator.ComputeDamageResponse(this, event.GetDamageResponse(), true);

    using AddEvent = void*(__thiscall*)(void*, void*, bool);
    const bool accepted =
        reinterpret_cast<AddEvent>(FUNC_CEventGroup_Add)(targetInterface->pPedIntelligence->eventGroup, event.GetInterface(), false) != nullptr;

    // MTA deliberately rejects GTA's own lethal response after its local
    // wasted pipeline has accepted the health transition. Report that replay
    // as successful too; cancelled or locked damage restores both values.
    return accepted || GetHealth() != previousHealth || GetArmor() != previousArmor;
}

void CPedSA::DisableSpeechForScript(bool stopCurrentSpeech)
{
    ((void(__thiscall*)(CPedSAInterface*, bool))FUNC_DisableSpeechForScript)(GetPedInterface(), stopCurrentSpeech);
}

void CPedSA::EnableSpeechForScript()
{
    ((void(__thiscall*)(CPedSAInterface*))FUNC_EnableSpeechForScript)(GetPedInterface());
}

bool CPedSA::AddProjectile(eWeaponType weaponType, CVector origin, float force, CVector* target, CEntity* targetEntity)
{
    CProjectileInfo* projectileInfo = pGame->GetProjectileInfo();
    if (!projectileInfo)
        return false;

    return projectileInfo->AddProjectile(static_cast<CEntitySA*>(this), weaponType, origin, force, const_cast<CVector*>(target),
                                         const_cast<CEntity*>(targetEntity));
}

void CPedSA::DetachPedFromEntity()
{
    // void __thiscall CPed::DettachPedFromEntity(CPed *this)
    ((void(__thiscall*)(CEntitySAInterface*))FUNC_DetachPedFromEntity)(m_pInterface);
}

bool CPedSA::InternalAttachEntityToEntity(DWORD entityInteface, const CVector* position, const CVector* rotation)
{
    // sDirection and fRotationLimit only apply to first-person shooting (bChangeCamera)
    CPedSAInterface* pedInterface = GetPedInterface();
    int              pedType = pedInterface->bPedType;

    // Hack the CPed type(?) to non-player so the camera doesn't get changed
    pedInterface->bPedType = 2;

    // CEntity *__thiscall CPed::AttachPedToEntity(CPed *this, CEntity *a2, float arg4, float a4, float a5, __int16 a6, int a7, eWeaponType a3)
    ((CEntitySAInterface * (__thiscall*)(CEntitySAInterface*, CEntitySAInterface*, float, float, float, std::uint16_t, int, eWeaponType))
         FUNC_AttachPedToEntity)(m_pInterface, reinterpret_cast<CEntitySAInterface*>(entityInteface), position->fX, position->fY, position->fZ, 0, 0,
                                 WEAPONTYPE_UNARMED);

    // Hack the CPed type(?) to whatever it was set to
    pedInterface->bPedType = pedType;

    return true;
}

CVehicle* CPedSA::GetVehicle() const
{
    CPedSAInterface* pedInterface = GetPedInterface();
    if (!pedInterface || !pedInterface->pedFlags.bInVehicle)
        return nullptr;

    CVehicleSAInterface* vehicleInterface = pedInterface->pVehicle;
    if (!vehicleInterface)
        return nullptr;

    auto* vehicleClientEntity = pGame->GetPools()->GetVehicle(reinterpret_cast<DWORD*>(vehicleInterface));
    return vehicleClientEntity ? vehicleClientEntity->pEntity : nullptr;
}

void CPedSA::Respawn(CVector* position, bool cameraCut)
{
    if (!cameraCut)
        // CGameLogic::RestorePlayerStuffDuringResurrection
        // Disable calls to CCamera::SetCameraDirectlyBehindForFollowPed_CamOnAString & CCamera::RestoreWithJumpCut
        MemSet((void*)0x4422EA, 0x90, 20);

    // void __cdecl CGameLogic::RestorePlayerStuffDuringResurrection(CPlayerPed *player, __int128 a2)
    ((void(__cdecl*)(CEntitySAInterface*, float, float, float, float))FUNC_RestorePlayerStuffDuringResurrection)(m_pInterface, position->fX, position->fY,
                                                                                                                 position->fZ, 1.0f);

#ifdef SortOutStreamingAndMemory  // Disabled to see if it reduces crashes
    float angle = 10.0f;          // angle for CRenderer::RequestObjectsInDirection

    // void __cdecl CGameLogic::SortOutStreamingAndMemory(CVector *translation, float angle)
    ((void(__cdecl*)(CVector*, float))FUNC_SortOutStreamingAndMemory)(position, angle);
#endif

    // BYTE *__thiscall CPed::RemoveGogglesModel(CPed *this)
    ((std::uint8_t*(__thiscall*)(CEntitySAInterface*))FUNC_RemoveGogglesModel)(m_pInterface);

    if (!cameraCut)
        // Re-enable calls to CCamera::SetCameraDirectlyBehindForFollowPed_CamOnAString & CCamera::RestoreWithJumpCut
        // Restore original bytes
        MemCpy((void*)0x4422EA, "\xB9\x28\xF0\xB6\x00\xE8\x4C\x9A\x0C\x00\xB9\x28\xF0\xB6\x00\xE8\xB2\x97\x0C\x00", 20);
}

CWeapon* CPedSA::GiveWeapon(eWeaponType weaponType, std::uint32_t ammo, eWeaponSkill skill)
{
    // Load weapon model
    if (weaponType != WEAPONTYPE_UNARMED)
    {
        CWeaponInfo* weaponInfo = pGame->GetWeaponInfo(weaponType, skill);
        if (weaponInfo)
        {
            CModelInfo* modelInfo = pGame->GetModelInfo(static_cast<std::uint32_t>(weaponInfo->GetModel()));
            if (modelInfo)
            {
                modelInfo->Request(BLOCKING, "CPedSA::GiveWeapon");
                modelInfo->MakeCustomModel();
            }

            // If the weapon is satchels, load the detonator too
            if (weaponType == WEAPONTYPE_REMOTE_SATCHEL_CHARGE)
                GiveWeapon(WEAPONTYPE_DETONATOR, 1, WEAPONSKILL_STD);
        }
    }

    // eWeaponType __thiscall CPed::GiveWeapon(CPed *this, eWeaponType weaponID, signed int ammo, int a4)
    // Last argument is unused
    eWeaponSlot weaponSlot =
        ((eWeaponSlot(__thiscall*)(CEntitySAInterface*, eWeaponType, std::uint32_t, int))FUNC_GiveWeapon)(m_pInterface, weaponType, ammo, 1);

    return GetWeapon(weaponSlot);
}

CWeapon* CPedSA::GetWeapon(eWeaponType weaponType) const
{
    if (weaponType >= WEAPONTYPE_LAST_WEAPONTYPE)
        return nullptr;

    CWeapon* weapon = GetWeapon(pGame->GetWeaponInfo(weaponType)->GetSlot());
    return (weapon && weapon->GetType() == weaponType) ? weapon : nullptr;
}

CWeapon* CPedSA::GetWeapon(eWeaponSlot weaponSlot) const noexcept
{
    return (weaponSlot >= 0 && weaponSlot < WEAPONSLOT_MAX) ? m_weapons[weaponSlot].get() : nullptr;
}

void CPedSA::ClearWeapons()
{
    // Remove all the weapons
    for (auto& weapon : m_weapons)
    {
        weapon->SetAmmoInClip(0);
        weapon->SetAmmoTotal(0);
        weapon->Remove();
    }
}

void CPedSA::RemoveWeaponModel(std::uint32_t model)
{
    if (auto* pedInterface = GetPedInterface())
        pedInterface->RemoveWeaponModel(model);
}

void CPedSA::ClearWeapon(eWeaponType weaponType)
{
    // BYTE *__thiscall CPed::ClearWeapon(CPed *this, eWeaponType a2)
    ((std::uint8_t*(__thiscall*)(CEntitySAInterface*, eWeaponType))FUNC_ClearWeapon)(m_pInterface, weaponType);
}

void CPedSA::SetIsStanding(bool standing)
{
    // int __thiscall CPed::SetIsStanding(CPed *this, unsigned __int8 a2)
    ((void(__thiscall*)(CEntitySAInterface*, bool))FUNC_SetIsStanding)(m_pInterface, standing);
}

void CPedSA::SetNativeTaskAirbornePresentationState(bool airborne, bool observer)
{
    auto& flags = GetPedInterface()->pedFlags;
    m_bNativeTaskAirbornePresentationObserver = airborne && observer;

    if (airborne)
    {
        // A replicated vertical velocity cannot launch a ped while GTA still
        // considers it planted. These are the same physical flags set by
        // CTaskSimpleJump::Launch; the observer still receives no native task.
        flags.bIsStanding = false;
        flags.bWasStanding = false;
        flags.bIsInTheAir = true;
        flags.bIsLanding = false;
        return;
    }

    // Do not force bIsStanding here. The replicated position may still be a
    // fraction above the floor, so GTA's ordinary collision pass must decide
    // when contact is real instead of leaving the ped suspended.
    flags.bIsInTheAir = false;
    flags.bIsLanding = false;
}

void CPedSA::RestoreLastGoodPhysicsState()
{
    CPhysicalSA::RestoreLastGoodPhysicsState();
    SetCurrentRotation(0);
    SetTargetRotation(0);
}

void CPedSA::SetCurrentWeaponSlot(eWeaponSlot weaponSlot)
{
    if (weaponSlot >= WEAPONSLOT_MAX)
        return;

    eWeaponSlot currentSlot = GetCurrentWeaponSlot();
    if (weaponSlot == currentSlot)
        return;

    CWeapon* weapon = GetWeapon(currentSlot);
    if (weapon)
    {
        CWeaponInfo* weaponInfo = weapon->GetInfo(WEAPONSKILL_STD);
        if (weaponInfo)
            RemoveWeaponModel(weaponInfo->GetModel());
    }

    // set the new weapon slot
    GetPedInterface()->bCurrentWeaponSlot = weaponSlot;

    // is the player the local player?
    CPed* localPlayer = pGame->GetPedContext();

    std::uintptr_t changeWeaponFunc;

    if (localPlayer == this)
    {
        auto* playerInfo = static_cast<CPlayerInfoSA*>(pGame->GetPlayerInfo());
        if (!playerInfo)
            return;

        if (auto* infoInterface = playerInfo->GetInterface())
            infoInterface->PlayerPedData.m_nChosenWeapon = weaponSlot;

        // void __thiscall CPlayerPed::MakeChangesForNewWeapon(CPlayerPed *this, int a3)
        changeWeaponFunc = FUNC_MakeChangesForNewWeapon_Slot;
    }
    else
        // void __thiscall CPed::SetCurrentWeapon(CPed *this, int slot)
        changeWeaponFunc = FUNC_SetCurrentWeapon;

    ((void(__thiscall*)(CEntitySAInterface*, eWeaponSlot))changeWeaponFunc)(m_pInterface, weaponSlot);
}

CVector* CPedSA::GetBonePosition(eBone bone, CVector* position)
{
    ApplySwimAndSlopeRotations();
    CEntitySAInterface* entity = GetInterface();

    // NOTE(botder): A crash used to occur at 0x749B7B in RpClumpForAllAtomics, because the clump pointer might have been null
    // for a broken model.
    if (entity->m_pRwObject)
        // int __thiscall CPed::GetBonePosition(CPed *this, CVector *pPoint, int bone_id, bool bDynamic)
        ((void(__thiscall*)(CEntitySAInterface*, CVector*, eBone, bool))FUNC_GetBonePosition)(entity, position, bone, true);

    // Clamp to a sane range as this function can occasionally return massive values,
    // which causes ProcessLineOfSight to effectively freeze
    if (!IsValidPosition(*position))
        *position = *GetPosition();

    return position;
}

CVector* CPedSA::GetTransformedBonePosition(eBone bone, CVector* position)
{
    ApplySwimAndSlopeRotations();
    CEntitySAInterface* entity = GetInterface();

    // NOTE(botder): A crash used to occur at 0x7C51A8 in RpHAnimIDGetIndex, because the clump pointer might have been null
    // for a broken model.
    // NOTE: A further crash occurs at 0x7C51B9 in RpHAnimIDGetIndex when the clump exists but lacks animation hierarchy data,
    // because GTA:SA's GetTransformedBonePosition doesn't check if GetAnimHierarchyFromSkinClump returns NULL.
    RpClump* clump = reinterpret_cast<RpClump*>(entity->m_pRwObject);
    if (clump && GetAnimHierarchyFromSkinClump(clump))
        // RwV3D *__thiscall CPed::GetTransformedBonePosition(CPed *this, RwV3D *pointsIn, int boneId, char bUpdateBones)
        ((RwV3d * (__thiscall*)(CEntitySAInterface*, CVector*, eBone, bool)) FUNC_GetTransformedBonePosition)(entity, position, bone, true);

    // Clamp to a sane range as this function can occasionally return massive values,
    // which causes ProcessLineOfSight to effectively freeze
    if (!IsValidPosition(*position))
        *position = *GetPosition();

    return position;
}

//
// Apply the extra ped rotations for slope pitch and swimming.
// Achieved by calling the code at the start of CPed::PreRenderAfterTest
//
void CPedSA::ApplySwimAndSlopeRotations()
{
    CPedSAInterface* pedInterface = GetPedInterface();
    if (pedInterface->pedFlags.bCalledPreRender)
        return;

    // void __thiscall CPed::PreRenderAfterTest(CPed *this)
    g_onlyUpdateRotations = true;
    ((void(__thiscall*)(CEntitySAInterface*))FUNC_PreRenderAfterTest)(pedInterface);
    g_onlyUpdateRotations = false;
}

bool CPedSA::IsInWater() const
{
    CTask* task = GetPedIntelligence()->GetTaskManager()->GetTask(TASK_PRIORITY_EVENT_RESPONSE_NONTEMP);
    return (task && task->GetTaskType() == TASK_COMPLEX_IN_WATER);
}

void CPedSA::SetGogglesState(bool isWearingThem)
{
    // void __thiscall CPed::PutOnGoggles(CPed *this)
    // void __thiscall CPed::TakeOffGoggles(CPed *this)
    std::uintptr_t enableGoggleFunc = isWearingThem ? FUNC_PutOnGoggles : FUNC_TakeOffGoggles;
    ((void(__thiscall*)(CEntitySAInterface*))enableGoggleFunc)(m_pInterface);
}

void CPedSA::SetClothesTextureAndModel(const char* texture, const char* model, int textureType)
{
    CPedClothesDesc* clothes = GetPedInterface()->pPlayerData->m_pClothes;
    if (!clothes)
        return;

    // int __fastcall CPedClothesDesc::SetTextureAndModel(DWORD* this, int unknown, char* textureName, char* modelName, eClothesTexturePart texturePart)
    // Second argument is unused in CKeyGen::GetUppercaseKey
    ((void(__fastcall*)(CPedClothesDesc*, int, const char*, const char*, std::uint8_t))FUNC_CPedClothesDesc__SetTextureAndModel)(
        clothes, 0, texture, model, static_cast<std::uint8_t>(textureType));
}

void CPedSA::RebuildPlayer()
{
    // void __cdecl CClothes::RebuildPlayer(CPed *ped, char bIgnoreFatAndMuscle)
    ((void(__cdecl*)(CEntitySAInterface*, bool))FUNC_CClothes__RebuildPlayer)(m_pInterface, false);
}

void CPedSA::SetFightingStyle(eFightingStyle style, std::uint8_t styleExtra)
{
    CPedSAInterface* pedInterface = GetPedInterface();
    if (style == pedInterface->bFightingStyle)
        return;

    pedInterface->bFightingStyle = style;

    if (styleExtra > 0 && styleExtra <= 6)
        pedInterface->bFightingStyleExtra |= (1 << (styleExtra - 1));
}

CEntity* CPedSA::GetContactEntity() const
{
    CEntitySAInterface* contactInterface = GetPedInterface()->pContactEntity;
    if (!contactInterface)
        return nullptr;

    return pGame->GetPools()->GetEntity(reinterpret_cast<DWORD*>(contactInterface));
}

void CPedSA::RemoveBodyPart(std::uint8_t boneID, std::uint8_t direction)
{
    // char __thiscall CPed::RemoveBodyPart(CPed *this, int boneID, int localDir)
    // second argument is unused (direction)
    ((char(__thiscall*)(CEntitySAInterface*, std::uint8_t, std::uint8_t))FUNC_CPed_RemoveBodyPart)(m_pInterface, boneID, 0);
}

void CPedSA::SetFootBlood(std::uint32_t footBlood)
{
    CPedSAInterface* pedInterface = GetPedInterface();
    pedInterface->pedFlags.bDoBloodyFootprints = footBlood > 0;

    // Set the amount of foot blood
    pedInterface->timeWhenDead = footBlood;
}

std::uint32_t CPedSA::GetFootBlood() const
{
    CPedSAInterface* pedInterface = GetPedInterface();

    // If the foot blood flag is activated, return the amount of foot blood
    return pedInterface->pedFlags.bDoBloodyFootprints ? pedInterface->timeWhenDead : 0;
}

bool CPedSA::SetOnFire(bool onFire)
{
    CPedSAInterface* pInterface = GetPedInterface();
    if (onFire == !!pInterface->pFireOnPed)
        return false;

    auto* fireManager = static_cast<CFireManagerSA*>(pGame->GetFireManager());
    if (!fireManager)
        return false;

    if (onFire)
    {
        CFire* fire = fireManager->StartFire(this, nullptr, static_cast<float>(DEFAULT_FIRE_PARTICLE_SIZE));
        if (!fire)
            return false;

        // Start the fire
        fire->SetTarget(this);
        fire->Ignite();
        fire->SetStrength(1.0f);
        // Attach the fire only to the player, do not let it
        // create child fires when moving.
        fire->SetNumGenerationsAllowed(0);
        pInterface->pFireOnPed = fire->GetInterface();
    }
    else
    {
        CFire* fire = fireManager->GetFire(static_cast<CFireSAInterface*>(pInterface->pFireOnPed));
        if (!fire)
            return false;

        fire->Extinguish();
    }

    return true;
}

void CPedSA::GetVoice(std::int16_t* voiceType, std::int16_t* voiceID) const
{
    if (!m_pedSound)
        return;

    if (voiceType)
        *voiceType = m_pedSound->GetVoiceTypeID();

    if (voiceID)
        *voiceID = m_pedSound->GetVoiceID();
}

void CPedSA::GetVoice(const char** voiceType, const char** voice) const
{
    std::int16_t sVoiceType, sVoiceID;
    GetVoice(&sVoiceType, &sVoiceID);

    if (voiceType)
        *voiceType = CPedSoundSA::GetVoiceTypeNameFromID(sVoiceType);
    if (voice)
        *voice = CPedSoundSA::GetVoiceNameFromID(sVoiceType, sVoiceID);
}

void CPedSA::SetVoice(std::int16_t voiceType, std::int16_t voiceID)
{
    if (!m_pedSound)
        return;

    m_pedSound->SetVoiceTypeID(voiceType);
    m_pedSound->SetVoiceID(voiceID);
}

void CPedSA::SetVoice(const char* voiceType, const char* voice)
{
    std::int16_t sVoiceType = CPedSoundSA::GetVoiceTypeIDFromName(voiceType);
    if (sVoiceType < 0)
        return;

    std::int16_t sVoiceID = CPedSoundSA::GetVoiceIDFromName(sVoiceType, voice);
    if (sVoiceID < 0)
        return;

    SetVoice(sVoiceType, sVoiceID);
}

// GetCurrentWeaponStat will only work if the game ped context is currently set to this ped
CWeaponStat* CPedSA::GetCurrentWeaponStat() const
{
    if (pGame->GetPedContext() != this)
    {
        OutputDebugLine("WARNING: GetCurrentWeaponStat ped context mismatch");
        return nullptr;
    }

    CWeapon* weapon = GetWeapon(GetCurrentWeaponSlot());
    if (!weapon)
        return nullptr;

    eWeaponType   weaponType = weapon->GetType();
    std::uint16_t weaponSkillStat = pGame->GetStats()->GetSkillStatIndex(weaponType);
    float         skill = pGame->GetStats()->GetStatValue(weaponSkillStat);

    return pGame->GetWeaponStatManager()->GetWeaponStatsFromSkillLevel(weaponType, skill);
}

float CPedSA::GetCurrentWeaponRange() const
{
    CWeaponStat* weaponStat = GetCurrentWeaponStat();
    return weaponStat ? weaponStat->GetWeaponRange() : 1.0f;
}

void CPedSA::AddWeaponAudioEvent(EPedWeaponAudioEventType audioEventType)
{
    // void __thiscall CAEPedWeaponAudioEntity::AddAudioEvent(CAEPedWeaponAudioEntity *this, int audioEventId)
    ((void(__thiscall*)(CPedWeaponAudioEntitySAInterface*, std::uint16_t))FUNC_CAEPedWeaponAudioEntity__AddAudioEvent)(
        &GetPedInterface()->weaponAudioEntity, static_cast<std::uint16_t>(audioEventType));
}

bool CPedSA::DoGunFlash(std::uint32_t duration, bool leftHand)
{
    if (!GetPedInterface() || !duration)
        return false;

    return reinterpret_cast<bool(__thiscall*)(CPedSAInterface*, std::uint32_t, bool)>(FUNC_CPed_DoGunFlash)(GetPedInterface(), duration, leftHand);
}

bool CPedSA::IsDoingGangDriveby() const
{
    if (!m_pedIntelligence)
        return false;

    CTask* task = GetPedIntelligence()->GetTaskManager()->GetTask(TASK_PRIORITY_PRIMARY);
    return (task && task->GetTaskType() == TASK_SIMPLE_GANG_DRIVEBY);
}

float CPedSA::GetOxygenLevel() const
{
    return GetPedInterface()->pPlayerData->m_fBreath;
}

void CPedSA::SetOxygenLevel(float oxygen)
{
    GetPedInterface()->pPlayerData->m_fBreath = oxygen;
}

void CPedSA::Say(const ePedSpeechContext& speechId, float probability)
{
    // Call CPed::Say
    ((void(__thiscall*)(CPedSAInterface*, ePedSpeechContext, int, float, bool, bool, bool))FUNC_CPed_Say)(GetPedInterface(), speechId, 0, probability, false,
                                                                                                          false, false);
}

void CPedSA::GetAttachedSatchels(std::vector<SSatchelsData>& satchelsList) const
{
    // Array of projectiles objects
    auto**                  projectilesArray = reinterpret_cast<CProjectileSAInterface**>(ARRAY_CProjectile);
    CProjectileSAInterface* projectileInterface = nullptr;

    // Array of projectiles infos
    auto*                       projectilesInfoArray = reinterpret_cast<CProjectileInfoSAInterface*>(ARRAY_CProjectileInfo);
    CProjectileInfoSAInterface* projectileInfoInterface = nullptr;

    satchelsList.reserve(PROJECTILE_COUNT);

    // Loop through all projectiles
    for (std::size_t i = 0; i < PROJECTILE_COUNT; i++)
    {
        projectileInterface = projectilesArray[i];

        // is attached to our ped?
        if (!projectileInterface || projectileInterface->m_pAttachedEntity != m_pInterface)
            continue;

        // index is always the same for both arrays
        projectileInfoInterface = &projectilesInfoArray[i];

        // We are only interested in satchels
        if (!projectileInfoInterface || projectileInfoInterface->dwProjectileType != eWeaponType::WEAPONTYPE_REMOTE_SATCHEL_CHARGE)
            continue;

        // Push satchel into the array. There is no need to check the counter because for satchels it restarts until the player detonates the charges
        satchelsList.emplace_back(projectileInterface, &projectileInterface->m_vecAttachedOffset, &projectileInterface->m_vecAttachedRotation);
    }
}

void CPedSA::SetInWaterFlags(bool inWater)
{
    auto* physicalInterface = static_cast<CPhysicalSAInterface*>(m_pInterface);
    if (!physicalInterface)
        return;

    physicalInterface->bTouchingWater = inWater;
    physicalInterface->bSubmergedInWater = inWater;
}

void __fastcall CPedSA::RemoveWeaponWhenEnteringVehicle(CPedSAInterface* pedInterface, void*, int jetpack)
{
    if (!pedInterface)
        return;

    pedInterface->RemoveWeaponWhenEnteringVehicle(jetpack == 1);
}

void CPedSAInterface::RemoveWeaponWhenEnteringVehicle(bool jetpack)
{
    // Bugfix #3659 (allow switch weapons while using jetpack - see PR #3573)
    if (!jetpack)
    {
        if (auto* playerData = pPlayerData)
            playerData->m_bInVehicleDontAllowWeaponChange = true;
    }

    if (savedWeapon != eWeaponType::WEAPONTYPE_UNIDENTIFIED)
        return;

    eWeaponSlot newSlot = WEAPONSLOT_MAX;

    if (IsPlayer())
    {
        auto* playerInfo = pGame->GetPlayerInfo();
        if (playerInfo && playerInfo->CanDoDriveBy())
        {
            const auto& smg = Weapons[WEAPONSLOT_TYPE_SMG];
            const auto& shotgun = Weapons[WEAPONSLOT_TYPE_SHOTGUN];
            const auto& pistol = Weapons[WEAPONSLOT_TYPE_HANDGUN];

            const bool hasSMG = (smg.m_eWeaponType == eWeaponType::WEAPONTYPE_MICRO_UZI || smg.m_eWeaponType == eWeaponType::WEAPONTYPE_TEC9 ||
                                 (jetpack && smg.m_eWeaponType == eWeaponType::WEAPONTYPE_MP5)) &&
                                smg.m_ammoTotal > 0;

            const bool hasSawnoff = jetpack && shotgun.m_eWeaponType == eWeaponType::WEAPONTYPE_SAWNOFF_SHOTGUN && shotgun.m_ammoTotal > 0;

            const bool hasPistol = jetpack && pistol.m_eWeaponType == eWeaponType::WEAPONTYPE_PISTOL && pistol.m_ammoTotal > 0;

            if (hasSMG)
            {
                newSlot = WEAPONSLOT_TYPE_SMG;
            }
            else if (hasSawnoff)  // Bugfix - the default here was WEAPONSLOT_TYPE_HANDGUN
            {
                newSlot = WEAPONSLOT_TYPE_SHOTGUN;
            }
            else if (hasPistol)
            {
                newSlot = WEAPONSLOT_TYPE_HANDGUN;
            }
        }
    }

    if (newSlot != WEAPONSLOT_MAX)
    {
        savedWeapon = Weapons[bCurrentWeaponSlot].m_eWeaponType;
        SetCurrentWeapon(newSlot);
    }
    else if (!jetpack)  // Bugfix #508 (weapons are invisible when wearing jetpack - see PR #3559)
    {
        auto weaponType = Weapons[bCurrentWeaponSlot].m_eWeaponType;
        auto model = pGame->GetWeaponInfo(weaponType, eWeaponSkill::WEAPONSKILL_STD)->GetModel();
        RemoveWeaponModel(model);
    }
}

////////////////////////////////////////////////////////////////
//
// CPed_PreRenderAfterTest
//
// Code at start of CPed::PreRenderAfterTest applies extra rotations for slope pitch and swimming.
// Check if they have already been applied.
//
////////////////////////////////////////////////////////////////
#define HOOKPOS_CPed_PreRenderAfterTest  0x5E65A0
#define HOOKSIZE_CPed_PreRenderAfterTest 15
static constexpr std::uintptr_t RETURN_CPed_PreRenderAfterTest = 0x5E65AF;
static constexpr std::uintptr_t RETURN_CPed_PreRenderAfterTestSkip = 0x5E6658;
static void __declspec(naked)   HOOK_CPed_PreRenderAfterTest()
{
    MTA_VERIFY_HOOK_LOCAL_SIZE;

    // clang-format off
    __asm
    {
        // Replaced code
        sub     esp, 70h
        push    ebx
        push    ebp
        push    esi
        mov     ebp, ecx
        mov     ecx, dword ptr [ebp+47Ch]
        push    edi

        // Check what to do
        mov     eax, [ebp+474h] // Load m_nThirdPedFlags
        test    eax, 400h // check bCalledPreRender flag
        jnz     skip_rotation_update

        // Run code at start of CPed::PreRenderAfterTest
        jmp     RETURN_CPed_PreRenderAfterTest

        skip_rotation_update:
        // Skip code at start of CPed::PreRenderAfterTest
        jmp     RETURN_CPed_PreRenderAfterTestSkip
    }
    // clang-format on
}

////////////////////////////////////////////////////////////////
//
// CPed_PreRenderAfterTest_Mid
//
// Code at mid of CPed::PreRenderAfterTest does all sorts of stuff
// Check if it should not be called because we only wanted to do the extra rotations
//
////////////////////////////////////////////////////////////////
#define HOOKPOS_CPed_PreRenderAfterTest_Mid  0x5E6669
#define HOOKSIZE_CPed_PreRenderAfterTest_Mid 5
static constexpr std::uintptr_t RETURN_CPed_PreRenderAfterTest_Mid = 0x5E666E;
static constexpr std::uintptr_t RETURN_CPed_PreRenderAfterTest_MidSkip = 0x5E766F;
static void __declspec(naked)   HOOK_CPed_PreRenderAfterTest_Mid()
{
    MTA_VERIFY_HOOK_LOCAL_SIZE;

    // clang-format off
    __asm
    {
        // Check what to do
        movzx   eax, byte ptr g_onlyUpdateRotations
        test    eax, eax
        jnz     skip_tail

        // Replaced code
        mov     al, byte ptr ds:[00B7CB89h]
        // Run code at mid of CPed::PreRenderAfterTest
        jmp     RETURN_CPed_PreRenderAfterTest_Mid

        skip_tail:
        // Skip code at mid of CPed::PreRenderAfterTest
        jmp     RETURN_CPed_PreRenderAfterTest_MidSkip
    }
    // clang-format on
}

namespace
{
    constexpr std::uintptr_t FUNC_CVisibilityPlugins_GetClumpAlpha = 0x732B20;
    constexpr std::uintptr_t FUNC_CShadows_StoreShadowForPedObject = 0x707B40;
    constexpr std::uintptr_t CALL_CPed_PreRenderAfterTest_StoreShadowForPedObject = 0x5E6900;

    void __cdecl StoreShadowForPedObject(CPedSAInterface* ped, float displacementX, float displacementY, float frontX, float frontY, float sideX, float sideY)
    {
        using GetClumpAlpha = int(__cdecl*)(RpClump*);
        if (reinterpret_cast<GetClumpAlpha>(FUNC_CVisibilityPlugins_GetClumpAlpha)(ped->m_pRwObject) == 0)
            return;

        using StoreShadow = void(__cdecl*)(CPedSAInterface*, float, float, float, float, float, float);
        reinterpret_cast<StoreShadow>(FUNC_CShadows_StoreShadowForPedObject)(ped, displacementX, displacementY, frontX, frontY, sideX, sideY);
    }
}

////////////////////////////////////////////////////////////////
//
// Setup hooks
//
////////////////////////////////////////////////////////////////
void CPedSA::StaticSetHooks()
{
    EZHookInstall(CPed_PreRenderAfterTest);
    EZHookInstall(CPed_PreRenderAfterTest_Mid);

    // GTA's player-specific blob-shadow path assumes that the local player is
    // always opaque. Do not enqueue it when MTA has made the clump invisible.
    HookInstallCall(CALL_CPed_PreRenderAfterTest_StoreShadowForPedObject, reinterpret_cast<DWORD>(StoreShadowForPedObject));

    HookInstallCall(0x68025A, (DWORD)CPedSA::RemoveWeaponWhenEnteringVehicle);  // CTaskSimpleJetPack::ProcessPed
    HookInstallCall(0x64DB4D, (DWORD)CPedSA::RemoveWeaponWhenEnteringVehicle);  // CTaskSimpleCarGetIn::ProcessPed
    HookInstallCall(0x64BCA3, (DWORD)CPedSA::RemoveWeaponWhenEnteringVehicle);  // CTaskSimpleCarSetPedInAsDriver::ProcessPed
    HookInstallCall(0x64B876, (DWORD)CPedSA::RemoveWeaponWhenEnteringVehicle);  // CTaskSimpleCarSetPedInAsPassenger::ProcessPed
}
void CPedSA::SetNativeAmbientGroupActive(bool active)
{
    if (m_bNativeAmbientGroupActive == active)
        return;

    auto* pedInterface = GetPedInterface();
    auto* intelligence = pedInterface ? pedInterface->pPedIntelligence : nullptr;
    if (active)
    {
        if (!intelligence || !pedInterface->pPedStats)
            return;
        m_iNativeAmbientGroupPreviousDecisionMaker = intelligence->decisionMakerType;
        m_iNativeAmbientGroupPreviousDecisionMakerInGroup = intelligence->decisionMakerTypeInGroup;
        m_nativeAmbientGroupPreviousAcquaintance = pedInterface->pedAcquaintance;
        m_bNativeAmbientGroupDecisionMakerCaptured = true;
        intelligence->decisionMakerType = pedInterface->pPedStats->GetDefaultDecisionMaker();
        intelligence->decisionMakerTypeInGroup = pedInterface->pPedStats->GetDefaultDecisionMaker();

        auto* modelInfo = reinterpret_cast<CPedModelInfoSAInterface*>(CModelInfoSAInterface::GetModelInfo(pedInterface->m_nModelIndex));
        if (modelInfo && modelInfo->pedType < 32)
        {
            using GetPedTypeAcquaintances = CPedAcquaintanceSAInterface*(__cdecl*)(int);
            if (auto* acquaintances = reinterpret_cast<GetPedTypeAcquaintances>(0x6089B0)(modelInfo->pedType))
                pedInterface->pedAcquaintance = *acquaintances;
        }
    }
    else if (m_bNativeAmbientGroupDecisionMakerCaptured && intelligence)
    {
        intelligence->decisionMakerType = m_iNativeAmbientGroupPreviousDecisionMaker;
        intelligence->decisionMakerTypeInGroup = m_iNativeAmbientGroupPreviousDecisionMakerInGroup;
        pedInterface->pedAcquaintance = m_nativeAmbientGroupPreviousAcquaintance;
        m_bNativeAmbientGroupDecisionMakerCaptured = false;
    }
    m_bNativeAmbientGroupActive = active;
}
