import { randomUUID } from "node:crypto";

export function createId(prefix) {
  return `${prefix}_${randomUUID().replace(/-/g, "").slice(0, 16)}`;
}
