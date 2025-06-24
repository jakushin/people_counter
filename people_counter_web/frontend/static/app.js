const canvas = document.getElementById('video-canvas');
const ctx = canvas.getContext('2d');
const statusDiv = document.getElementById('status');
const startBtn = document.getElementById('start-btn');
const container = document.getElementById('container');

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
let bytesReceived = [];

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

function fitAndDrawImage(img) {
  // canvas всегда равен размеру контейнера
  const contRect = container.getBoundingClientRect();
  canvas.width = contRect.width;
  canvas.height = contRect.height;
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  // вычисляем масштаб fit to window
  const scale = Math.min(canvas.width / img.width, canvas.height / img.height);
  const imgW = img.width * scale;
  const imgH = img.height * scale;
  // центрируем
  const x = (canvas.width - imgW) / 2;
  const y = (canvas.height - imgH) / 2;
  ctx.drawImage(img, x, y, imgW, imgH);
  drawOverlay(ctx, lastStats, canvas.width, canvas.height);
}

function updateFit() {
  if (lastImg) {
    fitAndDrawImage(lastImg);
  }
}

window.addEventListener('resize', updateFit);

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
    bytesReceived = [];
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
        // bitrate вычисляется по bytesReceived
        const now = Date.now();
        bytesReceived = bytesReceived.filter(b => now - b.t < 2000); // 2 сек
        const total = bytesReceived.reduce((s, b) => s + b.n, 0);
        lastStats.bitrate = (total * 8 / 2 / 1000).toFixed(1) + ' kbps';
        if (lastImg) updateFit();
      } catch(e) {}
      return;
    }
    // бинарные данные (jpeg)
    const blob = new Blob([event.data], {type: 'image/jpeg'});
    bytesReceived.push({n: blob.size, t: Date.now()});
    const img = new window.Image();
    img.onload = function() {
      lastImg = img;
      lastImgW = img.width;
      lastImgH = img.height;
      updateFit();
    };
    img.onerror = function() {
      setStatus('Ошибка декодирования изображения', true);
      lastStats.status = 'Ошибка декодирования';
      if (lastImg) updateFit();
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