// Small line icons for the app window drawn on the home page, close to the SF Symbols the app itself uses.
const paths: Record<string, string> = {
  sidebar: '<rect x="3" y="5" width="18" height="14" rx="3.5"/><path d="M9.5 5v14M5.8 9h1.4M5.8 12h1.4"/>',
  inspector: '<rect x="3" y="5" width="18" height="14" rx="3.5"/><path d="M14.5 5v14M16.8 9h1.4M16.8 12h1.4"/>',
  house: '<path d="M4 11.5 12 5l8 6.5M6.5 10v8.5h11V10M10.5 18.5v-4.5h3v4.5"/>',
  branch: '<circle cx="7" cy="5.5" r="1.9"/><circle cx="17" cy="5.5" r="1.9"/><circle cx="12" cy="19" r="1.9"/><path d="M7 7.4c0 4 5 3.2 5 9.7M17 7.4c0 4-5 3.2-5 9.7"/>',
  terminal: '<rect x="3.5" y="5.5" width="17" height="13" rx="2.5"/><path d="m7.5 10 2.5 2-2.5 2M12.5 14.5h4"/>',
  server: '<rect x="4" y="5" width="16" height="6" rx="1.8"/><rect x="4" y="13" width="16" height="6" rx="1.8"/><path d="M7.5 8h.01M7.5 16h.01"/>',
  plus: '<path d="M12 6v12M6 12h12"/>',
  split: '<rect x="3.5" y="5.5" width="17" height="13" rx="2.5"/><path d="M12 5.5v13"/>',
  chevron: '<path d="m7.5 10 4.5 4.5 4.5-4.5"/>',
  commit: '<circle cx="12" cy="12" r="8.2"/><path d="m8.4 12.2 2.5 2.5 4.8-5"/>',
  push: '<path d="M7.2 17.5a4.2 4.2 0 0 1-.5-8.3 5.6 5.6 0 0 1 10.9 1.2 3.6 3.6 0 0 1-.4 7.1M12 20v-8m0 0-2.8 2.8M12 12l2.8 2.8"/>',
  pull: '<circle cx="7" cy="6" r="1.9"/><circle cx="7" cy="18" r="1.9"/><circle cx="17" cy="18" r="1.9"/><path d="M7 7.9v8.2M17 16.1V11a3 3 0 0 0-3-3h-2m0 0 2-2m-2 2 2 2"/>',
  doc: '<path d="M7 3.8h7l4 4v12.4H7z"/><path d="M14 3.8v4h4"/>',
  info: '<circle cx="12" cy="12" r="8.2"/><path d="M12 11v5.2M12 7.8h.01"/>',
  refresh: '<path d="M18.5 9A7 7 0 1 0 19 13.5M18.8 4.8V9h-4.2"/>',
  close: '<path d="m7 7 10 10M17 7 7 17"/>',
  turn: '<path d="M6 5.5v6a3.5 3.5 0 0 0 3.5 3.5H18m0 0-3.2-3.2M18 15l-3.2 3.2"/>',
  changes: '<path d="M12 5v8M8 9h8M8 18h8"/>',
  search: '<circle cx="11" cy="11" r="6"/><path d="m15.6 15.6 3.9 3.9"/>',
  note: '<rect x="4" y="5" width="16" height="12" rx="2.5"/><path d="M8 20l3-3M8 9.5h8M8 12.5h5"/>',
  spark: '<path d="M12 4.5l1.6 4.4 4.4 1.6-4.4 1.6L12 16.5l-1.6-4.4L6 10.5l4.4-1.6z"/>',
};

export function icon(name: string): string {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] ?? ""}</svg>`;
}
