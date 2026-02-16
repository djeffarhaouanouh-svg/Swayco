'use client'

import { useEffect, useRef, useState, useCallback } from 'react'
import { Play, Pause, Volume2, MoreVertical } from 'lucide-react'
import { useRouter } from 'next/navigation'
import maplibregl from 'maplibre-gl'
import { characters, places, WorldItem, countries, getCountry, COUNTRY_PLACEHOLDER, type MusicTrack } from '@/data/worldData'
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

function SingleTrackPlayer({ track }: { track: MusicTrack }) {
  const start = track.start ?? 0
  const end = track.end ?? 30
  const maxDuration = end - start

  const [isPlaying, setIsPlaying] = useState(false)
  const [currentTime, setCurrentTime] = useState(start)
  const audioRef = useRef<HTMLAudioElement | null>(null)
  const displayTime = Math.max(0, currentTime - start)

  useEffect(() => {
    const audio = audioRef.current
    if (!audio || !track.url) return
    const onLoaded = () => {
      audio.currentTime = start
      setCurrentTime(start)
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

  const togglePlay = async () => {
    const audio = audioRef.current
    if (!audio) return
    if (isPlaying) {
      audio.pause()
      setIsPlaying(false)
    } else {
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
      <button type="button" className="country-music-more" aria-label="Options">
        <MoreVertical className="w-5 h-5" />
      </button>
    </div>
  )
}

function CountryMusicPlayer({ tracks = [] }: { tracks?: (string | MusicTrack)[] }) {
  const normalized = (tracks ?? []).map(toTrack).filter((t) => t.url)
  if (normalized.length === 0) return null

  return (
    <div className="country-music">
      {normalized.map((track, i) => (
        <SingleTrackPlayer key={i} track={track} />
      ))}
    </div>
  )
}

export default function WorldExplorer() {
  const mapContainer = useRef<HTMLDivElement>(null)
  const map = useRef<maplibregl.Map | null>(null)
  const markersRef = useRef<maplibregl.Marker[]>([])
  const filterRef = useRef<FilterType>('all')
  const clusterModeRef = useRef<boolean | null>(null)

  const router = useRouter()
  const [currentFilter, setCurrentFilter] = useState<FilterType>('all')
  const [selectedItem, setSelectedItem] = useState<WorldItem | null>(null)
  const [selectedCountry, setSelectedCountry] = useState<{ country: string; center: [number, number]; zoom: number; description?: string; images?: string[]; music?: (string | MusicTrack)[] } | null>(null)
  const [isSheetOpen, setIsSheetOpen] = useState(false)

  filterRef.current = currentFilter

  const clearMarkers = useCallback(() => {
    markersRef.current.forEach(m => m.remove())
    markersRef.current = []
  }, [])

  const updateMarkers = useCallback((m: maplibregl.Map) => {
    const filter = filterRef.current
    const zoom = m.getZoom()
    const shouldCluster = zoom < CLUSTER_ZOOM_THRESHOLD

    // Skip if mode hasn't changed
    if (shouldCluster === clusterModeRef.current) return

    clearMarkers()
    clusterModeRef.current = shouldCluster

    // Monuments: always show individually (hide when filtering by character or scene)
    if (filter !== 'character' && filter !== 'scene') {
        places.forEach(item => {
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

        const marker = new maplibregl.Marker({ element: el, anchor: 'bottom' })
          .setLngLat(item.coordinates)
          .addTo(m)

        markersRef.current.push(marker)
      })
    }

    // Characters (hide when filtering by place or scene)
    if (filter !== 'place' && filter !== 'scene') {
      if (shouldCluster) {
        const grouped: Record<string, WorldItem[]> = {}
        characters.forEach(item => {
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

          const marker = new maplibregl.Marker({ element: el, anchor: 'center' })
            .setLngLat(countryData.center)
            .addTo(m)

          markersRef.current.push(marker)
        })
      } else {
        characters.forEach(item => {
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

          const marker = new maplibregl.Marker({ element: el, anchor: 'bottom' })
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

    const m = new maplibregl.Map({
      container: mapContainer.current,
      style: 'https://api.maptiler.com/maps/streets/style.json?key=wqHnXt1whHSsXwHW5IBS',
      center: [2.3522, 48.8566],
      zoom: 3,
      minZoom: 2,
      maxZoom: 12,
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
      new maplibregl.NavigationControl({ showCompass: false }),
      'top-right'
    )

    map.current = m

    return () => {
      clearMarkers()
      m.remove()
      map.current = null
    }
  }, [updateMarkers, clearMarkers])

  // Update markers when filter changes
  useEffect(() => {
    if (!map.current || !map.current.loaded()) return
    clusterModeRef.current = null // force rebuild
    updateMarkers(map.current)
  }, [currentFilter, updateMarkers])

  const closeSheet = () => {
    setIsSheetOpen(false)
    setSelectedItem(null)
    setSelectedCountry(null)
  }

  return (
    <div className="app-container">
      {/* Header */}
      <div className="header">
        <div className="logo">Explorer</div>
        <div className="filters">
          <button
            className={`filter-btn ${currentFilter === 'all' ? 'active' : ''}`}
            onClick={() => setCurrentFilter('all')}
          >
            Tout
          </button>
          <button
            className={`filter-btn ${currentFilter === 'character' ? 'active' : ''}`}
            onClick={() => setCurrentFilter('character')}
          >
            👤 Personnages
          </button>
          <button
            className={`filter-btn ${currentFilter === 'place' ? 'active' : ''}`}
            onClick={() => setCurrentFilter('place')}
          >
            🏛️ Lieux
          </button>
          <button
            className={`filter-btn ${currentFilter === 'scene' ? 'active' : ''}`}
            onClick={() => setCurrentFilter('scene')}
          >
            🎬 Scènes
          </button>
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
        <div className="sheet-handle" />
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
                <div className="card-actions">
                  <button className="btn-secondary" onClick={closeSheet}>Fermer</button>
                </div>
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
                    💬 Parler
                  </button>
                  <button className="btn-secondary" onClick={closeSheet}>Fermer</button>
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
                  <button className="btn-secondary" onClick={closeSheet}>Fermer</button>
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
