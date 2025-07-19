import React from 'react';
import { Routes, Route, Link } from 'react-router-dom';
import Gallery from './Gallery';
import WebRTCStream from './WebRTCStream';

export default function App() {
  return (
    <div>
      <Routes>
        <Route path="/" element={<WebRTCStream />} />
        <Route path="/gallery" element={<Gallery />} />
      </Routes>
    </div>
  );
} 