// The sounds the water sprites make. They are off until the visitor turns them on (the choice is remembered), and
// nothing is downloaded before that.
//
// The sounds are those of the introduction film, rendered by the film's own sound code into one small file of clips
// laid end to end (public/crew-sounds.mp3); crew-sounds.json says where each clip starts and how long it is. Each
// sprite has its own voice, its own plop in the water and its own song.
import clips from "./crew-sounds.json";

export type CrewSound = "splash" | "paddle" | "leap" | "land" | "shake" | "hop" | "pop" | "hi" | "note" | "punch" | "kick" | "cheer" | "step" | "peek" | "snore";
export type CrewVoice = "aqua" | "claude" | "codex" | "shell";

const KEY = "crew-sound", where = clips as Record<string, number[]>;
let context: AudioContext | null = null, master: GainNode | null = null, tape: AudioBuffer | null = null, loading = false, on = false;

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
    master = context.createGain(); master.gain.value = 0.55; master.connect(context.destination);
  }
  if (!tape && !loading) {
    loading = true;
    const audio = context;
    fetch("/crew-sounds.mp3").then((answer) => answer.arrayBuffer()).then((bytes) => audio.decodeAudioData(bytes)).then((buffer) => { tape = buffer; }).catch(() => { loading = false; });
  }
  if (context.state === "suspended") void context.resume();
  return context.state === "running" && tape ? context : null;
}

// One clip off the tape, at a volume, a little later if asked, faster or slower to raise or lower it.
function clip(audio: AudioContext, name: string, volume = 1, after = 0, rate = 1): void {
  const place = where[name];
  if (!place || !tape) return;
  const source = audio.createBufferSource(), level = audio.createGain();
  source.buffer = tape; source.playbackRate.value = rate; level.gain.value = volume;
  source.connect(level); level.connect(master!);
  source.start(audio.currentTime + after, place[0], place[1] + 0.03);   // the tail of silence allows for the encoder's delay
}

const strokes: Record<string, number> = {};
const snores: Record<CrewVoice, number> = { aqua: 1.12, claude: 0.94, codex: 1.26, shell: 0.82 };

/** Plays one sound in the voice of a sprite. `step` picks the note of a song. */
export function crewSound(name: CrewSound, voice: CrewVoice = "aqua", step = 0): void {
  if (!on) return;
  const audio = ready();
  if (!audio) return;
  switch (name) {
    case "splash": clip(audio, `${voice}.splash`); break;
    case "paddle": clip(audio, `${voice}.paddle${(strokes[voice] = (strokes[voice] ?? 0) + 1) % 2}`); break;
    case "leap": clip(audio, `${voice}.out`); clip(audio, `${voice}.oh`, 0.8, 0.04); break;
    case "land": clip(audio, `${voice}.land`); break;
    case "shake": clip(audio, `${voice}.shake`, 1, 0.1); break;
    case "hop": clip(audio, `${voice}.jump`, 0.7); break;
    case "pop": clip(audio, `${voice}.paddle1`, 0.8, 0, 1.6); break;
    case "hi": clip(audio, `${voice}.hi`); break;
    case "note": clip(audio, `${voice}.note${step % 8}`); break;
    case "punch": clip(audio, `${voice}.punch`); break;
    case "kick": clip(audio, `${voice}.kick`); break;
    case "cheer": clip(audio, `${voice}.yay`); break;
    case "step": clip(audio, `${voice}.land`, 0.3, 0, 1.5); break;
    case "peek": clip(audio, `${voice}.ask`, 0.9); break;
    case "snore": clip(audio, "snore", 1, 0, snores[voice]); break;
  }
}
