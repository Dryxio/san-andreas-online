/*****************************************************************************
 *
 *  PROJECT:     Multi Theft Auto v1.0
 *  LICENSE:     See LICENSE in the top level directory
 *  FILE:        mods/deathmatch/logic/CWater.cpp
 *  PURPOSE:     Water entity class
 *
 *  Multi Theft Auto is available from https://www.multitheftauto.com/
 *
 *****************************************************************************/

#include "StdInc.h"
#include "CWater.h"
#include "CWaterManager.h"
#include "CLogger.h"

CWater::CWater(CWaterManager* pWaterManager, CElement* pParent, EWaterType waterType, unsigned char ucFlags) : CElement(pParent)
{
    m_pWaterManager = pWaterManager;

    m_iType = CElement::WATER;
    SetTypeName("water");
    m_WaterType = waterType;

    m_Vertices[0] = CVector(-10.0f, -10.0f, 0.0f);
    m_Vertices[1] = CVector(10.0f, -10.0f, 0.0f);
    m_Vertices[2] = CVector(-10.0f, 10.0f, 0.0f);
    if (m_WaterType == QUAD)
        m_Vertices[3] = CVector(10.0f, 10.0f, 0.0f);

    m_ucFlags = ucFlags;

    if (m_pWaterManager)
        m_pWaterManager->AddToList(this);
}

CWater::~CWater()
{
    Unlink();
}

void CWater::Unlink()
{
    if (m_pWaterManager)
        m_pWaterManager->RemoveFromList(this);
}

const CVector& CWater::GetPosition()
{
    m_vecPosition = CVector(0.0f, 0.0f, 0.0f);
    for (int i = 0; i < GetNumVertices(); i++)
    {
        m_vecPosition += m_Vertices[i];
    }
    m_vecPosition /= static_cast<float>(GetNumVertices());
    return m_vecPosition;
}

void CWater::SetPosition(const CVector& vecPosition)
{
    CVector vecDelta = vecPosition - CWater::GetPosition();
    for (int i = 0; i < GetNumVertices(); i++)
    {
        m_Vertices[i] += vecDelta;
    }
    RoundVertices();
}

float CWater::GetLevel() const
{
    float fLevel = 0.0f;
    for (int i = 0; i < GetNumVertices(); i++)
    {
        fLevel += m_Vertices[i].fZ;
    }
    return fLevel / static_cast<float>(GetNumVertices());
}

void CWater::SetLevel(float fLevel)
{
    for (int i = 0; i < GetNumVertices(); i++)
    {
        m_Vertices[i].fZ = fLevel;
    }
}

bool CWater::ReadSpecialData(const int iLine)
{
    char szPropName[10];
    m_WaterType = QUAD;
    for (int i = 0; i < 4; i++)
    {
        snprintf(szPropName, sizeof(szPropName), "posX%d", i + 1);
        if (!GetCustomDataFloat(szPropName, m_Vertices[i].fX, true))
        {
            if (i == 3)
            {
                m_WaterType = TRIANGLE;
                break;
            }
            else
            {
                CLogger::ErrorPrintf("Bad/missing 'posX%d' attribute in <water> (line %d)\n", i + 1, iLine);
                return false;
            }
        }
        snprintf(szPropName, sizeof(szPropName), "posY%d", i + 1);
        if (!GetCustomDataFloat(szPropName, m_Vertices[i].fY, true))
        {
            if (i == 3)
            {
                m_WaterType = TRIANGLE;
                break;
            }
            else
            {
                CLogger::ErrorPrintf("Bad/missing 'posY%d' attribute in <water> (line %d)\n", i + 1, iLine);
                return false;
            }
        }
        snprintf(szPropName, sizeof(szPropName), "posZ%d", i + 1);
        if (!GetCustomDataFloat(szPropName, m_Vertices[i].fZ, true))
        {
            if (i == 3)
            {
                m_WaterType = TRIANGLE;
                break;
            }
            else
            {
                CLogger::ErrorPrintf("Bad/missing 'posZ%d' attribute in <water> (line %d)\n", i + 1, iLine);
                return false;
            }
        }
    }

    // Map files keep the old shallow="true" attribute (invisible water, as in
    // MTA) and can use flags="0".."3" from water.dat instead, which wins.
    bool bShallow = false;
    if (!GetCustomDataBool("shallow", bShallow, true))
        bShallow = false;
    m_ucFlags = WaterFlags::FromLegacyShallow(bShallow);

    int iFlags;
    if (GetCustomDataInt("flags", iFlags, true))
    {
        if (!WaterFlags::IsValid(iFlags))
        {
            CLogger::ErrorPrintf("Bad 'flags' attribute in <water> (line %d), expected 0 to 3\n", iLine);
            return false;
        }
        m_ucFlags = static_cast<unsigned char>(iFlags);
    }

    RoundVertices();
    if (!Valid())
    {
        CLogger::ErrorPrintf("Invalid <water> element (line %d)\n", iLine);
        return false;
    }
    return true;
}

bool CWater::GetVertex(int index, CVector& vecPosition) const
{
    if (index < 0 || index >= GetNumVertices())
        return false;

    vecPosition = m_Vertices[index];
    return true;
}

void CWater::SetVertex(int index, CVector& vecPosition)
{
    if (index < 0 || index >= GetNumVertices())
        return;

    m_Vertices[index] = vecPosition;
    RoundVertex(index);
}

bool CWater::Valid()
{
    for (int i = 0; i < GetNumVertices(); i++)
    {
        if (!IsVertexWithinWorld(i))
            return false;
    }

    if (m_WaterType == QUAD)
    {
        return m_Vertices[0].fX < m_Vertices[1].fX && m_Vertices[2].fX < m_Vertices[3].fX && m_Vertices[0].fY < m_Vertices[2].fY &&
               m_Vertices[1].fY < m_Vertices[3].fY;
    }
    else
    {
        return m_Vertices[0].fX < m_Vertices[1].fX && (m_Vertices[0].fY < m_Vertices[2].fY) == (m_Vertices[1].fY < m_Vertices[2].fY);
    }
}

void CWater::RoundVertices()
{
    for (int i = 0; i < GetNumVertices(); i++)
    {
        RoundVertex(i);
    }
}

void CWater::RoundVertex(int index)
{
    m_Vertices[index].fX = (float)((int)m_Vertices[index].fX & ~1);
    m_Vertices[index].fY = (float)((int)m_Vertices[index].fY & ~1);
}

bool CWater::IsVertexWithinWorld(int index)
{
    constexpr float extendedWaterMinCoord = -10000.0f;
    constexpr float extendedWaterMaxEntityCoord = 9999.0f;
    return m_Vertices[index].fX >= extendedWaterMinCoord && m_Vertices[index].fX <= extendedWaterMaxEntityCoord &&
           m_Vertices[index].fY >= extendedWaterMinCoord && m_Vertices[index].fY <= extendedWaterMaxEntityCoord;
}
