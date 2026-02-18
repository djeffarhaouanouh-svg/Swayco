'use client'

import { useState, useRef, useEffect, useCallback } from 'react'
import { useRouter } from 'next/navigation'
import { ArrowLeft, Send, ChevronRight, MessageCircle, MoreVertical, Trash2 } from 'lucide-react'

const IMAGE_MAP: Record<string, string> = {
  intro:          '/intro.jpg',
  construction:   '/intro.jpg',
  etage_1:        '/etage-1.jpg',
  etage1:         '/etage-1.jpg',
  premier_etage:  '/etage-1.jpg',
  etage_2:        '/etage-2.avif',
  etage2:         '/etage-2.avif',
  deuxieme_etage: '/etage-2.avif',
  sommet:         '/sommet.jpeg',
  top:            '/sommet.jpeg',
}

const N8N_URL = 'https://ouistitiii.app.n8n.cloud/webhook/guide-eiffel'
const SESSION_ID = `guide_${Math.random().toString(36).slice(2)}`

function parseN8nReply(reply: string): Record<string, string> {
  // Supprime le préfixe [object Object] si présent
  const cleaned = reply.replace(/^\[object Object\]\s*/i, '')
  // Split sur les sauts de ligne (littéraux \n ou vrais retours)
  const lines = cleaned.split(/\\n|\n/).map(l => l.trim()).filter(Boolean)
  const result: Record<string, string> = {}
  for (const line of lines) {
    const eqIndex = line.indexOf(' = ')
    if (eqIndex > 0) {
      const key = line.slice(0, eqIndex).trim()
      const value = line.slice(eqIndex + 3).trim()
      if (key) result[key] = value
    }
  }
  return result
}

async function callGuide(payload: Record<string, string>) {
  const res = await fetch(N8N_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  const raw = await res.json()

  // Log pour debug — visible dans DevTools > Console
  console.log('[Guide n8n raw]', JSON.stringify(raw))

  const item = Array.isArray(raw) ? raw[0] : raw

  // n8n renvoie { reply: { reply: "string..." } } — on descend jusqu'à la string
  let current = item
  while (current?.reply !== undefined) {
    current = current.reply
  }

  // current est soit une string à parser, soit déjà l'objet final
  if (typeof current === 'string') {
    return parseN8nReply(current)
  }
  return current
}

interface ChatMessage {
  id: string
  role: 'user' | 'assistant'
  content: string
  time: string
  isStep?: boolean
  stepTitle?: string
  stepAnecdote?: string
  stepImage?: string
}

const getTime = () =>
  new Date().toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })

export default function EiffelGuidePage() {
  const router = useRouter()
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [currentStep, setCurrentStep] = useState('intro')
  const [hasNextStep, setHasNextStep] = useState(true)
  const [input, setInput] = useState('')
  const [isLoading, setIsLoading] = useState(false)
  const [showInput, setShowInput] = useState(false)
  const [showMenu, setShowMenu] = useState(false)
  const [bgOffset, setBgOffset] = useState({ x: 50, y: 50 })
  const messagesEndRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)

  // Fermer le menu en cliquant ailleurs
  useEffect(() => {
    if (!showMenu) return
    const handle = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) setShowMenu(false)
    }
    document.addEventListener('mousedown', handle)
    return () => document.removeEventListener('mousedown', handle)
  }, [showMenu])

  const handleClear = () => {
    setMessages([])
    setCurrentStep('intro')
    setHasNextStep(true)
    setShowInput(false)
    setShowMenu(false)
  }

  // Parallaxe gyroscope
  useEffect(() => {
    if (typeof window === 'undefined' || !('DeviceOrientationEvent' in window)) return
    const handle = (e: DeviceOrientationEvent) => {
      const x = Math.max(20, Math.min(80, 50 + (e.gamma ?? 0) * 0.08))
      const y = Math.max(20, Math.min(80, 50 + (e.beta ?? 0) * 0.08))
      setBgOffset({ x, y })
    }
    window.addEventListener('deviceorientation', handle)
    return () => window.removeEventListener('deviceorientation', handle)
  }, [])

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages, isLoading])

  const fetchNextStep = useCallback(async () => {
    setIsLoading(true)
    setShowInput(false)

    const loadingId = Date.now().toString()
    setMessages(prev => [...prev, {
      id: loadingId,
      role: 'assistant',
      content: '',
      time: getTime(),
    }])

    try {
      const data = await callGuide({ sessionId: SESSION_ID, mode: 'next', step: currentStep })

      if (data.type === 'step') {
        const image = IMAGE_MAP[currentStep] ?? IMAGE_MAP['intro']
        setMessages(prev => prev.map(m =>
          m.id === loadingId ? {
            ...m,
            content: data.text,
            isStep: true,
            stepTitle: data.title,
            stepAnecdote: data.anecdote,
            stepImage: image,
          } : m
        ))
        setCurrentStep(data.next_step ?? '')
        setHasNextStep(!!data.next_step)
      }
    } catch {
      setMessages(prev => prev.map(m =>
        m.id === loadingId
          ? { ...m, content: 'Impossible de charger l\'étape. Réessayez.' }
          : m
      ))
    } finally {
      setIsLoading(false)
    }
  }, [currentStep])

  const sendQuestion = useCallback(async () => {
    const q = input.trim()
    if (!q || isLoading) return

    const userMsg: ChatMessage = {
      id: Date.now().toString(),
      role: 'user',
      content: q,
      time: getTime(),
    }
    const loadingId = (Date.now() + 1).toString()
    const loadingMsg: ChatMessage = {
      id: loadingId,
      role: 'assistant',
      content: '',
      time: getTime(),
    }

    setMessages(prev => [...prev, userMsg, loadingMsg])
    setInput('')
    setShowInput(false)
    setIsLoading(true)

    try {
      const data = await callGuide({ sessionId: SESSION_ID, mode: 'question', step: currentStep, question: q })

      setMessages(prev => prev.map(m =>
        m.id === loadingId
          ? { ...m, content: data.type === 'answer' ? data.text : 'Réponse non disponible.' }
          : m
      ))
    } catch {
      setMessages(prev => prev.map(m =>
        m.id === loadingId
          ? { ...m, content: 'Erreur de connexion. Réessayez.' }
          : m
      ))
    } finally {
      setIsLoading(false)
      inputRef.current?.focus()
    }
  }, [input, isLoading, currentStep])

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      sendQuestion()
    }
  }

  const bgImage = IMAGE_MAP[currentStep] ?? IMAGE_MAP['intro']

  return (
    <div className="chat-container chat-container-with-bg">
      {/* Fond parallaxe */}
      <div
        className="chat-bg-fixed chat-bg-parallax"
        style={{
          backgroundImage: `linear-gradient(rgba(0,0,0,0.45), rgba(0,0,0,0.55)), url(${bgImage})`,
          backgroundPosition: `${bgOffset.x}% ${bgOffset.y}%`,
        }}
        aria-hidden
      />

      {/* Header */}
      <header className="chat-header">
        <button
          type="button"
          onClick={() => router.back()}
          className="chat-back-btn"
          aria-label="Retour"
        >
          <ArrowLeft size={22} />
        </button>
        <div className="chat-header-info">
          <div className="chat-header-avatar">
            <span className="chat-header-scene-icon" style={{ fontSize: 20 }}>🗼</span>
          </div>
          <div className="chat-header-text">
            <span className="chat-header-name">Guide Tour Eiffel</span>
            <span className="chat-header-location">Paris, France</span>
          </div>
        </div>
        <div className="chat-header-actions" ref={menuRef}>
          <button onClick={() => setShowMenu(!showMenu)} className="chat-menu-btn">
            <MoreVertical size={18} />
          </button>
          {showMenu && (
            <div className="chat-dropdown">
              <button onClick={handleClear} className="chat-dropdown-item chat-dropdown-danger">
                <Trash2 size={16} />
                <span>Recommencer la visite</span>
              </button>
            </div>
          )}
        </div>
      </header>

      {/* Messages */}
      <div className="chat-messages">
        {messages.length === 0 && !isLoading && (
          <div className="chat-empty">
            <p>Appuyez sur <strong>Étape suivante</strong> pour commencer la visite guidée</p>
          </div>
        )}

        {messages.map(msg => (
          <div
            key={msg.id}
            className={`chat-bubble-row ${msg.role === 'user' ? 'chat-bubble-right' : 'chat-bubble-left'}`}
          >
            {msg.role === 'assistant' && (
              <div className="chat-bubble-avatar-small">
                <span className="chat-bubble-scene-icon" style={{ fontSize: 18 }}>🗼</span>
              </div>
            )}

            <div>
              {msg.role === 'user' ? (
                <>
                  <div className="chat-bubble chat-bubble-user">
                    <p>{msg.content}</p>
                  </div>
                  <div className="chat-bubble-meta chat-meta-right">
                    <span>{msg.time}</span>
                  </div>
                </>
              ) : (
                <>
                  <div className="chat-bubble-wrapper">
                    <div className="chat-bubble chat-bubble-assistant">
                      {/* Loading dots */}
                      {!msg.content && !msg.isStep && (
                        <div className="chat-typing">
                          <span /><span /><span />
                        </div>
                      )}

                      {/* Step card */}
                      {msg.isStep && (
                        <div style={{ overflow: 'hidden', borderRadius: 12 }}>
                          {msg.stepImage && (
                            <img
                              src={msg.stepImage}
                              alt={msg.stepTitle ?? 'Tour Eiffel'}
                              style={{ width: '100%', height: 160, objectFit: 'cover', display: 'block' }}
                            />
                          )}
                          <div style={{ padding: '12px 4px 4px' }}>
                            {msg.stepTitle && (
                              <p style={{ fontWeight: 700, marginBottom: 6, fontSize: 15 }}>{msg.stepTitle}</p>
                            )}
                            <p>{msg.content}</p>
                            {msg.stepAnecdote && (
                              <div style={{
                                marginTop: 10,
                                background: 'rgba(245,158,11,0.12)',
                                border: '1px solid rgba(245,158,11,0.25)',
                                borderRadius: 10,
                                padding: '8px 10px',
                              }}>
                                <p style={{ fontSize: 11, fontWeight: 700, color: '#f59e0b', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 4 }}>
                                  Anecdote
                                </p>
                                <p style={{ fontSize: 12, color: '#d1d5db' }}>{msg.stepAnecdote}</p>
                              </div>
                            )}
                          </div>
                        </div>
                      )}

                      {/* Simple answer */}
                      {!msg.isStep && msg.content && (
                        <p>{msg.content}</p>
                      )}
                    </div>
                  </div>
                  <div className="chat-bubble-meta chat-meta-left">
                    <span>{msg.time}</span>
                  </div>
                </>
              )}
            </div>
          </div>
        ))}

        <div ref={messagesEndRef} />
      </div>

      {/* Input bar */}
      <div className="chat-input-bar" style={{ flexDirection: 'column', gap: 8, alignItems: 'stretch' }}>
        {/* Boutons d'action */}
        {!showInput && (
          <div style={{ display: 'flex', gap: 8 }}>
            {hasNextStep && (
              <button
                type="button"
                onClick={fetchNextStep}
                disabled={isLoading}
                style={{
                  flex: 1,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  gap: 6,
                  padding: '10px 14px',
                  background: isLoading ? 'rgba(245,158,11,0.4)' : '#f59e0b',
                  color: '#000',
                  fontWeight: 700,
                  fontSize: 14,
                  borderRadius: 22,
                  border: 'none',
                  cursor: isLoading ? 'not-allowed' : 'pointer',
                  transition: 'background 0.2s',
                }}
              >
                <ChevronRight size={16} />
                {messages.length === 0 ? 'Commencer la visite' : 'Étape suivante'}
              </button>
            )}
            <button
              type="button"
              onClick={() => { setShowInput(true); setTimeout(() => inputRef.current?.focus(), 50) }}
              disabled={isLoading}
              style={{
                flex: 1,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                gap: 6,
                padding: '10px 14px',
                background: 'rgba(255,255,255,0.1)',
                color: '#fff',
                fontWeight: 600,
                fontSize: 14,
                borderRadius: 22,
                border: '1px solid rgba(255,255,255,0.15)',
                cursor: isLoading ? 'not-allowed' : 'pointer',
                transition: 'background 0.2s',
              }}
            >
              <MessageCircle size={16} />
              Poser une question
            </button>
          </div>
        )}

        {/* Champ question */}
        {showInput && (
          <div className="chat-input-wrapper" style={{ display: 'flex', alignItems: 'center', gap: 8, width: '100%' }}>
            <input
              ref={inputRef}
              type="text"
              value={input}
              onChange={e => setInput(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Posez votre question…"
              disabled={isLoading}
              style={{ flex: 1 }}
            />
            <button
              type="button"
              onClick={sendQuestion}
              disabled={isLoading || !input.trim()}
              className="chat-send-btn"
            >
              <Send size={20} />
            </button>
          </div>
        )}

        {/* Fin de visite */}
        {!hasNextStep && (
          <p style={{ textAlign: 'center', color: 'rgba(255,255,255,0.5)', fontSize: 13, margin: 0 }}>
            🏁 Visite terminée — vous pouvez encore poser des questions
          </p>
        )}
      </div>
    </div>
  )
}
