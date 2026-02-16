import { NextRequest, NextResponse } from 'next/server';

export async function GET(request: NextRequest) {
  const jobId = request.nextUrl.searchParams.get('jobId');

  if (!jobId) {
    return NextResponse.json({ error: 'jobId requis' }, { status: 400 });
  }

  try {
    const response = await fetch(`https://api.vmodel.ai/api/tasks/v1/get/${jobId}`, {
      headers: {
        'Authorization': `Bearer ${process.env.VMODEL_API_TOKEN}`,
      },
    });

    const data = await response.json();

    // Map VModel statuses to our statuses
    let status = 'processing';
    if (data.status === 'succeeded') status = 'completed';
    else if (data.status === 'failed' || data.status === 'canceled') status = 'failed';

    return NextResponse.json({
      status,
      videoUrl: data.output?.[0] || null,
      error: data.error || null,
      vmodelTime: data.total_time || null,
    });
  } catch (error) {
    console.error('[status]', error);
    return NextResponse.json({ error: 'Erreur polling' }, { status: 500 });
  }
}
