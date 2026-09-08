export type Phase = "auth" | "consent" | "quota" | "claude" | "gemini" | "vision" | "completion";

/** Durations only: never store tokens, user IDs, prompts, receipt text, or URLs. */
export class RequestTiming {
  private readonly started = performance.now();
  private readonly phases: { phase: Phase; duration_ms: number; completed: boolean }[] = [];

  async measure<T>(phase: Phase, operation: () => Promise<T>): Promise<T> {
    const start = performance.now();
    let completed = false;
    try {
      const value = await operation();
      completed = true;
      return value;
    } finally {
      this.phases.push({ phase, duration_ms: this.elapsed(start), completed });
    }
  }

  summary(functionName: string, status: number) {
    return { event: "request_timing", function: functionName, status,
      duration_ms: this.elapsed(this.started), phases: [...this.phases] };
  }

  header(): string {
    return this.phases.map((entry, index) => `${entry.phase}_${index};dur=${entry.duration_ms}`).join(", ");
  }

  private elapsed(start: number): number { return Math.round((performance.now() - start) * 100) / 100; }
}

export function withTiming(
  functionName: string,
  handler: (request: Request, timing: RequestTiming) => Promise<Response>,
): (request: Request) => Promise<Response> {
  return async (request) => {
    const timing = new RequestTiming();
    let status = 500;
    try {
      const response = await handler(request, timing);
      status = response.status;
      const headers = new Headers(response.headers);
      const serverTiming = timing.header();
      if (serverTiming) headers.set("Server-Timing", serverTiming);
      return new Response(response.body, { status, statusText: response.statusText, headers });
    } finally {
      console.info(JSON.stringify(timing.summary(functionName, status)));
    }
  };
}
