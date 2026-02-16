'use client'

import { useState, useRef, useCallback, useEffect } from 'react'
import { ChevronLeft, ChevronRight } from 'lucide-react'

interface ImageCarouselProps {
  images: string[]
  alt: string
  className?: string
}

export default function ImageCarousel({ images, alt, className = '' }: ImageCarouselProps) {
  const [activeIndex, setActiveIndex] = useState(0)
  const scrollRef = useRef<HTMLDivElement>(null)

  const updateActiveIndex = useCallback(() => {
    const el = scrollRef.current
    if (!el || images.length <= 1) return
    const slideWidth = el.scrollWidth / images.length
    const index = Math.round(el.scrollLeft / slideWidth)
    setActiveIndex(Math.min(index, images.length - 1))
  }, [images.length])

  const goToSlide = (index: number) => {
    const el = scrollRef.current
    if (!el) return
    const slideWidth = el.clientWidth
    el.scrollTo({ left: index * slideWidth, behavior: 'smooth' })
    setActiveIndex(index)
  }

  useEffect(() => {
    const el = scrollRef.current
    if (!el) return
    el.addEventListener('scroll', updateActiveIndex)
    return () => el.removeEventListener('scroll', updateActiveIndex)
  }, [updateActiveIndex])

  if (images.length === 0) return null

  const slideWidthPercent = 100 / images.length
  const showControls = images.length > 1

  return (
    <div className={`image-carousel-wrapper ${className}`}>
      <div
        ref={scrollRef}
        className="image-carousel"
        role="region"
        aria-label={`Carrousel de ${images.length} image${images.length > 1 ? 's' : ''}`}
      >
        <div
          className="image-carousel-track"
          style={{ width: `${images.length * 100}%` }}
        >
          {images.map((src, i) => (
            <div
              key={i}
              className="image-carousel-slide"
              style={{ width: `${slideWidthPercent}%` }}
            >
              <img src={src} alt={`${alt} - ${i + 1}`} className="card-image" />
            </div>
          ))}
        </div>
      </div>

      {showControls && (
        <>
          <button
            type="button"
            className="image-carousel-arrow image-carousel-arrow-left"
            onClick={() => goToSlide(Math.max(0, activeIndex - 1))}
            aria-label="Image précédente"
          >
            <ChevronLeft className="w-5 h-5" />
          </button>
          <button
            type="button"
            className="image-carousel-arrow image-carousel-arrow-right"
            onClick={() => goToSlide(Math.min(images.length - 1, activeIndex + 1))}
            aria-label="Image suivante"
          >
            <ChevronRight className="w-5 h-5" />
          </button>
          <div className="image-carousel-dots">
            {images.map((_, i) => (
              <button
                key={i}
                type="button"
                className={`image-carousel-dot ${i === activeIndex ? 'active' : ''}`}
                onClick={() => goToSlide(i)}
                aria-label={`Aller à l'image ${i + 1}`}
                aria-current={i === activeIndex ? 'true' : undefined}
              />
            ))}
          </div>
        </>
      )}
    </div>
  )
}
