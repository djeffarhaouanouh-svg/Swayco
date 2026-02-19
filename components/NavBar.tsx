'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { FontAwesomeIcon } from '@fortawesome/react-fontawesome'
import { faHouse, faCompass, faMessage, faWandMagicSparkles, faUser } from '@fortawesome/free-solid-svg-icons'
import type { IconDefinition } from '@fortawesome/fontawesome-svg-core'

type NavItem = 'accueil' | 'discover' | 'messages' | 'creer' | 'profil'

const NAV_ITEMS: { id: NavItem; label: string; icon: IconDefinition; href: string }[] = [
  { id: 'accueil', label: 'Accueil', icon: faHouse, href: '/' },
  { id: 'discover', label: 'Discover', icon: faCompass, href: '/discover' },
  { id: 'creer', label: 'Créer', icon: faWandMagicSparkles, href: '/creer' },
  { id: 'messages', label: 'Messages', icon: faMessage, href: '/messages' },
  { id: 'profil', label: 'Profil', icon: faUser, href: '/profil' },
]

export default function NavBar() {
  const pathname = usePathname()

  // Masquer la navbar sur certaines pages (onboarding, chat, discover, scene, lieux)
  if (pathname.startsWith('/chat') || pathname.startsWith('/discover') || pathname.startsWith('/creer') || pathname.startsWith('/guide-eiffel')) {
    return null
  }

  const isActive = (href: string) => {
    if (href === '/') return pathname === '/'
    return pathname.startsWith(href)
  }

  return (
    <nav className="bottom-nav">
      <div className="bottom-nav-items">
        {NAV_ITEMS.map((item) => (
          <Link
            key={item.id}
            href={item.href}
            className={`bottom-nav-item ${isActive(item.href) ? 'active' : ''}`}
          >
            <span className="bottom-nav-icon"><FontAwesomeIcon icon={item.icon} /></span>
          </Link>
        ))}
      </div>
    </nav>
  )
}
