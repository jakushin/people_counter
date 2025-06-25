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
let lastStats = {
  timestamp: null,
  fps: null,
  shape: null,
  cpu: null,
  mem: null,
  status: 'Нет соединения'
};
let bytesReceived = [];
let roiPoints = null;
let draggingVertex = null;
let draggingMid = null;
let roiScale = 1;
let pendingRoi = null; // Для хранения ROI, если lastImg ещё не загружен

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
  ctx.fillRect(w-180, 0, 180, 95);
  ctx.globalAlpha = 1.0;
  ctx.fillStyle = '#0f0';
  ctx.fillText('Статус: ' + (stats.status || ''), w-10, 5);
  ctx.fillStyle = '#fff';
  ctx.fillText('Время: ' + (stats.timestamp ? new Date(stats.timestamp*1000).toLocaleTimeString() : '-'), w-10, 22);
  ctx.fillText('FPS: ' + (stats.fps ?? '-'), w-10, 37);
  ctx.fillText('Размер: ' + (stats.shape ? stats.shape[0]+'x'+stats.shape[1] : '-'), w-10, 52);
  ctx.fillText('CPU: ' + (stats.cpu !== null ? stats.cpu + '%' : '-'), w-10, 67);
  ctx.fillText('MEM: ' + (stats.mem !== null ? stats.mem + '%' : '-'), w-10, 82);
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
    circle.addEventListener('dblclick', e => {
      e.stopPropagation();
      const idx = parseInt(circle.getAttribute('data-idx'));
      if (roiPoints.length > 3 && idx >= 0 && idx < roiPoints.length) {
        roiPoints.splice(idx, 1);
        drawRoi();
        sendRoi();
      }
    });
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
  if (!wsUrl) return;
  if (ws) ws.close();
  ws = new WebSocket(wsUrl);
  ws.binaryType = 'arraybuffer';
  setStatus('Подключение...', false);
  lastStats.status = 'Подключение...';
  ws.onopen = () => {
    setStatus('Поток запущен');
    lastStats.status = 'Поток запущен';
    if (lastImg) {
      drawRoi();
    }
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
      try {
        const stats = JSON.parse(event.data);
        // Если это ROI от backend
        if (stats.type === 'roi' && Array.isArray(stats.points)) {
          if (lastImg) {
            roiPoints = stats.points;
            drawRoi();
            sendRoi();
          } else {
            pendingRoi = stats.points;
          }
          return;
        }
        lastStats = {...lastStats, ...stats};
        lastStats.status = 'Поток запущен';
        if (lastImg) updateFit();
      } catch(e) {}
      return;
    }
    const blob = new Blob([event.data], {type: 'image/jpeg'});
    const img = new window.Image();
    img.onload = function() {
      lastImg = img;
      lastImgW = img.width;
      lastImgH = img.height;
      // Если есть pendingRoi — применяем его
      if (pendingRoi) {
        roiPoints = pendingRoi;
        pendingRoi = null;
        drawRoi();
        sendRoi();
      } else if (!roiPoints) {
        // Ждём ROI от backend, если не пришёл — fallback
        setTimeout(() => {
          if (!roiPoints) {
            roiPoints = getDefaultRoiPoints(img.width, img.height);
            sendRoi();
            drawRoi();
          }
        }, 200);
      }
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