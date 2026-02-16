'use client';

import { useState, useRef, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { ArrowLeft, Send, CheckCheck, MoreVertical, Trash2 } from 'lucide-react';
import { characters } from '@/data/worldData';
import type { Character } from '@/data/worldData';

interface Message {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  status: 'sending' | 'completed' | 'failed';
  time: string;
}

const getTime = () =>
  new Date().toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });

// Simule une reponse IA basee sur le personnage
function generateResponse(character: Character, userMessage: string): string {
  const greetings = [
    `Ah, quelle belle question ! En tant que ${character.name} de ${character.location}, je peux te dire que...`,
    `Salut ! Ici ${character.name}. ${character.description.split('.')[0]}.`,
    `Bienvenue ! Je suis ${character.name}, laisse-moi te raconter...`,
  ];
  const responses = [
    `C'est une super question ! ${character.description}`,
    `Ah oui, ${character.location} est un endroit magique pour ca ! Je connais bien le sujet.`,
    `Merci de me demander ! En vivant a ${character.location}, j'ai appris beaucoup de choses la-dessus.`,
    `Interessant ! Tu sais, ${character.description.split('.')[0]}. C'est pour ca que j'adore en parler !`,
    `Haha, j'adore cette question ! Ici a ${character.location}, on a une perspective unique sur ce sujet.`,
  ];

  const lower = userMessage.toLowerCase();
  if (lower.includes('bonjour') || lower.includes('salut') || lower.includes('hello') || lower.includes('hey')) {
    return greetings[Math.floor(Math.random() * greetings.length)];
  }
  return responses[Math.floor(Math.random() * responses.length)];
}

export default function ChatPage() {
  const router = useRouter();
  const [character, setCharacter] = useState<Character | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [showMenu, setShowMenu] = useState(false);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);

  // Charger le personnage depuis l'URL
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const id = params.get('characterId');
    if (id) {
      const found = characters.find(c => c.id === parseInt(id));
      if (found) setCharacter(found);
    }
  }, []);

  // Scroll en bas a chaque nouveau message
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  // Fermer le menu quand on clique ailleurs
  useEffect(() => {
    if (!showMenu) return;
    const handleClick = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setShowMenu(false);
      }
    };
    document.addEventListener('mousedown', handleClick);
    return () => document.removeEventListener('mousedown', handleClick);
  }, [showMenu]);

  const handleClearMessages = () => {
    setMessages([]);
    setShowMenu(false);
  };

  const sendMessage = async () => {
    if (!input.trim() || isLoading || !character) return;

    const userMessage: Message = {
      id: Date.now().toString(),
      role: 'user',
      content: input.trim(),
      status: 'completed',
      time: getTime(),
    };

    const assistantId = (Date.now() + 1).toString();
    const loadingMessage: Message = {
      id: assistantId,
      role: 'assistant',
      content: '',
      status: 'sending',
      time: getTime(),
    };

    setMessages(prev => [...prev, userMessage, loadingMessage]);
    setInput('');
    setIsLoading(true);

    // Simuler un delai de reponse
    setTimeout(() => {
      const response = generateResponse(character, userMessage.content);
      setMessages(prev =>
        prev.map(m =>
          m.id === assistantId
            ? { ...m, content: response, status: 'completed' as const }
            : m
        )
      );
      setIsLoading(false);
      inputRef.current?.focus();
    }, 800 + Math.random() * 1200);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  };

  return (
    <div className="chat-container">
      {/* Header */}
      <header className="chat-header">
        <button
          type="button"
          onClick={() => {
            if (window.history.length > 1) router.back();
            else router.push('/');
          }}
          className="chat-back-btn"
          aria-label="Retour"
        >
          <ArrowLeft size={22} />
        </button>

        <div className="chat-header-info">
          <div className="chat-header-avatar">
            <img
              src={character?.image || '/avatar-1.png'}
              alt={character?.name || 'Avatar'}
            />
          </div>
          <div className="chat-header-text">
            <span className="chat-header-name">{character?.name || 'Avatar'}</span>
            <span className="chat-header-location">{character?.location || ''}</span>
          </div>
        </div>

        <div className="chat-header-actions" ref={menuRef}>
          <button onClick={() => setShowMenu(!showMenu)} className="chat-menu-btn">
            <MoreVertical size={18} />
          </button>
          {showMenu && (
            <div className="chat-dropdown">
              <button onClick={handleClearMessages} className="chat-dropdown-item chat-dropdown-danger">
                <Trash2 size={16} />
                <span>Effacer les messages</span>
              </button>
            </div>
          )}
        </div>
      </header>

      {/* Messages */}
      <div className="chat-messages">
        {messages.length === 0 && (
          <div className="chat-empty">
            <p>Commencez une conversation avec {character?.name || 'votre avatar IA'}</p>
          </div>
        )}

        {messages.map(message => (
          <div
            key={message.id}
            className={`chat-bubble-row ${message.role === 'user' ? 'chat-bubble-right' : 'chat-bubble-left'}`}
          >
            {message.role === 'assistant' && (
              <div className="chat-bubble-avatar-small">
                <img src={character?.image || '/avatar-1.png'} alt="" />
              </div>
            )}
            <div>
              <div
                className={`chat-bubble ${message.role === 'user' ? 'chat-bubble-user' : 'chat-bubble-assistant'}`}
              >
                {message.status === 'sending' ? (
                  <div className="chat-typing">
                    <span /><span /><span />
                  </div>
                ) : (
                  <p>{message.content}</p>
                )}
              </div>
              <div className={`chat-bubble-meta ${message.role === 'user' ? 'chat-meta-right' : 'chat-meta-left'}`}>
                <span>{message.time}</span>
                {message.role === 'user' && <CheckCheck size={14} />}
              </div>
            </div>
          </div>
        ))}
        <div ref={messagesEndRef} />
      </div>

      {/* Input */}
      <div className="chat-input-bar">
        <div className="chat-input-wrapper">
          <input
            ref={inputRef}
            type="text"
            value={input}
            onChange={e => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Message..."
            disabled={isLoading}
          />
        </div>
        <button
          onClick={sendMessage}
          disabled={isLoading || !input.trim()}
          className="chat-send-btn"
        >
          <Send size={20} />
        </button>
      </div>
    </div>
  );
}
