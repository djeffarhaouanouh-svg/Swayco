'use client'

import { useRouter } from 'next/navigation'
import { ArrowLeft } from 'lucide-react'
import { characters } from '@/data/worldData'
import type { Character } from '@/data/worldData'

function DiscoverSlide({ character, onChat }: { character: Character; onChat: () => void }) {
  return (
    <div className="discover-slide">
      <img
        src={character.image}
        alt={character.name}
        className="discover-slide-image"
      />
      <div className="discover-slide-overlay">
        <div className="discover-slide-info">
          <h2 className="discover-slide-name">{character.name}</h2>
          <p className="discover-slide-location">📍 {character.location}</p>
          <p className="discover-slide-stats">💬 {character.stats.messages} messages</p>
          <button className="discover-slide-btn" onClick={onChat}>
            💬 Parler
          </button>
        </div>
      </div>
    </div>
  )
}

export default function DiscoverFeed() {
  const router = useRouter()

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
          onChat={() => router.push(`/chat?characterId=${character.id}`)}
        />
      ))}
    </div>
  )
}
