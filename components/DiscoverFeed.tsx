'use client'

import { useState, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { ArrowLeft, Bookmark } from 'lucide-react'
import { getCountry } from '@/data/worldData'
import type { Character } from '@/data/worldData'
import { getSavedCharacterIds, toggleSavedCharacter } from '@/lib/savedCharacters'

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
}

function DiscoverSlide({
  character,
  isSaved,
  onToggleSave,
  onChat,
}: {
  character: Character
  isSaved: boolean
  onToggleSave: () => void
  onChat: () => void
}) {
  const country = getCountry(character)
  const iso = COUNTRY_ISO[country]
  return (
    <div className="discover-slide">
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
            <span>{character.location}</span>
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
          <button className="discover-slide-btn" onClick={onChat}>
            Discutez
          </button>
        </div>
      </div>
    </div>
  )
}

export default function DiscoverFeed() {
  const router = useRouter()
  const [characters, setCharacters] = useState<Character[]>([])
  const [savedIds, setSavedIds] = useState<number[]>([])

  useEffect(() => {
    if (typeof window !== 'undefined') {
      setSavedIds(getSavedCharacterIds())
    }
  }, [])

  useEffect(() => {
    fetch('/api/characters')
      .then(res => res.json())
      .then(data => {
        if (Array.isArray(data)) setCharacters(data)
      })
      .catch(err => console.error('Erreur chargement personnages:', err))
  }, [])

  const handleToggleSave = (character: Character) => {
    const nowSaved = toggleSavedCharacter(character)
    setSavedIds((prev) =>
      nowSaved
        ? [...prev, character.id]
        : prev.filter((id) => id !== character.id)
    )
  }

  return (
    <div className="discover-feed">
      <button
        onClick={() => {
          if (window.history.length > 1) router.back()
          else router.push('/')
        }}
        className="discover-back-btn"
        aria-label="Retour"
      >
        <ArrowLeft size={22} />
      </button>
      {characters.map((character) => (
        <DiscoverSlide
          key={character.id}
          character={character}
          isSaved={savedIds.includes(character.id)}
          onToggleSave={() => handleToggleSave(character)}
          onChat={() => router.push(`/chat?characterId=${character.id}`)}
        />
      ))}
    </div>
  )
}
