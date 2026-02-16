# 🚀 Guide d'installation rapide - World Explorer

## Installation en 3 étapes

### 1️⃣ Installer les dépendances

```bash
npm install
```

Cela va installer :
- Next.js 14
- React 18
- MapLibre GL JS 3.6
- TypeScript

### 2️⃣ Vérifier la configuration

Le fichier `.env.local` est déjà créé avec la clé API MapTiler :

```
NEXT_PUBLIC_MAPTILER_API_KEY=fKnWhwpsg06RjF31AeCs
```

✅ **Rien à faire**, c'est déjà configuré !

### 3️⃣ Lancer l'application

```bash
npm run dev
```

Ouvrir : **http://localhost:3000**

---

## 🎯 Commandes disponibles

| Commande | Description |
|----------|-------------|
| `npm run dev` | Lancer en mode développement |
| `npm run build` | Compiler pour production |
| `npm start` | Lancer la version production |
| `npm run lint` | Vérifier le code |

---

## 📦 Que faire ensuite ?

### Personnaliser les données

Modifier `data/worldData.ts` pour ajouter vos propres :
- Personnages
- Lieux
- Coordonnées GPS

### Intégrer votre backend

Dans `components/WorldExplorer.tsx`, remplacer :

```typescript
const handleStartChat = (name: string) => {
  // Votre logique de redirection
  router.push(`/chat?character=${name}`)
}
```

### Changer le style de carte

Styles MapTiler disponibles :
- `darkmatter` (actuel)
- `streets`
- `voyager`
- `topo`
- `hybrid`

Modifier dans `components/WorldExplorer.tsx` :

```typescript
style: `https://api.maptiler.com/maps/STYLE/style.json?key=${apiKey}`
```

---

## ❓ Problèmes courants

### La carte est blanche

```bash
# Redémarrer après modification .env
npm run dev
```

### Erreur TypeScript

```bash
# Recompiler
npm run build
```

### Images ne chargent pas

Vérifier `next.config.js` contient :

```javascript
images: {
  domains: ['images.unsplash.com'],
}
```

---

## 🌟 Fonctionnalités prêtes

✅ Carte MapLibre avec MapTiler  
✅ 15 personnages + 10 lieux  
✅ Filtres fonctionnels  
✅ Responsive mobile/desktop  
✅ Animations premium  
✅ Bottom sheet/Side panel  
✅ TypeScript strict  

---

**Prêt à explorer le monde ! 🌍**
