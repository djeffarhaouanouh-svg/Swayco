import { NextRequest, NextResponse } from "next/server";
import { prisma } from "@/lib/prisma";

export const dynamic = 'force-dynamic';

function formatMemberSince(date: Date | null): string {
  if (!date) return "";
  return date.toLocaleDateString("fr-FR", {
    day: "numeric",
    month: "long",
    year: "numeric",
  });
}

function mapUserToProfile(user: {
  id: number;
  email: string;
  name: string | null;
  created_at: Date | null;
  plan: string | null;
  credits: number | null;
  credits_per_month: number | null;
  characters_count: number | null;
}) {
  return {
    id: String(user.id),
    name: user.name ?? "Utilisateur",
    email: user.email,
    memberSince: formatMemberSince(user.created_at),
    credits: user.credits ?? 21,
    creditsPerMonth: user.credits_per_month ?? 5,
    charactersCount: user.characters_count ?? 0,
    plan: user.plan === "free" ? "Gratuit" : user.plan ?? "Gratuit",
  };
}

export async function GET(request: NextRequest) {
  try {
    const email = request.nextUrl.searchParams.get("email");
    const userId = request.nextUrl.searchParams.get("userId");

    if (!email && !userId) {
      return NextResponse.json(
        { error: "Email ou userId requis" },
        { status: 400 }
      );
    }

    const user = await prisma.users.findFirst({
      where: userId
        ? { id: parseInt(userId, 10) }
        : { email: email! },
    });

    if (!user) {
      return NextResponse.json({ error: "Profil non trouvé" }, { status: 404 });
    }

    return NextResponse.json(mapUserToProfile(user));
  } catch (error) {
    console.error("[API Profile GET]", error);
    return NextResponse.json(
      { error: "Erreur lors de la récupération du profil" },
      { status: 500 }
    );
  }
}

export async function PATCH(request: NextRequest) {
  try {
    const body = await request.json();
    const { id, email, name, credits, creditsPerMonth, charactersCount } =
      body;

    const identifier = id ?? email;
    if (!identifier) {
      return NextResponse.json(
        { error: "id ou email requis" },
        { status: 400 }
      );
    }

    const existing = await prisma.users.findFirst({
      where: id
        ? { id: typeof id === "string" ? parseInt(id, 10) : id }
        : { email: String(email) },
    });

    const updateData: {
      name?: string;
      email?: string;
      credits?: number;
      credits_per_month?: number;
      characters_count?: number;
    } = {};
    if (name !== undefined) updateData.name = String(name);
    if (email !== undefined) updateData.email = String(email);
    if (credits !== undefined) updateData.credits = Number(credits);
    if (creditsPerMonth !== undefined)
      updateData.credits_per_month = Number(creditsPerMonth);
    if (charactersCount !== undefined)
      updateData.characters_count = Number(charactersCount);

    if (existing) {
      const user = await prisma.users.update({
        where: { id: existing.id },
        data: updateData,
      });
      return NextResponse.json(mapUserToProfile(user));
    }

    const newUser = await prisma.users.create({
      data: {
        name: String(name ?? "Utilisateur"),
        email: String(email ?? identifier),
        credits: Number(credits ?? 21),
        credits_per_month: Number(creditsPerMonth ?? 5),
        characters_count: Number(charactersCount ?? 0),
      },
    });

    return NextResponse.json(mapUserToProfile(newUser));
  } catch (error) {
    console.error("[API Profile PATCH]", error);
    return NextResponse.json(
      { error: "Erreur lors de la mise à jour du profil" },
      { status: 500 }
    );
  }
}

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { name, email } = body;

    if (!email?.trim()) {
      return NextResponse.json({ error: "Email requis" }, { status: 400 });
    }

    const existing = await prisma.users.findUnique({
      where: { email: email.trim() },
    });

    if (existing) {
      return NextResponse.json(mapUserToProfile(existing));
    }

    const user = await prisma.users.create({
      data: {
        name: String(name?.trim() || "Utilisateur"),
        email: email.trim(),
        credits: 21,
        credits_per_month: 5,
        characters_count: 0,
      },
    });

    return NextResponse.json(mapUserToProfile(user));
  } catch (error) {
    console.error("[API Profile POST]", error);
    return NextResponse.json(
      { error: "Erreur lors de la création du profil" },
      { status: 500 }
    );
  }
}
