export interface AppActor {
  id: string;
  /** Stable public game/social key. Never the private contact address. */
  email: string;
  contactEmail: string;
  full_name: string;
  metadata: Record<string, unknown>;
}

export interface AppContext {
  tx: any;
  actor: AppActor;
  now: Date;
  config: Record<string, string | undefined>;
  /** Evidence verified before opening the database transaction. */
  evidence?: any;
}

export class AppServiceError extends Error {
  code: string;
  status: number;
  retryable: boolean;
  constructor(code: string, message: string, status = 400, retryable = false) {
    super(message);
    this.name = 'AppServiceError';
    this.code = code;
    this.status = status;
    this.retryable = retryable;
  }
}

export const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export function requireUUID(value: unknown, field = 'id'): string {
  if (typeof value !== 'string' || !uuidPattern.test(value)) {
    throw new AppServiceError('invalid_' + field, field + ' must be a UUID.');
  }
  return value.toLowerCase();
}
