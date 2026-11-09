import { useCallback, useEffect, useRef, useState } from 'react'
import { Header } from './components/Header'
import { AmbientLighting } from './components/AmbientLighting'
import { BottomNavBar, type NavItemKey } from './components/BottomNavBar'
import { useI18n } from './i18n'
import { chooseLaunchLoadscreen } from './loadscreen'
import { backend } from './backend'
import { actions, type NetworkStats } from './store'
import type { ServerItem } from './types'
import { notifyMenuVisualReady, type MenuFeaturedServer, type MenuIdentity, type MenuLanguage } from './menuBridge'
import {
  findNeonRelease,
  formatReleaseVersion,
  LATEST_NEON_RELEASE,
  type NeonRelease,
} from './releaseNotes'
import { playUiSound } from './uiSound'
import { IconPlay } from './components/Icons'
import { cleanGameMode, cleanMapName, cleanServerName, cleanServerText } from './textSanitizer'
import './MainMenu.css'

interface MainMenuProps {
  buildNumber: number
  inGame: boolean
  identity: MenuIdentity
  featuredServer: MenuFeaturedServer | null
  locale: string
  languages: readonly MenuLanguage[]
  onBrowseServers: () => void
  onResume: () => void
  onDisconnect: () => void
  onQuickConnect: () => void
  onMapEditor: () => void
  onSettings: () => void
  onAbout: () => void
  onUpdates: () => void
  onIdentity: () => void
  onPlayFeatured: () => void
  onLanguage: (locale: string) => void
  onQuit: () => void
}

const UPDATE_PROMPT_STORAGE_KEY = 'neon:last-seen-update'

function shouldShowUpdatePrompt(release: NeonRelease): boolean {
  if (new URLSearchParams(window.location.search).has('shownews')) return true
  try {
    return window.localStorage.getItem(UPDATE_PROMPT_STORAGE_KEY) !== String(release.build)
  } catch {
    return true
  }
}

function rememberUpdatePrompt(release: NeonRelease): void {
  try {
    window.localStorage.setItem(UPDATE_PROMPT_STORAGE_KEY, String(release.build))
  } catch {
    // Ignore read-only storage errors
  }
}

function getFeaturedBanner(server: ServerItem | null): string {
  if (!server) return chooseLaunchLoadscreen()
  if (server.bannerUrl) return server.bannerUrl
  let hash = 0
  const str = server.id || server.name
  for (let i = 0; i < str.length; i++) {
    hash = (hash << 5) - hash + str.charCodeAt(i)
    hash |= 0
  }
  return `./loadscreens/loadsc${(Math.abs(hash) % 14) + 1}.webp`
}

export function MainMenu(props: MainMenuProps) {
  const { t } = useI18n()
  const [currentBg, setCurrentBg] = useState(() => chooseLaunchLoadscreen())
  const [incomingBg, setIncomingBg] = useState<string | null>(null)
  const [isCrossFading, setIsCrossFading] = useState(false)
  const [artReady, setArtReady] = useState(true)
  const [showUpdatePrompt, setShowUpdatePrompt] = useState(false)
  const [stats, setStats] = useState<NetworkStats>({ playersOnline: 0, peakPlayers: 0, serverCount: 0 })
  const [recentServer, setRecentServer] = useState<ServerItem | null>(null)
  const [featuredServers, setFeaturedServers] = useState<ServerItem[]>([])
  const [featuredIndex, setFeaturedIndex] = useState(0)
  const visualReadySent = useRef(false)
  const updatePromptChecked = useRef(false)

  const forceUpdatePrompt = new URLSearchParams(window.location.search).has('shownews')
  const updateRelease =
    findNeonRelease(props.buildNumber) ??
    (props.buildNumber === 0 || forceUpdatePrompt || typeof window.mta?.triggerEvent !== 'function'
      ? LATEST_NEON_RELEASE
      : undefined)

  // Periodic background changing every 15 seconds with smooth Ken Burns panning and cross-fade
  useEffect(() => {
    if (props.inGame) return
    const interval = setInterval(() => {
      const nextNum = Math.floor(Math.random() * 14) + 1
      const nextPath = `./loadscreens/loadsc${nextNum}.webp`
      setIncomingBg(nextPath)
      setIsCrossFading(true)

      const timer = setTimeout(() => {
        setCurrentBg(nextPath)
        setIncomingBg(null)
        setIsCrossFading(false)
      }, 2000)

      return () => clearTimeout(timer)
    }, 16000)

    return () => clearInterval(interval)
  }, [props.inGame])

  // Fetch real dynamic stats, recent history, and populate random featured servers pool
  useEffect(() => {
    let active = true
    void backend.getNetworkStats().then((data) => {
      if (active && data) setStats(data)
    })
    void backend.getHistory().then((history) => {
      if (active && history.length > 0) setRecentServer(history[0] ?? null)
    })
    void backend.getServers('internet').then((servers) => {
      if (!active || !servers.length) return
      const online = servers.filter((s) => s.scanState !== 'offline')
      const pool = online.length > 0 ? online : servers

      const withBanner = pool.filter((s) => Boolean(s.bannerUrl))
      const withoutBanner = pool.filter((s) => !s.bannerUrl)

      const shuffle = <T,>(arr: T[]): T[] => [...arr].sort(() => Math.random() - 0.5)
      const selected = [...shuffle(withBanner), ...shuffle(withoutBanner)].slice(0, 5)

      if (selected.length > 0) {
        setFeaturedServers(selected)
        setFeaturedIndex(0)
      }
    })
    return () => {
      active = false
    }
  }, [])

  // Auto rotate featured server every 8 seconds
  useEffect(() => {
    if (featuredServers.length <= 1) return
    const timer = setInterval(() => {
      setFeaturedIndex((prev) => (prev + 1) % featuredServers.length)
    }, 8000)
    return () => clearInterval(timer)
  }, [featuredServers.length])

  const dismissUpdatePrompt = useCallback(() => {
    if (updateRelease) rememberUpdatePrompt(updateRelease)
    setShowUpdatePrompt(false)
  }, [updateRelease])

  useEffect(() => {
    if (props.inGame) {
      setShowUpdatePrompt(false)
      return
    }
    if (!artReady || !updateRelease || updatePromptChecked.current) return
    updatePromptChecked.current = true
    setShowUpdatePrompt(shouldShowUpdatePrompt(updateRelease))
  }, [artReady, props.inGame, updateRelease])

  useEffect(() => {
    if (visualReadySent.current || (!props.inGame && !artReady)) return

    let cancelled = false
    let firstFrame = 0
    let secondFrame = 0
    let animationTimer = 0
    const notifyAfterPaint = () => {
      firstFrame = window.requestAnimationFrame(() => {
        secondFrame = window.requestAnimationFrame(() => {
          if (cancelled || visualReadySent.current) return
          visualReadySent.current = true
          notifyMenuVisualReady()
        })
      })
    }

    const fontsReady = document.fonts.ready.then(() => undefined, () => undefined)
    const animationReady = props.inGame
      ? Promise.resolve()
      : new Promise<void>((resolve) => {
          animationTimer = window.setTimeout(resolve, 190)
        })
    void Promise.all([fontsReady, animationReady]).then(notifyAfterPaint)
    return () => {
      cancelled = true
      window.clearTimeout(animationTimer)
      window.cancelAnimationFrame(firstFrame)
      window.cancelAnimationFrame(secondFrame)
    }
  }, [artReady, props.inGame])

  const onBottomNav = useCallback(
    (key: NavItemKey) => {
      switch (key) {
        case 'servers':
          props.onBrowseServers()
          break
        case 'reconnect':
          if (recentServer) {
            actions.connectTo(recentServer)
          } else {
            props.onQuickConnect()
          }
          break
        case 'resume':
          props.onResume()
          break
        case 'host-game':
          props.onQuickConnect()
          break
        case 'map-editor':
          props.onMapEditor()
          break
        case 'settings':
          props.onSettings()
          break
        case 'updates':
          props.onUpdates()
          break
        case 'about':
          props.onAbout()
          break
        case 'disconnect':
          props.onDisconnect()
          break
        case 'quit':
          props.onQuit()
          break
      }
    },
    [props, recentServer],
  )

  const activeFeaturedServer: ServerItem | null =
    featuredServers.length > 0 ? featuredServers[featuredIndex] ?? null : null

  const featuredServerName = activeFeaturedServer
    ? cleanServerName(activeFeaturedServer.name)
    : props.featuredServer?.name || 'San Andreas Online'

  const featuredServerDesc = activeFeaturedServer
    ? cleanServerText(activeFeaturedServer.description || activeFeaturedServer.tagline) ||
      `${cleanGameMode(activeFeaturedServer.gameMode)} • ${cleanMapName(activeFeaturedServer.map)} • ${activeFeaturedServer.players}/${activeFeaturedServer.maxPlayers} Players`
    : props.featuredServer?.tagline ||
      'Top multiplayer server with high-action freeroam, custom races, and missions.'

  const handlePlayFeatured = useCallback(() => {
    playUiSound('select')
    if (activeFeaturedServer) {
      actions.connectTo(activeFeaturedServer)
    } else if (props.featuredServer) {
      props.onPlayFeatured()
    } else {
      props.onBrowseServers()
    }
  }, [activeFeaturedServer, props])

  return (
    <main className={`main-menu${props.inGame ? ' main-menu--ingame' : ''}`}>
      {/* Background artwork with Ken Burns animation and smooth cross-fade */}
      {!props.inGame && (
        <div className="main-menu__art" aria-hidden="true">
          <div className="main-menu__scene-layer main-menu__scene-layer--current">
            <img
              className="main-menu__scene"
              src={currentBg}
              alt=""
              draggable={false}
              fetchPriority="high"
              onLoad={() => setArtReady(true)}
              onError={() => setArtReady(true)}
            />
          </div>
          {incomingBg && (
            <div
              className={`main-menu__scene-layer main-menu__scene-layer--incoming ${isCrossFading ? 'is-fading' : ''}`}
            >
              <img
                className="main-menu__scene"
                src={incomingBg}
                alt=""
                draggable={false}
              />
            </div>
          )}
        </div>
      )}
      <div className="main-menu__wash" aria-hidden="true" />
      <AmbientLighting />

      {/* Header with Brand Logo, Live Player Counts, and Language Selector */}
      <Header
        title="San Andreas Online"
        subtitle="Grand Theft Auto: San Andreas™ © 2005 Rockstar Games, Inc."
        variant="brand"
        stats={stats.playersOnline > 0 || stats.serverCount > 0 ? stats : undefined}
        locale={props.locale}
        languages={props.languages}
        onLanguageSelect={props.onLanguage}
      />

      {/* Main Center Area: Featured Server Showcase + Color Strip + Last Played */}
      <section className="main-menu__showcase" aria-label={t('aria.mainMenu')}>
        <div className="main-menu__featured-container">
          <div className="main-menu__featured-eyebrow-row">
            <h2 className="main-menu__featured-eyebrow">
              {t('main.featuredServer').toUpperCase()}
            </h2>
          </div>

          <div
            className="main-menu__featured-card"
            onClick={handlePlayFeatured}
          >
            <img
              className="main-menu__card-banner"
              src={getFeaturedBanner(activeFeaturedServer)}
              alt={featuredServerName}
              draggable={false}
              onError={(e) => {
                const target = e.currentTarget
                const fallback = chooseLaunchLoadscreen()
                if (!target.src.endsWith(fallback.replace('./', ''))) {
                  target.src = fallback
                }
              }}
            />
            <div className="main-menu__card-shade" />

            {/* Pagination indicator pills */}
            <div className="main-menu__carousel-pills" aria-hidden="true">
              {(featuredServers.length > 0 ? featuredServers : [0, 1, 2]).map((_, idx) => (
                <span
                  key={idx}
                  className={`main-menu__pill${featuredIndex === idx ? ' main-menu__pill--active' : ''}`}
                  onClick={(e) => {
                    e.stopPropagation()
                    playUiSound('highlight')
                    setFeaturedIndex(idx)
                  }}
                />
              ))}
            </div>

            {/* Server Card Details & Connect Button */}
            <div className="main-menu__card-content">
              <div className="main-menu__card-info">
                {activeFeaturedServer && (
                  <div className="main-menu__card-badge-row">
                    <span className="main-menu__card-badge main-menu__card-badge--mode">
                      {cleanGameMode(activeFeaturedServer.gameMode)}
                    </span>
                    <span className="main-menu__card-badge main-menu__card-badge--players">
                      {activeFeaturedServer.players} / {activeFeaturedServer.maxPlayers} PLAYERS
                    </span>
                    {activeFeaturedServer.ping !== undefined && (
                      <span className="main-menu__card-badge main-menu__card-badge--ping">
                        {activeFeaturedServer.ping} MS
                      </span>
                    )}
                  </div>
                )}
                <strong className="main-menu__card-title">{featuredServerName}</strong>
                <p className="main-menu__card-desc">{featuredServerDesc}</p>
              </div>

              <button
                type="button"
                className="main-menu__card-connect-btn"
                onClick={(e) => {
                  e.stopPropagation()
                  handlePlayFeatured()
                }}
              >
                <IconPlay size={16} />
                <span>{t('common.connect')}</span>
              </button>
            </div>
          </div>

          {/* GTA Multi-color Accent Strip */}
          <div className="main-menu__color-strip" aria-hidden="true" />

          {/* Last Played Bar */}
          <div
            className={`main-menu__last-played${recentServer ? ' main-menu__last-played--clickable' : ''}`}
            onClick={() => {
              if (recentServer) {
                playUiSound('select')
                actions.connectTo(recentServer)
              } else {
                props.onBrowseServers()
              }
            }}
          >
            <span className="main-menu__last-played-label">Last Played</span>
            <span className="main-menu__last-played-name">
              {recentServer
                ? `${cleanServerName(recentServer.name)} — ${cleanGameMode(recentServer.gameMode)} • ${cleanMapName(recentServer.map)}`
                : 'No recent server — click to browse servers'}
            </span>
          </div>
        </div>
      </section>

      {/* Release Notes Dialog if active */}
      {showUpdatePrompt && updateRelease && (
        <div className="main-menu__update-overlay">
          <section
            className="main-menu__update-prompt"
            role="dialog"
            aria-modal="true"
            aria-labelledby="update-prompt-title"
          >
            <header className="main-menu__update-prompt-header">
              <span>What’s new in San Andreas Online</span>
              <small>{formatReleaseVersion(updateRelease)}</small>
            </header>
            <h2 id="update-prompt-title">{updateRelease.title}</h2>
            <p>{updateRelease.summary}</p>
            <ul>
              {updateRelease.highlights.map((highlight) => (
                <li key={highlight}>{highlight}</li>
              ))}
            </ul>
            <footer className="main-menu__update-prompt-actions">
              <button
                type="button"
                className="main-menu__update-prompt-more"
                onClick={() => {
                  dismissUpdatePrompt()
                  playUiSound('select')
                  props.onUpdates()
                }}
              >
                View all changes <span aria-hidden="true">▸</span>
              </button>
              <button
                type="button"
                className="main-menu__update-prompt-dismiss"
                autoFocus
                onClick={() => {
                  playUiSound('back')
                  dismissUpdatePrompt()
                }}
              >
                Got it
              </button>
            </footer>
          </section>
        </div>
      )}

      {/* Global Bottom Navigation Dock */}
      <BottomNavBar
        currentView="main-menu"
        inGame={props.inGame}
        identity={props.identity}
        recentServerName={recentServer?.name ? cleanServerName(recentServer.name) : undefined}
        onNavigate={onBottomNav}
        onIdentity={props.onIdentity}
      />
    </main>
  )
}