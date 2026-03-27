self.addEventListener('install', (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
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

self.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.type === 'badge-sync') {
    event.waitUntil(syncBadge(data.count));
  }
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
      },
    });
  })());
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl =
    (event.notification.data && event.notification.data.url) || '/';

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
