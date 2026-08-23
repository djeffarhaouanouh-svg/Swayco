# syntax=docker/dockerfile:1
# --- Flutter Web (release) ---
FROM ghcr.io/cirruslabs/flutter:stable AS flutter-build

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
COPY dart_defines.env ./dart_defines.env

# Bake client config from dart_defines.env — never Railway ARG + `${VAR:-}`
# inside RUN. That interpolation turns `https://….supabase.co` into
# `https://….supabase.cO` and leaves TOKEN_API_BASE empty.
RUN flutter config --no-analytics \
  && flutter build web --release --dart-define-from-file=dart_defines.env

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
