'use client';

import { useRouter } from 'next/navigation';
import { ArrowLeft } from 'lucide-react';
import { characters } from '@/data/worldData';
import type { Character } from '@/data/worldData';

// Derniers messages simulés pour chaque conversation
const recentConversations: { characterId: number; lastMessage: string }[] = [
  { characterId: 1, lastMessage: "Tu me fais toujours sourire, mon amour." },
  { characterId: 2, lastMessage: "Oh là là, quel charme soudain ! Je vais très bien, merci de t'en so..." },
  { characterId: 4, lastMessage: "Salut ! Ça me fait plaisir de te parler aujourd'hui." },
];

export default function MessagesPage() {
  const router = useRouter();

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
          <span className="messages-logo-heart">♥</span>
          <span className="messages-logo-text">swayco.ai</span>
        </div>
        <div className="messages-header-spacer" />
      </header>

      {/* Title */}
      <h1 className="messages-title">Messages</h1>

      {/* Conversation list */}
      <div className="messages-list">
        {recentConversations.map((conv) => {
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
        })}
      </div>
    </div>
  );
}
