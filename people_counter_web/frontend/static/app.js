const canvas = document.getElementById('video-canvas');
const ctx = canvas.getContext('2d');
const statusDiv = document.getElementById('status');
const startBtn = document.getElementById('start-btn');
const container = document.getElementById('container');
const roiSvg = document.getElementById('roi-svg');
const resetRoiBtn = document.getElementById('reset-roi-btn');

let ws = null;
let running = false;
let lastImg = null;
let lastImgW = 0;
let lastImgH = 0;
let reconnectTimeout = null;
let wsUrl = null;
let manualClose = false; // Флаг для предотвращения автопереподключения
let lastStats = {
  timestamp: null,
  fps: null,
  shape: null,
  cpu_all: null,
  cpu_cores: [],
  mem_percent: null,
  mem_total_gb: null,
  mem_used_gb: null,
  mem_available_gb: null,
  disk_percent: null,
  disk_total_gb: null,
  disk_used_gb: null,
  disk_read_speed: 0,
  disk_write_speed: 0,
  disk_read_latency: 0,
  disk_write_latency: 0,
  net_sent_mbps: null,
  net_recv_mbps: null,
  status: 'Нет соединения',
  crop_h: null,
  crop_w: null,
  imgsz: null,
  frame_count: null,
  source_type: null,
  detect_time: null
};
let bytesReceived = [];
let roiPoints = null;
let draggingVertex = null;
let draggingMid = null;
let roiScale = 1;
let pendingRoi = null; // Для хранения ROI, если lastImg ещё не загружен
let roiReceivedFromBackend = false; // Новый флаг

// Video management variables
let currentSource = 'camera'; // 'camera' or 'video'
let videoList = [];
let currentVideo = null;

function setStatus(msg, error=false) {
  statusDiv.textContent = msg;
  statusDiv.style.color = error ? 'red' : 'green';
}

function formatBytes(bytes) {
  if (bytes === 0) return '0 B/s';
  const k = 1024;
  const sizes = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
}

function formatLatency(ops) {
  if (ops === 0) return '0 ops/s';
  if (ops < 1) return (ops * 1000).toFixed(1) + ' mops/s';
  if (ops < 1000) return ops.toFixed(1) + ' ops/s';
  return (ops / 1000).toFixed(1) + ' kops/s';
}

function formatMetric(value, unit, maxWidth = 8) {
  const text = value + unit;
  return text.padStart(maxWidth);
}

function formatFPS(fps) {
  if (fps === null || fps === undefined) return '   -';
  const fpsText = fps.toFixed(1);
  return fpsText.padStart(5); // 5 символов для FPS (например: " 9.5")
}

function formatDiskMetric(value, formatter) {
  const formatted = formatter(value);
  return formatted.padStart(12); // 12 символов для disk метрик
}

function drawOverlay(ctx, stats, w, h) {
  ctx.save();
  ctx.font = '12px monospace';
  ctx.textAlign = 'right';
  ctx.textBaseline = 'top';
  ctx.globalAlpha = 0.8;
  ctx.fillStyle = '#222';
  ctx.fillRect(w-220, 0, 220, 300); // Увеличиваем высоту для всех CPU ядер
  ctx.globalAlpha = 1.0;
  
  let y = 5;
  const lineHeight = 16;
  
  // Статус
  ctx.fillStyle = '#0f0';
  ctx.fillText('Статус: ' + (stats.status || ''), w-10, y);
  y += lineHeight;
  
  // Время
  ctx.fillStyle = '#fff';
  ctx.fillText('Время: ' + (stats.timestamp ? new Date(stats.timestamp*1000).toLocaleTimeString() : '-'), w-10, y);
  y += lineHeight;
  
  // FPS (выравнивание по 5 символам)
  ctx.fillText('FPS: ' + formatFPS(stats.fps), w-10, y);
  y += lineHeight;
  
  // Размер кадра
  ctx.fillText('Размер: ' + (stats.shape ? stats.shape[0]+'x'+stats.shape[1] : '-'), w-10, y);
  y += lineHeight;
  
  // CPU общий (выравнивание по 3 символам) - жирный и увеличенный шрифт
  ctx.fillStyle = '#ff6b6b';
  ctx.font = 'bold 14px monospace'; // Увеличиваем шрифт с 12px до 14px и делаем жирным
  const cpuAllText = 'CPU_all: ' + formatMetric(Math.round(stats.cpu_all || 0), '%', 3);
  ctx.fillText(cpuAllText, w-10, y);
  y += lineHeight;
  
  // Возвращаем обычный шрифт для остальных метрик
  ctx.font = '12px monospace';
  
  // CPU по ядрам (все ядра, отсортированные по номеру, выравнивание по 3 символам)
  if (stats.cpu_cores && stats.cpu_cores.length > 0) {
    // Создаем массив с индексами для сортировки
    const cpuWithIndex = stats.cpu_cores.map((value, index) => ({ value: Math.round(value), index }));
    // Сортируем по индексу (номеру ядра)
    cpuWithIndex.sort((a, b) => a.index - b.index);
    
    for (let i = 0; i < cpuWithIndex.length; i++) {
      ctx.fillStyle = '#ff8e8e';
      const cpuText = `CPU_${(cpuWithIndex[i].index + 1).toString().padStart(2)}: ${formatMetric(cpuWithIndex[i].value, '%', 3)}`;
      ctx.fillText(cpuText, w-10, y);
      y += lineHeight;
    }
  }
  
  // Память с информацией о размере (выравнивание по 3 символам)
  ctx.fillStyle = '#4ecdc4';
  const memPercent = Math.round(stats.mem_percent || 0);
  const memText = `MEM: ${formatMetric(memPercent, '%', 3)} (${stats.mem_used_gb}/${stats.mem_total_gb}GB)`;
  ctx.fillText(memText, w-10, y);
  y += lineHeight;
  
  // Диск (выравнивание по 3 символам)
  ctx.fillStyle = '#45b7d1';
  const diskPercent = Math.round(stats.disk_percent || 0);
  const diskText = `DISK: ${formatMetric(diskPercent, '%', 3)} (${stats.disk_used_gb}/${stats.disk_total_gb}GB)`;
  ctx.fillText(diskText, w-10, y);
  y += lineHeight;
  
  // Диск I/O (всегда показываем, выравнивание по 12 символам)
  ctx.fillStyle = '#ff9ff3';
  const diskReadText = 'DISK_R: ' + formatDiskMetric(stats.disk_read_speed, formatBytes);
  ctx.fillText(diskReadText, w-10, y);
  y += lineHeight;
  const diskWriteText = 'DISK_W: ' + formatDiskMetric(stats.disk_write_speed, formatBytes);
  ctx.fillText(diskWriteText, w-10, y);
  y += lineHeight;
  
  // Диск Latency (всегда показываем, выравнивание по 12 символам)
  ctx.fillStyle = '#ff6b9d';
  const diskReadLatText = 'DISK_RL: ' + formatDiskMetric(stats.disk_read_latency, formatLatency);
  ctx.fillText(diskReadLatText, w-10, y);
  y += lineHeight;
  const diskWriteLatText = 'DISK_WL: ' + formatDiskMetric(stats.disk_write_latency, formatLatency);
  ctx.fillText(diskWriteLatText, w-10, y);
  y += lineHeight;
  
  // Сеть (выравнивание по 4 символам)
  ctx.fillStyle = '#a55eea';
  const netSentText = 'NET_S: ' + formatMetric(Math.round(stats.net_sent_mbps || 0), 'Mbps', 4);
  ctx.fillText(netSentText, w-10, y);
  y += lineHeight;
  const netRecvText = 'NET_R: ' + formatMetric(Math.round(stats.net_recv_mbps || 0), 'Mbps', 4);
  ctx.fillText(netRecvText, w-10, y);
  y += lineHeight;
  
  // Crop и imgsz
  ctx.fillStyle = '#ff0';
  ctx.fillText('Crop: ' + (stats.crop_w && stats.crop_h ? stats.crop_w + 'x' + stats.crop_h : '-'), w-10, y);
  y += lineHeight;
  ctx.fillText('imgsz: ' + (stats.imgsz || '-'), w-10, y);
  y += lineHeight;
  
  // Информация о видео
  if (currentVideo) {
    ctx.fillStyle = '#ffa500';
    ctx.fillText('Video: ' + currentVideo.substring(0, 15) + '...', w-10, y);
  }
  
  ctx.restore();
}

function getDefaultRoiPoints(imgW, imgH) {
  // 50px отступ, но не менее 10% ширины/высоты
  const pad = 50;
  return [
    [pad, pad],
    [imgW - pad, pad],
    [imgW - pad, imgH - pad],
    [pad, imgH - pad]
  ];
}

function drawRoi() {
  if (!roiPoints || !lastImg) { roiSvg.innerHTML = ''; return; }
  const contRect = container.getBoundingClientRect();
  roiSvg.setAttribute('width', contRect.width);
  roiSvg.setAttribute('height', contRect.height);
  roiSvg.style.width = contRect.width + 'px';
  roiSvg.style.height = contRect.height + 'px';
  const scale = Math.min(contRect.width / lastImg.width, contRect.height / lastImg.height);
  roiScale = scale;
  const offsetX = (contRect.width - lastImg.width * scale) / 2;
  const offsetY = (contRect.height - lastImg.height * scale) / 2;
  const pointsStr = roiPoints.map(([x, y]) => `${x * scale + offsetX},${y * scale + offsetY}`).join(' ');
  const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
  polygon.setAttribute('points', pointsStr);
  polygon.setAttribute('class', 'roi-polygon');
  roiSvg.innerHTML = '';
  roiSvg.appendChild(polygon);
  // Вершины
  roiPoints.forEach(([x, y], i) => {
    const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    circle.setAttribute('cx', x * scale + offsetX);
    circle.setAttribute('cy', y * scale + offsetY);
    circle.setAttribute('r', 8);
    circle.setAttribute('class', 'roi-vertex');
    circle.setAttribute('data-idx', i);
    circle.addEventListener('mousedown', e => { draggingVertex = i; e.stopPropagation(); });
    roiSvg.appendChild(circle);
  });
  // Средние точки
  for (let i = 0; i < roiPoints.length; i++) {
    const next = (i + 1) % roiPoints.length;
    const mx = (roiPoints[i][0] + roiPoints[next][0]) / 2;
    const my = (roiPoints[i][1] + roiPoints[next][1]) / 2;
    const midCircle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    midCircle.setAttribute('cx', mx * scale + offsetX);
    midCircle.setAttribute('cy', my * scale + offsetY);
    midCircle.setAttribute('r', 6);
    midCircle.setAttribute('class', 'roi-midpoint');
    midCircle.addEventListener('mousedown', e => { draggingMid = i + 1; e.stopPropagation(); });
    roiSvg.appendChild(midCircle);
  }
}

function sendRoi() {
  if (ws && ws.readyState === 1 && roiPoints) {
    ws.send(JSON.stringify({ type: 'roi', points: roiPoints }));
  }
}

function drawRoiMask(ctx, img, scale, x, y) {
  if (!roiPoints || roiPoints.length < 3) return;
  // Сначала рисуем полупрозрачную маску на область изображения
  ctx.save();
  ctx.globalAlpha = 1.0;
  ctx.beginPath();
  ctx.rect(x, y, img.width * scale, img.height * scale);
  ctx.closePath();
  ctx.fillStyle = 'rgba(0,0,0,0.18)';
  ctx.fill();
  // Затем вырезаем ROI
  ctx.globalCompositeOperation = 'destination-out';
  ctx.beginPath();
  const [startX, startY] = [roiPoints[0][0] * scale + x, roiPoints[0][1] * scale + y];
  ctx.moveTo(startX, startY);
  for (let i = 1; i < roiPoints.length; i++) {
    ctx.lineTo(roiPoints[i][0] * scale + x, roiPoints[i][1] * scale + y);
  }
  ctx.closePath();
  ctx.fill();
  ctx.restore();
}

function fitAndDrawImage(img) {
  const contRect = container.getBoundingClientRect();
  canvas.width = contRect.width;
  canvas.height = contRect.height;
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  const scale = Math.min(canvas.width / img.width, canvas.height / img.height);
  const imgW = img.width * scale;
  const imgH = img.height * scale;
  const x = (canvas.width - imgW) / 2;
  const y = (canvas.height - imgH) / 2;
  ctx.drawImage(img, x, y, imgW, imgH);
  drawOverlay(ctx, lastStats, canvas.width, canvas.height);
  drawRoi();
}

function updateFit() {
  if (lastImg) {
    fitAndDrawImage(lastImg);
  }
}

window.addEventListener('resize', updateFit);

function connectWS() {
  const user = document.getElementById('user').value;
  const password = document.getElementById('password').value;
  const host = document.getElementById('host').value;
  
  if (currentSource === 'camera' && (!user || !password || !host)) {
    setStatus('Заполните все поля для камеры', true);
    return;
  }
  
  if (currentSource === 'video' && !currentVideo) {
    setStatus('Выберите видео для запуска', true);
    return;
  }
  
  // Формируем WebSocket URL без параметров
  const wsUrl = `ws://${window.location.host}/ws`;
  console.log('Connecting to WebSocket:', wsUrl);
  
  setStatus('Подключение...', false);
  ws = new WebSocket(wsUrl);
  ws.binaryType = 'arraybuffer';
  lastStats.status = 'Подключение...';
  roiReceivedFromBackend = false; // Сброс при новом подключении
  
  ws.onopen = function(event) {
    console.log('WebSocket connected, sending auth...');
    
    // Отправляем учетные данные через сообщение
    let authData;
    if (currentSource === 'video') {
      // Для видео используем фиктивные параметры
      authData = {
        type: 'auth',
        user: 'dummy',
        password: 'dummy',
        host: 'dummy'
      };
    } else {
      // Для камеры используем реальные параметры
      authData = {
        type: 'auth',
        user: user,
        password: password,
        host: host
      };
    }
    
    ws.send(JSON.stringify(authData));
    setStatus('Подключено', false);
    lastStats.status = 'Подключено';
    if (lastImg) {
      drawRoi();
    }
  };
  ws.onerror = function(error) {
    console.error('WebSocket error:', error);
    setStatus('Ошибка WebSocket', true);
  };
  ws.onclose = function(event) {
    console.log('WebSocket closed:', event.code, event.reason);
    setStatus('Соединение разорвано', true);
    
    // Не переподключаемся если это было ручное закрытие
    if (manualClose) {
      console.log('Manual close detected, not reconnecting');
      manualClose = false;
      return;
    }
    
    if (reconnectTimeout) clearTimeout(reconnectTimeout);
    reconnectTimeout = setTimeout(connectWS, 5000);
  };
  ws.onmessage = function(event) {
    if (event.data instanceof ArrayBuffer) {
      // Получение изображения
      const arrayBuffer = event.data;
      const uint8Array = new Uint8Array(arrayBuffer);
      const blob = new Blob([uint8Array], { type: 'image/jpeg' });
      const url = URL.createObjectURL(blob);
      
      const img = new Image();
      img.onload = function() {
        lastImg = img;
        lastImgW = img.width;
        lastImgH = img.height;
        fitAndDrawImage(img);
        URL.revokeObjectURL(url);
      };
      img.onerror = function() {
        console.error('Failed to load image');
        lastStats.status = 'Ошибка декодирования';
      };
      img.src = url;
    } else {
      // Получение метаданных
      try {
        const stats = JSON.parse(event.data);
        
        // Дебаг логи для диагностики проблемы с обновлением
        const now = Date.now();
        if (!window.lastStatsUpdate) {
          window.lastStatsUpdate = now;
          window.statsUpdateCount = 0;
          window.statsHistory = [];
        }
        
        window.statsUpdateCount++;
        const timeSinceLastUpdate = now - window.lastStatsUpdate;
        
        // Сохраняем историю обновлений для анализа
        window.statsHistory.push({
          timestamp: now,
          cpu_all: stats.cpu_all,
          mem_percent: stats.mem_percent,
          fps: stats.fps,
          frame_count: stats.frame_count
        });
        
        // Оставляем только последние 50 обновлений
        if (window.statsHistory.length > 50) {
          window.statsHistory.shift();
        }
        
        // Логируем каждые 10 обновлений или каждые 5 секунд
        if (window.statsUpdateCount % 10 === 0 || timeSinceLastUpdate > 5000) {
          const avgUpdateRate = window.statsHistory.length > 1 ? 
            (window.statsHistory.length - 1) / ((now - window.statsHistory[0].timestamp) / 1000) : 0;
          
          console.log(`[DEBUG] Stats update #${window.statsUpdateCount}:`, {
            timestamp: stats.timestamp,
            timeSinceLastUpdate: timeSinceLastUpdate + 'ms',
            updateRate: (window.statsUpdateCount / (timeSinceLastUpdate / 1000)).toFixed(2) + ' updates/sec',
            avgUpdateRate: avgUpdateRate.toFixed(2) + ' updates/sec',
            historySize: window.statsHistory.length,
            cpu_all: stats.cpu_all,
            mem_percent: stats.mem_percent,
            fps: stats.fps,
            frame_count: stats.frame_count
          });
          
          // Анализируем частоту обновлений
          if (window.statsHistory.length > 10) {
            const recentUpdates = window.statsHistory.slice(-10);
            const intervals = [];
            for (let i = 1; i < recentUpdates.length; i++) {
              intervals.push(recentUpdates[i].timestamp - recentUpdates[i-1].timestamp);
            }
            const avgInterval = intervals.reduce((a, b) => a + b, 0) / intervals.length;
            const minInterval = Math.min(...intervals);
            const maxInterval = Math.max(...intervals);
            
            console.log(`[DEBUG] Update intervals analysis:`, {
              avgInterval: avgInterval.toFixed(0) + 'ms',
              minInterval: minInterval + 'ms',
              maxInterval: maxInterval + 'ms',
              variance: intervals.length > 1 ? 
                (intervals.reduce((a, b) => a + Math.pow(b - avgInterval, 2), 0) / (intervals.length - 1)).toFixed(0) + 'ms²' : 'N/A'
            });
          }
          
          window.lastStatsUpdate = now;
          window.statsUpdateCount = 0;
        }
        
        // Если это ROI от backend
        if (stats.type === 'roi' && Array.isArray(stats.points)) {
          roiReceivedFromBackend = true;
          roiPoints = stats.points;
          drawRoi();
          updateFit();
          return;
        }
        lastStats = { ...lastStats, ...stats };
        lastStats.status = 'Поток запущен';
        if (lastImg) updateFit();
      } catch (e) {
        console.error('Failed to parse stats:', e);
      }
    }
  };
}

startBtn.onclick = async () => {
  if (reconnectTimeout) clearTimeout(reconnectTimeout);
  
  // Останавливаем предыдущий источник перед подключением к новому
  await resetVideoState();
  
  connectWS();
};

// --- ROI mouse events ---
function getRoiMousePos(e) {
  const contRect = container.getBoundingClientRect();
  const scale = roiScale;
  const offsetX = (contRect.width - lastImg.width * scale) / 2;
  const offsetY = (contRect.height - lastImg.height * scale) / 2;
  const x = (e.clientX - contRect.left - offsetX) / scale;
  const y = (e.clientY - contRect.top - offsetY) / scale;
  return [x, y];
}

// --- ROI pointer events ---
let pointerDown = false;
let pointerId = null;
roiSvg.addEventListener('pointerdown', e => {
  if (e.target.classList.contains('roi-vertex')) {
    draggingVertex = parseInt(e.target.getAttribute('data-idx'));
    pointerDown = true;
    pointerId = e.pointerId;
    roiSvg.setPointerCapture(pointerId);
    e.stopPropagation();
  } else if (e.target.classList.contains('roi-midpoint')) {
    draggingMid = Array.from(roiSvg.querySelectorAll('.roi-midpoint')).indexOf(e.target) + 1;
    pointerDown = true;
    pointerId = e.pointerId;
    roiSvg.setPointerCapture(pointerId);
    e.stopPropagation();
  }
});
roiSvg.addEventListener('pointermove', e => {
  if (!pointerDown || e.pointerId !== pointerId) return;
  if (draggingVertex !== null && lastImg) {
    const [x, y] = getRoiMousePos(e);
    roiPoints[draggingVertex] = [Math.max(0, Math.min(lastImg.width, x)), Math.max(0, Math.min(lastImg.height, y))];
    drawRoi();
    sendRoi();
  }
});
roiSvg.addEventListener('pointerup', e => {
  if (e.pointerId !== pointerId) return;
  pointerDown = false;
  pointerId = null;
  if (draggingVertex !== null) draggingVertex = null;
  if (draggingMid !== null && lastImg) {
    const [x, y] = getRoiMousePos(e);
    roiPoints.splice(draggingMid, 0, [Math.max(0, Math.min(lastImg.width, x)), Math.max(0, Math.min(lastImg.height, y))]);
    draggingMid = null;
    drawRoi();
    sendRoi();
  }
  roiSvg.releasePointerCapture(e.pointerId);
});
roiSvg.addEventListener('pointerleave', e => {
  pointerDown = false;
  pointerId = null;
  draggingVertex = null;
  draggingMid = null;
});

resetRoiBtn.onclick = () => {
  if (lastImg) {
    roiPoints = getDefaultRoiPoints(lastImg.width, lastImg.height);
    drawRoi();
    sendRoi();
  }
};

// Добавляем обработчик contextmenu для удаления точки по правому клику
roiSvg.addEventListener('contextmenu', function(e) {
  if (e.target.classList.contains('roi-vertex')) {
    e.preventDefault();
    const idx = parseInt(e.target.getAttribute('data-idx'));
    if (roiPoints.length > 3 && idx >= 0 && idx < roiPoints.length) {
      roiPoints.splice(idx, 1);
      drawRoi();
      sendRoi();
    }
  }
});

// --- Автозаполнение и автосохранение user/password/host через localStorage ---
window.addEventListener('DOMContentLoaded', () => {
  const userInput = document.getElementById('user');
  const passwordInput = document.getElementById('password');
  const hostInput = document.getElementById('host');
  // Подставить значения из localStorage
  if (localStorage.getItem('pc_user')) userInput.value = localStorage.getItem('pc_user');
  if (localStorage.getItem('pc_password')) passwordInput.value = localStorage.getItem('pc_password');
  if (localStorage.getItem('pc_host')) hostInput.value = localStorage.getItem('pc_host');
  // Сохранять при изменении
  userInput.addEventListener('input', e => localStorage.setItem('pc_user', userInput.value));
  passwordInput.addEventListener('input', e => localStorage.setItem('pc_password', passwordInput.value));
  hostInput.addEventListener('input', e => localStorage.setItem('pc_host', hostInput.value));
  
  // Video controls event handlers
  const cameraSource = document.getElementById('camera-source');
  const videoSource = document.getElementById('video-source');
  const uploadBtn = document.getElementById('upload-btn');
  const startVideoBtn = document.getElementById('start-video-btn');
  const stopVideoBtn = document.getElementById('stop-video-btn');
  
  cameraSource.addEventListener('change', async () => {
    console.log('[DEBUG] Camera source selected');
    currentSource = 'camera';
    updateSourceControls();
    await resetVideoState();
  });
  
  videoSource.addEventListener('change', async () => {
    console.log('[DEBUG] Video source selected');
    currentSource = 'video';
    updateSourceControls();
    loadVideoList();
    await resetVideoState();
  });
  
  uploadBtn.addEventListener('click', uploadVideo);
  startVideoBtn.addEventListener('click', startVideo);
  stopVideoBtn.addEventListener('click', stopVideo);
  
  // Initialize source controls
  updateSourceControls();
});

// Video management functions
async function loadVideoList() {
  try {
    const response = await fetch('/api/videos');
    const data = await response.json();
    videoList = data.videos || [];
    updateVideoSelect();
  } catch (error) {
    console.error('Failed to load video list:', error);
  }
}

function updateVideoSelect() {
  const select = document.getElementById('video-select');
  select.innerHTML = '<option value="">Выберите видео...</option>';
  videoList.forEach(video => {
    const option = document.createElement('option');
    option.value = video;
    option.textContent = video;
    select.appendChild(option);
  });
}

async function uploadVideo() {
  const fileInput = document.getElementById('video-file');
  const file = fileInput.files[0];
  if (!file) {
    alert('Выберите файл для загрузки');
    return;
  }
  
  const formData = new FormData();
  formData.append('file', file);
  
  // Показываем прогресс-бар
  const progressDiv = document.getElementById('upload-progress');
  const progressFill = document.querySelector('.progress-fill');
  const progressText = document.querySelector('.progress-text');
  
  console.log('Progress elements:', { progressDiv, progressFill, progressText });
  
  if (!progressDiv || !progressFill || !progressText) {
    console.error('Progress bar elements not found!');
    setStatus('Ошибка: элементы прогресс-бара не найдены', true);
    return;
  }
  
  progressDiv.style.display = 'block';
  progressFill.style.width = '0%';
  progressText.textContent = 'Загрузка файла...';
  
  console.log('Progress bar shown, starting upload...');
  
  try {
    // Симулируем прогресс загрузки
    const progressInterval = setInterval(() => {
      const currentWidth = parseInt(progressFill.style.width) || 0;
      if (currentWidth < 90) {
        progressFill.style.width = (currentWidth + 10) + '%';
        if (currentWidth < 30) {
          progressText.textContent = 'Загрузка файла...';
        } else if (currentWidth < 60) {
          progressText.textContent = 'Конвертация видео...';
        } else {
          progressText.textContent = 'Завершение...';
        }
      }
    }, 500);
    
    setStatus('Загрузка и конвертация видео...', false);
    const response = await fetch('/api/videos/upload', {
      method: 'POST',
      body: formData
    });
    
    clearInterval(progressInterval);
    progressFill.style.width = '100%';
    progressText.textContent = 'Готово!';
    
    if (response.ok) {
      const result = await response.json();
      console.log('Upload response:', result);
      setStatus(`Видео загружено и сконвертировано: ${result.filename}`, false);
      await loadVideoList();
      fileInput.value = '';
      
      // Скрываем прогресс-бар через 2 секунды
      setTimeout(() => {
        progressDiv.style.display = 'none';
      }, 2000);
    } else {
      const error = await response.json();
      setStatus(`Ошибка загрузки: ${error.detail}`, true);
      progressText.textContent = 'Ошибка!';
      progressFill.style.background = '#ff4444';
      
      // Скрываем прогресс-бар через 3 секунды
      setTimeout(() => {
        progressDiv.style.display = 'none';
        progressFill.style.background = 'linear-gradient(90deg, #ffa500, #ffb733)';
      }, 3000);
    }
  } catch (error) {
    setStatus('Ошибка загрузки видео', true);
    console.error('Upload error:', error);
    progressText.textContent = 'Ошибка!';
    progressFill.style.background = '#ff4444';
    
    // Скрываем прогресс-бар через 3 секунды
    setTimeout(() => {
      progressDiv.style.display = 'none';
      progressFill.style.background = 'linear-gradient(90deg, #ffa500, #ffb733)';
    }, 3000);
  }
}

async function startVideo() {
  const select = document.getElementById('video-select');
  const videoFile = select.value;
  if (!videoFile) {
    alert('Выберите видео для запуска');
    return;
  }
  
  console.log('Starting video:', videoFile);
  
  try {
    setStatus('Запуск видео...', false);
    const response = await fetch(`/api/videos/start?video_filename=${encodeURIComponent(videoFile)}`, {
      method: 'POST'
    });
    
    console.log('Start video response:', response.status, response.statusText);
    
    if (response.ok) {
      const result = await response.json();
      console.log('Start video result:', result);
      setStatus(`Видео запущено: ${videoFile}`, false);
      currentVideo = videoFile;
      
      // Закрываем текущий WebSocket если он открыт
      if (ws && ws.readyState === 1) {
        console.log('Closing existing WebSocket connection');
        manualClose = true;
        ws.close();
      }
      
      // Автоматически подключаем WebSocket для видео файла
      setTimeout(() => {
        console.log('Automatically connecting WebSocket for video');
        connectWS();
      }, 1000);
    } else {
      const error = await response.json();
      console.error('Start video error:', error);
      setStatus(`Ошибка запуска: ${error.detail}`, true);
    }
  } catch (error) {
    console.error('Start video exception:', error);
    setStatus('Ошибка запуска видео', true);
  }
}

async function stopVideo() {
  try {
    const response = await fetch('/api/videos/stop', {
      method: 'POST'
    });
    
    if (response.ok) {
      setStatus('Видео остановлено', false);
      currentVideo = null;
      
      // Закрываем текущий WebSocket если он открыт
      if (ws && ws.readyState === 1) {
        console.log('Closing WebSocket connection after stopping video');
        manualClose = true;
        ws.close();
      }
    } else {
      setStatus('Ошибка остановки видео', true);
    }
  } catch (error) {
    setStatus('Ошибка остановки видео', true);
    console.error('Stop video error:', error);
  }
}

function updateSourceControls() {
  const cameraControls = document.getElementById('camera-controls');
  const videoControls = document.getElementById('video-controls');
  const startBtn = document.getElementById('start-btn');
  
  console.log('[DEBUG] updateSourceControls called');
  console.log('[DEBUG] currentSource:', currentSource);
  console.log('[DEBUG] Elements found:', { cameraControls, videoControls, startBtn });
  
  if (currentSource === 'camera') {
    console.log('[DEBUG] Setting camera mode');
    cameraControls.style.display = 'block';
    videoControls.style.display = 'none';
    startBtn.style.display = 'block'; // Показываем кнопку Старт для камеры
    console.log('[DEBUG] Start button display set to:', startBtn.style.display);
  } else {
    console.log('[DEBUG] Setting video mode');
    cameraControls.style.display = 'none';
    videoControls.style.display = 'block';
    startBtn.style.display = 'none'; // Скрываем кнопку Старт для видео файла
    console.log('[DEBUG] Start button display set to:', startBtn.style.display);
  }
}

async function resetVideoState() {
  console.log('Resetting video state due to source change');
  
  // Останавливаем видео на backend если оно запущено
  if (currentVideo) {
    try {
      console.log('Stopping current video on backend:', currentVideo);
      const response = await fetch('/api/videos/stop', {
        method: 'POST'
      });
      
      if (response.ok) {
        console.log('Video stopped successfully on backend');
        setStatus('Предыдущий источник остановлен', false);
      } else {
        console.warn('Failed to stop video on backend');
      }
    } catch (error) {
      console.error('Error stopping video on backend:', error);
    }
  }
  
  // Сбрасываем состояние
  currentVideo = null;
  
  // Закрываем WebSocket соединение
  if (ws && ws.readyState === 1) {
    console.log('Closing WebSocket connection due to source change');
    manualClose = true;
    ws.close();
  }
} 