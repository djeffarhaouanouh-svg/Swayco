'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { ArrowLeft } from 'lucide-react';
import { characters } from '@/data/worldData';
import type { Character } from '@/data/worldData';

type ConversationPreview = { characterId: number; lastMessage: string; updatedAt: string | null };

export default function MessagesPage() {
  const router = useRouter();
  const [previews, setPreviews] = useState<ConversationPreview[]>([]);
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

  const handleConversationClick = (character: Character) => {
    router.push(`/chat?characterId=${character.id}`);
  };

  return (
    <div className="messages-container">
      {/* Header */}
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

      {/* Title */}
      <h1 className="messages-title">Messages</h1>

      {/* Conversation list */}
      <div className="messages-list">
        {loading ? (
          <p className="messages-loading">Chargement...</p>
        ) : previews.length === 0 ? (
          <p className="messages-empty">Aucune conversation pour le moment.</p>
        ) : (
          previews.map((conv) => {
            const character = characters.find((c) => c.id === conv.characterId);
            if (!character) return null;
            return (
              <button
                key={character.id}
                type="button"
                className="messages-item"
                onClick={() => handleConversationClick(character)}
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
          })
        )}
      </div>
    </div>
  );
}
