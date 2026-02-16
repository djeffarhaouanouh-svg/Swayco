import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";

export const dynamic = 'force-dynamic';

function mapScene(s: {
  id: number;
  name: string;
  location: string;
  lng: number;
  lat: number;
  image_url: string | null;
  description: string | null;
  character_id: number;
}) {
  return {
    id: s.id,
    type: "scene" as const,
    name: s.name,
    location: s.location,
    coordinates: [s.lng, s.lat] as [number, number],
    image: s.image_url || "",
    description: s.description || "",
    characterId: s.character_id,
  };
}

export async function GET() {
  try {
    const scenes = await prisma.scenes.findMany({
      orderBy: { created_at: "desc" },
    });
    return NextResponse.json(scenes.map(mapScene));
  } catch (error) {
    console.error("[API Scenes GET]", error);
    return NextResponse.json(
      { error: "Erreur lors de la récupération des scènes" },
      { status: 500 }
    );
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { name, location, description, typeScene, ambiance, characterId, imageUrl } = body;

    if (!name?.trim()) {
      return NextResponse.json({ error: "Nom requis" }, { status: 400 });
    }

    const loc = location?.trim() || name.trim();

    // Geocode via Nominatim
    let lng = 0;
    let lat = 0;
    try {
      const query = encodeURIComponent(loc);
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
      console.warn("[Geocoding Scene]", geoErr);
    }

    // Fallback: Paris center
    if (lng === 0 && lat === 0) {
      lng = 2.3522 + (Math.random() - 0.5) * 0.5;
      lat = 48.8566 + (Math.random() - 0.5) * 0.5;
    }

    const descParts = [
      typeScene?.trim() ? `Type: ${typeScene.trim()}.` : "",
      ambiance?.trim() ? `Ambiance: ${ambiance.trim()}.` : "",
      description?.trim() || "",
    ].filter(Boolean);

    const scene = await prisma.scenes.create({
      data: {
        name: name.trim(),
        location: loc,
        lng,
        lat,
        image_url: imageUrl || null,
        description: descParts.join(" ") || null,
        type_scene: typeScene?.trim() || null,
        ambiance: ambiance?.trim() || null,
        character_id: characterId || 1,
      },
    });

    return NextResponse.json(mapScene(scene), { status: 201 });
  } catch (error) {
    console.error("[API Scenes POST]", error);
    return NextResponse.json(
      { error: "Erreur lors de la création de la scène" },
      { status: 500 }
    );
  }
}
