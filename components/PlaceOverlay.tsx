'use client'

import { useRouter } from 'next/navigation'
import { X } from 'lucide-react'

export type PlaceOverlayData = {
  id: number
  name: string
  image: string
  images?: string[]
  visitLabel?: string
  visitHref?: string
}

type PlaceOverlayProps = {
  place: PlaceOverlayData
  isOpen: boolean
  onClose: () => void
}

export default function PlaceOverlay({ place, isOpen, onClose }: PlaceOverlayProps) {
  const router = useRouter()
  const imageUrl = place.images?.[0] ?? place.image

  const handleVisit = () => {
    onClose()
    if (place.visitHref) {
      router.push(place.visitHref)
    }
  }

  if (!isOpen) return null

  return (
    <>
      <div
        className="character-overlay-backdrop"
        onClick={onClose}
        aria-hidden
      />
      <div className="character-overlay-wrapper" role="dialog" aria-modal="true" aria-label={`Monument ${place.name}`}>
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
              src={imageUrl}
              alt={place.name}
              className="character-overlay-image"
            />
            <div className="character-overlay-gradient" />
            <div className="place-overlay-text">
              <button
                type="button"
                className="character-overlay-btn"
                onClick={handleVisit}
              >
                {place.visitLabel ?? 'Visiter'}
              </button>
            </div>
          </div>
        </div>
      </div>
    </>
  )
}
