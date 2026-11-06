import { ConvexError } from "convex/values";

export type ImportBudgetScope =
  | "request"
  | "identity"
  | "group"
  | "expense"
  | "references"
  | "revisions";
export class MeasuredBudgetError extends Error {
  constructor(
    readonly scope: ImportBudgetScope,
    message: string
  ) {
    super(message);
    this.name = "MeasuredBudgetError";
  }
}
export function throwImportBudgetExceeded(scope: ImportBudgetScope): never {
  throw new ConvexError({ code: "IMPORT_BUDGET_EXCEEDED", scope });
}
export function isImportBudgetExceeded(error: unknown): boolean {
  if (error instanceof MeasuredBudgetError) return true;
  if (!(error instanceof ConvexError)) return false;
  let data: unknown = error.data;
  if (typeof data === "string") {
    try {
      data = JSON.parse(data);
    } catch {
      return false;
    }
  }
  if (!data || typeof data !== "object") return false;
  return (
    "code" in data &&
    data.code === "IMPORT_BUDGET_EXCEEDED" &&
    "scope" in data &&
    ["request", "identity", "group", "expense", "references", "revisions"].includes(
      String(data.scope)
    )
  );
}
export type ImportItemOutcome = {
  kind: "friend" | "group" | "expense";
  id: string;
  status: "created" | "updated" | "already_present" | "rejected";
  error_code?: "IMPORT_ITEM_INVALID";
  notice?: "inactive_party_scrubbed";
};
