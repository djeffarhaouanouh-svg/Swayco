import type { NextConfig } from "next";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const nextConfig: NextConfig = {
  // This app lives inside the Swayco monorepo, which has its own
  // lockfile one level up. Pin the Turbopack root to admin/ so it does
  // not infer the parent directory.
  turbopack: {
    root: dirname(fileURLToPath(import.meta.url)),
  },
  // Page « Audios » : un vocal envoyé à la main peut peser quelques Mo (la
  // limite par défaut est de 1 Mo). Le bucket plafonne de toute façon à 5 Mo.
  experimental: {
    serverActions: { bodySizeLimit: "6mb" },
  },
};

export default nextConfig;
