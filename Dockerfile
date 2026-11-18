FROM python:3.11-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY pyproject.toml README.md LICENSE ./
COPY spotified ./spotified
RUN pip install --no-cache-dir .

EXPOSE 4381
ENTRYPOINT ["spotified"]
