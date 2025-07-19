import React from 'react';
import { Routes, Route, Link } from 'react-router-dom';
import Gallery from './Gallery';
import WebRTCStream from './WebRTCStream';

export default function App() {
  return (
    <div>
      <nav style={{padding: 16, borderBottom: '1px solid #ccc'}}>
        <Link to="/">WebRTC Stream</Link> | <Link to="/gallery">Gallery</Link>
      </nav>
      <Routes>
        <Route path="/" element={<WebRTCStream />} />
        <Route path="/gallery" element={<Gallery />} />
      </Routes>
    </div>
  );
} 