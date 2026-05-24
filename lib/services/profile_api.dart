import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Translation credits, refilled every 30 days. UI-side we expose
/// these as "crédits" where 1 crédit = 60 s of translated call, so the
/// per-tier numbers read as 75 / 300 / 1000 / 2000 — abstract and
/// generous instead of stopwatch-y. Source of truth for the matching
/// per-tier values lives in `backend/tiers.js` (FEATURES); these
/// constants exist so the local UI can pre-render a refill without
/// waiting on the network.
const int freeMonthlyCreditsSeconds = 75 * 60;          // 75 crédits / mois
const int plusMonthlyCreditsSeconds = 360 * 60;         // 360 crédits / mois (6 h)
const int ultraPlusMonthlyCreditsSeconds = 1300 * 60;   // 1300 crédits / mois ≈ 5 h / semaine (cap fair-use)

/// Legacy alias kept so older call sites that still read this name
/// keep compiling during the rename. New code should use the
/// `*MonthlyCreditsSeconds` constants above directly.
const int freeWeeklyCreditsSeconds = freeMonthlyCreditsSeconds;
const int freeWeeklyAdvertisedSeconds = freeMonthlyCreditsSeconds;
const int proWeeklyCreditsSeconds = ultraPlusMonthlyCreditsSeconds;

/// Refill cadence: every 30 days from the last refill. Aligned with
/// Stripe's monthly invoice so "refill" and "new bill" land together.
const Duration creditsRefillPeriod = Duration(days: 30);

class RemoteProfile {
  const RemoteProfile({
    required this.id,
    required this.handle,
    required this.displayName,
    required this.language,
    required this.avatarColor,
    required this.avatarUrl,
    this.discoverPhotoUrl = '',
    this.bio = '',
    this.gender = '',
    this.hideOnlineStatus = false,
    this.isPro = false,
    this.subscriptionTier = 'free',
    this.elevenlabsVoiceId = '',
    this.creditsSeconds = freeWeeklyCreditsSeconds,
    this.creditsResetAt,
    this.lifetimeCallSeconds = 0,
    this.proExpiresAt,
    this.lastSeen,
  });

  final String id;
  final String handle;
  final String displayName;
  final String language;
  final String avatarColor;
  final String avatarUrl;

  /// Public URL of the larger photo shown when this profile appears in
  /// someone else's Discover card stack. Optional — empty falls back to
  /// [avatarUrl] (or the placeholder beyond that).
  final String discoverPhotoUrl;

  /// Free-form short tagline shown on the user's own profile and on their
  /// Discover card. Capped at [profileBioMaxLength] characters.
  final String bio;

  /// Self-declared grammatical gender. One of:
  ///   'm' — masculine
  ///   'f' — feminine
  ///   'x' — non-binary / unspecified
  ///   ''  — not provided
  /// Used by the contextual chat translator so gendered languages
  /// (FR/ES/IT/AR/HE/…) produce the correct agreement. Not exposed in
  /// the profile editor yet; column lives in the DB so the wiring is
  /// ready when we surface it.
  final String gender;

  /// When true, other clients should not show this user as online or render
  /// their "last seen" timestamp. Source of truth lives on the server so it
  /// can't be bypassed by a tampered client.
  final bool hideOnlineStatus;

  /// Subscription state. `true` while the user has an active Premium
  /// entitlement (validated against the store IAP receipt server-side, later).
  final bool isPro;

  /// Raw tier string: `'free' | 'plus' | 'pro' | 'ultra'`. Used by the
  /// chat UI to decide whether to expose the `/voice/dub` CTA (Plus+)
  /// or the live-call upgrade nudge. The backend re-validates the tier
  /// on every paid endpoint — this field only drives client-side hints.
  final String subscriptionTier;

  bool get isPlus => subscriptionTier == 'plus'
      || subscriptionTier == 'ultra_plus';
  /// True for the new top tier "Ultra Plus" (was historically "pro" /
  /// "ultra" — both have been collapsed into this single tier).
  bool get isUltraPlus => subscriptionTier == 'ultra_plus';

  /// Legacy alias kept so chat_thread_screen / other call sites that
  /// still read `isUltra` keep compiling during the rename. Same
  /// semantics as [isUltraPlus] now that Ultra/Pro merged.
  bool get isUltra => isUltraPlus;

  /// True when this user's tier unlocks /voice/dub — i.e. anything
  /// above Free. Mirrors `tiers.js#FEATURES.voiceDub !== 'none'`.
  bool get canDubAudio => isPlus;

  /// ElevenLabs voice id from the user's own Instant Voice Clone.
  /// Populated by /voice/enroll. Empty until enrolled. Only ever
  /// non-empty for Ultra subscribers — the backend gates enrolment on
  /// tier so this field stays empty for everyone else.
  final String elevenlabsVoiceId;

  /// True when this user has already enrolled their voice clone.
  /// Drives the profile card's "Voix clonée" badge vs. the CTA.
  bool get hasClonedVoice => elevenlabsVoiceId.isNotEmpty;

  /// Translation credit remaining in seconds. Decremented during calls; the
  /// translation pipeline disables itself when this hits 0 but the underlying
  /// call keeps going.
  final int creditsSeconds;

  /// Next refill — when `now()` passes this, credits are reset to the tier's
  /// weekly allotment ([proWeeklyCreditsSeconds] / [freeWeeklyCreditsSeconds]).
  final DateTime? creditsResetAt;

  /// Lifetime stat (never reset). Used for "X minutes used" on the profile.
  final int lifetimeCallSeconds;

  /// When the current Premium period ends. Null on free tier.
  final DateTime? proExpiresAt;

  /// Last time this user's app was foregrounded (presence heartbeat).
  /// Null when unknown. Whether it is surfaced as "online" is gated by
  /// [hideOnlineStatus] on the client.
  final DateTime? lastSeen;

  /// Backwards-compat shim — the rest of the UI still reads `firstName` /
  /// `sourceLang`. Same data, different schema names.
  String get firstName => displayName;
  String get sourceLang => language;

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    final s = v.toString();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s)?.toLocal();
  }

  static int _parseInt(dynamic v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  factory RemoteProfile.fromMap(Map<String, dynamic> m) => RemoteProfile(
        id: m['id']?.toString() ?? '',
        handle: m['handle']?.toString() ?? '',
        displayName: m['display_name']?.toString() ?? '',
        language: m['language']?.toString() ?? '',
        avatarColor: m['avatar_color']?.toString() ?? '',
        avatarUrl: m['avatar_url']?.toString() ?? '',
        discoverPhotoUrl: m['discover_photo_url']?.toString() ?? '',
        bio: m['bio']?.toString() ?? '',
        gender: () {
          final g = m['gender']?.toString().trim() ?? '';
          return (g == 'm' || g == 'f' || g == 'x') ? g : '';
        }(),
        hideOnlineStatus: m['hide_online_status'] == true,
        isPro: m['is_pro'] == true,
        subscriptionTier: () {
          final t = m['subscription_tier']?.toString().trim().toLowerCase() ?? '';
          // Soft-migrate any rows that still carry the old 'pro' /
          // 'ultra' values (in case the DB migration lags the deploy)
          // so the UI doesn't crash on a stale row.
          if (t == 'pro' || t == 'ultra') return 'ultra_plus';
          return (t == 'plus' || t == 'ultra_plus') ? t : 'free';
        }(),
        elevenlabsVoiceId: m['elevenlabs_voice_id']?.toString().trim() ?? '',
        creditsSeconds:
            _parseInt(m['credits_seconds'], freeWeeklyCreditsSeconds),
        creditsResetAt: _parseDate(m['credits_reset_at']),
        lifetimeCallSeconds: _parseInt(m['lifetime_call_seconds'], 0),
        proExpiresAt: _parseDate(m['pro_expires_at']),
        lastSeen: _parseDate(m['last_seen']),
      );
}

/// Maximum number of characters allowed in a profile bio. Enforced on the
/// client; the DB column should also have a `length(bio) <= 80` check.
const int profileBioMaxLength = 80;

/// Supabase `profiles` table. Mirror of the local UserPrefs profile so that
/// other users can discover each other by display name.
/// Result of the most recent [ProfileApi.upsertMyProfile] call. Surfaced in
/// the Profile screen so users can see whether their row actually reached
/// Supabase, and what the failure was if it did not.
class ProfileSyncStatus {
  ProfileSyncStatus({
    required this.attemptedAt,
    required this.ok,
    this.error,
  });
  final DateTime attemptedAt;
  final bool ok;
  final String? error;
}

abstract final class ProfileApi {
  static SupabaseClient get _c => Supabase.instance.client;

  /// Most recent upsert outcome — null before the first attempt.
  static ProfileSyncStatus? lastSync;

  /// Build a deterministic handle from the user's display name + device id
  /// so it stays stable across edits but is unique per install.
  static String _deriveHandle(String displayName, String deviceId) {
    final sanitized = displayName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '')
        .substring(0, displayName.length.clamp(0, 24));
    final suffix = deviceId.replaceAll('-', '').substring(0, 6);
    final base = sanitized.isEmpty ? 'user' : sanitized;
    return '$base-$suffix';
  }

  /// Deterministic accent color for the avatar circle when there is no
  /// uploaded photo. Returns a 7-char `#RRGGBB`.
  static String _deriveAvatarColor(String seed) {
    const palette = <String>[
      '#00A884', '#128C7E', '#075E54', '#34B7F1', '#1F6FEB',
      '#7B61FF', '#A855F7', '#EC4899', '#F97316', '#EAB308',
      '#22C55E', '#14B8A6',
    ];
    if (seed.isEmpty) return palette[0];
    var hash = 0;
    for (final c in seed.codeUnits) {
      hash = (hash * 31 + c) & 0x7fffffff;
    }
    return palette[hash % palette.length];
  }

  /// Write-through: insert or update my profile row keyed by [deviceId].
  /// Safe to call repeatedly — uses upsert on the primary key. Records the
  /// outcome in [lastSync] so the Profile screen can surface failures.
  static Future<void> upsertMyProfile({
    required String deviceId,
    required String displayName,
    required String language,
    String gender = '',
  }) async {
    final now = DateTime.now();
    if (!isSupabaseReady) {
      lastSync = ProfileSyncStatus(
        attemptedAt: now,
        ok: false,
        error: 'Supabase client not initialized (missing SUPABASE_URL / '
            'SUPABASE_PUBLISHABLE_KEY at build time).',
      );
      debugPrint('ProfileApi.upsertMyProfile: Supabase not ready, skipping');
      return;
    }
    if (deviceId.isEmpty || displayName.isEmpty) {
      lastSync = ProfileSyncStatus(
        attemptedAt: now,
        ok: false,
        error: 'Empty deviceId or displayName.',
      );
      return;
    }
    try {
      final row = <String, dynamic>{
        'id': deviceId,
        'handle': _deriveHandle(displayName, deviceId),
        'display_name': displayName,
        'language': language,
        'avatar_color': _deriveAvatarColor(displayName + deviceId),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      // Only write `gender` when explicitly provided so re-running the
      // upsert (e.g. on a language change) can't clobber a value picked
      // earlier in onboarding with an empty string.
      final g = gender.trim();
      if (g == 'm' || g == 'f' || g == 'x') {
        row['gender'] = g;
      }
      await _c.from('profiles').upsert(row, onConflict: 'id');
      lastSync = ProfileSyncStatus(attemptedAt: now, ok: true);
    } catch (e) {
      lastSync = ProfileSyncStatus(
        attemptedAt: now,
        ok: false,
        error: e.toString(),
      );
      debugPrint('ProfileApi.upsertMyProfile failed: $e');
    }
  }

  /// Upload [bytes] as the user's avatar to Supabase Storage and write the
  /// resulting public URL back into `profiles.avatar_url`. Throws on failure
  /// so the caller can surface the real error (bucket missing, RLS, etc.).
  static Future<String> uploadAvatar({
    required String deviceId,
    required Uint8List bytes,
    String contentType = 'image/jpeg',
  }) async {
    if (!isSupabaseReady) {
      throw StateError('Supabase non configuré');
    }
    if (deviceId.isEmpty) throw ArgumentError('deviceId vide');
    if (bytes.isEmpty) throw ArgumentError('image vide');

    final ext = contentType.endsWith('png') ? 'png' : 'jpg';
    final path = '$deviceId.$ext';
    await _c.storage.from('avatars').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            upsert: true,
            contentType: contentType,
            cacheControl: '3600',
          ),
        );
    final baseUrl = _c.storage.from('avatars').getPublicUrl(path);
    final urlWithBuster =
        '$baseUrl?v=${DateTime.now().millisecondsSinceEpoch}';
    await _c.from('profiles').update({
      'avatar_url': urlWithBuster,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', deviceId);
    return urlWithBuster;
  }

  /// Upload [bytes] as the user's Discover-card photo. Same `avatars` bucket
  /// as the avatar (RLS already configured) but stored under a `discover/`
  /// prefix so the two photos can have different sizes / aspect ratios
  /// without colliding. Returns the cache-busted public URL.
  static Future<String> uploadDiscoverPhoto({
    required String deviceId,
    required Uint8List bytes,
    String contentType = 'image/jpeg',
  }) async {
    if (!isSupabaseReady) {
      throw StateError('Supabase non configuré');
    }
    if (deviceId.isEmpty) throw ArgumentError('deviceId vide');
    if (bytes.isEmpty) throw ArgumentError('image vide');

    final ext = contentType.endsWith('png') ? 'png' : 'jpg';
    final path = 'discover/$deviceId.$ext';
    await _c.storage.from('avatars').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            upsert: true,
            contentType: contentType,
            cacheControl: '3600',
          ),
        );
    final baseUrl = _c.storage.from('avatars').getPublicUrl(path);
    final urlWithBuster =
        '$baseUrl?v=${DateTime.now().millisecondsSinceEpoch}';
    await _c.from('profiles').update({
      'discover_photo_url': urlWithBuster,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', deviceId);
    return urlWithBuster;
  }

  /// Case-insensitive substring search by display name. Excludes my own profile.
  static Future<List<RemoteProfile>> searchByFirstName({
    required String query,
    required String myDeviceId,
    int limit = 30,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final rows = await _c
        .from('profiles')
        .select()
        .ilike('display_name', '%$q%')
        .neq('id', myDeviceId)
        .order('display_name', ascending: true)
        .limit(limit);
    return (rows as List)
        .map((r) => RemoteProfile.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList(growable: false);
  }

  /// Bulk fetch by ids (used to resolve friendship rows into people).
  static Future<List<RemoteProfile>> fetchByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final rows = await _c.from('profiles').select().inFilter('id', ids);
    return (rows as List)
        .map((r) => RemoteProfile.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList(growable: false);
  }

  /// Fetch a single profile by id, or null if no row exists. Also applies the
  /// weekly credit-refill check so the rest of the app doesn't have to.
  static Future<RemoteProfile?> fetchById(String id) async {
    if (!isSupabaseReady || id.isEmpty) return null;
    final row = await _c.from('profiles').select().eq('id', id).maybeSingle();
    if (row == null) return null;
    final p = RemoteProfile.fromMap(Map<String, dynamic>.from(row));
    final refilled = await _maybeRefillCredits(p);
    return refilled ?? p;
  }

  /// If [p.creditsResetAt] is in the past, top credits back up to the tier's
  /// weekly allotment and push a new reset date 7 days out. Returns the
  /// updated profile, or null if no refill was needed.
  static Future<RemoteProfile?> _maybeRefillCredits(RemoteProfile p) async {
    final resetAt = p.creditsResetAt;
    if (resetAt == null) return null;
    if (DateTime.now().isBefore(resetAt)) return null;
    final allotment =
        p.isPro ? proWeeklyCreditsSeconds : freeWeeklyCreditsSeconds;
    final nextReset = DateTime.now().toUtc().add(creditsRefillPeriod);
    try {
      await _c.from('profiles').update({
        'credits_seconds': allotment,
        'credits_reset_at': nextReset.toIso8601String(),
      }).eq('id', p.id);
    } catch (e) {
      debugPrint('ProfileApi._maybeRefillCredits failed: $e');
      return null;
    }
    return RemoteProfile(
      id: p.id,
      handle: p.handle,
      displayName: p.displayName,
      language: p.language,
      avatarColor: p.avatarColor,
      avatarUrl: p.avatarUrl,
      discoverPhotoUrl: p.discoverPhotoUrl,
      bio: p.bio,
      hideOnlineStatus: p.hideOnlineStatus,
      isPro: p.isPro,
      creditsSeconds: allotment,
      creditsResetAt: nextReset.toLocal(),
      lifetimeCallSeconds: p.lifetimeCallSeconds,
      proExpiresAt: p.proExpiresAt,
    );
  }

  /// Decrement `credits_seconds` by [seconds] and bump `lifetime_call_seconds`
  /// by the same amount. Both clamp at sensible bounds. Returns the new
  /// credits balance, or null on failure.
  ///
  /// Note: this is a client-side decrement. A determined user could spoof it
  /// by editing the request. That's fine for the v1 honor-system; if it
  /// becomes an issue we'll move it behind a Postgres function with
  /// `SECURITY DEFINER` so the decrement is atomic + tamper-proof.
  static Future<int?> consumeCredits({
    required String userId,
    required int seconds,
  }) async {
    if (!isSupabaseReady || userId.isEmpty || seconds <= 0) return null;
    try {
      // Read-modify-write. Two round-trips but keeps the logic readable.
      final row = await _c
          .from('profiles')
          .select('credits_seconds, lifetime_call_seconds')
          .eq('id', userId)
          .maybeSingle();
      if (row == null) return null;
      final current = RemoteProfile._parseInt(row['credits_seconds'], 0);
      final lifetime =
          RemoteProfile._parseInt(row['lifetime_call_seconds'], 0);
      final next = (current - seconds).clamp(0, 1 << 31);
      await _c.from('profiles').update({
        'credits_seconds': next,
        'lifetime_call_seconds': lifetime + seconds,
      }).eq('id', userId);
      return next;
    } catch (e) {
      debugPrint('ProfileApi.consumeCredits failed: $e');
      return null;
    }
  }

  /// Persist the user's short tagline. Trims to [profileBioMaxLength] so a
  /// client without the right TextField max can't push an oversize string.
  /// Returns the saved value (the trimmed input) for optimistic updates.
  static Future<String?> updateMyBio({
    required String userId,
    required String bio,
  }) async {
    if (!isSupabaseReady || userId.isEmpty) return null;
    final trimmed = bio.length > profileBioMaxLength
        ? bio.substring(0, profileBioMaxLength)
        : bio;
    try {
      await _c.from('profiles').update({
        'bio': trimmed,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', userId);
      return trimmed;
    } catch (e) {
      debugPrint('ProfileApi.updateMyBio failed: $e');
      return null;
    }
  }

  /// Toggle the privacy bit that hides this user's online presence from
  /// other clients. Returns true on success so the caller can keep the
  /// optimistic UI in sync if the request failed.
  static Future<bool> updateHideOnlineStatus({
    required String userId,
    required bool hide,
  }) async {
    if (!isSupabaseReady || userId.isEmpty) return false;
    try {
      await _c.from('profiles').update({
        'hide_online_status': hide,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', userId);
      return true;
    } catch (e) {
      debugPrint('ProfileApi.updateHideOnlineStatus failed: $e');
      return false;
    }
  }

  /// Presence heartbeat — bump the caller's `last_seen` to now. Other
  /// clients read it to show an online indicator (gated by
  /// `hide_online_status`). Best-effort: a missing `last_seen` column
  /// (migration 0018 not applied yet) just no-ops via the catch.
  static Future<void> touchLastSeen(String userId) async {
    if (!isSupabaseReady || userId.isEmpty) return;
    try {
      await _c.from('profiles').update({
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', userId);
    } catch (e) {
      debugPrint('ProfileApi.touchLastSeen failed: $e');
    }
  }

  /// Drop the user's Discover photo: clear the column on profiles, wipe
  /// every "like" row pointing at this user (the likes were earned on
  /// the photo that's now gone), AND remove both common file extensions
  /// from storage so a re-upload of the opposite extension doesn't leave
  /// the old one orphaned. Storage cleanup failures are swallowed —
  /// they're at worst a few KB of orphan files.
  static Future<void> deleteMyDiscoverPhoto(String userId) async {
    if (!isSupabaseReady || userId.isEmpty) return;
    try {
      await _c.from('profiles').update({
        'discover_photo_url': '',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', userId);
    } catch (e) {
      debugPrint('ProfileApi.deleteMyDiscoverPhoto: DB update failed: $e');
      rethrow;
    }
    // Wipe likes received: they were given for a photo that no longer
    // exists. Counter on the profile resets to 0 immediately.
    try {
      await _c.from('likes').delete().eq('liked', userId);
    } catch (e) {
      debugPrint(
          'ProfileApi.deleteMyDiscoverPhoto: likes cleanup failed: $e');
    }
    try {
      await _c.storage.from('avatars').remove([
        'discover/$userId.jpg',
        'discover/$userId.png',
      ]);
    } catch (e) {
      debugPrint('ProfileApi.deleteMyDiscoverPhoto: storage cleanup failed: $e');
    }
  }

  /// People to surface on the Discover stack. Excludes the caller and
  /// anyone the caller has blocked / who has blocked the caller, AND
  /// anyone who hasn't uploaded a Discover photo yet (no card to show).
  /// Friends are still included — the user explicitly wants to keep
  /// seeing them in Discover. Sorted most-recently-updated first.
  static Future<List<RemoteProfile>> fetchDiscoverFeed({
    required String myId,
    int limit = 50,
  }) async {
    if (!isSupabaseReady || myId.isEmpty) return const [];
    try {
      final rows = await _c
          .from('profiles')
          .select()
          .neq('id', myId)
          .neq('discover_photo_url', '')
          .order('updated_at', ascending: false)
          .limit(limit);
      final candidates = (rows as List)
          .map((r) => RemoteProfile.fromMap(Map<String, dynamic>.from(r as Map)))
          .toList(growable: false);
      if (candidates.isEmpty) return const [];

      final excluded = <String>{};
      try {
        final blocks = await _c
            .from('blocked_users')
            .select('blocker, blocked')
            .or('blocker.eq.$myId,blocked.eq.$myId');
        for (final row in (blocks as List)) {
          final m = Map<String, dynamic>.from(row as Map);
          final blocker = m['blocker']?.toString() ?? '';
          final blocked = m['blocked']?.toString() ?? '';
          if (blocker == myId && blocked.isNotEmpty) excluded.add(blocked);
          if (blocked == myId && blocker.isNotEmpty) excluded.add(blocker);
        }
      } catch (_) {}

      return candidates
          .where((p) => !excluded.contains(p.id))
          .toList(growable: false);
    } catch (e) {
      debugPrint('ProfileApi.fetchDiscoverFeed failed: $e');
      return const [];
    }
  }

  /// Permanently remove the caller's profile row and any friendships they
  /// participate in. The Supabase auth.users record is **not** deleted —
  /// that requires a server-side admin call. Calling code should sign the
  /// user out right after; the next sign-in will route them through
  /// onboarding because their profile row is gone.
  static Future<void> deleteMyProfile(String userId) async {
    if (!isSupabaseReady || userId.isEmpty) return;
    try {
      await _c
          .from('friendships')
          .delete()
          .or('requester.eq.$userId,addressee.eq.$userId');
    } catch (e) {
      debugPrint('ProfileApi.deleteMyProfile: friendships cleanup failed: $e');
    }
    await _c.from('profiles').delete().eq('id', userId);
  }

}
