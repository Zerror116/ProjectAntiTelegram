(function () {
  function urlBase64ToUint8Array(base64String) {
    const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
    const base64 = (base64String + padding)
      .replace(/-/g, '+')
      .replace(/_/g, '/');
    const rawData = atob(base64);
    return Uint8Array.from([...rawData].map((ch) => ch.charCodeAt(0)));
  }

  async function ensureRegistration() {
    if (!('serviceWorker' in navigator)) {
      return null;
    }
    const existing = await navigator.serviceWorker.getRegistration();
    const registration =
      existing || (await navigator.serviceWorker.register('/flutter_service_worker.js'));
    await navigator.serviceWorker.ready;
    return registration;
  }

  async function getSubscriptionJson() {
    const registration = await ensureRegistration();
    if (!registration || !registration.pushManager) {
      return null;
    }
    const subscription = await registration.pushManager.getSubscription();
    return subscription ? JSON.stringify(subscription) : null;
  }

  async function subscribeJson(publicKey) {
    const registration = await ensureRegistration();
    if (!registration || !registration.pushManager) {
      return null;
    }
    const existing = await registration.pushManager.getSubscription();
    if (existing) {
      return JSON.stringify(existing);
    }
    const subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(publicKey),
    });
    return subscription ? JSON.stringify(subscription) : null;
  }

  async function unsubscribeCurrent() {
    const registration = await ensureRegistration();
    if (!registration || !registration.pushManager) {
      return null;
    }
    const subscription = await registration.pushManager.getSubscription();
    if (!subscription) {
      return null;
    }
    const endpoint = subscription.endpoint || null;
    await subscription.unsubscribe();
    return endpoint;
  }

  window.projectPhoenixPush = {
    ensureRegistration,
    getSubscriptionJson,
    subscribeJson,
    unsubscribeCurrent,
  };
})();
