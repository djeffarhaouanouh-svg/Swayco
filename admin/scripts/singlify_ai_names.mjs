// Remplace les prénoms COMPOSÉS des comptes IA (« Gabriela Sophia », « Marie-Lola »,
// créés par dedupe_ai_names.mjs) par un prénom SIMPLE, en gardant des prénoms
// différents dans chaque groupe (pays + genre) grâce aux variantes d'orthographe :
// Chloé / Cloé / Chloe, Camila / Kamila / Camilla, Sofía / Sophia / Sofia…
//
// Par compte renommé : display_name, handle (même règle que l'app : prénom a-z0-9
// + 6 derniers caractères de l'id) et le prénom dans le texte du personnage
// (ai_personas). Un compte pour lequel il ne reste aucun prénom simple libre garde
// son prénom composé (on ne casse jamais l'unicité).
//
//   node admin/scripts/singlify_ai_names.mjs            aperçu (n'écrit rien)
//   node admin/scripts/singlify_ai_names.mjs --apply    écrit
//
// Utilise SUPABASE_SERVICE_ROLE_KEY de admin/.env.local.
import { createClient } from '@supabase/supabase-js';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const APPLY = process.argv.includes('--apply');
// --uniquify : en plus des prénoms composés, on rend DISTINCTS les prénoms partagés (le premier porteur le garde).
// --countries=Argentine,Colombie,Brésil : ne traite que ces pays.
const UNIQ = process.argv.includes('--uniquify');
const ONLY = ((process.argv.find((a) => a.startsWith('--countries=')) || '').split('=')[1] || '').split(',').filter(Boolean);
const env = Object.fromEntries(
  readFileSync(resolve(import.meta.dirname, '..', '.env.local'), 'utf8')
    .split('\n').map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#') && l.includes('='))
    .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }),
);
const db = createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

const w = (s) => s.split(',').map((x) => x.trim()).filter(Boolean);
const strip = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '');
const isLatin = (s) => /^[\p{Script=Latin}'’ .-]+$/u.test(s);
const isCompound = (s) => /[ -]/.test(s.trim()) && isLatin(s);

// ── Variantes d'orthographe (réelles et courantes), selon la langue ──────────
function variantsOnce(name, lang) {
  const out = new Set();
  const add = (v) => { if (v && v !== name && v.length >= 3 && v.length <= 12) out.add(v); };
  const es = lang === 'es', pt = lang === 'pt', fr = lang === 'fr', en = lang === 'en';
  add(strip(name));                                                          // Sofía → Sofia, Chloé → Chloe
  if ((es || pt || fr || en) && /^C[aou]/.test(name)) add('K' + name.slice(1)); // Camila → Kamila
  if ((es || pt || fr || en) && /^K[aou]/.test(name)) add('C' + name.slice(1)); // Karen → Caren
  if ((es || fr) && /^Chlo/.test(name)) add('Clo' + name.slice(4));          // Chloé → Cloé
  if ((es || fr) && /^Chri/.test(name)) add('Cri' + name.slice(4));          // Christina → Cristina
  if (/Soph/.test(name)) add(name.replace('Soph', 'Sof'));                   // Sophia → Sofia
  if (/^Sof(?!f)/.test(name) && !/ie$/.test(name)) add(name.replace('Sof', 'Soph')); // Sofia → Sophia
  if ((es || pt || fr || en) && /[ei]la$/i.test(name)) add(name.replace(/([ei])la$/i, '$1lla')); // Isabela → Isabella, Camila → Camilla
  if ((es || pt || fr || en) && /[ei]lla$/i.test(name)) add(name.replace(/lla$/i, 'la'));        // Isabella → Isabela
  if (/[^n]ana$/i.test(name) || /^Ana$/.test(name)) add(name.replace(/ana$/i, 'anna'));          // Ana → Anna, Mariana → Marianna
  if (/anna$/i.test(name) && name.length > 4) add(name.replace(/anna$/i, 'ana'));                // Julianna → Juliana
  if ((es || pt || en) && /^Y[aeiou]/.test(name)) add('J' + name.slice(1));  // Yasmin → Jasmin
  if ((es || pt || en) && /^J[aeiou]s/.test(name)) add('Y' + name.slice(1)); // Jasmin → Yasmin
  if ((es || pt || en) && /ay/.test(name)) add(name.replace('ay', 'ai'));    // Mayra → Maira
  if ((es || pt || en) && /ey/.test(name)) add(name.replace('ey', 'ei'));    // Leyla → Leila
  if (/^(Sara|Hanna|Hana|Lara|Noa|Maya)$/.test(name)) add(name + 'h');       // Sara → Sarah
  if (/^(Sarah|Hannah|Leah|Noah)$/.test(name)) add(name.slice(0, -1));       // Sarah → Sara
  if (es && /[^í]ia$/.test(name)) add(name.replace(/ia$/, 'ía'));            // Lucia → Lucía
  if (fr && /^(Chlo|Zo|Am[eé]|Em[eé]|Ma[eë]|Jo[eë]|Lo[eë])/.test(name) && /e$/.test(name)) add(name.replace(/e$/, 'é')); // Chloe → Chloé
  if ((es || pt || en) && /^Isa/.test(name) && name.length >= 6) add('Iza' + name.slice(3)); // Isabel → Izabel
  return out;
}
function variantsOf(name, lang) {
  const lvl1 = variantsOnce(name, lang);
  const all = new Set(lvl1);
  for (const v of lvl1) for (const x of variantsOnce(v, lang)) if (x !== name) all.add(x);
  return all;
}
// ── Prénoms simples réels, en plus de ceux déjà en base ──────────────────────
const EXTRA = {
  es: w('Abigail, Ailén, Alondra, Anabel, Araceli, Aurora, Ayelén, Bárbara, Brenda, Brisa, Candelaria, Carmen, Cecilia, Celeste, Dalila, Dayana, Dolores, Eliana, Esperanza, Estefanía, Eugenia, Evelyn, Fabiola, Fátima, Gisela, Giselle, Graciela, Guadalupe, Ivana, Jazmín, Johana, Karina, Katherine, Leticia, Lourdes, Luna, Magali, Marcela, Maribel, Marisol, Mercedes, Mireya, Nadia, Noemí, Pamela, Priscila, Rosario, Sabrina, Selena, Silvana, Tamara, Vanesa, Yamila, Yesenia, Yuliana, Zulema, Alicia, Amparo, Angélica, Antonia, Belén, Berta, Blanca, Carla, Catalina, Clara, Consuelo, Diana, Elvira, Emma, Erika, Flor, Gloria, Inés, Irma, Isabel, Jimena, Josefina, Karla, Laura, Liliana, Lidia, Lola, Lorena, Mabel, Macarena, Maite, Malena, Martina, Milagros, Mónica, Nuria, Olga, Paloma, Patricia, Raquel, Rebeca, Renata, Rosa, Sandra, Silvia, Sol, Soledad, Susana, Tatiana, Teresa, Valeria, Verónica, Victoria, Violeta, Ximena, Yolanda, Zoe, Agustina, Aldana, Antonella, Araceli, Azul, Bianca, Camila, Carolina, Constanza, Delfina, Emilia, Florencia, Francisca, Gabriela, Jessica, Julieta, Luciana, Mariana, Mayra, Micaela, Natalia, Paula, Rocío, Romina, Salomé, Samanta, Sofía, Thiago, Vanina, Yanina'),
  pt: w('Adriele, Alana, Alessandra, Alícia, Aline, Amélia, Andressa, Angélica, Bianca, Bruna, Camila, Carla, Carolina, Cecília, Clara, Cláudia, Cristina, Daiane, Daniela, Débora, Denise, Elisa, Eloá, Emanuelle, Fernanda, Fabiana, Gabriela, Gisele, Giovana, Helena, Isabela, Isadora, Jaqueline, Joana, Juliana, Kauane, Larissa, Laura, Leila, Letícia, Lorena, Luana, Luciana, Luísa, Marcela, Mariana, Marina, Melissa, Michele, Mirella, Natália, Nicole, Patrícia, Paula, Rafaela, Raquel, Rebeca, Renata, Sabrina, Sara, Sofia, Tainá, Thaís, Valentina, Vanessa, Vitória, Yasmin, Alice, Amanda, Ana, Beatriz, Brenda, Carol, Emilly, Evelyn, Gabrielly, Heloísa, Jéssica, Kelly, Lavínia, Lívia, Manuela, Maria, Milena, Pietra, Priscila, Sophia, Stephanie, Talita, Viviane'),
  fr: w('Adèle, Alix, Amandine, Angèle, Anouk, Ariane, Aurélie, Axelle, Béatrice, Candice, Capucine, Carla, Cassandre, Célia, Charlotte, Chloé, Clémence, Coralie, Daphné, Eva, Fanny, Flore, Gabrielle, Inès, Jade, Jeanne, Juliette, Laetitia, Léna, Lila, Louise, Lucie, Maëlle, Margaux, Mélanie, Mélissa, Morgane, Naïs, Noémie, Océane, Ophélie, Pauline, Romane, Salomé, Sarah, Sixtine, Solène, Stella, Typhaine, Victoire, Zoé, Camille, Léa, Manon, Marine, Mathilde, Alice, Anaïs, Lola, Marion, Julie, Emma, Clara, Elodie'),
  de: w('Annika, Antonia, Carlotta, Charlotte, Clara, Emilia, Emma, Finja, Frieda, Greta, Hanna, Helena, Ida, Jana, Johanna, Jule, Katharina, Lara, Laura, Lea, Lena, Leonie, Lina, Lisa, Luisa, Marie, Mathilda, Maya, Merle, Mia, Mila, Nele, Nina, Paula, Pauline, Sarah, Sophie, Svenja, Thea, Theresa, Vanessa, Alina, Amelie, Anna, Carla, Elisa, Eva, Franziska, Isabell, Jasmin, Julia, Larissa, Michelle, Nadine, Romy, Sina, Stefanie, Tabea, Verena'),
  sv: w('Agnes, Alice, Alma, Amanda, Astrid, Cecilia, Ebba, Elin, Elsa, Emelie, Emma, Filippa, Freja, Frida, Hanna, Ida, Ingrid, Johanna, Josefin, Julia, Klara, Linnea, Lovisa, Maja, Matilda, Moa, Nora, Saga, Selma, Signe, Sofia, Stella, Tilda, Vera, Wilma, Alva, Annika, Camilla, Caroline, Charlotte, Elvira, Erika, Evelina, Felicia, Gabriella, Helena, Isabelle, Jessica, Karolina, Lisa, Louise, Madeleine, Malin, Mikaela, Natalie, Rebecka, Sandra, Sofie, Therese, Victoria, Tyra, Tora, Nellie, Livia, Siri, Edith, Greta, Hedvig, Ronja, Tuva'),
  en: w('Angelica, Jasmine, Kristine, Rhea, Marianne, Mikaela, Bea, Kathleen, Trisha, Camille, Nicole, Joanna, Patricia, Andrea, Janine, Sheena, Charmaine, Shaira, Aira, Czarina, Denise, Erika, Gwen, Kyla, Maureen, Nadine, Pia, Queenie, Rica, Samantha, Zara, Alyssa, Bianca, Hazel, Jocelyn, Mariel, Ara, Bernadette, Carmela, Dianne, Elaine, Faith, Grace, Hannah, Irish, Kimberly, Lorraine, Maricel, Nikki, Odette, Pauline, Rochelle, Shane, Thea, Venus, Wendy, Yvonne, Abby, Cherry, Daisy, Ella, Fatima, Hanna, Ivy, Joy, Kristel, Lyka, Mica, Nena, Precious, Shaina, Trina, Ysabel, Zia'),
};
// Prénoms féminins supplémentaires (réels), pour réduire les répétitions dans les gros groupes.
const MORE = {
  de: w('Aaliyah, Adelina, Alexandra, Alicia, Alissa, Amelia, Angelina, Anja, Annabell, Anne, Antonella, Bianca, Carolin, Celina, Chiara, Christina, Dana, Denise, Eileen, Elena, Elif, Ellen, Emely, Fabienne, Felicitas, Fiona, Gabriele, Hannah, Heidi, Isabel, Jacqueline, Jennifer, Jessica, Jolina, Josefine, Kaja, Karin, Katja, Kim, Klara, Lilly, Lotta, Louisa, Magdalena, Mareike, Marlene, Melina, Mirja, Nathalie, Nicole, Olivia, Pia, Rebecca, Sabine, Selina, Sonja, Tamara, Tessa, Ulrike, Vivien, Yasmin, Ayleen, Berit, Cosima, Dorothea, Elsa, Femke, Giulia, Henrike, Imke, Jette, Kira, Leni, Lilli, Mina, Nika, Ronja, Silja, Tina, Valerie, Wiebke'),
  sv: w('Adele, Alexandra, Alicia, Amelia, Annie, Beatrice, Bella, Bianca, Cornelia, Disa, Eleonora, Elise, Ellie, Embla, Emilia, Engla, Ester, Eva, Fanny, Gunilla, Hedda, Hilda, Hilma, Iris, Jennie, Jonna, Kajsa, Karin, Lea, Lilly, Linda, Majken, Mathilda, Mimmi, Mira, Molly, Nathalie, Nea, Olivia, Rut, Sally, Sara, Sigrid, Sonja, Svea, Tilde, Tove, Ulrika, Vilma, Ylva, Agneta, Birgitta, Cajsa, Dagny, Elina, Gerda, Helga, Inga, Johanna, Kerstin, Lotta, Margareta, Nilla, Pernilla, Sanna, Tina, Wendela, Yvonne, Åsa, Elsie, Märta'),
  pt: w('Abigail, Adélia, Ágatha, Alessa, Alinne, Allana, Anna, Antônia, Ariane, Aurora, Bárbara, Beatrice, Bia, Carine, Cássia, Catarina, Célia, Cíntia, Clarice, Cleo, Dandara, Dayane, Diana, Eduarda, Elaine, Eliane, Érica, Estela, Eva, Evelin, Fabíola, Flávia, Francisca, Gabrielle, Giovanna, Graciele, Heloisa, Ingrid, Iara, Íris, Isabelly, Isis, Jade, Janaína, Jordana, Joyce, Julia, Júlia, Karen, Karina, Kamila, Keila, Lais, Laís, Leandra, Lídia, Lilian, Lorraine, Lua, Luna, Magda, Maiara, Maísa, Mara, Márcia, Mel, Mônica, Nayara, Nina, Noemi, Pâmela, Priscilla, Rayane, Regina, Rita, Roberta, Rosa, Samara, Simone, Sônia, Stefany, Suelen, Tatiana, Tâmara, Thalita, Vera, Vivian, Yara, Yasmim'),
  fr: w('Adeline, Agathe, Albane, Alexia, Alicia, Amélie, Anaëlle, Andréa, Angelina, Annabelle, Apolline, Audrey, Aurore, Bérénice, Camélia, Carole, Cathy, Céline, Chiara, Claire, Clarisse, Colombe, Constance, Corinne, Cynthia, Dorine, Éléonore, Élisa, Émeline, Emmanuelle, Eugénie, Gaëlle, Héloïse, Hortense, Jessica, Joséphine, Julia, Justine, Karine, Laura, Laure, Léonie, Lilou, Lise, Lisa, Louna, Lucile, Madeleine, Maélys, Maeva, Margot, Marie, Marianne, Maud, Mia, Mila, Nadia, Nathalie, Nina, Noa, Olivia, Perrine, Rose, Roxane, Sabrina, Servane, Sidonie, Sofia, Sophie, Stéphanie, Suzanne, Sylvie, Tiphaine, Valentine, Vanessa, Violette, Zélie'),
};
for (const [k, v] of Object.entries(MORE)) EXTRA[k] = [...new Set([...EXTRA[k], ...v])];
// Prénoms portugais / brésiliens supplémentaires (réels).
EXTRA.pt = [...new Set([...EXTRA.pt, ...w('Aisha, Alanis, Alexia, Amabile, Amora, Analice, Aparecida, Ayla, Bella, Benedita, Bernadete, Betina, Brisa, Cacau, Camile, Cândida, Carmem, Cassiane, Cleide, Creusa, Dalila, Dalva, Dirce, Dora, Edna, Eleonora, Elis, Eliza, Elza, Emanuela, Emília, Esther, Fátima, Fabrícia, Flora, Franciele, Gal, Gláucia, Gleice, Hadassa, Hellen, Hortência, Inês, Iracema, Irene, Isaura, Ivete, Jacira, Jandira, Joice, Jussara, Karla, Kátia, Késia, Lara, Leda, Leonor, Lia, Lígia, Liliane, Lourdes, Lucélia, Lucimara, Luzia, Maitê, Marilene, Marta, Mayara, Meire, Mirian, Neide, Nádia, Nathália, Odete, Olga, Palmira, Poliana, Raissa, Rosângela, Ruth, Sandy, Selma, Sheila, Silvana, Solange, Tereza, Thaynara, Valdirene, Valéria, Vânia, Vilma, Zilda, Zuleica, Abgail, Adriana, Agnes, Alba, Alma, Amara, Ana Júlia, Anabela, Anelise, Antonela, Arlete, Aurélia, Bárbara, Bernarda, Brígida, Cacilda, Camélia, Carlota, Carminha, Cátia, Celeste, Celina, Cibele, Cinara, Clívia, Dália, Dayse, Diva, Domingas, Dulce, Eda, Eglantina, Elida, Elisabete, Elô, Eunice, Evani, Filomena, Francine, Gessica, Glória, Graça, Guiomar, Hilda, Ilda, Ilka, Iolanda, Irís, Isa, Jamile, Jane, Janete, Jenifer, Joelma, Judite, Kamilly, Kelen, Kiara, Lana, Lenita, Lilia, Lucinda, Lurdes, Madalena, Mafalda, Marcia, Margarida, Marly, Matilde, Mirela, Mylena, Nara, Natasha, Nelma, Nilce, Noeli, Norma, Ofélia, Ondina, Pérola, Rosana, Rosália, Rute, Sabina, Sueli, Teresinha, Ubiratana, Vanda, Verônica, Zélia')])];
// Prénoms espagnols / latino-américains supplémentaires (réels).
EXTRA.es = [...new Set([...EXTRA.es, ...w('Abril, Adriana, Aída, Ainara, Alba, Alejandra, Alexa, Alexia, Alina, Allison, Amaia, Amalia, Amanda, Amelia, Anahí, Andrea, Ángela, Angie, Ariadna, Ariana, Astrid, Aylín, Bea, Beatriz, Berenice, Betina, Brianna, Camelia, Candela, Carina, Carlota, Cassandra, Catherine, Celia, Cintia, Claudia, Clarisa, Cloe, Cristal, Dafne, Daiana, Dariana, Débora, Elba, Eleonora, Elisa, Elsa, Emily, Estela, Estrella, Eva, Fabiana, Federica, Fernanda, Fiorella, Francesca, Gala, Gema, Georgina, Gimena, Giuliana, Gladys, Helena, Ileana, Irene, Iris, Ivanna, Jacqueline, Jennifer, Jenny, Joana, Jordana, Josefa, Judith, Julia, Kiara, Laia, Larissa, Lía, Lilian, Lina, Lisandra, Lucero, Lucrecia, Luisa, Luz, Maia, Mailén, Manuela, Marcia, Margarita, Marina, Marta, Matilde, Mirta, Mora, Nahir, Naiara, Nancy, Natasha, Nelly, Nicole, Nina, Oriana, Penélope, Pía, Rafaela, Regina, Ruth, Samantha, Sasha, Serena, Sheyla, Shirley, Sonia, Stefanía, Tania, Tiziana, Trinidad, Uma, Úrsula, Vera, Viviana, Wendy, Xiomara, Yaneth, Yara, Yazmín, Zaira, Marlene, Rosalía, Abigaíl, Alma, Anabella, Analía, Bettina, Brenda, Carmela, Dulce, Eloísa, Fabiola, Gloria, Inmaculada, Jovana, Kimberly, Lupe, Maite, Nerea, Pilar, Rita, Selene, Tamara, Vilma, Zenaida')])];
const POOL_LANG = {
  Argentine: 'es', Colombie: 'es', Espagne: 'es', Mexique: 'es', 'Brésil': 'pt', Portugal: 'pt',
  France: 'fr', Belgique: 'fr', Suisse: 'de', Allemagne: 'de', 'Suède': 'sv', Philippines: 'en', Inde: 'en',
};

const fetchAll = async (cols, build) => {
  const out = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await build(db.from('profiles').select(cols)).order('id').range(from, from + 999);
    if (error) throw error;
    out.push(...data);
    if (data.length < 1000) break;
  }
  return out;
};
const slug = (name) => strip(String(name)).toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 24) || 'user';
const shuffle = (a) => { for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };

const ais = await fetchAll('id, display_name, country, gender, handle, city', (q) => q.eq('is_ai', true));
const allHandles = new Set((await fetchAll('id, handle', (q) => q)).map((r) => r.handle));
const groups = new Map();
for (const a of ais) { const k = `${a.country}|${a.gender}`; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(a); }

const plan = [];
const report = [];
for (const [key, accts] of [...groups].sort()) {
  const [country, gender] = key.split('|');
  const lang = POOL_LANG[country];
  if (ONLY.length && !ONLY.includes(country)) continue;
  // À renommer : les prénoms composés, et (avec --uniquify) les prénoms déjà portés par un autre compte du groupe.
  const seenNames = new Set();
  const dupLosers = UNIQ
    ? accts.filter((a) => {
        if (isCompound(a.display_name)) return false;
        const k = a.display_name.toLowerCase();
        if (seenNames.has(k)) return true;
        seenNames.add(k);
        return false;
      })
    : [];
  const compounds = [...accts.filter((a) => isCompound(a.display_name)), ...dupLosers];
  if (!compounds.length || !lang) continue;
  const renamable = new Set(compounds);
  const singles = accts.filter((a) => !renamable.has(a));
  // villes où chaque prénom est déjà porté
  const cities = new Map();
  const usedGlobal = new Set();
  const take = (name, city) => { usedGlobal.add(name.toLowerCase()); const k = name.toLowerCase(); if (!cities.has(k)) cities.set(k, new Set()); cities.get(k).add(city); };
  for (const a of singles) take(a.display_name, a.city);
  // Les prénoms ajoutés (EXTRA) sont féminins : pas pour les groupes d'hommes.
  const bases = new Set([...singles.map((a) => a.display_name), ...(gender === 'f' ? EXTRA[lang] : [])]);
  const pool = new Set();
  for (const b of bases) { if (isLatin(b) && !/[ -]/.test(b)) { pool.add(b); for (const v of variantsOf(b, lang)) pool.add(v); } }
  const poolList = [...pool];
  const free = shuffle(poolList.filter((n) => !usedGlobal.has(n.toLowerCase())));
  let unique = 0, reused = 0, kept = 0;
  for (const a of shuffle([...compounds])) {
    let name = free.shift();
    if (name) { unique++; }
    else {
      // Plus aucun prénom neuf : on reprend le moins porté, mais SEULEMENT s'il ne l'est pas déjà dans la même ville.
      const ok = poolList.filter((n) => !(cities.get(n.toLowerCase()) || new Set()).has(a.city));
      ok.sort((x, y) => (cities.get(x.toLowerCase())?.size || 0) - (cities.get(y.toLowerCase())?.size || 0) || Math.random() - 0.5);
      name = ok[0];
      if (name) reused++; else { kept++; continue; }
    }
    take(name, a.city);
    plan.push({ id: a.id, from: a.display_name, to: name, key, oldHandle: a.handle });
  }
  report.push({ groupe: key, composés: compounds.length, 'prénom neuf': unique, 'repris (autre ville)': reused, 'restent composés': kept, 'pool': pool.size });
}
// handles : même règle que l'app, uniques
for (const p of plan) {
  const hex = p.id.replace(/-/g, '');
  let h = `${slug(p.to)}-${hex.slice(-6)}`;
  for (let n = 8; allHandles.has(h) && h !== p.oldHandle && n <= 16; n += 2) h = `${slug(p.to)}-${hex.slice(-n)}`;
  allHandles.add(h);
  p.handle = h;
}

console.table(report);
console.log(`${plan.length} comptes passeraient d'un prénom composé à un prénom simple.`);
const samples = shuffle([...plan]).slice(0, 16).map((p) => `${p.from}  →  ${p.to}`);
console.log(samples.join('\n'));
writeFileSync(resolve(import.meta.dirname, '.singlify_plan.json'), JSON.stringify(plan));

if (APPLY) {
  // texte du personnage : le prénom en tête et dans tout le texte
  const personas = new Map();
  for (let from = 0; ; from += 1000) {
    const { data, error } = await db.from('ai_personas').select('user_id, persona').order('user_id').range(from, from + 999);
    if (error) throw error;
    for (const r of data) personas.set(r.user_id, r.persona);
    if (data.length < 1000) break;
  }
  let done = 0, personaDone = 0;
  for (let i = 0; i < plan.length; i += 20) {
    await Promise.all(plan.slice(i, i + 20).map(async (p) => {
      const { error } = await db.from('profiles').update({ display_name: p.to, handle: p.handle }).eq('id', p.id).eq('is_ai', true);
      if (error) { console.error('ERR', p.id, error.message); return; }
      done++;
      const text = personas.get(p.id);
      if (text && text.includes(p.from)) {
        const r = await db.from('ai_personas').update({ persona: text.replace(new RegExp('(?<![\\p{L}])' + p.from.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(?![\\p{L}])', 'gu'), p.to) }).eq('user_id', p.id);
        if (!r.error) personaDone++;
      }
    }));
  }
  console.log(`${done}/${plan.length} profils mis à jour (nom + handle), ${personaDone} textes de personnage mis à jour. Ancien état dans admin/scripts/.singlify_plan.json`);
}
