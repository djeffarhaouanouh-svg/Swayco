'use strict';

// LiveKit Egress — server-side call recording for ad footage only. Records
// BOTH participants' video + audio (RoomComposite, not a screen capture of
// one phone) straight to a Supabase Storage bucket via its S3-compatible
// endpoint. Gated to an allow-list of Supabase accounts (EGRESS_ADMIN_EMAIL /
// EGRESS_ADMIN_EMAILS) so no other user can ever trigger it. The list lives
// in Railway env vars, not in the app build, so granting someone access is a
// Railway edit, not a new app release — see isEgressAdmin(). Nothing here
// touches the call's own audio/WebRTC path — Egress joins the room as an
// extra, invisible participant.

const {
  EgressClient,
  EncodedFileOutput,
  EncodedFileType,
  EncodingOptionsPreset,
  S3Upload,
} = require('livekit-server-sdk');

const LIVEKIT_URL = process.env.LIVEKIT_URL?.trim();
const LIVEKIT_API_KEY = process.env.LIVEKIT_API_KEY?.trim();
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET?.trim();

// Allow-list of emails that may start/stop a recording. Union of the single
// legacy var (kept so the Railway value already set doesn't need renaming)
// and a comma-separated list for adding more people without touching code.
const EGRESS_ADMIN_EMAILS = new Set(
  [
    process.env.EGRESS_ADMIN_EMAIL,
    ...(process.env.EGRESS_ADMIN_EMAILS?.split(',') ?? []),
  ]
    .map((e) => e?.trim().toLowerCase())
    .filter(Boolean),
);

const S3_ACCESS_KEY = process.env.EGRESS_S3_ACCESS_KEY?.trim();
const S3_SECRET_KEY = process.env.EGRESS_S3_SECRET_KEY?.trim();
const S3_ENDPOINT = process.env.EGRESS_S3_ENDPOINT?.trim();
const S3_BUCKET = process.env.EGRESS_S3_BUCKET?.trim();
const S3_REGION = process.env.EGRESS_S3_REGION?.trim() || 'us-east-1';

let _client;
function egressClient() {
  if (_client !== undefined) return _client;
  if (!LIVEKIT_URL || !LIVEKIT_API_KEY || !LIVEKIT_API_SECRET) {
    _client = null;
    return null;
  }
  _client = new EgressClient(LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET);
  return _client;
}

function egressConfigured() {
  return Boolean(
    egressClient() && S3_ACCESS_KEY && S3_SECRET_KEY && S3_ENDPOINT && S3_BUCKET,
  );
}

/** Only an allow-listed Supabase-authenticated account may start/stop a
 *  recording — `email` comes from a verified Supabase JWT, never a client
 *  claim. Add/remove people by editing EGRESS_ADMIN_EMAILS in Railway. */
function isEgressAdmin(email) {
  return Boolean(
    typeof email === 'string' && EGRESS_ADMIN_EMAILS.has(email.trim().toLowerCase()),
  );
}

/** Starts a RoomComposite recording of `room` — both participants' tiles,
 *  merged audio — uploaded directly to the Supabase Storage bucket by
 *  LiveKit's own Egress worker. Returns { egressId, filename }. */
async function startEgress(room) {
  const client = egressClient();
  if (!client || !egressConfigured()) {
    throw new Error('egress_unconfigured');
  }
  const filename = `recordings/${room}-${Date.now()}.mp4`;
  const file = new EncodedFileOutput({
    fileType: EncodedFileType.MP4,
    filepath: filename,
    output: {
      case: 's3',
      value: new S3Upload({
        accessKey: S3_ACCESS_KEY,
        secret: S3_SECRET_KEY,
        region: S3_REGION,
        endpoint: S3_ENDPOINT,
        bucket: S3_BUCKET,
        forcePathStyle: true,
      }),
    },
  });
  // Portrait (1080x1920) — matches how the call screen itself is framed and
  // how the footage gets used (TikTok/Reels/Stories ads), not the landscape
  // default.
  const info = await client.startRoomCompositeEgress(
    room,
    { file },
    { layout: 'grid', encodingOptions: EncodingOptionsPreset.PORTRAIT_H264_1080P_30 },
  );
  return { egressId: info.egressId, filename };
}

async function stopEgress(egressId) {
  const client = egressClient();
  if (!client) throw new Error('egress_unconfigured');
  return client.stopEgress(egressId);
}

/** Diagnostic only: the last few egress jobs with their actual status/error
 *  from LiveKit — start/stop only confirm the job was ACCEPTED, not that the
 *  S3 upload succeeded, so this is the only place that failure surfaces. */
async function listRecentEgress() {
  const client = egressClient();
  if (!client) throw new Error('egress_unconfigured');
  const jobs = await client.listEgress();
  return jobs
    .sort((a, b) => Number(b.startedAt) - Number(a.startedAt))
    .slice(0, 10)
    .map((j) => ({
      egressId: j.egressId,
      roomName: j.roomName,
      status: j.status,
      error: j.error || null,
      startedAt: Number(j.startedAt),
      endedAt: Number(j.endedAt) || null,
      files: j.fileResults.map((f) => ({
        filename: f.filename,
        location: f.location,
        size: Number(f.size),
      })),
    }));
}

module.exports = {
  isEgressAdmin,
  egressConfigured,
  startEgress,
  stopEgress,
  listRecentEgress,
};
