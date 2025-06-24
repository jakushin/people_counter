const canvas = document.getElementById('video-canvas');
const ctx = canvas.getContext('2d');
const statusDiv = document.getElementById('status');
const startBtn = document.getElementById('start-btn');

let ws = null;
let running = false;

function setStatus(msg, error=false) {
  statusDiv.textContent = msg;
  statusDiv.style.color = error ? 'red' : 'green';
}

function resizeCanvas(w, h) {
  canvas.width = w;
  canvas.height = h;
}

startBtn.onclick = () => {
  if (ws) ws.close();
  const user = document.getElementById('user').value;
  const password = document.getElementById('password').value;
  const host = document.getElementById('host').value;
  const wsUrl = `ws://${window.location.hostname}:8000/ws?user=${encodeURIComponent(user)}&password=${encodeURIComponent(password)}&host=${encodeURIComponent(host)}`;
  ws = new WebSocket(wsUrl);
  ws.binaryType = 'arraybuffer';
  setStatus('Подключение...', false);
  ws.onopen = () => setStatus('Поток запущен');
  ws.onerror = e => setStatus('Ошибка WebSocket', true);
  ws.onclose = () => setStatus('Поток остановлен');
  ws.onmessage = (event) => {
    const blob = new Blob([event.data], {type: 'image/jpeg'});
    const img = new window.Image();
    img.onload = function() {
      resizeCanvas(img.width, img.height);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    };
    img.onerror = function() {
      setStatus('Ошибка декодирования изображения', true);
    };
    img.src = URL.createObjectURL(blob);
  };
}; 