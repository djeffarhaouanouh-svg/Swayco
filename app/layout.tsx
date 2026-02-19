import type { Metadata } from 'next'
import Script from 'next/script'
import './globals.css'
import NavBar from '@/components/NavBar'

export const metadata: Metadata = {
  title: 'World Explorer - Découvrez le monde',
  description: 'Explorez le monde à travers des personnages IA et des lieux culturels emblématiques',
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="fr">
      <head>
        <Script
          src="https://t.contentsquare.net/uxa/5682f410a201f.js"
          strategy="beforeInteractive"
        />
      </head>
      <body>
        {children}
        <NavBar />
      </body>
    </html>
  )
}
