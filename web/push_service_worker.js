const RUNTIME_CACHE_PREFIX = 'projectphoenix-runtime-';
const IMAGE_RUNTIME_CACHE = `${RUNTIME_CACHE_PREFIX}images-v1`;
const IMAGE_RUNTIME_CACHE_LIMIT = 120;
const IMAGE_PRECACHE_BATCH_SIZE = 10;

self.addEventListener('install', (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(
      keys
        .filter((key) => key.startsWith(RUNTIME_CACHE_PREFIX) && key !== IMAGE_RUNTIME_CACHE)
        .map((key) => caches.delete(key)),
    );
    await syncBadge(0);
    await self.clients.claim();
  })());
});

async function syncBadge(count) {
  const normalized = Number.isFinite(Number(count)) ? Math.max(0, Number(count)) : 0;
  try {
    if (self.navigator && typeof self.navigator.setAppBadge === 'function') {
      if (normalized > 0) {
        await self.navigator.setAppBadge(normalized);
      } else if (typeof self.navigator.clearAppBadge === 'function') {
        await self.navigator.clearAppBadge();
      } else {
        await self.navigator.setAppBadge(0);
      }
    }
  } catch (_) {
    // ignore
  }
}

function isRuntimeImageRequest(request) {
  if (!request || request.method !== 'GET') return false;
  let url;
  try {
    url = new URL(request.url);
  } catch (_) {
    return false;
  }
  if (url.origin !== self.location.origin) return false;
  return (
    url.pathname.startsWith('/uploads/') ||
    url.pathname.startsWith('/api/chats/media/')
  );
}

async function trimRuntimeCache(cacheName, limit) {
  const cache = await caches.open(cacheName);
  const keys = await cache.keys();
  if (keys.length <= limit) return;
  const overflow = keys.length - limit;
  for (let index = 0; index < overflow; index += 1) {
    await cache.delete(keys[index]);
  }
}

async function cacheImageResponse(request, response) {
  if (!response || !response.ok) return response;
  const cache = await caches.open(IMAGE_RUNTIME_CACHE);
  await cache.put(request, response.clone());
  await trimRuntimeCache(IMAGE_RUNTIME_CACHE, IMAGE_RUNTIME_CACHE_LIMIT);
  return response;
}

async function handleImageRuntimeRequest(event) {
  const cache = await caches.open(IMAGE_RUNTIME_CACHE);
  const cached = await cache.match(event.request);
  if (cached) {
    event.waitUntil(
      fetch(event.request)
        .then((response) => cacheImageResponse(event.request, response))
        .catch(() => null),
    );
    return cached;
  }
  const networkFetch = fetch(event.request);
  event.waitUntil(
    networkFetch
      .then((response) => cacheImageResponse(event.request, response))
      .catch(() => null),
  );
  return networkFetch;
}

async function precacheImageBatch(urls) {
  if (!Array.isArray(urls) || urls.length === 0) return;
  const cache = await caches.open(IMAGE_RUNTIME_CACHE);
  const uniqueUrls = Array.from(new Set(urls))
    .filter((value) => typeof value === 'string' && value.trim().length > 0)
    .slice(0, IMAGE_PRECACHE_BATCH_SIZE);

  for (const rawUrl of uniqueUrls) {
    try {
      const url = new URL(rawUrl, self.location.origin);
      if (
        url.origin !== self.location.origin ||
        (!url.pathname.startsWith('/uploads/') &&
          !url.pathname.startsWith('/api/chats/media/'))
      ) {
        continue;
      }
      const request = new Request(url.toString(), {
        method: 'GET',
        credentials: 'same-origin',
      });
      const existing = await cache.match(request);
      if (existing) continue;
      const response = await fetch(request);
      await cacheImageResponse(request, response);
    } catch (_) {
      // ignore bad URLs and transient network errors
    }
  }
}

function buildNotificationTapPayload(sourcePayload = {}) {
  const data = sourcePayload.data && typeof sourcePayload.data === 'object'
    ? sourcePayload.data
    : {};
  return {
    id: sourcePayload.id || sourcePayload.message_id || '',
    category: sourcePayload.category || sourcePayload.type || '',
    priority: sourcePayload.priority || 'normal',
    title: sourcePayload.title || 'Проект Феникс',
    body: sourcePayload.body || '',
    deep_link: sourcePayload.deep_link || sourcePayload.url || '/',
    media: sourcePayload.media && typeof sourcePayload.media === 'object'
      ? sourcePayload.media
      : {},
    payload: sourcePayload.payload && typeof sourcePayload.payload === 'object'
      ? sourcePayload.payload
      : {},
    force_show: sourcePayload.forceShow === true || sourcePayload.force_show === true,
    badge_count: Number(sourcePayload.badgeCount || sourcePayload.badge_count || 0) || 0,
    inbox_item_id: sourcePayload.inbox_item_id || data.inboxItemId || '',
    campaign_id: sourcePayload.campaign_id || sourcePayload.campaignId || '',
    cta_label: sourcePayload.cta_label || sourcePayload.ctaLabel || '',
    version: sourcePayload.version || '',
    required_update:
      sourcePayload.required_update === true || sourcePayload.requiredUpdate === true,
    thread_id: sourcePayload.thread_id || sourcePayload.threadId || data.chatId || '',
  };
}

function buildNotificationOpenUrl(targetUrl, payload) {
  try {
    const url = new URL(targetUrl || '/', self.location.origin);
    url.searchParams.set('notification_payload', JSON.stringify(payload));
    return url.toString();
  } catch (_) {
    return targetUrl || '/';
  }
}

self.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.type === 'badge-sync') {
    event.waitUntil(syncBadge(data.count));
    return;
  }
  if (data.type === 'precache-images') {
    event.waitUntil(precacheImageBatch(data.urls || []));
  }
});

self.addEventListener('fetch', (event) => {
  if (!isRuntimeImageRequest(event.request)) return;
  event.respondWith(handleImageRuntimeRequest(event));
});

self.addEventListener('push', (event) => {
  const payload = (() => {
    try {
      return event.data ? event.data.json() : {};
    } catch (_) {
      return {};
    }
  })();

  const title = payload.title || 'Проект Феникс';
  const body = payload.body || 'Новое сообщение';
  const url = payload.url || '/';
  const badgeCount = Number(payload.badgeCount || 0) || 0;
  const forceShow = payload.forceShow === true;
  const tapPayload = buildNotificationTapPayload(payload);

  event.waitUntil((async () => {
    await syncBadge(badgeCount);

    const windows = await self.clients.matchAll({
      type: 'window',
      includeUncontrolled: true,
    });
    const hasVisibleClient = windows.some((client) => {
      return client.visibilityState === 'visible' && client.focused;
    });

    if (hasVisibleClient && !forceShow) {
      return;
    }

    await self.registration.showNotification(title, {
      body,
      tag: payload.tag || 'projectphoenix-chat-message',
      icon: '/icons/Icon-192.png',
      badge: '/icons/Icon-maskable-192.png',
      silent: false,
      renotify: true,
      requireInteraction: false,
      data: {
        url,
        chatId: payload.data && payload.data.chatId ? payload.data.chatId : null,
        payload: tapPayload,
      },
    });
  })());
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const notificationData = event.notification.data || {};
  const tapPayload = notificationData.payload || buildNotificationTapPayload({});
  const targetUrl = buildNotificationOpenUrl(
    notificationData.url || '/',
    tapPayload,
  );

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({
      type: 'window',
      includeUncontrolled: true,
    });
    for (const client of windows) {
      if ('focus' in client) {
        await client.focus();
        if ('navigate' in client) {
          try {
            await client.navigate(targetUrl);
          } catch (_) {
            // ignore
          }
        }
        return;
      }
    }
    if (self.clients.openWindow) {
      await self.clients.openWindow(targetUrl);
    }
  })());
});
