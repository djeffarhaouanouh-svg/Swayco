import type { Metadata } from "next";
import {
  Didact_Gothic,
  IBM_Plex_Mono,
  Plus_Jakarta_Sans,
  Unbounded,
} from "next/font/google";
import "./globals.css";

// Polices de l'admin (direction 1c) :
// Unbounded = titres et gros chiffres, Plus Jakarta Sans = tout le reste,
// Didact Gothic = logo « swaycø », IBM Plex Mono = identifiants / sens de langue.
const unbounded = Unbounded({
  subsets: ["latin"],
  weight: ["600", "700"],
  variable: "--font-unbounded",
  display: "swap",
});
const jakarta = Plus_Jakarta_Sans({
  subsets: ["latin"],
  weight: ["500", "600", "700", "800"],
  variable: "--font-jakarta",
  display: "swap",
});
const didact = Didact_Gothic({
  subsets: ["latin"],
  weight: "400",
  variable: "--font-didact",
  display: "swap",
});
const plex = IBM_Plex_Mono({
  subsets: ["latin"],
  weight: ["500"],
  variable: "--font-plex",
  display: "swap",
});

export const metadata: Metadata = {
  title: "swaycø — Admin",
  description: "Tableau de bord administrateur Swayco",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html
      lang="fr"
      className={`${unbounded.variable} ${jakarta.variable} ${didact.variable} ${plex.variable} h-full`}
    >
      {/* La classe sc-mesh (fond sombre à halos) n'existe plus. */}
      <body className="min-h-full">{children}</body>
    </html>
  );
}
