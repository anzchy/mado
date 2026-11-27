#!/usr/bin/env node
// Help-site content check. Implemented after I887-WI-1 RED receipt.
export async function checkSite() {
  return [];
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  const errors = await checkSite(process.argv[2]);
  for (const error of errors) console.error(error);
  process.exitCode = errors.length ? 1 : 0;
}
