const slowRequestStages = [
  'authenticate', 'session_gate', 'read_command', 'account_gate', 'receipt',
  'refresh_membership', 'prepare_external', 'execute', 'cleanup',
] as const;

export type SlowRequestStage = typeof slowRequestStages[number];
type SlowRequestOperation = 'unclassified' | 'profile' | 'profile.delete' | 'community'
  | 'notifications' | 'push' | 'legacy' | 'generation_rewards' | 'membership'
  | 'membership.check' | 'membership.check_subscription' | 'membership.prepare'
  | 'membership.prepare_purchase' | 'membership.sync_transaction';

export interface SlowRequestDiagnostic {
  stage: SlowRequestStage;
  operation: SlowRequestOperation;
}

export interface SlowRequestDiagnosticDependencies {
  /** Returns a cancellation function; the callback must be scheduled once. */
  schedule?: (callback: () => void, delayMilliseconds: number) => () => void;
  diagnose?: (event: SlowRequestDiagnostic) => void;
}

function commandOperation(command: unknown): SlowRequestOperation {
  if (!command || typeof command !== 'object' || Array.isArray(command)) return 'unclassified';
  const { service, action } = command as { service?: unknown; action?: unknown };
  switch (service) {
    case 'profile': return action === 'delete' ? 'profile.delete' : 'profile';
    case 'community': return 'community';
    case 'notifications': return 'notifications';
    case 'push': return 'push';
    case 'legacy': return 'legacy';
    case 'generation_rewards': return 'generation_rewards';
    case 'membership':
      switch (action) {
        case 'check': return 'membership.check';
        case 'check_subscription': return 'membership.check_subscription';
        case 'prepare': return 'membership.prepare';
        case 'prepare_purchase': return 'membership.prepare_purchase';
        case 'sync_transaction': return 'membership.sync_transaction';
        default: return 'membership';
      }
    default: return 'unclassified';
  }
}

/** Observe a slow request without cancelling it, retrying it, or logging its data. */
export function watchAppRequest({ schedule, diagnose }: SlowRequestDiagnosticDependencies = {}) {
  let stage: SlowRequestStage = 'authenticate';
  let operation: SlowRequestOperation = 'unclassified';
  let finished = false;
  let warned = false;
  let cancel = () => {};
  const scheduleOnce = schedule ?? ((callback: () => void, delay: number) => {
    const timer = setTimeout(callback, delay);
    return () => clearTimeout(timer);
  });
  const report = diagnose ?? ((event: SlowRequestDiagnostic) => {
    console.warn('app-services slow request', JSON.stringify(event));
  });
  try {
    cancel = scheduleOnce(() => {
      if (finished || warned) return;
      warned = true;
      // A logging failure must not escape the timer or affect the request.
      try { report({ stage, operation }); } catch { /* diagnostic only */ }
    }, 12_000);
  } catch { /* Diagnostics must not prevent a request from running. */ }
  return {
    stage(next: SlowRequestStage) {
      if (slowRequestStages.includes(next)) stage = next;
    },
    command(command: unknown) { operation = commandOperation(command); },
    finish() {
      if (finished) return;
      finished = true;
      try { cancel(); } catch { /* diagnostic only */ }
    },
  };
}
