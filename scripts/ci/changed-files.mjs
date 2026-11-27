// Validates a pull request's changed-file list as GitHub's files API returns it (100 per page). Shared by the native
// classifier and the release-contents filter (#861), so both read the same trusted list the same way.
export const PER_PAGE = 100;
export const MAX_FILES = 3000;
const STATUSES = new Set(['added', 'removed', 'modified', 'renamed', 'copied', 'changed', 'unchanged']);

/**
 * Every path the list names (both ends of a rename or copy), or `{ error }` when the list cannot be trusted: a missing
 * or capped count, a malformed page or entry, or a count that differs from the event's changed_files.
 */
export function listChangedFiles({ changedFiles, pages }) {
  const fail = error => ({ error });
  if (!Number.isInteger(changedFiles) || changedFiles <= 0) return fail('pull_request.changed_files missing or zero');
  if (changedFiles >= MAX_FILES) return fail(`changed_files ${changedFiles} reaches the ${MAX_FILES}-file API cap`);
  if (!Array.isArray(pages) || pages.length === 0) return fail('no file list');
  const files = [];
  let count = 0;
  for (const [index, page] of pages.entries()) {
    if (!Array.isArray(page)) return fail(`page ${index + 1} is not a list`);
    if (page.length > PER_PAGE || (index < pages.length - 1 && page.length !== PER_PAGE)) {
      return fail(`page ${index + 1} has ${page.length} entries`);
    }
    for (const entry of page) {
      if (!entry || typeof entry !== 'object' || typeof entry.filename !== 'string' || !STATUSES.has(entry.status)) {
        return fail('malformed file entry');
      }
      const paths = [entry.filename];
      if (entry.status === 'renamed' || entry.status === 'copied') {
        if (typeof entry.previous_filename !== 'string') return fail(`${entry.status} entry without previous_filename`);
        paths.push(entry.previous_filename);
      } else if (entry.previous_filename !== undefined) {
        return fail('previous_filename on a non-rename entry');
      }
      count++;
      files.push(...paths);
    }
  }
  if (count !== changedFiles) return fail(`listed ${count} files, event says ${changedFiles}`);
  return { files, count };
}
