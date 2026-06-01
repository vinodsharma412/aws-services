// API URL comes from the environment build variable (set during CI/CD).
// Falls back to localhost:9000 for local development.
export const API_URL =
  process.env.REACT_APP_API_URL ||
  `http://localhost:9000/api/v1`;

// TOKEN_KEY is the localStorage key for the JWT access token.
export const TOKEN_KEY = 'access_token';

// NOTE: REACT_APP_SSE_URL is removed.
// Real-time scraping progress now uses polling (usePolling hook)
// instead of SSE, because API Gateway + Lambda has a 29-second timeout
// that breaks long-lived SSE connections.
