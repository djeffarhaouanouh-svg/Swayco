"use client";

import { useState, useEffect } from "react";
import Link from "next/link";
import {
  User,
  Mail,
  Calendar,
  Link2,
  Pencil,
  TrendingUp,
  Users,
  Settings,
  LogOut,
  ChevronRight,
} from "lucide-react";

export default function ProfilPage() {
  const [userName, setUserName] = useState<string>("Lenny");
  const [userEmail, setUserEmail] = useState<string>("lennyhdr1@gmail.com");
  const [memberSince, setMemberSince] = useState<string>("13 janvier 2026");
  const [credits, setCredits] = useState<number>(21);
  const [creditsPerMonth, setCreditsPerMonth] = useState<number>(5);
  const [charactersCount, setCharactersCount] = useState<number>(7);

  useEffect(() => {
    if (typeof window === "undefined") return;
    const name = localStorage.getItem("userName") ?? "Utilisateur";
    const email = localStorage.getItem("userEmail") ?? "";
    const since = localStorage.getItem("memberSince") ?? "";
    setUserName(name);
    if (email) setUserEmail(email);
    if (since) setMemberSince(since);
    // TODO: fetch credits et charactersCount depuis l'API
  }, []);

  const handleLogout = () => {
    if (typeof window !== "undefined") {
      localStorage.removeItem("userId");
      localStorage.removeItem("userName");
      localStorage.removeItem("userEmail");
      window.location.href = "/";
    }
  };

  const initial = userName.charAt(0).toUpperCase();

  return (
    <div className="min-h-screen bg-[#0F0F0F] text-white pt-6 pb-10">
      <div className="max-w-2xl mx-auto px-4 md:px-6">
        <h1 className="text-2xl font-bold mb-6">
          Mon <span className="text-[#3BB9FF]">Profil</span>
        </h1>

        {/* Section Identité */}
        <div className="w-full bg-[#1E1E1E] rounded-2xl p-5 md:p-6 border border-[#2A2A2A] mb-4">
          <div className="flex items-start gap-4">
            <div className="w-14 h-14 rounded-full bg-[#3BB9FF] flex items-center justify-center flex-shrink-0">
              <span className="text-xl font-bold text-white">{initial}</span>
            </div>
            <div className="flex-1 min-w-0">
              <div className="flex items-start justify-between gap-2">
                <div>
                  <h2 className="text-lg font-bold text-white">{userName}</h2>
                  <p className="text-sm text-white/80 truncate">{userEmail}</p>
                </div>
                <button
                  type="button"
                  className="w-9 h-9 rounded-lg bg-[#3BB9FF]/20 flex items-center justify-center text-[#3BB9FF] hover:bg-[#3BB9FF]/30 transition-colors flex-shrink-0"
                  aria-label="Modifier le profil"
                >
                  <Pencil className="w-4 h-4" />
                </button>
              </div>
              <div className="mt-5 space-y-4">
                <div>
                  <div className="flex items-center gap-2 text-[#A3A3A3] text-sm mb-1">
                    <User className="w-4 h-4" />
                    <span>Nom de profil</span>
                  </div>
                  <p className="font-semibold text-white">{userName}</p>
                </div>
                <div>
                  <div className="flex items-center gap-2 text-[#A3A3A3] text-sm mb-1">
                    <Mail className="w-4 h-4" />
                    <span>Email</span>
                  </div>
                  <p className="font-semibold text-white truncate">{userEmail}</p>
                </div>
                <div>
                  <div className="flex items-center gap-2 text-[#A3A3A3] text-sm mb-1">
                    <Calendar className="w-4 h-4" />
                    <span>Membre depuis</span>
                  </div>
                  <p className="font-semibold text-white">{memberSince}</p>
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Section Mes Crédits */}
        <div className="w-full bg-[#1E1E1E] rounded-2xl p-5 md:p-6 border border-[#2A2A2A] mb-4">
          <div className="flex items-center justify-between mb-3">
            <div className="flex items-center gap-2">
              <Link2 className="w-4 h-4 text-white" />
              <span className="font-medium text-white">Mes Crédits</span>
            </div>
            <span className="px-3 py-1 rounded-full bg-[#2A2A2A] text-white text-xs font-medium">
              Gratuit
            </span>
          </div>
          <p className="mb-4">
            <span className="text-3xl font-bold text-[#3BB9FF]">{credits}</span>
            <span className="text-white/80 ml-1">/ {creditsPerMonth} par mois</span>
          </p>
          <button
            type="button"
            className="w-full py-3 px-4 bg-[#3BB9FF] rounded-xl text-white font-semibold flex items-center justify-center gap-2 hover:bg-[#2AA3E6] transition-colors"
          >
            <TrendingUp className="w-5 h-5" />
            Passer Premium
          </button>
        </div>

        {/* Personnages */}
        <Link
          href="/personnages"
          className="flex items-center justify-between w-full px-5 py-4 md:px-6 bg-[#1E1E1E] border border-[#2A2A2A] rounded-2xl hover:bg-[#252525] hover:border-[#3BB9FF]/30 transition-colors mb-3"
        >
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-[#2A2A2A] flex items-center justify-center">
              <Users className="w-5 h-5 text-[#3BB9FF]" />
            </div>
            <div className="text-left">
              <p className="font-semibold text-white">Personnages</p>
              <p className="text-sm text-[#A3A3A3]">{charactersCount} créés</p>
            </div>
          </div>
          <ChevronRight className="w-5 h-5 text-[#6B7280]" />
        </Link>

        {/* Paramètres */}
        <button
          type="button"
          className="flex items-center w-full px-5 py-4 md:px-6 bg-[#1E1E1E] border border-[#2A2A2A] rounded-2xl hover:bg-[#252525] hover:border-[#3BB9FF]/30 transition-colors text-left mb-3"
        >
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-[#2A2A2A] flex items-center justify-center">
              <Settings className="w-5 h-5 text-white" />
            </div>
            <p className="font-semibold text-white">Paramètres</p>
          </div>
        </button>

        {/* Déconnexion */}
        <button
          type="button"
          onClick={handleLogout}
          className="flex items-center w-full px-5 py-4 md:px-6 bg-[#1E1E1E] border border-[#2A2A2A] rounded-2xl hover:bg-red-500/10 hover:border-red-500/30 transition-colors text-left"
        >
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-[#2A2A2A] flex items-center justify-center">
              <LogOut className="w-5 h-5 text-red-400" />
            </div>
            <p className="font-semibold text-red-400">Déconnexion</p>
          </div>
        </button>

      </div>

      {/* Footer */}
      <footer className="bg-[#1A1A1A] border-t border-[#2A2A2A] text-white py-8 pb-8 mt-12">
        <div className="max-w-7xl mx-auto px-6">
          <div className="grid grid-cols-1 md:grid-cols-3 gap-8 mb-8">
            <div>
              <h3 className="text-xl font-bold mb-4">
                <span className="text-white">swayco</span><span className="text-[#3BB9FF]">.ai</span>
              </h3>
              <p className="text-[#A3A3A3] text-sm">
                Conversations personnalisées avec vos créatrices préférées, alimentées par l&apos;IA.
              </p>
            </div>
            <div>
              <h4 className="font-semibold mb-4 text-white">Légal</h4>
              <ul className="space-y-2 text-sm">
                <li>
                  <Link href="/mentions-legales" className="text-[#A3A3A3] hover:text-[#3BB9FF] transition-colors">
                    Mentions légales
                  </Link>
                </li>
                <li>
                  <Link href="/cgv" className="text-[#A3A3A3] hover:text-[#3BB9FF] transition-colors">
                    CGV
                  </Link>
                </li>
                <li>
                  <Link href="/confidentialite" className="text-[#A3A3A3] hover:text-[#3BB9FF] transition-colors">
                    Confidentialité
                  </Link>
                </li>
                <li>
                  <Link href="/cookies" className="text-[#A3A3A3] hover:text-[#3BB9FF] transition-colors">
                    Cookies
                  </Link>
                </li>
              </ul>
            </div>
            <div>
              <h4 className="font-semibold mb-4 text-white">Support</h4>
              <ul className="space-y-2 text-sm">
                <li>
                  <Link href="/faq" className="text-[#A3A3A3] hover:text-[#3BB9FF] transition-colors">
                    FAQ
                  </Link>
                </li>
                <li>
                  <Link href="/contact" className="text-[#A3A3A3] hover:text-[#3BB9FF] transition-colors">
                    Contact
                  </Link>
                </li>
              </ul>
            </div>
          </div>
          <div className="border-t border-[#2A2A2A] pt-6 text-center text-sm text-[#A3A3A3]">
            <p>&copy; {new Date().getFullYear()} MyDouble. Tous droits réservés.</p>
          </div>
        </div>
      </footer>
    </div>
  );
}
