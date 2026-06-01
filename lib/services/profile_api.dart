import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Translation credits. UI-side we expose these as "crédits" where
/// 1 crédit = 60 s of translated call, so the per-tier numbers read
/// abstract and generous instead of stopwatch-y. Source of truth for
/// the matching per-tier values lives in `backend/tiers.js` (FEATURES);
/// these constants exist so the local UI can pre-render a refill
/// without waiting on the network.
///
/// Free is refilled every 7 days ([freeRefillPeriod]); paid tiers
/// every 30 days ([paidRefillPeriod]) to match Stripe's monthly
/// invoice.
const int freeWeeklyCreditsSeconds = 15 * 60; // 15 crédits / semaine
const int plusMonthlyCreditsSeconds = 180 * 60; // 180 crédits / mois (3 h)
const int ultraPlusMonthlyCreditsSeconds = 360 * 60; // 360 crédits / mois (6 h)

/// Legacy alias kept so older call sites that still read this name
/// keep compiling during the rename. New code should use
/// `ultraPlusMonthlyCreditsSeconds` directly.
const int proWeeklyCreditsSeconds = ultraPlusMonthlyCreditsSeconds;

/// Refill cadence per tier. Free rolls over weekly; paid tiers roll
/// over every 30 days to land on the same date as Stripe's monthly
/// invoice ("refill" and "new bill" feel like the same event).
const Duration freeRefillPeriod = Duration(days: 7);
const Duration paidRefillPeriod = Duration(days: 30);

class RemoteProfile {
  const RemoteProfile({
    required this.id,
    required this.handle,
    required this.displayName,
    required this.language,
    required this.avatarColor,
    required this.avatarUrl,
    this.discoverPhotoUrl = '',
    this.photos = const [],
    this.bio = '',
    this.emojis = const [],
    this.interests = const [],
    this.country = '',
    this.city = '',
    this.gender = '',
    this.hideOnlineStatus = false,
    this.hideFromCountry = false,
    this.isPro = false,
    this.subscriptionTier = 'free',
    this.elevenlabsVoiceId = '',
    this.creditsSeconds = freeWeeklyCreditsSeconds,
    this.creditsResetAt,
    this.lifetimeCallSeconds = 0,
    this.proExpiresAt,
    this.lastSeen,
    this.referralCode = '',
  });

  final String id;
  final String handle;
  final String displayName;
  final String language;
  final String avatarColor;
  final String avatarUrl;

  /// Public URL of the larger photo shown when this profile appears in
  /// someone else's Discover card stack. Optional — empty falls back to
  /// [avatarUrl] (or the placeholder beyond that). Mirror of [photos]`[0]`.
  final String discoverPhotoUrl;

  /// Ordered photo gallery shown in the "Tes photos" section. Each element is
  /// a public URL. `photos[0]` drives the Discover-card photo
  /// ([discoverPhotoUrl], kept in sync by [ProfileApi.addProfilePhoto] /
  /// [removeProfilePhoto]). The PDP / [avatarUrl] is now independent — set
  /// separately via [ProfileApi.uploadAvatar].
  final List<String> photos;

  /// Free-form short tagline shown on the user's own profile and on their
  /// Discover card. Capped at [profileBioMaxLength] characters.
  final String bio;

  /// A short, expressive list of emojis the user picks to decorate their
  /// profile (rendered as tiles in the "Emojis" section). Each element is
  /// one grapheme/emoji; capped at [profileEmojisMax] client-side.
  ///
  /// Legacy: superseded by [interests] in the UI; kept for back-compat.
  final List<String> emojis;

  /// Predefined "centres d'intérêt" tags the user picked (e.g. "K-pop",
  /// "Football"), rendered as colour-coded chips in the "Centres d'intérêt"
  /// section. Capped at [profileInterestsMax] client-side.
  final List<String> interests;

  /// Free-text country + city entered in the profile editor (e.g. "France" /
  /// "Paris"). Shown together in small text under the name on the Discover
  /// card. Either may be empty.
  final String country;
  final String city;

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

  /// When true, this profile is hidden from the Discover feed for
  /// users whose [language] matches theirs (used as a country proxy
  /// because the schema has no `country` column). Client-side filter
  /// + server column for defense-in-depth.
  final bool hideFromCountry;

  /// Subscription state. `true` while the user has an active Premium
  /// entitlement (validated against the store IAP receipt server-side, later).
  final bool isPro;

  /// Raw tier string: `'free' | 'plus' | 'pro' | 'ultra'`. Used by the
  /// chat UI to decide whether to expose the `/voice/dub` CTA (Plus+)
  /// or the live-call upgrade nudge. The backend re-validates the tier
  /// on every paid endpoint — this field only drives client-side hints.
  final String subscriptionTier;

  bool get isPlus =>
      subscriptionTier == 'plus' || subscriptionTier == 'ultra_plus';

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
  /// allotment ([proWeeklyCreditsSeconds] / [freeWeeklyCreditsSeconds]).
  final DateTime? creditsResetAt;

  /// Lifetime stat (never reset). Used for "X minutes used" on the profile.
  final int lifetimeCallSeconds;

  /// When the current Premium period ends. Null on free tier.
  final DateTime? proExpiresAt;

  /// Last time this user's app was foregrounded (presence heartbeat).
  /// Null when unknown. Whether it is surfaced as "online" is gated by
  /// [hideOnlineStatus] on the client.
  final DateTime? lastSeen;

  /// Short URL-safe slug appended to share links as `?ref=<code>` so a
  /// new sign-up can be attributed back to whoever sent the invite.
  /// Server-assigned at profile insert (see migration 0028); empty
  /// only on legacy rows that haven't been fetched since the backfill.
  final String referralCode;

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
    photos: () {
      final raw = m['photos'];
      if (raw is List) {
        return raw
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      }
      return const <String>[];
    }(),
    bio: m['bio']?.toString() ?? '',
    emojis: () {
      final raw = m['emojis'];
      if (raw is List) {
        return raw
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      }
      return const <String>[];
    }(),
    interests: () {
      final raw = m['interests'];
      if (raw is List) {
        return raw
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      }
      return const <String>[];
    }(),
    country: m['country']?.toString() ?? '',
    city: m['city']?.toString() ?? '',
    gender: () {
      final g = m['gender']?.toString().trim() ?? '';
      return (g == 'm' || g == 'f' || g == 'x') ? g : '';
    }(),
    hideOnlineStatus: m['hide_online_status'] == true,
    hideFromCountry: m['hide_from_country'] == true,
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
    creditsSeconds: _parseInt(m['credits_seconds'], freeWeeklyCreditsSeconds),
    creditsResetAt: _parseDate(m['credits_reset_at']),
    lifetimeCallSeconds: _parseInt(m['lifetime_call_seconds'], 0),
    proExpiresAt: _parseDate(m['pro_expires_at']),
    lastSeen: _parseDate(m['last_seen']),
    referralCode: m['referral_code']?.toString() ?? '',
  );

  /// Returns a copy with the given fields overridden. Used by the few call
  /// sites that mutate a single attribute (bio / emojis save, credit refill)
  /// and need a fresh immutable instance without re-listing every field —
  /// which previously dropped attributes like `subscriptionTier` on rebuild.
  RemoteProfile copyWith({
    String? handle,
    String? displayName,
    String? language,
    String? avatarColor,
    String? avatarUrl,
    String? discoverPhotoUrl,
    List<String>? photos,
    String? bio,
    List<String>? emojis,
    List<String>? interests,
    String? country,
    String? city,
    String? gender,
    bool? hideOnlineStatus,
    bool? hideFromCountry,
    bool? isPro,
    String? subscriptionTier,
    String? elevenlabsVoiceId,
    int? creditsSeconds,
    DateTime? creditsResetAt,
    int? lifetimeCallSeconds,
    DateTime? proExpiresAt,
    DateTime? lastSeen,
    String? referralCode,
  }) => RemoteProfile(
    id: id,
    handle: handle ?? this.handle,
    displayName: displayName ?? this.displayName,
    language: language ?? this.language,
    avatarColor: avatarColor ?? this.avatarColor,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    discoverPhotoUrl: discoverPhotoUrl ?? this.discoverPhotoUrl,
    photos: photos ?? this.photos,
    bio: bio ?? this.bio,
    emojis: emojis ?? this.emojis,
    interests: interests ?? this.interests,
    country: country ?? this.country,
    city: city ?? this.city,
    gender: gender ?? this.gender,
    hideOnlineStatus: hideOnlineStatus ?? this.hideOnlineStatus,
    hideFromCountry: hideFromCountry ?? this.hideFromCountry,
    isPro: isPro ?? this.isPro,
    subscriptionTier: subscriptionTier ?? this.subscriptionTier,
    elevenlabsVoiceId: elevenlabsVoiceId ?? this.elevenlabsVoiceId,
    creditsSeconds: creditsSeconds ?? this.creditsSeconds,
    creditsResetAt: creditsResetAt ?? this.creditsResetAt,
    lifetimeCallSeconds: lifetimeCallSeconds ?? this.lifetimeCallSeconds,
    proExpiresAt: proExpiresAt ?? this.proExpiresAt,
    lastSeen: lastSeen ?? this.lastSeen,
    referralCode: referralCode ?? this.referralCode,
  );
}

/// Maximum number of characters allowed in a profile bio. Enforced on the
/// client; the DB column should also have a `length(bio) <= 80` check.
const int profileBioMaxLength = 80;

/// Maximum number of characters allowed in a display name. Matches the
/// clamp applied when deriving the handle in [ProfileApi._deriveHandle].
const int profileNameMaxLength = 24;

/// Maximum number of emojis a user can pin to their profile. Kept small so
/// the "Emojis" section stays a single tidy row across phone widths.
const int profileEmojisMax = 5;

/// Maximum number of photos in a user's gallery ("Tes photos" section).
const int profilePhotosMax = 6;

/// Maximum number of "centres d'intérêt" tags a user can pin to their
/// profile. The full taxonomy of selectable tags lives in `interests.dart`.
const int profileInterestsMax = 4;

/// Supabase `profiles` table. Mirror of the local UserPrefs profile so that
/// other users can discover each other by display name.
/// Result of the most recent [ProfileApi.upsertMyProfile] call. Surfaced in
/// the Profile screen so users can see whether their row actually reached
/// Supabase, and what the failure was if it did not.
class ProfileSyncStatus {
  ProfileSyncStatus({required this.attemptedAt, required this.ok, this.error});
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
      '#00A884',
      '#128C7E',
      '#075E54',
      '#34B7F1',
      '#1F6FEB',
      '#7B61FF',
      '#A855F7',
      '#EC4899',
      '#F97316',
      '#EAB308',
      '#22C55E',
      '#14B8A6',
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
        error:
            'Supabase client not initialized (missing SUPABASE_URL / '
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
    await _c.storage
        .from('avatars')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            upsert: true,
            contentType: contentType,
            cacheControl: '3600',
          ),
        );
    final baseUrl = _c.storage.from('avatars').getPublicUrl(path);
    final urlWithBuster = '$baseUrl?v=${DateTime.now().millisecondsSinceEpoch}';
    await _c
        .from('profiles')
        .update({
          'avatar_url': urlWithBuster,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', deviceId);
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
    await _c.storage
        .from('avatars')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            upsert: true,
            contentType: contentType,
            cacheControl: '3600',
          ),
        );
    final baseUrl = _c.storage.from('avatars').getPublicUrl(path);
    final urlWithBuster = '$baseUrl?v=${DateTime.now().millisecondsSinceEpoch}';
    await _c
        .from('profiles')
        .update({
          'discover_photo_url': urlWithBuster,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', deviceId);
    return urlWithBuster;
  }

  /// Append [bytes] as a new photo in the user's gallery ("Tes photos").
  /// Each upload gets a unique storage path so the gallery can hold several
  /// distinct files. `photos[0]` still drives the Discover-card photo
  /// (`discover_photo_url`), but the PDP / avatar is independent now — set
  /// separately via [uploadAvatar] — so this never touches `avatar_url`.
  ///
  /// [current] is the gallery as the client currently knows it; the new URL
  /// is appended (capped at [profilePhotosMax]) and the full new list is
  /// persisted and returned for an optimistic update.
  static Future<List<String>> addProfilePhoto({
    required String deviceId,
    required Uint8List bytes,
    required List<String> current,
    String contentType = 'image/jpeg',
  }) async {
    if (!isSupabaseReady) {
      throw StateError('Supabase non configuré');
    }
    if (deviceId.isEmpty) throw ArgumentError('deviceId vide');
    if (bytes.isEmpty) throw ArgumentError('image vide');
    if (current.length >= profilePhotosMax) {
      throw StateError('Galerie pleine ($profilePhotosMax photos max)');
    }

    final ext = contentType.endsWith('png') ? 'png' : 'jpg';
    // Unique path per photo (timestamp) under a per-user folder so several
    // photos coexist instead of overwriting a single fixed key.
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = 'discover/$deviceId/$stamp.$ext';
    await _c.storage
        .from('avatars')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            upsert: true,
            contentType: contentType,
            cacheControl: '3600',
          ),
        );
    final url = _c.storage.from('avatars').getPublicUrl(path);
    final next = [...current, url].take(profilePhotosMax).toList();
    await _c
        .from('profiles')
        .update({
          'photos': next,
          // The gallery drives the Discover card (photos[0]), but the PDP /
          // avatar is now an independent picture set via [uploadAvatar] — so we
          // no longer touch `avatar_url` here.
          'discover_photo_url': next.first,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', deviceId);
    return next;
  }

  /// Remove [url] from the user's gallery. Re-syncs `discover_photo_url` to
  /// the new `photos[0]` (or empties it when the gallery becomes empty) —
  /// the independent PDP (`avatar_url`) is left untouched — best-effort
  /// deletes the underlying storage object, and, when the gallery is now
  /// empty, drops received likes (earned on a Discover card that no longer
  /// has a photo). Returns the new gallery list.
  static Future<List<String>> removeProfilePhoto({
    required String deviceId,
    required String url,
    required List<String> current,
  }) async {
    if (!isSupabaseReady) {
      throw StateError('Supabase non configuré');
    }
    if (deviceId.isEmpty) throw ArgumentError('deviceId vide');
    final next = current.where((p) => p != url).toList(growable: false);
    // Keep the Discover card in sync with the gallery's first photo; the PDP
    // (avatar_url) is independent now and left untouched.
    final discover = next.isEmpty ? '' : next.first;
    await _c
        .from('profiles')
        .update({
          'photos': next,
          'discover_photo_url': discover,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', deviceId);
    // Best-effort storage cleanup: the public URL is
    // ".../object/public/avatars/<path>" — strip the prefix to recover the
    // storage key. A failure here is at worst a few KB of orphaned bytes.
    try {
      final marker = '/avatars/';
      final i = url.indexOf(marker);
      if (i != -1) {
        final key = url.substring(i + marker.length).split('?').first;
        await _c.storage.from('avatars').remove([key]);
      }
    } catch (e) {
      debugPrint('ProfileApi.removeProfilePhoto: storage cleanup failed: $e');
    }
    if (next.isEmpty) {
      try {
        await _c.from('likes').delete().eq('liked', deviceId);
      } catch (e) {
        debugPrint('ProfileApi.removeProfilePhoto: likes cleanup failed: $e');
      }
    }
    return next;
  }

  /// Case-insensitive substring search across display name AND handle.
  /// Excludes my own profile.
  ///
  /// "@" prefix narrows the search to handles only — same UX convention
  /// as Twitter / Instagram. Without the prefix, both columns are
  /// matched in a single OR query so the user can type either a real
  /// name or a handle without thinking about which.
  static Future<List<RemoteProfile>> searchProfiles({
    required String query,
    required String myDeviceId,
    int limit = 30,
  }) async {
    var q = query.trim();
    if (q.isEmpty) return const [];
    // `@john` → search handle only; `@` alone is a no-op.
    final handleOnly = q.startsWith('@');
    if (handleOnly) {
      q = q.substring(1).trim();
      if (q.isEmpty) return const [];
    }
    // PostgREST escapes commas inside `or` clause arguments — strip
    // them defensively so a stray comma in user input doesn't blow up
    // the query parser.
    final safe = q.replaceAll(',', ' ');
    final builder = _c.from('profiles').select();
    final filtered = handleOnly
        ? builder.ilike('handle', '%$safe%')
        : builder.or('display_name.ilike.%$safe%,handle.ilike.%$safe%');
    final rows = await filtered
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
    final allotment = switch (p.subscriptionTier) {
      'ultra_plus' => ultraPlusMonthlyCreditsSeconds,
      'plus' => plusMonthlyCreditsSeconds,
      _ => freeWeeklyCreditsSeconds,
    };
    final period = p.isPro ? paidRefillPeriod : freeRefillPeriod;
    final nextReset = DateTime.now().toUtc().add(period);
    try {
      await _c
          .from('profiles')
          .update({
            'credits_seconds': allotment,
            'credits_reset_at': nextReset.toIso8601String(),
          })
          .eq('id', p.id);
    } catch (e) {
      debugPrint('ProfileApi._maybeRefillCredits failed: $e');
      return null;
    }
    return p.copyWith(
      creditsSeconds: allotment,
      creditsResetAt: nextReset.toLocal(),
    );
  }

  /// Tell the server "I was invited by the holder of [code]". Idempotent
  /// — a second call (or a self-referral) is rejected without throwing.
  /// Returns null when the RPC fails entirely; otherwise a parsed
  /// result map: `{ok, reason?, referralsTotal?, bonusAddedSeconds?}`.
  static Future<Map<String, dynamic>?> attributeReferral(String code) async {
    if (!isSupabaseReady) return null;
    final trimmed = code.trim();
    if (trimmed.isEmpty) return null;
    try {
      final res = await _c.rpc(
        'attribute_referral',
        params: {'p_code': trimmed},
      );
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'ok': false, 'reason': 'malformed_response'};
    } catch (e) {
      debugPrint('ProfileApi.attributeReferral failed: $e');
      return null;
    }
  }

  /// Count of users who signed up with [userId] as their referrer.
  /// Used by the invite-friends popup to render "X / 3" progress. Falls
  /// back to 0 on failure rather than throwing — the popup shouldn't
  /// blow up when the network is flaky.
  static Future<int> countReferrals(String userId) async {
    if (!isSupabaseReady || userId.isEmpty) return 0;
    try {
      final rows = await _c
          .from('profiles')
          .select('id')
          .eq('referred_by', userId);
      return rows.length;
    } catch (e) {
      debugPrint('ProfileApi.countReferrals failed: $e');
      return 0;
    }
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
      final lifetime = RemoteProfile._parseInt(row['lifetime_call_seconds'], 0);
      final next = (current - seconds).clamp(0, 1 << 31);
      await _c
          .from('profiles')
          .update({
            'credits_seconds': next,
            'lifetime_call_seconds': lifetime + seconds,
          })
          .eq('id', userId);
      return next;
    } catch (e) {
      debugPrint('ProfileApi.consumeCredits failed: $e');
      return null;
    }
  }

  /// Persist the user's display name (the "prénom"). Trims to
  /// [profileNameMaxLength]; ignores a blank value (a profile must keep a
  /// name). Only `display_name` is written — the `@handle` is a stable,
  /// unique slug and is intentionally left untouched. Returns the saved
  /// value for optimistic updates, or null on failure / empty input.
  static Future<String?> updateMyName({
    required String userId,
    required String name,
  }) async {
    if (!isSupabaseReady || userId.isEmpty) return null;
    var trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.length > profileNameMaxLength) {
      trimmed = trimmed.substring(0, profileNameMaxLength);
    }
    try {
      await _c
          .from('profiles')
          .update({
            'display_name': trimmed,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId);
      return trimmed;
    } catch (e) {
      debugPrint('ProfileApi.updateMyName failed: $e');
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
      await _c
          .from('profiles')
          .update({
            'bio': trimmed,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId);
      return trimmed;
    } catch (e) {
      debugPrint('ProfileApi.updateMyBio failed: $e');
      return null;
    }
  }

  /// Persist the user's chosen profile emojis. Trims blanks and caps at
  /// [profileEmojisMax] so a client without the right limit can't push an
  /// oversize list. Returns the saved list (for optimistic updates), or null
  /// on failure.
  static Future<List<String>?> updateMyEmojis({
    required String userId,
    required List<String> emojis,
  }) async {
    if (!isSupabaseReady || userId.isEmpty) return null;
    final cleaned = emojis
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(profileEmojisMax)
        .toList(growable: false);
    try {
      await _c
          .from('profiles')
          .update({
            'emojis': cleaned,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId);
      return cleaned;
    } catch (e) {
      debugPrint('ProfileApi.updateMyEmojis failed: $e');
      return null;
    }
  }

  /// Persist the user's free-text country + city (profile editor). Trims both;
  /// stores empty strings when blank. Returns true on success.
  static Future<bool> updateMyLocation({
    required String userId,
    required String country,
    required String city,
  }) async {
    if (!isSupabaseReady || userId.isEmpty) return false;
    String cap(String s) => s.trim().length > 60 ? s.trim().substring(0, 60) : s.trim();
    try {
      await _c
          .from('profiles')
          .update({
            'country': cap(country),
            'city': cap(city),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId);
      return true;
    } catch (e) {
      debugPrint('ProfileApi.updateMyLocation failed: $e');
      return false;
    }
  }

  /// Persist the user's chosen "centres d'intérêt". Trims blanks, dedupes and
  /// caps at [profileInterestsMax] so a client without the right limit can't
  /// push an oversize list. Returns the saved list (for optimistic updates),
  /// or null on failure.
  static Future<List<String>?> updateMyInterests({
    required String userId,
    required List<String> interests,
  }) async {
    if (!isSupabaseReady || userId.isEmpty) return null;
    final seen = <String>{};
    final cleaned = <String>[];
    for (final raw in interests) {
      final v = raw.trim();
      if (v.isEmpty || !seen.add(v)) continue;
      cleaned.add(v);
      if (cleaned.length >= profileInterestsMax) break;
    }
    try {
      await _c
          .from('profiles')
          .update({
            'interests': cleaned,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId);
      return cleaned;
    } catch (e) {
      debugPrint('ProfileApi.updateMyInterests failed: $e');
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
      await _c
          .from('profiles')
          .update({
            'hide_online_status': hide,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId);
      return true;
    } catch (e) {
      debugPrint('ProfileApi.updateHideOnlineStatus failed: $e');
      return false;
    }
  }

  /// Persist the "hide me from people who speak my language" toggle.
  /// We use `language` as a country proxy (no dedicated country
  /// column). Discover excludes matching profiles client-side too,
  /// but the server column is the source of truth so the rule stays
  /// honoured if RLS lets others query the row directly.
  static Future<bool> updateHideFromCountry({
    required String userId,
    required bool hide,
  }) async {
    if (!isSupabaseReady || userId.isEmpty) return false;
    try {
      await _c
          .from('profiles')
          .update({
            'hide_from_country': hide,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId);
      return true;
    } catch (e) {
      debugPrint('ProfileApi.updateHideFromCountry failed: $e');
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
      await _c
          .from('profiles')
          .update({'last_seen': DateTime.now().toUtc().toIso8601String()})
          .eq('id', userId);
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
      // The single photo doubles as the avatar (PDP), so clearing it must
      // wipe both columns — otherwise the deleted photo would linger as the
      // user's avatar everywhere else in the app.
      await _c
          .from('profiles')
          .update({
            'discover_photo_url': '',
            'avatar_url': '',
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId);
    } catch (e) {
      debugPrint('ProfileApi.deleteMyDiscoverPhoto: DB update failed: $e');
      rethrow;
    }
    // Wipe likes received: they were given for a photo that no longer
    // exists. Counter on the profile resets to 0 immediately.
    try {
      await _c.from('likes').delete().eq('liked', userId);
    } catch (e) {
      debugPrint('ProfileApi.deleteMyDiscoverPhoto: likes cleanup failed: $e');
    }
    try {
      await _c.storage.from('avatars').remove([
        'discover/$userId.jpg',
        'discover/$userId.png',
      ]);
    } catch (e) {
      debugPrint(
        'ProfileApi.deleteMyDiscoverPhoto: storage cleanup failed: $e',
      );
    }
  }

  /// Random source used by [_scoreDiscoverCandidate] to jitter ties so
  /// the deck doesn't feel deterministic between refreshes.
  static final Random _feedRng = Random();

  /// Score a Discover candidate from the local user's point of view.
  /// Higher is "show me sooner". Components, all additive:
  ///
  /// • Activity recency (gated on the peer not hiding their online
  ///   status). A peer active in the last 5 min beats a week-old one.
  /// • Fetch-order bonus — the DB returns rows pre-sorted by
  ///   `updated_at desc`, so the position in that returned list is a
  ///   free proxy for "recently changed profile".
  /// • Cross-language bonus — Swayco is a translation app, so a peer
  ///   who speaks a different language is more interesting by default.
  /// • Popularity bonus — log-scaled count of received likes so
  ///   already-loved profiles drift to the top of the deck without one
  ///   mega-popular account locking the #1 slot forever.
  /// • Bio bonus — completed profiles look more inviting on a card.
  /// • Random jitter (0..10) so identical scores shuffle gently across
  ///   refreshes.
  ///
  /// Pure function over the candidate + the local user's context —
  /// keeping the ranking client-side means we don't need a custom
  /// Supabase RPC for ordering.
  static double _scoreDiscoverCandidate(
    RemoteProfile p,
    int positionInFetch,
    String myLang,
    int receivedLikes,
  ) {
    double s = 0;

    final ls = p.lastSeen;
    if (ls != null && !p.hideOnlineStatus) {
      final mins = DateTime.now().difference(ls).inMinutes;
      if (mins <= 5) {
        s += 60;
      } else if (mins <= 60) {
        s += 40;
      } else if (mins <= 60 * 24) {
        s += 25;
      } else if (mins <= 60 * 24 * 7) {
        s += 10;
      }
    }

    if (positionInFetch < 10) {
      s += 20;
    } else if (positionInFetch < 25) {
      s += 10;
    }

    final theirLang = p.language.trim().toLowerCase();
    if (myLang.isNotEmpty && theirLang.isNotEmpty && theirLang != myLang) {
      s += 30;
    }

    // Popularity boost: log10(likes + 1) * 18 → caps around +36 for
    // 100+ likes, ~+18 for 10 likes, ~+5 for 1 like, 0 for none. The
    // log scale prevents one viral account from flattening the deck.
    if (receivedLikes > 0) {
      s += log(receivedLikes + 1) / ln10 * 18;
    }

    if (p.bio.trim().isNotEmpty) s += 8;

    s += _feedRng.nextDouble() * 10;
    return s;
  }

  /// People to surface on the Discover stack. Backed by the
  /// `discover_feed` SECURITY DEFINER RPC (migration 0026) which
  /// applies every privacy filter in SQL:
  ///   • caller excluded
  ///   • profiles without a discover photo excluded
  ///   • blocks (both directions) excluded
  ///   • peers with hide_from_country=true AND a matching language
  ///     excluded — opt-out can't be bypassed by a tampered client
  ///     because the rows never leave the database.
  ///
  /// The composite scoring lives client-side: it carries a random
  /// jitter between refreshes and only affects display order, so
  /// keeping it here doesn't weaken any privacy guarantee.
  static Future<List<RemoteProfile>> fetchDiscoverFeed({
    required String myId,
    int limit = 50,
  }) async {
    if (!isSupabaseReady || myId.isEmpty) return const [];
    try {
      final result = await _c.rpc(
        'discover_feed',
        params: {'p_user_id': myId, 'p_limit': limit},
      );
      if (result is! List) return const [];
      final candidates = result
          .map(
            (r) => RemoteProfile.fromMap(Map<String, dynamic>.from(r as Map)),
          )
          .toList(growable: false);
      if (candidates.isEmpty) return const [];

      // Look up my language for the client-side scoring (cross-
      // language bonus). The peer privacy filter that depends on it
      // already ran server-side in the RPC, so we no longer need it
      // for correctness — just for ranking.
      String myLang = '';
      try {
        final me = await fetchById(myId);
        myLang = me?.language.trim().toLowerCase() ?? '';
      } catch (_) {}

      // Batched popularity counts for every candidate in one round-
      // trip via the `received_likes_counts` SECURITY DEFINER RPC
      // (migration 0027). Inlined rather than going through LikeApi
      // because that file imports profile_api and we'd create a
      // circular import. Best-effort: a failure just skips the
      // popularity boost — every candidate is treated as 0 likes.
      Map<String, int> likeCounts = const {};
      try {
        final result = await _c.rpc(
          'received_likes_counts',
          params: {
            'p_ids': candidates
                .map((p) => p.id)
                .where((id) => id.isNotEmpty)
                .toList(),
          },
        );
        if (result is List) {
          final out = <String, int>{};
          for (final row in result) {
            final m = Map<String, dynamic>.from(row as Map);
            final id = m['liked']?.toString() ?? '';
            final n = (m['n'] as num?)?.toInt() ?? 0;
            if (id.isNotEmpty) out[id] = n;
          }
          likeCounts = out;
        }
      } catch (e) {
        debugPrint('ProfileApi.fetchDiscoverFeed: like counts failed: $e');
      }

      // Score each candidate up front so the random jitter in
      // [_scoreDiscoverCandidate] is computed once per row and the
      // sort comparator stays stable.
      final scored = <(RemoteProfile, double)>[
        for (var i = 0; i < candidates.length; i++)
          (
            candidates[i],
            _scoreDiscoverCandidate(
              candidates[i],
              i,
              myLang,
              likeCounts[candidates[i].id] ?? 0,
            ),
          ),
      ];
      scored.sort((a, b) => b.$2.compareTo(a.$2));
      return List<RemoteProfile>.unmodifiable(scored.map((s) => s.$1));
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
