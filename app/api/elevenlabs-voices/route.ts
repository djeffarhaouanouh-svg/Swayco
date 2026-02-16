import { NextResponse } from "next/server";

export type ElevenLabsVoice = {
  voice_id: string;
  name: string;
  category?: string;
  labels?: Record<string, string>;
};

type ElevenLabsApiResponse = {
  voices: ElevenLabsVoice[];
};

export async function GET() {
  const apiKey = process.env.ELEVENLABS_API_KEY;
  if (!apiKey) {
    return NextResponse.json(
      { error: "ELEVENLABS_API_KEY non configurée" },
      { status: 500 }
    );
  }

  try {
    const res = await fetch("https://api.elevenlabs.io/v1/voices", {
      headers: {
        "xi-api-key": apiKey,
        Accept: "application/json",
      },
    });

    if (!res.ok) {
      const errText = await res.text();
      return NextResponse.json(
        { error: `ElevenLabs API: ${res.status}`, details: errText },
        { status: res.status }
      );
    }

    const data: ElevenLabsApiResponse = await res.json();
    return NextResponse.json(data.voices || []);
  } catch (err) {
    console.error("ElevenLabs voices fetch error:", err);
    return NextResponse.json(
      {
        error: "Erreur lors de la récupération des voix",
        details: err instanceof Error ? err.message : "Unknown error",
      },
      { status: 500 }
    );
  }
}
