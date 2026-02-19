'use client'

import { useState, useEffect, useRef, useCallback, forwardRef } from 'react'
import { useRouter } from 'next/navigation'
import { ArrowLeft, Bookmark } from 'lucide-react'
import { getCountry, getCity } from '@/data/worldData'
import type { Character } from '@/data/worldData'
import { getSavedCharacterIds, toggleSavedCharacter } from '@/lib/savedCharacters'

const DISCOVER_SCROLL_KEY = 'discover-slide'

/* Module-level index – survives component remounts during SPA navigation */
let persistedSlideIndex = 0
try {
  const s = typeof window !== 'undefined' ? sessionStorage.getItem(DISCOVER_SCROLL_KEY) : null
  if (s !== null) persistedSlideIndex = Math.max(0, parseInt(s, 10))
} catch (_) {}

const COUNTRY_ISO: Record<string, string> = {
  France: 'fr',
  Japon: 'jp',
  Italie: 'it',
  'Royaume-Uni': 'gb',
  Brésil: 'br',
  Maroc: 'ma',
  Russie: 'ru',
  Espagne: 'es',
  USA: 'us',
  Irlande: 'ie',
  Chine: 'cn',
  Australie: 'au',
  Grèce: 'gr',
  Égypte: 'eg',
  'Pays-Bas': 'nl',
  Inde: 'in',
  Pérou: 'pe',
  Portugal: 'pt',
}

const DiscoverSlide = forwardRef<
  HTMLDivElement,
  {
    character: Character
    isSaved: boolean
    onToggleSave: () => void
    onChat: () => void
  }
>(function DiscoverSlide({ character, isSaved, onToggleSave, onChat }, ref) {
  const country = getCountry(character)
  const city = getCity(character)
  const iso = COUNTRY_ISO[country]
  const locationLabel = city ? `${city}, ${country}` : country
  return (
    <div className="discover-slide" ref={ref}>
      <img
        src={character.image}
        alt={character.name}
        className="discover-slide-image"
      />
      <button
        type="button"
        onClick={(e) => {
          e.stopPropagation()
          onToggleSave()
        }}
        className={`discover-slide-signer ${isSaved ? 'discover-slide-signer--saved' : ''}`}
        aria-label={isSaved ? 'Retirer des enregistrements' : 'Enregistrer ce personnage'}
      >
        <Bookmark
          size={24}
          strokeWidth={2}
          fill={isSaved ? 'currentColor' : 'none'}
        />
      </button>
      <div className="discover-slide-overlay">
        <div className="discover-slide-info">
          <h2 className="discover-slide-name">{character.name}</h2>
          <p className="discover-slide-location">
            <span>📍</span>
            <span>{locationLabel}</span>
            {iso && (
              <img
                src={`https://flagcdn.com/24x18/${iso}.png`}
                alt=""
                aria-hidden
                className="discover-slide-flag"
              />
            )}
          </p>
          <p className="discover-slide-stats">💬 {character.stats.messages} messages</p>
          {character.teaser && (
            <p className="discover-slide-teaser">
              {character.teaser.split('\n').map((line, i) => (
                <span key={i}>{line}</span>
              ))}
            </p>
          )}
          <button className="discover-slide-btn" onClick={(e) => { e.stopPropagation(); onChat(); }}>
            Discutez
          </button>
        </div>
      </div>
    </div>
  )
})

export default function DiscoverFeed() {
  const router = useRouter()
  const feedRef = useRef<HTMLDivElement>(null)
  const slideRefs = useRef<(HTMLDivElement | null)[]>([])
  const [characters, setCharacters] = useState<Character[]>([])
  const [savedIds, setSavedIds] = useState<number[]>([])
  const isNavigatingRef = useRef(false)

  useEffect(() => {
    if (typeof window !== 'undefined') {
      setSavedIds(getSavedCharacterIds())
    }
  }, [])

  useEffect(() => {
    fetch('/api/characters', { cache: 'no-store' })
      .then(res => res.json())
      .then(data => {
        if (Array.isArray(data)) setCharacters(data)
      })
      .catch(err => console.error('Erreur chargement personnages:', err))
  }, [])

  /* ---- Track visible slide with IntersectionObserver ---- */
  useEffect(() => {
    const el = feedRef.current
    if (!el || characters.length === 0) return

    const observer = new IntersectionObserver(
      (entries) => {
        if (isNavigatingRef.current) return
        for (const entry of entries) {
          if (entry.isIntersecting && entry.intersectionRatio >= 0.5) {
            const idx = slideRefs.current.indexOf(entry.target as HTMLDivElement)
            if (idx !== -1) {
              persistedSlideIndex = idx
              try { sessionStorage.setItem(DISCOVER_SCROLL_KEY, String(idx)) } catch (_) {}
            }
          }
        }
      },
      { root: el, threshold: 0.5 }
    )

    slideRefs.current.forEach((slide) => {
      if (slide) observer.observe(slide)
    })

    return () => observer.disconnect()
  }, [characters.length])

  /* ---- Restore scroll position when characters load ---- */
  useEffect(() => {
    if (characters.length === 0) return
    const idx = persistedSlideIndex
    if (idx <= 0) return

    // Immediate attempt
    const slide = slideRefs.current[idx]
    if (slide) {
      slide.scrollIntoView({ behavior: 'instant' as ScrollBehavior })
    }

    // Safety retry after layout settles
    const id = setTimeout(() => {
      const s = slideRefs.current[idx]
      if (s) s.scrollIntoView({ behavior: 'instant' as ScrollBehavior })
    }, 100)

    return () => clearTimeout(id)
  }, [characters.length])

  /* ---- navigation helpers ---- */
  const navigateAway = useCallback((go: () => void) => {
    isNavigatingRef.current = true
    go()
  }, [])

  const handleBack = () => {
    navigateAway(() => {
      if (window.history.length > 1) router.back()
      else router.push('/')
    })
  }

  const handleChat = (characterId: number) => {
    navigateAway(() => router.push(`/chat?characterId=${characterId}`))
  }

  const handleToggleSave = (character: Character) => {
    const nowSaved = toggleSavedCharacter(character)
    setSavedIds((prev) =>
      nowSaved
        ? [...prev, character.id]
        : prev.filter((id) => id !== character.id)
    )
  }

  return (
    <div
      ref={feedRef}
      className="discover-feed"
    >
      <button
        onClick={handleBack}
        className="discover-back-btn"
        aria-label="Retour"
      >
        <ArrowLeft size={22} />
      </button>
      {characters.map((character, i) => (
        <DiscoverSlide
          key={character.id}
          ref={(el) => { slideRefs.current[i] = el }}
          character={character}
          isSaved={savedIds.includes(character.id)}
          onToggleSave={() => handleToggleSave(character)}
          onChat={() => handleChat(character.id)}
        />
      ))}
    </div>
  )
}
