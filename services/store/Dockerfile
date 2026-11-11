# Empower's flask-otlp store API, from sentry-demos/empower (see ../../README.md).
FROM public.ecr.aws/docker/library/python:3.11-slim-bookworm
WORKDIR /src
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
ENV PYTHONUNBUFFERED=1
EXPOSE 8080
# Two workers; each creates its own app, Sentry client and OTel exporter after the fork.
CMD ["gunicorn", "--workers", "2", "--bind", "0.0.0.0:8080", "--timeout", "120", "app:app"]
