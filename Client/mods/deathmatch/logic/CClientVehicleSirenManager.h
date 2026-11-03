/*****************************************************************************
 *
 *  PROJECT:     Multi Theft Auto
 *  LICENSE:     See LICENSE in the top level directory
 *  FILE:        Client/mods/deathmatch/logic/CClientVehicleSirenManager.h
 *  PURPOSE:     Advanced Vehicle Sirens (AVS) native lighting subsystem
 *               Matches Cake's original AVS C++ architecture: dynamic DFF dummy
 *               discovery, multi-state JSON manifest parsing, native CCoronas
 *               rendering at 0x6FC580, TIR directional falloff, 360 rotators,
 *               and multiplayer synchronization.
 *
 *****************************************************************************/

#pragma once

#include <Common.h>
#include <CVector.h>
#include <SharedUtil.h>
#include <game/RenderWare.h>

#pragma push_macro("snprintf")
#undef snprintf
#include <nlohmann/json.hpp>
#pragma pop_macro("snprintf")

#include <map>
#include <vector>
#include <string>
#include <unordered_map>
#include <memory>

class CClientManager;
class CClientVehicle;

// Rotary beacon directions matching AVS VehicleSirens.h
enum class EAVSRotatorDirection
{
    Clockwise = 0,
    CounterClockwise = 1,
    Switch = 2
};

// Rotary beacon interpolation types
enum class EAVSRotatorType
{
    Linear = 0,
    Ease = 1
};

// Siren lighting optic types
enum class EAVSSirenType
{
    Directional = 0,
    NonDirectional = 1,
    Inversed = 2,
    Rotator = 3
};

// Rotary beacon specification
struct SAVSRotatorConfig
{
    EAVSRotatorDirection direction = EAVSRotatorDirection::Clockwise;
    EAVSRotatorType      type = EAVSRotatorType::Linear;
    unsigned long        time = 1000;
    float                offset = 0.0f;
    float                radius = 360.0f;
};

// Shadow projection configuration
struct SAVSShadowConfig
{
    float       size = 0.0f;
    std::string type;
    float       offset = 0.0f;
};

// Material / group illumination definition
struct SAVSSirenMaterialConfig
{
    int               id = 0;
    EAVSSirenType     type = EAVSSirenType::Directional;
    float             size = 0.3f;
    float             radius = 180.0f;  // TIR cone angle in degrees (default 180 for standard beam)
    SColor            color = SColorRGBA(255, 255, 255, 128);
    float             inertia = 0.0f;
    int               delay = 0;
    SAVSRotatorConfig rotator;
    SAVSShadowConfig  shadow;
    std::vector<int>  pattern;  // Millisecond slice durations
    int               patternTotalTime = 0;
    std::string       texture;
};

// Single functional state (e.g. "1.Emergency", "2. Right", "3. Left")
struct SAVSStateConfig
{
    std::string                            name;
    std::map<int, SAVSSirenMaterialConfig> materials;  // Map of dummy/material group index -> config
};

// Complete vehicle model configuration parsed from AVS JSON manifest
struct SAVSModelConfig
{
    std::uint32_t                          modelId = 0;
    std::vector<std::string>               stateNames;
    std::map<std::string, SAVSStateConfig> states;
    float                                  streamDistance = 150.0f;
    bool                                   inertiaEnabled = true;
    float                                  inertiaAngle = 30.0f;
    bool                                   flareEnabled = true;
    float                                  flareDistance = 40.0f;
};

// Single light dummy discovered dynamically from the vehicle DFF RwFrame hierarchy
struct SAVSDummyInfo
{
    int     id = 0;
    CVector localPos;
    float   baseAngle = 0.0f;  // Angle in degrees extracted from frame orientation
    int     type = 0;
    SColor  overrideColor;
    bool    hasOverrideColor = false;
};

// Tracked material info for dynamic vehicle texture swapping & ambient illumination matching original AVS
struct SAVSMaterialInfo
{
    RpMaterial* pMaterial = nullptr;
    RwTexture*  pOriginalTexture = nullptr;
    RwTexture*  pActiveTexture = nullptr;
    float       originalAmbient = 1.0f;
    RwColor     originalColor = {255, 255, 255, 255};
};

// Runtime state tracked per streamed vehicle
struct SAVSVehicleRuntime
{
    int                                          activeStateIndex = 0;  // 0 = off, 1 = state 1...
    std::string                                  activeStateName;
    bool                                         muted = false;
    unsigned long                                stateStartedAt = 0;
    std::map<int, std::vector<SAVSDummyInfo>>    dummiesByGroup;
    bool                                         dummiesDiscovered = false;
    std::map<int, std::vector<SAVSMaterialInfo>> materialsByGroup;
    bool                                         materialsDiscovered = false;
    bool                                         shadowsEnabled = true;
};

class CClientVehicleSirenManager
{
public:
    static CClientVehicleSirenManager& GetSingleton();

    // Model registration & JSON manifest loading
    bool                     RegisterModelFromJSON(std::uint32_t modelId, const std::string& jsonContent);
    bool                     UnregisterModel(std::uint32_t modelId);
    bool                     HasModelConfig(std::uint32_t modelId) const;
    const SAVSModelConfig*   GetModelConfig(std::uint32_t modelId) const;
    std::vector<std::string> GetModelStates(std::uint32_t modelId) const;

    // Per-vehicle siren control
    bool        SetVehicleSirenState(CClientVehicle* pVehicle, int stateIndex);
    bool        SetVehicleSirenState(CClientVehicle* pVehicle, const std::string& stateName);
    int         GetVehicleSirenStateIndex(CClientVehicle* pVehicle) const;
    std::string GetVehicleSirenStateName(CClientVehicle* pVehicle) const;
    void        SetVehicleSirenMuted(CClientVehicle* pVehicle, bool muted);
    bool        IsVehicleSirenMuted(CClientVehicle* pVehicle) const;

    // Ground reflection / siren shadows control
    void SetSirenShadowsEnabled(bool enabled) { m_bShadowsEnabled = enabled; }
    bool IsSirenShadowsEnabled() const { return m_bShadowsEnabled; }
    void SetVehicleSirenShadowsEnabled(CClientVehicle* pVehicle, bool enabled);
    bool IsVehicleSirenShadowsEnabled(CClientVehicle* pVehicle) const;

    // Lifecycle hooks
    void OnVehicleDestroyed(CClientVehicle* pVehicle);
    void DoPulse(CClientManager* pManager);
    void DoRender(CClientManager* pManager);

    // Dynamic RwFrame dummy & RpMaterial discovery
    void DiscoverVehicleDummies(CClientVehicle* pVehicle, SAVSVehicleRuntime& runtime);
    void DiscoverVehicleMaterials(CClientVehicle* pVehicle, SAVSVehicleRuntime& runtime);
    void RestoreVehicleMaterials(CClientVehicle* pVehicle, SAVSVehicleRuntime& runtime);

private:
    CClientVehicleSirenManager() = default;
    ~CClientVehicleSirenManager() = default;
    CClientVehicleSirenManager(const CClientVehicleSirenManager&) = delete;
    CClientVehicleSirenManager& operator=(const CClientVehicleSirenManager&) = delete;

    // AVS native corona registration helper (implements PluginCoronas::AddWithAngle)
    void RenderCoronaWithAngle(void* pVehicleInterface, unsigned int coronaId, float cameraAngle, float dummyAngle, float radius, float inertiaAngle,
                               bool inertiaEnabled, unsigned char r, unsigned char g, unsigned char b, unsigned char a, const CVector& localPos, float size,
                               float farClip);

    std::unordered_map<std::uint32_t, SAVSModelConfig>      m_ModelConfigs;
    std::unordered_map<CClientVehicle*, SAVSVehicleRuntime> m_VehicleRuntimes;
    bool                                                    m_bShadowsEnabled = true;
};
