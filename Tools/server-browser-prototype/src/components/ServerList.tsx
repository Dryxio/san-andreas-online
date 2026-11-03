import { memo, useCallback, useEffect, useRef, useState, type CSSProperties } from 'react'
import { useI18n } from '../i18n'
import type { ServerItem } from '../types'
import { cleanGameMode, cleanMapName, cleanServerName } from '../textSanitizer'
import { Flag, IconLock, IconPlay, IconStar, IconStarFilled } from './Icons'

const ROW_HEIGHT = 88
const ROW_GAP = 8
const STRIDE = ROW_HEIGHT + ROW_GAP
const VIRTUALIZATION_THRESHOLD = 30
const OVERSCAN = 4

function visibleWindow(scrollTop: number, viewport: number, serverCount: number) {
  return {
    first: Math.max(0, Math.floor(scrollTop / STRIDE) - OVERSCAN),
    last: Math.min(serverCount, Math.ceil((scrollTop + viewport) / STRIDE) + OVERSCAN),
  }
}

interface ServerListProps {
  servers: readonly ServerItem[]
  selectedId: string | null
  directTarget: string | null
  onSelect: (id: string) => void
  onJoin: (server: ServerItem) => void
  onToggleFavourite: (server: ServerItem) => void
}

function serverCountries(server: ServerItem): string[] {
  if (server.countries?.length) return server.countries
  return server.country ? [server.country] : []
}

function serverInitials(name: string): string {
  const words = name.replace(/[^\p{L}\p{N}]+/gu, ' ').trim().split(/\s+/)
  return words.slice(0, 2).map((word) => word[0]).join('').toUpperCase() || 'SA'
}

const Row = memo(function Row({
  server,
  top,
  flow,
  selected,
  onSelect,
  onJoin,
  onToggleFavourite,
}: {
  server: ServerItem
  top?: number
  flow?: boolean
  selected: boolean
  onSelect: (id: string) => void
  onJoin: (server: ServerItem) => void
  onToggleFavourite: (server: ServerItem) => void
}) {
  const { formatNumber, t } = useI18n()
  const offline = server.scanState === 'offline'

  const pingClass =
    server.ping !== undefined
      ? server.ping < 70
        ? 'sao-ping--good'
        : server.ping < 160
          ? 'sao-ping--medium'
          : 'sao-ping--high'
      : ''

  return (
    <div
      className={`sao-server-card${flow ? ' sao-server-card--flow' : ''}${selected ? ' sao-server-card--selected' : ''}${server.isFeatured ? ' sao-server-card--featured' : ''}${offline ? ' sao-server-card--offline' : ''}`}
      style={top === undefined ? undefined : { top }}
      onClick={() => onSelect(server.id)}
      onDoubleClick={() => onJoin(server)}
      role="row"
      aria-selected={selected}
    >
      <div className="sao-server-card__left">
        <span
          className="sao-server-card__logo"
          style={{ '--server-accent': server.accent ?? '#ffbb4e' } as CSSProperties}
          aria-hidden="true"
        >
          <span className="sao-server-card__initials">{serverInitials(server.name)}</span>
          {server.logoUrl && (
            <img
              src={server.logoUrl}
              alt=""
              draggable={false}
              referrerPolicy="no-referrer"
              onError={(e) => {
                e.currentTarget.style.display = 'none'
              }}
            />
          )}
        </span>

        <div className="sao-server-card__body">
          <div className="sao-server-card__title-row">
            <span className="sao-server-card__name">{cleanServerName(server.name)}</span>
            {server.passworded && (
              <span className="sao-server-card__lock" title={t('server.passwordProtected')}>
                <IconLock size={13} />
              </span>
            )}
            {server.isFeatured && (
              <span className="sao-server-card__featured-badge">{t('server.featured')}</span>
            )}
          </div>
          <div className="sao-server-card__sub-row">
            <span className="sao-server-card__mode">{cleanGameMode(server.gameMode)}</span>
            <span className="sao-server-card__divider">•</span>
            <span className="sao-server-card__map">{cleanMapName(server.map)}</span>
          </div>
        </div>
      </div>

      <div className="sao-server-card__right">
        <span className="sao-server-card__countries">
          {serverCountries(server).map((country) => (
            <Flag key={country} country={country} />
          ))}
        </span>

        <button
          type="button"
          className={`sao-server-card__star${server.isFavourite ? ' sao-server-card__star--active' : ''}`}
          title={server.isFavourite ? t('server.removeFavourite') : t('server.addFavourite')}
          onClick={(e) => {
            e.stopPropagation()
            onToggleFavourite(server)
          }}
        >
          {server.isFavourite ? <IconStarFilled size={16} /> : <IconStar size={16} />}
        </button>

        <div className="sao-server-card__stats">
          <span className="sao-server-card__players">
            {offline ? '—' : `${formatNumber(server.players)} / ${formatNumber(server.maxPlayers)}`}
          </span>
          <span className={`sao-server-card__ping ${pingClass}`}>
            {offline ? t('server.offline') : server.ping !== undefined ? `${server.ping} ms` : '…'}
          </span>
        </div>

        <button
          type="button"
          className="sao-server-card__connect-btn"
          title={t('common.connect')}
          onClick={(e) => {
            e.stopPropagation()
            onJoin(server)
          }}
        >
          <IconPlay size={13} />
          <span>{t('common.connect')}</span>
        </button>
      </div>
    </div>
  )
})

export const ServerList = memo(function ServerList(props: ServerListProps) {
  const { t } = useI18n()
  const scrollRef = useRef<HTMLDivElement>(null)
  const serverCountRef = useRef(props.servers.length)
  serverCountRef.current = props.servers.length
  const [visibleRange, setVisibleRange] = useState(() => visibleWindow(0, 600, props.servers.length))

  const updateVisibleWindow = useCallback((el: HTMLDivElement) => {
    const next = visibleWindow(el.scrollTop, el.clientHeight, serverCountRef.current)
    setVisibleRange((current) => current.first === next.first && current.last === next.last ? current : next)
  }, [])

  useEffect(() => {
    const el = scrollRef.current
    if (!el) return
    const observer = new ResizeObserver(() => updateVisibleWindow(el))
    observer.observe(el)
    updateVisibleWindow(el)
    return () => observer.disconnect()
  }, [updateVisibleWindow])

  useEffect(() => {
    const el = scrollRef.current
    if (el) updateVisibleWindow(el)
  }, [props.servers.length, updateVisibleWindow])

  const totalHeight = props.servers.length * STRIDE
  const useVirtual = props.servers.length > VIRTUALIZATION_THRESHOLD
  const renderedServers = useVirtual
    ? props.servers.slice(visibleRange.first, visibleRange.last)
    : props.servers

  return (
    <div
      ref={scrollRef}
      className="sao-server-list"
      role="feed"
      aria-label={t('aria.serverList')}
      onScroll={(e) => updateVisibleWindow(e.currentTarget)}
    >
      {props.servers.length === 0 ? (
        <div className="sao-server-list__empty">
          <p>{t('browser.empty')}</p>
          <small>{t('browser.emptyHint')}</small>
        </div>
      ) : useVirtual ? (
        <div className="sao-server-list__canvas" style={{ height: totalHeight }}>
          {renderedServers.map((server, index) => {
            const actualIndex = visibleRange.first + index
            return (
              <Row
                key={server.id}
                server={server}
                top={actualIndex * STRIDE}
                selected={server.id === props.selectedId}
                onSelect={props.onSelect}
                onJoin={props.onJoin}
                onToggleFavourite={props.onToggleFavourite}
              />
            )
          })}
        </div>
      ) : (
        <div className="sao-server-list__flow">
          {props.servers.map((server) => (
            <Row
              key={server.id}
              server={server}
              flow
              selected={server.id === props.selectedId}
              onSelect={props.onSelect}
              onJoin={props.onJoin}
              onToggleFavourite={props.onToggleFavourite}
            />
          ))}
        </div>
      )}
    </div>
  )
})
