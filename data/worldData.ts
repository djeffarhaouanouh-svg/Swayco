export interface Character {
  id: number;
  type: 'character';
  name: string;
  location: string;
  coordinates: [number, number]; // [lng, lat]
  image: string;
  description: string;
  teaser?: string; // court texte affiché au-dessus du bouton Parler (2 lignes séparées par \n)
  cityImage?: string; // image de la ville (fond du chat)
  voiceId?: string; // ElevenLabs voice ID for TTS
  stats: {
    messages: string;
  };
  badge: string;
  creatorName?: string; // nom du créateur du personnage
}

export interface Place {
  id: number;
  type: 'place';
  name: string;
  location: string;
  coordinates: [number, number]; // [lng, lat]
  image: string;
  images?: string[]; // optional carousel, falls back to [image]
  description: string;
  stats: {
    visitors: string;
  };
}

export interface Scene {
  id: number;
  type: 'scene';
  name: string;
  location: string;
  coordinates: [number, number]; // [lng, lat]
  image: string;
  description: string;
  characterId: number; // id du personnage avec qui discuter (ex: la boulangère)
}

export type WorldItem = Character | Place | Scene;

// Placeholder image for countries without a photo yet
const COUNTRY_PLACEHOLDER = 'data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" width="400" height="250" viewBox="0 0 400 250"%3E%3Crect fill="%231a1a1a" width="400" height="250"/%3E%3Ctext fill="%23555" font-size="18" font-family="sans-serif" x="50%" y="50%" text-anchor="middle" dy=".35em"%3EImage à venir%3C/text%3E%3C/svg%3E';

export interface MusicTrack {
  url: string;
  start?: number; // sec, défaut 0
  end?: number;   // sec, défaut selon piste
  label?: string;
  artist?: string;
  title?: string;
}

export interface CountryCluster {
  country: string;
  center: [number, number];
  zoom: number; // zoom target when clicking
  description?: string;
  images?: string[];
  music?: (string | MusicTrack)[]; // URLs ou pistes avec start/end
}

// Country definitions with center coords, zoom targets, descriptions and images
export const countries: CountryCluster[] = [
  {
    country: 'France',
    center: [2.3522, 46.6034],
    zoom: 6,
    description: 'La France, patrie des droits de l\'homme, est réputée pour son art de vivre, sa gastronomie, sa culture et ses paysages variés. De Paris à la Côte d\'Azur, des châteaux de la Loire aux vignobles de Bordeaux, elle attire des millions de voyageurs chaque année.',
    images: [
      'https://images.unsplash.com/photo-1502602898657-3e91760cbb34?w=400&h=500&fit=crop',
      'https://images.unsplash.com/photo-1531366934919-4bcd7c65e216?w=400&h=500&fit=crop',
    ],
    music: [
      { url: '/music/france.m4a', start: 0, end: 30, label: 'France 1', artist: 'Aya Nakamura', title: 'Djadja' },
      { url: '/music/france-2.m4a', start: 15, end: 60, label: 'France 2', artist: 'Indila', title: 'Dernière danse' },
    ],
  },
  { country: 'Japon', center: [138.2529, 36.2048], zoom: 6 },
  { country: 'Italie', center: [12.5674, 41.8719], zoom: 6 },
  { country: 'Royaume-Uni', center: [-1.1743, 52.3555], zoom: 6 },
  { country: 'Brésil', center: [-51.9253, -14.2350], zoom: 6 },
  { country: 'Maroc', center: [-7.0926, 31.7917], zoom: 6 },
  { country: 'Russie', center: [37.6173, 55.7558], zoom: 6 },
  { country: 'Espagne', center: [-3.7492, 40.4637], zoom: 6 },
  { country: 'USA', center: [-95.7129, 37.0902], zoom: 6 },
  { country: 'Irlande', center: [-7.6921, 53.1424], zoom: 7 },
  { country: 'Chine', center: [104.1954, 35.8617], zoom: 6 },
  { country: 'Australie', center: [151.2093, -33.8688], zoom: 6 },
  { country: 'Grèce', center: [23.7275, 37.9838], zoom: 7 },
  { country: 'Égypte', center: [31.2357, 30.0444], zoom: 6 },
  { country: 'Pays-Bas', center: [5.2913, 52.1326], zoom: 7 },
  { country: 'Inde', center: [78.9629, 20.5937], zoom: 6 },
  { country: 'Pérou', center: [-75.0152, -9.1900], zoom: 6 },
  { country: 'Portugal', center: [-8.2245, 39.3999], zoom: 6 },
];

export { COUNTRY_PLACEHOLDER };

// Map each item to its country
export function getCountry(item: WorldItem): string {
  // Use the country field directly if available (DB characters have it)
  const countryField = 'country' in item && typeof (item as Record<string, unknown>).country === 'string'
    ? (item as Record<string, unknown>).country as string
    : null;
  if (countryField) {
    const match = countries.find(c => c.country === countryField);
    if (match) return match.country;
  }

  const loc = item.location;
  if (loc.includes('France') || loc.includes('Paris')) return 'France';
  if (loc.includes('Japon') || loc.includes('Tokyo')) return 'Japon';
  if (loc.includes('Italie') || loc.includes('Rome')) return 'Italie';
  if (loc.includes('Royaume-Uni') || loc.includes('Londres')) return 'Royaume-Uni';
  if (loc.includes('Brésil') || loc.includes('Rio')) return 'Brésil';
  if (loc.includes('Maroc') || loc.includes('Marrakech')) return 'Maroc';
  if (loc.includes('Russie') || loc.includes('Moscou')) return 'Russie';
  if (loc.includes('Espagne') || loc.includes('Barcelone')) return 'Espagne';
  if (loc.includes('USA') || loc.includes('New York')) return 'USA';
  if (loc.includes('Irlande') || loc.includes('Dublin')) return 'Irlande';
  if (loc.includes('Chine') || loc.includes('Shanghai')) return 'Chine';
  if (loc.includes('Australie') || loc.includes('Sydney')) return 'Australie';
  if (loc.includes('Grèce') || loc.includes('Athènes')) return 'Grèce';
  if (loc.includes('Égypte') || loc.includes('Caire')) return 'Égypte';
  if (loc.includes('Pays-Bas') || loc.includes('Amsterdam')) return 'Pays-Bas';
  if (loc.includes('Inde') || loc.includes('Agra')) return 'Inde';
  if (loc.includes('Pérou')) return 'Pérou';
  if (loc.includes('Portugal') || loc.includes('Lisbonne') || loc.includes('Nisa')) return 'Portugal';
  return loc;
}

export const characters: Character[] = [
  {
    id: 1,
    type: 'character',
    name: 'Jade',
    location: 'Paris, France',
    coordinates: [2.3522, 48.8566],
    image: '/jade.png',
    description: 'Parisienne passionnée d\'art et d\'histoire. Adore discuter de culture française, cuisine raffinée et architecture haussmannienne.',
    teaser: 'Étudiante en droit le jour, confidente la nuit 😉\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1511739001486-6bfe10ce785f?w=800&h=1200&fit=crop',
    stats: { messages: '111.2k' },
    badge: 'FX'
  },
  {
    id: 2,
    type: 'character',
    name: 'Yuki',
    location: 'Tokyo, Japon',
    coordinates: [139.6917, 35.6895],
    image: 'https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=400&h=500&fit=crop',
    description: 'Tokyoïte moderne et traditionnelle. Passionnée de manga, technologie et cérémonie du thé. Parle de la vie urbaine japonaise.',
    teaser: 'Manga le matin, matcha l\'après-midi ✨\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1540959733332-eab4deabeeaf?w=800&h=1200&fit=crop',
    stats: { messages: '312.5k' },
    badge: 'FX'
  },
  {
    id: 3,
    type: 'character',
    name: 'Marco',
    location: 'Rome, Italie',
    coordinates: [12.4964, 41.9028],
    image: 'https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=400&h=500&fit=crop',
    description: 'Romain chaleureux, guide touristique passionné. Expert en histoire antique, gastronomie italienne et dolce vita.',
    teaser: 'Guide le jour, épicurien la nuit 🍝\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1552832230-c0197dd311b5?w=800&h=1200&fit=crop',
    stats: { messages: '189.3k' },
    badge: 'FX'
  },
  {
    id: 4,
    type: 'character',
    name: 'Emma',
    location: 'Londres, Royaume-Uni',
    coordinates: [-0.1278, 51.5074],
    image: 'https://images.unsplash.com/photo-1488426862026-3ee34a7d66df?w=400&h=500&fit=crop',
    description: 'Londonienne élégante, passionnée de littérature britannique, thé et culture royale. Aime les conversations profondes.',
    teaser: 'Earl Grey le matin, poésie le soir ☕\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1513635269975-59663e0ac1ad?w=800&h=1200&fit=crop',
    stats: { messages: '267.1k' },
    badge: 'FX'
  },
  {
    id: 5,
    type: 'character',
    name: 'Isabella',
    location: 'Rio de Janeiro, Brésil',
    coordinates: [-43.1729, -22.9068],
    image: 'https://images.unsplash.com/photo-1531746020798-e6953c6e8e04?w=400&h=500&fit=crop',
    description: 'Brésilienne joyeuse et énergique. Parle de samba, carnaval, plages paradisiaques et joie de vivre carioca.',
    teaser: 'Samba au cœur, soleil dans l\'âme 🌴\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1483729558449-99ef09a8c325?w=800&h=1200&fit=crop',
    stats: { messages: '198.7k' },
    badge: 'FX'
  },
  {
    id: 6,
    type: 'character',
    name: 'Ahmed',
    location: 'Marrakech, Maroc',
    coordinates: [-7.9811, 31.6295],
    image: 'https://images.unsplash.com/photo-1506794778202-cad84cf45f1d?w=400&h=500&fit=crop',
    description: 'Guide marocain expert des souks. Connaît les secrets de Marrakech, épices, artisanat et traditions berbères.',
    teaser: 'Souks le jour, conteur la nuit 🧿\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1489749798305-4fea3d13302f?w=800&h=1200&fit=crop',
    stats: { messages: '156.2k' },
    badge: 'FX'
  },
  {
    id: 7,
    type: 'character',
    name: 'Natasha',
    location: 'Moscou, Russie',
    coordinates: [37.6173, 55.7558],
    image: 'https://images.unsplash.com/photo-1524504388940-b1c1722653e1?w=400&h=500&fit=crop',
    description: 'Moscovite cultivée, passionnée de ballet, littérature russe et architecture soviétique. Élégante et intellectuelle.',
    teaser: 'Ballet au matin, Dostoïevski au soir 📚\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1513326738677-b964603b136d?w=800&h=1200&fit=crop',
    stats: { messages: '143.9k' },
    badge: 'FX'
  },
  {
    id: 8,
    type: 'character',
    name: 'Carlos',
    location: 'Barcelone, Espagne',
    coordinates: [2.1734, 41.3851],
    image: 'https://images.unsplash.com/photo-1500648767791-00dcc994a43e?w=400&h=500&fit=crop',
    description: 'Catalan passionné d\'architecture Gaudí, football et tapas. Adore partager la culture méditerranéenne vibrante.',
    teaser: 'Gaudí par jour, tapas par nuit 🏛️\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1583422409516-2895a77efded?w=800&h=1200&fit=crop',
    stats: { messages: '221.4k' },
    badge: 'FX'
  },
  {
    id: 9,
    type: 'character',
    name: 'Aria',
    location: 'New York, USA',
    coordinates: [-74.0060, 40.7128],
    image: 'https://images.unsplash.com/photo-1529626455594-4ff0802cfb7e?w=400&h=500&fit=crop',
    description: 'New-Yorkaise dynamique, passionnée de mode, art contemporain et vie urbaine intense. Toujours à l\'affût des tendances.',
    teaser: 'Manhattan le jour, Brooklyn la nuit 🗽\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1566404791232-af9fe0ae8f8b?w=800&h=1200&fit=crop',
    stats: { messages: '378.6k' },
    badge: 'FX'
  },
  {
    id: 10,
    type: 'character',
    name: 'Liam',
    location: 'Dublin, Irlande',
    coordinates: [-6.2603, 53.3498],
    image: 'https://images.unsplash.com/photo-1492562080023-ab3db95bfbce?w=400&h=500&fit=crop',
    description: 'Irlandais chaleureux, conteur né. Parle de légendes celtiques, pubs traditionnels et paysages verdoyants d\'Irlande.',
    teaser: 'Pubs le jour, légendes la nuit 🍀\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1600096194734-9c8a2a150109?w=800&h=1200&fit=crop',
    stats: { messages: '134.5k' },
    badge: 'FX'
  },
  {
    id: 11,
    type: 'character',
    name: 'Mei',
    location: 'Shanghai, Chine',
    coordinates: [121.4737, 31.2304],
    image: 'https://images.unsplash.com/photo-1502823403499-6ccfcf4fb453?w=400&h=500&fit=crop',
    description: 'Shanghaïenne moderne, experte en business et tradition chinoise. Passionnée de calligraphie et innovation technologique.',
    teaser: 'Business le jour, calligraphie la nuit 🎋\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1508804185872-d7badad00f7d?w=800&h=1200&fit=crop',
    stats: { messages: '289.1k' },
    badge: 'FX'
  },
  {
    id: 12,
    type: 'character',
    name: 'Olivia',
    location: 'Sydney, Australie',
    coordinates: [151.2093, -33.8688],
    image: 'https://images.unsplash.com/photo-1517841905240-472988babdf9?w=400&h=500&fit=crop',
    description: 'Australienne aventurière, amoureuse de la nature. Parle de surf, vie marine et culture décontractée aussie.',
    teaser: 'Surf le matin, étoiles la nuit 🏄\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1506973035872-a4ec16b8e8d9?w=800&h=1200&fit=crop',
    stats: { messages: '167.8k' },
    badge: 'FX'
  },
  {
    id: 13,
    type: 'character',
    name: 'Dimitri',
    location: 'Athènes, Grèce',
    coordinates: [23.7275, 37.9838],
    image: 'https://images.unsplash.com/photo-1504257432389-52343af06ae3?w=400&h=500&fit=crop',
    description: 'Athénien passionné d\'histoire antique et philosophie. Guide expert des ruines grecques et mythologie.',
    teaser: 'Philosophe le jour, mythologue la nuit 🏛️\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1555993524-3d26e037e07f?w=800&h=1200&fit=crop',
    stats: { messages: '142.3k' },
    badge: 'FX'
  },
  {
    id: 14,
    type: 'character',
    name: 'Amara',
    location: 'Le Caire, Égypte',
    coordinates: [31.2357, 30.0444],
    image: 'https://images.unsplash.com/photo-1509967419530-da38b4704bc6?w=400&h=500&fit=crop',
    description: 'Égyptienne fascinante, experte en égyptologie. Partage les secrets des pharaons, pyramides et civilisation millénaire.',
    teaser: 'Égyptologue le jour, mystérieuse la nuit ☀️\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1539650116574-8efeb43e2750?w=800&h=1200&fit=crop',
    stats: { messages: '201.5k' },
    badge: 'FX'
  },
  {
    id: 15,
    type: 'character',
    name: 'Lucas',
    location: 'Amsterdam, Pays-Bas',
    coordinates: [4.9041, 52.3676],
    image: 'https://images.unsplash.com/photo-1463453091185-61582044d556?w=400&h=500&fit=crop',
    description: 'Hollandais décontracté, passionné de vélo, canaux et art flamand. Parle de culture libérale et qualité de vie néerlandaise.',
    teaser: 'Vélo le jour, van Gogh la nuit 🎨\nParle-moi de tout… ou presque.',
    cityImage: 'https://images.unsplash.com/photo-1534351590666-13e3e96b5017?w=800&h=1200&fit=crop',
    stats: { messages: '176.9k' },
    badge: 'FX'
  }
];

export const scenes: Scene[] = [
  {
    id: 201,
    type: 'scene',
    name: 'La boulangerie',
    location: 'Paris, France',
    coordinates: [2.35, 48.92],
    image: 'https://images.unsplash.com/photo-1509440159596-0249088772ff?w=400&h=500&fit=crop',
    description: 'Tu es dans la boulangerie et tu as un jeu de regard avec la boulangère.',
    characterId: 1
  }
];

export const places: Place[] = [
  {
    id: 101,
    type: 'place',
    name: 'Tour Eiffel',
    location: 'Paris, France',
    coordinates: [2.2945, 48.8584],
    image: 'https://images.unsplash.com/photo-1511739001486-6bfe10ce785f?w=400&h=500&fit=crop',
    images: [
      'https://images.unsplash.com/photo-1511739001486-6bfe10ce785f?w=400&h=500&fit=crop',
      'https://images.unsplash.com/photo-1488646953014-85cb44e25828?w=400&h=500&fit=crop',
    ],
    description: 'Monument emblématique de Paris construit en 1889. Symbole de la France, elle offre une vue panoramique spectaculaire sur la capitale.',
    stats: { visitors: '7M/an' }
  },
  {
    id: 102,
    type: 'place',
    name: 'Colisée',
    location: 'Rome, Italie',
    coordinates: [12.4924, 41.8902],
    image: 'https://images.unsplash.com/photo-1552832230-c0197dd311b5?w=400&h=500&fit=crop',
    description: 'Amphithéâtre romain antique, chef-d\'œuvre architectural de 80 après J.-C. Témoin de la grandeur de l\'Empire romain.',
    stats: { visitors: '6M/an' }
  },
  {
    id: 103,
    type: 'place',
    name: 'Statue de la Liberté',
    location: 'New York, USA',
    coordinates: [-74.0445, 40.6892],
    image: 'https://images.unsplash.com/photo-1566404791232-af9fe0ae8f8b?w=400&h=500&fit=crop',
    description: 'Symbole universel de liberté et démocratie. Cadeau de la France aux États-Unis, inaugurée en 1886.',
    stats: { visitors: '4.5M/an' }
  },
  {
    id: 104,
    type: 'place',
    name: 'Taj Mahal',
    location: 'Agra, Inde',
    coordinates: [78.0421, 27.1751],
    image: 'https://images.unsplash.com/photo-1564507592333-c60657eea523?w=400&h=500&fit=crop',
    description: 'Mausolée de marbre blanc, monument d\'amour éternel. Chef-d\'œuvre de l\'architecture moghole du 17ème siècle.',
    stats: { visitors: '8M/an' }
  },
  {
    id: 105,
    type: 'place',
    name: 'Grande Muraille',
    location: 'Chine',
    coordinates: [116.5704, 40.4319],
    image: 'https://images.unsplash.com/photo-1508804185872-d7badad00f7d?w=400&h=500&fit=crop',
    description: 'Fortification de plus de 20 000 km construite sur plusieurs siècles. Merveille du monde et prouesse architecturale.',
    stats: { visitors: '10M/an' }
  },
  {
    id: 106,
    type: 'place',
    name: 'Machu Picchu',
    location: 'Pérou',
    coordinates: [-72.5450, -13.1631],
    image: 'https://images.unsplash.com/photo-1587595431973-160d0d94add1?w=400&h=500&fit=crop',
    description: 'Cité inca perchée à 2430m d\'altitude. Site archéologique mystérieux datant du 15ème siècle, merveille du monde.',
    stats: { visitors: '1.5M/an' }
  },
  {
    id: 107,
    type: 'place',
    name: 'Pyramides de Gizeh',
    location: 'Le Caire, Égypte',
    coordinates: [31.1342, 29.9792],
    image: 'https://images.unsplash.com/photo-1568322445389-f64ac2515020?w=400&h=500&fit=crop',
    description: 'Tombeaux monumentaux des pharaons, seule merveille antique encore debout. Construites il y a plus de 4500 ans.',
    stats: { visitors: '14M/an' }
  },
  {
    id: 108,
    type: 'place',
    name: 'Sagrada Familia',
    location: 'Barcelone, Espagne',
    coordinates: [2.1744, 41.4036],
    image: 'https://images.unsplash.com/photo-1583422409516-2895a77efded?w=400&h=500&fit=crop',
    description: 'Basilique spectaculaire d\'Antoni Gaudí, en construction depuis 1882. Chef-d\'œuvre du modernisme catalan.',
    stats: { visitors: '4.7M/an' }
  },
  {
    id: 109,
    type: 'place',
    name: 'Christ Rédempteur',
    location: 'Rio de Janeiro, Brésil',
    coordinates: [-43.2105, -22.9519],
    image: 'https://images.unsplash.com/photo-1648202838928-ec566d09b992?w=400&h=500&fit=crop',
    description: 'Statue monumentale du Christ dominant Rio. Symbole du Brésil inaugurée en 1931, haute de 38 mètres.',
    stats: { visitors: '2M/an' }
  },
  {
    id: 110,
    type: 'place',
    name: 'Opéra de Sydney',
    location: 'Sydney, Australie',
    coordinates: [151.2153, -33.8568],
    image: 'https://images.unsplash.com/photo-1523059623039-a9ed027e7fad?w=400&h=500&fit=crop',
    description: 'Icône architecturale moderne aux toits en forme de voiles. Centre culturel majeur inauguré en 1973.',
    stats: { visitors: '8.2M/an' }
  }
];
