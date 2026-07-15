import { clean } from "./contracts.ts";

type Entity = Record<string, any>;

/**
 * Base44 scheduled automations can deliver function_args under body.args.
 * Top-level drain is handled separately and still requires either the internal
 * secret or an authenticated admin; this helper only recognizes nested args.
 */
export function scheduledDrainArgs(body: Entity): Entity | null {
  if (clean(body?.action)) return null;
  if (
    !body?.args || typeof body.args !== "object" || Array.isArray(body.args)
  ) {
    return null;
  }
  const args = body.args as Entity;
  if (clean(args.action).toLowerCase() !== "drain") return null;
  return { ...args, action: "drain" };
}

export function isAdminAutomationUser(user: Entity | null | undefined) {
  return Boolean(clean(user?.id)) &&
    clean(user?.role).toLowerCase() === "admin";
}
