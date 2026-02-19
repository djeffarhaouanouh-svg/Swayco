'use client'

import { useRouter } from 'next/navigation'
import { X } from 'lucide-react'

export type SceneOverlayData = {
  id: number
  name: string
  image: string
  location: string
}

type SceneOverlayProps = {
  scene: SceneOverlayData
  isOpen: boolean
  onClose: () => void
}

export default function SceneOverlay({ scene, isOpen, onClose }: SceneOverlayProps) {
  const router = useRouter()

  const startScene = () => {
    const sessionId = crypto.randomUUID()
    onClose()
    router.push(
      `/chat?sceneImage=${encodeURIComponent(scene.image || '')}&sceneName=${encodeURIComponent(scene.name)}&sceneLocation=${encodeURIComponent(scene.location)}&sceneId=${scene.id}&sceneSessionId=${sessionId}`
    )
  }

  if (!isOpen) return null

  return (
    <>
      <div
        className="character-overlay-backdrop"
        onClick={onClose}
        aria-hidden
      />
      <div className="character-overlay-wrapper" role="dialog" aria-modal="true" aria-label={`Scène ${scene.name}`}>
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
              src={scene.image}
              alt={scene.name}
              className="character-overlay-image"
            />
            <div className="character-overlay-gradient" />
            <div className="scene-overlay-buttons">
              <div className="scene-overlay-info">
                <p className="scene-overlay-name">{scene.name}</p>
                <p className="scene-overlay-location">{scene.location}</p>
              </div>
              <button type="button" className="scene-overlay-btn scene-overlay-start-btn" onClick={startScene}>
                🎬 Commencer la scène
              </button>
            </div>
          </div>
        </div>
      </div>
    </>
  )
}
