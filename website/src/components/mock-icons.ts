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

const page = '<path d="M3.5 1.5h6l3 3V14a.5.5 0 0 1-.5.5H3.5A.5.5 0 0 1 3 14V2a.5.5 0 0 1 .5-.5z" fill="#fff" stroke="#bdbdc2" stroke-width=".7"/><path d="M9.5 1.5v3h3" fill="#ececee" stroke="#bdbdc2" stroke-width=".7" stroke-linejoin="round"/>';
const badge = (text: string, color: string) =>
  `<rect x="1.5" y="2.5" width="13" height="11" rx="2.6" fill="${color}"/><text x="8" y="10.1" text-anchor="middle" font-size="${text.length > 2 ? 4.6 : 5.6}" font-weight="700" fill="#fff" font-family="system-ui, sans-serif">${text}</text>`;
const marks: Record<string, string> = {
  swift: page + '<path d="M5 7.4c1.4 1.5 2.8 2.300 4.100 2.700-1.200-1-2.100-2.100-2.700-3.300 1.500 1.200 2.800 2 3.800 2.500.4-.8.200-1.900-.6-2.800 1.400.9 2.200 2.500 1.700 4 .4.500.5 1 .3 1.400-.3-.4-.7-.6-1.300-.4-1.700.700-4-.100-5.300-4.100z" fill="#f05138"/>',
  mov: page + '<rect x="4.800" y="7" width="6.400" height="4.800" rx=".9" fill="#5b5bd6"/><path d="M7.300 8.300v2.200l2-1.100z" fill="#fff"/>',
  m4a: page + '<path d="M7.100 11.500V7.500l3.200-.8v4" fill="none" stroke="#f0459a" stroke-width=".9" stroke-linejoin="round"/><circle cx="6.300" cy="11.500" r=".95" fill="#f0459a"/><circle cx="9.500" cy="10.700" r=".95" fill="#f0459a"/>',
  png: page + '<rect x="4.800" y="7" width="6.400" height="4.800" rx=".7" fill="#bfe3ff"/><path d="M4.900 11.800l2.100-2.400 1.400 1.400 1-1 1.700 2z" fill="#30a46c"/><circle cx="9.700" cy="8.300" r=".65" fill="#f5b400"/>',
  md: badge("MD", "#59667a"),
  json: badge("{}", "#cc801a"),
  yml: badge("YML", "#993340"),
  sh: badge("SH", "#408c4d"),
};
const folder = '<path d="M1 4.200C1 3.500 1.500 3 2.200 3h3.200c.4 0 .8.200 1 .4l.9.900h6.500c.7 0 1.200.5 1.200 1.200V12c0 .7-.5 1.200-1.200 1.200H2.200C1.500 13.200 1 12.700 1 12z" fill="#3a9be6"/><path d="M1 6.400c0-.7.5-1.200 1.200-1.200h11.600c.7 0 1.200.5 1.200 1.200V12c0 .7-.5 1.200-1.200 1.200H2.200C1.500 13.200 1 12.700 1 12z" fill="#6ec1f7"/>';

/** A file's icon as the app's tree shows it: the system folder, a document page marked by type, or a labelled badge. */
export function fileIcon(name: string, isFolder = false): string {
  const body = isFolder ? folder : marks[name.split(".").pop() ?? ""] ?? page;
  return `<svg viewBox="0 0 16 16" aria-hidden="true">${body}</svg>`;
}
