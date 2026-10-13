// Spreads the AI accounts' first names out. The seeder drew names WITH
// replacement from tiny lists (15 per language), so a country holds hundreds
// of accounts sharing a dozen names (two "Johanna" for one person…).
//
// Per (country, gender): the pool = names already in use + EXTRA below; each
// name may carry at most ceil(accounts / pool) accounts. Accounts over their
// name's cap are renamed to the least-used name of the pool. Everyone else is
// left alone. Only profiles.display_name changes.
//
//   node admin/scripts/dedupe_ai_names.mjs            dry run (writes nothing)
//   node admin/scripts/dedupe_ai_names.mjs --apply    writes
//
// Uses SUPABASE_SERVICE_ROLE_KEY from admin/.env.local.
import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const APPLY = process.argv.includes('--apply');
const env = Object.fromEntries(
  readFileSync(resolve(import.meta.dirname, '..', '.env.local'), 'utf8')
    .split('\n').map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#') && l.includes('='))
    .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }),
);
const db = createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

const w = (s) => s.split(',').map((x) => x.trim()).filter(Boolean);

const ES_F = w('Ana, Laura, Cristina, Patricia, Rocío, Beatriz, Lorena, Pilar, Silvia, Raquel, Eva, Teresa, Inés, Noelia, Claudia, Mónica, Rosa, Verónica, Marina, Celia, Lidia, Sandra, Rebeca, Miriam, Blanca, Clara, Candela, Olivia, Soledad, Belén, Macarena, Esther, Elisa, Adriana, Brenda, Tatiana, Lina, Estefanía, Stephanie, Yuliana, Viviana, Mayra, Ivonne, Dayana, Michelle, Nicole, Evelyn, Micaela, Candelaria, Pamela, Brisa, Guadalupe, Magdalena, Maite, Josefina, Delfina, Bianca, Morena, Sol, Lola, Zoe, Aylén, Constanza, Javiera, Fátima, Karen, Kimberly, Johana, Yesenia, Angie, Nayeli, Ailén, Rocío, Aitana, Leire, Ainhoa, Itziar, Triana');
const ES_M = w('Carlos, Jorge, Luis, Miguel, Manuel, Fernando, Raúl, Óscar, David, Samuel, Guillermo, Gonzalo, Ignacio, Lucas, Martín, Federico, Franco, Lautaro, Valentín, Benjamín, Juan, José, Antonio, Francisco, Alberto, Enrique, Mario, Víctor, Gabriel, Cristóbal, Jhon, Brayan, Yeison, Mauricio, Felipe, Camilo, Julio, Rodrigo, Héctor, Ramón, Joel, Axel, Bautista, Nahuel, Ismael, Aitor, Unai, Jon, Pau');
const PT_F = w('Ana Clara, Ana Júlia, Maria Eduarda, Maria Clara, Isadora, Emanuelly, Sophia, Heloísa, Luiza, Lavínia, Cecília, Melissa, Stefany, Kamila, Jéssica, Débora, Daniele, Priscila, Renata, Vanessa, Viviane, Tatiane, Simone, Luciana, Cristiane, Adriana, Roberta, Carla, Paula, Flávia, Elaine, Michele, Monique, Pâmela, Rayane, Jaqueline, Kelly, Sandra, Silvia, Ingrid, Leila, Mirela, Noemi, Olívia, Pietra, Rebeca, Sara, Talita, Valéria, Yara, Agatha, Antonella, Bárbara, Catarina, Diana, Estela, Fabiana');
const PT_M = w('Carlos, Marcos, Paulo, Ricardo, Fábio, Leandro, Alex, Diego, Renan, Willian, Vitor, Victor, Fernando, Roberto, Sérgio, Márcio, Maurício, Alan, Kauã, Yuri, Joaquim, Miguel, Benício, Théo, Lorenzo, Nicolas, Emanuel, Isaque, Elias, Jonas, Lucca, Pietro, Ruan, Cauã, Daniel');

const EXTRA = {
  'Allemagne|f': w('Anna, Lea, Emma, Laura, Julia, Katharina, Charlotte, Luisa, Paula, Mathilda, Frieda, Marlene, Pauline, Jule, Sarah, Vanessa, Jana, Nina, Eva, Isabell, Alina, Franziska, Theresa, Carla, Helena, Anja, Svenja, Merle, Lotta, Thea, Finja, Maya, Elisa, Annika, Katrin, Miriam, Melanie, Sabrina, Jessica, Lisa, Antonia, Victoria, Josephine, Henrike, Rebecca, Selina, Tabea, Luna, Emily, Mara, Linda, Celine, Karolin, Larissa, Michelle, Nadine, Stefanie, Verena, Wiebke, Hanna, Romy, Jasmin, Kim, Laila, Sina, Pia'),
  'Allemagne|m': w('Lukas, Moritz, Niklas, Leon, Julian, Simon, Fabian, Florian, Sebastian, Tobias, Marcel, Dominik, Philipp, Alexander, Lennart, Henri, Anton, Theo, Matteo, Oskar, Mats, Jannik, Nico, Kilian, Timo, Erik, Johannes, Marvin, Kevin, Robin, Lasse, Ole, Hannes, Valentin, Benedikt, Christian, Daniel, Stefan, Patrick, Sven'),
  'France|f': w('Clara, Lola, Zoé, Louise, Alice, Julie, Marine, Océane, Pauline, Anaïs, Margaux, Eva, Romane, Juliette, Élise, Charlotte, Mathilde, Clémence, Justine, Laura, Marion, Elodie, Lucie, Agathe, Capucine, Apolline, Salomé, Noémie, Lou, Rose, Anna, Axelle, Célia, Cécile, Coralie, Déborah, Eloïse, Estelle, Gaëlle, Héloïse, Iris, Joséphine, Lise, Maëva, Maëlys, Morgane, Nolwenn, Orane, Priscilla, Sixtine, Typhaine, Victoire, Yasmine, Émilie, Solène, Garance, Violette, Cassandre, Lisa, Maélie'),
  'France|m': w('Antoine, Alexandre, Arthur, Baptiste, Clément, Adrien, Louis, Jules, Paul, Tom, Mathis, Quentin, Romain, Thomas, Valentin, Victor, Julien, Simon, Pierre, Nicolas, Florian, Benjamin, Guillaume, Mathieu, Rémi, Axel, Kévin, Dylan, Sacha, Samuel, Matthieu, Corentin, Yann, Loïc, Anthony, Bastien, Damien, Jérémy, Killian, Mehdi'),
  'Corée du Sud|f': w('수빈, 예린, 유나, 지유, 나은, 서현, 소민, 가은, 다인, 아린, 시은, 윤서, 하린, 채은, 민지, 예진, 지원, 수현, 은지, 혜인, 보라, 세아, 연우, 나연, 다현, 하영, 승아, 현서, 주아, 서아, 이서, 지아, 다온, 아인, 도연, 하나, 유빈, 채린, 소희, 미소, 예나, 지현, 은채, 라희, 시현, 윤아, 나윤, 소은, 가영, 서영, 다영, 지수, 은비, 수민, 채아'),
  'Japon|f': w('莉奈, 優奈, 美優, 彩花, 瑞希, 咲良, 七海, 心春, 杏, 楓, 柚希, 菜々子, 琴音, 千尋, 梨花, 明日香, 玲奈, 絵里, 沙希, 麻衣, 由美, 奈々, 友香, 理央, 実優, 日向, 澪, 凪, 栞, 萌, 里奈, 香織, 恵, 舞, 陽菜, 紗希, 結菜, 莉央, 優花, 春香, 夏美, 愛美, 真由, 佳奈, 未来, 彩乃, 志穂, 智美, 亜美, 知佳, 華, 結愛, 芽依, 心愛, 咲'),
  'Argentine|f': ES_F, 'Colombie|f': ES_F, 'Espagne|f': ES_F,
  'Argentine|m': ES_M, 'Colombie|m': ES_M, 'Espagne|m': ES_M,
  'Brésil|f': PT_F, 'Brésil|m': PT_M,
  'Suède|f': w('Maria, Anna, Karin, Kristina, Sara, Jenny, Linda, Annika, Camilla, Caroline, Charlotte, Erika, Evelina, Felicia, Gabriella, Helena, Isabelle, Jessica, Karolina, Lisa, Louise, Madeleine, Malin, Mikaela, Natalie, Rebecka, Sandra, Sofie, Sophie, Therese, Victoria, Alva, Elvira, Tyra, Tora, Majken, Lykke, Nellie, Livia, Siri, Edith, Greta, Hedvig, Ronja, Tuva, Lina, Mia'),
  'Suède|m': w('Johan, Anders, Mikael, Andreas, Fredrik, Magnus, Mattias, Marcus, Jonas, Daniel, Simon, Emil, Jakob, Rasmus, Sebastian, Adam, Ludvig, Theodor, Sixten, Valter, Vincent, Ture, Nils, Olle, Måns, Alfred, Arvid, Edvin, Folke, Gabriel, Henrik, Joel, Kalle, Love, Malte, Noel'),
  'Philippines|f': w('Ara, Bernadette, Carmela, Dianne, Elaine, Faith, Grace, Hannah, Irish, Jhoanna, Kimberly, Lorraine, Maricel, Nikki, Odette, Pauline, Rochelle, Shane, Thea, Venus, Wendy, Yvonne, Abby, Cherry, Daisy, Ella, Fatima, Gelaine, Hanna, Ivy, Joy, Kristel, Lyka, Mica, Nena, Precious, Rose Ann, Shaina, Trina, Ysabel, Zia'),
  'Inde|f': w('Aaradhya, Anika, Bhumi, Chhavi, Deepika, Ekta, Falguni, Garima, Harini, Indira, Jyoti, Kiara, Lavanya, Mitali, Nandini, Ojasvi, Palak, Rashi, Saanvi, Tanya'),
};

const rows = [];
for (let from = 0; ; from += 1000) {
  const { data, error } = await db.from('profiles')
    .select('id, display_name, country, gender').eq('is_ai', true).order('id').range(from, from + 999);
  if (error) throw error;
  rows.push(...data);
  if (data.length < 1000) break;
}

const groups = new Map();
for (const r of rows) {
  const k = `${r.country}|${r.gender}`;
  if (!groups.has(k)) groups.set(k, []);
  groups.get(k).push(r);
}

const shuffle = (a) => { for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };
const renames = [];

for (const [k, accts] of [...groups].sort()) {
  const pool = [...new Set([...accts.map((a) => a.display_name), ...(EXTRA[k] ?? [])])];
  const cap = Math.ceil(accts.length / pool.length);
  const use = new Map(pool.map((n) => [n, 0]));
  const over = [];
  for (const a of shuffle([...accts])) {
    const n = use.get(a.display_name) ?? 0;
    if (n < cap) use.set(a.display_name, n + 1);
    else over.push(a);
  }
  for (const a of over) {
    const min = Math.min(...use.values());
    const cands = [...use].filter(([, c]) => c === min).map(([n]) => n);
    const name = cands[Math.floor(Math.random() * cands.length)];
    use.set(name, min + 1);
    renames.push({ id: a.id, from: a.display_name, to: name, key: k });
  }
  const maxUse = Math.max(...use.values());
  console.log(`${k.padEnd(20)} accounts ${String(accts.length).padStart(4)}  pool ${String(pool.length).padStart(3)}  max per name ${maxUse}  renamed ${over.length}`);
}

console.log(`\n${renames.length} renames planned (${APPLY ? 'APPLYING' : 'dry run — pass --apply to write'})`);
if (APPLY) {
  let done = 0;
  for (let i = 0; i < renames.length; i += 20) {
    await Promise.all(renames.slice(i, i + 20).map(async (r) => {
      const { error } = await db.from('profiles').update({ display_name: r.to }).eq('id', r.id).eq('is_ai', true);
      if (error) console.error('ERR', r.id, error.message); else done++;
    }));
  }
  console.log(`${done}/${renames.length} updated`);
}
