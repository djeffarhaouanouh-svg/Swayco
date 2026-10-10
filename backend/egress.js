'use strict';

// LiveKit Egress — server-side call recording for ad footage only. Records
// BOTH participants' video + audio (RoomComposite, not a screen capture of
// one phone) straight to a Supabase Storage bucket via its S3-compatible
// endpoint. Gated to a single Supabase account (EGRESS_ADMIN_EMAIL) so no
// other user can ever trigger it. Nothing here touches the call's own
// audio/WebRTC path — Egress joins the room as an extra, invisible
// participant.

const { EgressClient, EncodedFileOutput, EncodedFileType, S3Upload } =
  require('livekit-server-sdk');

const LIVEKIT_URL = process.env.LIVEKIT_URL?.trim();
const LIVEKIT_API_KEY = process.env.LIVEKIT_API_KEY?.trim();
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET?.trim();

const EGRESS_ADMIN_EMAIL = process.env.EGRESS_ADMIN_EMAIL?.trim().toLowerCase();

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

/** Only the developer's own Supabase-authenticated account may start/stop a
 *  recording — `email` comes from a verified Supabase JWT, never a client
 *  claim. */
function isEgressAdmin(email) {
  return Boolean(
    EGRESS_ADMIN_EMAIL &&
      typeof email === 'string' &&
      email.trim().toLowerCase() === EGRESS_ADMIN_EMAIL,
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
  const info = await client.startRoomCompositeEgress(
    room,
    { file },
    { layout: 'grid' },
  );
  return { egressId: info.egressId, filename };
}

async function stopEgress(egressId) {
  const client = egressClient();
  if (!client) throw new Error('egress_unconfigured');
  return client.stopEgress(egressId);
}

module.exports = { isEgressAdmin, egressConfigured, startEgress, stopEgress };
