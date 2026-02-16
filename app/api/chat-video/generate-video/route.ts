import { NextRequest, NextResponse } from 'next/server';

// VModel version ID for video generation - adjust if needed
const VMODEL_VIDEO_VERSION = 'YOUR_VIDEO_MODEL_VERSION_ID'; // TODO: set the correct 64-char version ID

export async function POST(request: NextRequest) {
  try {
    const { content, characterImage } = await request.json();

    if (!content?.trim()) {
      return NextResponse.json({ error: 'Contenu requis' }, { status: 400 });
    }

    const response = await fetch('https://api.vmodel.ai/api/tasks/v1/create', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${process.env.VMODEL_API_TOKEN}`,
      },
      body: JSON.stringify({
        version: VMODEL_VIDEO_VERSION,
        input: {
          text: content.trim(),
          image_url: characterImage || undefined,
        },
      }),
    });

    const data = await response.json();

    if (!response.ok || !data.result?.task_id) {
      console.error('[generate-video] VModel error:', data);
      return NextResponse.json({ error: data.message || 'Erreur génération vidéo' }, { status: 500 });
    }

    return NextResponse.json({ jobId: data.result.task_id });
  } catch (error) {
    console.error('[generate-video]', error);
    return NextResponse.json({ error: 'Erreur serveur' }, { status: 500 });
  }
}
