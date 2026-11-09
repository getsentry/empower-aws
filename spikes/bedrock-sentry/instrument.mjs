// Loaded with `node --import`, so Sentry patches the AWS SDK before it is imported.
import * as Sentry from '@sentry/node';

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  environment: 'spike',
  release: process.env.GITHUB_SHA,
  tracesSampleRate: 1.0,
  enableLogs: true,
});
