'use client'

import { useState, useRef, useEffect } from 'react'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { FontAwesomeIcon } from '@fortawesome/react-fontawesome'
import { faHouse, faCompass, faMessage, faWandMagicSparkles, faUser, faUsers, faVideo } from '@fortawesome/free-solid-svg-icons'
import type { IconDefinition } from '@fortawesome/fontawesome-svg-core'

type NavItem = 'accueil' | 'discover' | 'messages' | 'creer' | 'profil'

const NAV_ITEMS: { id: NavItem; label: string; icon: IconDefinition; href?: string }[] = [
  { id: 'accueil', label: 'Accueil', icon: faHouse, href: '/' },
  { id: 'discover', label: 'Discover', icon: faCompass, href: '/discover' },
  { id: 'creer', label: 'Créer', icon: faWandMagicSparkles },
  { id: 'messages', label: 'Messages', icon: faMessage, href: '/messages' },
  { id: 'profil', label: 'Profil', icon: faUser, href: '/profil' },
]

const CREER_OPTIONS: { label: string; href: string; icon: IconDefinition }[] = [
  { label: 'Personnages', href: '/creer', icon: faUsers },
  { label: 'Scène', href: '/creer/scene', icon: faVideo },
]

export default function NavBar() {
  const pathname = usePathname()
  const [creerOpen, setCreerOpen] = useState(false)
  const dropdownRef = useRef<HTMLDivElement>(null)

  // Fermer le menu en cliquant à l'extérieur (hooks toujours appelés en premier)
  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
        setCreerOpen(false)
      }
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [])

  // Masquer la navbar sur certaines pages (onboarding, chat, discover, scene, lieux)
  if (pathname.startsWith('/chat') || pathname.startsWith('/discover') || pathname.startsWith('/creer')) {
    return null
  }

  const isActive = (href: string) => {
    if (href === '/') return pathname === '/'
    return pathname.startsWith(href)
  }

  const isCreerActive = pathname.startsWith('/creer')

  return (
    <nav className="bottom-nav">
      <div className="bottom-nav-items">
        {NAV_ITEMS.map((item) => {
          if (item.id === 'creer') {
            return (
              <div key={item.id} className="relative flex-1 flex justify-center" ref={dropdownRef}>
                <button
                  type="button"
                  onClick={() => setCreerOpen(!creerOpen)}
                  className={`bottom-nav-item w-full ${creerOpen || isCreerActive ? 'active' : ''}`}
                >
                  <span className="bottom-nav-icon"><FontAwesomeIcon icon={item.icon} /></span>
                </button>
                {creerOpen && (
                  <div className="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 min-w-[140px] bg-[#1a1a1a] border border-[#2A2A2A] rounded-xl overflow-hidden shadow-xl z-[600]">
                    {CREER_OPTIONS.map((opt, index) => (
                      <Link
                        key={opt.href}
                        href={opt.href}
                        className={`flex items-center gap-2 px-4 py-3 text-sm text-white hover:bg-[#252525] transition-colors ${index < CREER_OPTIONS.length - 1 ? 'border-b border-[#2A2A2A]' : ''}`}
                        onClick={() => setCreerOpen(false)}
                      >
                        <FontAwesomeIcon icon={opt.icon} className="w-4 h-4 text-[#A3A3A3]" />
                        {opt.label}
                      </Link>
                    ))}
                  </div>
                )}
              </div>
            )
          }
          return (
            <Link
              key={item.id}
              href={item.href!}
              className={`bottom-nav-item ${isActive(item.href!) ? 'active' : ''}`}
            >
              <span className="bottom-nav-icon"><FontAwesomeIcon icon={item.icon} /></span>
            </Link>
          )
        })}
      </div>
    </nav>
  )
}
