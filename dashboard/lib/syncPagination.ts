// Keyset pagination keeps records sharing a timestamp together. A failed page
// rejects the entire request, so clients cannot commit a partial cursor.
export async function readSyncPages<T extends { id: string; updated_at: string }>(
  table: string,
  since: string,
  until: string,
  read: (query: string) => Promise<T[]>,
): Promise<T[]> {
  const result: T[] = [];
  let last: T | undefined;
  while (true) {
    const query = new URLSearchParams();
    query.set("select", "*");
    query.append("updated_at", `gte.${since}`);
    query.append("updated_at", `lte.${until}`);
    query.set("order", "updated_at.asc,id.asc");
    query.set("limit", "1000");
    if (last) {
      query.set("or", `(updated_at.gt.${last.updated_at},and(updated_at.eq.${last.updated_at},id.gt.${last.id}))`);
    }
    const page = await read(`${table}?${query}`);
    result.push(...page);
    if (page.length < 1000) return result;
    last = page[page.length - 1];
  }
}
