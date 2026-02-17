import { Suspense } from 'react'
import DiscoverFeed from '@/components/DiscoverFeed'

export default function DiscoverPage() {
  return (
    <Suspense fallback={null}>
      <DiscoverFeed />
    </Suspense>
  )
}
