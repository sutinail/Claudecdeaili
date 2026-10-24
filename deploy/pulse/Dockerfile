FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir \
    -i https://mirrors.cloud.tencent.com/pypi/simple \
    --trusted-host mirrors.cloud.tencent.com \
    -r requirements.txt

ENV PYTHONUNBUFFERED=1

COPY . .

EXPOSE 8300 8301

CMD ["python", "start.py"]
