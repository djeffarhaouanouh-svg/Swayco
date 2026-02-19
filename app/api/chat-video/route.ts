import { NextRequest, NextResponse } from 'next/server';
import { prisma } from '@/lib/prisma';

export async function POST(request: NextRequest) {
  try {
    const {
      message,
      conversationHistory,
      characterName,
      characterDescription,
      characterLocation,
      sceneId,
    } = await request.json();

    let systemPrompt: string;

    if (sceneId) {
      const scene = await prisma.scenes.findUnique({
        where: { id: Number(sceneId) },
      });

      // Contexte de lieu : priorité à la description de la scène, sinon on la compose
      const lieuContext = scene?.description
        || (scene ? `Tu te trouves dans ${scene.name}${scene.location ? `, ${scene.location}` : ''}.` : '');

      // Le personnage garde sa propre personnalité, on ajoute juste le lieu
      systemPrompt = `Tu es ${characterName || 'un personnage'}, ${characterDescription || 'quelqu\'un de chaleureux et authentique'}. ${lieuContext} Réponds en restant totalement toi-même. Réponds toujours en français. Sois concis (2-4 phrases max).`;
    } else {
      // Mode personnage classique (sans scène)
      systemPrompt = `Tu es ${characterName || 'un personnage IA'}, ${characterDescription || 'un personnage chaleureux et amical'}. Tu vis à ${characterLocation || 'quelque part dans le monde'}. Réponds de manière naturelle, chaleureuse et en restant dans ton personnage. Réponds toujours en français. Sois concis (2-4 phrases max).`;
    }

    const messages = [
      { role: 'system', content: systemPrompt },
      ...(conversationHistory || []).map((m: { role: string; content: string }) => ({
        role: m.role,
        content: m.content,
      })),
      { role: 'user', content: message },
    ];

    const response = await fetch('https://api.deepseek.com/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${process.env.DEEPSEEK_API_KEY}`,
      },
      body: JSON.stringify({
        model: 'deepseek-chat',
        messages,
        max_tokens: 300,
      }),
    });

    if (!response.ok) {
      const errorData = await response.json().catch(() => ({}));
      console.error('[API chat-video] DeepSeek error:', response.status, errorData);
      return NextResponse.json({ error: 'Erreur API IA' }, { status: 500 });
    }

    const data = await response.json();
    const aiResponse = data.choices?.[0]?.message?.content || 'Désolé, je ne peux pas répondre pour le moment.';

    return NextResponse.json({ aiResponse });
  } catch (error) {
    console.error('[API chat-video]', error);
    return NextResponse.json({ error: 'Erreur serveur' }, { status: 500 });
  }
}
