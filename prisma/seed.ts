import { PrismaClient } from "@prisma/client";

const prisma = new PrismaClient();

const seedCharacters = [
  {
    id: 1,
    name: "Jade",
    location: "Paris, France",
    country: "France",
    lng: 2.3522,
    lat: 48.8566,
    image_url: "/jade.png",
    description:
      "Parisienne passionnée d'art et d'histoire. Adore discuter de culture française, cuisine raffinée et architecture haussmannienne.",
    teaser:
      "Étudiante en droit le jour, confidente la nuit 😉\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1511739001486-6bfe10ce785f?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "111.2k",
  },
  {
    id: 2,
    name: "Yuki",
    location: "Tokyo, Japon",
    country: "Japon",
    lng: 139.6917,
    lat: 35.6895,
    image_url:
      "https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=400&h=500&fit=crop",
    description:
      "Tokyoïte moderne et traditionnelle. Passionnée de manga, technologie et cérémonie du thé. Parle de la vie urbaine japonaise.",
    teaser:
      "Manga le matin, matcha l'après-midi ✨\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1540959733332-eab4deabeeaf?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "312.5k",
  },
  {
    id: 3,
    name: "Marco",
    location: "Rome, Italie",
    country: "Italie",
    lng: 12.4964,
    lat: 41.9028,
    image_url:
      "https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=400&h=500&fit=crop",
    description:
      "Romain chaleureux, guide touristique passionné. Expert en histoire antique, gastronomie italienne et dolce vita.",
    teaser:
      "Guide le jour, épicurien la nuit 🍝\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1552832230-c0197dd311b5?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "189.3k",
  },
  {
    id: 4,
    name: "Emma",
    location: "Londres, Royaume-Uni",
    country: "Royaume-Uni",
    lng: -0.1278,
    lat: 51.5074,
    image_url:
      "https://images.unsplash.com/photo-1488426862026-3ee34a7d66df?w=400&h=500&fit=crop",
    description:
      "Londonienne élégante, passionnée de littérature britannique, thé et culture royale. Aime les conversations profondes.",
    teaser:
      "Earl Grey le matin, poésie le soir ☕\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1513635269975-59663e0ac1ad?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "267.1k",
  },
  {
    id: 5,
    name: "Isabella",
    location: "Rio de Janeiro, Brésil",
    country: "Brésil",
    lng: -43.1729,
    lat: -22.9068,
    image_url:
      "https://images.unsplash.com/photo-1531746020798-e6953c6e8e04?w=400&h=500&fit=crop",
    description:
      "Brésilienne joyeuse et énergique. Parle de samba, carnaval, plages paradisiaques et joie de vivre carioca.",
    teaser:
      "Samba au cœur, soleil dans l'âme 🌴\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1483729558449-99ef09a8c325?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "198.7k",
  },
  {
    id: 6,
    name: "Ahmed",
    location: "Marrakech, Maroc",
    country: "Maroc",
    lng: -7.9811,
    lat: 31.6295,
    image_url:
      "https://images.unsplash.com/photo-1506794778202-cad84cf45f1d?w=400&h=500&fit=crop",
    description:
      "Guide marocain expert des souks. Connaît les secrets de Marrakech, épices, artisanat et traditions berbères.",
    teaser:
      "Souks le jour, conteur la nuit 🧿\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1489749798305-4fea3d13302f?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "156.2k",
  },
  {
    id: 7,
    name: "Natasha",
    location: "Moscou, Russie",
    country: "Russie",
    lng: 37.6173,
    lat: 55.7558,
    image_url:
      "https://images.unsplash.com/photo-1524504388940-b1c1722653e1?w=400&h=500&fit=crop",
    description:
      "Moscovite cultivée, passionnée de ballet, littérature russe et architecture soviétique. Élégante et intellectuelle.",
    teaser:
      "Ballet au matin, Dostoïevski au soir 📚\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1513326738677-b964603b136d?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "143.9k",
  },
  {
    id: 8,
    name: "Carlos",
    location: "Barcelone, Espagne",
    country: "Espagne",
    lng: 2.1734,
    lat: 41.3851,
    image_url:
      "https://images.unsplash.com/photo-1500648767791-00dcc994a43e?w=400&h=500&fit=crop",
    description:
      "Catalan passionné d'architecture Gaudí, football et tapas. Adore partager la culture méditerranéenne vibrante.",
    teaser:
      "Gaudí par jour, tapas par nuit 🏛️\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1583422409516-2895a77efded?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "221.4k",
  },
  {
    id: 9,
    name: "Aria",
    location: "New York, USA",
    country: "USA",
    lng: -74.006,
    lat: 40.7128,
    image_url:
      "https://images.unsplash.com/photo-1529626455594-4ff0802cfb7e?w=400&h=500&fit=crop",
    description:
      "New-Yorkaise dynamique, passionnée de mode, art contemporain et vie urbaine intense. Toujours à l'affût des tendances.",
    teaser:
      "Manhattan le jour, Brooklyn la nuit 🗽\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1566404791232-af9fe0ae8f8b?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "378.6k",
  },
  {
    id: 10,
    name: "Liam",
    location: "Dublin, Irlande",
    country: "Irlande",
    lng: -6.2603,
    lat: 53.3498,
    image_url:
      "https://images.unsplash.com/photo-1492562080023-ab3db95bfbce?w=400&h=500&fit=crop",
    description:
      "Irlandais chaleureux, conteur né. Parle de légendes celtiques, pubs traditionnels et paysages verdoyants d'Irlande.",
    teaser:
      "Pubs le jour, légendes la nuit 🍀\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1600096194734-9c8a2a150109?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "134.5k",
  },
  {
    id: 11,
    name: "Mei",
    location: "Shanghai, Chine",
    country: "Chine",
    lng: 121.4737,
    lat: 31.2304,
    image_url:
      "https://images.unsplash.com/photo-1502823403499-6ccfcf4fb453?w=400&h=500&fit=crop",
    description:
      "Shanghaïenne moderne, experte en business et tradition chinoise. Passionnée de calligraphie et innovation technologique.",
    teaser:
      "Business le jour, calligraphie la nuit 🎋\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1508804185872-d7badad00f7d?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "289.1k",
  },
  {
    id: 12,
    name: "Olivia",
    location: "Sydney, Australie",
    country: "Australie",
    lng: 151.2093,
    lat: -33.8688,
    image_url:
      "https://images.unsplash.com/photo-1517841905240-472988babdf9?w=400&h=500&fit=crop",
    description:
      "Australienne aventurière, amoureuse de la nature. Parle de surf, vie marine et culture décontractée aussie.",
    teaser:
      "Surf le matin, étoiles la nuit 🏄\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1506973035872-a4ec16b8e8d9?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "167.8k",
  },
  {
    id: 13,
    name: "Dimitri",
    location: "Athènes, Grèce",
    country: "Grèce",
    lng: 23.7275,
    lat: 37.9838,
    image_url:
      "https://images.unsplash.com/photo-1504257432389-52343af06ae3?w=400&h=500&fit=crop",
    description:
      "Athénien passionné d'histoire antique et philosophie. Guide expert des ruines grecques et mythologie.",
    teaser:
      "Philosophe le jour, mythologue la nuit 🏛️\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1555993524-3d26e037e07f?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "142.3k",
  },
  {
    id: 14,
    name: "Amara",
    location: "Le Caire, Égypte",
    country: "Égypte",
    lng: 31.2357,
    lat: 30.0444,
    image_url:
      "https://images.unsplash.com/photo-1509967419530-da38b4704bc6?w=400&h=500&fit=crop",
    description:
      "Égyptienne fascinante, experte en égyptologie. Partage les secrets des pharaons, pyramides et civilisation millénaire.",
    teaser:
      "Égyptologue le jour, mystérieuse la nuit ☀️\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1539650116574-8efeb43e2750?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "201.5k",
  },
  {
    id: 15,
    name: "Lucas",
    location: "Amsterdam, Pays-Bas",
    country: "Pays-Bas",
    lng: 4.9041,
    lat: 52.3676,
    image_url:
      "https://images.unsplash.com/photo-1463453091185-61582044d556?w=400&h=500&fit=crop",
    description:
      "Hollandais décontracté, passionné de vélo, canaux et art flamand. Parle de culture libérale et qualité de vie néerlandaise.",
    teaser:
      "Vélo le jour, van Gogh la nuit 🎨\nParle-moi de tout… ou presque.",
    city_image:
      "https://images.unsplash.com/photo-1534351590666-13e3e96b5017?w=800&h=1200&fit=crop",
    badge: "FX",
    stats_messages: "176.9k",
  },
];

const seedPlaces = [
  { id: 101, name: "Tour Eiffel", location: "Paris, France", lng: 2.2945, lat: 48.8584, image_url: "https://images.unsplash.com/photo-1511739001486-6bfe10ce785f?w=400&h=500&fit=crop", description: "Monument emblématique de Paris construit en 1889. Symbole de la France, elle offre une vue panoramique spectaculaire sur la capitale.", stats_visitors: "7M/an" },
  { id: 102, name: "Colisée", location: "Rome, Italie", lng: 12.4924, lat: 41.8902, image_url: "https://images.unsplash.com/photo-1552832230-c0197dd311b5?w=400&h=500&fit=crop", description: "Amphithéâtre romain antique, chef-d'œuvre architectural de 80 après J.-C.", stats_visitors: "6M/an" },
  { id: 103, name: "Statue de la Liberté", location: "New York, USA", lng: -74.0445, lat: 40.6892, image_url: "https://images.unsplash.com/photo-1566404791232-af9fe0ae8f8b?w=400&h=500&fit=crop", description: "Symbole universel de liberté et démocratie. Cadeau de la France aux États-Unis, inaugurée en 1886.", stats_visitors: "4.5M/an" },
  { id: 104, name: "Taj Mahal", location: "Agra, Inde", lng: 78.0421, lat: 27.1751, image_url: "https://images.unsplash.com/photo-1564507592333-c60657eea523?w=400&h=500&fit=crop", description: "Mausolée de marbre blanc, monument d'amour éternel.", stats_visitors: "8M/an" },
  { id: 105, name: "Grande Muraille", location: "Chine", lng: 116.5704, lat: 40.4319, image_url: "https://images.unsplash.com/photo-1508804185872-d7badad00f7d?w=400&h=500&fit=crop", description: "Fortification de plus de 20 000 km construite sur plusieurs siècles.", stats_visitors: "10M/an" },
  { id: 106, name: "Machu Picchu", location: "Pérou", lng: -72.545, lat: -13.1631, image_url: "https://images.unsplash.com/photo-1587595431973-160d0d94add1?w=400&h=500&fit=crop", description: "Cité inca perchée à 2430m d'altitude.", stats_visitors: "1.5M/an" },
  { id: 107, name: "Pyramides de Gizeh", location: "Le Caire, Égypte", lng: 31.1342, lat: 29.9792, image_url: "https://images.unsplash.com/photo-1568322445389-f64ac2515020?w=400&h=500&fit=crop", description: "Tombeaux monumentaux des pharaons, seule merveille antique encore debout.", stats_visitors: "14M/an" },
  { id: 108, name: "Sagrada Familia", location: "Barcelone, Espagne", lng: 2.1744, lat: 41.4036, image_url: "https://images.unsplash.com/photo-1583422409516-2895a77efded?w=400&h=500&fit=crop", description: "Basilique spectaculaire d'Antoni Gaudí, en construction depuis 1882.", stats_visitors: "4.7M/an" },
  { id: 109, name: "Christ Rédempteur", location: "Rio de Janeiro, Brésil", lng: -43.2105, lat: -22.9519, image_url: "https://images.unsplash.com/photo-1648202838928-ec566d09b992?w=400&h=500&fit=crop", description: "Statue monumentale du Christ dominant Rio.", stats_visitors: "2M/an" },
  { id: 110, name: "Opéra de Sydney", location: "Sydney, Australie", lng: 151.2153, lat: -33.8568, image_url: "https://images.unsplash.com/photo-1523059623039-a9ed027e7fad?w=400&h=500&fit=crop", description: "Icône architecturale moderne aux toits en forme de voiles.", stats_visitors: "8.2M/an" },
];

const seedScenes = [
  { id: 201, name: "La boulangerie", location: "Paris, France", lng: 2.35, lat: 48.92, image_url: "https://images.unsplash.com/photo-1509440159596-0249088772ff?w=400&h=500&fit=crop", description: "Tu es dans la boulangerie et tu as un jeu de regard avec la boulangère.", character_id: 1 },
];

async function main() {
  console.log("Seeding database...");

  for (const char of seedCharacters) {
    await prisma.characters.upsert({
      where: { id: char.id },
      update: char,
      create: char,
    });
  }
  console.log(`Seeded ${seedCharacters.length} characters`);

  for (const place of seedPlaces) {
    await prisma.places.upsert({
      where: { id: place.id },
      update: place,
      create: place,
    });
  }
  console.log(`Seeded ${seedPlaces.length} places`);

  for (const scene of seedScenes) {
    await prisma.scenes.upsert({
      where: { id: scene.id },
      update: scene,
      create: scene,
    });
  }
  console.log(`Seeded ${seedScenes.length} scenes`);

  // Reset sequences so new IDs don't conflict with seeded ones
  await prisma.$executeRawUnsafe(`SELECT setval(pg_get_serial_sequence('characters', 'id'), (SELECT MAX(id) FROM characters))`);
  await prisma.$executeRawUnsafe(`SELECT setval(pg_get_serial_sequence('places', 'id'), (SELECT MAX(id) FROM places))`);
  await prisma.$executeRawUnsafe(`SELECT setval(pg_get_serial_sequence('scenes', 'id'), (SELECT MAX(id) FROM scenes))`);

  console.log("Seeding complete!");
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
