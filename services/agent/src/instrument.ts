// Loaded with `node --import`, before anything else, so Sentry can patch the AWS SDK
// and Node's http and fetch.
import * as Sentry from '@sentry/node';

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  environment: process.env.SENTRY_ENVIRONMENT || 'aws-demo',
  release: process.env.SENTRY_RELEASE,
  tracesSampleRate: 1.0,
  enableLogs: true,
  // Trace headers go to the store API next to us, never to AWS or anywhere else.
  tracePropagationTargets: [/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?\//],
});
