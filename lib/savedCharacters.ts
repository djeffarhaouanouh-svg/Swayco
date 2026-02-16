import type { Character } from '@/data/worldData'

const STORAGE_KEY = 'savedCharacters'

export function getSavedCharacterIds(): number[] {
  if (typeof window === 'undefined') return []
  try {
    const stored = localStorage.getItem(STORAGE_KEY)
    const arr = stored ? JSON.parse(stored) : []
    return Array.isArray(arr) ? arr : []
  } catch {
    return []
  }
}

export function isCharacterSaved(id: number): boolean {
  return getSavedCharacterIds().includes(id)
}

export function saveCharacter(character: Character): void {
  if (typeof window === 'undefined') return
  const ids = getSavedCharacterIds()
  if (ids.includes(character.id)) return
  ids.push(character.id)
  localStorage.setItem(STORAGE_KEY, JSON.stringify(ids))

  const charsKey = 'savedCharactersData'
  const chars = getSavedCharactersData()
  if (!chars.some((c) => c.id === character.id)) {
    chars.push(character)
    localStorage.setItem(charsKey, JSON.stringify(chars))
  }
}

export function unsaveCharacter(id: number): void {
  if (typeof window === 'undefined') return
  const ids = getSavedCharacterIds().filter((i) => i !== id)
  localStorage.setItem(STORAGE_KEY, JSON.stringify(ids))

  const chars = getSavedCharactersData().filter((c) => c.id !== id)
  localStorage.setItem('savedCharactersData', JSON.stringify(chars))
}

export function toggleSavedCharacter(character: Character): boolean {
  const saved = isCharacterSaved(character.id)
  if (saved) {
    unsaveCharacter(character.id)
    return false
  }
  saveCharacter(character)
  return true
}

export function getSavedCharactersData(): Character[] {
  if (typeof window === 'undefined') return []
  try {
    const stored = localStorage.getItem('savedCharactersData')
    const arr = stored ? JSON.parse(stored) : []
    return Array.isArray(arr) ? arr : []
  } catch {
    return []
  }
}
