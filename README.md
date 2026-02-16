# 🌍 World Explorer

Application Next.js 14 d'exploration du monde avec carte interactive MapLibre GL, personnages IA et lieux culturels.

## ✨ Fonctionnalités

- 🗺️ **Carte interactive** avec MapLibre GL JS et tuiles MapTiler (style dark)
- 👤 **15 personnages** géolocalisés avec profils détaillés
- 🏛️ **10 lieux culturels** emblématiques du monde
- 🎯 **Filtres dynamiques** (Tout / Personnages / Lieux)
- 📱 **Responsive** : Bottom sheet mobile / Side panel desktop
- ✨ **Animations** fluides et design premium
- 🔒 **Zoom bloqué** entre niveau 2 (monde) et 7 (département)

## 🚀 Installation

### 1. Installer les dépendances

```bash
npm install
```

### 2. Configurer la clé API MapTiler

Créer un fichier `.env.local` à la racine :

```bash
NEXT_PUBLIC_MAPTILER_API_KEY=fKnWhwpsg06RjF31AeCs
```

> **Note :** La clé est déjà fournie dans `.env.example`. Pour une clé personnelle, rendez-vous sur [MapTiler Cloud](https://cloud.maptiler.com/).

### 3. Lancer le serveur de développement

```bash
npm run dev
```

Ouvrir [http://localhost:3000](http://localhost:3000) dans votre navigateur.

## 📁 Structure du projet

```
world-explorer-app/
├── app/
│   ├── layout.tsx          # Layout principal avec metadata
│   ├── page.tsx            # Page d'accueil
│   └── globals.css         # Styles globaux + MapLibre CSS
├── components/
│   └── WorldExplorer.tsx   # Composant principal de la carte
├── data/
│   └── worldData.ts        # Données des personnages et lieux
├── public/
├── .env.local              # Variables d'environnement (à créer)
├── .env.example            # Template pour .env
├── package.json
├── tsconfig.json
└── next.config.js
```

## 🛠️ Technologies utilisées

- **Next.js 14** - Framework React avec App Router
- **TypeScript** - Typage statique
- **MapLibre GL JS 3.6** - Carte interactive open-source
- **MapTiler** - Tuiles cartographiques (style Dark Matter)
- **CSS3** - Animations et gradients

## 🎨 Personnalisation

### Modifier les personnages/lieux

Éditer `data/worldData.ts` :

```typescript
export const characters: Character[] = [
  {
    id: 1,
    type: 'character',
    name: 'Nom du personnage',
    location: 'Ville, Pays',
    coordinates: [longitude, latitude], // Format [lng, lat]
    image: 'URL de l\'image',
    description: 'Description...',
    stats: { messages: '123.4k' },
    badge: 'FX'
  }
]
```

### Changer le style de carte

Dans `components/WorldExplorer.tsx`, modifier l'URL du style :

```typescript
style: `https://api.maptiler.com/maps/STYLE_NAME/style.json?key=${apiKey}`
```

Styles disponibles : `darkmatter`, `streets`, `hybrid`, `topo`, `voyager`, etc.

### Ajuster les limites de zoom

Dans `components/WorldExplorer.tsx` :

```typescript
minZoom: 2,  // Vue mondiale
maxZoom: 7,  // Niveau département
```

## 🔗 Intégration

### Ajouter une page de chat

Créer `app/chat/page.tsx` :

```typescript
'use client'

import { useSearchParams } from 'next/navigation'

export default function ChatPage() {
  const searchParams = useSearchParams()
  const character = searchParams.get('character')
  
  return <div>Chat avec {character}</div>
}
```

Puis dans `WorldExplorer.tsx` :

```typescript
import { useRouter } from 'next/navigation'

const router = useRouter()

const handleStartChat = (name: string) => {
  router.push(`/chat?character=${encodeURIComponent(name)}`)
}
```

## 🌐 Déploiement

### Vercel (recommandé)

```bash
npm run build
vercel
```

### Autres plateformes

```bash
npm run build
npm start
```

## 📝 Variables d'environnement

| Variable | Description | Requis |
|----------|-------------|--------|
| `NEXT_PUBLIC_MAPTILER_API_KEY` | Clé API MapTiler | Oui |

## 🐛 Dépannage

### La carte ne s'affiche pas

- Vérifier que la clé API est présente dans `.env.local`
- Redémarrer le serveur après modification de `.env.local`
- Vérifier la console du navigateur pour les erreurs

### Les markers ne s'affichent pas

- Vérifier que les coordonnées sont au format `[longitude, latitude]`
- S'assurer que MapLibre GL CSS est importé dans `globals.css`

### Erreur de build TypeScript

```bash
npm run build
```

Si des erreurs persistent, vérifier `tsconfig.json` et les types dans `worldData.ts`

## 📄 Licence

MIT

## 🤝 Support

Pour toute question ou problème, ouvrir une issue sur GitHub.

---

**Développé avec ❤️ pour l'exploration du monde** 🌍
