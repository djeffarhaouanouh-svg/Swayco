'use client'

import { useEffect, useRef, useState, useCallback } from 'react'
import { Play, Pause, Volume2, MoreVertical, ChevronDown, Menu, X } from 'lucide-react'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import * as maptilersdk from '@maptiler/sdk'
import '@maptiler/sdk/dist/maptiler-sdk.css'
import { WorldItem, countries, getCountry, COUNTRY_PLACEHOLDER, type MusicTrack, type Character, type Place, type Scene } from '@/data/worldData'
import ImageCarousel from '@/components/ImageCarousel'

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

  filterRef.current = currentFilter
  const charactersRef = useRef<Character[]>([])
  charactersRef.current = characters
  const placesRef = useRef<Place[]>([])
  placesRef.current = places
  const scenesRef = useRef<Scene[]>([])
  scenesRef.current = scenes

  // Fetch characters, places and scenes from DB
  useEffect(() => {
    fetch('/api/characters')
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

    // Skip if mode hasn't changed
    if (shouldCluster === clusterModeRef.current) return

    clearMarkers()
    clusterModeRef.current = shouldCluster

    // Scènes: show when all or scene (hide when character or place)
    if (filter !== 'character' && filter !== 'place') {
      scenesRef.current.forEach(item => {
        const el = createMarkerElement(item, () => {
          setSelectedItem(item)
          setSelectedCountry(null)
          setIsSheetOpen(true)
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

    // Monuments: always show individually (hide when filtering by character or scene)
    if (filter !== 'character' && filter !== 'scene') {
        placesRef.current.forEach(item => {
        const el = createMarkerElement(item, () => {
          setSelectedItem(item)
          setSelectedCountry(null)
          setIsSheetOpen(true)
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
        charactersRef.current.forEach(item => {
          const country = getCountry(item)
          if (!grouped[country]) grouped[country] = []
          grouped[country].push(item)
        })

        Object.entries(grouped).forEach(([countryName, items]) => {
          const countryData = countries.find(c => c.country === countryName)
          if (!countryData) return

          const el = createClusterElement(items.length, () => {
            clusterModeRef.current = null // force refresh after flyTo
            setSelectedCountry(countryData)
            setSelectedItem(null)
            setIsSheetOpen(true)
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
      } else {
        charactersRef.current.forEach(item => {
          const el = createMarkerElement(item, () => {
            setSelectedItem(item)
            setSelectedCountry(null)
            setIsSheetOpen(true)
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
      attributionControl: false
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
        <div className="logo">Explorer</div>
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
          <Link href="/profil" onClick={() => setBurgerOpen(false)}>Mon profil</Link>
          <Link href="/" onClick={() => setBurgerOpen(false)}>Accueil</Link>
          <Link href="/discover" onClick={() => setBurgerOpen(false)}>Discover</Link>
          <Link href="/messages" onClick={() => setBurgerOpen(false)}>Messages</Link>
          <Link href="/creer" onClick={() => setBurgerOpen(false)}>Créer</Link>
        </nav>
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
                <p className="card-description">{selectedCountry.description || 'Explorez ce pays sur la carte.'}</p>
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
                <p className="card-subtitle">Par swayco.ai</p>
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
                  <button className="btn-primary" onClick={() => alert(`Explorer ${selectedItem.name}...`)}>
                    🔍 En savoir plus
                  </button>
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
                <div className="card-actions">
                  <button className="btn-primary" onClick={() => router.push(`/chat?characterId=${selectedItem.characterId}`)}>
                    Commencer
                  </button>
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
