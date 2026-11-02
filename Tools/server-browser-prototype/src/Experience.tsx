import { lazy, Suspense, useCallback, useEffect, useState } from 'react'
import { I18nProvider, useI18n } from './i18n'
import { MainMenu } from './MainMenu'
import { ConnectModals, NativeMessageModal } from './components/Modals'
import { useMenuBridge } from './menuBridge'

const ServerBrowser = lazy(() => import('./App').then(({ App }) => ({ default: App })))
const loadSettings = () => import('./Settings').then(({ Settings }) => ({ default: Settings }))
const Settings = lazy(loadSettings)
const Updates = lazy(() => import('./Updates').then(({ Updates }) => ({ default: Updates })))

type View = 'main-menu' | 'server-browser' | 'settings' | 'updates'

function viewFromLocation(): View {
  if (window.location.hash === '#/servers' || window.location.hash === '/servers') return 'server-browser'
  if (window.location.hash === '#/settings' || window.location.hash === '/settings') return 'settings'
  if (window.location.hash === '#/updates' || window.location.hash === '/updates') return 'updates'
  return 'main-menu'
}

export function Experience() {
  const [view, setView] = useState<View>(viewFromLocation)
  const menu = useMenuBridge()

  const navigateTo = useCallback((newView: View) => {
    setView(newView)
    if (newView === 'server-browser') window.location.hash = '/servers'
    else if (newView === 'settings') window.location.hash = '/settings'
    else if (newView === 'updates') window.location.hash = '/updates'
    else {
      if (window.location.hash) {
        window.location.hash = ''
      }
    }
  }, [])

  useEffect(() => {
    const syncView = () => setView(viewFromLocation())
    window.addEventListener('hashchange', syncView)
    return () => window.removeEventListener('hashchange', syncView)
  }, [])

  useEffect(() => {
    let secondFrame: number | undefined
    const firstFrame = window.requestAnimationFrame(() => {
      secondFrame = window.requestAnimationFrame(() => { void loadSettings() })
    })
    return () => {
      window.cancelAnimationFrame(firstFrame)
      if (secondFrame !== undefined) window.cancelAnimationFrame(secondFrame)
    }
  }, [])

  return (
    <I18nProvider locale={menu.state.locale} translations={menu.state.translations}>
      {view === 'server-browser' ? (
        <ServerBrowserRoute />
      ) : view === 'settings' ? (
        <Suspense fallback={<div className="route-loading" aria-label="Loading settings" />}>
          <Settings onClose={() => navigateTo('main-menu')} />
        </Suspense>
      ) : view === 'updates' ? (
        <Suspense fallback={<div className="route-loading" aria-label="Loading updates" />}>
          <Updates buildNumber={menu.state.buildNumber} onClose={() => navigateTo('main-menu')} />
        </Suspense>
      ) : (
        <MainMenu
          buildNumber={menu.state.buildNumber}
          inGame={menu.state.inGame}
          identity={menu.state.identity}
          featuredServer={menu.state.featuredServer}
          locale={menu.state.locale}
          languages={menu.state.languages}
          onBrowseServers={() => navigateTo('server-browser')}
          onResume={() => menu.command('menu:resume')}
          onDisconnect={() => menu.command('menu:disconnect')}
          onQuickConnect={() => menu.command('menu:quickConnect', () => navigateTo('server-browser'))}
          onMapEditor={() => menu.command('menu:mapEditor')}
          onSettings={() => menu.command('menu:settings', () => navigateTo('settings'))}
          onAbout={() => menu.command('menu:about')}
          onUpdates={() => navigateTo('updates')}
          onIdentity={() => menu.command('menu:identity')}
          onPlayFeatured={() => menu.command('menu:playFeatured')}
          onLanguage={menu.setLanguage}
          onQuit={() => menu.command('menu:quit', () => window.close())}
        />
      )}
      <ConnectModals
        connect={menu.state.connect}
        onSubmitPassword={menu.submitConnectionPassword}
        onRetry={menu.retryConnection}
        onDismiss={menu.dismissConnection}
        onLinkIdentity={() => {
          menu.dismissConnection()
          navigateTo('main-menu')
          menu.command('menu:identity')
        }}
      />
      <NativeMessageModal dialog={menu.state.dialog} onRespond={menu.respondToDialog} />
    </I18nProvider>
  )
}

function ServerBrowserRoute() {
  const { t } = useI18n()
  return (
    <Suspense fallback={<div className="route-loading" aria-label={t('route.loadingServerBrowser')} />}>
      <ServerBrowser />
    </Suspense>
  )
}