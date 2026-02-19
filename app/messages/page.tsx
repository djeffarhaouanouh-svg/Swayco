'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { ArrowLeft } from 'lucide-react';
import { characters as worldCharacters } from '@/data/worldData';

type CharPreview = {
  type: 'character';
  characterId: number;
  lastMessage: string;
  updatedAt: string | null;
};

type ScenePreview = {
  type: 'scene';
  sceneId: number;
  sceneSessionId: string | null;
  sceneName: string;
  sceneImage: string | null;
  sceneLocation: string | null;
  characterId: number | null;
  characterName: string | null;
  characterImage: string | null;
  lastMessage: string;
  updatedAt: string | null;
};

type PlaceVisitPreview = {
  type: 'place';
  placeSessionId: string;
  placeName: string;
  placeImage: string | null;
  placeLocation: string | null;
  lastMessage: string;
  updatedAt: string | null;
};

type Preview = CharPreview | ScenePreview | PlaceVisitPreview;

export default function MessagesPage() {
  const router = useRouter();
  const [previews, setPreviews] = useState<Preview[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch('/api/messages/previews')
      .then((res) => res.json())
      .then((data) => {
        if (data.success && Array.isArray(data.previews)) {
          setPreviews(data.previews);
        }
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  const handleBack = () => {
    if (window.history.length > 1) router.back();
    else router.push('/');
  };

  const handleCharClick = (characterId: number) => {
    router.push(`/chat?characterId=${characterId}`);
  };

  const handleSceneClick = (p: ScenePreview) => {
    const params = new URLSearchParams();
    params.set('sceneId', String(p.sceneId));
    params.set('sceneName', p.sceneName);
    if (p.sceneImage) params.set('sceneImage', p.sceneImage);
    if (p.sceneLocation) params.set('sceneLocation', p.sceneLocation);
    if (p.characterId) params.set('sceneCharacterId', String(p.characterId));
    if (p.sceneSessionId) params.set('sceneSessionId', p.sceneSessionId);
    params.set('sceneResume', '1'); // indique qu'on revient depuis /messages
    router.push(`/chat?${params.toString()}`);
  };

  return (
    <div className="messages-container">
      <header className="messages-header">
        <button
          type="button"
          onClick={handleBack}
          className="messages-back-btn"
          aria-label="Retour"
        >
          <ArrowLeft size={22} />
        </button>
        <div className="messages-logo">
          <img src="/logo%20swayco.png" alt="Swayco" className="messages-logo-img" />
        </div>
        <div className="messages-header-spacer" />
      </header>

      <h1 className="messages-title">Messages</h1>

      <div className="messages-list">
        {loading ? (
          <p className="messages-loading">Chargement...</p>
        ) : previews.length === 0 ? (
          <p className="messages-empty">Aucune conversation pour le moment.</p>
        ) : (
          previews.map((conv) => {
            if (conv.type === 'character') {
              // Chercher d'abord dans worldData, sinon utiliser les infos de la DB (nom/image manquants ici)
              const character = worldCharacters.find((c) => c.id === conv.characterId);
              if (!character) return null;
              return (
                <button
                  key={`char-${conv.characterId}`}
                  type="button"
                  className="messages-item"
                  onClick={() => handleCharClick(conv.characterId)}
                >
                  <div className="messages-item-avatar">
                    <img src={character.image} alt={character.name} />
                  </div>
                  <div className="messages-item-content">
                    <span className="messages-item-name">{character.name}</span>
                    <span className="messages-item-preview">{conv.lastMessage}</span>
                  </div>
                </button>
              );
            }

            // Visite guidée d'un lieu
            if (conv.type === 'place') {
              return (
                <button
                  key={`place-${conv.placeSessionId}`}
                  type="button"
                  className="messages-item"
                  onClick={() => router.push(`/guide-eiffel?placeSessionId=${conv.placeSessionId}`)}
                >
                  <div className="messages-item-avatar messages-item-avatar-scene">
                    {conv.placeImage ? (
                      <img src={conv.placeImage} alt={conv.placeName} />
                    ) : (
                      <span className="messages-item-scene-icon">🗼</span>
                    )}
                  </div>
                  <div className="messages-item-content">
                    <span className="messages-item-name">{conv.placeName}</span>
                    {conv.placeLocation && (
                      <span className="messages-item-scene-char">{conv.placeLocation}</span>
                    )}
                    <span className="messages-item-preview">{conv.lastMessage}</span>
                  </div>
                </button>
              );
            }

            // Conversation de scène
            return (
              <button
                key={`scene-${conv.sceneId}-${conv.sceneSessionId ?? 'old'}`}
                type="button"
                className="messages-item"
                onClick={() => handleSceneClick(conv)}
              >
                <div className="messages-item-avatar messages-item-avatar-scene">
                  {conv.sceneImage ? (
                    <img src={conv.sceneImage} alt={conv.sceneName} />
                  ) : (
                    <span className="messages-item-scene-icon">🎬</span>
                  )}
                  {/* Avatar du personnage en badge */}
                  {conv.characterImage && (
                    <img
                      src={conv.characterImage}
                      alt={conv.characterName || ''}
                      className="messages-item-avatar-badge"
                    />
                  )}
                </div>
                <div className="messages-item-content">
                  <span className="messages-item-name">{conv.sceneName}</span>
                  {conv.characterName && (
                    <span className="messages-item-scene-char">avec {conv.characterName}</span>
                  )}
                  <span className="messages-item-preview">{conv.lastMessage}</span>
                </div>
              </button>
            );
          })
        )}
      </div>
    </div>
  );
}
