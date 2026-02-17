import { NextRequest, NextResponse } from 'next/server';
import { put } from '@vercel/blob';
import { prisma } from '@/lib/prisma';
import { characters as staticCharacters } from '@/data/worldData';

const VMODEL_VERSION = 'ae74513f15f2bb0e42acf4023d7cd6dbddd61242c5538b71f830a630aacf1c9d';

// Default ElevenLabs voice if character has none
const DEFAULT_VOICE_ID = 'EXAVITQu4vr4xnSDxMaL'; // "Sarah" - a natural female voice

async function uploadToBlob(data: Blob | Buffer, filename: string): Promise<string> {
  const blob = await put(filename, data, { access: 'public' });
  return blob.url;
}

export async function POST(request: NextRequest) {
  try {
    const { content, characterId } = await request.json();

    if (!content?.trim()) {
      return NextResponse.json({ error: 'Contenu requis' }, { status: 400 });
    }

    const elevenLabsKey = process.env.ELEVENLABS_API_KEY;
    const vmodelToken = process.env.VMODEL_API_TOKEN;

    if (!elevenLabsKey) {
      return NextResponse.json({ error: 'ELEVENLABS_API_KEY manquante' }, { status: 500 });
    }
    if (!vmodelToken) {
      return NextResponse.json({ error: 'VMODEL_API_TOKEN manquant' }, { status: 500 });
    }

    // --- Resolve character (voice + avatar) ---
    let voiceId: string | null = null;
    let avatarUrl: string | null = null;

    // Try static characters first
    if (characterId) {
      const staticChar = staticCharacters.find(c => c.id === characterId);
      if (staticChar) {
        voiceId = staticChar.voiceId || null;
        avatarUrl = staticChar.image || null;
      }

      // Try DB characters (may override static)
      try {
        const dbChar = await prisma.characters.findUnique({ where: { id: characterId } });
        if (dbChar) {
          voiceId = dbChar.voice_id || voiceId;
          avatarUrl = dbChar.image_url || avatarUrl;
        }
      } catch {
        // DB not available, use static data
      }
    }

    voiceId = voiceId || DEFAULT_VOICE_ID;

    const baseUrl = process.env.NEXT_PUBLIC_APP_URL || 'http://localhost:3000';
    avatarUrl = avatarUrl || `${baseUrl}/avatar-1.png`;

    // Make relative URLs absolute
    if (avatarUrl.startsWith('/')) {
      avatarUrl = `${baseUrl}${avatarUrl}`;
    }

    // If avatar is on localhost, upload to Blob so VModel can access it
    const isLocalAvatar = avatarUrl.includes('localhost') || avatarUrl.includes('127.0.0.1');
    if (isLocalAvatar && process.env.BLOB_READ_WRITE_TOKEN) {
      try {
        const avatarResponse = await fetch(avatarUrl);
        if (avatarResponse.ok) {
          const avatarBuffer = Buffer.from(await avatarResponse.arrayBuffer());
          const contentType = avatarResponse.headers.get('content-type') || 'image/png';
          const ext = contentType.includes('jpeg') || contentType.includes('jpg') ? 'jpg' : 'png';
          avatarUrl = await uploadToBlob(avatarBuffer, `avatars/char-${characterId || 'default'}-${Date.now()}.${ext}`);
        }
      } catch (e) {
        console.error('[generate-video] Failed to upload local avatar to blob:', e);
      }
    }

    // --- Step 1: ElevenLabs TTS (text → audio MP3) ---
    console.log('[generate-video] Generating audio via ElevenLabs, voiceId:', voiceId);
    const ttsResponse = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
      {
        method: 'POST',
        headers: {
          'xi-api-key': elevenLabsKey,
          'Content-Type': 'application/json',
          'Accept': 'audio/mpeg',
        },
        body: JSON.stringify({
          text: content.trim(),
          model_id: 'eleven_multilingual_v2',
          voice_settings: {
            stability: 0.5,
            similarity_boost: 0.75,
          },
        }),
      }
    );

    if (!ttsResponse.ok) {
      const errText = await ttsResponse.text();
      console.error('[generate-video] ElevenLabs error:', ttsResponse.status, errText);
      return NextResponse.json({ error: 'Erreur génération audio' }, { status: 500 });
    }

    const audioBuffer = Buffer.from(await ttsResponse.arrayBuffer());

    // --- Step 2: Upload audio to Vercel Blob ---
    console.log('[generate-video] Uploading audio to Blob...');
    const audioBlobUrl = await uploadToBlob(audioBuffer, `audio/tts-${Date.now()}.mp3`);
    console.log('[generate-video] Audio uploaded:', audioBlobUrl);

    // --- Step 3: Call VModel (avatar + speech → video) ---
    console.log('[generate-video] Calling VModel with avatar:', avatarUrl, 'speech:', audioBlobUrl);
    const vmodelResponse = await fetch('https://api.vmodel.ai/api/tasks/v1/create', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${vmodelToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        version: VMODEL_VERSION,
        input: {
          avatar: avatarUrl,
          speech: audioBlobUrl,
          resolution: '480',
        },
      }),
    });

    const vmodelData = await vmodelResponse.json();

    if (!vmodelResponse.ok || !vmodelData.result?.task_id) {
      console.error('[generate-video] VModel error:', vmodelData);
      return NextResponse.json({ error: vmodelData.message || 'Erreur génération vidéo' }, { status: 500 });
    }

    console.log('[generate-video] VModel task created:', vmodelData.result.task_id);
    return NextResponse.json({
      jobId: vmodelData.result.task_id,
      audioUrl: audioBlobUrl,
    });
  } catch (error) {
    console.error('[generate-video]', error);
    return NextResponse.json({ error: 'Erreur serveur' }, { status: 500 });
  }
}
