'use client'

import { useEffect, useRef, useState, useCallback } from 'react'
import { Play, Pause, Volume2, MoreVertical, ChevronDown, Menu, X, User, Home, Compass, MessageCircle, Wand2, Crown, MessageSquare, Mail, Share2 } from 'lucide-react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import * as maptilersdk from '@maptiler/sdk'
import '@maptiler/sdk/dist/maptiler-sdk.css'
import { WorldItem, countries, getCountry, COUNTRY_PLACEHOLDER, type MusicTrack, type Character, type Place, type Scene } from '@/data/worldData'
import ImageCarousel from '@/components/ImageCarousel'
import CharacterOverlay from '@/components/CharacterOverlay'
import PlaceOverlay from '@/components/PlaceOverlay'
import SceneOverlay from '@/components/SceneOverlay'

type FilterType = 'all' | 'character' | 'place' | 'scene'

const CLUSTER_ZOOM_THRESHOLD = 5

function toTrack(item: string | MusicTrack): MusicTrack {
  return typeof item === 'string' ? { url: item, start: 0, end: 30 } : item
}

function createMarkerElement(item: WorldItem, onClick: () => void): HTMLDivElement {
  const el = document.createElement('div')

  if (item.type === 'character') {
    el.className = 'map-bubble'
    el.innerHTML = `
      <div class="map-bubble-avatar">
        <img src="${item.image}" alt="${item.name}" />
        <span class="map-bubble-name-overlay">${item.name}</span>
      </div>
    `
  } else if (item.type === 'scene') {
    el.className = 'map-scene'
    el.innerHTML = `
      <div class="map-scene-card">
        <div class="map-scene-frame">
          <img src="${item.image}" alt="${item.name}" />
          <span class="map-scene-icon">🎬</span>
        </div>
        <span class="map-scene-label">${item.name}</span>
      </div>
    `
  } else {
    el.className = 'map-bubble place'
    el.innerHTML = `
      <span class="map-bubble-name">${item.name}</span>
      <div class="map-bubble-avatar">
        <img src="${item.image}" alt="${item.name}" />
      </div>
    `
  }

  el.addEventListener('click', (e) => {
    e.stopPropagation()
    onClick()
  })
  return el
}

function createClusterElement(count: number, onClick: () => void): HTMLDivElement {
  const el = document.createElement('div')
  el.className = 'map-cluster'
  el.innerHTML = `<span>${count}</span>`
  el.addEventListener('click', (e) => {
    e.stopPropagation()
    onClick()
  })
  return el
}

function formatTime(seconds: number) {
  const m = Math.floor(seconds / 60)
  const s = Math.floor(seconds % 60)
  return `${m}:${s.toString().padStart(2, '0')}`
}

function SingleTrackPlayer({
  track,
  id,
  playingId,
  onStartPlaying,
}: {
  track: MusicTrack
  id: number
  playingId: number | null
  onStartPlaying: (id: number) => void
}) {
  const start = track.start ?? 0
  const end = track.end ?? 30
  const maxDuration = end - start

  const [isPlaying, setIsPlaying] = useState(false)
  const [currentTime, setCurrentTime] = useState(start)
  const [playbackRate, setPlaybackRate] = useState(1)
  const [moreOpen, setMoreOpen] = useState(false)
  const audioRef = useRef<HTMLAudioElement | null>(null)
  const moreRef = useRef<HTMLDivElement>(null)
  const displayTime = Math.max(0, currentTime - start)

  useEffect(() => {
    const audio = audioRef.current
    if (!audio || !track.url) return
    audio.playbackRate = playbackRate
  }, [playbackRate])

  useEffect(() => {
    if (playingId !== null && playingId !== id) {
      const audio = audioRef.current
      if (audio) {
        audio.pause()
        setIsPlaying(false)
      }
    }
  }, [playingId, id])

  useEffect(() => {
    const audio = audioRef.current
    if (!audio || !track.url) return
    const onLoaded = () => {
      audio.currentTime = start
      setCurrentTime(start)
      audio.playbackRate = playbackRate
    }
    const onTimeUpdate = () => {
      const t = audio.currentTime
      setCurrentTime(t)
      if (t >= end) {
        audio.pause()
        audio.currentTime = end
        setIsPlaying(false)
        setCurrentTime(end)
      }
    }
    const onEnded = () => setIsPlaying(false)
    audio.addEventListener('loadedmetadata', onLoaded)
    audio.addEventListener('timeupdate', onTimeUpdate)
    audio.addEventListener('ended', onEnded)
    if (audio.readyState >= 1) onLoaded()
    return () => {
      audio.removeEventListener('loadedmetadata', onLoaded)
      audio.removeEventListener('timeupdate', onTimeUpdate)
      audio.removeEventListener('ended', onEnded)
      audio.pause()
    }
  }, [track.url, start, end])

  useEffect(() => {
    const close = (e: MouseEvent) => {
      if (moreRef.current && !moreRef.current.contains(e.target as Node)) setMoreOpen(false)
    }
    document.addEventListener('mousedown', close)
    return () => document.removeEventListener('mousedown', close)
  }, [])

  const togglePlay = async () => {
    const audio = audioRef.current
    if (!audio) return
    if (isPlaying) {
      audio.pause()
      setIsPlaying(false)
    } else {
      onStartPlaying(id)
      const now = audio.currentTime
      if (now < start || now >= end || displayTime >= maxDuration) {
        audio.currentTime = start
        setCurrentTime(start)
      }
      try {
        await audio.play()
        setIsPlaying(true)
      } catch (err) {
        console.warn('Lecture audio:', err)
      }
    }
  }

  const handleRestart = () => {
    const audio = audioRef.current
    if (audio) {
      audio.currentTime = start
      setCurrentTime(start)
      setMoreOpen(false)
    }
  }

  const handleToggleSpeed = () => {
    const nextRate = playbackRate === 1 ? 2 : 1
    setPlaybackRate(nextRate)
    const audio = audioRef.current
    if (audio) audio.playbackRate = nextRate
    setMoreOpen(false)
  }

  const handleProgressClick = (e: React.MouseEvent<HTMLDivElement>) => {
    const audio = audioRef.current
    if (!audio) return
    const rect = e.currentTarget.getBoundingClientRect()
    const x = (e.clientX - rect.left) / rect.width
    const targetDisplay = Math.min(x * maxDuration, maxDuration)
    const targetTime = start + targetDisplay
    audio.currentTime = targetTime
    setCurrentTime(targetTime)
  }

  return (
    <div className="country-music-track">
      {(track.artist || track.title) && (
        <div className="country-music-info">
          <span className="country-music-artist">{track.artist}</span>
          {track.title && <span className="country-music-title">&ldquo;{track.title}&rdquo;</span>}
        </div>
      )}
      <div className="country-music-player">
      <audio
        ref={audioRef}
        src={track.url}
        preload="metadata"
      />
      <button
        type="button"
        className="country-music-play-btn"
        onClick={togglePlay}
        aria-label={isPlaying ? 'Pause' : 'Lecture'}
      >
        {isPlaying ? <Pause className="w-5 h-5" /> : <Play className="w-5 h-5" />}
      </button>
      <span className="country-music-time">
        {formatTime(displayTime)} / {formatTime(maxDuration)}
        {playbackRate === 2 && <span className="country-music-speed-badge">x2</span>}
      </span>
      <div
        className="country-music-progress"
        onClick={handleProgressClick}
        role="progressbar"
        aria-valuenow={maxDuration ? (displayTime / maxDuration) * 100 : 0}
        aria-valuemin={0}
        aria-valuemax={100}
      >
        <div
          className="country-music-progress-fill"
          style={{ width: `${Math.max(0, Math.min(100, (displayTime / maxDuration) * 100))}%` }}
        />
      </div>
      <div className="country-music-volume" aria-hidden>
        <Volume2 className="w-5 h-5" />
      </div>
      <div className="country-music-more-wrapper" ref={moreRef}>
        <button
          type="button"
          className="country-music-more"
          onClick={() => setMoreOpen(!moreOpen)}
          aria-label="Options"
          aria-expanded={moreOpen}
        >
          <MoreVertical className="w-5 h-5" />
        </button>
        {moreOpen && (
          <div className="country-music-more-dropdown">
            <button type="button" onClick={handleRestart}>
              ↺ Relancer à zéro
            </button>
            <button type="button" onClick={handleToggleSpeed}>
              {playbackRate === 1 ? '▶ Vitesse x2' : '▶ Vitesse x1'}
            </button>
          </div>
        )}
      </div>
      </div>
    </div>
  )
}

function CountryMusicPlayer({ tracks = [] }: { tracks?: (string | MusicTrack)[] }) {
  const normalized = (tracks ?? []).map(toTrack).filter((t) => t.url)
  const [expanded, setExpanded] = useState(false)
  const [playingId, setPlayingId] = useState<number | null>(null)

  if (normalized.length === 0) return null

  return (
    <div className="country-music">
      <button
        type="button"
        className="country-music-toggle"
        onClick={() => setExpanded(!expanded)}
        aria-expanded={expanded}
      >
        <ChevronDown className={`country-music-arrow ${expanded ? 'open' : ''}`} size={20} />
      </button>
      {expanded && (
        <div className="country-music-list">
          {normalized.map((track, i) => (
            <SingleTrackPlayer
              key={i}
              track={track}
              id={i}
              playingId={playingId}
              onStartPlaying={setPlayingId}
            />
          ))}
        </div>
      )}
    </div>
  )
}

export default function WorldExplorer() {
  const mapContainer = useRef<HTMLDivElement>(null)
  const map = useRef<maptilersdk.Map | null>(null)
  const markersRef = useRef<maptilersdk.Marker[]>([])
  const filterRef = useRef<FilterType>('all')
  const clusterModeRef = useRef<boolean | null>(null)

  const router = useRouter()
  const [characters, setCharacters] = useState<Character[]>([])
  const [places, setPlaces] = useState<Place[]>([])
  const [scenes, setScenes] = useState<Scene[]>([])
  const [currentFilter, setCurrentFilter] = useState<FilterType>('all')
  const [filterOpen, setFilterOpen] = useState(false)
  const [burgerOpen, setBurgerOpen] = useState(false)
  const filterDropdownRef = useRef<HTMLDivElement>(null)
  const [selectedItem, setSelectedItem] = useState<WorldItem | null>(null)
  const [selectedCountry, setSelectedCountry] = useState<{ country: string; center: [number, number]; zoom: number; description?: string; images?: string[]; music?: (string | MusicTrack)[] } | null>(null)
  const [isSheetOpen, setIsSheetOpen] = useState(false)
  const [characterOverlay, setCharacterOverlay] = useState<Character | null>(null)
  const [placeOverlay, setPlaceOverlay] = useState<Place | null>(null)
  const [sceneOverlay, setSceneOverlay] = useState<Scene | null>(null)

  filterRef.current = currentFilter
  const charactersRef = useRef<Character[]>([])
  charactersRef.current = characters
  const placesRef = useRef<Place[]>([])
  placesRef.current = places
  const scenesRef = useRef<Scene[]>([])
  scenesRef.current = scenes

  // Fetch characters, places and scenes from DB
  useEffect(() => {
    fetch('/api/characters', { cache: 'no-store' })
      .then(res => res.json())
      .then(data => { if (Array.isArray(data)) setCharacters(data) })
      .catch(err => console.error('Erreur chargement personnages:', err))
    fetch('/api/places')
      .then(res => res.json())
      .then(data => { if (Array.isArray(data)) setPlaces(data) })
      .catch(err => console.error('Erreur chargement lieux:', err))
    fetch('/api/scenes')
      .then(res => res.json())
      .then(data => { if (Array.isArray(data)) setScenes(data) })
      .catch(err => console.error('Erreur chargement scènes:', err))
  }, [])

  useEffect(() => {
    const close = (e: MouseEvent) => {
      if (filterDropdownRef.current && !filterDropdownRef.current.contains(e.target as Node)) setFilterOpen(false)
    }
    document.addEventListener('mousedown', close)
    return () => document.removeEventListener('mousedown', close)
  }, [])

  useEffect(() => {
    if (burgerOpen) {
      document.body.style.overflow = 'hidden'
    } else {
      document.body.style.overflow = ''
    }
    return () => { document.body.style.overflow = '' }
  }, [burgerOpen])

  const clearMarkers = useCallback(() => {
    markersRef.current.forEach(m => m.remove())
    markersRef.current = []
  }, [])

  const updateMarkers = useCallback((m: maptilersdk.Map) => {
    const filter = filterRef.current
    const zoom = m.getZoom()
    const shouldCluster = zoom < CLUSTER_ZOOM_THRESHOLD
    const zoomedOut = zoom < CLUSTER_ZOOM_THRESHOLD

    // Skip if mode hasn't changed
    if (shouldCluster === clusterModeRef.current) return

    clearMarkers()
    clusterModeRef.current = shouldCluster

    // Zoomé loin : monuments + clusters (pas de personnages/scènes individuels)
    if (zoomedOut) {
      // Monuments
      placesRef.current.forEach(item => {
        const el = createMarkerElement(item, () => {
          setPlaceOverlay(item)
          m.flyTo({
            center: item.coordinates,
            zoom: Math.min(m.getZoom() + 2, 12),
            duration: 1000
          })
        })
        const marker = new maptilersdk.Marker({ element: el, anchor: 'bottom' })
          .setLngLat(item.coordinates)
          .addTo(m)
        markersRef.current.push(marker)
      })
      // Clusters par pays (si filtre le permet)
      if (filter !== 'place' && filter !== 'scene') {
        const grouped: Record<string, WorldItem[]> = {}
        const ungroupedChars: WorldItem[] = []
        charactersRef.current.forEach(item => {
          const country = getCountry(item)
          const countryData = countries.find(c => c.country === country)
          if (countryData) {
            if (!grouped[country]) grouped[country] = []
            grouped[country].push(item)
          } else {
            ungroupedChars.push(item)
          }
        })
        Object.entries(grouped).forEach(([countryName, items]) => {
          const countryData = countries.find(c => c.country === countryName)
          if (!countryData) return
          const el = createClusterElement(items.length, () => {
            clusterModeRef.current = null
            setSelectedCountry(null)
            setSelectedItem(null)
            setIsSheetOpen(false)
            m.flyTo({
              center: countryData.center,
              zoom: countryData.zoom,
              duration: 1000
            })
          })
          const marker = new maptilersdk.Marker({ element: el, anchor: 'center' })
            .setLngLat(countryData.center)
            .addTo(m)
          markersRef.current.push(marker)
        })
        ungroupedChars.forEach(item => {
          const el = createMarkerElement(item, () => {
            setSelectedItem(item)
            setSelectedCountry(null)
            setCharacterOverlay(item)
            m.flyTo({
              center: item.coordinates,
              zoom: Math.min(m.getZoom() + 2, 12),
              duration: 1000
            })
          })
          const marker = new maptilersdk.Marker({ element: el, anchor: 'bottom' })
            .setLngLat(item.coordinates)
            .addTo(m)
          markersRef.current.push(marker)
        })
      }
      return
    }

    // Zoomé près : personnages, scènes et monuments selon le filtre

    // Scènes : visibles en même temps que les personnages (cache si filtre "lieux")
    if (filter !== 'place') {
      scenesRef.current.forEach(item => {
        const el = createMarkerElement(item, () => {
          setSceneOverlay(item)
          m.flyTo({
            center: item.coordinates,
            zoom: Math.min(m.getZoom() + 2, 12),
            duration: 1000
          })
        })

        const marker = new maptilersdk.Marker({ element: el, anchor: 'bottom' })
          .setLngLat(item.coordinates)
          .addTo(m)

        markersRef.current.push(marker)
      })
    }

    // Monuments: overlay au clic (hide when filtering by character or scene)
    if (filter !== 'character' && filter !== 'scene') {
        placesRef.current.forEach(item => {
        const el = createMarkerElement(item, () => {
          setPlaceOverlay(item)
          m.flyTo({
            center: item.coordinates,
            zoom: Math.min(m.getZoom() + 2, 12),
            duration: 1000
          })
        })

        const marker = new maptilersdk.Marker({ element: el, anchor: 'bottom' })
          .setLngLat(item.coordinates)
          .addTo(m)

        markersRef.current.push(marker)
      })
    }

    // Characters (hide when filtering by place or scene)
    if (filter !== 'place' && filter !== 'scene') {
      if (shouldCluster) {
        const grouped: Record<string, WorldItem[]> = {}
        const ungroupedChars: WorldItem[] = []
        charactersRef.current.forEach(item => {
          const country = getCountry(item)
          const countryData = countries.find(c => c.country === country)
          if (countryData) {
            if (!grouped[country]) grouped[country] = []
            grouped[country].push(item)
          } else {
            ungroupedChars.push(item)
          }
        })

        Object.entries(grouped).forEach(([countryName, items]) => {
          const countryData = countries.find(c => c.country === countryName)
          if (!countryData) return

          const el = createClusterElement(items.length, () => {
            clusterModeRef.current = null // force refresh after flyTo
            setSelectedCountry(null)
            setSelectedItem(null)
            setIsSheetOpen(false)
            m.flyTo({
              center: countryData.center,
              zoom: countryData.zoom,
              duration: 1000
            })
          })

          const marker = new maptilersdk.Marker({ element: el, anchor: 'center' })
            .setLngLat(countryData.center)
            .addTo(m)

          markersRef.current.push(marker)
        })

        ungroupedChars.forEach(item => {
          const el = createMarkerElement(item, () => {
            setSelectedItem(item)
            setSelectedCountry(null)
            setCharacterOverlay(item)
            m.flyTo({
              center: item.coordinates,
              zoom: Math.min(m.getZoom() + 2, 12),
              duration: 1000
            })
          })
          const marker = new maptilersdk.Marker({ element: el, anchor: 'bottom' })
            .setLngLat(item.coordinates)
            .addTo(m)
          markersRef.current.push(marker)
        })
      } else {
        charactersRef.current.forEach(item => {
          const el = createMarkerElement(item, () => {
            setSelectedItem(item)
            setSelectedCountry(null)
            setCharacterOverlay(item)
            m.flyTo({
              center: item.coordinates,
              zoom: Math.min(m.getZoom() + 2, 12),
              duration: 1000
            })
          })

          const marker = new maptilersdk.Marker({ element: el, anchor: 'bottom' })
            .setLngLat(item.coordinates)
            .addTo(m)

          markersRef.current.push(marker)
        })
      }
    }
  }, [clearMarkers])

  // Initialize map
  useEffect(() => {
    if (!mapContainer.current) return

    if (map.current) {
      map.current.remove()
      map.current = null
    }

    maptilersdk.config.apiKey = 'wqHnXt1whHSsXwHW5IBS'

    const m = new maptilersdk.Map({
      container: mapContainer.current,
      style: maptilersdk.MapStyle.STREETS,
      center: [2.3522, 48.8566],
      zoom: 3,
      minZoom: 2,
      maxZoom: 16,
      terrain: true,
      pitch: 60,
      attributionControl: false,
      geolocateControl: false
    })

    m.on('error', (e: unknown) => {
      console.error('Map error:', e)
    })

    m.on('load', () => {
      clusterModeRef.current = null
      updateMarkers(m)
    })

    // idle fires once after ALL animations finish - no flickering
    m.on('idle', () => {
      updateMarkers(m)
    })

    m.addControl(
      new maptilersdk.NavigationControl({ showCompass: false, showZoom: false }),
      'top-right'
    )

    map.current = m

    return () => {
      clearMarkers()
      m.remove()
      map.current = null
    }
  }, [updateMarkers, clearMarkers])

  // Update markers when filter, characters, places or scenes change
  useEffect(() => {
    if (!map.current || !map.current.loaded()) return
    clusterModeRef.current = null // force rebuild
    updateMarkers(map.current)
  }, [currentFilter, characters, places, scenes, updateMarkers])

  const closeSheet = () => {
    setIsSheetOpen(false)
    setSelectedItem(null)
    setSelectedCountry(null)
  }

  const closeCharacterOverlay = () => {
    setCharacterOverlay(null)
  }

  const closePlaceOverlay = () => {
    setPlaceOverlay(null)
  }

  const closeSceneOverlay = () => {
    setSceneOverlay(null)
  }

  return (
    <div className="app-container">
      {/* Header */}
      <div className="header">
        <button
          type="button"
          className="header-burger"
          onClick={() => setBurgerOpen(!burgerOpen)}
          aria-label="Menu"
          aria-expanded={burgerOpen}
        >
          <Menu size={24} />
        </button>
        <img src="/logo%20swayco.png" alt="Swayco" className="logo logo-img" />
        <div className={`explorer-filter-dropdown ${filterOpen ? 'open' : ''}`} ref={filterDropdownRef}>
          <button
            type="button"
            className="explorer-filter-trigger"
            onClick={() => setFilterOpen(!filterOpen)}
            aria-expanded={filterOpen}
          >
            <span>
              {currentFilter === 'all' && 'Tout'}
              {currentFilter === 'character' && '👤 Personnages'}
              {currentFilter === 'place' && '🏛️ Lieux'}
              {currentFilter === 'scene' && '🎬 Scènes'}
            </span>
            <ChevronDown className={filterOpen ? 'open' : ''} size={18} />
          </button>
          {filterOpen && (
            <ul className="explorer-filter-menu">
              <li><button type="button" className={currentFilter === 'all' ? 'active' : ''} onClick={() => { setCurrentFilter('all'); setFilterOpen(false); }}>Tout</button></li>
              <li><button type="button" className={currentFilter === 'character' ? 'active' : ''} onClick={() => { setCurrentFilter('character'); setFilterOpen(false); }}>👤 Personnages</button></li>
              <li><button type="button" className={currentFilter === 'place' ? 'active' : ''} onClick={() => { setCurrentFilter('place'); setFilterOpen(false); }}>🏛️ Lieux</button></li>
              <li><button type="button" className={currentFilter === 'scene' ? 'active' : ''} onClick={() => { setCurrentFilter('scene'); setFilterOpen(false); }}>🎬 Scènes</button></li>
            </ul>
          )}
        </div>
      </div>

      {/* Burger menu overlay + drawer */}
      <div className={`burger-overlay ${burgerOpen ? 'active' : ''}`} onClick={() => setBurgerOpen(false)} aria-hidden={!burgerOpen} />
      <div className={`burger-drawer ${burgerOpen ? 'active' : ''}`}>
        <nav className="burger-nav">
          <Link href="/profil" onClick={() => setBurgerOpen(false)} className="burger-nav-item"><User size={18} className="burger-nav-icon" />Mon profil</Link>
          <Link href="/" onClick={() => setBurgerOpen(false)} className="burger-nav-item"><Home size={18} className="burger-nav-icon" />Accueil</Link>
          <Link href="/discover" onClick={() => setBurgerOpen(false)} className="burger-nav-item"><Compass size={18} className="burger-nav-icon" />Découvrir</Link>
          <Link href="/messages" onClick={() => setBurgerOpen(false)} className="burger-nav-item"><MessageCircle size={18} className="burger-nav-icon" />Discuter</Link>
          <Link href="/creer" onClick={() => setBurgerOpen(false)} className="burger-nav-item"><Wand2 size={18} className="burger-nav-icon" />Créer</Link>
          <Link href="/profil" onClick={() => setBurgerOpen(false)} className="burger-nav-item burger-nav-premium"><Crown size={18} className="burger-nav-icon" />Devenir Premium</Link>
        </nav>
        <div className="burger-nav-bottom">
        <div className="burger-nav-footer-buttons">
          <Link href="/contact" onClick={() => setBurgerOpen(false)} className="burger-footer-btn">Contact</Link>
          <Link href="/affiliation" onClick={() => setBurgerOpen(false)} className="burger-footer-btn">Affiliation</Link>
        </div>
        <div className="burger-nav-legal-inline">
          <Link href="/mentions-legales" onClick={() => setBurgerOpen(false)}>Mentions légales</Link>
          <span className="burger-legal-sep">·</span>
          <Link href="/confidentialite" onClick={() => setBurgerOpen(false)}>Confidentialité</Link>
          <span className="burger-legal-sep">·</span>
          <Link href="/cookies" onClick={() => setBurgerOpen(false)}>Cookies</Link>
          <span className="burger-legal-sep">·</span>
          <Link href="/faq" onClick={() => setBurgerOpen(false)}>FAQ</Link>
        </div>
        <div className="burger-nav-copyright">
          &copy; {new Date().getFullYear()} MyDouble
        </div>
        </div>
      </div>

      {/* Map */}
      <div className="map-container">
        <div ref={mapContainer} id="worldMap" />
      </div>

      {/* Overlay */}
      <div
        className={`overlay ${isSheetOpen ? 'active' : ''}`}
        onClick={closeSheet}
      />

      {/* Bottom Sheet */}
      <div className={`bottom-sheet ${isSheetOpen ? 'active' : ''}`}>
        <div className="sheet-header">
          <div className="sheet-handle" />
          <button type="button" className="sheet-close-btn" onClick={closeSheet} aria-label="Fermer">
            <X size={20} />
          </button>
        </div>
        <div className="sheet-content">
          {selectedCountry && (
            <div className="character-card country-card">
              <div className="card-image-container">
                <ImageCarousel
                  images={selectedCountry.images?.length ? selectedCountry.images : [COUNTRY_PLACEHOLDER]}
                  alt={selectedCountry.country}
                />
              </div>
              <div className="card-info">
                <h2 className="card-name">📍 {selectedCountry.country}</h2>
                {selectedCountry.music?.length ? (
                  <CountryMusicPlayer tracks={selectedCountry.music} />
                ) : null}
              </div>
            </div>
          )}
          {selectedItem && selectedItem.type === 'character' && (
            <div className="character-card">
              <div className="card-image-container">
                <img src={selectedItem.image} alt={selectedItem.name} className="card-image" />
                <div className="card-badge">{selectedItem.badge}</div>
              </div>
              <div className="card-info">
                <h2 className="card-name">{selectedItem.name}</h2>
                <p className="card-subtitle">{selectedItem.creatorName ? `Par ${selectedItem.creatorName}` : 'Par swayco.ai'}</p>
                <div className="card-stats">
                  <div className="stat-item">💬 {selectedItem.stats.messages}</div>
                  <div className="stat-item">📍 {selectedItem.location}</div>
                </div>
                <p className="card-description">{selectedItem.description}</p>
                <div className="card-actions">
                  <button className="btn-primary" onClick={() => router.push(`/chat?characterId=${selectedItem.id}`)}>
                    Discutez
                  </button>
                </div>
              </div>
            </div>
          )}

          {selectedItem && selectedItem.type === 'place' && (
            <div className="character-card">
              <div className="card-image-container">
                <ImageCarousel
                  images={selectedItem.images ?? [selectedItem.image]}
                  alt={selectedItem.name}
                />
              </div>
              <div className="card-info">
                <h2 className="card-name">{selectedItem.name}</h2>
                <p className="card-subtitle">{selectedItem.location}</p>
                <div className="card-stats">
                  <div className="stat-item">👥 {selectedItem.stats.visitors}</div>
                </div>
                <p className="card-description">{selectedItem.description}</p>
                <div className="card-actions">
                  {selectedItem.name === 'Tour Eiffel' && (
                    <button
                      className="btn-primary"
                      style={{ background: '#f59e0b', borderColor: '#f59e0b', boxShadow: '0 4px 15px rgba(245,158,11,0.4)', color: '#000' }}
                      onClick={() => router.push('/guide-eiffel')}
                    >
                      🗼 Visite guidée interactive
                    </button>
                  )}
                </div>
              </div>
            </div>
          )}

          {selectedItem && selectedItem.type === 'scene' && (
            <div className="character-card">
              <div className="card-image-container">
                <img src={selectedItem.image} alt={selectedItem.name} className="card-image" />
                <span className="card-badge">🎬</span>
              </div>
              <div className="card-info">
                <h2 className="card-name">{selectedItem.name}</h2>
                <p className="card-subtitle">{selectedItem.location}</p>
                <p className="card-description">{selectedItem.description}</p>
                <div className="card-actions card-actions-scene">
                  <button
                    type="button"
                    className="btn-scene-action"
                    onClick={() => router.push(`/chat?sceneImage=${encodeURIComponent(selectedItem.image || '')}&sceneName=${encodeURIComponent(selectedItem.name)}&sceneLocation=${encodeURIComponent(selectedItem.location)}`)}
                  >
                    👋 Entrer et commander comme un Français
                  </button>
                  <button
                    type="button"
                    className="btn-scene-action"
                    onClick={() => router.push(`/chat?sceneImage=${encodeURIComponent(selectedItem.image || '')}&sceneName=${encodeURIComponent(selectedItem.name)}&sceneLocation=${encodeURIComponent(selectedItem.location)}`)}
                  >
                    🥖 Découvrir les spécialités
                  </button>
                  <button
                    type="button"
                    className="btn-scene-action"
                    onClick={() => router.push(`/chat?sceneImage=${encodeURIComponent(selectedItem.image || '')}&sceneName=${encodeURIComponent(selectedItem.name)}&sceneLocation=${encodeURIComponent(selectedItem.location)}`)}
                  >
                    💬 Discuter avec la boulangère
                  </button>
                </div>
              </div>
            </div>
          )}
        </div>
      </div>

      {characterOverlay && (
        <CharacterOverlay
          character={{
            id: characterOverlay.id,
            name: characterOverlay.name,
            image: characterOverlay.image,
            description: characterOverlay.description,
            teaser: characterOverlay.teaser,
            location: characterOverlay.location,
            badge: characterOverlay.badge,
          }}
          isOpen={!!characterOverlay}
          onClose={closeCharacterOverlay}
        />
      )}

      {placeOverlay && (
        <PlaceOverlay
          place={{
            id: placeOverlay.id,
            name: placeOverlay.name,
            image: placeOverlay.image,
            images: placeOverlay.images,
            visitLabel: placeOverlay.name === 'Tour Eiffel' ? '🗼 Visite guidée interactive' : 'Visiter',
            visitHref: placeOverlay.name === 'Tour Eiffel' ? '/guide-eiffel' : undefined,
          }}
          isOpen={!!placeOverlay}
          onClose={closePlaceOverlay}
        />
      )}

      {sceneOverlay && (
        <SceneOverlay
          scene={{
            id: sceneOverlay.id,
            name: sceneOverlay.name,
            image: sceneOverlay.image,
            location: sceneOverlay.location,
          }}
          isOpen={!!sceneOverlay}
          onClose={closeSceneOverlay}
        />
      )}
    </div>
  )
}
