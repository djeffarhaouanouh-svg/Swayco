# syntax=docker/dockerfile:1
# --- Flutter Web (release) ---
FROM ghcr.io/cirruslabs/flutter:stable AS flutter-build

# Build-time args. Accept either the Next.js-style names or the plain
# Flutter-side names — Railway only forwards a service variable as a build
# arg when the ARG name matches, so declaring both lets the same Dockerfile
# work regardless of how the variables are named in the Railway dashboard.
ARG NEXT_PUBLIC_SUPABASE_URL=""
ARG NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=""
ARG SUPABASE_URL=""
ARG SUPABASE_PUBLISHABLE_KEY=""

WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
# pubspec.yaml carries `path:` overrides for the patched sherpa_onnx iOS/macOS
# plugins. `pub get` resolves them even for a web build, so the directories have
# to be present or it fails with "could not find package sherpa_onnx_ios".
COPY native ./native
RUN flutter pub get

COPY analysis_options.yaml ./
COPY lib ./lib
COPY web ./web
COPY assets ./assets

# Pick whichever set the user has defined in Railway, preferring the plain
# SUPABASE_* names. Fail loudly if both are empty so the build doesn't
# silently produce an unconfigured bundle.
RUN flutter config --no-analytics \
  && URL="${SUPABASE_URL:-${NEXT_PUBLIC_SUPABASE_URL}}" \
  && KEY="${SUPABASE_PUBLISHABLE_KEY:-${NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY}}" \
  && if [ -z "$URL" ] || [ -z "$KEY" ]; then \
       echo "ERROR: SUPABASE_URL/SUPABASE_PUBLISHABLE_KEY (or their NEXT_PUBLIC_* aliases) must be set as Railway service variables and forwarded as build args." >&2; \
       exit 1; \
     fi \
  && flutter build web --release \
       --dart-define=TOKEN_API_BASE= \
       --dart-define=SUPABASE_URL="$URL" \
       --dart-define=SUPABASE_PUBLISHABLE_KEY="$KEY"

# --- Node: API + static web ---
FROM node:22-alpine AS runtime

WORKDIR /app
ENV NODE_ENV=production

COPY backend/package.json backend/package-lock.json ./
RUN npm ci --omit=dev

COPY backend/server.js ./server.js
COPY backend/notify.js ./notify.js
COPY backend/apns_voip.js ./apns_voip.js
COPY backend/stripe.js ./stripe.js
COPY backend/analytics.js ./analytics.js
COPY backend/tiers.js ./tiers.js
# Online "X en ligne" broadcast tables — required by server.js (require('./nationalities')).
COPY backend/nationalities.js ./nationalities.js
# Re-engagement emails — required by notify.js (require('./email')).
COPY backend/email.js ./email.js
COPY --from=flutter-build /app/build/web ./web
# Static legal site (Terms / Privacy / Help) — served by server.js at
# /terms, /privacy, /help, /legal alongside the Flutter web bundle.
COPY legal-site ./legal-site

EXPOSE 8080
ENV PORT=8080

CMD ["node", "server.js"]
