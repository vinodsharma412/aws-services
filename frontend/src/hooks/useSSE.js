/**
 * usePolling — polling replacement for the previous SSE hook.
 *
 * Why polling instead of SSE:
 *   API Gateway + Lambda enforces a hard 29-second response timeout.
 *   SSE (Server-Sent Events) requires a long-lived connection that would be
 *   killed at 29 seconds.  Polling every 2 seconds is simpler, works through
 *   API Gateway, and has minimal DynamoDB cost (< 1 RCU per poll).
 *
 * Usage (drop-in replacement for the old useSSE hook):
 *   const { data, connected } = usePolling('/scraping/jobs', null, 2000);
 *   // data: latest JSON from the endpoint (or null on error)
 *   // connected: true while polling is active
 *
 * Polling stops automatically when:
 *   - path is set to null
 *   - the component unmounts
 *   - no active jobs remain (pending + running === 0) — pass a check function
 *
 * @param {string|null}  path          API path, e.g. "/scraping/jobs"
 * @param {*}            init          Initial value for `data`
 * @param {number}       intervalMs    Polling interval in ms (default 2000)
 * @param {function}     shouldStop    Optional: (data) => boolean — stop when true
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import api from '../services/api';

export default function usePolling(path, init = null, intervalMs = 2000, shouldStop = null) {
  const [data,      setData]      = useState(init);
  const [connected, setConnected] = useState(false);
  const timerRef  = useRef(null);
  const activeRef = useRef(false);

  const poll = useCallback(async () => {
    if (!activeRef.current || !path) return;

    try {
      const res = await api.get(path);
      setData(res.data);
      setConnected(true);

      // Stop polling when all jobs are complete (no pending/running)
      if (shouldStop && shouldStop(res.data)) {
        activeRef.current = false;
        setConnected(false);
        return;
      }
    } catch {
      setConnected(false);
    }

    if (activeRef.current) {
      timerRef.current = setTimeout(poll, intervalMs);
    }
  }, [path, intervalMs, shouldStop]);

  useEffect(() => {
    if (!path) return;

    activeRef.current = true;
    poll();

    return () => {
      activeRef.current = false;
      if (timerRef.current) clearTimeout(timerRef.current);
      setConnected(false);
    };
  }, [path, poll]);

  return { data, connected };
}

// Named export kept for backward compatibility with any direct import of useSSE
export { usePolling as useSSE };
