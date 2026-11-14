// The sounds the water sprites make, synthesised with Web Audio: no files to download. They are off until the
// visitor turns them on; the choice is remembered.
//
// These are the voices of the introduction film. Each sprite babbles in its own voice: a pulse wave at its home pitch
// through two formant bands that move from one vowel to another inside every syllable, so it speaks rather than beeps.
// Water is a round plop per sprite, pitched to it, with a little spray.
export type CrewSound = "splash" | "paddle" | "leap" | "land" | "shake" | "hop" | "pop" | "hi" | "note" | "punch" | "kick" | "cheer" | "step" | "peek" | "snore";
export type CrewVoice = "aqua" | "claude" | "codex" | "shell";

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
    master = context.createGain(); master.gain.value = 0.5; master.connect(context.destination);
    hiss = context.createBuffer(1, context.sampleRate, context.sampleRate);
    const samples = hiss.getChannelData(0);
    for (let index = 0; index < samples.length; index++) samples[index] = Math.random() * 2 - 1;
  }
  if (context.state === "suspended") void context.resume();
  return context.state === "running" ? context : null;
}

// ── the four voices: home pitch (MIDI), pulse width, how much of a syllable's time is sounded, how far the pitch
//    wanders, the vowels it favours, how bright it is, how much of the plain tone is mixed in, and its plop in the water
const vowels: Record<string, [number, number]> = { a: [800, 1250], i: [320, 2300], u: [360, 800], e: [520, 1900], o: [520, 950] };
const talkers: Record<CrewVoice, { base: number; duty: number; length: number; range: number; vowels: string; bright: number; dry: number; plop: number }> = {
  aqua: { base: 74, duty: 0.4, length: 0.8, range: 1, vowels: "ouaoe", bright: 6000, dry: 0.5, plop: 430 },       // the guide: clear, friendly, round
  claude: { base: 66, duty: 0.5, length: 0.92, range: 0.8, vowels: "aoeau", bright: 2800, dry: 0.55, plop: 365 },  // warm, lower, calm
  codex: { base: 81, duty: 0.25, length: 0.6, range: 1, vowels: "ieaie", bright: 7000, dry: 0.6, plop: 500 },      // bright, quick, crisp
  shell: { base: 61, duty: 0.125, length: 0.7, range: 0.35, vowels: "uouo", bright: 3500, dry: 1, plop: 305 },     // lowest, dry, terse
};
const scale: number[] = [];                                       // D major, the key of the film
for (let midi = 24; midi < 109; midi++) if ([1, 2, 4, 6, 7, 9, 11].includes(midi % 12)) scale.push(midi);
const stepFrom = (midi: number, steps: number): number => {
  let nearest = 0;
  scale.forEach((note, index) => { if (Math.abs(note - midi) < Math.abs(scale[nearest] - midi)) nearest = index; });
  return scale[Math.min(scale.length - 1, Math.max(0, nearest + Math.round(steps)))];
};
const hertz = (midi: number): number => 440 * 2 ** ((midi - 69) / 12);
const pick = (count: number): number => Math.floor(Math.random() * count);

const waves = new Map<number, PeriodicWave>();
function pulse(audio: AudioContext, duty: number): PeriodicWave {
  let wave = waves.get(duty);
  if (!wave) {
    const real = new Float32Array(31), imaginary = new Float32Array(31);
    for (let k = 1; k < 31; k++) real[k] = Math.sin(Math.PI * k * duty) / k;
    wave = audio.createPeriodicWave(real, imaginary); waves.set(duty, wave);
  }
  return wave;
}

// One syllable: `glide` semitones of pitch movement inside it, from vowel `first` to vowel `second`.
function syllable(audio: AudioContext, voice: CrewVoice, midi: number, time: number, glide: number, volume: number, after: number, vibrato = false, vowel?: string): void {
  const who = talkers[voice], start = audio.currentTime + after, end = start + time, pitch = hertz(midi);
  const carrier = audio.createOscillator(), out = audio.createGain(), bright = audio.createBiquadFilter();
  carrier.setPeriodicWave(pulse(audio, who.duty));
  // a scoop up into the note, then the glide
  carrier.frequency.setValueAtTime(pitch * 2 ** (-1.5 / 12), start);
  carrier.frequency.exponentialRampToValueAtTime(pitch, start + Math.min(0.03, time * 0.3));
  carrier.frequency.linearRampToValueAtTime(pitch * 2 ** (glide / 12), end);
  if (vibrato) {
    const wobble = audio.createOscillator(), depth = audio.createGain();
    wobble.frequency.value = 5.5; depth.gain.setValueAtTime(0, start); depth.gain.linearRampToValueAtTime(pitch * 0.016, start + 0.1);
    wobble.connect(depth); depth.connect(carrier.frequency); wobble.start(start); wobble.stop(end + 0.02);
  }
  const first = vowels[vowel ?? who.vowels[pick(who.vowels.length)]], second = vowels[vowel ?? (voice === "shell" ? "u" : who.vowels[pick(who.vowels.length)])];
  [0, 1].forEach((band) => {
    const formant = audio.createBiquadFilter(), level = audio.createGain();
    formant.type = "bandpass"; formant.Q.value = band ? 3.1 : 2.3; level.gain.value = band ? 1.4 : 2;
    formant.frequency.setValueAtTime(first[band], start + time * 0.25); formant.frequency.linearRampToValueAtTime(second[band], start + time * 0.75);
    carrier.connect(formant); formant.connect(level); level.connect(bright);
  });
  const body = audio.createBiquadFilter(), plain = audio.createGain();          // the low-passed carrier keeps the pitch its fundamental
  body.type = "lowpass"; body.frequency.value = pitch * 1.5; plain.gain.value = who.dry;
  carrier.connect(body); body.connect(plain); plain.connect(bright);
  bright.type = "lowpass"; bright.frequency.value = who.bright;
  out.gain.setValueAtTime(0.0001, start); out.gain.linearRampToValueAtTime(volume, start + 0.008);
  out.gain.setValueAtTime(volume, end - Math.min(0.04, time * 0.35)); out.gain.linearRampToValueAtTime(0.0001, end);
  bright.connect(out); out.connect(master!);
  carrier.start(start); carrier.stop(end + 0.02);
}
// A few syllables with the melody of a mood: a greeting rises at the end, a cheer climbs, a question lifts, a snore sinks.
type Mood = "hi" | "yay" | "ask" | "sleepy" | "chat";
function say(audio: AudioContext, voice: CrewVoice, mood: Mood, count: number, time: number, volume = 0.3): void {
  const who = talkers[voice], each = time / count;
  for (let k = 0; k < count; k++) {
    let step = pick(5) - 2, glide = 0;
    if (mood === "hi") step = k === count - 1 ? 2 : 0;
    else if (mood === "yay") { step = count > 1 ? Math.round((4 * k) / (count - 1)) : 4; if (k === count - 1) glide = 1; }
    else if (mood === "ask") { step = k === count - 1 ? 2 : pick(3) - 1; if (k === count - 1) glide = 4; }
    else if (mood === "sleepy") { step = 1 - k; glide = -3.5; }
    const sounded = Math.max(0.04, each * (mood === "sleepy" ? 0.95 : who.length));
    syllable(audio, voice, stepFrom(who.base, Math.abs(step) > 1 ? step * who.range : step), sounded, glide * Math.sqrt(who.range), volume, k * each, mood === "yay" && sounded > 0.12);
  }
}

// ── water and the body
function envelope(audio: AudioContext, volume: number, decay: number, time: number, after: number): GainNode {
  const gain = audio.createGain(), start = audio.currentTime + after;
  gain.gain.setValueAtTime(0.0001, start); gain.gain.linearRampToValueAtTime(volume, start + 0.004);
  gain.gain.setTargetAtTime(0.0001, start + 0.004, decay);
  gain.connect(master!);
  void time;
  return gain;
}
function sine(audio: AudioContext, shape: (frequency: AudioParam, start: number) => void, time: number, volume: number, decay: number, after = 0): void {
  const voice = audio.createOscillator(), start = audio.currentTime + after;
  shape(voice.frequency, start);
  voice.connect(envelope(audio, volume, decay, time, after)); voice.start(start); voice.stop(start + time);
}
function spray(audio: AudioContext, low: number, high: number, time: number, volume: number, decay: number, after = 0): void {
  const source = audio.createBufferSource(), band = audio.createBiquadFilter(), start = audio.currentTime + after;
  source.buffer = hiss; band.type = "bandpass"; band.frequency.value = Math.sqrt(low * high); band.Q.value = Math.sqrt(low * high) / (high - low);
  source.connect(band); band.connect(envelope(audio, volume, decay, time, after));
  source.start(start, Math.random() * 0.5); source.stop(start + time);
}
// bright droplets scattered over a short while
function plinks(audio: AudioContext, count: number, low: number, high: number, over: number, volume: number): void {
  for (let drop = 0; drop < count; drop++) {
    const pitch = low + Math.random() * (high - low), after = Math.random() * over * 0.8;
    sine(audio, (frequency, start) => { frequency.setValueAtTime(pitch * 1.2, start); frequency.exponentialRampToValueAtTime(pitch, start + 0.02); }, 0.09, volume * (0.4 + Math.random() * 0.6) * (1 - after / over), 0.02, after);
  }
}
// A round plop: the pitch drops in, then a bubble closes upward; a little spray after it.
function plop(audio: AudioContext, pitch: number, small: boolean): void {
  const time = small ? 0.3 : 0.45;
  sine(audio, (frequency, start) => { frequency.setValueAtTime(pitch * 1.7, start); frequency.exponentialRampToValueAtTime(pitch, start + 0.025); frequency.linearRampToValueAtTime(pitch * (small ? 1.55 : 1.4), start + 0.13); }, time, 0.5, small ? 0.045 : 0.075);
  if (!small) sine(audio, (frequency, start) => frequency.setValueAtTime(pitch / 2, start), time, 0.22, 0.06);
  spray(audio, 2200, 7500, time, small ? 0.1 : 0.08, small ? 0.07 : 0.11, 0.01);
  plinks(audio, small ? 5 : 4, 1800, small ? 4200 : 3200, time, 0.12);
}

function smack(audio: AudioContext, after: number): void {
  sine(audio, (frequency, start) => { frequency.setValueAtTime(210, start); frequency.exponentialRampToValueAtTime(85, start + 0.05); }, 0.09, 0.3, 0.02, after);
  spray(audio, 1800, 6000, 0.03, 0.1, 0.006, after);
}

const strokes: Record<string, number> = {};
const song = [0, 2, 4, 2, 5, 4, 2, 1];                            // what a sprite sings, in steps of the scale above its home pitch

/** Plays one sound in the voice of a sprite. `step` picks the note of a song. */
export function crewSound(name: CrewSound, voice: CrewVoice = "aqua", step = 0): void {
  if (!on) return;
  const audio = ready();
  if (!audio) return;
  const who = talkers[voice];
  switch (name) {
    case "splash": plop(audio, who.plop, false); break;
    case "paddle": {                                              // a tiny dab of water; two pitches in turn, left hand, right hand
      const turn = (strokes[voice] = (strokes[voice] ?? 0) + 1), pitch = who.plop * 1.5 * (turn % 2 ? 1.12 : 1);
      sine(audio, (frequency, start) => { frequency.setValueAtTime(pitch, start); frequency.linearRampToValueAtTime(pitch * 1.25, start + 0.05); }, 0.09, 0.16, 0.022);
      spray(audio, 350, 2400, 0.26, 0.07, 0.07);                    // the water the arm pushes back
      plinks(audio, 2, 600, 1400, 0.2, 0.07);                     // and the bubbles it leaves
      break;
    }
    case "leap": syllable(audio, voice, stepFrom(who.base, 1), 0.15, 5, 0.26, 0); plop(audio, who.plop * 1.7, true); break;
    case "land": sine(audio, (frequency, start) => { frequency.setValueAtTime(110, start); frequency.exponentialRampToValueAtTime(62, start + 0.12); }, 0.2, 0.3, 0.05); spray(audio, 300, 1500, 0.06, 0.05, 0.012); break;
    case "shake": for (let flick = 0; flick < 9; flick++) spray(audio, 3000, 9000, 0.05, 0.035 * (1 - flick / 12), 0.012, flick * 0.05); plinks(audio, 8, 2200, 4800, 0.5, 0.1); break;
    case "hop": syllable(audio, voice, stepFrom(who.base, 2), 0.09, 2, 0.22, 0); break;
    case "pop": plinks(audio, 2, 2400, 3800, 0.08, 0.2); break;
    case "hi": say(audio, voice, "hi", 2, 0.3); break;
    case "note": syllable(audio, voice, stepFrom(who.base, song[step % song.length]), 0.27, 0, 0.26, 0, true, step % 2 ? "o" : "a"); break;
    // a blow is the air it moves, the shout that goes with it, and a dry smack at the end of the reach
    case "punch": spray(audio, 500, 2400, 0.09, 0.07, 0.025); smack(audio, 0.06); syllable(audio, voice, stepFrom(who.base, 3), 0.09, -3, 0.26, 0, false, "a"); break;
    case "kick": spray(audio, 300, 1600, 0.13, 0.09, 0.035); smack(audio, 0.09); syllable(audio, voice, stepFrom(who.base, 4), 0.13, -4, 0.28, 0, false, "a"); break;
    case "cheer": say(audio, voice, "yay", 3, 0.48); break;
    case "step": sine(audio, (frequency, start) => frequency.setValueAtTime(hertz(who.base) / 2, start), 0.04, 0.06, 0.008); spray(audio, 1500, 6000, 0.02, 0.012, 0.005); break;
    case "peek": say(audio, voice, "ask", 2, 0.3, 0.24); break;
    case "snore": say(audio, voice, "sleepy", 2, 0.9, 0.1); break;
  }
}
