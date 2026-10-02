FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY notes ./notes
COPY tests ./tests
USER nobody
EXPOSE 3000
CMD ["python", "-m", "notes"]
