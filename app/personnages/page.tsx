"use client";

import { useState, useEffect } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ArrowLeft, Plus, MessageCircle, MapPin } from "lucide-react";

type CharacterItem = {
  id: number;
  name: string;
  location: string;
  image: string;
  description: string;
  stats: { messages: string };
  badge: string;
};

export default function PersonnagesPage() {
  const router = useRouter();
  const [characters, setCharacters] = useState<CharacterItem[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch("/api/characters")
      .then((res) => res.json())
      .then((data) => {
        if (Array.isArray(data)) setCharacters(data);
      })
      .catch((err) => console.error("Erreur chargement personnages:", err))
      .finally(() => setLoading(false));
  }, []);

  return (
    <div className="min-h-screen bg-[#0F0F0F] text-white flex flex-col pt-[env(safe-area-inset-top)] pb-[calc(60px+env(safe-area-inset-bottom))]">
      <header className="sticky top-0 z-50 flex items-center justify-between px-4 py-3 border-b border-[#2A2A2A] bg-[#0F0F0F]">
        <div className="flex items-center gap-3">
          <Link
            href="/profil"
            className="p-2 rounded-lg hover:bg-[#1A1A1A] transition-colors"
          >
            <ArrowLeft className="w-5 h-5" />
          </Link>
          <h1 className="text-lg font-semibold">Personnages</h1>
        </div>
        <Link
          href="/creer"
          className="flex items-center gap-1.5 px-3 py-2 bg-[#3BB9FF] rounded-xl text-sm font-medium hover:bg-[#2AA3E6] transition-colors"
        >
          <Plus className="w-4 h-4" />
          Créer
        </Link>
      </header>

      <main className="flex-1 px-4 py-4">
        {loading ? (
          <div className="flex items-center justify-center py-12 text-[#A3A3A3]">
            <div className="w-8 h-8 border-2 border-[#3BB9FF] border-t-transparent rounded-full animate-spin" />
            <span className="ml-2">Chargement...</span>
          </div>
        ) : characters.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-16 text-center">
            <p className="text-[#A3A3A3] mb-4">Aucun personnage pour le moment</p>
            <Link
              href="/creer"
              className="flex items-center gap-2 px-5 py-3 bg-[#3BB9FF] rounded-xl font-medium hover:bg-[#2AA3E6] transition-colors"
            >
              <Plus className="w-5 h-5" />
              Créer mon premier personnage
            </Link>
          </div>
        ) : (
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            {characters.map((char) => (
              <button
                key={char.id}
                type="button"
                onClick={() => router.push(`/chat?characterId=${char.id}`)}
                className="flex items-start gap-3 p-4 bg-[#1E1E1E] border border-[#2A2A2A] rounded-2xl hover:border-[#3BB9FF]/30 hover:bg-[#252525] transition-colors text-left"
              >
                <div className="w-14 h-14 rounded-full overflow-hidden flex-shrink-0 bg-[#2A2A2A]">
                  <img
                    src={char.image}
                    alt={char.name}
                    className="w-full h-full object-cover"
                  />
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 mb-1">
                    <h3 className="font-semibold text-white truncate">
                      {char.name}
                    </h3>
                    <span className="px-1.5 py-0.5 text-xs bg-[#3BB9FF]/20 text-[#3BB9FF] rounded font-medium">
                      {char.badge}
                    </span>
                  </div>
                  <p className="text-sm text-[#A3A3A3] flex items-center gap-1 mb-1">
                    <MapPin className="w-3 h-3" />
                    {char.location}
                  </p>
                  <p className="text-sm text-[#6B7280] line-clamp-2">
                    {char.description}
                  </p>
                  <p className="text-xs text-[#A3A3A3] flex items-center gap-1 mt-2">
                    <MessageCircle className="w-3 h-3" />
                    {char.stats.messages} messages
                  </p>
                </div>
              </button>
            ))}
          </div>
        )}
      </main>
    </div>
  );
}
