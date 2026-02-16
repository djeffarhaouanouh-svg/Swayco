import { characters as worldCharacters } from '@/data/worldData';

export function getStaticCharacterById(id: number) {
  const c = worldCharacters.find(ch => ch.id === id);
  if (!c) return null;
  return {
    id: c.id,
    name: c.name,
    location: c.location,
    image: c.image,
    description: c.description,
    cityImage: c.cityImage,
  };
}
