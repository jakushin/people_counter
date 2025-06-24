// polygon-editor.js
const img = document.getElementById('video');
const svg = document.getElementById('overlay');
// Если нужно только две точки (как линия), можно начать с двух:
let points = [
  [200, 200],
  [400, 200]
];
let draggingPoint = null;
let draggingMid = null;

function resizeSVG() {
  const cr = img.getBoundingClientRect();
  svg.setAttribute('width', cr.width);
  svg.setAttribute('height', cr.height);
  svg.style.width = cr.width + 'px';
  svg.style.height = cr.height + 'px';
  drawPolygon();
}

function getMidPoint(p1, p2) {
  return [(p1[0]+p2[0])/2, (p1[1]+p2[1])/2];
}

function scalePointsToImg() {
  const cr = img.getBoundingClientRect();
  const scaleX = cr.width / img.naturalWidth;
  const scaleY = cr.height / img.naturalHeight;
  return points.map(([x, y]) => [x * scaleX, y * scaleY]);
}

function scalePointFromScreen(x, y) {
  const cr = img.getBoundingClientRect();
  const scaleX = img.naturalWidth / cr.width;
  const scaleY = img.naturalHeight / cr.height;
  return [x * scaleX, y * scaleY];
}

function drawPolygon() {
  svg.innerHTML = '';
  const scaled = scalePointsToImg();
  // Если две точки — рисуем линию, иначе полигон
  if (points.length === 2) {
    const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
    line.setAttribute('x1', scaled[0][0]);
    line.setAttribute('y1', scaled[0][1]);
    line.setAttribute('x2', scaled[1][0]);
    line.setAttribute('y2', scaled[1][1]);
    line.setAttribute('stroke', '#007bff');
    line.setAttribute('stroke-width', 3);
    svg.appendChild(line);
  } else {
    const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
    polygon.setAttribute('points', scaled.map(p => p.join(',')).join(' '));
    polygon.setAttribute('class', 'polygon-area');
    svg.appendChild(polygon);
  }
  // Draw vertices
  scaled.forEach((p, i) => {
    const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    circle.setAttribute('cx', p[0]);
    circle.setAttribute('cy', p[1]);
    circle.setAttribute('r', 8);
    circle.setAttribute('class', 'vertex');
    circle.addEventListener('mousedown', (e) => {
      draggingPoint = i;
      e.stopPropagation();
    });
    svg.appendChild(circle);
  });
  // Draw midpoints (если больше двух точек)
  if (points.length > 2) {
    for (let i = 0; i < scaled.length; i++) {
      const next = (i+1)%scaled.length;
      const mid = getMidPoint(scaled[i], scaled[next]);
      const midCircle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      midCircle.setAttribute('cx', mid[0]);
      midCircle.setAttribute('cy', mid[1]);
      midCircle.setAttribute('r', 6);
      midCircle.setAttribute('class', 'midpoint');
      midCircle.addEventListener('mousedown', (e) => {
        draggingMid = i+1;
        e.stopPropagation();
      });
      svg.appendChild(midCircle);
    }
  }
}

drawPolygon();

window.addEventListener('mousemove', (e) => {
  if (draggingPoint !== null) {
    const cr = svg.getBoundingClientRect();
    const x = e.clientX - cr.left;
    const y = e.clientY - cr.top;
    const [imgX, imgY] = scalePointFromScreen(x, y);
    points[draggingPoint] = [imgX, imgY];
    drawPolygon();
  }
});

window.addEventListener('mouseup', (e) => {
  if (draggingPoint !== null) {
    draggingPoint = null;
  }
  if (draggingMid !== null) {
    const cr = svg.getBoundingClientRect();
    const x = e.clientX - cr.left;
    const y = e.clientY - cr.top;
    const [imgX, imgY] = scalePointFromScreen(x, y);
    points.splice(draggingMid, 0, [imgX, imgY]);
    draggingMid = null;
    drawPolygon();
  }
});

svg.addEventListener('mouseleave', () => {
  draggingPoint = null;
  draggingMid = null;
});

window.addEventListener('resize', resizeSVG);
img.onload = resizeSVG;
if (img.complete) resizeSVG(); 