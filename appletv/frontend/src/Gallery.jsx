import React, { useEffect, useState } from 'react';

export default function Gallery() {
  const [records, setRecords] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [playing, setPlaying] = useState(null);
  const [deleting, setDeleting] = useState(null);

  const fetchRecords = () => {
    setLoading(true);
    fetch('/api/records')
      .then(res => {
        if (!res.ok) throw new Error('Failed to fetch records');
        return res.json();
      })
      .then(setRecords)
      .catch(e => setError(e.message))
      .finally(() => setLoading(false));
  };

  useEffect(() => {
    fetchRecords();
    const timer = setInterval(fetchRecords, 5000);
    return () => clearInterval(timer);
  }, []);



  const handleDelete = async (filename) => {
    if (!window.confirm(`Delete file ${filename}?`)) return;
    setDeleting(filename);
    try {
      const res = await fetch(`/api/records/${encodeURIComponent(filename)}`, { method: 'DELETE' });
      if (!res.ok) throw new Error((await res.json()).error || 'Failed to delete');
      fetchRecords();
    } catch (e) {
      alert(e.message);
    } finally {
      setDeleting(null);
    }
  };

  if (loading) return <div style={{padding:32}}>Loading...</div>;
  if (error) return <div style={{padding:32, color:'red'}}>Error: {error}</div>;

  return (
    <div style={{padding:32}}>
      <h2>Gallery</h2>
      {records.length === 0 ? <p>No recordings found.</p> : (
        <table style={{width:'100%', borderCollapse:'collapse'}}>
          <thead>
            <tr>
              <th align="left">Filename</th>
              <th>Size (MB)</th>
              <th>Duration (s)</th>
              <th>Created</th>
              <th>Play</th>
              <th>Download</th>
              <th>Delete</th>
            </tr>
          </thead>
          <tbody>
            {records.map(r => (
              <tr key={r.filename}>
                <td>{r.filename}</td>
                <td align="right">{(r.size/1024/1024).toFixed(2)}</td>
                <td align="right">{r.duration ? r.duration.toFixed(1) : '-'}</td>
                <td>{new Date(r.createdAt).toLocaleString()}</td>
                <td>
                  <button onClick={() => setPlaying(r.filename)} style={{padding:'2px 8px'}}>Play</button>
                </td>
                <td>
                  <a href={`/api/records/${encodeURIComponent(r.filename)}`} download>
                    Download
                  </a>
                </td>
                <td>
                  <button onClick={() => handleDelete(r.filename)} disabled={deleting===r.filename} style={{padding:'2px 8px', color:'red'}}>
                    {deleting===r.filename ? 'Deleting...' : 'Delete'}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {playing && (
        <div style={{marginTop:32}}>
          <h3>Playing: {playing}</h3>
          <video src={`/api/records/${encodeURIComponent(playing)}`} controls autoPlay style={{maxWidth:'100%'}} />
          <div><button onClick={() => setPlaying(null)} style={{marginTop:8}}>Close</button></div>
        </div>
      )}
    </div>
  );
} 