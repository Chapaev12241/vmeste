FROM python:3.12-slim
WORKDIR /app
COPY server.py .
ENV DATABASE_PATH=/data/ryadom.sqlite
RUN mkdir /data
EXPOSE 8080
CMD ["python", "server.py"]
