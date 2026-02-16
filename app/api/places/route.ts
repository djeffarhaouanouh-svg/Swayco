import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";

function mapPlace(p: {
  id: number;
  name: string;
  location: string;
  lng: number;
  lat: number;
  image_url: string | null;
  description: string | null;
  stats_visitors: string | null;
}) {
  return {
    id: p.id,
    type: "place" as const,
    name: p.name,
    location: p.location,
    coordinates: [p.lng, p.lat] as [number, number],
    image: p.image_url || "",
    images: p.image_url ? [p.image_url] : [],
    description: p.description || "",
    stats: { visitors: p.stats_visitors || "0" },
  };
}

export async function GET() {
  try {
    const places = await prisma.places.findMany({
      orderBy: { created_at: "desc" },
    });
    return NextResponse.json(places.map(mapPlace));
  } catch (error) {
    console.error("[API Places GET]", error);
    return NextResponse.json(
      { error: "Erreur lors de la récupération des lieux" },
      { status: 500 }
    );
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { name, address, imageUrl } = body;

    if (!name?.trim()) {
      return NextResponse.json({ error: "Nom requis" }, { status: 400 });
    }

    const location = address?.trim() || name.trim();

    // Geocode via Nominatim
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
      console.warn("[Geocoding Place]", geoErr);
    }

    if (lng === 0 && lat === 0) {
      lng = 2.3522 + (Math.random() - 0.5) * 0.5;
      lat = 48.8566 + (Math.random() - 0.5) * 0.5;
    }

    const place = await prisma.places.create({
      data: {
        name: name.trim(),
        location,
        lng,
        lat,
        image_url: imageUrl || null,
        description: null,
        stats_visitors: "0",
      },
    });

    return NextResponse.json(mapPlace(place), { status: 201 });
  } catch (error) {
    console.error("[API Places POST]", error);
    return NextResponse.json(
      { error: "Erreur lors de la création du lieu" },
      { status: 500 }
    );
  }
}
