import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";

export const dynamic = 'force-dynamic';

// Map coordinates by country name (fallback when no precise coords)
const COUNTRY_COORDS: Record<string, [number, number]> = {
  France: [2.3522, 48.8566],
  Japon: [139.6917, 35.6895],
  Italie: [12.4964, 41.9028],
  "Royaume-Uni": [-0.1278, 51.5074],
  Brésil: [-43.1729, -22.9068],
  Maroc: [-7.9811, 31.6295],
  Russie: [37.6173, 55.7558],
  Espagne: [2.1734, 41.3851],
  USA: [-74.006, 40.7128],
  Irlande: [-6.2603, 53.3498],
  Chine: [121.4737, 31.2304],
  Australie: [151.2093, -33.8688],
  Grèce: [23.7275, 37.9838],
  Égypte: [31.2357, 30.0444],
  "Pays-Bas": [4.9041, 52.3676],
  Inde: [78.0421, 27.1751],
  Pérou: [-75.0152, -9.19],
  Portugal: [-8.2245, 39.3999],
};

function mapCharacter(c: {
  id: number;
  name: string;
  location: string;
  country: string;
  lng: number;
  lat: number;
  image_url: string | null;
  description: string | null;
  teaser: string | null;
  city_image: string | null;
  badge: string | null;
  voice_id: string | null;
  stats_messages: string | null;
  creator?: { name: string | null } | null;
}) {
  return {
    id: c.id,
    type: "character" as const,
    name: c.name,
    location: c.location,
    country: c.country,
    coordinates: [c.lng, c.lat] as [number, number],
    image: (c.image_url && !c.image_url.startsWith("blob:")) ? c.image_url : "/jade.png",
    description: c.description || "",
    teaser: c.teaser || undefined,
    cityImage: c.city_image || undefined,
    stats: { messages: c.stats_messages || "0" },
    badge: c.badge || "FX",
    voiceId: c.voice_id || undefined,
    creatorName: c.creator?.name || undefined,
  };
}

export async function GET(request: NextRequest) {
  try {
    const url = request.url ?? `${request.nextUrl?.origin || ""}/api/characters${request.nextUrl?.search || ""}`;
    const { searchParams } = new URL(url);
    const creatorIdParam = searchParams.get("creatorId");
    const creatorId = creatorIdParam ? parseInt(creatorIdParam, 10) : undefined;

    const where = creatorId != null && !isNaN(creatorId)
      ? { creator_id: creatorId }
      : undefined;

    const chars = await prisma.characters.findMany({
      where,
      orderBy: { id: "desc" },
    });

    const creatorIds = [...new Set(chars.map((c) => c.creator_id).filter((id): id is number => id != null))];
    const creators = creatorIds.length > 0
      ? await prisma.users.findMany({
          where: { id: { in: creatorIds } },
          select: { id: true, name: true },
        })
      : [];
    const creatorMap = Object.fromEntries(creators.map((u) => [u.id, u.name]));

    const withCreator = chars.map((c) => ({
      ...c,
      creator: c.creator_id ? { name: creatorMap[c.creator_id] ?? null } : null,
    }));

    return NextResponse.json(withCreator.map(mapCharacter));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("[API Characters GET]", error);
    return NextResponse.json(
      { error: "Erreur lors de la récupération des personnages", details: message },
      { status: 500 }
    );
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { name, country, address, age, description, voiceId, imageUrl, creatorId, creatorEmail } = body;

    if (!name?.trim()) {
      return NextResponse.json({ error: "Nom requis" }, { status: 400 });
    }
    if (!country?.trim()) {
      return NextResponse.json({ error: "Pays requis" }, { status: 400 });
    }

    const location = address?.trim()
      ? `${address.trim()}, ${country.trim()}`
      : country.trim();

    // Geocode: convert address/country to precise coordinates via Nominatim
    let lng = 0;
    let lat = 0;
    try {
      const query = encodeURIComponent(location);
      const geoRes = await fetch(
        `https://nominatim.openstreetmap.org/search?q=${query}&format=json&limit=1`,
        { headers: { "User-Agent": "Swayco/1.0" } }
      );
      const geoData = await geoRes.json();
      if (Array.isArray(geoData) && geoData.length > 0) {
        lng = parseFloat(geoData[0].lon);
        lat = parseFloat(geoData[0].lat);
      }
    } catch (geoErr) {
      console.warn("[Geocoding] Erreur, fallback sur coords pays:", geoErr);
    }

    // Fallback: use country center if geocoding failed
    if (lng === 0 && lat === 0) {
      const coords = COUNTRY_COORDS[country.trim()] || [0, 0];
      lng = coords[0] + (Math.random() - 0.5) * 0.5;
      lat = coords[1] + (Math.random() - 0.5) * 0.5;
    }

    const descText = [
      description?.trim() || "",
      age?.trim() ? `${age.trim()} ans.` : "",
    ]
      .filter(Boolean)
      .join(" ");

    let creatorIdNum: number | undefined;
    if (creatorId != null) {
      const parsed = parseInt(String(creatorId), 10);
      if (!isNaN(parsed)) creatorIdNum = parsed;
    }
    if (creatorIdNum == null && creatorEmail?.trim()) {
      const user = await prisma.users.findUnique({
        where: { email: creatorEmail.trim() },
        select: { id: true },
      });
      if (user) creatorIdNum = user.id;
    }
    const character = await prisma.characters.create({
      data: {
        name: name.trim(),
        location,
        country: country.trim(),
        lng,
        lat,
        image_url: imageUrl || null,
        description: descText || null,
        teaser: null,
        city_image: null,
        badge: "FX",
        voice_id: voiceId || null,
        stats_messages: "0",
        ...(creatorIdNum != null && { creator_id: creatorIdNum }),
      },
    });
    return NextResponse.json(mapCharacter(character), { status: 201 });
  } catch (error) {
    console.error("[API Characters POST]", error);
    return NextResponse.json(
      { error: "Erreur lors de la création du personnage" },
      { status: 500 }
    );
  }
}
