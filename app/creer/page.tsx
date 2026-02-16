"use client";

import { useState, Suspense, useEffect, useRef } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { ArrowLeft, Camera, X, Volume2, Loader2 } from "lucide-react";

type Voice = {
  voice_id: string;
  name: string;
  category?: string;
  labels?: Record<string, string>;
};

type GenderFilter = "tous" | "femme" | "homme";

function CreerContent() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const stepParam = searchParams.get("step");
  const step =
    stepParam === "4" ? 4 : stepParam === "3" ? 3 : stepParam === "2" ? 2 : 1;
  const nameFromUrl = searchParams.get("name") ?? "";

  const [prenom, setPrenom] = useState(step === 1 ? "" : nameFromUrl);
  const [pays, setPays] = useState("");
  const [adresse, setAdresse] = useState("");
  const [age, setAge] = useState("");
  const [descriptionPersonnage, setDescriptionPersonnage] = useState("");
  const [importedImageUrl, setImportedImageUrl] = useState<string | null>(null);
  const [importedImageFile, setImportedImageFile] = useState<File | null>(null);
  const [showImageOverlay, setShowImageOverlay] = useState(false);
  const [voices, setVoices] = useState<Voice[]>([]);
  const [selectedVoiceId, setSelectedVoiceId] = useState<string | null>(null);
  const [genderFilter, setGenderFilter] = useState<GenderFilter>("tous");
  const [playingVoiceId, setPlayingVoiceId] = useState<string | null>(null);
  const [voicesLoading, setVoicesLoading] = useState(false);
  const [voicesError, setVoicesError] = useState<string | null>(null);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const isVoiceFeminine = (v: Voice) => {
    const g = (v.labels?.gender ?? "").toLowerCase();
    return g === "female" || g === "feminine" || g === "femme";
  };
  const isVoiceMasculine = (v: Voice) => {
    const g = (v.labels?.gender ?? "").toLowerCase();
    return g === "male" || g === "masculine" || g === "homme";
  };

  const filteredVoices =
    genderFilter === "tous"
      ? voices
      : genderFilter === "femme"
      ? voices.filter(isVoiceFeminine)
      : voices.filter(isVoiceMasculine);

  const displayName = step !== 1 ? nameFromUrl || prenom : prenom;
  const isStep1 = step === 1;
  const isStep2 = step === 2;
  const isStep3 = step === 3;
  const isStep4 = step === 4;

  const handleSubmitStep1 = (e: React.FormEvent) => {
    e.preventDefault();
    const trimmed = prenom.trim();
    if (trimmed) {
      router.push(`/creer?step=2&name=${encodeURIComponent(trimmed)}`);
    }
  };

  const handleBack = () => {
    if (isStep2) {
      router.push("/creer");
    } else if (isStep3) {
      router.push(`/creer?step=2&name=${encodeURIComponent(displayName)}`);
    } else if (isStep4) {
      router.push(`/creer?step=3&name=${encodeURIComponent(displayName)}`);
    } else {
      router.push("/");
    }
  };

  const onFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file || !file.type.startsWith("image/")) return;
    setImportedImageFile(file);
    setImportedImageUrl((prev) => {
      if (prev) URL.revokeObjectURL(prev);
      return URL.createObjectURL(file);
    });
  };

  const handleRemoveImage = () => {
    setImportedImageUrl((prev) => {
      if (prev) URL.revokeObjectURL(prev);
      return null;
    });
    setImportedImageFile(null);
    if (fileInputRef.current) {
      fileInputRef.current.value = "";
    }
  };

  const handleSubmitStep2 = () => {
    if (!displayName || !displayName.trim()) return;
    router.push(`/creer?step=3&name=${encodeURIComponent(displayName.trim())}`);
  };

  const handleSubmitStep3 = (e: React.FormEvent) => {
    e.preventDefault();
    if (!displayName || !displayName.trim()) return;
    router.push(`/creer?step=4&name=${encodeURIComponent(displayName.trim())}`);
  };

  const [isSubmitting, setIsSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);

  const handleSubmitStep4 = async () => {
    if (!displayName || !displayName.trim()) return;
    setIsSubmitting(true);
    setSubmitError(null);

    try {
      const res = await fetch("/api/characters", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: displayName.trim(),
          country: pays || "France",
          address: adresse || null,
          age: age || null,
          description: descriptionPersonnage || null,
          voiceId: selectedVoiceId,
          imageUrl: importedImageUrl || null,
        }),
      });

      if (!res.ok) {
        const data = await res.json();
        setSubmitError(data.error || "Erreur lors de la création");
        return;
      }

      router.push("/personnages");
    } catch (err) {
      setSubmitError("Erreur réseau, réessaye.");
      console.error("Erreur création personnage:", err);
    } finally {
      setIsSubmitting(false);
    }
  };

  const playVoicePreview = (voiceId: string, e: React.MouseEvent) => {
    e.stopPropagation();
    if (playingVoiceId === voiceId) {
      audioRef.current?.pause();
      setPlayingVoiceId(null);
      return;
    }
    if (audioRef.current) {
      audioRef.current.pause();
    }
    setSelectedVoiceId(voiceId);
    setPlayingVoiceId(voiceId);
    const audio = new Audio(`/api/elevenlabs-preview?voice_id=${voiceId}`);
    audioRef.current = audio;
    audio.addEventListener("ended", () => setPlayingVoiceId(null));
    audio.addEventListener("error", () => setPlayingVoiceId(null));
    audio.play().catch(() => setPlayingVoiceId(null));
  };

  const handleVoiceCardClick = (voice: Voice, e: React.MouseEvent) => {
    setSelectedVoiceId(voice.voice_id);
    playVoicePreview(voice.voice_id, e);
  };

  useEffect(() => {
    return () => {
      if (importedImageUrl) URL.revokeObjectURL(importedImageUrl);
      audioRef.current?.pause();
    };
  }, [importedImageUrl]);

  useEffect(() => {
    if (step === 1 && importedImageUrl) {
      URL.revokeObjectURL(importedImageUrl);
      setImportedImageUrl(null);
    }
  }, [step, importedImageUrl]);

  useEffect(() => {
    if (!isStep4) return;
    setVoicesLoading(true);
    setVoicesError(null);
    fetch("/api/elevenlabs-voices")
      .then((res) => res.json())
      .then((data) => {
        if (Array.isArray(data)) {
          setVoices(data);
        } else if (data.error) {
          setVoicesError(data.error);
        } else {
          setVoicesError("Format de réponse inattendu");
        }
      })
      .catch((err) => {
        setVoicesError(err.message || "Erreur réseau");
      })
      .finally(() => setVoicesLoading(false));
  }, [isStep4]);

  const progressWidth =
    step === 1 ? "25%" : step === 2 ? "50%" : step === 3 ? "75%" : "100%";

  return (
    <div className="min-h-screen bg-[#0F0F0F] text-white flex flex-col pt-[env(safe-area-inset-top)] pb-[env(safe-area-inset-bottom)]">
      <header className="sticky top-0 z-50 flex items-center justify-between pl-3 pr-12 md:pl-4 md:pr-20 py-3 border-b border-[#2A2A2A] bg-[#0F0F0F]">
        <button
          type="button"
          onClick={handleBack}
          className="p-2 rounded-lg hover:bg-[#1A1A1A] transition-colors text-white"
          aria-label="Retour"
        >
          <ArrowLeft className="w-5 h-5" />
        </button>
        <h1 className="text-base font-semibold absolute left-1/2 -translate-x-1/2">
          Onboarding IA
        </h1>
        <div className="w-9" />
      </header>

      {isStep1 ? (
        /* Étape 1 : Prénom */
        <main className="flex-1 px-12 md:px-20 pt-6 pb-6">
          <div className="mb-6">
            <span className="text-sm text-[#A3A3A3]">Étape 1 / 4</span>
            <div className="w-full h-2 bg-[#2A2A2A] rounded-full overflow-hidden mt-1">
              <div
                className="h-full bg-[#3BB9FF] transition-all duration-300"
                style={{ width: progressWidth }}
              />
            </div>
          </div>
          <p className="text-white mb-3">
            Pour commencer, quel est ton prénom ?
          </p>
          <form onSubmit={handleSubmitStep1} className="space-y-3">
            <div>
              <input
                type="text"
                value={prenom}
                onChange={(e) => setPrenom(e.target.value)}
                placeholder="Ton prénom"
                className="w-full px-4 py-3 bg-[#1E1E1E] border border-[#2A2A2A] rounded-xl text-white placeholder:text-[#6B7280] focus:outline-none focus:ring-2 focus:ring-[#3BB9FF] focus:border-transparent"
                autoFocus
              />
            </div>
            <button
              type="submit"
              disabled={!prenom.trim()}
              className={`w-full py-3 px-4 rounded-xl text-white font-medium transition-colors ${
                prenom.trim()
                  ? "bg-[#3BB9FF] hover:bg-[#2AA3E6]"
                  : "bg-[#1E1E1E] border border-[#2A2A2A] text-[#6B7280] cursor-not-allowed"
              }`}
            >
              Suivant
            </button>
          </form>
        </main>
      ) : isStep2 ? (
        /* Étape 2 : Upload photo */
        <main className="flex-1 px-6 md:px-20 pt-8 pb-24 flex flex-col">
          <input
            ref={fileInputRef}
            type="file"
            accept="image/*"
            onChange={onFileChange}
            className="hidden"
          />

          <div className="mb-6">
            <span className="text-sm text-[#A3A3A3]">Étape 2 / 4</span>
            <div className="w-full h-2 bg-[#2A2A2A] rounded-full overflow-hidden mt-1">
              <div
                className="h-full bg-[#3BB9FF] transition-all duration-300"
                style={{ width: progressWidth }}
              />
            </div>
          </div>

          <h2 className="text-xl font-semibold text-white mb-2">Ta photo</h2>
          <p className="text-[#A3A3A3] mb-6">
            Upload ta photo pour personnaliser ton avatar, {displayName}
          </p>

          {!importedImageUrl ? (
            <button
              type="button"
              onClick={() => fileInputRef.current?.click()}
              className="w-full aspect-square max-w-[300px] mx-auto flex flex-col items-center justify-center gap-3 bg-[#1E1E1E] border-2 border-dashed border-[#2A2A2A] rounded-xl hover:border-[#3BB9FF] hover:bg-[#252525] transition-colors text-[#A3A3A3] hover:text-white"
            >
              <Camera className="w-16 h-16 text-[#3BB9FF]" />
              <span className="text-base font-medium">Ajouter une photo</span>
              <span className="text-sm">PNG, JPG ou WEBP</span>
            </button>
          ) : (
            <div className="flex-1 flex flex-col items-center">
              <div
                className="relative w-full max-w-[300px] aspect-square rounded-xl overflow-hidden bg-[#1E1E1E] border border-[#2A2A2A] mb-4 cursor-pointer"
                onClick={() => setShowImageOverlay(true)}
              >
                <img
                  src={importedImageUrl}
                  alt={`Photo de ${displayName}`}
                  className="w-full h-full object-cover"
                />
                <button
                  type="button"
                  onClick={(e) => {
                    e.stopPropagation();
                    handleRemoveImage();
                  }}
                  aria-label="Supprimer la photo"
                  className="absolute top-2 right-2 w-8 h-8 rounded-full bg-black/60 hover:bg-black/80 flex items-center justify-center text-white transition-colors"
                >
                  <X className="w-5 h-5" />
                </button>
              </div>
              <button
                type="button"
                onClick={() => fileInputRef.current?.click()}
                className="text-[#3BB9FF] hover:underline text-sm"
              >
                Changer la photo
              </button>
            </div>
          )}

          {showImageOverlay && importedImageUrl && (
            <div
              className="fixed inset-0 z-50 bg-black/90 flex items-center justify-center p-4"
              onClick={() => setShowImageOverlay(false)}
            >
              <button
                type="button"
                onClick={() => setShowImageOverlay(false)}
                aria-label="Fermer"
                className="absolute top-4 right-4 w-10 h-10 rounded-full bg-white/10 hover:bg-white/20 flex items-center justify-center text-white transition-colors"
              >
                <X className="w-6 h-6" />
              </button>
              <img
                src={importedImageUrl}
                alt={`Photo de ${displayName}`}
                className="max-w-full max-h-full object-contain rounded-xl"
                onClick={(e) => e.stopPropagation()}
              />
            </div>
          )}

          <footer className="fixed bottom-0 left-0 right-0 pl-4 pr-4 md:pl-6 md:pr-6 py-4 bg-[#0F0F0F] border-t border-[#2A2A2A] flex items-center justify-end pb-[max(1rem,env(safe-area-inset-bottom))]">
            <button
              type="button"
              onClick={handleSubmitStep2}
              className="py-2.5 px-6 font-medium rounded-xl transition-colors flex items-center gap-2 bg-[#3BB9FF] text-white hover:bg-[#2AA3E6]"
            >
              Continuer
            </button>
          </footer>
        </main>
      ) : isStep3 ? (
        /* Étape 3 : Caractéristiques */
        <main className="flex-1 px-6 md:px-20 pt-8 pb-24 flex flex-col">
          <div className="mb-6">
            <span className="text-sm text-[#A3A3A3]">Étape 3 / 4</span>
            <div className="w-full h-2 bg-[#2A2A2A] rounded-full overflow-hidden mt-1">
              <div
                className="h-full bg-[#3BB9FF] transition-all duration-300"
                style={{ width: progressWidth }}
              />
            </div>
          </div>

          <h2 className="text-xl font-semibold text-white mb-2">
            Caractéristiques
          </h2>
          <p className="text-[#A3A3A3] mb-6">
            Complète les informations du personnage, {displayName}
          </p>

          <form onSubmit={handleSubmitStep3} className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-[#A3A3A3] mb-1.5">
                Pays
              </label>
              <input
                type="text"
                value={pays}
                onChange={(e) => setPays(e.target.value)}
                placeholder="Ex : France"
                className="w-full px-4 py-3 bg-[#1E1E1E] border border-[#2A2A2A] rounded-xl text-white placeholder:text-[#6B7280] focus:outline-none focus:ring-2 focus:ring-[#3BB9FF] focus:border-transparent"
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-[#A3A3A3] mb-1.5">
                Adresse <span className="text-[#6B7280]">(facultatif)</span>
              </label>
              <input
                type="text"
                value={adresse}
                onChange={(e) => setAdresse(e.target.value)}
                placeholder="Ex : Paris, 75001"
                className="w-full px-4 py-3 bg-[#1E1E1E] border border-[#2A2A2A] rounded-xl text-white placeholder:text-[#6B7280] focus:outline-none focus:ring-2 focus:ring-[#3BB9FF] focus:border-transparent"
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-[#A3A3A3] mb-1.5">
                Âge
              </label>
              <input
                type="text"
                value={age}
                onChange={(e) => setAge(e.target.value)}
                placeholder="Ex : 28 ans"
                className="w-full px-4 py-3 bg-[#1E1E1E] border border-[#2A2A2A] rounded-xl text-white placeholder:text-[#6B7280] focus:outline-none focus:ring-2 focus:ring-[#3BB9FF] focus:border-transparent"
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-[#A3A3A3] mb-1.5">
                Décris le personnage
              </label>
              <textarea
                value={descriptionPersonnage}
                onChange={(e) => setDescriptionPersonnage(e.target.value)}
                placeholder="Personnalité, passions, style de vie..."
                rows={4}
                className="w-full px-4 py-3 bg-[#1E1E1E] border border-[#2A2A2A] rounded-xl text-white placeholder:text-[#6B7280] focus:outline-none focus:ring-2 focus:ring-[#3BB9FF] focus:border-transparent resize-none"
              />
            </div>

            <footer className="fixed bottom-0 left-0 right-0 pl-4 pr-4 md:pl-6 md:pr-6 py-4 bg-[#0F0F0F] border-t border-[#2A2A2A] flex justify-end pb-[max(1rem,env(safe-area-inset-bottom))]">
              <button
                type="submit"
                className="py-2.5 px-6 font-medium rounded-xl bg-[#3BB9FF] text-white hover:bg-[#2AA3E6] transition-colors"
              >
                Continuer
              </button>
            </footer>
          </form>
        </main>
      ) : (
        /* Étape 4 : Sélection de la voix */
        <main className="flex-1 px-6 md:px-20 pt-8 pb-24 flex flex-col">
          <div className="mb-6">
            <span className="text-sm text-[#A3A3A3]">Étape 4 / 4</span>
            <div className="w-full h-2 bg-[#2A2A2A] rounded-full overflow-hidden mt-1">
              <div
                className="h-full bg-[#3BB9FF] transition-all duration-300"
                style={{ width: progressWidth }}
              />
            </div>
          </div>

          <h2 className="text-xl font-semibold text-white mb-2">
            Choisis ta voix
          </h2>
          <p className="text-[#A3A3A3] mb-4">
            Clique sur une voix pour l&apos;écouter. Sélectionne celle qui te plaît, {displayName}
          </p>

          {/* Filtre Homme / Femme */}
          <div className="flex gap-2 mb-6">
            <button
              type="button"
              onClick={() => setGenderFilter("tous")}
              className={`px-4 py-2 rounded-xl text-sm font-medium transition-colors ${
                genderFilter === "tous"
                  ? "bg-[#3BB9FF] text-white"
                  : "bg-[#1E1E1E] border border-[#2A2A2A] text-[#A3A3A3] hover:border-[#3BB9FF]"
              }`}
            >
              Tous
            </button>
            <button
              type="button"
              onClick={() => setGenderFilter("femme")}
              className={`px-4 py-2 rounded-xl text-sm font-medium transition-colors ${
                genderFilter === "femme"
                  ? "bg-[#3BB9FF] text-white"
                  : "bg-[#1E1E1E] border border-[#2A2A2A] text-[#A3A3A3] hover:border-[#3BB9FF]"
              }`}
            >
              Femme
            </button>
            <button
              type="button"
              onClick={() => setGenderFilter("homme")}
              className={`px-4 py-2 rounded-xl text-sm font-medium transition-colors ${
                genderFilter === "homme"
                  ? "bg-[#3BB9FF] text-white"
                  : "bg-[#1E1E1E] border border-[#2A2A2A] text-[#A3A3A3] hover:border-[#3BB9FF]"
              }`}
            >
              Homme
            </button>
          </div>

          {voicesLoading ? (
            <div className="flex-1 flex items-center justify-center">
              <div className="flex flex-col items-center gap-3 text-[#A3A3A3]">
                <div className="w-8 h-8 border-2 border-[#3BB9FF] border-t-transparent rounded-full animate-spin" />
                <span>Chargement des voix...</span>
              </div>
            </div>
          ) : voicesError ? (
            <div className="p-4 bg-red-500/20 border border-red-500/50 rounded-xl text-red-200 text-sm">
              {voicesError}
            </div>
          ) : (
            <div className="flex-1 overflow-y-auto pb-4">
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                {filteredVoices.map((voice) => {
                  const isPlaying = playingVoiceId === voice.voice_id;
                  const isSelected = selectedVoiceId === voice.voice_id;
                  return (
                    <button
                      key={voice.voice_id}
                      type="button"
                      onClick={(e) => handleVoiceCardClick(voice, e)}
                      className={`flex items-center gap-3 py-4 px-4 rounded-xl text-left transition-all ${
                        isSelected
                          ? "bg-[#3BB9FF] text-white border-2 border-[#3BB9FF]"
                          : "bg-[#1E1E1E] text-white border border-[#2A2A2A] hover:border-[#3BB9FF]"
                      }`}
                    >
                      <div className="w-10 h-10 rounded-full bg-white/20 flex items-center justify-center flex-shrink-0">
                        {isPlaying ? (
                          <Loader2 className="w-5 h-5 animate-spin" />
                        ) : (
                          <Volume2 className="w-5 h-5" />
                        )}
                      </div>
                      <div className="min-w-0 flex-1">
                        <span className="font-medium block truncate">
                          {voice.name}
                        </span>
                        {voice.category && (
                          <span className="text-sm opacity-80">
                            {voice.category}
                          </span>
                        )}
                      </div>
                    </button>
                  );
                })}
              </div>
              {filteredVoices.length === 0 && !voicesLoading && (
                <p className="text-[#A3A3A3] text-center py-8">
                  {genderFilter === "tous"
                    ? "Aucune voix disponible"
                    : `Aucune voix ${genderFilter} trouvée`}
                </p>
              )}
            </div>
          )}

          {submitError && (
            <div className="p-3 bg-red-500/20 border border-red-500/50 rounded-xl text-red-200 text-sm mb-4">
              {submitError}
            </div>
          )}

          <footer className="fixed bottom-0 left-0 right-0 pl-4 pr-4 md:pl-6 md:pr-6 py-4 bg-[#0F0F0F] border-t border-[#2A2A2A] flex items-center justify-end pb-[max(1rem,env(safe-area-inset-bottom))]">
            <button
              type="button"
              onClick={handleSubmitStep4}
              disabled={isSubmitting}
              className={`py-2.5 px-6 font-medium rounded-xl transition-colors flex items-center gap-2 ${
                isSubmitting
                  ? "bg-[#2A2A2A] text-[#6B7280] cursor-not-allowed"
                  : "bg-[#3BB9FF] text-white hover:bg-[#2AA3E6]"
              }`}
            >
              {isSubmitting ? (
                <>
                  <Loader2 className="w-4 h-4 animate-spin" />
                  Création...
                </>
              ) : (
                "Terminer"
              )}
            </button>
          </footer>
        </main>
      )}
    </div>
  );
}

export default function CreerPage() {
  return (
    <Suspense fallback={null}>
      <CreerContent />
    </Suspense>
  );
}
