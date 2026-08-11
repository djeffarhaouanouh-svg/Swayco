import type { Metadata } from "next";
import { Bricolage_Grotesque, DM_Sans } from "next/font/google";
import "./globals.css";

// The app's two faces (lib/theme/swayco_theme.dart → SCText):
// Bricolage Grotesque for headings, DM Sans for everything else.
const bricolage = Bricolage_Grotesque({
  subsets: ["latin"],
  variable: "--font-bricolage",
  display: "swap",
});

const dmSans = DM_Sans({
  subsets: ["latin"],
  variable: "--font-dm-sans",
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
      className={`${bricolage.variable} ${dmSans.variable} h-full`}
    >
      <body className="sc-mesh min-h-full">{children}</body>
    </html>
  );
}
