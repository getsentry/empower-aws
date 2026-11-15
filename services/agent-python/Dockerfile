FROM public.ecr.aws/docker/library/python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src ./src
ENV PYTHONUNBUFFERED=1 PORT=8001
EXPOSE 8001
# One process: chat sessions live in memory. Turns run in threads.
CMD ["python", "-m", "src.server"]
