import "express";

declare module "express" {
  interface Request {
    actor: {
      type: "board" | "agent" | "none";
      userId?: string;
      agentId?: string;
      companyId?: string;
      companyIds?: string[];
      keyId?: string | undefined;
      runId?: string;
      isInstanceAdmin?: boolean;
      source: string;
    };
  }
}
