# Empower's flask-otlp store API, from sentry-demos/empower (see ../../README.md).
FROM public.ecr.aws/docker/library/python:3.11-slim-bookworm
WORKDIR /src
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
ENV PYTHONUNBUFFERED=1
EXPOSE 8080
# Two workers; each creates its own app, Sentry client and OTel exporter after the fork.
# empower-aws: threads, so a slow /products (pg_sleep on purpose) does not block /checkout.
CMD ["gunicorn", "--workers", "3", "--threads", "8", "--worker-class", "gthread", "--bind", "0.0.0.0:8080", "--timeout", "120", "app:app"]
