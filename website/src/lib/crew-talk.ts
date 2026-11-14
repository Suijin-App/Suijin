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
  [[0, "Hey human. Yes, you.", "hi"], [1, "Leave them alone, they're reading.", "hmm"]],
  [[0, "Are they reading this bubble?", "ask"], [1, "They are now.", "laugh"]],
  [[0, "Blink if you can read this.", "chat"], [1, "They blinked!", "yay"], [0, "Everybody blinks.", "hmm"]],
  [[0, "Skimming doesn't count.", "hmm"], [1, "Read every word, human.", "chat"]],
  [[0, "Scroll down, there's more.", "chat"], [1, "We'll swim after you.", "yay"]],
  [[0, "My pane is bigger than yours.", "laugh"], [1, "Zoom is not a personality.", "hmm"]],
  [[0, "Ten panes in one tab.", "chat"], [1, "Who needs ten?", "ask"], [0, "You'd be surprised.", "laugh"]],
  [[0, "I opened a pull request.", "yay"], [1, "Did the checks pass?", "ask"], [0, "...I opened a pull request.", "hmm"]],
  [[0, "Somebody leave me a note on a line.", "ask"], [1, "Line 12: stop talking.", "laugh"]],
  [[0, "I need permission.", "ask"], [1, "For what?", "ask"], [0, "For everything. I'm in Ask mode.", "hmm"]],
  [[0, "Skip all permissions!", "yay"], [1, "That comes with a warning badge.", "hmm"]],
  [[0, "Who's the coordinator today?", "ask"], [1, "Me. Go fetch results.", "chat"], [0, "Yes boss.", "hmm"]],
  [[0, "Can I have another account?", "ask"], [1, "Ask Settings, not me.", "chat"]],
  [[0, "How much of the limit is left?", "ask"], [1, "It's in the status bar. Look down.", "chat"]],
  [[0, "The human closed the window!", "oh"], [1, "We keep running. Breathe.", "chat"]],
  [[0, "Native app. No Electron.", "yay"], [1, "You say that to everyone.", "laugh"]],
  [[0, "Nothing leaves this Mac.", "chat"], [1, "Not even me?", "ask"], [0, "Especially not you.", "laugh"]],
  [[0, "Open source, by the way.", "chat"], [1, "Apache 2.0. We checked.", "yay"]],
  [[0, "I'm hungry.", "hmm"], [1, "You're a drop of water.", "chat"], [0, "A hungry one.", "hmm"]],
  [[0, "Let's count the pixels on you.", "chat"], [1, "Please don't.", "oh"]],
  [[0, "Do I look round to you?", "ask"], [1, "You look twelve by fourteen.", "laugh"]],
  [[0, "Race you to the footer.", "yay"], [1, "The human decides where we go.", "hmm"]],
  [[0, "It's quiet.", "hmm"], [1, "Too quiet.", "hmm"], [0, "Turn the sound on, human!", "yay"]],
  [[0, "What's a Suijin?", "ask"], [1, "A water god. Be respectful.", "chat"], [0, "Oh. Hello, sir.", "oh"]],
  [[0, "I dreamt I was on main.", "hmm"], [1, "A nightmare.", "oh"]],
  [[0, "Rebase or merge?", "ask"], [1, "Not this again.", "oh"]],
  [[0, "Tabs or spaces?", "ask"], [1, "We are not doing this here.", "hmm"]],
  [[0, "Two minutes of film. Go watch.", "chat"], [1, "We're all in it.", "yay"]],
  [[0, "Tell your friends about us.", "chat"], [1, "Tell your enemies too.", "laugh"]],
  [[0, "Buy us a coffee?", "ask"], [1, "We're made of water.", "hmm"], [0, "Then a water.", "laugh"]],
  [[0, "One, two, three...", "chat"], [1, "Four. It's always four.", "hmm"]],
  [[0, "Roll call!", "yay"], [1, "Here.", "chat"], [2, "Here.", "chat"]],
  [[0, "Who's the fastest swimmer?", "ask"], [1, "Me.", "chat"], [2, "Me.", "chat"]],
  [[0, "Knock knock.", "chat"], [1, "Who's there?", "ask"], [0, "Merge.", "chat"], [1, "Merge who?", "ask"], [0, "Merge me already.", "laugh"]],
];
/** What a neighbour says when one of them sings, spars or takes a walk. */
export const audience = {
  sing: ["Encore!", "Nice voice.", "Every. Single. Time.", "That's my song!", "A little quieter?"],
  fight: ["Show-off.", "Who are you fighting?", "Nice kick!", "Careful, that's my edge.", "Sensei!"],
  pace: ["Going somewhere?", "Stretching your legs?", "You'll fall in."],
};
/** What each sprite says about itself, once, soon after the page opens. */
export const introductions: Record<string, [string, TalkMood]> = {
  aqua: ["I'm the guide. Follow me!", "hi"], claude: ["Claude Code here. Hello!", "hi"], codex: ["Codex. I type fast.", "chat"], shell: ["Just a shell. I run anything.", "hmm"],
};
/** One sprite, to the reader, about the part of the page on screen (the id of the section). */
export const places: Record<string, [string, TalkMood][]> = {
  agents: [["Any agent with a CLI gets in.", "chat"], ["That's us on the list!", "yay"], ["Find yours. I'll wait.", "chat"], ["Each of us in its own worktree.", "chat"]],
  features: [["This is the good part.", "yay"], ["Read this one. It's my favourite.", "chat"], ["Split it. Drag it. Zoom it.", "chat"], ["Review, commit, pull request. In one tab.", "yay"], ["Look at the pictures at least.", "hmm"]],
  faq: [["Good questions here.", "chat"], ["I had that question too.", "hmm"], ["Open one. They don't bite.", "chat"], ["The answer is usually yes.", "laugh"]],
  community: [["Come say hi on Discord!", "hi"], ["Sponsor us! Please?", "ask"], ["Star us on GitHub!", "yay"], ["Tell us what's missing.", "chat"]],
  get: [["The button. It's right there.", "chat"], ["Download the app!", "yay"], ["macOS 15 or later. You have that, right?", "ask"], ["Free. Open source. Go on.", "chat"]],
  // the other pages, by path
  "/releases": [["Fresh release notes!", "yay"], ["Read what changed. We worked hard.", "chat"], ["Newest at the top.", "chat"]],
  "/privacy": [["Short version: your code stays on your Mac.", "chat"], ["Nobody reads this page. You do. Respect.", "hi"], ["No account. No server of ours.", "chat"]],
  "/404": [["This page fell in the water.", "oh"], ["Nothing here. Swim back home?", "ask"], ["We looked. It's gone.", "hmm"]],
};
/** The race when several sprites follow the reader. */
export const race = {
  behind: ["Hey, wait for me!", "Wait up!", "Not so fast!", "My arms are short!", "Where are we going?", "I just got comfortable!"],
  ahead: ["Too slow!", "Last one there is a bug!", "Keep up!", "Swim faster!", "The human moved. Go go go!", "Follow the scroll!"],
  first: ["First!", "I got here first!", "Beat you.", "Saved you a spot. Not really.", "Easy."], last: ["You cheated.", "I had further to swim.", "Second is fine.", "I wasn't racing.", "Water in my eyes."],
  rushed: ["Slow down, human!", "Whoa. Easy on the scroll.", "Did you even read that?", "We can't swim that fast!"],
};
/** Answers to being pressed, to the reader going quiet and coming back, to the film opening and the lights changing. */
export const reactions = {
  pressed: ["Hey!", "That tickles.", "Hehe.", "Again!", "I'm working here.", "Boop.", "Do the others too.", "Okay, okay!", "You found me.", "Careful, I'm wet."],
  nap: ["Nap time.", "Did they leave?", "Wake me if they scroll.", "Five minutes."], back: ["You're back!", "Oh! Hello again.", "I wasn't sleeping.", "Where were we?"],
  film: ["Good film, right?", "We were great in that.", "Watch it again?"], dark: ["Who turned off the lights?", "Cosy.", "Night shift."], light: ["My eyes!", "Good morning.", "Too bright!"],
};
