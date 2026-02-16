'use client';

import { useState, useRef, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { ArrowLeft, Send, CheckCheck, MoreVertical, Trash2, Play, X } from 'lucide-react';
import { characters as worldCharacters } from '@/data/worldData';
import type { Character } from '@/data/worldData';

interface Message {
  id: string;
  dbId?: number;
  role: 'user' | 'assistant';
  content: string;
  status: 'sending' | 'completed' | 'failed' | 'processing' | 'generating';
  time: string;
  videoUrl?: string;
  audioUrl?: string;
  imageUrl?: string;
  jobId?: string;
  showVideo?: boolean;
}

const getTime = () =>
  new Date().toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });

export default function ChatPage() {
  const router = useRouter();
  const [character, setCharacter] = useState<Character | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [showMenu, setShowMenu] = useState(false);
  const [expandedVideoUrl, setExpandedVideoUrl] = useState<string | null>(null);
  const [generatingMessageId, setGeneratingMessageId] = useState<string | null>(null);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const pollingRef = useRef<Map<string, NodeJS.Timeout>>(new Map());

  // Parallaxe du fond via gyroscope
  const [bgOffset, setBgOffset] = useState({ x: 50, y: 50 });
  const PARALLAX_FACTOR = 8;

  useEffect(() => {
    if (typeof window === 'undefined' || !('DeviceOrientationEvent' in window)) return;
    const handleOrientation = (e: DeviceOrientationEvent) => {
      const gamma = e.gamma ?? 0;
      const beta = e.beta ?? 0;
      const x = Math.max(20, Math.min(80, 50 + gamma * (PARALLAX_FACTOR / 90)));
      const y = Math.max(20, Math.min(80, 50 + beta * (PARALLAX_FACTOR / 90)));
      setBgOffset({ x, y });
    };
    window.addEventListener('deviceorientation', handleOrientation);
    return () => window.removeEventListener('deviceorientation', handleOrientation);
  }, []);

  // Mode scene
  const [sceneImage, setSceneImage] = useState<string | null>(null);
  const [sceneName, setSceneName] = useState<string | null>(null);
  const [sceneLocation, setSceneLocation] = useState<string | null>(null);
  const isSceneMode = !!(sceneImage && sceneName);

  // Charger depuis l'URL
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const sceneImgParam = params.get('sceneImage');
    const sceneNameParam = params.get('sceneName');
    const sceneLocParam = params.get('sceneLocation');
    const idParam = params.get('characterId');

    if (sceneImgParam) setSceneImage(decodeURIComponent(sceneImgParam));
    if (sceneNameParam) setSceneName(decodeURIComponent(sceneNameParam));
    if (sceneLocParam) setSceneLocation(decodeURIComponent(sceneLocParam));

    if (idParam && !sceneImgParam) {
      const id = parseInt(idParam, 10);
      const fromWorld = worldCharacters.find((c) => c.id === id);
      if (fromWorld) setCharacter(fromWorld);
      const merged: Character[] = [...worldCharacters];
      fetch('/api/characters')
        .then((res) => res.json())
        .then((data) => {
          if (Array.isArray(data)) {
            data.forEach((ac: Character) => {
              const idx = merged.findIndex((m) => m.id === ac.id);
              if (idx >= 0) merged[idx] = ac;
              else merged.push(ac);
            });
          }
          const found = merged.find((c) => c.id === id);
          if (found) setCharacter(found);
        })
        .catch(() => {
          if (!fromWorld) {
            const found = worldCharacters.find((c) => c.id === id);
            if (found) setCharacter(found);
          }
        });
    }
  }, []);

  // Charger les messages depuis la DB
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const charId = params.get('characterId');
    const scnId = params.get('sceneId');
    if (!charId && !scnId) return;

    const query = new URLSearchParams();
    if (charId) query.set('characterId', charId);
    if (scnId) query.set('sceneId', scnId);

    fetch(`/api/messages?${query.toString()}`)
      .then(res => res.json())
      .then(data => {
        if (data.success && Array.isArray(data.messages) && data.messages.length > 0) {
          setMessages(data.messages.map((m: any) => ({
            id: m.id.toString(),
            dbId: m.id,
            role: m.role,
            content: m.content,
            status: 'completed' as const,
            time: new Date(m.created_at).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' }),
            videoUrl: m.video_url || undefined,
            audioUrl: m.audio_url || undefined,
            showVideo: !!m.video_url,
          })));
        }
      })
      .catch(() => {});
  }, []);

  // Scroll en bas a chaque nouveau message
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  // Cleanup polling on unmount
  useEffect(() => {
    return () => {
      pollingRef.current.forEach(timer => clearTimeout(timer));
    };
  }, []);

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

  // Sauvegarder un message en DB
  const saveMessageToDB = useCallback(async (data: { role: string; content: string; videoUrl?: string }) => {
    const params = new URLSearchParams(window.location.search);
    const charId = params.get('characterId');
    const scnId = params.get('sceneId');
    try {
      const res = await fetch('/api/messages', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          characterId: charId || null,
          sceneId: scnId || null,
          role: data.role,
          content: data.content,
          videoUrl: data.videoUrl || null,
        }),
      });
      const result = await res.json();
      return result.success ? result.message.id : null;
    } catch {
      return null;
    }
  }, []);

  // Polling VModel job status
  const pollJobStatus = useCallback(async (jobId: string, messageId: string, attemptCount = 0) => {
    const MAX_ATTEMPTS = 60;

    try {
      const response = await fetch(`/api/chat-video/status?jobId=${jobId}`);
      const data = await response.json();

      if (data.status === 'completed' && data.videoUrl) {
        setMessages(prev => {
          const msg = prev.find(m => m.id === messageId);
          if (msg?.dbId) {
            fetch('/api/messages', {
              method: 'PUT',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ id: msg.dbId, videoUrl: data.videoUrl }),
            }).catch(() => {});
          }
          return prev.map(m =>
            m.id === messageId
              ? { ...m, videoUrl: data.videoUrl, status: 'completed' as const, showVideo: true, content: m.content || '' }
              : m
          );
        });
        pollingRef.current.delete(jobId);
      } else if (data.status === 'failed') {
        setMessages(prev =>
          prev.map(m =>
            m.id === messageId
              ? { ...m, status: 'failed' as const, content: m.content + ' (erreur vidéo)' }
              : m
          )
        );
        pollingRef.current.delete(jobId);
      } else if (attemptCount >= MAX_ATTEMPTS) {
        setMessages(prev =>
          prev.map(m =>
            m.id === messageId
              ? { ...m, status: 'failed' as const, content: m.content + ' (timeout)' }
              : m
          )
        );
        pollingRef.current.delete(jobId);
      } else {
        const timer = setTimeout(() => pollJobStatus(jobId, messageId, attemptCount + 1), 3000);
        pollingRef.current.set(jobId, timer);
      }
    } catch {
      if (attemptCount >= MAX_ATTEMPTS) {
        setMessages(prev =>
          prev.map(m =>
            m.id === messageId
              ? { ...m, status: 'failed' as const, content: m.content + ' (erreur polling)' }
              : m
          )
        );
        pollingRef.current.delete(jobId);
      } else {
        const timer = setTimeout(() => pollJobStatus(jobId, messageId, attemptCount + 1), 3000);
        pollingRef.current.set(jobId, timer);
      }
    }
  }, []);

  // Generer une video pour un message
  const handleGenerateVideo = useCallback(async (messageId: string, content: string) => {
    if (!content.trim()) return;

    setGeneratingMessageId(messageId);

    try {
      const response = await fetch('/api/chat-video/generate-video', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          content: content.trim(),
          characterImage: character?.image || null,
        }),
      });
      const data = await response.json();

      if (!response.ok || !data.jobId) {
        console.error('Erreur generate-video:', data.error);
        setGeneratingMessageId(null);
        return;
      }

      setGeneratingMessageId(null);
      setMessages(prev =>
        prev.map(m =>
          m.id === messageId
            ? { ...m, status: 'processing' as const, jobId: data.jobId }
            : m
        )
      );
      pollJobStatus(data.jobId, messageId);
    } catch (error) {
      console.error('Erreur generate-video:', error);
      setGeneratingMessageId(null);
    }
  }, [character, pollJobStatus]);

  const handleClearMessages = () => {
    setMessages([]);
    setShowMenu(false);
    const params = new URLSearchParams(window.location.search);
    const charId = params.get('characterId');
    const scnId = params.get('sceneId');
    const query = new URLSearchParams();
    if (charId) query.set('characterId', charId);
    if (scnId) query.set('sceneId', scnId);
    fetch(`/api/messages?${query.toString()}`, { method: 'DELETE' }).catch(() => {});
  };

  const sendMessage = async () => {
    if (!input.trim() || isLoading) return;
    if (!character && !isSceneMode) return;

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
    const userInput = input.trim();
    setInput('');
    setIsLoading(true);

    saveMessageToDB({ role: 'user', content: userInput });

    const history = messages
      .filter(m => m.status === 'completed' && m.content)
      .slice(-10)
      .map(m => ({ role: m.role, content: m.content }));

    try {
      const res = await fetch('/api/chat-video', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          message: userInput,
          conversationHistory: history,
          characterName: isSceneMode ? sceneName : character?.name,
          characterDescription: isSceneMode ? `Un personnage dans la scène ${sceneName}` : character?.description,
          characterLocation: isSceneMode ? sceneLocation : character?.location,
        }),
      });

      const data = await res.json();
      const aiText = data.aiResponse || 'Désolé, une erreur est survenue.';

      const dbId = await saveMessageToDB({ role: 'assistant', content: aiText });

      setMessages(prev =>
        prev.map(m =>
          m.id === assistantId
            ? { ...m, content: aiText, status: 'completed' as const, dbId: dbId || undefined }
            : m
        )
      );
    } catch {
      setMessages(prev =>
        prev.map(m =>
          m.id === assistantId
            ? { ...m, content: 'Erreur de connexion.', status: 'failed' as const }
            : m
        )
      );
    }

    setIsLoading(false);
    inputRef.current?.focus();
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  };

  const bgImage = sceneImage || character?.cityImage;

  return (
    <div className={`chat-container ${bgImage ? 'chat-container-with-bg' : ''}`}>
      {/* Fond fixe */}
      {bgImage && (
        <div
          className="chat-bg-fixed chat-bg-parallax"
          style={{
            backgroundImage: `linear-gradient(rgba(0,0,0,0.3), rgba(0,0,0,0.4)), url(${bgImage})`,
            backgroundPosition: `${bgOffset.x}% ${bgOffset.y}%`,
          }}
          aria-hidden
        />
      )}

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
            {isSceneMode ? (
              <span className="chat-header-scene-icon">🎬</span>
            ) : (
              <img
                src={character?.image || '/avatar-1.png'}
                alt={character?.name || 'Avatar'}
              />
            )}
          </div>
          <div className="chat-header-text">
            <span className="chat-header-name">{isSceneMode ? sceneName : (character?.name || 'Avatar')}</span>
            <span className="chat-header-location">{isSceneMode ? (sceneLocation || '') : (character?.location || '')}</span>
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
            <p>{isSceneMode ? `Commencez une conversation à ${sceneName}` : `Commencez une conversation avec ${character?.name || 'votre avatar IA'}`}</p>
          </div>
        )}

        {messages.map(message => (
          <div
            key={message.id}
            className={`chat-bubble-row ${message.role === 'user' ? 'chat-bubble-right' : 'chat-bubble-left'}`}
          >
            {message.role === 'assistant' && (
              <div className="chat-bubble-avatar-small">
                {isSceneMode ? (
                  <span className="chat-bubble-scene-icon">🎬</span>
                ) : (
                  <img src={character?.image || '/avatar-1.png'} alt="" />
                )}
              </div>
            )}
            <div>
              {message.role === 'user' ? (
                <>
                  <div className="chat-bubble chat-bubble-user">
                    <p>{message.content}</p>
                  </div>
                  <div className="chat-bubble-meta chat-meta-right">
                    <span>{message.time}</span>
                    <CheckCheck size={14} />
                  </div>
                </>
              ) : (
                <>
                  <div className="chat-bubble-wrapper">
                    <div className="chat-bubble chat-bubble-assistant">
                      {message.status === 'sending' && (
                        <div className="chat-typing">
                          <span /><span /><span />
                        </div>
                      )}

                      {message.status === 'generating' && (
                        <div className="chat-progress-container">
                          <div className="chat-progress-label">
                            <span>Préparation...</span>
                            <span className="chat-progress-time">~15s</span>
                          </div>
                          <div className="chat-progress-bar">
                            <div className="chat-progress-fill" />
                          </div>
                        </div>
                      )}

                      {message.status === 'processing' && (
                        <div className="chat-progress-container">
                          {message.content && <p style={{ marginBottom: '0.5rem' }}>{message.content}</p>}
                          <div className="chat-progress-label">
                            <span>Génération vidéo...</span>
                            <span className="chat-progress-time">~40s</span>
                          </div>
                          <div className="chat-progress-bar">
                            <div className="chat-progress-fill" />
                          </div>
                        </div>
                      )}

                      {message.status !== 'sending' && message.status !== 'generating' && message.status !== 'processing' && message.content && (
                        <p>{message.content}</p>
                      )}

                      {message.videoUrl && message.showVideo && (
                        <div
                          className="chat-video-bubble"
                          onClick={(e) => {
                            const video = (e.currentTarget as HTMLDivElement).querySelector('video');
                            if (!video) return;
                            if (video.paused) video.play();
                            else video.pause();
                          }}
                          onDoubleClick={() => {
                            if (message.videoUrl) setExpandedVideoUrl(message.videoUrl);
                          }}
                        >
                          <video
                            key={message.videoUrl}
                            src={message.videoUrl}
                            autoPlay
                            playsInline
                            preload="auto"
                          />
                        </div>
                      )}

                      {message.imageUrl && (
                        <div className="chat-image-bubble">
                          <img src={message.imageUrl} alt="Photo" />
                        </div>
                      )}
                    </div>

                    {message.content && !message.videoUrl && message.status === 'completed' && (
                      <>
                        {generatingMessageId === message.id ? (
                          <div className="chat-play-btn">
                            <div className="chat-play-spinner">
                              <div className="chat-play-spinner-inner" />
                            </div>
                          </div>
                        ) : (
                          <button
                            type="button"
                            className="chat-play-btn"
                            onClick={() => handleGenerateVideo(message.id, message.content)}
                            aria-label="Générer la vidéo"
                          >
                            <div className="neon-border-spinner-wrapper" style={{ width: '100%', height: '100%' }}>
                              <div className="neon-border-spinner" aria-hidden />
                              <Play size={14} fill="currentColor" style={{ marginLeft: 2 }} />
                            </div>
                          </button>
                        )}
                      </>
                    )}
                  </div>
                  <div className="chat-bubble-meta chat-meta-left">
                    <span>{message.time}</span>
                  </div>
                </>
              )}
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
          disabled={isLoading || !input.trim() || (!character && !isSceneMode)}
          className="chat-send-btn"
        >
          <Send size={20} />
        </button>
      </div>

      {/* Overlay video plein ecran */}
      {expandedVideoUrl && (
        <div className="chat-video-overlay" onClick={() => setExpandedVideoUrl(null)}>
          <button
            type="button"
            className="chat-video-overlay-close"
            onClick={(e) => { e.stopPropagation(); setExpandedVideoUrl(null); }}
            aria-label="Fermer"
          >
            <X size={20} />
          </button>
          <div onClick={(e) => e.stopPropagation()}>
            <video
              key={expandedVideoUrl}
              src={expandedVideoUrl}
              controls
              autoPlay
              playsInline
            />
          </div>
        </div>
      )}
    </div>
  );
}
