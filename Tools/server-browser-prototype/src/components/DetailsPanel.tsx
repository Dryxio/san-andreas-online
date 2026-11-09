import { useEffect, useRef, useState } from 'react'
import { useI18n } from '../i18n'
import type { ServerItem, ServerPlayer } from '../types'
import { cleanGameMode, cleanMapName, cleanServerName, cleanServerText } from '../textSanitizer'

function serverFallbackArt(id: string): string {
  let hash = 0
  for (let i = 0; i < id.length; i++) {
    hash = (hash << 5) - hash + id.charCodeAt(i)
    hash |= 0
  }
  return `./loadscreens/loadsc${(Math.abs(hash) % 14) + 1}.webp`
}
import { playUiSound } from '../uiSound'
import {
  Flag,
  IconArrowLeft,
  IconAt,
  IconCheck,
  IconCopy,
  IconPlay,
} from './Icons'

interface DetailsPanelProps {
  server: ServerItem | null
  playersViewOpen: boolean
  onOpenPlayers: () => void
  onClosePlayers: () => void
  onConnect: (server: ServerItem) => void
  onCopyLink: (server: ServerItem) => Promise<boolean>
  onOpenLink?: (url: string) => boolean
}

function shortName(name: string): string {
  return name.replace(/\s*\|.*$/, '').trim() || name
}

export function DetailsPanel({
  server,
  playersViewOpen,
  onOpenPlayers,
  onClosePlayers,
  onConnect,
  onCopyLink,
  onOpenLink,
}: DetailsPanelProps) {
  const [copyState, setCopyState] = useState<'idle' | 'copied' | 'failed'>('idle')
  const copyResetTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const copyGeneration = useRef(0)
  const playersButtonRef = useRef<HTMLButtonElement>(null)
  const backButtonRef = useRef<HTMLButtonElement>(null)
  const previousPlayersViewOpen = useRef(playersViewOpen)
  const { formatNumber, t } = useI18n()

  useEffect(() => {
    if (playersViewOpen && !previousPlayersViewOpen.current) backButtonRef.current?.focus()
    if (!playersViewOpen && previousPlayersViewOpen.current) playersButtonRef.current?.focus()
    previousPlayersViewOpen.current = playersViewOpen
  }, [playersViewOpen])

  useEffect(() => {
    copyGeneration.current += 1
    setCopyState('idle')
    if (copyResetTimer.current) clearTimeout(copyResetTimer.current)
    return () => {
      copyGeneration.current += 1
      if (copyResetTimer.current) clearTimeout(copyResetTimer.current)
    }
  }, [server?.id])

  if (!server) {
    return (
      <aside className="sao-details sao-details--empty">
        <p>{t('details.selectServer')}</p>
      </aside>
    )
  }

  const copyAddress = async () => {
    playUiSound('select')
    const generation = ++copyGeneration.current
    const success = await onCopyLink(server)
    if (generation !== copyGeneration.current) return
    setCopyState(success ? 'copied' : 'failed')
    if (!success) playUiSound('error')
    if (copyResetTimer.current) clearTimeout(copyResetTimer.current)
    copyResetTimer.current = setTimeout(() => setCopyState('idle'), 1600)
  }

  const serverAddress = `${server.publicHost || server.ip}:${server.gamePort}`
  const primaryLang = server.languages?.[0] ?? 'English'

  return (
    <aside className="sao-details">
      <div className="sao-details__scroll">
        {playersViewOpen ? (
          <section id="server-player-list" className="players-view" aria-labelledby="players-view-title">
            <button
              ref={backButtonRef}
              type="button"
              className="players-view__back"
              onClick={onClosePlayers}
            >
              <IconArrowLeft size={14} />
              {t('details.backToServerDetails')}
            </button>
            <div className="players-view__heading">
              <span className="players-view__icon" aria-hidden="true">
                <IconAt size={21} />
              </span>
              <div>
                <span className="details__kicker">{shortName(server.name)}</span>
                <h2 id="players-view-title" className="details__title">
                  {t('common.players')} ({formatNumber(server.players)})
                </h2>
              </div>
            </div>
            {server.playerList && server.playerList.length > 0 ? (
              <ul className="players-view__list">
                {server.playerList.map((player: ServerPlayer) => (
                  <li key={`${player.name}-${player.ping}`} className="players-view__row">
                    <span className="players-view__name">{player.name}</span>
                    <span className="players-view__meta">
                      {player.score !== undefined && <span className="players-view__score">{player.score}</span>}
                      {player.ping !== undefined && <span className="players-view__ping">{player.ping} ms</span>}
                    </span>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="players-view__empty">{t('details.noPlayersOnline')}</p>
            )}
          </section>
        ) : (
          <div className="sao-details__content">
            {/* Server Banner Image */}
            <div className="sao-details__banner">
              <img
                src={server.bannerUrl || serverFallbackArt(server.id)}
                alt={cleanServerName(server.name)}
                draggable={false}
                referrerPolicy="no-referrer"
                onError={(e) => {
                  const target = e.currentTarget
                  const fallback = serverFallbackArt(server.id)
                  if (!target.src.endsWith(fallback.replace('./', ''))) {
                    target.src = fallback
                  }
                }}
              />
              <div className="sao-details__banner-gradient" />
            </div>

            {/* Server Header info */}
            <div className="sao-details__header">
              <div className="sao-details__title-row">
                <h2 className="sao-details__name">{cleanServerName(server.name)}</h2>
                <div className="sao-details__lang-tag">
                  {server.country && <Flag country={server.country} />}
                  <span>{primaryLang}</span>
                </div>
              </div>
              <p className="sao-details__desc">
                {cleanServerText(server.description || server.tagline) || 'Experience San Andreas Online multiplayer.'}
              </p>
            </div>

            {/* Action Buttons: Connect & Copy IP */}
            <div className="sao-details__actions">
              <button
                type="button"
                className="sao-btn-connect"
                onClick={() => onConnect(server)}
              >
                <IconPlay size={15} />
                <span>{t('common.connect')}</span>
              </button>

              <button
                type="button"
                className="sao-btn-secondary"
                onClick={copyAddress}
                title={t('details.copyAddress', { address: serverAddress })}
              >
                {copyState === 'copied' ? <IconCheck size={15} /> : <IconCopy size={15} />}
                <span>{copyState === 'copied' ? t('details.copied') : 'Copy IP'}</span>
              </button>
            </div>

            {/* Server Metadata Grid/Table */}
            <div className="sao-details__meta-table">
              <div className="sao-meta-row">
                <span className="sao-meta-label">IP:Port</span>
                <span className="sao-meta-value sao-meta-value--code">{serverAddress}</span>
              </div>

              <div className="sao-meta-row">
                <span className="sao-meta-label">Players</span>
                <span className="sao-meta-value">
                  {formatNumber(server.players)} / {formatNumber(server.maxPlayers)}
                </span>
              </div>

              <div className="sao-meta-row">
                <span className="sao-meta-label">Ping</span>
                <span className="sao-meta-value sao-meta-value--ping">
                  {server.ping !== undefined ? `${server.ping} ms` : '—'}
                </span>
              </div>

              <div className="sao-meta-row">
                <span className="sao-meta-label">Gamemode</span>
                <span className="sao-meta-value">{cleanGameMode(server.gameMode)}</span>
              </div>

              <div className="sao-meta-row">
                <span className="sao-meta-label">Map</span>
                <span className="sao-meta-value">{cleanMapName(server.map)}</span>
              </div>

              <div className="sao-meta-row">
                <span className="sao-meta-label">Version</span>
                <span className="sao-meta-value">{server.version || '1.6'}</span>
              </div>

              <div className="sao-meta-row">
                <span className="sao-meta-label">Language</span>
                <span className="sao-meta-value">
                  {server.languages?.join(', ') || primaryLang}
                </span>
              </div>
            </div>

            {server.links && server.links.length > 0 && onOpenLink && (
              <div className="sao-details__links">
                {server.links.map((link) => (
                  <button
                    key={link.url}
                    type="button"
                    className="sao-btn-players"
                    onClick={() => onOpenLink(link.url)}
                  >
                    <span>{link.label}</span>
                  </button>
                ))}
              </div>
            )}

            {/* Players list button if players exist */}
            {server.players > 0 && (
              <div className="sao-details__footer">
                <button
                  ref={playersButtonRef}
                  type="button"
                  className="sao-btn-players"
                  onClick={onOpenPlayers}
                >
                  <IconAt size={14} />
                  <span>{t('details.viewAllPlayers', { count: formatNumber(server.players) })}</span>
                </button>
              </div>
            )}
          </div>
        )}
      </div>
    </aside>
  )
}
