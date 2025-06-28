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

# Создать окружение и установить все зависимости в одном блоке
RUN conda create -y -n people python=3.10 && \
    conda init bash && \
    . ~/.bashrc && \
    conda activate people && \
    conda install -y -c conda-forge ffmpeg opencv numpy && \
    conda install -y -c pytorch pytorch=1.13.0 torchvision=0.14.0 cpuonly && \
    conda install -y -c conda-forge lap && \
    pip install ultralytics fastapi uvicorn psutil && \
    python -c "import cv2, numpy, ultralytics, torch, sys; print('Python', sys.version); print('OpenCV', cv2.__version__); print('Numpy', numpy.__version__); print('Ultralytics', ultralytics.__version__); print('PyTorch', torch.__version__)" && \
    ffmpeg -version | head -1

# Использовать bash как shell для активации окружения
SHELL ["/bin/bash", "-c"]

COPY requirements.txt .
COPY app ./app

# Установить дополнительные зависимости из requirements.txt
RUN source ~/.bashrc && conda activate people && pip install --no-cache-dir -r requirements.txt

CMD ["/bin/bash", "-c", "source ~/.bashrc && conda activate people && uvicorn app.main:app --host 0.0.0.0 --port 8000 --log-level warning"] 