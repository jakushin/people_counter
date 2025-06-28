FROM continuumio/miniconda3:latest
WORKDIR /app

# Установить libGL для OpenCV и build tools для компиляции
RUN apt-get update && apt-get install -y \
    libgl1 \
    build-essential \
    gcc \
    g++ \
    make \
    cmake \
    pkg-config

# Создать новое окружение с python=3.10
RUN conda create -y -n people python=3.10 && \
    echo "conda activate people" >> ~/.bashrc

# Использовать bash как shell для активации окружения
SHELL ["/bin/bash", "-c"]

# Установить зависимости в окружение
RUN conda activate people && \
    conda install -y -c conda-forge ffmpeg opencv numpy && \
    conda install -y -c pytorch pytorch torchvision cpuonly && \
    pip install ultralytics fastapi uvicorn psutil

# Вывести версии основных библиотек
RUN conda activate people && \
    python -c "import cv2, numpy, ultralytics, torch, sys; print('Python', sys.version); print('OpenCV', cv2.__version__); print('Numpy', numpy.__version__); print('Ultralytics', ultralytics.__version__); print('PyTorch', torch.__version__)" && \
    ffmpeg -version | head -1

COPY requirements.txt .
RUN conda activate people && pip install --no-cache-dir -r requirements.txt
COPY app ./app
CMD ["/bin/bash", "-c", "conda activate people && uvicorn app.main:app --host 0.0.0.0 --port 8000 --log-level warning"] 