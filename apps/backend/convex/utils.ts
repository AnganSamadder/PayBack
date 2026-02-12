// Hex codes matching SwiftUI system colors
export const AVATAR_COLORS = [
  "#007AFF", // Blue
  "#34C759", // Green
  "#FF9500", // Orange
  "#AF52DE", // Purple
  "#FF2D55", // Pink
  "#FF3B30", // Red
  "#5856D6", // Indigo
  "#30B0C7", // Teal
  "#32ADE6", // Cyan
  "#00C7BE" // Mint
];

export function getRandomAvatarColor(): string {
  const index = Math.floor(Math.random() * AVATAR_COLORS.length);
  return AVATAR_COLORS[index];
}
