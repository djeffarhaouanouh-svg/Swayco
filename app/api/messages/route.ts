import { NextRequest, NextResponse } from 'next/server';
import { prisma } from '@/lib/prisma';

export const dynamic = 'force-dynamic';

export async function GET(request: NextRequest) {
  const characterId = request.nextUrl.searchParams.get('characterId');
  const sceneId = request.nextUrl.searchParams.get('sceneId');
  const sceneSessionId = request.nextUrl.searchParams.get('sceneSessionId');

  const where: Record<string, unknown> = {};
  if (characterId) where.character_id = parseInt(characterId);
  if (sceneSessionId) where.scene_session_id = sceneSessionId;
  else if (sceneId) where.scene_id = parseInt(sceneId);

  try {
    const messages = await prisma.messages.findMany({
      where,
      orderBy: { created_at: 'asc' },
    });
    return NextResponse.json({ success: true, messages });
  } catch (error) {
    console.error('[API Messages GET]', error);
    return NextResponse.json({ error: 'Erreur chargement messages' }, { status: 500 });
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const message = await prisma.messages.create({
      data: {
        user_id: body.userId ? parseInt(body.userId) : null,
        character_id: body.characterId ? parseInt(body.characterId) : null,
        scene_id: body.sceneId ? parseInt(body.sceneId) : null,
        scene_session_id: body.sceneSessionId || null,
        role: body.role,
        content: body.content,
        video_url: body.videoUrl || null,
        audio_url: body.audioUrl || null,
      },
    });
    return NextResponse.json({ success: true, message }, { status: 201 });
  } catch (error) {
    console.error('[API Messages POST]', error);
    return NextResponse.json({ error: 'Erreur sauvegarde message' }, { status: 500 });
  }
}

export async function PUT(request: NextRequest) {
  try {
    const body = await request.json();
    const message = await prisma.messages.update({
      where: { id: body.id },
      data: {
        video_url: body.videoUrl ?? undefined,
        audio_url: body.audioUrl ?? undefined,
        content: body.content ?? undefined,
      },
    });
    return NextResponse.json({ success: true, message });
  } catch (error) {
    console.error('[API Messages PUT]', error);
    return NextResponse.json({ error: 'Erreur mise à jour message' }, { status: 500 });
  }
}

export async function DELETE(request: NextRequest) {
  const characterId = request.nextUrl.searchParams.get('characterId');
  const sceneId = request.nextUrl.searchParams.get('sceneId');
  const sceneSessionId = request.nextUrl.searchParams.get('sceneSessionId');

  const where: Record<string, unknown> = {};
  if (characterId) where.character_id = parseInt(characterId);
  if (sceneSessionId) where.scene_session_id = sceneSessionId;
  else if (sceneId) where.scene_id = parseInt(sceneId);

  try {
    await prisma.messages.deleteMany({ where });
    return NextResponse.json({ success: true });
  } catch (error) {
    console.error('[API Messages DELETE]', error);
    return NextResponse.json({ error: 'Erreur suppression messages' }, { status: 500 });
  }
}
