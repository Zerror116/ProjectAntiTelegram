const RUNTIME_CACHE_PREFIX = 'projectphoenix-runtime-';
const IMAGE_PRECACHE_BATCH_SIZE = 12;
const RUNTIME_IMAGE_CACHES = {
  avatars: {
    name: `${RUNTIME_CACHE_PREFIX}avatars-v2`,
    limit: 180,
  },
  productThumbs: {
    name: `${RUNTIME_CACHE_PREFIX}product-thumbs-v2`,
    limit: 260,
  },
  previews: {
    name: `${RUNTIME_CACHE_PREFIX}previews-v2`,
    limit: 140,
  },
  chatMedia: {
    name: `${RUNTIME_CACHE_PREFIX}chat-media-v2`,
    limit: 72,
  },
  genericImages: {
    name: `${RUNTIME_CACHE_PREFIX}generic-images-v2`,
    limit: 96,
  },
};
const ACTIVE_RUNTIME_CACHES = new Set(
  Object.values(RUNTIME_IMAGE_CACHES).map((entry) => entry.name),
);

self.addEventListener('install', (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(
      keys
        .filter((key) => key.startsWith(RUNTIME_CACHE_PREFIX) && !ACTIVE_RUNTIME_CACHES.has(key))
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

function normalizeRequestUrl(request) {
  try {
    return new URL(request.url);
  } catch (_) {
    return null;
  }
}

function resolveRuntimeCacheConfig(request) {
  if (!request || request.method !== 'GET') return null;
  const url = normalizeRequestUrl(request);
  if (!url || url.origin !== self.location.origin) return null;

  const pathname = url.pathname;
  if (pathname.startsWith('/uploads/users/') || pathname.startsWith('/uploads/channels/')) {
    return RUNTIME_IMAGE_CACHES.avatars;
  }
  if (pathname.startsWith('/uploads/products/variants/') || pathname.startsWith('/uploads/claims/variants/')) {
    return RUNTIME_IMAGE_CACHES.productThumbs;
  }
  if (pathname.startsWith('/uploads/products/') || pathname.startsWith('/uploads/claims/')) {
    return RUNTIME_IMAGE_CACHES.productThumbs;
  }
  if (pathname.startsWith('/api/chats/media/image/') || pathname.startsWith('/uploads/chat_media/images/')) {
    return RUNTIME_IMAGE_CACHES.previews;
  }
  if (
    pathname.startsWith('/api/chats/media/video/') ||
    pathname.startsWith('/api/chats/media/voice/') ||
    pathname.startsWith('/api/chats/media/file/') ||
    pathname.startsWith('/uploads/chat_media/video/') ||
    pathname.startsWith('/uploads/chat_media/voice/') ||
    pathname.startsWith('/uploads/chat_media/files/')
  ) {
    return RUNTIME_IMAGE_CACHES.chatMedia;
  }
  if (pathname.startsWith('/uploads/')) {
    return RUNTIME_IMAGE_CACHES.genericImages;
  }
  return null;
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

async function cacheRuntimeResponse(request, response, config) {
  if (!response || !response.ok || !config) return response;
  const cache = await caches.open(config.name);
  await cache.put(request, response.clone());
  await trimRuntimeCache(config.name, config.limit);
  return response;
}

async function handleRuntimeMediaRequest(event) {
  const config = resolveRuntimeCacheConfig(event.request);
  if (!config) {
    return fetch(event.request);
  }

  const cache = await caches.open(config.name);
  const cached = await cache.match(event.request);
  if (cached) {
    event.waitUntil(
      fetch(event.request)
        .then((response) => cacheRuntimeResponse(event.request, response, config))
        .catch(() => null),
    );
    return cached;
  }

  const networkFetch = fetch(event.request);
  event.waitUntil(
    networkFetch
      .then((response) => cacheRuntimeResponse(event.request, response, config))
      .catch(() => null),
  );
  return networkFetch;
}

async function precacheImageBatch(urls) {
  if (!Array.isArray(urls) || urls.length === 0) return;
  const uniqueUrls = Array.from(new Set(urls))
    .filter((value) => typeof value === 'string' && value.trim().length > 0)
    .slice(0, IMAGE_PRECACHE_BATCH_SIZE);

  for (const rawUrl of uniqueUrls) {
    try {
      const url = new URL(rawUrl, self.location.origin);
      if (url.origin !== self.location.origin) continue;
      const request = new Request(url.toString(), {
        method: 'GET',
        credentials: 'same-origin',
      });
      const config = resolveRuntimeCacheConfig(request);
      if (!config) continue;
      const cache = await caches.open(config.name);
      const existing = await cache.match(request);
      if (existing) continue;
      const response = await fetch(request);
      await cacheRuntimeResponse(request, response, config);
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
  const config = resolveRuntimeCacheConfig(event.request);
  if (!config) return;
  event.respondWith(handleRuntimeMediaRequest(event));
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
