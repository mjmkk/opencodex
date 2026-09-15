// This poll reads structured request state only. It never starts a model turn.
export function startApprovalNotifications({ bridge, notifier, store, intervalMs = 30000, logger = console }) {
  if (!bridge || !notifier) return () => {};
  let stopped = false, running = false;
  const poll = async () => {
    if (stopped || running) return;
    running = true;
    try {
      const devices = store.listPushDevices();
      if (!devices.length) return;
      const { data } = await bridge("list");
      for (const document of data ?? []) {
        const request = document.request;
        if (stopped || document.state !== "pending" || request.expires_at * 1000 <= Date.now()) continue;
        const threadId = request.return_target?.thread_id;
        if (!threadId) continue;
        const result = await notifier.notify({ devices, job: { threadId, jobId: `structured:${request.id}` },
          envelope: { type: "approval.required", seq: 0,
            payload: { approvalId: request.id, requestVersion: document.request_version, source: "structured_approval",
              quickResponse: document.quick_response } } });
        for (const token of result.invalidDeviceTokens ?? []) store.removePushDevice(token);
      }
    } catch { logger.warn?.("Structured approval notification refresh is unavailable"); }
    finally { running = false; }
  };
  const timer = setInterval(poll, intervalMs); timer.unref(); void poll();
  return () => { stopped = true; clearInterval(timer); };
}
