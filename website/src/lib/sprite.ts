// The Suijin water sprite: a pixel droplet on a 12 x 14 grid, the same character as in the introduction film and
// the app's welcome tour. `spritePixels` turns a pose into the SVG rectangles of one sprite.
export type SpriteColor = "aqua" | "claude" | "codex" | "shell";
export type SpriteEyes = "n" | "l" | "r" | "u" | "d" | "wide" | "happy" | "shut" | "blink" | "sleepy" | "star";
export type SpriteMouth = "none" | "open" | "o" | "smile";
export type SpriteArms = "down" | "up" | "wave";
export type SpriteLegs = "stand" | "tuck";
export interface SpritePose { eyes?: SpriteEyes; mouth?: SpriteMouth; arms?: SpriteArms; legs?: SpriteLegs; blush?: boolean }

export const SPRITE_SIZE = { width: 12, height: 14 };
// body, shade, highlight, eye, blush: aqua is the guide, coral Claude Code, indigo Codex, green the shell.
const palette: Record<SpriteColor, string[]> = {
  aqua: ["#19B8D8", "#0F8FB5", "#DDF8FF", "#0A2B40", "#F7A8CC"],
  claude: ["#EE7B5C", "#C9583D", "#FFE7DD", "#3D1A10", "#FFC0CB"],
  codex: ["#7A6BF2", "#584AC9", "#E8E4FF", "#17113F", "#E9A6F2"],
  shell: ["#22B585", "#168A66", "#DBFAEE", "#062F25", "#F8BDB8"],
};
// Body rows 0..11 as [first column, last column]; the tip curls to the right.
const body = [[6, 6], [5, 6], [5, 6], [4, 7], [3, 8], [2, 9], [1, 10], [1, 10], [1, 10], [1, 10], [2, 9], [3, 8]];
const eyes: Record<SpriteEyes, number[][]> = {
  n: [[3, 7], [3, 8], [8, 7], [8, 8]], l: [[2, 7], [2, 8], [7, 7], [7, 8]], r: [[4, 7], [4, 8], [9, 7], [9, 8]],
  u: [[3, 6], [3, 7], [8, 6], [8, 7]], d: [[3, 8], [3, 9], [8, 8], [8, 9]],
  wide: [[3, 6], [3, 7], [3, 8], [8, 6], [8, 7], [8, 8]],
  happy: [[2, 8], [3, 7], [4, 8], [7, 8], [8, 7], [9, 8]],
  shut: [[2, 8], [3, 8], [4, 8], [7, 8], [8, 8], [9, 8]],
  blink: [[3, 8], [8, 8]],
  sleepy: [[2, 7], [3, 7], [4, 7], [3, 8], [7, 7], [8, 7], [9, 7], [8, 8]],
  // big eyes, each with a sparkle (the third number marks a highlight pixel)
  star: [[3, 7], [4, 7], [3, 8], [4, 8], [7, 7], [8, 7], [7, 8], [8, 8], [3, 7, 1], [7, 7, 1]],
};
const mouth: Record<SpriteMouth, number[][]> = {
  none: [], open: [[5, 9], [6, 9], [5, 10], [6, 10]], o: [[5, 10], [6, 10]], smile: [[4, 9], [7, 9], [5, 10], [6, 10]],
};
const legs: Record<SpriteLegs, number[][]> = {
  stand: [[4, 12], [3, 13], [4, 13], [7, 12], [7, 13], [8, 13]], tuck: [[3, 12], [4, 12], [7, 12], [8, 12]],
};
const arms: Record<SpriteArms, number[][]> = {
  down: [], up: [[0, 7], [0, 6], [0, 5], [11, 7], [11, 6], [11, 5]], wave: [[11, 7], [11, 6], [11, 5]],
};

/** The rectangles of one sprite in the given pose, for an `<svg viewBox="0 0 12 14" shape-rendering="crispEdges">`. */
export function spritePixels(color: SpriteColor, pose: SpritePose = {}): string {
  const [bodyFill, shade, highlight, eye, blush] = palette[color];
  const cells = new Map<string, string>();
  const put = (column: number, row: number, fill: string) => cells.set(`${column},${row}`, fill);
  body.forEach(([first, last], row) => { for (let column = first; column <= last; column++) put(column, row, row === 11 ? shade : bodyFill); });
  put(9, 10, shade); put(10, 9, shade);
  put(3, 5, highlight);
  for (const [column, row] of arms[pose.arms ?? "down"]) put(column, row, bodyFill);
  for (const [column, row] of legs[pose.legs ?? "stand"]) put(column, row, row === 13 ? shade : bodyFill);
  if (pose.blush) { put(2, 9, blush); put(9, 9, blush); }
  for (const [column, row] of mouth[pose.mouth ?? "none"]) put(column, row, eye);
  for (const [column, row, sparkle] of eyes[pose.eyes ?? "n"]) put(column, row, sparkle ? highlight : eye);
  let rects = "";
  for (const [key, fill] of cells) { const [column, row] = key.split(","); rects += `<rect x="${column}" y="${row}" width="1.03" height="1.03" fill="${fill}"/>`; }
  return rects;
}
