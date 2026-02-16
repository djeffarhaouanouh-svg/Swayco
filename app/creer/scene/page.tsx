"use client";

import { useState, Suspense, useEffect, useRef } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { ArrowLeft, Camera, X, Loader2 } from "lucide-react";

function SceneContent() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const stepParam = searchParams.get("step");
  const step = stepParam === "3" ? 3 : stepParam === "2" ? 2 : 1;
  const nameFromUrl = searchParams.get("name") ?? "";

  const [prenom, setPrenom] = useState(step === 1 ? "" : nameFromUrl);
  const [typeScene, setTypeScene] = useState("");
  const [ambiance, setAmbiance] = useState("");
  const [descriptionScene, setDescriptionScene] = useState("");
  const [importedImageUrl, setImportedImageUrl] = useState<string | null>(null);
  const [importedImageFile, setImportedImageFile] = useState<File | null>(null);
  const [showImageOverlay, setShowImageOverlay] = useState(false);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const displayName = step !== 1 ? nameFromUrl || prenom : prenom;
  const isStep1 = step === 1;
  const isStep2 = step === 2;
  const isStep3 = step === 3;

  const handleSubmitStep1 = (e: React.FormEvent) => {
    e.preventDefault();
    const trimmed = prenom.trim();
    if (trimmed) {
      router.push(`/creer/scene?step=2&name=${encodeURIComponent(trimmed)}`);
    }
  };

  const handleBack = () => {
    if (isStep2) {
      router.push("/creer/scene");
    } else if (isStep3) {
      router.push(`/creer/scene?step=2&name=${encodeURIComponent(displayName)}`);
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
    if (fileInputRef.current) fileInputRef.current.value = "";
  };

  const handleSubmitStep2 = () => {
    if (!displayName?.trim()) return;
    router.push(`/creer/scene?step=3&name=${encodeURIComponent(displayName.trim())}`);
  };

  const [isSubmitting, setIsSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [adresseScene, setAdresseScene] = useState("");

  const handleSubmitStep3 = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!displayName?.trim()) return;
    setIsSubmitting(true);
    setSubmitError(null);

    try {
      const res = await fetch("/api/scenes", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: displayName.trim(),
          location: adresseScene.trim() || null,
          description: descriptionScene || null,
          typeScene: typeScene || null,
          ambiance: ambiance || null,
          characterId: 1,
          imageUrl: importedImageUrl || null,
        }),
      });

      if (!res.ok) {
        const data = await res.json();
        setSubmitError(data.error || "Erreur lors de la création");
        return;
      }

      router.push("/");
    } catch (err) {
      setSubmitError("Erreur réseau, réessaye.");
      console.error("Erreur création scène:", err);
    } finally {
      setIsSubmitting(false);
    }
  };

  useEffect(() => {
    return () => {
      if (importedImageUrl) URL.revokeObjectURL(importedImageUrl);
    };
  }, [importedImageUrl]);

  const progressWidth = step === 1 ? "33%" : step === 2 ? "66%" : "100%";

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
          Créer une scène
        </h1>
        <div className="w-9" />
      </header>

      {isStep1 ? (
        <main className="flex-1 px-12 md:px-20 pt-6 pb-6">
          <div className="mb-6">
            <span className="text-sm text-[#A3A3A3]">Étape 1 / 3</span>
            <div className="w-full h-2 bg-[#2A2A2A] rounded-full overflow-hidden mt-1">
              <div className="h-full bg-[#3BB9FF] transition-all duration-300" style={{ width: progressWidth }} />
            </div>
          </div>
          <p className="text-white mb-3">Quel est ton prénom ?</p>
          <form onSubmit={handleSubmitStep1} className="space-y-3">
            <input
              type="text"
              value={prenom}
              onChange={(e) => setPrenom(e.target.value)}
              placeholder="Ton prénom"
              className="w-full px-4 py-3 bg-[#1E1E1E] border border-[#2A2A2A] rounded-xl text-white placeholder:text-[#6B7280] focus:outline-none focus:ring-2 focus:ring-[#3BB9FF] focus:border-transparent"
              autoFocus
            />
            <button
              type="submit"
              disabled={!prenom.trim()}
              className={`w-full py-3 px-4 rounded-xl text-white font-medium transition-colors ${
                prenom.trim() ? "bg-[#3BB9FF] hover:bg-[#2AA3E6]" : "bg-[#1E1E1E] border border-[#2A2A2A] text-[#6B7280] cursor-not-allowed"
              }`}
            >
              Suivant
            </button>
          </form>
        </main>
      ) : isStep2 ? (
        <main className="flex-1 px-6 md:px-20 pt-8 pb-24 flex flex-col">
          <input ref={fileInputRef} type="file" accept="image/*" onChange={onFileChange} className="hidden" />
          <div className="mb-6">
            <span className="text-sm text-[#A3A3A3]">Étape 2 / 3</span>
            <div className="w-full h-2 bg-[#2A2A2A] rounded-full overflow-hidden mt-1">
              <div className="h-full bg-[#3BB9FF] transition-all duration-300" style={{ width: progressWidth }} />
            </div>
          </div>
          <h2 className="text-xl font-semibold text-white mb-2">Photo de la scène</h2>
          <p className="text-[#A3A3A3] mb-6">Upload une photo pour illustrer ta scène, {displayName}</p>

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
                <img src={importedImageUrl} alt={`Photo scène`} className="w-full h-full object-cover" />
                <button
                  type="button"
                  onClick={(e) => { e.stopPropagation(); handleRemoveImage(); }}
                  aria-label="Supprimer"
                  className="absolute top-2 right-2 w-8 h-8 rounded-full bg-black/60 hover:bg-black/80 flex items-center justify-center text-white"
                >
                  <X className="w-5 h-5" />
                </button>
              </div>
              <button type="button" onClick={() => fileInputRef.current?.click()} className="text-[#3BB9FF] hover:underline text-sm">
                Changer la photo
              </button>
            </div>
          )}

          {showImageOverlay && importedImageUrl && (
            <div className="fixed inset-0 z-50 bg-black/90 flex items-center justify-center p-4" onClick={() => setShowImageOverlay(false)}>
              <button onClick={() => setShowImageOverlay(false)} aria-label="Fermer" className="absolute top-4 right-4 w-10 h-10 rounded-full bg-white/10 hover:bg-white/20 flex items-center justify-center text-white">
                <X className="w-6 h-6" />
              </button>
              <img src={importedImageUrl} alt="Photo scène" className="max-w-full max-h-full object-contain rounded-xl" onClick={(e) => e.stopPropagation()} />
            </div>
          )}

          <footer className="fixed bottom-0 left-0 right-0 pl-4 pr-4 md:pl-6 md:pr-6 py-4 bg-[#0F0F0F] border-t border-[#2A2A2A] flex justify-end pb-[max(1rem,env(safe-area-inset-bottom))]">
            <button type="button" onClick={handleSubmitStep2} className="py-2.5 px-6 font-medium rounded-xl bg-[#3BB9FF] text-white hover:bg-[#2AA3E6]">
              Continuer
            </button>
          </footer>
        </main>
      ) : (
        <main className="flex-1 px-6 md:px-20 pt-8 pb-24 flex flex-col">
          <div className="mb-6">
            <span className="text-sm text-[#A3A3A3]">Étape 3 / 3</span>
            <div className="w-full h-2 bg-[#2A2A2A] rounded-full overflow-hidden mt-1">
              <div className="h-full bg-[#3BB9FF] transition-all duration-300" style={{ width: progressWidth }} />
            </div>
          </div>
          <h2 className="text-xl font-semibold text-white mb-2">Caractéristiques de la scène</h2>
          <p className="text-[#A3A3A3] mb-6">Complète les informations de ta scène, {displayName}</p>

          <form onSubmit={handleSubmitStep3} className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-[#A3A3A3] mb-1.5">Adresse / Lieu</label>
              <input
                type="text"
                value={adresseScene}
                onChange={(e) => setAdresseScene(e.target.value)}
                placeholder="Ex : Paris, Shibuya, Rome..."
                className="w-full px-4 py-3 bg-[#1E1E1E] border border-[#2A2A2A] rounded-xl text-white placeholder:text-[#6B7280] focus:outline-none focus:ring-2 focus:ring-[#3BB9FF] focus:border-transparent"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-[#A3A3A3] mb-1.5">Type de scène</label>
              <input
                type="text"
                value={typeScene}
                onChange={(e) => setTypeScene(e.target.value)}
                placeholder="Ex : Intérieur, Extérieur, Restaurant..."
                className="w-full px-4 py-3 bg-[#1E1E1E] border border-[#2A2A2A] rounded-xl text-white placeholder:text-[#6B7280] focus:outline-none focus:ring-2 focus:ring-[#3BB9FF] focus:border-transparent"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-[#A3A3A3] mb-1.5">Ambiance</label>
              <input
                type="text"
                value={ambiance}
                onChange={(e) => setAmbiance(e.target.value)}
                placeholder="Ex : Romantique, Dynamique, Calme..."
                className="w-full px-4 py-3 bg-[#1E1E1E] border border-[#2A2A2A] rounded-xl text-white placeholder:text-[#6B7280] focus:outline-none focus:ring-2 focus:ring-[#3BB9FF] focus:border-transparent"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-[#A3A3A3] mb-1.5">Décris la scène</label>
              <textarea
                value={descriptionScene}
                onChange={(e) => setDescriptionScene(e.target.value)}
                placeholder="Décris la scène, l'atmosphère, les détails..."
                rows={4}
                className="w-full px-4 py-3 bg-[#1E1E1E] border border-[#2A2A2A] rounded-xl text-white placeholder:text-[#6B7280] focus:outline-none focus:ring-2 focus:ring-[#3BB9FF] focus:border-transparent resize-none"
              />
            </div>

            {submitError && (
              <div className="p-3 bg-red-500/20 border border-red-500/50 rounded-xl text-red-200 text-sm">
                {submitError}
              </div>
            )}

            <footer className="fixed bottom-0 left-0 right-0 pl-4 pr-4 md:pl-6 md:pr-6 py-4 bg-[#0F0F0F] border-t border-[#2A2A2A] flex justify-end pb-[max(1rem,env(safe-area-inset-bottom))]">
              <button
                type="submit"
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
          </form>
        </main>
      )}
    </div>
  );
}

export default function ScenePage() {
  return (
    <Suspense fallback={null}>
      <SceneContent />
    </Suspense>
  );
}
