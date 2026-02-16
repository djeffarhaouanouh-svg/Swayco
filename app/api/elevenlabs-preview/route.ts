import { NextRequest, NextResponse } from "next/server";

const PREVIEW_TEXT = "Bonjour, je suis prêt pour notre conversation.";

export async function GET(request: NextRequest) {
  const voiceId = request.nextUrl.searchParams.get("voice_id");
  if (!voiceId) {
    return NextResponse.json({ error: "voice_id requis" }, { status: 400 });
  }

  const apiKey = process.env.ELEVENLABS_API_KEY;
  if (!apiKey) {
    return NextResponse.json(
      { error: "ELEVENLABS_API_KEY non configurée" },
      { status: 500 }
    );
  }

  try {
    const res = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
      {
        method: "POST",
        headers: {
          "xi-api-key": apiKey,
          "Content-Type": "application/json",
          Accept: "audio/mpeg",
        },
        body: JSON.stringify({
          text: PREVIEW_TEXT,
          model_id: "eleven_multilingual_v2",
        }),
      }
    );

    if (!res.ok) {
      const errText = await res.text();
      return NextResponse.json(
        { error: `ElevenLabs API: ${res.status}`, details: errText },
        { status: res.status }
      );
    }

    const audioBuffer = await res.arrayBuffer();
    return new NextResponse(audioBuffer, {
      headers: {
        "Content-Type": "audio/mpeg",
        "Cache-Control": "private, max-age=3600",
      },
    });
  } catch (err) {
    console.error("ElevenLabs preview error:", err);
    return NextResponse.json(
      {
        error: "Erreur lors de la génération de l'aperçu",
        details: err instanceof Error ? err.message : "Unknown error",
      },
      { status: 500 }
    );
  }
}
