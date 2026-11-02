import { useEffect, useState } from 'react'
import { useI18n } from '../i18n'
import type { MenuIdentity } from '../menuBridge'
import { playUiSound } from '../uiSound'
import './BottomNavBar.css'

export type NavItemKey =
  | 'reconnect'
  | 'resume'
  | 'servers'
  | 'host-game'
  | 'map-editor'
  | 'disconnect'
  | 'settings'
  | 'updates'
  | 'about'
  | 'quit'

interface BottomNavBarProps {
  currentView: 'main-menu' | 'server-browser' | 'settings' | 'updates'
  inGame: boolean
  identity?: MenuIdentity
  recentServerName?: string | null
  onNavigate: (key: NavItemKey) => void
  onIdentity?: () => void
}

function DiscordIcon() {
  return (
    <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" fill="currentColor">
      <path d="M19.5 5.4a16 16 0 0 0-4-1.3l-.5 1a14.8 14.8 0 0 0-6 0l-.5-1a16 16 0 0 0-4 1.3C2 9.1 1.3 12.7 1.6 16.2a16.4 16.4 0 0 0 4.9 2.5l1.2-1.7a10.7 10.7 0 0 1-1.9-.9l.5-.4a11.5 11.5 0 0 0 11.4 0l.5.4a11 11 0 0 1-1.9.9l1.2 1.7a16.4 16.4 0 0 0 4.9-2.5c.4-4.1-.8-7.6-2.9-10.8ZM8.5 14.5c-1.1 0-2-1-2-2.2s.9-2.2 2-2.2 2 1 2 2.2-.9 2.2-2 2.2Zm7 0c-1.1 0-2-1-2-2.2s.9-2.2 2-2.2 2 1 2 2.2-.9 2.2-2 2.2Z" />
    </svg>
  )
}

export function BottomNavBar({
  currentView,
  inGame,
  identity,
  recentServerName,
  onNavigate,
  onIdentity,
}: BottomNavBarProps) {
  const { t } = useI18n()

  const navItems: Array<{ id: NavItemKey; label: string; active?: boolean }> = inGame
    ? [
        { id: 'resume', label: t('main.resumeGame'), active: currentView === 'main-menu' },
        { id: 'servers', label: t('main.browseServers'), active: currentView === 'server-browser' },
        { id: 'settings', label: t('common.settings'), active: currentView === 'settings' },
        { id: 'disconnect', label: t('common.disconnect') },
        { id: 'quit', label: t('main.quitGame') },
      ]
    : [
        {
          id: 'reconnect',
          label: recentServerName ? `RECONNECT` : t('main.quickConnect'),
        },
        {
          id: 'servers',
          label: t('main.browseServers'),
          active: currentView === 'server-browser',
        },
        { id: 'host-game', label: 'HOST GAME' },
        { id: 'map-editor', label: t('main.mapEditor') },
        { id: 'settings', label: t('common.settings'), active: currentView === 'settings' },
        { id: 'updates', label: 'UPDATES', active: currentView === 'updates' },
        { id: 'about', label: t('common.about') },
        { id: 'quit', label: t('main.quitGame') },
      ]

  const [hoveredIndex, setHoveredIndex] = useState<number | null>(null)

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      // Don't intercept if user is typing in an input
      if (['INPUT', 'TEXTAREA'].includes((e.target as HTMLElement)?.tagName)) return

      if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
        e.preventDefault()
        const activeIdx = navItems.findIndex((it) => it.active)
        const currentIdx = hoveredIndex !== null ? hoveredIndex : activeIdx >= 0 ? activeIdx : 0
        const dir = e.key === 'ArrowRight' ? 1 : -1
        const nextIdx = (currentIdx + dir + navItems.length) % navItems.length
        setHoveredIndex(nextIdx)
        playUiSound('highlight')
      } else if (e.key === 'Enter' && hoveredIndex !== null) {
        e.preventDefault()
        const it = navItems[hoveredIndex]
        if (it) {
          playUiSound('select')
          onNavigate(it.id)
        }
      }
    }

    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [hoveredIndex, navItems, onNavigate])

  return (
    <footer className="bottom-nav-bar" role="navigation" aria-label="Main menu navigation bar">
      <div className="bottom-nav-bar__left">
        {identity && onIdentity && (
          <button
            type="button"
            className={`bottom-nav-bar__identity${identity.authenticated ? ' bottom-nav-bar__identity--connected' : ''}`}
            title={identity.authenticated ? identity.displayName : t('main.discordLink')}
            onClick={() => {
              playUiSound('select')
              onIdentity()
            }}
          >
            <span className="bottom-nav-bar__identity-icon">
              <DiscordIcon />
            </span>
            <span className="bottom-nav-bar__identity-status">
              <span className={`bottom-nav-bar__status-dot${identity.authenticated ? ' bottom-nav-bar__status-dot--online' : ''}`} />
              <span className="bottom-nav-bar__identity-name">
                {identity.authenticated ? identity.displayName : t('main.identity')}
              </span>
            </span>
          </button>
        )}
      </div>

      <nav className="bottom-nav-bar__items">
        {navItems.map((item, idx) => {
          const isSelected = item.active || hoveredIndex === idx
          return (
            <button
              key={item.id}
              type="button"
              className={`bottom-nav-bar__item${item.active ? ' bottom-nav-bar__item--active' : ''}${isSelected ? ' bottom-nav-bar__item--selected' : ''}`}
              onMouseEnter={() => {
                if (hoveredIndex !== idx) {
                  setHoveredIndex(idx)
                  playUiSound('highlight')
                }
              }}
              onMouseLeave={() => setHoveredIndex(null)}
              onClick={() => {
                playUiSound('select')
                onNavigate(item.id)
              }}
            >
              <span className="bottom-nav-bar__label">{item.label}</span>
              {item.active && <span className="bottom-nav-bar__indicator" />}
            </button>
          )
        })}
      </nav>
    </footer>
  )
}
