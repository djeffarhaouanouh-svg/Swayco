/// Wire tokens whose spelling predates the Swayco naming.
///
/// The peer on the other end of a call may be running an app build from the
/// stores, and those builds read the legacy key off the LiveKit data channel.
/// We therefore publish both spellings and accept either on receipt. Once
/// builds up to 6.1.6 have aged out, delete [kLegacyLocalTtsFlag] and the two
/// call sites that emit it.
library;

/// Set on a caption packet when the payload carries no audio and the receiver
/// must synthesise speech itself.
const String kLocalTtsFlag = 'localTts';

/// Pre-rename spelling of [kLocalTtsFlag]. Emit-only compatibility.
const String kLegacyLocalTtsFlag = 'kokoro';
