/**
 * Text and metadata sanitization utilities for San Andreas Online.
 * Strips binary garbage, ASE protocol packed bytes, replacement characters (diamonds),
 * and color codes from server text fields.
 */

export function cleanServerText(raw?: string | null): string {
  if (!raw) return ''
  // 1. Remove MTA/mIRC hex color codes (#RRGGBB)
  let text = raw.replace(/#([0-9a-fA-F]{6})/g, '')
  // 2. Remove control characters (0-31, 127-159) and replacement character (\uFFFD / diamond '?')
  text = text.replace(/[\u0000-\u001F\u007F-\u009F\uFFFD]/g, '')
  // 3. Normalize multiple whitespace
  return text.trim()
}

export function cleanMapName(raw?: string | null): string {
  if (!raw) return 'San Andreas'
  let text = cleanServerText(raw)

  // ASE extension data handling:
  // MTA ASE server responses often append protocol version/flags after '/'
  // e.g. "San Andreas/335104...", "NONCD/1512..."
  const slashIdx = text.indexOf('/')
  if (slashIdx !== -1) {
    const prefix = text.slice(0, slashIdx).trim()
    // If the part before slash has letters and is a valid map name
    if (prefix.length > 0 && /[a-zA-Z]/.test(prefix)) {
      text = prefix
    } else {
      text = 'San Andreas'
    }
  }

  // Remove any remaining non-standard symbols at the end
  text = text.replace(/[^a-zA-Z0-9_\-\s.+]/g, '').trim()

  return text || 'San Andreas'
}

export function cleanGameMode(raw?: string | null): string {
  if (!raw) return 'Multiplayer'
  let text = cleanServerText(raw)
  // Remove non-standard trailing binary remnants
  text = text.replace(/[^a-zA-Z0-9_\-\s.+]/g, '').trim()
  return text || 'Multiplayer'
}

export function cleanServerName(raw?: string | null): string {
  if (!raw) return 'Multiplayer Server'
  const text = cleanServerText(raw)
  return text || 'Multiplayer Server'
}
