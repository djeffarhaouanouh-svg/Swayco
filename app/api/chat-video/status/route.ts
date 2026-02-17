import { NextRequest, NextResponse } from 'next/server';
import { put } from '@vercel/blob';

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
    const result = data.result || data;

    // Map VModel statuses to our statuses
    let status = 'processing';
    if (result.status === 'succeeded') status = 'completed';
    else if (result.status === 'failed' || result.status === 'canceled') status = 'failed';

    let videoUrl: string | null = result.output?.[0] || null;

    // Copy the video to Vercel Blob for a stable URL
    if (status === 'completed' && videoUrl && process.env.BLOB_READ_WRITE_TOKEN) {
      try {
        const videoResponse = await fetch(videoUrl);
        if (videoResponse.ok) {
          const videoBuffer = Buffer.from(await videoResponse.arrayBuffer());
          const blob = await put(`videos/chat-${jobId}-${Date.now()}.mp4`, videoBuffer, { access: 'public' });
          videoUrl = blob.url;
        }
      } catch (e) {
        console.error('[status] Failed to copy video to Blob, using original URL:', e);
        // Keep the original VModel URL as fallback
      }
    }

    return NextResponse.json({
      status,
      videoUrl,
      error: result.error || null,
      vmodelTime: result.total_time || null,
    });
  } catch (error) {
    console.error('[status]', error);
    return NextResponse.json({ error: 'Erreur polling' }, { status: 500 });
  }
}
