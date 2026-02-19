import { NextResponse } from 'next/server';
import { prisma } from '@/lib/prisma';

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    // 1. Conversations directes avec un personnage (pas de scène)
    const charMessages = await prisma.messages.findMany({
      where: { character_id: { not: null }, scene_id: null, role: 'assistant' },
      distinct: ['character_id'],
      orderBy: [{ character_id: 'asc' }, { created_at: 'desc' }],
      select: { character_id: true, content: true, created_at: true },
    });

    // 3. Visites de lieux (scene_session_id commence par "place_", pas de scene_id)
    const placeMessages = await prisma.messages.findMany({
      where: { scene_id: null, scene_session_id: { startsWith: 'place_' }, role: 'assistant' },
      distinct: ['scene_session_id'],
      orderBy: [{ scene_session_id: 'asc' }, { created_at: 'desc' }],
      select: { scene_session_id: true, content: true, created_at: true },
    });

    // 2a. Sessions de scènes avec session_id (une entrée par session)
    const newSessionMessages = await prisma.messages.findMany({
      where: { scene_id: { not: null }, scene_session_id: { not: null }, role: 'assistant' },
      distinct: ['scene_session_id'],
      orderBy: [{ scene_session_id: 'asc' }, { created_at: 'desc' }],
      select: { scene_id: true, scene_session_id: true, character_id: true, content: true, created_at: true },
    });

    // 2b. Anciennes sessions sans session_id (groupées par scene_id pour rétrocompat)
    const oldSessionMessages = await prisma.messages.findMany({
      where: { scene_id: { not: null }, scene_session_id: null, role: 'assistant' },
      distinct: ['scene_id'],
      orderBy: [{ scene_id: 'asc' }, { created_at: 'desc' }],
      select: { scene_id: true, scene_session_id: true, character_id: true, content: true, created_at: true },
    });

    const sceneMessages = [...newSessionMessages, ...oldSessionMessages];

    // Récupérer les scènes concernées (avec leur character_id par défaut)
    const sceneIds = sceneMessages.map(m => m.scene_id!).filter(Boolean);
    const scenes = sceneIds.length > 0
      ? await prisma.scenes.findMany({ where: { id: { in: sceneIds } } })
      : [];
    const sceneMap = Object.fromEntries(scenes.map(s => [s.id, s]));

    // Résoudre le character_id effectif pour chaque message de scène
    // Priorité : character_id du message, sinon character_id par défaut de la scène
    const resolvedSceneChars = sceneMessages.map(m => {
      const scene = sceneMap[m.scene_id!];
      return m.character_id ?? scene?.character_id ?? null;
    });

    // Collecter tous les character_id à charger
    const charIds = [
      ...charMessages.map(m => m.character_id!),
      ...resolvedSceneChars.filter((id): id is number => id != null),
    ];
    const uniqueCharIds = [...new Set(charIds)];
    const dbCharacters = uniqueCharIds.length > 0
      ? await prisma.characters.findMany({
          where: { id: { in: uniqueCharIds } },
          select: { id: true, name: true, image_url: true },
        })
      : [];
    const charMap = Object.fromEntries(dbCharacters.map(c => [c.id, c]));

    // Construire les previews
    const charPreviews = charMessages.map(m => ({
      type: 'character' as const,
      characterId: m.character_id!,
      lastMessage: m.content,
      updatedAt: m.created_at ? m.created_at.toISOString() : null,
    }));

    const scenePreviews = sceneMessages.map((m, i) => {
      const scene = sceneMap[m.scene_id!];
      const effectiveCharId = resolvedSceneChars[i];
      const char = effectiveCharId ? charMap[effectiveCharId] : null;
      return {
        type: 'scene' as const,
        sceneId: m.scene_id!,
        sceneSessionId: m.scene_session_id || null,
        sceneName: scene?.name || 'Scène',
        sceneImage: scene?.image_url || null,
        sceneLocation: scene?.location || null,
        characterId: effectiveCharId,
        characterName: char?.name || null,
        characterImage: char?.image_url || null,
        lastMessage: m.content,
        updatedAt: m.created_at ? m.created_at.toISOString() : null,
      };
    });

    const placePreviews = placeMessages.map(m => ({
      type: 'place' as const,
      placeSessionId: m.scene_session_id!,
      placeName: 'Guide Tour Eiffel',
      placeImage: 'https://images.unsplash.com/photo-1511739001486-6bfe10ce785f?w=400&h=500&fit=crop',
      placeLocation: 'Paris, France',
      lastMessage: m.content,
      updatedAt: m.created_at ? m.created_at.toISOString() : null,
    }));

    const all = [...charPreviews, ...scenePreviews, ...placePreviews].sort((a, b) => {
      const aTime = a.updatedAt ? new Date(a.updatedAt).getTime() : 0;
      const bTime = b.updatedAt ? new Date(b.updatedAt).getTime() : 0;
      return bTime - aTime;
    });

    return NextResponse.json({ success: true, previews: all });
  } catch (error) {
    console.error('[API Messages Previews]', error);
    return NextResponse.json({ error: 'Erreur chargement aperçus' }, { status: 500 });
  }
}
