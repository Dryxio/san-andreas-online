import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { DetailsPanel } from './components/DetailsPanel'
import { Header } from './components/Header'
import { ServerList } from './components/ServerList'
import { StatusBar } from './components/StatusBar'
import { Toolbar } from './components/Toolbar'
import { AmbientLighting } from './components/AmbientLighting'
import { BottomNavBar, type NavItemKey } from './components/BottomNavBar'
import { visibleServers } from './search'
import { actions, useBrowserState } from './store'
import { chooseLaunchLoadscreen } from './loadscreen'
import { formatNeonServerLink, parseServerAddress } from './types'
import { playUiSound } from './uiSound'
import { useI18n } from './i18n'

export function App() {
  const { t } = useI18n()
  const state = useBrowserState()
  const searchRef = useRef<HTMLInputElement>(null)
  const hasInitialSelection = useRef(false)
  const [loadscreen] = useState(chooseLaunchLoadscreen)
  const [playersViewServerId, setPlayersViewServerId] = useState<string | null>(null)

  useEffect(() => {
    actions.resume()
    void actions.init()
    return actions.suspend
  }, [])

  const directAddress = useMemo(() => parseServerAddress(state.query), [state.query])
  const directTarget = directAddress ? formatNeonServerLink(directAddress) : null
  const servers = useMemo(
    () => visibleServers([...state.servers.values()], directAddress ? '' : state.query, state.filters),
    [directAddress, state.servers, state.query, state.filters],
  )

  const selected = state.selectedId ? (state.servers.get(state.selectedId) ?? null) : null
  const playersViewOpen = selected !== null && playersViewServerId === selected.id

  useEffect(() => {
    if (!directAddress) return
    const matchingServer = [...state.servers.values()].find(
      (server) =>
        (server.ip.toLowerCase() === directAddress.ip || server.publicHost === directAddress.ip) &&
        server.gamePort === directAddress.port,
    )
    if (matchingServer && matchingServer.id !== state.selectedId) actions.select(matchingServer.id)
  }, [directAddress, state.selectedId, state.servers])

  useEffect(() => {
    if (!state.selectedId) return
    if (hasInitialSelection.current) playUiSound('highlight')
    else hasInitialSelection.current = true
  }, [state.selectedId])

  useEffect(() => {
    if (playersViewServerId !== null && playersViewServerId !== state.selectedId) setPlayersViewServerId(null)
  }, [playersViewServerId, state.selectedId])

  const connectFromToolbar = useCallback(() => {
    if (directAddress) actions.connectToAddress(directAddress)
    else if (selected) actions.connectTo(selected)
  }, [directAddress, selected])

  const joinServer = useCallback((server: Parameters<typeof actions.connectTo>[0]) => {
    playUiSound('select')
    actions.connectTo(server)
  }, [])

  const toggleFavourite = useCallback((server: Parameters<typeof actions.toggleFavourite>[0]) => {
    playUiSound('select')
    actions.toggleFavourite(server)
  }, [])

  // Keyboard navigation
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (state.connect.phase !== 'idle') {
        if (e.key === 'Escape') {
          actions.dismissConnect()
        }
        return
      }
      if (playersViewOpen) {
        if (e.key === 'Escape') {
          e.preventDefault()
          playUiSound('back')
          setPlayersViewServerId(null)
        }
        return
      }
      const inSearch = document.activeElement === searchRef.current
      if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
        e.preventDefault()
        actions.moveSelection(
          servers.map((s) => s.id),
          e.key === 'ArrowDown' ? 1 : -1,
        )
      } else if (e.key === 'Enter') {
        if (directAddress) {
          playUiSound('select')
          actions.connectToAddress(directAddress)
        } else if (selected) {
          playUiSound('select')
          actions.connectTo(selected)
        }
      } else if (e.key === 'Escape') {
        playUiSound('back')
        actions.closeBrowser()
      } else if (!inSearch && e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault()
        searchRef.current?.focus()
        actions.setQuery(`${state.query}${e.key}`)
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [directAddress, playersViewOpen, servers, selected, state.connect.phase, state.query])

  const onBottomNav = useCallback((key: NavItemKey) => {
    switch (key) {
      case 'servers':
        window.location.hash = '/servers'
        break
      case 'settings':
        window.location.hash = '/settings'
        break
      case 'updates':
        window.location.hash = '/updates'
        break
      case 'reconnect':
      case 'resume':
        window.location.hash = ''
        break
      case 'about':
        window.location.hash = ''
        break
      case 'quit':
        window.close()
        break
      default:
        window.location.hash = ''
        break
    }
  }, [])

  return (
    <div className="shell sao-browser-shell">
      <div className="browser-art" aria-hidden="true">
        <img src={loadscreen} alt="" draggable={false} />
      </div>
      <div className="browser-wash" aria-hidden="true" />
      <AmbientLighting />

      <Header
        title={t('browser.title')}
        subtitle="San Andreas Online — Multiplayer Server Browser"
        variant="page"
        stats={state.stats}
        onClose={() => {
          playUiSound('back')
          actions.closeBrowser()
        }}
      />

      <div className="main sao-browser-main">
        <Toolbar
          source={state.source}
          refreshing={state.refreshing}
          query={state.query}
          filters={state.filters}
          directTarget={directTarget}
          searchRef={searchRef}
          totalServersCount={state.stats.serverCount || state.servers.size}
          favoritesCount={[...state.servers.values()].filter((s) => s.isFavourite).length}
          recentCount={state.source === 'recent' ? state.servers.size : undefined}
          onSource={(source) => void actions.setSource(source)}
          onRefresh={() => void actions.refresh()}
          onQuery={actions.setQuery}
          onFilters={actions.setFilters}
          onConnect={connectFromToolbar}
        />

        <div className="sao-browser-content">
          <div className="sao-browser-list-col">
            <ServerList
              servers={servers}
              selectedId={state.selectedId}
              directTarget={directTarget}
              onSelect={actions.select}
              onJoin={joinServer}
              onToggleFavourite={toggleFavourite}
            />
          </div>

          <div className="sao-browser-details-col">
            <DetailsPanel
              server={selected}
              playersViewOpen={playersViewOpen}
              onOpenPlayers={() => {
                if (!selected) return
                playUiSound('select')
                setPlayersViewServerId(selected.id)
              }}
              onClosePlayers={() => {
                playUiSound('back')
                setPlayersViewServerId(null)
              }}
              onConnect={(server) => {
                playUiSound('select')
                actions.connectTo(server)
              }}
              onCopyLink={actions.copyServerLink}
              onOpenLink={actions.openExternal}
            />
          </div>
        </div>
      </div>

      <StatusBar progress={state.progress} notice={state.notice} />

      <BottomNavBar
        currentView="server-browser"
        inGame={false}
        onNavigate={onBottomNav}
      />
    </div>
  )
}
