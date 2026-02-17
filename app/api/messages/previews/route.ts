import { NextResponse } from 'next/server';
import { prisma } from '@/lib/prisma';

export const dynamic = 'force-dynamic';

/** Dernier message assistant par personnage (pour la page Messages) */
export async function GET() {
  try {
    const messages = await prisma.messages.findMany({
      where: {
        character_id: { not: null },
        role: 'assistant',
      },
      distinct: ['character_id'],
      orderBy: [{ character_id: 'asc' }, { created_at: 'desc' }],
      select: { character_id: true, content: true, created_at: true },
    });
    const previews = messages
      .map((m) => ({
        characterId: m.character_id!,
        lastMessage: m.content,
        updatedAt: m.created_at,
      }))
      .sort((a, b) => {
        const aTime = a.updatedAt ? new Date(a.updatedAt).getTime() : 0;
        const bTime = b.updatedAt ? new Date(b.updatedAt).getTime() : 0;
        return bTime - aTime;
      });
    return NextResponse.json({ success: true, previews });
  } catch (error) {
    console.error('[API Messages Previews]', error);
    return NextResponse.json({ error: 'Erreur chargement aperçus' }, { status: 500 });
  }
}
