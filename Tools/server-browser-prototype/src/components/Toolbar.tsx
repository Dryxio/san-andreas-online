import { useEffect, useRef, useState } from 'react'
import { useI18n, type TranslationKey } from '../i18n'
import type { BrowserFilters } from '../search'
import type { ServerSource } from '../types'
import { playUiSound } from '../uiSound'
import {
  IconCheck,
  IconFilter,
  IconPlay,
  IconRefresh,
  IconSearch,
  IconStar,
} from './Icons'

function IconClock({ size = 16 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <circle cx="12" cy="12" r="10" />
      <polyline points="12 6 12 12 16 14" />
    </svg>
  )
}

interface ToolbarProps {
  source: ServerSource
  refreshing: boolean
  query: string
  filters: BrowserFilters
  directTarget: string | null
  searchRef: React.RefObject<HTMLInputElement | null>
  totalServersCount?: number
  favoritesCount?: number
  recentCount?: number
  onSource: (source: ServerSource) => void
  onRefresh: () => void
  onQuery: (query: string) => void
  onFilters: (filters: BrowserFilters) => void
  onConnect: () => void
}

const FILTER_LABEL_KEYS: Record<keyof BrowserFilters, TranslationKey> = {
  hideFull: 'browser.filter.hideFull',
  hideEmpty: 'browser.filter.hideEmpty',
  hideLocked: 'browser.filter.hideLocked',
  hideIncompatible: 'browser.filter.hideIncompatible',
  hideOffline: 'browser.filter.hideOffline',
}

function useClickOutside(open: boolean, close: () => void) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const onDown = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) close()
    }
    window.addEventListener('mousedown', onDown)
    return () => window.removeEventListener('mousedown', onDown)
  }, [open, close])
  return ref
}

export function Toolbar(props: ToolbarProps) {
  const { t, formatNumber } = useI18n()
  const [filtersOpen, setFiltersOpen] = useState(false)
  const filtersRef = useClickOutside(filtersOpen, () => setFiltersOpen(false))

  const activeFilters = Object.values(props.filters).filter(Boolean).length

  return (
    <div className="sao-toolbar">
      {/* Category Tabs: All Servers, Favorites, Recent */}
      <div className="sao-toolbar__tabs">
        <button
          type="button"
          className={`sao-tab${props.source === 'internet' ? ' sao-tab--active' : ''}`}
          onClick={() => {
            playUiSound('select')
            props.onSource('internet')
          }}
        >
          <span>All Servers {props.totalServersCount !== undefined && `(${formatNumber(props.totalServersCount)})`}</span>
          {props.source === 'internet' && <span className="sao-tab__indicator" />}
        </button>

        <button
          type="button"
          className={`sao-tab${props.source === 'favourites' ? ' sao-tab--active' : ''}`}
          onClick={() => {
            playUiSound('select')
            props.onSource('favourites')
          }}
        >
          <IconStar size={16} />
          <span>Favorites {props.favoritesCount !== undefined && `(${formatNumber(props.favoritesCount)})`}</span>
          {props.source === 'favourites' && <span className="sao-tab__indicator" />}
        </button>

        <button
          type="button"
          className={`sao-tab${props.source === 'recent' ? ' sao-tab--active' : ''}`}
          onClick={() => {
            playUiSound('select')
            props.onSource('recent')
          }}
        >
          <IconClock size={16} />
          <span>Recent {props.recentCount !== undefined && `(${formatNumber(props.recentCount)})`}</span>
          {props.source === 'recent' && <span className="sao-tab__indicator" />}
        </button>
      </div>

      {/* Search and Action Bar */}
      <div className="sao-toolbar__search-bar">
        <div className={`sao-search${props.directTarget ? ' sao-search--direct' : ''}`}>
          <span className="sao-search__icon" aria-hidden="true">
            <IconSearch size={16} />
          </span>
          <input
            ref={props.searchRef}
            type="text"
            className="sao-search__input"
            value={props.query}
            placeholder={t('browser.searchPlaceholder')}
            onChange={(e) => props.onQuery(e.target.value)}
          />
          {props.directTarget && (
            <button
              type="button"
              className="sao-search__direct-btn"
              onClick={props.onConnect}
              title={t('browser.directConnect')}
            >
              <IconPlay size={14} />
              <span>{t('browser.directConnect')}</span>
            </button>
          )}
        </div>

        <div className="sao-toolbar__actions">
          <div className="menu-anchor" ref={filtersRef}>
            <button
              type="button"
              className={`sao-tool-btn${activeFilters > 0 ? ' sao-tool-btn--active' : ''}`}
              onClick={() => {
                playUiSound('select')
                setFiltersOpen((v) => !v)
              }}
              aria-label={t('common.filters')}
            >
              <IconFilter size={15} />
              <span>{t('common.filters')}</span>
              {activeFilters > 0 && <span className="sao-filter-badge">{activeFilters}</span>}
            </button>

            {filtersOpen && (
              <div className="menu menu--right" role="menu">
                {(Object.keys(FILTER_LABEL_KEYS) as Array<keyof BrowserFilters>).map((key) => {
                  const active = props.filters[key]
                  return (
                    <button
                      key={key}
                      type="button"
                      className={`menu__item${active ? ' menu__item--active' : ''}`}
                      onMouseEnter={() => playUiSound('highlight')}
                      onClick={() => {
                        playUiSound('select')
                        props.onFilters({ ...props.filters, [key]: !active })
                      }}
                    >
                      <span className="check">{active && <IconCheck size={14} />}</span>
                      <span>{t(FILTER_LABEL_KEYS[key])}</span>
                    </button>
                  )
                })}
              </div>
            )}
          </div>

          <button
            type="button"
            className={`sao-tool-btn${props.refreshing ? ' sao-tool-btn--spinning' : ''}`}
            onClick={() => {
              playUiSound('select')
              props.onRefresh()
            }}
            title={t('common.refresh')}
          >
            <IconRefresh size={15} />
          </button>
        </div>
      </div>
    </div>
  )
}
