(async () => {
  const state = (window.__phoenixRecoveryState = {
    startedAt: new Date().toISOString(),
    status: 'starting',
    recovered: 0,
    scannedTasks: 0,
    matchedCacheEntries: 0,
    failures: [],
    loops: 0,
    totalTasksSeen: 0,
  });

  const normalizeName = (value) => {
    if (typeof value !== 'string') return '';
    const trimmed = value.trim();
    if (!trimmed) return '';
    const parts = trimmed.split('/');
    return parts[parts.length - 1];
  };

  function readSavedSession() {
    try {
      const raw =
        window.localStorage.getItem('flutter.saved_tenant_sessions_v1') ||
        window.sessionStorage.getItem('flutter.saved_tenant_sessions_v1') ||
        '';
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (!Array.isArray(parsed) || !parsed.length) return null;
      parsed.sort((a, b) => {
        const aTs = Date.parse(a && a.updated_at ? a.updated_at : 0) || 0;
        const bTs = Date.parse(b && b.updated_at ? b.updated_at : 0) || 0;
        return bTs - aTs;
      });
      const session = parsed.find((item) => item && (item.token || item.refresh_token));
      return session || null;
    } catch (_) {
      return null;
    }
  }

  const savedSession = readSavedSession();
  const injectedToken = typeof window.__phoenixInjectedToken === 'string' ? window.__phoenixInjectedToken : '';
  const injectedRefreshToken = typeof window.__phoenixInjectedRefreshToken === 'string' ? window.__phoenixInjectedRefreshToken : '';
  const token =
    injectedToken ||
    (savedSession && savedSession.token) ||
    window.localStorage.getItem('flutter.auth_token') ||
    window.localStorage.getItem('auth_token') ||
    window.localStorage.getItem('jwt') ||
    window.sessionStorage.getItem('flutter.auth_token') ||
    window.sessionStorage.getItem('jwt') ||
    '';
  if (!token) {
    state.status = 'error';
    state.failures.push('missing_jwt');
    return state;
  }

  let accessToken = token;
  let refreshToken =
    injectedRefreshToken ||
    (savedSession && savedSession.refresh_token) ||
    window.localStorage.getItem('flutter.auth_refresh_token') ||
    window.localStorage.getItem('auth_refresh_token') ||
    window.sessionStorage.getItem('flutter.auth_refresh_token') ||
    '';

  function authHeaders() {
    return { Authorization: `Bearer ${accessToken}` };
  }

  async function refreshSession() {
    if (!refreshToken) return false;
    const response = await fetch('/api/auth/refresh', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: refreshToken }),
    });
    if (!response.ok) return false;
    const payload = await response.json().catch(() => null);
    const nextAccess = payload && (payload.token || payload.access);
    const nextRefresh = payload && payload.refresh_token;
    if (!nextAccess) return false;
    accessToken = String(nextAccess);
    if (nextRefresh) {
      refreshToken = String(nextRefresh);
    }
    try { window.localStorage.setItem('flutter.auth_token', accessToken); } catch (_) {}
    try {
      if (nextRefresh) {
        window.localStorage.setItem('flutter.auth_refresh_token', String(nextRefresh));
      }
    } catch (_) {}
    return true;
  }

  async function buildCacheIndex() {
    const index = new Map();
    const cacheNames = await caches.keys();
    for (const cacheName of cacheNames) {
      let cache;
      try {
        cache = await caches.open(cacheName);
      } catch (_) {
        continue;
      }
      let requests = [];
      try {
        requests = await cache.keys();
      } catch (_) {
        continue;
      }
      for (const request of requests) {
        try {
          const url = new URL(request.url, location.origin);
          const fileName = normalizeName(url.pathname);
          if (!fileName) continue;
          if (!index.has(fileName)) {
            index.set(fileName, { cacheName, requestUrl: request.url });
          }
        } catch (_) {
          // ignore bad URLs
        }
      }
    }
    return index;
  }

  async function fetchTasks(limit = 1000) {
    let response = await fetch(`/api/profile/uploads-recovery/tasks?limit=${limit}`, {
      method: 'GET',
      headers: authHeaders(),
      credentials: 'same-origin',
    });
    if (response.status === 401) {
      const refreshed = await refreshSession();
      if (refreshed) {
        response = await fetch(`/api/profile/uploads-recovery/tasks?limit=${limit}`, {
          method: 'GET',
          headers: authHeaders(),
          credentials: 'same-origin',
        });
      }
    }
    if (!response.ok) {
      throw new Error(`tasks_http_${response.status}`);
    }
    const payload = await response.json();
    return Array.isArray(payload?.data?.tasks) ? payload.data.tasks : [];
  }

  async function loadCachedBlob(cacheIndex, task) {
    const names = [
      normalizeName(task.original_file_name),
      normalizeName(task.expected_filename),
      normalizeName(task.relative_upload_path),
    ].filter(Boolean);

    for (const name of names) {
      const hit = cacheIndex.get(name);
      if (!hit) continue;
      try {
        const cache = await caches.open(hit.cacheName);
        const response = await cache.match(hit.requestUrl);
        if (!response || !response.ok) continue;
        const blob = await response.blob();
        if (!blob || !blob.size) continue;
        state.matchedCacheEntries += 1;
        return { blob, source: hit.requestUrl, fileName: name };
      } catch (_) {
        // continue
      }
    }

    if (typeof task.original_url === 'string' && task.original_url) {
      try {
        const response = await fetch(task.original_url, {
          method: 'GET',
          credentials: 'same-origin',
          cache: 'force-cache',
        });
        if (response && response.ok) {
          const blob = await response.blob();
          if (blob && blob.size) {
            return {
              blob,
              source: task.original_url,
              fileName: normalizeName(task.expected_filename) || normalizeName(task.original_file_name) || 'recovered.bin',
            };
          }
        }
      } catch (_) {
        // ignore network/cache fallback errors
      }
    }

    return null;
  }

  async function uploadRecovered(task, blob, fileName) {
    const file = new File([blob], fileName || task.expected_filename || 'recovered.bin', {
      type: blob.type || 'application/octet-stream',
      lastModified: Date.now(),
    });
    const formData = new FormData();
    formData.append('task_id', task.id);
    formData.append('file', file, file.name);

    const response = await fetch('/api/profile/uploads-recovery/upload', {
      method: 'POST',
      headers: authHeaders(),
      credentials: 'same-origin',
      body: formData,
    });
    if (!response.ok) {
      const text = await response.text().catch(() => '');
      throw new Error(`upload_http_${response.status}:${text.slice(0, 160)}`);
    }
    return response.json().catch(() => ({}));
  }

  state.status = 'building_cache_index';
  const cacheIndex = await buildCacheIndex();
  state.cacheEntries = cacheIndex.size;

  for (let loop = 0; loop < 6; loop += 1) {
    state.loops = loop + 1;
    state.status = 'fetching_tasks';
    const tasks = await fetchTasks(1000);
    state.totalTasksSeen = Math.max(state.totalTasksSeen, tasks.length);
    if (!tasks.length) {
      state.status = 'done';
      return state;
    }

    let recoveredThisLoop = 0;
    state.status = 'recovering';
    for (const task of tasks) {
      state.scannedTasks += 1;
      const cached = await loadCachedBlob(cacheIndex, task);
      if (!cached) continue;
      try {
        await uploadRecovered(task, cached.blob, cached.fileName || task.expected_filename);
        recoveredThisLoop += 1;
        state.recovered += 1;
      } catch (error) {
        state.failures.push({
          task_id: task.id,
          expected_filename: task.expected_filename,
          error: String(error && error.message ? error.message : error),
        });
      }
    }

    if (recoveredThisLoop === 0) {
      state.status = 'done';
      return state;
    }
  }

  state.status = 'done';
  return state;
})().catch((error) => {
  window.__phoenixRecoveryState = {
    startedAt: new Date().toISOString(),
    status: 'error',
    recovered: 0,
    scannedTasks: 0,
    matchedCacheEntries: 0,
    failures: [String(error && error.message ? error.message : error)],
    loops: 0,
    totalTasksSeen: 0,
  };
  return window.__phoenixRecoveryState;
});
