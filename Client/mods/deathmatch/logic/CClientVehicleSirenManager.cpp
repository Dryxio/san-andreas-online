/*****************************************************************************
 *
 *  PROJECT:     Multi Theft Auto
 *  LICENSE:     See LICENSE in the top level directory
 *  FILE:        Client/mods/deathmatch/logic/CClientVehicleSirenManager.cpp
 *  PURPOSE:     Advanced Vehicle Sirens (AVS) native lighting subsystem
 *               Matches Cake's original AVS C++ architecture: dynamic DFF dummy
 *               discovery, multi-state JSON manifest parsing, native CCoronas
 *               rendering at 0x6FC580, TIR directional falloff, 360 rotators,
 *               and multiplayer synchronization.
 *
 *****************************************************************************/

#include "StdInc.h"
#include "CClientVehicleSirenManager.h"
#include "CClientManager.h"
#include "CClientVehicle.h"
#include "CClientVehicleManager.h"
#include "CClientCamera.h"
#include <game/CVehicle.h>
#include <cmath>
#include <cctype>

// GTA San Andreas native CCoronas::RegisterCorona function pointer (address 0x6FC580)
using RegisterCorona_t = void(__cdecl*)(unsigned int id, void* attachTo, unsigned char r, unsigned char g, unsigned char b, unsigned char intensity,
                                        const CVector& pos, float size, float range, void* texture, int flareType, int reflType, int losCheck, int trail,
                                        float normalAngle, bool neonFade, float pullTowardsCam, bool fullBright, float fadeSpeed, bool onlyFromBelow,
                                        bool whiteCore);
#define FUNC_CCoronas_RegisterCorona 0x6FC580

// GTA San Andreas native RenderWare function pointers for clump traversal and texture dictionary lookups
using RpClumpForAllAtomicsCB_t = bool(__cdecl*)(RpAtomic*, void*);
using RpClumpForAllAtomics_t = RpClump*(__cdecl*)(RpClump*, RpClumpForAllAtomicsCB_t, void*);
static auto RpClumpForAllAtomics = reinterpret_cast<RpClumpForAllAtomics_t>(0x00749B70);

using RwTexDictionaryFindNamedTexture_t = RwTexture*(__cdecl*)(RwTexDictionary*, const char*);
static auto RwTexDictionaryFindNamedTexture = reinterpret_cast<RwTexDictionaryFindNamedTexture_t>(0x007F39F0);

// GTA San Andreas native CShadows::StoreShadowToBeRendered function pointer (address 0x707390)
using StoreShadowToBeRendered_t = void(__cdecl*)(char type, void* texture, const CVector* pos, float frontX, float frontY, float sideX, float sideY,
                                                 short intensity, unsigned char r, unsigned char g, unsigned char b, float zDistance, bool drawOnWater,
                                                 float scale, void* shadowData, bool drawOnBuildings);
#define FUNC_CShadows_StoreShadowToBeRendered 0x707390
#define VAR_gpShadowCarTex                    0xC403E0
#define VAR_gpShadowExplosionTex              0xC403F4
#define VAR_gpShadowHeadLightsTex             0xC403F8

namespace
{
    // Helper to decode 2 hex characters into byte (matching AVS VehicleDummy::ReadHex)
    int ReadHex(char a, char b)
    {
        int valA = (a >= '0' && a <= '9') ? (a - '0') : ((a & 0x7) + 9);
        int valB = (b >= '0' && b <= '9') ? (b - '0') : ((b & 0x7) + 9);
        return (valA << 4) + valB;
    }

    // Helper to parse hex color string "#RRGGBB" or "RRGGBB"
    SColor ParseHexColor(const std::string& hex, unsigned char defaultAlpha = 128)
    {
        std::string clean = hex;
        if (!clean.empty() && clean[0] == '#')
            clean = clean.substr(1);

        if (clean.length() >= 6)
        {
            unsigned char r = static_cast<unsigned char>(ReadHex(clean[0], clean[1]));
            unsigned char g = static_cast<unsigned char>(ReadHex(clean[2], clean[3]));
            unsigned char b = static_cast<unsigned char>(ReadHex(clean[4], clean[5]));
            unsigned char a = (clean.length() >= 8) ? static_cast<unsigned char>(ReadHex(clean[6], clean[7])) : defaultAlpha;
            return SColorRGBA(r, g, b, a);
        }
        return SColorRGBA(255, 255, 255, defaultAlpha);
    }
}

CClientVehicleSirenManager& CClientVehicleSirenManager::GetSingleton()
{
    static CClientVehicleSirenManager instance;
    return instance;
}

bool CClientVehicleSirenManager::RegisterModelFromJSON(std::uint32_t modelId, const std::string& jsonContent)
{
    try
    {
        auto root = nlohmann::json::parse(jsonContent);

        SAVSModelConfig config;
        config.modelId = modelId;

        // Parse global settings
        if (root.contains("streamDistance") && root["streamDistance"].is_number())
            config.streamDistance = root["streamDistance"].get<float>();
        if (root.contains("inertia") && root["inertia"].is_boolean())
            config.inertiaEnabled = root["inertia"].get<bool>();
        if (root.contains("inertiaAngle") && root["inertiaAngle"].is_number())
            config.inertiaAngle = root["inertiaAngle"].get<float>();

        // Parse references (templates and colors) matching AVS VehicleSirenData::References
        std::map<std::string, nlohmann::json> references;
        std::map<std::string, SColor>         referenceColors;

        // Seed standard AVS fallback colors in case a config uses named color references
        referenceColors["yellow"] = SColorRGBA(255, 153, 0, 180);
        referenceColors["amber"] = SColorRGBA(255, 153, 0, 180);
        referenceColors["red"] = SColorRGBA(255, 0, 0, 180);
        referenceColors["blue"] = SColorRGBA(0, 0, 255, 180);
        referenceColors["white"] = SColorRGBA(255, 255, 255, 180);
        referenceColors["green"] = SColorRGBA(0, 255, 0, 180);
        referenceColors["orange"] = SColorRGBA(255, 128, 0, 180);

        if (root.contains("references") && root["references"].is_object())
        {
            for (auto it = root["references"].begin(); it != root["references"].end(); ++it)
            {
                std::string key = it.key();
                const auto& value = it.value();

                if (key == "colors" && value.is_object())
                {
                    for (auto cIt = value.begin(); cIt != value.end(); ++cIt)
                    {
                        const auto& cVal = cIt.value();
                        if (cVal.is_object())
                        {
                            unsigned char r = static_cast<unsigned char>(cVal.value("red", 255));
                            unsigned char g = static_cast<unsigned char>(cVal.value("green", 255));
                            unsigned char b = static_cast<unsigned char>(cVal.value("blue", 255));
                            unsigned char a = static_cast<unsigned char>(cVal.value("alpha", 180));
                            referenceColors[cIt.key()] = SColorRGBA(r, g, b, a);
                        }
                    }
                    continue;
                }

                references[key] = value;
            }
        }

        // Parse states (supporting both nested "states" block and root-level state definitions matching original AVS)
        nlohmann::json statesObj = root;
        bool           isRootStates = true;
        if (root.contains("states") && root["states"].is_object())
        {
            statesObj = root["states"];
            isRootStates = false;
        }

        if (statesObj.is_object())
        {
            for (auto stateIt = statesObj.begin(); stateIt != statesObj.end(); ++stateIt)
            {
                std::string stateName = stateIt.key();
                if (isRootStates)
                {
                    if (stateName == "references" || stateName == "streamDistance" || stateName == "inertia" || stateName == "inertiaAngle" ||
                        stateName == "flare" || stateName == "flareDistance" || !stateIt.value().is_object())
                        continue;
                }

                SAVSStateConfig stateConfig;
                stateConfig.name = stateName;

                if (stateIt.value().is_object())
                {
                    for (auto matIt = stateIt.value().begin(); matIt != stateIt.value().end(); ++matIt)
                    {
                        int            matIndex = std::stoi(matIt.key());
                        nlohmann::json matJson = matIt.value();

                        // Resolve references if declared (merging template keys)
                        if (matJson.contains("reference"))
                        {
                            std::vector<std::string> refList;
                            if (matJson["reference"].is_string())
                                refList.push_back(matJson["reference"].get<std::string>());
                            else if (matJson["reference"].is_array())
                            {
                                for (const auto& r : matJson["reference"])
                                    if (r.is_string())
                                        refList.push_back(r.get<std::string>());
                            }

                            for (const auto& refName : refList)
                            {
                                auto refFound = references.find(refName);
                                if (refFound != references.end() && refFound->second.is_object())
                                {
                                    for (auto fieldIt = refFound->second.begin(); fieldIt != refFound->second.end(); ++fieldIt)
                                    {
                                        if (!matJson.contains(fieldIt.key()))
                                            matJson[fieldIt.key()] = fieldIt.value();
                                    }
                                }
                            }
                        }

                        SAVSSirenMaterialConfig matConfig;
                        matConfig.id = matIndex;

                        if (matJson.contains("size") && matJson["size"].is_number())
                            matConfig.size = matJson["size"].get<float>();

                        if (matJson.contains("radius") && matJson["radius"].is_number())
                            matConfig.radius = matJson["radius"].get<float>();

                        if (matJson.contains("inertia") && matJson["inertia"].is_number())
                            matConfig.inertia = matJson["inertia"].get<float>();

                        if (matJson.contains("delay") && matJson["delay"].is_number())
                            matConfig.delay = matJson["delay"].get<int>();

                        // Color parsing matching AVS VehicleSirenMaterial constructor
                        if (matJson.contains("color"))
                        {
                            const auto& colVal = matJson["color"];
                            if (colVal.is_string())
                            {
                                std::string colStr = colVal.get<std::string>();
                                auto        refIt = referenceColors.find(colStr);
                                if (refIt != referenceColors.end())
                                {
                                    matConfig.color = refIt->second;
                                }
                                else if (!colStr.empty() && (colStr[0] == '#' || std::isxdigit(colStr[0])))
                                {
                                    matConfig.color = ParseHexColor(colStr);
                                }
                            }
                            else if (colVal.is_object())
                            {
                                unsigned char r = static_cast<unsigned char>(colVal.value("red", 255));
                                unsigned char g = static_cast<unsigned char>(colVal.value("green", 255));
                                unsigned char b = static_cast<unsigned char>(colVal.value("blue", 255));
                                unsigned char a = static_cast<unsigned char>(colVal.value("alpha", 180));
                                matConfig.color = SColorRGBA(r, g, b, a);
                            }
                            else if (colVal.is_array() && colVal.size() >= 3)
                            {
                                unsigned char r = colVal[0].get<unsigned char>();
                                unsigned char g = colVal[1].get<unsigned char>();
                                unsigned char b = colVal[2].get<unsigned char>();
                                unsigned char a = (colVal.size() >= 4) ? colVal[3].get<unsigned char>() : 180;
                                matConfig.color = SColorRGBA(r, g, b, a);
                            }
                        }

                        // Type parsing
                        if (matJson.contains("type") && matJson["type"].is_string())
                        {
                            std::string t = matJson["type"].get<std::string>();
                            if (t == "directional")
                                matConfig.type = EAVSSirenType::Directional;
                            else if (t == "non-directional")
                                matConfig.type = EAVSSirenType::NonDirectional;
                            else if (t == "inversed-directional")
                                matConfig.type = EAVSSirenType::Inversed;
                            else if (t == "rotator")
                            {
                                matConfig.type = EAVSSirenType::Rotator;
                                if (matJson.contains("rotator") && matJson["rotator"].is_object())
                                {
                                    auto rJson = matJson["rotator"];
                                    if (rJson.contains("direction") && rJson["direction"].is_string())
                                    {
                                        std::string dir = rJson["direction"].get<std::string>();
                                        if (dir == "clockwise")
                                            matConfig.rotator.direction = EAVSRotatorDirection::Clockwise;
                                        else if (dir == "counter-clockwise")
                                            matConfig.rotator.direction = EAVSRotatorDirection::CounterClockwise;
                                        else if (dir == "switch")
                                            matConfig.rotator.direction = EAVSRotatorDirection::Switch;
                                    }
                                    if (rJson.contains("time") && rJson["time"].is_number())
                                        matConfig.rotator.time = rJson["time"].get<unsigned long>();
                                    if (rJson.contains("radius") && rJson["radius"].is_number())
                                        matConfig.rotator.radius = rJson["radius"].get<float>();
                                    if (rJson.contains("offset") && rJson["offset"].is_number())
                                        matConfig.rotator.offset = rJson["offset"].get<float>();
                                }
                            }
                        }

                        // Pattern parsing (supporting both flat durations and nested repetitions [reps, d1, d2...])
                        if (matJson.contains("pattern") && matJson["pattern"].is_array())
                        {
                            for (const auto& item : matJson["pattern"])
                            {
                                if (item.is_number())
                                {
                                    int dur = item.get<int>();
                                    matConfig.pattern.push_back(dur);
                                    matConfig.patternTotalTime += dur;
                                }
                                else if (item.is_array() && item.size() >= 2)
                                {
                                    int reps = item[0].get<int>();
                                    for (int r = 0; r < reps; ++r)
                                    {
                                        for (size_t i = 1; i < item.size(); ++i)
                                        {
                                            int dur = item[i].get<int>();
                                            matConfig.pattern.push_back(dur);
                                            matConfig.patternTotalTime += dur;
                                        }
                                    }
                                }
                            }
                        }

                        // Shadow projection parsing matching AVS manifest
                        if (matJson.contains("shadow") && matJson["shadow"].is_object())
                        {
                            const auto& sObj = matJson["shadow"];
                            if (sObj.contains("size") && sObj["size"].is_number())
                                matConfig.shadow.size = sObj["size"].get<float>();
                            if (sObj.contains("offset") && sObj["offset"].is_number())
                                matConfig.shadow.offset = sObj["offset"].get<float>();
                            if (sObj.contains("type"))
                            {
                                if (sObj["type"].is_string())
                                    matConfig.shadow.type = sObj["type"].get<std::string>();
                                else if (sObj["type"].is_number())
                                    matConfig.shadow.type = std::to_string(sObj["type"].get<int>());
                            }
                        }

                        stateConfig.materials[matIndex] = matConfig;
                    }
                }

                config.stateNames.push_back(stateName);
                config.states[stateName] = stateConfig;
            }
        }

        m_ModelConfigs[modelId] = config;
        return true;
    }
    catch (const std::exception&)
    {
        return false;
    }
}

bool CClientVehicleSirenManager::UnregisterModel(std::uint32_t modelId)
{
    return m_ModelConfigs.erase(modelId) > 0;
}

bool CClientVehicleSirenManager::HasModelConfig(std::uint32_t modelId) const
{
    return m_ModelConfigs.find(modelId) != m_ModelConfigs.end();
}

const SAVSModelConfig* CClientVehicleSirenManager::GetModelConfig(std::uint32_t modelId) const
{
    auto it = m_ModelConfigs.find(modelId);
    return (it != m_ModelConfigs.end()) ? &it->second : nullptr;
}

std::vector<std::string> CClientVehicleSirenManager::GetModelStates(std::uint32_t modelId) const
{
    auto it = m_ModelConfigs.find(modelId);
    if (it != m_ModelConfigs.end())
        return it->second.stateNames;
    return {};
}

void CClientVehicleSirenManager::DiscoverVehicleDummies(CClientVehicle* pVehicle, SAVSVehicleRuntime& runtime)
{
    runtime.dummiesByGroup.clear();

    if (!pVehicle || !pVehicle->GetGameVehicle())
        return;

    // Scan all RwFrames in the vehicle model hierarchy matching AVS dummy naming conventions
    std::map<SString, SVehicleFrame>& componentMap = pVehicle->GetGameVehicle()->GetComponentMap();
    if (componentMap.empty())
        return;

    runtime.dummiesDiscovered = true;

    for (const auto& pair : componentMap)
    {
        const SString& name = pair.first;
        RwFrame*       pFrame = pair.second.pFrame;
        if (!pFrame)
            continue;

        int start = -1;
        if (name.BeginsWith("siren_"))
            start = 6;
        else if (name.BeginsWith("siren"))
            start = 5;
        else if (name.BeginsWith("light_em"))
            start = 8;

        if (start == -1 || static_cast<int>(name.length()) <= start)
            continue;

        // Parse material group digits
        std::string materialDigits;
        int         idx = start;
        while (idx < static_cast<int>(name.length()) && std::isdigit(name[idx]))
        {
            materialDigits += name[idx];
            idx++;
        }

        if (materialDigits.empty())
            continue;

        int matGroup = std::stoi(materialDigits);
        if (start == 8)  // light_em special mapping
            matGroup = 256 - matGroup;

        SAVSDummyInfo dummy;
        dummy.id = matGroup;
        dummy.localPos = CVector(pFrame->modelling.pos.x, pFrame->modelling.pos.y, pFrame->modelling.pos.z);

        // Calculate heading angle from RwFrame modelling matrix (exact AVS formula)
        float angle = ((std::atan2(pFrame->modelling.right.y, pFrame->modelling.right.x) * 57.295776f) - 180.0f);
        while (angle < 0.0f)
            angle += 360.0f;
        angle -= 180.0f;

        if (pFrame->modelling.at.z <= 0.0f && angle == 0.0f)
        {
            angle = pFrame->modelling.at.z * 180.0f;
            if (angle > 0.0f)
                angle -= 180.0f;
        }

        dummy.baseAngle = angle;

        // Optional embedded hex color in dummy name (e.g. siren_1_ff0000 or siren1_ff0000)
        if (static_cast<int>(name.length()) >= idx + 6)
        {
            if (name[idx] == '_')
                idx++;
            if (static_cast<int>(name.length()) >= idx + 6)
            {
                dummy.overrideColor =
                    SColorRGBA(static_cast<unsigned char>(ReadHex(name[idx], name[idx + 1])), static_cast<unsigned char>(ReadHex(name[idx + 2], name[idx + 3])),
                               static_cast<unsigned char>(ReadHex(name[idx + 4], name[idx + 5])), 128);
                dummy.hasOverrideColor = true;
            }
        }

        runtime.dummiesByGroup[matGroup].push_back(dummy);
    }
}

void CClientVehicleSirenManager::DiscoverVehicleMaterials(CClientVehicle* pVehicle, SAVSVehicleRuntime& runtime)
{
    runtime.materialsByGroup.clear();

    if (!pVehicle || !pVehicle->GetGameVehicle())
        return;

    // Retrieve entity's clump object
    RpClump* pClump = pVehicle->GetGameVehicle()->GetRpClump();
    if (!pClump)
        return;

    runtime.materialsDiscovered = true;

    struct SDiscoveryContext
    {
        SAVSVehicleRuntime* pRuntime;
    } context = {&runtime};

    RpClumpForAllAtomics(
        pClump,
        [](RpAtomic* atomic, void* data) -> bool
        {
            if (!atomic || !atomic->geometry)
                return true;

            auto*       ctx = static_cast<SDiscoveryContext*>(data);
            RpGeometry* geom = atomic->geometry;

            for (int i = 0; i < geom->materials.entries; ++i)
            {
                RpMaterial* mat = geom->materials.materials[i];
                if (!mat || !mat->texture || !mat->texture->name[0])
                    continue;

                std::string texName = mat->texture->name;

                // Check whether texture belongs to an emergency lighting mesh (AVS standard 'siren' prefix or IVF 'vehiclelights128')
                bool isSiren = (texName.rfind("siren", 0) == 0);
                bool isIVF = (texName.rfind("vehiclelights128", 0) == 0);

                if (!isSiren && !isIVF)
                    continue;

                int matGroup = -1;
                if (isSiren && mat->color.g == 255 && mat->color.b == 255)
                {
                    // AVS standard modeling encoding: vertex color red component specifies material group ID (e.g. 1..42)
                    matGroup = static_cast<int>(mat->color.r);
                }
                else if (isIVF && mat->color.r >= 240 && mat->color.g == 0 && mat->color.b == 0)
                {
                    // IVF encoding compatibility: 256 - red
                    matGroup = 256 - static_cast<int>(mat->color.r);
                }
                else
                {
                    continue;
                }

                if (matGroup <= 0)
                    continue;

                auto& groupList = ctx->pRuntime->materialsByGroup[matGroup];
                bool  alreadyAdded = false;
                for (const auto& item : groupList)
                {
                    if (item.pMaterial == mat)
                    {
                        alreadyAdded = true;
                        break;
                    }
                }
                if (alreadyAdded)
                    continue;

                // Query vehicle TXD dictionary for the active illuminated texture (appending "on" or "_on", e.g. "sirenlight" -> "sirenlighton")
                RwTexture* pActiveTex = mat->texture;
                if (mat->texture->txd)
                {
                    std::string onName1 = texName + "on";
                    std::string onName2 = texName + "_on";
                    RwTexture*  pFound = RwTexDictionaryFindNamedTexture(mat->texture->txd, onName1.c_str());
                    if (!pFound)
                        pFound = RwTexDictionaryFindNamedTexture(mat->texture->txd, onName2.c_str());
                    if (pFound)
                        pActiveTex = pFound;
                }

                SAVSMaterialInfo info;
                info.pMaterial = mat;
                info.pOriginalTexture = mat->texture;
                info.pActiveTexture = pActiveTex;
                info.originalAmbient = mat->lighting.ambient;
                info.originalColor = {255, 255, 255, 255};  // Clean neutral unlit color

                // Reset material vertex color to white so it renders the unlit texture cleanly without color tints
                mat->color.r = 255;
                mat->color.g = 255;
                mat->color.b = 255;
                mat->color.a = 255;

                groupList.push_back(info);
            }

            return true;
        },
        &context);
}

void CClientVehicleSirenManager::RestoreVehicleMaterials(CClientVehicle* pVehicle, SAVSVehicleRuntime& runtime)
{
    for (auto& pair : runtime.materialsByGroup)
    {
        for (auto& info : pair.second)
        {
            if (info.pMaterial)
            {
                info.pMaterial->texture = info.pOriginalTexture;
                info.pMaterial->lighting.ambient = info.originalAmbient;
                info.pMaterial->color = info.originalColor;
            }
        }
    }
}

bool CClientVehicleSirenManager::SetVehicleSirenState(CClientVehicle* pVehicle, int stateIndex)
{
    if (!pVehicle)
        return false;

    if (stateIndex <= 0)
    {
        auto it = m_VehicleRuntimes.find(pVehicle);
        if (it != m_VehicleRuntimes.end())
        {
            it->second.activeStateIndex = 0;
            it->second.activeStateName = "off";
            RestoreVehicleMaterials(pVehicle, it->second);
        }
        return true;
    }

    const SAVSModelConfig* pConfig = GetModelConfig(pVehicle->GetModel());
    if (!pConfig || stateIndex > static_cast<int>(pConfig->stateNames.size()))
        return false;

    SAVSVehicleRuntime& runtime = m_VehicleRuntimes[pVehicle];
    runtime.activeStateIndex = stateIndex;
    runtime.activeStateName = pConfig->stateNames[stateIndex - 1];
    runtime.stateStartedAt = GetTickCount32();

    if (!runtime.dummiesDiscovered)
        DiscoverVehicleDummies(pVehicle, runtime);
    if (!runtime.materialsDiscovered)
        DiscoverVehicleMaterials(pVehicle, runtime);

    return true;
}

bool CClientVehicleSirenManager::SetVehicleSirenState(CClientVehicle* pVehicle, const std::string& stateName)
{
    if (!pVehicle)
        return false;

    if (stateName == "off" || stateName.empty() || stateName == "0")
        return SetVehicleSirenState(pVehicle, 0);

    const SAVSModelConfig* pConfig = GetModelConfig(pVehicle->GetModel());
    if (!pConfig)
        return false;

    for (size_t i = 0; i < pConfig->stateNames.size(); ++i)
    {
        if (pConfig->stateNames[i] == stateName)
            return SetVehicleSirenState(pVehicle, static_cast<int>(i + 1));
    }

    return false;
}

int CClientVehicleSirenManager::GetVehicleSirenStateIndex(CClientVehicle* pVehicle) const
{
    auto it = m_VehicleRuntimes.find(pVehicle);
    return (it != m_VehicleRuntimes.end()) ? it->second.activeStateIndex : 0;
}

std::string CClientVehicleSirenManager::GetVehicleSirenStateName(CClientVehicle* pVehicle) const
{
    auto it = m_VehicleRuntimes.find(pVehicle);
    return (it != m_VehicleRuntimes.end()) ? it->second.activeStateName : "off";
}

void CClientVehicleSirenManager::SetVehicleSirenMuted(CClientVehicle* pVehicle, bool muted)
{
    if (pVehicle)
        m_VehicleRuntimes[pVehicle].muted = muted;
}

bool CClientVehicleSirenManager::IsVehicleSirenMuted(CClientVehicle* pVehicle) const
{
    auto it = m_VehicleRuntimes.find(pVehicle);
    return (it != m_VehicleRuntimes.end()) ? it->second.muted : false;
}

void CClientVehicleSirenManager::SetVehicleSirenShadowsEnabled(CClientVehicle* pVehicle, bool enabled)
{
    if (pVehicle)
        m_VehicleRuntimes[pVehicle].shadowsEnabled = enabled;
}

bool CClientVehicleSirenManager::IsVehicleSirenShadowsEnabled(CClientVehicle* pVehicle) const
{
    auto it = m_VehicleRuntimes.find(pVehicle);
    return (it != m_VehicleRuntimes.end()) ? it->second.shadowsEnabled : true;
}

void CClientVehicleSirenManager::OnVehicleDestroyed(CClientVehicle* pVehicle)
{
    auto it = m_VehicleRuntimes.find(pVehicle);
    if (it != m_VehicleRuntimes.end())
    {
        RestoreVehicleMaterials(pVehicle, it->second);
        m_VehicleRuntimes.erase(it);
    }
}

void CClientVehicleSirenManager::DoPulse(CClientManager* pManager)
{
    // AVS vehicle states are explicitly synchronized across multiplayer through the
    // server-managed element data and Lua events. We deliberately do not overwrite
    // custom AVS vehicle states based on GTA's internal bSirenOrAlarm flag here, because
    // civilian or non-stock emergency vehicle models (e.g. Yosemite 554, utility trucks)
    // never have bSirenOrAlarm set by GTA's native horn logic. Forcing state to 0 here
    // would immediately cancel the active strobe state every frame.
}

void CClientVehicleSirenManager::RenderCoronaWithAngle(void* pVehicleInterface, unsigned int coronaId, float cameraAngle, float dummyAngle, float radius,
                                                       float inertiaAngle, bool inertiaEnabled, unsigned char r, unsigned char g, unsigned char b,
                                                       unsigned char a, const CVector& localPos, float size, float farClip)
{
    float differenceAngle = (cameraAngle > dummyAngle) ? (cameraAngle - dummyAngle) : (dummyAngle - cameraAngle);
    float diameter = radius / 2.0f;

    // Angle culling: if viewer is outside the TIR optic beam cone, discard corona
    if (differenceAngle < diameter || differenceAngle > (360.0f - diameter))
        return;

    // Smooth inertia angle falloff matching original AVS PluginCoronas::AddWithAngle
    if (inertiaEnabled && inertiaAngle > 0.0f)
    {
        float alphaFloat = static_cast<float>(a);
        if (differenceAngle < diameter + inertiaAngle)
        {
            float edgeAngle = diameter - differenceAngle;
            float multiplier = edgeAngle / inertiaAngle;
            if (multiplier < 0.0f)
                multiplier = 0.0f;
            if (multiplier > 1.0f)
                multiplier = 1.0f;
            a = static_cast<unsigned char>(alphaFloat * multiplier);
        }
        else if (differenceAngle > (360.0f - diameter) - inertiaAngle)
        {
            float edgeAngle = inertiaAngle - (differenceAngle - ((360.0f - diameter) - inertiaAngle));
            float multiplier = edgeAngle / inertiaAngle;
            if (multiplier < 0.0f)
                multiplier = 0.0f;
            if (multiplier > 1.0f)
                multiplier = 1.0f;
            a = static_cast<unsigned char>(alphaFloat * multiplier);
        }
    }

    if (a == 0)
        return;

    // Register native GTA corona attached directly to the vehicle entity interface
    reinterpret_cast<RegisterCorona_t>(FUNC_CCoronas_RegisterCorona)(coronaId, pVehicleInterface, r, g, b, a, localPos, size, farClip, nullptr, 0, 0, 0, 0,
                                                                     0.0f, false, 0.5f, false, 100.0f, false, false);
}

void CClientVehicleSirenManager::DoRender(CClientManager* pManager)
{
    if (!pManager || !pManager->GetVehicleManager())
        return;

    unsigned long now = GetTickCount32();

    // Camera heading in degrees
    CVector cameraRot;
    pManager->GetCamera()->GetRotationDegrees(cameraRot);
    float cameraAngle = cameraRot.fZ;

    auto it = pManager->GetVehicleManager()->StreamedBegin();
    auto end = pManager->GetVehicleManager()->StreamedEnd();

    for (; it != end; ++it)
    {
        CClientVehicle* pVehicle = *it;
        if (!pVehicle || pVehicle->IsBlown() || !pVehicle->GetGameVehicle())
            continue;

        auto runtimeIt = m_VehicleRuntimes.find(pVehicle);
        if (runtimeIt == m_VehicleRuntimes.end() || runtimeIt->second.activeStateIndex <= 0)
            continue;

        SAVSVehicleRuntime&    runtime = runtimeIt->second;
        const SAVSModelConfig* pConfig = GetModelConfig(pVehicle->GetModel());
        if (!pConfig)
            continue;

        auto stateIt = pConfig->states.find(runtime.activeStateName);
        if (stateIt == pConfig->states.end())
            continue;

        const SAVSStateConfig& state = stateIt->second;
        void*                  pVehicleInterface = pVehicle->GetGameVehicle()->GetInterface();
        if (!pVehicleInterface)
            continue;

        // Discover dummies and materials dynamically from vehicle DFF & TXD if first stream-in
        if (!runtime.dummiesDiscovered)
            DiscoverVehicleDummies(pVehicle, runtime);
        if (!runtime.materialsDiscovered)
            DiscoverVehicleMaterials(pVehicle, runtime);

        // Vehicle heading angle in degrees
        CVector vehRot;
        pVehicle->GetRotationDegrees(vehRot);
        float vehicleAngle = vehRot.fZ;

        unsigned long elapsedStateTime = now - runtime.stateStartedAt;

        // Dynamically update physical vehicle mesh materials (texture swap to "sirenlighton", ambient boost, and diffuse color tint)
        for (auto& pair : runtime.materialsByGroup)
        {
            int   matGroup = pair.first;
            auto& matList = pair.second;

            auto matCfgIt = state.materials.find(matGroup);
            bool isGroupActiveInState = (matCfgIt != state.materials.end());

            bool   isOn = false;
            SColor lightColor = SColorRGBA(255, 255, 255, 255);

            if (isGroupActiveInState)
            {
                const SAVSSirenMaterialConfig& matConfig = matCfgIt->second;
                lightColor = matConfig.color;

                if (matConfig.patternTotalTime > 0 && !matConfig.pattern.empty())
                {
                    unsigned long timeInPattern =
                        (elapsedStateTime + static_cast<unsigned long>(matConfig.delay)) % static_cast<unsigned long>(matConfig.patternTotalTime);
                    unsigned long accum = 0;
                    int           sliceIndex = 0;
                    for (size_t i = 0; i < matConfig.pattern.size(); ++i)
                    {
                        accum += static_cast<unsigned long>(matConfig.pattern[i]);
                        if (timeInPattern < accum)
                        {
                            sliceIndex = static_cast<int>(i);
                            break;
                        }
                    }
                    isOn = (sliceIndex % 2 == 0);
                }
                else
                {
                    isOn = true;
                }
            }

            for (auto& info : matList)
            {
                if (!info.pMaterial)
                    continue;

                if (isOn)
                {
                    // Swapping to illuminated texture (sirenlighton), boosting ambient lighting to 4.0f for self-illumination glow, and applying diffuse color
                    info.pMaterial->texture = info.pActiveTexture;
                    info.pMaterial->lighting.ambient = 4.0f;
                    info.pMaterial->color.r = lightColor.R;
                    info.pMaterial->color.g = lightColor.G;
                    info.pMaterial->color.b = lightColor.B;
                    info.pMaterial->color.a = 255;
                }
                else
                {
                    // Reverting to dark unlit texture (sirenlight) and standard ambient lighting
                    info.pMaterial->texture = info.pOriginalTexture;
                    info.pMaterial->lighting.ambient = info.originalAmbient;
                    info.pMaterial->color = info.originalColor;
                }
            }
        }

        for (const auto& matPair : state.materials)
        {
            int                            matGroup = matPair.first;
            const SAVSSirenMaterialConfig& matConfig = matPair.second;

            // Check flash pattern on/off state
            bool isLightOn = true;
            if (matConfig.patternTotalTime > 0 && !matConfig.pattern.empty())
            {
                unsigned long timeInPattern =
                    (elapsedStateTime + static_cast<unsigned long>(matConfig.delay)) % static_cast<unsigned long>(matConfig.patternTotalTime);
                unsigned long accum = 0;
                int           sliceIndex = 0;

                for (size_t i = 0; i < matConfig.pattern.size(); ++i)
                {
                    accum += static_cast<unsigned long>(matConfig.pattern[i]);
                    if (timeInPattern < accum)
                    {
                        sliceIndex = static_cast<int>(i);
                        break;
                    }
                }

                // In AVS: even slices (0, 2, 4...) are ON, odd slices (1, 3, 5...) are OFF
                isLightOn = (sliceIndex % 2 == 0);
            }

            if (!isLightOn)
                continue;

            auto dummyGroupIt = runtime.dummiesByGroup.find(matGroup);
            if (dummyGroupIt == runtime.dummiesByGroup.end())
                continue;

            int dummyIdx = 0;
            for (const auto& dummy : dummyGroupIt->second)
            {
                dummyIdx++;

                float dummyAngle = vehicleAngle + dummy.baseAngle;

                // Handle 360 rotators matching original AVS formula: angle = (elapsed / Time) * Radius
                if (matConfig.type == EAVSSirenType::Rotator && matConfig.rotator.time > 0)
                {
                    float sweep =
                        (static_cast<float>(elapsedStateTime % matConfig.rotator.time) / static_cast<float>(matConfig.rotator.time)) * matConfig.rotator.radius;

                    if (matConfig.rotator.direction == EAVSRotatorDirection::CounterClockwise)
                        sweep = 360.0f - sweep;
                    else if (matConfig.rotator.direction == EAVSRotatorDirection::Switch)
                        sweep = matConfig.rotator.offset + (360.0f - sweep);

                    dummyAngle += sweep;
                    while (dummyAngle > 360.0f)
                        dummyAngle -= 360.0f;
                    while (dummyAngle < 0.0f)
                        dummyAngle += 360.0f;
                }
                else if (matConfig.type == EAVSSirenType::Inversed)
                {
                    dummyAngle -= 180.0f;
                }

                // Unique per-dummy corona identifier matching AVS
                unsigned int coronaId = (reinterpret_cast<unsigned int>(pVehicleInterface) * 255) + 255 + (matGroup * 16) + dummyIdx;

                SColor lightColor = dummy.hasOverrideColor ? dummy.overrideColor : matConfig.color;

                if (matConfig.type == EAVSSirenType::NonDirectional)
                {
                    // Non-directional corona renders from all angles
                    reinterpret_cast<RegisterCorona_t>(FUNC_CCoronas_RegisterCorona)(coronaId, pVehicleInterface, lightColor.R, lightColor.G, lightColor.B,
                                                                                     lightColor.A, dummy.localPos, matConfig.size, pConfig->streamDistance,
                                                                                     nullptr, 0, 0, 0, 0, 0.0f, false, 0.5f, false, 100.0f, false, false);
                }
                else
                {
                    // Directional TIR corona with angle culling and edge falloff
                    RenderCoronaWithAngle(pVehicleInterface, coronaId, cameraAngle, dummyAngle, matConfig.radius, pConfig->inertiaAngle,
                                          pConfig->inertiaEnabled, lightColor.R, lightColor.G, lightColor.B, lightColor.A, dummy.localPos, matConfig.size,
                                          pConfig->streamDistance);
                }

                // Ground light reflection (siren shadow projection) matching original AVS enableShadow
                bool customShadowsDisabled = false;
                bool elemShadowVal = true;
                if (pVehicle->GetCustomDataBool("avs:shadows", elemShadowVal, false) && !elemShadowVal)
                    customShadowsDisabled = true;

                if (m_bShadowsEnabled && runtime.shadowsEnabled && !customShadowsDisabled)
                {
                    RwTexture* pShadowTex = *reinterpret_cast<RwTexture**>(VAR_gpShadowHeadLightsTex);
                    if (!pShadowTex)
                        pShadowTex = *reinterpret_cast<RwTexture**>(VAR_gpShadowExplosionTex);
                    if (!pShadowTex)
                        pShadowTex = *reinterpret_cast<RwTexture**>(VAR_gpShadowCarTex);

                    if (pShadowTex)
                    {
                        float shadowOffset = matConfig.shadow.offset;
                        float shadowSize = (matConfig.shadow.size > 0.0f) ? matConfig.shadow.size : (matConfig.size * 3.5f);

                        float   radDummy = (90.0f - dummyAngle) * (3.14159265f / 180.0f);
                        CVector localShadowPos(dummy.localPos.fX + (shadowOffset * std::cos(radDummy)),
                                               dummy.localPos.fY + ((0.5f + shadowOffset) * std::sin(radDummy)), dummy.localPos.fZ);

                        CMatrix vehMatrix;
                        pVehicle->GetMatrix(vehMatrix);
                        CVector worldCenter = vehMatrix.TransformVector(localShadowPos);

                        float fAngle = (vehicleAngle + dummy.baseAngle + 180.0f) * (3.14159265f / 180.0f);
                        float upX = -std::sin(fAngle) * shadowSize;
                        float upY = std::cos(fAngle) * shadowSize;
                        float rightX = std::cos(fAngle) * shadowSize;
                        float rightY = std::sin(fAngle) * shadowSize;

                        short intensity = static_cast<short>(lightColor.A);

                        reinterpret_cast<StoreShadowToBeRendered_t>(FUNC_CShadows_StoreShadowToBeRendered)(
                            2,  // SHADOW_ADDITIVE (light reflection projection on road and buildings)
                            pShadowTex, &worldCenter, upX, upY, rightX, rightY, intensity, lightColor.R, lightColor.G, lightColor.B,
                            4.0f,     // zDistance downward
                            false,    // drawOnWater
                            1.0f,     // scale
                            nullptr,  // shadowData
                            true      // drawOnBuildings
                        );
                    }
                }
            }
        }
    }
}
