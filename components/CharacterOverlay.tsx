'use client'

import { useRouter } from 'next/navigation'
import { X } from 'lucide-react'

export type CharacterOverlayData = {
  id: number
  name: string
  image: string
  description: string
  teaser?: string
  age?: string | number
  location?: string
  badge?: string
}

type CharacterOverlayProps = {
  character: CharacterOverlayData
  isOpen: boolean
  onClose: () => void
}

export default function CharacterOverlay({ character, isOpen, onClose }: CharacterOverlayProps) {
  const router = useRouter()

  const handleDiscutez = () => {
    onClose()
    router.push(`/chat?characterId=${character.id}`)
  }

  const displayName = character.age != null ? `${character.name} ${character.age}` : character.name
  const previewText = character.teaser?.split('\n')[0] ?? character.description

  if (!isOpen) return null

  return (
    <>
      <div
        className="character-overlay-backdrop"
        onClick={onClose}
        aria-hidden
      />
      <div className="character-overlay-wrapper" role="dialog" aria-modal="true" aria-label={`Profil de ${character.name}`}>
        <div className="character-overlay-card" onClick={(e) => e.stopPropagation()}>
          <button
            type="button"
            className="character-overlay-close"
            onClick={onClose}
            aria-label="Fermer"
          >
            <X size={24} />
          </button>
          <div className="character-overlay-image-wrap">
            <img
              src={character.image}
              alt={character.name}
              className="character-overlay-image"
            />
            <div className="character-overlay-gradient" />
            <div className="character-overlay-text">
              <div className="character-overlay-text-left">
                <h2 className="character-overlay-name">{displayName}</h2>
                <p className="character-overlay-description">{previewText}</p>
              </div>
              <button
                type="button"
                className="character-overlay-btn"
                onClick={handleDiscutez}
              >
                Discutez
              </button>
            </div>
          </div>
        </div>
      </div>
    </>
  )
}
