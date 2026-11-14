// What the water sprites say to each other and to the reader. A line is [speaker, words, mood]: the speaker is a
// place in the cast picked for the scene (0 speaks first), the mood chooses the voice clip that goes with the words.
export type TalkMood = "chat" | "hi" | "ask" | "yay" | "laugh" | "hmm" | "oh";
export type TalkLine = [number, string, TalkMood];

/** Small scenes for two sprites standing around. */
export const scenes: TalkLine[][] = [
  [[0, "Is the human still reading?", "ask"], [1, "I think so. Don't stare.", "chat"], [0, "Hi, human!", "hi"]],
  [[0, "Read the next bit!", "chat"], [1, "Don't be lazy. Scroll!", "yay"]],
  [[0, "Do you think they'll download it?", "ask"], [1, "Shh. Act natural.", "hmm"]],
  [[0, "Download the app!", "yay"], [1, "Say please.", "hmm"], [0, "Please download the app!", "yay"]],
  [[0, "Sponsor us!", "yay"], [1, "We run on snacks.", "chat"], [0, "And on water.", "laugh"]],
  [[0, "Star us on GitHub!", "yay"], [1, "It costs nothing.", "chat"], [0, "And we can see it from here.", "laugh"]],
  [[0, "I can do a flip.", "chat"], [1, "No you can't.", "laugh"], [0, "...no, I can't.", "hmm"]],
  [[0, "Who took my worktree?", "ask"], [1, "You have your own. Everyone does.", "chat"]],
  [[0, "I finished my task!", "yay"], [1, "Already? Show me the diff.", "ask"]],
  [[0, "What does this button do?", "ask"], [1, "Don't touch it.", "oh"]],
  [[0, "Are we on main?", "ask"], [1, "No. Our own branch. Relax.", "chat"]],
  [[0, "I'm waiting for the human.", "hmm"], [1, "Same. Classic.", "laugh"]],
  [[0, "Nice water today.", "chat"], [1, "It's a web page.", "hmm"], [0, "Still nice.", "yay"]],
  [[0, "Merge conflict!", "oh"], [1, "Not here. Never here.", "chat"]],
  [[0, "Sing with me!", "yay"], [1, "Only if you stop after.", "laugh"]],
  [[0, "Four of us, one window.", "chat"], [1, "And nobody steps on anybody.", "yay"]],
  [[0, "Did you hear that?", "ask"], [1, "That was a scroll wheel.", "chat"]],
  [[0, "I ran out of tokens once.", "hmm"], [1, "We don't talk about that.", "oh"]],
  [[0, "Join the Discord!", "yay"], [1, "We're friendly. Mostly.", "laugh"]],
  [[0, "Is it merged yet?", "ask"], [1, "Review first.", "hmm"], [0, "Fine.", "hmm"]],
  [[0, "How long have we been here?", "ask"], [1, "Since the page loaded.", "chat"], [0, "Feels longer.", "hmm"]],
  [[0, "Quit the app, we keep working.", "chat"], [1, "That's the whole point.", "yay"]],
  [[0, "Psst. Click one of us.", "chat"], [1, "Not me. Click that one.", "laugh"]],
  [[0, "You swim funny.", "laugh"], [1, "I swim fast.", "chat"]],
];
/** What each sprite says about itself, once, soon after the page opens. */
export const introductions: Record<string, [string, TalkMood]> = {
  aqua: ["I'm the guide. Follow me!", "hi"], claude: ["Claude Code here. Hello!", "hi"], codex: ["Codex. I type fast.", "chat"], shell: ["Just a shell. I run anything.", "hmm"],
};
/** One sprite, to the reader, about the part of the page on screen (the id of the section). */
export const places: Record<string, [string, TalkMood][]> = {
  agents: [["Any agent with a CLI gets in.", "chat"], ["That's us on the list!", "yay"]],
  features: [["This is the good part.", "yay"], ["Read this one. It's my favourite.", "chat"]],
  faq: [["Good questions here.", "chat"], ["I had that question too.", "hmm"]],
  community: [["Come say hi on Discord!", "hi"], ["Sponsor us! Please?", "ask"]],
  get: [["The button. It's right there.", "chat"], ["Download the app!", "yay"]],
};
/** The race when several sprites follow the reader. */
export const race = {
  behind: ["Hey, wait for me!", "Wait up!", "Not so fast!"], ahead: ["Too slow!", "Last one there is a bug!", "Keep up!"],
  first: ["First!", "I got here first!", "Beat you."], last: ["You cheated.", "I had further to swim.", "Second is fine."], rushed: ["Slow down, human!", "Whoa. Easy on the scroll."],
};
/** Answers to being pressed, to the reader going quiet and coming back, to the film opening and the lights changing. */
export const reactions = {
  pressed: ["Hey!", "That tickles.", "Hehe.", "Again!", "I'm working here."], nap: ["Nap time.", "Did they leave?"], back: ["You're back!", "Oh! Hello again."],
  film: ["Movie time!", "Shh. It's starting."], dark: ["Who turned off the lights?", "Cosy."], light: ["My eyes!", "Good morning."],
};
