// The sounds the water sprites make, synthesised with Web Audio: no files to download. They are off until the
// visitor turns them on; the choice is remembered. Square and triangle waves for the sprites (they are pixels, so
// they sound like an old console) and filtered noise for the water.
export type CrewSound = "splash" | "paddle" | "leap" | "land" | "hop" | "pop" | "note" | "punch" | "kick" | "cheer" | "step" | "peek" | "snore";

const KEY = "crew-sound";
let context: AudioContext | null = null, master: GainNode | null = null, hiss: AudioBuffer | null = null, on = false;

export const soundOn = (): boolean => on;
/** Whether sound was left on at the last visit. It can only start after a press or a key: browsers require that. */
export const soundWanted = (): boolean => { try { return localStorage.getItem(KEY) === "1"; } catch { return false; } };
export function setSound(next: boolean): void {
  on = next;
  try { localStorage.setItem(KEY, next ? "1" : "0"); } catch { /* private mode: the choice lasts for this page only */ }
  if (on) ready();
}

function ready(): AudioContext | null {
  if (!context) {
    const Audio = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Audio) return null;
    context = new Audio();
    master = context.createGain(); master.gain.value = 0.32; master.connect(context.destination);
    hiss = context.createBuffer(1, context.sampleRate, context.sampleRate);
    const samples = hiss.getChannelData(0);
    for (let index = 0; index < samples.length; index++) samples[index] = Math.random() * 2 - 1;
  }
  if (context.state === "suspended") void context.resume();
  return context.state === "running" ? context : null;
}

// A voice that fades out: attack in a few milliseconds, then an exponential decay over `time` seconds.
function fade(audio: AudioContext, volume: number, time: number, after: number): GainNode {
  const gain = audio.createGain(), start = audio.currentTime + after;
  gain.gain.setValueAtTime(0.0001, start);
  gain.gain.exponentialRampToValueAtTime(volume, start + 0.006);
  gain.gain.exponentialRampToValueAtTime(0.0001, start + time);
  gain.connect(master!);
  return gain;
}
// A note that slides from one pitch to another.
function tone(audio: AudioContext, wave: OscillatorType, from: number, to: number, time: number, volume: number, after = 0): void {
  const voice = audio.createOscillator(), start = audio.currentTime + after;
  voice.type = wave; voice.frequency.setValueAtTime(from, start); voice.frequency.exponentialRampToValueAtTime(to, start + time);
  voice.connect(fade(audio, volume, time, after)); voice.start(start); voice.stop(start + time + 0.02);
}
// A burst of noise through a filter whose frequency sweeps: water, and the air a punch moves.
function rush(audio: AudioContext, kind: BiquadFilterType, from: number, to: number, time: number, volume: number, after = 0): void {
  const source = audio.createBufferSource(), filter = audio.createBiquadFilter(), start = audio.currentTime + after;
  source.buffer = hiss; filter.type = kind; filter.Q.value = 0.9;
  filter.frequency.setValueAtTime(from, start); filter.frequency.exponentialRampToValueAtTime(to, start + time);
  source.connect(filter); filter.connect(fade(audio, volume, time, after));
  source.start(start, Math.random() * 0.5); source.stop(start + time + 0.02);
}

const tune = [523, 659, 784, 659, 880, 784, 659, 587];           // what a sprite sings: C E G E A G E D

/** Plays one sound. `pitch` is the sprite's own voice (1 is the guide's); `step` picks the note of a song. */
export function crewSound(name: CrewSound, pitch = 1, step = 0): void {
  if (!on) return;
  const audio = ready();
  if (!audio) return;
  switch (name) {
    case "splash": rush(audio, "bandpass", 1900, 420, 0.38, 0.5); rush(audio, "highpass", 3200, 5200, 0.2, 0.22); tone(audio, "sine", 280, 80, 0.2, 0.3); break;
    case "paddle": rush(audio, "bandpass", 700, 1500, 0.15, 0.14); tone(audio, "sine", 380, 620, 0.07, 0.05, 0.05); break;
    case "leap": tone(audio, "square", 300 * pitch, 900 * pitch, 0.17, 0.09); break;
    case "land": tone(audio, "sine", 170, 64, 0.13, 0.4); rush(audio, "lowpass", 900, 300, 0.06, 0.12); break;
    case "hop": tone(audio, "square", 520 * pitch, 800 * pitch, 0.08, 0.07); break;
    case "pop": tone(audio, "triangle", 880 * pitch, 1320 * pitch, 0.08, 0.12); break;
    case "note": { const key = tune[step % tune.length] * pitch; tone(audio, "square", key, key, 0.24, 0.07); tone(audio, "triangle", key / 2, key / 2, 0.24, 0.1); break; }
    case "punch": rush(audio, "bandpass", 1400, 320, 0.08, 0.3); tone(audio, "square", 230 * pitch, 110 * pitch, 0.06, 0.08); break;
    case "kick": rush(audio, "bandpass", 900, 200, 0.12, 0.34); tone(audio, "sine", 170, 60, 0.11, 0.3); break;
    case "cheer": [659, 784, 1047].forEach((key, index) => tone(audio, "square", key * pitch, key * pitch, 0.14, 0.07, index * 0.085)); break;
    case "step": tone(audio, "square", 190 * pitch, 140 * pitch, 0.03, 0.04); break;
    case "peek": tone(audio, "triangle", 600 * pitch, 920 * pitch, 0.1, 0.1); break;
    case "snore": tone(audio, "sine", 120 * pitch, 84 * pitch, 0.55, 0.1); break;
  }
}
