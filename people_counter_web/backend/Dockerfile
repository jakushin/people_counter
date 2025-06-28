FROM continuumio/miniconda3:latest
WORKDIR /app

# Установить libGL для OpenCV
RUN apt-get update && apt-get install -y libgl1

# Установить ffmpeg, opencv, numpy, ultralytics через conda
RUN conda install -y -c conda-forge ffmpeg opencv numpy && \
    pip install ultralytics fastapi uvicorn psutil

# Вывести версии основных библиотек
RUN python -c "import cv2, numpy, ultralytics, sys; print('Python', sys.version); print('OpenCV', cv2.__version__); print('Numpy', numpy.__version__); print('Ultralytics', ultralytics.__version__)" && \
    ffmpeg -version | head -1

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--log-level", "warning"] 