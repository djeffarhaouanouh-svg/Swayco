"use client";

import { useState, useEffect, useCallback } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import {
  User,
  Mail,
  Calendar,
  Pencil,
  Users,
  Settings,
  LogOut,
  ChevronRight,
  ChevronDown,
  X,
  Bookmark,
  MapPin,
  MessageCircle,
  Plus,
} from "lucide-react";
import { getSavedCharactersData } from "@/lib/savedCharacters";

type ProfileData = {
  id: string;
  name: string;
  email: string;
  memberSince: string;
  credits: number;
  creditsPerMonth: number;
  charactersCount: number;
  plan: string;
};

type SavedCharacter = {
  id: number;
  name: string;
  image: string;
  location: string;
};

type CreatedCharacter = {
  id: number;
  name: string;
  location: string;
  image: string;
  description: string;
  stats: { messages: string };
  badge: string;
};

export default function ProfilPage() {
  const router = useRouter();
  const [userName, setUserName] = useState<string>("Utilisateur");
  const [userEmail, setUserEmail] = useState<string>("");
  const [memberSince, setMemberSince] = useState<string>("");
  const [isEditing, setIsEditing] = useState(false);
  const [editName, setEditName] = useState("");
  const [editEmail, setEditEmail] = useState("");
  const [charactersCount, setCharactersCount] = useState<number>(0);
  const [loading, setLoading] = useState(true);
  const [profileId, setProfileId] = useState<string | null>(null);
  const [savedChars, setSavedChars] = useState<SavedCharacter[]>([]);
  const [savedOpen, setSavedOpen] = useState(false);
  const [createdChars, setCreatedChars] = useState<CreatedCharacter[]>([]);
  const [createdOpen, setCreatedOpen] = useState(false);
  const [createdLoading, setCreatedLoading] = useState(false);

  useEffect(() => {
    const fetchProfile = async () => {
      if (typeof window === "undefined") return;
      const storedEmail = localStorage.getItem("userEmail");
      const storedId = localStorage.getItem("userId");
      const storedName = localStorage.getItem("userName");

      setLoading(true);
      try {
        const params = new URLSearchParams();
        if (storedId) params.set("userId", storedId);
        else if (storedEmail) params.set("email", storedEmail);

        if (params.toString()) {
          const res = await fetch(`/api/profile?${params}`);
          if (res.ok) {
            const data: ProfileData = await res.json();
            setUserName(data.name);
            setUserEmail(data.email);
            setMemberSince(data.memberSince);
            setCharactersCount(data.charactersCount);
            setProfileId(data.id);
            localStorage.setItem("userId", data.id);
            localStorage.setItem("userName", data.name);
            localStorage.setItem("userEmail", data.email);
            if (data.memberSince)
              localStorage.setItem("memberSince", data.memberSince);
            return;
          }
        }
      } catch (err) {
        console.error("Erreur chargement profil:", err);
      }
      setLoading(false);
      if (storedName) setUserName(storedName);
      if (storedEmail) setUserEmail(storedEmail);
    };
    fetchProfile().finally(() => setLoading(false));
  }, []);

  const refreshSavedChars = () => {
    if (typeof window !== "undefined") {
      const data = getSavedCharactersData();
      setSavedChars(
        data.map((c) => ({
          id: c.id,
          name: c.name,
          image: c.image,
          location: c.location,
        }))
      );
    }
  };

  useEffect(() => {
    refreshSavedChars();
  }, []);

  useEffect(() => {
    const onStorage = () => refreshSavedChars();
    window.addEventListener("storage", onStorage);
    return () => window.removeEventListener("storage", onStorage);
  }, []);

  const fetchCreatedChars = useCallback(() => {
    const id = profileId || (typeof window !== "undefined" ? localStorage.getItem("userId") : null);
    if (!id) return;
    setCreatedLoading(true);
    fetch(`/api/characters?creatorId=${encodeURIComponent(id)}`, { cache: "no-store" })
      .then((res) => res.json())
      .then((data) => {
        if (Array.isArray(data)) setCreatedChars(data);
        else if (data?.error) console.error("API characters:", data.error);
      })
      .catch((err) => console.error("Erreur chargement personnages créés:", err))
      .finally(() => setCreatedLoading(false));
  }, [profileId]);

  useEffect(() => {
    fetchCreatedChars();
  }, [fetchCreatedChars]);

  const handleLogout = () => {
    if (typeof window !== "undefined") {
      localStorage.removeItem("userId");
      localStorage.removeItem("userName");
      localStorage.removeItem("userEmail");
      window.location.href = "/";
    }
  };

  const handleOpenEdit = () => {
    setEditName(userName);
    setEditEmail(userEmail);
    setIsEditing(true);
  };

  const handleCloseEdit = () => {
    setIsEditing(false);
  };

  const handleSaveEdit = async (e: React.FormEvent) => {
    e.preventDefault();
    const newName = editName.trim() || userName;
    const newEmail = editEmail.trim() || userEmail;
    if (!newEmail) return;

    try {
      const res = await fetch("/api/profile", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ...(profileId && { id: profileId }),
          email: newEmail,
          name: newName,
        }),
      });
      if (res.ok) {
        const data: ProfileData = await res.json();
        setUserName(data.name);
        setUserEmail(data.email);
        setMemberSince(data.memberSince);
        setCharactersCount(data.charactersCount);
        setProfileId(data.id);
        if (typeof window !== "undefined") {
          localStorage.setItem("userId", data.id);
          localStorage.setItem("userName", data.name);
          localStorage.setItem("userEmail", data.email);
        }
      }
    } catch (err) {
      console.error("Erreur sauvegarde profil:", err);
    }
    setIsEditing(false);
  };

  const initial = userName.charAt(0).toUpperCase();

  return (
    <div className="min-h-screen bg-[#0F0F0F] text-white pt-6 pb-10">
      <div className="max-w-2xl mx-auto px-4 md:px-6">
        <h1 className="text-2xl font-bold mb-6">
          Mon <span className="text-[#3BB9FF]">Profil</span>
        </h1>

        {loading && (
          <div className="flex items-center justify-center py-12 text-[#A3A3A3]">
            <div className="w-8 h-8 border-2 border-[#3BB9FF] border-t-transparent rounded-full animate-spin" />
            <span className="ml-2">Chargement du profil...</span>
          </div>
        )}

        {!loading && (
        <>
        {/* Section Identité */}
        <div className="w-full bg-[#1E1E1E] rounded-2xl p-5 md:p-6 border border-[#2A2A2A] mb-4">
          <div className="relative">
            <button
              type="button"
              onClick={handleOpenEdit}
              className="absolute top-0 right-0 w-9 h-9 rounded-lg bg-[#3BB9FF]/20 flex items-center justify-center text-[#3BB9FF] hover:bg-[#3BB9FF]/30 transition-colors"
              aria-label="Modifier le profil"
            >
              <Pencil className="w-4 h-4" />
            </button>
            <div className="flex flex-col items-start text-left">
              <div className="flex items-center gap-4 mb-5">
                <div className="w-14 h-14 rounded-full bg-[#3BB9FF] flex items-center justify-center flex-shrink-0">
                  <span className="text-xl font-bold text-white">{initial}</span>
                </div>
                <div>
                  <h2 className="text-lg font-bold text-white">{userName}</h2>
                  <p className="text-sm text-white/80 truncate">{userEmail}</p>
                </div>
              </div>
              <div className="space-y-4 w-full">
                <div className="flex flex-col items-start">
                  <div className="flex items-center gap-2 text-[#A3A3A3] text-sm mb-1">
                    <User className="w-4 h-4" />
                    <span>Nom de profil</span>
                  </div>
                  <p className="font-semibold text-white">{userName}</p>
                </div>
                <div className="flex flex-col items-start">
                  <div className="flex items-center gap-2 text-[#A3A3A3] text-sm mb-1">
                    <Mail className="w-4 h-4" />
                    <span>Email</span>
                  </div>
                  <p className="font-semibold text-white truncate">{userEmail}</p>
                </div>
                <div className="flex flex-col items-start">
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

        {/* Modal Modifier le profil */}
        {isEditing && (
          <div
            className="fixed inset-0 z-50 bg-black/80 flex items-center justify-center p-4"
            onClick={handleCloseEdit}
          >
            <div
              className="bg-[#1E1E1E] border border-[#2A2A2A] rounded-2xl p-6 w-full max-w-md"
              onClick={(e) => e.stopPropagation()}
            >
              <div className="flex items-center justify-between mb-6">
                <h3 className="text-lg font-semibold text-white">
                  Modifier le profil
                </h3>
                <button
                  type="button"
                  onClick={handleCloseEdit}
                  className="w-9 h-9 rounded-lg bg-[#2A2A2A] flex items-center justify-center text-[#A3A3A3] hover:text-white transition-colors"
                  aria-label="Fermer"
                >
                  <X className="w-5 h-5" />
                </button>
              </div>
              <form onSubmit={handleSaveEdit} className="space-y-4">
                <div>
                  <label className="block text-sm font-medium text-[#A3A3A3] mb-1.5">
                    Nom de profil
                  </label>
                  <input
                    type="text"
                    value={editName}
                    onChange={(e) => setEditName(e.target.value)}
                    placeholder="Ton prénom"
                    className="w-full px-4 py-3 bg-[#0F0F0F] border border-[#2A2A2A] rounded-xl text-white placeholder:text-[#6B7280] focus:outline-none focus:ring-2 focus:ring-[#3BB9FF] focus:border-transparent"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-[#A3A3A3] mb-1.5">
                    Email
                  </label>
                  <input
                    type="email"
                    value={editEmail}
                    onChange={(e) => setEditEmail(e.target.value)}
                    placeholder="ton@email.com"
                    className="w-full px-4 py-3 bg-[#0F0F0F] border border-[#2A2A2A] rounded-xl text-white placeholder:text-[#6B7280] focus:outline-none focus:ring-2 focus:ring-[#3BB9FF] focus:border-transparent"
                  />
                </div>
                <div className="flex gap-3 pt-2">
                  <button
                    type="button"
                    onClick={handleCloseEdit}
                    className="flex-1 py-3 px-4 rounded-xl bg-[#2A2A2A] text-[#A3A3A3] font-medium hover:bg-[#333] transition-colors"
                  >
                    Annuler
                  </button>
                  <button
                    type="submit"
                    className="flex-1 py-3 px-4 rounded-xl bg-[#3BB9FF] text-white font-medium hover:bg-[#2AA3E6] transition-colors"
                  >
                    Enregistrer
                  </button>
                </div>
              </form>
            </div>
          </div>
        )}

        {/* Personnages enregistrés - menu déroulant */}
        <div className="w-full bg-[#1E1E1E] border border-[#2A2A2A] rounded-2xl overflow-hidden mb-3">
          <button
            type="button"
            onClick={() => setSavedOpen((o) => !o)}
            className="flex items-center justify-between w-full px-5 py-4 md:px-6 hover:bg-[#252525] hover:border-[#3BB9FF]/30 transition-colors text-left"
          >
            <div className="flex items-center gap-3">
              <div className="w-10 h-10 rounded-lg bg-[#2A2A2A] flex items-center justify-center">
                <Bookmark className="w-5 h-5 text-[#FFD700]" fill="#FFD700" />
              </div>
              <div className="text-left">
                <p className="font-semibold text-white">Personnages enregistrés</p>
                <p className="text-sm text-[#A3A3A3]">
                  {savedChars.length} personnage{savedChars.length !== 1 ? "s" : ""} sauvegardé{savedChars.length !== 1 ? "s" : ""}
                </p>
              </div>
            </div>
            <span
              className={`w-9 h-9 flex items-center justify-center text-[#6B7280] transition-transform duration-200 ${savedOpen ? "rotate-0" : "-rotate-90"}`}
            >
              <ChevronDown className="w-5 h-5" />
            </span>
          </button>
          {savedOpen && (
            <div className="px-5 pb-5 md:px-6 pt-0 border-t border-[#2A2A2A]">
              {savedChars.length === 0 ? (
                <div className="flex flex-col gap-3 pt-4">
                  <p className="text-[#A3A3A3] text-sm">
                    Aucun personnage enregistré. Découvre des personnages et clique sur le signet pour les enregistrer.
                  </p>
                  <Link
                    href="/discover"
                    className="inline-flex items-center justify-center gap-2 px-4 py-2 rounded-xl bg-[#3BB9FF]/20 text-[#3BB9FF] text-sm font-medium hover:bg-[#3BB9FF]/30 transition-colors w-fit"
                  >
                    Aller au Discover
                    <ChevronRight className="w-4 h-4" />
                  </Link>
                </div>
              ) : (
                <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 pt-4">
                  {savedChars.map((c) => (
                    <button
                      key={c.id}
                      type="button"
                      onClick={() => router.push(`/chat?characterId=${c.id}`)}
                      className="group flex flex-col items-center p-3 rounded-xl bg-[#0F0F0F] border border-[#2A2A2A] hover:border-[#3BB9FF]/50 hover:bg-[#1A1A1A] transition-colors text-left"
                    >
                      <div className="w-full aspect-[3/4] rounded-lg overflow-hidden mb-2 bg-[#2A2A2A]">
                        <img
                          src={c.image}
                          alt={c.name}
                          className="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
                        />
                      </div>
                      <p className="font-medium text-white text-sm truncate w-full">{c.name}</p>
                      <p className="text-xs text-[#A3A3A3] truncate w-full">{c.location}</p>
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>

        {/* Personnages créés */}
        <div className="w-full bg-[#1E1E1E] border border-[#2A2A2A] rounded-2xl overflow-hidden mb-3">
          <button
            type="button"
            onClick={() => {
              setCreatedOpen((o) => !o);
              if (!createdOpen) fetchCreatedChars();
            }}
            className="flex items-center justify-between w-full px-5 py-4 md:px-6 hover:bg-[#252525] hover:border-[#3BB9FF]/30 transition-colors text-left"
          >
            <div className="flex items-center gap-3">
              <div className="w-10 h-10 rounded-lg bg-[#2A2A2A] flex items-center justify-center">
                <Users className="w-5 h-5 text-[#3BB9FF]" />
              </div>
              <div className="text-left">
                <p className="font-semibold text-white">Personnages</p>
                <p className="text-sm text-[#A3A3A3]">
                  {createdChars.length} créés
                </p>
              </div>
            </div>
            <span
              className={`w-9 h-9 flex items-center justify-center text-[#6B7280] transition-transform duration-200 ${createdOpen ? "rotate-0" : "-rotate-90"}`}
            >
              <ChevronDown className="w-5 h-5" />
            </span>
          </button>
          {createdOpen && (
            <div className="px-5 pb-5 md:px-6 pt-0 border-t border-[#2A2A2A]">
              {createdLoading ? (
                <div className="flex items-center justify-center py-8 text-[#A3A3A3]">
                  <div className="w-6 h-6 border-2 border-[#3BB9FF] border-t-transparent rounded-full animate-spin mr-2" />
                  Chargement...
                </div>
              ) : createdChars.length === 0 ? (
                <div className="flex flex-col gap-3 pt-4">
                  <p className="text-[#A3A3A3] text-sm">
                    Aucun personnage créé. Crée ton premier personnage.
                  </p>
                  <Link
                    href="/creer"
                    className="inline-flex items-center justify-center gap-2 px-4 py-2 rounded-xl bg-[#3BB9FF]/20 text-[#3BB9FF] text-sm font-medium hover:bg-[#3BB9FF]/30 transition-colors w-fit"
                  >
                    <Plus className="w-4 h-4" />
                    Créer un personnage
                  </Link>
                </div>
              ) : (
                <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 pt-4">
                  {createdChars.map((c) => (
                    <button
                      key={c.id}
                      type="button"
                      onClick={() => router.push(`/chat?characterId=${c.id}`)}
                      className="group flex flex-col items-center p-3 rounded-xl bg-[#0F0F0F] border border-[#2A2A2A] hover:border-[#3BB9FF]/50 hover:bg-[#1A1A1A] transition-colors text-left"
                    >
                      <div className="w-full aspect-[3/4] rounded-lg overflow-hidden mb-2 bg-[#2A2A2A]">
                        <img
                          src={c.image || "/jade.png"}
                          alt={c.name}
                          className="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
                        />
                      </div>
                      <p className="font-medium text-white text-sm truncate w-full">{c.name}</p>
                      <p className="text-xs text-[#A3A3A3] truncate w-full flex items-center gap-1">
                        <MapPin className="w-3 h-3 flex-shrink-0" />
                        {c.location}
                      </p>
                      <p className="text-xs text-[#6B7280] mt-0.5 flex items-center gap-1">
                        <MessageCircle className="w-3 h-3 flex-shrink-0" />
                        {c.stats?.messages ?? "0"} messages
                      </p>
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>

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
        </>
        )}

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
