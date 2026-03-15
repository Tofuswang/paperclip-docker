interface PaperclipActor {
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

declare namespace Express {
  interface Request {
    actor: PaperclipActor;
  }
}
