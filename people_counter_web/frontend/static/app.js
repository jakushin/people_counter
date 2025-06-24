const canvas = document.getElementById('video-canvas');
const ctx = canvas.getContext('2d');
const statusDiv = document.getElementById('status');
const startBtn = document.getElementById('start-btn');
const scaleSlider = document.getElementById('scale-slider');
const scaleValue = document.getElementById('scale-value');

let ws = null;
let running = false;
let lastImg = null;
let lastImgW = 0;
let lastImgH = 0;
let reconnectTimeout = null;
let wsUrl = null;
let lastStats = {
  timestamp: null,
  fps: null,
  shape: null,
  bitrate: null,
  status: 'Нет соединения'
};

function setStatus(msg, error=false) {
  statusDiv.textContent = msg;
  statusDiv.style.color = error ? 'red' : 'green';
}

function drawOverlay(ctx, stats, w, h) {
  ctx.save();
  ctx.font = '13px monospace';
  ctx.textAlign = 'right';
  ctx.textBaseline = 'top';
  ctx.globalAlpha = 0.8;
  ctx.fillStyle = '#222';
  ctx.fillRect(w-180, 0, 180, 80);
  ctx.globalAlpha = 1.0;
  ctx.fillStyle = '#0f0';
  ctx.fillText('Статус: ' + (stats.status || ''), w-10, 5);
  ctx.fillStyle = '#fff';
  ctx.fillText('Время: ' + (stats.timestamp ? new Date(stats.timestamp*1000).toLocaleTimeString() : '-'), w-10, 22);
  ctx.fillText('FPS: ' + (stats.fps ?? '-'), w-10, 37);
  ctx.fillText('Размер: ' + (stats.shape ? stats.shape[0]+'x'+stats.shape[1] : '-'), w-10, 52);
  ctx.fillText('Bitrate: ' + (stats.bitrate ?? '-'), w-10, 67);
  ctx.restore();
}

function drawImageWithScale(img) {
  const scale = parseInt(scaleSlider.value, 10) / 100;
  const w = Math.round(img.width * scale);
  const h = Math.round(img.height * scale);
  canvas.width = w;
  canvas.height = h;
  ctx.clearRect(0, 0, w, h);
  ctx.drawImage(img, 0, 0, w, h);
  drawOverlay(ctx, lastStats, w, h);
}

scaleSlider.oninput = function() {
  scaleValue.textContent = scaleSlider.value;
  if (lastImg) {
    drawImageWithScale(lastImg);
  }
};

function connectWS() {
  if (!wsUrl) return;
  if (ws) ws.close();
  ws = new WebSocket(wsUrl);
  ws.binaryType = 'arraybuffer';
  setStatus('Подключение...', false);
  lastStats.status = 'Подключение...';
  ws.onopen = () => {
    setStatus('Поток запущен');
    lastStats.status = 'Поток запущен';
  };
  ws.onerror = e => {
    setStatus('Ошибка WebSocket', true);
    lastStats.status = 'Ошибка WebSocket';
  };
  ws.onclose = () => {
    setStatus('Поток остановлен, переподключение...', true);
    lastStats.status = 'Переподключение...';
    reconnectTimeout = setTimeout(connectWS, 3000);
  };
  ws.onmessage = (event) => {
    if (typeof event.data === 'string') {
      // статистика
      try {
        const stats = JSON.parse(event.data);
        lastStats = {...lastStats, ...stats};
        lastStats.status = 'Поток запущен';
        if (lastImg) drawImageWithScale(lastImg);
      } catch(e) {}
      return;
    }
    // бинарные данные (jpeg)
    const blob = new Blob([event.data], {type: 'image/jpeg'});
    const img = new window.Image();
    img.onload = function() {
      lastImg = img;
      lastImgW = img.width;
      lastImgH = img.height;
      drawImageWithScale(img);
    };
    img.onerror = function() {
      setStatus('Ошибка декодирования изображения', true);
      lastStats.status = 'Ошибка декодирования';
      if (lastImg) drawImageWithScale(lastImg);
    };
    img.src = URL.createObjectURL(blob);
  };
}

startBtn.onclick = () => {
  if (reconnectTimeout) clearTimeout(reconnectTimeout);
  const user = document.getElementById('user').value;
  const password = document.getElementById('password').value;
  const host = document.getElementById('host').value;
  wsUrl = `ws://${window.location.hostname}:8000/ws?user=${encodeURIComponent(user)}&password=${encodeURIComponent(password)}&host=${encodeURIComponent(host)}`;
  connectWS();
}; 