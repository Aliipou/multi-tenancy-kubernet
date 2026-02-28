FROM python:3.11-slim

WORKDIR /app

RUN adduser --uid 1001 --disabled-password --gecos "" appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

ENV PYTHONUNBUFFERED=1

USER 1001

CMD ["python", "main.py"]
