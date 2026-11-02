import { useI18n } from '../i18n'
import type { NetworkStats } from '../store'
import { IconArrowLeft, IconGlobe } from './Icons'

interface HeaderProps {
  title?: string
  subtitle?: string
  stats?: NetworkStats
  onClose?: () => void
  locale?: string
  languages?: readonly { locale: string; name: string }[]
  onLanguageSelect?: (locale: string) => void
  variant?: 'brand' | 'page'
}

export function Header({
  title,
  subtitle,
  stats,
  onClose,
  locale,
  languages,
  onLanguageSelect,
  variant,
}: HeaderProps) {
  const { formatNumber, t } = useI18n()

  const currentLang = languages?.find((l) => l.locale === locale)?.name ?? 'English (US)'
  const isBrand = variant === 'brand' || (!variant && (title === 'San Andreas Online' || !title))
  const displayTitle = title ?? 'San Andreas Online'

  return (
    <header className="sao-header">
      <div className="sao-header__left">
        <h1 className={`sao-header__title ${isBrand ? 'sao-header__title--brand' : 'sao-header__title--page'}`}>
          {displayTitle}
        </h1>
        <p className="sao-header__subtitle">
          {subtitle ?? 'Grand Theft Auto: San Andreas™ © 2005 Rockstar Games, Inc.'}
        </p>
      </div>

      <div className="sao-header__right">
        {stats && (
          <div className="sao-header__live-status">
            <span className="sao-header__live-dot" aria-hidden="true">
              <span className="sao-header__live-dot-outer" />
              <span className="sao-header__live-dot-inner" />
            </span>
            <span className="sao-header__live-text">
              {formatNumber(stats.playersOnline)} players online on {formatNumber(stats.serverCount)} servers
            </span>
          </div>
        )}

        {languages && onLanguageSelect && (
          <div className="sao-header__lang">
            <span className="sao-header__lang-icon" aria-hidden="true">
              <IconGlobe size={18} />
            </span>
            <select
              className="sao-header__lang-select"
              value={locale ?? 'en_US'}
              title={currentLang}
              onChange={(e) => onLanguageSelect(e.target.value)}
              aria-label={t('aria.chooseLanguage')}
            >
              {languages.map((lang) => (
                <option key={lang.locale} value={lang.locale}>
                  {lang.name}
                </option>
              ))}
            </select>
          </div>
        )}

        {onClose && (
          <button
            type="button"
            className="sao-header__back-btn"
            onClick={onClose}
            title={t('browser.backToMain')}
          >
            <IconArrowLeft size={16} />
            <span>{t('browser.backToMain')}</span>
          </button>
        )}
      </div>
    </header>
  )
}
