(function () {
  let workerScriptAvailable;

  function withTimeout(promise, timeoutMs) {
    return Promise.race([
      promise,
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), timeoutMs)),
    ]);
  }

  function urlBase64ToUint8Array(base64String) {
    const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
    const base64 = (base64String + padding)
      .replace(/-/g, '+')
      .replace(/_/g, '/');
    const rawData = atob(base64);
    return Uint8Array.from([...rawData].map((ch) => ch.charCodeAt(0)));
  }

  async function hasWorkerScript() {
    if (workerScriptAvailable !== undefined) {
      return workerScriptAvailable;
    }
    try {
      const response = await withTimeout(fetch('/flutter_service_worker.js', {
        method: 'HEAD',
        cache: 'no-store',
      }), 2500);
      workerScriptAvailable = response.ok;
    } catch (_) {
      workerScriptAvailable = false;
    }
    return workerScriptAvailable;
  }

  function currentWorkerUrl() {
    let workerUrl = '/flutter_service_worker.js';
    try {
      const buildVersion = (localStorage.getItem('projectphoenix-web-build-version') || '').trim();
      if (buildVersion) {
        workerUrl = `${workerUrl}?v=${encodeURIComponent(buildVersion)}`;
      }
    } catch (_) {}
    return workerUrl;
  }

  async function ensureRegistration() {
    if (!('serviceWorker' in navigator)) {
      return null;
    }
    const existing = await withTimeout(
      navigator.serviceWorker.getRegistration(),
      3000,
    ).catch(() => null);
    if (!existing && !(await hasWorkerScript())) {
      return null;
    }
    try {
      const registration = await withTimeout(
        navigator.serviceWorker.register(currentWorkerUrl(), { scope: '/' }),
        5000,
      );
      if (registration && typeof registration.update === 'function') {
        await withTimeout(registration.update().catch(() => {}), 2500).catch(() => {});
      }
      await withTimeout(navigator.serviceWorker.ready, 4000);
      return registration;
    } catch (_) {
      if (!existing) return null;
      if (typeof existing.update === 'function') {
        await withTimeout(existing.update().catch(() => {}), 2500).catch(() => {});
      }
      await withTimeout(navigator.serviceWorker.ready, 4000).catch(() => {});
      return existing;
    }
  }

  async function getSubscriptionJson() {
    const registration = await ensureRegistration();
    if (!registration || !registration.pushManager) {
      return null;
    }
    const subscription = await withTimeout(
      registration.pushManager.getSubscription(),
      5000,
    );
    return subscription ? JSON.stringify(subscription) : null;
  }

  async function subscribeJson(publicKey) {
    const registration = await ensureRegistration();
    if (!registration || !registration.pushManager) {
      return null;
    }
    const existing = await withTimeout(
      registration.pushManager.getSubscription(),
      5000,
    );
    if (existing) {
      return JSON.stringify(existing);
    }
    const subscription = await withTimeout(
      registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(publicKey),
      }),
      12000,
    );
    return subscription ? JSON.stringify(subscription) : null;
  }

  async function unsubscribeCurrent() {
    const registration = await ensureRegistration();
    if (!registration || !registration.pushManager) {
      return null;
    }
    const subscription = await withTimeout(
      registration.pushManager.getSubscription(),
      5000,
    );
    if (!subscription) {
      return null;
    }
    const endpoint = subscription.endpoint || null;
    await withTimeout(subscription.unsubscribe(), 8000);
    return endpoint;
  }

  window.projectPhoenixPush = {
    ensureRegistration,
    getSubscriptionJson,
    subscribeJson,
    unsubscribeCurrent,
  };
})();
