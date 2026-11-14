// Read at build time as plain text; the path is relative to this file.
import changelog from "../../../CHANGELOG.md?raw";

// The release notes page is built from CHANGELOG.md at the repository root, so the site never says something the
// changelog does not.
export interface Release {
  version: string;
  /** "2026-11-20", or null while the version is not released yet. */
  date: string | null;
  /** One entry per bullet, as safe HTML. */
  entries: string[];
}

function escape(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Inline Markdown the changelog uses: `code` and **bold**.
function inline(text: string): string {
  return escape(text)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
}

export function releases(): Release[] {
  const result: Release[] = [];
  let current: Release | null = null;
  let entry: string[] | null = null;
  const flush = () => {
    if (current && entry) current.entries.push(inline(entry.join(" ")));
    entry = null;
  };
  for (const line of changelog.split("\n")) {
    const heading = /^## (\S+)(?: \((.+)\))?/.exec(line);
    if (heading) {
      flush();
      const date = heading[2] && /^\d{4}-\d{2}-\d{2}$/.test(heading[2]) ? heading[2] : null;
      current = { version: heading[1], date, entries: [] };
      result.push(current);
    } else if (line.startsWith("- ")) {
      flush();
      entry = [line.slice(2).trim()];
    } else if (entry && line.startsWith("  ") && line.trim()) {
      entry.push(line.trim());
    } else if (!line.trim()) {
      flush();
    }
  }
  flush();
  return result;
}
