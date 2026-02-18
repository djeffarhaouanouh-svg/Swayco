import { NextRequest, NextResponse } from 'next/server'

const N8N_URL = 'https://ouistitiii.app.n8n.cloud/webhook-test/guide-eiffel'

export async function POST(request: NextRequest) {
  try {
    const body = await request.json()

    const res = await fetch(N8N_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })

    if (!res.ok) {
      return NextResponse.json(
        { error: `Erreur webhook: ${res.status}` },
        { status: res.status }
      )
    }

    const raw = await res.json()
    // n8n renvoie parfois un tableau — on unwrap le premier élément
    const data = Array.isArray(raw) ? raw[0] : raw
    return NextResponse.json(data)
  } catch (error) {
    console.error('[Guide Eiffel API]', error)
    return NextResponse.json(
      { error: 'Erreur serveur' },
      { status: 500 }
    )
  }
}
