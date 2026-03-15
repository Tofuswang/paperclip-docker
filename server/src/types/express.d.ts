export interface Actor {
  type: "board" | "agent" | "none";
  userId?: string;
  agentId?: string;
  companyId?: string;
  companyIds?: string[];
  keyId?: string | undefined;
  runId?: string;
  isInstanceAdmin?: boolean;
  source: string;
}

declare module "express-serve-static-core" {
  interface Request {
    actor: Actor;
  }
}
