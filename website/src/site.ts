// Facts the pages share. Keep every sentence true to the app: the README, CHANGELOG.md and the privacy text in
// App/Features/Settings/LegalDocuments.swift are the sources.
export const site = {
  name: "Suijin",
  url: "https://suijin.app",
  tagline: "Many agents, one calm window.",
  description:
    "Suijin is a native macOS app that runs Claude Code, Codex and any other AI coding agent side by side, each in its own git worktree.",
  repository: "https://github.com/Suijin-App/Suijin",
  repositoryName: "Suijin-App/Suijin",
  releases: "https://github.com/Suijin-App/Suijin/releases",
  discord: "https://discord.gg/sFEhaWAMvq",
  changelog: "https://github.com/Suijin-App/Suijin/blob/main/CHANGELOG.md",
  publisher: "Tekmium Solutions",
  license: "Apache-2.0",
  licenseUrl: "https://github.com/Suijin-App/Suijin/blob/main/LICENSE",
  minimumSystem: "macOS 15",
  // Set to the version string once the first release is published; the download wording follows it.
  releasedVersion: null as string | null,
  // The site token of Cloudflare Web Analytics (dashboard: Analytics & Logs, Web Analytics). Empty turns it off.
  analyticsToken: "",
};

export const faq = [
  {
    question: "What is Suijin?",
    answer:
      "Suijin is a native macOS app for running several AI coding agents at the same time. Each agent works in a git worktree of its own, so their changes never collide, and you review, commit and open pull requests for what they did from the same window.",
  },
  {
    question: "Which AI coding agents does Suijin work with?",
    answer:
      "Claude Code and Codex are built in: Suijin shows their status, manages their accounts and permission modes, and lets them hand work to each other. Any other agent that runs in a terminal, such as Gemini CLI, Aider or OpenCode, runs in a shell tab or pane next to them, with its own worktree and a place in split layouts, but without those extra features.",
  },
  {
    question: "Does my code leave my Mac?",
    answer:
      "Not through Suijin. The app has no account and no server that sees your code or conversations. The agents you run talk to their own providers, exactly as they do in any terminal.",
  },
  {
    question: "Why does each agent get its own git worktree?",
    answer:
      "A worktree is a separate folder checked out on its own branch of the same repository. Giving every agent one means two agents can edit the same project at once without overwriting each other, and each branch can be reviewed and merged on its own.",
  },
  {
    question: "Do my agents keep running when I quit Suijin?",
    answer:
      "Yes, by default. Sessions run in a background helper, so closing or updating Suijin does not stop them, and they are there when you open the app again. Closing a tab ends its session.",
  },
  {
    question: "Can I use more than one Claude or Codex account?",
    answer:
      "Yes. You can add several managed accounts per agent, choose which one a session uses, and let Suijin move a session to the next account with room when one hits its usage limit. Your own existing logins are never changed.",
  },
  {
    question: "What does Suijin send over the network?",
    answer:
      "About once a day it asks suijin.app whether a newer version exists; that request carries only the app's name and version, and is counted per day and version with nothing about you kept. To show usage limits it asks Anthropic or OpenAI with your own login. Everything else is the agents and tools you run yourself.",
  },
  {
    question: "Is Suijin open source?",
    answer:
      "Yes. The source is on GitHub under the Apache License 2.0, so you may read, build, change and redistribute it. The license covers the code, not the Suijin name or icon.",
  },
  {
    question: "What do I need to run Suijin?",
    answer:
      "A Mac with macOS 15 or later; the Liquid Glass interface needs macOS 26 or later. For the built-in agents, Claude Code and/or Codex installed on your Mac. Suijin is signed with a Developer ID and notarized by Apple, and is distributed outside the Mac App Store.",
  },
];

// Agents named on the site. The first two are integrated; the others are examples of command-line agents, which run
// in a shell tab or pane like any terminal program. `icon` names a file in src/assets/agents; the logos belong to
// their owners and are shown only to say which tools run in Suijin.
export const agents: { name: string; icon: string | null; builtIn?: boolean }[] = [
  { name: "Claude Code", icon: "claude-color", builtIn: true },
  { name: "Codex", icon: "codex", builtIn: true },
  { name: "Gemini CLI", icon: "gemini-color" },
  { name: "OpenCode", icon: "opencode" },
  { name: "Cursor CLI", icon: "cursor" },
  { name: "Copilot CLI", icon: "githubcopilot" },
  { name: "Amp", icon: "amp-color" },
  { name: "Goose", icon: "goose" },
  { name: "Cline", icon: "cline" },
  { name: "Qwen Code", icon: "qwen-color" },
  { name: "Kiro CLI", icon: "kiro-color" },
  { name: "Grok CLI", icon: "grok" },
  { name: "Kimi CLI", icon: "kimi-color" },
  { name: "Mistral Vibe", icon: "mistral-color" },
  { name: "Aider", icon: null },
  { name: "Any CLI agent", icon: null },
];
